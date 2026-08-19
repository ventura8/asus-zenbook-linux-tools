---
name: systemd-verifier
description: Verify systemd service unit integrity and sleep hook scripts.
---

# Systemd Verifier Skill

Use this skill to validate systemd service files and sleep hooks before deployment.

## Instructions

1. **Live Output & Persistent Logs**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   systemd-analyze --version 2>&1 | tee reports/distro-logs/systemd-verifier.log
   ```

   Always run verification commands with live CLI output and always save logs under `reports/distro-logs/`.

1. **Analyze Systemd Service Files**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   TMP_BIN=$(mktemp -d)
   TMP_SVC=$(mktemp -d)
   cleanup() {
      rm -rf "$TMP_BIN" "$TMP_SVC"
   }
   trap cleanup EXIT
   # Preserve launcher symlinks as regular staged files for reliable verification.
   cp -aL bin/. "$TMP_BIN"/
   chmod +x "$TMP_BIN"/*
   for svc in systemd/*.service; do
       sed "s|/usr/local/bin|$TMP_BIN|g" "$svc" > "$TMP_SVC/$(basename "$svc")"
   done
   # Resolve Key= in one [Section]; last assignment wins (systemd override).
   # Misplaced keys (wrong section) and overridden values fail the assert.
   _assert_svc_directive() {
       local file="$1" section="$2" key="$3" expected="$4" label="$5"
       local actual
       actual=$(awk -v want_section="$section" -v want_key="$key" '
           BEGIN { cur = ""; found = 0; val = "" }
           /^[[:space:]]*[#;]/ || /^[[:space:]]*$/ { next }
           /^\[/ {
               cur = $0
               sub(/^\[/, "", cur)
               sub(/\].*/, "", cur)
               next
           }
           cur != want_section { next }
           index($0, want_key "=") != 1 { next }
           {
               found = 1
               val = substr($0, length(want_key) + 2)
           }
           END {
               if (!found)
                   exit 1
               print val
           }
       ' "$file") || {
           echo "systemd assert failed ($label): $file" >&2
           return 1
       }
       if [ "$actual" != "$expected" ]; then
           echo "systemd assert failed ($label): $file (got '$actual')" >&2
           return 1
       fi
   }
   _assert_svc_absent() {
       local file="$1" pattern="$2" label="$3"
       if grep -qE "$pattern" "$file"; then
           echo "systemd assert failed ($label): $file" >&2
           return 1
       fi
   }
   for unit in asus-hotkey-daemon.service asus-touchpad-share.service; do
       staged="$TMP_SVC/$unit"
       _assert_svc_directive "$staged" Service ProtectSystem no 'ProtectSystem=no'
       _assert_svc_absent "$staged" '^NoNewPrivileges=yes$' 'no NoNewPrivileges=yes'
       _assert_svc_absent "$staged" '^Wants=systemd-udev-settle\.service$' \
           'no udev-settle Wants'
       _assert_svc_absent "$staged" '^After=systemd-udev-settle\.service$' \
           'no udev-settle After'
       _assert_svc_directive "$staged" Service ProtectHome read-only \
           'ProtectHome=read-only'
       _assert_svc_directive "$staged" Service RuntimeDirectory \
           asus-zenbook-notif 'RuntimeDirectory=asus-zenbook-notif'
       _assert_svc_directive "$staged" Service RuntimeDirectoryPreserve yes \
           'RuntimeDirectoryPreserve=yes'
       _assert_svc_directive "$staged" Service Environment \
           PYTHONDONTWRITEBYTECODE=1 'Environment=PYTHONDONTWRITEBYTECODE=1'
   done
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Unit \
       StartLimitIntervalSec 60 'StartLimitIntervalSec=60'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Unit \
       StartLimitBurst 10 'StartLimitBurst=10'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Service \
       ProtectKernelModules yes 'ProtectKernelModules=yes'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Service \
       ProtectKernelLogs yes 'ProtectKernelLogs=yes'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Service \
       RestrictNamespaces yes 'RestrictNamespaces=yes'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Service \
       RestrictSUIDSGID yes 'RestrictSUIDSGID=yes'
   _assert_svc_directive "$TMP_SVC/asus-hotkey-daemon.service" Service \
       PrivateDevices no 'PrivateDevices=no'
   _assert_svc_absent "$TMP_SVC/asus-sound-fix.service" '^ExecStartPre=' \
       'sound-fix no ExecStartPre hwdev poll'
   _assert_svc_directive "$TMP_SVC/asus-sound-fix.service" Service \
       ProtectSystem strict 'ProtectSystem=strict'
   _assert_svc_directive "$TMP_SVC/asus-sound-fix.service" Service \
       ProtectHome read-only 'ProtectHome=read-only'
   _assert_svc_directive "$TMP_SVC/asus-sound-fix.service" Service \
       StateDirectory asus-zenbook-linux-tools \
       'StateDirectory=asus-zenbook-linux-tools'
   _assert_svc_directive "$TMP_SVC/asus-sound-fix.service" Service \
       ReadWritePaths '-/dev/snd' 'ReadWritePaths=-/dev/snd'
   _assert_svc_absent "$TMP_SVC/asus-sound-fix.service" '^DeviceAllow=' \
       'sound-fix no DeviceAllow (char-snd blocks hwC* under strict)'
   systemd-analyze verify "$TMP_SVC"/*.service 2>&1 \
       | tee reports/distro-logs/systemd-verify-services.log
   ```

   For hotkey daemon and touchpad share units, prefer `ProtectSystem=no` over
   `ProtectSystem=strict`/`full`. Strict/full mode remounts `/run` and `/tmp`
   read-only and, when combined with `NoNewPrivileges=yes` or
   `RestrictSUIDSGID=yes`, breaks `runuser` session D-Bus calls used for
   notifications, Settings/Share helpers, and Mutter topology (3-monitor
   window-swap). Keep `ProtectHome=read-only` with
   `RuntimeDirectory=asus-zenbook-notif`. Hotkey and touchpad units must set
   `RuntimeDirectoryPreserve=yes` so the shared runtime directory survives
   restarts, and `Environment=PYTHONDONTWRITEBYTECODE=1` so imports do not leave
   `__pycache__` beside installed modules (dpkg cannot remove those leftovers).
   Display-mode sticky OSD state must
   also live under that RuntimeDirectory (`NOTIF_ID_ROOT`), never `/run/user`,
   or `.session` writes fail and the monitor dialog hard-cycles.
   After starting ydotoold, display-mode must poll for the socket before
   succeeding (empty `TARGET` on the first press looked like a no-op OSD).
   Orphan `.session` markers without a live watchdog must reopen sticky OSD,
   not P-only cycle.    Window-swap must prime desktop user cache, then
   `prime_gnome_window_swap_extension` (clear `disable-user-extensions`, enable
   UUID, honor exit status, ≤2s D-Bus wait), then topology (with one retry)
   before the event loop and apply cached hops synchronously when D-Bus is
   already ready; advance bounce step only after a successful move. Deferred
   hops must reuse already-usable monitors and use `attempts=1` (do not
   re-detect Mutter + attempts=3 — tens-of-seconds regression). Cache D-Bus
   True for 30s / False for 0.5s only. Before each hop, realign bounce step using
   focus via the Asus Window Swap GNOME extension (`MoveFocused` /
   `GetFocusedMonitor`) with opposite-direction retry on edge no-ops; fall back
   to uinput when both directions return false or when D-Bus is missing after
   extension enable retry. Do not use the pointer as a keyboard-focus proxy.
   Display-mode Esc cancel must set `${prefix}.cancel`, drop `.session` before
   injected Esc, and skip watchdog apply-release while `.cancel` is set; hotkey
   daemon arms post-Esc display-mode cooldown and AT-proxy Super release.
   On AT Esc during sticky OSD, drop buffered Super with `reset_pending_meta` —
   never `flush_pending_meta` (AT Super+P after ydotool Esc reopens the dialog).
   Hotkey unit must set `StartLimitIntervalSec=60` with `StartLimitBurst=10` so
   restart storms are bounded while brief `/dev/input` gaps can still recover.
   Hotkey unit also sets `ProtectKernelModules=yes`, `ProtectKernelLogs=yes`,
   `RestrictNamespaces=yes`, and `RestrictSUIDSGID=yes` with `PrivateDevices=no` (evdev/uinput still need device
   nodes). Sound oneshot unit must not duplicate hwdev polling in `ExecStartPre`;
   `asus-sound-fix.sh` `poll_sound_hwdev` owns settle timing. Sound oneshot uses
   `ProtectSystem=strict` + `ProtectHome=read-only` with
   `ReadWritePaths=-/dev/snd` only (no `DeviceAllow=char-snd`; it blocks hwC nodes).
   Do **not** add `Wants=`/`After=systemd-udev-settle.service` on hotkey/touchpad units.
   Do **not** harden hotkey/touchpad to `ProtectSystem=full`
   in reviews—those units require `ProtectSystem=no`.
   Optional `ReadWritePaths=` entries that may be absent need the systemd `-`
   ignore-if-missing prefix or start fails with `status=226/NAMESPACE`.

1. **Verify System Sleep Hooks**:

   ```bash
   set -euo pipefail
   mkdir -p reports/distro-logs
   # Prerequisite: install.sh must have created the hook on the host.
   HOOK=/lib/systemd/system-sleep/asus-sound-fix
   [ -f "$HOOK" ] || { echo "Hook not installed at $HOOK" >&2; exit 1; }
   bash -n "$HOOK" 2>&1 | tee reports/distro-logs/systemd-verify-hook-syntax.log
   # Exercise pre-sleep phase (should exit 0 without applying verbs)
   bash "$HOOK" pre suspend 2>&1 | tee reports/distro-logs/systemd-verify-hook-pre.log
   echo "pre phase: OK"
      # Exercise post-wake phase only with explicit real-system opt-in
      if [ "${E2E_REAL_ALLOW_SYSTEM_CHANGES:-0}" = "1" ]; then
         bash "$HOOK" post suspend 2>&1 | tee reports/distro-logs/systemd-verify-hook-post.log
         echo "post phase: OK"
      else
         echo "Skipping post phase; set E2E_REAL_ALLOW_SYSTEM_CHANGES=1 to enable real-system hook execution."
      fi
   ```
