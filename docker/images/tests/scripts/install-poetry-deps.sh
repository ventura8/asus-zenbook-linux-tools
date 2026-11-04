#!/usr/bin/env bash
# Shared Poetry bootstrap for CI test images (invoked from Dockerfiles).
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"
DEPS_DIR="${DEPS_DIR:-/opt/asus-zenbook-deps}"

"$PYTHON_BIN" -m venv /opt/poetry-venv
/opt/poetry-venv/bin/pip install --no-cache-dir --root-user-action=ignore \
    --upgrade pip==26.3 setuptools==84.2.1 wheel==0.48.0
/opt/poetry-venv/bin/pip install --no-cache-dir --root-user-action=ignore poetry==2.5.1

export PATH="/opt/poetry-venv/bin:${PATH}"
export POETRY_VIRTUALENVS_IN_PROJECT=true
cd "$DEPS_DIR"
if [ -f VERSION ]; then
    poetry version "$(tr -d '[:space:]' < VERSION)"
fi
poetry install --with dev --no-interaction --no-root
# set -u safe: HOME may be unset in minimal Docker RUN environments.
if [ -n "${HOME:-}" ]; then
    rm -rf "${HOME}/.cache/pypoetry"
fi
