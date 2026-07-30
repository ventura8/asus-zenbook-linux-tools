#!/usr/bin/env bash
# kcov driver: exercise sourced control-center helper dispatch.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

# shellcheck source=bin/asus-control-center.sh
_driver_source_required "$REPO_ROOT/bin/asus-control-center.sh" control_center_helpers quiet

_run_control_center_dispatch_helpers() {
    local tmp family
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN
    touch "$tmp/org.gnome.Settings.desktop" "$tmp/systemsettings.desktop" \
        "$tmp/xfce4-settings-manager.desktop" "$tmp/lxqt-config.desktop" \
        "$tmp/cinnamon-settings.desktop" "$tmp/mate-control-center.desktop"
    for family in kde xfce lxqt cinnamon mate gnome other; do
        _exercise _settings_cmds_for_family "$family" >/dev/null
        _exercise DESKTOP_DIR="$tmp" _desktop_file_for_family "$family" >/dev/null
    done
    _soft_expect 2 main unexpected >/dev/null
}

_run_control_center_dispatch_helpers
