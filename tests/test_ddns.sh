#!/usr/bin/env bash
# Tests for the Cloudflare dynamic DNS updater installed in the container.
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

export PATH="$PWD/tests/stubs:$PATH"
TOKEN='cf-Token_with$pecial"chars'
UPDATER=$(mktemp)
bash -c 'source ./openvpn-as-lxc.sh; ddns_updater' >"$UPDATER"

# run_updater -> sets OUT, STATUS, CALLS, RECORD, WRITES
run_updater() {
  local conf
  conf=$(mktemp)
  printf 'DDNS_ZONE=%q\nDDNS_RECORD=%q\nDDNS_TOKEN=%q\n' example.com vpn.example.com "$TOKEN" >"$conf"
  : >"$STUB_LOG"
  OUT=$(OPENVPN_AS_DDNS_CONF="$conf" bash "$UPDATER" 2>&1)
  STATUS=$?
  CALLS=$(cat "$STUB_LOG")
  RECORD=$(cat "$STUB_CF_DIR/record" 2>/dev/null)
  WRITES=$(cat "$STUB_CF_DIR/writes" 2>/dev/null)
  rm -f "$conf"
}

reset_state() {
  STUB_CF_DIR=$(mktemp -d)
  export STUB_CF_DIR STUB_LOG="$STUB_CF_DIR/calls"
  export STUB_CF_TOKEN=$TOKEN STUB_CF_ZONE=example.com STUB_PUBLIC_IP=203.0.113.7
  unset STUB_IPIFY_FAIL
}

echo "# creates the record when missing"
reset_state
run_updater
assert_eq "create exits 0" 0 "$STATUS"
assert_eq "record created DNS only" "vpn.example.com 203.0.113.7 false" "$RECORD"
assert_eq "one POST" "POST" "$WRITES"
assert_contains "create message" "$OUT" "Created vpn.example.com -> 203.0.113.7"

echo "# updates when the IP changed"
reset_state
echo "vpn.example.com 198.51.100.1 false" >"$STUB_CF_DIR/record"
run_updater
assert_eq "update exits 0" 0 "$STATUS"
assert_eq "record updated" "vpn.example.com 203.0.113.7 false" "$RECORD"
assert_eq "one PATCH" "PATCH" "$WRITES"

echo "# does nothing when the IP is the same"
reset_state
echo "vpn.example.com 203.0.113.7 false" >"$STUB_CF_DIR/record"
run_updater
assert_eq "unchanged exits 0" 0 "$STATUS"
assert_eq "no writes" "" "$WRITES"
assert_contains "unchanged message" "$OUT" "already points to 203.0.113.7"

echo "# turns off the Cloudflare proxy (orange cloud) on the record"
reset_state
echo "vpn.example.com 203.0.113.7 true" >"$STUB_CF_DIR/record"
run_updater
assert_eq "proxied fixed" "vpn.example.com 203.0.113.7 false" "$RECORD"

echo "# falls back to 1.1.1.1/cdn-cgi/trace"
reset_state
export STUB_IPIFY_FAIL=1
run_updater
assert_eq "fallback exits 0" 0 "$STATUS"
assert_eq "fallback ip used" "vpn.example.com 203.0.113.7 false" "$RECORD"

echo "# rejected token"
reset_state
export STUB_CF_TOKEN=other-token
run_updater
assert_eq "bad token exits 1" 1 "$STATUS"
assert_contains "api error shown" "$OUT" "Authentication error"
assert_eq "bad token writes nothing" "" "$WRITES"

echo "# zone not visible to the token"
reset_state
export STUB_CF_ZONE=other.com
run_updater
assert_eq "missing zone exits 1" 1 "$STATUS"
assert_contains "missing zone message" "$OUT" "Zone example.com not found"

echo "# refuses to touch a name that has a CNAME"
reset_state
echo "vpn.example.com target.example.net false CNAME" >"$STUB_CF_DIR/record"
run_updater
assert_eq "cname exits 1" 1 "$STATUS"
assert_contains "cname message" "$OUT" "has CNAME/AAAA or several A records"
assert_eq "cname writes nothing" "" "$WRITES"

echo "# refuses several A records"
reset_state
printf 'vpn.example.com 198.51.100.1 false\nvpn.example.com 198.51.100.2 false\n' >"$STUB_CF_DIR/record"
run_updater
assert_eq "several A exits 1" 1 "$STATUS"
assert_eq "several A writes nothing" "" "$WRITES"

echo "# ignores records of other types (TXT) on the same name"
reset_state
printf 'vpn.example.com 198.51.100.1 false\nvpn.example.com v=spf1 false TXT\n' >"$STUB_CF_DIR/record"
run_updater
assert_eq "txt alongside exits 0" 0 "$STATUS"
assert_eq "txt alongside updates A" "PATCH" "$WRITES"

echo "# rejects an invalid public IP"
reset_state
export STUB_PUBLIC_IP=999.1.1.1
run_updater
assert_eq "invalid ip exits 1" 1 "$STATUS"
assert_contains "invalid ip message" "$OUT" "Could not detect the public IPv4"

echo "# token never on the command line"
reset_state
run_updater
assert_not_contains "token not in curl argv" "$CALLS" "$TOKEN"
assert_not_contains "token not in output" "$OUT" "$TOKEN"

rm -f "$UPDATER"
finish
