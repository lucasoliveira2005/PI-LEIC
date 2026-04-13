#!/usr/bin/env bash

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

read_ip_devname() {
  local config_path="$1"

  awk -F '=' '
    /^[[:space:]]*ip_devname[[:space:]]*=/ {
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
