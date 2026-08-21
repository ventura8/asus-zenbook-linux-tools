#!/usr/bin/env bash
# Build an RPM from the git checkout (no separate tarball).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SPEC="${REPO_ROOT}/packaging/rpm/asus-zenbook-linux-tools.spec"
VERSION_FILE="${REPO_ROOT}/VERSION"

if [ ! -f "$VERSION_FILE" ]; then
    echo "Missing VERSION file: $VERSION_FILE" >&2
    exit 1
fi

if [ ! -f "$SPEC" ]; then
    echo "Missing RPM spec file: $SPEC" >&2
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
RPM_TOP="${RPM_TOP:-${REPO_ROOT}/.rpm-build}"
case "$RPM_TOP" in
    /*) ;;
    *) RPM_TOP="${REPO_ROOT}/${RPM_TOP#./}" ;;
esac
mkdir -p "${RPM_TOP}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

cp "$SPEC" "${RPM_TOP}/SPECS/"

rpmbuild -ba "${RPM_TOP}/SPECS/asus-zenbook-linux-tools.spec" \
    --define "_topdir ${RPM_TOP}" \
    --define "_gitroot ${REPO_ROOT}" \
    --define "version ${VERSION}"

mapfile -t _rpm_matches < <(find "${RPM_TOP}/RPMS" -name 'asus-zenbook-linux-tools-*.rpm' -print)
if [ "${#_rpm_matches[@]}" -eq 0 ]; then
    echo "RPM build produced no package under ${RPM_TOP}/RPMS" >&2
    exit 1
fi
printf '%s\n' "${_rpm_matches[@]}" >&2
