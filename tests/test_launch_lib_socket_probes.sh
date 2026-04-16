#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/socket_probes.sh
source "$REPO_ROOT/src/launch_lib/socket_probes.sh"

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

CORE_PROBE_SMF_PFCP_PORT=8805
CORE_PROBE_UPF_PFCP_PORT=8805
CORE_PROBE_UPF_GTPU_PORT=2152
CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS=1

snapshot_good="$(cat <<'EOF'
tcp LISTEN 0 128 127.0.0.1:38412 0.0.0.0:* users:((\"open5gs-amfd\",pid=1,fd=3))
tcp LISTEN 0 128 127.0.0.1:7777 0.0.0.0:* users:((\"open5gs-smfd\",pid=2,fd=3))
udp UNCONN 0 0 127.0.0.1:8805 0.0.0.0:* users:((\"open5gs-smfd\",pid=2,fd=4))
udp UNCONN 0 0 127.0.0.1:8805 0.0.0.0:* users:((\"open5gs-upfd\",pid=3,fd=5))
udp UNCONN 0 0 127.0.0.1:2152 0.0.0.0:* users:((\"open5gs-upfd\",pid=3,fd=6))
EOF
)"

if ! socket_probes_snapshot_has_process_tcp_listener "$snapshot_good" "open5gs-amfd"; then
  echo "Expected amfd tcp listener detection" >&2
  exit 1
fi

endpoint="$(socket_probes_first_tcp_listener_endpoint_for_process "$snapshot_good" "open5gs-amfd")"
assert_eq "127.0.0.1:38412" "$endpoint" "first endpoint extraction"

failures=()
if socket_probes_collect_core_socket_probe_failures "$snapshot_good" failures; then
  echo "Did not expect failures for valid socket snapshot" >&2
  exit 1
fi

snapshot_bad="$(cat <<'EOF'
tcp LISTEN 0 128 127.0.0.1:38412 0.0.0.0:* users:((\"open5gs-amfd\",pid=1,fd=3))
EOF
)"

if ! socket_probes_collect_core_socket_probe_failures "$snapshot_bad" failures; then
  echo "Expected failures for incomplete socket snapshot" >&2
  exit 1
fi

joined_failures="${failures[*]}"
if [[ "$joined_failures" != *"open5gs-smfd missing tcp listener"* ]]; then
  echo "Expected smfd listener failure in output" >&2
  exit 1
fi

endpoint_failures=()
if ! socket_probes_collect_core_endpoint_probe_failures "$snapshot_bad" endpoint_failures; then
  echo "Expected endpoint probe failures for missing endpoints" >&2
  exit 1
fi

joined_endpoint_failures="${endpoint_failures[*]}"
if [[ "$joined_endpoint_failures" != *"open5gs-smfd missing active endpoint"* ]]; then
  echo "Expected missing endpoint failure" >&2
  exit 1
fi

echo "launch_lib/socket_probes.sh tests passed"
