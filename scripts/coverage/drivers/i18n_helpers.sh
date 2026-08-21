#!/usr/bin/env bash
# kcov driver: exercise lib/asus-i18n.sh locale and gettext fallbacks.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
cd "$REPO_ROOT" || exit 1

# shellcheck source=scripts/coverage/drivers/kcov_driver_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov_driver_common.sh"

_i18n_expect_env() {
    local expected="$1"
    shift
    _soft_expect "$expected" _exercise KCOV_EXERCISE_RETURN_STATUS=1 "$@"
}

_i18n_restore_force_msgid() {
    ASUS_I18N_FORCE_MSGID="$1"
    export ASUS_I18N_FORCE_MSGID
}

_write_i18n_command_stubs() {
    local mock="$1" user uid
    user="$(id -un)"
    uid="$(id -u)"
    cat > "$mock/gettext" <<'EOF'
#!/bin/sh
[ "${GETTEXT_FAIL:-0}" = 1 ] && exit 1
[ "${GETTEXT_EMPTY:-0}" = 1 ] && exit 0
[ "${GETTEXT_IDENTITY:-0}" = 1 ] && { printf '%s' "$1"; exit 0; }
printf 'translated:%s' "$1"
EOF
    cat > "$mock/ngettext" <<'EOF'
#!/bin/sh
[ "${NGETTEXT_FAIL:-0}" = 1 ] && exit 1
[ "${NGETTEXT_EMPTY:-0}" = 1 ] && exit 0
if [ "$3" -eq 1 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
EOF
    cat > "$mock/loginctl" <<EOF
#!/bin/sh
if [ "\$1" = list-sessions ]; then
    printf '1 %s %s seat0\\n' "$uid" "$user"
    exit 0
fi
case "\$4" in
    Type) echo x11 ;;
    State) echo active ;;
    Name) echo "$user" ;;
    Leader) echo "\${I18N_LEADER_PID:-0}" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$mock/gettext" "$mock/ngettext" "$mock/loginctl"
}

_run_i18n_locale_paths() {
    local mock="$1" iso="$2" proc_root="$3"
    local prefix_root="${TEXTDOMAINDIR%/locale}/prefix"
    _soft_expect 0 _asus_i18n_repo_root >/dev/null
    _i18n_expect_env 0 TEXTDOMAINDIR="$TEXTDOMAINDIR" _asus_resolve_textdomain_dir >/dev/null
    _i18n_expect_env 0 TEXTDOMAINDIR= PREFIX="$prefix_root" \
        _asus_resolve_textdomain_dir >/dev/null
    _soft_expect 0 _asus_normalize_ui_language "RO_ro.UTF-8@latin" >/dev/null
    _soft_expect 0 _asus_normalize_ui_language "jv_ID" >/dev/null
    _soft_expect 1 _asus_normalize_ui_language "invalid-language"
    _i18n_expect_env 1 ASUS_TEST_MODE=0 ASUS_UI_LANG=ro _asus_test_ui_language
    _i18n_expect_env 0 ASUS_TEST_MODE=1 ASUS_UI_LANG=ro _asus_test_ui_language >/dev/null
    _soft_expect 1 _asus_first_session_ui_language "$(id -un)"
    _i18n_expect_env 0 PATH="$mock:$iso" ASUS_PROC_ENVIRON_ROOT="$proc_root" \
        I18N_LEADER_PID="$$" _asus_first_session_ui_language "$(id -un)" >/dev/null
    _i18n_expect_env 0 ASUS_TEST_MODE=1 ASUS_UI_LANG=ro _asus_resolve_ui_locale >/dev/null
    resolved="$(ASUS_TEST_MODE=0 LC_MESSAGES=de_DE.UTF-8 _asus_resolve_ui_locale)"
    _soft_expect 0 test "$resolved" = "de_DE.UTF-8"
    resolved="$(ASUS_TEST_MODE=0 LC_MESSAGES='' LANG=de_DE.UTF-8 LANGUAGE='' _asus_resolve_ui_locale)"
    _soft_expect 0 test "$resolved" = "de_DE.UTF-8"
    _i18n_expect_env 0 ASUS_TEST_MODE=1 ASUS_UI_LANG=bad_locale _asus_gettext_env >/dev/null
    _i18n_expect_env 0 ASUS_TEST_MODE=1 ASUS_UI_LANG=ro_RO.UTF-8 _asus_gettext_env >/dev/null
    _run_i18n_utf8_locale_paths
}

_run_i18n_utf8_locale_paths() {
    # _asus_locale_charset_part_valid: empty charset/modifier suffix rejected,
    # non-empty modifier suffix accepted.
    _soft_expect 1 _asus_locale_charset_part_valid "de_DE."
    _soft_expect 1 _asus_locale_charset_part_valid "de_DE@"
    _soft_expect 0 _asus_locale_charset_part_valid "en_US@euro"
    # Same-shell hits for _asus_locale_is_utf8_for_language (split for CCN).
    _soft_expect 0 _asus_locale_is_utf8_for_language "de_DE.UTF-8" de
    _soft_expect 0 _asus_locale_is_utf8_for_language "ro_RO.utf8" ro
    _soft_expect 1 _asus_locale_is_utf8_for_language "de_DE.ISO-8859-1" de
    _soft_expect 1 _asus_locale_is_utf8_for_language "fr_FR.UTF-8" de
    # _asus_env_utf8_locale_for_language: non-UTF-8 env candidate is rejected
    # (falls through to locale -a / C.UTF-8), UTF-8 candidate is returned.
    resolved="$(LC_ALL=ro_RO.ISO-8859-2 _asus_utf8_locale_for_language ro)"
    _soft_expect 0 test "$resolved" != "ro_RO.ISO-8859-2"
    resolved="$(LC_ALL=de_DE.UTF-8 _asus_utf8_locale_for_language de)"
    _soft_expect 0 test "$resolved" = "de_DE.UTF-8"
    # _asus_locale_a_utf8_for_language: match from `locale -a` output.
    resolved="$(LC_ALL='' LC_MESSAGES='' LANG='' _asus_utf8_locale_for_language c)"
    _soft_expect 0 test -n "$resolved"
    # _asus_lc_messages_for_gettext: bare language falls through to
    # _asus_utf8_locale_for_language.
    resolved="$(_asus_lc_messages_for_gettext de de)"
    _soft_expect 0 test -n "$resolved"
}

_run_i18n_gettext_paths() {
    local mock="$1" iso="$2" saved_force="${ASUS_I18N_FORCE_MSGID-}"
    # Temporarily clear msgid-only for this driver process (same shell → kcov hits).
    ASUS_I18N_FORCE_MSGID=0
    export ASUS_I18N_FORCE_MSGID
    PATH="$iso" _soft _asus_gettext "No gettext" >/dev/null
    PATH="$mock:$iso" ASUS_TEST_MODE=1 ASUS_UI_LANG=ro \
        _soft _asus_gettext "Message" >/dev/null
    PATH="$mock:$iso" GETTEXT_FAIL=1 _soft _asus_gettext "Fallback" >/dev/null
    PATH="$mock:$iso" GETTEXT_EMPTY=1 _soft _asus_gettext "Empty" >/dev/null
    PATH="$mock:$iso" _soft _asus_gettextf "%s then %s" one two >/dev/null
    PATH="$mock:$iso" _soft _asus_gettextf "No placeholder" ignored >/dev/null
    PATH="$mock:$iso" GETTEXT_IDENTITY=1 \
        _soft _asus_pgettext "menu" "Balanced" >/dev/null
    _i18n_restore_force_msgid "$saved_force"
}

_run_i18n_plural_paths() {
    local mock="$1" iso="$2" saved_force="${ASUS_I18N_FORCE_MSGID-}"
    ASUS_I18N_FORCE_MSGID=0
    export ASUS_I18N_FORCE_MSGID
    PATH="$iso" _soft _asus_ngettext "one" "many" 1 >/dev/null
    PATH="$iso" _soft _asus_ngettext "one" "many" 2 >/dev/null
    PATH="$mock:$iso" _soft _asus_ngettext "one" "many" 2 >/dev/null
    PATH="$mock:$iso" NGETTEXT_FAIL=1 _soft _asus_ngettext "one" "many" 2 >/dev/null
    PATH="$mock:$iso" NGETTEXT_EMPTY=1 _soft _asus_ngettext "one" "many" 1 >/dev/null
    _i18n_restore_force_msgid "$saved_force"
    _soft_expect 0 _asus_source_plural "one" "many" 1 >/dev/null
    _soft_expect 0 _asus_source_plural "one" "many" 3 >/dev/null
}

_run_i18n_kcov_main() {
    local tmp mock iso
    tmp=$(mktemp -d)
    # Expand path now: local tmp is gone when EXIT runs after this function returns.
    trap 'rm -rf "'"$tmp"'"' EXIT
    mock="$tmp/mock"
    iso="$tmp/iso"
    TEXTDOMAINDIR="$tmp/locale"
    mkdir -p "$mock" "$iso" "$TEXTDOMAINDIR" "$tmp/prefix/usr/local/share/locale"
    _link_iso_tools "$iso"
    _link_iso_additional_tools "$iso" tr env id awk grep head
    _write_i18n_command_stubs "$mock"
    mkdir -p "$tmp/proc/$$"
    printf 'LC_MESSAGES=fr_FR.UTF-8\0' > "$tmp/proc/$$/environ"
    export TEXTDOMAINDIR

    # shellcheck source=lib/asus-session.sh
    _driver_source_required "$REPO_ROOT/lib/asus-session.sh" i18n_helpers quiet
    # shellcheck source=lib/asus-i18n.sh
    _driver_source_required "$REPO_ROOT/lib/asus-i18n.sh" i18n_helpers quiet

    # Cover _asus_ui_label before _exercise-heavy paths (kcov attribution).
    _soft _asus_ui_label "ASUS ZenBook" >/dev/null

    _run_i18n_gettext_paths "$mock" "$iso"
    _run_i18n_plural_paths "$mock" "$iso"
    _run_i18n_locale_paths "$mock" "$iso" "$tmp/proc"
}

_run_i18n_kcov_main
