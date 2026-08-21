#!/usr/bin/env bash
# Canonical release package kinds (tag workflow build-packages matrix).
RELEASE_PACKAGE_KINDS=(
    rpm-fedora-44
    rpm-rocky-10
    rpm-opensuse-tw
    arch
    appimage
    flatpak
    snap
)

_require_exact_one_glob() {
    local label="$1"
    shift
    local matches=("$@")
    if [ "${#matches[@]}" -ne 1 ]; then
        printf 'Expected exactly one %s file, found %s\n' "$label" "${#matches[@]}" >&2
        printf '%s\n' "${matches[@]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}

_release_repo_relative_path() {
    local repo_root="$1"
    local target_path="$2"
    local canonical_repo=""
    if ! canonical_repo="$(cd "$repo_root" && pwd)"; then
        printf 'Failed to resolve repository root: %s\n' "$repo_root" >&2
        return 1
    fi
    if [[ "$target_path" == "$canonical_repo"/* ]]; then
        printf '%s\n' "${target_path#"$canonical_repo"/}"
        return 0
    fi
    if [[ "$target_path" == /* ]]; then
        printf '%s\n' "$target_path"
        return 0
    fi
    printf '%s\n' "${target_path#./}"
}

_release_docker_rm() {
    local repo_root="$1"
    shift
    local paths=("$@") rel_paths=() path rel=""
    if [ "${#paths[@]}" -eq 0 ]; then
        return 0
    fi
    for path in "${paths[@]}"; do
        rel="$(_release_repo_relative_path "$repo_root" "$path")"
        rel_paths+=("$rel")
    done
    docker run --rm \
        -v "${repo_root}:/workspace:Z" \
        -w /workspace \
        alpine:3.20 \
        sh -c 'rm -rf -- "$@"' _ "${rel_paths[@]}"
}

_release_wipe_dir_contents() {
    local repo_root="$1"
    local target_dir="$2"
    local rel=""
    local host_uid="" host_gid=""
    rel="$(_release_repo_relative_path "$repo_root" "$target_dir")"
    if [ -z "$rel" ] || [ "$rel" = "." ] || [[ "$rel" == /* ]]; then
        printf 'Wipe target must resolve inside the repository (got: %s)\n' \
            "${rel:-<empty>}" >&2
        return 1
    fi
    host_uid="$(id -u)"
    host_gid="$(id -g)"
    docker run --rm \
        -v "${repo_root}:/workspace:Z" \
        -w /workspace \
        alpine:3.20 \
        sh -c 'rel="$1"; uid="$2"; gid="$3"; rm -rf "/workspace/${rel}" && mkdir -p "/workspace/${rel}" && chown "${uid}:${gid}" "/workspace/${rel}"' \
        _ "$rel" "$host_uid" "$host_gid"
}

_release_docker_rm_rpm_build_trees() {
    local repo_root="$1"
    docker run --rm \
        -v "${repo_root}:/workspace:Z" \
        -w /workspace \
        alpine:3.20 \
        sh -c 'rm -rf /workspace/.rpm-build /workspace/.rpm-build-*'
}

_release_docker_rm_arch_staging() {
    local repo_root="$1"
    _release_docker_rm "$repo_root" \
        "${repo_root}/packaging/arch/pkg" \
        "${repo_root}/packaging/arch/src"
}

_release_docker_rm_portable_staging() {
    local repo_root="$1"
    _release_docker_rm "$repo_root" \
        "${repo_root}/packaging/appimage/AppDir" \
        "${repo_root}/packaging/flatpak/builddir" \
        "${repo_root}/packaging/flatpak/repo" \
        "${repo_root}/.flatpak-builder" \
        "${repo_root}/packaging/snap/parts" \
        "${repo_root}/packaging/snap/stage" \
        "${repo_root}/packaging/snap/prime"
}

_release_pkg_kind_is_valid() {
    local kind="$1" entry=""
    for entry in "${RELEASE_PACKAGE_KINDS[@]}"; do
        if [ "$entry" = "$kind" ]; then
            return 0
        fi
    done
    return 1
}

_release_pkg_rpm_artifact_glob() {
    local kind="$1"
    if [ "$kind" = "rpm-rocky-10" ]; then
        printf '%s\n' 'asus-zenbook-linux-tools-*.el10.noarch.rpm'
        return 0
    fi
    if [ "$kind" = "rpm-fedora-44" ]; then
        printf '%s\n' 'asus-zenbook-linux-tools-*fc44*.rpm'
        return 0
    fi
    if [ "$kind" = "rpm-opensuse-tw" ]; then
        printf '%s\n' 'asus-zenbook-linux-tools-*-1.noarch.rpm'
        return 0
    fi
    return 1
}

_release_pkg_portable_artifact_glob() {
    local kind="$1"
    case "$kind" in
        appimage)
            printf '%s\n' 'asus-zenbook-linux-tools-*-x86_64.AppImage'
            ;;
        flatpak)
            printf '%s\n' 'asus-zenbook-linux-tools-*.flatpak'
            ;;
        snap)
            printf '%s\n' 'asus-zenbook-linux-tools_*.snap'
            ;;
        *)
            return 1
            ;;
    esac
}

_release_pkg_artifact_glob() {
    local kind="$1"
    if [[ "$kind" == rpm-* ]]; then
        _release_pkg_rpm_artifact_glob "$kind"
        return $?
    fi
    if [ "$kind" = "arch" ]; then
        printf '%s\n' 'asus-zenbook-linux-tools-*.pkg.tar.*'
        return 0
    fi
    _release_pkg_portable_artifact_glob "$kind"
}

_release_pkg_validate_artifact() {
    local kind="$1"
    local artifacts_dir="$2"
    local glob="" file="" matches=()
    glob="$(_release_pkg_artifact_glob "$kind")" || return 1
    while IFS= read -r -d '' file; do
        matches+=("$file")
    done < <(find "$artifacts_dir" -maxdepth 1 -type f -name "$glob" -print0 2>/dev/null || true)
    if [ "${#matches[@]}" -ne 1 ]; then
        printf 'Expected exactly one %s artifact in %s, found %s\n' \
            "$kind" "$artifacts_dir" "${#matches[@]}" >&2
        printf '%s\n' "${matches[@]}" >&2
        return 1
    fi
    printf '%s\n' "${matches[0]}"
}
