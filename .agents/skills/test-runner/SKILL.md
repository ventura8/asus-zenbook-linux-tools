---
name: test-runner
description: Execute unit tests, end-to-end tests, and check ≥90% code coverage.
---

# Test Runner Skill

Use this skill to execute unit tests and end-to-end test suites independently while measuring code coverage.

## Dependency & Mocking Philosophy

- **Real deps first**: Always install the actual package or system library when
  possible. Mock or stub only unavoidable external system boundaries that cannot
  run as-is in CI — hardware/kernel interfaces (e.g. `evdev` InputDevice/UInput
  nodes), privileged services, and system commands such as session buses,
  `gsettings`, `kwriteconfig`, and `xfconf-query`. Prefer the real `evdev`
  Python package for imports; device nodes remain a hardware boundary.
- **Never mock owned code**: Do not mock/stub classes, functions, or modules from
  this repo (`bin/`, `lib/`, `scripts/`, installers). Call the real owned
  implementation; patch only external boundaries as above.
- **Install one-liners**: Human README/release quick-starts must be one pasteable **interactive**
  command (`curl … | sudo bash`). Never put `NONINTERACTIVE_CHOICE` in those human blocks.
  Clearly labeled headless/automation sections in `docs/INSTRUCTIONS.md` may use a
  `NONINTERACTIVE_CHOICE` install after downloading a **pinned release** `install.sh`
  and verifying `install.sh.sha256` (not a mutable `main` branch pipe). Prefer readable
  wraps that break after trailing `&&` or `|`
  (or with `\`) so lines stay ≤140. Do not suppress MD013 and do not use global
  `code_blocks`/`tables` exemptions in `.markdownlint.json`.
  Whenever `install.sh` itself changes in a PR, regenerate `install.sh.sha256` in the same
  change set (`sha256sum install.sh > install.sh.sha256`) — CI fails on a stale checksum.
  Always run automatic formatters / delinters with safe autofix before hand-editing lint failures.
- **No convenience stubs**: Never stub a pure software library (e.g., `dbus`, `evdev`) just to avoid
  installing it. Install the real dependency in the Docker image or test environment instead.
- **i18n**: Unit tests cover gettext locale precedence and catalog fallback.
  Compat smoke validates locale catalog deployment on all nine distros; full-DE
  cells probe real DE CLIs/schemas only.

## Instructions

1. **Live Output & Persistent Logs**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   ./scripts/run-tests.sh 2>&1 | tee reports/distro-logs/tests.log
   ```

   Always run test commands with live CLI output and always persist logs under `reports/distro-logs/`.

1. **Run Unit Tests with Coverage**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   coverage run tools/dot_test_runner.py \
     --start-dir tests/unit --top-level-dir . --failfast \
     2>&1 | tee reports/distro-logs/unit-tests.log
   ```

   Prefer `tools/dot_test_runner.py` over raw `unittest discover`. Fail-fast is on by
   default so the first real failure stops the suite. Name test classes after the
   behavior under test (e.g. `TestAsusHotkeyAtKeyboardProxy`,
   `ProductGatesDiscoveryTests`) — do **not** use `Coverage`, `Edge`, or `Extra` in
   class or module names. Capture stdout/stderr (and product logging via
   `assertLogs` / `install_captured_logging`) inside negative-path unit fixtures so
   intentional CLI/tool failure text is available for assertions and debug logs but
   does not pollute the live suite console. Shell helpers keep per-command capture
   files (`SHELL_UNIT_LOG_DIR`); opt into live console mirror with
   `SHELL_UNIT_LIVE_TEE=1`.    Display-mode sticky OSD release must assert Shift/Meta keyups
   (`tests/unit/shell/test_asus_display_mode.py`), not Super-only release.
   Sticky second-press tests must keep `ASUS_DISPLAY_MODE_IDLE_SECS` large enough
   (e.g. 30) that parallel Docker matrix load cannot expire `.session` mid-test.
   Esc-during-OSD cancel is covered in
   `tests/unit/bin/test_asus_hotkey_display_osd_cancel.py` (AT Esc not forwarded,
   post-Esc display-mode cooldown, proxy Super release). **Invariant:** Esc while
   sticky OSD is active must `reset_pending_meta` (never `flush_pending_meta`);
   flushing Super+P reopens Mutter’s dialog after ydotool Esc dismiss
   (`test_esc_during_osd_drops_pending_meta_without_flush`). Display-mode
   `--cancel-osd` / `${prefix}.cancel` watchdog skip:
   `tests/unit/shell/test_asus_display_mode.py`.
   Firmware Super+P swallow must include KEY_P **down and up** before Meta-up
   (`test_firmware_super_p_is_swallowed_and_dispatches_display_script`); a KEY_P
   release must not flush the pending chord (that regression hard-cycles Mutter
   with no OSD). Keep AT keyboard / WMI input OSError paths, Esc routing,
   NOTIF_ID_ROOT OSD glob, and WMI-gone `SystemExit` across
   `test_asus_hotkey_at_keyboard_proxy.py` / `test_asus_hotkey_input_devices.py`
   so `bin/asus_hotkey_daemon_input.py` stays ≥90%. Loader path-append /
   missing-`shared_imports` cases live in
   `tests/unit/bin/test_asus_hotkey_daemon.py` (`TestAsusHotkeyDaemonLoader`).
   `tools/dot_test_runner.py` needs `addError`/`addSkip`/`addSubTest` marker coverage in
   `tests/unit/tools/test_dot_test_runner.py` (not only `addFailure`).
   Window-swap unit tests must use `window_swap_monitor_patches()` (sync worker
   plus wmctrl/xdotool boundaries) and seed `LAST_*` cache state so host
   `xdotool`/`wmctrl` cannot move the IDE window during CI/local runs.
   That helper patches `asus_hotkey_daemon_session._run_command`. After the
   hotkey-daemon module split, patch and invoke private helpers on the module
   where the execution binding lives (`_session`, `_topology_detect`,
   `_desktop_family`, `_window_swap`, `_window_swap_gnome`, `_window_move`, or
   `_topology`); runtime/monitor facade exports preserve imports but are not
   effective patch targets for sibling-local bindings.
   Empty-cache presses must start `_start_deferred_window_swap_worker` (not
   event-thread await); cover with
   `test_perform_window_swap_defers_when_cache_empty`. Cached GNOME defer must
   **pass usable monitors** into the worker (cover
   `test_deferred_cached_swap_passes_usable_monitors` /
   `test_monitors_for_deferred_reuses_seed`) — do not re-detect Mutter on every
   deferred hop. Negative D-Bus readiness TTL is 0.5s
   (`test_dbus_not_ready_uses_short_negative_ttl`); never cache False for 30s.
   Startup priming order is `prime_desktop_user_cache`, then
   `prime_gnome_window_swap_extension` (clears `disable-user-extensions`), then
   `prime_topology_cache`.    GNOME move fallbacks:
   `test_apply_gnome_window_move_uinput_when_extension_edge_noop` in
   `tests/unit/bin/test_asus_hotkey_daemon_monitor_layout.py`.
   LXQt window-swap: `test_apply_window_move_lxqt_geometric` +
   `test_lxqt_never_uses_gnome_extension_or_uinput` (no extension/uinput path).
   Cinnamon/MATE window-swap: `test_apply_window_move_cinnamon_geometric` /
   `test_apply_window_move_mate_geometric` + fail-closed no-extension tests.
   Display Toggle DE-family settings and no-Mutter fallbacks live in
   `tests/unit/shell/test_asus_display_mode_de_settings.py`; shared fixtures live in
   `tests/unit/shell/display_mode_shell_test_utils.py`. Relevant tests include
   `test_lxqt_fallback_skips_mutter_cycle`,
   `test_cinnamon_fallback_skips_mutter_cycle`,
   `test_mate_fallback_skips_mutter_cycle` (settings only).
   Mint bare-GNOME: session + runtime heuristic tests remap `ubuntu:GNOME` when
   secondary cinnamon/mate signals hit.
   ScreenPad OSD: `test_gnome_osd_primes_extension_then_skips_notify` must keep
   best-effort prime (`|| true`) + short retries under the 5s helper budget.
   Also `test_lxqt_value_hint_notify_skips_generic_fallback`,
   `test_cinnamon_show_osd_skips_notification`,
   `test_mate_value_hint_notify_skips_generic_fallback`.

   Shell-complexity and file-size unit fixtures belong under repo-root `.tmp-tests/`
   (gitignored; excluded from `scripts/check_file_size_limits.py` walks). Oversized scoped files
   must be **split**, not shortened by deleting comments or blank lines (see AGENTS.md).

1. **Run Mocked End-to-End Tests with Coverage (CI/local default)**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   (
     export PYTHONPATH="$PWD"
     cd tests/e2e/mock
     coverage run -a ../../../tools/dot_test_runner.py \
       --start-dir . --top-level-dir .. --failfast
   ) 2>&1 | tee reports/distro-logs/mocked-e2e-tests.log
   ```

   Mocked/CI E2E tests must use per-test timeout budgets in the **20–30 second** range
   (inclusive; `tests/e2e/e2e_utils.py` rejects values below 20 and above
   `MAX_E2E_TIMEOUT_SECONDS=30` in mock mode).
   `run_e2e_command` streams stdout/stderr live, tees under
   `PROJECT_ROOT/reports/distro-logs/` (`E2E_LOG_DIR` is accepted only when it resolves under that root),
   and still returns captured text.
   Shared mock E2E fixtures use `MOCK_UID` consistently for session bus paths and
   package-manager test stubs use a distinct directory per backend.
   On timeout it signals tee threads, kills the child process group, and joins tee threads with a bounded budget.
   Shell unit helpers in `tests/unit/shell/shell_test_utils.py` tee the same way (`SHELL_UNIT_LOG_DIR` override).
   `terminate_pid_file` rechecks `/proc/<pid>/stat` starttime before SIGKILL to avoid PID-reuse races.
   Camera notification icon tests must set `ASUS_ICON_THEME_ROOT` to a temp Adwaita/Yaru tree
   (do not branch on host `/usr/share/icons`).
   Pass argv to `run_e2e_command` as a `Sequence[str]` (e.g. `["bash", script]`), not a shell string.
   Real-system E2E may use up to `MAX_REAL_E2E_TIMEOUT_SECONDS=300` only when both
   `allow_real=True` and `E2E_REAL_ALLOW_SYSTEM_CHANGES=1` are set.
   Timeout overruns are hard failures.

1. **Run Real-System End-to-End Tests (opt-in only)**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh \
     2>&1 | tee reports/distro-logs/real-e2e-tests.log
   ```

1. **Enforce Coverage Threshold**:

   Prefer `./scripts/build-and-test.sh` (CI parity) or `run_python_coverage_gate` from
   `scripts/coverage/gates.sh` (facade → `gates_python.sh` / `gates_shell.sh` /
   `gates_kcov.sh`): every configured product Python file must appear in the report at ≥90%,
   not only TOTAL.

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   # shellcheck source=scripts/coverage/gates.sh
   source scripts/coverage/gates.sh
   include_pattern="$(_python_coverage_include_pattern)"
   run_python_coverage_gate "$include_pattern" 90 \
     2>&1 | tee reports/distro-logs/python-coverage-gate.log
   exit "${PIPESTATUS[0]}"
   ```

   `_python_coverage_include_pattern` is derived from `_list_product_python_files` so newly
   added `bin/` / `tools/` modules are gated automatically (plus the hardcoded extras).

   After unit and mocked E2E runs with `coverage run` / `coverage run -a`, the same gate runs inside
   `./scripts/build-and-test.sh`.

   Product shell kcov must stay ≥90% (`bin/*.sh`, `lib/*.sh`, `install.sh`,
   `uninstall.sh`). `KCOV_MIN_PERCENT` may raise the gate above 90 but cannot
   lower it below 90 (default 90; clamped in `gates_kcov.sh` via the gates facade).
   Percentages are keyed by `KCOV_REPO_ROOT`-relative product paths, not basename.
   `scripts/coverage/common.sh` memoizes `KCOV_REPO_ROOT` per process and links isolated
   PATH tools via `type -P` (`_kcov_isolated_bin_dir`, `_link_kcov_tool`).
   For `asus-fan-toggle.sh`, discover via `SYS_PLATFORM_ROOT` (same platform root as
   camera); sysfs-only scenarios use `ASUS_FAN_NODE`; PPD paths
   need `ASUS_FAN_USE_PPD=1` plus a fake `powerprofilesctl` on `PATH`
   (see `scripts/coverage/kcov-scenarios.sh`).
   Sound hwdev settle polls `/dev/snd/hwC*D*` up to 75×0.2s (`SOUND_HWDEV_POLL_ATTEMPTS`).
   Camera toggle must read the sysfs node back before notifying; display-mode
   `_ensure_watchdog` uses an atomic `mkdir` lock dir (with RETURN cleanup) to avoid
   duplicate watchdogs. Window-swap runs on a worker thread with an in-flight guard;
   keep `swap_step` updates on the event thread.
   Coverage drivers that create temp dirs must register `trap 'rm -rf …' EXIT`
   immediately after `mktemp` (prefer subshells for scenario helpers).
   Kcov fixtures that exercise product `_run_as_user` must use a passwd-backed session
   user (same-user exec); prefer `_make_fake_loginctl_current_user` over the
   ghost_user stub. Desktop configure drivers must also bind `$BUS_ROOT/$uid/bus`,
   source `asus-session.sh`, and source `asus-i18n.sh` after `install-shared.sh`;
   assert the primary configure call exits 0 so an early D-Bus/gettext failure is never hidden.
   Raise helper coverage with deterministic external-command and filesystem failures asserted
   through `_soft_expect`; keep owned install/restore helpers real.
   Installed-lib bootstrap coverage uses
   `ASUS_FORCE_INSTALLED_LIB=1` with `ASUS_INSTALLED_LIB_DIR` on product scripts
   (no `/usr/local` mounts; no `/tmp` script copies that basename-collide).
   Direct scenarios (`_kcov_expect_direct_run_env`, e.g. root+`runuser`
   `cam_not_writable`) must log under `$kcov_root/logs/` like kcov runs; expected
   exit `1` with “not writable” is success, but leaked stderr on the console is a
   harness bug. Unexpected exits fail the gate immediately.

1. **Generate Coverage Badge (Local)**:

   ```bash
   coverage-badge -f -o assets/coverage.svg
   ```

1. **Validate Distro Matrix Coverage**:

   Ensure containerized test runs cover the always-on nine:

   - `ubuntu:26.04`
   - `debian:trixie`
   - `fedora:44`
   - `rocky:10`
   - `opensuse/tumbleweed`
   - `archlinux:latest`
   - `opensuse/leap:16.0`
   - `almalinux:10`
   - `manjarolinux/base:latest`

   Full-DE family variants and limited nested proofs run in the same push/PR
   CI pipeline (not nightly). SteamOS compatibility is validated through the
   Arch lane plus Arch-derivative installer mapping tests.
