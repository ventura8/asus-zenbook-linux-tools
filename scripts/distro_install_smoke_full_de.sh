#!/usr/bin/env bash
# Sourced by distro_install_smoke_desktop.sh — FULL_DE CLI/schema presence checks.
# Prefer real tools when ASUS_CI_FULL_DE=1: probe absolute binaries/schemas before
# PATH stubs shadow them. Install wiring still uses stubs under the smoke bus
# (fake socket cannot back real dconf); stubs remain the fallback for empty-arg
# images. Fail closed when curated packages should be present but CLIs miss.

_smoke_tool_present() {
    command -v "$1" >/dev/null 2>&1
}

_smoke_full_de_abs_bin() {
    # Resolve before mock_bin is prepended to PATH (caller must probe early).
    local tool="$1" resolved=""
    resolved="$(type -P "$tool" 2>/dev/null || true)"
    [ -n "$resolved" ] && [ -x "$resolved" ] || return 1
    printf '%s' "$resolved"
}

_smoke_real_cli_works() {
    local tool="$1" abs="$2"
    case "$tool" in
        gsettings)
            "$abs" list-schemas >/dev/null 2>&1
            ;;
        kwriteconfig6|kwriteconfig5)
            "$abs" --help >/dev/null 2>&1
            ;;
        xfconf-query)
            "$abs" --version >/dev/null 2>&1
            ;;
        *)
            return 0
            ;;
    esac
}

_smoke_probe_real_cli() {
    local tool="$1" abs=""
    abs="$(_smoke_full_de_abs_bin "$tool")" || return 1
    _smoke_real_cli_works "$tool" "$abs" || return 1
    _smoke_log "  ✓ FULL_DE real CLI probed: $abs"
    return 0
}

_smoke_lxqt_conf_candidates() {
    printf '%s\n' \
        /etc/xdg/lxqt/globalkeyshortcuts.conf \
        /etc/xdg/lxqt/globalkeyshortcuts.conf/globalkeyshortcuts.conf \
        /usr/share/lxqt/globalkeyshortcuts.conf \
        /usr/share/lxqt/globalkeyshortcuts.conf/globalkeyshortcuts.conf
}

_smoke_lxqt_conf_is_present() {
    # Debian ships the defaults as a *directory* containing the .conf file.
    local conf="$1" nested=""
    [ -f "$conf" ] && return 0
    [ -d "$conf" ] || return 1
    for nested in "$conf"/globalkeyshortcuts.conf "$conf"/*.conf; do
        [ -f "$nested" ] && return 0
    done
    return 1
}

_smoke_probe_lxqt_conf() {
    # Curated lxqt-globalkeys ships system defaults used by install-lxqt.
    local conf=""
    while IFS= read -r conf; do
        if _smoke_lxqt_conf_is_present "$conf"; then
            _smoke_log "  ✓ FULL_DE lxqt conf present: $conf"
            return 0
        fi
    done < <(_smoke_lxqt_conf_candidates)
    _smoke_fail "ASUS_CI_FULL_DE=1 lxqt missing globalkeyshortcuts.conf (lxqt-globalkeys)"
}

_smoke_require_gnome_schema() {
    local abs="$1"
    "$abs" list-schemas 2>/dev/null | grep -Fq 'org.gnome.desktop.wm.keybindings' \
        || _smoke_fail "FULL_DE gnome schemas missing (org.gnome.desktop.wm.keybindings)"
}

_smoke_probe_cinnamon_schema() {
    local abs="$1"
    "$abs" list-schemas 2>/dev/null | grep -Fq 'org.cinnamon.desktop.keybindings' \
        || _smoke_log "  · cinnamon schemas not listed (package may ship data-only)"
}

_smoke_probe_mate_schema() {
    local abs="$1"
    "$abs" list-schemas 2>/dev/null | grep -Fq 'org.mate.desktop' \
        || _smoke_log "  · mate schemas not listed (package may ship data-only)"
}

_smoke_probe_gsettings_schema() {
    local family="$1" abs="$2"
    case "$family" in
        gnome) _smoke_require_gnome_schema "$abs" ;;
        cinnamon) _smoke_probe_cinnamon_schema "$abs" ;;
        mate) _smoke_probe_mate_schema "$abs" ;;
    esac
}

_smoke_probe_full_de_schemas() {
    local family="$1" abs=""
    if [ "$family" = "lxqt" ]; then
        _smoke_probe_lxqt_conf
        return 0
    fi
    abs="$(_smoke_full_de_abs_bin gsettings)" || return 0
    _smoke_probe_gsettings_schema "$family" "$abs"
    return 0
}

_smoke_full_de_tools_for_family() {
    local family="$1"
    case "$family" in
        gnome|cinnamon|mate) printf '%s\n' gsettings ;;
        kde) printf '%s\n' kwriteconfig6 kwriteconfig5 ;;
        xfce) printf '%s\n' xfconf-query ;;
        lxqt) printf '%s\n' lxqt-globalkeysd lxqt-config-globalkeyshortcuts ;;
    esac
}

_smoke_require_one_full_de_cli() {
    local family="$1" tool="$2"
    if _smoke_probe_real_cli "$tool"; then
        return 0
    fi
    if _smoke_tool_present "$tool"; then
        _smoke_log "  ✓ FULL_DE CLI present (probe soft): $tool"
        return 0
    fi
    return 1
}

_smoke_require_any_full_de_cli() {
    # KDE: EL9 ships kwriteconfig5 (kf5-kconfig); others prefer kwriteconfig6.
    local family="$1" tool="" saw_any=0
    while IFS= read -r tool; do
        saw_any=1
        if _smoke_require_one_full_de_cli "$family" "$tool"; then
            return 0
        fi
    done < <(_smoke_full_de_tools_for_family "$family")
    [ "$saw_any" -eq 1 ] || return 0
    _smoke_fail \
        "ASUS_CI_FULL_DE=1 ASUS_CI_DE_FAMILY=$family missing CLI: kwriteconfig6|kwriteconfig5"
}

_smoke_require_all_full_de_clis() {
    local family="$1" tool=""
    while IFS= read -r tool; do
        if ! _smoke_require_one_full_de_cli "$family" "$tool"; then
            _smoke_fail "ASUS_CI_FULL_DE=1 ASUS_CI_DE_FAMILY=$family missing CLI: $tool"
        fi
    done < <(_smoke_full_de_tools_for_family "$family")
}

_smoke_require_full_de_clis() {
    local family="$1" expected="${ASUS_CI_DE_FAMILY:-}"
    [ -n "$expected" ] || return 0
    [ "$expected" = "$family" ] || return 0
    case "$family" in
        kde) _smoke_require_any_full_de_cli "$family" ;;
        *) _smoke_require_all_full_de_clis "$family" ;;
    esac
    _smoke_probe_full_de_schemas "$family"
}
