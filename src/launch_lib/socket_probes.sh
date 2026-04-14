#!/usr/bin/env bash

socket_probes_snapshot_has_process_tcp_listener() {
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

socket_probes_snapshot_has_process_udp_port() {
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

socket_probes_collect_core_socket_probe_failures() {
  local snapshot="$1"
  local -n failures_ref="$2"

  failures_ref=()

  if ! socket_probes_snapshot_has_process_tcp_listener "$snapshot" "open5gs-amfd"; then
    failures_ref+=("open5gs-amfd missing tcp listener")
  fi
  if ! socket_probes_snapshot_has_process_tcp_listener "$snapshot" "open5gs-smfd"; then
    failures_ref+=("open5gs-smfd missing tcp listener")
  fi
  if ! socket_probes_snapshot_has_process_udp_port "$snapshot" "open5gs-smfd" "$CORE_PROBE_SMF_PFCP_PORT"; then
    failures_ref+=("open5gs-smfd missing udp:${CORE_PROBE_SMF_PFCP_PORT}")
  fi
  if ! socket_probes_snapshot_has_process_udp_port "$snapshot" "open5gs-upfd" "$CORE_PROBE_UPF_PFCP_PORT"; then
    failures_ref+=("open5gs-upfd missing udp:${CORE_PROBE_UPF_PFCP_PORT}")
  fi
  if ! socket_probes_snapshot_has_process_udp_port "$snapshot" "open5gs-upfd" "$CORE_PROBE_UPF_GTPU_PORT"; then
    failures_ref+=("open5gs-upfd missing udp:${CORE_PROBE_UPF_GTPU_PORT}")
  fi

  [[ ${#failures_ref[@]} -gt 0 ]]
}

socket_probes_first_tcp_listener_endpoint_for_process() {
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

socket_probes_tcp_endpoint_probe_ok() {
  local endpoint="$1"
  local host="${endpoint%:*}"
  local port="${endpoint##*:}"

  [[ -n "$host" && -n "$port" ]] || return 1

  timeout "$CORE_READINESS_ENDPOINT_PROBE_TIMEOUT_SECONDS" \
    bash -c ": </dev/tcp/${host}/${port}" >/dev/null 2>&1
}

socket_probes_collect_core_endpoint_probe_failures() {
  local snapshot="$1"
  local -n failures_ref="$2"
  local endpoint

  failures_ref=()

  endpoint="$(socket_probes_first_tcp_listener_endpoint_for_process "$snapshot" "open5gs-amfd")"
  if [[ -z "$endpoint" ]]; then
    failures_ref+=("open5gs-amfd missing active endpoint")
  elif ! socket_probes_tcp_endpoint_probe_ok "$endpoint"; then
    failures_ref+=("open5gs-amfd endpoint probe failed: ${endpoint}")
  fi

  endpoint="$(socket_probes_first_tcp_listener_endpoint_for_process "$snapshot" "open5gs-smfd")"
  if [[ -z "$endpoint" ]]; then
    failures_ref+=("open5gs-smfd missing active endpoint")
  elif ! socket_probes_tcp_endpoint_probe_ok "$endpoint"; then
    failures_ref+=("open5gs-smfd endpoint probe failed: ${endpoint}")
  fi

  [[ ${#failures_ref[@]} -gt 0 ]]
}
