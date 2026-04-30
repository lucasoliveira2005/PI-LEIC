#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

create_stub_command() {
  local path="$1"

  cat > "$path" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$path"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

stub_dir="$tmp_dir/stubs"
mkdir -p "$stub_dir"

for cmd in sudo systemctl systemd-run ps ip ss; do
  create_stub_command "$stub_dir/$cmd"
done

cat > "$stub_dir/gnb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_dir/gnb"

cat > "$stub_dir/srsue" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_dir/srsue"

output_file="$tmp_dir/launch_dry_run.out"
error_file="$tmp_dir/launch_dry_run.err"
help_output="$tmp_dir/help.out"
stop_output="$tmp_dir/stop_dry_run.out"

if ! bash "$REPO_ROOT/src/launch_stack.sh" --help > "$help_output" 2> "$error_file"; then
  echo "Expected launch_stack --help to succeed" >&2
  cat "$error_file" >&2 || true
  exit 1
fi

if ! grep -q "Usage:" "$help_output" || ! grep -q -- "--dry-run" "$help_output"; then
  echo "Help output contract changed unexpectedly" >&2
  cat "$help_output" >&2 || true
  exit 1
fi

if ! env \
  PATH="$stub_dir:$PATH" \
  PYTHON_BIN="$(command -v python3)" \
  WORKDIR="$REPO_ROOT/src" \
  GNB_BIN="$stub_dir/gnb" \
  UE_BIN="$stub_dir/srsue" \
  DASHBOARD_ENABLED=0 \
  HEALTHCHECK_ENABLED=0 \
  bash "$REPO_ROOT/src/launch_stack.sh" --mode supervised --stop --dry-run > "$stop_output" 2> "$error_file"; then
  echo "Expected launch_stack stop dry run to succeed" >&2
  cat "$error_file" >&2 || true
  exit 1
fi

if ! grep -q "Would stop user units" "$stop_output"; then
  echo "Stop dry-run output did not include stop action details" >&2
  cat "$stop_output" >&2 || true
  exit 1
fi

if ! env \
  PATH="$stub_dir:$PATH" \
  PYTHON_BIN="$(command -v python3)" \
  WORKDIR="$REPO_ROOT/src" \
  GNB_BIN="$stub_dir/gnb" \
  UE_BIN="$stub_dir/srsue" \
  DASHBOARD_ENABLED=0 \
  HEALTHCHECK_ENABLED=0 \
  bash "$REPO_ROOT/src/launch_stack.sh" --mode supervised --dry-run > "$output_file" 2> "$error_file"; then
  echo "Expected launch_stack dry run to succeed" >&2
  cat "$error_file" >&2 || true
  exit 1
fi

if ! grep -q "Dry run complete" "$output_file"; then
  echo "Dry run output did not reach completion" >&2
  cat "$output_file" >&2 || true
  exit 1
fi

echo "launch_stack dry-run rootless shell test passed"
