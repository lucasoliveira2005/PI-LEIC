#!/usr/bin/env bash

root_runtime_start_sudo_keepalive() {
  (
    while true; do
      sudo -n true >/dev/null 2>&1 || exit 0
      sleep "$SUDO_KEEPALIVE_INTERVAL_SECONDS"
    done
  ) &
  SUDO_KEEPALIVE_PID="$!"
}

root_runtime_require_sudo_session() {
  sudo -v
  if [[ -z "$SUDO_KEEPALIVE_PID" ]]; then
    root_runtime_start_sudo_keepalive
  fi
}

root_runtime_stop_user_unit_if_exists() {
  local unit="$1"
  systemctl --user stop "$unit" >/dev/null 2>&1 || true
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
}

root_runtime_collect_known_user_units() {
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

root_runtime_stop_root_unit_if_exists() {
  local unit="$1"
  sudo -n systemctl stop "$unit" >/dev/null 2>&1 || true
  sudo -n systemctl reset-failed "$unit" >/dev/null 2>&1 || true
}

root_runtime_start_root_unit() {
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

root_runtime_start_user_unit() {
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
