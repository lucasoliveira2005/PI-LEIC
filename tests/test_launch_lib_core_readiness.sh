#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=src/launch_lib/common.sh
source "$REPO_ROOT/src/launch_lib/common.sh"
# shellcheck source=src/launch_lib/journal_helpers.sh
source "$REPO_ROOT/src/launch_lib/journal_helpers.sh"
# shellcheck source=src/launch_lib/socket_probes.sh
source "$REPO_ROOT/src/launch_lib/socket_probes.sh"
# shellcheck source=src/launch_lib/core_readiness.sh
source "$REPO_ROOT/src/launch_lib/core_readiness.sh"

DRY_RUN=1
CORE_READINESS_TIMEOUT_SECONDS=9

output="$(core_readiness_wait_for_core_readiness 0 0 0)"

if [[ "$output" != *"Would wait up to 9s for dynamic Open5GS core readiness checks."* ]]; then
  echo "Unexpected dry-run core readiness output" >&2
  echo "$output" >&2
  exit 1
fi

echo "launch_lib/core_readiness.sh tests passed"
