#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, Iterable, Iterator, List, Optional


def extract_payload(entry: Dict) -> Dict:
    return entry.get("raw_payload") or entry.get("payload") or entry


def build_ue_identity(ue_metrics: Dict, cell_index: int, ue_index: int) -> str:
    ue_value = ue_metrics.get("ue")
    if ue_value not in (None, ""):
        return f"ue:{ue_value}"

    rnti_value = ue_metrics.get("rnti")
    if rnti_value not in (None, ""):
        return f"rnti:{rnti_value}"

    return f"cell{cell_index}-ue{ue_index}"


def extract_cell_ue_entities(payload: Dict) -> List[Dict]:
    cells = payload.get("cells") or []
    if not isinstance(cells, list):
        return []

    entities = []

    for cell_index, cell in enumerate(cells):
        if not isinstance(cell, dict):
            continue

        cell_metrics = cell.get("cell_metrics") or {}
        pci = cell_metrics.get("pci") if isinstance(cell_metrics, dict) else None

        ue_list = cell.get("ue_list") or []
        if not isinstance(ue_list, list):
            continue

        for ue_index, ue_metrics in enumerate(ue_list):
            if not isinstance(ue_metrics, dict):
                continue

            entity = {
                "cell_index": cell_index,
                "ue_index": ue_index,
                "ue_identity": build_ue_identity(ue_metrics, cell_index, ue_index),
                "ue": dict(ue_metrics),
            }
            if pci is not None:
                entity["pci"] = pci

            entities.append(entity)

    return entities


class MetricsLogReader:
    def __init__(
        self,
        log_file: Path,
        include_rotated: bool = True,
        max_archives: Optional[int] = None,
    ) -> None:
        self.log_file = Path(log_file)
        self.include_rotated = include_rotated
        self.max_archives = max_archives

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

    def latest_cells_by_source(self) -> Dict[str, Dict]:
        latest_by_source = {}

        for entry in self.iter_events():
            source_id = entry.get("source_id", "single")
            payload = extract_payload(entry)

            entities = extract_cell_ue_entities(payload)
            if not entities:
                continue

            latest_by_source[source_id] = {
                "timestamp": (
                    entry.get("timestamp")
                    or payload.get("timestamp")
                    or entry.get("collector_timestamp")
                ),
                "entities": entities,
            }

        return latest_by_source
