#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/health_classification.sh
source "$REPO_ROOT/src/launch_lib/health_classification.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "Assertion failed: ${message}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"

  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Assertion failed: ${message}" >&2
    echo "  expected to contain: ${needle}" >&2
    echo "  output: ${haystack}" >&2
    exit 1
  fi
}

assert_eq "core-discovery" "$(classify_attach_failure_line "SMF cannot discover [NSSF]")" "core discovery classification"
assert_eq "registration-reject" "$(classify_attach_failure_line "Registration reject from network")" "registration reject classification"
assert_eq "pdu-session" "$(classify_attach_failure_line "PDU session establishment failed")" "pdu session classification"
assert_eq "rrc-release" "$(classify_attach_failure_line "RRC release observed")" "rrc release classification"
assert_eq "unknown" "$(classify_attach_failure_line "Some unrelated warning")" "unknown classification"

failures=(
  "[core-discovery] cannot discover"
  "[pdu-session] pdu rejected"
  "[pdu-session] pdu released"
  "line without category"
)
summary_output="$(print_attach_failure_summary failures)"

assert_contains "$summary_output" "core-discovery: 1" "summary includes core-discovery count"
assert_contains "$summary_output" "pdu-session: 2" "summary includes pdu-session count"
assert_contains "$summary_output" "unknown: 1" "summary includes unknown count"

echo "launch_lib/health_classification.sh tests passed"
