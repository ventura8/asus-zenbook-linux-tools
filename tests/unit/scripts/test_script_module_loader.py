"""Unit tests for scripts module path loader restore-on-failure behavior."""

from __future__ import annotations

import sys
import types
import unittest

from tests.shared.failing_module import failing_module_path
from tests.unit.bin.attr_helpers import call_attr
from tests.unit.scripts import script_module_loader as loader


class TestScriptModuleLoader(unittest.TestCase):
    """Verify exec_module failure restores or clears sys.modules."""

    def test_failed_exec_removes_partial_module(self) -> None:
        """A raised exec_module must not leave a partial module registered."""
        module_name = "_script_module_loader_fail_test"
        sys.modules.pop(module_name, None)
        with failing_module_path() as bad_module, self.assertRaises(RuntimeError):
            call_attr(loader, "_exec_module_from_path", module_name, bad_module)
        self.assertNotIn(module_name, sys.modules)

    def test_failed_exec_restores_prior_module(self) -> None:
        """A prior sys.modules entry must be restored when exec_module fails."""
        module_name = "_script_module_loader_prior_test"
        prior = types.ModuleType(module_name, doc="prior")
        sys.modules[module_name] = prior
        try:
            with failing_module_path() as bad_module, self.assertRaises(RuntimeError):
                call_attr(loader, "_exec_module_from_path", module_name, bad_module)
            self.assertIs(sys.modules[module_name], prior)
            self.assertEqual(prior.__doc__, "prior")
        finally:
            sys.modules.pop(module_name, None)


if __name__ == "__main__":
    unittest.main()
