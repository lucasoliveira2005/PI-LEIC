#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

PYTHON_BIN="${PYTHON_BIN:-python3}"
METRICS_OUT="${METRICS_OUT:-$REPO_ROOT/metrics/gnb_metrics.jsonl}"
METRICS_SOURCES_CONFIG="${METRICS_SOURCES_CONFIG:-$REPO_ROOT/config/metrics_sources.json}"
METRICS_LOG_INCLUDE_ROTATED="${METRICS_LOG_INCLUDE_ROTATED:-1}"
METRICS_LOG_MAX_ARCHIVES="${METRICS_LOG_MAX_ARCHIVES:-5}"
METRICS_SQLITE_ENABLED="${METRICS_SQLITE_ENABLED:-1}"
METRICS_SQLITE_PATH="${METRICS_SQLITE_PATH:-/tmp/pi-leic-metrics.sqlite}"
FRESHNESS_CHECK_MODE="${FRESHNESS_CHECK_MODE:-hybrid}"
FRESHNESS_AGE_WINDOW_SECONDS="${FRESHNESS_AGE_WINDOW_SECONDS:-15}"
FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS="${FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS:-2}"
# Persist the validator freshness baseline under var/ so a crash between
# "baseline captured" and "validate_metrics" does not force a full rerun.
# Override with FRESHNESS_BASELINE_PATH for custom locations (CI, ephemeral runs).
FRESHNESS_BASELINE_PATH="${FRESHNESS_BASELINE_PATH:-$REPO_ROOT/var/freshness_baseline.json}"
TRAFFIC_TARGET="${TRAFFIC_TARGET:-10.45.0.1}"
IPERF_DURATION_SECONDS="${IPERF_DURATION_SECONDS:-5}"
IPERF_PORT="${IPERF_PORT:-5201}"
IPERF_SERVER_MANAGE="${IPERF_SERVER_MANAGE:-1}"
TRAFFIC_SETTLE_SECONDS="${TRAFFIC_SETTLE_SECONDS:-3}"
NET_READY_TIMEOUT_SECONDS="${NET_READY_TIMEOUT_SECONDS:-60}"
NET_READY_POLL_SECONDS="${NET_READY_POLL_SECONDS:-1}"
UE_NAMESPACES_RAW="${UE_NAMESPACES:-ue1:ue2}"
LAUNCH_MODE="${LAUNCH_MODE:-supervised}"
LAUNCH_DASHBOARD_ENABLED="${LAUNCH_DASHBOARD_ENABLED:-0}"
LAUNCH_HEALTHCHECK_ENABLED="${LAUNCH_HEALTHCHECK_ENABLED:-1}"
LAUNCH_HEALTHCHECK_STRICT="${LAUNCH_HEALTHCHECK_STRICT:-1}"
LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH="${LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH:-0}"
LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="${LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS:-1}"
LAUNCH_HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES="${LAUNCH_HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES:-core-discovery}"
LAUNCH_CORE_READINESS_TIMEOUT_SECONDS="${LAUNCH_CORE_READINESS_TIMEOUT_SECONDS:-45}"
LAUNCH_CORE_READINESS_POLL_SECONDS="${LAUNCH_CORE_READINESS_POLL_SECONDS:-1}"
LAUNCH_CORE_READINESS_STABLE_POLLS="${LAUNCH_CORE_READINESS_STABLE_POLLS:-3}"
LAUNCH_CORE_READINESS_REQUIRE_LOG_MARKERS="${LAUNCH_CORE_READINESS_REQUIRE_LOG_MARKERS:-1}"
LAUNCH_CORE_READINESS_REQUIRE_SOCKET_PROBES="${LAUNCH_CORE_READINESS_REQUIRE_SOCKET_PROBES:-1}"
LAUNCH_CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES="${LAUNCH_CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES:-1}"
LAUNCH_CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS="${LAUNCH_CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS:-1}"
LAUNCH_CORE_PROBE_SMF_PFCP_PORT="${LAUNCH_CORE_PROBE_SMF_PFCP_PORT:-8805}"
LAUNCH_CORE_PROBE_UPF_PFCP_PORT="${LAUNCH_CORE_PROBE_UPF_PFCP_PORT:-8805}"
LAUNCH_CORE_PROBE_UPF_GTPU_PORT="${LAUNCH_CORE_PROBE_UPF_GTPU_PORT:-2152}"
LAUNCH_CORE_STABILIZATION_SECONDS="${LAUNCH_CORE_STABILIZATION_SECONDS:-0}"
VALIDATE_ALLOW_ROOT="${VALIDATE_ALLOW_ROOT:-0}"

SKIP_PROVISION=0
SKIP_LAUNCH=0
SKIP_TRAFFIC=0

usage() {
  cat <<EOF
Usage: bash src/validate_stage.sh [--skip-provision] [--skip-launch] [--skip-traffic]

This validation run:
  1. applies subscriber provisioning
  2. launches the multi-gNB stack
  3. runs iperf3 from each UE namespace to ${TRAFFIC_TARGET}
  4. confirms fresh metrics from every configured source
  5. confirms fresh non-zero dl_brate and ul_brate for all observed UE entities
     in every configured source

Options:
  --skip-provision  Reuse existing subscribers.
  --skip-launch     Reuse an already running stack.
  --skip-traffic    Skip the traffic generation step.
  --help            Show this message.

Environment overrides:
  PYTHON_BIN, METRICS_OUT, METRICS_SOURCES_CONFIG, TRAFFIC_TARGET
  IPERF_DURATION_SECONDS, IPERF_PORT, IPERF_SERVER_MANAGE
  METRICS_LOG_INCLUDE_ROTATED, METRICS_LOG_MAX_ARCHIVES
  METRICS_SQLITE_ENABLED, METRICS_SQLITE_PATH
  FRESHNESS_CHECK_MODE, FRESHNESS_AGE_WINDOW_SECONDS
  FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS, FRESHNESS_BASELINE_PATH
  TRAFFIC_SETTLE_SECONDS, NET_READY_TIMEOUT_SECONDS, NET_READY_POLL_SECONDS
  UE_NAMESPACES, LAUNCH_MODE, LAUNCH_DASHBOARD_ENABLED
  LAUNCH_HEALTHCHECK_ENABLED, LAUNCH_HEALTHCHECK_STRICT
  LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH
  LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS
  LAUNCH_HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES
  LAUNCH_CORE_READINESS_TIMEOUT_SECONDS
  LAUNCH_CORE_READINESS_POLL_SECONDS
  LAUNCH_CORE_READINESS_STABLE_POLLS
  LAUNCH_CORE_READINESS_REQUIRE_LOG_MARKERS
  LAUNCH_CORE_READINESS_REQUIRE_SOCKET_PROBES
  LAUNCH_CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES
  LAUNCH_CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS
  LAUNCH_CORE_PROBE_SMF_PFCP_PORT
  LAUNCH_CORE_PROBE_UPF_PFCP_PORT
  LAUNCH_CORE_PROBE_UPF_GTPU_PORT
  LAUNCH_CORE_STABILIZATION_SECONDS

Notes:
  UE_NAMESPACES uses colon-separated names, for example: ue1:ue2
  The launcher runs in supervised mode by default here.
  The dashboard is disabled by default here because validation does not depend on it.
  The launch readiness checks are enabled by default here so traffic starts only
  after the supervised stack has had a chance to attach and publish fresh metrics.
  Those launch readiness checks run in strict mode here for service/metrics health.
  Launch readiness also fails fast by default when explicit attach/PDU failure
  signals are detected in UE/core logs.
  Core readiness now waits dynamically for stable active units and startup log
  markers plus live socket and active endpoint probes instead of relying on a fixed sleep.
  UE data-path checks are deferred to this script's route wait and ping steps.
  An extra fixed settle delay is still available via LAUNCH_CORE_STABILIZATION_SECONDS
  but defaults to 0.
  When IPERF_SERVER_MANAGE=1 (default) this script starts one iperf3 server per UE
  on consecutive ports (IPERF_PORT, IPERF_PORT+1, ...) so all UE clients can run
  simultaneously.  Set IPERF_SERVER_MANAGE=0 when servers are already running on
  TRAFFIC_TARGET.  Before running iperf3, this script waits for a routable path inside
  each UE namespace.
  This script still performs the stricter validation after traffic generation.
  Freshness policy can be tuned with FRESHNESS_CHECK_MODE
  (signature|sequence|age|hybrid), FRESHNESS_AGE_WINDOW_SECONDS, and
  FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS.
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
    --skip-traffic)
      SKIP_TRAFFIC=1
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

if [[ "${EUID:-$(id -u)}" -eq 0 && "$VALIDATE_ALLOW_ROOT" != "1" ]]; then
  cat >&2 <<'EOF'
validate_stage.sh should be run as your regular user, not via sudo/root.

Use:
  bash src/validate_stage.sh

The validation flow requests sudo only for privileged operations and relies on
systemd user services for collector/dashboard orchestration.
If you really need root mode, set VALIDATE_ALLOW_ROOT=1 explicitly.
EOF
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_sudo_session() {
  if sudo -n true >/dev/null 2>&1; then
    return 0
  fi

  echo "Requesting sudo credentials for validation..."
  sudo -v
}

require_file() {
  local label="$1"
  local path="$2"

  if [[ ! -f "$path" ]]; then
    echo "$label not found: $path" >&2
    exit 1
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

write_baseline_signatures() {
  local output_file="$1"
  shift

  "$PYTHON_BIN" - \
  "$REPO_ROOT" \
  "$METRICS_OUT" \
  "$METRICS_LOG_INCLUDE_ROTATED" \
  "$METRICS_LOG_MAX_ARCHIVES" \
  "$METRICS_SQLITE_ENABLED" \
  "$METRICS_SQLITE_PATH" \
  "$@" > "$output_file" <<'PY'
import json
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
metrics_path = Path(sys.argv[2])
log_include_rotated = sys.argv[3].strip().lower() not in {"0", "false", "no", "off"}
log_max_archives = int(sys.argv[4])
sqlite_enabled = sys.argv[5].strip().lower() not in {"0", "false", "no", "off"}
sqlite_path = Path(sys.argv[6])
required_sources = sys.argv[7:]

src_dir = repo_root / "src"
if str(src_dir) not in sys.path:
  sys.path.insert(0, str(src_dir))

from metrics_api import MetricsLogReader
from metrics_liveness import build_baseline_payload


reader = MetricsLogReader(
  metrics_path,
  include_rotated=log_include_rotated,
  max_archives=log_max_archives,
  sqlite_path=sqlite_path if sqlite_enabled else None,
  prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()
source_sequences = reader.source_sequences()

baseline_payload = build_baseline_payload(
  latest_by_source,
  source_sequences,
  required_sources,
)
print(json.dumps(baseline_payload, sort_keys=True, ensure_ascii=False))
PY
}

validate_metrics() {
  local baseline_file="$1"
  shift

  "$PYTHON_BIN" - \
  "$REPO_ROOT" \
  "$METRICS_OUT" \
  "$METRICS_LOG_INCLUDE_ROTATED" \
  "$METRICS_LOG_MAX_ARCHIVES" \
  "$METRICS_SQLITE_ENABLED" \
  "$METRICS_SQLITE_PATH" \
  "$baseline_file" \
  "$@" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
metrics_path = Path(sys.argv[2])
log_include_rotated = sys.argv[3].strip().lower() not in {"0", "false", "no", "off"}
log_max_archives = int(sys.argv[4])
sqlite_enabled = sys.argv[5].strip().lower() not in {"0", "false", "no", "off"}
sqlite_path = Path(sys.argv[6])
baseline_file = Path(sys.argv[7])
required_sources = sys.argv[8:]

src_dir = repo_root / "src"
if str(src_dir) not in sys.path:
    sys.path.insert(0, str(src_dir))

from metrics_api import MetricsLogReader
from metrics_liveness import (
  evaluate_source_freshness,
  load_baseline_payload,
  settings_from_env,
)


settings = settings_from_env()
baseline_captured_at_epoch, baseline_signatures, baseline_sequences, baseline_sample_epoch = load_baseline_payload(
  baseline_file
)

reader = MetricsLogReader(
  metrics_path,
  include_rotated=log_include_rotated,
  max_archives=log_max_archives,
  sqlite_path=sqlite_path if sqlite_enabled else None,
  prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()
source_sequences = reader.source_sequences()
source_sample_epochs = reader.latest_sample_epoch_by_source()
window_events = reader.window_cells_events(lower_epoch=baseline_captured_at_epoch)
if not window_events:
  # Some test fixtures omit timestamps; fall back to unbounded scan in that case.
  window_events = reader.window_cells_events()

window_events_by_source = {}
for event in window_events:
  source_id = str(event.get("source_id", "single"))
  entities = event.get("entities") or []
  if not entities:
    continue
  window_events_by_source.setdefault(source_id, []).append(event)


def coerce_int(value):
  try:
    return int(value)
  except (TypeError, ValueError):
    return None


def iter_recent_entities(source_id, source_entry):
  source_events = window_events_by_source.get(source_id) or []
  if source_events:
    baseline_sequence = coerce_int(baseline_sequences.get(source_id))
    current_sequence = coerce_int(source_sequences.get(source_id))
    if current_sequence is None:
      current_sequence = coerce_int(source_entry.get("sequence"))

    if baseline_sequence is not None and current_sequence is not None and current_sequence > baseline_sequence:
      event_count = current_sequence - baseline_sequence
      for event in source_events[-event_count:]:
        for entity in event.get("entities") or []:
          yield entity
      return

    if baseline_sequence is None:
      for event in source_events[-50:]:
        for entity in event.get("entities") or []:
          yield entity
      return

    for entity in source_events[-1].get("entities") or []:
      yield entity
    return

  for entity in source_entry.get("entities") or []:
    yield entity

seen_sources = set()
positive = {
  source_id: {}
  for source_id in required_sources
}
stale_sources = []

for source_id in required_sources:
  source_entry = latest_by_source.get(source_id)
  if source_entry is None:
    continue

  seen_sources.add(source_id)
  is_fresh = evaluate_source_freshness(
    source_id,
    source_entry,
    source_sequences,
    source_sample_epochs,
    baseline_captured_at_epoch,
    baseline_signatures,
    baseline_sequences,
    baseline_sample_epoch,
    settings,
  )

  if not is_fresh:
    stale_sources.append(source_id)

  for entity in iter_recent_entities(source_id, source_entry):
    if not isinstance(entity, dict):
      continue

    ue_metrics = entity.get("ue") or {}
    if not isinstance(ue_metrics, dict):
      continue

    entity_id = str(
      entity.get("ue_identity")
      or f"cell{entity.get('cell_index', 0)}-ue{entity.get('ue_index', 0)}"
    )
    state = positive[source_id].setdefault(
      entity_id,
      {"dl": False, "ul": False},
    )

    if float(ue_metrics.get("dl_brate", 0) or 0) > 0:
      state["dl"] = True
    if float(ue_metrics.get("ul_brate", 0) or 0) > 0:
      state["ul"] = True

missing_sources = [source_id for source_id in required_sources if source_id not in seen_sources]
missing_entity_samples = [
    source_id
    for source_id in required_sources
    if source_id in seen_sources and not positive[source_id]
]
missing_dl = []
missing_ul = []

for source_id in required_sources:
  for entity_id, state in positive[source_id].items():
    if not state["dl"]:
      missing_dl.append(f"{source_id}:{entity_id}")
    if not state["ul"]:
      missing_ul.append(f"{source_id}:{entity_id}")

if missing_sources or stale_sources or missing_entity_samples or missing_dl or missing_ul:
  if missing_sources:
    print("Missing fresh metrics from: " + ", ".join(missing_sources), file=sys.stderr)
  if stale_sources:
    print(
      "Metrics freshness criteria not met from: " + ", ".join(stale_sources),
      file=sys.stderr,
    )
  if missing_entity_samples:
    print(
      "Missing fresh UE samples in cells metrics from: "
      + ", ".join(missing_entity_samples),
      file=sys.stderr,
    )
  if missing_dl:
    print("Missing fresh non-zero dl_brate from entities: " + ", ".join(missing_dl), file=sys.stderr)
  if missing_ul:
    print("Missing fresh non-zero ul_brate from entities: " + ", ".join(missing_ul), file=sys.stderr)
  raise SystemExit(1)

print("Fresh metrics seen from: " + ", ".join(required_sources))
entity_counts = [
    f"{source_id} ({len(positive[source_id])} UE entities)"
    for source_id in required_sources
]
print(
    "Fresh non-zero dl_brate and ul_brate confirmed for observed entities: "
    + ", ".join(entity_counts)
)
PY
}

# Array of PIDs for locally managed iperf3 server instances (one per UE namespace).
IPERF_SERVER_PIDS=()

start_iperf_servers() {
  if [[ "$IPERF_SERVER_MANAGE" != "1" ]]; then
    return 0
  fi

  # Start one server per UE on sequential ports (IPERF_PORT, IPERF_PORT+1, ...) so
  # all UE clients can run simultaneously without contending for the same server slot.
  local idx=0
  for _ns in "${UE_NAMESPACES[@]}"; do
    local port=$(( IPERF_PORT + idx ))
    echo "Starting local iperf3 server on port ${port}..."
    iperf3 --server --port "$port" >/dev/null 2>&1 &
    IPERF_SERVER_PIDS+=($!)
    (( idx++ )) || true
  done
  # Brief pause so all servers bind before the first client connects.
  sleep 0.5
}

stop_iperf_servers() {
  if [[ "$IPERF_SERVER_MANAGE" != "1" || ${#IPERF_SERVER_PIDS[@]} -eq 0 ]]; then
    return 0
  fi

  echo "Stopping local iperf3 server(s) (pids: ${IPERF_SERVER_PIDS[*]})..."
  for pid in "${IPERF_SERVER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  IPERF_SERVER_PIDS=()
}

netns_route_ready() {
  local netns_name="$1"
  sudo -n ip netns exec "$netns_name" ip route get "$TRAFFIC_TARGET" >/dev/null 2>&1
}

show_netns_debug() {
  local netns_name="$1"

  echo "Namespace ${netns_name} addresses:"
  sudo -n ip netns exec "$netns_name" ip addr || true
  echo "Namespace ${netns_name} routes:"
  sudo -n ip netns exec "$netns_name" ip route || true
}

wait_for_netns_route() {
  local netns_name="$1"
  local deadline=$((SECONDS + NET_READY_TIMEOUT_SECONDS))

  echo "Waiting up to ${NET_READY_TIMEOUT_SECONDS}s for ${netns_name} to gain a route to ${TRAFFIC_TARGET}..."

  while (( SECONDS < deadline )); do
    if netns_route_ready "$netns_name"; then
      echo "${netns_name} route to ${TRAFFIC_TARGET} is ready."
      return 0
    fi

    sleep "$NET_READY_POLL_SECONDS"
  done

  echo "${netns_name} never gained a route to ${TRAFFIC_TARGET}." >&2
  show_netns_debug "$netns_name" >&2
  return 1
}

require_command "$PYTHON_BIN"
require_command sudo
require_command ip
require_command iperf3
require_file "Metrics sources config" "$METRICS_SOURCES_CONFIG"
require_sudo_session

cd "$REPO_ROOT"

mkdir -p "$(dirname "$FRESHNESS_BASELINE_PATH")"
BASELINE_SIGNATURES_FILE="$FRESHNESS_BASELINE_PATH"
# Baseline is intentionally persistent (no rm-on-exit) so a crash between
# baseline capture and metrics validation can be recovered from on the next run.
trap 'stop_iperf_servers' EXIT

IFS=':' read -r -a UE_NAMESPACES <<< "$UE_NAMESPACES_RAW"
mapfile -t REQUIRED_SOURCES < <(load_required_sources)

if [[ ${#REQUIRED_SOURCES[@]} -eq 0 ]]; then
  echo "No source_id values found in: $METRICS_SOURCES_CONFIG" >&2
  exit 1
fi

write_baseline_signatures "$BASELINE_SIGNATURES_FILE" "${REQUIRED_SOURCES[@]}"

echo "Validation baseline captured for required sources."
echo "Required sources: $(IFS=', '; echo "${REQUIRED_SOURCES[*]}")"
echo "UE namespaces: $(IFS=', '; echo "${UE_NAMESPACES[*]}")"

if [[ "$SKIP_PROVISION" != "1" ]]; then
  echo "Applying subscriber provisioning..."
  "$PYTHON_BIN" src/provision_subscribers.py --apply
fi

if [[ "$SKIP_LAUNCH" != "1" ]]; then
  echo "Launching the full multi-gNB stage in ${LAUNCH_MODE} mode..."
  DASHBOARD_ENABLED="$LAUNCH_DASHBOARD_ENABLED" \
    HEALTHCHECK_ENABLED="$LAUNCH_HEALTHCHECK_ENABLED" \
    HEALTHCHECK_STRICT="$LAUNCH_HEALTHCHECK_STRICT" \
    FRESHNESS_CHECK_MODE="$FRESHNESS_CHECK_MODE" \
    FRESHNESS_AGE_WINDOW_SECONDS="$FRESHNESS_AGE_WINDOW_SECONDS" \
    FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS="$FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS" \
    HEALTHCHECK_REQUIRE_UE_DATA_PATH="$LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH" \
    HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="$LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS" \
    HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES="$LAUNCH_HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES" \
    CORE_READINESS_TIMEOUT_SECONDS="$LAUNCH_CORE_READINESS_TIMEOUT_SECONDS" \
    CORE_READINESS_POLL_SECONDS="$LAUNCH_CORE_READINESS_POLL_SECONDS" \
    CORE_READINESS_STABLE_POLLS="$LAUNCH_CORE_READINESS_STABLE_POLLS" \
    CORE_READINESS_REQUIRE_LOG_MARKERS="$LAUNCH_CORE_READINESS_REQUIRE_LOG_MARKERS" \
    CORE_READINESS_REQUIRE_SOCKET_PROBES="$LAUNCH_CORE_READINESS_REQUIRE_SOCKET_PROBES" \
    CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES="$LAUNCH_CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES" \
    CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS="$LAUNCH_CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS" \
    CORE_PROBE_SMF_PFCP_PORT="$LAUNCH_CORE_PROBE_SMF_PFCP_PORT" \
    CORE_PROBE_UPF_PFCP_PORT="$LAUNCH_CORE_PROBE_UPF_PFCP_PORT" \
    CORE_PROBE_UPF_GTPU_PORT="$LAUNCH_CORE_PROBE_UPF_GTPU_PORT" \
    CORE_STABILIZATION_SECONDS="$LAUNCH_CORE_STABILIZATION_SECONDS" \
    bash src/launch_stack.sh --mode "$LAUNCH_MODE"
fi

if [[ "$SKIP_TRAFFIC" != "1" ]]; then
  start_iperf_servers

  # Wait for each UE namespace to have a routable path to TRAFFIC_TARGET before
  # starting its iperf3 client.  Route-waits run sequentially (they are fast in
  # practice and order doesn't matter); iperf3 clients are then all backgrounded
  # so every UE generates traffic simultaneously, producing concurrent load across
  # all gNBs rather than sequential single-UE bursts.
  iperf_pids=()
  iperf_port_idx=0
  for netns_name in "${UE_NAMESPACES[@]}"; do
    wait_for_netns_route "$netns_name"
    local_port=$(( IPERF_PORT + iperf_port_idx ))
    echo "Running iperf3 from ${netns_name} to ${TRAFFIC_TARGET} for ${IPERF_DURATION_SECONDS}s (port ${local_port})..."
    sudo -n ip netns exec "$netns_name" iperf3 -c "$TRAFFIC_TARGET" -t "$IPERF_DURATION_SECONDS" -p "$local_port" &
    iperf_pids+=($!)
    (( iperf_port_idx++ )) || true
  done

  traffic_failed=0
  for pid in "${iperf_pids[@]}"; do
    wait "$pid" || traffic_failed=1
  done

  stop_iperf_servers

  if [[ "$traffic_failed" != "0" ]]; then
    echo "One or more iperf3 traffic runs failed." >&2
    exit 1
  fi
fi

echo "Waiting ${TRAFFIC_SETTLE_SECONDS}s for fresh traffic metrics..."
sleep "$TRAFFIC_SETTLE_SECONDS"

echo "Validating fresh metrics..."
validate_metrics "$BASELINE_SIGNATURES_FILE" "${REQUIRED_SOURCES[@]}"

echo "Validation run passed."
