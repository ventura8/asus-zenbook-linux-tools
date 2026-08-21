"""Shared helpers for mocked E2E daemon tests."""

from __future__ import annotations

import os
import tempfile
import unittest
from collections.abc import Callable
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_env import (
    build_install_mock_env,
    write_executable,
)


def build_pythonpath_env(project_root: str) -> dict[str, str]:
    """Return subprocess environment with the project path on PYTHONPATH."""
    env = dict(os.environ)
    existing_pythonpath = env.get("PYTHONPATH", "")
    path_parts = [project_root]
    if existing_pythonpath:
        path_parts.append(existing_pythonpath)
    env["PYTHONPATH"] = ":".join(path_parts)
    return env


def verify_mocked_de_launcher(
    test_case: unittest.TestCase,
    script_path: str,
    env_factory: Callable[[str], tuple[dict[str, str], Path, Path, Path]],
    binary_name: str,
) -> None:
    """Helper to verify launching DE-specific binaries via a stub logger."""
    with tempfile.TemporaryDirectory() as tmp_dir:
        env, _dest_dir, mock_bin, _home = env_factory(tmp_dir)
        log_file = Path(tmp_dir) / f"{binary_name}_invocations.log"
        write_executable(
            mock_bin / binary_name,
            f'#!/bin/sh\necho "$@" >> "{log_file}"\nsleep 0.5\nexit 0\n',
        )
        result = run_e2e_command(["bash", script_path], env=env, timeout=25)
        test_case.assertEqual(result.returncode, 0, result.stderr)
        test_case.assertTrue(log_file.exists())


def verify_mocked_gdbus_action(
    test_case: unittest.TestCase,
    script_path: str,
    expected_substring: str,
    env_desktop: str = "GNOME",
) -> None:
    """Helper to verify GNOME D-Bus actions via a stub gdbus."""
    with tempfile.TemporaryDirectory() as tmp:
        env, _dest_dir, mock_bin = build_install_mock_env(tmp)
        env["XDG_CURRENT_DESKTOP"] = env_desktop
        recorded_calls = Path(tmp) / "gdbus_calls.log"
        write_executable(
            mock_bin / "gdbus",
            f'#!/bin/sh\necho "$@" >> "{recorded_calls}"\nexit 0\n',
        )
        proc = run_e2e_command(["bash", script_path], env=env, timeout=25)
        test_case.assertEqual(proc.returncode, 0, proc.stderr)
        test_case.assertTrue(recorded_calls.exists())
        content = recorded_calls.read_text(encoding="utf-8")
        test_case.assertIn(expected_substring, content)
