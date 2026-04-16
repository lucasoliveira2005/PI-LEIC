#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

append_good_metrics() {
  local path="$1"

  cat >> "$path" <<'JSONL'
{"source_id":"gnb1","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x101","dl_brate":1200.0,"ul_brate":800.0}]}]}}
{"source_id":"gnb2","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x201","dl_brate":1400.0,"ul_brate":900.0}]}]}}
JSONL
}

append_bad_metrics() {
  local path="$1"

  cat >> "$path" <<'JSONL'
{"source_id":"gnb1","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x301","dl_brate":1100.0,"ul_brate":700.0}]}]}}
{"source_id":"gnb2","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x401","dl_brate":1500.0,"ul_brate":0.0}]}]}}
JSONL
}

append_steady_metrics() {
  local path="$1"

  cat >> "$path" <<'JSONL'
{"source_id":"gnb1","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x501","dl_brate":900.0,"ul_brate":450.0}]}]}}
{"source_id":"gnb2","raw_payload":{"cells":[{"ue_list":[{"rnti":"0x601","dl_brate":950.0,"ul_brate":470.0}]}]}}
JSONL
}

create_stub_commands() {
  local stub_dir="$1"

  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
  shift
fi

if [[ "${1:-}" == "-v" ]]; then
  exit 0
fi

exec "$@"
EOF

  cat > "$stub_dir/ip" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$stub_dir/iperf3" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$stub_dir/sudo" "$stub_dir/ip" "$stub_dir/iperf3"
}

run_success_case() {
  local sources_file="$1"
  local stub_dir="$2"
  local metrics_file="$3"
  local output_file="$4"
  local error_file="$5"

  : > "$metrics_file"
  (
    sleep 1
    append_good_metrics "$metrics_file"
  ) &
  local writer_pid=$!

  if ! env \
    PATH="$stub_dir:$PATH" \
    METRICS_OUT="$metrics_file" \
    METRICS_SOURCES_CONFIG="$sources_file" \
    TRAFFIC_SETTLE_SECONDS=2 \
    bash "$REPO_ROOT/src/validate_stage.sh" --skip-provision --skip-launch --skip-traffic > "$output_file" 2> "$error_file"; then
    wait "$writer_pid" || true
    echo "Expected validate_stage success case to pass" >&2
    cat "$error_file" >&2 || true
    exit 1
  fi

  wait "$writer_pid"
}

run_failure_case() {
  local sources_file="$1"
  local stub_dir="$2"
  local metrics_file="$3"
  local output_file="$4"
  local error_file="$5"

  : > "$metrics_file"
  (
    sleep 1
    append_bad_metrics "$metrics_file"
  ) &
  local writer_pid=$!

  if env \
    PATH="$stub_dir:$PATH" \
    METRICS_OUT="$metrics_file" \
    METRICS_SOURCES_CONFIG="$sources_file" \
    TRAFFIC_SETTLE_SECONDS=2 \
    bash "$REPO_ROOT/src/validate_stage.sh" --skip-provision --skip-launch --skip-traffic > "$output_file" 2> "$error_file"; then
    wait "$writer_pid" || true
    echo "Expected validate_stage failure case to fail" >&2
    exit 1
  fi

  wait "$writer_pid"

  if ! grep -q "Missing fresh non-zero ul_brate" "$error_file"; then
    echo "Failure case did not report missing UL throughput" >&2
    cat "$error_file" >&2 || true
    exit 1
  fi
}

run_hybrid_sequence_case() {
  local sources_file="$1"
  local stub_dir="$2"
  local metrics_file="$3"
  local output_file="$4"
  local error_file="$5"

  : > "$metrics_file"
  append_steady_metrics "$metrics_file"

  (
    sleep 1
    append_steady_metrics "$metrics_file"
  ) &
  local writer_pid=$!

  if ! env \
    PATH="$stub_dir:$PATH" \
    METRICS_OUT="$metrics_file" \
    METRICS_SOURCES_CONFIG="$sources_file" \
    FRESHNESS_CHECK_MODE=hybrid \
    TRAFFIC_SETTLE_SECONDS=2 \
    bash "$REPO_ROOT/src/validate_stage.sh" --skip-provision --skip-launch --skip-traffic > "$output_file" 2> "$error_file"; then
    wait "$writer_pid" || true
    echo "Expected validate_stage hybrid sequence case to pass" >&2
    cat "$error_file" >&2 || true
    exit 1
  fi

  wait "$writer_pid"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

sources_file="$tmp_dir/metrics_sources.json"
cat > "$sources_file" <<'JSON'
[
  {
    "source_id": "gnb1",
    "ws_url": "ws://127.0.0.1:6001"
  },
  {
    "source_id": "gnb2",
    "ws_url": "ws://127.0.0.1:6002"
  }
]
JSON

stub_dir="$tmp_dir/stubs"
mkdir -p "$stub_dir"
create_stub_commands "$stub_dir"

run_success_case \
  "$sources_file" \
  "$stub_dir" \
  "$tmp_dir/metrics_success.jsonl" \
  "$tmp_dir/success.out" \
  "$tmp_dir/success.err"

run_failure_case \
  "$sources_file" \
  "$stub_dir" \
  "$tmp_dir/metrics_failure.jsonl" \
  "$tmp_dir/failure.out" \
  "$tmp_dir/failure.err"

run_hybrid_sequence_case \
  "$sources_file" \
  "$stub_dir" \
  "$tmp_dir/metrics_hybrid.jsonl" \
  "$tmp_dir/hybrid.out" \
  "$tmp_dir/hybrid.err"

echo "validate_stage rootless shell tests passed"
