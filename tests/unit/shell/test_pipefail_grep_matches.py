"""Pattern checks on large text must not fail under `set -o pipefail`.

`printf '%s\\n' "$x" | grep -q …` SIGPIPEs the writer (status 141) when grep
exits on an early match while printf is still writing, so a *matching* message
counted as a failure. It surfaced as an intermittent CI failure of the container
uninstall smoke (systemctl transport errors treated as real errors). Large
inputs make that race deterministic, so these tests pin the here-string form.
"""

import os
import shlex
import tempfile
import unittest
from pathlib import Path

from tests.unit.shell.shell_test_utils import run_bash_c, write_fake_executable

REPO_ROOT = Path(__file__).resolve().parents[3]
UNINSTALL = REPO_ROOT / "uninstall.sh"
SESSION_LIB = REPO_ROOT / "lib" / "asus-session.sh"
# ~1 MiB of filler after the matching first line: far beyond any pipe buffer.
_FILLER = 'printf "filler line %s\\n" $(seq 1 60000)'


def _source_uninstall(check: str) -> str:
    """Return a pipefail snippet that sources uninstall.sh without running main."""
    return (
        "set -euo pipefail; export ASUS_UNINSTALL_SOURCE_ONLY=1; "
        f"source {shlex.quote(str(UNINSTALL))} >/dev/null 2>&1; {check}"
    )


class TestPipefailSafeUninstallMatches(unittest.TestCase):
    """uninstall.sh transport / absent-unit detection on large stderr."""

    def _status(self, func: str, first_line: str) -> int:
        """Return *func*'s status for *first_line* followed by ~1 MiB of filler."""
        snippet = _source_uninstall(
            f"msg=$(printf '%s\\n' {shlex.quote(first_line)}; {_FILLER}); "
            f'if {func} "$msg"; then echo MATCH; else echo "NOMATCH $?"; fi'
        )
        proc = run_bash_c(snippet, timeout=20, log_name=f"pipefail-{func}")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        return 0 if proc.stdout.strip() == "MATCH" else 1

    def test_transport_error_matches_despite_large_stderr(self):
        """A systemd-not-PID-1 message is still recognised as a transport error."""
        line = "System has not been booted with systemd as init system (PID 1). Can't operate."
        self.assertEqual(self._status("_is_systemctl_transport_unavailable", line), 0)

    def test_absent_unit_matches_despite_large_stderr(self):
        """A 'not loaded' message is still recognised as an absent unit."""
        self.assertEqual(self._status("_is_absent_unit_error", "Unit asus-x.service not loaded."), 0)

    def test_unrelated_error_still_does_not_match(self):
        """Non-matching text keeps failing both checks."""
        self.assertEqual(self._status("_is_systemctl_transport_unavailable", "Access denied"), 1)


class TestPipefailSafeSchemaProbe(unittest.TestCase):
    """asus-session.sh Mint schema probe over a long `gsettings list-schemas`."""

    def test_cinnamon_schema_found_first_in_long_list(self):
        """A match on the first of many schemas returns cinnamon under pipefail."""
        with tempfile.TemporaryDirectory() as tmp:
            write_fake_executable(
                os.path.join(tmp, "gsettings"),
                "#!/bin/bash\necho org.cinnamon.desktop.keybindings\n"
                'for i in $(seq 1 60000); do echo "org.example.schema$i"; done\n',
            )
            env = dict(os.environ, PATH=f"{tmp}:{os.environ.get('PATH', '/usr/bin:/bin')}")
            snippet = (
                "set -euo pipefail; "
                f"source {shlex.quote(str(SESSION_LIB))} >/dev/null 2>&1; "
                "_asus_probe_de_schema_family"
            )
            proc = run_bash_c(snippet, env=env, timeout=20, log_name="pipefail-schema-probe")
        self.assertEqual(proc.returncode, 0, msg=proc.stderr)
        self.assertEqual(proc.stdout.strip(), "cinnamon")


if __name__ == "__main__":
    unittest.main()
