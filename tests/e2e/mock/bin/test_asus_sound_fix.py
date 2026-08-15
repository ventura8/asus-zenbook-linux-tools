"""E2E tests matching bin/asus-sound-fix.sh."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.e2e.e2e_utils import run_e2e_command

PROJECT_ROOT = str(Path(__file__).resolve().parents[4])
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")


def _path_with_required_entries() -> str:
    """Return PATH containing expected binary locations for shell utilities."""
    inherited_path = os.environ.get("PATH", "")
    required_entries = ["/bin", "/usr/bin", "/usr/sbin"]
    path_entries = [entry for entry in inherited_path.split(os.pathsep) if entry]
    for entry in required_entries:
        if entry not in path_entries:
            path_entries.append(entry)
    return os.pathsep.join(path_entries)


def _build_sound_fix_env(dev_snd: str, proc_asound: str) -> dict[str, str]:
    """Return environment overrides for sound-fix hardware-root probing tests."""
    return dict(
        os.environ,
        DEV_SND_ROOT=dev_snd,
        PROC_ASOUND_ROOT=proc_asound,
        PATH=_path_with_required_entries(),
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


if __name__ == "__main__":
    unittest.main()
