#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/metrics_contract.sh
source "$REPO_ROOT/src/launch_lib/metrics_contract.sh"

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

metrics_file="$tmp_dir/metrics.jsonl"
cat > "$metrics_file" <<'JSONL'
{"source_id":"gnb1","timestamp":"t0","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x101","dl_brate":1000.0,"ul_brate":500.0}]}]}}
JSONL

PYTHON_BIN_RESOLVED="$(command -v python3)"
REPO_ROOT_PATH="$REPO_ROOT"
METRICS_OUT_PATH="$metrics_file"
METRICS_LOG_INCLUDE_ROTATED=0
METRICS_LOG_MAX_ARCHIVES=5
METRICS_SQLITE_ENABLED=0
METRICS_SQLITE_PATH="$tmp_dir/metrics.sqlite"

baseline_file="$tmp_dir/baseline.json"
metrics_contract_write_baseline_signatures "$baseline_file" gnb1

first_state="$(metrics_contract_collect_health_states "$baseline_file" gnb1 | head -n 1)"
assert_eq $'gnb1\t1\t1\t0' "$first_state" "state is not fresh immediately after baseline"

cat >> "$metrics_file" <<'JSONL'
{"source_id":"gnb1","timestamp":"t1","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x101","dl_brate":2000.0,"ul_brate":900.0}]}]}}
JSONL

second_state="$(metrics_contract_collect_health_states "$baseline_file" gnb1 | head -n 1)"
assert_eq $'gnb1\t1\t1\t1' "$second_state" "state becomes fresh after new metrics"

echo "launch_lib/metrics_contract.sh tests passed"
