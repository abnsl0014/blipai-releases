#!/usr/bin/python3
"""How the app tried to put text into the focused window, on GNOME and KDE (their jobs only).

  paste-path.py SINCE_MS PASTE_TOOLS_LOG PORTAL_DBUS_LOG BOX_EVENTS

The release build logs nothing, so this reads what it did instead:
  PASTE_TOOLS_LOG  every wtype / ydotool / wl-copy the app ran, with its exit code (lib.sh's shims)
  PORTAL_DBUS_LOG  dbus-monitor of the RemoteDesktop portal (CreateSession, SelectDevices, Start,
                   NotifyKeyboardKeycode), its Response signals, and notifications (Notify)
  BOX_EVENTS       the text box's key log (target.py), which notes what the clipboard held when
                   it got Ctrl+Shift+V
and prints one line for the report, e.g. "wtype exit 1, ydotool exit 1, then portal paste:
wl-copy, Ctrl+Shift+V through the RemoteDesktop portal (6 key events)".
The app's own tiers (linux/wayland-inject.js): wtype → ydotool → portal paste → wl-copy + notice.
"""
import re
import sys
import time

KEYS = {29: "Ctrl", 42: "Shift", 47: "V", 97: "RightCtrl", 54: "RightShift"}


def tools(path, since):
    out = []
    try:
        for line in open(path, errors="replace"):
            parts = line.split(" ", 3)
            if len(parts) < 4 or not parts[0].isdigit() or int(parts[0]) < since:
                continue
            m = re.search(r"-> exit (\d+)", parts[3])
            out.append((int(parts[0]), parts[2], int(m.group(1)) if m else None))
    except OSError:
        pass
    return out


def dbus_events(path, since):
    """[(ms, kind, detail)] from dbus-monitor's default output."""
    events, cur = [], None
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return events
    for line in lines + ["method call time=0"]:
        if re.match(r"^(method call|signal|method return|error) ", line):
            if cur and cur[0] >= since:
                events.append(cur)
            m = re.search(r"time=([\d.]+)", line)
            member = re.search(r"member=(\w+)", line)
            ms = int(float(m.group(1)) * 1000) if m else 0
            cur = [ms, member.group(1) if member else "", []] if member else None
        elif cur is not None:
            v = re.match(r"\s+(?:u?int32|string|object path|boolean)\s+(.*)$", line)
            if v:
                cur[2].append(v.group(1).strip('"'))
    return events


def main():
    since, tools_log, dbus_log, box_log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
    parts = []
    ran = tools(tools_log, since)
    ev = dbus_events(dbus_log, since)
    keys = [e for e in ev if e[1] == "NotifyKeyboardKeycode"]
    asked = [e for e in ev if e[1] in ("CreateSession", "Start")]
    notices = [e for e in ev if e[1] == "Notify"]
    for _, name, rc in ran:
        if name in ("wtype", "ydotool"):
            parts.append(f"{name} exit {rc}" + (" (typed)" if rc == 0 else ""))
    copied = any(n == "wl-copy" and rc == 0 for _, n, rc in ran)
    if keys:
        chord = []
        for e in keys:
            nums = [a for a in e[2] if re.fullmatch(r"-?\d+", a)]
            if len(nums) >= 2 and nums[-1] == "1":
                chord.append(KEYS.get(int(nums[-2]), nums[-2]))
        parts.append(f"portal paste: {'wl-copy, ' if copied else ''}{'+'.join(chord) or '?'} pressed through the "
                     f"RemoteDesktop portal ({len(keys)} key events)"
                     + (" after a new portal session" if asked else ""))
    elif asked:
        parts.append("RemoteDesktop portal session asked for, no keys sent")
    shown = []
    for e in notices:  # Notify(app_name, replaces_id, app_icon, summary, body, ...)
        if not e[2] or "blip" not in e[2][0].lower():
            continue  # the desktop's own notices (KDE: "Remote control session started")
        text = ": ".join(x for x in e[2][3:5] if x)[:90]
        if text and text not in shown:  # GNOME Shell passes it on once more
            shown.append(text)
    for text in shown:
        parts.append(f"clipboard fallback: {'wl-copy, then ' if copied else ''}the notice \"{text}\"")
    if copied and not keys and not notices and not any(rc == 0 for _, n, rc in ran if n != "wl-copy"):
        parts.append("wl-copy only")
    try:
        box = [l.rstrip() for l in open(box_log, errors="replace")]
        today = time.strftime("%Y-%m-%d ")
        for l in box:
            t = time.mktime(time.strptime(today + l[:8], "%Y-%m-%d %H:%M:%S")) * 1000 + int(l[9:12] or 0)
            if t >= since - 1000 and "clipboard held" in l:
                parts.append("the box " + l[13:].strip()[:160])
                break
    except (OSError, ValueError):
        pass
    print(", ".join(parts) if parts else "the app ran no paste tool and no portal call")


if __name__ == "__main__":
    main()
