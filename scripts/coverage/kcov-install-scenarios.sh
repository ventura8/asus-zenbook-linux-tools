#!/usr/bin/env bash
# Install/uninstall and product-lib kcov scenario helpers.

_make_fake_systemctl_script() {
    local tmp="$1"
    cat <<'EOF' > "$tmp/systemctl"
#!/bin/sh
if [ "$1" = "is-active" ]; then
    echo active
fi
exit 0
EOF
    chmod +x "$tmp/systemctl"
}

_make_fake_systemctl_inactive_script() {
    local tmp="$1"
    cat <<'EOF' > "$tmp/systemctl-inactive"
#!/bin/sh
if [ "$1" = "is-active" ]; then
    exit 3
fi
exit 0
EOF
    chmod +x "$tmp/systemctl-inactive"
}

_setup_mock_install_env() {
    local tmp="$1" uid
    uid="$(id -u)"
    # Session user must be a real passwd name (not ghost_user) so GNOME
    # _install_run_as_user same-user path works under Docker coverage-gate.
    # Bind bus under the container UID (never hardcode 1000 — GHA asusci is often 1001).
    _make_fake_loginctl_current_user "$tmp"
    _make_fake_gsettings_script "$tmp"
    _make_fake_sudo_script "$tmp"
    _make_fake_systemctl_script "$tmp"
    mkdir -p "$tmp/bus_root/$uid" "$tmp/dest/usr/local/bin"
    _kcov_make_stub "$tmp/dest/usr/local/bin/asus-sound-fix.sh"
    _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
}

# install.sh/uninstall.sh stay under kcov with short timeouts so product shell
# coverage includes installers/libs without multi-minute instrumentation stalls.
_kcov_install_fast_env() {
    printf '%s\n' \
        "ASUS_TEST_MODE=1" \
        "SKIP_ROOT_CHECK=1" \
        "SKIP_PKG_INSTALL=1" \
        "SKIP_PKG_REMOVE=1" \
        "INSTALL_COMMAND_TIMEOUT=1" \
        "INSTALL_SKIP_TIMEOUT_WRAPPER=1" \
        "INSTALL_ASSUME_UNIT_ACTIVE=1" \
        "SOUND_FIX_PROBE_TIMEOUT=1" \
        "SOUND_HWDEV_POLL_ATTEMPTS=1"
}

_seed_gnome_backup_state() {
    local dest="$1" uid state_dir
    uid="$(id -u)"
    state_dir="$dest/var/lib/asus-zenbook-linux-tools/$uid"
    mkdir -p "$state_dir"
    echo "['Print']" > "$state_dir/orig_show_screenshot_ui"
    echo "['XF86Launch1']" > "$state_dir/orig_control_center"
    echo "['<Super>p']" > "$state_dir/orig_switch_video_mode"
    echo "['<Super>p']" > "$state_dir/orig_switch_monitor"
}

_run_kcov_install_base_runs() {
    local kcov_root="$1" tmp="$2"
    local -a fast_env
    mapfile -t fast_env < <(_kcov_install_fast_env)
    _seed_gnome_backup_state "$tmp/dest"
    _kcov_expect_run_env "0" "$kcov_root" install_all \
        "${fast_env[@]}" PATH="$tmp:$PATH" NONINTERACTIVE_CHOICE="WMI TOUCHPAD GNOME" \
        DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/bus_root" SYSTEMCTL_CMD="$tmp/systemctl" \
        ./install.sh
    _kcov_expect_run_env "0" "$kcov_root" install_existing_backup \
        "${fast_env[@]}" PATH="$tmp:$PATH" NONINTERACTIVE_CHOICE="GNOME" \
        DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/bus_root" SYSTEMCTL_CMD="$tmp/systemctl" \
        ./install.sh
    # INSTALL_SOURCE_DIR + temp-script cleanup trap path.
    touch "$tmp/install-temp-script.sh"
    _kcov_expect_run_env "0" "$kcov_root" install_source_dir \
        "${fast_env[@]}" PATH="$tmp:$PATH" NONINTERACTIVE_CHOICE="WMI" \
        INSTALL_SOURCE_DIR="$(pwd)" INSTALL_TEMP_SCRIPT="$tmp/install-temp-script.sh" \
        DESTDIR="$tmp/dest_src" DBUS_BUS_ROOT="$tmp/bus_root" SYSTEMCTL_CMD="$tmp/systemctl" \
        ./install.sh
    _kcov_expect_run_env "0" "$kcov_root" install_reexec_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver install_reexec_helpers.sh)"
}

_run_kcov_install_fail_runs_1() {
    local kcov_root="$1" tmp="$2"
    local -a fast_env
    mapfile -t fast_env < <(_kcov_install_fast_env)
    _kcov_expect_run_env "1" "$kcov_root" install_root_fail \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=0 SKIP_PKG_INSTALL=1 INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        DESTDIR="$tmp/dest" SYSTEMCTL_CMD="false" EFFECTIVE_UID_OVERRIDE=1000 ./install.sh
    _kcov_expect_run_env "1" "$kcov_root" install_deps_skip \
        "${fast_env[@]}" NONINTERACTIVE_CHOICE="WMI TOUCHPAD SOUND GNOME" PATH="/nonexistent:$PATH" \
        DESTDIR="$tmp/dest" SYSTEMCTL_CMD="false" ./install.sh
    _kcov_expect_run_env "1" "$kcov_root" install_sound_fail \
        "${fast_env[@]}" NONINTERACTIVE_CHOICE="SOUND" DESTDIR="$tmp/dest" SYSTEMCTL_CMD="false" \
        ./install.sh
}

_run_kcov_install_fail_runs_2() {
    local kcov_root="$1" tmp="$2"
    local -a fast_env
    mapfile -t fast_env < <(_kcov_install_fast_env)
    mkdir -p "$tmp/empty_bus"
    _kcov_expect_run_env "1" "$kcov_root" install_gnome_nobus \
        "${fast_env[@]}" NONINTERACTIVE_CHOICE="GNOME" DESTDIR="$tmp/dest" \
        DBUS_BUS_ROOT="$tmp/empty_bus" ./install.sh
    _kcov_expect_run_env "1" "$kcov_root" install_gnome_fail \
        "${fast_env[@]}" NONINTERACTIVE_CHOICE="GNOME" DESTDIR="$tmp/dest" \
        DBUS_BUS_ROOT="$tmp/bus_root" SYSTEMCTL_CMD="true" PATH="$tmp:$PATH" FAIL_GSETTINGS=1 \
        ./install.sh
}

_run_kcov_install_runs() {
    _run_kcov_install_base_runs "$1" "$2"
    _run_kcov_install_fail_runs_1 "$1" "$2"
    _run_kcov_install_fail_runs_2 "$1" "$2"
    _run_kcov_install_deps_and_selection_runs "$1" "$2"
}

_run_kcov_uninstall_runs() {
    local kcov_root="$1" tmp="$2"
    local -a fast_env
    mapfile -t fast_env < <(_kcov_install_fast_env)
    _make_fake_systemctl_inactive_script "$tmp"
    _kcov_expect_run_env "0" "$kcov_root" uninstall_all \
        "${fast_env[@]}" PATH="$tmp:$PATH" DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl-inactive" ./uninstall.sh
    _seed_gnome_backup_state "$tmp/dest"
    _kcov_expect_run_env "0" "$kcov_root" uninstall_with_saved_vals \
        "${fast_env[@]}" PATH="$tmp:$PATH" DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl-inactive" ./uninstall.sh
    mkdir -p "$tmp/empty_bus"
    _seed_gnome_backup_state "$tmp/dest"
    _kcov_expect_run_env "1" "$kcov_root" uninstall_restore_fail \
        "${fast_env[@]}" PATH="$tmp:$PATH" DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/empty_bus" \
        SYSTEMCTL_CMD="$tmp/systemctl-inactive" ./uninstall.sh
    _kcov_expect_run_env "1" "$kcov_root" uninstall_root_fail \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=0 SKIP_PKG_INSTALL=1 INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        DESTDIR="$tmp/dest" SYSTEMCTL_CMD="false" EFFECTIVE_UID_OVERRIDE=1000 ./uninstall.sh
    # systemctl "unit not found" is treated as success for stop/disable/is-active.
    # daemon-reload must still succeed so file removal can complete cleanly.
    cat <<'EOF' > "$tmp/systemctl-absent"
#!/bin/sh
if [ "$1" = "daemon-reload" ]; then
    exit 0
fi
echo "Unit asus-hotkey-daemon.service could not be found." >&2
exit 1
EOF
    chmod +x "$tmp/systemctl-absent"
    _kcov_expect_run_env "0" "$kcov_root" uninstall_absent_units \
        "${fast_env[@]}" PATH="$tmp:$PATH" DESTDIR="$tmp/dest_absent" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl-absent" ./uninstall.sh
    # Hard systemctl failure results in uninstall exit status 1.
    cat <<'EOF' > "$tmp/systemctl-hardfail"
#!/bin/sh
echo "Failed to connect to bus" >&2
exit 1
EOF
    chmod +x "$tmp/systemctl-hardfail"
    _kcov_expect_run_env "1" "$kcov_root" uninstall_systemctl_hardfail \
        "${fast_env[@]}" PATH="$tmp:$PATH" DESTDIR="$tmp/dest_hf" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl-hardfail" ./uninstall.sh
    # Recorded dependency removal path (SKIP_PKG_REMOVE unset).
    mkdir -p "$tmp/dest_deps/var/lib/asus-zenbook-linux-tools"
    printf '%s\n' python3-evdev ydotool > "$tmp/dest_deps/var/lib/asus-zenbook-linux-tools/installed-packages"
    _kcov_make_stub "$tmp/apt-get"
    _kcov_make_stub "$tmp/apt-mark"
    _kcov_make_stub "$tmp/dpkg-query" "printf 'installed\\n'"
    _kcov_expect_run_env "0" "$kcov_root" uninstall_remove_deps \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=1 SKIP_PKG_REMOVE=0 \
        INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian \
        PATH="$tmp:$PATH" DESTDIR="$tmp/dest_deps" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl-inactive" ./uninstall.sh
}

_run_kcov_install_uninstall_scenarios() {
    (
        local kcov_root="$1"
        local tmp
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        _setup_mock_install_env "$tmp"
        _run_kcov_install_runs "$kcov_root" "$tmp"
        _run_kcov_uninstall_runs "$kcov_root" "$tmp"
    )
}

_run_kcov_install_deps_and_selection_runs() {
    local kcov_root="$1" tmp="$2"
    local mock="$tmp/pkgmock"
    mkdir -p "$mock" "$tmp/dest2" "$tmp/dest3" "$tmp/dest4"
    # Present packages: install_system_deps reports "already installed".
    _kcov_make_stub "$mock/dpkg"
    _kcov_make_stub "$mock/rpm"
    _kcov_make_stub "$mock/pacman"
    _kcov_make_stub "$mock/apt-get"
    _kcov_make_stub "$mock/dnf"
    _kcov_make_stub "$mock/zypper"
    _kcov_expect_run_env "0" "$kcov_root" install_deps_present \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=0 INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_ASSUME_UNIT_ACTIVE=1 SOUND_FIX_PROBE_TIMEOUT=1 SOUND_HWDEV_POLL_ATTEMPTS=1 \
        INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian PATH="$mock:$tmp:$PATH" \
        NONINTERACTIVE_CHOICE="WMI TOUCHPAD GNOME" DESTDIR="$tmp/dest" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl" ./install.sh
    _kcov_expect_run_env "0" "$kcov_root" install_deps_fedora \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=0 INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_ASSUME_UNIT_ACTIVE=1 INSTALL_OS_ID=fedora PATH="$mock:$tmp:$PATH" \
        NONINTERACTIVE_CHOICE="1,4" DESTDIR="$tmp/dest2" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl" ./install.sh
    # Missing packages + successful installer command.
    _kcov_make_stub "$mock/dpkg" 'exit 1'
    _kcov_make_stub "$mock/apt-get"
    _kcov_expect_run_env "0" "$kcov_root" install_deps_install_cmd \
        ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=0 INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
        INSTALL_ASSUME_UNIT_ACTIVE=1 INSTALL_OS_ID=ubuntu INSTALL_OS_ID_LIKE=debian PATH="$mock:$tmp:$PATH" \
        NONINTERACTIVE_CHOICE="WMI" DESTDIR="$tmp/dest4" DBUS_BUS_ROOT="$tmp/bus_root" \
        SYSTEMCTL_CMD="$tmp/systemctl" ./install.sh
    # Interactive default selection when NONINTERACTIVE_CHOICE is unset.
    # Use a sound-capable mock so the default-all path can succeed end-to-end.
    mkdir -p "$tmp/snd" "$tmp/asound/card0"
    touch "$tmp/snd/hwC0D0"
    printf "ALC294\n" > "$tmp/asound/card0/codec#0"
    _kcov_make_stub "$tmp/hda-verb"
    _kcov_expect_run_env "0" "$kcov_root" install_default_selection \
        PATH="$tmp:$PATH" ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 SKIP_PKG_INSTALL=1 \
        INSTALL_COMMAND_TIMEOUT=1 \
        INSTALL_SKIP_TIMEOUT_WRAPPER=1 INSTALL_ASSUME_UNIT_ACTIVE=1 INSTALL_FAKE_NO_TTY=1 \
        DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
        DESTDIR="$tmp/dest3" DBUS_BUS_ROOT="$tmp/bus_root" SYSTEMCTL_CMD="$tmp/systemctl" \
        ./install.sh
}

_run_kcov_os_detection_helpers() {
    (
        local kcov_root="$1" tmp mock
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mock="$tmp/pkgmock"
        mkdir -p "$mock"
        _kcov_make_stub "$mock/dpkg"
        _kcov_make_stub "$mock/rpm"
        _kcov_make_stub "$mock/pacman"
        _kcov_make_stub "$mock/apt-get"
        _kcov_make_stub "$mock/apt"
        _kcov_make_stub "$mock/dnf"
        _kcov_make_stub "$mock/zypper"
        _kcov_make_stub "$mock/yum"
        _kcov_expect_run_env "0" "$kcov_root" os_detect_helpers \
            PATH="$mock:$PATH" REPO_ROOT="$(pwd)" "$(_kcov_driver os_detect_helpers.sh)"
        # Missing packages + installer command path.
        _kcov_make_stub "$mock/dpkg" 'exit 1'
        _kcov_make_stub "$mock/rpm" 'exit 1'
        _kcov_make_stub "$mock/pacman" 'exit 1'
        _kcov_expect_run_env "0" "$kcov_root" os_detect_helpers_missing \
            PATH="$mock:$PATH" REPO_ROOT="$(pwd)" "$(_kcov_driver os_detect_helpers.sh)"
    )
}

_run_kcov_selection_helpers() {
    (
        local kcov_root="$1"
        # Scripted TUI keys exercise apply/cancel/empty without whiptail.
        _kcov_expect_run_env "0" "$kcov_root" selection_helpers \
            ASUS_TUI_SCRIPT_KEYS=$'\n' REPO_ROOT="$(pwd)" "$(_kcov_driver selection_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" selection_helpers_cancel \
            ASUS_TUI_SCRIPT_KEYS=$'\x1b' REPO_ROOT="$(pwd)" "$(_kcov_driver selection_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" selection_helpers_empty \
            ASUS_TUI_SCRIPT_KEYS=' j j j \n' REPO_ROOT="$(pwd)" \
            "$(_kcov_driver selection_helpers.sh)"
    )
}

_run_kcov_shared_common_helpers() {
    (
        local kcov_root="$1" tmp uid
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        uid="$(id -u)"
        mkdir -p "$tmp/bus/$uid"
        _kcov_bind_unix_bus "$tmp/bus/$uid/bus"
        printf '#!/bin/sh\necho "(uint32 9,)"\n' > "$tmp/gdbus"; chmod +x "$tmp/gdbus"
        _kcov_make_stub "$tmp/notify-send"
        _make_fake_loginctl_current_user "$tmp"
        _make_fake_sudo_script "$tmp"
        _kcov_expect_run_env "0" "$kcov_root" common_notify_helpers \
            PATH="$tmp:$PATH" RUN_USER_ROOT="$tmp/bus" KCOV_BUS_ROOT="$tmp/bus" REPO_ROOT="$(pwd)" \
            "$(_kcov_driver common_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" shared_install_helpers \
            ASUS_TEST_MODE=1 SKIP_ROOT_CHECK=1 INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
            REPO_ROOT="$(pwd)" "$(_kcov_driver shared_helpers.sh)"
        _kcov_make_stub "$tmp/gdbus" 'exit 1'
        _kcov_expect_run_env "0" "$kcov_root" common_notify_fallback \
            PATH="$tmp:$PATH" RUN_USER_ROOT="$tmp/bus" KCOV_BUS_ROOT="$tmp/bus" REPO_ROOT="$(pwd)" \
            "$(_kcov_driver common_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" i18n_helpers \
            REPO_ROOT="$(pwd)" "$(_kcov_driver i18n_helpers.sh)"
        # Components helper coverage with sound mocks + systemctl.
        mkdir -p "$tmp/snd" "$tmp/asound/card0" "$tmp/dest"
        touch "$tmp/snd/hwC0D0"
        printf "ALC294\n" > "$tmp/asound/card0/codec#0"
        _kcov_make_stub "$tmp/hda-verb"
        _make_fake_systemctl_script "$tmp"
        _kcov_expect_run_env "0" "$kcov_root" components_helpers \
            PATH="$tmp:$PATH" REPO_ROOT="$(pwd)" DESTDIR="$tmp/dest" SYSTEMCTL_CMD="$tmp/systemctl" \
            INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 INSTALL_ASSUME_UNIT_ACTIVE=1 \
            DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" SOUND_FIX_PROBE_TIMEOUT=1 \
            SOUND_HWDEV_POLL_ATTEMPTS=1 "$(_kcov_driver components_helpers.sh)"
        printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$tmp/systemctl-fail"; chmod +x "$tmp/systemctl-fail"
        _kcov_expect_run_env "0" "$kcov_root" components_helpers_fail \
            PATH="$tmp:$PATH" REPO_ROOT="$(pwd)" DESTDIR="$tmp/dest2" SYSTEMCTL_CMD="$tmp/systemctl-fail" \
            KCOV_FAIL_SYSTEMCTL="$tmp/systemctl-fail" INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
            INSTALL_STRICT_COMPONENTS=1 DEV_SND_ROOT="$tmp/snd" PROC_ASOUND_ROOT="$tmp/asound" \
            "$(_kcov_driver components_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" uninstall_helpers \
            PATH="$tmp:$PATH" REPO_ROOT="$(pwd)" DESTDIR="$tmp/dest_un" DBUS_BUS_ROOT="$tmp/bus" \
            SYSTEMCTL_CMD="$tmp/systemctl" RUN_USER_ROOT="$tmp/bus" \
            INSTALL_COMMAND_TIMEOUT=1 INSTALL_SKIP_TIMEOUT_WRAPPER=1 \
            "$(_kcov_driver uninstall_helpers.sh)"
    )
}

_run_kcov_display_source_helpers() {
    local kcov_root="$1"
    # Split entry/session/backend so each kcov run stays ≤45s and kcov can
    # attribute same-shell hits (heavy slices drop later parent-shell coverage).
    _kcov_expect_run_env "0" "$kcov_root" disp_source_entry \
        REPO_ROOT="$(pwd)" ASUS_KCOV_DISPLAY_SLICE=entry \
        "$(_kcov_driver display_helpers.sh)"
    _kcov_expect_run_env "0" "$kcov_root" disp_source_session \
        REPO_ROOT="$(pwd)" ASUS_KCOV_DISPLAY_SLICE=session \
        "$(_kcov_driver display_helpers.sh)"
    _kcov_expect_run_env "0" "$kcov_root" disp_source_backend \
        REPO_ROOT="$(pwd)" ASUS_KCOV_DISPLAY_SLICE=backend \
        "$(_kcov_driver display_helpers.sh)"
}

_run_kcov_session_helpers() {
    local kcov_root="$1"
    _kcov_expect_run_env "0" "$kcov_root" session_helpers \
        REPO_ROOT="$(pwd)" "$(_kcov_driver session_helpers.sh)"
}

_run_kcov_desktop_install_helpers() {
    local kcov_root="$1"
    (
        local kde_dest xfce_dest lxqt_dest cin_dest mate_dest
        kde_dest=$(mktemp -d)
        xfce_dest=$(mktemp -d)
        lxqt_dest=$(mktemp -d)
        cin_dest=$(mktemp -d)
        mate_dest=$(mktemp -d)
        gnome_dest=$(mktemp -d)
        trap 'rm -rf "$kde_dest" "$xfce_dest" "$lxqt_dest" "$cin_dest" "$mate_dest" "$gnome_dest"' EXIT
        _kcov_expect_run_env "0" "$kcov_root" kde_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$kde_dest" \
            "$(_kcov_driver kde_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" xfce_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$xfce_dest" \
            "$(_kcov_driver xfce_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" lxqt_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$lxqt_dest" \
            "$(_kcov_driver lxqt_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" cinnamon_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$cin_dest" \
            "$(_kcov_driver cinnamon_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" mate_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$mate_dest" \
            "$(_kcov_driver mate_helpers.sh)"
        _kcov_expect_run_env "0" "$kcov_root" gnome_helpers \
            REPO_ROOT="$(pwd)" DESTDIR="$gnome_dest" \
            "$(_kcov_driver gnome_helpers.sh)"
    )
}

_run_kcov_product_lib_helpers() {
    local kcov_root="$1"
    _run_kcov_os_detection_helpers "$kcov_root"
    _run_kcov_selection_helpers "$kcov_root"
    _run_kcov_shared_common_helpers "$kcov_root"
    _run_kcov_display_source_helpers "$kcov_root"
    _run_kcov_session_helpers "$kcov_root"
    _run_kcov_desktop_install_helpers "$kcov_root"
}

_run_kcov_screenshot_family_scenarios() {
    local kcov_root="$1"
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _kcov_make_stub "$tmp/gdbus" 'exit 1'
        _kcov_make_stub "$tmp/ydotool"
        printf '#!/bin/sh\necho ["Print"]\n' > "$tmp/gsettings"; chmod +x "$tmp/gsettings"
        _kcov_make_stub "$tmp/systemctl"
        _kcov_make_stub "$tmp/xdotool"
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        # Private ydotool socket under $tmp; screenshot honors YDOTOOL_SOCKET.
        _kcov_bind_unix_bus "$tmp/ydotool.sock"
        _soft ln -sf "$tmp/ydotool.sock" "$tmp/bus_root/$uid/.ydotool_socket" 2>/dev/null
        _kcov_expect_run_env "0" "$kcov_root" ss_gnome_keychord PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=gnome \
            YDOTOOL_SOCKET="$tmp/ydotool.sock" \
            DISPLAY=:0 ./bin/asus-screenshot.sh
        rm -f "$tmp/ydotool.sock"
        # Keep a failing ydotool stub so PATH does not fall through to a real one.
        _kcov_make_stub "$tmp/ydotool" 'exit 1'
        _kcov_expect_run_env "0" "$kcov_root" ss_gnome_xdotool PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=gnome \
            DISPLAY=:0 ./bin/asus-screenshot.sh
        # Already-bound show-screenshot-ui short-circuit.
        printf '#!/bin/sh\necho ["<Super><Shift>s"]\n' > "$tmp/gsettings"
        _kcov_expect_run_env "0" "$kcov_root" ss_gnome_keybinding_present PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=gnome \
            DISPLAY=:0 ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        # First gdbus ShowScreenshotUI fails; second InteractiveScreenshot succeeds.
        cat > "$tmp/gdbus" <<'EOF'
#!/bin/sh
case "$*" in
    *ShowScreenshotUI*) exit 1 ;;
    *InteractiveScreenshot*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
        chmod +x "$tmp/gdbus"
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_gnome_interactive PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=gnome \
            ASUS_SCREENSHOT_DISABLE_KEYCHORD=1 ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _kcov_make_stub "$tmp/spectacle" 'sleep 1; exit 0'
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_kde_spectacle PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=kde ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _kcov_make_stub "$tmp/xfce4-screenshooter" 'sleep 1; exit 0'
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_xfce_shooter PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=xfce ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _kcov_make_stub "$tmp/screengrab" 'sleep 1; exit 0'
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_lxqt_screengrab PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=lxqt ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        # Preferred kde path fails (no spectacle); fall back to gnome dbus.
        _kcov_make_stub "$tmp/gdbus"
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "0" "$kcov_root" ss_kde_fallback_gnome PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=kde ./bin/asus-screenshot.sh
    )
    (
        local tmp uid
        tmp=$(mktemp -d)
        uid="$(id -u)"
        trap 'rm -rf "$tmp"' EXIT
        _make_fake_loginctl_current_user "$tmp"
        _kcov_make_stub "$tmp/gdbus" 'exit 1'
        _make_fake_sudo_script "$tmp"
        mkdir -p "$tmp/bus_root/$uid"
        _kcov_bind_unix_bus "$tmp/bus_root/$uid/bus"
        _kcov_expect_run_env "1" "$kcov_root" ss_portal_fail PATH="$tmp:$PATH" \
            RUN_USER_ROOT="$tmp/bus_root" ASUS_DESKTOP_FAMILY=other \
            ASUS_SCREENSHOT_DISABLE_KEYCHORD=1 ./bin/asus-screenshot.sh
    )
}

# shellcheck source=scripts/coverage/kcov-install-scenarios-desktop.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov-install-scenarios-desktop.sh"
# shellcheck source=scripts/coverage/kcov-install-scenarios-shards.sh
source "$(dirname "${BASH_SOURCE[0]}")/kcov-install-scenarios-shards.sh"
