"""Build backend-neutral network observations for the agent."""

from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

from shared.identity import build_ue_identity


SCHEMA_VERSION = "network-observation.v1"
FORBIDDEN_AGENT_KEYS = {
    "ran_backend",
    "backend",
    "transport",
    "source_endpoint",
    "ws_url",
    "log_path",
    "rf_sim",
    "rfsim",
    "rfdevice",
    "port",
    "install_path",
    "process",
}


def _as_float(value: Any) -> Optional[float]:
    if value in (None, ""):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _as_int(value: Any) -> Optional[int]:
    if value in (None, ""):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _sum_values(values: Iterable[Optional[int]]) -> Optional[int]:
    concrete = [value for value in values if value is not None]
    if not concrete:
        return None
    return int(sum(concrete))


def _has_value(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, dict):
        return any(_has_value(item) for item in value.values())
    if isinstance(value, list):
        return any(_has_value(item) for item in value)
    return True


def _availability(observation: Dict[str, Any]) -> Dict[str, str]:
    ues = observation.get("ues") if isinstance(observation.get("ues"), list) else []
    cells = observation.get("cells") if isinstance(observation.get("cells"), list) else []

    radio_quality = any(_has_value(ue.get("radio_quality")) for ue in ues)
    throughput = any(_has_value(ue.get("throughput")) for ue in ues)
    reliability = any(_has_value(ue.get("reliability")) for ue in ues)
    scheduler = any(_has_value(ue.get("scheduler")) for ue in ues) or any(
        _has_value(cell.get("control_channel_load")) for cell in cells
    )
    latency = any(_has_value(ue.get("latency")) for ue in ues)
    core_session = any(
        any(
            isinstance(item, dict)
            and _as_int(item.get("lcid")) is not None
            and int(item["lcid"]) >= 4
            and ((_as_int(item.get("tx_bytes")) or 0) > 0 or (_as_int(item.get("rx_bytes")) or 0) > 0)
            for item in ((ue.get("traffic") or {}).get("lcid_bytes") or [])
        )
        for ue in ues
    )

    return {
        "radio_quality": "available" if radio_quality else "missing",
        "throughput": "available" if throughput else "missing",
        "reliability": "available" if reliability else "missing",
        "scheduler": "available" if scheduler else "missing",
        "latency": "available" if latency else "missing",
        "core_session": "partial" if core_session else "missing",
    }


def _assert_agent_safe(value: Any) -> None:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in FORBIDDEN_AGENT_KEYS:
                raise ValueError(f"forbidden agent observation key: {key}")
            _assert_agent_safe(item)
    elif isinstance(value, list):
        for item in value:
            _assert_agent_safe(item)


def _bler_from_ok_nok(ok: Any, nok: Any) -> Optional[float]:
    ok_value = _as_float(ok)
    nok_value = _as_float(nok)
    if ok_value is None or nok_value is None:
        return None
    total = ok_value + nok_value
    if total <= 0:
        return None
    return nok_value / total


def _brate_to_mbps(value: Any) -> Optional[float]:
    brate = _as_float(value)
    if brate is None:
        return None
    return brate / 1000.0


def _srsran_observation(payload: Dict[str, Any], timestamp: Optional[str]) -> Optional[Dict[str, Any]]:
    cells_payload = payload.get("cells")
    if not isinstance(cells_payload, list):
        return None

    cells: List[Dict[str, Any]] = []
    ues: List[Dict[str, Any]] = []

    for cell_index, cell in enumerate(cells_payload):
        if not isinstance(cell, dict):
            continue

        cell_id = f"cell-{cell_index}"
        cell_metrics = cell.get("cell_metrics") if isinstance(cell.get("cell_metrics"), dict) else {}
        cells.append(
            {
                "cell_id": cell_id,
                "pci": _as_int(cell_metrics.get("pci")),
                "prb_usage_pct": _as_float(
                    cell_metrics.get("prb_usage_pct")
                    or cell_metrics.get("dl_prb_usage_pct")
                    or cell_metrics.get("ul_prb_usage_pct")
                ),
                "control_channel_load": {
                    "pucch_rb_usage_pct": _as_float(cell_metrics.get("pucch_tot_rb_usage_avg")),
                    "cce_fail_dl": None,
                    "cce_fail_ul": None,
                },
            }
        )

        ue_list = cell.get("ue_list")
        if not isinstance(ue_list, list):
            continue

        for ue_index, ue_metrics in enumerate(ue_list):
            if not isinstance(ue_metrics, dict):
                continue

            ue_id = build_ue_identity(ue_metrics, cell_index, ue_index)
            ues.append(
                {
                    "ue_id": ue_id,
                    "cell_id": cell_id,
                    "sync_state": ue_metrics.get("sync_state"),
                    "radio_quality": {
                        "cqi": _as_int(ue_metrics.get("cqi")),
                        "rank_indicator": _as_int(ue_metrics.get("ri") or ue_metrics.get("rank_indicator")),
                        "rsrp_dbm": _as_float(ue_metrics.get("pusch_rsrp_db") or ue_metrics.get("rsrp_dbm")),
                        "sinr_db": _as_float(ue_metrics.get("pusch_sinr_db") or ue_metrics.get("sinr_db")),
                        "dl_snr_db": _as_float(ue_metrics.get("pucch_snr_db")),
                        "ul_snr_db": _as_float(ue_metrics.get("pusch_snr_db")),
                        "power_headroom_db": _as_float(ue_metrics.get("phr") or ue_metrics.get("power_headroom_db")),
                        "pcmax_dbm": _as_float(ue_metrics.get("pcmax_dbm")),
                    },
                    "throughput": {
                        "dl_goodput_mbps": _brate_to_mbps(ue_metrics.get("dl_brate")),
                        "ul_goodput_mbps": _brate_to_mbps(ue_metrics.get("ul_brate")),
                    },
                    "reliability": {
                        "dl_bler": _bler_from_ok_nok(ue_metrics.get("dl_nof_ok"), ue_metrics.get("dl_nof_nok")),
                        "ul_bler": _bler_from_ok_nok(ue_metrics.get("ul_nof_ok"), ue_metrics.get("ul_nof_nok")),
                        "dlsch_rounds": None,
                        "ulsch_rounds": None,
                        "dlsch_errors": _as_int(ue_metrics.get("dl_nof_nok")),
                        "ulsch_errors": _as_int(ue_metrics.get("ul_nof_nok")),
                        "pucch_dtx": _as_int(ue_metrics.get("pucch_dtx")),
                        "ulsch_dtx": _as_int(ue_metrics.get("ulsch_dtx")),
                    },
                    "scheduler": {
                        "dl_mcs": _as_int(ue_metrics.get("dl_mcs")),
                        "ul_mcs": _as_int(ue_metrics.get("ul_mcs")),
                        "ul_nprb": _as_int(ue_metrics.get("ul_nof_prb") or ue_metrics.get("ul_nprb")),
                    },
                    "traffic": {
                        "lcid_bytes": [],
                    },
                }
            )

    if not cells and not ues:
        return None

    observation = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": timestamp or payload.get("timestamp"),
        "cells": cells,
        "ues": ues,
    }
    observation["metric_availability"] = _availability(observation)
    return observation


def _oai_observation(payload: Dict[str, Any], timestamp: Optional[str]) -> Optional[Dict[str, Any]]:
    stats = payload.get("oai_mac_stats")
    if not isinstance(stats, dict):
        return None
    ue_payloads = stats.get("ues")
    if not isinstance(ue_payloads, list) or not ue_payloads:
        return None

    cell_id = "cell-0"
    cce_fail_dl = _sum_values(_as_int(ue.get("cce_fail_dl")) for ue in ue_payloads if isinstance(ue, dict))
    cce_fail_ul = _sum_values(_as_int(ue.get("cce_fail_ul")) for ue in ue_payloads if isinstance(ue, dict))
    cells = [
        {
            "cell_id": cell_id,
            "pci": _as_int(stats.get("pci")),
            "prb_usage_pct": _as_float(stats.get("prb_usage_pct")),
            "control_channel_load": {
                "pucch_rb_usage_pct": None,
                "cce_fail_dl": cce_fail_dl,
                "cce_fail_ul": cce_fail_ul,
            },
        }
    ]

    ues: List[Dict[str, Any]] = []
    for ue in ue_payloads:
        if not isinstance(ue, dict):
            continue
        rnti = ue.get("rnti")
        ue_id = f"rnti:{rnti}" if rnti not in (None, "") else f"cell0-ue{len(ues)}"
        ues.append(
            {
                "ue_id": ue_id,
                "cell_id": cell_id,
                "sync_state": ue.get("sync_state"),
                "radio_quality": {
                    "cqi": _as_int(ue.get("cqi")),
                    "rank_indicator": _as_int(ue.get("rank_indicator")),
                    "rsrp_dbm": _as_float(ue.get("rsrp_dbm")),
                    "sinr_db": _as_float(ue.get("sinr_db")),
                    "dl_snr_db": _as_float(ue.get("dl_snr_db")),
                    "ul_snr_db": _as_float(ue.get("ul_snr_db")),
                    "power_headroom_db": _as_float(ue.get("power_headroom_db")),
                    "pcmax_dbm": _as_float(ue.get("pcmax_dbm")),
                },
                "throughput": {
                    "dl_goodput_mbps": _as_float(ue.get("dl_goodput_mbps")),
                    "ul_goodput_mbps": _as_float(ue.get("ul_goodput_mbps")),
                },
                "reliability": {
                    "dl_bler": _as_float(ue.get("dl_bler")),
                    "ul_bler": _as_float(ue.get("ul_bler")),
                    "dlsch_rounds": ue.get("dlsch_rounds") if isinstance(ue.get("dlsch_rounds"), list) else None,
                    "ulsch_rounds": ue.get("ulsch_rounds") if isinstance(ue.get("ulsch_rounds"), list) else None,
                    "dlsch_errors": _as_int(ue.get("dlsch_errors")),
                    "ulsch_errors": _as_int(ue.get("ulsch_errors")),
                    "pucch_dtx": _as_int(ue.get("pucch_dtx")),
                    "ulsch_dtx": _as_int(ue.get("ulsch_dtx")),
                },
                "scheduler": {
                    "dl_mcs": _as_int(ue.get("dl_mcs")),
                    "ul_mcs": _as_int(ue.get("ul_mcs")),
                    "ul_nprb": _as_int(ue.get("ul_nprb")),
                },
                "traffic": {
                    "lcid_bytes": ue.get("lcid_bytes") if isinstance(ue.get("lcid_bytes"), list) else [],
                },
            }
        )

    observation = {
        "schema_version": SCHEMA_VERSION,
        "timestamp": timestamp or payload.get("timestamp"),
        "cells": cells,
        "ues": ues,
    }
    observation["metric_availability"] = _availability(observation)
    return observation


def network_observation_from_payload(
    payload: Dict[str, Any],
    *,
    timestamp: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    if not isinstance(payload, dict):
        return None

    observation = _oai_observation(payload, timestamp) or _srsran_observation(payload, timestamp)
    if observation is None:
        return None

    _assert_agent_safe(observation)
    return observation


def network_observation_from_event(event: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    payload = event.get("raw_payload")
    if not isinstance(payload, dict):
        return None
    timestamp = event.get("timestamp") or payload.get("timestamp") or event.get("collector_timestamp")
    return network_observation_from_payload(payload, timestamp=timestamp)


class AgentObservationWriter:
    """Append-only JSONL writer for sanitized agent network observations."""

    def __init__(self, output_path: Any):
        self.output_path = Path(output_path)
        self.lock = threading.Lock()

    def write(self, observation: Dict[str, Any]) -> None:
        _assert_agent_safe(observation)
        line = json.dumps(observation, ensure_ascii=False)
        with self.lock:
            self.output_path.parent.mkdir(parents=True, exist_ok=True)
            with self.output_path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
                handle.flush()
