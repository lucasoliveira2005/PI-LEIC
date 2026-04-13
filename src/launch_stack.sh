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
METRICS_SOURCES_CONFIG="${METRICS_SOURCES_CONFIG:-$SCRIPT_DIR/../config/metrics_sources.json}"
METRICS_OUT="${METRICS_OUT:-$SCRIPT_DIR/../metrics/gnb_metrics.jsonl}"
GNB_BIN="${GNB_BIN:-gnb}"
UE_BIN="${UE_BIN:-srsue}"
GNB_CONFIGS="${GNB_CONFIGS:-$SCRIPT_DIR/../config/gnb_gnb1_zmq.yaml:$SCRIPT_DIR/../config/gnb_gnb2_zmq.yaml}"
UE_CONFIGS="${UE_CONFIGS:-$SCRIPT_DIR/../config/ue1_zmq.conf.txt:$SCRIPT_DIR/../config/ue2_zmq.conf.txt}"
MPLCONFIGDIR_PATH="${MPLCONFIGDIR_PATH:-/tmp/pi-leic-matplotlib}"
DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-1}"
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

usage() {
  cat <<EOF
Usage: ./launch_stack.sh [--mode MODE] [--workdir PATH] [--dry-run] [--stop] [--status] [--logs COMPONENT]

Actions:
  start (default)  Start the stage.
  --stop           Stop supervised units and remove UE namespaces.
  --status         Show core and supervised unit status.
  --logs NAME      Follow logs for one component. Examples: core, collector, dashboard, gnb1, ue1

Options:
  --mode MODE      Launch mode: supervised (default) or terminals.
  --workdir PATH   Linux path where the Python scripts live.
  --dry-run        Print the commands instead of starting anything.
  --help           Show this message.

Environment overrides:
  WORKDIR, MODE, PYTHON_BIN, VENV_DIR, REQUIREMENTS_FILE, METRICS_SCRIPT, DASHBOARD_SCRIPT
  METRICS_SOURCES_CONFIG, METRICS_OUT, GNB_BIN, UE_BIN, GNB_CONFIGS, UE_CONFIGS
  DASHBOARD_ENABLED, HEALTHCHECK_ENABLED, HEALTHCHECK_STRICT
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

resolve_path() {
  local base="$1"
  local path="$2"

  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "$base/$path"
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

join_by() {
  local separator="$1"
  shift

  if [[ $# -eq 0 ]]; then
    return 0
  fi

  local first="$1"
  shift

  printf '%s' "$first"
  for item in "$@"; do
    printf '%s%s' "$separator" "$item"
  done
}

resolve_config_list() {
  local base="$1"
  local raw_list="$2"
  local -n output_ref="$3"
  local item

  IFS=':' read -r -a output_ref <<< "$raw_list"
  for item in "${!output_ref[@]}"; do
    output_ref[$item]="$(resolve_path "$base" "${output_ref[$item]}")"
  done
}

read_netns() {
  local config_path="$1"

  awk -F '=' '
    /^[[:space:]]*netns[[:space:]]*=/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$config_path"
}

read_ip_devname() {
  local config_path="$1"

  awk -F '=' '
    /^[[:space:]]*ip_devname[[:space:]]*=/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      print $2
      exit
    }
  ' "$config_path"
}

config_label() {
  local label

  label="$(basename -- "$1")"
  label="${label%.yaml}"
  label="${label%.conf.txt}"
  label="${label#gnb_}"
  label="${label%_zmq}"
  printf '%s\n' "$label"
}

root_unit_name() {
  printf '%s\n' "${UNIT_PREFIX}-$1.service"
}

user_unit_name() {
  printf '%s\n' "${UNIT_PREFIX}-$1.service"
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
  if [[ -f "$METRICS_OUT_PATH" ]]; then
    wc -l < "$METRICS_OUT_PATH"
  else
    echo 0
  fi
}

root_file_line_count() {
  local path="$1"
  local line_count

  if ! sudo -n test -f "$path" >/dev/null 2>&1; then
    echo 0
    return
  fi

  line_count="$(sudo -n wc -l -- "$path" 2>/dev/null | awk '{print $1}' || true)"
  if [[ "$line_count" =~ ^[0-9]+$ ]]; then
    echo "$line_count"
  else
    echo 0
  fi
}

root_file_contains_pattern_since_line() {
  local path="$1"
  local start_line="$2"
  local regex="$3"

  [[ -n "$regex" ]] || return 1
  if ! sudo -n test -f "$path" >/dev/null 2>&1; then
    return 1
  fi

  sudo -n tail -n "+$((start_line + 1))" "$path" 2>/dev/null \
    | grep -E -i "$regex" >/dev/null 2>&1
}

root_file_first_match_since_line() {
  local path="$1"
  local start_line="$2"
  local regex="$3"

  [[ -n "$regex" ]] || return 0
  if ! sudo -n test -f "$path" >/dev/null 2>&1; then
    return 0
  fi

  sudo -n tail -n "+$((start_line + 1))" "$path" 2>/dev/null \
    | grep -E -i -m 1 "$regex" || true
}

root_unit_first_match_since_epoch() {
  local unit="$1"
  local since_epoch="$2"
  local regex="$3"

  [[ -n "$regex" ]] || return 0
  sudo -n journalctl -u "$unit" --since "@$since_epoch" --no-pager -o cat 2>/dev/null \
    | grep -E -i -m 1 "$regex" || true
}

socket_snapshot_has_process_tcp_listener() {
  local snapshot="$1"
  local process_name="$2"

  awk -v process_name="$process_name" '
    $1 ~ /^tcp/ && index($0, process_name) {
      found = 1
      exit
    }
    END {
      exit(found ? 0 : 1)
    }
  ' <<< "$snapshot"
}

socket_snapshot_has_process_udp_port() {
  local snapshot="$1"
  local process_name="$2"
  local port="$3"

  awk -v process_name="$process_name" -v port="$port" '
    $1 ~ /^udp/ && index($0, process_name) && ($5 ~ ":" port "$" || $5 ~ "\\]:" port "$") {
      found = 1
      exit
    }
    END {
      exit(found ? 0 : 1)
    }
  ' <<< "$snapshot"
}

collect_core_socket_probe_failures() {
  local snapshot="$1"
  local -n failures_ref="$2"

  failures_ref=()

  if ! socket_snapshot_has_process_tcp_listener "$snapshot" "open5gs-amfd"; then
    failures_ref+=("open5gs-amfd missing tcp listener")
  fi
  if ! socket_snapshot_has_process_tcp_listener "$snapshot" "open5gs-smfd"; then
    failures_ref+=("open5gs-smfd missing tcp listener")
  fi
  if ! socket_snapshot_has_process_udp_port "$snapshot" "open5gs-smfd" "$CORE_PROBE_SMF_PFCP_PORT"; then
    failures_ref+=("open5gs-smfd missing udp:${CORE_PROBE_SMF_PFCP_PORT}")
  fi
  if ! socket_snapshot_has_process_udp_port "$snapshot" "open5gs-upfd" "$CORE_PROBE_UPF_PFCP_PORT"; then
    failures_ref+=("open5gs-upfd missing udp:${CORE_PROBE_UPF_PFCP_PORT}")
  fi
  if ! socket_snapshot_has_process_udp_port "$snapshot" "open5gs-upfd" "$CORE_PROBE_UPF_GTPU_PORT"; then
    failures_ref+=("open5gs-upfd missing udp:${CORE_PROBE_UPF_GTPU_PORT}")
  fi

  [[ ${#failures_ref[@]} -gt 0 ]]
}

first_tcp_listener_endpoint_for_process() {
  local snapshot="$1"
  local process_name="$2"

  awk -v process_name="$process_name" '
    $1 ~ /^tcp/ && index($0, process_name) {
      split($5, parts, ":")
      port = parts[length(parts)]
      host = substr($5, 1, length($5) - length(port) - 1)

      if (host == "*" || host == "0.0.0.0") {
        host = "127.0.0.1"
      }

      if (host ~ /\[/ || host ~ /:/) {
        next
      }

      print host ":" port
      exit
    }
  ' <<< "$snapshot"
}

tcp_endpoint_probe_ok() {
  local endpoint="$1"
  local host="${endpoint%:*}"
  local port="${endpoint##*:}"

  [[ -n "$host" && -n "$port" ]] || return 1

  timeout "$CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS" \
    bash -c ": </dev/tcp/${host}/${port}" >/dev/null 2>&1
}

collect_core_endpoint_probe_failures() {
  local snapshot="$1"
  local -n failures_ref="$2"
  local endpoint

  failures_ref=()

  endpoint="$(first_tcp_listener_endpoint_for_process "$snapshot" "open5gs-amfd")"
  if [[ -z "$endpoint" ]]; then
    failures_ref+=("open5gs-amfd missing active endpoint")
  elif ! tcp_endpoint_probe_ok "$endpoint"; then
    failures_ref+=("open5gs-amfd endpoint probe failed: ${endpoint}")
  fi

  endpoint="$(first_tcp_listener_endpoint_for_process "$snapshot" "open5gs-smfd")"
  if [[ -z "$endpoint" ]]; then
    failures_ref+=("open5gs-smfd missing active endpoint")
  elif ! tcp_endpoint_probe_ok "$endpoint"; then
    failures_ref+=("open5gs-smfd endpoint probe failed: ${endpoint}")
  fi

  [[ ${#failures_ref[@]} -gt 0 ]]
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

metrics_source_seen_since() {
  local start_line="$1"
  local source_id="$2"

  [[ -f "$METRICS_OUT_PATH" ]] || return 1

  tail -n +"$((start_line + 1))" "$METRICS_OUT_PATH" | grep -F "\"source_id\": \"$source_id\"" >/dev/null 2>&1
}

metrics_attach_seen_since() {
  local start_line="$1"
  local source_id="$2"

  [[ -f "$METRICS_OUT_PATH" ]] || return 1

  tail -n +"$((start_line + 1))" "$METRICS_OUT_PATH" \
    | grep -F "\"source_id\": \"$source_id\"" \
    | grep -F '"metric_family": "cells"' \
    | grep -F '"rnti":' >/dev/null 2>&1
}

prepare_python_env() {
  mkdir -p "$(dirname -- "$METRICS_OUT_PATH")"
  mkdir -p "$MPLCONFIGDIR_PATH"

  if [[ ! -d "$VENV_DIR_PATH" ]]; then
    "$PYTHON_BIN_RESOLVED" -m venv "$VENV_DIR_PATH"
  fi

  if ! "$VENV_DIR_PATH/bin/python" -c 'import matplotlib, websocket' >/dev/null 2>&1; then
    "$VENV_DIR_PATH/bin/python" -m pip install -r "$REQUIREMENTS_FILE_PATH"
  fi
}

start_sudo_keepalive() {
  (
    while true; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep "$SUDO_KEEPALIVE_INTERVAL_SECONDS"
    done
  ) &
  SUDO_KEEPALIVE_PID="$!"
}

require_sudo_session() {
  sudo -v
  if [[ -z "$SUDO_KEEPALIVE_PID" ]]; then
    start_sudo_keepalive
  fi
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
  local comm="$1"
  local needle="$2"

  ps -eo pid=,comm=,args= | awk -v comm="$comm" -v needle="$needle" '
    $2 == comm && index($0, needle) {
      print $1
    }
  '
}

find_pids_by_needle() {
  local needle="$1"

  ps -eo pid=,args= | awk -v needle="$needle" '
    index($0, needle) {
      print $1
    }
  '
}

find_python_pids_by_needle() {
  local needle="$1"

  ps -eo pid=,comm=,args= | awk -v needle="$needle" '
    $2 ~ /^python([0-9.]*)?$/ && index($0, needle) {
      print $1
    }
  '
}

kill_matching_pids() {
  local label="$1"
  shift
  local -a pids=("$@")

  if [[ ${#pids[@]} -eq 0 ]]; then
    return 0
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Would terminate stale ${label} processes: $(join_by ', ' "${pids[@]}")"
    return 0
  fi

  echo "Terminating stale ${label} processes: $(join_by ', ' "${pids[@]}")"
  sudo -n kill "${pids[@]}" >/dev/null 2>&1 || true
  sleep 1
  sudo -n kill -9 "${pids[@]}" >/dev/null 2>&1 || true
}

kill_processes_for_comm_and_needles() {
  local label="$1"
  local comm="$2"
  shift 2
  local needle
  local pid
  local -A pid_set=()
  local -a pids=()

  for needle in "$@"; do
    [[ -n "$needle" ]] || continue
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      pid_set["$pid"]=1
    done < <(find_pids_by_comm_and_needle "$comm" "$needle")
  done

  for pid in "${!pid_set[@]}"; do
    pids+=("$pid")
  done

  kill_matching_pids "$label" "${pids[@]}"
}

kill_python_processes_for_needles() {
  local label="$1"
  shift
  local needle
  local pid
  local -A pid_set=()
  local -a pids=()

  for needle in "$@"; do
    [[ -n "$needle" ]] || continue
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      pid_set["$pid"]=1
    done < <(find_python_pids_by_needle "$needle")
  done

  for pid in "${!pid_set[@]}"; do
    pids+=("$pid")
  done

  kill_matching_pids "$label" "${pids[@]}"
}

cleanup_stale_lab_processes() {
  local gnb_config
  local ue_config
  local gnb_label
  local ue_label
  local gnb_config_rel=""
  local ue_config_rel=""
  local metrics_script_rel=""
  local dashboard_script_rel=""
  local gnb_comm
  local ue_comm

  gnb_comm="$(basename -- "$GNB_BIN_RESOLVED")"
  ue_comm="$(basename -- "$UE_BIN_RESOLVED")"

  if [[ "$METRICS_SCRIPT_PATH" == "$REPO_ROOT_PATH/"* ]]; then
    metrics_script_rel="${METRICS_SCRIPT_PATH#$REPO_ROOT_PATH/}"
  fi
  if [[ "$DASHBOARD_SCRIPT_PATH" == "$REPO_ROOT_PATH/"* ]]; then
    dashboard_script_rel="${DASHBOARD_SCRIPT_PATH#$REPO_ROOT_PATH/}"
  fi

  for gnb_config in "${GNB_CONFIG_PATHS[@]}"; do
    gnb_label="$(config_label "$gnb_config")"
    if [[ "$gnb_config" == "$REPO_ROOT_PATH/"* ]]; then
      gnb_config_rel="${gnb_config#$REPO_ROOT_PATH/}"
    else
      gnb_config_rel=""
    fi
    kill_processes_for_comm_and_needles \
      "gNB ${gnb_label}" \
      "$gnb_comm" \
      "$gnb_config" \
      "$gnb_config_rel" \
      "$(basename -- "$gnb_config")"
  done

  for ue_config in "${UE_CONFIG_PATHS[@]}"; do
    ue_label="$(config_label "$ue_config")"
    if [[ "$ue_config" == "$REPO_ROOT_PATH/"* ]]; then
      ue_config_rel="${ue_config#$REPO_ROOT_PATH/}"
    else
      ue_config_rel=""
    fi
    kill_processes_for_comm_and_needles \
      "UE ${ue_label}" \
      "$ue_comm" \
      "$ue_config" \
      "$ue_config_rel" \
      "$(basename -- "$ue_config")"
  done

  kill_python_processes_for_needles \
    "metrics collector" \
    "$METRICS_SCRIPT_PATH" \
    "$metrics_script_rel"

  if [[ "$DASHBOARD_ENABLED" == "1" ]]; then
    kill_python_processes_for_needles \
      "dashboard" \
      "$DASHBOARD_SCRIPT_PATH" \
      "$dashboard_script_rel"
  fi
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
  local amf_start_line="$1"
  local smf_start_line="$2"
  local upf_start_line="$3"
  local deadline=$((SECONDS + CORE_READINESS_TIMEOUT_SECONDS))
  local marker_checks_enabled="$CORE_READINESS_REQUIRE_LOG_MARKERS"
  local smf_amf_assoc_checks_enabled="$CORE_READINESS_REQUIRE_SMF_AMF_ASSOCIATION"
  local socket_probe_checks_enabled="$CORE_READINESS_REQUIRE_SOCKET_PROBES"
  local endpoint_probe_checks_enabled="$CORE_READINESS_REQUIRE_ACTIVE_ENDPOINT_PROBES"
  local stable_polls=0
  local -a inactive_units=()
  local -a missing_markers=()
  local -a missing_socket_probes=()
  local -a missing_endpoint_probes=()
  local unit
  local core_failure_line
  local socket_snapshot

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Would wait up to ${CORE_READINESS_TIMEOUT_SECONDS}s for dynamic Open5GS core readiness checks."
    return 0
  fi

  echo "Waiting up to ${CORE_READINESS_TIMEOUT_SECONDS}s for dynamic Open5GS core readiness..."

  if [[ "$marker_checks_enabled" == "1" ]]; then
    if ! sudo -n test -f "$CORE_AMF_LOG_PATH" >/dev/null 2>&1; then
      marker_checks_enabled=0
      echo "Core log marker checks disabled: missing $CORE_AMF_LOG_PATH"
    elif ! sudo -n test -f "$CORE_SMF_LOG_PATH" >/dev/null 2>&1; then
      marker_checks_enabled=0
      echo "Core log marker checks disabled: missing $CORE_SMF_LOG_PATH"
    elif ! sudo -n test -f "$CORE_UPF_LOG_PATH" >/dev/null 2>&1; then
      marker_checks_enabled=0
      echo "Core log marker checks disabled: missing $CORE_UPF_LOG_PATH"
    fi
  fi

  if [[ "$marker_checks_enabled" != "1" ]]; then
    smf_amf_assoc_checks_enabled=0
  fi

  if [[ "$socket_probe_checks_enabled" == "1" ]]; then
    if ! sudo -n ss -H -lntup -4 >/dev/null 2>&1; then
      socket_probe_checks_enabled=0
      echo "Core socket probes disabled: unable to inspect listening sockets with ss."
    fi
  fi

  if [[ "$endpoint_probe_checks_enabled" == "1" ]]; then
    if [[ "$socket_probe_checks_enabled" != "1" ]]; then
      endpoint_probe_checks_enabled=0
      echo "Active endpoint probes disabled: socket probes are unavailable."
    elif ! command -v timeout >/dev/null 2>&1; then
      endpoint_probe_checks_enabled=0
      echo "Active endpoint probes disabled: 'timeout' command is unavailable."
    fi
  fi

  while (( SECONDS < deadline )); do
    inactive_units=()
    missing_markers=()
    missing_socket_probes=()
    missing_endpoint_probes=()

    for unit in "${CORE_UNITS[@]}"; do
      if ! sudo -n systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        inactive_units+=("$unit")
      fi
    done

    if [[ "$marker_checks_enabled" == "1" ]]; then
      if ! root_file_contains_pattern_since_line "$CORE_AMF_LOG_PATH" "$amf_start_line" 'ngap_server|sbi_server'; then
        missing_markers+=("amf")
      fi
      if ! root_file_contains_pattern_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" 'pfcp_server|gtp_connect|sbi_server'; then
        missing_markers+=("smf")
      fi
      if [[ "$smf_amf_assoc_checks_enabled" == "1" ]] && ! root_file_contains_pattern_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" '\[AMF\] NFInstance associated|\[namf-comm\] NFService associated'; then
        missing_markers+=("smf-amf-association")
      fi
      if ! root_file_contains_pattern_since_line "$CORE_UPF_LOG_PATH" "$upf_start_line" 'pfcp_server|gtpu_server'; then
        missing_markers+=("upf")
      fi
    fi

    if [[ "$socket_probe_checks_enabled" == "1" ]]; then
      socket_snapshot="$(sudo -n ss -H -lntup -4 2>/dev/null || true)"
      collect_core_socket_probe_failures "$socket_snapshot" missing_socket_probes || true

      if [[ "$endpoint_probe_checks_enabled" == "1" ]]; then
        collect_core_endpoint_probe_failures "$socket_snapshot" missing_endpoint_probes || true
      fi
    fi

    core_failure_line="$(root_file_first_match_since_line "$CORE_AMF_LOG_PATH" "$amf_start_line" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
    if [[ -n "$core_failure_line" ]]; then
      echo "Detected control-plane failure signal while waiting for core readiness:"
      echo "  amf.log: ${core_failure_line}"
      return 1
    fi

    core_failure_line="$(root_file_first_match_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
    if [[ -n "$core_failure_line" ]]; then
      echo "Detected control-plane failure signal while waiting for core readiness:"
      echo "  smf.log: ${core_failure_line}"
      return 1
    fi

    if [[ ${#inactive_units[@]} -eq 0 && ${#missing_markers[@]} -eq 0 && ${#missing_socket_probes[@]} -eq 0 && ${#missing_endpoint_probes[@]} -eq 0 ]]; then
      stable_polls=$((stable_polls + 1))
    else
      stable_polls=0
    fi

    if (( stable_polls >= CORE_READINESS_STABLE_POLLS )); then
      echo "Core readiness checks passed."
      if [[ "$socket_probe_checks_enabled" == "1" ]]; then
        echo "Core socket probes passed for AMF/SMF/UPF listeners."
      fi
      if [[ "$endpoint_probe_checks_enabled" == "1" ]]; then
        echo "Active endpoint probes passed for AMF/SMF TCP listeners."
      fi
      return 0
    fi

    sleep "$CORE_READINESS_POLL_SECONDS"
  done

  echo "Timed out waiting for dynamic Open5GS core readiness."
  if [[ ${#inactive_units[@]} -gt 0 ]]; then
    echo "Inactive core units: $(join_by ', ' "${inactive_units[@]}")"
  fi
  if [[ "$marker_checks_enabled" == "1" && ${#missing_markers[@]} -gt 0 ]]; then
    echo "Missing startup markers in core logs: $(join_by ', ' "${missing_markers[@]}")"
  fi
  if [[ "$socket_probe_checks_enabled" == "1" && ${#missing_socket_probes[@]} -gt 0 ]]; then
    echo "Missing core socket probes: $(join_by ', ' "${missing_socket_probes[@]}")"
  fi
  if [[ "$endpoint_probe_checks_enabled" == "1" && ${#missing_endpoint_probes[@]} -gt 0 ]]; then
    echo "Failed active endpoint probes: $(join_by ', ' "${missing_endpoint_probes[@]}")"
  fi
  return 1
}

classify_attach_failure_line() {
  local line="$1"
  local line_lower

  line_lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"

  if [[ "$line_lower" == *"cannot discover"* || "$line_lower" == *"http response error [status:5"* || "$line_lower" == *"http response error [5"* ]]; then
    echo "core-discovery"
    return
  fi

  if [[ "$line_lower" == *"registration reject"* || "$line_lower" == *"attach reject"* ]]; then
    echo "registration-reject"
    return
  fi

  if [[ "$line_lower" == *"pdu session"* ]]; then
    if [[ "$line_lower" == *"reject"* || "$line_lower" == *"fail"* || "$line_lower" == *"error"* || "$line_lower" == *"release"* ]]; then
      echo "pdu-session"
      return
    fi
  fi

  if [[ "$line_lower" == *"rrc release"* ]]; then
    echo "rrc-release"
    return
  fi

  echo "unknown"
}

print_attach_failure_summary() {
  local -n failures_ref="$1"
  local entry
  local category
  local -A counts=()
  local -a ordered_categories=(
    "core-discovery"
    "registration-reject"
    "pdu-session"
    "rrc-release"
    "unknown"
  )

  for entry in "${failures_ref[@]}"; do
    category="${entry#[}"
    if [[ "$category" == "$entry" ]]; then
      category="unknown"
    else
      category="${category%%]*}"
    fi
    counts["$category"]=$(( ${counts["$category"]:-0} + 1 ))
  done

  echo "Attach/PDU failure category summary:"
  for category in "${ordered_categories[@]}"; do
    if [[ -n "${counts[$category]:-}" ]]; then
      echo "  ${category}: ${counts[$category]}"
      unset 'counts[$category]'
    fi
  done

  for category in "${!counts[@]}"; do
    echo "  ${category}: ${counts[$category]}"
  done
}

collect_attach_failure_signals_since() {
  local since_epoch="$1"
  local -n failures_ref="$2"
  local unit
  local failure_line
  local category

  failures_ref=()

  failure_line="$(root_file_first_match_since_line "$CORE_AMF_LOG_PATH" "$HEALTHCHECK_AMF_LOG_START_LINE" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
  if [[ -n "$failure_line" ]]; then
    category="$(classify_attach_failure_line "$failure_line")"
    failures_ref+=("[${category}] amf.log: $failure_line")
  fi

  failure_line="$(root_file_first_match_since_line "$CORE_SMF_LOG_PATH" "$HEALTHCHECK_SMF_LOG_START_LINE" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
  if [[ -n "$failure_line" ]]; then
    category="$(classify_attach_failure_line "$failure_line")"
    failures_ref+=("[${category}] smf.log: $failure_line")
  fi

  for unit in "${UE_ROOT_UNIT_NAMES[@]}"; do
    failure_line="$(root_unit_first_match_since_epoch "$unit" "$since_epoch" "$HEALTHCHECK_UE_FAILURE_REGEX")"
    if [[ -n "$failure_line" ]]; then
      category="$(classify_attach_failure_line "$failure_line")"
      failures_ref+=("[${category}] ${unit}: ${failure_line}")
    fi
  done

  [[ ${#failures_ref[@]} -gt 0 ]]
}

run_health_checks() {
  local start_line="$1"
  local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT_SECONDS))
  local require_ue_data_path="$HEALTHCHECK_REQUIRE_UE_DATA_PATH"
  local healthcheck_since_epoch="${HEALTHCHECK_START_EPOCH:-0}"
  local attach_failure_reported=0
  local -a missing_sources=()
  local -a missing_attach=()
  local -a missing_netns=()
  local -a missing_netdev_ipv4=()
  local -a missing_default_routes=()
  local -a inactive_root_units=()
  local -a inactive_user_units=()
  local -a attach_failure_signals=()
  local -a last_attach_failure_signals=()
  local source_id
  local ue_netns
  local ue_device
  local unit
  local checks_ready

  if [[ "$HEALTHCHECK_ENABLED" != "1" ]]; then
    return 0
  fi

  if [[ ! "$healthcheck_since_epoch" =~ ^[0-9]+$ ]]; then
    healthcheck_since_epoch="$(date +%s)"
  elif (( healthcheck_since_epoch <= 0 )); then
    healthcheck_since_epoch="$(date +%s)"
  fi

  echo "Running launch readiness checks for up to ${HEALTHCHECK_TIMEOUT_SECONDS}s..."

  while (( SECONDS < deadline )); do
    missing_sources=()
    missing_attach=()
    missing_netns=()
    missing_netdev_ipv4=()
    missing_default_routes=()
    inactive_root_units=()
    inactive_user_units=()

    for source_id in "${METRICS_SOURCE_IDS[@]}"; do
      if ! metrics_source_seen_since "$start_line" "$source_id"; then
        missing_sources+=("$source_id")
      fi
      if ! metrics_attach_seen_since "$start_line" "$source_id"; then
        missing_attach+=("$source_id")
      fi
    done

    for ue_netns in "${UE_NETNS_LIST[@]}"; do
      if ! netns_exists "$ue_netns"; then
        missing_netns+=("$ue_netns")
        continue
      fi

      ue_device="${UE_NETNS_DEVICE_MAP[$ue_netns]:-}"
      if ! netns_device_has_ipv4 "$ue_netns" "$ue_device"; then
        missing_netdev_ipv4+=("${ue_netns}:${ue_device}")
      fi
      if ! netns_has_default_route "$ue_netns"; then
        missing_default_routes+=("$ue_netns")
      fi
    done

    for unit in "${HEALTHCHECK_ROOT_UNITS[@]}"; do
      if ! sudo -n systemctl is-active --quiet "$unit" >/dev/null 2>&1; then
        inactive_root_units+=("$unit")
      fi
    done

    for unit in "${HEALTHCHECK_USER_UNITS[@]}"; do
      if ! systemctl --user is-active --quiet "$unit" >/dev/null 2>&1; then
        inactive_user_units+=("$unit")
      fi
    done

    if collect_attach_failure_signals_since "$healthcheck_since_epoch" attach_failure_signals; then
      last_attach_failure_signals=("${attach_failure_signals[@]}")
      if [[ "$attach_failure_reported" == "0" ]]; then
        echo "Detected attach/PDU failure signals while waiting for readiness:"
        for source_id in "${attach_failure_signals[@]}"; do
          echo "  ${source_id}"
        done
        print_attach_failure_summary last_attach_failure_signals
        attach_failure_reported=1
      fi

      if [[ "$HEALTHCHECK_FAIL_FAST_ON_ATTACH_ERRORS" == "1" ]]; then
        echo "Failing launch readiness early due to explicit attach/PDU failure signals."
        return 1
      fi
    fi

    checks_ready=1
    if [[ ${#missing_sources[@]} -gt 0 || ${#missing_attach[@]} -gt 0 || ${#missing_netns[@]} -gt 0 || ${#inactive_root_units[@]} -gt 0 || ${#inactive_user_units[@]} -gt 0 ]]; then
      checks_ready=0
    fi
    if [[ "$require_ue_data_path" == "1" && ( ${#missing_netdev_ipv4[@]} -gt 0 || ${#missing_default_routes[@]} -gt 0 ) ]]; then
      checks_ready=0
    fi

    if [[ "$checks_ready" == "1" ]]; then
      echo "Launch readiness checks passed."
      echo "Fresh metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
      echo "UE namespaces present: $(join_by ', ' "${UE_NETNS_LIST[@]}")"
      echo "Attach-like cells metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
      if [[ "$require_ue_data_path" == "1" ]]; then
        echo "UE namespace data path ready: $(join_by ', ' "${UE_NETNS_LIST[@]}")"
      else
        echo "UE namespace data path checks deferred (HEALTHCHECK_REQUIRE_UE_DATA_PATH=0)."
      fi
      if [[ ${#HEALTHCHECK_ROOT_UNITS[@]} -gt 0 ]]; then
        echo "Required supervised root units active: $(join_by ', ' "${HEALTHCHECK_ROOT_UNITS[@]}")"
      fi
      if [[ ${#HEALTHCHECK_USER_UNITS[@]} -gt 0 ]]; then
        echo "Required supervised user units active: $(join_by ', ' "${HEALTHCHECK_USER_UNITS[@]}")"
      fi
      return 0
    fi

    sleep "$HEALTHCHECK_POLL_SECONDS"
  done

  echo "Launch readiness checks completed with warnings."
  if [[ ${#missing_sources[@]} -gt 0 ]]; then
    echo "No fresh metrics observed from: $(join_by ', ' "${missing_sources[@]}")"
  fi
  if [[ ${#missing_attach[@]} -gt 0 ]]; then
    echo "No attach-like cells metrics observed from: $(join_by ', ' "${missing_attach[@]}")"
  fi
  if [[ ${#missing_netns[@]} -gt 0 ]]; then
    echo "Missing UE namespaces: $(join_by ', ' "${missing_netns[@]}")"
  fi
  if [[ "$require_ue_data_path" == "1" ]]; then
    if [[ ${#missing_netdev_ipv4[@]} -gt 0 ]]; then
      echo "UE namespaces missing IPv4 on configured tunnel device: $(join_by ', ' "${missing_netdev_ipv4[@]}")"
    fi
    if [[ ${#missing_default_routes[@]} -gt 0 ]]; then
      echo "UE namespaces missing default route: $(join_by ', ' "${missing_default_routes[@]}")"
    fi
  elif [[ ${#missing_netdev_ipv4[@]} -gt 0 || ${#missing_default_routes[@]} -gt 0 ]]; then
    echo "UE data-path checks were deferred in launch readiness (HEALTHCHECK_REQUIRE_UE_DATA_PATH=0)."
  fi
  if [[ ${#inactive_root_units[@]} -gt 0 ]]; then
    echo "Inactive or missing supervised root units: $(join_by ', ' "${inactive_root_units[@]}")"
  fi
  if [[ ${#inactive_user_units[@]} -gt 0 ]]; then
    echo "Inactive or missing supervised user units: $(join_by ', ' "${inactive_user_units[@]}")"
  fi
  if [[ "$attach_failure_reported" == "1" ]]; then
    echo "Attach/PDU failure signals were detected during readiness checks."
    if [[ ${#last_attach_failure_signals[@]} -gt 0 ]]; then
      print_attach_failure_summary last_attach_failure_signals
    fi
  fi
  echo "Use '$0 --status' or '$0 --logs <component>' to inspect the supervised stack."

  if [[ "$HEALTHCHECK_STRICT" == "1" ]]; then
    return 1
  fi
}

stop_user_unit_if_exists() {
  local unit="$1"
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
}

collect_known_user_units() {
  local -n source_ref="$1"
  local -n target_ref="$2"
  local unit
  local load_state

  target_ref=()
  for unit in "${source_ref[@]}"; do
    load_state="$(systemctl --user show "$unit" --property=LoadState --value 2>/dev/null || true)"
    if [[ -n "$load_state" && "$load_state" != "not-found" ]]; then
      target_ref+=("$unit")
    fi
  done
}

stop_root_unit_if_exists() {
  local unit="$1"
  sudo -n systemctl stop "$unit" >/dev/null 2>&1 || true
  sudo -n systemctl reset-failed "$unit" >/dev/null 2>&1 || true
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
  local unit="$1"
  local description="$2"
  shift 2

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[root unit %s]\nsudo -n systemd-run --unit=%q %q\n\n' "$unit" "$unit" "$(join_by ' ' "$@")"
    return
  fi

  sudo -n systemd-run \
    --quiet \
    --collect \
    --no-ask-password \
    --unit="$unit" \
    --description="$description" \
    --working-directory="$WORKDIR" \
    --property=Restart=on-failure \
    --property=RestartSec=2 \
    "$@" >/dev/null
}

start_user_unit() {
  local unit="$1"
  local description="$2"
  shift 2

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[user unit %s]\nsystemd-run --user --unit=%q %q\n\n' "$unit" "$unit" "$(join_by ' ' "$@")"
    return
  fi

  systemd-run \
    --user \
    --quiet \
    --collect \
    --unit="$unit" \
    --description="$description" \
    --working-directory="$WORKDIR" \
    --property=Restart=on-failure \
    --property=RestartSec=2 \
    "$@" >/dev/null
}

start_supervised_stack() {
  require_supervised_runtime_prereqs

  local collector_unit
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
  local -a dashboard_args

  if [[ "$DRY_RUN" != "1" ]]; then
    require_sudo_session
    prepare_python_env
  fi

  stop_supervised_stack 1
  cleanup_stale_lab_processes
  start_line="$(metrics_line_count)"
  HEALTHCHECK_START_EPOCH="$(date +%s)"
  HEALTHCHECK_AMF_LOG_START_LINE="$(root_file_line_count "$CORE_AMF_LOG_PATH")"
  amf_log_start_line="$HEALTHCHECK_AMF_LOG_START_LINE"
  smf_log_start_line="$(root_file_line_count "$CORE_SMF_LOG_PATH")"
  HEALTHCHECK_SMF_LOG_START_LINE="$smf_log_start_line"
  upf_log_start_line="$(root_file_line_count "$CORE_UPF_LOG_PATH")"
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
    "$VENV_DIR_PATH/bin/python"
    -u
    "$METRICS_SCRIPT_PATH"
  )
  start_user_unit "$collector_unit" "PI-LEIC Metrics Collector" "${collector_args[@]}"

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
  HEALTHCHECK_START_EPOCH="$(date +%s)"
  HEALTHCHECK_AMF_LOG_START_LINE="$(root_file_line_count "$CORE_AMF_LOG_PATH")"
  HEALTHCHECK_SMF_LOG_START_LINE="$(root_file_line_count "$CORE_SMF_LOG_PATH")"
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
'$VENV_DIR_PATH/bin/python' -u '$METRICS_SCRIPT_PATH'
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

  if [[ "$DASHBOARD_ENABLED" == "1" ]]; then
    open_terminal "Metrics Dashboard" "$dashboard_command"
    terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 2))
  else
    terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 1))
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
      echo "Use one of: core, collector, dashboard, $(join_by ', ' "${COMPONENT_KEYS[@]}")" >&2
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
METRICS_SOURCES_CONFIG_PATH="$(resolve_path "$WORKDIR" "$METRICS_SOURCES_CONFIG")"
METRICS_OUT_PATH="$(resolve_path "$WORKDIR" "$METRICS_OUT")"
VENV_DIR_PATH="$(resolve_path "$WORKDIR" "$VENV_DIR")"
REPO_ROOT_PATH="$(cd -- "$(dirname -- "$METRICS_SOURCES_CONFIG_PATH")/.." && pwd)"

require_file "Requirements file" "$REQUIREMENTS_FILE_PATH"
require_file "Metrics collector" "$METRICS_SCRIPT_PATH"
require_file "Dashboard script" "$DASHBOARD_SCRIPT_PATH"
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
