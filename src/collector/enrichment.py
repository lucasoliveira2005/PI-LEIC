"""Event enrichment: family classification, D1 contract field derivation, source loading."""

from __future__ import annotations

import json
import urllib.parse
from datetime import datetime, timezone
from typing import Dict, List, Optional

from shared.identity import extract_cell_ue_entities

from .config import METRICS_SCHEMA_VERSION, SOURCES_CONFIG


def required_source_keys() -> List[str]:
    return ["source_id", "gnb_id", "ws_url"]


def source_endpoint(source: Dict) -> str:
    return source.get("ws_url", "-")


def load_sources() -> List[Dict]:
    with SOURCES_CONFIG.open("r", encoding="utf-8") as f:
        sources = json.load(f)

    if not isinstance(sources, list) or not sources:
        raise ValueError(f"Expected a non-empty list in {SOURCES_CONFIG}")

    required_keys = set(required_source_keys())
    for source in sources:
        missing = required_keys.difference(source)
        if missing:
            missing_str = ", ".join(sorted(missing))
            raise ValueError(f"Missing keys in source config {source}: {missing_str}")

        sid = source.get("source_id", "?")
        ws_url = source.get("ws_url", "")
        scheme = urllib.parse.urlparse(ws_url).scheme
        if scheme not in {"ws", "wss"}:
            raise ValueError(
                f"Source '{sid}' has invalid ws_url '{ws_url}': "
                f"scheme must be 'ws' or 'wss', got '{scheme or '(empty)'}'"
            )

    return sources


def metric_family(payload: Dict) -> str:
    if "cells" in payload:
        return "cells"
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


def _calculate_bler_pct(ue_metrics: Dict) -> Optional[float]:
    """Derive DL retransmission ratio from per-UE counters.

    Supports two counter naming conventions:
    - Newer srsRAN: ``dl_nof_nok`` / ``dl_nof_ok``
    - Older srsRAN: ``dl_retx`` / ``dl_ok``

    Returns None when the required counters are absent.
    """
    nok = (
        ue_metrics.get("dl_nof_nok")
        if ue_metrics.get("dl_nof_nok") is not None
        else ue_metrics.get("dl_retx")
    )
    ok = (
        ue_metrics.get("dl_nof_ok")
        if ue_metrics.get("dl_nof_ok") is not None
        else ue_metrics.get("dl_ok")
    )
    if nok is None:
        return None
    total = float(nok) + float(ok or 0)
    if total <= 0:
        return None
    return round(float(nok) / total * 100.0, 2)


def extract_contract_fields(payload: Dict) -> Dict:
    """Extract and derive D1 contract fields from a srsRAN metrics payload.

    Fields derivable from the WebSocket metrics path:
      cell_id, ue_id   — resolved via entity extraction (pci + ue_identity)
      throughput_mbps  — sum of dl_brate + ul_brate from the first UE entity, in Mbps
      bler_pct         — DL retransmission ratio from the first UE entity when counters
                         are present (dl_nof_nok / (dl_nof_ok + dl_nof_nok), or the
                         older dl_retx / (dl_ok + dl_retx) naming convention)

    Fields that require the E2/RIC interface and are NOT populated here:
      prb_usage_pct — needs PRB grant/capacity reporting from the scheduler
      latency_ms    — not exported via the WebSocket metrics path
      rsrp_dbm      — not exported via the WebSocket metrics path
    """
    contract_fields: Dict = {}

    # Pass through any contract field already present at the top level — the
    # future E2SM KPM adapter (Phase 1) will supply these directly.
    for key in (
        "cell_id",
        "ue_id",
        "latency_ms",
        "throughput_mbps",
        "prb_usage_pct",
        "bler_pct",
        "rsrp_dbm",
    ):
        value = payload.get(key)
        if value not in (None, ""):
            contract_fields[key] = value

    entities = extract_cell_ue_entities(payload)
    if not entities:
        return contract_fields

    first_entity = entities[0]
    ue_metrics = first_entity.get("ue") or {}

    # cell_id and ue_id from entity extraction.
    if "cell_id" not in contract_fields and first_entity.get("pci") is not None:
        contract_fields["cell_id"] = first_entity["pci"]

    if "ue_id" not in contract_fields:
        ue_identity = first_entity.get("ue_identity")
        if isinstance(ue_identity, str) and ue_identity:
            contract_fields["ue_id"] = (
                ue_identity.split(":", 1)[1] if ":" in ue_identity else ue_identity
            )

    # throughput_mbps: derived from DL + UL bitrate (bits/s → Mbit/s).
    if "throughput_mbps" not in contract_fields:
        dl = ue_metrics.get("dl_brate")
        ul = ue_metrics.get("ul_brate")
        if dl is not None or ul is not None:
            contract_fields["throughput_mbps"] = round(
                (float(dl or 0) + float(ul or 0)) / 1_000_000, 4
            )

    # bler_pct: DL retransmission ratio, if counters are available.
    if "bler_pct" not in contract_fields:
        bler = _calculate_bler_pct(ue_metrics)
        if bler is not None:
            contract_fields["bler_pct"] = bler

    return contract_fields


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
    endpoint_value = source.get("ws_url")

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


def summarize_event(event: Dict) -> str:
    payload = event["raw_payload"]
    family = event["metric_family"]
    source_id = event["source_id"]

    if family == "cells":
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

    return f"[{source_id}] {family} timestamp={event.get('timestamp') or '-'}"
