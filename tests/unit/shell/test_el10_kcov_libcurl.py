"""Unit tests for EL10 kcov libcurl-devel matching helper."""

import os
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_shell_script, write_stubs

_REPO_ROOT = Path(__file__).resolve().parents[3]
_HELPER = _REPO_ROOT / "docker/images/tests/scripts/el10-kcov-libcurl.sh"

_RPM_STUB = r"""#!/bin/sh
log="${EL10_STUB_LOG}"
: >>"$log"
if [ "$1" = "-q" ] && [ "$2" = "--qf" ]; then
    pkg="$4"
    printf '%s query-qf %s\n' "$pkg" >>"$log"
    if [ "$pkg" = "libcurl" ]; then
        printf '%s\n' "${EL10_LIBCURL_VR:-8.12.1-4.el10}"
        exit 0
    fi
    exit 1
fi
if [ "$1" = "-q" ]; then
    pkg="$2"
    printf '%s query %s\n' "$pkg" >>"$log"
    if [ "$pkg" = "libcurl" ] && [ "${EL10_HAS_LIBCURL:-1}" = "1" ]; then
        exit 0
    fi
    exit 1
fi
echo "unexpected rpm args: $*" >&2
exit 2
"""

_DNF_STUB = r"""#!/bin/sh
log="${EL10_STUB_LOG}"
: >>"$log"
printf 'dnf %s\n' "$*" >>"$log"
if [ "${EL10_EXACT_DEVEL_FAIL:-0}" = "1" ]; then
    case " $* " in
        *" libcurl-devel-"*)
            echo "No match for argument: libcurl-devel-*" >&2
            exit 1
            ;;
    esac
fi
exit 0
"""


class TestEl10KcovLibcurl(unittest.TestCase):
    """Install libcurl-devel at the same VR as installed libcurl."""

    def _run(self, tmp: Path, extra_env=None):
        """Run the helper with rpm/dnf stubs under *tmp*."""
        mock_bin = write_stubs({"rpm": _RPM_STUB, "dnf": _DNF_STUB}, tmp / "bin")
        env = os.environ.copy()
        env["PATH"] = f"{mock_bin}:{env.get('PATH', '')}"
        env["EL10_STUB_LOG"] = str(tmp / "cmds.log")
        if extra_env:
            env.update(extra_env)
        return run_shell_script(_HELPER, env=env, timeout=10)

    def test_installs_devel_matching_installed_libcurl(self):
        """Exact libcurl-devel-VERSION-RELEASE is requested after aligning libcurl."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run(tmp, extra_env={"EL10_LIBCURL_VR": "8.12.1-4.el10"})
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            log = (tmp / "cmds.log").read_text(encoding="utf-8")
            self.assertIn("--allowerasing --nobest libcurl curl", log)
            self.assertIn("libcurl-devel-8.12.1-4.el10", log)
            self.assertNotIn("installing --nobest", proc.stderr)

    def test_falls_back_to_nobest_when_exact_devel_missing(self):
        """If the matching devel RPM is gone, --nobest is the documented dnf path."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run(tmp, extra_env={"EL10_EXACT_DEVEL_FAIL": "1"})
            self.assertEqual(proc.returncode, 0, msg=proc.stderr)
            log = (tmp / "cmds.log").read_text(encoding="utf-8")
            self.assertIn("libcurl-devel-8.12.1-4.el10", log)
            self.assertIn("--nobest libcurl-devel", log)
            self.assertIn("exact devel missing", proc.stderr)

    def test_fails_closed_when_libcurl_is_missing(self):
        """kcov cannot build without CURL; do not skip-broken past a missing libcurl."""
        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp = Path(tmp_dir)
            proc = self._run(tmp, extra_env={"EL10_HAS_LIBCURL": "0"})
            self.assertEqual(proc.returncode, 1, msg=proc.stdout)
            self.assertIn("libcurl is not installed", proc.stderr)
