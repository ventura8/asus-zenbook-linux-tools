#!/usr/bin/env bash
# Retry pacman for Arch/Manjaro rolling-mirror 404s (superseded package tarballs).
set -euo pipefail

_PACMAN_RETRY_MAX="${PACMAN_RETRY_MAX:-3}"

_pacman_retry_max() {
    if [[ "${_PACMAN_RETRY_MAX}" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "${_PACMAN_RETRY_MAX}"
        return 0
    fi
    printf '3\n'
}

_pacman_wipe_stale_metadata() {
    # Root-only: unit tests must not delete a developer host's pacman DBs.
    if [ "${EUID:-}" != "0" ]; then
        return 0
    fi
    rm -f /var/lib/pacman/sync/*.db /var/lib/pacman/sync/*.db.sig
    rm -f /var/cache/pacman/pkg/*.part
    return 0
}

_pacman_resync_dbs() {
    _pacman_wipe_stale_metadata
    set +e
    pacman -Syy --noconfirm
    set -e
    return 0
}

_pacman_backoff() {
    local secs="${PACMAN_RETRY_SLEEP:-$1}"
    if [ "$secs" = "0" ]; then
        return 0
    fi
    sleep "$secs"
}

_pacman_retry() {
    local attempt=1 max
    max="$(_pacman_retry_max)"
    while [ "$attempt" -le "$max" ]; do
        if pacman "$@"; then
            return 0
        fi
        echo "pacman-retry: attempt ${attempt}/${max} failed; refreshing DBs..." >&2
        _pacman_resync_dbs
        if [ "$attempt" -eq "$max" ]; then
            break
        fi
        attempt=$((attempt + 1))
        _pacman_backoff "$((attempt * 8))"
    done
    echo "pacman-retry: failed after ${max} attempts" >&2
    return 1
}

_pacman_retry_main() {
    if [ "$#" -eq 0 ]; then
        echo "pacman-retry: missing pacman arguments" >&2
        return 2
    fi
    _pacman_retry "$@"
}

_pacman_retry_main "$@"
