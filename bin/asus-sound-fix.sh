#!/bin/bash
# ALC294 / Cirrus Smart Amp Sound Fix for ASUS ZenBook laptops
# Detects HDA card number dynamically and applies initialization verbs

DEV_SND="${DEV_SND_ROOT:-/dev/snd}"
PROC_ASOUND="${PROC_ASOUND_ROOT:-/proc/asound}"
# Default 75 attempts × 0.2s sleep ≈ 15s hwdev poll budget.
SOUND_HWDEV_POLL_ATTEMPTS="${SOUND_HWDEV_POLL_ATTEMPTS:-75}"
SOUND_HDA_NID="${SOUND_HDA_NID:-0x20}"

_sound_hwdev_poll_attempts() {
    if [[ "$SOUND_HWDEV_POLL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$SOUND_HWDEV_POLL_ATTEMPTS"
        return 0
    fi
    printf '75\n'
}

_sound_hda_nid_valid() {
    local nid="$SOUND_HDA_NID" value hex_digits
    if [[ "$nid" =~ ^0[xX]([0-9a-fA-F]+)$ ]]; then
        hex_digits="${BASH_REMATCH[1]}"
        # Reject oversized hex before $((nid)) (mirror camera USB-class guard).
        [ "${#hex_digits}" -le 2 ] || return 1
        value=$((nid))
    elif [[ "$nid" =~ ^[0-9]+$ ]]; then
        value=$((10#$nid))
    else
        return 1
    fi
    [ "$value" -ge 0 ] && [ "$value" -le 255 ]
}

_validate_sound_hda_nid() {
    if _sound_hda_nid_valid; then
        return 0
    fi
    echo "Error: Invalid SOUND_HDA_NID: ${SOUND_HDA_NID}" >&2
    echo "Expected a decimal integer or 0x-prefixed hex value (0-0xff)." >&2
    return 1
}

_get_codec_file() {
    local dev="$1"
    [ ! -e "$dev" ] && return 1
    local parsed card_num device_num
    parsed=$(echo "$dev" | sed -n 's/.*hwC\([0-9]\+\)D\([0-9]\+\).*/\1 \2/p')
    card_num=${parsed%% *}
    device_num=${parsed#* }
    [ -n "$card_num" ] && [ -n "$device_num" ] && echo "$PROC_ASOUND/card$card_num/codec#$device_num"
}

check_codec_match() {
    local dev="$1"
    local codec_file
    codec_file=$(_get_codec_file "$dev")
    [ -n "$codec_file" ] && [ -f "$codec_file" ] && grep -qiE 'ALC294|Cirrus' "$codec_file" 2>/dev/null
}

find_sound_hwdev() {
    local dev
    for dev in "$DEV_SND"/hwC*D*; do
        check_codec_match "$dev" && { echo "$dev"; return 0; }
    done
    return 1
}

poll_sound_hwdev() {
    local attempt max_attempts
    max_attempts=$(_sound_hwdev_poll_attempts)
    for ((attempt = 1; attempt <= max_attempts; attempt += 1)); do
        local hwdev
        hwdev=$(find_sound_hwdev) && { echo "$hwdev"; return 0; }
        [ "$attempt" -lt "$max_attempts" ] && sleep 0.2
    done
    return 1
}

SOUND_STATE_DIR="${ASUS_SOUND_STATE_DIR:-/var/lib/asus-zenbook-linux-tools}"

_sound_verb_err_dir() {
    local dir="$SOUND_STATE_DIR"
    if mkdir -p "$dir" 2>/dev/null && [ -w "$dir" ]; then
        printf '%s\n' "$dir"
        return 0
    fi
    printf '%s\n' "${TMPDIR:-/tmp}"
}

_sound_bin_root() {
    # As root, ignore attacker-controlled BIN_ROOT; only approved install paths.
    if [ "${EUID:-$(id -u)}" -eq 0 ]; then
        printf '%s\n' "/usr/local/bin"
        return 0
    fi
    printf '%s\n' "${BIN_ROOT:-/usr/local/bin}"
}

_run_system_hda_verb() {
    local hwdev="$1" verb_code="$2" verb_param="$3" nid="$4" err_sys="$5"
    if [ -n "$err_sys" ]; then
        hda-verb "$hwdev" "$nid" "$verb_code" "$verb_param" >/dev/null 2>"$err_sys"
    else
        hda-verb "$hwdev" "$nid" "$verb_code" "$verb_param" >/dev/null
    fi
}

_resolve_explicit_python_hda_helper() {
    local verb_bin="$1"
    [ "$verb_bin" != "hda-verb" ] || return 1
    [ -f "$verb_bin" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    printf '%s\n' "$verb_bin"
}

_locate_bundled_python_hda_helper() {
    local here candidate bin_root
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bin_root=$(_sound_bin_root)
    for candidate in "$here/asus_hda_verb.py" "$bin_root/asus_hda_verb.py"; do
        [ -f "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    return 1
}

_find_bundled_python_hda_helper() {
    command -v python3 >/dev/null 2>&1 || return 1
    _locate_bundled_python_hda_helper
}

_resolve_python_hda_helper() {
    local verb_bin="$1"
    if _resolve_explicit_python_hda_helper "$verb_bin"; then
        return 0
    fi
    [ "$verb_bin" = "hda-verb" ] || return 1
    _find_bundled_python_hda_helper
}

_run_python_hda_verb() {
    local py_helper="$1" hwdev="$2" verb_code="$3" verb_param="$4" nid="$5" err_py="$6"
    if [ -n "$err_py" ]; then
        python3 "$py_helper" "$hwdev" "$nid" "$verb_code" "$verb_param" >/dev/null 2>"$err_py"
    else
        python3 "$py_helper" "$hwdev" "$nid" "$verb_code" "$verb_param" >/dev/null
    fi
}

_emit_hda_verb_stderr() {
    local err_sys="$1" err_py="$2"
    [ -n "$err_sys" ] && [ -s "$err_sys" ] && cat "$err_sys" >&2
    [ -n "$err_py" ] && [ -s "$err_py" ] && cat "$err_py" >&2
    return 0
}

_cleanup_hda_verb_temps() {
    local err_sys="$1" err_py="$2"
    [ -n "$err_sys" ] && rm -f "$err_sys"
    [ -n "$err_py" ] && rm -f "$err_py"
    return 0
}

_try_system_hda_verb() {
    local hwdev="$1" verb_code="$2" verb_param="$3" nid="$4"
    local -n _sys_err="$5"
    local err_dir="$6" rc
    command -v hda-verb >/dev/null 2>&1 || return 1
    _sys_err=$(mktemp "${err_dir}/asus-sound-verb-sys.XXXXXX" 2>/dev/null) || _sys_err=""
    _run_system_hda_verb "$hwdev" "$verb_code" "$verb_param" "$nid" "$_sys_err"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _cleanup_hda_verb_temps "$_sys_err" ""
        _sys_err=""
        return 0
    fi
    return "$rc"
}

_try_python_hda_verb() {
    local verb_bin="$1" hwdev="$2" verb_code="$3" verb_param="$4" nid="$5"
    local -n _py_err="$6"
    local err_dir="$7" py_helper
    py_helper=$(_resolve_python_hda_helper "$verb_bin") || return 1
    _py_err=$(mktemp "${err_dir}/asus-sound-verb-py.XXXXXX" 2>/dev/null) || _py_err=""
    _run_python_hda_verb "$py_helper" "$hwdev" "$verb_code" "$verb_param" "$nid" "$_py_err"
}

_run_one_hda_verb() {
    local verb_bin="$1" hwdev="$2" verb_code="$3" verb_param="$4" nid="${5:-$SOUND_HDA_NID}"
    local err_dir err_sys="" err_py="" rc=1
    err_dir=$(_sound_verb_err_dir)
    if _try_system_hda_verb "$hwdev" "$verb_code" "$verb_param" "$nid" err_sys "$err_dir"; then
        return 0
    fi
    _try_python_hda_verb "$verb_bin" "$hwdev" "$verb_code" "$verb_param" "$nid" err_py "$err_dir"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        _cleanup_hda_verb_temps "$err_sys" "$err_py"
        return 0
    fi
    _emit_hda_verb_stderr "$err_sys" "$err_py"
    _cleanup_hda_verb_temps "$err_sys" "$err_py"
    return "$rc"
}

_format_hda_verb_cmd() {
    local verb_bin="$1" hwdev="$2" verb_code="$3" verb_param="$4" nid="${5:-$SOUND_HDA_NID}"
    if [ "$verb_bin" = "hda-verb" ]; then
        printf 'hda-verb "%s" %s %s %s' "$hwdev" "$nid" "$verb_code" "$verb_param"
        return 0
    fi
    printf 'python3 "%s" "%s" %s %s %s' "$verb_bin" "$hwdev" "$nid" "$verb_code" "$verb_param"
}

_run_hda_verbs() {
    local hwdev="$1" verb_bin="$2"
    local verb_cmd verb_pair verb_code verb_param
    for verb_pair in 0x500:0x1b 0x477:0x4a4b 0x500:0xf 0x477:0x74; do
        verb_code="${verb_pair%%:*}"
        verb_param="${verb_pair#*:}"
        _run_one_hda_verb "$verb_bin" "$hwdev" "$verb_code" "$verb_param" "$SOUND_HDA_NID" || {
            verb_cmd=$(_format_hda_verb_cmd "$verb_bin" "$hwdev" "$verb_code" "$verb_param" "$SOUND_HDA_NID")
            echo "Error: Failed command: $verb_cmd. Earlier verbs may already have been applied." >&2
            return 1
        }
    done
}

_resolve_hda_verb_bin() {
    if command -v hda-verb >/dev/null 2>&1; then
        printf '%s\n' hda-verb
        return 0
    fi
    _find_bundled_python_hda_helper
}

apply_hda_verbs() {
    local hwdev="$1" verb_bin
    verb_bin=$(_resolve_hda_verb_bin) || {
        echo "Error: hda-verb is not installed and asus_hda_verb.py fallback is missing." >&2
        echo "Install alsa-tools / hda-verb, or reinstall the SOUND component." >&2
        return 1
    }

    _run_hda_verbs "$hwdev" "$verb_bin" || { echo "Error: Failed to apply sound verbs." >&2; return 1; }
    return 0
}

main() {
    _validate_sound_hda_nid || return 1
    echo "Initializing ASUS ZenBook Sound Fix..."
    local hwdev
    hwdev=$(poll_sound_hwdev) || { echo "Error: Could not find sound card containing ALC294/Cirrus codec." >&2; return 1; }

    apply_hda_verbs "$hwdev" || return 1
    echo "ASUS ZenBook sound verbs applied successfully to $hwdev."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
    exit $?
fi