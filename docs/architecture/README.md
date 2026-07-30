# Architecture & Design Overview

## Repository Structure (Partial Overview)

```text
.
├── .agents/
│   └── skills/
│       ├── code-linter/
│       │   └── SKILL.md
│       ├── installer-tester/
│       │   └── SKILL.md
│       ├── pipeline-runner/
│       │   └── SKILL.md
│       ├── resolve-pr-comments/
│       │   ├── SKILL.md
│       │   ├── examples.md
│       │   └── reference.md
│       ├── systemd-verifier/
│       │   └── SKILL.md
│       └── test-runner/
│           └── SKILL.md
├── AGENTS.md
├── .github/
│   └── workflows/
│       ├── ci.yml
│       └── ppa-release.yml
├── debian/
│   ├── changelog
│   ├── control
│   ├── copyright
│   ├── postinst
│   ├── postrm
│   ├── prerm
│   ├── rules
│   └── asus-zenbook-configure
├── assets/
│   └── coverage.svg
├── bin/
│   ├── asus-camera-toggle.sh
│   ├── asus-control-center.sh
│   ├── asus_display_mode.py
│   ├── asus-display-mode.sh
│   ├── asus-fan-toggle.sh
│   ├── asus-hotkey-daemon.py
│   ├── asus-screenpad-brightness.sh
│   ├── asus-screenpad-toggle.sh
│   ├── asus-screenshot.sh
│   ├── asus-sound-fix.sh
│   └── asus-touchpad-share.py
├── gnome/
│   └── asus-window-swap@ventura8.github.com/
├── lib/
│   ├── asus-bootstrap.sh
│   ├── asus-common.sh
│   ├── asus-display-mutter.sh
│   ├── asus-notif-icons.sh
│   ├── asus-session.sh
│   ├── install-components.sh
│   ├── install-gnome.sh
│   ├── install-kde.sh
│   ├── install-lxqt.sh
│   ├── install-cinnamon.sh
│   ├── install-mate.sh
│   ├── install-os-detection.sh
│   ├── install-selection.sh
│   ├── install-shared.sh
│   ├── install-xfce.sh
│   └── uninstall-desktop-restore.sh
├── systemd/
│   ├── asus-hotkey-daemon.service
│   ├── asus-sound-fix.service
│   └── asus-touchpad-share.service
├── tests/
│   ├── unit/
│   │   ├── bin/
│   │   │   ├── test_asus_hotkey_daemon.py
│   │   │   ├── test_asus_display_mode.py
│   │   │   └── test_asus_touchpad_share.py
│   │   └── shell/
│   │       ├── test_asus_camera_toggle.py
│   │       ├── test_asus_control_center.py
│   │       ├── test_asus_display_mode.py
│   │       ├── test_asus_fan_toggle.py
│   │       ├── test_asus_screenpad_toggle.py
│   │       ├── test_asus_screenshot.py
│   │       ├── test_asus_sound_fix.py
│   │       ├── test_install.py
│   │       └── test_uninstall.py
│   └── e2e/
│       ├── e2e_utils.py
│       ├── mock/
│       │   ├── bin/
│       │   │   ├── test_asus_hotkey_daemon.py
│       │   │   ├── test_asus_touchpad_share.py
│       │   │   ├── test_asus_screenshot.py
│       │   │   └── test_asus_sound_fix.py
│       │   ├── test_install.py
│       │   └── test_uninstall.py
│       └── real/
│           ├── test_install_real.py
│           └── test_uninstall_real.py
├── tools/
│   ├── make_fake_loginctl.py
│   └── shell_complexity.py
├── scripts/
│   ├── build-and-test.sh
│   └── run_real_e2e.sh
├── install.sh
├── uninstall.sh
```

## Component Architecture

### Hardware Hotkey Listener Daemon (`bin/asus-hotkey-daemon.py`)

- Exclusive-grabs `"Asus WMI hotkeys"` and the AT keyboard when present.
- Swallows firmware-fast AT `Super+P` chords (Display Toggle) and dispatches
  `asus-display-mode.sh`; forwards human held-Super+P so native OSD cycling
  still works. `saw_p` arms only on KEY_P key-down; KEY_P releases stay in the
  pending buffer until Meta-up (flushing on release hard-cycles Mutter with no
  OSD). Never maps AT scancode `0x38` (Left Alt) through the WMI table.
- Forwards unmapped WMI keys (including `KEY_TOUCHPAD_TOGGLE` / `0x6B`) via
  uinput so GNOME keeps native touchpad/touchscreen toggle behavior.
- Watches i2c ASUE* (or other non-AT) keyboards for Shift and also tracks Shift
  on the AT proxy. Exclusive-grabs `"Video Bus"` plus WMI so Fn brightness can
  be filtered; AT `KEY_BRIGHTNESSUP`/`DOWN` are filtered the same way when Shift
  is held. While Shift is held and a writable ScreenPad sysfs node exists,
  swallows brightness and dispatches `asus-screenpad-brightness.sh up|down`.
  Without a ScreenPad node (or helper), brightness is forwarded for the main
  panel. ~80 ms cross-source dedupe for WMI+Video Bus; helper debounce ~80 ms.
  **Alt is not used**: ASUS maps brightness to F4/F5, so Alt+Fn+brightness
  collides with GNOME Alt+F4 on the typing keyboard.
- Feedback after a successful ScreenPad write: GNOME extension `ShowOsd`
  (`--dest org.gnome.Shell`, path `/org/gnome/Shell/Extensions/AsusWindowSwap`;
  OSD targets the ScreenPad monitor — `DP-3` / ScreenPad geometry — not the
  primary panel) → Plasma `org.kde.osdService.brightnessChanged` /
  `showProgress` → LXQt Spec `value`-hint notify via `lxqt-notificationd` (no
  public LXQt OSD D-Bus) → Cinnamon `org.Cinnamon.ShowOSD` on `/org/Cinnamon` →
  MATE Spec `value`-hint notify (no public MATE ShowOSD; never
  `Backlight.SetBrightness` for feedback) → replace-in-place notify
  (`screenpad-brightness` id + sync tag; XFCE stand-in). On ShowOsd miss, clear
  `disable-user-extensions`, `gnome-extensions enable`, retry (≤3×1s); priming
  is best-effort so retries still run. Without a live AsusWindowSwap D-Bus
  export (UUID listed but INACTIVE when user extensions are globally disabled),
  feedback falls to Plasma/LXQt/Cinnamon/MATE/notify.
- Enforces helper debounce via `_is_debounced`: ~50 ms for Display Toggle
  (`asus-display-mode.sh`) and ~300 ms for other helpers, to prevent duplicate
  invocations from kernel WMI double-events.
- At startup, warms `prime_desktop_user_cache()`, then
  `prime_gnome_window_swap_extension()` (clear `disable-user-extensions`, then
  session-bus `gnome-extensions enable` when the UUID is in gsettings but Shell
  has not exported `/org/gnome/Shell/Extensions/AsusWindowSwap`; honor enable
  exit status; wait ≤2s), then `prime_topology_cache()` so Mutter D-Bus topology
  detect has session env. Queries
  `asus_display_mode.py --detect-topology-map` (Mutter) and falls back
  to `xrandr --query` geometry when Mutter is unavailable (but does not replace
  a Mutter cache with xrandr pixels). Each monitor entry includes Mutter `index`
  so `GetFocusedMonitor` aligns with bounce-step realignment. Computes a
  geometry-aware bounce path with jitter-tolerant ordering for horizontal,
  vertical, and mixed layouts. Bounce step resets only when the monitor count
  changes. On GNOME each hop first uses the
  `asus-window-swap@ventura8.github.com` Shell extension
  (`GetFocusedMonitor` / `MoveFocused`); edge no-ops retry the opposite
  direction on the same press, then fall back to virtual Super+Shift+Arrow when
  both return false. When D-Bus is missing, the deferred worker re-runs extension
  enable (fail-fast) and retries once before uinput. Virtual chords are used only
  when the extension remains unavailable after that. Before each hop the bounce
  phase is realigned to the focused window's monitor so a window already on the
  last display moves on the first press instead of a GNOME Down no-op. Cached
  topology applies a synchronous hop on the hotkey thread only when GNOME Window
  Swap extension D-Bus is already ready; KDE/XFCE/LXQt/Cinnamon/MATE
  `wmctrl`/`xdotool` moves (and GNOME when the extension is not ready) use a
  deferred worker that
  **reuses already-usable monitors** (never re-detect Mutter on every deferred
  hop) with
  `attempts=1`. D-Bus readiness caches True for 30s and False for 0.5s — do not
  stick misses for the positive TTL. Empty cache also uses a deferred
  detect+swap worker. Workers commit `next_step` only after a successful move.
- Executes monitor/topology probes in the active desktop user session
  context (D-Bus + `XDG_RUNTIME_DIR`, plus `DISPLAY` / `WAYLAND_DISPLAY` /
  `XDG_CURRENT_DESKTOP` when resolvable from the session leader environ)
  even though the daemon itself runs as root.
- Moves windows via `wmctrl`/`xdotool` on KDE/XFCE/LXQt/Cinnamon/MATE; GNOME
  uses the extension / uinput path above. Non-GNOME feature parity is geometric
  move only (no GNOME Shell Window Swap extension port — Mutter Meta / Muffin /
  Marco are not drop-ins). Gaps vs GNOME (e.g. focused-monitor D-Bus) are
  accepted honestly. Never blocks `detect_swap_topology_map` on the hotkey
  event thread.
- Executes helper scripts for fan mode toggle, ScreenPad toggle/brightness,
  camera privacy toggle, Control Center, screenshot UI, and display OSD.

### Cross-Desktop Settings Launcher (`bin/asus-control-center.sh`)

- Resolves the active user session and opens the matching desktop's native Settings
  app on GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, and MATE.
- GNOME tries `org.gnome.Settings` D-Bus Activate first; other families launch
  family-specific settings CLIs or `.desktop` files.

### Localization

- Bash and Python UI surfaces share GNU gettext domain
  `asus-zenbook-linux-tools`. Source catalogs under `po/` cover the 99 codes in
  `po/SUPPORTED_LANGUAGES`; package and installer paths compile them to FHS
  `share/locale/<code>/LC_MESSAGES/` directories.
- Language lookup uses test-only `ASUS_TEST_MODE=1` + `ASUS_UI_LANG`, then the
  active user's session locale (`LC_MESSAGES` → `LANG` → `LANGUAGE`), with English
  msgids as the soft fallback.

### Display Projection Mode Switcher (`bin/asus-display-mode.sh`)

- Prefer native monitor OSD via sticky Super+P (`ydotool` on Wayland/X11;
  `xdotool` on X11 when ydotool is missing). Works with GNOME and KDE when
  Super/Meta+P opens the compositor switcher.
- Fall back to Mutter D-Bus profile cycling (**GNOME only**) through
  `asus_display_mode.py`; on KDE/XFCE/LXQt/Cinnamon/MATE skip Mutter and open
  DE display settings (`gnome-control-center display`, Plasma `kcm_kscreen`,
  `xfce4-display-settings`, `lxqt-config-monitor`, `cinnamon-settings display`,
  `mate-display-properties`). **Why not Mutter on LXQt/Cinnamon/MATE:**
  `org.gnome.Mutter.DisplayConfig` is Shell/mutter-owned; LXQt compositors,
  Cinnamon Muffin, and MATE Marco do not expose our GNOME cycle path, and
  calling it risks a leftover GNOME session bus applying wrong layouts. LXQt
  Global Keys also bind Meta+P → `asus-display-mode.sh` (runtime still prefers
  ydotool/xdotool).
- Window swap on LXQt/Cinnamon/MATE stays `wmctrl`→`xdotool` (no GNOME Shell
  extension port).
- Session type and desktop family come from `lib/asus-session.sh`
  (`loginctl` Type + leader `/proc/<pid>/environ`, then
  `systemctl --user show-environment`). Missing runtime dir is status **1**;
  transport/timeout failures are status **2** and set a negative-cache skip
  flag so broken session sockets cannot stall helpers.
- Sticky Super session: first press holds Super and taps P; later presses
  within the idle window only tap P; idle timeout releases Super first (apply),
  then clears Shift/Ctrl/Alt L+R. Esc during an active sticky session: the
  hotkey daemon must **not** forward AT Esc; it calls `asus-display-mode.sh
  --cancel-osd`, which sets `${prefix}.cancel`, drops `.session` before injecting
  Esc, waits briefly, then Super-up on the same ydotool/xdotool stream that
  holds Super so idle watchdog `_release_osd_modifiers` (apply-only) cannot race
  cancel. The daemon releases AT-proxy Super/Shift/Ctrl/Alt ups and suppresses new
  `asus-display-mode.sh` dispatches for ~450ms
  (`ASUS_DISPLAY_OSD_ESC_COOLDOWN_SECS`) so firmware Super+P echo cannot
  re-open the OSD. State lives under `/run/asus-zenbook-notif/$uid/` (daemon
  `ProtectHome=read-only` blocks `/run/user`). If the internal watchdog cannot
  start after opening the OSD, the helper dismisses modifiers and fails closed
  instead of leaving Super latched. Linux Esc autorepeat (`value==2`) is
  swallowed while a cancel is in progress so repeat events are not forwarded to
  the compositor. Missing session still releases
  after idle so Super cannot stick.
  `install-gnome.sh` keeps `switch-monitor=['<Super>p']`, clears custom
  `<Super>p`, and does not bind stock `F8`.
- `asus_display_mode.py` remains the Mutter topology/profile backend used by
  the hotkey daemon for window-swap detection.

### Screenshot / Share (`bin/asus-screenshot.sh`)

- GNOME: `ShowScreenshotUI` when present, else `InteractiveScreenshot`, else
  Super+Shift+S / Print via `ydotool`/`xdotool` (soft-ensures GNOME
  `show-screenshot-ui` includes Super+Shift+S for Fn+F11 / Share), else portal.
  Ubuntu 26.04+ peers often get AccessDenied on interactive D-Bus capture.
- KDE: Spectacle `--region`
- XFCE: `xfce4-screenshooter -r`
- LXQt: `screengrab -r`
- Cinnamon: `gnome-screenshot --area`
- MATE: `mate-screenshot --area`
- Last resort: xdg-desktop-portal Screenshot (reduced UX)
- Touchpad Share invokes the same helper; its unit must allow `runuser` (same
  hardening rules as the hotkey daemon).

### Desktop shortcut installers

- Component `DESKTOP` (compat alias `GNOME`) dispatches by detected DE:
  `lib/install-gnome.sh`, `lib/install-kde.sh`, `lib/install-xfce.sh`,
  `lib/install-lxqt.sh`, `lib/install-cinnamon.sh`, `lib/install-mate.sh`.
- Default “all” includes `DESKTOP` only for gnome/kde/xfce/lxqt/cinnamon/mate sessions.
- LXQt upserts Exec shortcuts in `~/.config/lxqt/globalkeyshortcuts.conf`
  (`XF86Display`, `Meta+P`, `Meta+F12`, `Meta+Shift+S`) with atomic backup and
  best-effort `pkill -HUP lxqt-globalkeysd` (re-login warning on reload miss;
  do not fail install solely on HUP).
- Cinnamon binds customs under `org.cinnamon.desktop.keybindings` (clears
  conflicting `video-outputs` first). MATE uses relocatable
  `org.mate.control-center.keybinding` slots. Uninstall restores via
  `lib/uninstall-desktop-restore.sh`.

### D-Bus Notification Overwriting Subsystem

- All toggle scripts (`asus-camera-toggle.sh`, `asus-fan-toggle.sh`,
  `asus-screenpad-toggle.sh`, `asus-screenpad-brightness.sh`) store and re-use
  active D-Bus replacement IDs in
  `/run/asus-zenbook-notif/$user_id/.asus_notif_<tag>.id`
  (not under `/run/user`, which systemd `ProtectHome=` makes read-only).
- ScreenPad brightness feedback order: GNOME extension `ShowOsd` on
  `/org/gnome/Shell/Extensions/AsusWindowSwap` via `--dest org.gnome.Shell`
  (bar drawn on the ScreenPad monitor: connector `DP-3`, else matching
  `3840x1100` / `1920x550` geometry, else primary if ScreenPad is absent) →
  Plasma `org.kde.osdService` (`brightnessChanged` or `showProgress`) →
  LXQt Spec `value`-hint notify via `lxqt-notificationd` (no public LXQt OSD
  D-Bus; panel volume/backlight plugins are private) → Cinnamon
  `org.Cinnamon.ShowOSD` (`a{sv}` icon + level 0–100 on `/org/Cinnamon`) →
  MATE Spec `value`-hint notify (no public ShowOSD; never call
  `org.mate.PowerManager.Backlight.SetBrightness` for ScreenPad feedback) →
  replace-in-place notify with tag `screenpad-brightness` (XFCE and other; id
  file under `/run/asus-zenbook-notif`). Miss path clears
  `disable-user-extensions` then enables the UUID before short ShowOsd retries.
  Private `org.gnome.Shell.ShowOSD` is not used (`AccessDenied`). Notify is never
  emitted when an OSD succeeded.
- Replaces on-screen popups in place without stack flooding, featuring
  dynamic thermal profile icons (`power-profile-performance`,
  `power-profile-balanced`, `power-profile-power-saver`) for fan mode
  switches. `asus-fan-toggle.sh` prefers `powerprofilesctl` so
  power-profiles-daemon and asus-wmi stay aligned, falling back to
  `throttle_thermal_policy` when PPD is unavailable.

### Touchpad Share Gesture Handler (`bin/asus-touchpad-share.py`)

- Reads raw touch events from `"touchpad"` `evdev` nodes.
- Identifies tap releases in the top-left 20% corner of touchpad
  coordinates within 0.7 seconds.
- Invokes `asus-screenshot.sh` so Share matches the WMI screenshot path on
  GNOME, KDE, XFCE, LXQt, Cinnamon, and MATE.

### Cirrus Smart Amp Audio Initializer (`bin/asus-sound-fix.sh`)

- Dynamically scans `/dev/snd/hwC*D*` and matches
  `/proc/asound/card*/codec#*` for `ALC294` or `Cirrus` smart amp hardware.
- Applies initialization register verbs via `hda-verb`, falling back to the
  bundled `asus_hda_verb.py` helper when the distro does not package
  `alsa-tools`/`hda-verb` (Rocky/RHEL).

### Systemd Services & Wake Hooks

- Manages background daemons with non-cyclic dependencies
  (`WantedBy=multi-user.target`).
- `asus-sound-fix.service` uses `ProtectSystem=strict` with
  `ReadWritePaths=-/dev/snd` for HDA verb access (do not add `DeviceAllow=char-snd`;
  it denies `/dev/snd/hwC*` on current systemd).
- Re-applies sound fix upon wake from suspend/sleep via
  `/lib/systemd/system-sleep/asus-sound-fix`.

### Installer Wizard (`install.sh`) & Uninstaller (`uninstall.sh`)

- Interactive ncurses component checklist (keyboard + mouse, OS accent color),
  including piped installs via `/dev/tty`.
- Validated text fallback when the TUI is unavailable (supports
  component names, numeric indexes, and `all`).
- Explicit abort semantics: `Cancel`/`Esc` aborts installation, and
  missing controlling terminals default to all components unless
  `NONINTERACTIVE_CHOICE` is provided.
- Detects the host OS family to select distro-appropriate package-manager
  commands for Debian/Ubuntu families (apt/apt-get), Fedora/RHEL families
  (dnf/yum), openSUSE/SUSE families (zypper), and Arch families (pacman),
  with SteamOS mapped through Arch-family OS detection (`ID=steamos`).
  Optional RPM deps: Rocky/RHEL skip unpackaged `ydotool` and `alsa-tools`
  (Fedora still installs both; openSUSE uses `hda-verb`). SOUND on Rocky/RHEL
  still installs automatically via bundled `asus_hda_verb.py` when system
  `hda-verb` is absent.
- Component `DESKTOP` (alias `GNOME`) dispatches to `install-gnome.sh`,
  `install-kde.sh`, `install-xfce.sh`, `install-lxqt.sh`, `install-cinnamon.sh`,
  or `install-mate.sh` from the detected desktop family.
- CI `--compat-only` distro matrix lanes run `scripts/run_distro_install_smoke.sh`
  (not the coverage-gate `--tests-only` stage): package availability probes
  (including PyGObject `python3-gi` / `python3-gobject` / `python-gobject`),
  product shell/Python checks, multi-DE family helpers, DESTDIR file
  install/uninstall, DESKTOP configure/uninstall cycles for
  gnome/kde/xfce/lxqt/cinnamon/mate with stubbed session bus and CLI tools (Window Swap
  extension tree + enable mark, KDE helper `.desktop`s, XFCE xfconf backups,
  LXQt `globalkeyshortcuts.conf` Exec lines), and
  (in-container) a live package cycle that purges sentinel deps then runs
  `install.sh`/`uninstall.sh` with `SKIP_PKG_*=0` so package recording/removal is
  not skipped merely because CI images preinstall those packages. Desktop and
  live-pkg helpers are split into `scripts/distro_install_smoke_desktop.sh` and
  `scripts/distro_install_smoke_live_pkg.sh`.
- **Always-on nine distro lanes:** Ubuntu 26.04, Debian trixie, Fedora 44, Rocky 10,
  openSUSE Tumbleweed, Arch latest, openSUSE Leap 16.0, AlmaLinux 10, Manjaro base.
  Empty `ASUS_CI_DE_FAMILY` = stub/CLI. Full-DE family variants run in the same
  push/PR CI job (`distro-full-de`), not nightly. Rocky/Alma exclude unpackaged
  cinnamon/mate/lxqt cells. Alma/RHEL 10 XFCE builds pinned `xfconf` from source.
  Rocky 10 / Alma KDE use `kf6-kconfig` (`kwriteconfig6`).
- **Desktop proof honesty tiers:** (1) Default stub/CLI + curated full-DE packages =
  install wiring / CLI-schema smoke only — not live panels. (2) Always-on limited
  nested proofs — CI installs Xvfb / gnome-shell+mutter / ydotool and attempts
  nested start; soft-skip only after install+start fails for environmental
  reasons (never missing apt packages) — still not live panels.
  (3) True DRM/panel/DM (privileged or self-hosted KVM) is out of scope for
  standard Actions Docker and must never gate PRs as a claim of live panels.
  **GDM/SDDM** greeter automation in standard GH Actions Docker is locked **NO**.
- **MoveFocused / OSD proof tiers:** (1) unit/mocked markers already covered;
  (2) nested MoveFocused limited E2E (always-on; install Shell deps; assert Shell
  starts; soft-skip only on env start failure); (3) sticky-marker/ydotool
  (always-on; install ydotool+Xvfb; soft-skip only when uinput/injection fails
  after packages present); (4) true laptop Mutter OSD dialog / hardware
  Fn/ScreenPad — still **NO** on standard Actions.
- **Experimental DRM/panel sketch (doc only):** a privileged container or
  self-hosted KVM + systemd-nspawn could approach seat/DRM panel proof; do not
  implement as a PR gate without separate approval. Cross-link honesty tier 3.
- Records packages newly installed by `install.sh` under
  `/var/lib/asus-zenbook-linux-tools/installed-packages` and removes those
  packages during `uninstall.sh` (use `SKIP_PKG_REMOVE=1` to skip). When no
  record exists, uninstall removes no packages unless
  `ASUS_UNINSTALL_FALLBACK_PKGS=1` (known project deps only; never base
  interpreters `python3` / `python`). Staged `DESTDIR` runs default
  `SKIP_PKG_REMOVE=1` when that variable is unset.
- Touchpad / ydotool: creates group `asus-uinput`, installs
  `udev/99-asus-uinput.rules` (`/dev/uinput` mode `0660`), and records session
  users in `asus-uinput-group-users` (legacy `input-group-users` is revoked on
  uninstall). This is narrower than adding users to group `input`.
- KDE shortcut backups live under `${STATE_DIR}/$uid/kde/` so KDE cleanup cannot
  remove GNOME `orig_*` files in the same uid directory.
- Configures GNOME keybindings (`show-screenshot-ui`, `control-center`, and
  `switch-video-mode`) via `gsettings` under the active D-Bus session.
- Backup and atomic rollback of original keybindings during installation and
  uninstallation. Optional keys (`switch-video-mode`, Mutter `switch-monitor`)
  restore only when backups exist so hosts without those schemas still
  uninstall cleanly.

### Debian / Launchpad PPA packaging (`debian/`)

- Native `3.0` package `asus-zenbook-linux-tools` ships payload under
  `/usr/share/asus-zenbook-linux-tools/` plus `/usr/sbin/asus-zenbook-configure`.
- `postinst` runs the interactive wizard (same selection as `install.sh`) only on
  first-time configure (empty previous-version argument) or when
  `DEBCONF_RECONFIGURE=1`, and only when a TTY is available; upgrades skip the
  wizard unless reconfigure is requested. Without a TTY, it prints
  `dpkg-reconfigure` / `asus-zenbook-configure`.
- Runtime deploy still uses `/usr/local/bin` and
  `/usr/local/lib/asus-zenbook-linux-tools` for parity with `install.sh`.
- Tag-triggered [`.github/workflows/ppa-release.yml`](../../.github/workflows/ppa-release.yml)
  uploads a signed source package to `ppa:ventura8/asus-zenbook-linux-tools`
  for **resolute** only (Python ≥ 3.13). CI `deb-package` and PPA build jobs tee
  apt dependency installs to `reports/distro-logs/` for post-mortem review.

### Shell Complexity & Quality Assurance (`tools/shell_complexity.py`)

- Analyzes cyclomatic complexity for bash scripts with A-F grade ratings.
- Enforces **Rank A** (CCN <= 5) on all functions in shell scripts across
  the repository.
- Enforces >= 90% line coverage for shell scripts measured via `kcov`.
- **File size**: [`scripts/check_file_size_limits.py`](../../scripts/check_file_size_limits.py)
  enforces a **600-line** maximum on scoped product and test sources (`bin/`, `lib/`, `tests/`,
  `tools/`, `scripts/`, `gnome/`, `docker/`, root installers, Debian maintainer scripts).
  Oversized files must be **split** (helpers, sibling modules, narrower test files). Never delete
  comments, docstrings, or spacing only to pass the gate.
