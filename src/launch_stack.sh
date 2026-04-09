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
HEALTHCHECK_TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-30}"
HEALTHCHECK_POLL_SECONDS="${HEALTHCHECK_POLL_SECONDS:-1}"
SUDO_KEEPALIVE_INTERVAL_SECONDS="${SUDO_KEEPALIVE_INTERVAL_SECONDS:-20}"
UNIT_PREFIX="${UNIT_PREFIX:-pi-leic}"

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
  HEALTHCHECK_TIMEOUT_SECONDS, HEALTHCHECK_POLL_SECONDS
  SUDO_KEEPALIVE_INTERVAL_SECONDS, UNIT_PREFIX

Notes:
  GNB_CONFIGS and UE_CONFIGS use colon-separated paths.
  Supervised mode prompts for sudo once, starts root components via systemd-run,
  and is the recommended mode for validation and repeatable runs.
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

netns_exists() {
  local netns_name="$1"
  ip netns list | awk '{print $1}' | grep -Fx "$netns_name" >/dev/null 2>&1
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

run_health_checks() {
  local start_line="$1"
  local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT_SECONDS))
  local -a missing_sources=()
  local -a missing_attach=()
  local -a missing_netns=()
  local source_id
  local ue_netns

  if [[ "$HEALTHCHECK_ENABLED" != "1" ]]; then
    return 0
  fi

  echo "Running launch readiness checks for up to ${HEALTHCHECK_TIMEOUT_SECONDS}s..."

  while (( SECONDS < deadline )); do
    missing_sources=()
    missing_attach=()
    missing_netns=()

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
      fi
    done

    if [[ ${#missing_sources[@]} -eq 0 && ${#missing_attach[@]} -eq 0 && ${#missing_netns[@]} -eq 0 ]]; then
      echo "Launch readiness checks passed."
      echo "Fresh metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
      echo "UE namespaces present: $(join_by ', ' "${UE_NETNS_LIST[@]}")"
      echo "Attach-like cells metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
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
  local collector_unit
  local dashboard_unit
  local gnb_config
  local ue_config
  local gnb_label
  local ue_label
  local ue_netns
  local ue_script
  local start_line
  local -a collector_args
  local -a dashboard_args

  if [[ "$DRY_RUN" != "1" ]]; then
    require_sudo_session
    prepare_python_env
  fi

  start_line="$(metrics_line_count)"
  stop_supervised_stack 1

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Would restart core services: $(join_by ' ' "${CORE_UNITS[@]}")"
  else
    sudo -n systemctl restart "${CORE_UNITS[@]}"
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
  echo "User units: $(join_by ', ' "${USER_UNIT_NAMES[@]}")"
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

  start_line="$(metrics_line_count)"

  core_command="$(
    cat <<EOF
sudo -n systemctl restart $(join_by ' ' "${CORE_UNITS[@]}")
sudo -n systemctl status open5gs-amfd --no-pager
sudo -n tail -f /var/log/open5gs/amf.log
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
  if [[ ${#USER_UNIT_NAMES[@]} -gt 0 ]]; then
    systemctl --user --no-pager --full status "${USER_UNIT_NAMES[@]}" || true
  else
    echo "No user runtime units configured."
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
      exec sudo -n tail -f /var/log/open5gs/amf.log
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
USER_UNIT_NAMES=(
  "$(user_unit_name "metrics-collector")"
  "$(user_unit_name "dashboard")"
)
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
  if [[ -z "$ue_netns" ]]; then
    echo "Could not determine netns from UE config: $ue_config" >&2
    exit 1
  fi
  ROOT_UNIT_NAMES+=("$ue_unit")
  COMPONENT_ROOT_UNITS["$ue_label"]="$ue_unit"
  COMPONENT_KEYS+=("$ue_label")
  UE_NETNS_LIST+=("$ue_netns")
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
