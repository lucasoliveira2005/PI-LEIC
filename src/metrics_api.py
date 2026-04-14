#!/usr/bin/env python3
"""Shared metrics reader API used by dashboard, launcher health checks, and validation."""

from __future__ import annotations

import json
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, Iterator, Optional

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from metrics_identity import extract_cell_ue_entities


def extract_payload(entry: Dict) -> Dict:
    return entry.get("raw_payload") or entry.get("payload") or entry


def parse_timestamp_to_epoch(value: object) -> Optional[float]:
    if value is None:
        return None

    if isinstance(value, (int, float)):
        return float(value)

    if not isinstance(value, str):
        return None

    candidate = value.strip()
    if not candidate:
        return None

    if candidate.endswith("Z"):
        candidate = candidate[:-1] + "+00:00"

    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError:
        return None

    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)

    return parsed.timestamp()


class MetricsLogReader:
    """Read latest metrics from SQLite (preferred) or JSONL fallback files."""

    def __init__(
        self,
        log_file: Path,
        include_rotated: bool = True,
        max_archives: Optional[int] = None,
        sqlite_path: Optional[Path] = None,
        prefer_sqlite: bool = True,
    ) -> None:
        self.log_file = Path(log_file)
        self.include_rotated = include_rotated
        self.max_archives = max_archives
        self.sqlite_path = Path(sqlite_path) if sqlite_path else None
        self.prefer_sqlite = prefer_sqlite

    def iter_log_paths(self) -> Iterable[Path]:
        paths = []

        if self.include_rotated:
            archives = []
            index = 1
            while True:
                archive = self.log_file.with_name(f"{self.log_file.name}.{index}")
                if not archive.exists():
                    break
                archives.append((index, archive))
                index += 1

            if self.max_archives is not None:
                archives = archives[: max(0, self.max_archives)]

            # .N is the oldest archive and .1 is the newest archive.
            for _idx, path in reversed(archives):
                paths.append(path)

        paths.append(self.log_file)
        return paths

    def iter_events(self) -> Iterator[Dict]:
        for path in self.iter_log_paths():
            if not path.exists():
                continue

            try:
                with path.open("r", encoding="utf-8") as handle:
                    for line in handle:
                        line = line.strip()
                        if not line:
                            continue

                        try:
                            event = json.loads(line)
                        except json.JSONDecodeError:
                            continue

                        if isinstance(event, dict):
                            yield event
            except OSError:
                continue

    def _latest_cells_by_source_from_jsonl(self) -> Dict[str, Dict]:
        latest_by_source = {}
        sequence_by_source = {}

        for entry in self.iter_events():
            source_id = entry.get("source_id", "single")
            payload = extract_payload(entry)

            entities = extract_cell_ue_entities(payload)
            if not entities:
                continue

            sequence_by_source[source_id] = sequence_by_source.get(source_id, 0) + 1

            latest_by_source[source_id] = {
                "timestamp": (
                    entry.get("timestamp")
                    or payload.get("timestamp")
                    or entry.get("collector_timestamp")
                ),
                "collector_timestamp": entry.get("collector_timestamp"),
                "sequence": sequence_by_source[source_id],
                "entities": entities,
            }

        return latest_by_source

    def _latest_cells_by_source_from_sqlite(self) -> Optional[Dict[str, Dict]]:
        if not self.sqlite_path or not self.sqlite_path.exists():
            return None

        query = """
            WITH source_event_counts AS (
                SELECT
                    source_id,
                    COUNT(*) AS source_sequence
                FROM metrics_events
                WHERE metric_family = 'cells'
                GROUP BY source_id
            ),
            latest_source_events AS (
                SELECT
                    id,
                    source_id,
                    event_timestamp,
                    collector_timestamp,
                    ROW_NUMBER() OVER (
                        PARTITION BY source_id
                        ORDER BY collector_timestamp DESC, id DESC
                    ) AS row_num
                FROM metrics_events
                WHERE metric_family = 'cells'
            )
            SELECT
                e.source_id,
                e.event_timestamp,
                e.collector_timestamp,
                sec.source_sequence,
                ce.cell_index,
                ce.ue_index,
                ce.ue_identity,
                ce.pci,
                ce.ue_json
            FROM latest_source_events AS lse
            JOIN metrics_events AS e
              ON e.id = lse.id
             AND lse.row_num = 1
            JOIN source_event_counts AS sec
              ON sec.source_id = e.source_id
            JOIN metrics_cell_entities AS ce
              ON ce.event_id = e.id
            ORDER BY e.source_id, ce.cell_index, ce.ue_index
        """

        try:
            with sqlite3.connect(str(self.sqlite_path)) as conn:
                rows = conn.execute(query).fetchall()
        except sqlite3.Error:
            return None

        latest_by_source = {}
        for (
            source_id,
            event_timestamp,
            collector_timestamp,
            source_sequence,
            cell_index,
            ue_index,
            ue_identity,
            pci,
            ue_json,
        ) in rows:
            source_entry = latest_by_source.setdefault(
                source_id,
                {
                    "timestamp": event_timestamp or collector_timestamp,
                    "collector_timestamp": collector_timestamp,
                    "sequence": int(source_sequence or 0),
                    "entities": [],
                },
            )

            try:
                ue_metrics = json.loads(ue_json) if ue_json else {}
            except json.JSONDecodeError:
                ue_metrics = {}

            entity = {
                "cell_index": cell_index,
                "ue_index": ue_index,
                "ue_identity": ue_identity,
                "ue": ue_metrics,
            }
            if pci is not None:
                entity["pci"] = pci

            source_entry["entities"].append(entity)

        return latest_by_source

    def latest_cells_by_source(self) -> Dict[str, Dict]:
        if self.prefer_sqlite:
            latest_from_sqlite = self._latest_cells_by_source_from_sqlite()
            if latest_from_sqlite:
                return latest_from_sqlite

        return self._latest_cells_by_source_from_jsonl()

    def source_sequences(self) -> Dict[str, int]:
        if self.prefer_sqlite and self.sqlite_path and self.sqlite_path.exists():
            query = """
                SELECT source_id, COUNT(*) AS source_sequence
                FROM metrics_events
                WHERE metric_family = 'cells'
                GROUP BY source_id
            """

            try:
                with sqlite3.connect(str(self.sqlite_path)) as conn:
                    rows = conn.execute(query).fetchall()
            except sqlite3.Error:
                rows = []

            if rows:
                return {source_id: int(source_sequence or 0) for source_id, source_sequence in rows}

        sequences = {}
        for event in self.iter_events():
            source_id = event.get("source_id", "single")
            payload = extract_payload(event)

            entities = extract_cell_ue_entities(payload)
            if not entities:
                continue

            sequences[source_id] = sequences.get(source_id, 0) + 1

        return sequences

    def latest_sample_epoch_by_source(self) -> Dict[str, Optional[float]]:
        latest_by_source = self.latest_cells_by_source()
        sample_epochs = {}

        for source_id, source_entry in latest_by_source.items():
            sample_epoch = parse_timestamp_to_epoch(source_entry.get("timestamp"))
            if sample_epoch is None:
                sample_epoch = parse_timestamp_to_epoch(source_entry.get("collector_timestamp"))
            sample_epochs[source_id] = sample_epoch

        return sample_epochs
