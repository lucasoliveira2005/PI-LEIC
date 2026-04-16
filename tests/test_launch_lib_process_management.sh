#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/common.sh
source "$REPO_ROOT/src/launch_lib/common.sh"
# shellcheck source=src/launch_lib/process_management.sh
source "$REPO_ROOT/src/launch_lib/process_management.sh"

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

cat > "$stub_dir/ps" <<'EOF'
#!/usr/bin/env bash
cat <<'PS'
 101 gnb /usr/bin/gnb -c config/gnb_gnb1_zmq.yaml
 102 srsue /usr/bin/srsue config/ue1_zmq.conf.txt
 103 python3 /usr/bin/python3 src/metrics_collector.py
 104 python /usr/bin/python src/dashboard.py
PS
EOF
chmod +x "$stub_dir/ps"

export PATH="$stub_dir:$PATH"
DRY_RUN=1

assert_eq "101" "$(process_management_find_pids_by_comm_and_needle gnb gnb1_zmq | tr -d '[:space:]')" "find by command and needle"
assert_eq "103" "$(process_management_find_python_pids_by_needle metrics_collector | tr -d '[:space:]')" "find python process"

kill_output="$(process_management_kill_matching_pids test-proc 200 201)"
if [[ "$kill_output" != *"Would terminate stale test-proc processes: 200, 201"* ]]; then
  echo "Expected dry-run kill output" >&2
  echo "$kill_output" >&2
  exit 1
fi

group_kill_output="$(process_management_kill_processes_for_comm_and_needles gnb-clean gnb gnb1_zmq.yaml)"
if [[ "$group_kill_output" != *"Would terminate stale gnb-clean processes: 101"* ]]; then
  echo "Expected grouped dry-run kill output" >&2
  echo "$group_kill_output" >&2
  exit 1
fi

echo "launch_lib/process_management.sh tests passed"
