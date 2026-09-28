# Hardware-validate the SonarQube cleanup branch on the 3080 laptop

## Context

Branch `claude/sonarqube-issues-vjimow` (on top of `9779c6f`) fixes the 1,795 open
SonarCloud findings. Most are shell rewrites across 105 files:

- `[`→`[[`, trailing `return $?` / bare `return`, `*) ;;` default arms;
- named locals, constants, merged `if`s;
- helper extractions to stay within CCN ≤5;
- file splits: `lib/install-components-uinput.sh`, `scripts/docker-utils-parallel.sh`,
  `scripts/coverage/kcov-display-scenarios.sh`, `tests/unit/shell/test_pipeline_ci_parity_sonar.py`.

Static gates were checked in the cloud container:

- Passed: `bash -n`, the complexity check, the 600-line cap, no suppressions, `install.sh.sha256`,
  and the POT freshness check.
- Match the original code: shellcheck and pylint report the same warnings as base, and the unit suite has the
  same failure set as base. That machine had no `evdev` and a broken `gi`.

Not verified in the cloud: the Docker lint and coverage images (TLS through the proxy failed), the kcov ≥90% gate,
and anything touching real hardware. The cloud session cannot reach the laptop, so this plan runs **in a Claude
session on the 3080 ZenBook**, started with Claude Desktop or `claude remote-control` in the repo checkout.

## Steps (on the laptop)

1. **Sync.**

   ```bash
   git fetch origin claude/sonarqube-issues-vjimow
   git checkout claude/sonarqube-issues-vjimow
   git log --oneline -1   # expect "docs: hardware validation plan for the SonarQube cleanup"
   ```

2. **Full CI-parity pipeline** (Docker works on the laptop). This covers lint waves, deb and release package smoke,
   the kcov/python coverage shards with the ≥90% merge, and the three compat families:

   ```bash
   set -euo pipefail && mkdir -p reports/distro-logs && \
     sudo timeout 10800 ./scripts/build-and-test.sh --full \
     2>&1 | tee reports/distro-logs/full-pipeline.log
   ```

   Then do the mandatory package-smoke log scan from AGENTS.md: grep `Error:|ERROR|WARNING:|Validation failed` in
   `reports/distro-logs/*.log`.
   - If kcov drops below 90% on a product file, the likely causes are the new `*) ;;` / `return` lines or the moved
     helpers (`_fan_canonical_path`, `_cycle_user_desktop_family`, `_effective_install_command_timeout`,
     `_screenpad_state_mtime`, `_scan_newest_screenpad_brightness`, `_suppress_duplicate_display_invoke`,
     `lib/install-components-uinput.sh`). Add kcov scenario calls rather than removing code.
3. **Real install / uninstall E2E** (mutates the host):

   ```bash
   sudo E2E_REAL_ALLOW_SYSTEM_CHANGES=1 ./scripts/run_real_e2e.sh \
     2>&1 | tee reports/distro-logs/real-e2e-install-uninstall.log
   ```

   Then run an interactive `sudo ./install.sh` with all components. Check the ncurses TUI, the banner rule, the
   `[n/m]` steps, and the asus-uinput group message (new file).
4. **Manual hardware checklist.** Watch `journalctl -u asus-hotkey-daemon -u asus-touchpad-share -f` while
   testing. Changed paths are in brackets.

   - **Fan**: Fn+F5 cycles Balanced→Performance→Quiet with the notification icon; `powerprofilesctl get`
     matches; an `ASUS_FAN_NODE` override is still honoured. Changed: `_fan_canonical_path`,
     `_prepare_ppd_fan_node` merged if.
   - **Display Toggle**: sticky Super+P OSD opens and cycles; Esc cancels; a rapid double press is suppressed.
     Changed: `main` / `_suppress_duplicate_display_invoke`, `_lock_is_duplicate` digit guard,
     `_cycle_user_desktop_family`, watchdog `[[ ]]`.
   - **ScreenPad**: toggle off/on restores the last brightness, including after a reboot; Shift+Fn brightness
     up/down shows the GNOME ShowOsd. Changed: `_scan_newest_screenpad_brightness`,
     `_ASUS_SCREENPAD_BRIGHTNESS_TAG`.
   - **Camera**: Fn+F10 toggles with the icon. Changed: `[[ ]]` conversions.
   - **Window swap**: the Fn hotkey moves the focused window between the main display and ScreenPad
     (shell side untouched; smoke only).
   - **Touchpad Share**: a top-left corner tap opens the screenshot UI. Changed: `[[ ]]` in the screenshot helper.
   - **Sound**: speakers work after boot and after a suspend/resume cycle; `systemctl status asus-sound-fix` is
     clean. Changed: `_enable_sound_service` `log_file` local.
   - **MyASUS / Settings**: the hotkey opens GNOME Settings. Changed: `asus-control-center.sh` `[[ ]]`.
   - **Uninstall**: `sudo ./uninstall.sh` restores GNOME keybindings (media-keys / mutter constants), removes
     the udev rule and revokes the asus-uinput group; the service-inactive warning text is unchanged.
     Changed: install-gnome constants, `_report_service_inactive_status`.

5. **Report and fix.** For any regression: fix it on the same branch, rerun the affected gate, commit, and push with
   `git push -u origin claude/sonarqube-issues-vjimow`. Record the pass/fail table in the session summary.
   After CI finishes on the branch, re-query the open SonarCloud issues:
   `https://sonarcloud.io/api/issues/search?componentKeys=asus-zenbook-linux-tools&resolved=false`. Only the 10
   documented false positives should remain: 8 S1481 nameref/dynamic-scope locals and 2 Python.

## Verification

Done when all of these hold:

- The `--full` pipeline is green, including the kcov/python ≥90% merge.
- The real E2E passes.
- Every row of the hardware checklist passes on the 3080 ZenBook.
- CI is green on the pushed head.
