"""Unit tests for repository sitecustomize module."""

import importlib.util
import os
import unittest
from pathlib import Path
from unittest.mock import patch


class TestSitecustomize(unittest.TestCase):
    """Ensure sitecustomize executes under coverage (site may preload it)."""

    def test_module_executes_from_source_path(self):
        """Load sitecustomize by file path so coverage records its lines."""
        path = Path(__file__).resolve().parents[2] / "sitecustomize.py"
        spec = importlib.util.spec_from_file_location("sitecustomize", path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(module.__doc__)
        self.assertTrue(module.SITECUSTOMIZE_LOADED)

    def test_display_mode_shell_sitecustomize_requires_startup_path(self):
        """Display-mode shell hook must fail when ASUS_DISPLAY_MODE_DBUS_STARTUP is invalid."""
        path = Path(__file__).resolve().parents[2] / "tests" / "fixtures" / "display_mode_shell_sitecustomize.py"
        spec = importlib.util.spec_from_file_location("display_mode_shell_sitecustomize", path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(os.environ, {"ASUS_DISPLAY_MODE_SHELL_TEST": "1"}, clear=False):
            os.environ.pop("ASUS_DISPLAY_MODE_DBUS_STARTUP", None)
            with self.assertRaises(SystemExit):
                spec.loader.exec_module(module)


if __name__ == "__main__":
    unittest.main()
