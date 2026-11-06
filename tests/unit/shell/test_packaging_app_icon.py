"""Application icon wiring guards for the portable package builders."""

from __future__ import annotations

import unittest
from pathlib import Path
from xml.etree import ElementTree

APP_ICON = "assets/icons/asus-zenbook-linux-tools.svg"
SVG_NS = "{http://www.w3.org/2000/svg}"


class TestPackagingAppIcon(unittest.TestCase):
    """Store and launcher icons use the app icon, never a notification glyph."""

    @classmethod
    def setUpClass(cls) -> None:
        """Resolve the repository root once."""
        cls.repo_root = Path(__file__).resolve().parents[3]

    def _read(self, relpath: str) -> str:
        return (self.repo_root / relpath).read_text(encoding="utf-8")

    def test_app_icon_is_a_square_svg_without_text(self) -> None:
        """A square viewBox and outlined shapes render the same on every store."""
        root = ElementTree.parse(self.repo_root / APP_ICON).getroot()
        self.assertEqual(root.tag, f"{SVG_NS}svg")
        self.assertEqual(root.get("viewBox"), "0 0 256 256")
        self.assertEqual(list(root.iter(f"{SVG_NS}text")), [])

    def test_snapcraft_icon_key_uses_app_icon(self) -> None:
        """The Snap Store listing reads the top-level icon key."""
        self.assertIn(f"\nicon: {APP_ICON}\n", self._read("packaging/snap/snapcraft.yaml"))

    def test_flatpak_exports_app_icon_under_the_app_id(self) -> None:
        """Flatpak only exports hicolor icons named after the app id."""
        manifest = self._read("packaging/flatpak/org.github.ventura8.AsusZenBookLinuxTools.yml")
        self.assertIn(
            f"install -Dm644 {APP_ICON}\n"
            "        /app/share/icons/hicolor/scalable/apps/org.github.ventura8.AsusZenBookLinuxTools.svg",
            manifest,
        )

    def test_appimage_uses_app_icon_for_desktop_entry_name(self) -> None:
        """AppDir root icon must match the desktop entry Icon= value."""
        builder = self._read("packaging/appimage/build-appimage.sh")
        self.assertIn(
            f'cp "${{REPO_ROOT}}/{APP_ICON}" \\\n    "${{APP_DIR}}/asus-zenbook-linux-tools.svg"',
            builder,
        )

    def test_portable_builders_do_not_use_notification_glyphs(self) -> None:
        """Symbolic glyphs stay reserved for runtime notifications."""
        for relpath in (
            "packaging/snap/snapcraft.yaml",
            "packaging/flatpak/org.github.ventura8.AsusZenBookLinuxTools.yml",
            "packaging/appimage/build-appimage.sh",
        ):
            with self.subTest(relpath=relpath):
                self.assertNotIn("-symbolic.svg", self._read(relpath))


if __name__ == "__main__":
    unittest.main()
