#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
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
HEALTHCHECK_ENABLED="${HEALTHCHECK_ENABLED:-1}"
HEALTHCHECK_TIMEOUT_SECONDS="${HEALTHCHECK_TIMEOUT_SECONDS:-20}"
HEALTHCHECK_POLL_SECONDS="${HEALTHCHECK_POLL_SECONDS:-1}"

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

usage() {
  cat <<EOF
Usage: ./launch_stack.sh [--workdir PATH] [--dry-run]

Options:
  --workdir PATH  Linux path where the Python scripts live.
  --dry-run       Print the commands instead of opening terminals.
  --help          Show this message.

Environment overrides:
  WORKDIR, PYTHON_BIN, VENV_DIR, REQUIREMENTS_FILE, METRICS_SCRIPT, DASHBOARD_SCRIPT
  METRICS_SOURCES_CONFIG, METRICS_OUT, GNB_BIN, UE_BIN, GNB_CONFIGS, UE_CONFIGS
  HEALTHCHECK_ENABLED, HEALTHCHECK_TIMEOUT_SECONDS, HEALTHCHECK_POLL_SECONDS

Notes:
  GNB_CONFIGS and UE_CONFIGS use colon-separated paths.
  The post-launch health check is a best-effort smoke check for interactive runs.
  It may warn while newly opened terminals are still waiting for sudo input.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)
      WORKDIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
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

read_metrics_source_ids() {
  "$PYTHON_BIN" -c '
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

  echo "Running best-effort post-launch smoke checks for up to ${HEALTHCHECK_TIMEOUT_SECONDS}s..."
  echo "These checks run immediately after the terminals open and may warn while those terminals are still waiting for sudo input."

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
      echo "Health check passed."
      echo "Fresh metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
      echo "UE namespaces present: $(join_by ', ' "${UE_NETNS_LIST[@]}")"
      echo "Attach-like cells metrics observed from: $(join_by ', ' "${METRICS_SOURCE_IDS[@]}")"
      return 0
    fi

    sleep "$HEALTHCHECK_POLL_SECONDS"
  done

  echo "Health check completed with warnings."
  echo "These warnings are not definitive failures in interactive mode."
  if [[ ${#missing_sources[@]} -gt 0 ]]; then
    echo "No fresh metrics observed from: $(join_by ', ' "${missing_sources[@]}")"
  fi
  if [[ ${#missing_attach[@]} -gt 0 ]]; then
    echo "No attach-like cells metrics observed from: $(join_by ', ' "${missing_attach[@]}")"
  fi
  if [[ ${#missing_netns[@]} -gt 0 ]]; then
    echo "Missing UE namespaces: $(join_by ', ' "${missing_netns[@]}")"
  fi
  echo "Use src/validate_stage.sh for the stricter end-to-end validation after traffic is generated."
  echo "Inspect the corresponding gNB, UE, and Metrics Collector terminals if these warnings persist."
}

prepare_python_env() {
  mkdir -p "$(dirname -- "$METRICS_OUT_PATH")"
  mkdir -p "$MPLCONFIGDIR_PATH"

  if [[ ! -d "$VENV_DIR_PATH" ]]; then
    "$PYTHON_BIN" -m venv "$VENV_DIR_PATH"
  fi

  if ! "$VENV_DIR_PATH/bin/python" -c 'import matplotlib, websocket' >/dev/null 2>&1; then
    "$VENV_DIR_PATH/bin/python" -m pip install -r "$REQUIREMENTS_FILE_PATH"
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

join_by() {
  local separator="$1"
  shift
  local first="$1"
  shift

  printf '%s' "$first"
  for item in "$@"; do
    printf '%s%s' "$separator" "$item"
  done
}

for cmd in sudo "$PYTHON_BIN"; do
  require_command "$cmd"
done

if [[ ! -d "$WORKDIR" ]]; then
  echo "Workdir does not exist: $WORKDIR" >&2
  exit 1
fi

WORKDIR="$(cd -- "$WORKDIR" && pwd)"
VENV_DIR="${VENV_DIR:-$WORKDIR/.venv}"

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
for config_path in "${UE_CONFIG_PATHS[@]}"; do
  ue_netns="$(read_netns "$config_path")"
  if [[ -z "$ue_netns" ]]; then
    echo "Could not determine netns from UE config: $config_path" >&2
    exit 1
  fi
  UE_NETNS_LIST+=("$ue_netns")
done

if [[ "$DRY_RUN" != "1" ]]; then
  for cmd in systemctl "$GNB_BIN" "$UE_BIN" ip; do
    require_command "$cmd"
  done

  if ! TERMINAL_EMULATOR="$(find_terminal_emulator)"; then
    echo "No supported terminal emulator found." >&2
    echo "Install gnome-terminal, konsole, xterm, or x-terminal-emulator." >&2
    exit 1
  fi

  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    echo "No graphical display detected." >&2
    echo "Run this launcher from a desktop session or use --dry-run to launch commands manually." >&2
    exit 1
  fi

  prepare_python_env
  METRICS_OUT_START_LINE="$(metrics_line_count)"
fi

core_units_joined="$(join_by ' ' "${CORE_UNITS[@]}")"

core_command="$(
  cat <<EOF
sudo systemctl restart $core_units_joined
sudo systemctl status open5gs-amfd --no-pager
sudo tail -f /var/log/open5gs/amf.log
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
sudo $GNB_BIN -c '$gnb_config'
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
sudo ip netns del '$ue_netns' 2>/dev/null || true
sudo ip netns add '$ue_netns'
sudo $UE_BIN '$ue_config'
EOF
  )"
  open_terminal "$ue_title" "$ue_command"
done

open_terminal "Metrics Collector" "$collector_command"
open_terminal "Metrics Dashboard" "$dashboard_command"

terminal_count=$((1 + ${#GNB_CONFIG_PATHS[@]} + ${#UE_CONFIG_PATHS[@]} + 2))

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete."
else
  echo "Opened $terminal_count terminals from: $WORKDIR"
  echo "Each radio and core terminal may ask for your sudo password."
  run_health_checks "$METRICS_OUT_START_LINE"
fi
