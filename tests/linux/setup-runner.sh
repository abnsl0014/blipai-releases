#!/bin/bash
# Installs what the test needs, as root, on Ubuntu/Debian (apt), Fedora (dnf) or Arch
# (pacman): a display server (Xvfb + Openbox, or Sway + XWayland), PulseAudio, the
# accessibility bus, GTK for the text box, xdotool/wtype, iptables, and the libraries an
# Electron AppImage needs. It deliberately leaves out libfuse2: install-app.sh checks
# whether the AppImage starts without it and installs it the way the website says.
# Then the website's Wayland setup: its tools (wtype, wl-clipboard, ydotool) are in the
# lists above, and the `input` group for the user who runs the app.
#   TEST_USER: the user who runs the app (default: the user who ran sudo)
set -uo pipefail
. /etc/os-release
TEST_USER="${TEST_USER:-${SUDO_USER:-$(id -un)}}"
log="${RUNNER_TEMP:-/tmp}/setup-packages.log"

case "${ID}:${ID_LIKE:-}" in
  ubuntu:*|debian:*|*:*debian*)
    export DEBIAN_FRONTEND=noninteractive
    pick() { apt-cache show "$1" > /dev/null 2>&1 && echo "$1" || echo "$2"; }
    apt-get update -qq >> "$log" 2>&1
    apt-get install -y -qq --no-install-recommends \
      sudo ca-certificates curl jq file procps psmisc iptables xdg-utils desktop-file-utils libglib2.0-bin \
      xvfb openbox xdotool x11-utils imagemagick sway wtype wl-clipboard ydotool grim xwayland \
      pulseaudio pulseaudio-utils dbus dbus-x11 at-spi2-core python3-pyatspi python3-gi \
      gir1.2-gtk-3.0 python3-evdev espeak-ng libnss3 libgbm1 libxss1 libxtst6 \
      "$(pick libgtk-3-0t64 libgtk-3-0)" "$(pick libasound2t64 libasound2)" >> "$log" 2>&1
    ;;
  fedora:*)
    dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
      sudo ca-certificates curl jq file procps-ng psmisc iptables-nft xdg-utils desktop-file-utils \
      xorg-x11-server-Xvfb openbox xdotool xdpyinfo ImageMagick sway wtype wl-clipboard ydotool grim \
      xorg-x11-server-Xwayland pulseaudio pulseaudio-utils dbus-daemon dbus-x11 at-spi2-core \
      python3-pyatspi python3-gobject gtk3 python3-evdev espeak-ng nss mesa-libgbm libXScrnSaver \
      libXtst alsa-lib shadow-utils util-linux >> "$log" 2>&1 \
    || dnf install -y --allowerasing --setopt=install_weak_deps=False --skip-unavailable \
      pulseaudio pulseaudio-utils >> "$log" 2>&1
    ;;
  arch:*|*:*arch*)
    pacman -Syu --noconfirm --needed \
      sudo ca-certificates curl jq file procps-ng psmisc iptables xdg-utils desktop-file-utils \
      xorg-server-xvfb openbox xdotool xorg-xdpyinfo imagemagick sway wtype wl-clipboard ydotool grim \
      xorg-xwayland pulseaudio libpulse dbus at-spi2-core python-atspi python-gobject gtk3 \
      python-evdev espeak-ng nss mesa libxss libxtst alsa-lib >> "$log" 2>&1
    ;;
  *) echo "unsupported distro: $ID" >&2; exit 1 ;;
esac
status=$?
tail -n 5 "$log"
[ "$status" -eq 0 ] || { echo "::error title=Install the test's packages::exit $status (see $log)"; exit 1; }

# The website's Wayland setup: `sudo groupadd -f input; sudo usermod -aG input $USER`.
groupadd -f input
usermod -aG input "$TEST_USER"
# The test's virtual keyboard (keys.py) writes to /dev/uinput.
[ -e /dev/uinput ] || modprobe uinput 2> /dev/null || true
[ -e /dev/uinput ] && chmod 0666 /dev/uinput
exit 0
