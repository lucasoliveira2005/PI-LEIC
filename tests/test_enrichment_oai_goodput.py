import unittest
import sys
import types

sys.modules.setdefault("websocket", types.SimpleNamespace(WebSocketApp=object))

from collector.enrichment import _GOODPUT_STATE, enrich_event


class OaiGoodputEnrichmentTests(unittest.TestCase):
    def setUp(self):
        _GOODPUT_STATE.clear()

    def tearDown(self):
        _GOODPUT_STATE.clear()

    def _payload(self, timestamp, tx_bytes, rx_bytes):
        return {
            "timestamp": timestamp,
            "oai_mac_stats": {
                "ues": [
                    {
                        "rnti": "2460",
                        "dl_goodput_mbps": 0.0,
                        "ul_goodput_mbps": 0.0,
                        "lcid_bytes": [
                            {"lcid": 1, "tx_bytes": 10, "rx_bytes": 20},
                            {"lcid": 4, "tx_bytes": tx_bytes, "rx_bytes": rx_bytes},
                        ],
                    }
                ],
            },
        }

    def test_oai_zero_goodput_falls_back_to_lcid_byte_deltas(self):
        source = {"source_id": "oai-gnb1", "gnb_id": "gnb1", "log_path": "/tmp/nrMAC_stats.log"}

        enrich_event(source, self._payload("2026-06-17T12:00:00+00:00", 1_000, 2_000))
        event = enrich_event(
            source,
            self._payload("2026-06-17T12:00:01+00:00", 2_000, 4_000),
        )

        ue = event["raw_payload"]["oai_mac_stats"]["ues"][0]
        self.assertAlmostEqual(ue["dl_goodput_mbps"], 0.008)
        self.assertAlmostEqual(ue["ul_goodput_mbps"], 0.016)
        self.assertAlmostEqual(ue["dl_brate"], 8_000.0)
        self.assertAlmostEqual(ue["ul_brate"], 16_000.0)


if __name__ == "__main__":
    unittest.main()
