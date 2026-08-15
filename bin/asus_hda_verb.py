#!/usr/bin/env python3
"""Minimal HD-audio verb writer compatible with alsa-tools hda-verb numeric CLI.

Used automatically when distro packages do not ship ``hda-verb`` (notably
Rocky/RHEL, which only provide ``alsa-tools-firmware``). Prefer a system
``hda-verb`` when present; this helper covers the numeric form:

    asus_hda_verb.py /dev/snd/hwC0D0 0x20 0x500 0x1b
"""

from __future__ import annotations

import argparse
import array
import fcntl
import struct
import sys

_IOC_READ = 2
_IOC_WRITE = 1
HDA_HWDEP_VERSION = 0x10000


def _ioc(direction: int, type_char: str, number: int, size: int) -> int:
    """Build a Linux ioctl request number."""
    return direction << 30 | size << 16 | ord(type_char) << 8 | number


def _ioctl_request(request: int) -> int:
    """Return an ioctl request safe for fcntl on signed C int platforms."""
    if request > 0x7FFFFFFF:
        return request - 0x100000000
    return request


HDA_IOCTL_PVERSION = _ioc(_IOC_READ, "H", 0x10, 4)
HDA_IOCTL_VERB_WRITE = _ioc(_IOC_READ | _IOC_WRITE, "H", 0x11, 8)


def parse_int(value: str) -> int:
    """Parse a decimal or 0x-prefixed hex integer."""
    return int(value, 0)


def _uses_wide_param(verb: int) -> bool:
    """Return True when alsa-tools hda-verb accepts a 16-bit parameter for *verb*."""
    if verb <= 0xF:
        return True
    if verb <= 0xFFF and not verb & 0xFF:
        return True
    return 0x400 <= verb <= 0x4FF


def _param_limit(verb: int) -> int:
    """Return max param width for a verb (alsa-tools numeric hda-verb rules)."""
    if _uses_wide_param(verb):
        return 0xFFFF
    return 0xFF


def _verb_param_word(verb: int, param: int) -> int:
    """Pack verb and param into the lower 24 bits of an HDA verb word."""
    if verb <= 0xF:
        return (verb << 16) | param
    if _uses_wide_param(verb):
        return (verb << 8) | param
    return (verb << 8) | (param & 0xFF)


def pack_verb(nid: int, verb: int, param: int) -> int:
    """Encode NID/verb/param into a single HDA verb word."""
    if not 0 <= nid <= 0xFF:
        raise ValueError(f"NID out of range (0-0xff): {nid:#x}")
    if not 0 <= verb <= 0xFFFF:
        raise ValueError(f"verb out of range (0-0xffff): {verb:#x}")
    param_limit = _param_limit(verb)
    if not 0 <= param <= param_limit:
        raise ValueError(f"param out of range (0-0x{param_limit:x}): {param:#x}")
    return (nid << 24) | _verb_param_word(verb, param)


def verb_buffer(verb: int, res: int = 0) -> array.array:
    """Mutable struct for IOWR verb write (verb, res)."""
    if array.array("I").itemsize != 4:
        raise RuntimeError("array('I') itemsize must be 4 for HDA verb buffer")
    return array.array("I", [verb & 0xFFFFFFFF, res & 0xFFFFFFFF])


def write_verb(device: str, nid: int, verb: int, param: int) -> int:
    """Send one verb via HDA hwdep ioctl; return codec response."""
    packed = pack_verb(nid, verb, param)
    with open(device, "rb+", buffering=0) as handle:
        version = struct.unpack(
            "i",
            fcntl.ioctl(handle, _ioctl_request(HDA_IOCTL_PVERSION), struct.pack("i", 0)),
        )[0]
        if version < HDA_HWDEP_VERSION:
            raise OSError(f"HDA hwdep version too old: {version:#x}")
        buf = verb_buffer(packed)
        fcntl.ioctl(handle, _ioctl_request(HDA_IOCTL_VERB_WRITE), buf)
        return int(buf[1])


def build_parser() -> argparse.ArgumentParser:
    """CLI parser matching alsa-tools numeric hda-verb usage."""
    parser = argparse.ArgumentParser(description="Send one HD-audio verb via hwdep")
    parser.add_argument("device", help="HDA hwdep device path (e.g. /dev/snd/hwC0D0)")
    parser.add_argument("nid", type=parse_int, help="Widget NID")
    parser.add_argument("verb", type=parse_int, help="Verb code")
    parser.add_argument("param", type=parse_int, help="Verb parameter")
    return parser


def main(argv: list[str] | None = None) -> int:
    """Entry point: write verb and print response like alsa-tools hda-verb."""
    args = build_parser().parse_args(argv)
    try:
        response = write_verb(args.device, args.nid, args.verb, args.param)
    except (OSError, RuntimeError, ValueError, struct.error) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    print(f"value = 0x{response:08x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
