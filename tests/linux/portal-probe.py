#!/usr/bin/python3
"""GNOME and KDE jobs: does the desktop's RemoteDesktop portal answer at all? (session.sh)

  portal-probe.py [SECONDS]

Asks xdg-desktop-portal for a RemoteDesktop session (CreateSession: no dialog, answered at
once on a working desktop), prints the answer, and closes the session again. If this gets no
answer, the app's paste permission can't either, and that's the test's problem, not the app's.
"""
import random
import sys

from gi.repository import Gio, GLib

timeout = int(sys.argv[1]) if len(sys.argv) > 1 else 30
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
loop = GLib.MainLoop()
sender = bus.get_unique_name()[1:].replace(".", "_")
token = "blipprobe%d" % random.randint(0, 1 << 30)
request = f"/org/freedesktop/portal/desktop/request/{sender}/{token}"
answer = {}


def on_response(_c, _s, _p, _i, _sig, params):
    answer["r"] = params.unpack()
    loop.quit()


bus.signal_subscribe(None, "org.freedesktop.portal.Request", "Response", request, None, 0, on_response)
try:
    bus.call_sync("org.freedesktop.portal.Desktop", "/org/freedesktop/portal/desktop",
                  "org.freedesktop.portal.RemoteDesktop", "CreateSession",
                  GLib.Variant("(a{sv})", ({"handle_token": GLib.Variant("s", token),
                                            "session_handle_token": GLib.Variant("s", token)},)),
                  None, 0, timeout * 1000, None)
except GLib.Error as err:
    print(f"CreateSession failed: {err.message}")
    sys.exit(1)
GLib.timeout_add_seconds(timeout, loop.quit)
loop.run()
if "r" not in answer:
    print(f"no answer to CreateSession within {timeout} s")
    sys.exit(1)
code, results = answer["r"]
handle = results.get("session_handle", "")
if handle:
    try:
        bus.call_sync("org.freedesktop.portal.Desktop", handle, "org.freedesktop.portal.Session", "Close",
                      None, None, 0, 5000, None)
    except GLib.Error:
        pass
print(f"CreateSession answered {code} ({'ok' if code == 0 else 'refused'})")
sys.exit(0 if code == 0 else 1)
