#!/usr/bin/env bash
set -euo pipefail

# Fresh-host bootstrap for the PI-LEIC OpenAirInterface + Open5GS stack.
# This script intentionally does not install or configure srsRAN.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR"

DRY_RUN=0
SKIP_SYSTEM_PACKAGES=0
SKIP_MONGODB=0
SKIP_OPEN5GS=0
SKIP_NETWORKING=0
SKIP_OAI_CLONE=0
SKIP_OAI_BUILD=0
SKIP_PYTHON=0
SKIP_PROVISION=0
RUN_LAUNCH=0
RUN_VALIDATE=0
UPDATE_OAI=0
INSTALL_DEV=0

PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="${VENV_DIR:-$REPO_ROOT/src/.venv}"
OAI_REPO_URL="${OAI_REPO_URL:-https://gitlab.eurecom.fr/oai/openairinterface5g.git}"
OAI_DIR="${OAI_DIR:-$HOME/oai/openairinterface5g}"
OAI_REF="${OAI_REF:-}"
MONGODB_MAJOR="${MONGODB_MAJOR:-8.0}"
MONGODB_UBUNTU_CODENAME="${MONGODB_UBUNTU_CODENAME:-}"
MONGODB_PIN_VERSION="${MONGODB_PIN_VERSION:-8.0.4}"
MONGODB_SHADOW_STACK_WORKAROUND="${MONGODB_SHADOW_STACK_WORKAROUND:-1}"
MONGODB_GLIBC_TUNABLES="${MONGODB_GLIBC_TUNABLES:-glibc.cpu.hwcaps=-SHSTK:glibc.pthread.rseq=1}"
MONGODB_READY_TIMEOUT_SECONDS="${MONGODB_READY_TIMEOUT_SECONDS:-60}"
OPEN5GS_UBUNTU_CODENAME="${OPEN5GS_UBUNTU_CODENAME:-}"
OPEN5GS_PPA_KEY_ID="${OPEN5GS_PPA_KEY_ID:-ACC46E8E238249B1}"
OPEN5GS_COMPAT_UBUNTU_CODENAME="${OPEN5GS_COMPAT_UBUNTU_CODENAME:-noble}"
UE_SUBNET="${UE_SUBNET:-10.45.0.0/16}"
API_HOST_VALUE="${API_HOST:-127.0.0.1}"
API_PORT_VALUE="${API_PORT:-8000}"
DASHBOARD_ENABLED_VALUE="${DASHBOARD_ENABLED:-0}"
OAI_GNB_EXTRA_ARGS_VALUE="${OAI_GNB_EXTRA_ARGS:---rfsim}"
OAI_UE_EXTRA_ARGS_DEFAULT="--rfsim -r 106 --numerology 1 --band 78 -C 3319680000 --ssb 516"
OAI_UE_EXTRA_ARGS_VALUE="${OAI_UE_EXTRA_ARGS:-$OAI_UE_EXTRA_ARGS_DEFAULT}"
RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-$REPO_ROOT/var/oai.env}"

OPEN5GS_UNITS=(
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
  cat <<'EOF'
Usage: ./setup_oai_open5gs.sh [options]

Default behavior:
  1. install system packages
  2. install MongoDB
  3. install Open5GS
  4. enable basic Open5GS networking
  5. clone/build OpenAirInterface gNB + nrUE RFsim binaries
  6. create src/.venv and install Python requirements
  7. provision Open5GS subscribers from config/subscribers.json

Options:
  --dry-run               Print the commands that would run.
  --skip-system-packages  Do not install base apt packages.
  --skip-mongodb          Do not install MongoDB.
  --skip-open5gs          Do not install Open5GS.
  --skip-networking       Do not configure IPv4 forwarding/NAT for Open5GS.
  --skip-oai-clone        Do not clone OpenAirInterface.
  --skip-oai-build        Do not build OpenAirInterface.
  --skip-python           Do not create/update the Python venv.
  --skip-provision        Do not apply subscriber provisioning.
  --update-oai            Fetch updates in an existing OAI checkout.
  --dev                   Install requirements-dev.txt too.
  --launch                Launch the supervised OAI stack after setup.
  --validate              Run src/validate_stage.sh after setup.
  --help                  Show this help.

Environment overrides:
  PYTHON_BIN, VENV_DIR, OAI_DIR, OAI_REPO_URL, OAI_REF
  MONGODB_MAJOR, MONGODB_UBUNTU_CODENAME, MONGODB_PIN_VERSION
  MONGODB_SHADOW_STACK_WORKAROUND, MONGODB_GLIBC_TUNABLES
  MONGODB_READY_TIMEOUT_SECONDS
  OPEN5GS_UBUNTU_CODENAME
  OPEN5GS_PPA_KEY_ID, OPEN5GS_COMPAT_UBUNTU_CODENAME, UE_SUBNET
  API_HOST, API_PORT, DASHBOARD_ENABLED
  OAI_GNB_EXTRA_ARGS, OAI_UE_EXTRA_ARGS, RUNTIME_ENV_FILE

Notes:
  Run as your regular user, not with sudo. The script requests sudo only for
  system package, Open5GS, networking, and service operations.
EOF
}

log() {
  printf '\n==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

print_cmd() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
}

run() {
  print_cmd "$@"
  if [[ "$DRY_RUN" != "1" ]]; then
    "$@"
  fi
}

run_in_dir() {
  local dir="$1"
  shift

  printf '+ cd %q &&' "$dir"
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" != "1" ]]; then
    (cd "$dir" && "$@")
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_regular_user() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    cat >&2 <<'EOF'
Do not run this setup script with sudo/root.

Use:
  ./setup_oai_open5gs.sh

It will request sudo for the operations that need it.
EOF
    exit 1
  fi
}

require_sudo_session() {
  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  if ! sudo -n true >/dev/null 2>&1; then
    sudo -v
  fi
}

detect_system_ubuntu_codename() {
  local codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi

  if [[ -z "$codename" ]]; then
    echo "Could not detect Ubuntu codename. Set MONGODB_UBUNTU_CODENAME or OPEN5GS_UBUNTU_CODENAME." >&2
    exit 1
  fi

  printf '%s\n' "$codename"
}

detect_ubuntu_codename() {
  if [[ -n "$MONGODB_UBUNTU_CODENAME" ]]; then
    printf '%s\n' "$MONGODB_UBUNTU_CODENAME"
    return
  fi

  local codename
  codename="$(detect_system_ubuntu_codename)"

  case "$codename" in
    focal|jammy|noble)
      ;;
    *)
      warn "MongoDB ${MONGODB_MAJOR} may not publish an Ubuntu '${codename}' repository yet; using 'noble'."
      warn "Override with MONGODB_UBUNTU_CODENAME if your target host needs a different suite."
      codename="noble"
      ;;
  esac

  printf '%s\n' "$codename"
}

detect_open5gs_codename() {
  if [[ -n "$OPEN5GS_UBUNTU_CODENAME" ]]; then
    printf '%s\n' "$OPEN5GS_UBUNTU_CODENAME"
    return
  fi

  local codename
  codename="$(detect_system_ubuntu_codename)"

  case "$codename" in
    focal|jammy|noble)
      ;;
    *)
      warn "Open5GS PPA does not appear to publish Ubuntu '${codename}' packages yet; using 'noble'."
      warn "Override with OPEN5GS_UBUNTU_CODENAME if your target host needs a different suite."
      codename="noble"
      ;;
  esac

  printf '%s\n' "$codename"
}

write_root_file() {
  local target="$1"
  local content="$2"

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ write root file %q\n' "$target"
    return
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  printf '%s' "$content" > "$tmp_file"
  sudo install -D -m 0644 "$tmp_file" "$target"
  rm -f "$tmp_file"
}

apt_install() {
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

apt_install_allow_downgrades() {
  run sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "$@"
}

apt_has_candidate() {
  local package_name="$1"

  apt-cache policy "$package_name" 2>/dev/null \
    | awk '/Candidate:/ {print $2; exit}' \
    | grep -vFx "(none)" >/dev/null 2>&1
}

install_microsoft_apt_key() {
  require_command curl
  require_command gpg

  local tmp_key tmp_gpg
  tmp_key="$(mktemp)"
  tmp_gpg="$(mktemp)"

  print_cmd curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$tmp_key"
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$tmp_key"
  print_cmd gpg --dearmor --yes -o "$tmp_gpg" "$tmp_key"
  gpg --dearmor --yes -o "$tmp_gpg" "$tmp_key"
  print_cmd sudo install -D -m 0644 "$tmp_gpg" /etc/apt/trusted.gpg.d/microsoft.gpg
  sudo install -D -m 0644 "$tmp_gpg" /etc/apt/trusted.gpg.d/microsoft.gpg
  print_cmd sudo install -D -m 0644 "$tmp_gpg" /etc/apt/keyrings/packages.microsoft.gpg
  sudo install -D -m 0644 "$tmp_gpg" /etc/apt/keyrings/packages.microsoft.gpg
  print_cmd sudo install -D -m 0644 "$tmp_gpg" /usr/share/keyrings/packages.microsoft.gpg
  sudo install -D -m 0644 "$tmp_gpg" /usr/share/keyrings/packages.microsoft.gpg

  rm -f "$tmp_key" "$tmp_gpg"
}

mongodb_packages_for_pin() {
  local version="$1"

  printf '%s\n' \
    "mongodb-org=${version}" \
    "mongodb-org-database=${version}" \
    "mongodb-org-server=${version}" \
    "mongodb-org-mongos=${version}" \
    "mongodb-org-shell=${version}" \
    "mongodb-org-tools=${version}" \
    "mongodb-org-database-tools-extra=${version}"
}

mongodb_package_names_for_pin() {
  printf '%s\n' \
    mongodb-org \
    mongodb-org-database \
    mongodb-org-server \
    mongodb-org-mongos \
    mongodb-org-shell \
    mongodb-org-tools \
    mongodb-org-database-tools-extra
}

configure_mongodb_runtime_workaround() {
  if [[ "$MONGODB_SHADOW_STACK_WORKAROUND" != "1" ]]; then
    return
  fi

  log "Configuring MongoDB runtime workaround for Linux 6.19+/7.x kernels"
  write_root_file "/etc/systemd/system/mongod.service.d/pi-leic-glibc-tunables.conf" "[Service]
Environment=\"GLIBC_TUNABLES=${MONGODB_GLIBC_TUNABLES}\"

"
}

wait_for_mongodb() {
  if [[ "$DRY_RUN" == "1" ]]; then
    print_cmd mongosh --quiet --eval "db.adminCommand({ ping: 1 }).ok"
    return
  fi

  require_command mongosh

  local deadline
  deadline=$((SECONDS + MONGODB_READY_TIMEOUT_SECONDS))

  until mongosh --quiet --eval "db.adminCommand({ ping: 1 }).ok" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      echo "MongoDB did not become ready within ${MONGODB_READY_TIMEOUT_SECONDS}s." >&2
      echo "Check the service with: systemctl status mongod.service" >&2
      systemctl --no-pager --full status mongod.service >&2 || true
      exit 1
    fi
    sleep 2
  done
}

configure_open5gs_noble_compat_repo() {
  local source_file prefs_file source_content prefs_content compat_suite
  compat_suite="$OPEN5GS_COMPAT_UBUNTU_CODENAME"
  source_file="/etc/apt/sources.list.d/pi-leic-ubuntu-${compat_suite}-open5gs-compat.sources"
  prefs_file="/etc/apt/preferences.d/pi-leic-open5gs-${compat_suite}-compat"
  source_content="Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: ${compat_suite}
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

"
  prefs_content="Package: *
Pin: release o=Ubuntu,n=${compat_suite}
Pin-Priority: -10

Package: libbson-1.0-0t64 libmongoc-1.0-0t64
Pin: release o=Ubuntu,n=${compat_suite}
Pin-Priority: 990

"

  warn "Adding pinned Ubuntu ${compat_suite} compatibility source for Open5GS Mongo C runtime ABI packages."
  write_root_file "$source_file" "$source_content"
  write_root_file "$prefs_file" "$prefs_content"
}

install_open5gs_apt_key() {
  require_command curl
  require_command gpg

  local key_url keyring tmp_key tmp_gpg
  key_url="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${OPEN5GS_PPA_KEY_ID}"
  keyring="/usr/share/keyrings/open5gs.gpg"
  tmp_key="$(mktemp)"
  tmp_gpg="$(mktemp)"

  print_cmd curl -fsSL "$key_url" -o "$tmp_key"
  curl -fsSL "$key_url" -o "$tmp_key"
  print_cmd gpg --dearmor --yes -o "$tmp_gpg" "$tmp_key"
  gpg --dearmor --yes -o "$tmp_gpg" "$tmp_key"
  print_cmd sudo install -D -m 0644 "$tmp_gpg" "$keyring"
  sudo install -D -m 0644 "$tmp_gpg" "$keyring"

  rm -f "$tmp_key" "$tmp_gpg"
}

repair_open5gs_apt_source() {
  local codename list_file sources_file repo_line sources_content
  codename="$(detect_open5gs_codename)"
  list_file="/etc/apt/sources.list.d/pi-leic-open5gs-${codename}.list"
  sources_file="/etc/apt/sources.list.d/open5gs-ubuntu-latest-$(detect_system_ubuntu_codename).sources"
  repo_line="deb [signed-by=/usr/share/keyrings/open5gs.gpg] https://ppa.launchpadcontent.net/open5gs/latest/ubuntu ${codename} main
"
  sources_content="Types: deb
URIs: https://ppa.launchpadcontent.net/open5gs/latest/ubuntu/
Suites: ${codename}
Components: main
Signed-By: /usr/share/keyrings/open5gs.gpg

"

  warn "Repairing Open5GS PPA source to use Ubuntu '${codename}'."

  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ repair or create Open5GS apt source for %q\n' "$codename"
    printf '+ disable stale Open5GS apt source files for unsupported suites\n'
    return
  fi

  if [[ -f "$sources_file" ]]; then
    write_root_file "$sources_file" "$sources_content"
  else
    write_root_file "$list_file" "$repo_line"
  fi

  sudo find /etc/apt/sources.list.d \
    -maxdepth 1 \
    -type f \
    \( -name 'open5gs-ubuntu-latest-*.list' -o -name 'open5gs-ubuntu-latest-*.sources' \) \
    ! -name "$(basename -- "$sources_file")" \
    -exec mv {} {}.disabled \; 2>/dev/null || true
}

apt_update() {
  print_cmd sudo apt-get update
  if [[ "$DRY_RUN" == "1" ]]; then
    return
  fi

  local output status
  set +e
  output="$(sudo apt-get update 2>&1)"
  status=$?
  set -e
  printf '%s\n' "$output"

  if [[ "$status" -eq 0 ]]; then
    return
  fi

  if grep -q "NO_PUBKEY EB3E94ADBE1229CF" <<< "$output" \
    && grep -q "packages.microsoft.com/repos/vscode" <<< "$output"; then
    warn "Detected missing Microsoft/VS Code apt signing key; installing the Microsoft package key and retrying apt update."
    install_microsoft_apt_key
    run sudo apt-get update
    return
  fi

  if grep -q "NO_PUBKEY ${OPEN5GS_PPA_KEY_ID}" <<< "$output" \
    && grep -q "ppa.launchpadcontent.net/open5gs/latest/ubuntu" <<< "$output"; then
    warn "Detected missing Open5GS PPA signing key; installing key ${OPEN5GS_PPA_KEY_ID} and retrying apt update."
    install_open5gs_apt_key
    repair_open5gs_apt_source
    run sudo apt-get update
    return
  fi

  if grep -q "ppa.launchpadcontent.net/open5gs/latest/ubuntu" <<< "$output" \
    && grep -q "does not have a Release file" <<< "$output"; then
    repair_open5gs_apt_source
    run sudo apt-get update
    return
  fi

  return "$status"
}

install_system_packages() {
  if [[ "$SKIP_SYSTEM_PACKAGES" == "1" ]]; then
    log "Skipping base system packages"
    return
  fi

  log "Installing base system packages"
  apt_update
  apt_install \
    git curl wget gnupg ca-certificates software-properties-common \
    python3 python3-venv python3-pip \
    jq iperf3 iproute2 iputils-ping net-tools iptables \
    build-essential cmake ninja-build pkg-config \
    autoconf automake libtool \
    libsctp-dev lksctp-tools libconfig-dev libssl-dev

  log "Loading SCTP kernel support"
  if [[ "$DRY_RUN" == "1" ]]; then
    print_cmd sudo modprobe sctp
    printf '+ write root file %q\n' "/etc/modules-load.d/pi-leic.conf"
  else
    sudo modprobe sctp || warn "Could not load SCTP module; check kernel support."
    write_root_file "/etc/modules-load.d/pi-leic.conf" "sctp
"
  fi
}

install_mongodb() {
  if [[ "$SKIP_MONGODB" == "1" ]]; then
    log "Skipping MongoDB"
    return
  fi

  require_command curl
  require_command gpg

  local codename keyring list_file key_url repo_line tmp_key
  codename="$(detect_ubuntu_codename)"
  keyring="/usr/share/keyrings/mongodb-server-${MONGODB_MAJOR}.gpg"
  list_file="/etc/apt/sources.list.d/mongodb-org-${MONGODB_MAJOR}.list"
  key_url="https://pgp.mongodb.com/server-${MONGODB_MAJOR}.asc"
  repo_line="deb [ arch=amd64,arm64 signed-by=${keyring} ] https://repo.mongodb.org/apt/ubuntu ${codename}/mongodb-org/${MONGODB_MAJOR} multiverse
"

  log "Installing MongoDB ${MONGODB_MAJOR} for Ubuntu ${codename}"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ download %q and install keyring %q\n' "$key_url" "$keyring"
  else
    tmp_key="$(mktemp)"
    curl -fsSL "$key_url" -o "$tmp_key"
    sudo gpg --dearmor --yes -o "$keyring" "$tmp_key"
    rm -f "$tmp_key"
  fi
  write_root_file "$list_file" "$repo_line"
  apt_update

  if [[ -n "$MONGODB_PIN_VERSION" ]]; then
    log "Installing MongoDB ${MONGODB_PIN_VERSION} server packages"
    warn "MongoDB newer than 8.0.4 refuses to start on this host's Linux 7.x kernel; pinning server packages to ${MONGODB_PIN_VERSION}."
    local -a mongodb_pin_names=()
    local -a mongodb_pin_packages=()
    mapfile -t mongodb_pin_names < <(mongodb_package_names_for_pin)
    mapfile -t mongodb_pin_packages < <(mongodb_packages_for_pin "$MONGODB_PIN_VERSION")
    print_cmd sudo apt-mark unhold "${mongodb_pin_names[@]}"
    if [[ "$DRY_RUN" != "1" ]]; then
      sudo apt-mark unhold "${mongodb_pin_names[@]}" >/dev/null 2>&1 || true
    fi
    apt_install_allow_downgrades "${mongodb_pin_packages[@]}" mongodb-mongosh
    run sudo apt-mark hold "${mongodb_pin_names[@]}"
  else
    apt_install mongodb-org
  fi

  configure_mongodb_runtime_workaround
  run sudo systemctl daemon-reload
  run sudo systemctl reset-failed mongod.service
  run sudo systemctl enable --now mongod
  wait_for_mongodb
}

install_open5gs() {
  if [[ "$SKIP_OPEN5GS" == "1" ]]; then
    log "Skipping Open5GS"
    return
  fi

  require_command add-apt-repository

  log "Installing Open5GS"
  run sudo add-apt-repository -y -n ppa:open5gs/latest
  repair_open5gs_apt_source
  configure_open5gs_noble_compat_repo
  apt_update
  if ! apt_has_candidate libbson-1.0-0t64 || ! apt_has_candidate libmongoc-1.0-0t64; then
    configure_open5gs_noble_compat_repo
    apt_update
  fi
  apt_install open5gs

  log "Enabling Open5GS services that exist on this host"
  local unit unit_file_match
  local -a failed_units=()
  for unit in "${OPEN5GS_UNITS[@]}"; do
    if [[ "$DRY_RUN" == "1" ]]; then
      print_cmd sudo systemctl enable --now "$unit"
      continue
    fi
    unit_file_match="$(systemctl list-unit-files "$unit.service" --no-legend 2>/dev/null || true)"
    if [[ -n "$unit_file_match" ]]; then
      sudo systemctl reset-failed "$unit" >/dev/null 2>&1 || true
      if ! sudo systemctl enable --now "$unit" >/dev/null; then
        failed_units+=("$unit")
      fi
    fi
  done

  if [[ ${#failed_units[@]} -gt 0 ]]; then
    warn "Some Open5GS services did not start during setup: ${failed_units[*]}"
    warn "The launcher will retry core services later; inspect with: systemctl status ${failed_units[*]}"
  fi
}

configure_open5gs_networking() {
  if [[ "$SKIP_NETWORKING" == "1" ]]; then
    log "Skipping Open5GS host networking"
    return
  fi

  log "Configuring IPv4 forwarding and Open5GS UE NAT"
  write_root_file "/etc/sysctl.d/99-pi-leic-open5gs.conf" "net.ipv4.ip_forward=1
"
  run sudo sysctl --system

  if [[ "$DRY_RUN" == "1" ]]; then
    print_cmd sudo iptables -t nat -C POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE
    print_cmd sudo iptables -t nat -A POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE
    return
  fi

  if ! sudo iptables -t nat -C POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE >/dev/null 2>&1; then
    sudo iptables -t nat -A POSTROUTING -s "$UE_SUBNET" ! -o ogstun -j MASQUERADE
  fi
}

clone_oai() {
  if [[ "$SKIP_OAI_CLONE" == "1" ]]; then
    log "Skipping OpenAirInterface clone"
    return
  fi

  log "Preparing OpenAirInterface checkout"
  if [[ -d "$OAI_DIR/.git" ]]; then
    printf 'OpenAirInterface already exists at %s\n' "$OAI_DIR"
    if [[ "$UPDATE_OAI" == "1" ]]; then
      run git -C "$OAI_DIR" fetch --all --tags
    fi
  elif [[ -e "$OAI_DIR" ]]; then
    echo "OAI_DIR exists but is not a git checkout: $OAI_DIR" >&2
    echo "Move it aside or set OAI_DIR to another path." >&2
    exit 1
  else
    run mkdir -p "$(dirname -- "$OAI_DIR")"
    run git clone "$OAI_REPO_URL" "$OAI_DIR"
  fi

  if [[ -n "$OAI_REF" ]]; then
    run git -C "$OAI_DIR" checkout "$OAI_REF"
  fi
}

build_oai() {
  if [[ "$SKIP_OAI_BUILD" == "1" ]]; then
    log "Skipping OpenAirInterface build"
    return
  fi

  if [[ ! -d "$OAI_DIR/cmake_targets" && "$DRY_RUN" != "1" ]]; then
    echo "Missing OAI cmake_targets directory: $OAI_DIR/cmake_targets" >&2
    exit 1
  fi

  log "Building OpenAirInterface gNB and nrUE RFsim binaries"
  run_in_dir "$OAI_DIR/cmake_targets" ./build_oai -I --install-optional-packages
  apt_install autoconf automake libtool
  run_in_dir "$OAI_DIR/cmake_targets" ./build_oai --gNB --nrUE --ninja --cmake-opt "-DAUTO_DOWNLOAD_ASN1C=ON"
}

setup_python_env() {
  if [[ "$SKIP_PYTHON" == "1" ]]; then
    log "Skipping Python environment"
    return
  fi

  log "Creating/updating Python virtual environment"
  if [[ ! -d "$VENV_DIR" ]]; then
    run "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  run "$VENV_DIR/bin/python" -m pip install --upgrade pip
  run "$VENV_DIR/bin/python" -m pip install -r "$REPO_ROOT/requirements.txt"
  if [[ "$INSTALL_DEV" == "1" ]]; then
    run "$VENV_DIR/bin/python" -m pip install -r "$REPO_ROOT/requirements-dev.txt"
  fi
}

write_runtime_env() {
  log "Writing OAI runtime environment to $RUNTIME_ENV_FILE"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '+ write user file %q\n' "$RUNTIME_ENV_FILE"
    return
  fi

  mkdir -p "$(dirname -- "$RUNTIME_ENV_FILE")"
  cat > "$RUNTIME_ENV_FILE" <<EOF
export RAN_BACKEND=oai
export OAI_DIR="$OAI_DIR"
export GNB_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
export UE_BIN="$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"
export METRICS_SOURCES_CONFIG="$REPO_ROOT/config/metrics_sources_oai.json"
export METRICS_OUT="$REPO_ROOT/metrics/oran/gnb_metrics.jsonl"
export METRICS_AGENT_OUT="$REPO_ROOT/metrics/oran/agent_network_observations.jsonl"
export METRICS_SQLITE_PATH="$REPO_ROOT/metrics/oran/pi-leic-metrics.sqlite"
export API_HOST="$API_HOST_VALUE"
export API_PORT="$API_PORT_VALUE"
export DASHBOARD_ENABLED="$DASHBOARD_ENABLED_VALUE"
export OAI_GNB_EXTRA_ARGS="$OAI_GNB_EXTRA_ARGS_VALUE"
export OAI_UE_EXTRA_ARGS="$OAI_UE_EXTRA_ARGS_VALUE"
export UE_NAMESPACES="ue-oai1:ue-oai2"
EOF
}

run_oai_env() {
  local -a env_args=(
    "RAN_BACKEND=oai"
    "OAI_DIR=$OAI_DIR"
    "GNB_BIN=$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
    "UE_BIN=$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"
    "METRICS_SOURCES_CONFIG=$REPO_ROOT/config/metrics_sources_oai.json"
    "METRICS_OUT=$REPO_ROOT/metrics/oran/gnb_metrics.jsonl"
    "METRICS_AGENT_OUT=$REPO_ROOT/metrics/oran/agent_network_observations.jsonl"
    "METRICS_SQLITE_PATH=$REPO_ROOT/metrics/oran/pi-leic-metrics.sqlite"
    "API_HOST=$API_HOST_VALUE"
    "API_PORT=$API_PORT_VALUE"
    "DASHBOARD_ENABLED=$DASHBOARD_ENABLED_VALUE"
    "OAI_GNB_EXTRA_ARGS=$OAI_GNB_EXTRA_ARGS_VALUE"
    "OAI_UE_EXTRA_ARGS=$OAI_UE_EXTRA_ARGS_VALUE"
    "UE_NAMESPACES=ue-oai1:ue-oai2"
    "LAUNCH_DASHBOARD_ENABLED=$DASHBOARD_ENABLED_VALUE"
  )

  run env "${env_args[@]}" "$@"
}

provision_subscribers() {
  if [[ "$SKIP_PROVISION" == "1" ]]; then
    log "Skipping subscriber provisioning"
    return
  fi

  log "Provisioning Open5GS subscribers"
  wait_for_mongodb
  run "$VENV_DIR/bin/python" "$REPO_ROOT/src/provision_subscribers.py" --apply
}

verify_local_setup() {
  log "Verifying local paths"
  local gnb_bin="$OAI_DIR/cmake_targets/ran_build/build/nr-softmodem"
  local ue_bin="$OAI_DIR/cmake_targets/ran_build/build/nr-uesoftmodem"

  if [[ "$DRY_RUN" == "1" ]]; then
    print_cmd test -x "$gnb_bin"
    print_cmd test -x "$ue_bin"
    print_cmd "$VENV_DIR/bin/python" -c "import fastapi, uvicorn, matplotlib, websocket"
    return
  fi

  test -x "$gnb_bin" || {
    echo "Missing OAI gNB binary: $gnb_bin" >&2
    exit 1
  }
  test -x "$ue_bin" || {
    echo "Missing OAI nrUE binary: $ue_bin" >&2
    exit 1
  }
  "$VENV_DIR/bin/python" -c "import fastapi, uvicorn, matplotlib, websocket"
}

launch_stack() {
  if [[ "$RUN_LAUNCH" != "1" ]]; then
    return
  fi

  log "Launching supervised OAI stack"
  run_oai_env bash "$REPO_ROOT/src/launch_stack.sh" --mode supervised
}

validate_stack() {
  if [[ "$RUN_VALIDATE" != "1" ]]; then
    return
  fi

  log "Running full stage validation"
  run_oai_env bash "$REPO_ROOT/src/validate_stage.sh"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --skip-system-packages)
        SKIP_SYSTEM_PACKAGES=1
        shift
        ;;
      --skip-mongodb)
        SKIP_MONGODB=1
        shift
        ;;
      --skip-open5gs)
        SKIP_OPEN5GS=1
        shift
        ;;
      --skip-networking)
        SKIP_NETWORKING=1
        shift
        ;;
      --skip-oai-clone)
        SKIP_OAI_CLONE=1
        shift
        ;;
      --skip-oai-build)
        SKIP_OAI_BUILD=1
        shift
        ;;
      --skip-python)
        SKIP_PYTHON=1
        shift
        ;;
      --skip-provision)
        SKIP_PROVISION=1
        shift
        ;;
      --update-oai)
        UPDATE_OAI=1
        shift
        ;;
      --dev)
        INSTALL_DEV=1
        shift
        ;;
      --launch)
        RUN_LAUNCH=1
        shift
        ;;
      --validate)
        RUN_VALIDATE=1
        shift
        ;;
      --help)
        usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  require_regular_user
  require_command sudo
  require_sudo_session

  install_system_packages
  install_mongodb
  install_open5gs
  configure_open5gs_networking
  clone_oai
  build_oai
  setup_python_env
  write_runtime_env
  provision_subscribers
  verify_local_setup
  launch_stack
  validate_stack

  log "Setup complete"
  printf 'Runtime env file: %s\n' "$RUNTIME_ENV_FILE"
  printf 'To launch later:\n'
  printf '  bash %q --mode supervised\n' "$REPO_ROOT/src/launch_stack.sh"
  printf 'To stop:\n'
  printf '  bash %q --stop\n' "$REPO_ROOT/src/launch_stack.sh"
}

main "$@"
