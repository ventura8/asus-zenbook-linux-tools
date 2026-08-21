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

_docker_buildx_cache_backend() {
    # local (default): type=local under .cache/docker-buildx.
    # gha: BuildKit GitHub Actions cache (CI); requires DOCKER_BUILDX_CACHE_SCOPE.
    printf '%s\n' "${DOCKER_BUILDX_CACHE_BACKEND:-local}"
}

_docker_buildx_append_local_cache_args() {
    local cache_path="$1"
    local -n _local_from="$2"
    local -n _local_to="$3"
    mkdir -p "$cache_path"
    if [ -f "$cache_path/index.json" ]; then
        _local_from=(--cache-from "type=local,src=$cache_path")
    fi
    _local_to=(--cache-to "type=local,dest=$cache_path,mode=max")
}

_docker_buildx_append_gha_cache_args() {
    local scope="${DOCKER_BUILDX_CACHE_SCOPE:-}"
    local -n _gha_from="$1"
    local -n _gha_to="$2"
    if [ -z "$scope" ]; then
        echo "DOCKER_BUILDX_CACHE_BACKEND=gha requires non-empty DOCKER_BUILDX_CACHE_SCOPE" >&2
        return 1
    fi
    _gha_from=(--cache-from "type=gha,scope=$scope")
    _gha_to=(--cache-to "type=gha,scope=$scope,mode=max")
}

_docker_buildx_resolve_cache_args() {
    local _cache_base_dir="$1" cache_path="$2"
    local from_name="$3" to_name="$4"
    local backend
    backend="$(_docker_buildx_cache_backend)"
    case "$backend" in
        local)
            _docker_buildx_append_local_cache_args "$cache_path" "$from_name" "$to_name"
            ;;
        gha)
            _docker_buildx_append_gha_cache_args "$from_name" "$to_name" || return 1
            ;;
        *)
            echo "Unsupported DOCKER_BUILDX_CACHE_BACKEND='$backend' (use local|gha)" >&2
            return 1
            ;;
    esac
    return 0
}

_docker_buildx_local_lock_dir() {
    local cache_base_dir="$1"
    local cache_key="$2"
    printf '%s/.locks/%s\n' "$cache_base_dir" "$cache_key"
}

_docker_release_local_buildx_lock() {
    local lock_dir="$1"
    [ -n "${lock_dir:-}" ] || return 0
    rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
}

# Prepend cmd to any existing handler for each sig (own cleanup always runs
# first, even when the prior handler calls exit before returning).
_docker_trap_add() {
    local cmd="$1" sig="" existing="" combined=""
    shift
    for sig in "$@"; do
        existing="$(trap -p "$sig" 2>/dev/null)"
        if [ -n "$existing" ]; then
            existing="$(printf '%s\n' "$existing" | sed -E "s/^trap -- '(.*)' (SIG)?${sig}\$/\\1/")"
            printf -v combined '%s; %s' "$cmd" "$existing"
        else
            combined="$cmd"
        fi
        trap -- "$combined" "$sig"
    done
}

_docker_lock_dir_age_secs() {
    local lock_dir="$1" mtime=""
    mtime="$(stat -c '%Y' "$lock_dir" 2>/dev/null || true)"
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$(( $(date +%s) - mtime ))"
        return 0
    fi
    printf '0\n'
}

_docker_reap_lock_missing_owner_pid() {
    local lock_dir="$1" age_secs=0
    age_secs="$(_docker_lock_dir_age_secs "$lock_dir")"
    # Grace must cover mkdir→owner.pid under parallel load (coverage×4 + compat
    # share tests-debian_trixie). Too-short grace lets waiters rmdir a live lock.
    if [ "$age_secs" -lt "${DOCKER_BUILDX_LOCK_GRACE_SECS:-30}" ]; then
        return 0
    fi
    rmdir "$lock_dir" 2>/dev/null || true
}

_docker_reap_lock_dead_owner() {
    local lock_dir="$1" owner_pid=""
    owner_pid="$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)"
    if [[ "$owner_pid" =~ ^[0-9]+$ ]] && kill -0 "$owner_pid" 2>/dev/null; then
        return 0
    fi
    rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
}

# Remove lock_dir when its recorded owner PID is gone, or when owner.pid is
# missing after a short grace (covers the mkdir→pid write window).
_docker_reap_stale_buildx_lock() {
    local lock_dir="$1"
    [ -d "$lock_dir" ] || return 0
    if [ ! -f "${lock_dir}/owner.pid" ]; then
        _docker_reap_lock_missing_owner_pid "$lock_dir"
        return 0
    fi
    _docker_reap_lock_dead_owner "$lock_dir"
}

_docker_buildx_build_with_cache() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4"
    local cache_base_dir="$5" cache_path="$6"
    shift 6
    local -a build_args=("$@")
    local cache_from_args=() cache_to_args=() build_status=0 backend
    backend="$(_docker_buildx_cache_backend)"
    _docker_buildx_resolve_cache_args "$cache_base_dir" "$cache_path" \
        cache_from_args cache_to_args || return 1
    "$docker_bin" buildx build \
        --load \
        -f "$dockerfile_path" \
        -t "$image_tag" \
        "${build_args[@]}" \
        "${cache_from_args[@]}" \
        "${cache_to_args[@]}" \
        "$repo_root" || build_status=$?
    # Local exports may leave partial cache; prune for size. GHA has no local tree.
    if [ "$backend" = "local" ]; then
        _docker_prune_buildx_local_cache "$cache_base_dir" "$cache_path"
    fi
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

_docker_wait_mkdir_lock() {
    local lock_dir="$1" deadline="$2"
    while ! mkdir "$lock_dir" 2>/dev/null; do
        _docker_reap_stale_buildx_lock "$lock_dir"
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Timed out waiting for buildx lock: $lock_dir" >&2
            return 1
        fi
        sleep 0.25
    done
}

_docker_record_lock_owner() {
    local lock_dir="$1"
    # Write owner.pid before registering EXIT cleanup so waiters never see an
    # empty lock dir and reap it under DOCKER_BUILDX_LOCK_GRACE_SECS.
    if ! printf '%s\n' "$$" >"${lock_dir}/owner.pid" 2>/dev/null; then
        echo "Failed to record buildx lock owner: $lock_dir" >&2
        rmdir "$lock_dir" 2>/dev/null || true
        return 1
    fi
    _docker_trap_add "_docker_release_local_buildx_lock '$lock_dir'" EXIT INT TERM
}

_docker_prepare_lock_root() {
    local lock_root="$1" probe=""
    if ! mkdir -p "$lock_root"; then
        echo "Failed to create buildx lock root: $lock_root" >&2
        return 1
    fi
    # 755, not 700: under `sudo --full`, this root-created dir sits inside the
    # repo tree that debian/rules clean's dh_clean sweep also walks as the
    # unprivileged $SUDO_USER (via runuser); 700 makes that traversal fail
    # with "Permission denied" and aborts the deb-package build. Only this
    # script creates entries here, so world-writable access isn't needed.
    chmod 755 "$lock_root" 2>/dev/null || true
    # Fail closed when a prior sudo run left .locks root-owned: mkdir lock
    # wait would otherwise spin until DOCKER_BUILDX_LOCK_TIMEOUT_SECS.
    probe="${lock_root}/.write-probe.$$"
    if ! mkdir "$probe" 2>/dev/null; then
        echo "Buildx lock root is not writable: $lock_root" \
            "(fix ownership, e.g. chown -R \"\$(id -u):\$(id -g)\" \"$lock_root\")" >&2
        return 1
    fi
    rmdir "$probe" 2>/dev/null || true
}

_docker_acquire_local_buildx_lock() {
    local cache_key="$1"
    local cache_base_dir="$2"
    local -n _lock_dir_ref="$3"
    local lock_root="" _acquired_lock_dir="" deadline=$((SECONDS + ${DOCKER_BUILDX_LOCK_TIMEOUT_SECS:-1200}))
    _lock_dir_ref=""
    [ "$(_docker_buildx_cache_backend)" = "local" ] || return 0
    lock_root="${cache_base_dir}/.locks"
    _docker_prepare_lock_root "$lock_root" || return 1
    _acquired_lock_dir="$(_docker_buildx_local_lock_dir "$cache_base_dir" "$cache_key")"
    _docker_wait_mkdir_lock "$_acquired_lock_dir" "$deadline" || return 1
    # owner.pid is written before EXIT trap registration (see _docker_record_lock_owner).
    _docker_record_lock_owner "$_acquired_lock_dir" || return 1
    _lock_dir_ref="$_acquired_lock_dir"
}

_docker_run_image_build() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4"
    local cache_base_dir="$5" cache_path="$6"
    shift 6
    if "$docker_bin" buildx version >/dev/null 2>&1; then
        _docker_buildx_build_with_cache "$docker_bin" "$dockerfile_path" "$image_tag" \
            "$repo_root" "$cache_base_dir" "$cache_path" "$@"
        return $?
    fi
    _docker_legacy_build "$docker_bin" "$dockerfile_path" "$image_tag" \
        "$repo_root" "$cache_base_dir" "$cache_path" "$@"
}

_docker_prepare_build_context() {
    # $2 is the caller's array name (e.g. build_args). Pass that name through to
    # _docker_ci_build_args — do not introduce a local nameref alias of the same
    # name or bash creates a circular nameref.
    local cache_base_dir="$1"
    local build_args_name="$2"
    _docker_require_bash_nameref || return 1
    _docker_require_nonempty_cache_base "$cache_base_dir" "Docker buildx cache path" || return 1
    _docker_ci_build_args "$build_args_name" || return 1
}

docker_build_with_buildx_or_build() {
    local docker_bin="$1" dockerfile_path="$2" image_tag="$3" repo_root="$4" cache_base_dir="$5" cache_key="$6"
    local cache_path="$cache_base_dir/$cache_key"
    local -a build_args
    local lock_dir="" build_status=0
    _docker_prepare_build_context "$cache_base_dir" build_args || return 1
    _docker_acquire_local_buildx_lock "$cache_key" "$cache_base_dir" lock_dir || return 1
    _docker_run_image_build "$docker_bin" "$dockerfile_path" "$image_tag" \
        "$repo_root" "$cache_base_dir" "$cache_path" "${build_args[@]}" \
        || build_status=$?
    _docker_release_local_buildx_lock "$lock_dir"
    return "$build_status"
}

_kill_pgid_if_running() {
    local pid="$1"
    if kill -0 "$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    fi
}

_kill_pgid_any_alive() {
    local pid=""
    for pid in "$@"; do
        kill -0 "$pid" 2>/dev/null && return 0
    done
    return 1
}

_kill_pgid_wait_exit() {
    local deadline=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$deadline" ]; do
        _kill_pgid_any_alive "$@" || return 0
        sleep 0.2
    done
}

_kill_pgid_force() {
    local pid=""
    for pid in "$@"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        fi
    done
}

_kill_pgid_reap() {
    local pid=""
    for pid in "$@"; do
        wait "$pid" 2>/dev/null || true
    done
}

_kill_pgid_list() {
    local pid=""
    for pid in "$@"; do
        _kill_pgid_if_running "$pid"
    done
    _kill_pgid_wait_exit "$@"
    _kill_pgid_force "$@"
    _kill_pgid_reap "$@"
}

_parallel_array_drop_index() {
    local -n _arr_ref="$1"
    unset "_arr_ref[$2]"
    _arr_ref=("${_arr_ref[@]}")
}

_parallel_report_done_job() {
    local done_pid="$1" code="$2"
    local -n _pids_ref="$3" _names_ref="$4" _logs_ref="$5"
    local on_fail_fn="${6:-}"
    local i=0
    for i in "${!_pids_ref[@]}"; do
        if [ "${_pids_ref[$i]}" != "$done_pid" ]; then
            continue
        fi
        if [ "$code" -eq 0 ]; then
            printf '  ✓ Passed: %s\n' "${_names_ref[$i]}"
        else
            printf '  ✗ Failed: %s  →  %s\n' "${_names_ref[$i]}" "${_logs_ref[$i]}" >&2
            if [ -n "$on_fail_fn" ]; then
                "$on_fail_fn" "${_names_ref[$i]}" "${_logs_ref[$i]}"
            fi
            return 1
        fi
        _parallel_array_drop_index _pids_ref "$i"
        _parallel_array_drop_index _names_ref "$i"
        _parallel_array_drop_index _logs_ref "$i"
        return 0
    done
    return 2
}