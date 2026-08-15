#!/usr/bin/env bash
# systemd unit lifecycle helpers for install-components.sh.

_run_one_unit_management_op() {
    local timeout_value="$1" log_file="$2"
    shift 2
    if ! _run_command_with_timeout "$timeout_value" "$SYSTEMCTL" "$@" \
        > /dev/null 2>"$log_file"; then
        cat "$log_file" >&2
        rm -f "$log_file"
        return 1
    fi
    return 0
}

_run_unit_management_ops_common() {
    local unit_name="$1" run_action="$2"
    local timeout_value="${INSTALL_COMMAND_TIMEOUT:-5}"
    local log_file

    log_file=$(mktemp)
    _valid_unit_log_file "$log_file" || return 1
    _run_one_unit_management_op "$timeout_value" "$log_file" daemon-reload || return 1
    _run_one_unit_management_op "$timeout_value" "$log_file" enable "$unit_name" || return 1
    _run_one_unit_management_op "$timeout_value" "$log_file" "$run_action" "$unit_name" || return 1
    rm -f "$log_file"
    return 0
}

_valid_unit_log_file() {
    local log_file="$1"
    [ -n "$log_file" ] || return 1
    [ -e "$log_file" ]
}

_run_unit_management_ops() {
    local unit_name="$1" run_action="$2"
    local timeout_value="${INSTALL_COMMAND_TIMEOUT:-5}"

    if ! _run_unit_management_ops_common "$unit_name" "$run_action"; then
        echo "  ✗ Failed to ${run_action} unit $unit_name (systemctl action)." >&2
        return 1
    fi
    if ! _verify_unit_state_after_action "$timeout_value" "$unit_name" "$run_action"; then
        echo "  ✗ Unit $unit_name ${run_action} did not verify as active." >&2
        return 1
    fi
    return 0
}

_verify_unit_state_after_action() {
    local timeout_value="$1" unit_name="$2" run_action="$3"

    if [ "$run_action" = "disable" ]; then
        return 0
    fi

    if [ "${INSTALL_ASSUME_UNIT_ACTIVE:-0}" = "1" ]; then
        return 0
    fi

    _run_command_with_timeout "$timeout_value" "$SYSTEMCTL" is-active "$unit_name" 2>/dev/null >/dev/null || return 1
}

_run_unit_management_ops_unverified() {
    _run_unit_management_ops_common "$@"
}
