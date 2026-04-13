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
NET_READY_TIMEOUT_SECONDS="${NET_READY_TIMEOUT_SECONDS:-60}"
NET_READY_POLL_SECONDS="${NET_READY_POLL_SECONDS:-1}"
UE_NAMESPACES_RAW="${UE_NAMESPACES:-ue1:ue2}"
LAUNCH_MODE="${LAUNCH_MODE:-supervised}"
LAUNCH_DASHBOARD_ENABLED="${LAUNCH_DASHBOARD_ENABLED:-0}"
LAUNCH_HEALTHCHECK_ENABLED="${LAUNCH_HEALTHCHECK_ENABLED:-1}"
LAUNCH_HEALTHCHECK_STRICT="${LAUNCH_HEALTHCHECK_STRICT:-1}"
LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH="${LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH:-0}"
LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="${LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS:-1}"
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
SKIP_PING=0

usage() {
  cat <<EOF
Usage: bash src/validate_stage.sh [--skip-provision] [--skip-launch] [--skip-ping]

This validation run:
  1. applies subscriber provisioning
  2. launches the multi-gNB stack
  3. sends traffic from each UE namespace to ${PING_TARGET}
  4. confirms fresh metrics from every configured source
  5. confirms fresh non-zero dl_brate and ul_brate for all observed UE entities
     in every configured source

Options:
  --skip-provision  Reuse existing subscribers.
  --skip-launch     Reuse an already running stack.
  --skip-ping       Skip the traffic generation step.
  --help            Show this message.

Environment overrides:
  PYTHON_BIN, METRICS_OUT, METRICS_SOURCES_CONFIG, PING_TARGET, PING_COUNT
  PING_WAIT_SECONDS, NET_READY_TIMEOUT_SECONDS, NET_READY_POLL_SECONDS
  UE_NAMESPACES, LAUNCH_MODE, LAUNCH_DASHBOARD_ENABLED
  LAUNCH_HEALTHCHECK_ENABLED, LAUNCH_HEALTHCHECK_STRICT
  LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH
  LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS
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
  Before pinging, this script also waits for a usable route inside each UE namespace.
  This script still performs the stricter validation after traffic generation.
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

  "$PYTHON_BIN" - "$METRICS_OUT" "$start_line" "$REPO_ROOT" "$@" <<'PY'
import json
import sys
from pathlib import Path

metrics_path = Path(sys.argv[1])
start_line = int(sys.argv[2])
repo_root = Path(sys.argv[3]).resolve()
required_sources = sys.argv[4:]

sys.path.insert(0, str(repo_root / "src"))

try:
    from metrics_identity import build_ue_identity
except Exception as exc:  # pragma: no cover - runtime safety in shell-embedded script
    raise SystemExit(f"Unable to import shared metrics identity helper: {exc}")

if not metrics_path.exists():
    raise SystemExit(f"Metrics file not found: {metrics_path}")

seen_sources = set()
positive = {
    source_id: {}
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

        for cell_index, cell in enumerate(cells):
            if not isinstance(cell, dict):
                continue

            ue_list = cell.get("ue_list") or []
            if not isinstance(ue_list, list):
                continue

            for ue_index, ue in enumerate(ue_list):
              if not isinstance(ue, dict):
                continue

              entity_id = build_ue_identity(ue, cell_index, ue_index)
              state = positive[source_id].setdefault(
                entity_id,
                {"dl": False, "ul": False},
              )

              if float(ue.get("dl_brate", 0) or 0) > 0:
                state["dl"] = True
              if float(ue.get("ul_brate", 0) or 0) > 0:
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

if missing_sources or missing_entity_samples or missing_dl or missing_ul:
    if missing_sources:
        print("Missing fresh metrics from: " + ", ".join(missing_sources), file=sys.stderr)
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

netns_route_ready() {
  local netns_name="$1"
  sudo ip netns exec "$netns_name" ip route get "$PING_TARGET" >/dev/null 2>&1
}

show_netns_debug() {
  local netns_name="$1"

  echo "Namespace ${netns_name} addresses:"
  sudo ip netns exec "$netns_name" ip addr || true
  echo "Namespace ${netns_name} routes:"
  sudo ip netns exec "$netns_name" ip route || true
}

wait_for_netns_route() {
  local netns_name="$1"
  local deadline=$((SECONDS + NET_READY_TIMEOUT_SECONDS))

  echo "Waiting up to ${NET_READY_TIMEOUT_SECONDS}s for ${netns_name} to gain a route to ${PING_TARGET}..."

  while (( SECONDS < deadline )); do
    if netns_route_ready "$netns_name"; then
      echo "${netns_name} route to ${PING_TARGET} is ready."
      return 0
    fi

    sleep "$NET_READY_POLL_SECONDS"
  done

  echo "${netns_name} never gained a route to ${PING_TARGET}." >&2
  show_netns_debug "$netns_name" >&2
  return 1
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
  echo "Launching the full multi-gNB stage in ${LAUNCH_MODE} mode..."
  DASHBOARD_ENABLED="$LAUNCH_DASHBOARD_ENABLED" \
    HEALTHCHECK_ENABLED="$LAUNCH_HEALTHCHECK_ENABLED" \
    HEALTHCHECK_STRICT="$LAUNCH_HEALTHCHECK_STRICT" \
    HEALTHCHECK_REQUIRE_UE_DATA_PATH="$LAUNCH_HEALTHCHECK_REQUIRE_UE_DATA_PATH" \
    HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="$LAUNCH_HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS" \
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

if [[ "$SKIP_PING" != "1" ]]; then
  for netns_name in "${UE_NAMESPACES[@]}"; do
    wait_for_netns_route "$netns_name"
    echo "Sending traffic from ${netns_name} to ${PING_TARGET}..."
    sudo ip netns exec "$netns_name" ping -c "$PING_COUNT" "$PING_TARGET"
  done
fi

echo "Waiting ${PING_WAIT_SECONDS}s for fresh traffic metrics..."
sleep "$PING_WAIT_SECONDS"

echo "Validating fresh metrics..."
validate_metrics "$START_LINE" "${REQUIRED_SOURCES[@]}"

echo "Validation run passed."
