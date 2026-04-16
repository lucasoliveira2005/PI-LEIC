#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"

ACTION="start"
MODE="${MODE:-supervised}"
LOG_TARGET=""
DRY_RUN="${DRY_RUN:-0}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-$SCRIPT_DIR/../requirements.txt}"
METRICS_SCRIPT="${METRICS_SCRIPT:-metrics_collector.py}"
DASHBOARD_SCRIPT="${DASHBOARD_SCRIPT:-dashboard.py}"
API_SCRIPT="${API_SCRIPT:-metrics_rest_api.py}"
METRICS_SOURCES_CONFIG="${METRICS_SOURCES_CONFIG:-$SCRIPT_DIR/../config/metrics_sources.json}"
METRICS_OUT="${METRICS_OUT:-$SCRIPT_DIR/../metrics/gnb_metrics.jsonl}"
METRICS_LOG_INCLUDE_ROTATED="${METRICS_LOG_INCLUDE_ROTATED:-1}"
METRICS_LOG_MAX_ARCHIVES="${METRICS_LOG_MAX_ARCHIVES:-5}"
METRICS_SQLITE_ENABLED="${METRICS_SQLITE_ENABLED:-1}"
METRICS_SQLITE_PATH="${METRICS_SQLITE_PATH:-/tmp/pi-leic-metrics.sqlite}"
METRICS_TRANSPORT_BACKEND="${METRICS_TRANSPORT_BACKEND:-websocket}"
FRESHNESS_CHECK_MODE="${FRESHNESS_CHECK_MODE:-hybrid}"
FRESHNESS_AGE_WINDOW_SECONDS="${FRESHNESS_AGE_WINDOW_SECONDS:-15}"
FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS="${FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS:-2}"
GNB_BIN="${GNB_BIN:-gnb}"
UE_BIN="${UE_BIN:-srsue}"
GNB_CONFIGS="${GNB_CONFIGS:-$SCRIPT_DIR/../config/gnb_gnb1_zmq.yaml:$SCRIPT_DIR/../config/gnb_gnb2_zmq.yaml}"
UE_CONFIGS="${UE_CONFIGS:-$SCRIPT_DIR/../config/ue1_zmq.conf.txt:$SCRIPT_DIR/../config/ue2_zmq.conf.txt}"
MPLCONFIGDIR_PATH="${MPLCONFIGDIR_PATH:-/tmp/pi-leic-matplotlib}"
DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-1}"
API_ENABLED="${API_ENABLED:-1}"
API_HOST="${API_HOST:-0.0.0.0}"
API_PORT="${API_PORT:-8000}"
HEALTHCHECK_ENABLED="${HEALTHCHECK_ENABLED:-1}"
HEALTHCHECK_STRICT="${HEALTHCHECK_STRICT:-0}"
HEALTHCHECK_REQUIRE_UE_DATA_PATH="${HEALTHCHECK_REQUIRE_UE_DATA_PATH:-1}"
HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS="${HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS:-1}"
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
  WORKDIR, MODE, PYTHON_BIN, VENV_DIR, REQUIREMENTS_FILE, METRICS_SCRIPT, DASHBOARD_SCRIPT, API_SCRIPT
  METRICS_SOURCES_CONFIG, METRICS_OUT, GNB_BIN, UE_BIN, GNB_CONFIGS, UE_CONFIGS
  METRICS_LOG_INCLUDE_ROTATED, METRICS_LOG_MAX_ARCHIVES
  METRICS_SQLITE_ENABLED, METRICS_SQLITE_PATH, METRICS_TRANSPORT_BACKEND
  FRESHNESS_CHECK_MODE, FRESHNESS_AGE_WINDOW_SECONDS
  FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS
  DASHBOARD_ENABLED, API_ENABLED, API_HOST, API_PORT
  HEALTHCHECK_ENABLED, HEALTHCHECK_STRICT
  HEALTHCHECK_REQUIRE_UE_DATA_PATH, HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS
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

  root_file_line_count "$CORE_UPF_LOG_PATH"
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
  local ue_script
  local start_line
  local amf_log_start_line
  local smf_log_start_line
  local upf_log_start_line
  local -a collector_args
  local -a api_args
  local -a dashboard_args

  if [[ "$DRY_RUN" != "1" ]]; then
    require_sudo_session
    prepare_python_env
  fi

  stop_supervised_stack 1
  cleanup_stale_lab_processes
  start_line="$(metrics_line_count)"

  upf_log_start_line="$(prepare_healthcheck_baseline_and_markers)"
  amf_log_start_line="$HEALTHCHECK_AMF_LOG_START_LINE"
  smf_log_start_line="$HEALTHCHECK_SMF_LOG_START_LINE"
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
    "--setenv=METRICS_SOURCES_CONFIG=$METRICS_SOURCES_CONFIG_PATH"
    "--setenv=METRICS_OUT=$METRICS_OUT_PATH"
    "--setenv=METRICS_SQLITE_ENABLED=$METRICS_SQLITE_ENABLED"
    "--setenv=METRICS_SQLITE_PATH=$METRICS_SQLITE_PATH"
    "--setenv=METRICS_TRANSPORT_BACKEND=$METRICS_TRANSPORT_BACKEND"
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
      "--setenv=METRICS_INGESTION_TRANSPORT=$METRICS_TRANSPORT_BACKEND"
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
    append_env_arg_if_set api_args METRICS_INGESTION_TRANSPORT
    append_env_arg_if_set api_args D1_TARGET_TRANSPORT
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
    start_root_unit \
      "$(root_unit_name "gnb-$gnb_label")" \
      "PI-LEIC gNB $gnb_label" \
      "$GNB_BIN_RESOLVED" -c "$gnb_config"
  done

  for ue_config in "${UE_CONFIG_PATHS[@]}"; do
    ue_label="$(config_label "$ue_config")"
    ue_netns="$(read_netns "$ue_config")"
    printf -v ue_script \
      'ip netns del %q 2>/dev/null || true; ip netns add %q; exec %q %q' \
      "$ue_netns" \
      "$ue_netns" \
      "$UE_BIN_RESOLVED" \
      "$ue_config"
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
export METRICS_SOURCES_CONFIG='$METRICS_SOURCES_CONFIG_PATH'
export METRICS_OUT='$METRICS_OUT_PATH'
export METRICS_SQLITE_ENABLED='$METRICS_SQLITE_ENABLED'
export METRICS_SQLITE_PATH='$METRICS_SQLITE_PATH'
export METRICS_TRANSPORT_BACKEND='$METRICS_TRANSPORT_BACKEND'
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
export METRICS_INGESTION_TRANSPORT='$METRICS_TRANSPORT_BACKEND'
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
    gnb_command="$(
      cat <<EOF
cd '$WORKDIR'
sudo -n '$GNB_BIN_RESOLVED' -c '$gnb_config'
EOF
    )"
    open_terminal "$gnb_title" "$gnb_command"
  done

  for ue_config in "${UE_CONFIG_PATHS[@]}"; do
    ue_title="UE $(config_label "$ue_config")"
    ue_netns="$(read_netns "$ue_config")"

    ue_command="$(
      cat <<EOF
cd '$WORKDIR'
sudo -n ip netns del '$ue_netns' 2>/dev/null || true
sudo -n ip netns add '$ue_netns'
sudo -n '$UE_BIN_RESOLVED' '$ue_config'
EOF
    )"
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
