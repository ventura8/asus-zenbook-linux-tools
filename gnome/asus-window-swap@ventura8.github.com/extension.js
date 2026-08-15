/* ASUS ZenBook window-swap + Shell OSD D-Bus helper for GNOME Shell. */
import Meta from 'gi://Meta';
import Gio from 'gi://Gio';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const DBUS_IFACE = `
<node>
  <interface name="org.gnome.Shell.Extensions.AsusWindowSwap">
    <method name="MoveFocused">
      <arg type="s" direction="in" name="direction"/>
      <arg type="b" direction="out" name="moved"/>
    </method>
    <method name="GetFocusedMonitor">
      <arg type="i" direction="out" name="monitor"/>
    </method>
    <method name="ShowOsd">
      <arg type="s" direction="in" name="icon"/>
      <arg type="d" direction="in" name="level"/>
    </method>
  </interface>
</node>`;

const OBJ_PATH = '/org/gnome/Shell/Extensions/AsusWindowSwap';

// Match bin/asus_display_mode_layout.py ScreenPad defaults (UX582HS).
const SCREENPAD_CONNECTOR = 'DP-3';
const SCREENPAD_SIZE_PAIRS = [
    [3840, 1100],
    [1920, 550],
];

const DIRECTION_MAP = Object.create(null);
DIRECTION_MAP.down = Meta.DisplayDirection.DOWN;
DIRECTION_MAP.up = Meta.DisplayDirection.UP;
DIRECTION_MAP.left = Meta.DisplayDirection.LEFT;
DIRECTION_MAP.right = Meta.DisplayDirection.RIGHT;

function _primaryMonitorIndex() {
    if (Main.layoutManager && typeof Main.layoutManager.primaryIndex === 'number')
        return Main.layoutManager.primaryIndex;
    return 0;
}

function _monitorIndexForConnector(connector) {
    try {
        const mm = global.backend.get_monitor_manager();
        if (!mm || typeof mm.get_monitor_for_connector !== 'function')
            return -1;
        const idx = mm.get_monitor_for_connector(connector);
        if (typeof idx !== 'number' || idx < 0)
            return -1;
        return idx;
    } catch {
        return -1;
    }
}

function _isScreenpadGeometry(monitor) {
    if (!monitor || monitor.width <= 0 || monitor.height <= 0)
        return false;
    for (const [width, height] of SCREENPAD_SIZE_PAIRS) {
        if (monitor.width === width && monitor.height === height)
            return true;
    }
    return false;
}

function _screenpadIndexByGeometry() {
    const monitors = Main.layoutManager?.monitors;
    if (!monitors || !monitors.length)
        return -1;
    const primary = _primaryMonitorIndex();
    for (let i = 0; i < monitors.length; i++) {
        if (i === primary)
            continue;
        if (_isScreenpadGeometry(monitors[i]))
            return i;
    }
    return -1;
}

function _screenpadMonitorIndex() {
    // Prefer the UX582HS connector used by display-mode layout helpers.
    const byConnector = _monitorIndexForConnector(SCREENPAD_CONNECTOR);
    if (byConnector >= 0)
        return byConnector;
    // Fallback: other DP-* / scaled logical sizes matching ScreenPad WxH.
    const byGeometry = _screenpadIndexByGeometry();
    if (byGeometry >= 0)
        return byGeometry;
    return -1;
}

function _osdMonitorIndex() {
    const screenpad = _screenpadMonitorIndex();
    if (screenpad >= 0)
        return screenpad;
    // ScreenPad absent from layout (off / single-monitor) → primary.
    return _primaryMonitorIndex();
}

function _resolveOsdIcon(icon) {
    const name = String(icon || 'display-brightness-symbolic');
    let gicon;
    try {
        gicon = Gio.ThemedIcon.new_with_default_fallbacks(name);
    } catch {
        gicon = Gio.Icon.new_for_string('display-brightness-symbolic');
    }
    return gicon;
}

function _clampOsdLevel(level) {
    let lvl = Number(level);
    if (!Number.isFinite(lvl))
        lvl = 0;
    if (lvl < 0)
        lvl = 0;
    if (lvl > 1)
        lvl = 1;
    return lvl;
}

export default class AsusWindowSwapExtension extends Extension {
    enable() {
        this._dbus = Gio.DBusExportedObject.wrapJSObject(DBUS_IFACE, this);
        this._dbus.export(Gio.DBus.session, OBJ_PATH);
    }

    disable() {
        // Always unexport even when flush() throws (session bus already gone).
        // Nulling _dbus without unexport leaves /AsusWindowSwap stuck so later
        // enable() cannot re-export ShowOsd — ScreenPad brightness falls to notify.
        const dbus = this._dbus;
        this._dbus = null;
        if (!dbus)
            return;
        try {
            dbus.flush();
        } catch {
            // ignore
        }
        try {
            dbus.unexport();
        } catch {
            // ignore
        }
    }

    MoveFocused(direction) {
        const win = global.display.focus_window;
        if (!win || win.minimized)
            return false;
        if (!win.allows_move())
            return false;
        if (win.get_window_type() !== Meta.WindowType.NORMAL)
            return false;
        const metaDir = DIRECTION_MAP[String(direction).toLowerCase()];
        if (metaDir === undefined)
            return false;
        const src = win.get_monitor();
        if (src < 0)
            return false;
        const dst = global.display.get_monitor_neighbor_index(src, metaDir);
        if (dst < 0)
            return false;
        win.move_to_monitor(dst);
        return true;
    }

    GetFocusedMonitor() {
        const win = global.display.focus_window;
        if (!win)
            return -1;
        return win.get_monitor();
    }

    ShowOsd(icon, level) {
        // GNOME 49+: showAll(icon, label, level, maxLevel) — same as volume/ShowOSD.
        // GNOME ≤48: show(monitorIndex, icon, label, level, maxLevel).
        // Never call show(-1, ...) when showAll exists: on 49+ show() is
        // show(icon, label, levelsMap) and the legacy arity throws → gdbus fails
        // → asus-screenpad.sh falls back to notifications only.
        const gicon = _resolveOsdIcon(icon);
        if (!gicon)
            throw new Error('ShowOsd: could not resolve icon');
        const lvl = _clampOsdLevel(level);
        const osd = Main.osdWindowManager;
        if (!osd)
            throw new Error('ShowOsd: osdWindowManager unavailable');
        // Always prefer the ScreenPad monitor so brightness feedback appears on
        // the panel being adjusted (fall back to primary when ScreenPad is off).
        const monitor = _osdMonitorIndex();
        if (typeof osd.showOne === 'function') {
            osd.showOne(monitor, gicon, null, lvl, 1);
            return;
        }
        if (typeof osd.showAll === 'function')
            osd.showAll(gicon, null, lvl, 1);
        else
            osd.show(monitor, gicon, null, lvl, 1);
    }
}
