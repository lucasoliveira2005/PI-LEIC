#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/common.sh
source "$REPO_ROOT/src/launch_lib/common.sh"
# shellcheck source=src/launch_lib/root_runtime.sh
source "$REPO_ROOT/src/launch_lib/root_runtime.sh"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "Assertion failed: ${message}" >&2
    echo "  expected: ${expected}" >&2
    echo "  actual:   ${actual}" >&2
    exit 1
  fi
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_dir="$tmp_dir/stubs"
mkdir -p "$stub_dir"

cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-n" ]]; then
  shift
fi
if [[ "${1:-}" == "-v" ]]; then
  exit 0
fi
exec "$@"
EOF
chmod +x "$stub_dir/sudo"

cat > "$stub_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "show" ]]; then
  unit="${3:-}"
  if [[ "$unit" == "known.service" ]]; then
    echo "loaded"
  else
    echo "not-found"
  fi
  exit 0
fi
exit 0
EOF
chmod +x "$stub_dir/systemctl"

export PATH="$stub_dir:$PATH"

DRY_RUN=1
WORKDIR="$tmp_dir"
SUDO_KEEPALIVE_INTERVAL_SECONDS=1
SUDO_KEEPALIVE_PID=""
UNIT_PREFIX="pi-leic"

root_output="$(root_runtime_start_root_unit pi-leic-test.service Test /bin/echo hello)"
if [[ "$root_output" != *"[root unit pi-leic-test.service]"* ]]; then
  echo "Expected root dry-run output" >&2
  echo "$root_output" >&2
  exit 1
fi

user_output="$(root_runtime_start_user_unit pi-leic-user.service TestUser /bin/echo hello)"
if [[ "$user_output" != *"[user unit pi-leic-user.service]"* ]]; then
  echo "Expected user dry-run output" >&2
  echo "$user_output" >&2
  exit 1
fi

source_units=(known.service missing.service)
target_units=()
root_runtime_collect_known_user_units source_units target_units
assert_eq "1" "${#target_units[@]}" "collect known user units count"
assert_eq "known.service" "${target_units[0]}" "collect known user units value"

root_runtime_require_sudo_session
if [[ -z "$SUDO_KEEPALIVE_PID" ]]; then
  echo "Expected keepalive pid to be set" >&2
  exit 1
fi
kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
SUDO_KEEPALIVE_PID=""

echo "launch_lib/root_runtime.sh tests passed"
