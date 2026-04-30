import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from metrics_api import MetricsLogReader, parse_timestamp_to_epoch


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

    def _write_sqlite_snapshot(self, db_path, rows):
        with sqlite3.connect(db_path) as conn:
            conn.execute(
                """
                CREATE TABLE metrics_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    collector_timestamp TEXT NOT NULL,
                    source_id TEXT NOT NULL,
                    gnb_id TEXT,
                    source_endpoint TEXT,
                    event_type TEXT,
                    metric_family TEXT,
                    event_timestamp TEXT,
                    raw_json TEXT NOT NULL
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE metrics_cell_entities (
                    event_id INTEGER NOT NULL,
                    source_id TEXT NOT NULL,
                    collector_timestamp TEXT NOT NULL,
                    event_timestamp TEXT,
                    cell_index INTEGER NOT NULL,
                    ue_index INTEGER NOT NULL,
                    ue_identity TEXT NOT NULL,
                    pci INTEGER,
                    dl_brate REAL,
                    ul_brate REAL,
                    signal_db REAL,
                    ue_json TEXT NOT NULL,
                    PRIMARY KEY (event_id, cell_index, ue_index)
                )
                """
            )

            for row in rows:
                event_cursor = conn.execute(
                    """
                    INSERT INTO metrics_events (
                        collector_timestamp,
                        source_id,
                        gnb_id,
                        source_endpoint,
                        event_type,
                        metric_family,
                        event_timestamp,
                        raw_json
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        row["collector_timestamp"],
                        row["source_id"],
                        row.get("gnb_id", row["source_id"]),
                        row.get("source_endpoint", "ws://127.0.0.1:55555"),
                        row.get("event_type", "metric"),
                        "cells",
                        row.get("event_timestamp", row["collector_timestamp"]),
                        json.dumps({"raw_payload": row.get("payload", {})}),
                    ),
                )
                event_id = event_cursor.lastrowid

                for entity in row["entities"]:
                    conn.execute(
                        """
                        INSERT INTO metrics_cell_entities (
                            event_id,
                            source_id,
                            collector_timestamp,
                            event_timestamp,
                            cell_index,
                            ue_index,
                            ue_identity,
                            pci,
                            dl_brate,
                            ul_brate,
                            signal_db,
                            ue_json
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            event_id,
                            row["source_id"],
                            row["collector_timestamp"],
                            row.get("event_timestamp", row["collector_timestamp"]),
                            entity["cell_index"],
                            entity["ue_index"],
                            entity["ue_identity"],
                            entity.get("pci"),
                            entity.get("ue", {}).get("dl_brate"),
                            entity.get("ue", {}).get("ul_brate"),
                            entity.get("ue", {}).get("pucch_snr_db"),
                            json.dumps(entity.get("ue", {})),
                        ),
                    )

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

    def test_latest_cells_by_source_prefers_sqlite_fast_path(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb1", "jsonl-only", 99, 99),
            ],
        )
        sqlite_path = Path(self.temp_dir.name) / "metrics.sqlite"
        self._write_sqlite_snapshot(
            sqlite_path,
            [
                {
                    "collector_timestamp": "2026-04-13T11:16:05.204753+00:00",
                    "event_timestamp": "sqlite-now",
                    "source_id": "gnb1",
                    "entities": [
                        {
                            "cell_index": 0,
                            "ue_index": 0,
                            "ue_identity": "ue:10",
                            "pci": 1,
                            "ue": {
                                "dl_brate": 123.0,
                                "ul_brate": 45.0,
                            },
                        }
                    ],
                }
            ],
        )

        reader = MetricsLogReader(
            self.log_file,
            include_rotated=False,
            sqlite_path=sqlite_path,
            prefer_sqlite=True,
        )
        latest = reader.latest_cells_by_source()

        self.assertEqual(latest["gnb1"]["timestamp"], "sqlite-now")
        self.assertEqual(latest["gnb1"]["entities"][0]["ue"]["dl_brate"], 123.0)

    def test_latest_cells_by_source_falls_back_to_jsonl_when_sqlite_missing(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb1", "jsonl-now", 7, 8),
            ],
        )
        missing_sqlite = Path(self.temp_dir.name) / "missing.sqlite"

        reader = MetricsLogReader(
            self.log_file,
            include_rotated=False,
            sqlite_path=missing_sqlite,
            prefer_sqlite=True,
        )
        latest = reader.latest_cells_by_source()

        self.assertEqual(latest["gnb1"]["timestamp"], "jsonl-now")
        self.assertEqual(latest["gnb1"]["entities"][0]["ue"]["ul_brate"], 8)

    def test_source_sequences_counts_cells_events_per_source(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb1", "t1", 1, 1),
                self._event("gnb1", "t2", 2, 2),
                self._event("gnb2", "t1", 3, 3),
            ],
        )

        reader = MetricsLogReader(self.log_file, include_rotated=False)
        self.assertEqual(reader.source_sequences(), {"gnb1": 2, "gnb2": 1})

    def test_window_cells_events_prefers_sqlite_when_available(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb1", "2026-04-14T10:00:00+00:00", 1, 1),
            ],
        )

        sqlite_path = Path(self.temp_dir.name) / "metrics-window.sqlite"
        self._write_sqlite_snapshot(
            sqlite_path,
            [
                {
                    "collector_timestamp": "2026-04-14T10:02:00+00:00",
                    "event_timestamp": "2026-04-14T10:02:00+00:00",
                    "source_id": "gnb-sqlite",
                    "entities": [
                        {
                            "cell_index": 0,
                            "ue_index": 0,
                            "ue_identity": "ue:sqlite",
                            "pci": 10,
                            "ue": {
                                "dl_brate": 100.0,
                                "ul_brate": 50.0,
                            },
                        }
                    ],
                }
            ],
        )

        reader = MetricsLogReader(
            self.log_file,
            include_rotated=False,
            sqlite_path=sqlite_path,
            prefer_sqlite=True,
        )
        window = reader.window_cells_events(
            lower_epoch=parse_timestamp_to_epoch("2026-04-14T10:01:00+00:00"),
            upper_epoch=parse_timestamp_to_epoch("2026-04-14T10:03:00+00:00"),
        )

        self.assertEqual(len(window), 1)
        self.assertEqual(window[0]["source_id"], "gnb-sqlite")

    def test_window_cells_events_falls_back_to_jsonl_when_sqlite_missing(self):
        self._write_jsonl(
            self.log_file,
            [
                self._event("gnb-jsonl", "2026-04-14T10:05:00+00:00", 9, 8),
            ],
        )

        reader = MetricsLogReader(
            self.log_file,
            include_rotated=False,
            sqlite_path=Path(self.temp_dir.name) / "missing-window.sqlite",
            prefer_sqlite=True,
        )
        window = reader.window_cells_events()

        self.assertEqual(len(window), 1)
        self.assertEqual(window[0]["source_id"], "gnb-jsonl")

    def test_latest_sample_epoch_by_source_uses_collector_timestamp_fallback(self):
        self._write_jsonl(
            self.log_file,
            [
                {
                    "source_id": "gnb1",
                    "collector_timestamp": "2026-04-13T11:16:05+00:00",
                    "raw_payload": {
                        "cells": [
                            {
                                "ue_list": [
                                    {
                                        "dl_brate": 11.0,
                                        "ul_brate": 12.0,
                                    }
                                ]
                            }
                        ]
                    },
                }
            ],
        )

        reader = MetricsLogReader(self.log_file, include_rotated=False)
        sample_epochs = reader.latest_sample_epoch_by_source()

        self.assertIn("gnb1", sample_epochs)
        self.assertIsNotNone(sample_epochs["gnb1"])

    def test_window_cells_events_sqlite_filters_by_timestamp_bounds(self):
        sqlite_path = Path(self.temp_dir.name) / "metrics-bounds.sqlite"
        self._write_sqlite_snapshot(
            sqlite_path,
            [
                {
                    "collector_timestamp": "2026-04-14T10:00:00+00:00",
                    "event_timestamp": "2026-04-14T10:00:00+00:00",
                    "source_id": "gnb1",
                    "entities": [
                        {
                            "cell_index": 0,
                            "ue_index": 0,
                            "ue_identity": "ue:before",
                            "ue": {"dl_brate": 1.0, "ul_brate": 1.0},
                        }
                    ],
                },
                {
                    "collector_timestamp": "2026-04-14T10:05:00+00:00",
                    "event_timestamp": "2026-04-14T10:05:00+00:00",
                    "source_id": "gnb1",
                    "entities": [
                        {
                            "cell_index": 0,
                            "ue_index": 0,
                            "ue_identity": "ue:inside",
                            "ue": {"dl_brate": 2.0, "ul_brate": 2.0},
                        }
                    ],
                },
                {
                    "collector_timestamp": "2026-04-14T10:10:00+00:00",
                    "event_timestamp": "2026-04-14T10:10:00+00:00",
                    "source_id": "gnb1",
                    "entities": [
                        {
                            "cell_index": 0,
                            "ue_index": 0,
                            "ue_identity": "ue:after",
                            "ue": {"dl_brate": 3.0, "ul_brate": 3.0},
                        }
                    ],
                },
            ],
        )

        reader = MetricsLogReader(
            self.log_file,
            include_rotated=False,
            sqlite_path=sqlite_path,
            prefer_sqlite=True,
        )
        window = reader.window_cells_events(
            lower_epoch=parse_timestamp_to_epoch("2026-04-14T10:02:00+00:00"),
            upper_epoch=parse_timestamp_to_epoch("2026-04-14T10:07:00+00:00"),
        )

        self.assertEqual(len(window), 1)
        identities = [e["ue_identity"] for entry in window for e in entry["entities"]]
        self.assertIn("ue:inside", identities)
        self.assertNotIn("ue:before", identities)
        self.assertNotIn("ue:after", identities)

    def test_iter_log_paths_handles_archive_gaps_and_max_archives(self):
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.4"), [self._event("gnb1", "t0", 1, 1)])
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.2"), [self._event("gnb1", "t1", 1, 1)])
        self._write_jsonl(self.log_file.with_name("metrics.jsonl.1"), [self._event("gnb1", "t2", 1, 1)])
        self._write_jsonl(self.log_file, [self._event("gnb1", "t3", 1, 1)])

        reader = MetricsLogReader(self.log_file, include_rotated=True, max_archives=2)
        path_names = [path.name for path in reader.iter_log_paths()]

        self.assertEqual(path_names, ["metrics.jsonl.2", "metrics.jsonl.1", "metrics.jsonl"])


if __name__ == "__main__":
    unittest.main()
