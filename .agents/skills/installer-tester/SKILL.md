---
name: installer-tester
description: Validate interactive installation and uninstallation wizard behavior.
---

# Installer Tester Skill

Use this skill to inspect and validate `install.sh` and `uninstall.sh` behavior across hardware feature toggles.

## Instructions

1. **Ncurses component checklist**: Interactive selection is
   `bin/asus_install_selection_tui.py` (via `lib/install-selection-tui.sh`), not
   whiptail. Each option shows tag + wrapped detailed description; keep the header
   message short (keys only). Support Space/arrows/Enter/Esc and mouse clicks; accent
   via `ASUS_TUI_ACCENT_RGB` or DE resolve. Headless coverage uses `--script-keys`.
   Text fallback must use the same detailed component msgids. Do not reintroduce
   `whiptail`/`libnewt`/`newt` install deps.

1. **Refresh `install.sh.sha256` on every `install.sh` edit**:
   Any change to `install.sh` must update the checksum in the same change set:

   ```bash
   sha256sum install.sh > install.sh.sha256
   sha256sum -c install.sh.sha256
   ```

   CI and PPA jobs run `sha256sum -c install.sh.sha256` after checkout; a stale hash fails
   the pipeline. Piped installs also verify against this file. Treat a missing checksum
   update as incomplete work (same as skipped tests).
1. **Live Output & Persistent Logs**:

   **Safe default (mocked / non-destructive E2E)** — no host install mutation; mocked tests use
   `SKIP_PKG_REMOVE=1` unless package-manager stubs are intentional:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   (
     export PYTHONPATH="$PWD"
     export SKIP_PKG_REMOVE=1
     cd tests/e2e/mock
     coverage run ../../../tools/dot_test_runner.py \
       --start-dir . --top-level-dir .. --failfast
   ) 2>&1 | tee reports/distro-logs/mocked-e2e-install.log
   ```

   **Real-system E2E (opt-in)** — mutates the host; requires root and
   `E2E_REAL_ALLOW_SYSTEM_CHANGES=1`. **Destructive real uninstall** additionally requires
   `E2E_REAL_ALLOW_DESTRUCTIVE_UNINSTALL=1` and a clean host guarded by the test-owned sentinel
   `${STATE_DIR:-/var/lib/asus-zenbook-linux-tools}/e2e-test-owned` (see `tests/e2e/real/`):

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh \
     2>&1 | tee reports/distro-logs/real-e2e-install-uninstall.log
   ```

   Always run installer checks with live CLI output and always persist logs under `reports/distro-logs/`.

1. **Syntax & Dependency Verification**:
   Ensure `install.sh` probes dependencies per OS family (`lib/install-os-detection.sh`):
   **Debian/Ubuntu** — `python3-evdev`, `alsa-tools`/`hda-verb`, `ydotool` when packaged
   (pure Debian skips `ydotool`; Display Toggle falls back to `xdotool`/Mutter/settings).
   **Fedora** — `python3-evdev`, `alsa-tools`, `hda-verb`, `ydotool`, `xdotool`.
   **Rocky/RHEL** — same except skip system `hda-verb`/`alsa-tools`/`ydotool` (SOUND uses bundled
   `bin/asus_hda_verb.py` when `hda-verb` is absent).
   **openSUSE** — evdev via `_resolve_suse_evdev_pkg` (`python3XY-evdev` from the active `python3`,
   else installed `python3-evdev`); `hda-verb`, `alsa-utils`, `ydotool`/`xdotool` when packaged.
   **Arch** — `python-evdev`, `alsa-tools`, `ydotool`, `xdotool`.
   Confirm `gsettings`/`systemctl` usage where DESKTOP or systemd units apply.
  Distro `--compat-only` smoke (`scripts/run_distro_install_smoke.sh`) must run
  DESKTOP configure cycles for `ASUS_DESKTOP_FAMILY=gnome|kde|xfce|lxqt|cinnamon|mate`
  under a fake session bus with stub `gsettings`/`kwriteconfig`/`xfconf-query`/LXQt
  conf / Cinnamon+MATE gsettings: assert Window Swap extension files + UUID in
  `enabled-extensions`, KDE helper `.desktop` files, XFCE backup/`xfce_bus_path`
  state, LXQt `globalkeyshortcuts.conf` Exec lines, and Cinnamon/MATE custom
  bindings, then uninstall cleanup. XFCE stub
  path keys must match exact `*<Super>F12` (not bare `*F12`); keep XF86Display and
  SuperShiftS mappings. This is
  install-wiring coverage only — not live GNOME Shell `GetFocusedMonitor`.
  Test images install PyGObject (`python3-gi` / `python3-gobject` /
  `python-gobject`) and, where packaged, XFCE/KDE CLI tools (`xfconf`,
  `libkf6config-bin` / `kf6-kconfig` / `kf5-kconfig` on Rocky 9 / `kconfig`)
  without full desktop stacks — including openSUSE Tumbleweed `kf6-kconfig` for
  `kwriteconfig6` (LXQt needs no extra image packages; conf-file backend uses
  HOME stubs). Alma/RHEL 10 Full-DE XFCE builds pinned `xfconf` from source when
  the RPM is absent (EPEL provides `libxfce4util` only).
   Desktop dependency probes include gettext and PyGObject using each distro's
   package names. Verify DESTDIR deploy/uninstall of locale catalogs and core
   WMI/TOUCHPAD assets. Full-DE smoke probes real DE CLIs/schemas only.
   Confirm `install.sh` records newly installed packages under
   `$STATE_DIR/installed-packages`, and `uninstall.sh` removes them via the
   distro package manager (`SKIP_PKG_REMOVE=1` skips removal in tests).
   With no record, uninstall removes no packages unless `ASUS_UNINSTALL_FALLBACK_PKGS=1`
   (known project deps only; never base interpreters).
   On Debian/Ubuntu, apt must use `-o Dpkg::Use-Pty=0` (and stdin `/dev/null`) so
   installs do not SIGTTOU-stop after package triggers in Cursor/sudo terminals.
1. **Root Privilege Check**:
   Verify both scripts refuse non-root via `check_root` (real `EUID` unless
   `ASUS_TEST_MODE=1`, which allows `SKIP_ROOT_CHECK` / `EFFECTIVE_UID_OVERRIDE`).
   Non-root without skip must exit 1 with "Please run as root".
1. **Desktop Keybindings Backup & Restore**:
   Verify `DESKTOP` (alias `GNOME`) dispatches to `install-gnome.sh` /
   `install-kde.sh` / `install-xfce.sh` / `install-lxqt.sh` /
   `install-cinnamon.sh` / `install-mate.sh` based on
   `asus_desktop_family`.
   For GNOME, verify `gsettings get` captures existing keybindings prior to
   setting custom values, and `uninstall.sh` safely restores them.
   Window Swap extension enable must use the session bus
   (`_run_as_user_on_session_bus` / `org.gnome.shell enabled-extensions`); bare
   `sudo -u gnome-extensions enable` without `DBUS_SESSION_BUS_ADDRESS` is a
   known false-success (`dbus-launch` / dconf warning). Enable path must also
   set `org.gnome.shell disable-user-extensions` to `false` — with the kill
   switch on, the UUID can stay in `enabled-extensions` while State is INACTIVE
   and `/org/gnome/Shell/Extensions/AsusWindowSwap` is missing (ScreenPad OSD →
   notify-only; window-swap cannot `MoveFocused`). Expect one logout before
   `GetFocusedMonitor` is live on Wayland for a newly copied extension.
   Soft-ensure of `show-screenshot-ui` from `asus-screenshot.sh` must also
   backup to `orig_show_screenshot_ui` before merge/set when that file is absent.
   Bus socket roots resolve as `BUS_ROOT` → `DBUS_BUS_ROOT` → `RUN_USER_ROOT` →
   `/run/user`; bus-info consumers use `cut -d: -f3-`.
   Optional keys (`switch-video-mode`, Mutter `switch-monitor`) must restore only when
   backup files exist; never hard-fail uninstall by resetting a missing schema key.
   When uninstall resolves `NO_SESSION_USER`, keep the sentinel username but use an empty
   `user_id` so restore paths skip (do not treat the sentinel as a UID directory).
   For KDE/XFCE/LXQt/Cinnamon/MATE, verify `desktop_family` markers under
   `$STATE_DIR/$uid` and matching restore.
   KDE shortcuts must invoke `kwriteconfig` with `HOME`/`XDG_CONFIG_HOME` via `env` under
   `_install_run_as_user` (installer helper in `lib/install-shared.sh`; product helpers keep
   `_run_as_user`). XFCE `xfconf-query` must use session `DBUS_SESSION_BUS_ADDRESS` /
   `XDG_RUNTIME_DIR` from the resolved bus path (persisted as `xfce_bus_path`).
   LXQt edits `~/.config/lxqt/globalkeyshortcuts.conf` with atomic tmp+`mv` backups
   (and `.absent` when a section did not exist); after write, best-effort
   `pkill -HUP lxqt-globalkeysd` — reload miss must warn (re-login / restart Global
   Keys), not fail install. Also bind `Meta%2BP` → `asus-display-mode.sh`. Runtime:
   window-swap `wmctrl`/`xdotool` only (no Shell extension / uinput chords),
   control-center `lxqt-config`, screenshot `screengrab -r`, display sticky Super+P
   then `lxqt-config-monitor` (never Mutter `ApplyMonitorsConfig` on LXQt).
   Cinnamon/MATE: gsettings customs (`install-cinnamon.sh` / `install-mate.sh`);
   runtime control-center `cinnamon-settings` / `mate-control-center`; screenshot
   `gnome-screenshot --area` / `mate-screenshot --area`; display sticky Super+P
   then `cinnamon-settings display` / `mate-display-properties` (never Mutter
   cycle; Muffin/Marco are not drop-ins for `ApplyMonitorsConfig`).
   Portal screenshot fallback uses `ASUS_PORTAL_SCREENSHOT_TIMEOUT_SECS` (default **8s**);
   do not remove the timeout (dead-bus hang guard).
1. **Distro Family Detection Coverage**:
   Verify package-manager detection correctly maps Debian/Ubuntu, Fedora/RHEL, openSUSE/SUSE, and Arch families,
   including `steamos` and Arch derivatives. Ubuntu flavours share apt via `ID=ubuntu`.
   openSUSE evdev package names come from `_resolve_suse_evdev_pkg` (`python3XY-evdev` from the
   active interpreter, or installed `python3-evdev`).
   CI test images create an `asusci` account from `ASUS_CI_UID`/`ASUS_CI_GID` and grant passwordless
   sudo only via `#UID ALL=(ALL) NOPASSWD:ALL` in `/etc/sudoers.d/asus-ci` (not `ALL ALL`).
   Matrix builds under `sudo` must resolve UIDs via `SUDO_UID`/`SUDO_GID` (see
   `_docker_host_uid_gid`); UID/GID must match `^[1-9][0-9]*$` (reject empty,
   non-numeric, zero, zero-padded). Live-pkg smoke treats a Debian
   package as installed only when `dpkg-query` status is `install ok installed`
   (config-files leftovers after non-purge remove must not count).
1. **Launchpad / Debian package path**:
   On Ubuntu resolute, prefer `ppa:ventura8/asus-zenbook-linux-tools` +
   `apt install asus-zenbook-linux-tools`. Confirm `postinst` runs the interactive wizard on
   first-time `configure` (empty previous-version) and when `DEBCONF_RECONFIGURE=1`
   (`dpkg-reconfigure`); plain upgrades skip the wizard (`SKIP_PKG_INSTALL=1`). Package
   payloads live under `/usr/share/asus-zenbook-linux-tools/`; the interactive wizard still
   deploys runtime under `/usr/local`. `prerm` uses `SKIP_PKG_REMOVE=1`. Rebuild locally with
   `dpkg-buildpackage -b -us -uc`.
1. **Fast Timeout Policy for Mocked E2E**:
   Ensure mocked installer tests use per-test timeout budgets of 20-30 seconds.
   Any timeout must fail the test immediately. Mocked uninstall environments must set
   `SKIP_PKG_REMOVE=1` unless the test intentionally stubs package-manager binaries.
