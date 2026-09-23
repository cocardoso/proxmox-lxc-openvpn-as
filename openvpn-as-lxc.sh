#!/usr/bin/env bash
# Creates an unprivileged Debian 13 LXC container on Proxmox VE and installs
# OpenVPN Access Server in it, asking every setting through whiptail dialogs.
#
# Usage: openvpn-as-lxc.sh [--dry-run] [--help]
# Run as root on a Proxmox VE 8.1+ node.

SCRIPT_VERSION="1.0.0"
TITLE="OpenVPN Access Server LXC"
BACKTITLE="Proxmox VE - OpenVPN Access Server installer v${SCRIPT_VERSION}"

# Read by the container installer through ${!name} in write_env_file.
# shellcheck disable=SC2034
{
  AS_REPO_KEY_URL="https://packages.openvpn.net/as-repo-public.asc"
  AS_REPO_URL="http://packages.openvpn.net/as/debian"
  AS_REPO_SUITE="trixie"
}
TEMPLATE_PATTERN='^debian-13-standard_.*\.tar\.(zst|xz|gz)$'
WEB_UI_PORT=943

DRY_RUN=0
CT_CREATED=0
LOG_DIR="${LOG_DIR:-/var/log}"
LOG_FILE=/dev/null
WORK_DIR=""
NET_WAIT_TRIES="${NET_WAIT_TRIES:-30}"

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
    wt_msg "Invalid value: '$value'. $error"
    default=$value
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

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

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
  ((major > 8 || (major == 8 && minor >= 1)))
}

preflight() {
  ((EUID == 0)) || die "Run this script as root on the Proxmox VE host."

  local cmd
  for cmd in pct pveam pvesm pvesh pveversion whiptail ip dpkg; do
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd (is this a Proxmox VE host?)"
  done

  local arch
  arch=$(dpkg --print-architecture)
  [[ $arch == amd64 ]] || die "OpenVPN Access Server packages exist only for amd64 on Debian (this host is $arch)."

  pve_version_ok || die "Proxmox VE 8.1 or newer is required (found: $(pveversion 2>/dev/null || echo unknown))."

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
  ask PUBLIC_HOST "Public hostname or IP that VPN clients will connect to:" "${IP_CIDR%/*}" is_fqdn_or_ip "Use a DNS name or an IPv4 address."
  ask TCP_PORT "OpenVPN daemon TCP port:" "443" is_vpn_tcp_port "Use 1-65535 (not $WEB_UI_PORT, used by the web UI)."
  ask UDP_PORT "OpenVPN daemon UDP port:" "1194" is_port "Use 1-65535."
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
VPN ports:       TCP $TCP_PORT, UDP $UDP_PORT
Mode:            $( ((DRY_RUN)) && echo "DRY RUN (nothing is changed)" || echo "create for real")

Create the container?
EOF
  )
  wt_yesno "$summary" 22 || user_abort
}

ensure_template() {
  local template
  msg "Updating the container template index"
  run pveam update

  template=$(pveam available --section system 2>/dev/null | awk '{print $2}' | grep -E "$TEMPLATE_PATTERN" | sort -V | tail -n 1) || true
  [[ -n $template ]] || die "Debian 13 template not found in 'pveam available'. Is this node on Proxmox VE 8.4 or newer?"

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
export DEBIAN_FRONTEND=noninteractive

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
"$SACLI" --key vpn.server.daemon.tcp.port --value "$TCP_PORT" ConfigPut
"$SACLI" --key vpn.server.daemon.udp.port --value "$UDP_PORT" ConfigPut
# sacli has no stdin option, so the password is briefly visible to root
# inside this container only.
"$SACLI" --user openvpn --new_pass "$ADMIN_PASSWORD" SetLocalPassword
"$SACLI" start

echo "--- Checking listening ports"
for _ in $(seq 1 30); do
  ss -Hltn "sport = :$WEB_UI_PORT" | grep -q . && break
  sleep 2
done
ss -Hltn "sport = :$WEB_UI_PORT" | grep -q . || { echo "Web UI is not listening on $WEB_UI_PORT"; exit 1; }
echo "--- Done"
INSTALLER
}

# Writes the installer settings as shell-quoted assignments, readable only by root.
write_env_file() {
  local file=$1 name
  (
    umask 077
    : >"$file"
    for name in CT_PASSWORD ADMIN_PASSWORD PUBLIC_HOST TCP_PORT UDP_PORT WEB_UI_PORT \
      AS_REPO_KEY_URL AS_REPO_URL AS_REPO_SUITE; do
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

  msg "Installing OpenVPN Access Server (this takes a few minutes, log: $LOG_FILE)"
  if ! run pct exec "$CTID" -- bash /root/ovpn-install.sh; then
    tail -n 20 "$LOG_FILE" >&2 || true
    die "The installation inside the container failed."
  fi
  run pct exec "$CTID" -- rm -f /root/ovpn-install.sh
  msg_ok "OpenVPN Access Server installed"
}

print_summary() {
  local ip=${IP_CIDR%/*}
  cat <<EOF

$( ((DRY_RUN)) && echo "Dry run finished. Nothing was changed." || echo "OpenVPN Access Server is ready.")

  Container:    $CTID ($CT_HOSTNAME)
  Admin UI:     https://$ip:$WEB_UI_PORT/admin   (user: openvpn)
  Client UI:    https://$ip:$WEB_UI_PORT/
  Public host:  $PUBLIC_HOST

  Forward these ports from $PUBLIC_HOST to $ip:
    TCP $TCP_PORT   (VPN over TCP; also serves the Client UI)
    UDP $UDP_PORT   (VPN over UDP)
  Keep TCP $WEB_UI_PORT internal unless you really need the Admin UI from outside.

  Log: $( ((DRY_RUN)) && echo "none (dry run)" || echo "$LOG_FILE")
EOF
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

  ensure_template
  create_container
  wait_for_network
  install_openvpn_as
  print_summary
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
