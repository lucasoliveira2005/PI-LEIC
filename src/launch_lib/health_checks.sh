#!/usr/bin/env bash

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
  local _start_line="$1"
  local deadline=$((SECONDS + HEALTHCHECK_TIMEOUT_SECONDS))
  local require_ue_data_path="$HEALTHCHECK_REQUIRE_UE_DATA_PATH"
  local healthcheck_since_epoch="${HEALTHCHECK_START_EPOCH:-0}"
  local baseline_file="${HEALTHCHECK_METRICS_BASELINE_FILE:-/dev/null}"
  local attach_failure_reported=0
  local -A source_seen_map=()
  local -A source_attach_map=()
  local -A source_fresh_map=()
  local -a missing_sources=()
  local -a missing_attach=()
  local -a stale_sources=()
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
  local source_seen
  local source_attach
  local source_fresh
  local health_states_output

  if [[ "$HEALTHCHECK_ENABLED" != "1" ]]; then
    return 0
  fi

  if [[ ! "$healthcheck_since_epoch" =~ ^[0-9]+$ ]]; then
    healthcheck_since_epoch="$(date +%s)"
  elif (( healthcheck_since_epoch <= 0 )); then
    healthcheck_since_epoch="$(date +%s)"
  fi

  echo "Running launch readiness checks for up to ${HEALTHCHECK_TIMEOUT_SECONDS}s..."
  echo "Freshness mode: ${FRESHNESS_CHECK_MODE} (age window: ${FRESHNESS_AGE_WINDOW_SECONDS}s)"

  while (( SECONDS < deadline )); do
    source_seen_map=()
    source_attach_map=()
    source_fresh_map=()
    missing_sources=()
    missing_attach=()
    stale_sources=()
    missing_netns=()
    missing_netdev_ipv4=()
    missing_default_routes=()
    inactive_root_units=()
    inactive_user_units=()

    health_states_output=""
    if ! health_states_output="$(metrics_contract_collect_health_states "$baseline_file" "${METRICS_SOURCE_IDS[@]}" 2>&1)"; then
      echo "Warning: failed to collect metrics health states:"
      echo "$health_states_output" | sed 's/^/  /'
    fi

    if [[ -n "$health_states_output" ]]; then
      while IFS=$'\t' read -r source_id source_seen source_attach source_fresh; do
        [[ -n "$source_id" ]] || continue
        source_seen_map["$source_id"]="$source_seen"
        source_attach_map["$source_id"]="$source_attach"
        source_fresh_map["$source_id"]="$source_fresh"
      done <<< "$health_states_output"
    fi

    for source_id in "${METRICS_SOURCE_IDS[@]}"; do
      if [[ "${source_seen_map[$source_id]:-0}" != "1" ]]; then
        missing_sources+=("$source_id")
      fi
      if [[ "${source_attach_map[$source_id]:-0}" != "1" ]]; then
        missing_attach+=("$source_id")
      fi
      if [[ "${source_fresh_map[$source_id]:-0}" != "1" ]]; then
        stale_sources+=("$source_id")
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
    if [[ ${#missing_sources[@]} -gt 0 || ${#missing_attach[@]} -gt 0 || ${#stale_sources[@]} -gt 0 || ${#missing_netns[@]} -gt 0 || ${#inactive_root_units[@]} -gt 0 || ${#inactive_user_units[@]} -gt 0 ]]; then
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
  if [[ ${#stale_sources[@]} -gt 0 ]]; then
    echo "Metrics freshness criteria not met from: $(join_by ', ' "${stale_sources[@]}")"
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
