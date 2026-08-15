#!/usr/bin/env bash
# Create asusci account matching host UID/GID with passwordless sudo for that UID.
set -euo pipefail

: "${ASUS_CI_UID:?ASUS_CI_UID is required}"
: "${ASUS_CI_GID:?ASUS_CI_GID is required}"
ASUS_CI_USER="${ASUS_CI_USER:-asusci}"

_validate_positive_host_id() {
    local label="$1" value="$2" kind="$3"
    if [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
        return 0
    fi
    echo "create-asusci-user: refuse ${label}=${value} (need positive host ${kind})" >&2
    return 1
}

_resolve_asusci_primary_gid() {
    # Reuse an existing group by name; only create when both name and GID are free.
    # When reusing by name, useradd/usermod must use that group's real GID.
    PRIMARY_GID="${ASUS_CI_GID}"
    if getent group "${ASUS_CI_USER}" >/dev/null; then
        PRIMARY_GID=$(getent group "${ASUS_CI_USER}" | cut -d: -f3)
        return 0
    fi
    if getent group "${ASUS_CI_GID}" >/dev/null; then
        return 0
    fi
    groupadd -g "${ASUS_CI_GID}" "${ASUS_CI_USER}"
}

_rename_uid_holder_to_asusci() {
    local existing_name="$1"
    # Host UID already belongs to another account (common in reused images).
    # Rename it so ASUS_CI_USER can own the requested UID and home.
    usermod -l "${ASUS_CI_USER}" -g "${PRIMARY_GID}" "${existing_name}"
    usermod -d "/home/${ASUS_CI_USER}" -m "${ASUS_CI_USER}" 2>/dev/null \
        || usermod -d "/home/${ASUS_CI_USER}" "${ASUS_CI_USER}"
    # -m may fail when the home already exists elsewhere; ensure the path exists
    # and is owned by the renamed CI user after a bare -d fallback.
    mkdir -p "/home/${ASUS_CI_USER}"
    chown "${ASUS_CI_USER}:${PRIMARY_GID}" "/home/${ASUS_CI_USER}"
}

_ensure_asusci_user() {
    local existing_name
    existing_name=$(getent passwd "${ASUS_CI_UID}" | cut -d: -f1 || true)
    if [ -n "${existing_name}" ] && [ "${existing_name}" != "${ASUS_CI_USER}" ]; then
        _rename_uid_holder_to_asusci "${existing_name}"
        return $?
    fi
    _create_or_align_asusci_user
}

_create_or_align_asusci_user() {
    if ! getent passwd "${ASUS_CI_USER}" >/dev/null; then
        useradd -m -u "${ASUS_CI_UID}" -g "${PRIMARY_GID}" -o -s /bin/bash \
            "${ASUS_CI_USER}"
        return $?
    fi
    if [ "$(id -u "${ASUS_CI_USER}")" != "${ASUS_CI_UID}" ]; then
        usermod -u "${ASUS_CI_UID}" -g "${PRIMARY_GID}" -o "${ASUS_CI_USER}"
    fi
}

_install_asusci_sudoers() {
    # Passwordless sudo for the CI UID only (#UID form; hadolint rejects newlines in RUN).
    printf '#%s ALL=(ALL) NOPASSWD:ALL\n' "${ASUS_CI_UID}" > /etc/sudoers.d/asus-ci
    chmod 440 /etc/sudoers.d/asus-ci
    if command -v visudo >/dev/null 2>&1; then
        visudo -c -f /etc/sudoers.d/asus-ci
    fi
}

_validate_positive_host_id ASUS_CI_UID "${ASUS_CI_UID}" UID || exit 1
_validate_positive_host_id ASUS_CI_GID "${ASUS_CI_GID}" GID || exit 1
_resolve_asusci_primary_gid
_ensure_asusci_user
_install_asusci_sudoers
