#!/bin/bash
# Starts what a desktop session provides, for the user running the test:
#   - a D-Bus session bus and the accessibility bus (AT-SPI)
#   - a display: SESSION=x11 → Xvfb with the Openbox window manager;
#                SESSION=wayland → Sway (headless) with XWayland, as on the website's
#                wlroots path (Sway/Hyprland: wtype types, no ydotool daemon needed)
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
eval "$(dbus-launch --sh-syntax)"
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
if [ "$SESSION" = wayland ]; then
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
if [ "$SESSION" = wayland ]; then wait_until 20 bash -c "swaymsg -t get_tree | grep -q 'Blip Test Target'"
else wait_until 20 xdotool search --name 'Blip Test Target'; fi \
  && record PASS "Test text box is up" "" || record FAIL "Test text box is up" "$(tail -n 3 "$OUT/target.log" | tr '\n' ' ')"
