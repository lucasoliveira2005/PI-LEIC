import json
import sys
import tempfile
import types
import unittest
from pathlib import Path

sys.modules.setdefault("websocket", types.SimpleNamespace(WebSocketApp=object))

from collector.network_observation import (
    AgentObservationWriter,
    FORBIDDEN_AGENT_KEYS,
    SCHEMA_VERSION,
    network_observation_from_payload,
)
from collector.oai_mac_stats import parse_oai_mac_stats_text


def _walk_keys(value):
    if isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _walk_keys(item)
    elif isinstance(value, list):
        for item in value:
            yield from _walk_keys(item)


class NetworkObservationTests(unittest.TestCase):
    def test_oai_payload_normalizes_to_agent_observation_without_setup_keys(self):
        payload = parse_oai_mac_stats_text(
            """
UE RNTI 2460 CU-UE-ID 2 in-sync PH 28 dB PCMAX 24 dBm, average RSRP -74 (8 meas), average SINR 40.0 (32 meas)
UE 2460: CQI 15, RI 2, PMI (14,1)
UE 2460: dlsch_rounds 32917/5113/1504/560, dlsch_errors 211, pucch0_DTX 1385 (SNR 19.8+0.2 dB), BLER 0.19557 MCS (1) 23 CCE fail 3, goodput 120.50 Mbps
UE 2460: ulsch_rounds 3756/353/182/179, ulsch_errors 170, ulsch_DTX 285, BLER 0.33021 MCS (1) 27 (Qm 8 deltaMCS 0 dB) NPRB 5 SNR 31.0 (-1.0) dB CCE fail 0, goodput 12.30 Mbps
UE 2460: LCID 4: TX 100 RX 200 bytes
""",
            timestamp="2026-05-28T12:00:00+00:00",
        )

        observation = network_observation_from_payload(payload)

        self.assertEqual(observation["schema_version"], SCHEMA_VERSION)
        self.assertEqual(observation["timestamp"], "2026-05-28T12:00:00+00:00")
        self.assertEqual(observation["ues"][0]["ue_id"], "rnti:2460")
        self.assertEqual(observation["ues"][0]["sync_state"], "in-sync")
        self.assertEqual(observation["ues"][0]["radio_quality"]["cqi"], 15)
        self.assertAlmostEqual(observation["ues"][0]["throughput"]["dl_goodput_mbps"], 120.5)
        self.assertEqual(observation["cells"][0]["control_channel_load"]["cce_fail_dl"], 3)
        self.assertEqual(observation["metric_availability"]["core_session"], "partial")

        keys = set(_walk_keys(observation))
        self.assertNotIn("ran_backend", keys)
        self.assertTrue(FORBIDDEN_AGENT_KEYS.isdisjoint(keys))

    def test_srsran_payload_normalizes_to_same_shape(self):
        payload = {
            "timestamp": "2026-05-28T12:00:00+00:00",
            "cells": [
                {
                    "cell_metrics": {
                        "pci": 1,
                        "pucch_tot_rb_usage_avg": 12.4,
                    },
                    "ue_list": [
                        {
                            "rnti": "0x4601",
                            "dl_brate": 1800.0,
                            "ul_brate": 620.0,
                            "pusch_snr_db": 24.5,
                            "pucch_snr_db": 19.2,
                            "cqi": 14,
                            "dl_mcs": 23,
                            "ul_mcs": 20,
                            "dl_nof_ok": 90,
                            "dl_nof_nok": 10,
                        }
                    ],
                }
            ],
        }

        observation = network_observation_from_payload(payload)

        self.assertEqual(observation["schema_version"], SCHEMA_VERSION)
        self.assertEqual(observation["cells"][0]["pci"], 1)
        self.assertEqual(observation["cells"][0]["control_channel_load"]["pucch_rb_usage_pct"], 12.4)
        self.assertEqual(observation["ues"][0]["ue_id"], "rnti:0x4601")
        self.assertAlmostEqual(observation["ues"][0]["throughput"]["dl_goodput_mbps"], 1.8)
        self.assertAlmostEqual(observation["ues"][0]["reliability"]["dl_bler"], 0.1)
        self.assertEqual(observation["metric_availability"]["throughput"], "available")

    def test_writer_rejects_forbidden_agent_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            writer = AgentObservationWriter(Path(tmp) / "agent.jsonl")
            with self.assertRaises(ValueError):
                writer.write({"schema_version": SCHEMA_VERSION, "ran_backend": "oai"})

    def test_writer_appends_sanitized_jsonl(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "agent.jsonl"
            writer = AgentObservationWriter(output)
            writer.write(
                {
                    "schema_version": SCHEMA_VERSION,
                    "timestamp": "2026-05-28T12:00:00+00:00",
                    "cells": [],
                    "ues": [],
                    "metric_availability": {},
                }
            )

            rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
            self.assertEqual(rows[0]["schema_version"], SCHEMA_VERSION)


if __name__ == "__main__":
    unittest.main()
