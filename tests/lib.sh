#!/usr/bin/env bash
# Minimal assertion helpers shared by the test files.

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); }
fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  echo "  FAIL: $*" >&2
}

assert_ok() {
  local desc=$1; shift
  if "$@"; then pass; else fail "$desc (expected success: $*)"; fi
}

assert_fails() {
  local desc=$1; shift
  if "$@"; then fail "$desc (expected failure: $*)"; else pass; fi
}

assert_eq() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then pass; else fail "$desc: expected [$expected] got [$actual]"; fi
}

assert_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then pass; else fail "$desc: missing [$needle]"; fi
}

assert_not_contains() {
  local desc=$1 haystack=$2 needle=$3
  if [[ "$haystack" != *"$needle"* ]]; then pass; else fail "$desc: unexpected [$needle]"; fi
}

finish() {
  echo "$(basename "$0"): $TESTS_RUN checks, $TESTS_FAILED failed"
  [[ $TESTS_FAILED -eq 0 ]]
}
