"""Parser for OpenAirInterface gNB MAC scheduler statistics.

OAI writes human-readable UE scheduler snapshots to ``nrMAC_stats.log``.  This
module converts the documented lines into a structured payload that the
collector can ingest like any other metric source.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional


_UE_HEADER_RE = re.compile(
    r"UE RNTI (?P<rnti>\S+) CU-UE-ID (?P<cu_ue_id>\d+) "
    r"(?P<sync_state>in-sync|out-of-sync) "
    r"PH (?P<power_headroom_db>-?\d+(?:\.\d+)?) dB "
    r"PCMAX (?P<pcmax_dbm>-?\d+(?:\.\d+)?) dBm, "
    r"average RSRP (?P<rsrp_dbm>-?\d+(?:\.\d+)?) "
    r"\((?P<rsrp_measurements>\d+) meas\)"
    r"(?:, average SINR (?P<sinr_db>-?\d+(?:\.\d+)?) "
    r"\((?P<sinr_measurements>\d+) meas\))?"
)
_CSI_RE = re.compile(
    r"UE (?P<rnti>\S+): CQI (?P<cqi>\d+), RI (?P<rank_indicator>\d+), "
    r"PMI \((?P<pmi>[^)]+)\)"
)
_UL_RI_RE = re.compile(
    r"UE (?P<rnti>\S+): UL-RI (?P<ul_rank_indicator>\d+),?\s+TPMI (?P<tpmi>\d+)"
)
_DLSCH_RE = re.compile(
    r"UE (?P<rnti>\S+): dlsch_rounds (?P<dlsch_rounds>[\d/]+), "
    r"dlsch_errors (?P<dlsch_errors>\d+), "
    r"pucch\d*_DTX (?P<pucch_dtx>\d+) "
    r"\(SNR (?P<dl_snr_db>-?\d+(?:\.\d+)?)(?P<dl_snr_delta_db>[+-]\d+(?:\.\d+)?)? dB\), "
    r"BLER (?P<dl_bler>-?\d+(?:\.\d+)?) "
    r"MCS \((?P<dl_mcs_table>\d+)\) (?P<dl_mcs>\d+) "
    r"CCE fail (?P<cce_fail_dl>\d+), "
    r"goodput (?P<dl_goodput_mbps>-?\d+(?:\.\d+)?) Mbps"
)
_ULSCH_RE = re.compile(
    r"UE (?P<rnti>\S+): ulsch_rounds (?P<ulsch_rounds>[\d/]+), "
    r"ulsch_errors (?P<ulsch_errors>\d+), "
    r"ulsch_DTX (?P<ulsch_dtx>\d+), "
    r"BLER (?P<ul_bler>-?\d+(?:\.\d+)?) "
    r"MCS \((?P<ul_mcs_table>\d+)\) (?P<ul_mcs>\d+) "
    r"\(Qm (?P<ul_qm>\d+) deltaMCS (?P<ul_delta_mcs_db>-?\d+(?:\.\d+)?) dB\) "
    r"NPRB (?P<ul_nprb>\d+) "
    r"SNR (?P<ul_snr_db>-?\d+(?:\.\d+)?) "
    r"\((?P<ul_snr_delta_db>[+-]?\d+(?:\.\d+)?)\) dB "
    r"CCE fail (?P<cce_fail_ul>\d+), "
    r"goodput (?P<ul_goodput_mbps>-?\d+(?:\.\d+)?) Mbps"
)
_LCID_RE = re.compile(
    r"UE (?P<rnti>\S+): LCID (?P<lcid>\d+): "
    r"TX\s+(?P<tx_bytes>\d+) RX\s+(?P<rx_bytes>\d+) bytes"
)


def _to_int(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    return int(value)


def _to_float(value: Optional[str]) -> Optional[float]:
    if value is None:
        return None
    return float(value)


def _rounds(value: str) -> List[int]:
    return [int(item) for item in value.split("/") if item != ""]


def _ue(ues: Dict[str, Dict[str, Any]], rnti: str) -> Dict[str, Any]:
    ue = ues.setdefault(rnti, {"rnti": rnti, "lcid_bytes": []})
    return ue


def parse_oai_mac_stats_text(
    text: str,
    *,
    timestamp: Optional[str] = None,
) -> Optional[Dict[str, Any]]:
    """Parse OAI ``nrMAC-stats.log`` text into a collector payload.

    Returns ``None`` when no UE metrics are found.
    """

    ues: Dict[str, Dict[str, Any]] = {}

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue

        match = _UE_HEADER_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.update(
                {
                    "cu_ue_id": _to_int(data.get("cu_ue_id")),
                    "sync_state": data.get("sync_state"),
                    "power_headroom_db": _to_float(data.get("power_headroom_db")),
                    "pcmax_dbm": _to_float(data.get("pcmax_dbm")),
                    "rsrp_dbm": _to_float(data.get("rsrp_dbm")),
                    "rsrp_measurements": _to_int(data.get("rsrp_measurements")),
                    "sinr_db": _to_float(data.get("sinr_db")),
                    "sinr_measurements": _to_int(data.get("sinr_measurements")),
                }
            )
            continue

        match = _CSI_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.update(
                {
                    "cqi": _to_int(data.get("cqi")),
                    "rank_indicator": _to_int(data.get("rank_indicator")),
                    "pmi": data.get("pmi"),
                }
            )
            continue

        match = _UL_RI_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.update(
                {
                    "ul_rank_indicator": _to_int(data.get("ul_rank_indicator")),
                    "tpmi": _to_int(data.get("tpmi")),
                }
            )
            continue

        match = _DLSCH_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.update(
                {
                    "dlsch_rounds": _rounds(data["dlsch_rounds"]),
                    "dlsch_errors": _to_int(data.get("dlsch_errors")),
                    "pucch_dtx": _to_int(data.get("pucch_dtx")),
                    "dl_snr_db": _to_float(data.get("dl_snr_db")),
                    "dl_snr_delta_db": _to_float(data.get("dl_snr_delta_db")),
                    "dl_bler": _to_float(data.get("dl_bler")),
                    "dl_mcs_table": _to_int(data.get("dl_mcs_table")),
                    "dl_mcs": _to_int(data.get("dl_mcs")),
                    "cce_fail_dl": _to_int(data.get("cce_fail_dl")),
                    "dl_goodput_mbps": _to_float(data.get("dl_goodput_mbps")),
                }
            )
            continue

        match = _ULSCH_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.update(
                {
                    "ulsch_rounds": _rounds(data["ulsch_rounds"]),
                    "ulsch_errors": _to_int(data.get("ulsch_errors")),
                    "ulsch_dtx": _to_int(data.get("ulsch_dtx")),
                    "ul_bler": _to_float(data.get("ul_bler")),
                    "ul_mcs_table": _to_int(data.get("ul_mcs_table")),
                    "ul_mcs": _to_int(data.get("ul_mcs")),
                    "ul_qm": _to_int(data.get("ul_qm")),
                    "ul_delta_mcs_db": _to_float(data.get("ul_delta_mcs_db")),
                    "ul_nprb": _to_int(data.get("ul_nprb")),
                    "ul_snr_db": _to_float(data.get("ul_snr_db")),
                    "ul_snr_delta_db": _to_float(data.get("ul_snr_delta_db")),
                    "cce_fail_ul": _to_int(data.get("cce_fail_ul")),
                    "ul_goodput_mbps": _to_float(data.get("ul_goodput_mbps")),
                }
            )
            continue

        match = _LCID_RE.search(line)
        if match:
            data = match.groupdict()
            ue = _ue(ues, data["rnti"])
            ue.setdefault("lcid_bytes", []).append(
                {
                    "lcid": _to_int(data.get("lcid")),
                    "tx_bytes": _to_int(data.get("tx_bytes")),
                    "rx_bytes": _to_int(data.get("rx_bytes")),
                }
            )

    if not ues:
        return None

    return {
        "timestamp": timestamp or datetime.now(timezone.utc).isoformat(),
        "oai_mac_stats": {
            "ues": list(ues.values()),
        },
    }
