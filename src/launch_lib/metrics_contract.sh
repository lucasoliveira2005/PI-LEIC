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


def source_signature(source_entry):
    entities = source_entry.get("entities") or []
    normalized_entities = []

    for entity in entities:
        if not isinstance(entity, dict):
            continue

        normalized_entities.append(
            {
                "cell_index": entity.get("cell_index"),
                "ue_index": entity.get("ue_index"),
                "ue_identity": entity.get("ue_identity"),
                "pci": entity.get("pci"),
                "ue": entity.get("ue") if isinstance(entity.get("ue"), dict) else {},
            }
        )

    normalized_entities.sort(
        key=lambda item: (
            item.get("cell_index", 0),
            item.get("ue_index", 0),
            str(item.get("ue_identity", "")),
        )
    )

    return json.dumps(
        {
            "timestamp": source_entry.get("timestamp"),
            "entities": normalized_entities,
        },
        sort_keys=True,
        ensure_ascii=False,
    )


reader = MetricsLogReader(
    metrics_path,
    include_rotated=log_include_rotated,
    max_archives=log_max_archives,
    sqlite_path=sqlite_path if sqlite_enabled else None,
    prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()

baseline = {}
for source_id in required_sources:
    source_entry = latest_by_source.get(source_id)
    if source_entry is not None:
        baseline[source_id] = source_signature(source_entry)

print(json.dumps(baseline, sort_keys=True, ensure_ascii=False))
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
import json
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


def source_signature(source_entry):
    entities = source_entry.get("entities") or []
    normalized_entities = []

    for entity in entities:
        if not isinstance(entity, dict):
            continue

        normalized_entities.append(
            {
                "cell_index": entity.get("cell_index"),
                "ue_index": entity.get("ue_index"),
                "ue_identity": entity.get("ue_identity"),
                "pci": entity.get("pci"),
                "ue": entity.get("ue") if isinstance(entity.get("ue"), dict) else {},
            }
        )

    normalized_entities.sort(
        key=lambda item: (
            item.get("cell_index", 0),
            item.get("ue_index", 0),
            str(item.get("ue_identity", "")),
        )
    )

    return json.dumps(
        {
            "timestamp": source_entry.get("timestamp"),
            "entities": normalized_entities,
        },
        sort_keys=True,
        ensure_ascii=False,
    )


try:
    baseline_signatures = json.loads(baseline_file.read_text(encoding="utf-8"))
except Exception:
    baseline_signatures = {}

reader = MetricsLogReader(
    metrics_path,
    include_rotated=log_include_rotated,
    max_archives=log_max_archives,
    sqlite_path=sqlite_path if sqlite_enabled else None,
    prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()

for source_id in required_sources:
    source_entry = latest_by_source.get(source_id)
    if source_entry is None:
        print(f"{source_id}\t0\t0\t0")
        continue

    entities = source_entry.get("entities") or []
    has_attach_entities = 1 if len(entities) > 0 else 0

    current_signature = source_signature(source_entry)
    baseline_signature = baseline_signatures.get(source_id)
    is_fresh = 1
    if baseline_signature is not None and baseline_signature == current_signature:
        is_fresh = 0

    print(f"{source_id}\t1\t{has_attach_entities}\t{is_fresh}")
PY
}
