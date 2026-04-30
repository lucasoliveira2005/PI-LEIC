#!/usr/bin/env bash

metrics_contract_write_baseline_signatures() {
  local output_file="$1"
  shift

  "$PYTHON_BIN_RESOLVED" - \
    "$REPO_ROOT_PATH" \
    "$METRICS_OUT_PATH" \
    "$METRICS_LOG_INCLUDE_ROTATED" \
    "$METRICS_LOG_MAX_ARCHIVES" \
    "$METRICS_SQLITE_ENABLED" \
    "$METRICS_SQLITE_PATH" \
    "$@" > "$output_file" <<'PY'
import json
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
metrics_path = Path(sys.argv[2])
log_include_rotated = sys.argv[3].strip().lower() not in {"0", "false", "no", "off"}
log_max_archives = int(sys.argv[4])
sqlite_enabled = sys.argv[5].strip().lower() not in {"0", "false", "no", "off"}
sqlite_path = Path(sys.argv[6])
required_sources = sys.argv[7:]

src_dir = repo_root / "src"
if str(src_dir) not in sys.path:
    sys.path.insert(0, str(src_dir))

from metrics_api import MetricsLogReader
from metrics_liveness import build_baseline_payload


reader = MetricsLogReader(
    metrics_path,
    include_rotated=log_include_rotated,
    max_archives=log_max_archives,
    sqlite_path=sqlite_path if sqlite_enabled else None,
    prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()
source_sequences = reader.source_sequences()

baseline_payload = build_baseline_payload(
    latest_by_source,
    source_sequences,
    required_sources,
)
print(json.dumps(baseline_payload, sort_keys=True, ensure_ascii=False))
PY
}

metrics_contract_collect_health_states() {
  local baseline_file="$1"
  shift

  "$PYTHON_BIN_RESOLVED" - \
    "$REPO_ROOT_PATH" \
    "$METRICS_OUT_PATH" \
    "$METRICS_LOG_INCLUDE_ROTATED" \
    "$METRICS_LOG_MAX_ARCHIVES" \
    "$METRICS_SQLITE_ENABLED" \
    "$METRICS_SQLITE_PATH" \
    "$baseline_file" \
    "$@" <<'PY'
import sys
from pathlib import Path

repo_root = Path(sys.argv[1]).resolve()
metrics_path = Path(sys.argv[2])
log_include_rotated = sys.argv[3].strip().lower() not in {"0", "false", "no", "off"}
log_max_archives = int(sys.argv[4])
sqlite_enabled = sys.argv[5].strip().lower() not in {"0", "false", "no", "off"}
sqlite_path = Path(sys.argv[6])
baseline_file = Path(sys.argv[7])
required_sources = sys.argv[8:]

src_dir = repo_root / "src"
if str(src_dir) not in sys.path:
    sys.path.insert(0, str(src_dir))

from metrics_api import MetricsLogReader
from metrics_liveness import (
    evaluate_source_freshness,
    load_baseline_payload,
    settings_from_env,
)


settings = settings_from_env()
baseline_captured_at_epoch, baseline_signatures, baseline_sequences, baseline_sample_epoch = load_baseline_payload(
    baseline_file
)

reader = MetricsLogReader(
    metrics_path,
    include_rotated=log_include_rotated,
    max_archives=log_max_archives,
    sqlite_path=sqlite_path if sqlite_enabled else None,
    prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()
source_sequences = reader.source_sequences()
source_sample_epochs = reader.latest_sample_epoch_by_source()

for source_id in required_sources:
    source_entry = latest_by_source.get(source_id)
    if source_entry is None:
        print(f"{source_id}\t0\t0\t0")
        continue

    entities = source_entry.get("entities") or []
    has_attach_entities = 1 if len(entities) > 0 else 0
    is_fresh = evaluate_source_freshness(
        source_id,
        source_entry,
        source_sequences,
        source_sample_epochs,
        baseline_captured_at_epoch,
        baseline_signatures,
        baseline_sequences,
        baseline_sample_epoch,
        settings,
    )

    print(f"{source_id}\t1\t{has_attach_entities}\t{1 if is_fresh else 0}")
PY
}
