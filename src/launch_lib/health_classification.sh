#!/usr/bin/env bash

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
