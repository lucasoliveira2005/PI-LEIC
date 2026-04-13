import importlib.util
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path


class DashboardDedupeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        repo_root = Path(__file__).resolve().parents[1]
        module_path = repo_root / "src" / "dashboard.py"

        # Keep matplotlib fully stubbed so importing dashboard.py is side-effect safe in tests.
        animation_stub = types.SimpleNamespace(
            FuncAnimation=lambda *args, **kwargs: object(),
        )
        axes_stub = types.SimpleNamespace(
            clear=lambda: None,
            plot=lambda *args, **kwargs: None,
            fill_between=lambda *args, **kwargs: None,
            set_title=lambda *args, **kwargs: None,
            set_ylabel=lambda *args, **kwargs: None,
            set_xlabel=lambda *args, **kwargs: None,
            legend=lambda *args, **kwargs: None,
            grid=lambda *args, **kwargs: None,
        )
        pyplot_stub = types.SimpleNamespace(
            subplots=lambda *args, **kwargs: (object(), (axes_stub, axes_stub)),
            subplots_adjust=lambda *args, **kwargs: None,
            show=lambda: None,
        )

        matplotlib_stub = types.ModuleType("matplotlib")
        matplotlib_stub.animation = animation_stub
        matplotlib_stub.pyplot = pyplot_stub

        sys.modules.setdefault("matplotlib", matplotlib_stub)
        sys.modules.setdefault("matplotlib.animation", animation_stub)
        sys.modules.setdefault("matplotlib.pyplot", pyplot_stub)

        spec = importlib.util.spec_from_file_location("dashboard_under_test", module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        cls.dashboard = module

    def setUp(self):
        self.dashboard.history_by_entity.clear()
        self.dashboard.last_sample_signature_by_entity.clear()

    def test_dedupe_with_missing_timestamp_uses_payload_signature(self):
        entity_key = ("gnb1", 0, "ue:1")
        ue_metrics = {"dl_brate": 100.0, "ul_brate": 50.0}

        first_sig = self.dashboard.build_entity_sample_signature(None, ue_metrics)
        self.assertTrue(first_sig.startswith("payload:"))

        if self.dashboard.last_sample_signature_by_entity.get(entity_key) != first_sig:
            self.dashboard.append_entity_sample(entity_key, ue_metrics)
            self.dashboard.last_sample_signature_by_entity[entity_key] = first_sig

        # Same payload and no timestamp should be deduped.
        second_sig = self.dashboard.build_entity_sample_signature(None, dict(ue_metrics))
        if self.dashboard.last_sample_signature_by_entity.get(entity_key) != second_sig:
            self.dashboard.append_entity_sample(entity_key, ue_metrics)
            self.dashboard.last_sample_signature_by_entity[entity_key] = second_sig

        self.assertEqual(len(self.dashboard.history_by_entity[entity_key]["times"]), 1)

    def test_signature_prefers_timestamp_when_present(self):
        ue_metrics = {"dl_brate": 100.0, "ul_brate": 50.0}

        sig_a = self.dashboard.build_entity_sample_signature("t1", ue_metrics)
        sig_b = self.dashboard.build_entity_sample_signature("t2", ue_metrics)
        sig_c = self.dashboard.build_entity_sample_signature("t2", {"dl_brate": 1.0})

        self.assertEqual(sig_a, "ts:t1")
        self.assertEqual(sig_b, "ts:t2")
        # With timestamp present, payload differences should not alter the signature.
        self.assertEqual(sig_b, sig_c)


if __name__ == "__main__":
    unittest.main()
