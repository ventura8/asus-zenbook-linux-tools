#!/usr/bin/env bash
# Coverage utility compatibility loader.
# The implementation is split across smaller modules in scripts/coverage/.

COVERAGE_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/coverage"

# shellcheck source=scripts/coverage/common.sh
source "$COVERAGE_UTILS_DIR/common.sh"
# shellcheck source=scripts/coverage/kcov-scenarios.sh
source "$COVERAGE_UTILS_DIR/kcov-scenarios.sh"
# shellcheck source=scripts/coverage/gates.sh
source "$COVERAGE_UTILS_DIR/gates.sh"
