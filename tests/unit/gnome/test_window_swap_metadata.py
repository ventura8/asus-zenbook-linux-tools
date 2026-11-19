"""GNOME Window Swap extension metadata must declare supported Shell majors."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

_REPO_ROOT = Path(__file__).resolve().parents[3]
_METADATA = (
    _REPO_ROOT
    / "gnome"
    / "asus-window-swap@ventura8.github.com"
    / "metadata.json"
)
_REQUIRED_FLOOR = 45
_REQUIRED_CEILING = 51


class TestWindowSwapShellVersions(unittest.TestCase):
    """Refuse shipping a metadata.json that omits current Ubuntu GNOME majors."""

    def test_shell_version_includes_gnome_51(self) -> None:
        """Require contiguous majors through GNOME 51 for Ubuntu 26.10 hosts."""
        payload = json.loads(_METADATA.read_text(encoding="utf-8"))
        versions = payload.get("shell-version")
        self.assertIsInstance(versions, list)
        self.assertTrue(versions, "shell-version must not be empty")

        numeric: list[int] = []
        for entry in versions:
            self.assertIsInstance(entry, str)
            self.assertRegex(entry, r"^[0-9]+$")
            numeric.append(int(entry))

        # Pin the Ubuntu 26.10 floor/ceiling so dropping 51 (or 45–50) fails closed.
        for major in range(_REQUIRED_FLOOR, _REQUIRED_CEILING + 1):
            self.assertIn(str(major), versions)

        newest = max(numeric)
        oldest = min(numeric)
        self.assertEqual(oldest, _REQUIRED_FLOOR)
        self.assertGreaterEqual(newest, _REQUIRED_CEILING)
        # Contiguous from oldest through newest declared major (no 45…51,53 gaps).
        for major in range(oldest, newest + 1):
            self.assertIn(
                str(major),
                versions,
                f"shell-version gap: missing {major} between {oldest} and {newest}",
            )


if __name__ == "__main__":
    unittest.main()
