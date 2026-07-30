"""Unit tests for bin/asus-sound-fix.sh."""

import os
import shlex
import shutil
import tempfile
import unittest

from tests.unit.shell.shell_test_utils import (
    assert_shell_source_smoke,
    bin_script,
    run_bash_c,
    run_shell_script,
    write_fake_executable,
)

SCRIPT = bin_script("asus-sound-fix.sh")


def _run_sound_fix(dev_snd, proc_asound, extra_env=None):
    """Run the sound-fix script with overridden sysfs roots."""
    env = dict(
        os.environ,
        DEV_SND_ROOT=dev_snd,
        PROC_ASOUND_ROOT=proc_asound,
    )
    if extra_env:
        env.update(extra_env)
    return run_shell_script(SCRIPT, env=env, timeout=30)


def _setup_codec(dev_snd, proc_asound, codec_content="ALC294\n"):
    """Create minimal sysfs layout for a matching ALC294 codec."""
    os.makedirs(dev_snd, exist_ok=True)
    with open(os.path.join(dev_snd, "hwC0D0"), "w", encoding="utf-8"):
        pass
    card_dir = os.path.join(proc_asound, "card0")
    os.makedirs(card_dir, exist_ok=True)
    with open(os.path.join(card_dir, "codec#0"), "w", encoding="utf-8") as f:
        f.write(codec_content)


def _fake_hda_verb(mock_bin, exit_code=0):
    """Install a fake hda-verb that exits with *exit_code*."""
    path = os.path.join(mock_bin, "hda-verb")
    write_fake_executable(path, f"#!/bin/sh\nexit {exit_code}\n")


def _symlink_executable(target, link_path):
    """Link target into the mock bin, and raise AssertionError if target is not executable."""
    if os.path.exists(link_path):
        return
    if not os.access(target, os.X_OK):
        raise AssertionError(f"Required executable is not runnable: {target}")
    os.symlink(target, link_path)


SOUND_FIX_REQUIRED_BINARIES = (
    "bash",
    "sed",
    "grep",
    "sleep",
    "cat",
    "mktemp",
    "rm",
    "dirname",
    "python3",
)


def _read_shebang_parts(target: str) -> list[str] | None:
    """Return shebang argv tokens for *target*, or None when absent/unreadable."""
    try:
        with open(target, "rb") as handle:
            head = handle.readline()
    except OSError:
        return None
    if not head.startswith(b"#!"):
        return None
    parts = head[2:].decode("utf-8", errors="replace").strip().split()
    return parts or None


def _env_shebang_lookup_token(parts: list[str], *, binary: str, target: str) -> str:
    """Return the first non-option token after ``/env`` in a shebang."""
    for token in parts[1:]:
        if token.startswith("-"):
            continue
        return token
    raise AssertionError(
        f"Isolated PATH for {binary!r} resolves to wrapper {target!r} whose env shebang has no interpreter token after options: {parts!r}"
    )


def _path_lookup_from_shebang(parts: list[str], *, binary: str, target: str) -> str | None:
    """Return a PATH-looked-up name, or None when an absolute shebang is host-resolved."""
    head = parts[0]
    if head.endswith("/env") and len(parts) > 1:
        return _env_shebang_lookup_token(parts, binary=binary, target=target)
    if not head.startswith("/"):
        return os.path.basename(head)
    if os.path.isfile(head):
        return None
    raise AssertionError(
        f"Isolated PATH for {binary!r} resolves to wrapper {target!r} whose shebang interpreter {head!r} is missing on the host"
    )


def _wrapper_lookup_is_satisfied(needed: str | None, binary: str, mock_bin: str, required: tuple[str, ...]) -> bool:
    """Return True when a wrapper's PATH dependency is already covered."""
    if needed == binary:
        raise AssertionError(f"Isolated PATH for {binary!r} resolves to wrapper whose env shebang is self-referential ({needed!r})")
    if needed is None:
        return True
    if needed in required:
        return True
    return os.path.exists(os.path.join(mock_bin, needed))


def _assert_wrapper_compatible(binary: str, target: str, mock_bin: str, required: tuple[str, ...]) -> None:
    """Fail when a wrapper shebang cannot run (missing host absolute interpreter or env target)."""
    parts = _read_shebang_parts(target)
    if parts is None:
        return
    needed = _path_lookup_from_shebang(parts, binary=binary, target=target)
    if _wrapper_lookup_is_satisfied(needed, binary, mock_bin, required):
        return
    raise AssertionError(
        f"Isolated PATH for {binary!r} resolves to wrapper {target!r} that needs "
        f"{needed!r}, which is absent from SOUND_FIX_REQUIRED_BINARIES"
    )


def _make_isolated_path_from_mock_bin(mock_bin, extra_binaries=()):
    """Build a mock-bin-only PATH with required utilities symlinked in."""
    required_binaries = (*SOUND_FIX_REQUIRED_BINARIES, *extra_binaries)

    for binary in required_binaries:
        binary_path = shutil.which(binary)
        if binary_path is None:
            raise AssertionError(f"Required test dependency not found in PATH: {binary}")
        _symlink_executable(binary_path, os.path.join(mock_bin, binary))
        _assert_wrapper_compatible(binary, binary_path, mock_bin, required_binaries)

    return mock_bin


class TestAsusSoundFixUnit(unittest.TestCase):
    """Unit tests for bin/asus-sound-fix.sh."""

    def test_no_card_exits_1_with_message(self):
        """Exits 1 with codec error when no matching sound card is found."""
        with tempfile.TemporaryDirectory() as tmpdir:
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            os.makedirs(dev_snd, exist_ok=True)
            os.makedirs(proc_asound, exist_ok=True)
            proc = _run_sound_fix(dev_snd, proc_asound)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Could not find sound card containing ALC294/Cirrus codec", proc.stderr)

    def test_nonmatching_codec_exits_1(self):
        """Exits 1 with codec error when a sound device exists but does not match ALC294/Cirrus."""
        with tempfile.TemporaryDirectory() as tmpdir:
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound, codec_content="AD1988\n")
            proc = _run_sound_fix(dev_snd, proc_asound)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("Could not find sound card containing ALC294/Cirrus codec", proc.stderr)

    def test_hda_verb_missing_exits_1(self):
        """Exits 1 when codec found but neither hda-verb nor fallback is available."""
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            tempfile.TemporaryDirectory() as mock_bin,
        ):
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound)
            isolated_path = _make_isolated_path_from_mock_bin(mock_bin)
            # Run a copy of the shell helper alone so checkout asus_hda_verb.py is not found.
            script_copy = os.path.join(tmpdir, "asus-sound-fix.sh")
            shutil.copy2(SCRIPT, script_copy)
            env = dict(
                os.environ,
                DEV_SND_ROOT=dev_snd,
                PROC_ASOUND_ROOT=proc_asound,
                PATH=isolated_path,
                BIN_ROOT=os.path.join(tmpdir, "empty-bin"),
            )
            os.makedirs(env["BIN_ROOT"], exist_ok=True)
            proc = run_shell_script(script_copy, env=env, timeout=30)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("hda-verb is not installed", proc.stderr)
        self.assertIn("asus_hda_verb.py fallback is missing", proc.stderr)

    def test_python_fallback_used_when_hda_verb_missing(self):
        """Uses asus_hda_verb.py when system hda-verb is absent."""
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            tempfile.TemporaryDirectory() as mock_bin,
        ):
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound)
            isolated_path = _make_isolated_path_from_mock_bin(mock_bin)
            script_copy = os.path.join(tmpdir, "asus-sound-fix.sh")
            fallback = os.path.join(tmpdir, "asus_hda_verb.py")
            shutil.copy2(SCRIPT, script_copy)
            write_fake_executable(fallback, "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n")
            env = dict(
                os.environ,
                DEV_SND_ROOT=dev_snd,
                PROC_ASOUND_ROOT=proc_asound,
                PATH=isolated_path,
                BIN_ROOT=tmpdir,
            )
            proc = run_shell_script(script_copy, env=env, timeout=30)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("applied successfully", proc.stdout)

    def test_hda_verb_failure_exits_1(self):
        """Exits 1 with verb error when hda-verb returns non-zero."""
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            tempfile.TemporaryDirectory() as mock_bin,
        ):
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound)
            _fake_hda_verb(mock_bin, exit_code=1)
            isolated_path = _make_isolated_path_from_mock_bin(mock_bin)
            proc = _run_sound_fix(
                dev_snd,
                proc_asound,
                extra_env={"PATH": isolated_path},
            )
        self.assertEqual(proc.returncode, 1)
        self.assertIn('Failed command: hda-verb "', proc.stderr)
        self.assertIn("Earlier verbs may already have been applied", proc.stderr)
        self.assertIn("Failed to apply sound verbs", proc.stderr)

    def test_hda_verb_success_exits_0(self):
        """Exits 0 when codec matches and hda-verb succeeds for all verbs."""
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            tempfile.TemporaryDirectory() as mock_bin,
        ):
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound)
            _fake_hda_verb(mock_bin, exit_code=0)
            isolated_path = _make_isolated_path_from_mock_bin(mock_bin)
            proc = _run_sound_fix(
                dev_snd,
                proc_asound,
                extra_env={"PATH": isolated_path},
            )
        self.assertEqual(proc.returncode, 0)
        self.assertIn("applied successfully", proc.stdout)

    def test_sourcing_script_does_not_run_main(self):
        """Sourcing the script should only define functions and not auto-run main."""
        assert_shell_source_smoke(self, SCRIPT, "apply_hda_verbs")

    def test_helper_functions_can_be_invoked_after_sourcing(self):
        """Helper functions should remain callable after the script is sourced."""
        with (
            tempfile.TemporaryDirectory() as tmpdir,
            tempfile.TemporaryDirectory() as mock_bin,
        ):
            dev_snd = os.path.join(tmpdir, "snd")
            proc_asound = os.path.join(tmpdir, "asound")
            _setup_codec(dev_snd, proc_asound)
            _fake_hda_verb(mock_bin, exit_code=0)
            isolated_path = _make_isolated_path_from_mock_bin(mock_bin)
            env = dict(os.environ, DEV_SND_ROOT=dev_snd, PROC_ASOUND_ROOT=proc_asound, PATH=isolated_path)
            command = (
                f"source {shlex.quote(str(SCRIPT))} >/dev/null 2>&1 && "
                '_get_codec_file "$DEV_SND_ROOT/hwC0D0" >/dev/null && '
                'check_codec_match "$DEV_SND_ROOT/hwC0D0" >/dev/null && '
                "find_sound_hwdev >/dev/null && "
                "poll_sound_hwdev >/dev/null && "
                'apply_hda_verbs "$DEV_SND_ROOT/hwC0D0" >/dev/null'
            )
            proc = run_bash_c(command, env=env, timeout=30)
        self.assertEqual(proc.returncode, 0)
        self.assertNotIn("Failed to apply sound verbs", proc.stderr)
        self.assertNotIn("Could not find sound card containing ALC294/Cirrus codec", proc.stderr)
        self.assertNotIn("hda-verb is not installed", proc.stderr)


if __name__ == "__main__":
    unittest.main()
