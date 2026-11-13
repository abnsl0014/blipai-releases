#!/usr/bin/python3
"""A virtual keyboard for Wayland sessions, where the app reads key presses from
/dev/input (evdev) the way it reads a real keyboard.

  keys.py serve FIFO     create the keyboard ("Blip Test Keyboard", through /dev/uinput)
                         and press keys as commands arrive on FIFO, one per line:
                         "down ctrl", "up super", "tap escape", "type /some/path.wav"
                         (FIFO "-": standard input)
  keys.py gnome FIFO     GNOME jobs: read the same commands from FIFO, press each key on
                         GNOME Shell's seat too (the test's shell extension), and pass the
                         line on to standard output, for `keys.py serve -` running as root.
                         A physical keyboard reaches both the app (/dev/input) and the
                         desktop; headless GNOME Shell reads no input devices of its own.
The keyboard stays plugged in for the whole run: the app opens input devices when it
starts, and a keyboard that appears for each press would come and go between reads.
On X11 the test uses xdotool instead (the app's X11 key listener reads the X server).
"""
import os
import sys
import time

from evdev import UInput, ecodes as e

KEYS = {
    "ctrl": e.KEY_LEFTCTRL, "super": e.KEY_LEFTMETA, "win": e.KEY_LEFTMETA, "shift": e.KEY_LEFTSHIFT,
    "alt": e.KEY_LEFTALT, "space": e.KEY_SPACE, "escape": e.KEY_ESC, "return": e.KEY_ENTER,
    "z": e.KEY_Z, "v": e.KEY_V, "a": e.KEY_A, "tab": e.KEY_TAB,
}


def keys_for(ch):
    """(keycode, shift) for one character on a US keyboard, as a person types it."""
    if ch.isascii() and ch.isalpha():
        return getattr(e, "KEY_" + ch.upper()), ch.isupper()
    if ch.isascii() and ch.isdigit():
        return getattr(e, "KEY_" + ch), False
    return {"/": (e.KEY_SLASH, False), "-": (e.KEY_MINUS, False), "_": (e.KEY_MINUS, True),
            ".": (e.KEY_DOT, False), " ": (e.KEY_SPACE, False), ",": (e.KEY_COMMA, False)}.get(ch, (None, False))


def node_of(ui):
    """The /dev/input/eventN the kernel made for the keyboard. (UInput.device is None in
    some python-evdev versions, so look it up in sysfs by name.)"""
    import glob
    time.sleep(0.5)
    for name_file in glob.glob("/sys/class/input/event*/device/name"):
        try:
            if open(name_file).read().strip() == ui.name:
                return "/dev/input/" + name_file.split("/")[4]
        except OSError:
            pass
    return "(no /dev/input node found)"


def lines(fifo):
    if fifo == "-":
        yield from iter(sys.stdin.readline, "")
        return
    while True:
        with open(fifo) as f:
            yield from f


def gnome(fifo):
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    for line in lines(fifo):
        parts = line.split()
        if len(parts) == 2 and parts[1] in KEYS:
            presses = {"down": [True], "up": [False], "tap": [True, False]}.get(parts[0], [])
            for i, pressed in enumerate(presses):
                if i:
                    time.sleep(0.05)
                # The same key reaches the desktop first, then the app (as a key event
                # reaches the compositor and evdev readers at about the same time).
                try:
                    bus.call_sync("org.gnome.Shell", "/app/blipai/TestShell", "app.blipai.TestShell", "Key",
                                  GLib.Variant("(ub)", (KEYS[parts[1]], pressed)), None, 0, 2000, None)
                except Exception as err:
                    print("gnome-shell key failed:", err, file=sys.stderr, flush=True)
        sys.stdout.write(line)
        sys.stdout.flush()


def main():
    if sys.argv[1] == "gnome":
        return gnome(sys.argv[2])
    fifo = sys.argv[2]
    if fifo != "-" and not os.path.exists(fifo):
        os.mkfifo(fifo)
    ui = UInput({e.EV_KEY: sorted(set(KEYS.values()))}, name="Blip Test Keyboard")
    print("ready", node_of(ui), flush=True)
    for line in lines(fifo):
        if line.startswith("type "):  # "type TEXT": each character as a key press, US layout
            for ch in line[5:].rstrip("\n"):
                code, shift = keys_for(ch)
                if code is None:
                    continue
                if shift:
                    ui.write(e.EV_KEY, e.KEY_LEFTSHIFT, 1); ui.syn()
                ui.write(e.EV_KEY, code, 1); ui.syn()
                time.sleep(0.02)
                ui.write(e.EV_KEY, code, 0); ui.syn()
                if shift:
                    ui.write(e.EV_KEY, e.KEY_LEFTSHIFT, 0); ui.syn()
                time.sleep(0.03)
            continue
        parts = line.split()
        if len(parts) != 2 or parts[1] not in KEYS:
            continue
        verb, code = parts[0], KEYS[parts[1]]
        if verb in ("down", "tap"):
            ui.write(e.EV_KEY, code, 1)
            ui.syn()
        if verb == "tap":
            time.sleep(0.05)
        if verb in ("up", "tap"):
            ui.write(e.EV_KEY, code, 0)
            ui.syn()
        time.sleep(0.04)

if __name__ == "__main__":
    main()
