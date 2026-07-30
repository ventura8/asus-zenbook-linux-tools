#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POT_PATH="$REPO_ROOT/po/asus-zenbook-linux-tools.pot"
DOMAIN="asus-zenbook-linux-tools"

_require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Missing required gettext tool: %s\n' "$1" >&2
        return 1
    }
}

_collect_sources() {
    mapfile -t SHELL_SOURCES < <(
        cd "$REPO_ROOT"
        find bin lib -type f -name '*.sh' -print | sort
    )
    SHELL_SOURCES+=("install.sh")
    mapfile -t PYTHON_SOURCES < <(
        cd "$REPO_ROOT"
        find bin -type f -name '*.py' -print | sort
    )
}

_normalize_pot() {
    local pot_file="$1"
    python3 - "$pot_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
lines = [
    '"POT-Creation-Date: 1970-01-01 00:00+0000\\n"'
    if line.startswith('"POT-Creation-Date:')
    else line
    for line in text.splitlines()
    if not line.startswith('"X-Generator:')
]
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
}

_extract_catalog() {
    local output_path="$1" temp_dir shell_pot python_pot python_subtitles_pot
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' RETURN
    shell_pot="$temp_dir/shell.pot"
    python_pot="$temp_dir/python.pot"
    python_subtitles_pot="$temp_dir/python-subtitles.pot"

    # --force-po writes the output even when a keyword pass finds no strings
    # (subtitle extraction is often empty after the preferences UI was removed).
    xgettext --force-po --language=Shell --from-code=UTF-8 --add-comments=TRANSLATORS: \
        --directory="$REPO_ROOT" \
        --keyword= \
        --keyword=_asus_gettext:1 --keyword=_asus_gettextf:1 \
        --keyword=_asus_pgettext:1c,2 --keyword=_asus_ngettext:1,2 \
        --flag=_asus_gettextf:1:sh-format --flag=_asus_ngettext:1:sh-format \
        --flag=_asus_ngettext:2:sh-format --package-name="$DOMAIN" \
        --msgid-bugs-address="https://github.com/ventura8/asus-zenbook-linux-tools/issues" \
        --output="$shell_pot" "${SHELL_SOURCES[@]}"

    xgettext --force-po --language=Python --from-code=UTF-8 --add-comments=TRANSLATORS: \
        --directory="$REPO_ROOT" \
        --keyword=gettext_message:1 --keyword=_message:1 --keyword=_row_text:1 \
        --keyword=_new_page:1 --keyword=_new_group:2 \
        --keyword=_add_switch:3 --keyword=_add_entry:3 \
        --keyword=_add_action:2 --keyword=_register_search:2 \
        --keyword=pgettext_message:1c,2 \
        --keyword=ngettext_message:1,2 --flag=gettext_message:1:python-format \
        --flag=ngettext_message:1:python-format --flag=ngettext_message:2:python-format \
        --package-name="$DOMAIN" \
        --msgid-bugs-address="https://github.com/ventura8/asus-zenbook-linux-tools/issues" \
        --output="$python_pot" "${PYTHON_SOURCES[@]}"

    xgettext --force-po --language=Python --from-code=UTF-8 --add-comments=TRANSLATORS: \
        --directory="$REPO_ROOT" \
        --keyword=_row_text:2 --keyword=_add_switch:4 --keyword=_add_entry:4 \
        --keyword=_add_action:3 --keyword=_register_search:3 \
        --package-name="$DOMAIN" \
        --msgid-bugs-address="https://github.com/ventura8/asus-zenbook-linux-tools/issues" \
        --output="$python_subtitles_pot" "${PYTHON_SOURCES[@]}"

    msgcat --use-first --sort-output --output-file="$output_path" \
        "$shell_pot" "$python_pot" "$python_subtitles_pot"
    _normalize_pot "$output_path"
    trap - RETURN
    rm -rf "$temp_dir"
}

_git_in_repo() {
    # -c safe.directory: lint Docker may mount the tree as a different owner than
    # the container user (dubious ownership); do not require mutating global gitconfig.
    git -C "$REPO_ROOT" -c "safe.directory=$REPO_ROOT" "$@"
}

_require_tracked_catalog() {
    # Fail closed when the pot exists only as a local/gitignored file: CI checkouts
    # omit ignored paths, so a dirty working tree must not hide a missing commit.
    if ! command -v git >/dev/null 2>&1; then
        printf 'Missing required tool: git (needed to verify catalog is tracked).\n' >&2
        return 1
    fi
    if ! _git_in_repo rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf 'Catalog check requires a git work tree so the template can be verified as tracked.\n' >&2
        return 1
    fi
    if ! _git_in_repo ls-files --error-unmatch \
        po/asus-zenbook-linux-tools.pot >/dev/null 2>&1; then
        printf \
            'Catalog template is not tracked by git; commit po/asus-zenbook-linux-tools.pot (see .gitignore ! exception).\n' \
            >&2
        return 1
    fi
}

_fail_catalog_msg() {
    printf '%s\n' "$1" >&2
    return 1
}

_compare_catalog_template() {
    local generated="$1"
    if [ ! -f "$POT_PATH" ]; then
        _fail_catalog_msg \
            'Catalog template missing; run scripts/i18n/extract_pot.sh and commit it.'
        return 1
    fi
    if ! cmp --silent "$generated" "$POT_PATH"; then
        _fail_catalog_msg 'Catalog template is stale; run scripts/i18n/extract_pot.sh.'
        return 1
    fi
    printf 'Catalog template is current.\n'
}

_check_current_catalog() {
    local generated status=0
    generated=$(mktemp) || return 1
    if ! _require_tracked_catalog; then
        rm -f "$generated"
        return 1
    fi
    if ! _extract_catalog "$generated"; then
        rm -f "$generated"
        return 1
    fi
    _compare_catalog_template "$generated" || status=$?
    rm -f "$generated"
    return "$status"
}

main() {
    local mode="${1:-}"
    _require_tool xgettext
    _require_tool msgcat
    _collect_sources
    if [ "$mode" = "--check" ]; then
        _check_current_catalog
        return $?
    fi
    if [ -n "$mode" ]; then
        printf 'Usage: %s [--check]\n' "$0" >&2
        return 2
    fi
    _extract_catalog "$POT_PATH"
    printf 'Updated %s\n' "$POT_PATH"
}

main "$@"
