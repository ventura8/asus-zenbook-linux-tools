# Instructions & Contribution Guidelines

## Setup & Prerequisites

Ensure Python 3.13+, `bash`, `python3` (stdlib curses), `gsettings`, `systemctl`, `evdev`
(via system package `python3-evdev` on most distros, or openSUSE resolution below, or PyPI `evdev`),
and linters are installed. **`hda-verb`**: Debian/Ubuntu/Fedora/Arch use `alsa-tools` or the
openSUSE `hda-verb` package; Rocky/RHEL have no system `hda-verb` — SOUND uses bundled
`bin/asus_hda_verb.py` when the system helper is absent. Install `nodejs` and `npm` before the
markdownlint CLI step below.
The installer now targets Ubuntu, Debian, Fedora, Rocky Linux, openSUSE, and
Arch Linux through the appropriate package manager. SteamOS maps to the Arch
package-manager family via `ID=steamos` / `ID_LIKE=arch`; it is not a dedicated
CI runtime image. Ubuntu flavours (Xubuntu/Kubuntu/Lubuntu) use the Debian/apt
path.
The optional **DESKTOP** install component configures GNOME, KDE Plasma, XFCE,
LXQt, Cinnamon, or MATE shortcuts (`lib/install-gnome.sh`, `lib/install-kde.sh`,
`lib/install-xfce.sh`, `lib/install-lxqt.sh`, `lib/install-cinnamon.sh`,
`lib/install-mate.sh`).

Desktop installs follow the active session locale automatically for setup,
notifications, display labels, and shortcut text via GNU gettext.

Docker Engine with access to the Docker daemon is required for the lint and
test verification wrappers (`./scripts/lint-in-docker.sh`,
`./scripts/run-tests.sh`, and `./scripts/build-and-test.sh`). Host-only
`--lints-only` / `--tests-only` paths are not the supported CI-parity entrypoint.

```bash
# Require Python 3.13+ before Poetry (matches product packaging)
python3 - <<'PY'
import sys
if sys.version_info < (3, 13):
    raise SystemExit(f"Python 3.13+ required, got {sys.version.split()[0]}")
PY

# Debian / Ubuntu
sudo apt-get install -y shellcheck systemd alsa-tools alsa-utils \
  python3-evdev libglib2.0-bin kcov nodejs npm pipx

# openSUSE — try `import evdev` first; then install the versioned RPM name that
# `_resolve_suse_evdev_pkg` in `lib/install-os-detection.sh` would pick (active `python3`,
# or keep an already-installed `python3-evdev`).
sudo zypper install -y ShellCheck systemd hda-verb alsa-utils \
  glib2-tools kcov nodejs npm
python3 -c 'import evdev' 2>/dev/null || \
  sudo zypper install -y "$(python3 -c 'import sys; print(f"python{sys.version_info.major}{sys.version_info.minor}-evdev")')"

# Fedora
sudo dnf install -y ShellCheck systemd alsa-tools alsa-utils glib2 \
  python3-evdev kcov nodejs npm pipx

# Rocky Linux (no packaged alsa-tools/hda-verb or ydotool; SOUND uses bundled
# asus_hda_verb.py automatically when system hda-verb is absent)
sudo dnf install -y epel-release
sudo dnf install -y ShellCheck systemd alsa-utils glib2 python3-evdev kcov nodejs npm pipx

# Arch Linux
sudo pacman -S --noconfirm shellcheck systemd alsa-tools alsa-utils glib2 kcov \
  python-evdev nodejs npm

python3 -c 'import evdev'

# Install Poetry via pipx (avoids writing into system Python)
pipx ensurepath
export PATH="${HOME}/.local/bin:${PATH}"
pipx install poetry==2.4.1
poetry install --with dev

npm install --prefix="${HOME}/.local" markdownlint-cli@0.49.1 eslint@10.9.0
# Or use the repo pin for GNOME extension JS linting (requires Node
# ^20.19.0 || ^22.13.0 || >=24 for ESLint 10):
# npm ci
```

## Ubuntu PPA Install (resolute)

Preferred on Ubuntu 26.04 / resolute:

```bash
sudo add-apt-repository ppa:ventura8/asus-zenbook-linux-tools && \
  sudo apt update && \
  sudo apt install asus-zenbook-linux-tools
```

This runs the interactive component wizard. Reconfigure with
`sudo dpkg-reconfigure asus-zenbook-linux-tools` or
`sudo asus-zenbook-configure`. Tag releases upload via
`.github/workflows/ppa-release.yml` (secrets `GPG_PRIVATE_KEY`,
`GPG_PASSPHRASE`). The same workflow also builds RPM, Arch, AppImage, Flatpak,
and Snap artifacts and attaches them to the GitHub Release (native `.deb` plus
multi-distro packages). Current notes: [v1.0.5](releases/v1.0.5.md).

## GitHub Release native packages

Download release assets and **`SHA256SUMS`** from the same GitHub Release tag.
Verify the downloaded asset before installation (replace the filename):

```bash
grep -F 'your-asset-filename' SHA256SUMS | sha256sum -c -

# Fedora / Rocky / Alma
sudo dnf install ./asus-zenbook-linux-tools-*.rpm

# openSUSE (checksum-verified RPM; zypper resolves dependencies)
sudo zypper install --allow-unsigned-rpm ./asus-zenbook-linux-tools-*.rpm

# Arch / Manjaro
sudo pacman -U ./asus-zenbook-linux-tools-*.pkg.tar.zst

# AppImage
sudo ./asus-zenbook-linux-tools-*-x86_64.AppImage

# Flatpak (system scope matches sudo run)
sudo flatpak install --system ./asus-zenbook-linux-tools-*.flatpak
sudo flatpak run org.github.ventura8.AsusZenBookLinuxTools

# Snap (--dangerous required for local classic snaps; only after checksum verification)
sudo snap install --dangerous ./asus-zenbook-linux-tools_*.snap
```

Reconfigure after install: `sudo asus-zenbook-configure`.

Portable AppImage / Flatpak / Snap bundles on the release page are
**installer-only** (they invoke the configure wizard with a bundled payload).
Use native packages for full systemd and udev integration.

## Headless / Automation Install

Human README quick-starts stay interactive. For CI or non-TTY automation only:

```bash
TAG=v1.0.5
git clone --depth 1 --branch "$TAG" \
  https://github.com/ventura8/asus-zenbook-linux-tools.git &&
  cd asus-zenbook-linux-tools &&
  sha256sum -c install.sh.sha256 &&
  sudo NONINTERACTIVE_CHOICE="WMI TOUCHPAD SOUND DESKTOP" bash ./install.sh
```

Headless no-op (install nothing):

```bash
sudo NONINTERACTIVE_CHOICE=none bash ./install.sh
```

## ScreenPad Brightness Portability

Requires the **WMI** component and a writable ScreenPad sysfs node
(`asus_screenpad` or `asus::screenpad`, or `ASUS_SCREENPAD_NODE`). Supported on
the CI distro matrix with GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, or MATE.

| Layer | GNOME | KDE | XFCE | LXQt | Matrix distros |
| --- | --- | --- | --- | --- | --- |
| Shift+Fn chord | yes | yes | yes | yes | WMI component |
| Sysfs ScreenPad node | required | required | required | required | required |
| Feedback | Shell `ShowOsd` | Plasma `osdService` | replace-in-place notify | Spec `value`-hint notify | same helpers |
| Notify stacking | N/A if OSD | N/A if OSD | single updating bubble | single updating bubble | id + sync tag |
| Alt+Fn | unsupported | unsupported | unsupported | unsupported | documented |

Cinnamon uses public `org.Cinnamon.ShowOSD`; MATE uses Spec `value`-hint Notify
(same chord/sysfs gates as the table).

Chord sources: WMI and/or Video Bus brightness plus Shift on ASUE i2c and/or AT.
Without a ScreenPad node the daemon forwards main-panel brightness (fail-open).
Feedback order: GNOME `ShowOsd` → Plasma `brightnessChanged`/`showProgress` →
LXQt Spec `value`-hint Notify → Cinnamon `org.Cinnamon.ShowOSD` → MATE Spec
`value`-hint Notify → replace-in-place notify (XFCE/other).

LXQt has **no** public display-only OSD D-Bus (panel volume/backlight plugins are
private). Cinnamon exposes public `org.Cinnamon.ShowOSD` on `/org/Cinnamon`
(`a{sv}`: `icon`, `level` 0–100) — display-only, does not change backlight.
MATE has **no** public ShowOSD (`MediaKeys` is Grab/Release only;
`PowerManager.Backlight.SetBrightness` mutates the main LCD — never use for
ScreenPad feedback). GNOME `ShowOsd` draws the brightness bar on the ScreenPad
monitor (`DP-3` / ScreenPad geometry; primary only when ScreenPad is off). It
needs the Asus Window Swap Shell extension **ACTIVE** with D-Bus exported: if
Extensions → “User extensions” is off
(`org.gnome.shell disable-user-extensions=true`), the UUID can still appear in
`enabled-extensions` while `ShowOsd`/`MoveFocused` fail — product code clears
that kill switch when priming. Probe with
`gdbus call --session --dest org.gnome.Shell --object-path
/org/gnome/Shell/Extensions/AsusWindowSwap --method
org.gnome.Shell.Extensions.AsusWindowSwap.ShowOsd 'display-brightness-symbolic' 0.5`
(not `--dest org.gnome.Shell.Extensions`). Cinnamon probe:
`gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon --method
org.Cinnamon.ShowOSD "{'icon': <'display-brightness-symbolic'>, 'level': <50>}"`.

## Running Verification

Before submitting any changes, execute lint and test checks via the Docker
wrappers:

Docker image definitions for these checks are committed under `docker/images/`
(lint image and per-distro test images).

```bash
set -euo pipefail
mkdir -p reports/distro-logs
./scripts/lint-in-docker.sh 2>&1 | tee reports/distro-logs/lint-docker.log
```

```bash
set -euo pipefail
mkdir -p reports/distro-logs
./scripts/run-tests.sh 2>&1 | tee reports/distro-logs/tests.log
```

Coverage-gate best practice in this repository:

- Run shell/Python coverage thresholds once in a canonical distro lane (Ubuntu).
- Run the broader distro matrix in compatibility mode without repeating coverage math.

Examples:

```bash
set -euo pipefail
mkdir -p reports/distro-logs
./scripts/run_docker_matrix.sh --coverage-gate \
  2>&1 | tee reports/distro-logs/docker-matrix-coverage-gate.log
./scripts/run_docker_matrix.sh --compat-only \
  2>&1 | tee reports/distro-logs/docker-matrix-compat-only.log
```

Or run the canonical wrapper:

```bash
./scripts/build-and-test.sh
```

In `--full` mode, the pipeline runs the dedicated coverage-gate Docker image
first (unit/kcov/e2e/Python coverage; no install smoke) and then executes the
always-on nine-distro compatibility matrix in `--compat-only` mode (includes
`scripts/run_distro_install_smoke.sh`: package probes, DESTDIR WMI/TOUCHPAD,
DESKTOP gnome/kde/xfce/lxqt/cinnamon/mate configure cycles with stubs, and in-container live
package mutation). CI also runs always-on `distro-full-de` family variants and
limited nested/MoveFocused/sticky proofs in the same push/PR workflow.
Arch/Manjaro test images retry `pacman -Syu`/`-S` when rolling mirrors 404 a
superseded package; Arch CI pins `archlinux-mirrorlist` (not geo/fastly).
Rocky/Alma kcov builds install `libcurl-devel` matching the installed libcurl
NEVRA (`el10-kcov-libcurl.sh`; `--nobest` when AppStream/BaseOS skew).

Host execution of `--lints-only` and `--tests-only` modes is intentionally
blocked. These modes run only inside Docker containers.

CI dependencies are pinned in workflow and Docker definitions, and
`.github/dependabot.yml` keeps those pinned versions updated on a weekly cadence.

Run real-system E2E tests only when debugging host-specific failures:

```bash
sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh
```

## Mandatory Quality Standards

- **Zero Suppression Policy**: Do not commit any linter disable directives
  (`# pylint: disable`, `# noqa`, `# type: ignore`). Hyphenated CLI entrypoint
  names must be symlinks to underscore-valid Python modules; never suppress `N999`
  via line/file `# noqa`, `# ruff: noqa`, `[tool.ruff.lint.per-file-ignores]`, or
  global `ignore`.
- **Auto-fix Before Manual Lint Fixes**: Always run automatic formatters / delinters with
  safe autofix before hand-editing lint failures (for example `ruff check --fix`,
  `ruff format`, `markdownlint --fix`, and `eslint --fix` when available). Re-lint, then
  manually fix only what remains.
  GNOME extension JS under `gnome/` is gated by ESLint (`eslint.config.mjs`; no
  `eslint-disable`).
- **Never Mock Owned Code**: Do not mock or stub classes, functions, or modules owned by this
  repository. Tests must exercise the real owned implementation and may patch only external
  boundaries that cannot exist in CI (hardware devices, missing privileged kernel interfaces).
- **Install One-Liners (Interactive for Humans)**: README / release human quick-install snippets
  must be one pasteable interactive command (`curl … | sudo bash`). Prefer readable wraps that
  break after trailing `&&` or `|` (or with `\`) so lines stay ≤140. Do not use
  `NONINTERACTIVE_CHOICE` there. **Exception:** clearly labeled headless/automation sections may
  use a `NONINTERACTIVE_CHOICE=…` install (see above). Do not suppress MD013 and do not set
  `line-length.code_blocks` or `tables` to `false` in `.markdownlint.json`.
- **No-Hang Policy**: `install.sh` and `uninstall.sh` must not block indefinitely waiting for input or user interaction.
  They must always progress to a deterministic completion path, including in non-interactive or headless environments.
  Component steps that stall (unit enable/daemon-reload style probes) must be bounded by a **5-second** timeout and
  reported as failures instead of hanging the whole run. Separate from that stall bound, installer helper commands that
  use `_run_command_with_timeout` / `INSTALL_COMMAND_TIMEOUT` default to **15 seconds** (see `AGENTS.md`). Use the
  5-second stall bound for hung component activation checks; use the 15-second helper default for normal install
  helper invocations unless a call site sets an explicit timeout.
- **Fast E2E Policy**: Mocked/CI E2E tests must run with a per-test timeout budget between 20 and 30 seconds.
  Any timeout is a test failure and must not be suppressed.
- **Code Coverage**: Production code coverage for product Python (find of `bin/` + `tools/` `*.py`,
  plus `shared_imports.py`, `scripts/check_file_size_limits.py`, `sitecustomize.py` via
  `_python_coverage_include_pattern`) and product shell (`bin/*.sh`, `lib/*.sh`, `install.sh`,
  `uninstall.sh`) must be at least **90%**. New product modules under those trees are required
  automatically; do not maintain a separate hardcoded include glob.
- **Complexity**: Keep function complexity at A-rank rating in `radon` (all blocks score ≤ 5).
- **File size (600 lines)**: Scoped product and test files (`bin/`, `lib/`, `tests/`, `tools/`,
  `scripts/`, `gnome/`, `docker/`, root installers, Debian maintainer scripts) must stay within the
  limit enforced by `scripts/check_file_size_limits.py`. When a file is too large, **split it into
  smaller modules** (helpers, sibling sources, focused tests). **Do not** remove comments,
  docstrings, or blank lines only to pass the gate.
