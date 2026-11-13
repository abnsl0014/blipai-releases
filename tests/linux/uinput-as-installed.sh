#!/bin/bash
# GNOME and KDE jobs, as root: put /dev/uinput back the way a stock Ubuntu or Fedora install
# has it, root's only (setup-runner.sh opened it to everyone for the Openbox and Sway jobs'
# virtual keyboard). On GNOME and KDE it matters: a world-writable /dev/uinput lets any
# program type into the desktop, and the app's paste must get there the way it does for the
# website's users, through the portal. The test's own keyboard (keys.py) runs as root there instead.
[ -e /dev/uinput ] || exit 0
chown root:root /dev/uinput
chmod 0600 /dev/uinput
echo "/dev/uinput: $(stat -c '%A %U:%G' /dev/uinput)"
