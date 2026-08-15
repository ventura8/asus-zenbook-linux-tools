#!/usr/bin/env bash
# kcov driver: exercise fan-toggle warning and validation branches.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/platform"
printf '0\n' > "$tmp/platform/throttle_thermal_policy"
chmod 666 "$tmp/platform/throttle_thermal_policy"
export SYS_PLATFORM_ROOT="$tmp/platform"
export ASUS_FAN_NODE="$tmp/platform/throttle_thermal_policy"
export ASUS_FAN_USE_PPD=0
export NOTIF_ID_ROOT="$tmp/notif"
mkdir -p "$NOTIF_ID_ROOT/$(id -u)"

# shellcheck source=bin/asus-fan-toggle.sh
_driver_source_required "$REPO_ROOT/bin/asus-fan-toggle.sh" fan_helpers quiet

_soft_expect 0 _normalize_fan_value 99 >/dev/null
_soft_expect 0 _normalize_fan_value abc >/dev/null
_soft_expect 0 _get_next_fan_profile_name 9 >/dev/null
_soft_expect 0 _validate_asus_fan_use_ppd
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 ASUS_FAN_USE_PPD=9 _validate_asus_fan_use_ppd
_ASUS_FAN_PPD_VALIDATED=1
_ASUS_FAN_USE_PPD_MODE=
_soft_expect 1 _ppd_mode_enabled
_ASUS_FAN_USE_PPD_MODE=1
_soft_expect 0 _ppd_mode_enabled
_soft_expect 0 _exercise ASUS_FAN_USE_PPD=0 _ppd_enabled >/dev/null
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 ASUS_FAN_USE_PPD=1 ASUS_FAN_NODE="$tmp/platform/throttle_thermal_policy" \
    _ppd_enabled >/dev/null
_soft_expect 0 _read_current_fan_value "$tmp/platform/throttle_thermal_policy" >/dev/null
chmod 000 "$tmp/platform/throttle_thermal_policy" 2>/dev/null
_soft_expect 0 _read_current_fan_value "$tmp/platform/throttle_thermal_policy" >/dev/null
chmod 666 "$tmp/platform/throttle_thermal_policy" 2>/dev/null
_soft_expect 0 _read_current_fan_value "" >/dev/null
printf 'x\n' > "$tmp/bad"
_soft_expect 0 _read_current_fan_value "$tmp/bad" >/dev/null
_soft_expect 0 _value_from_ppd_name balanced >/dev/null
_soft_expect 0 _value_from_ppd_name performance >/dev/null
_soft_expect 0 _value_from_ppd_name power-saver >/dev/null
_soft_expect 0 _value_from_ppd_name weird-profile >/dev/null
_soft_expect 0 _get_next_fan_profile_name 0 >/dev/null
_soft_expect 0 _get_next_fan_profile_name 1 >/dev/null
_soft_expect 0 _get_next_fan_profile_name 2 >/dev/null
_soft_expect 0 _get_fan_icon 0 >/dev/null
_soft_expect 0 _get_fan_icon 1 >/dev/null
_soft_expect 0 _get_fan_icon 2 >/dev/null
_soft_expect 1 _fan_sysfs_path_allowed /etc/passwd >/dev/null
_soft_expect 0 find_fan_node >/dev/null
# PPD path: mock powerprofilesctl + force ASUS_FAN_USE_PPD=1 with node present.
printf '#!/bin/sh\ncase "$1" in get) echo balanced ;; set) exit 0 ;; *) exit 0 ;; esac\n' \
    > "$tmp/powerprofilesctl"
chmod +x "$tmp/powerprofilesctl"
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 ASUS_FAN_NODE="$tmp/platform/throttle_thermal_policy" \
    _ppd_enabled >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 _read_ppd_profile >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 \
    _read_current_fan_value "$tmp/platform/throttle_thermal_policy" >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 \
    _apply_fan_profile 1 "$tmp/platform/throttle_thermal_policy" >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 \
    _prepare_ppd_fan_node "$tmp/platform/throttle_thermal_policy" >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 \
    _prepare_ppd_fan_node "" >/dev/null
# Sysfs apply failure paths.
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 _apply_fan_profile_sysfs 1 "" >/dev/null
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
    _require_sysfs_fan_node "" >/dev/null
chmod a-w "$tmp/platform/throttle_thermal_policy" 2>/dev/null
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
    _require_sysfs_fan_node "$tmp/platform/throttle_thermal_policy" >/dev/null
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
    _apply_fan_profile_sysfs 1 "$tmp/platform/throttle_thermal_policy" >/dev/null
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=1 \
    _prepare_ppd_fan_node "$tmp/platform/throttle_thermal_policy" >/dev/null
rm -f "$tmp/platform/throttle_thermal_policy"
mkdir -p "$tmp/platform/throttle_thermal_policy"
_soft_expect 1 _exercise KCOV_EXERCISE_RETURN_STATUS=1 \
    _apply_fan_profile_sysfs 1 "$tmp/platform/throttle_thermal_policy" >/dev/null
# Empty-node PPD read fallback (no sysfs).
_soft_expect 0 _exercise PATH="$tmp:$PATH" ASUS_FAN_USE_PPD=0 ASUS_FAN_NODE="" \
    _read_current_fan_value "" >/dev/null
