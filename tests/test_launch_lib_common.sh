#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/common.sh
source "$REPO_ROOT/src/launch_lib/common.sh"

UNIT_PREFIX="pi-leic-stage"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cat > "$tmp_dir/ue_test.conf.txt" <<'EOF'
netns = ue-test
ip_devname = tun-test
EOF

assert_eq "$tmp_dir/metrics.jsonl" "$(resolve_path "$tmp_dir" "metrics.jsonl")" "resolve_path with relative path"
assert_eq "/tmp/custom.jsonl" "$(resolve_path "$tmp_dir" "/tmp/custom.jsonl")" "resolve_path with absolute path"

resolved_configs=()
resolve_config_list "$tmp_dir" "gnb1.yaml:/abs/gnb2.yaml" resolved_configs
assert_eq "$tmp_dir/gnb1.yaml" "${resolved_configs[0]}" "resolve_config_list first element"
assert_eq "/abs/gnb2.yaml" "${resolved_configs[1]}" "resolve_config_list second element"

assert_eq "ue-test" "$(read_netns "$tmp_dir/ue_test.conf.txt")" "read_netns"
assert_eq "tun-test" "$(read_ip_devname "$tmp_dir/ue_test.conf.txt")" "read_ip_devname"

assert_eq "gnb1" "$(config_label "gnb_gnb1_zmq.yaml")" "config_label for gNB"
assert_eq "ue1" "$(config_label "ue1_zmq.conf.txt")" "config_label for UE"

assert_eq "alpha,beta,gamma" "$(join_by "," alpha beta gamma)" "join_by"
assert_eq "" "$(join_by ",")" "join_by with empty list"

assert_eq "${UNIT_PREFIX}-gnb1.service" "$(root_unit_name "gnb1")" "root_unit_name"
assert_eq "${UNIT_PREFIX}-collector.service" "$(user_unit_name "collector")" "user_unit_name"

echo "launch_lib/common.sh tests passed"
