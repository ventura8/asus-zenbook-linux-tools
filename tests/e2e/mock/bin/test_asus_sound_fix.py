"""E2E tests matching bin/asus-sound-fix.sh."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command
from tests.e2e.mock.mock_env import write_executable

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")


def _build_sound_fix_env(dev_snd: str, proc_asound: str, extra_bin: str = "") -> dict[str, str]:
    """Return environment overrides for sound-fix hardware-root probing tests."""
    current_path = os.environ.get("PATH", "")
    if extra_bin:
        path_val = f"{extra_bin}:{current_path}"
    else:
        path_val = current_path
    return dict(
        os.environ,
        DEV_SND_ROOT=dev_snd,
        PROC_ASOUND_ROOT=proc_asound,
        PATH=path_val,
    )


class TestAsusSoundFixE2E(unittest.TestCase):
    """End-to-end tests for bin/asus-sound-fix.sh."""

    def test_missing_card_exit(self):
        """Test asus-sound-fix.sh exits cleanly when matching sound card is absent."""
        script_path = os.path.join(BIN_DIR, "asus-sound-fix.sh")
        with tempfile.TemporaryDirectory() as empty_dir:
            dev_snd = os.path.join(empty_dir, "dev", "snd")
            proc_asound = os.path.join(empty_dir, "proc", "asound")
            os.makedirs(dev_snd, exist_ok=True)
            os.makedirs(proc_asound, exist_ok=True)

            env = _build_sound_fix_env(dev_snd, proc_asound)
            proc = run_e2e_command(["bash", script_path], env=env, timeout=20)
            self.assertEqual(proc.returncode, 1)
            self.assertIn(
                "Could not find sound card containing ALC294/Cirrus codec",
                proc.stderr,
            )

    def test_alc294_codec_success(self):
        """Test asus-sound-fix.sh detects ALC294 codec and applies HDA verbs."""
        script_path = os.path.join(BIN_DIR, "asus-sound-fix.sh")
        with tempfile.TemporaryDirectory() as tmp_dir:
            dev_snd = os.path.join(tmp_dir, "dev", "snd")
            proc_asound = os.path.join(tmp_dir, "proc", "asound", "card0")
            os.makedirs(dev_snd, exist_ok=True)
            os.makedirs(proc_asound, exist_ok=True)

            (Path(proc_asound) / "codec#0").write_text("Codec: Realtek ALC294\n", encoding="utf-8")
            (Path(dev_snd) / "hwC0D0").write_text("", encoding="utf-8")

            mock_bin = os.path.join(tmp_dir, "bin")
            os.makedirs(mock_bin, exist_ok=True)
            hda_log = Path(tmp_dir) / "hda_verb_calls.log"
            write_executable(
                Path(mock_bin) / "hda-verb",
                f'#!/bin/sh\necho "$@" >> "{hda_log}"\nexit 0\n',
            )

            env = _build_sound_fix_env(dev_snd, os.path.join(tmp_dir, "proc", "asound"), extra_bin=mock_bin)
            proc = run_e2e_command(["bash", script_path], env=env, timeout=20)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("sound verbs applied successfully", proc.stdout)
            self.assertTrue(hda_log.exists())


if __name__ == "__main__":
    unittest.main()
