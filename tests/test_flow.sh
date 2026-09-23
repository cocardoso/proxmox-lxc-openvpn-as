#!/usr/bin/env bash
# End-to-end tests of the interactive flow against fake Proxmox commands.
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

ROOT=$PWD
export PATH="$ROOT/tests/stubs:$PATH"

CT_PASS="Ct'root \"pa\$\$ :x"
ADMIN_PASS='Adm!n $(id) `x` ;&|*'

# Default answers, one per dialog (template storage is auto-selected).
default_answers() {
  printf '%s\n' 105 openvpn-as "$CT_PASS" "$CT_PASS" local-lvm 8 2 2048 vmbr1 20 \
    192.168.20.50/24 192.168.20.1 "1.1.1.1 9.9.9.9" "$ADMIN_PASS" "$ADMIN_PASS" \
    vpn.example.com 443 1194 yes
}

# run_flow ANSWERS_TEXT [script args...]  -> sets OUT, STATUS, CALLS
run_flow() {
  local answers=$1
  shift
  local tmp
  tmp=$(mktemp -d)
  printf '%s' "$answers" >"$tmp/answers"
  : >"$tmp/calls"
  mkdir -p "$tmp/pushed" "$tmp/log"
  OUT=$(STUB_ANSWERS="$tmp/answers" STUB_LOG="$tmp/calls" STUB_PUSH_DIR="$tmp/pushed" \
    LOG_DIR="$tmp/log" NET_WAIT_TRIES=1 timeout 20 bash ./openvpn-as-lxc.sh "$@" 2>&1)
  STATUS=$?
  CALLS=$(cat "$tmp/calls")
  PUSHED=$tmp/pushed
  LOGS=$(cat "$tmp/log"/* 2>/dev/null)
}

echo "# dry run, full flow"
run_flow "$(default_answers)" --dry-run
assert_eq "dry run exits 0" 0 "$STATUS"
assert_contains "creates from newest Debian 13 template" "$OUT" \
  "[dry-run] pct create 105 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst"
assert_contains "static net with vlan" "$OUT" \
  "--net0 name=eth0,bridge=vmbr1,ip=192.168.20.50/24,gw=192.168.20.1,tag=20"
assert_contains "unprivileged" "$OUT" "--unprivileged 1"
assert_contains "rootfs" "$OUT" "--rootfs local-lvm:8"
assert_contains "dns" "$OUT" "--nameserver 1.1.1.1 9.9.9.9"
assert_contains "tun passthrough" "$OUT" "[dry-run] pct set 105 --dev0 /dev/net/tun"
assert_contains "downloads template" "$OUT" "[dry-run] pveam download local debian-13-standard_13.1-2_amd64.tar.zst"
assert_not_contains "no real pct call" "$CALLS" "pct "
assert_not_contains "ct password hidden" "$OUT" "$CT_PASS"
assert_not_contains "admin password hidden" "$OUT" "$ADMIN_PASS"
assert_contains "summary shows admin url" "$OUT" "https://192.168.20.50:943/admin"

echo "# no vlan"
run_flow "$(default_answers | sed '10s/.*//')" --dry-run
assert_contains "net0 without tag" "$OUT" "gw=192.168.20.1 --nameserver"

echo "# cancel on the third dialog"
run_flow "$(printf '%s\n' 105 openvpn-as __CANCEL__)" --dry-run
assert_eq "cancel exits 1" 1 "$STATUS"
assert_contains "abort message" "$OUT" "Aborted by user"
assert_not_contains "nothing created" "$OUT" "pct create"

echo "# cancel on the summary"
run_flow "$(default_answers | sed '$s/.*/no/')" --dry-run
assert_eq "summary 'no' exits 1" 1 "$STATUS"
assert_not_contains "nothing created after 'no'" "$OUT" "pct create"

echo "# password mismatch and short password are asked again"
run_flow "$(printf '%s\n' 105 openvpn-as short "$CT_PASS" other-password; default_answers | sed -n '3,$p')" --dry-run
assert_eq "retry flow exits 0" 0 "$STATUS"
assert_contains "short password warning" "$CALLS" "at least 8 characters"
assert_contains "mismatch warning" "$CALLS" "do not match"

echo "# invalid values are asked again"
run_flow "$(default_answers | sed '11s/.*/192.168.20.300\/24\n192.168.20.50\/24/')" --dry-run
assert_eq "invalid ip flow exits 0" 0 "$STATUS"
assert_contains "invalid ip warning" "$CALLS" "Invalid value: '192.168.20.300/24'"

echo "# invalid value starting with '-' is asked again, not aborted"
run_flow "$(default_answers | sed '10s/.*/-1\n20/')" --dry-run
assert_eq "negative vlan flow exits 0" 0 "$STATUS"
assert_contains "negative vlan rejected" "$CALLS" "Invalid value: '-1'"
assert_contains "vlan applied after retry" "$OUT" "tag=20"

echo "# CT ID in use"
export STUB_USED_IDS=105
run_flow "$(default_answers | sed '1s/.*/105\n106/')" --dry-run
unset STUB_USED_IDS
assert_contains "used id rejected" "$CALLS" "Invalid value: '105'"
assert_contains "next id used" "$OUT" "pct create 106 "

echo "# TCP port 943 is rejected"
run_flow "$(default_answers | sed '17s/.*/943\n443/')" --dry-run
assert_contains "943 rejected" "$CALLS" "Invalid value: '943'"
assert_eq "943 flow still exits 0" 0 "$STATUS"

echo "# template already present"
STUB_HAS_TEMPLATE=1 run_flow "$(default_answers)" --dry-run
assert_not_contains "no download" "$OUT" "pveam download"

echo "# no Debian 13 template"
STUB_NO_DEB13=1 run_flow "$(default_answers)" --dry-run
assert_eq "missing template exits 1" 1 "$STATUS"
assert_contains "missing template message" "$OUT" "Debian 13 template not found"
assert_not_contains "missing template creates nothing" "$OUT" "pct create"

echo "# old Proxmox VE"
STUB_PVEVERSION="pve-manager/8.3.5/abc (running kernel: 6.8)" run_flow "" --dry-run
assert_eq "pve 8.3 exits 1" 1 "$STATUS"
assert_contains "pve version message" "$OUT" "Proxmox VE 8.4 or newer"
STUB_PVEVERSION="pve-manager/8.4.1/abc (running kernel: 6.8)" run_flow "$(default_answers)" --dry-run
assert_eq "pve 8.4 accepted" 0 "$STATUS"

echo "# non-amd64 host"
STUB_ARCH=arm64 run_flow "" --dry-run
assert_eq "arm64 exits 1" 1 "$STATUS"
assert_contains "arch message" "$OUT" "only for amd64"

echo "# no rootdir storage"
STUB_STORAGES_rootdir="" run_flow "$(default_answers)" --dry-run
assert_eq "no storage exits 1" 1 "$STATUS"
assert_contains "no storage message" "$OUT" "No active storage supports 'rootdir'"

echo "# no bridge"
STUB_BRIDGES="" run_flow "$(default_answers | sed -n '1,8p')" --dry-run
assert_contains "no bridge message" "$OUT" "No vmbr* bridge found"

echo "# unknown option"
run_flow "" --bogus
assert_eq "unknown option exits 1" 1 "$STATUS"

echo "# dry run does not persist the tun module"
rm -f /etc/modules-load.d/tun.conf
run_flow "$(default_answers)" --dry-run
assert_contains "dry run shows tun persistence" "$OUT" "[dry-run] tee /etc/modules-load.d/tun.conf"
assert_fails "dry run writes nothing" test -e /etc/modules-load.d/tun.conf

echo "# real run persists the tun module once"
run_flow "$(default_answers)"
assert_eq "tun.conf content" "tun" "$(cat /etc/modules-load.d/tun.conf 2>/dev/null)"
run_flow "$(default_answers)"
assert_contains "tun already configured" "$OUT" "tun module already loaded at boot"
rm -f /etc/modules-load.d/tun.conf
printf 'loop\ntun\n' >/etc/modules
run_flow "$(default_answers)"
assert_fails "tun in /etc/modules is respected" test -e /etc/modules-load.d/tun.conf
: >/etc/modules

echo "# real run: success, secrets are pushed intact and not logged"
run_flow "$(default_answers)"
assert_eq "real run exits 0" 0 "$STATUS"
assert_contains "order: create" "$CALLS" "pct create 105"
assert_contains "tun set" "$CALLS" "pct set 105 --dev0 /dev/net/tun"
assert_contains "env pushed 0600" "$CALLS" "/root/ovpn-install.env --perms 0600"
assert_contains "installer executed" "$CALLS" "pct exec 105 -- bash /root/ovpn-install.sh"
order=$(grep -nE '^pct (create|set|start|exec 105 -- bash)' <<<"$CALLS" | cut -d' ' -f2 | tr '\n' ' ')
assert_eq "pct call order" "create set start exec " "$order"
(
  source "$PUSHED/ovpn-install.env"
  [[ $CT_PASSWORD == "$CT_PASS" && $ADMIN_PASSWORD == "$ADMIN_PASS" && $TCP_PORT == 443 ]]
) && pass || fail "env file round-trips special characters"
assert_eq "env file mode" 600 "$(stat -c %a "$PUSHED/ovpn-install.env")"
assert_not_contains "log has no ct password" "$LOGS" "$CT_PASS"
assert_not_contains "log has no admin password" "$LOGS" "$ADMIN_PASS"
assert_not_contains "no destroy on success" "$CALLS" "destroy"

echo "# real run: failure after create offers to destroy"
STUB_PCT_FAIL=start run_flow "$(default_answers; echo yes)"
assert_eq "failed run exits non-zero" 1 "$STATUS"
assert_contains "destroy asked" "$CALLS" "whiptail yesno The installation failed."
assert_contains "container destroyed" "$CALLS" "pct destroy 105 --purge"

echo "# real run: failure, user keeps the container"
STUB_PCT_FAIL=start run_flow "$(default_answers; echo no)"
assert_not_contains "container kept" "$CALLS" "pct destroy"
assert_contains "kept message" "$OUT" "kept for inspection"

echo "# real run: network never comes up"
STUB_PCT_FAIL=exec run_flow "$(default_answers; echo no)"
assert_contains "network error message" "$OUT" "cannot resolve packages.openvpn.net"

finish
