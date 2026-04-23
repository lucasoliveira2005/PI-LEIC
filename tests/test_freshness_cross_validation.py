"""Cross-validation: Python liveness module vs. Shell metrics_contract wrapper.

Both paths must produce identical baseline signatures and freshness verdicts
for the same JSONL input.  This guards against drift between the two entry
points that share the same underlying Python implementation.
"""

import json
import os
import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path

from metrics_api import MetricsLogReader
from shared.liveness import (
    build_baseline_payload,
    evaluate_source_freshness,
    FreshnessSettings,
)

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = REPO_ROOT / "src"


def _fixture_event(source_id, timestamp, dl_brate=1000.0, ul_brate=500.0):
    return {
        "source_id": source_id,
        "timestamp": timestamp,
        "raw_payload": {
            "cells": [
                {
                    "ue_list": [
                        {
                            "rnti": "0x101",
                            "dl_brate": dl_brate,
                            "ul_brate": ul_brate,
                        }
                    ]
                }
            ]
        },
    }


def _write_jsonl(path, events):
    with open(path, "w", encoding="utf-8") as fh:
        for event in events:
            fh.write(json.dumps(event, ensure_ascii=False) + "\n")


def _call_shell_baseline(tmp_dir, metrics_path, sources):
    """Invoke metrics_contract_write_baseline_signatures via bash."""
    baseline_file = os.path.join(tmp_dir, "shell_baseline.json")
    quoted_sources = " ".join(shlex.quote(source) for source in sources)
    script = f"""
set -euo pipefail
source {shlex.quote(str(SRC_DIR / "launch_lib/metrics_contract.sh"))}

PYTHON_BIN_RESOLVED="$(command -v python3)"
REPO_ROOT_PATH={shlex.quote(str(REPO_ROOT))}
METRICS_OUT_PATH={shlex.quote(str(metrics_path))}
METRICS_LOG_INCLUDE_ROTATED=0
METRICS_LOG_MAX_ARCHIVES=5
METRICS_SQLITE_ENABLED=0
METRICS_SQLITE_PATH={shlex.quote(str(Path(tmp_dir) / "unused.sqlite"))}

metrics_contract_write_baseline_signatures {shlex.quote(str(baseline_file))} {quoted_sources}
"""
    subprocess.run(
        ["bash", "-c", script],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(Path(baseline_file).read_text(encoding="utf-8"))


def _call_shell_health(tmp_dir, metrics_path, baseline_file, sources, mode="hybrid"):
    """Invoke metrics_contract_collect_health_states via bash."""
    quoted_sources = " ".join(shlex.quote(source) for source in sources)
    script = f"""
set -euo pipefail
source {shlex.quote(str(SRC_DIR / "launch_lib/metrics_contract.sh"))}

PYTHON_BIN_RESOLVED="$(command -v python3)"
REPO_ROOT_PATH={shlex.quote(str(REPO_ROOT))}
METRICS_OUT_PATH={shlex.quote(str(metrics_path))}
METRICS_LOG_INCLUDE_ROTATED=0
METRICS_LOG_MAX_ARCHIVES=5
METRICS_SQLITE_ENABLED=0
METRICS_SQLITE_PATH={shlex.quote(str(Path(tmp_dir) / "unused.sqlite"))}

export FRESHNESS_CHECK_MODE={shlex.quote(str(mode))}
metrics_contract_collect_health_states {shlex.quote(str(baseline_file))} {quoted_sources}
"""
    result = subprocess.run(
        ["bash", "-c", script],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = {}
    for line in result.stdout.strip().splitlines():
        parts = line.split("\t")
        rows[parts[0]] = {
            "has_data": int(parts[1]),
            "has_entities": int(parts[2]),
            "is_fresh": int(parts[3]),
        }
    return rows


class FreshnessCrossValidationTests(unittest.TestCase):
    """Verify that the shell wrapper and direct Python calls agree."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.tmp_dir = self.tmp.name

    # ------------------------------------------------------------------
    # Baseline payload
    # ------------------------------------------------------------------

    def test_baseline_signatures_match(self):
        metrics_path = os.path.join(self.tmp_dir, "metrics.jsonl")
        events = [_fixture_event("gnb1", "t0", dl_brate=1000.0)]
        _write_jsonl(metrics_path, events)

        # Python path
        reader = MetricsLogReader(
            Path(metrics_path),
            include_rotated=False,
            sqlite_path=None,
            prefer_sqlite=False,
        )
        py_baseline = build_baseline_payload(
            reader.latest_cells_by_source(),
            reader.source_sequences(),
            ["gnb1"],
        )

        # Shell path
        sh_baseline = _call_shell_baseline(self.tmp_dir, metrics_path, ["gnb1"])

        self.assertEqual(
            py_baseline["signatures"],
            sh_baseline["signatures"],
            "Baseline signatures must match between Python and Shell paths",
        )
        self.assertEqual(
            py_baseline["sequences"],
            sh_baseline["sequences"],
        )

    # ------------------------------------------------------------------
    # Freshness: stale immediately after baseline
    # ------------------------------------------------------------------

    def test_stale_on_same_data_both_paths(self):
        metrics_path = os.path.join(self.tmp_dir, "metrics.jsonl")
        events = [_fixture_event("gnb1", "t0")]
        _write_jsonl(metrics_path, events)

        # Python
        reader = MetricsLogReader(
            Path(metrics_path), include_rotated=False,
            sqlite_path=None, prefer_sqlite=False,
        )
        py_baseline = build_baseline_payload(
            reader.latest_cells_by_source(),
            reader.source_sequences(),
            ["gnb1"],
        )
        source_entry = reader.latest_cells_by_source().get("gnb1")
        py_fresh = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=source_entry,
            source_sequences=reader.source_sequences(),
            source_sample_epochs=reader.latest_sample_epoch_by_source(),
            baseline_captured_at_epoch=py_baseline["captured_at_epoch"],
            baseline_signatures=py_baseline["signatures"],
            baseline_sequences=py_baseline["sequences"],
            baseline_sample_epoch=py_baseline["sample_epoch"],
            settings=FreshnessSettings(mode="signature", age_window_seconds=15.0, clock_skew_tolerance_seconds=2.0),
        )

        # Shell
        baseline_file = os.path.join(self.tmp_dir, "baseline_stale.json")
        sh_baseline = _call_shell_baseline(self.tmp_dir, metrics_path, ["gnb1"])
        Path(baseline_file).write_text(json.dumps(sh_baseline), encoding="utf-8")

        sh_states = _call_shell_health(
            self.tmp_dir, metrics_path, baseline_file, ["gnb1"], mode="signature",
        )

        self.assertFalse(py_fresh, "Python: should be stale against own baseline")
        self.assertEqual(sh_states["gnb1"]["is_fresh"], 0, "Shell: should be stale against own baseline")

    # ------------------------------------------------------------------
    # Freshness: fresh after new data arrives
    # ------------------------------------------------------------------

    def test_fresh_after_new_data_both_paths(self):
        metrics_path = os.path.join(self.tmp_dir, "metrics.jsonl")
        events = [_fixture_event("gnb1", "t0", dl_brate=1000.0)]
        _write_jsonl(metrics_path, events)

        # Take baseline
        reader = MetricsLogReader(
            Path(metrics_path), include_rotated=False,
            sqlite_path=None, prefer_sqlite=False,
        )
        py_baseline = build_baseline_payload(
            reader.latest_cells_by_source(),
            reader.source_sequences(),
            ["gnb1"],
        )
        baseline_file = os.path.join(self.tmp_dir, "baseline_fresh.json")
        Path(baseline_file).write_text(json.dumps(py_baseline), encoding="utf-8")

        # Append new data
        with open(metrics_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(_fixture_event("gnb1", "t1", dl_brate=2000.0)) + "\n")

        # Python re-read
        reader2 = MetricsLogReader(
            Path(metrics_path), include_rotated=False,
            sqlite_path=None, prefer_sqlite=False,
        )
        source_entry = reader2.latest_cells_by_source().get("gnb1")
        py_fresh = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=source_entry,
            source_sequences=reader2.source_sequences(),
            source_sample_epochs=reader2.latest_sample_epoch_by_source(),
            baseline_captured_at_epoch=py_baseline["captured_at_epoch"],
            baseline_signatures=py_baseline["signatures"],
            baseline_sequences=py_baseline["sequences"],
            baseline_sample_epoch=py_baseline["sample_epoch"],
            settings=FreshnessSettings(mode="signature", age_window_seconds=15.0, clock_skew_tolerance_seconds=2.0),
        )

        # Shell
        sh_states = _call_shell_health(
            self.tmp_dir, metrics_path, baseline_file, ["gnb1"], mode="signature",
        )

        self.assertTrue(py_fresh, "Python: should be fresh after new data")
        self.assertEqual(sh_states["gnb1"]["is_fresh"], 1, "Shell: should be fresh after new data")

    # ------------------------------------------------------------------
    # Multi-source: partial freshness
    # ------------------------------------------------------------------

    def test_multi_source_partial_freshness(self):
        metrics_path = os.path.join(self.tmp_dir, "metrics.jsonl")
        events = [
            _fixture_event("gnb1", "t0", dl_brate=1000.0),
            _fixture_event("gnb2", "t0", dl_brate=500.0),
        ]
        _write_jsonl(metrics_path, events)

        sources = ["gnb1", "gnb2"]

        # Baseline
        reader = MetricsLogReader(
            Path(metrics_path), include_rotated=False,
            sqlite_path=None, prefer_sqlite=False,
        )
        py_baseline = build_baseline_payload(
            reader.latest_cells_by_source(),
            reader.source_sequences(),
            sources,
        )
        baseline_file = os.path.join(self.tmp_dir, "baseline_multi.json")
        Path(baseline_file).write_text(json.dumps(py_baseline), encoding="utf-8")

        # Only gnb1 gets new data
        with open(metrics_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(_fixture_event("gnb1", "t1", dl_brate=3000.0)) + "\n")

        reader2 = MetricsLogReader(
            Path(metrics_path), include_rotated=False,
            sqlite_path=None, prefer_sqlite=False,
        )
        settings = FreshnessSettings(mode="signature", age_window_seconds=15.0, clock_skew_tolerance_seconds=2.0)

        py_gnb1 = evaluate_source_freshness(
            "gnb1", reader2.latest_cells_by_source()["gnb1"],
            reader2.source_sequences(), reader2.latest_sample_epoch_by_source(),
            py_baseline["captured_at_epoch"], py_baseline["signatures"],
            py_baseline["sequences"], py_baseline["sample_epoch"], settings,
        )
        py_gnb2 = evaluate_source_freshness(
            "gnb2", reader2.latest_cells_by_source()["gnb2"],
            reader2.source_sequences(), reader2.latest_sample_epoch_by_source(),
            py_baseline["captured_at_epoch"], py_baseline["signatures"],
            py_baseline["sequences"], py_baseline["sample_epoch"], settings,
        )

        sh_states = _call_shell_health(
            self.tmp_dir, metrics_path, baseline_file, sources, mode="signature",
        )

        self.assertTrue(py_gnb1)
        self.assertFalse(py_gnb2)
        self.assertEqual(sh_states["gnb1"]["is_fresh"], 1)
        self.assertEqual(sh_states["gnb2"]["is_fresh"], 0)


if __name__ == "__main__":
    unittest.main()
