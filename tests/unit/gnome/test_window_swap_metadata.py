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


class TestWindowSwapShellVersions(unittest.TestCase):
    """Refuse shipping a metadata.json that omits current Ubuntu GNOME majors."""

    def test_shell_version_includes_gnome_51(self) -> None:
        """Require contiguous majors through GNOME 51 for Ubuntu 26.10 hosts."""
        payload = json.loads(_METADATA.read_text(encoding="utf-8"))
        versions = payload.get("shell-version")
        self.assertIsInstance(versions, list)
        self.assertIn("51", versions)
        # Keep the historical ESM/LTS range so older installs still validate.
        for major in ("45", "46", "47", "48", "49", "50"):
            self.assertIn(major, versions)


if __name__ == "__main__":
    unittest.main()
