import importlib.util
import json
import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "src" / "metrics_collector.py"

# Tests only exercise the writer path, so a lightweight websocket stub is enough.
sys.modules.setdefault("websocket", types.SimpleNamespace(WebSocketApp=object))

SPEC = importlib.util.spec_from_file_location("metrics_collector", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

EventWriter = MODULE.EventWriter


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


if __name__ == "__main__":
    unittest.main()
