#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

source_runtime_env_if_present() {
  local env_file="${RUNTIME_ENV_FILE:-$REPO_ROOT/var/oai.env}"
  local name
  local -A saved_values=()
  local -a saved_names=()
  local -a override_names=(
    RAN_BACKEND
    PYTHON_BIN
    VENV_DIR
    METRICS_SOURCES_CONFIG
    METRICS_OUT
    METRICS_AGENT_OUT
    METRICS_SQLITE_PATH
    API_HOST
    API_PORT
    DASHBOARD_ENABLED
    GNB_BIN
    UE_BIN
    GNB_CONFIGS
    UE_CONFIGS
    OAI_GNB_EXTRA_ARGS
    OAI_UE_EXTRA_ARGS
    UE_NAMESPACES
    RUNTIME_ENV_FILE
  )

  if [[ "${PI_LEIC_AUTO_SOURCE_ENV:-1}" != "1" || ! -f "$env_file" ]]; then
    return
  fi

  for name in "${override_names[@]}"; do
    if [[ -v "$name" ]]; then
      saved_values[$name]="${!name}"
      saved_names+=("$name")
    fi
  done

  # shellcheck source=/dev/null
  source "$env_file"

  for name in "${saved_names[@]}"; do
    printf -v "$name" '%s' "${saved_values[$name]}"
    export "$name"
  done
}

source_runtime_env_if_present

ACTION="start"
MODE="${MODE:-supervised}"
LOG_TARGET=""
DRY_RUN="${DRY_RUN:-0}"
RAN_BACKEND="${RAN_BACKEND:-oai}"
case "$RAN_BACKEND" in
  oai|oran|openairinterface)
    RAN_BACKEND="oai"
    ;;
  srsran)
    ;;
  *)
    echo "Unsupported RAN_BACKEND: $RAN_BACKEND" >&2
    echo "Supported values: oai, oran, openairinterface, srsran" >&2
    exit 1
    ;;
esac

if [[ "$RAN_BACKEND" == "oai" ]]; then
  DEFAULT_METRICS_SOURCES_CONFIG="$SCRIPT_DIR/../config/metrics_sources_oai.json"
  DEFAULT_GNB_BIN="nr-softmodem"
  DEFAULT_UE_BIN="nr-uesoftmodem"
  DEFAULT_GNB_CONFIGS="$SCRIPT_DIR/../config/oai/gnb.sa.band78.rfsim.conf:$SCRIPT_DIR/../config/oai/gnb2.sa.band78.rfsim.conf"
  DEFAULT_UE_CONFIGS="$SCRIPT_DIR/../config/oai/nrue.rfsim.launch.conf:$SCRIPT_DIR/../config/oai/nrue2.rfsim.launch.conf"
else
  DEFAULT_METRICS_SOURCES_CONFIG="$SCRIPT_DIR/../config/metrics_sources.json"
  DEFAULT_GNB_BIN="gnb"
  DEFAULT_UE_BIN="srsue"
  DEFAULT_GNB_CONFIGS="$SCRIPT_DIR/../config/gnb_gnb1_zmq.yaml:$SCRIPT_DIR/../config/gnb_gnb2_zmq.yaml"
  DEFAULT_UE_CONFIGS="$SCRIPT_DIR/../config/ue1_zmq.conf.txt:$SCRIPT_DIR/../config/ue2_zmq.conf.txt"
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$SCRIPT_DIR/../requirements.txt}"
METRICS_SCRIPT="${METRICS_SCRIPT:-metrics_collector.py}"
DASHBOARD_SCRIPT="${DASHBOARD_SCRIPT:-dashboard.py}"
API_SCRIPT="${API_SCRIPT:-metrics_rest_api.py}"
METRICS_SOURCES_CONFIG="${METRICS_SOURCES_CONFIG:-$DEFAULT_METRICS_SOURCES_CONFIG}"
METRICS_OUT="${METRICS_OUT:-$SCRIPT_DIR/../metrics/gnb_metrics.jsonl}"
METRICS_AGENT_OUT="${METRICS_AGENT_OUT:-$SCRIPT_DIR/../metrics/agent_network_observations.jsonl}"
METRICS_LOG_INCLUDE_ROTATED="${METRICS_LOG_INCLUDE_ROTATED:-1}"
METRICS_LOG_MAX_ARCHIVES="${METRICS_LOG_MAX_ARCHIVES:-5}"
METRICS_SQLITE_ENABLED="${METRICS_SQLITE_ENABLED:-1}"
METRICS_SQLITE_PATH="${METRICS_SQLITE_PATH:-/tmp/pi-leic-metrics.sqlite}"
FRESHNESS_CHECK_MODE="${FRESHNESS_CHECK_MODE:-hybrid}"
FRESHNESS_AGE_WINDOW_SECONDS="${FRESHNESS_AGE_WINDOW_SECONDS:-15}"
FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS="${FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS:-2}"
GNB_BIN="${GNB_BIN:-$DEFAULT_GNB_BIN}"
UE_BIN="${UE_BIN:-$DEFAULT_UE_BIN}"
GNB_CONFIGS="${GNB_CONFIGS:-$DEFAULT_GNB_CONFIGS}"
UE_CONFIGS="${UE_CONFIGS:-$DEFAULT_UE_CONFIGS}"
OAI_GNB_EXTRA_ARGS="${OAI_GNB_EXTRA_ARGS:---rfsim}"
OAI_UE_EXTRA_ARGS="${OAI_UE_EXTRA_ARGS:---rfsim --rfsimulator.serveraddr 127.0.0.1}"
MPLCONFIGDIR_PATH="${MPLCONFIGDIR_PATH:-/tmp/pi-leic-matplotlib}"
DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-1}"
API_ENABLED="${API_ENABLED:-1}"
API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8000}"
HEALTHCHECK_ENABLED="${HEALTHCHECK_ENABLED:-1}"
HEALTHCHECK_STRICT="${HEALTHCHECK_STRICT:-0}"
HEALTHCHECK_REQUIRE_UE_DATA_PATH="${HEALTHCHECK_REQUIRE_UE_DATA_PATH:-0}"
HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="${HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS:-1}"
HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES="${HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES:-core-discovery}"
HEALTHCHECK_UE_FAILURE_REGEX="${HEALTHCHECK_UE_FAILURE_REGEX:-Registration reject|Attach reject|PDU session.*reject|PDU Session.*reject}"
HEALTHCHECK_AMF_FAILURE_REGEX="${HEALTHCHECK_AMF_FAILURE_REGEX:-HTTP response error \\[(status:)?5[0-9][0-9]\\]|Cannot discover \\[[^]]+\\]|Registration reject}"
HEALTHCHECK_TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-30}"
HEALTHCHECK_POLL_SECONDS="${HEALTHCHECK_POLL_SECONDS:-1}"
CORE_READINESS_TIMEOUT_SECONDS="${CORE_READINESS_TIMEOUT_SECONDS:-45}"
CORE_READINESS_POLL_SECONDS="${CORE_READINESS_POLL_SECONDS:-1}"
CORE_READINESS_STABLE_POLLS="${CORE_READINESS_STABLE_POLLS:-3}"
CORE_READINESS_REQUIRE_LOG_MARKERS="${CORE_READINESS_REQUIRE_LOG_MARKERS:-1}"
CORE_READINESS_REQUIRE_SMF_AMF_ASSOCIATION="${CORE_READINESS_REQUIRE_SMF_AMF_ASSOCIATION:-1}"
CORE_READINESS_REQUIRE_SOCKET_PROBES="${CORE_READINESS_REQUIRE_SOCKET_PROBES:-1}"
CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES="${CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES:-1}"
CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS="${CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS:-1}"
CORE_PROBE_SMF_PFCP_PORT="${CORE_PROBE_SMF_PFCP_PORT:-8805}"
CORE_PROBE_UPF_PFCP_PORT="${CORE_PROBE_UPF_PFCP_PORT:-8805}"
CORE_PROBE_UPF_GTPU_PORT="${CORE_PROBE_UPF_GTPU_PORT:-2152}"
CORE_STABILIZATION_SECONDS="${CORE_STABILIZATION_SECONDS:-0}"
CORE_AMF_LOG_PATH="${CORE_AMF_LOG_PATH:-/var/log/open5gs/amf.log}"
CORE_SMF_LOG_PATH="${CORE_SMF_LOG_PATH:-/var/log/open5gs/smf.log}"
CORE_UPF_LOG_PATH="${CORE_UPF_LOG_PATH:-/var/log/open5gs/upf.log}"
SUDO_KEEPALIVE_INTERVAL_SECONDS="${SUDO_KEEPALIVE_INTERVAL_SECONDS:-20}"
UNIT_PREFIX="${UNIT_PREFIX:-pi-leic}"
ALLOW_SUPERVISED_AS_ROOT="${ALLOW_SUPERVISED_AS_ROOT:-0}"

CORE_UNITS=(
  open5gs-mmed
  open5gs-sgwcd
  open5gs-smfd
  open5gs-amfd
  open5gs-sgwud
  open5gs-upfd
  open5gs-hssd
  open5gs-pcrfd
  open5gs-nrfd
  open5gs-scpd
  open5gs-seppd
  open5gs-ausfd
  open5gs-udmd
  open5gs-pcfd
  open5gs-nssfd
  open5gs-bsfd
  open5gs-udrd
)

SUDO_KEEPALIVE_PID=""
HEALTHCHECK_METRICS_BASELINE_FILE=""
LAUNCH_LIB_DIR="$SCRIPT_DIR/launch_lib"

# shellcheck source=src/launch_lib/common.sh
source "$LAUNCH_LIB_DIR/common.sh"
# shellcheck source=src/launch_lib/root_runtime.sh
source "$LAUNCH_LIB_DIR/root_runtime.sh"
# shellcheck source=src/launch_lib/journal_helpers.sh
source "$LAUNCH_LIB_DIR/journal_helpers.sh"
# shellcheck source=src/launch_lib/socket_probes.sh
source "$LAUNCH_LIB_DIR/socket_probes.sh"
# shellcheck source=src/launch_lib/process_management.sh
source "$LAUNCH_LIB_DIR/process_management.sh"
# shellcheck source=src/launch_lib/core_readiness.sh
source "$LAUNCH_LIB_DIR/core_readiness.sh"
# shellcheck source=src/launch_lib/health_classification.sh
source "$LAUNCH_LIB_DIR/health_classification.sh"
# shellcheck source=src/launch_lib/metrics_contract.sh
source "$LAUNCH_LIB_DIR/metrics_contract.sh"
# shellcheck source=src/launch_lib/health_checks.sh
source "$LAUNCH_LIB_DIR/health_checks.sh"

usage() {
  cat <<EOF
Usage: ./launch_stack.sh [--mode MODE] [--workdir PATH] [--dry-run] [--stop] [--status] [--logs COMPONENT]

Actions:
  start (default)  Start the stage.
  --stop           Stop supervised units and remove UE namespaces.
  --status         Show core and supervised unit status.
  --logs NAME      Follow logs for one component. Examples: core, collector, api, dashboard, gnb1, ue1

Options:
  --mode MODE      Launch mode: supervised (default) or terminals.
  --workdir PATH   Linux path where the Python scripts live.
  --dry-run        Print the commands instead of starting anything.
  --help           Show this message.

Environment overrides:
  WORKDIR, MODE, RAN_BACKEND, PYTHON_BIN, VENV_DIR, REQUIREMENTS_FILE, METRICS_SCRIPT, DASHBOARD_SCRIPT, API_SCRIPT
  METRICS_SOURCES_CONFIG, METRICS_OUT, METRICS_AGENT_OUT, GNB_BIN, UE_BIN, GNB_CONFIGS, UE_CONFIGS
  OAI_GNB_EXTRA_ARGS, OAI_UE_EXTRA_ARGS
  METRICS_LOG_INCLUDE_ROTATED, METRICS_LOG_MAX_ARCHIVES
  METRICS_SQLITE_ENABLED, METRICS_SQLITE_PATH
  FRESHNESS_CHECK_MODE, FRESHNESS_AGE_WINDOW_SECONDS
  FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS
  DASHBOARD_ENABLED, API_ENABLED, API_HOST, API_PORT
  HEALTHCHECK_ENABLED, HEALTHCHECK_STRICT
  HEALTHCHECK_REQUIRE_UE_DATA_PATH, HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS
  HEALTHCHECK_FAIL_FAST_EXCLUDE_CATEGORIES
  HEALTHCHECK_UE_FAILURE_REGEX, HEALTHCHECK_AMF_FAILURE_REGEX
  HEALTHCHECK_TIMEOUT_SECONDS, HEALTHCHECK_POLL_SECONDS
  CORE_READINESS_TIMEOUT_SECONDS, CORE_READINESS_POLL_SECONDS
  CORE_READINESS_STABLE_POLLS, CORE_READINESS_REQUIRE_LOG_MARKERS
  CORE_READINESS_REQUIRE_SMF_AMF_ASSOCIATION
  CORE_READINESS_REQUIRE_SOCKET_PROBES
  CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES
  CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS
  CORE_PROBE_SMF_PFCP_PORT, CORE_PROBE_UPF_PFCP_PORT, CORE_PROBE_UPF_GTPU_PORT
  CORE_STABILIZATION_SECONDS
  CORE_AMF_LOG_PATH, CORE_SMF_LOG_PATH, CORE_UPF_LOG_PATH
  SUDO_KEEPALIVE_INTERVAL_SECONDS, UNIT_PREFIX

Notes:
  GNB_CONFIGS and UE_CONFIGS use colon-separated paths.
  Supervised mode prompts for sudo once, starts root components via systemd-run,
  and is the recommended mode for validation and repeatable runs.
  Core readiness waits dynamically for active core units, startup markers,
  optional SMF<->AMF association markers,
  live Open5GS socket probes, and active endpoint probes,
  then optionally applies CORE_STABILIZATION_SECONDS as an extra settle delay.
  Terminals mode is kept as a fallback for manual desktop debugging.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --stop)
      ACTION="stop"
      shift
      ;;
    --status)
      ACTION="status"
      shift
      ;;
    --logs)
      ACTION="logs"
      LOG_TARGET="$2"
      shift 2
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

cleanup() {
  if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
  fi

  if [[ -n "$HEALTHCHECK_METRICS_BASELINE_FILE" ]]; then
    rm -f "$HEALTHCHECK_METRICS_BASELINE_FILE" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

resolve_executable() {
  local executable="$1"

  if [[ "$executable" == */* ]]; then
    if [[ ! -x "$executable" ]]; then
      echo "Executable not found or not executable: $executable" >&2
      exit 1
    fi
    printf '%s\n' "$executable"
    return
  fi

  if ! command -v "$executable" >/dev/null 2>&1; then
    echo "Missing required command: $executable" >&2
    exit 1
  fi

  command -v "$executable"
}

require_supervised_runtime_prereqs() {
  if [[ "$MODE" != "supervised" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi

  if [[ "${EUID:-$(id -u)}" -eq 0 && "$ALLOW_SUPERVISED_AS_ROOT" != "1" ]]; then
    cat >&2 <<'EOF'
launch_stack.sh in supervised mode should be run as your regular user, not via sudo/root.

Use:
  bash src/launch_stack.sh

The script requests sudo only for privileged operations and runs collector/dashboard
as user services.
If you really need root mode, set ALLOW_SUPERVISED_AS_ROOT=1 explicitly.
EOF
    exit 1
  fi

  if ! systemctl --user show-environment >/dev/null 2>&1; then
    cat >&2 <<'EOF'
Unable to access the systemd user bus required by supervised mode.

Try running from your normal login session (without sudo), for example:
  bash src/launch_stack.sh

If you are on SSH/headless, ensure your user manager and DBUS session are available.
EOF
    exit 1
  fi
}

display_available() {
  [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]
}

find_terminal_emulator() {
  local terminal

  for terminal in gnome-terminal konsole xterm x-terminal-emulator; do
    if command -v "$terminal" >/dev/null 2>&1; then
      printf '%s\n' "$terminal"
      return 0
    fi
  done

  return 1
}

read_metrics_source_ids() {
  "$PYTHON_BIN_RESOLVED" -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

for item in data:
    print(item["source_id"])
' "$METRICS_SOURCES_CONFIG_PATH"
}

metrics_line_count() {
  journal_helpers_metrics_line_count "$@"
}

root_file_line_count() {
  journal_helpers_root_file_line_count "$@"
}

root_file_contains_pattern_since_line() {
  journal_helpers_root_file_contains_pattern_since_line "$@"
}

root_file_first_match_since_line() {
  journal_helpers_root_file_first_match_since_line "$@"
}

root_unit_first_match_since_epoch() {
  journal_helpers_root_unit_first_match_since_epoch "$@"
}

socket_snapshot_has_process_tcp_listener() {
  socket_probes_snapshot_has_process_tcp_listener "$@"
}

socket_snapshot_has_process_udp_port() {
  socket_probes_snapshot_has_process_udp_port "$@"
}

collect_core_socket_probe_failures() {
  socket_probes_collect_core_socket_probe_failures "$@"
}

first_tcp_listener_endpoint_for_process() {
  socket_probes_first_tcp_listener_endpoint_for_process "$@"
}

tcp_endpoint_probe_ok() {
  socket_probes_tcp_endpoint_probe_ok "$@"
}

collect_core_endpoint_probe_failures() {
  socket_probes_collect_core_endpoint_probe_failures "$@"
}

netns_exists() {
  local netns_name="$1"
  ip netns list | awk '{print $1}' | grep -Fx "$netns_name" >/dev/null 2>&1
}

netns_device_has_ipv4() {
  local netns_name="$1"
  local device_name="$2"

  [[ -n "$device_name" ]] || return 1
  sudo -n ip netns exec "$netns_name" ip -4 -o addr show dev "$device_name" scope global 2>/dev/null \
    | grep -q .
}

netns_has_default_route() {
  local netns_name="$1"

  sudo -n ip netns exec "$netns_name" ip route show default 2>/dev/null | grep -q .
}

prepare_python_env() {
  mkdir -p "$(dirname -- "$METRICS_OUT_PATH")"
  mkdir -p "$MPLCONFIGDIR_PATH"

  if [[ ! -d "$VENV_DIR_PATH" ]]; then
    "$PYTHON_BIN_RESOLVED" -m venv "$VENV_DIR_PATH"
  fi

  if ! "$VENV_DIR_PATH/bin/python" -c 'import matplotlib, websocket, fastapi, uvicorn' >/dev/null 2>&1; then
    "$VENV_DIR_PATH/bin/python" -m pip install -r "$REQUIREMENTS_FILE_PATH"
  fi
}

start_sudo_keepalive() {
  root_runtime_start_sudo_keepalive "$@"
}

require_sudo_session() {
  root_runtime_require_sudo_session "$@"
}

append_env_arg_if_set() {
  local -n target_ref="$1"
  local env_name="$2"
  local env_value="${!env_name:-}"

  if [[ -n "$env_value" ]]; then
    target_ref+=("--setenv=${env_name}=${env_value}")
  fi
}

find_pids_by_comm_and_needle() {
  process_management_find_pids_by_comm_and_needle "$@"
}

find_pids_by_needle() {
  process_management_find_pids_by_needle "$@"
}

find_python_pids_by_needle() {
  process_management_find_python_pids_by_needle "$@"
}

kill_matching_pids() {
  process_management_kill_matching_pids "$@"
}

kill_processes_for_comm_and_needles() {
  process_management_kill_processes_for_comm_and_needles "$@"
}

kill_python_processes_for_needles() {
  process_management_kill_python_processes_for_needles "$@"
}

cleanup_stale_lab_processes() {
  process_management_cleanup_stale_lab_processes "$@"
}

open_terminal() {
  local title="$1"
  local command="$2"
  local full_command="$command; exec bash"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[%s]\n%s\n\n' "$title" "$full_command"
    return
  fi

  case "$TERMINAL_EMULATOR" in
    gnome-terminal)
      gnome-terminal --title="$title" -- bash -lc "$full_command"
      ;;
    konsole)
      konsole --new-tab --hold -p tabtitle="$title" -e bash -lc "$full_command"
      ;;
    xterm)
      xterm -T "$title" -hold -e bash -lc "$full_command" &
      ;;
    x-terminal-emulator)
      x-terminal-emulator -e bash -lc "$full_command" &
      ;;
    *)
      echo "Unsupported terminal emulator: $TERMINAL_EMULATOR" >&2
      exit 1
      ;;
  esac
}

wait_for_core_readiness() {
  core_readiness_wait_for_core_readiness "$@"
}

stop_user_unit_if_exists() {
  root_runtime_stop_user_unit_if_exists "$@"
}

collect_known_user_units() {
  root_runtime_collect_known_user_units "$@"
}

stop_root_unit_if_exists() {
  root_runtime_stop_root_unit_if_exists "$@"
}

stop_supervised_stack() {
  local quiet="${1:-0}"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Would stop user units: $(join_by ', ' "${USER_UNIT_NAMES[@]}")"
    echo "Would stop root units: $(join_by ', ' "${ROOT_UNIT_NAMES[@]}")"
    echo "Would remove UE namespaces: $(join_by ', ' "${UE_NETNS_LIST[@]}")"
    return
  fi

  require_sudo_session

  for unit in "${USER_UNIT_NAMES[@]}"; do
    stop_user_unit_if_exists "$unit"
  done

  for unit in "${ROOT_UNIT_NAMES[@]}"; do
    stop_root_unit_if_exists "$unit"
  done

  for ue_netns in "${UE_NETNS_LIST[@]}"; do
    sudo -n ip netns del "$ue_netns" >/dev/null 2>&1 || true
  done

  if [[ "$quiet" != "1" ]]; then
    echo "Stopped supervised stack units."
  fi
}

start_root_unit() {
  root_runtime_start_root_unit "$@"
}

start_user_unit() {
  root_runtime_start_user_unit "$@"
}

prepare_healthcheck_baseline_and_markers() {
  if [[ -n "$HEALTHCHECK_METRICS_BASELINE_FILE" ]]; then
    rm -f "$HEALTHCHECK_METRICS_BASELINE_FILE" >/dev/null 2>&1 || true
  fi

  HEALTHCHECK_METRICS_BASELINE_FILE="$(mktemp)"
  metrics_contract_write_baseline_signatures "$HEALTHCHECK_METRICS_BASELINE_FILE" "${METRICS_SOURCE_IDS[@]}"

  HEALTHCHECK_START_EPOCH="$(date +%s)"
  HEALTHCHECK_AMF_LOG_START_LINE="$(root_file_line_count "$CORE_AMF_LOG_PATH")"
  HEALTHCHECK_SMF_LOG_START_LINE="$(root_file_line_count "$CORE_SMF_LOG_PATH")"
  HEALTHCHECK_UPF_LOG_START_LINE="$(root_file_line_count "$CORE_UPF_LOG_PATH")"
}

start_supervised_stack() {
  require_supervised_runtime_prereqs

  local collector_unit
  local api_unit
  local dashboard_unit
  local gnb_config
  local ue_config
  local gnb_label
  local ue_label
  local ue_netns
  local ue_arg
  local ue_script
  local start_line
  local amf_log_start_line
  local smf_log_start_line
  local upf_log_start_line
  local -a collector_args
  local -a api_args
  local -a dashboard_args
  local -a gnb_args
  local -a ue_args

  if [[ "$DRY_RUN" != "1" ]]; then
    require_sudo_session
    prepare_python_env
  fi

  stop_supervised_stack 1
  cleanup_stale_lab_processes
  start_line="$(metrics_line_count)"

  prepare_healthcheck_baseline_and_markers
  amf_log_start_line="$HEALTHCHECK_AMF_LOG_START_LINE"
  smf_log_start_line="$HEALTHCHECK_SMF_LOG_START_LINE"
  upf_log_start_line="$HEALTHCHECK_UPF_LOG_START_LINE"
  HEALTHCHECK_ROOT_UNITS=("${ROOT_UNIT_NAMES[@]}")
  HEALTHCHECK_USER_UNITS=(
    "$(user_unit_name "metrics-collector")"
  )

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Would restart core services: $(join_by ' ' "${CORE_UNITS[@]}")"
  else
    sudo -n systemctl restart "${CORE_UNITS[@]}"
  fi

  wait_for_core_readiness "$amf_log_start_line" "$smf_log_start_line" "$upf_log_start_line"

  if [[ "$CORE_STABILIZATION_SECONDS" -gt 0 ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "Would apply an extra ${CORE_STABILIZATION_SECONDS}s control-plane settle delay."
    else
      echo "Applying an extra ${CORE_STABILIZATION_SECONDS}s control-plane settle delay..."
      sleep "$CORE_STABILIZATION_SECONDS"
    fi
  fi

  collector_unit="$(user_unit_name "metrics-collector")"
  collector_args=(
    "--setenv=RAN_BACKEND=$RAN_BACKEND"
    "--setenv=METRICS_SOURCES_CONFIG=$METRICS_SOURCES_CONFIG_PATH"
    "--setenv=METRICS_OUT=$METRICS_OUT_PATH"
    "--setenv=METRICS_AGENT_OUT=$METRICS_AGENT_OUT_PATH"
    "--setenv=METRICS_SQLITE_ENABLED=$METRICS_SQLITE_ENABLED"
    "--setenv=METRICS_SQLITE_PATH=$METRICS_SQLITE_PATH"
    "$VENV_DIR_PATH/bin/python"
    -u
    "$METRICS_SCRIPT_PATH"
  )
  append_env_arg_if_set collector_args METRICS_SQLITE_TIMEOUT_SECONDS
  append_env_arg_if_set collector_args METRICS_SQLITE_RETRY_MAX_FAILURES
  append_env_arg_if_set collector_args METRICS_SQLITE_RETRY_COOLDOWN_SECONDS
  append_env_arg_if_set collector_args METRICS_SQLITE_RETENTION_MAX_AGE_DAYS
  append_env_arg_if_set collector_args METRICS_SQLITE_RETENTION_MAX_ROWS
  append_env_arg_if_set collector_args METRICS_SQLITE_RETENTION_INTERVAL_EVENTS
  append_env_arg_if_set collector_args METRICS_SQLITE_RETENTION_VACUUM
  start_user_unit "$collector_unit" "PI-LEIC Metrics Collector" "${collector_args[@]}"

  if [[ "$API_ENABLED" == "1" ]]; then
    api_unit="$(user_unit_name "metrics-api")"
    api_args=(
      "--setenv=METRICS_OUT=$METRICS_OUT_PATH"
      "--setenv=METRICS_LOG_INCLUDE_ROTATED=$METRICS_LOG_INCLUDE_ROTATED"
      "--setenv=METRICS_LOG_MAX_ARCHIVES=$METRICS_LOG_MAX_ARCHIVES"
      "--setenv=METRICS_SQLITE_ENABLED=$METRICS_SQLITE_ENABLED"
      "--setenv=METRICS_SQLITE_PATH=$METRICS_SQLITE_PATH"
      "--setenv=API_HOST=$API_HOST"
      "--setenv=API_PORT=$API_PORT"
      "$VENV_DIR_PATH/bin/python"
      -u
      "$API_SCRIPT_PATH"
    )
    append_env_arg_if_set api_args API_SCHEMA_VERSION
    append_env_arg_if_set api_args ALERT_STALE_AFTER_SECONDS
    append_env_arg_if_set api_args ALERT_MIN_DL_BRATE
    append_env_arg_if_set api_args ALERT_MIN_UL_BRATE
    append_env_arg_if_set api_args ALERT_RULESET_VERSION
    append_env_arg_if_set api_args API_AUDIT_DB_ENABLED
    append_env_arg_if_set api_args API_AUDIT_DB_PATH
    append_env_arg_if_set api_args API_AUDIT_DB_TIMEOUT_SECONDS
    append_env_arg_if_set api_args QUERY_BACKEND_MODE
    append_env_arg_if_set api_args FRESHNESS_CHECK_MODE
    append_env_arg_if_set api_args FRESHNESS_AGE_WINDOW_SECONDS
    append_env_arg_if_set api_args FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS
    start_user_unit "$api_unit" "PI-LEIC Metrics REST API" "${api_args[@]}"
    HEALTHCHECK_USER_UNITS+=("$api_unit")
  fi

  if [[ "$DASHBOARD_ENABLED" == "1" ]]; then
    if display_available; then
      dashboard_unit="$(user_unit_name "dashboard")"
      dashboard_args=(
        "--setenv=METRICS_OUT=$METRICS_OUT_PATH"
        "--setenv=MPLCONFIGDIR=$MPLCONFIGDIR_PATH"
      )
      append_env_arg_if_set dashboard_args DISPLAY
      append_env_arg_if_set dashboard_args WAYLAND_DISPLAY
      append_env_arg_if_set dashboard_args XAUTHORITY
      append_env_arg_if_set dashboard_args DBUS_SESSION_BUS_ADDRESS
      dashboard_args+=("$VENV_DIR_PATH/bin/python" "$DASHBOARD_SCRIPT_PATH")
      start_user_unit "$dashboard_unit" "PI-LEIC Metrics Dashboard" "${dashboard_args[@]}"
      HEALTHCHECK_USER_UNITS+=("$dashboard_unit")
    else
      echo "Skipping dashboard in supervised mode because no graphical display was detected."
    fi
  fi

  for gnb_config in "${GNB_CONFIG_PATHS[@]}"; do
    gnb_label="$(config_label "$gnb_config")"
    if [[ "$RAN_BACKEND" == "oai" ]]; then
      # Each OAI gNB writes nrMAC_stats.log (hard-coded relative path) and
      # nrRRC_stats.log to its CWD; give each its own directory so a second
      # gNB does not overwrite the first.
      local gnb_workdir="$WORKDIR/../metrics/oran/$gnb_label"
      read -r -a gnb_args <<< "$OAI_GNB_EXTRA_ARGS"
      printf -v gnb_script \
        'mkdir -p %q && cd %q && exec %q -O %q' \
        "$gnb_workdir" \
        "$gnb_workdir" \
        "$GNB_BIN_RESOLVED" \
        "$gnb_config"
      for gnb_arg in "${gnb_args[@]}"; do
        printf -v gnb_script '%s %q' "$gnb_script" "$gnb_arg"
      done
      start_root_unit \
        "$(root_unit_name "gnb-$gnb_label")" \
        "PI-LEIC gNB $gnb_label" \
        /bin/bash -lc "$gnb_script"
    else
      gnb_args=(-c "$gnb_config")
      start_root_unit \
        "$(root_unit_name "gnb-$gnb_label")" \
        "PI-LEIC gNB $gnb_label" \
        "$GNB_BIN_RESOLVED" "${gnb_args[@]}"
    fi
  done

  for ue_config in "${UE_CONFIG_PATHS[@]}"; do
    ue_label="$(config_label "$ue_config")"
    ue_netns="$(read_netns "$ue_config")"
    if [[ "$RAN_BACKEND" == "oai" ]]; then
      # Per-UE OAI config (IMSI/K/OPC + RFsim port) comes from the shim's
      # ue_config key; the launcher prepends `-O <abs_path>` so OAI_UE_EXTRA_ARGS
      # stays the common RF args (--rfsim, -r, --band, -C, --ssb).
      local ue_oai_config
      ue_oai_config="$(read_ue_config "$ue_config")"
      if [[ -z "$ue_oai_config" ]]; then
        echo "Missing 'ue_config' in OAI UE launch shim: $ue_config" >&2
        return 1
      fi
      # Resolve relative ue_config against the shim's own directory, not WORKDIR.
      if [[ "$ue_oai_config" != /* ]]; then
        ue_oai_config="$(dirname -- "$ue_config")/$ue_oai_config"
      fi
      read -r -a ue_args <<< "$OAI_UE_EXTRA_ARGS"

      # OAI nr-uesoftmodem writes nrL1_UE_stats-0.log (and similar) to its CWD
      # with hard-coded relative paths. Give each UE its own directory under
      # metrics/oran/ so the logs don't land in the launcher's CWD.
      local ue_workdir="$WORKDIR/../metrics/oran/ue-$ue_label"

      # When the shim declares veth IPs, run the UE inside its netns and create a
      # veth pair so the UE can reach the gNB's RFsim server. This isolates each
      # UE's `oaitun_ue1` TUN — OAI hard-codes the TUN name per process, so two
      # UEs in the host netns would collide. With per-UE netns, each gets its
      # own `oaitun_ue1` (independent interface inside its own namespace).
      local ue_veth_host_ip ue_veth_ns_ip
      ue_veth_host_ip="$(read_veth_host_ip "$ue_config")"
      ue_veth_ns_ip="$(read_veth_ns_ip "$ue_config")"
      if [[ -n "$ue_veth_host_ip" && -n "$ue_veth_ns_ip" ]]; then
        local veth_host_ifname="vh-$ue_netns"
        local veth_ns_ifname="vp-$ue_netns"
        local ue_exec_cmd
        printf -v ue_exec_cmd 'exec ip netns exec %q %q -O %q' \
          "$ue_netns" "$UE_BIN_RESOLVED" "$ue_oai_config"
        for ue_arg in "${ue_args[@]}"; do
          printf -v ue_exec_cmd '%s %q' "$ue_exec_cmd" "$ue_arg"
        done
        printf -v ue_script \
          'set -e; mkdir -p %q; cd %q; ip netns del %q 2>/dev/null || true; ip link del %q 2>/dev/null || true; ip netns add %q; ip link add %q type veth peer name %q; ip link set %q netns %q; ip addr add %s/30 dev %q; ip link set %q up; ip netns exec %q ip addr add %s/30 dev %q; ip netns exec %q ip link set %q up; ip netns exec %q ip link set lo up; %s' \
          "$ue_workdir" \
          "$ue_workdir" \
          "$ue_netns" \
          "$veth_host_ifname" \
          "$ue_netns" \
          "$veth_host_ifname" "$veth_ns_ifname" \
          "$veth_ns_ifname" "$ue_netns" \
          "$ue_veth_host_ip" "$veth_host_ifname" \
          "$veth_host_ifname" \
          "$ue_netns" "$ue_veth_ns_ip" "$veth_ns_ifname" \
          "$ue_netns" "$veth_ns_ifname" \
          "$ue_netns" \
          "$ue_exec_cmd"
      else
        printf -v ue_script \
          'mkdir -p %q && cd %q && ip netns del %q 2>/dev/null || true; ip netns add %q; exec %q -O %q' \
          "$ue_workdir" \
          "$ue_workdir" \
          "$ue_netns" \
          "$ue_netns" \
          "$UE_BIN_RESOLVED" \
          "$ue_oai_config"
        for ue_arg in "${ue_args[@]}"; do
          printf -v ue_script '%s %q' "$ue_script" "$ue_arg"
        done
      fi
    else
      printf -v ue_script \
        'ip netns del %q 2>/dev/null || true; ip netns add %q; exec %q %q' \
        "$ue_netns" \
        "$ue_netns" \
        "$UE_BIN_RESOLVED" \
        "$ue_config"
    fi
    start_root_unit \
      "$(root_unit_name "ue-$ue_label")" \
      "PI-LEIC UE $ue_label" \
      /bin/bash -lc "$ue_script"
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run complete."
    return
  fi

  echo "Started supervised stack from: $WORKDIR"
  echo "Core services restarted: $(join_by ', ' "${CORE_UNITS[@]}")"
  echo "Root units: $(join_by ', ' "${ROOT_UNIT_NAMES[@]}")"
  echo "User units: $(join_by ', ' "${HEALTHCHECK_USER_UNITS[@]}")"
  echo "Use '$0 --status' for status or '$0 --logs collector' to inspect logs."
  run_health_checks "$start_line"
}

start_terminal_stack() {
  local core_command
  local collector_command
  local api_command
  local dashboard_command
  local gnb_config
  local ue_config
  local gnb_title
  local gnb_command
  local ue_title
  local ue_netns
  local ue_command
  local terminal_count
  local start_line

  if [[ "$DRY_RUN" != "1" ]]; then
    require_sudo_session
    prepare_python_env
  fi

  if ! TERMINAL_EMULATOR="$(find_terminal_emulator)"; then
    echo "No supported terminal emulator found." >&2
    echo "Install gnome-terminal, konsole, xterm, or x-terminal-emulator." >&2
    exit 1
  fi

  if ! display_available; then
    echo "No graphical display detected." >&2
    echo "Use '--mode supervised' or run from a desktop session." >&2
    exit 1
  fi

  stop_supervised_stack 1
  cleanup_stale_lab_processes
  start_line="$(metrics_line_count)"

  prepare_healthcheck_baseline_and_markers >/dev/null
  HEALTHCHECK_ROOT_UNITS=()
  HEALTHCHECK_USER_UNITS=()

  core_command="$(
    cat <<EOF
sudo -n systemctl restart $(join_by ' ' "${CORE_UNITS[@]}")
sudo -n systemctl status open5gs-amfd --no-pager
sudo -n tail -f '$CORE_AMF_LOG_PATH'
EOF
  )"

  collector_command="$(
    cat <<EOF
cd '$WORKDIR'
export RAN_BACKEND='$RAN_BACKEND'
export METRICS_SOURCES_CONFIG='$METRICS_SOURCES_CONFIG_PATH'
export METRICS_OUT='$METRICS_OUT_PATH'
export METRICS_AGENT_OUT='$METRICS_AGENT_OUT_PATH'
export METRICS_SQLITE_ENABLED='$METRICS_SQLITE_ENABLED'
export METRICS_SQLITE_PATH='$METRICS_SQLITE_PATH'
'$VENV_DIR_PATH/bin/python' -u '$METRICS_SCRIPT_PATH'
EOF
  )"

  api_command="$(
    cat <<EOF
cd '$WORKDIR'
export METRICS_OUT='$METRICS_OUT_PATH'
export METRICS_LOG_INCLUDE_ROTATED='$METRICS_LOG_INCLUDE_ROTATED'
export METRICS_LOG_MAX_ARCHIVES='$METRICS_LOG_MAX_ARCHIVES'
export METRICS_SQLITE_ENABLED='$METRICS_SQLITE_ENABLED'
export METRICS_SQLITE_PATH='$METRICS_SQLITE_PATH'
export API_HOST='$API_HOST'
export API_PORT='$API_PORT'
'$VENV_DIR_PATH/bin/python' -u '$API_SCRIPT_PATH'
EOF
  )"

  dashboard_command="$(
    cat <<EOF
cd '$WORKDIR'
export METRICS_OUT='$METRICS_OUT_PATH'
export MPLCONFIGDIR='$MPLCONFIGDIR_PATH'
'$VENV_DIR_PATH/bin/python' '$DASHBOARD_SCRIPT_PATH'
EOF
  )"

  open_terminal "Core" "$core_command"

  for gnb_config in "${GNB_CONFIG_PATHS[@]}"; do
    gnb_title="gNB $(config_label "$gnb_config")"
    if [[ "$RAN_BACKEND" == "oai" ]]; then
      gnb_command="$(
        cat <<EOF
cd '$WORKDIR'
sudo -n '$GNB_BIN_RESOLVED' -O '$gnb_config' $OAI_GNB_EXTRA_ARGS
EOF
      )"
    else
      gnb_command="$(
        cat <<EOF
cd '$WORKDIR'
sudo -n '$GNB_BIN_RESOLVED' -c '$gnb_config'
EOF
      )"
    fi
    open_terminal "$gnb_title" "$gnb_command"
  done

  for ue_config in "${UE_CONFIG_PATHS[@]}"; do
    ue_title="UE $(config_label "$ue_config")"
    ue_netns="$(read_netns "$ue_config")"

    if [[ "$RAN_BACKEND" == "oai" ]]; then
      local ue_oai_config_t
      ue_oai_config_t="$(read_ue_config "$ue_config")"
      if [[ -z "$ue_oai_config_t" ]]; then
        echo "Missing 'ue_config' in OAI UE launch shim: $ue_config" >&2
        return 1
      fi
      if [[ "$ue_oai_config_t" != /* ]]; then
        ue_oai_config_t="$(dirname -- "$ue_config")/$ue_oai_config_t"
      fi
      # Per-UE workdir so OAI's nrL1_UE_stats-0.log doesn't land in the
      # launcher's CWD.
      local ue_workdir_t="$WORKDIR/../metrics/oran/ue-$(config_label "$ue_config")"
      local ue_veth_host_ip_t ue_veth_ns_ip_t
      ue_veth_host_ip_t="$(read_veth_host_ip "$ue_config")"
      ue_veth_ns_ip_t="$(read_veth_ns_ip "$ue_config")"
      if [[ -n "$ue_veth_host_ip_t" && -n "$ue_veth_ns_ip_t" ]]; then
        ue_command="$(
          cat <<EOF
mkdir -p '$ue_workdir_t'
cd '$ue_workdir_t'
sudo -n ip netns del '$ue_netns' 2>/dev/null || true
sudo -n ip link del 'vh-$ue_netns' 2>/dev/null || true
sudo -n ip netns add '$ue_netns'
sudo -n ip link add 'vh-$ue_netns' type veth peer name 'vp-$ue_netns'
sudo -n ip link set 'vp-$ue_netns' netns '$ue_netns'
sudo -n ip addr add '$ue_veth_host_ip_t/30' dev 'vh-$ue_netns'
sudo -n ip link set 'vh-$ue_netns' up
sudo -n ip netns exec '$ue_netns' ip addr add '$ue_veth_ns_ip_t/30' dev 'vp-$ue_netns'
sudo -n ip netns exec '$ue_netns' ip link set 'vp-$ue_netns' up
sudo -n ip netns exec '$ue_netns' ip link set lo up
sudo -n ip netns exec '$ue_netns' '$UE_BIN_RESOLVED' -O '$ue_oai_config_t' $OAI_UE_EXTRA_ARGS
EOF
        )"
      else
        ue_command="$(
          cat <<EOF
mkdir -p '$ue_workdir_t'
cd '$ue_workdir_t'
sudo -n ip netns del '$ue_netns' 2>/dev/null || true
sudo -n ip netns add '$ue_netns'
sudo -n ip netns exec '$ue_netns' '$UE_BIN_RESOLVED' -O '$ue_oai_config_t' $OAI_UE_EXTRA_ARGS
EOF
        )"
      fi
    else
      ue_command="$(
        cat <<EOF
cd '$WORKDIR'
sudo -n ip netns del '$ue_netns' 2>/dev/null || true
sudo -n ip netns add '$ue_netns'
sudo -n '$UE_BIN_RESOLVED' '$ue_config'
EOF
      )"
    fi
    open_terminal "$ue_title" "$ue_command"
  done

  open_terminal "Metrics Collector" "$collector_command"

  if [[ "$API_ENABLED" == "1" ]]; then
    open_terminal "Metrics API" "$api_command"
  fi

  if [[ "$DASHBOARD_ENABLED" == "1" ]]; then
    open_terminal "Metrics Dashboard" "$dashboard_command"
    if [[ "$API_ENABLED" == "1" ]]; then
      terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 3))
    else
      terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 2))
    fi
  else
    if [[ "$API_ENABLED" == "1" ]]; then
      terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 2))
    else
      terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 1))
    fi
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run complete."
    return
  fi

  echo "Opened $terminal_count terminals from: $WORKDIR"
  echo "Sudo credentials were cached up front, so those terminals should not prompt again unless the sudo ticket expires."
  run_health_checks "$start_line"
}

show_supervised_status() {
  local status_target
  local -a status_user_units=()

  require_sudo_session

  echo "Core service status:"
  sudo -n systemctl --no-pager --full status open5gs-amfd open5gs-smfd open5gs-upfd || true
  echo
  echo "Root unit status:"
  if [[ ${#ROOT_UNIT_NAMES[@]} -gt 0 ]]; then
    sudo -n systemctl --no-pager --full status "${ROOT_UNIT_NAMES[@]}" || true
  else
    echo "No root runtime units configured."
  fi
  echo
  echo "User unit status:"
  collect_known_user_units USER_UNIT_NAMES status_user_units
  if [[ ${#status_user_units[@]} -gt 0 ]]; then
    systemctl --user --no-pager --full status "${status_user_units[@]}" || true
  else
    echo "No user runtime units currently loaded."
  fi

  status_target="$(join_by ', ' "${UE_NETNS_LIST[@]}")"
  echo
  echo "Expected UE namespaces: ${status_target}"
}

show_component_logs() {
  local target="$1"
  local unit

  case "$target" in
    core)
      require_sudo_session
      exec sudo -n tail -f "$CORE_AMF_LOG_PATH"
      ;;
    collector)
      exec journalctl --user -u "$(user_unit_name "metrics-collector")" -f
      ;;
    api)
      exec journalctl --user -u "$(user_unit_name "metrics-api")" -f
      ;;
    dashboard)
      exec journalctl --user -u "$(user_unit_name "dashboard")" -f
      ;;
    *)
      if [[ -n "${COMPONENT_ROOT_UNITS[$target]:-}" ]]; then
        require_sudo_session
        unit="${COMPONENT_ROOT_UNITS[$target]}"
        exec sudo -n journalctl -u "$unit" -f
      fi
      echo "Unknown log target: $target" >&2
      echo "Use one of: core, collector, api, dashboard, $(join_by ', ' "${COMPONENT_KEYS[@]}")" >&2
      exit 1
      ;;
  esac
}

require_command sudo
require_command systemctl
require_command systemd-run
require_command ps
require_command ip
require_command ss

if [[ ! -d "$WORKDIR" ]]; then
  echo "Workdir does not exist: $WORKDIR" >&2
  exit 1
fi

WORKDIR="$(cd -- "$WORKDIR" && pwd)"
VENV_DIR="${VENV_DIR:-$WORKDIR/.venv}"

PYTHON_BIN_RESOLVED="$(resolve_executable "$PYTHON_BIN")"
GNB_BIN_RESOLVED="$(resolve_executable "$GNB_BIN")"
UE_BIN_RESOLVED="$(resolve_executable "$UE_BIN")"

REQUIREMENTS_FILE_PATH="$(resolve_path "$WORKDIR" "$REQUIREMENTS_FILE")"
METRICS_SCRIPT_PATH="$(resolve_path "$WORKDIR" "$METRICS_SCRIPT")"
DASHBOARD_SCRIPT_PATH="$(resolve_path "$WORKDIR" "$DASHBOARD_SCRIPT")"
API_SCRIPT_PATH="$(resolve_path "$WORKDIR" "$API_SCRIPT")"
METRICS_SOURCES_CONFIG_PATH="$(resolve_path "$WORKDIR" "$METRICS_SOURCES_CONFIG")"
METRICS_OUT_PATH="$(resolve_path "$WORKDIR" "$METRICS_OUT")"
METRICS_AGENT_OUT_PATH="$(resolve_path "$WORKDIR" "$METRICS_AGENT_OUT")"
VENV_DIR_PATH="$(resolve_path "$WORKDIR" "$VENV_DIR")"
REPO_ROOT_PATH="$(cd -- "$(dirname -- "$METRICS_SOURCES_CONFIG_PATH")/.." && pwd)"

require_file "Requirements file" "$REQUIREMENTS_FILE_PATH"
require_file "Metrics collector" "$METRICS_SCRIPT_PATH"
require_file "Dashboard script" "$DASHBOARD_SCRIPT_PATH"
require_file "Metrics REST API script" "$API_SCRIPT_PATH"
require_file "Metrics sources config" "$METRICS_SOURCES_CONFIG_PATH"

resolve_config_list "$WORKDIR" "$GNB_CONFIGS" GNB_CONFIG_PATHS
resolve_config_list "$WORKDIR" "$UE_CONFIGS" UE_CONFIG_PATHS
mapfile -t METRICS_SOURCE_IDS < <(read_metrics_source_ids)

if [[ ${#GNB_CONFIG_PATHS[@]} -eq 0 ]]; then
  echo "No gNB configs were provided." >&2
  exit 1
fi

if [[ ${#UE_CONFIG_PATHS[@]} -eq 0 ]]; then
  echo "No UE configs were provided." >&2
  exit 1
fi

for config_path in "${GNB_CONFIG_PATHS[@]}"; do
  require_file "gNB config" "$config_path"
done

for config_path in "${UE_CONFIG_PATHS[@]}"; do
  require_file "UE config" "$config_path"
done

if [[ ${#METRICS_SOURCE_IDS[@]} -eq 0 ]]; then
  echo "No metrics sources were found in: $METRICS_SOURCES_CONFIG_PATH" >&2
  exit 1
fi

UE_NETNS_LIST=()
ROOT_UNIT_NAMES=()
UE_ROOT_UNIT_NAMES=()
USER_UNIT_NAMES=(
  "$(user_unit_name "metrics-collector")"
  "$(user_unit_name "metrics-api")"
  "$(user_unit_name "dashboard")"
)
HEALTHCHECK_ROOT_UNITS=()
HEALTHCHECK_USER_UNITS=()
HEALTHCHECK_START_EPOCH=0
HEALTHCHECK_AMF_LOG_START_LINE=0
HEALTHCHECK_SMF_LOG_START_LINE=0
HEALTHCHECK_UPF_LOG_START_LINE=0
declare -A UE_NETNS_DEVICE_MAP=()
declare -A COMPONENT_ROOT_UNITS=()
COMPONENT_KEYS=()

for gnb_config in "${GNB_CONFIG_PATHS[@]}"; do
  gnb_label="$(config_label "$gnb_config")"
  gnb_unit="$(root_unit_name "gnb-$gnb_label")"
  ROOT_UNIT_NAMES+=("$gnb_unit")
  COMPONENT_ROOT_UNITS["$gnb_label"]="$gnb_unit"
  COMPONENT_KEYS+=("$gnb_label")
done

for ue_config in "${UE_CONFIG_PATHS[@]}"; do
  ue_label="$(config_label "$ue_config")"
  ue_unit="$(root_unit_name "ue-$ue_label")"
  ue_netns="$(read_netns "$ue_config")"
  ue_device="$(read_ip_devname "$ue_config")"
  if [[ -z "$ue_netns" ]]; then
    echo "Could not determine netns from UE config: $ue_config" >&2
    exit 1
  fi
  if [[ -z "$ue_device" ]]; then
    echo "Could not determine ip_devname from UE config: $ue_config" >&2
    exit 1
  fi
  ROOT_UNIT_NAMES+=("$ue_unit")
  UE_ROOT_UNIT_NAMES+=("$ue_unit")
  COMPONENT_ROOT_UNITS["$ue_label"]="$ue_unit"
  COMPONENT_KEYS+=("$ue_label")
  UE_NETNS_LIST+=("$ue_netns")
  UE_NETNS_DEVICE_MAP["$ue_netns"]="$ue_device"
done

if [[ "$MODE" != "supervised" && "$MODE" != "terminals" ]]; then
  echo "Unsupported mode: $MODE" >&2
  echo "Supported modes: supervised, terminals" >&2
  exit 1
fi

case "$ACTION" in
  start)
    if [[ "$MODE" == "supervised" ]]; then
      start_supervised_stack
    else
      start_terminal_stack
    fi
    ;;
  stop)
    stop_supervised_stack
    cleanup_stale_lab_processes
    ;;
  status)
    show_supervised_status
    ;;
  logs)
    if [[ -z "$LOG_TARGET" ]]; then
      echo "--logs requires a component name." >&2
      exit 1
    fi
    show_component_logs "$LOG_TARGET"
    ;;
  *)
    echo "Unsupported action: $ACTION" >&2
    exit 1
    ;;
esac
