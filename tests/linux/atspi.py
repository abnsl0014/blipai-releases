#!/usr/bin/python3
"""Reads and presses the app's UI through AT-SPI, the Linux accessibility bus (what screen
readers use). The app is started with --force-renderer-accessibility so Chromium fills it.

  atspi.py text APP [WINDOW]     the text of every element in APP's windows (or one window)
  atspi.py press APP LABEL [WINDOW]
                                 press the first button whose name contains LABEL
  atspi.py windows APP           the names of APP's windows
  atspi.py save-as APP PATH      in APP's save dialog, type PATH as the name and press Save
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


def main():
    cmd, app = sys.argv[1], sys.argv[2]
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
