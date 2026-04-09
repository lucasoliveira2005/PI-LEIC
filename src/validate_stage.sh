#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
METRICS_OUT="${METRICS_OUT:-$REPO_ROOT/metrics/gnb_metrics.jsonl}"
METRICS_SOURCES_CONFIG="${METRICS_SOURCES_CONFIG:-$REPO_ROOT/config/metrics_sources.json}"
PING_TARGET="${PING_TARGET:-10.45.0.1}"
PING_COUNT="${PING_COUNT:-4}"
PING_WAIT_SECONDS="${PING_WAIT_SECONDS:-3}"
UE_NAMESPACES_RAW="${UE_NAMESPACES:-ue1:ue2}"
LAUNCH_HEALTHCHECK_ENABLED="${LAUNCH_HEALTHCHECK_ENABLED:-0}"

SKIP_PROVISION=0
SKIP_LAUNCH=0
SKIP_PING=0

usage() {
  cat <<EOF
Usage: bash src/validate_stage.sh [--skip-provision] [--skip-launch] [--skip-ping]

This validation run:
  1. applies subscriber provisioning
  2. launches the multi-gNB stack
  3. sends traffic from each UE namespace to ${PING_TARGET}
  4. confirms fresh metrics from every configured source
  5. confirms fresh non-zero dl_brate and ul_brate for every configured source

Options:
  --skip-provision  Reuse existing subscribers.
  --skip-launch     Reuse an already running stack.
  --skip-ping       Skip the traffic generation step.
  --help            Show this message.

Environment overrides:
  PYTHON_BIN, METRICS_OUT, METRICS_SOURCES_CONFIG, PING_TARGET, PING_COUNT
  PING_WAIT_SECONDS, UE_NAMESPACES, LAUNCH_HEALTHCHECK_ENABLED

Notes:
  UE_NAMESPACES uses colon-separated names, for example: ue1:ue2
  The launcher smoke check is disabled by default here because this script performs
  the stricter validation after traffic generation.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-provision)
      SKIP_PROVISION=1
      shift
      ;;
    --skip-launch)
      SKIP_LAUNCH=1
      shift
      ;;
    --skip-ping)
      SKIP_PING=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_file() {
  local label="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    echo "$label not found: $path" >&2
    exit 1
  fi
}

metrics_line_count() {
  if [[ -f "$METRICS_OUT" ]]; then
    wc -l < "$METRICS_OUT"
  else
    echo 0
  fi
}

load_required_sources() {
  "$PYTHON_BIN" - "$METRICS_SOURCES_CONFIG" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

for item in data:
    print(item["source_id"])
PY
}

validate_metrics() {
  local start_line="$1"
  shift

  "$PYTHON_BIN" - "$METRICS_OUT" "$start_line" "$@" <<'PY'
import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
start_line = int(sys.argv[2])
required_sources = sys.argv[3:]

if not metrics_path.exists():
    raise SystemExit(f"Metrics file not found: {metrics_path}")

seen_sources = set()
positive = {
    source_id: {"dl": False, "ul": False}
    for source_id in required_sources
}

with metrics_path.open(encoding="utf-8") as handle:
    for line_number, line in enumerate(handle, start=1):
        if line_number <= start_line:
            continue

        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue

        source_id = event.get("source_id")
        if source_id not in positive:
            continue

        seen_sources.add(source_id)

        payload = event.get("raw_payload") or event
        cells = payload.get("cells") or []
        if not cells:
            continue

        ue_list = cells[0].get("ue_list") or []
        if not ue_list:
            continue

        ue = ue_list[0]
        if float(ue.get("dl_brate", 0) or 0) > 0:
            positive[source_id]["dl"] = True
        if float(ue.get("ul_brate", 0) or 0) > 0:
            positive[source_id]["ul"] = True

missing_sources = [source_id for source_id in required_sources if source_id not in seen_sources]
missing_dl = [source_id for source_id in required_sources if not positive[source_id]["dl"]]
missing_ul = [source_id for source_id in required_sources if not positive[source_id]["ul"]]

if missing_sources or missing_dl or missing_ul:
    if missing_sources:
        print("Missing fresh metrics from: " + ", ".join(missing_sources), file=sys.stderr)
    if missing_dl:
        print("Missing fresh non-zero dl_brate from: " + ", ".join(missing_dl), file=sys.stderr)
    if missing_ul:
        print("Missing fresh non-zero ul_brate from: " + ", ".join(missing_ul), file=sys.stderr)
    raise SystemExit(1)

print("Fresh metrics seen from: " + ", ".join(required_sources))
print("Fresh non-zero dl_brate and ul_brate confirmed for: " + ", ".join(required_sources))
PY
}

require_command "$PYTHON_BIN"
require_command sudo
require_command ip
require_file "Metrics sources config" "$METRICS_SOURCES_CONFIG"

cd "$REPO_ROOT"

IFS=':' read -r -a UE_NAMESPACES <<< "$UE_NAMESPACES_RAW"
mapfile -t REQUIRED_SOURCES < <(load_required_sources)

if [[ ${#REQUIRED_SOURCES[@]} -eq 0 ]]; then
  echo "No source_id values found in: $METRICS_SOURCES_CONFIG" >&2
  exit 1
fi

START_LINE="$(metrics_line_count)"

echo "Validation baseline: metrics file line ${START_LINE}"
echo "Required sources: $(IFS=', '; echo "${REQUIRED_SOURCES[*]}")"
echo "UE namespaces: $(IFS=', '; echo "${UE_NAMESPACES[*]}")"

if [[ "$SKIP_PROVISION" != "1" ]]; then
  echo "Applying subscriber provisioning..."
  "$PYTHON_BIN" src/provision_subscribers.py --apply
fi

if [[ "$SKIP_LAUNCH" != "1" ]]; then
  echo "Launching the full multi-gNB stage..."
  HEALTHCHECK_ENABLED="$LAUNCH_HEALTHCHECK_ENABLED" bash src/launch_stack.sh
fi

if [[ "$SKIP_PING" != "1" ]]; then
  for netns_name in "${UE_NAMESPACES[@]}"; do
    echo "Sending traffic from ${netns_name} to ${PING_TARGET}..."
    sudo ip netns exec "$netns_name" ping -c "$PING_COUNT" "$PING_TARGET"
  done
fi

echo "Waiting ${PING_WAIT_SECONDS}s for fresh traffic metrics..."
sleep "$PING_WAIT_SECONDS"

echo "Validating fresh metrics..."
validate_metrics "$START_LINE" "${REQUIRED_SOURCES[@]}"

echo "Validation run passed."
