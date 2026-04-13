import json
import tempfile
import unittest
from pathlib import Path

from src.metrics_api import MetricsLogReader


class MetricsApiTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.log_file = Path(self.temp_dir.name) / "metrics.jsonl"

    def _write_jsonl(self, path, events):
        with path.open("w", encoding="utf-8") as handle:
            for event in events:
                handle.write(json.dumps(event, ensure_ascii=False) + "\n")

    def _event(self, source_id, timestamp, dl, ul):
        return {
            "source_id": source_id,
            "timestamp": timestamp,
            "raw_payload": {
                "cells": [
                    {
                        "ue_list": [
                            {
                                "dl_brate": dl,
                                "ul_brate": ul,
                            }
                        ]
                    }
                ]
            },
        }

    def _event_multi(self, source_id, timestamp):
        return {
            "source_id": source_id,
            "timestamp": timestamp,
            "raw_payload": {
                "cells": [
                    {
                        "cell_metrics": {"pci": 101},
                        "ue_list": [
                            {
                                "ue": "alpha",
                                "dl_brate": 20,
                                "ul_brate": 21,
                            },
                            {
                                "rnti": 102,
                                "dl_brate": 22,
                                "ul_brate": 23,
                            },
                        ],
                    },
                    {
                        "cell_metrics": {"pci": 202},
                        "ue_list": [
                            {
                                "dl_brate": 24,
                                "ul_brate": 25,
                            }
                        ],
                    },
                ]
            },
        }

    def test_reads_archives_in_chronological_order(self):
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.2"), [self._event("gnb1", "t1", 1, 1)])
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.1"), [self._event("gnb1", "t2", 2, 2)])
        self._write_jsonl(self.log_file, [self._event("gnb1", "t3", 3, 3)])

        reader = MetricsLogReader(self.log_file, include_rotated=True)
        events = list(reader.iter_events())

        self.assertEqual([e["timestamp"] for e in events], ["t1", "t2", "t3"])

    def test_latest_cells_by_source_prefers_newest_event(self):
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.1"), [self._event("gnb1", "old", 10, 11)])
        self._write_jsonl(
            self.log_file,
            [
                self._event_multi("gnb1", "new"),
                self._event("gnb2", "now", 30, 31),
            ],
        )

        reader = MetricsLogReader(self.log_file, include_rotated=True)
        latest = reader.latest_cells_by_source()

        self.assertEqual(latest["gnb1"]["timestamp"], "new")
        self.assertEqual(len(latest["gnb1"]["entities"]), 3)
        entity_by_identity = {
            entity["ue_identity"]: entity
            for entity in latest["gnb1"]["entities"]
        }
        self.assertEqual(entity_by_identity["ue:alpha"]["ue"]["dl_brate"], 20)
        self.assertEqual(entity_by_identity["rnti:102"]["ue"]["ul_brate"], 23)
        self.assertEqual(entity_by_identity["cell1-ue0"]["cell_index"], 1)
        self.assertEqual(entity_by_identity["cell1-ue0"]["pci"], 202)
        self.assertEqual(latest["gnb2"]["timestamp"], "now")

    def test_latest_cells_by_source_uses_newest_per_source(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb1", "t1", 1, 1),
                self._event("gnb1", "t2", 2, 2),
                self._event("gnb2", "t1", 3, 3),
            ],
        )

        reader = MetricsLogReader(self.log_file, include_rotated=False)
        latest = reader.latest_cells_by_source()

        self.assertEqual(latest["gnb1"]["timestamp"], "t2")
        self.assertEqual(latest["gnb1"]["entities"][0]["ue"]["dl_brate"], 2)
        self.assertEqual(latest["gnb2"]["timestamp"], "t1")
        self.assertEqual(latest["gnb2"]["entities"][0]["ue_identity"], "cell0-ue0")


if __name__ == "__main__":
    unittest.main()
