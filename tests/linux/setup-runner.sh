#!/bin/bash
# Installs what the test needs, as root, on Ubuntu/Debian (apt), Fedora (dnf) or Arch
# (pacman): a display server (Xvfb + Openbox, or Sway + XWayland), PulseAudio, the
# accessibility bus, GTK for the text box, xdotool/wtype, iptables, and the libraries an
# Electron AppImage needs. It deliberately leaves out libfuse2: install-app.sh checks
# whether the AppImage starts without it and installs it the way the website says.
# Then the website's Wayland setup: its install command (wl-clipboard and wtype), as
# printed there, and the `input` group for the user who runs the app.
#   TEST_USER: the user who runs the app (default: the user who ran sudo)
#   DESKTOP:   gnome or kde for those jobs: also installs that desktop (headless) and its portal
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
      xvfb openbox xdotool x11-utils imagemagick sway wtype wl-clipboard grim xwayland \
      pulseaudio pulseaudio-utils dbus dbus-x11 at-spi2-core python3-pyatspi python3-gi \
      gir1.2-gtk-3.0 python3-evdev espeak-ng gdb libnss3 libgbm1 libxss1 libxtst6 \
      "$(pick libgtk-3-0t64 libgtk-3-0)" "$(pick libasound2t64 libasound2)" >> "$log" 2>&1
    ;;
  fedora:*)
    dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
      sudo ca-certificates curl jq file procps-ng psmisc iptables-nft xdg-utils desktop-file-utils \
      xorg-x11-server-Xvfb openbox xdotool xdpyinfo ImageMagick sway wtype wl-clipboard grim \
      xorg-x11-server-Xwayland pulseaudio pulseaudio-utils dbus-daemon dbus-x11 at-spi2-core \
      python3-pyatspi python3-gobject gtk3 python3-evdev espeak-ng gdb nss mesa-libgbm libXScrnSaver \
      libXtst alsa-lib shadow-utils util-linux >> "$log" 2>&1 \
    || dnf install -y --allowerasing --setopt=install_weak_deps=False --skip-unavailable \
      pulseaudio pulseaudio-utils >> "$log" 2>&1
    ;;
  arch:*|*:*arch*)
    pacman -Syu --noconfirm --needed \
      sudo ca-certificates curl jq file procps-ng psmisc iptables xdg-utils desktop-file-utils \
      xorg-server-xvfb openbox xdotool xorg-xdpyinfo imagemagick sway wtype wl-clipboard grim \
      xorg-xwayland pulseaudio libpulse dbus at-spi2-core python-atspi python-gobject gtk3 \
      python-evdev espeak-ng gdb nss mesa libxss libxtst alsa-lib >> "$log" 2>&1
    ;;
  *) echo "unsupported distro: $ID" >&2; exit 1 ;;
esac
status=$?

# GNOME and KDE jobs: the desktop itself, run headless by session.sh. GNOME: GNOME Shell (it
# brings mutter) and the GNOME portal backend. KDE: KWin, the KDE portal backend, and what a
# Plasma install has that they need: plasma-integration (KWin crashed at start in a full
# session without it), PipeWire (KWin offers the portal its screencast protocol only with it,
# and the portal refuses a RemoteDesktop session without that), the XDG applications menu
# and KDE's service cache (KWin finds which programs may use its privileged protocols there),
# and kde-open, which xdg-open uses on Plasma (it opens the sign-in link).
if [ "$status" -eq 0 ] && [ -n "${DESKTOP:-}" ]; then
  case "${DESKTOP}:${ID}:${ID_LIKE:-}" in
    gnome:ubuntu:*|gnome:debian:*|gnome:*:*debian*)
      apt-get install -y -qq --no-install-recommends gnome-shell xdg-desktop-portal xdg-desktop-portal-gnome \
        dconf-cli xwayland >> "$log" 2>&1 ;;
    gnome:fedora:*)
      # Nautilus too: since GNOME 47 the GNOME portal's file chooser is Nautilus's window.
      dnf install -y --setopt=install_weak_deps=False gnome-shell xdg-desktop-portal xdg-desktop-portal-gnome \
        nautilus xorg-x11-server-Xwayland mesa-dri-drivers dconf >> "$log" 2>&1 ;;
    kde:fedora:*)
      dnf install -y --setopt=install_weak_deps=False kwin xdg-desktop-portal xdg-desktop-portal-kde \
        plasma-integration breeze-icon-theme kf6-kservice kde-cli-tools redhat-menus pipewire wireplumber \
        xorg-x11-server-Xwayland mesa-dri-drivers >> "$log" 2>&1 ;;
    *) echo "no $DESKTOP setup for $ID" >> "$log"; false ;;
  esac
  status=$?
  # Mutter and KWin start Xwayland on a socket here; a container has no such folder.
  mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix
fi
tail -n 5 "$log"
[ "$status" -eq 0 ] || { echo "::error title=Install the test's packages::exit $status (see $log)"; exit 1; }

# The website's Wayland step 1, word for word (content/articles/linux-setup.md). Its result
# goes to website-wayland-tools.txt for user-steps.sh to report.
out_dir="${OUT:-${RUNNER_TEMP:-/tmp}/blip-test}"; mkdir -p "$out_dir"
case "${ID}:${ID_LIKE:-}" in   # BlipAIWebsite#260: wl-clipboard and wtype; no ydotool
  ubuntu:*|debian:*|*:*debian*) cmd="apt install -y wl-clipboard wtype" ;;
  fedora:*) cmd="dnf install -y wl-clipboard wtype" ;;
  *) cmd="pacman -Syu --noconfirm wl-clipboard wtype" ;;
esac
$cmd >> "$out_dir/website-wayland-tools.log" 2>&1
echo "$? sudo ${cmd/ -y/}" > "$out_dir/website-wayland-tools.txt"
chown "$TEST_USER" "$out_dir" "$out_dir"/website-wayland-tools.* 2> /dev/null || true

# The website's Wayland setup: `sudo groupadd -f input; sudo usermod -aG input $USER`.
groupadd -f input
usermod -aG input "$TEST_USER"
# The test's virtual keyboard (keys.py) writes to /dev/uinput.
[ -e /dev/uinput ] || modprobe uinput 2> /dev/null || true
[ -e /dev/uinput ] && chmod 0666 /dev/uinput
exit 0
