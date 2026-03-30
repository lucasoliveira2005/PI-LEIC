#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$SCRIPT_DIR}"
DRY_RUN="${DRY_RUN:-0}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$WORKDIR/.venv}"
METRICS_SCRIPT="${METRICS_SCRIPT:-metrics_exporter.py}"
DASHBOARD_SCRIPT="${DASHBOARD_SCRIPT:-dashboard.py}"
GNB_BIN="${GNB_BIN:-gnb}"
UE_BIN="${UE_BIN:-srsue}"
GNB_CONFIG="${GNB_CONFIG:-$SCRIPT_DIR/../config/gnb_zmq.yaml}"
UE_CONFIG="${UE_CONFIG:-$SCRIPT_DIR/../config/ue_zmq.conf.txt}"

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
  --workdir PATH  Linux path where gnb_zmq.yaml, ue_zmq.conf.txt and metrics_exporter.py live.
  --dry-run       Print the commands instead of opening terminals.
  --help          Show this message.

Environment overrides:
  WORKDIR, PYTHON_BIN, VENV_DIR, METRICS_SCRIPT, GNB_BIN, UE_BIN, GNB_CONFIG, UE_CONFIG
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

for cmd in sudo "$PYTHON_BIN"; do
  require_command "$cmd"
done

if [[ ! -d "$WORKDIR" ]]; then
  echo "Workdir does not exist: $WORKDIR" >&2
  exit 1
fi

if [[ ! -f "$METRICS_SCRIPT" ]]; then
  echo "Metrics exporter not found: $WORKDIR/$METRICS_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$DASHBOARD_SCRIPT" ]]; then
  echo "Dashboard script not found: $WORKDIR/$DASHBOARD_SCRIPT" >&2
  exit 1
fi

if [[ ! -f "$GNB_CONFIG" ]]; then
  echo "gNB config not found: $WORKDIR/$GNB_CONFIG" >&2
  exit 1
fi

if [[ ! -f "$UE_CONFIG" ]]; then
  echo "UE config not found: $WORKDIR/$UE_CONFIG" >&2
  exit 1
fi

open_terminal() {
  local title="$1"
  local command="$2"
  local full_command="$command; exec bash"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[%s]\n%s\n\n' "$title" "$full_command"
    return
  fi

  if command -v gnome-terminal >/dev/null 2>&1; then
    gnome-terminal --title="$title" -- bash -lc "$full_command"
    return
  fi

  if command -v konsole >/dev/null 2>&1; then
    konsole --new-tab --hold -p tabtitle="$title" -e bash -lc "$full_command"
    return
  fi

  if command -v xterm >/dev/null 2>&1; then
    xterm -T "$title" -hold -e bash -lc "$full_command" &
    return
  fi

  if command -v x-terminal-emulator >/dev/null 2>&1; then
    x-terminal-emulator -e bash -lc "$full_command" &
    return
  fi

  echo "No supported terminal emulator found." >&2
  echo "Install gnome-terminal, konsole, xterm, or x-terminal-emulator." >&2
  exit 1
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

core_units_joined="$(join_by ' ' "${CORE_UNITS[@]}")"

core_command="$(
  cat <<EOF
sudo systemctl restart $core_units_joined
sudo systemctl status open5gs-amfd --no-pager
sudo tail -f /var/log/open5gs/amf.log
EOF
)"

gnb_command="$(
  cat <<EOF
cd '$WORKDIR'
sudo $GNB_BIN -c '$GNB_CONFIG'
EOF
)"

ue_command="$(
  cat <<EOF
cd '$WORKDIR'
sudo $UE_BIN '$UE_CONFIG'
EOF
)"

metrics_command="$(
  cat <<EOF
cd '$WORKDIR'
[ -d '$VENV_DIR' ] || $PYTHON_BIN -m venv '$VENV_DIR'
source '$VENV_DIR/bin/activate'
$PYTHON_BIN -c 'import websocket' >/dev/null 2>&1 || $PYTHON_BIN -m pip install websocket-client
$PYTHON_BIN '$METRICS_SCRIPT'
EOF
)"

dashboard_command="$(
  cat <<EOF
cd '$WORKDIR'
$PYTHON_BIN '$DASHBOARD_SCRIPT'
EOF
)"

open_terminal "Core" "$core_command"
open_terminal "gNB" "$gnb_command"
open_terminal "UE" "$ue_command"
open_terminal "Metrics Exporter" "$metrics_command"
open_terminal "Metrics Dashboard" "$dashboard_command"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Dry run complete."
else
  echo "Opened 4 terminals from: $WORKDIR"
  echo "Each terminal may ask for your sudo password."
fi
