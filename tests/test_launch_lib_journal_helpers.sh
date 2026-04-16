#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/journal_helpers.sh
source "$REPO_ROOT/src/launch_lib/journal_helpers.sh"

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
exec "$@"
EOF
chmod +x "$stub_dir/sudo"

cat > "$stub_dir/journalctl" <<'EOF'
#!/usr/bin/env bash
cat <<'LOG'
boot complete
Registration reject from test
LOG
EOF
chmod +x "$stub_dir/journalctl"

export PATH="$stub_dir:$PATH"

METRICS_OUT_PATH="$tmp_dir/metrics.jsonl"
cat > "$METRICS_OUT_PATH" <<'JSONL'
{"line":1}
{"line":2}
JSONL

log_file="$tmp_dir/amf.log"
cat > "$log_file" <<'LOG'
line one
line two
Registration reject sample
LOG

assert_eq "2" "$(journal_helpers_metrics_line_count)" "metrics line count"
assert_eq "3" "$(journal_helpers_root_file_line_count "$log_file")" "root file line count"

if ! journal_helpers_root_file_contains_pattern_since_line "$log_file" 1 'Registration reject'; then
  echo "Expected pattern lookup to match after offset" >&2
  exit 1
fi

first_match="$(journal_helpers_root_file_first_match_since_line "$log_file" 0 'Registration reject')"
assert_eq "Registration reject sample" "$first_match" "first match since line"

unit_match="$(journal_helpers_root_unit_first_match_since_epoch fake.service 0 'Registration reject')"
assert_eq "Registration reject from test" "$unit_match" "journalctl first match"

echo "launch_lib/journal_helpers.sh tests passed"
