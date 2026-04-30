import io
import json
import unittest
from pathlib import Path

from shared.structured_logging import emit_structured_log


class StructuredLoggingTests(unittest.TestCase):
    def test_emit_structured_log_writes_json_record(self):
        stream = io.StringIO()

        emit_structured_log(
            "collector.ready",
            "Metrics collector ready.",
            service="metrics_collector",
            stream=stream,
            source_id="gnb1",
            output_path=Path("/tmp/metrics.jsonl"),
            nested={"path": Path("/tmp/db.sqlite")},
        )

        payload = json.loads(stream.getvalue())
        self.assertEqual(payload["level"], "info")
        self.assertEqual(payload["event"], "collector.ready")
        self.assertEqual(payload["message"], "Metrics collector ready.")
        self.assertEqual(payload["service"], "metrics_collector")
        self.assertEqual(payload["source_id"], "gnb1")
        self.assertEqual(payload["output_path"], "/tmp/metrics.jsonl")
        self.assertEqual(payload["nested"]["path"], "/tmp/db.sqlite")
        self.assertIn("timestamp", payload)


if __name__ == "__main__":
    unittest.main()
