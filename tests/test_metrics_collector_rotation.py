import json
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

# Stub out the websocket module before the collector package imports it.
sys.modules.setdefault("websocket", types.SimpleNamespace(WebSocketApp=object))

from collector.enrichment import enrich_event  # noqa: E402
from collector.storage import EventWriter, SQLiteEventSink  # noqa: E402
from collector.transport import (  # noqa: E402
    WebSocketSourceAdapter,
    build_transport_adapter,
    websocket_keepalive_kwargs,
)
from collector.config import METRICS_SCHEMA_VERSION  # noqa: E402


class EventWriterRotationTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.output_file = Path(self.temp_dir.name) / "metrics.jsonl"

    def _event(self, sequence):
        return {
            "source_id": "gnb1",
            "metric_family": "cells",
            "timestamp": sequence,
            "raw_payload": {
                "cells": [
                    {
                        "ue_list": [
                            {
                                "dl_brate": float(sequence + 1),
                                "ul_brate": float(sequence + 1),
                            }
                        ]
                    }
                ]
            },
        }

    def _read_jsonl(self, path):
        if not path.exists():
            return []
        with path.open("r", encoding="utf-8") as handle:
            return [json.loads(line) for line in handle if line.strip()]

    def test_rotation_creates_archive_file(self):
        writer = EventWriter(self.output_file, rotate_max_bytes=1, rotate_max_files=2)

        writer.write(self._event(1))
        writer.write(self._event(2))

        archive_1 = self.output_file.parent / "metrics.jsonl.1"
        self.assertTrue(archive_1.exists())
        self.assertEqual(len(self._read_jsonl(self.output_file)), 1)
        self.assertEqual(len(self._read_jsonl(archive_1)), 1)

    def test_rotation_respects_file_retention_limit(self):
        writer = EventWriter(self.output_file, rotate_max_bytes=1, rotate_max_files=2)

        for index in range(8):
            writer.write(self._event(index))

        archive_1 = self.output_file.parent / "metrics.jsonl.1"
        archive_2 = self.output_file.parent / "metrics.jsonl.2"
        archive_3 = self.output_file.parent / "metrics.jsonl.3"

        self.assertTrue(archive_1.exists())
        self.assertTrue(archive_2.exists())
        self.assertFalse(archive_3.exists())

    def test_sqlite_sink_recovers_after_transient_write_failure(self):
        sqlite_path = Path(self.temp_dir.name) / "metrics.sqlite"
        writer = EventWriter(
            self.output_file,
            sqlite_enabled=True,
            sqlite_path=sqlite_path,
            sqlite_timeout_seconds=1.0,
            sqlite_retry_max_failures=3,
            sqlite_retry_cooldown_seconds=0,
        )

        class FlakySink:
            def write_event(self, _event):
                raise sqlite3.OperationalError("database is locked")

        writer.sqlite_sink = FlakySink()

        writer.write(self._event(1))
        self.assertIsNone(writer.sqlite_sink)
        self.assertGreater(writer.sqlite_consecutive_failures, 0)

        writer.write(self._event(2))

        self.assertIsNotNone(writer.sqlite_sink)
        self.assertEqual(writer.sqlite_consecutive_failures, 0)
        self.assertEqual(len(self._read_jsonl(self.output_file)), 2)

        with sqlite3.connect(sqlite_path) as conn:
            event_count = conn.execute("SELECT COUNT(*) FROM metrics_events").fetchone()[0]

        self.assertGreaterEqual(event_count, 1)

    def test_sqlite_retention_max_rows_prunes_old_events(self):
        sqlite_path = Path(self.temp_dir.name) / "metrics-retention.sqlite"
        writer = EventWriter(
            self.output_file,
            sqlite_enabled=True,
            sqlite_path=sqlite_path,
            sqlite_timeout_seconds=1.0,
            sqlite_retry_max_failures=3,
            sqlite_retry_cooldown_seconds=0,
            sqlite_retention_max_rows=2,
            sqlite_retention_interval_events=1,
        )

        for index in range(5):
            writer.write(self._event(index))

        with sqlite3.connect(sqlite_path) as conn:
            event_count = conn.execute("SELECT COUNT(*) FROM metrics_events").fetchone()[0]

        self.assertLessEqual(event_count, 2)

    def test_enrich_event_derives_throughput_mbps_from_brates(self):
        source = {"source_id": "gnb1", "gnb_id": "gnb-1", "ws_url": "ws://127.0.0.1:5001"}
        payload = {
            "timestamp": "2026-04-14T10:00:00+00:00",
            "cells": [
                {
                    "ue_list": [
                        {"ue": "ueA", "dl_brate": 2_000_000.0, "ul_brate": 1_000_000.0}
                    ]
                }
            ],
        }

        event = enrich_event(source, payload)

        self.assertAlmostEqual(event["throughput_mbps"], 3.0, places=3)

    def test_enrich_event_derives_bler_pct_from_nof_counters(self):
        source = {"source_id": "gnb1", "gnb_id": "gnb-1", "ws_url": "ws://127.0.0.1:5001"}
        payload = {
            "timestamp": "2026-04-14T10:00:00+00:00",
            "cells": [
                {
                    "ue_list": [
                        {
                            "ue": "ueA",
                            "dl_brate": 1000.0,
                            "ul_brate": 500.0,
                            "dl_nof_nok": 10,
                            "dl_nof_ok": 90,
                        }
                    ]
                }
            ],
        }

        event = enrich_event(source, payload)

        self.assertAlmostEqual(event["bler_pct"], 10.0, places=1)

    def test_enrich_event_derives_bler_pct_from_legacy_retx_counters(self):
        source = {"source_id": "gnb1", "gnb_id": "gnb-1", "ws_url": "ws://127.0.0.1:5001"}
        payload = {
            "timestamp": "2026-04-14T10:00:00+00:00",
            "cells": [
                {
                    "ue_list": [
                        {
                            "ue": "ueA",
                            "dl_brate": 1000.0,
                            "ul_brate": 500.0,
                            "dl_retx": 5,
                            "dl_ok": 95,
                        }
                    ]
                }
            ],
        }

        event = enrich_event(source, payload)

        self.assertAlmostEqual(event["bler_pct"], 5.0, places=1)

    def test_enrich_event_no_throughput_when_no_brate(self):
        source = {"source_id": "gnb1", "gnb_id": "gnb-1", "ws_url": "ws://127.0.0.1:5001"}
        payload = {
            "timestamp": "2026-04-14T10:00:00+00:00",
            "cells": [{"ue_list": [{"ue": "ueA"}]}],
        }

        event = enrich_event(source, payload)

        self.assertNotIn("throughput_mbps", event)
        self.assertNotIn("bler_pct", event)

    def test_enrich_event_adds_schema_and_default_event_type(self):
        source = {
            "source_id": "gnb1",
            "gnb_id": "gnb-1",
            "ws_url": "ws://127.0.0.1:5001",
        }
        payload = {
            "timestamp": "2026-04-14T10:00:00+00:00",
            "cells": [
                {
                    "cell_metrics": {"pci": 123},
                    "ue_list": [
                        {
                            "ue": "ueA",
                            "dl_brate": 1000.0,
                            "ul_brate": 500.0,
                        }
                    ],
                }
            ],
        }

        event = enrich_event(source, payload)

        self.assertEqual(event["metric_family"], "cells")
        self.assertEqual(event["event_type"], "metric")
        self.assertEqual(event["schema_version"], METRICS_SCHEMA_VERSION)
        self.assertEqual(event["cell_id"], 123)
        self.assertEqual(event["ue_id"], "ueA")

    def test_enrich_event_preserves_supported_payload_event_type(self):
        source = {
            "source_id": "gnb1",
            "gnb_id": "gnb-1",
            "ws_url": "ws://127.0.0.1:5001",
        }
        payload = {
            "event_type": "alarm",
            "timestamp": "2026-04-14T10:00:00+00:00",
            "du": {},
        }

        event = enrich_event(source, payload)

        self.assertEqual(event["event_type"], "alarm")

    def test_websocket_keepalive_kwargs_enabled_by_default(self):
        kwargs = websocket_keepalive_kwargs()

        self.assertIn("ping_interval", kwargs)
        self.assertGreater(kwargs["ping_interval"], 0)
        self.assertIn("ping_timeout", kwargs)
        self.assertGreaterEqual(kwargs["ping_timeout"], 0)

    def test_transport_adapter_factory_returns_websocket_adapter(self):
        source = {
            "source_id": "gnb1",
            "gnb_id": "gnb1",
            "ws_url": "ws://127.0.0.1:55551",
        }

        adapter = build_transport_adapter(source)
        self.assertIsInstance(adapter, WebSocketSourceAdapter)

    def test_sqlite_sink_migrates_old_schema_on_open(self):
        """SQLiteEventSink must open a DB created without event_type/source_endpoint and write to it."""
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "old_schema.sqlite"

            # Simulate a DB written by an older version of the code (no event_type, no source_endpoint).
            with sqlite3.connect(str(db_path)) as conn:
                conn.execute(
                    """
                    CREATE TABLE metrics_events (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        collector_timestamp TEXT NOT NULL,
                        source_id TEXT NOT NULL,
                        gnb_id TEXT,
                        ws_url TEXT,
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

            sink = SQLiteEventSink(db_path)
            event = {
                "source_id": "gnb1",
                "metric_family": "cells",
                "event_type": "metric",
                "source_endpoint": "ws://127.0.0.1:55555",
                "collector_timestamp": "2026-04-14T10:00:00+00:00",
                "timestamp": "2026-04-14T10:00:00+00:00",
                "raw_payload": {
                    "cells": [
                        {
                            "ue_list": [
                                {"dl_brate": 100.0, "ul_brate": 50.0}
                            ]
                        }
                    ]
                },
            }
            # Must not raise — the forward migration should have added the missing columns.
            sink.write_event(event)

            with sqlite3.connect(str(db_path)) as conn:
                count = conn.execute("SELECT COUNT(*) FROM metrics_events").fetchone()[0]
            self.assertEqual(count, 1)


if __name__ == "__main__":
    unittest.main()
