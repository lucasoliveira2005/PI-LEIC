import unittest
import sys
import types

sys.modules.setdefault("websocket", types.SimpleNamespace(WebSocketApp=object))

from collector.oai_mac_stats import parse_oai_mac_stats_text


OAI_MAC_STATS_SAMPLE = """
UE RNTI 2460 CU-UE-ID 2 in-sync PH 28 dB PCMAX 24 dBm, average RSRP -74 (8 meas), average SINR 40.0 (32 meas)
UE 2460: CQI 15, RI 2, PMI (14,1)
UE 2460: UL-RI 2 TPMI 0
UE 2460: dlsch_rounds 32917/5113/1504/560, dlsch_errors 211, pucch0_DTX 1385 (SNR 19.8+0.2 dB), BLER 0.19557 MCS (1) 23 CCE fail 3, goodput 120.50 Mbps
UE 2460: ulsch_rounds 3756/353/182/179, ulsch_errors 170, ulsch_DTX 285, BLER 0.33021 MCS (1) 27 (Qm 8 deltaMCS 0 dB) NPRB 5 SNR 31.0 (-1.0) dB CCE fail 0, goodput 12.30 Mbps
UE 2460: LCID 1: TX            651 RX           3031 bytes
UE 2460: LCID 4: TX     1526169592 RX          16152 bytes
"""


class OaiMacStatsParserTests(unittest.TestCase):
    def test_extracts_documented_oai_mac_stats_fields(self):
        payload = parse_oai_mac_stats_text(
            OAI_MAC_STATS_SAMPLE,
            timestamp="2026-05-28T12:00:00+00:00",
        )

        self.assertIsNotNone(payload)
        self.assertEqual(payload["timestamp"], "2026-05-28T12:00:00+00:00")
        ues = payload["oai_mac_stats"]["ues"]
        self.assertEqual(len(ues), 1)

        ue = ues[0]
        self.assertEqual(ue["rnti"], "2460")
        self.assertEqual(ue["cu_ue_id"], 2)
        self.assertEqual(ue["sync_state"], "in-sync")
        self.assertEqual(ue["power_headroom_db"], 28.0)
        self.assertEqual(ue["pcmax_dbm"], 24.0)
        self.assertEqual(ue["rsrp_dbm"], -74.0)
        self.assertEqual(ue["sinr_db"], 40.0)
        self.assertEqual(ue["cqi"], 15)
        self.assertEqual(ue["rank_indicator"], 2)
        self.assertEqual(ue["dlsch_rounds"], [32917, 5113, 1504, 560])
        self.assertEqual(ue["ulsch_rounds"], [3756, 353, 182, 179])
        self.assertEqual(ue["dlsch_errors"], 211)
        self.assertEqual(ue["ulsch_errors"], 170)
        self.assertEqual(ue["pucch_dtx"], 1385)
        self.assertEqual(ue["ulsch_dtx"], 285)
        self.assertAlmostEqual(ue["dl_bler"], 0.19557)
        self.assertAlmostEqual(ue["ul_bler"], 0.33021)
        self.assertEqual(ue["dl_mcs"], 23)
        self.assertEqual(ue["ul_mcs"], 27)
        self.assertEqual(ue["cce_fail_dl"], 3)
        self.assertEqual(ue["cce_fail_ul"], 0)
        self.assertEqual(ue["ul_nprb"], 5)
        self.assertAlmostEqual(ue["dl_goodput_mbps"], 120.50)
        self.assertAlmostEqual(ue["ul_goodput_mbps"], 12.30)
        self.assertEqual(ue["lcid_bytes"][1], {"lcid": 4, "tx_bytes": 1526169592, "rx_bytes": 16152})

    def test_returns_none_without_ue_metrics(self):
        self.assertIsNone(parse_oai_mac_stats_text("random startup line"))


if __name__ == "__main__":
    unittest.main()
