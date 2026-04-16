#!/usr/bin/env python3
"""Shared freshness contract helpers for launcher and validator scripts."""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple

from .env_utils import parse_non_negative_float_env
from metrics_api import parse_timestamp_to_epoch


def source_signature(source_entry: Dict) -> str:
    """Build a stable JSON signature for the latest per-source cells snapshot.

    The timestamp field is intentionally included in the signature so that two
    consecutive samples with identical UE metrics (e.g., the gNB is idle) still
    produce different signatures when their timestamps differ.  This means
    ``mode=signature`` treats a new sample as "fresh" whenever the gNB reports a
    different wall-clock time — which is almost always correct.  The trade-off is
    that a clock-frozen gNB would appear stale even if UE metrics are changing;
    in that case prefer ``mode=hybrid`` or ``mode=sequence``.
    """

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


def coerce_int(value: object) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def coerce_float(value: object) -> Optional[float]:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


@dataclass(frozen=True)
class FreshnessSettings:
    mode: str
    age_window_seconds: float
    clock_skew_tolerance_seconds: float


def settings_from_env() -> FreshnessSettings:
    mode = os.environ.get("FRESHNESS_CHECK_MODE", "hybrid").strip().lower()
    if mode not in {"signature", "sequence", "age", "hybrid"}:
        mode = "hybrid"

    return FreshnessSettings(
        mode=mode,
        age_window_seconds=parse_non_negative_float_env("FRESHNESS_AGE_WINDOW_SECONDS", 15.0),
        clock_skew_tolerance_seconds=parse_non_negative_float_env(
            "FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS", 2.0
        ),
    )


def load_baseline_payload(path: Path) -> Tuple[float, Dict[str, str], Dict[str, int], Dict[str, float]]:
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

        normalized_sequences = {}
        for source_id, sequence in sequences.items():
            parsed = coerce_int(sequence)
            if parsed is not None:
                normalized_sequences[str(source_id)] = parsed

        normalized_sample_epoch = {}
        for source_id, epoch in sample_epoch.items():
            parsed = coerce_float(epoch)
            if parsed is not None:
                normalized_sample_epoch[str(source_id)] = parsed

        normalized_signatures = {str(source_id): str(signature) for source_id, signature in signatures.items()}

        return (
            captured_at_epoch,
            normalized_signatures,
            normalized_sequences,
            normalized_sample_epoch,
        )

    # Backward compatibility for old baseline payloads that were signature-only maps.
    normalized_signatures = {str(source_id): str(signature) for source_id, signature in raw_payload.items()}
    return 0.0, normalized_signatures, {}, {}


def build_baseline_payload(
    latest_by_source: Dict[str, Dict],
    source_sequences: Dict[str, int],
    required_sources: Iterable[str],
    captured_at_epoch: Optional[float] = None,
) -> Dict:
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

    return {
        "captured_at_epoch": captured_at_epoch if captured_at_epoch is not None else time.time(),
        "signatures": baseline_signatures,
        "sequences": baseline_sequences,
        "sample_epoch": baseline_sample_epoch,
    }


def evaluate_source_freshness(
    source_id: str,
    source_entry: Dict,
    source_sequences: Dict[str, int],
    source_sample_epochs: Dict[str, Optional[float]],
    baseline_captured_at_epoch: float,
    baseline_signatures: Dict[str, str],
    baseline_sequences: Dict[str, int],
    baseline_sample_epoch: Dict[str, float],
    settings: FreshnessSettings,
) -> bool:
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
    if current_sample_epoch is not None and settings.age_window_seconds > 0:
        age_recent = (time.time() - current_sample_epoch) <= settings.age_window_seconds
        if baseline_epoch is not None:
            age_recent = age_recent and (
                current_sample_epoch + settings.clock_skew_tolerance_seconds >= baseline_epoch
            )

    baseline_has_reference = (
        baseline_source_known
        or baseline_signature is not None
        or baseline_sequence is not None
        or baseline_epoch is not None
    )

    if not baseline_has_reference:
        return True

    if settings.mode == "signature":
        return signature_changed
    if settings.mode == "sequence":
        return sequence_advanced
    if settings.mode == "age":
        return age_recent

    return signature_changed or sequence_advanced or age_recent
