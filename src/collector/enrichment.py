"""Event enrichment: family classification, D1 contract field derivation, source loading."""

from __future__ import annotations

import json
import os
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from shared.identity import extract_cell_ue_entities  # re-exported for collector consumers

from .config import METRICS_SCHEMA_VERSION, SOURCES_CONFIG


def required_source_keys() -> List[str]:
    return ["source_id", "gnb_id"]


def source_endpoint(source: Dict) -> str:
    return source.get("ws_url") or source.get("log_path") or "-"


def source_transport(source: Dict) -> str:
    return str(source.get("transport") or "websocket_json")


def resolve_oai_log_path(log_path: str) -> str:
    expanded = Path(os.path.expandvars(os.path.expanduser(str(log_path))))
    if expanded.is_absolute():
        return str(expanded)

    config_dir = SOURCES_CONFIG.resolve().parent
    base_dir = config_dir.parent if config_dir.name == "config" else config_dir
    return str((base_dir / expanded).resolve())


def load_sources() -> List[Dict]:
    with SOURCES_CONFIG.open("r", encoding="utf-8") as f:
        sources = json.load(f)

    if not isinstance(sources, list) or not sources:
        raise ValueError(f"Expected a non-empty list in {SOURCES_CONFIG}")

    for source in sources:
        required_keys = set(required_source_keys())
        transport = source_transport(source)
        if transport == "websocket_json":
            required_keys.add("ws_url")
        elif transport == "oai_mac_stats":
            required_keys.add("log_path")
        else:
            raise ValueError(
                f"Source '{source.get('source_id', '?')}' has unsupported transport '{transport}'"
            )

        missing = required_keys.difference(source)
        if missing:
            missing_str = ", ".join(sorted(missing))
            raise ValueError(f"Missing keys in source config {source}: {missing_str}")

        if transport == "websocket_json":
            sid = source.get("source_id", "?")
            ws_url = source.get("ws_url", "")
            scheme = urllib.parse.urlparse(ws_url).scheme
            if scheme not in {"ws", "wss"}:
                raise ValueError(
                    f"Source '{sid}' has invalid ws_url '{ws_url}': "
                    f"scheme must be 'ws' or 'wss', got '{scheme or '(empty)'}'"
                )
        elif transport == "oai_mac_stats":
            source["log_path"] = resolve_oai_log_path(str(source["log_path"]))

    return sources


def metric_family(payload: Dict) -> str:
    if "cells" in payload:
        return "cells"
    if "oai_mac_stats" in payload:
        return "oai_mac_stats"
    if "rlc_metrics" in payload:
        return "rlc_metrics"
    if "du_low" in payload:
        return "du_low"
    if "du" in payload:
        return "du"

    for key in payload:
        if key != "timestamp":
            return key

    return "unknown"


def classify_event_type(payload: Dict, family: str) -> str:
    event_type = payload.get("event_type")
    if isinstance(event_type, str):
        normalized = event_type.strip().lower()
        if normalized in {"metric", "alarm", "state"}:
            return normalized

    if family == "unknown":
        return "state"

    return "metric"


_CONTRACT_FIELD_KEYS = (
    "cell_id",
    "ue_id",
    "latency_ms",
    "throughput_mbps",
    "prb_usage_pct",
    "bler_pct",
    "rsrp_dbm",
)


def extract_contract_fields(payload: Dict) -> Dict:
    """Pass through D1 contract fields already present at the payload top level.

    The current WebSocket metrics path does **not** supply these fields — a
    cells/du/du_low payload is multi-UE/multi-cell, and any single value at the
    event level can only describe one entity. Per-UE truth lives inside
    ``raw_payload.cells[].ue_list[]`` and the denormalized ``metrics_cell_entities``
    SQLite rows; consumers compute per-UE throughput/BLER from those snapshots.

    The pass-through is kept as a compatibility hook for KPI payloads that are
    already scoped to a (cell, UE) pair.
    """
    return {
        key: payload[key]
        for key in _CONTRACT_FIELD_KEYS
        if payload.get(key) not in (None, "")
    }


def extract_context(payload: Dict) -> Dict:
    context: Dict = {}

    cells = payload.get("cells") or []
    if cells:
        # For cells payloads, authoritative UE/cell context lives inside raw_payload.
        # Avoid ambiguous top-level fields derived from the first entity only.
        return context

    rlc_metrics = payload.get("rlc_metrics")
    if isinstance(rlc_metrics, dict):
        if "ue_id" in rlc_metrics:
            context["ue"] = rlc_metrics["ue_id"]
        if "du_id" in rlc_metrics:
            context["cell_index"] = rlc_metrics["du_id"]

    du = payload.get("du") or {}
    mac_dl = (
        du.get("du_high", {})
        .get("mac", {})
        .get("dl", [])
    )
    if mac_dl and isinstance(mac_dl[0], dict) and "pci" in mac_dl[0]:
        context["pci"] = mac_dl[0]["pci"]

    return context


def enrich_event(source: Dict, payload: Dict) -> Dict:
    family = metric_family(payload)
    endpoint_value = source_endpoint(source)

    event = {
        "collector_timestamp": datetime.now(timezone.utc).isoformat(),
        "source_id": source["source_id"],
        "gnb_id": source["gnb_id"],
        "source_endpoint": endpoint_value,
        "metric_family": family,
        "event_type": classify_event_type(payload, family),
        "schema_version": METRICS_SCHEMA_VERSION,
        "timestamp": payload.get("timestamp"),
        "raw_payload": payload,
    }
    event.update(extract_context(payload))
    event.update(extract_contract_fields(payload))
    return event


def summarize_event(
    event: Dict, entities: Optional[List[Dict[str, Any]]] = None
) -> str:
    payload = event["raw_payload"]
    family = event["metric_family"]
    source_id = event["source_id"]

    if family == "cells":
        if entities is None:
            entities = extract_cell_ue_entities(payload)
        if entities:
            sample = entities[0]
            sample_ue = sample.get("ue") or {}
            snr = sample_ue.get("pucch_snr_db", sample_ue.get("pusch_snr_db", 0))
            return (
                f"[{source_id}] cells "
                f"entities={len(entities)}"
                f" sample={sample.get('ue_identity', '-')}"
                f" dl={sample_ue.get('dl_brate', 0):.1f}"
                f" ul={sample_ue.get('ul_brate', 0):.1f}"
                f" snr={snr:.2f}"
            )
        return f"[{source_id}] cells entities=0"

    if family == "oai_mac_stats":
        stats = payload.get("oai_mac_stats") if isinstance(payload, dict) else {}
        ues = stats.get("ues") if isinstance(stats, dict) else []
        if isinstance(ues, list) and ues:
            sample = ues[0] if isinstance(ues[0], dict) else {}
            dl_goodput = sample.get("dl_goodput_mbps") or 0
            ul_goodput = sample.get("ul_goodput_mbps") or 0
            return (
                f"[{source_id}] oai_mac_stats "
                f"ues={len(ues)} sample=rnti:{sample.get('rnti', '-')}"
                f" dl_goodput={dl_goodput:.2f}"
                f" ul_goodput={ul_goodput:.2f}"
            )
        return f"[{source_id}] oai_mac_stats ues=0"

    return f"[{source_id}] {family} timestamp={event.get('timestamp') or '-'}"
