#!/usr/bin/env bash

process_management_find_pids_by_comm_and_needle() {
  local comm="$1"
  local needle="$2"

  ps -eo pid=,comm=,args= | awk -v comm="$comm" -v needle="$needle" '
    $2 == comm && index($0, needle) {
      print $1
    }
  '
}

process_management_find_pids_by_needle() {
  local needle="$1"

  ps -eo pid=,args= | awk -v needle="$needle" '
    index($0, needle) {
      print $1
    }
  '
}

process_management_find_python_pids_by_needle() {
  local needle="$1"

  ps -eo pid=,comm=,args= | awk -v needle="$needle" '
    $2 ~ /^python([0-9.]*)?$/ && index($0, needle) {
      print $1
    }
  '
}

process_management_kill_matching_pids() {
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

process_management_kill_processes_for_comm_and_needles() {
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
    done < <(process_management_find_pids_by_comm_and_needle "$comm" "$needle")
  done

  for pid in "${!pid_set[@]}"; do
    pids+=("$pid")
  done

  process_management_kill_matching_pids "$label" "${pids[@]}"
}

process_management_kill_python_processes_for_needles() {
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
    done < <(process_management_find_python_pids_by_needle "$needle")
  done

  for pid in "${!pid_set[@]}"; do
    pids+=("$pid")
  done

  process_management_kill_matching_pids "$label" "${pids[@]}"
}

process_management_cleanup_stale_lab_processes() {
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
    process_management_kill_processes_for_comm_and_needles \
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
    process_management_kill_processes_for_comm_and_needles \
      "UE ${ue_label}" \
      "$ue_comm" \
      "$ue_config" \
      "$ue_config_rel" \
      "$(basename -- "$ue_config")"
  done

  process_management_kill_python_processes_for_needles \
    "metrics collector" \
    "$METRICS_SCRIPT_PATH" \
    "$metrics_script_rel"

  if [[ "$DASHBOARD_ENABLED" == "1" ]]; then
    process_management_kill_python_processes_for_needles \
      "dashboard" \
      "$DASHBOARD_SCRIPT_PATH" \
      "$dashboard_script_rel"
  fi
}
