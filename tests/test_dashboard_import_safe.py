import importlib.util
import sys
import types
import unittest
from pathlib import Path


class DashboardImportSafetyTests(unittest.TestCase):
    @staticmethod
    def _load_dashboard(module_name):
        repo_root = Path(__file__).resolve().parents[1]
        module_path = repo_root / "src" / "dashboard.py"
        spec = importlib.util.spec_from_file_location(module_name, module_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_import_does_not_initialize_runtime(self):
        dashboard = self._load_dashboard("dashboard_import_safe")

        self.assertIsNone(dashboard.READER)
        self.assertIsNone(dashboard.fig)
        self.assertIsNone(dashboard.ax1)
        self.assertIsNone(dashboard.ax2)
        self.assertIsNone(dashboard.ani)

    def test_main_initializes_runtime_and_calls_show(self):
        dashboard = self._load_dashboard("dashboard_main_init")

        show_calls = {"count": 0}

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

        def show_stub():
            show_calls["count"] += 1

        pyplot_stub = types.SimpleNamespace(
            subplots=lambda *args, **kwargs: (object(), (axes_stub, axes_stub)),
            subplots_adjust=lambda *args, **kwargs: None,
            show=show_stub,
        )

        matplotlib_stub = types.ModuleType("matplotlib")
        matplotlib_stub.animation = animation_stub
        matplotlib_stub.pyplot = pyplot_stub

        module_names = ["matplotlib", "matplotlib.animation", "matplotlib.pyplot"]
        previous_modules = {name: sys.modules.get(name) for name in module_names}

        try:
            sys.modules["matplotlib"] = matplotlib_stub
            sys.modules["matplotlib.animation"] = animation_stub
            sys.modules["matplotlib.pyplot"] = pyplot_stub

            dashboard.main()

            self.assertIsNotNone(dashboard.READER)
            self.assertIsNotNone(dashboard.fig)
            self.assertIsNotNone(dashboard.ax1)
            self.assertIsNotNone(dashboard.ax2)
            self.assertIsNotNone(dashboard.ani)
            self.assertEqual(show_calls["count"], 1)
        finally:
            for name, previous in previous_modules.items():
                if previous is None:
                    sys.modules.pop(name, None)
                else:
                    sys.modules[name] = previous


if __name__ == "__main__":
    unittest.main()
