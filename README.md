# 🚀 ASUS ZenBook Linux Tools

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![OS: Linux](https://img.shields.io/badge/OS-Linux%20Multi--DE-orange.svg)](https://www.kernel.org/)
[![Python: 3.13](https://img.shields.io/badge/Python-3.13-blue.svg)](https://www.python.org/)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-4EAA25.svg)](https://www.gnu.org/software/bash/)
[![Coverage](assets/coverage.svg)](assets/coverage.svg)

A complete utility suite and interactive installer to fix hardware hotkeys,
Cirrus audio amplifiers, dual-screen window swapping, and touchpad gestures
on **ASUS ZenBook** laptops running Linux. The installer targets Ubuntu,
Debian, Fedora, Rocky Linux, openSUSE, and Arch Linux (including Ubuntu
flavours such as Xubuntu/Kubuntu/Lubuntu via `ID=ubuntu`). SteamOS maps to the
Arch package family for detection; it is not a separate CI runtime lane.

---

## ⚡ Installation

### Ubuntu 26.04 (Resolute) / Resolute-based Linux Mint (PPA)

Preferred on **Ubuntu 26.04 (Resolute)** and **Linux Mint editions based on
Ubuntu 26.04 Resolute**. Other releases use the [generic one-liner](#one-liner-any-supported-distro).

```bash
sudo add-apt-repository ppa:ventura8/asus-zenbook-linux-tools &&
  sudo apt update &&
  sudo apt install asus-zenbook-linux-tools
```

The package runs the same interactive component wizard as `install.sh`
(WMI, TOUCHPAD, SOUND, DESKTOP). Re-run later with
`sudo dpkg-reconfigure asus-zenbook-linux-tools` or `sudo asus-zenbook-configure`.

### GitHub Release packages (Fedora, Rocky, openSUSE, Arch)

Each `v*` tag attaches native packages and a **`SHA256SUMS`** manifest to the
[GitHub Release](https://github.com/ventura8/asus-zenbook-linux-tools/releases).
Download the asset for your distro **and** `SHA256SUMS` from the same release,
verify the checksum for that asset, then install.

> [!NOTE]
> `SHA256SUMS` is **same-origin integrity** only: the manifest and release assets come from the
> same GitHub tag. It is not an independently trusted detached signature or public-key release
> authentication. Bare `sha256sum -c SHA256SUMS` needs every listed asset on disk.

```bash
grep -F 'your-asset-filename' SHA256SUMS | sha256sum -c -

# Fedora / Rocky / Alma / RHEL family
sudo dnf install ./asus-zenbook-linux-tools-*.rpm

# openSUSE (checksum-verified RPM; zypper resolves dependencies)
sudo zypper install --allow-unsigned-rpm ./asus-zenbook-linux-tools-*.rpm

# Arch / Manjaro
sudo pacman -U ./asus-zenbook-linux-tools-*.pkg.tar.zst

# AppImage (after sha256sum -c)
sudo ./asus-zenbook-linux-tools-*-x86_64.AppImage

# Flatpak (system scope matches sudo run)
sudo flatpak install --system ./asus-zenbook-linux-tools-*.flatpak
sudo flatpak run org.github.ventura8.AsusZenBookLinuxTools

# Snap (classic local install requires --dangerous only after checksum verification)
sudo snap install --dangerous ./asus-zenbook-linux-tools_*.snap
```

Portable **installer bundles** (AppImage, Flatpak, Snap) are also attached for
experiments; they run `asus-zenbook-configure` with the bundled payload and still
require root for systemd/udev deployment. The Flatpak bundle deploys to the host
via `/run/host` (`--filesystem=host`); native packages are recommended.

### One-Liner (any supported distro)

```bash
curl -fsSL \
  https://raw.githubusercontent.com/ventura8/asus-zenbook-linux-tools/v1.0.4/install.sh.sha256 \
  -o install.sh.sha256 &&
  curl -fsSL \
  https://raw.githubusercontent.com/ventura8/asus-zenbook-linux-tools/v1.0.4/install.sh \
  -o install.sh &&
  sha256sum -c install.sh.sha256 &&
  sudo bash ./install.sh
```

> [!NOTE]
> `install.sh.sha256` is **same-origin integrity** only: both the checksum and
> `install.sh` come from the same GitHub tag. It is not an independently trusted
> detached signature or public-key release authentication.
>
> `sudo bash ./install.sh` opens an ncurses component checklist (keyboard + mouse)
> when a terminal is available, otherwise manual text selection from `/dev/tty`.
> Piped installs (`curl … | sudo bash`) also prompt on `/dev/tty` when a terminal
> is available.
>
> [!IMPORTANT]
> This quick-start is interactive. For CI/scripts, use the headless section in
> `docs/INSTRUCTIONS.md`. Component steps that hang are bounded so the install
> reports failure instead of stalling forever.

---

## 🌟 Overview

Many modern ASUS ZenBooks (especially Duo / OLED models) suffer from missing
driver hooks under Linux out-of-the-box:

* Internal speakers remain silent due to uninitialized ALC294 / Cirrus smart
  amplifiers.
* Secondary screen (ScreenPad) hotkeys, fan profile switches, and camera
  privacy toggles do nothing.
* Capacitive touchpad corner gestures (like the Share key) are ignored.

This repository provides lightweight `evdev` event daemons, `hda-verb` audio
initializers, and an **interactive terminal wizard** that lets you selectively
install only what you need.

---

## ✨ Features

### 🔊 1. Cirrus Smart Amp Sound Fix

* **The Problem:** Internal speakers produce no sound even when ALC294 hardware
  is detected.
* **The Fix:** Sends hardware initialization verbs via `hda-verb` (or the
  bundled `asus_hda_verb.py` fallback on distros without `alsa-tools`) dynamically
  on boot and automatically reapplies them when waking up from **sleep,
  suspend, or hibernate**.

### 🖥️ 2. Hardware Hotkey & ScreenPad Daemon (`asus-hotkey-daemon`)

Hooks into `Asus WMI hotkeys` (and related input) with ~300 ms helper debounce
(Display Toggle uses ~50 ms so Super+P cycles match native speed):

* **Window Swap Key:** Bounce the focused window across monitors from cached
  Mutter/`xrandr` topology. On GNOME, prefer the Window Swap Shell extension
  (`MoveFocused`); fall back to Super+Shift+Arrow via uinput. On
  KDE/XFCE/LXQt/Cinnamon/MATE, move with `wmctrl`/`xdotool` on a deferred worker
  (not on the hotkey event thread). Those families use geometric move only —
  there is no GNOME Shell extension port (Mutter Meta / Muffin / Marco are not
  drop-ins for that path).
* **ScreenPad Toggle:** On/Off via `asus-screenpad-toggle.sh` with sysfs
  write-back verify before notify (UX582HS keycap glyphs when templates exist).
* **ScreenPad Brightness:** Hold **Shift** and press Fn brightness to step
  ScreenPad backlight (`asus-screenpad-brightness.sh`). Plain Fn brightness still
  adjusts the main panel. **Do not use Alt** for this chord: on ASUS layouts the
  brightness keys are F4/F5, so Alt+Fn+brightness is Alt+F4/F5 and GNOME closes
  the focused window. Feedback after a successful write: GNOME Shell `ShowOsd`
  (DESKTOP extension) → Plasma `org.kde.osdService` → LXQt Spec `value`-hint
  notify via `lxqt-notificationd` (no public LXQt OSD D-Bus) → Cinnamon
  `org.Cinnamon.ShowOSD` → MATE Spec `value`-hint notify (no public MATE
  ShowOSD) → replace-in-place notify (XFCE and other). Requires writable
  `asus_screenpad` / `asus::screenpad`; without
  it the chord is not swallowed. Steps clamp to a floor of 1 (Off stays on toggle).
* **Installer Feedback:** WMI hotkey daemon startup failures are reported
  explicitly so a broken install is never marked successful.
* **Fan Mode Cycle:** Prefers `powerprofilesctl` (power-profiles-daemon) so CPU
  and platform profiles stay synced, with sysfs `throttle_thermal_policy`
  fallback. Cycles Balanced, Performance, and Quiet with D-Bus popups using
  dynamic icons (`power-profile-performance`, `power-profile-balanced`,
  `power-profile-power-saver`).
* **Camera Privacy:** Toggles ASUS WMI camera sysfs; reads the node back and
  fails closed if the value does not match before notifying.
* **Display Toggle:** ZenBook firmware often emits a short Super+P on the AT
  keyboard (WMI `0x38` may be absent). The daemon exclusive-grabs AT, swallows
  that firmware chord, and runs `asus-display-mode.sh`. The helper opens sticky
  native OSD via Super+P (`ydotool` first, then X11 `xdotool`); GNOME may fall
  back to Mutter profile cycling, else DE display settings. On
  KDE/XFCE/LXQt/Cinnamon/MATE, skip Mutter (`org.gnome.Mutter.DisplayConfig` is
  Shell-owned; Cinnamon Muffin / MATE Marco are not drop-ins) and open DE
  settings (`lxqt-config-monitor`, `cinnamon-settings display`,
  `mate-display-properties`). LXQt also binds Meta+P in Global Keys to the same
  helper. Esc during sticky OSD cancels on the same injector device (does not
  hard-apply). Pure Debian without `ydotool` falls back to
  `xdotool`/Mutter/settings as appropriate.
* **Single-ID Notification Overwriting:** Replaceable notification IDs live under
  `/run/asus-zenbook-notif/$UID/` (also sticky Display Toggle OSD state) so
  popups update in place without flooding the stack.

### 🖐️ 3. Touchpad Share Gesture Listener

* Monitors raw `evdev` touch coordinates on capacitive ASUS touchpads
  (`BTN_TOUCH` lifecycle).
* Tapping the **top-left Share icon** triggers `asus-screenshot.sh` (GNOME Shell
  D-Bus, then Super+Shift+S / Print via `ydotool`/`xdotool`, then portal /
  Spectacle / XFCE / LXQt `screengrab` / Cinnamon `gnome-screenshot` / MATE
  `mate-screenshot` fallbacks).

### ⚙️ 4. Multi-Desktop Keybindings & Control Center Launcher

* **Display Toggle / XF86Display:** AT firmware Super+P is filtered to
  `asus-display-mode.sh` (sticky OSD path above). Stock `F8` stays unbound.
  Mutter keeps `switch-monitor=['<Super>p']` for human-held Super+P.
* **F11 / Touchpad Share:** Mapped to `asus-screenshot.sh` (GNOME / KDE / XFCE /
  LXQt / Cinnamon / MATE interactive region capture).
* **Touchpad / Touchscreen Toggle:** Native path (daemon forwards unmapped WMI
  `KEY_TOUCHPAD_TOGGLE`).
* **Fn+F12 / MyASUS Key:** `asus-control-center.sh` opens the active desktop's
  native Settings app (GNOME Settings Activate, then family-specific settings CLIs).
* **Localized UI:** Setup, notifications, display labels, and shortcuts follow the
  desktop session language automatically via GNU gettext.

---

## 💻 Tested Hardware & Distributions

* Laptops: ASUS ZenBook Duo series (UX582H, OLED Duo series)
* Distributions: Ubuntu, Debian, Fedora, Rocky Linux, openSUSE, and Arch Linux
  (SteamOS uses Arch-family package detection; not a dedicated CI image).
  Ubuntu flavours (Xubuntu/Kubuntu/Lubuntu) and Mint (Cinnamon/MATE) share the
  apt path; select **DESKTOP** only when running GNOME, KDE Plasma, XFCE, LXQt,
  Cinnamon, or MATE.
* Compatibility matrix lanes run DESTDIR install/uninstall smoke plus package
  probes. Images preinstall deps for imports; container smoke still purges
  sentinel packages and runs a live `install.sh`/`uninstall.sh` package cycle.
* Desktop Environments (Wayland and X11 where the DE supports them):
  * Full helper coverage: GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, MATE
  * Display Toggle: AT Super+P swallow → sticky OSD (`ydotool` / X11 `xdotool`);
    Mutter cycle on GNOME only; KDE/XFCE/LXQt/Cinnamon/MATE → DE settings
    (`lxqt-config-monitor` / `cinnamon-settings display` /
    `mate-display-properties`; LXQt Global Keys also binds Meta+P)
  * Screenshot / Share: GNOME Shell, Spectacle, `xfce4-screenshooter`,
    `screengrab -r` (LXQt), `gnome-screenshot --area` (Cinnamon), or
    `mate-screenshot --area` (MATE)
  * Window swap: GNOME extension / uinput chords; KDE/XFCE/LXQt/Cinnamon/MATE
    `wmctrl`/`xdotool` only (no Shell extension port)
  * Desktop shortcuts install component: `DESKTOP` (alias `GNOME`) via
    `install-gnome.sh` / `install-kde.sh` / `install-xfce.sh` /
    `install-lxqt.sh` / `install-cinnamon.sh` / `install-mate.sh`
    (LXQt edits `~/.config/lxqt/globalkeyshortcuts.conf`; Cinnamon/MATE use
    gsettings customs)

---

## 🔍 Service Status & Troubleshooting

To verify that services are running or check event logs:

```bash
# Check status of hotkey daemon
sudo systemctl status asus-hotkey-daemon.service

# Check status of sound fix
sudo systemctl status asus-sound-fix.service

# Stream touchpad gesture logs in real-time
sudo journalctl -u asus-touchpad-share.service -f
```

---

## 🧹 Uninstallation

Remove installed scripts, services, restored GNOME keybindings, and system packages that
this project previously installed:

```bash
sudo ./uninstall.sh
```

`install.sh` records newly installed packages under
`/var/lib/asus-zenbook-linux-tools/installed-packages`. Uninstall removes that recorded set.
If no record exists, uninstall removes no packages unless
`ASUS_UNINSTALL_FALLBACK_PKGS=1` (known project deps only; never base interpreters).
Set `SKIP_PKG_REMOVE=1` to keep packages when needed. Staged `DESTDIR` uninstalls
default `SKIP_PKG_REMOVE=1` when that variable is unset.

---

## 🧪 Distribution Matrix Validation

Lint checks are executed in a dedicated Docker image based on `python:3.13-slim`:

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/lint-in-docker.sh 2>&1 | tee reports/distro-logs/lint-in-docker.log
  exit "${PIPESTATUS[0]}"
)
```

The canonical lint wrapper always runs in Docker as well:

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run-lints.sh 2>&1 | tee reports/distro-logs/lints.log
  exit "${PIPESTATUS[0]}"
)
```

Docker image definitions are versioned in this repository under:

* `docker/images/lint/python-3.13-slim.Dockerfile`
* `docker/images/tests/ubuntu-26.04.Dockerfile`
* `docker/images/tests/debian-trixie.Dockerfile`
* `docker/images/tests/fedora-44.Dockerfile`
* `docker/images/tests/rocky-10.Dockerfile`
* `docker/images/tests/opensuse-tumbleweed.Dockerfile`
* `docker/images/tests/archlinux-latest.Dockerfile`
* `docker/images/tests/opensuse-leap-16.0.Dockerfile`
* `docker/images/tests/almalinux-10.Dockerfile`
* `docker/images/tests/manjarolinux-base-latest.Dockerfile`

Each image now bakes Python dependencies from `pyproject.toml` and
`poetry.lock` into a dedicated image layer, so dependency installs are cached
and only rebuilt when those files change.

To exercise the test-only verification flow inside containers for the supported Linux
families, run:

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run_docker_matrix.sh --dry-run 2>&1 |
    tee reports/distro-logs/matrix-dry-run.log
  exit "${PIPESTATUS[0]}"
)
```

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run_docker_matrix.sh 2>&1 | tee reports/distro-logs/matrix.log
  exit "${PIPESTATUS[0]}"
)
```

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run_docker_matrix.sh --parallel 2>&1 |
    tee reports/distro-logs/matrix-parallel.log
  exit "${PIPESTATUS[0]}"
)
```

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run_docker_matrix.sh --compat-only 2>&1 |
    tee reports/distro-logs/matrix-compat-only.log
  exit "${PIPESTATUS[0]}"
)
```

If you interrupt the matrix run (`Ctrl+C`), the runner now force-stops all
active matrix containers before exiting.

The canonical test wrapper always runs this Docker matrix flow:

```bash
(
  set -euo pipefail
  mkdir -p reports/distro-logs
  ./scripts/run-tests.sh 2>&1 | tee reports/distro-logs/tests.log
  exit "${PIPESTATUS[0]}"
)
```

The matrix targets nine always-on lanes: `ubuntu:26.04`, `debian:trixie`,
`fedora:44`, `rocky:10`, `opensuse/tumbleweed`, `archlinux:latest`,
`opensuse/leap:16.0`, `almalinux:10`, and `manjarolinux/base:latest`. Full-DE
family variants (`ASUS_CI_DE_FAMILY`) run in the same CI pipeline
(`distro-full-de` job), not nightly. Arch/Manjaro image builds retry
`pacman -Syu`/`-S` on rolling-mirror 404s; Arch pins non-geo pacman mirrors.
Rocky/Alma kcov builds install `libcurl-devel` matching the installed
libcurl NEVRA (`el10-kcov-libcurl.sh`). Local debug: `--distro` and/or `--de-family`.

Recommended split:

* Canonical coverage gate (single distro):

  ```bash
  (
    set -euo pipefail
    mkdir -p reports/distro-logs
    ./scripts/run_docker_matrix.sh --coverage-gate 2>&1 |
      tee reports/distro-logs/matrix-coverage-gate.log
    exit "${PIPESTATUS[0]}"
  )
  ```

* Cross-distro compatibility checks (no repeated coverage gating):

  ```bash
  (
    set -euo pipefail
    mkdir -p reports/distro-logs
    ./scripts/run_docker_matrix.sh --compat-only 2>&1 |
      tee reports/distro-logs/matrix-compat-only.log
    exit "${PIPESTATUS[0]}"
  )
  ```

`./scripts/build-and-test.sh --full` runs this same split automatically:
lint waves in Docker (cheap ∥ heavy) ∥ Debian `.deb` smoke with
`DEB_BUILD_OPTIONS=nocheck` (no host unit tests), then canonical
**debian:trixie** coverage-gate (kcov ∥ python), then package-family
compatibility matrices (`--distro-family`).

Mocked/CI E2E tests use a strict per-test timeout budget of 20-30 seconds. Any
test command that exceeds its timeout is treated as a failed test.

`./scripts/build-and-test.sh` orchestrates Docker-only lint and test stages on
the pipeline host (never `run-lints.sh` / unit / kcov / e2e on the host).
Only real-system end-to-end tests are host-executed via
`sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh`.

## 🧪 Advanced Test Overrides

`bin/asus-display-mode.sh` supports optional runtime-root overrides that keep
tests and sandbox runs off real system paths:

* `DBUS_BUS_ROOT` (default: `/run/user`) controls D-Bus session socket lookup only.
* `NOTIF_ID_ROOT` (default: `/run/asus-zenbook-notif`) stores notification replace IDs
  and display-mode sticky OSD session state.
* `SYS_CLASS_ROOT` (default: `/sys/class`) controls where ScreenPad backlight nodes
  are probed.
* `SYS_PLATFORM_ROOT` (default: `/sys/devices/platform`) controls camera-toggle
  (`asus-camera-toggle.sh`) ASUS WMI camera node discovery.

If unset, production behavior remains unchanged.

## 🖥️ Display Profile Cycle Behavior

When sticky Super+P OSD is unavailable, `bin/asus-display-mode.sh` may cycle
Mutter layouts via `asus_display_mode.py`. Profiles are derived from currently
connected outputs (not a fixed two-display assumption).

* Monitor groups:
  * **Main**: built-in panel (typically `eDP-*`, default connector `eDP-1`).
  * **ScreenPad**: ZenBook secondary panel (typically `DP-*`, default `DP-3`).
  * **External**: all remaining connected non-builtin displays, treated as one grouped set.
* Dynamic profile cycle (when all groups are present):
  * `All Displays`
  * `Main + External xN`
  * `ScreenPad + External xN`
  * `Main Only`
  * `ScreenPad Only`
  * `External Only`
* Notifications are context-aware and include external count when relevant.

Preferred path remains sticky native OSD (`ydotool`/`xdotool`); Mutter cycling and
DE settings apps are fallbacks. Esc cancels an open sticky OSD without applying.
