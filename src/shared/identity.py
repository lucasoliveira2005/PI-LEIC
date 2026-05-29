#!/usr/bin/env python3
"""UE entity extraction and identity resolution."""

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
    oai_stats = payload.get("oai_mac_stats")
    if isinstance(oai_stats, dict):
        return extract_oai_mac_ue_entities(oai_stats)

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


def extract_oai_mac_ue_entities(oai_stats: Dict) -> List[Dict]:
    ue_list = oai_stats.get("ues")
    if not isinstance(ue_list, list):
        return []

    entities = []
    pci = oai_stats.get("pci")
    for ue_index, ue_metrics in enumerate(ue_list):
        if not isinstance(ue_metrics, dict):
            continue

        ue_copy = dict(ue_metrics)
        if ue_copy.get("dl_brate") is None and ue_copy.get("dl_goodput_mbps") is not None:
            ue_copy["dl_brate"] = float(ue_copy["dl_goodput_mbps"]) * 1_000_000.0
        if ue_copy.get("ul_brate") is None and ue_copy.get("ul_goodput_mbps") is not None:
            ue_copy["ul_brate"] = float(ue_copy["ul_goodput_mbps"]) * 1_000_000.0
        if ue_copy.get("pusch_snr_db") is None and ue_copy.get("ul_snr_db") is not None:
            ue_copy["pusch_snr_db"] = ue_copy["ul_snr_db"]
        if ue_copy.get("pucch_snr_db") is None and ue_copy.get("dl_snr_db") is not None:
            ue_copy["pucch_snr_db"] = ue_copy["dl_snr_db"]

        entity = {
            "cell_index": 0,
            "ue_index": ue_index,
            "ue_identity": build_ue_identity(ue_copy, 0, ue_index),
            "ue": ue_copy,
        }
        if pci is not None:
            entity["pci"] = pci
        entities.append(entity)

    return entities
