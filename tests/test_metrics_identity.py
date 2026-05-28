import unittest

from metrics_identity import build_ue_identity, extract_cell_ue_entities


class MetricsIdentityTests(unittest.TestCase):
    def test_build_ue_identity_prefers_ue_then_rnti_then_fallback(self):
        self.assertEqual(build_ue_identity({"ue": 12, "rnti": 99}, 0, 0), "ue:12")
        self.assertEqual(build_ue_identity({"rnti": 99}, 0, 1), "rnti:99")
        self.assertEqual(build_ue_identity({}, 2, 3), "cell2-ue3")

    def test_extract_cell_ue_entities_parses_all_cells_and_ues(self):
        payload = {
            "cells": [
                {
                    "cell_metrics": {"pci": 1},
                    "ue_list": [
                        {"ue": 1, "dl_brate": 10.0, "ul_brate": 11.0},
                        {"rnti": 200, "dl_brate": 12.0, "ul_brate": 13.0},
                    ],
                },
                {
                    "cell_metrics": {"pci": 2},
                    "ue_list": [
                        {"dl_brate": 14.0, "ul_brate": 15.0},
                    ],
                },
            ]
        }

        entities = extract_cell_ue_entities(payload)

        self.assertEqual(len(entities), 3)
        self.assertEqual(entities[0]["ue_identity"], "ue:1")
        self.assertEqual(entities[1]["ue_identity"], "rnti:200")
        self.assertEqual(entities[2]["ue_identity"], "cell1-ue0")
        self.assertEqual(entities[2]["pci"], 2)

    def test_extract_cell_ue_entities_maps_oai_mac_stats_to_entities(self):
        payload = {
            "oai_mac_stats": {
                "pci": 10,
                "ues": [
                    {
                        "rnti": "2460",
                        "dl_goodput_mbps": 120.5,
                        "ul_goodput_mbps": 12.3,
                        "ul_snr_db": 31.0,
                        "dl_snr_db": 19.8,
                    }
                ],
            }
        }

        entities = extract_cell_ue_entities(payload)

        self.assertEqual(len(entities), 1)
        self.assertEqual(entities[0]["ue_identity"], "rnti:2460")
        self.assertEqual(entities[0]["pci"], 10)
        self.assertAlmostEqual(entities[0]["ue"]["dl_brate"], 120500.0)
        self.assertAlmostEqual(entities[0]["ue"]["ul_brate"], 12300.0)
        self.assertAlmostEqual(entities[0]["ue"]["pusch_snr_db"], 31.0)


if __name__ == "__main__":
    unittest.main()
