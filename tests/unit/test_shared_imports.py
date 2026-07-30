"""Unit tests for shared_imports module loader helpers."""

import sys
import tempfile
import types
import unittest
from pathlib import Path

import shared_imports


class SharedImportsTests(unittest.TestCase):
    """Verify shared_imports module caching and path-loading behavior."""

    def setUp(self):
        """Remove cached asus_common before each shared_imports test."""
        self._saved_asus_common = sys.modules.pop("asus_common", None)

    def tearDown(self):
        """Restore any asus_common module cached before setUp."""
        sys.modules.pop("asus_common", None)
        if self._saved_asus_common is not None:
            sys.modules["asus_common"] = self._saved_asus_common

    def test_load_asus_common_reuses_preloaded_module(self):
        """load_asus_common should return already-loaded asus_common from sys.modules."""
        sentinel = types.ModuleType("asus_common")
        sys.modules["asus_common"] = sentinel
        loaded = shared_imports.load_asus_common()
        self.assertIs(loaded, sentinel)

    def test_load_asus_common_caches_module_without_reexecution(self):
        """Repeated load_asus_common calls should return one module object without re-exec."""
        repo_root = Path(__file__).resolve().parents[2]
        asus_common_path = repo_root / "bin" / "asus_common.py"
        self.assertTrue(asus_common_path.is_file())

        first = shared_imports.load_asus_common()
        second = shared_imports.load_asus_common()

        self.assertIs(first, second)
        self.assertEqual(Path(first.__file__).resolve(), asus_common_path.resolve())

    def test_load_module_from_path_removes_failed_module(self):
        """Failed exec_module should remove the partial module from sys.modules."""
        module_name = "_shared_imports_failing_load_test"
        sys.modules.pop(module_name, None)
        with tempfile.TemporaryDirectory() as tmp_dir:
            bad_module = Path(tmp_dir) / "bad_module.py"
            bad_module.write_text("raise RuntimeError('boom')\n", encoding="utf-8")
            with self.assertRaises(RuntimeError):
                shared_imports.load_module_from_path(module_name, str(bad_module))
        self.assertNotIn(module_name, sys.modules)

    def test_load_module_from_path_keeps_successful_module(self):
        """Successful exec_module should leave the module registered in sys.modules."""
        module_name = "_shared_imports_success_load_test"
        sys.modules.pop(module_name, None)
        with tempfile.TemporaryDirectory() as tmp_dir:
            good_module = Path(tmp_dir) / "good_module.py"
            good_module.write_text("VALUE = 42\n", encoding="utf-8")
            loaded = shared_imports.load_module_from_path(module_name, str(good_module))
        try:
            self.assertIs(sys.modules[module_name], loaded)
            self.assertEqual(loaded.VALUE, 42)
        finally:
            sys.modules.pop(module_name, None)


if __name__ == "__main__":
    unittest.main()
