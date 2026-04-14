#!/usr/bin/env bash

journal_helpers_metrics_line_count() {
  if [[ -f "$METRICS_OUT_PATH" ]]; then
    wc -l < "$METRICS_OUT_PATH"
  else
    echo 0
  fi
}

journal_helpers_root_file_line_count() {
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

journal_helpers_root_file_contains_pattern_since_line() {
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

journal_helpers_root_file_first_match_since_line() {
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

journal_helpers_root_unit_first_match_since_epoch() {
  local unit="$1"
  local since_epoch="$2"
  local regex="$3"

  [[ -n "$regex" ]] || return 0
  sudo -n journalctl -u "$unit" --since "@$since_epoch" --no-pager -o cat 2>/dev/null \
    | grep -E -i -m 1 "$regex" || true
}
