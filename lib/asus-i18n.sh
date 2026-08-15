#!/usr/bin/env bash
# GNU gettext helpers for user-facing ASUS ZenBook Linux Tools text.

ASUS_TEXTDOMAIN="asus-zenbook-linux-tools"

_asus_i18n_repo_root() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    (cd "$lib_dir/.." && pwd)
}

_asus_resolve_textdomain_dir() {
    local repo_root candidate
    if [ -n "${TEXTDOMAINDIR:-}" ]; then
        printf '%s\n' "$TEXTDOMAINDIR"
        return 0
    fi
    repo_root=$(_asus_i18n_repo_root 2>/dev/null || true)
    for candidate in \
        "${repo_root:+${repo_root}/locale}" \
        "${PREFIX:-}/usr/local/share/locale" \
        "/usr/share/locale"; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done
    printf '%s\n' "${PREFIX:-}/usr/local/share/locale"
}

_asus_normalize_ui_language() {
    local value="${1:-}"
    value="${value%%:*}"
    value="${value%%.*}"
    value="${value%%@*}"
    value="${value%%_*}"
    value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        jv) value="jw" ;;
    esac
    case "$value" in
        [a-z][a-z]|[a-z][a-z][a-z]) printf '%s\n' "$value" ;;
        *) return 1 ;;
    esac
}

_asus_test_ui_language() {
    [ "${ASUS_TEST_MODE:-0}" = "1" ] || return 1
    [ -n "${ASUS_UI_LANG:-}" ] || return 1
    printf '%s\n' "$ASUS_UI_LANG"
}

_asus_session_ui_value() {
    local key="$1" target_user="${2:-}"
    declare -F asus_session_env_value >/dev/null 2>&1 || return 1
    asus_session_env_value "$key" "$target_user"
}

_asus_first_session_ui_language() {
    local target_user="${1:-}" key value
    for key in LC_MESSAGES LANG LANGUAGE; do
        if value=$(_asus_session_ui_value "$key" "$target_user" 2>/dev/null) &&
            [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    return 1
}

_asus_resolve_ui_locale() {
    local target_user="${1:-}" value
    if value=$(_asus_test_ui_language 2>/dev/null); then
        printf '%s\n' "$value"
        return 0
    fi
    if value=$(_asus_first_session_ui_language "$target_user"); then
        printf '%s\n' "$value"
        return 0
    fi
    value="${LC_MESSAGES:-${LANG:-${LANGUAGE:-en}}}"
    printf '%s\n' "$value"
}

_asus_gettext_env() {
    local target_user="${ASUS_I18N_TARGET_USER:-}" locale language locale_for_lookup
    locale=$(_asus_resolve_ui_locale "$target_user")
    language=$(_asus_normalize_ui_language "$locale" 2>/dev/null || true)
    [ -n "$language" ] || language="en"
    locale_for_lookup="$locale"
    case "$locale_for_lookup" in
        *.*|*@*) ;;
        *) locale_for_lookup="${language}_${language}.UTF-8" ;;
    esac
    printf '%s\n%s\n' "$language" "$locale_for_lookup"
}

_asus_gettext() {
    local msgid="$1" language locale translated textdomain_dir env_blob
    # kcov+bash loses caller line attribution after nested gettext helper work.
    # Coverage scenarios set ASUS_I18N_FORCE_MSGID=1; production leaves it unset.
    if [ "${ASUS_I18N_FORCE_MSGID:-0}" = "1" ] \
        || ! command -v gettext >/dev/null 2>&1; then
        printf '%s' "$msgid"
        return 0
    fi
    env_blob=$(_asus_gettext_env)
    language=${env_blob%%$'\n'*}
    locale=${env_blob#*$'\n'}
    locale=${locale%%$'\n'*}
    textdomain_dir=$(_asus_resolve_textdomain_dir)
    translated=$(
        LANGUAGE="$language" LC_MESSAGES="$locale" \
            TEXTDOMAIN="$ASUS_TEXTDOMAIN" TEXTDOMAINDIR="$textdomain_dir" \
            gettext "$msgid" 2>/dev/null
    ) || translated="$msgid"
    printf '%s' "${translated:-$msgid}"
}

_asus_gettextf() {
    local format argument prefix suffix
    format=$(_asus_gettext "$1")
    shift
    for argument in "$@"; do
        case "$format" in
            *%s*)
                prefix=${format%%\%s*}
                suffix=${format#*%s}
                format="${prefix}${argument}${suffix}"
                ;;
        esac
    done
    printf '%s' "$format"
}

_asus_pgettext() {
    local context="$1" msgid="$2" key translated
    key="${context}"$'\004'"${msgid}"
    translated=$(_asus_gettext "$key")
    [ "$translated" = "$key" ] && translated="$msgid"
    printf '%s' "$translated"
}

_asus_ngettext() {
    local singular="$1" plural="$2" count="$3"
    local language locale translated textdomain_dir env_blob
    if [ "${ASUS_I18N_FORCE_MSGID:-0}" = "1" ] \
        || ! command -v ngettext >/dev/null 2>&1; then
        _asus_source_plural "$singular" "$plural" "$count"
        return 0
    fi
    env_blob=$(_asus_gettext_env)
    language=${env_blob%%$'\n'*}
    locale=${env_blob#*$'\n'}
    locale=${locale%%$'\n'*}
    textdomain_dir=$(_asus_resolve_textdomain_dir)
    if ! translated=$(
        LANGUAGE="$language" LC_MESSAGES="$locale" \
            TEXTDOMAIN="$ASUS_TEXTDOMAIN" TEXTDOMAINDIR="$textdomain_dir" \
            ngettext "$singular" "$plural" "$count" 2>/dev/null
    ); then
        translated=""
    fi
    if [ -z "$translated" ]; then
        translated=$(_asus_source_plural "$singular" "$plural" "$count")
    fi
    printf '%s' "$translated"
}

_asus_source_plural() {
    local singular="$1" plural="$2" count="$3"
    if [ "$count" -eq 1 ]; then
        printf '%s' "$singular"
        return 0
    fi
    printf '%s' "$plural"
}

# Safe label helper for install/uninstall tables (msgid English fallback).
_asus_ui_label() {
    local msgid="$1"
    if declare -F _asus_gettext >/dev/null 2>&1; then
        _asus_gettext "$msgid"
        return 0
    fi
    printf '%s' "$msgid"
}
