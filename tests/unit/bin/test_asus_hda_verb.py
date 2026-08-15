"""Unit tests for bin/asus_hda_verb.py."""

import array
import io
import struct
import sys
import unittest
from pathlib import Path
from unittest import mock

import shared_imports
from tests.unit.bin.attr_helpers import get_attr

PROJECT_ROOT = Path(__file__).resolve().parents[3]
BIN_DIR = PROJECT_ROOT / "bin"


def _load_hda_module():
    """Load bin/asus_hda_verb.py via shared_imports.load_module_from_path."""
    path = BIN_DIR / "asus_hda_verb.py"
    if str(BIN_DIR) not in sys.path:
        sys.path.insert(0, str(BIN_DIR))
    module_name = "asus_hda_verb"
    existing = sys.modules.get(module_name)
    if existing is not None and getattr(existing, "__file__", None) == str(path):
        return existing
    return shared_imports.load_module_from_path(module_name, str(path))


hda = _load_hda_module()


class TestAsusHdaVerb(unittest.TestCase):
    """Numeric hda-verb fallback helper."""

    def test_pack_and_parse(self):
        """Verb packing and int parsing match alsa-tools layout."""
        self.assertEqual(hda.parse_int("0x20"), 0x20)
        self.assertEqual(hda.parse_int("32"), 32)
        self.assertEqual(hda.pack_verb(0x20, 0x500, 0x1B), 0x2005001B)

    def test_pack_verb_small_verb_uses_high_shift(self):
        """Verbs <= 0xF pack 16-bit params without overlapping the verb nibble."""
        self.assertEqual(hda.pack_verb(0x20, 0x5, 0x1234), 0x20051234)

    def test_pack_verb_sound_fix_realtek_wide_param(self):
        """Realtek sound-fix verb pair uses full 16-bit param in the HDA word."""
        self.assertEqual(hda.pack_verb(0x20, 0x477, 0x4A4B), 0x20047F4B)

    def test_pack_verb_zero_low_byte_verb_accepts_16_bit_param(self):
        """12-bit verbs with a zero low byte accept 16-bit parameters."""
        self.assertEqual(hda.pack_verb(0x20, 0x500, 0x1FF), 0x200501FF)

    def test_pack_verb_rejects_wide_param_outside_wide_rules(self):
        """Verbs outside wide-param rules reject parameters wider than 8 bits."""
        self.assertEqual(hda.pack_verb(0x20, 0x477, 0x4B), 0x2004774B)
        with self.assertRaises(ValueError):
            hda.pack_verb(0x20, 0x123, 0x1FF)

    def test_ioc_constants(self):
        """Linux ioctl request numbers match HDA hwdep header."""
        self.assertEqual(hda.HDA_IOCTL_PVERSION, 0x80044810)
        self.assertEqual(hda.HDA_IOCTL_VERB_WRITE, 0xC0084811)
        ioctl_request = get_attr(hda, "_ioctl_request")
        self.assertEqual(ioctl_request(hda.HDA_IOCTL_PVERSION), hda.HDA_IOCTL_PVERSION - 0x100000000)
        self.assertEqual(ioctl_request(hda.HDA_IOCTL_VERB_WRITE), hda.HDA_IOCTL_VERB_WRITE - 0x100000000)

    def test_write_verb_success(self):
        """write_verb issues PVERSION then VERB_WRITE and returns response."""
        handle = mock.MagicMock()
        calls = []
        ioctl_request = get_attr(hda, "_ioctl_request")

        def ioctl_side_effect(_fd, request, arg):
            calls.append(request)
            if request == ioctl_request(hda.HDA_IOCTL_PVERSION):
                return struct.pack("i", 0x10000)
            if request == ioctl_request(hda.HDA_IOCTL_VERB_WRITE):
                self.assertEqual(int(arg[0]), hda.pack_verb(0x20, 0x500, 0x1B))
                arg[1] = 0xABCD
                return 0
            raise AssertionError(f"unexpected ioctl {request:#x}")

        with mock.patch("builtins.open", return_value=handle):
            handle.__enter__.return_value = handle
            handle.__exit__.return_value = False
            with mock.patch("fcntl.ioctl", side_effect=ioctl_side_effect):
                result = hda.write_verb("/dev/snd/hwC0D0", 0x20, 0x500, 0x1B)
        self.assertEqual(result, 0xABCD)
        self.assertEqual(
            calls,
            [ioctl_request(hda.HDA_IOCTL_PVERSION), ioctl_request(hda.HDA_IOCTL_VERB_WRITE)],
        )

    def test_write_verb_rejects_old_version(self):
        """Old hwdep protocol versions raise OSError."""
        handle = mock.MagicMock()
        ioctl_request = get_attr(hda, "_ioctl_request")

        def ioctl_side_effect(_fd, request, _arg):
            if request == ioctl_request(hda.HDA_IOCTL_PVERSION):
                return struct.pack("i", 0xFFFF)
            raise AssertionError("VERB_WRITE should not run")

        with mock.patch("builtins.open", return_value=handle):
            handle.__enter__.return_value = handle
            handle.__exit__.return_value = False
            with mock.patch("fcntl.ioctl", side_effect=ioctl_side_effect), self.assertRaises(OSError):
                hda.write_verb("/dev/snd/hwC0D0", 0x20, 0x500, 0x1B)

    def test_main_standard_verb_success(self):
        """main() returns 0 for a standard verb write."""
        handle = mock.MagicMock()
        handle.__enter__.return_value = handle
        handle.__exit__.return_value = False
        ioctl_request = get_attr(hda, "_ioctl_request")

        def ioctl_success(_fd, request, arg):
            if request == ioctl_request(hda.HDA_IOCTL_PVERSION):
                return struct.pack("i", hda.HDA_HWDEP_VERSION)
            if request == ioctl_request(hda.HDA_IOCTL_VERB_WRITE):
                self.assertEqual(int(arg[0]), hda.pack_verb(0x20, 0x500, 0x1B))
                arg[1] = 0x11
                return 0
            raise AssertionError(f"unexpected ioctl {request:#x}")

        with mock.patch("builtins.open", return_value=handle), mock.patch("fcntl.ioctl", side_effect=ioctl_success):
            stderr = io.StringIO()
            stdout = io.StringIO()
            with mock.patch("sys.stderr", stderr), mock.patch("sys.stdout", stdout):
                self.assertEqual(hda.main(["/dev/snd/hwC0D0", "0x20", "0x500", "0x1b"]), 0)
            self.assertIn("0x00000011", stdout.getvalue())
            self.assertEqual(stderr.getvalue(), "")

    def test_main_realtek_wide_param_success(self):
        """main() returns 0 for Realtek wide-param verb 0x477."""
        handle = mock.MagicMock()
        handle.__enter__.return_value = handle
        handle.__exit__.return_value = False
        ioctl_request = get_attr(hda, "_ioctl_request")

        def ioctl_sound_fix(_fd, request, arg):
            if request == ioctl_request(hda.HDA_IOCTL_PVERSION):
                return struct.pack("i", hda.HDA_HWDEP_VERSION)
            if request == ioctl_request(hda.HDA_IOCTL_VERB_WRITE):
                self.assertEqual(int(arg[0]), hda.pack_verb(0x20, 0x477, 0x4A4B))
                arg[1] = 0x22
                return 0
            raise AssertionError(f"unexpected ioctl {request:#x}")

        with mock.patch("builtins.open", return_value=handle), mock.patch("fcntl.ioctl", side_effect=ioctl_sound_fix):
            stdout = io.StringIO()
            with mock.patch("sys.stdout", stdout):
                self.assertEqual(hda.main(["/dev/snd/hwC0D0", "0x20", "0x477", "0x4a4b"]), 0)
            self.assertIn("0x00000022", stdout.getvalue())

    def test_main_oserror_failure(self):
        """main() returns 1 when ioctl raises OSError."""
        handle = mock.MagicMock()
        handle.__enter__.return_value = handle
        handle.__exit__.return_value = False
        with mock.patch("builtins.open", return_value=handle), mock.patch("fcntl.ioctl", side_effect=OSError("denied")):
            stderr = io.StringIO()
            with mock.patch("sys.stderr", stderr):
                self.assertEqual(hda.main(["/dev/snd/hwC0D0", "0x20", "0x500", "0x1b"]), 1)
            self.assertIn("denied", stderr.getvalue())

    def test_verb_buffer(self):
        """Verb buffer is a mutable unsigned-int pair."""
        buf = hda.verb_buffer(1, 2)
        self.assertIsInstance(buf, array.array)
        self.assertEqual(buf.typecode, "I")
        self.assertEqual(list(buf), [1, 2])


if __name__ == "__main__":
    unittest.main()
