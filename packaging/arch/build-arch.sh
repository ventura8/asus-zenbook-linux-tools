#!/usr/bin/env bash
# Build Arch package from git checkout; sync pkgver from VERSION.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARCH_DIR="${REPO_ROOT}/packaging/arch"
ARCH_CACHE_DIR="${REPO_ROOT}/.cache/asus-arch-package-build"

_arch_build_lock_file() {
    printf '%s\n' "${ARCH_CACHE_DIR}.lock"
}

_ensure_makepkg_user() {
    local user="${ASUS_MAKEPKG_USER:-asusmakepkg}" uid="${ASUS_MAKEPKG_UID:-1000}"
    if id -u "$user" >/dev/null 2>&1; then
        printf '%s\n' "$user"
        return 0
    fi
    if ! getent passwd "$uid" >/dev/null 2>&1; then
        useradd -m -u "$uid" "$user"
    else
        useradd -m "$user"
    fi
    printf '%s\n' "$user"
}

_chown_arch_build_paths() {
    local user="$1"
    mkdir -p "$ARCH_CACHE_DIR"
    chown -R "${user}:${user}" "$ARCH_DIR" "$ARCH_CACHE_DIR"
}

_run_makepkg_flocked() {
    local lock_file=""
    lock_file="$(_arch_build_lock_file)"
    mkdir -p "$ARCH_CACHE_DIR"
    cd "$ARCH_DIR"
    if command -v flock >/dev/null 2>&1; then
        flock "$lock_file" makepkg -sf --noconfirm --nocheck
        return $?
    fi
    makepkg -sf --noconfirm --nocheck
}

_run_makepkg_locked() {
    local user="" lock_file="" inner="" q_arch="" q_lock=""
    if [ "$(id -u)" -ne 0 ]; then
        _run_makepkg_flocked
        return $?
    fi
    user="$(_ensure_makepkg_user)"
    _chown_arch_build_paths "$user"
    lock_file="$(_arch_build_lock_file)"
    q_arch="$(printf '%q' "$ARCH_DIR")"
    q_lock="$(printf '%q' "$lock_file")"
    inner="cd ${q_arch} && makepkg -sf --noconfirm --nocheck"
    if command -v flock >/dev/null 2>&1; then
        inner="cd ${q_arch} && flock ${q_lock} makepkg -sf --noconfirm --nocheck"
    fi
    su -s /bin/bash "$user" -c "$inner"
}

_run_makepkg_locked

matches=()
while IFS= read -r -d '' pkg; do
    matches+=("$pkg")
done < <(find "${ARCH_DIR}" -maxdepth 1 -name 'asus-zenbook-linux-tools-*.pkg.tar.*' -print0 2>/dev/null || true)
if [ "${#matches[@]}" -eq 0 ]; then
    echo "Arch makepkg produced no asus-zenbook-linux-tools package" >&2
    exit 1
fi
printf '%s\n' "${matches[@]}"
