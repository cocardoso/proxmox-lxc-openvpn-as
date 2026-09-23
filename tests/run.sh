#!/usr/bin/env bash
# Runs every tests/test_*.sh inside a Debian 13 container (bash 5, like PVE).
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${IN_TEST_CONTAINER:-}" != 1 ]]; then
  exec docker run --rm --device /dev/net/tun -e IN_TEST_CONTAINER=1 -v "$PWD":/w -w /w debian:trixie bash tests/run.sh "$@"
fi

status=0
for t in tests/test_*.sh; do
  bash "$t" || status=1
done
exit $status
