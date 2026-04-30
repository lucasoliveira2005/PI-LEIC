import os
import time
import unittest

from shared.liveness import (
    FreshnessSettings,
    build_baseline_payload,
    evaluate_source_freshness,
    settings_from_env,
    source_signature,
)


def _make_source_entry(dl_brate=1000.0, timestamp="2026-04-14T10:00:00+00:00"):
    return {
        "timestamp": timestamp,
        "entities": [
            {
                "cell_index": 0,
                "ue_index": 0,
                "ue_identity": "ue:1",
                "pci": 10,
                "ue": {"dl_brate": dl_brate, "ul_brate": 500.0},
            }
        ],
    }


def _settings(mode):
    return FreshnessSettings(
        mode=mode,
        age_window_seconds=15.0,
        clock_skew_tolerance_seconds=2.0,
    )


class SourceSignatureTests(unittest.TestCase):
    def test_identical_payloads_produce_same_signature(self):
        entry = _make_source_entry()
        self.assertEqual(source_signature(entry), source_signature(entry))

    def test_different_brate_produces_different_signature(self):
        entry_a = _make_source_entry(dl_brate=1000.0)
        entry_b = _make_source_entry(dl_brate=2000.0)
        self.assertNotEqual(source_signature(entry_a), source_signature(entry_b))

    def test_different_timestamp_produces_different_signature(self):
        entry_a = _make_source_entry(timestamp="2026-04-14T10:00:00+00:00")
        entry_b = _make_source_entry(timestamp="2026-04-14T10:00:01+00:00")
        self.assertNotEqual(source_signature(entry_a), source_signature(entry_b))

    def test_missing_timestamp_still_produces_signature(self):
        entry = _make_source_entry()
        entry.pop("timestamp", None)
        sig = source_signature(entry)
        self.assertIsInstance(sig, str)
        self.assertTrue(len(sig) > 0)

    def test_empty_entry_produces_stable_signature(self):
        sig = source_signature({})
        self.assertIsInstance(sig, str)


class EvaluateFreshnessSignatureModeTests(unittest.TestCase):
    def _baseline(self, entry):
        bp = build_baseline_payload(
            latest_by_source={"gnb1": entry},
            source_sequences={},
            required_sources=["gnb1"],
        )
        return bp

    def test_fresh_when_no_baseline_known(self):
        entry = _make_source_entry()
        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=0.0,
            baseline_signatures={},
            baseline_sequences={},
            baseline_sample_epoch={},
            settings=_settings("signature"),
        )
        self.assertTrue(result)

    def test_fresh_when_signature_changed(self):
        old_entry = _make_source_entry(dl_brate=1000.0)
        new_entry = _make_source_entry(dl_brate=2000.0)
        bp = self._baseline(old_entry)

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=new_entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=bp["captured_at_epoch"],
            baseline_signatures=bp["signatures"],
            baseline_sequences=bp["sequences"],
            baseline_sample_epoch=bp["sample_epoch"],
            settings=_settings("signature"),
        )
        self.assertTrue(result)

    def test_stale_when_signature_unchanged(self):
        entry = _make_source_entry()
        bp = self._baseline(entry)

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=bp["captured_at_epoch"],
            baseline_signatures=bp["signatures"],
            baseline_sequences=bp["sequences"],
            baseline_sample_epoch=bp["sample_epoch"],
            settings=_settings("signature"),
        )
        self.assertFalse(result)


class EvaluateFreshnessAgeModeTests(unittest.TestCase):
    def test_fresh_when_timestamp_recent(self):
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
        entry = _make_source_entry(timestamp=now_iso)

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=0.0,
            baseline_signatures={},
            baseline_sequences={},
            baseline_sample_epoch={},
            settings=_settings("age"),
        )
        self.assertTrue(result)

    def test_stale_when_timestamp_old(self):
        entry = _make_source_entry(timestamp="2000-01-01T00:00:00+00:00")

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=0.0,
            baseline_signatures={"gnb1": "some-sig"},
            baseline_sequences={},
            baseline_sample_epoch={},
            settings=_settings("age"),
        )
        self.assertFalse(result)

    def test_stale_when_no_timestamp(self):
        entry = {"entities": []}  # no timestamp field

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=0.0,
            baseline_signatures={"gnb1": "some-sig"},
            baseline_sequences={},
            baseline_sample_epoch={},
            settings=_settings("age"),
        )
        self.assertFalse(result)


class EvaluateFreshnessSequenceModeTests(unittest.TestCase):
    def _baseline_with_seq(self, seq):
        entry = _make_source_entry()
        entry["sequence"] = seq
        return build_baseline_payload(
            latest_by_source={"gnb1": entry},
            source_sequences={"gnb1": seq},
            required_sources=["gnb1"],
        )

    def test_fresh_when_sequence_advanced(self):
        bp = self._baseline_with_seq(10)
        entry = _make_source_entry()
        entry["sequence"] = 11

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={"gnb1": 11},
            source_sample_epochs={},
            baseline_captured_at_epoch=bp["captured_at_epoch"],
            baseline_signatures=bp["signatures"],
            baseline_sequences=bp["sequences"],
            baseline_sample_epoch=bp["sample_epoch"],
            settings=_settings("sequence"),
        )
        self.assertTrue(result)

    def test_stale_when_sequence_unchanged(self):
        bp = self._baseline_with_seq(10)
        entry = _make_source_entry()
        entry["sequence"] = 10

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,
            source_sequences={"gnb1": 10},
            source_sample_epochs={},
            baseline_captured_at_epoch=bp["captured_at_epoch"],
            baseline_signatures=bp["signatures"],
            baseline_sequences=bp["sequences"],
            baseline_sample_epoch=bp["sample_epoch"],
            settings=_settings("sequence"),
        )
        self.assertFalse(result)


class EvaluateFreshnessHybridModeTests(unittest.TestCase):
    def test_hybrid_fresh_if_any_sub_check_passes(self):
        """Hybrid mode: recent age alone is sufficient even if signature/sequence unchanged."""
        now_iso = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
        entry = _make_source_entry(timestamp=now_iso)
        bp = build_baseline_payload(
            latest_by_source={"gnb1": entry},
            source_sequences={},
            required_sources=["gnb1"],
        )

        result = evaluate_source_freshness(
            source_id="gnb1",
            source_entry=entry,  # same entry → signature unchanged
            source_sequences={},
            source_sample_epochs={},
            baseline_captured_at_epoch=bp["captured_at_epoch"],
            baseline_signatures=bp["signatures"],
            baseline_sequences=bp["sequences"],
            baseline_sample_epoch=bp["sample_epoch"],
            settings=_settings("hybrid"),
        )
        # Timestamp is fresh → hybrid should be True even though signature unchanged
        self.assertTrue(result)


class SettingsFromEnvTests(unittest.TestCase):
    def setUp(self):
        for key in ("FRESHNESS_CHECK_MODE", "FRESHNESS_AGE_WINDOW_SECONDS",
                    "FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS"):
            os.environ.pop(key, None)

    def tearDown(self):
        for key in ("FRESHNESS_CHECK_MODE", "FRESHNESS_AGE_WINDOW_SECONDS",
                    "FRESHNESS_CLOCK_SKEW_TOLERANCE_SECONDS"):
            os.environ.pop(key, None)

    def test_defaults(self):
        s = settings_from_env()
        self.assertEqual(s.mode, "hybrid")
        self.assertAlmostEqual(s.age_window_seconds, 15.0)
        self.assertAlmostEqual(s.clock_skew_tolerance_seconds, 2.0)

    def test_mode_override(self):
        os.environ["FRESHNESS_CHECK_MODE"] = "age"
        s = settings_from_env()
        self.assertEqual(s.mode, "age")

    def test_invalid_mode_falls_back_to_hybrid(self):
        os.environ["FRESHNESS_CHECK_MODE"] = "invalid_mode"
        s = settings_from_env()
        self.assertEqual(s.mode, "hybrid")

    def test_age_window_override(self):
        os.environ["FRESHNESS_AGE_WINDOW_SECONDS"] = "30"
        s = settings_from_env()
        self.assertAlmostEqual(s.age_window_seconds, 30.0)


if __name__ == "__main__":
    unittest.main()
