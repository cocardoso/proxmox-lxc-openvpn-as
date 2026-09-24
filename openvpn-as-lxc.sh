#!/usr/bin/env bash
# Creates an unprivileged Debian 13 LXC container on Proxmox VE and installs
# OpenVPN Access Server in it, asking every setting through whiptail dialogs.
#
# Source:  https://github.com/cocardoso/proxmox-lxc-openvpn-as
# License: MIT
# This is an independent open-source project, not affiliated with, endorsed
# or supported by OpenVPN Inc. or Proxmox Server Solutions GmbH.
#
# Usage: openvpn-as-lxc.sh [--dry-run] [--help]
# Run as root on a Proxmox VE 8.4+ node (older pct rejects Debian 13).

SCRIPT_VERSION="1.1.0"
TITLE="OpenVPN Access Server LXC"
BACKTITLE="Proxmox VE - OpenVPN Access Server installer v${SCRIPT_VERSION}"

# Read by the container installer through ${!name} in write_env_file.
# shellcheck disable=SC2034
{
  AS_REPO_KEY_URL="https://packages.openvpn.net/as-repo-public.asc"
  AS_REPO_URL="http://packages.openvpn.net/as/debian"
  AS_REPO_SUITE="trixie"
}
TEMPLATE_PREFIX="debian-13-standard_"
WEB_UI_PORT=943
TUN_MODULES_FILE="/etc/modules-load.d/tun.conf"
CF_API="https://api.cloudflare.com/client/v4"
DDNS_UPDATER_PATH="/usr/local/sbin/openvpn-as-ddns"

DRY_RUN=0
HOST_ARCH=""
CT_CREATED=0
LOG_DIR="${LOG_DIR:-/var/log}"
LOG_FILE=/dev/null
WORK_DIR=""
NET_WAIT_TRIES="${NET_WAIT_TRIES:-30}"

VPN_PROTOCOLS="both"
TCP_PORT=""
UDP_PORT=""
DDNS_ENABLED=0
DDNS_ZONE=""
DDNS_RECORD=""
DDNS_TOKEN=""
DDNS_OK=1
CF_ZONE_ID=""

# ---------------------------------------------------------------------------
# Validators: return 0 when the value is acceptable.
# ---------------------------------------------------------------------------

is_ipv4() {
  local octet
  [[ ${1-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    [[ $octet == 0 || $octet != 0* ]] || return 1
    ((octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local value=${1-}
  [[ $value == */* ]] || return 1
  local mask=${value##*/}
  is_ipv4 "${value%/*}" || return 1
  [[ $mask =~ ^[1-9][0-9]?$ ]] && ((mask <= 32))
}

is_positive_int() {
  [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

is_port() {
  is_positive_int "${1-}" && ((${#1} <= 5)) && ((10#$1 <= 65535))
}

is_vpn_tcp_port() {
  is_port "${1-}" && ((10#$1 != WEB_UI_PORT))
}

is_vlan() {
  [[ -z ${1-} ]] && return 0
  [[ $1 =~ ^[1-9][0-9]{0,3}$ ]] && ((10#$1 <= 4094))
}

is_hostname() {
  [[ ${1-} =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

is_fqdn_or_ip() {
  local value=${1-} label
  local -a labels
  is_ipv4 "$value" && return 0
  [[ -n $value && ${#value} -le 253 ]] || return 1
  [[ $value != .* && $value != *. && $value != *..* ]] || return 1
  IFS=. read -ra labels <<<"$value"
  for label in "${labels[@]}"; do
    is_hostname "$label" || return 1
  done
}

is_dns_list() {
  local server
  local -a servers
  read -ra servers <<<"${1-}"
  ((${#servers[@]} > 0)) || return 1
  for server in "${servers[@]}"; do
    is_ipv4 "$server" || return 1
  done
}

is_domain() {
  [[ ${1-} == *.* ]] && ! is_ipv4 "$1" && is_fqdn_or_ip "$1"
}

# The DNS record must be a name inside the zone (not the zone apex).
is_record_in_zone() {
  local record=${1,,} zone=${DDNS_ZONE,,}
  is_domain "$record" && [[ $record == *".$zone" ]]
}

is_disk_size() {
  is_positive_int "${1-}" && ((10#$1 >= 4))
}

is_memory() {
  is_positive_int "${1-}" && ((10#$1 >= 1024))
}

ctid_available() {
  is_positive_int "${1-}" && ((10#$1 >= 100)) || return 1
  pvesh get /cluster/nextid --vmid "$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

msg() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
  log "$*"
}

msg_ok() {
  printf '\033[1;32m OK\033[0m %s\n' "$*"
  log "OK: $*"
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  log "ERROR: $*"
  exit 1
}

user_abort() {
  printf 'Aborted by user. Nothing was created.\n' >&2
  exit 1
}

# Runs a command that changes the host, or only prints it in dry-run mode.
run() {
  if ((DRY_RUN)); then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  log "+ $*"
  "$@" >>"$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# whiptail wrappers (the swap 3>&1 1>&2 2>&3 captures whiptail's answer)
# ---------------------------------------------------------------------------

wt_input() {
  whiptail --backtitle "$BACKTITLE" --title "$TITLE" --inputbox "$1" 10 72 "$2" 3>&1 1>&2 2>&3
}

wt_password() {
  whiptail --backtitle "$BACKTITLE" --title "$TITLE" --passwordbox "$1" 10 72 3>&1 1>&2 2>&3
}

wt_menu() {
  local prompt=$1
  shift
  whiptail --backtitle "$BACKTITLE" --title "$TITLE" --menu "$prompt" 18 72 8 "$@" 3>&1 1>&2 2>&3
}

wt_msg() {
  whiptail --backtitle "$BACKTITLE" --title "$TITLE" --msgbox "$1" 10 72
}

wt_yesno() {
  whiptail --backtitle "$BACKTITLE" --title "$TITLE" --yesno "$1" "${2:-12}" 72
}

# ask VAR PROMPT DEFAULT VALIDATOR ERROR_MESSAGE
ask() {
  local var=$1 prompt=$2 default=$3 validator=$4 error=$5 value
  while true; do
    value=$(wt_input "$prompt" "$default") || user_abort
    if "$validator" "$value"; then
      printf -v "$var" '%s' "$value"
      return 0
    fi
    # Keep the original default: whiptail would parse a value like "-1" as an option.
    wt_msg "Invalid value: '$value'. $error"
  done
}

# ask_password VAR LABEL
ask_password() {
  local var=$1 label=$2 first second
  while true; do
    first=$(wt_password "$label (min. 8 characters)") || user_abort
    if ((${#first} < 8)); then
      wt_msg "The password must have at least 8 characters."
      continue
    fi
    second=$(wt_password "Confirm: $label") || user_abort
    if [[ $first == "$second" ]]; then
      printf -v "$var" '%s' "$first"
      return 0
    fi
    wt_msg "The passwords do not match. Try again."
  done
}

# select_storage VAR CONTENT LABEL
select_storage() {
  local var=$1 content=$2 label=$3 name type avail choice
  local -a options=()
  while read -r name type _ _ _ avail _; do
    options+=("$name" "$(printf '%-10s %6s GiB free' "$type" "$((avail / 1024 / 1024))")")
  done < <(pvesm status --content "$content" 2>/dev/null | awk 'NR > 1 && $3 == "active"')

  ((${#options[@]} > 0)) || die "No active storage supports '$content' ($label)."
  if ((${#options[@]} == 2)); then
    printf -v "$var" '%s' "${options[0]}"
    return 0
  fi
  choice=$(wt_menu "Select the storage for the $label:" "${options[@]}") || user_abort
  printf -v "$var" '%s' "$choice"
}

list_bridges() {
  ip -br link show type bridge 2>/dev/null | awk '$1 ~ /^vmbr/ {print $1}'
}

select_bridge() {
  local bridge choice
  local -a options=()
  while read -r bridge; do
    [[ -n $bridge ]] && options+=("$bridge" "Linux bridge")
  done < <(list_bridges)

  ((${#options[@]} > 0)) || die "No vmbr* bridge found on this node."
  if ((${#options[@]} == 2)); then
    BRIDGE=${options[0]}
    return 0
  fi
  choice=$(wt_menu "Select the network bridge:" "${options[@]}") || user_abort
  BRIDGE=$choice
}

# cf_get TOKEN PATH: GET on the Cloudflare API. The token goes to curl through
# a 0600 header file, never on the command line.
cf_get() {
  local header="$WORK_DIR/cf-auth" response
  (
    umask 077
    printf 'Authorization: Bearer %s\n' "$1" >"$header"
  )
  response=$(curl -sS --max-time 15 -H @"$header" "$CF_API$2" 2>/dev/null) || response=""
  rm -f "$header"
  printf '%s' "$response"
}

# cf_json EXPR: decodes the JSON on stdin into $d and prints the Perl EXPR.
# Perl and JSON::PP are always present on Proxmox VE, jq is not.
cf_json() {
  perl -MJSON::PP -e 'local $/; my $d = eval { decode_json(<STDIN>) } or exit 1;
    my $out = eval $ARGV[0]; exit 1 if $@; print $out // ""' "$1"
}

# Returns 0 when the token can read the zone and its DNS records; sets CF_ZONE_ID.
# shellcheck disable=SC2016 # the single-quoted arguments are Perl code
cloudflare_token_ok() {
  local token=$1 zone=$2 response
  response=$(cf_get "$token" "/zones?name=$zone")
  CF_ZONE_ID=$(cf_json '$d->{success} ? ($d->{result}[0]{id} // "") : ""' <<<"$response") || CF_ZONE_ID=""
  [[ -n $CF_ZONE_ID ]] || return 1
  response=$(cf_get "$token" "/zones/$CF_ZONE_ID/dns_records?per_page=1")
  [[ $(cf_json '$d->{success} ? 1 : 0' <<<"$response" || true) == 1 ]]
}

# Prints the A, AAAA and CNAME records of NAME as "TYPE CONTENT (proxied|DNS only)".
# shellcheck disable=SC2016 # the single-quoted arguments are Perl code
cloudflare_records() {
  local response
  response=$(cf_get "$1" "/zones/$CF_ZONE_ID/dns_records?name=$2")
  cf_json '$d->{success} or die; join "", map { "$_->{type} $_->{content} (" . ($_->{proxied} ? "proxied" : "DNS only") . ")\n" }
    grep { $_->{type} =~ /^(A|AAAA|CNAME)$/ } @{ $d->{result} }' <<<"$response"
}

# Returns 0 when DDNS_RECORD can be managed by the updater: it does not exist
# yet, or it is a single A record the user agrees to take over.
ddns_record_usable() {
  local records a_count
  if ! records=$(cloudflare_records "$DDNS_TOKEN" "$DDNS_RECORD"); then
    wt_msg "Could not read the DNS records of $DDNS_RECORD from Cloudflare."
    return 1
  fi
  a_count=$(grep -c '^A ' <<<"$records" || true)
  if grep -qE '^(AAAA|CNAME) ' <<<"$records" || ((a_count > 1)); then
    wt_msg "$DDNS_RECORD already has records the dynamic DNS updater cannot manage:\n\n$records\n\nChoose another name."
    return 1
  fi
  if [[ -n $records ]]; then
    wt_yesno "$DDNS_RECORD already exists:\n\n$records\n\nIt will point to this network's public IP and be set to DNS only (not proxied). Use it?" 14 || return 1
  fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

banner() {
  cat <<'EOF'
  ___                __     ______  _   _      _    ____
 / _ \ _ __   ___ _ _\ \   / /  _ \| \ | |    / \  / ___|
| | | | '_ \ / _ \ '_ \ \ / /| |_) |  \| |   / _ \ \___ \
| |_| | |_) |  __/ | | \ V / |  __/| |\  |  / ___ \ ___) |
 \___/| .__/ \___|_| |_|\_/  |_|   |_| \_| /_/   \_\____/
      |_|
EOF
  printf '  OpenVPN Access Server LXC for Proxmox VE - v%s\n' "$SCRIPT_VERSION"
  printf '  https://github.com/cocardoso/proxmox-lxc-openvpn-as\n\n'
  printf '  Independent open-source project, not affiliated with, endorsed or\n'
  printf '  supported by OpenVPN Inc. or Proxmox Server Solutions GmbH.\n\n'
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--help]

Creates an unprivileged Debian 13 LXC container on this Proxmox VE node and
installs OpenVPN Access Server in it. All settings are asked interactively.

  --dry-run   Ask everything and print the commands instead of running them.
  -h, --help  Show this help.
EOF
}

parse_args() {
  while (($# > 0)); do
    case $1 in
      --dry-run) DRY_RUN=1 ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

pve_version_ok() {
  local version major minor
  version=$(pveversion 2>/dev/null | sed -n 's|^pve-manager/\([0-9]*\.[0-9]*\).*|\1|p')
  [[ -n $version ]] || return 1
  major=${version%%.*}
  minor=${version#*.}
  ((major > 8 || (major == 8 && minor >= 4)))
}

preflight() {
  ((EUID == 0)) || die "Run this script as root on the Proxmox VE host."

  local cmd
  for cmd in pct pveam pvesm pvesh pveversion whiptail ip dpkg; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd (is this a Proxmox VE host?)"
  done

  HOST_ARCH=$(dpkg --print-architecture)
  [[ $HOST_ARCH == amd64 ]] || die "OpenVPN Access Server packages exist only for amd64 on Debian (this host is $HOST_ARCH)."

  pve_version_ok || die "Proxmox VE 8.4 or newer is required (found: $(pveversion 2>/dev/null || echo unknown))."

  if [[ ! -c /dev/net/tun ]]; then
    run modprobe tun
    ((DRY_RUN)) || [[ -c /dev/net/tun ]] || die "/dev/net/tun is not available on the host."
  fi
}

collect_settings() {
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null) || die "Could not get the next free CT ID."

  ask CTID "Container ID:" "$next_id" ctid_available "Use a free ID >= 100."
  ask CT_HOSTNAME "Container hostname:" "openvpn-as" is_hostname "Letters, digits and '-' only."
  ask_password CT_PASSWORD "Container root password"

  select_storage TEMPLATE_STORAGE vztmpl "container template"
  select_storage ROOTFS_STORAGE rootdir "container disk"
  ask DISK_GB "Disk size in GiB:" "8" is_disk_size "Use a whole number >= 4."
  ask CORES "CPU cores:" "2" is_positive_int "Use a whole number >= 1."
  ask MEMORY_MB "Memory in MiB:" "2048" is_memory "Use a whole number >= 1024."

  select_bridge
  ask VLAN "VLAN tag (leave empty for none):" "" is_vlan "Use 1-4094 or leave empty."
  ask IP_CIDR "Container IPv4 address with prefix (e.g. 192.168.1.50/24):" "" is_ipv4_cidr "Use the form a.b.c.d/nn."
  ask GATEWAY "Gateway IPv4 address:" "" is_ipv4 "Use the form a.b.c.d."
  ask DNS "DNS servers (space separated):" "$GATEWAY" is_dns_list "Use IPv4 addresses separated by spaces."

  ask_password ADMIN_PASSWORD "OpenVPN AS admin ('openvpn' user) password"
  VPN_PROTOCOLS=$(wt_menu "VPN protocols. Pick 'UDP only' when your router can forward only UDP:" \
    both "UDP + TCP (TCP as fallback)" \
    udp "UDP only") || user_abort
  if [[ $VPN_PROTOCOLS == both ]]; then
    ask TCP_PORT "OpenVPN daemon TCP port:" "443" is_vpn_tcp_port "Use 1-65535 (not $WEB_UI_PORT, used by the web UI)."
  fi
  ask UDP_PORT "OpenVPN daemon UDP port:" "1194" is_port "Use 1-65535."

  collect_ddns
  if ((DDNS_ENABLED)); then
    PUBLIC_HOST=$DDNS_RECORD
  else
    ask PUBLIC_HOST "Public hostname or IP that VPN clients will connect to:" "${IP_CIDR%/*}" is_fqdn_or_ip "Use a DNS name or an IPv4 address."
  fi
}

# Optional Cloudflare dynamic DNS: a record kept pointing to the public IP.
collect_ddns() {
  DDNS_ENABLED=0
  wt_yesno "Keep a Cloudflare DNS record pointing to this network's public IP (dynamic DNS)?\n\nUse it when your public IP changes. You need a Cloudflare API token with Zone:Read and DNS:Edit permissions on the zone." 14 || return 0

  ask DDNS_ZONE "Cloudflare zone (e.g. example.com):" "" is_domain "Use a domain name such as example.com."
  DDNS_ZONE=${DDNS_ZONE,,}
  ask_ddns_record
  while true; do
    DDNS_TOKEN=$(wt_password "Cloudflare API token for $DDNS_ZONE (leave empty to skip dynamic DNS):") || user_abort
    [[ -z $DDNS_TOKEN ]] && return 0
    cloudflare_token_ok "$DDNS_TOKEN" "$DDNS_ZONE" && break
    wt_msg "Cloudflare rejected the token, or it cannot read the DNS records of $DDNS_ZONE. Check the token permissions and try again."
  done
  until ddns_record_usable; do
    ask_ddns_record
  done
  DDNS_ENABLED=1
}

ask_ddns_record() {
  ask DDNS_RECORD "DNS record for the VPN clients (created as DNS only, not proxied):" "vpn.$DDNS_ZONE" is_record_in_zone "Use a name inside $DDNS_ZONE, such as vpn.$DDNS_ZONE."
  DDNS_RECORD=${DDNS_RECORD,,}
}

confirm_settings() {
  local summary
  summary=$(
    cat <<EOF
CT ID:           $CTID
Hostname:        $CT_HOSTNAME
Template store:  $TEMPLATE_STORAGE
Disk:            ${DISK_GB} GiB on $ROOTFS_STORAGE
CPU / Memory:    $CORES cores / $MEMORY_MB MiB
Network:         $BRIDGE${VLAN:+ (VLAN $VLAN)}, $IP_CIDR via $GATEWAY
DNS:             $DNS
Public host:     $PUBLIC_HOST
Dynamic DNS:     $( ((DDNS_ENABLED)) && echo "Cloudflare, $DDNS_RECORD" || echo "off")
VPN ports:       UDP $UDP_PORT${TCP_PORT:+, TCP $TCP_PORT}
Mode:            $( ((DRY_RUN)) && echo "DRY RUN (nothing is changed)" || echo "create for real")

Create the container?
EOF
  )
  wt_yesno "$summary" 22 || user_abort
}

# Loads the tun module on every host boot so /dev/net/tun is always there for dev0.
persist_tun_module() {
  if grep -qsx 'tun' /etc/modules /etc/modules-load.d/*.conf; then
    msg_ok "tun module already loaded at boot"
    return 0
  fi
  msg "Loading the tun module at boot ($TUN_MODULES_FILE)"
  run mkdir -p "${TUN_MODULES_FILE%/*}"
  printf 'tun\n' | run tee "$TUN_MODULES_FILE"
}

ensure_template() {
  local template pattern="^${TEMPLATE_PREFIX}.*_${HOST_ARCH}\.tar\.(zst|xz|gz)$"
  msg "Updating the container template index"
  run pveam update

  template=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "$pattern" | sort -V | tail -n 1) || true
  if [[ -z $template ]]; then
    ((DRY_RUN)) && die "Debian 13 template not found in the local index. Run 'pveam update' and try the dry run again."
    die "Debian 13 template not found in 'pveam available'. Is this node on Proxmox VE 8.4 or newer?"
  fi

  TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${template}"
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk '{print $1}' | grep -xF "$TEMPLATE_VOLID" >/dev/null; then
    msg_ok "Template $template already present"
  else
    msg "Downloading template $template"
    run pveam download "$TEMPLATE_STORAGE" "$template"
  fi
}

create_container() {
  local net0="name=eth0,bridge=${BRIDGE},ip=${IP_CIDR},gw=${GATEWAY}${VLAN:+,tag=${VLAN}}"

  msg "Creating container $CTID"
  run pct create "$CTID" "$TEMPLATE_VOLID" \
    --hostname "$CT_HOSTNAME" \
    --ostype debian \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap 512 \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "$net0" \
    --nameserver "$DNS" \
    --timezone host
  ((DRY_RUN)) || CT_CREATED=1

  msg "Passing /dev/net/tun to the container"
  run pct set "$CTID" --dev0 /dev/net/tun

  msg "Starting container $CTID"
  run pct start "$CTID"
}

wait_for_network() {
  ((DRY_RUN)) && return 0
  msg "Waiting for the container network"
  local i
  for ((i = 1; i <= NET_WAIT_TRIES; i++)); do
    if pct exec "$CTID" -- getent hosts packages.openvpn.net >/dev/null 2>&1; then
      msg_ok "Network is up"
      return 0
    fi
    sleep 2
  done
  die "The container cannot resolve packages.openvpn.net. Check IP, gateway, VLAN and DNS."
}

# Prints the script that runs inside the container. It reads its settings
# from ENV_FILE (written with printf %q) and deletes that file right away.
container_installer() {
  cat <<'INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE=/root/ovpn-install.env
SACLI=/usr/local/openvpn_as/scripts/sacli

# shellcheck disable=SC1090
source "$ENV_FILE"
rm -f "$ENV_FILE"
export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8

echo "--- Setting the root password"
printf 'root:%s\n' "$CT_PASSWORD" | chpasswd

echo "--- Upgrading the base system"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y install ca-certificates wget net-tools gnupg

echo "--- Adding the OpenVPN Access Server repository"
install -d -m 0755 /etc/apt/keyrings
wget -qO /etc/apt/keyrings/as-repository.asc "$AS_REPO_KEY_URL"
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/as-repository.asc] $AS_REPO_URL $AS_REPO_SUITE main" \
  >/etc/apt/sources.list.d/openvpn-as-repo.list
apt-get update

echo "--- Installing openvpn-as"
apt-get -y install openvpn-as

echo "--- Waiting for Access Server to be ready"
for _ in $(seq 1 60); do
  "$SACLI" status >/dev/null 2>&1 && break
  sleep 2
done
"$SACLI" status >/dev/null

echo "--- Configuring Access Server"
"$SACLI" --key host.name --value "$PUBLIC_HOST" ConfigPut
if [[ $VPN_PROTOCOLS == udp ]]; then
  # A single UDP daemon, like the Admin UI "UDP" protocol setting.
  "$SACLI" --key vpn.server.daemon.enable --value false ConfigPut
  "$SACLI" --key vpn.daemon.0.listen.protocol --value udp ConfigPut
  "$SACLI" --key vpn.daemon.0.listen.port --value "$UDP_PORT" ConfigPut
  "$SACLI" --key vpn.server.port_share.enable --value false ConfigPut
else
  "$SACLI" --key vpn.server.daemon.tcp.port --value "$TCP_PORT" ConfigPut
  "$SACLI" --key vpn.server.daemon.udp.port --value "$UDP_PORT" ConfigPut
fi
# sacli has no stdin option, so the password is briefly visible to root
# inside this container only.
# DCO (kernel ovpn module) needs CAP_NET_ADMIN in the host namespace, which an
# unprivileged LXC lacks: its netlink calls fail and the daemons stop.
# Without DCO the daemons use /dev/net/tun instead.
"$SACLI" --key vpn.server.daemon.ovpndco --value false ConfigPut
"$SACLI" --user openvpn --new_pass "$ADMIN_PASSWORD" SetLocalPassword
# The package already started the daemons with DCO on. Restarting cancels their
# pending queries, so "sacli start" reports errors even when the new daemons
# come up fine; the status checks below decide instead.
"$SACLI" start || echo "sacli start reported errors; checking the daemons"

echo "--- Checking the VPN daemons"
for _ in $(seq 1 15); do
  status=$("$SACLI" status)
  grep -q '"openvpn_[0-9]*": "on"' <<<"$status" && ! grep -q '"openvpn_[0-9]*": "off"' <<<"$status" && break
  sleep 2
done
if grep -q '"openvpn_[0-9]*": "off"' <<<"$status" || ! grep -q '"openvpn_[0-9]*": "on"' <<<"$status"; then
  echo "Some OpenVPN daemons are not running:"
  grep '"openvpn_' <<<"$status"
  exit 1
fi

echo "--- Checking listening ports"
for _ in $(seq 1 30); do
  [[ -n $(ss -Hltn "sport = :$WEB_UI_PORT") ]] && break
  sleep 2
done
[[ -n $(ss -Hltn "sport = :$WEB_UI_PORT") ]] || { echo "Web UI is not listening on $WEB_UI_PORT"; exit 1; }

if [[ $DDNS_ENABLED == 1 ]]; then
  echo "--- Setting up Cloudflare dynamic DNS"
  apt-get -y install curl jq
  (
    umask 077
    printf 'DDNS_ZONE=%q\nDDNS_RECORD=%q\nDDNS_TOKEN=%q\n' "$DDNS_ZONE" "$DDNS_RECORD" "$DDNS_TOKEN" \
      >/etc/openvpn-as-ddns.conf
  )
  cat >/etc/systemd/system/openvpn-as-ddns.service <<'UNIT'
[Unit]
Description=Update the Cloudflare DNS record of OpenVPN Access Server
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/openvpn-as-ddns
UNIT
  cat >/etc/systemd/system/openvpn-as-ddns.timer <<'UNIT'
[Unit]
Description=Run openvpn-as-ddns every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now openvpn-as-ddns.timer
fi
echo "--- Done"
INSTALLER
}

# Prints the dynamic DNS updater installed in the container. It keeps a
# Cloudflare A record (DNS only) pointing to the public IPv4 of the network.
ddns_updater() {
  cat <<'DDNS'
#!/usr/bin/env bash
# Keeps a Cloudflare DNS A record (DNS only) pointing to this network's public
# IPv4. Installed by openvpn-as-lxc.sh and run by openvpn-as-ddns.timer.
set -euo pipefail

CONF=${OPENVPN_AS_DDNS_CONF:-/etc/openvpn-as-ddns.conf}
API=https://api.cloudflare.com/client/v4

# shellcheck disable=SC1090
source "$CONF"
: "${DDNS_ZONE:?}" "${DDNS_RECORD:?}" "${DDNS_TOKEN:?}"

# cf METHOD PATH [JSON]: calls the API. The token reaches curl through a file
# descriptor, so it never shows up in the process list.
cf() {
  local method=$1 path=$2 body=${3-}
  if [[ -n $body ]]; then
    curl -sS --max-time 20 -X "$method" -H @<(printf 'Authorization: Bearer %s\n' "$DDNS_TOKEN") \
      -H 'Content-Type: application/json' --data "$body" "$API$path"
  else
    curl -sS --max-time 20 -X "$method" -H @<(printf 'Authorization: Bearer %s\n' "$DDNS_TOKEN") "$API$path"
  fi
}

# check RESPONSE WHAT: exits with the API error messages unless it succeeded.
check() {
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$1"; then
    echo "Cloudflare API error while $2: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$1" 2>/dev/null || echo "$1")" >&2
    exit 1
  fi
}

is_ipv4() {
  local octet
  [[ ${1-} =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for octet in "${BASH_REMATCH[@]:1}"; do
    ((10#$octet <= 255)) || return 1
  done
}

public_ip() {
  local ip
  ip=$(curl -4 -sS --max-time 10 https://api.ipify.org 2>/dev/null) || ip=""
  if ! is_ipv4 "$ip"; then
    ip=$(curl -4 -sS --max-time 10 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p') || ip=""
  fi
  if ! is_ipv4 "$ip"; then
    echo "Could not detect the public IPv4 address." >&2
    exit 1
  fi
  printf '%s\n' "$ip"
}

ip=$(public_ip)

response=$(cf GET "/zones?name=$DDNS_ZONE")
check "$response" "looking up the zone $DDNS_ZONE"
zone_id=$(jq -r '.result[0].id // empty' <<<"$response")
if [[ -z $zone_id ]]; then
  echo "Zone $DDNS_ZONE not found, or the token cannot see it." >&2
  exit 1
fi

response=$(cf GET "/zones/$zone_id/dns_records?name=$DDNS_RECORD")
check "$response" "reading the record $DDNS_RECORD"
# Only a single A record can be managed: a CNAME blocks it, an AAAA would send
# IPv6 clients elsewhere and extra A records would keep answering old IPs.
if ! jq -e '[.result[] | select(.type == "AAAA" or .type == "CNAME")] == [] and ([.result[] | select(.type == "A")] | length) <= 1' >/dev/null <<<"$response"; then
  echo "$DDNS_RECORD has CNAME/AAAA or several A records; leave a single A record (or none)." >&2
  exit 1
fi
record=$(jq -c '[.result[] | select(.type == "A")][0] // {}' <<<"$response")
record_id=$(jq -r '.id // empty' <<<"$record")
current_ip=$(jq -r '.content // empty' <<<"$record")
proxied=$(jq -r '.proxied // false' <<<"$record")

# VPN traffic cannot go through the Cloudflare proxy, so the record is DNS only.
body=$(jq -nc --arg name "$DDNS_RECORD" --arg ip "$ip" '{type: "A", name: $name, content: $ip, ttl: 60, proxied: false}')
if [[ -z $record_id ]]; then
  response=$(cf POST "/zones/$zone_id/dns_records" "$body")
  check "$response" "creating the record $DDNS_RECORD"
  echo "Created $DDNS_RECORD -> $ip"
elif [[ $current_ip == "$ip" && $proxied == false ]]; then
  echo "$DDNS_RECORD already points to $ip"
else
  response=$(cf PATCH "/zones/$zone_id/dns_records/$record_id" "$body")
  check "$response" "updating the record $DDNS_RECORD"
  echo "Updated $DDNS_RECORD: $current_ip -> $ip"
fi
DDNS
}

# Writes the installer settings as shell-quoted assignments, readable only by root.
write_env_file() {
  local file=$1 name
  (
    umask 077
    : >"$file"
    for name in CT_PASSWORD ADMIN_PASSWORD PUBLIC_HOST VPN_PROTOCOLS TCP_PORT UDP_PORT WEB_UI_PORT \
      AS_REPO_KEY_URL AS_REPO_URL AS_REPO_SUITE DDNS_ENABLED DDNS_ZONE DDNS_RECORD DDNS_TOKEN; do
      printf '%s=%q\n' "$name" "${!name}" >>"$file"
    done
  )
}

install_openvpn_as() {
  local installer="$WORK_DIR/ovpn-install.sh" env_file="$WORK_DIR/ovpn-install.env"
  container_installer >"$installer"
  write_env_file "$env_file"

  run pct push "$CTID" "$env_file" /root/ovpn-install.env --perms 0600
  run pct push "$CTID" "$installer" /root/ovpn-install.sh --perms 0700
  rm -f "$env_file"
  if ((DDNS_ENABLED)); then
    ddns_updater >"$WORK_DIR/openvpn-as-ddns"
    run pct push "$CTID" "$WORK_DIR/openvpn-as-ddns" "$DDNS_UPDATER_PATH" --perms 0755
  fi

  msg "Installing OpenVPN Access Server (this takes a few minutes, log: $LOG_FILE)"
  if ! run pct exec "$CTID" -- bash /root/ovpn-install.sh; then
    tail -n 20 "$LOG_FILE" >&2 || true
    die "The installation inside the container failed."
  fi
  run pct exec "$CTID" -- rm -f /root/ovpn-install.sh
  msg_ok "OpenVPN Access Server installed"
}

# Runs the first dynamic DNS update. A failure is only a warning: the VPN works
# and the timer keeps retrying every 5 minutes.
start_ddns() {
  msg "Updating the Cloudflare DNS record $DDNS_RECORD"
  if run pct exec "$CTID" -- systemctl start openvpn-as-ddns.service; then
    msg_ok "Dynamic DNS is active ($DDNS_RECORD, checked every 5 minutes)"
  else
    DDNS_OK=0
  fi
}

print_summary() {
  local ip=${IP_CIDR%/*} forwards
  forwards="    UDP $UDP_PORT   (VPN over UDP)"
  if [[ -n $TCP_PORT ]]; then
    forwards="    TCP $TCP_PORT   (VPN over TCP; also serves the Client UI)
$forwards"
  fi
  cat <<EOF

$( ((DRY_RUN)) && echo "Dry run finished. Nothing was changed." || echo "OpenVPN Access Server is ready.")

  Container:    $CTID ($CT_HOSTNAME)
  Admin UI:     https://$ip:$WEB_UI_PORT/admin   (user: openvpn)
  Client UI:    https://$ip:$WEB_UI_PORT/
  Public host:  $PUBLIC_HOST$( ((DDNS_ENABLED)) && echo "   (Cloudflare dynamic DNS)")

  Forward these ports on your router/firewall to $ip:
$forwards
  Keep TCP $WEB_UI_PORT internal unless you really need the Admin UI from outside.

  Log: $( ((DRY_RUN)) && echo "none (dry run)" || echo "$LOG_FILE")
EOF
  if ((!DDNS_OK)); then
    printf '\n  WARNING: the first dynamic DNS update failed. The timer retries every 5 minutes.\n'
    printf '  Check that the token has DNS:Edit on %s, then see:\n' "$DDNS_ZONE"
    printf '    pct exec %s -- journalctl -u openvpn-as-ddns\n' "$CTID"
  fi
}

on_err() {
  log "Command failed at line $1: $2"
}

on_exit() {
  local status=$?
  [[ -n $WORK_DIR ]] && rm -rf "$WORK_DIR"
  if ((status != 0 && CT_CREATED && !DRY_RUN)); then
    printf 'Installation failed. Log: %s\n' "$LOG_FILE" >&2
    if wt_yesno "The installation failed.\n\nDestroy container $CTID?"; then
      pct stop "$CTID" >/dev/null 2>&1 || true
      pct destroy "$CTID" --purge >/dev/null 2>&1 && printf 'Container %s destroyed.\n' "$CTID" >&2
    else
      printf 'Container %s kept for inspection.\n' "$CTID" >&2
    fi
  fi
}

main() {
  set -Eeuo pipefail
  trap 'on_err "$LINENO" "$BASH_COMMAND"' ERR
  trap on_exit EXIT

  parse_args "$@"
  banner
  preflight
  WORK_DIR=$(mktemp -d)

  collect_settings
  confirm_settings

  if ((DRY_RUN)); then
    LOG_FILE="$WORK_DIR/dry-run.log"
  else
    LOG_FILE="$LOG_DIR/openvpn-as-lxc-${CTID}.log"
  fi
  log "openvpn-as-lxc.sh v$SCRIPT_VERSION starting for CT $CTID"

  persist_tun_module
  ensure_template
  create_container
  wait_for_network
  install_openvpn_as
  if ((DDNS_ENABLED)); then
    start_ddns
  fi
  print_summary
}

# Run main unless sourced (tests). BASH_SOURCE is empty under bash -c "$(curl ...)".
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then
  main "$@"
fi
