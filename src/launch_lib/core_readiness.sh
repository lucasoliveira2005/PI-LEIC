#!/usr/bin/env bash

core_readiness_wait_for_core_readiness() {
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
      if ! journal_helpers_root_file_contains_pattern_since_line "$CORE_AMF_LOG_PATH" "$amf_start_line" 'ngap_server|sbi_server'; then
        missing_markers+=("amf")
      fi
      if ! journal_helpers_root_file_contains_pattern_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" 'pfcp_server|gtp_connect|sbi_server'; then
        missing_markers+=("smf")
      fi
      if [[ "$smf_amf_assoc_checks_enabled" == "1" ]] && ! journal_helpers_root_file_contains_pattern_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" '\[AMF\] NFInstance associated|\[namf-comm\] NFService associated'; then
        missing_markers+=("smf-amf-association")
      fi
      if ! journal_helpers_root_file_contains_pattern_since_line "$CORE_UPF_LOG_PATH" "$upf_start_line" 'pfcp_server|gtpu_server'; then
        missing_markers+=("upf")
      fi
    fi

    if [[ "$socket_probe_checks_enabled" == "1" ]]; then
      socket_snapshot="$(sudo -n ss -H -lntup -4 2>/dev/null || true)"
      socket_probes_collect_core_socket_probe_failures "$socket_snapshot" missing_socket_probes || true

      if [[ "$endpoint_probe_checks_enabled" == "1" ]]; then
        socket_probes_collect_core_endpoint_probe_failures "$socket_snapshot" missing_endpoint_probes || true
      fi
    fi

    core_failure_line="$(journal_helpers_root_file_first_match_since_line "$CORE_AMF_LOG_PATH" "$amf_start_line" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
    if [[ -n "$core_failure_line" ]]; then
      echo "Detected control-plane failure signal while waiting for core readiness:"
      echo "  amf.log: ${core_failure_line}"
      return 1
    fi

    core_failure_line="$(journal_helpers_root_file_first_match_since_line "$CORE_SMF_LOG_PATH" "$smf_start_line" "$HEALTHCHECK_AMF_FAILURE_REGEX")"
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
