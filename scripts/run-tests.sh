#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"
mkdir -p reports/distro-logs
./scripts/run_docker_matrix.sh "$@" 2>&1 | tee reports/distro-logs/tests.log
exit "${PIPESTATUS[0]}"
