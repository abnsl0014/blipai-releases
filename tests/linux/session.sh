#!/bin/bash
# Starts what a desktop session provides, for the user running the test:
#   - a D-Bus session bus and the accessibility bus (AT-SPI)
#   - a display: SESSION=x11 → Xvfb with the Openbox window manager;
#                SESSION=wayland → Sway (headless) with XWayland, as on the website's
#                wlroots path (Sway/Hyprland: wtype types, no ydotool daemon needed);
#                DESKTOP=gnome → GNOME Shell (headless, virtual monitor) with Xwayland;
#                DESKTOP=kde → KWin (virtual) with Xwayland, PipeWire and KDE's service cache;
#                both with xdg-desktop-portal and the desktop's own backend, on demand
#   - PulseAudio with a virtual microphone: a "voice" sink whose monitor is the default
#     input, and separate "speakers", so the app's own sounds don't reach the mic
#   - on Wayland, a virtual keyboard on /dev/input (keys.py)
#   - the text box the app types into (target.py)
# and writes the environment to $SESSION_ENV for the other scripts.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
env_out() { echo "export $1=$(printf '%q' "$2")" >> "$SESSION_ENV"; export "$1=$2"; }
: > "$SESSION_ENV"

env_out SESSION "$SESSION"
rt="${XDG_RUNTIME_DIR:-}"
if [ -z "$rt" ] || [ ! -w "$rt" ]; then rt="$RUNNER_TEMP/xdg-runtime"; mkdir -p "$rt"; chmod 700 "$rt"; fi
env_out XDG_RUNTIME_DIR "$rt"

# D-Bus session bus, and accessibility switched on (Chromium reads org.a11y.Status).
if [ -n "${DESKTOP:-}" ]; then
  # GNOME and KDE logins get their session bus from systemd, at a path
  # (unix:path=/run/user/UID/bus). dbus-launch's is an abstract socket, which the app's
  # D-Bus library (dbus-next) reaches only through a native module the AppImage doesn't
  # ship, so its portal paste never got as far as the bus. Use a path, as those logins do.
  bus="$XDG_RUNTIME_DIR/bus"; [ -e "$bus" ] && bus="$XDG_RUNTIME_DIR/bus-blip-test"
  # In the foreground (detached), so the services it starts (the portals) log to session-bus.log.
  setsid dbus-daemon --session --address="unix:path=$bus" --nofork > "$OUT/session-bus.log" 2>&1 < /dev/null &
  export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"
  wait_until 10 test -S "$bus"
else
  eval "$(dbus-launch --sh-syntax)"
fi
env_out DBUS_SESSION_BUS_ADDRESS "$DBUS_SESSION_BUS_ADDRESS"
env_out NO_AT_BRIDGE 0
env_out ACCESSIBILITY_ENABLED 1
dbus-send --session --print-reply --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress > /dev/null 2>&1 || true
dbus-send --session --dest=org.a11y.Bus /org/a11y/bus org.freedesktop.DBus.Properties.Set \
  string:org.a11y.Status string:IsEnabled variant:boolean:true > /dev/null 2>&1 || true

# Sound.
pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=file:"$OUT/pulseaudio.log" 2>> "$OUT/pulseaudio.log"
wait_until 10 pactl info
pactl load-module module-null-sink sink_name=speakers sink_properties=device.description=Speakers > /dev/null
pactl load-module module-null-sink sink_name=voice sink_properties=device.description=Test_Voice > /dev/null
pactl load-module module-remap-source master=voice.monitor source_name=testmic \
  source_properties=device.description=Test_Microphone > /dev/null
pactl set-default-sink speakers
pactl set-default-source testmic
{ echo "sinks:"; pactl list short sinks; echo "sources:"; pactl list short sources; } > "$OUT/audio-devices.txt" 2>&1

# Display.
gnome_call() { gdbus call --session -d org.gnome.Shell -o /app/blipai/TestShell -m "app.blipai.TestShell.$1" "${@:2}"; }
newest() { ls -t "$@" 2> /dev/null | head -n 1; }
start_virtual_keyboard() {  # GNOME and KDE: /dev/uinput is root's there (uinput-as-installed.sh)
  rm -f "$KEYS_FIFO"; mkfifo "$KEYS_FIFO"
  if [ "$DESKTOP" = gnome ]; then
    setsid bash -c "'$PY' '$here/keys.py' gnome '$KEYS_FIFO' 2>> '$OUT/keys-gnome.log' | sudo -n '$PY' '$here/keys.py' serve -" \
      > "$OUT/keys.log" 2>&1 < /dev/null &
  else
    setsid sudo -n "$PY" "$here/keys.py" serve "$KEYS_FIFO" > "$OUT/keys.log" 2>&1 < /dev/null &
  fi
}
if [ -n "${DESKTOP:-}" ]; then
  . /etc/os-release
  env_out XDG_SESSION_TYPE wayland
  if [ "$DESKTOP" = gnome ]; then
    # What a GNOME login sets: Ubuntu's session is "ubuntu:GNOME", Fedora's "GNOME".
    if [ "$ID" = ubuntu ]; then env_out XDG_CURRENT_DESKTOP ubuntu:GNOME; env_out XDG_SESSION_DESKTOP ubuntu
    else env_out XDG_CURRENT_DESKTOP GNOME; env_out XDG_SESSION_DESKTOP gnome; fi
    env_out DESKTOP_SESSION "$XDG_SESSION_DESKTOP"
    env_out GNOME_DESKTOP_SESSION_ID this-is-deprecated   # gnome-session sets it; Ubuntu's xdg-open 1.1.3 knows GNOME by it
    # Screen readers' setting (GNOME Shell and GTK fill the accessibility tree), no screen
    # lock in a headless session, and the test's stand-in for the keyboard and mouse
    # (gnome-shell-extension/: a keyboard on the seat, focus by title, screenshots).
    gsettings set org.gnome.desktop.interface toolkit-accessibility true
    gsettings set org.gnome.desktop.session idle-delay 0
    gsettings set org.gnome.desktop.screensaver lock-enabled false
    gsettings set org.gnome.shell welcome-dialog-last-shown-version '9999' 2> /dev/null
    ext="$HOME/.local/share/gnome-shell/extensions/blip-test@blipai.app"
    mkdir -p "$ext" && cp "$here"/gnome-shell-extension/* "$ext/"
    gsettings set org.gnome.shell enabled-extensions "['blip-test@blipai.app']"
    gsettings set org.gnome.shell disable-user-extensions false
    args=(--headless --virtual-monitor 1280x800)
    gnome-shell --help 2>&1 | grep -q -- '--wayland ' && args=(--wayland "${args[@]}")
    setsid gnome-shell "${args[@]}" > "$OUT/gnome-shell.log" 2>&1 < /dev/null &
    wait_until 60 bash -c "ls '$XDG_RUNTIME_DIR'/wayland-* 2>/dev/null | grep -qv lock"
    env_out WAYLAND_DISPLAY "$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* | grep -v lock | head -n 1)")"
    # Mutter runs Xwayland for X11 apps (the app is one) and says on which display.
    wait_until 30 grep -q 'Using public X11 display' "$OUT/gnome-shell.log"
    env_out DISPLAY "$(grep -oE 'Using public X11 display :[0-9]+' "$OUT/gnome-shell.log" | head -n 1 | grep -oE ':[0-9]+')"
    env_out XAUTHORITY "$(newest "$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.*)"
    if wait_until 60 gnome_call Windows; then
      gnome_call HideOverview > /dev/null   # GNOME starts in the Activities overview; a person clicks out of it
      record INFO "Session" "GNOME Shell $(gnome-shell --version | awk '{print $3}') (headless, Wayland, 1280x800) with Xwayland on $DISPLAY; $XDG_CURRENT_DESKTOP"
    else
      record HARNESS "Session: GNOME Shell with the test's helper" "no GNOME Shell or its test extension after 60 s: $(grep -E 'ERROR|JS ERROR|Error|extension' "$OUT/gnome-shell.log" | tail -n 3 | paste -sd' ' | cut -c1-250)"
    fi
  else
    env_out XDG_CURRENT_DESKTOP KDE
    env_out XDG_SESSION_DESKTOP KDE
    env_out DESKTOP_SESSION plasma
    env_out KDE_FULL_SESSION true
    env_out KDE_SESSION_VERSION 6
    env_out QT_LINUX_ACCESSIBILITY_ALWAYS_ON 1
    kbuildsycoca6 > "$OUT/kbuildsycoca.log" 2>&1
    setsid pipewire > "$OUT/pipewire.log" 2>&1 < /dev/null &
    sleep 1
    setsid wireplumber > "$OUT/wireplumber.log" 2>&1 < /dev/null &
    xs_before=$(ls /tmp/.X11-unix 2> /dev/null | xargs)
    QT_FORCE_STDERR_LOGGING=1 QT_LOGGING_RULES="kwin_core.debug=false;kwin_scripting.debug=true" \
      setsid kwin_wayland --virtual --xwayland --width 1280 --height 800 --socket wayland-0 > "$OUT/kwin.log" 2>&1 < /dev/null &
    wait_until 60 test -S "$XDG_RUNTIME_DIR/wayland-0"
    env_out WAYLAND_DISPLAY wayland-0
    wait_until 30 bash -c "[ \"\$(ls /tmp/.X11-unix 2>/dev/null | xargs)\" != '$xs_before' ]"
    xs=$(comm -13 <(tr ' ' '\n' <<< "$xs_before" | sort) <(ls /tmp/.X11-unix | sort) | head -n 1)
    env_out DISPLAY ":${xs#X}"
    # KWin starts Xwayland on the first X11 client; it takes clients without an auth file.
    xa=$(newest "$XDG_RUNTIME_DIR"/xauth_* "$XDG_RUNTIME_DIR"/.Xauthority*); [ -n "$xa" ] && env_out XAUTHORITY "$xa"
    if pgrep -x kwin_wayland > /dev/null && [ -n "$xs" ]; then
      record INFO "Session" "KDE Plasma's KWin $(kwin_wayland --version 2>/dev/null | awk '{print $2}') (virtual, Wayland, 1280x800) with Xwayland on $DISPLAY"
    else
      record HARNESS "Session: KWin" "KWin isn't up: $(tail -n 3 "$OUT/kwin.log" | paste -sd' ' | cut -c1-250)"
    fi
  fi
  # The portals start on demand, with this session's environment.
  dbus-update-activation-environment XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION \
    WAYLAND_DISPLAY DISPLAY ${XAUTHORITY:+XAUTHORITY} XDG_RUNTIME_DIR ${GNOME_DESKTOP_SESSION_ID:+GNOME_DESKTOP_SESSION_ID} ${KDE_FULL_SESSION:+KDE_FULL_SESSION KDE_SESSION_VERSION QT_LINUX_ACCESSIBILITY_ALWAYS_ON} > /dev/null 2>&1
  # What the app says over D-Bus that the test can't see in its silent release log: the
  # RemoteDesktop portal calls (the paste path) and its notifications (the clipboard fallback).
  setsid dbus-monitor --session "interface='org.freedesktop.portal.RemoteDesktop'" \
    "type='signal',interface='org.freedesktop.portal.Request',member='Response'" \
    "interface='org.freedesktop.Notifications',member='Notify'" > "$OUT/portal-dbus.log" 2>&1 < /dev/null &
  # Does the desktop's RemoteDesktop portal answer? (No dialog for this step.) If it
  # doesn't, the app's paste permission can't work here, and that's the harness's problem.
  if probe=$(with_timeout 70 "$PY" "$here/portal-probe.py" 60 2>&1); then
    record PASS "Session: the desktop's RemoteDesktop portal answers" "$probe"
  else
    touch "$OUT/.portal-broken"   # paste checks can't blame the app then (lib.sh, onboarding.sh)
    record HARNESS "Session: the desktop's RemoteDesktop portal answers" "$probe; $(grep -iE 'portal|error|warn' "$OUT/session-bus.log" | tail -n 3 | paste -sd' ' | cut -c1-250)"
  fi
  start_virtual_keyboard
  if wait_until 10 grep -q 'ready /dev/input/event' "$OUT/keys.log"; then
    record PASS "Virtual keyboard on /dev/input" "$(head -n 1 "$OUT/keys.log")$( [ "$DESKTOP" = gnome ] && echo "; its keys reach GNOME Shell too")"
  else
    record HARNESS "Virtual keyboard on /dev/input" "keys.py: $(tail -n 2 "$OUT/keys.log" | paste -sd' ' | cut -c1-200) ($(ls -l /dev/uinput 2>&1))"
  fi
elif [ "$SESSION" = wayland ]; then
  cat > "$RUNNER_TEMP/sway.cfg" << 'CFG'
output HEADLESS-1 resolution 1280x800
xwayland enable
default_border none
focus_on_window_activation focus
CFG
  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    setsid sway -c "$RUNNER_TEMP/sway.cfg" > "$OUT/sway.log" 2>&1 < /dev/null &
  wait_until 20 bash -c "ls '$XDG_RUNTIME_DIR'/wayland-* 2>/dev/null | grep -qv lock"
  env_out WAYLAND_DISPLAY "$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-* | grep -v lock | head -n 1)")"
  env_out SWAYSOCK "$(ls "$XDG_RUNTIME_DIR"/sway-ipc.* 2>/dev/null | head -n 1)"
  env_out XDG_SESSION_TYPE wayland
  env_out XDG_CURRENT_DESKTOP sway
  # Sway starts XWayland on its own display; the app (Electron) runs through it, as it
  # does by default on GNOME and KDE Wayland too.
  wait_until 20 bash -c "ls /tmp/.X11-unix/ 2>/dev/null | grep -q X"
  env_out DISPLAY ":$(ls /tmp/.X11-unix/ | sed 's/^X//' | sort -n | tail -n 1)"
  # A headless Sway has no keyboard on its seat (keys.py's uinput device is for the app,
  # which reads /dev/input; Sway's headless backend doesn't). Then the first key of every
  # wtype run is lost while the focused window's keyboard focus arrives, and dictations
  # came out as "he quick brown fox". A real desktop always has one, so keep a virtual
  # keyboard on the seat for the whole session (wtype sleeping for a day).
  setsid wtype -s 86400000 > "$OUT/seat-keyboard.log" 2>&1 < /dev/null &
  # The virtual keyboard: plugged in now, before the app starts and opens input devices.
  setsid "$PY" "$here/keys.py" serve "$KEYS_FIFO" > "$OUT/keys.log" 2>&1 < /dev/null &
  record INFO "Session" "Wayland (Sway $(sway --version 2>/dev/null | awk '{print $3}'), headless) with XWayland on $DISPLAY"
  if wait_until 10 grep -q 'ready /dev/input/event' "$OUT/keys.log"; then
    record PASS "Virtual keyboard on /dev/input" "$(head -n 1 "$OUT/keys.log")"
  else
    record FAIL "Virtual keyboard on /dev/input" "keys.py: $(tail -n 2 "$OUT/keys.log" | paste -sd' ' | cut -c1-200) ($(ls -l /dev/uinput 2>&1))"
  fi
else
  setsid Xvfb :99 -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 < /dev/null &
  env_out DISPLAY :99
  wait_until 20 xdpyinfo
  env_out XDG_SESSION_TYPE x11
  setsid openbox > "$OUT/openbox.log" 2>&1 < /dev/null &
  sleep 1
  record INFO "Session" "X11 (Xvfb with Openbox) on $DISPLAY"
fi

# The text box.
setsid "$PY" "$here/target.py" "$TARGET_FILE" > "$OUT/target.log" 2>&1 < /dev/null &
if [ -n "${DESKTOP:-}" ]; then
  if wait_until 20 bash -c "'$PY' '$here/atspi.py' windows target.py | grep -q 'Blip Test Target'"; then
    record PASS "Test text box is up" "$( [ "$DESKTOP" = gnome ] && gnome_call Windows | cut -c1-200)"
  else record HARNESS "Test text box is up" "$(tail -n 3 "$OUT/target.log" | tr '\n' ' ')"; fi
else
  if [ "$SESSION" = wayland ]; then wait_until 20 bash -c "swaymsg -t get_tree | grep -q 'Blip Test Target'"
  else wait_until 20 xdotool search --name 'Blip Test Target'; fi \
    && record PASS "Test text box is up" "" || record FAIL "Test text box is up" "$(tail -n 3 "$OUT/target.log" | tr '\n' ' ')"
fi
