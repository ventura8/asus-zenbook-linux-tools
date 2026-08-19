#!/usr/bin/env bash
# Sync tool.poetry.version in pyproject.toml from the root VERSION file.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="${REPO_ROOT}/VERSION"
PYPROJECT="${REPO_ROOT}/pyproject.toml"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Missing VERSION file: $VERSION_FILE" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ -z "$VERSION" ]; then
    echo "VERSION file is empty: $VERSION_FILE" >&2
    exit 1
fi

if [ ! -f "$PYPROJECT" ]; then
    echo "Missing pyproject.toml: $PYPROJECT" >&2
    exit 1
fi

python3 - <<'PYEOF' "$PYPROJECT" "$VERSION"
import sys
from pathlib import Path

pyproject_path = Path(sys.argv[1])
version = sys.argv[2]
lines = pyproject_path.read_text(encoding="utf-8").splitlines(keepends=True)
out: list[str] = []
in_poetry = False
replaced = False
inserted = False

for line in lines:
    stripped = line.strip()
    if stripped == "[tool.poetry]":
        in_poetry = True
        out.append(line)
        continue
    if in_poetry and stripped.startswith("[") and stripped != "[tool.poetry]":
        if not replaced and not inserted:
            out.append(f'version = "{version}"\n')
            inserted = True
        in_poetry = False
    if in_poetry and stripped.startswith("version"):
        key = stripped.split("=", 1)[0].strip()
        if key == "version":
            out.append(f'version = "{version}"\n')
            replaced = True
            continue
    out.append(line)

if in_poetry and not replaced and not inserted:
    # [tool.poetry] was last section — append version before EOF.
    out.append(f'version = "{version}"\n')
    inserted = True

pyproject_path.write_text("".join(out), encoding="utf-8")
PYEOF

python3 - <<'PYEOF' "$REPO_ROOT"
from pathlib import Path
import sys
import tomllib

repo_root = Path(sys.argv[1])
version_path = repo_root / "VERSION"
if not version_path.is_file():
    print("  ✗ Missing VERSION file (single source of truth).", file=sys.stderr)
    sys.exit(1)

file_version = version_path.read_text(encoding="utf-8").strip()
if not file_version:
    print("  ✗ VERSION file is empty.", file=sys.stderr)
    sys.exit(1)

with (repo_root / "pyproject.toml").open("rb") as handle:
    data = tomllib.load(handle)
try:
    poetry_version = data["tool"]["poetry"]["version"]
except KeyError:
    print("  ✗ pyproject.toml missing tool.poetry.version.", file=sys.stderr)
    sys.exit(1)

if file_version != poetry_version:
    print(
        f"  ✗ VERSION ({file_version}) does not match "
        f"pyproject.toml tool.poetry.version ({poetry_version}).",
        file=sys.stderr,
    )
    sys.exit(1)

print(f"  ✓ Version sync passed ({file_version}).")
PYEOF
