#!/usr/bin/env bash

_docker_cache_size_kb() {
    local path="$1"
    if [ ! -d "$path" ]; then
        echo 0
        return 0
    fi
    # Always succeed: du may exit non-zero when it cannot read some entries.
    du -sk "$path" 2>/dev/null | awk 'NF {print $1+0; found=1} END {if (!found) print 0}' || true
    return 0
}

_is_positive_integer() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]
}

_active_cache_is_base() {
    local active_cache_path="$1" cache_base_dir="$2"
    [ -n "$cache_base_dir" ] || return 1
    [ "$active_cache_path" = "$cache_base_dir" ] \
        || [ "$active_cache_path" -ef "$cache_base_dir" ] 2>/dev/null
}

_reset_active_cache_if_oversize() {
    local total_cache_kb="$1" max_cache_kb="$2" active_cache_path="$3" cache_base_dir="$4"
    [ -n "$active_cache_path" ] || return 0
    if [ "$total_cache_kb" -gt "$max_cache_kb" ]; then
        if _active_cache_is_base "$active_cache_path" "$cache_base_dir"; then
            echo "Warning: Docker buildx cache at '$active_cache_path' equals cache base; " \
                "skipping removal (limit ${max_cache_kb}KB, total ${total_cache_kb}KB)." >&2
            return 0
        fi
        rm -rf "$active_cache_path"
        mkdir -p "$active_cache_path"
    fi
}

_docker_oldest_from_find() {
    # Tolerate SIGPIPE from sort when head closes early under pipefail.
    local line
    line=$( { "$@" | sort -n | head -n 1; } || true )
    printf '%s\n' "${line#*$'\t'}"
}

_docker_find_oldest_cache_with_find() {
    local cache_base_dir="$1" active_cache_path="$2"
    if [ -n "$active_cache_path" ] && [ -e "$active_cache_path" ]; then
        _docker_oldest_from_find find "$cache_base_dir" -mindepth 1 -maxdepth 1 -type d \
            ! -samefile "$active_cache_path" -printf '%T@\t%p\n'
    else
        _docker_oldest_from_find find "$cache_base_dir" -mindepth 1 -maxdepth 1 -type d \
            -printf '%T@\t%p\n'
    fi
}

_docker_cache_dir_is_prunable() {
    local dir="$1" active_cache_path="$2"
    [ -d "$dir" ] || return 1
    if [ -n "$active_cache_path" ] && [ "$dir" -ef "$active_cache_path" ] 2>/dev/null; then
        return 1
    fi
}

_docker_dir_mtime() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null || echo 0
}

_docker_mtime_is_older() {
    local candidate="$1" oldest="$2"
    [ -z "$oldest" ] || [ "$candidate" -lt "$oldest" ]
}

_docker_print_nonempty_path() {
    [ -n "$1" ] && printf '%s\n' "$1"
}

_docker_find_oldest_cache_portable() {
    local cache_base_dir="$1" active_cache_path="$2"
    local oldest_dir="" dir mtime oldest_mtime=""
    for dir in "$cache_base_dir"/*; do
        _docker_cache_dir_is_prunable "$dir" "$active_cache_path" || continue
        mtime=$(_docker_dir_mtime "$dir")
        if _docker_mtime_is_older "$mtime" "$oldest_mtime"; then
            oldest_mtime="$mtime"
            oldest_dir="$dir"
        fi
    done
    _docker_print_nonempty_path "$oldest_dir"
}

_docker_find_oldest_cache_subdir() {
    local cache_base_dir="$1" active_cache_path="$2"
    if find "$cache_base_dir" -mindepth 0 -maxdepth 0 -printf '%p\n' >/dev/null 2>&1; then
        _docker_find_oldest_cache_with_find "$cache_base_dir" "$active_cache_path"
        return 0
    fi
    _docker_find_oldest_cache_portable "$cache_base_dir" "$active_cache_path"
    return 0
}

_docker_count_prunable_cache_subdirs() {
    local cache_base_dir="$1" active_cache_path="$2"
    local count=0 dir
    for dir in "$cache_base_dir"/*; do
        [ -d "$dir" ] || continue
        if [ -n "$active_cache_path" ] && [ "$dir" -ef "$active_cache_path" ] 2>/dev/null; then
            continue
        fi
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

_docker_prune_one_oldest_cache() {
    local cache_base_dir="$1" active_cache_path="$2"
    local oldest_dir
    oldest_dir=$(_docker_find_oldest_cache_subdir "$cache_base_dir" "$active_cache_path")
    [ -n "$oldest_dir" ] || return 1
    rm -rf "$oldest_dir"
    # Successful removal counts as progress even when du rounds to the same KB.
    _docker_cache_size_kb "$cache_base_dir"
    return 0
}

_docker_require_nonempty_cache_base() {
    if [ -n "${1:-}" ]; then
        return 0
    fi
    echo "Error: empty cache_base_dir; refusing ${2:-operation}" >&2
    return 1
}

_docker_prune_max_cache_kb_or_skip() {
    local max_cache_kb="${DOCKER_BUILDX_CACHE_MAX_KB:-2097152}"
    if [ "${DOCKER_BUILDX_SKIP_PRUNE:-0}" = "1" ]; then
        return 1
    fi
    if _is_positive_integer "$max_cache_kb"; then
        printf '%s\n' "$max_cache_kb"
        return 0
    fi
    echo "Warning: invalid DOCKER_BUILDX_CACHE_MAX_KB=${max_cache_kb}; skipping buildx cache prune" >&2
    return 1
}

_docker_prune_until_under_limit() {
    local cache_base_dir="$1" active_cache_path="$2" max_cache_kb="$3"
    local total_cache_kb remaining next_kb
    total_cache_kb="$(_docker_cache_size_kb "$cache_base_dir")"
    remaining=$(_docker_count_prunable_cache_subdirs "$cache_base_dir" "$active_cache_path")
    while [ "$total_cache_kb" -gt "$max_cache_kb" ] && [ "$remaining" -gt 0 ]; do
        if ! next_kb="$(_docker_prune_one_oldest_cache "$cache_base_dir" "$active_cache_path")"; then
            echo "Warning: Docker buildx cache prune made no progress under '$cache_base_dir' " \
                "(limit ${max_cache_kb}KB, current ${total_cache_kb}KB)." >&2
            break
        fi
        total_cache_kb="$next_kb"
        remaining=$((remaining - 1))
    done
    printf '%s\n' "$total_cache_kb"
}

_docker_prune_buildx_local_cache() {
    local cache_base_dir="$1" active_cache_path="$2"
    local max_cache_kb total_cache_kb

    _docker_require_nonempty_cache_base "$cache_base_dir" "buildx cache prune" || return 1
    max_cache_kb=$(_docker_prune_max_cache_kb_or_skip) || return 0
    total_cache_kb=$(_docker_prune_until_under_limit "$cache_base_dir" "$active_cache_path" "$max_cache_kb")
    _reset_active_cache_if_oversize "$total_cache_kb" "$max_cache_kb" "$active_cache_path" "$cache_base_dir"
}

_docker_host_uid_gid() {
    # Prefer the invoking user's IDs when this script runs under sudo (id -u → 0).
    # Building ASUS_CI_UID=0 renames/usermods root inside the image and fails.
    local uid gid
    uid="${ASUS_CI_UID:-${SUDO_UID:-$(id -u)}}"
    gid="${ASUS_CI_GID:-${SUDO_GID:-$(id -g)}}"
    case "$uid" in
        '' | *[!0-9]* | 0)
            echo "Invalid ASUS_CI_UID '${uid:-<empty>}' (need a positive numeric host UID)" >&2
            return 1
            ;;
    esac
    case "$gid" in
        '' | *[!0-9]* | 0)
            echo "Invalid ASUS_CI_GID '${gid:-<empty>}' (need a positive numeric host GID)" >&2
            return 1
            ;;
    esac
    printf '%s %s\n' "$uid" "$gid"
}

_docker_host_targetarch() {
    # Map host machine to Docker TARGETARCH (lint image hadolint download, etc.).
    case "$(uname -m)" in
        x86_64 | amd64) printf '%s\n' amd64 ;;
        aarch64 | arm64) printf '%s\n' arm64 ;;
        *)
            echo "Unsupported host architecture '$(uname -m)' for TARGETARCH" >&2
            return 1
            ;;
    esac
}

_docker_require_bash_nameref() {
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then
        echo "Bash >= 4.3 is required for nameref support (found ${BASH_VERSION})" >&2
        return 1
    fi
    return 0
}

_docker_ci_build_args() {
    _docker_require_bash_nameref || return 1
    local -n _build_args_ref="$1"
    local host_uid host_gid uid_gid targetarch
    uid_gid=$(_docker_host_uid_gid) || return 1
    read -r host_uid host_gid <<< "$uid_gid" || return 1
    targetarch=$(_docker_host_targetarch) || return 1
    _build_args_ref=(
        --build-arg "ASUS_CI_UID=$host_uid"
        --build-arg "ASUS_CI_GID=$host_gid"
        --build-arg "ASUS_CI_USER=asusci"
        --build-arg "TARGETARCH=$targetarch"
        --build-arg "ASUS_CI_DE_FAMILY=${ASUS_CI_DE_FAMILY:-}"
    )
}

_docker_buildx_build_with_cache() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4"
    local cache_base_dir="$5" cache_path="$6"
    shift 6
    local -a build_args=("$@")
    local cache_from_args=() build_status=0
    mkdir -p "$cache_path"
    if [ -f "$cache_path/index.json" ]; then
        cache_from_args=(--cache-from "type=local,src=$cache_path")
    fi
    "$docker_bin" buildx build \
        --load \
        -f "$dockerfile_path" \
        -t "$image_tag" \
        "${build_args[@]}" \
        "${cache_from_args[@]}" \
        --cache-to "type=local,dest=$cache_path,mode=max" \
        "$repo_root" || build_status=$?
    # Failed builds may leave partial cache exports; still prune for size control.
    _docker_prune_buildx_local_cache "$cache_base_dir" "$cache_path"
    return "$build_status"
}

_docker_legacy_build() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4"
    local cache_base_dir="$5" cache_path="$6"
    shift 6
    # Legacy docker build: prune local cache before build (same size control as buildx).
    _docker_prune_buildx_local_cache "$cache_base_dir" "$cache_path" || return 1
    "$docker_bin" build \
        -f "$dockerfile_path" \
        -t "$image_tag" \
        "$@" \
        "$repo_root"
}

docker_build_with_buildx_or_build() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4" cache_base_dir="$5" cache_key="$6"
    local cache_path="$cache_base_dir/$cache_key"
    local -a build_args
    _docker_require_bash_nameref || return 1
    _docker_require_nonempty_cache_base "$cache_base_dir" "Docker buildx cache path" || return 1
    _docker_ci_build_args build_args || return 1

    if "$docker_bin" buildx version >/dev/null 2>&1; then
        _docker_buildx_build_with_cache "$docker_bin" "$dockerfile_path" "$image_tag" \
            "$repo_root" "$cache_base_dir" "$cache_path" "${build_args[@]}"
        return $?
    fi
    _docker_legacy_build "$docker_bin" "$dockerfile_path" "$image_tag" \
        "$repo_root" "$cache_base_dir" "$cache_path" "${build_args[@]}"
}