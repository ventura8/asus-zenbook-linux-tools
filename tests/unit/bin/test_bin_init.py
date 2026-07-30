"""Unit tests for bin package marker."""

import importlib
import unittest


class TestBinInit(unittest.TestCase):
    """Ensure bin/__init__.py is imported under coverage."""

    def test_bin_package_docstring(self):
        """Importing bin exposes the package docstring marker."""
        module = importlib.import_module("bin")
        self.assertTrue(module.__doc__)


if __name__ == "__main__":
    unittest.main()
