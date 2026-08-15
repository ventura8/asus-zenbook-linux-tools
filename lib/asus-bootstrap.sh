#!/usr/bin/env bash
# Shared loader for ASUS ZenBook bin helpers.
# Callers locate this file via literal repo or installed paths, then call
# _source_common_helper. Once the lib directory is known, sibling libs are
# loaded relative to it (standard practice: one libdir discovery).

_ASUS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_try_source_libdir_common() {
    # Libdir that provided this bootstrap (checkout or /usr/local/lib/...).
    # shellcheck source=lib/asus-common.sh
    . "$_ASUS_LIB_DIR/asus-common.sh"
}

_source_common_helper() {
    if [ ! -f "$_ASUS_LIB_DIR/asus-common.sh" ]; then
        echo "Error: Missing common helper lib/asus-common.sh" >&2
        return 1
    fi
    if _try_source_libdir_common; then
        return 0
    fi
    echo "Error: Failed to source common helper $_ASUS_LIB_DIR/asus-common.sh" >&2
    return 1
}
