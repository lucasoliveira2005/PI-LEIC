#!/usr/bin/env python3
from __future__ import annotations

from typing import Dict, List


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
