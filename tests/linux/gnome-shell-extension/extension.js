// Test harness only (tests/linux/session.sh installs it in the test user's home).
// Headless GNOME Shell has no keyboard or mouse, so this stands in for the person at it:
//   Key(code, pressed)   a key on the seat's keyboard (evdev code), as a physical keyboard
//                        delivers it to the compositor. The app itself reads keys from
//                        /dev/input (keys.py); this is the same key press reaching GNOME.
//   Focus(title)         click a window with that title (activates it, as a click does)
//   HideOverview()       close the Activities overview GNOME starts in (a click on the desktop)
//   Windows()            JSON list of windows: title, wm_class, focus, X11 or Wayland
//   Screenshot(path)     a PNG of the screen (GNOME's own screenshot code)
// It never touches the portal or its dialogs: those are pressed over AT-SPI (atspi.py).
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const IFACE = `<node><interface name="app.blipai.TestShell">
  <method name="Key"><arg type="u" direction="in"/><arg type="b" direction="in"/></method>
  <method name="Focus"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
  <method name="HideOverview"/>
  <method name="Windows"><arg type="s" direction="out"/></method>
  <method name="Screenshot"><arg type="s" direction="in"/><arg type="b" direction="out"/></method>
</interface></node>`;

export default class BlipTestExtension extends Extension {
    enable() {
        const seat = Clutter.get_default_backend().get_default_seat();
        this._keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE, this);
        this._dbus.export(Gio.DBus.session, '/app/blipai/TestShell');
    }

    disable() {
        this._dbus?.unexport();
        this._dbus = null;
        this._keyboard = null;
    }

    Key(code, pressed) {
        this._keyboard.notify_key(GLib.get_monotonic_time(), code,
            pressed ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
    }

    _windows() {
        return global.get_window_actors().map(a => a.meta_window).filter(w => w);
    }

    Focus(title) {
        const w = this._windows().find(x => x.get_title() === title);
        if (!w)
            return false;
        Main.activateWindow(w, global.get_current_time());
        return true;
    }

    HideOverview() {
        Main.overview.hide();
    }

    Windows() {
        const focus = global.display.get_focus_window();
        return JSON.stringify(this._windows().map(w => ({
            title: w.get_title(),
            wm_class: w.get_wm_class(),
            focused: w === focus,
            x11: w.get_client_type() === Meta.WindowClientType.X11,
            type: w.get_window_type(),
            above: w.is_above(),
            rect: (r => [r.x, r.y, r.width, r.height])(w.get_frame_rect()),
        })));
    }

    ScreenshotAsync([path], invocation) {
        const file = Gio.File.new_for_path(path);
        const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
        new Shell.Screenshot().screenshot(false, stream, (obj, res) => {
            let ok = false;
            try {
                obj.screenshot_finish(res);
                ok = true;
            } catch (e) {
                logError(e, 'Blip test screenshot');
            }
            stream.close(null);
            invocation.return_value(new GLib.Variant('(b)', [ok]));
        });
    }
}
