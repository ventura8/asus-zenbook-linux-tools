#!/usr/bin/env bash

# Directory of this sourced file (BASH_SOURCE inside functions is the caller).
_GATES_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=gates_shell.sh
source "${_GATES_SH_DIR}/gates_shell.sh"
# shellcheck source=gates_python.sh
source "${_GATES_SH_DIR}/gates_python.sh"
# shellcheck source=gates_kcov.sh
source "${_GATES_SH_DIR}/gates_kcov.sh"
