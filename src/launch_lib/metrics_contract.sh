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
import time
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

from metrics_api import MetricsLogReader, parse_timestamp_to_epoch


def source_signature(source_entry):
    """Build a stable signature for the latest per-source cells snapshot."""

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


def coerce_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


reader = MetricsLogReader(
    metrics_path,
    include_rotated=log_include_rotated,
    max_archives=log_max_archives,
    sqlite_path=sqlite_path if sqlite_enabled else None,
    prefer_sqlite=sqlite_enabled,
)
latest_by_source = reader.latest_cells_by_source()
source_sequences = reader.source_sequences()

baseline_signatures = {}
baseline_sequences = {}
baseline_sample_epoch = {}

for source_id in required_sources:
    source_entry = latest_by_source.get(source_id)
    if source_entry is None:
        continue

    baseline_signatures[source_id] = source_signature(source_entry)

    sequence = coerce_int(source_entry.get("sequence"))
    if sequence is None:
        sequence = coerce_int(source_sequences.get(source_id))
    if sequence is not None:
        baseline_sequences[source_id] = sequence

    sample_epoch = parse_timestamp_to_epoch(source_entry.get("timestamp"))
    if sample_epoch is None:
        sample_epoch = parse_timestamp_to_epoch(source_entry.get("collector_timestamp"))
    if sample_epoch is not None:
        baseline_sample_epoch[source_id] = sample_epoch

baseline_payload = {
    "captured_at_epoch": time.time(),
    "signatures": baseline_signatures,
    "sequences": baseline_sequences,
    "sample_epoch": baseline_sample_epoch,
}
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
import json
import os
import sys
import time
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

from metrics_api import MetricsLogReader, parse_timestamp_to_epoch


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


def coerce_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def coerce_float(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_non_negative_float_env(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default

    try:
        value = float(raw)
    except ValueError:
        return default

    if value < 0:
        return default

    return value


def load_baseline_payload(path):
    try:
        raw_payload = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        raw_payload = {}

    if not isinstance(raw_payload, dict):
        return 0.0, {}, {}, {}

    if (
        "signatures" in raw_payload
        or "sequences" in raw_payload
        or "sample_epoch" in raw_payload
    ):
        signatures = raw_payload.get("signatures")
        sequences = raw_payload.get("sequences")
        sample_epoch = raw_payload.get("sample_epoch")
        captured_at_epoch = coerce_float(raw_payload.get("captured_at_epoch")) or 0.0

        if not isinstance(signatures, dict):
            signatures = {}
        if not isinstance(sequences, dict):
            sequences = {}
        if not isinstance(sample_epoch, dict):
            sample_epoch = {}

        return captured_at_epoch, signatures, sequences, sample_epoch

    # Backward compatibility for old baseline payloads that were signature-only maps.
    return 0.0, raw_payload, {}, {}


freshness_mode = os.environ.get("FRESHNESS_CHECK_MODE", "hybrid").strip().lower()
if freshness_mode not in {"signature", "sequence", "age", "hybrid"}:
    freshness_mode = "hybrid"

freshness_age_window_seconds = parse_non_negative_float_env(
    "FRESHNESS_AGE_WINDOW_SECONDS",
    15.0,
)
freshness_clock_skew_tolerance_seconds = parse_non_negative_float_env(
    "FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS",
    2.0,
)

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

    baseline_signature = baseline_signatures.get(source_id)
    current_signature = source_signature(source_entry)
    signature_changed = False
    if baseline_signature is not None:
        signature_changed = baseline_signature != current_signature

    baseline_source_known = (
        source_id in baseline_signatures
        or source_id in baseline_sequences
        or source_id in baseline_sample_epoch
    )

    baseline_sequence = coerce_int(baseline_sequences.get(source_id))
    current_sequence = coerce_int(source_entry.get("sequence"))
    if current_sequence is None:
        current_sequence = coerce_int(source_sequences.get(source_id))

    if baseline_sequence is None:
        sequence_advanced = signature_changed
    else:
        sequence_advanced = current_sequence is not None and current_sequence > baseline_sequence

    current_sample_epoch = source_sample_epochs.get(source_id)
    if current_sample_epoch is None:
        current_sample_epoch = parse_timestamp_to_epoch(source_entry.get("timestamp"))
    if current_sample_epoch is None:
        current_sample_epoch = parse_timestamp_to_epoch(source_entry.get("collector_timestamp"))

    baseline_epoch = coerce_float(baseline_sample_epoch.get(source_id))
    if baseline_epoch is None and baseline_source_known and baseline_captured_at_epoch > 0:
        baseline_epoch = baseline_captured_at_epoch

    age_recent = False
    if current_sample_epoch is not None and freshness_age_window_seconds > 0:
        age_recent = (time.time() - current_sample_epoch) <= freshness_age_window_seconds
        if baseline_epoch is not None:
            age_recent = age_recent and (
                current_sample_epoch + freshness_clock_skew_tolerance_seconds >= baseline_epoch
            )

    baseline_has_reference = (
        baseline_source_known
        or baseline_signature is not None
        or baseline_sequence is not None
        or baseline_epoch is not None
    )

    if not baseline_has_reference:
        is_fresh = 1
    elif freshness_mode == "signature":
        is_fresh = 1 if signature_changed else 0
    elif freshness_mode == "sequence":
        is_fresh = 1 if sequence_advanced else 0
    elif freshness_mode == "age":
        is_fresh = 1 if age_recent else 0
    else:
        is_fresh = 1 if (signature_changed or sequence_advanced or age_recent) else 0

    print(f"{source_id}\t1\t{has_attach_entities}\t{is_fresh}")
PY
}
