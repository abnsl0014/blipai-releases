#!/usr/bin/python3
"""A virtual keyboard for Wayland sessions, where the app reads key presses from
/dev/input (evdev) the way it reads a real keyboard.

  keys.py serve FIFO     create the keyboard ("Blip Test Keyboard", through /dev/uinput)
                         and press keys as commands arrive on FIFO, one per line:
                         "down ctrl", "up super", "tap escape"
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


def main():
    fifo = sys.argv[2]
    if not os.path.exists(fifo):
        os.mkfifo(fifo)
    ui = UInput({e.EV_KEY: sorted(set(KEYS.values()))}, name="Blip Test Keyboard")
    print("ready", ui.device.path, flush=True)
    while True:
        with open(fifo) as f:
            for line in f:
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
