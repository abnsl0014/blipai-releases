#!/usr/bin/python3
"""The dictation target: a GTK window with one text box, like any app a person types into.

Usage: target.py FILE [TITLE]
  The box's text is mirrored to FILE on every change. Creating FILE.clear empties the box
  and brings the window forward (the test does it before each dictation). Every key,
  focus change and text change is logged to FILE.events (not the text itself), so a
  "nothing typed" failure can say what the box received; on Ctrl+Shift+V (the app's portal
  paste on GNOME and KDE) it also notes what the clipboard held.
GTK picks X11 or Wayland from the environment, so the same window serves both sessions.
"""
import os
import sys
import time

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Gdk  # noqa: E402

path = sys.argv[1]
events = path + ".events"


def note(msg):
    try:
        with open(events, "a") as f:
            f.write(time.strftime("%H:%M:%S.") + f"{int(time.time() * 1000) % 1000:03d} {msg}\n")
    except OSError:
        pass


win = Gtk.Window(title=sys.argv[2] if len(sys.argv) > 2 else "Blip Test Target")
win.set_default_size(900, 500)
view = Gtk.TextView()
view.set_wrap_mode(Gtk.WrapMode.WORD)
buf = view.get_buffer()
win.add(view)
open(path, "w").close()


def on_changed(b):
    text = b.get_text(b.get_start_iter(), b.get_end_iter(), True)
    with open(path, "w") as f:
        f.write(text)
    note(f"text now {len(text)} chars")


def on_key(_w, ev):
    mods = []
    if ev.state & Gdk.ModifierType.CONTROL_MASK:
        mods.append("ctrl")
    if ev.state & Gdk.ModifierType.SHIFT_MASK:
        mods.append("shift")
    if ev.state & Gdk.ModifierType.MOD1_MASK:
        mods.append("alt")
    note("key " + "+".join(mods + [Gdk.keyval_name(ev.keyval) or str(ev.keyval)]))
    if mods[:2] == ["ctrl", "shift"] and Gdk.keyval_to_lower(ev.keyval) == Gdk.KEY_v:
        # What the app's portal paste presses. GTK text boxes paste on Ctrl+V (and
        # Shift+Insert), so note what was on the clipboard then; the box doesn't paste it.
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).request_text(
            lambda _c, text: note("got ctrl+shift+V; the clipboard held: " + repr((text or "")[:120])))
    return False


def poll():
    if os.path.exists(path + ".clear"):
        try:
            os.remove(path + ".clear")
        except OSError:
            pass
        buf.set_text("")
        win.present()
        view.grab_focus()
    return True


buf.connect("changed", on_changed)
view.connect("key-press-event", on_key)
win.connect("focus-in-event", lambda *_: note("window focused") or False)
win.connect("focus-out-event", lambda *_: note("window lost focus") or False)
win.connect("destroy", Gtk.main_quit)
GLib.timeout_add(200, poll)
win.show_all()
view.grab_focus()
Gtk.main()
