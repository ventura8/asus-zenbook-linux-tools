#!/usr/bin/env bash
# Install libcurl-devel that matches the libcurl NEVRA in this EL10 image.
# Appstream can advertise a newer devel than baseos libcurl (nothing provides …).
set -euo pipefail

_rpm_vr() {
    rpm -q --qf '%{VERSION}-%{RELEASE}' "$1"
}

_libcurl_vr() {
    if rpm -q libcurl >/dev/null 2>&1; then
        _rpm_vr libcurl
        return 0
    fi
    if rpm -q libcurl-minimal >/dev/null 2>&1; then
        _rpm_vr libcurl-minimal
        return 0
    fi
    echo "el10-kcov-libcurl: libcurl is not installed" >&2
    return 1
}

_install_exact_devel() {
    local vr="$1"
    echo "el10-kcov-libcurl: installing libcurl-devel-${vr}" >&2
    dnf -y install --allowerasing "libcurl-devel-${vr}"
}

_install_nobest_devel() {
    echo "el10-kcov-libcurl: exact devel missing; installing --nobest" >&2
    dnf -y install --allowerasing --nobest libcurl-devel
}

dnf -y install --allowerasing --nobest libcurl curl
vr="$(_libcurl_vr)"
if _install_exact_devel "$vr"; then
    exit 0
fi
_install_nobest_devel
