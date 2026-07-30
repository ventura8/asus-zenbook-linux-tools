"""Helper script to create mock loginctl binary for pipeline testing."""

from __future__ import annotations

import os
import pwd
import shlex
import sys


def _ghost_user_content() -> str:
    """Return loginctl stub body for the default ghost_user fixture."""
    return """#!/bin/sh
if [ "$1" = "list-sessions" ]; then
    printf "c3 1000 ghost_user seat0\\nc1 1000 ghost_user seat0\\n\\n"
    exit 0
fi
if [ "$1" != "show-session" ]; then
    echo "unsupported loginctl command: $1" >&2
    exit 1
fi
if [ -z "$2" ] || [ -z "$4" ]; then
    echo "show-session requires session id and property" >&2
    exit 1
fi
if [ "$4" = "Type" ]; then
    if [ "$2" = "c3" ]; then echo "tty"; exit 0; fi
    echo "${LOGINCTL_STYPE:-x11}"; exit 0
fi
if [ "$4" = "State" ]; then
    if [ "$2" = "c3" ]; then echo "closing"; exit 0; fi
    echo "active"; exit 0
fi
if [ "$4" = "Seat" ]; then echo "seat0"; exit 0; fi
if [ "$4" = "Name" ]; then echo "ghost_user"; exit 0; fi
echo "unsupported show-session property: $4" >&2
exit 1
"""


def _current_user_content(uid: str, user: str) -> str:
    """Return loginctl stub body for the invoking uid/username."""
    user_q = shlex.quote(user)
    return f"""#!/bin/sh
if [ "$1" = "list-sessions" ]; then
    printf '1 %s %s seat0\\n' "{uid}" {user_q}
    exit 0
fi
if [ "$1" != "show-session" ]; then
    echo "unsupported loginctl command: $1" >&2
    exit 1
fi
if [ -z "$2" ] || [ -z "$4" ]; then
    echo "show-session requires session id and property" >&2
    exit 1
fi
case "$4" in
    Type) echo "${{LOGINCTL_STYPE:-x11}}" ;;
    State) echo active ;;
    Seat) echo seat0 ;;
    Name) printf '%s\\n' {user_q} ;;
    *) echo "unsupported show-session property: $4" >&2; exit 1 ;;
esac
exit 0
"""


def _current_username() -> str:
    """Return the current username without requiring a controlling TTY."""
    try:
        return pwd.getpwuid(os.getuid()).pw_name
    except KeyError:
        return str(os.getuid())


def _parse_loginctl_args(argv: list[str]) -> tuple[bool, str]:
    """Return (current_user, target_dir) from CLI argv or exit on bad usage."""
    args = list(argv)
    current_user = False
    if args and args[0] == "--current-user":
        current_user = True
        args = args[1:]
    if len(args) < 1:
        print(
            "Usage: python3 tools/make_fake_loginctl.py [--current-user] <target_dir>",
            file=sys.stderr,
        )
        sys.exit(1)
    target_dir = args[0]
    if not os.path.isdir(target_dir):
        print(f"Error: target directory does not exist: {target_dir}", file=sys.stderr)
        sys.exit(1)
    return current_user, target_dir


def main(argv: list[str] | None = None) -> None:
    """Write mock loginctl script into specified directory."""
    current_user, target_dir = _parse_loginctl_args(sys.argv[1:] if argv is None else argv)
    content = _current_user_content(str(os.getuid()), _current_username()) if current_user else _ghost_user_content()
    loginctl_path = os.path.join(target_dir, "loginctl")
    fd = os.open(loginctl_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o755)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(loginctl_path, 0o755)


if __name__ == "__main__":
    main()
