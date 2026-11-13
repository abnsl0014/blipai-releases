#!/usr/bin/python3
"""Reads and presses the app's UI through AT-SPI, the Linux accessibility bus (what screen
readers use). The app is started with --force-renderer-accessibility so Chromium fills it.

  atspi.py text APP [WINDOW]     the text of every element in APP's windows (or one window)
  atspi.py press APP LABEL [WINDOW]
                                 press the first button whose name contains LABEL
  atspi.py windows APP           the names of APP's windows
  atspi.py save-as APP PATH      in APP's save dialog, type PATH as the name and press Save
  atspi.py portal-dialog         the text of the desktop portal's consent dialog, if one is up
  atspi.py portal-approve        approve that dialog as a person does: turn on its switches
                                 that grant access (GNOME: "Allow Remote Interaction", without
                                 which Share stays greyed out), keep its defaults otherwise
                                 ("Remember This Selection"), press Share / Approve / Allow
APP is matched against the accessible application name, case-insensitively, as a substring.
"""
import sys

import pyatspi


def apps(name):
    desktop = pyatspi.Registry.getDesktop(0)
    for i in range(desktop.childCount):
        try:
            app = desktop.getChildAtIndex(i)
        except Exception:
            continue
        if app is not None and name.lower() in (app.name or "").lower():
            yield app


def windows(name, only=None):
    for app in apps(name):
        for i in range(app.childCount):
            try:
                w = app.getChildAtIndex(i)
            except Exception:
                continue
            if w is None:
                continue
            if only and (w.name or "") != only:
                continue
            yield w


def walk(node, depth=0):
    if node is None or depth > 60:
        return
    yield node
    try:
        n = node.childCount
    except Exception:
        return
    for i in range(n):
        try:
            child = node.getChildAtIndex(i)
        except Exception:
            continue
        yield from walk(child, depth + 1)


def text_of(node):
    try:
        t = node.queryText()
        s = t.getText(0, -1)
        if s and s.strip():
            return s
    except Exception:
        pass
    return node.name or ""


APPROVE = ("Share", "Approve", "Allow")
GRANT_SWITCHES = ("Allow Remote Interaction",)


def portal_dialogs():
    """(window, nodes) for each window of a portal backend (xdg-desktop-portal-gnome, -kde,
    -gtk) or GNOME Shell that has a Share / Approve / Allow button."""
    for w in windows("portal"):
        nodes = list(walk(w))
        for n in nodes:
            try:
                if n.getRoleName() in ("push button", "button") and (n.name or "").replace("_", "") in APPROVE:
                    yield w, nodes
                    break
            except Exception:
                continue


def describe(w, nodes):
    seen, lines = set(), [f"[{w.name}]"]
    for n in nodes:
        try:
            role, name = n.getRoleName(), (text_of(n) or "").strip().replace("\n", " ")
        except Exception:
            continue
        key = (role in ("check box", "toggle button", "switch", "push button", "button"), name)
        if not name or key in seen:
            continue
        seen.add(key)
        if role in ("check box", "toggle button", "switch"):
            on = n.getState().contains(pyatspi.STATE_CHECKED)
            lines.append(f"{name} [{'on' if on else 'off'}]")
        elif role in ("push button", "button"):
            ok = n.getState().contains(pyatspi.STATE_SENSITIVE)
            lines.append(f"({name}{'' if ok else ', greyed out'})")
        elif role in ("label", "heading", "text", "static"):
            lines.append(name)
    return " ".join(lines)


def main():
    cmd = sys.argv[1]
    if cmd == "portal-dialog":
        found = [describe(w, n) for w, n in portal_dialogs()]
        print(" | ".join(found))
        return 0 if found else 2
    if cmd == "portal-approve":
        import time
        for w, nodes in portal_dialogs():
            done = []
            for n in nodes:
                try:
                    role, name = n.getRoleName(), n.name or ""
                except Exception:
                    continue
                if role in ("check box", "toggle button", "switch") and name in GRANT_SWITCHES \
                        and not n.getState().contains(pyatspi.STATE_CHECKED):
                    n.queryAction().doAction(0)
                    done.append(f'turned on "{name}"')
                    time.sleep(0.5)
            for label in APPROVE:
                for n in nodes:
                    try:
                        if n.getRoleName() in ("push button", "button") and (n.name or "").replace("_", "") == label:
                            if not n.getState().contains(pyatspi.STATE_SENSITIVE):
                                print("; ".join(done + [f'"{label}" is greyed out']))
                                return 1
                            n.queryAction().doAction(0)
                            print("; ".join(done + [f'pressed "{label}" in "{w.name}"']))
                            return 0
                    except Exception:
                        continue
        print("no portal dialog")
        return 2
    app = sys.argv[2]
    if cmd == "windows":
        print(", ".join(w.name or "?" for w in windows(app)))
    elif cmd == "text":
        only = sys.argv[3] if len(sys.argv) > 3 else None
        for w in windows(app, only):
            print(f"== window: {w.name}")
            seen = None
            for node in walk(w):
                s = text_of(node).replace("￼", "").strip()   # drop embedded-object marks
                if s and s != seen:
                    print(s)
                    seen = s
    elif cmd == "press":
        label = sys.argv[3]
        only = sys.argv[4] if len(sys.argv) > 4 else None
        names = []
        for w in windows(app, only):
            names.append(w.name or "?")
            for node in walk(w):
                try:
                    role = node.getRoleName()
                except Exception:
                    continue
                if role not in ("push button", "button", "toggle button", "link"):
                    continue
                if label.lower() not in (node.name or "").lower():
                    continue
                try:
                    action = node.queryAction()
                    action.doAction(0)
                    print(f'pressed "{node.name}" in {w.name}')
                    return 0
                except Exception as e:
                    print(f"found \"{node.name}\" but it can't be pressed: {e}")
                    return 1
        print(f'no button "{label}" in windows {names}')
        return 2
    elif cmd == "save-as":
        # GTK's save dialog (what Electron shows on Linux): type the path into its name
        # box and press Save, as a person choosing where to save would.
        target = sys.argv[3]
        for w in windows(app):
            entries, save = [], None
            for node in walk(w):
                try:
                    role = node.getRoleName()
                except Exception:
                    continue
                if role == "text" and not entries:
                    try:
                        node.queryEditableText()
                        entries.append(node)
                    except Exception:
                        pass
                if role in ("push button", "button") and (node.name or "").replace("_", "") == "Save":
                    save = node
            if entries and save:
                entries[0].queryEditableText().setTextContents(target)
                save.queryAction().doAction(0)
                print(f"typed the path into {w.name or 'the save dialog'} and pressed Save")
                return 0
        print("no save dialog with a name box and a Save button")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
