# Shared helpers for the Linux release test. Sourced by the other scripts.
# Every check appends one line to $RESULTS:  STATUS<TAB>check<TAB>detail
# STATUS is PASS, FAIL, WARN (a real finding that doesn't break users), SKIP or INFO, or
# HARNESS: the test itself couldn't do a step (GNOME and KDE jobs), so nothing about the app
# can be said from it. report.sh turns the file into the job summary and fails the job if any
# line is FAIL or HARNESS.

: "${RUNNER_TEMP:=/tmp}"
: "${OUT:=$RUNNER_TEMP/blip-test}"           # everything uploaded as the run's artifact
: "${RESULTS:=$OUT/results.tsv}"
: "${SESSION:=x11}"                          # x11 or wayland
: "${DESKTOP:=}"                             # gnome or kde (Wayland); empty: Openbox or Sway
: "${SESSION_ENV:=$RUNNER_TEMP/session.env}" # written by session.sh
: "${APP_DIR:=$HOME/.local/bin}"             # where the website's install steps put it
: "${APPIMAGE_PATH:=$APP_DIR/BlipAI.AppImage}"
: "${APP_PROCESS:=blip-ai}"                  # the Electron binary inside the AppImage
: "${TARGET_FILE:=$RUNNER_TEMP/target.txt}"
: "${KEYS_FIFO:=$RUNNER_TEMP/keys.fifo}"
: "${PY:=/usr/bin/python3}"                   # the distro's Python: it has the GTK, AT-SPI and evdev bindings
here_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$OUT/screens" 2> /dev/null
touch "$RESULTS" 2> /dev/null
[ -f "$SESSION_ENV" ] && source "$SESSION_ENV"

record() {  # record STATUS "check" "detail"
  local status="$1" check="$2" detail="${3:-}"
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$status" "$check" "$detail" "$(date -u +%T)" >> "$RESULTS"   # the time lines it up with the logs
  case "$status" in
    FAIL) echo "::error title=$check::$detail" ;;
    HARNESS) echo "::error title=Test harness: $check::$detail" ;;
    WARN|SKIP) echo "::warning title=$check::$detail" ;;
    *) echo "$status  $check  $detail" ;;
  esac
}

wait_until() {  # wait_until SECONDS command...  → 0 as soon as the command succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" > /dev/null 2>&1 && return 0
    sleep 0.5
  done
  return 1
}

with_timeout() { local s="$1"; shift; timeout --kill-after=5 "$s" "$@"; }

retry() {  # retry COMMAND...: up to 4 tries, 10/20/30 s apart, for network blips
  local try
  for try in 1 2 3 4; do
    "$@" && return 0
    [ "$try" -lt 4 ] && { echo "retrying in $((try * 10)) s: $*" >&2; sleep $((try * 10)); }
  done
  return 1
}

# In a subshell: os-release defines VERSION (e.g. "12 (bookworm)"), which would overwrite the
# release version every script uses (and is exported to them). Arch's has none.
distro() { ( . /etc/os-release; echo "${PRETTY_NAME:-$ID}" ); }

screenshot() {  # screenshot NAME → $OUT/screens/NN-NAME.png (private once signed in)
  local dir="$OUT/screens" n
  if [ -f "$OUT/.signed-in" ] && [ "${PUBLISH_SIGNED_IN_SCREENSHOTS:-0}" != 1 ]; then
    dir="$RUNNER_TEMP/private-screens"; mkdir -p "$dir"
  fi
  n=$( (find "$OUT/screens" "$RUNNER_TEMP/private-screens" -name '*.png' 2>/dev/null) | wc -l | tr -d ' ')
  local f="$dir/$(printf '%02d' $((n + 1)))-$1.png"
  if [ "$DESKTOP" = gnome ]; then with_timeout 10 gdbus call --session -d org.gnome.Shell -o /app/blipai/TestShell \
    -m app.blipai.TestShell.Screenshot "$f" > /dev/null 2>&1
  elif [ "$DESKTOP" = kde ]; then with_timeout 10 import -window root "$f" 2>/dev/null   # Xwayland's windows only (the app's)
  elif [ "$SESSION" = wayland ]; then with_timeout 10 grim "$f" 2>/dev/null
  else with_timeout 10 import -window root "$f" 2>/dev/null; fi
  true
}

# --- speech into the virtual mic --------------------------------------------------
# The phrases (phrases.txt) are rendered ahead of time by the workflow's "voice" job on a
# Mac, with macOS's `say` (the voice the Mac test uses), into $SPEECH_DIR/<sha1>.wav.
# Played into the "voice" sink, whose monitor is the default microphone (session.sh).
# Without them (a local run), espeak-ng stands in, which is harder to transcribe.
: "${SPEECH_DIR:=$RUNNER_TEMP/speech}"
speech_file() { echo "$SPEECH_DIR/$(printf '%s' "$1" | sha1sum | cut -c1-12).wav"; }
render_speech() {
  local text f
  mkdir -p "$SPEECH_DIR"
  for text in "$@"; do
    f=$(speech_file "$text")
    if [ ! -s "$f" ] && command -v espeak-ng > /dev/null; then
      espeak-ng -s 150 -w "$f" "$text" 2> /dev/null
      echo "$text" >> "$OUT/speech-fallback.txt"
    fi
  done
}
speak() {  # speak "text": plays it into the virtual mic and returns when it has finished
  render_speech "$1"
  with_timeout 20 paplay --device=voice "$(speech_file "$1")"
}

# --- keys ---------------------------------------------------------------------------
# X11: xdotool (XTEST), which the app's X11 key listener (XInput2) sees like a keyboard.
# Wayland: keys.py's virtual keyboard on /dev/input, which the app reads (evdev).
xkey() { case "$1" in super|win) echo Super_L ;; ctrl) echo Control_L ;; shift) echo Shift_L ;; alt) echo Alt_L ;;
  space) echo space ;; escape) echo Escape ;; return) echo Return ;; *) echo "$1" ;; esac; }
key() {  # key down|up|tap NAME
  if [ "$SESSION" = wayland ]; then  # (a write to the FIFO waits for keys.py; don't wait forever)
    timeout 3 sh -c 'echo "$1 $2" > "$3"' _ "$1" "$2" "$KEYS_FIFO" || echo "key $1 $2: the virtual keyboard isn't listening" >&2
    sleep 0.05
  else
    case "$1" in down) xdotool keydown "$(xkey "$2")" ;; up) xdotool keyup "$(xkey "$2")" ;; tap) xdotool key "$(xkey "$2")" ;; esac
    sleep 0.04
  fi
}
type_keys() {  # Wayland: type_keys TEXT on the test's virtual keyboard (US layout), as a person types
  timeout 15 sh -c 'echo "type $1" > "$2"' _ "$1" "$KEYS_FIFO" || echo "type: the virtual keyboard isn't listening" >&2
  sleep $(( ${#1} / 15 + 1 ))
}
chord() {  # chord ctrl+super+space: press in order, release in reverse
  local k keys=() i
  IFS=+ read -ra keys <<< "$1"
  for k in "${keys[@]}"; do key down "$k"; done
  sleep 0.08
  for ((i=${#keys[@]}-1; i>=0; i--)); do key up "${keys[$i]}"; done
}

# --- the app ------------------------------------------------------------------------
app_running() { pgrep -x "$APP_PROCESS" > /dev/null; }
app_userdata() { find "$HOME/.config" -maxdepth 1 -type d -iname '*blip*' 2>/dev/null | head -n 1; }
app_log() { find "$HOME/.config" -maxdepth 4 -ipath '*blip*' -name main.log 2>/dev/null | head -n 1; }
app_config() { find "$HOME/.config" -maxdepth 2 -ipath '*blip*' -name config.json 2>/dev/null | head -n 1; }
log_has() { local l; l=$(app_log); [ -n "$l" ] && grep -qa -- "$1" "$l"; }

# Starts the AppImage the way the website says (~/.local/bin/BlipAI.AppImage), with
# Chromium's accessibility tree on so the test can read the windows. On Wayland it runs
# with the `input` group, as after the website's "join the input group, then log in again".
wtype_shim() {  # Wayland: puts a wtype in front of the real one that notes each call the app
  # makes and whether Blip's overlay was on screen then (run 4, Debian 13 on Sway: every
  # dictation was transcribed but its text never reached the box; Paste last, with no
  # overlay, did). Prints the folder to put first on the app's PATH.
  local dir="$RUNNER_TEMP/shim" real
  real=$(command -v wtype) || return 0
  mkdir -p "$dir"
  cat > "$dir/wtype" << EOF
#!/bin/sh
v=no; DISPLAY="$DISPLAY" xdotool search --onlyvisible --name '^Blip AI Overlay\$' > /dev/null 2>&1 && v=yes
echo "\$(date +%T.%3N) wtype called; Blip's overlay on screen: \$v" >> "$OUT/wtype-calls.log"
exec "$real" "\$@"
EOF
  chmod +x "$dir/wtype"
  echo "$dir"
}
paste_tool_shims() {  # GNOME and KDE: like wtype_shim, for every tool the app's Wayland
  # paste runs (wtype, then ydotool, then wl-copy for the portal paste or the clipboard
  # fallback): each call and its exit code go to paste-tools.log. Prints the folder.
  local dir="$RUNNER_TEMP/shim" real t
  mkdir -p "$dir"
  for t in wtype ydotool wl-copy; do
    real=$(PATH="${PATH//$dir:/}" command -v "$t") || continue
    [ "$real" = "$dir/$t" ] && continue
    cat > "$dir/$t" << EOF
#!/bin/sh
"$real" "\$@"; rc=\$?
echo "\$(date +%s%3N) \$(date +%T.%3N) $t \$* -> exit \$rc" >> "$OUT/paste-tools.log"
exit \$rc
EOF
    chmod +x "$dir/$t"
  done
  echo "$dir"
}
launch_app() {  # launch_app [ARGS...]
  local cmd=("$APPIMAGE_PATH" --force-renderer-accessibility ${APP_EXTRA_ARGS:-} "$@") shim
  if [ -n "$DESKTOP" ]; then shim=$(paste_tool_shims); cmd=(env "PATH=$shim:$PATH" "${cmd[@]}")
  elif [ "$SESSION" = wayland ]; then shim=$(wtype_shim); [ -n "$shim" ] && cmd=(env "PATH=$shim:$PATH" "${cmd[@]}"); fi
  if [ "$SESSION" = wayland ] && ! id -nG | grep -qw input; then
    setsid sg input -c "$(printf '%q ' "${cmd[@]}")" >> "$OUT/app-stdout.log" 2>> "$OUT/app-stderr.log" < /dev/null &
  else
    setsid "${cmd[@]}" >> "$OUT/app-stdout.log" 2>> "$OUT/app-stderr.log" < /dev/null &
  fi
  wait_until 40 app_running
}
app_main_pid() {  # the app's main process: the blip-ai that isn't one of Chromium's --type= helpers
  local pid
  for pid in $(pgrep -x "$APP_PROCESS"); do
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q -- '--type=' || { echo "$pid"; return; }
  done
}
quit_app() {  # SIGTERM to the main process, as a logout or `systemctl stop` sends; the app
  # quits through app.quit() and closes its helpers itself. (Signalling every blip-ai
  # process kills Chromium's GPU and network helpers under it, and it aborts.)
  local pid; pid=$(app_main_pid)
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null
  wait_until 20 bash -c "! pgrep -x '$APP_PROCESS' > /dev/null" && return 0
  # Still up: note which processes are left and what they're doing, for the report
  # (release builds log nothing on quit). QUIT_LEFT is read by the caller.
  QUIT_LEFT=$(for p in $(pgrep -x "$APP_PROCESS"); do
    printf '%s %s(%s, %s) ' "$( [ "$p" = "$pid" ] && echo main || echo helper)" \
      "$(tr '\0' ' ' < /proc/$p/cmdline 2> /dev/null | grep -oE -- '--type=[a-z-]+' | head -n 1)" \
      "$(awk '{print $3}' /proc/$p/stat 2> /dev/null)" "$(cat /proc/$p/wchan 2> /dev/null)"
  done)
  ps -o pid,ppid,stat,etime,args -p "$(pgrep -d, -x "$APP_PROCESS")" > "$OUT/quit-left-$(date +%H%M%S).txt" 2>&1
  hang_snapshot quit
  return 1
}
hang_snapshot() {  # hang_snapshot NAME → $OUT/hang-NAME-HHMMSS.txt, for a stuck app: every
  # blip-ai process with each thread's state and kernel wait, the kernel stack of each thread
  # that isn't idling in a poll or futex, and a gdb backtrace of every thread of each process
  # that isn't one of Chromium's --type= helpers (Electron's symbols: electron-vX-linux-x64-symbols.zip).
  local f="$OUT/hang-$1-$(date +%H%M%S).txt" p t w
  {
    ps -o pid,ppid,stat,etime,args -p "$(pgrep -d, -x "$APP_PROCESS")" 2>&1
    for p in $(pgrep -x "$APP_PROCESS"); do
      echo; echo "=== pid $p: $(tr '\0' ' ' < /proc/$p/cmdline 2> /dev/null | cut -c1-160)"
      for t in /proc/$p/task/*; do
        w=$(cat "$t/wchan" 2> /dev/null)
        echo "tid ${t##*/} $(cat "$t/comm" 2> /dev/null) $(awk '{print $3}' "$t/stat" 2> /dev/null) $w"
        case "$w" in futex_*|do_epoll_wait|ep_poll|do_sys_poll|poll_schedule_timeout*|do_select|hrtimer_nanosleep|do_nanosleep|0) ;;
          *) sudo -n cat "$t/stack" 2> /dev/null | sed 's/^/    /' ;; esac
      done
      if ! tr '\0' ' ' < /proc/$p/cmdline 2> /dev/null | grep -q -- '--type=' && command -v gdb > /dev/null; then
        echo "--- where blip-ai is loaded (to symbolize its frames)"; grep -m 2 -E '/blip-ai$' "/proc/$p/maps" 2> /dev/null
        echo "--- gdb: thread apply all bt"
        with_timeout 60 sudo -n gdb -p "$p" -batch -nx -ex 'set pagination off' -ex 'thread apply all bt 40' 2>&1 \
          | grep -vE '^\[(New LWP|Thread debugging|Inferior)|^Using host libthread_db|^warning: (Could not|Unable)' | head -n 600
      fi
    done
  } > "$f" 2>&1
}
app_windows() { with_timeout 20 "$PY" "$here_lib/atspi.py" windows "$APP_PROCESS" 2>/dev/null; }
ui_dump() {  # ui_dump NAME [WINDOW] → $OUT/ui-NAME.txt
  local try
  for try in 1 2 3; do
    with_timeout 40 "$PY" "$here_lib/atspi.py" text "$APP_PROCESS" ${2:+"$2"} > "$OUT/ui-$1.txt" 2>&1 || true
    grep -qv '^== window' "$OUT/ui-$1.txt" && return 0
    sleep 2
  done
}
press() { with_timeout 40 "$PY" "$here_lib/atspi.py" press "$APP_PROCESS" "$@" 2>&1; }

# --- the text box -------------------------------------------------------------------
focus_window() {  # GNOME and KDE: focus_window TITLE, as a click on that window would
  if [ "$DESKTOP" = gnome ]; then
    gdbus call --session -d org.gnome.Shell -o /app/blipai/TestShell -m app.blipai.TestShell.Focus "$1" 2> /dev/null | grep -q true
  else  # a KWin script, through KWin's D-Bus scripting interface
    local js="$RUNNER_TEMP/kwin-focus.js" id
    printf 'for (const w of workspace.windowList()) if (w.caption === %s) workspace.activeWindow = w;\n' \
      "$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1")" > "$js"
    gdbus call --session -d org.kde.KWin -o /Scripting -m org.kde.kwin.Scripting.unloadScript blipfocus > /dev/null 2>&1
    id=$(gdbus call --session -d org.kde.KWin -o /Scripting -m org.kde.kwin.Scripting.loadScript "$js" blipfocus 2> /dev/null | grep -oE '[0-9]+' | head -n 1)
    [ -n "$id" ] && gdbus call --session -d org.kde.KWin -o "/Scripting/Script$id" -m org.kde.kwin.Script.run > /dev/null 2>&1
    gdbus call --session -d org.kde.KWin -o /Scripting -m org.kde.kwin.Scripting.unloadScript blipfocus > /dev/null 2>&1
    [ -n "$id" ]
  fi
}
focus_target_once() {
  if [ -n "$DESKTOP" ]; then focus_window "Blip Test Target"
  elif [ "$SESSION" = wayland ]; then swaymsg '[title="Blip Test Target"] focus' > /dev/null 2>&1
  else xdotool search --name 'Blip Test Target' windowactivate --sync > /dev/null 2>&1 || true; fi
}
target_has_focus() {  # the box's own last focus event says it has the keyboard
  [ "$(grep -E 'window (focused|lost focus)$' "$TARGET_FILE.events" 2> /dev/null | tail -n 1 | cut -d' ' -f2-)" = "window focused" ]
}
focus_target() {
  touch "$TARGET_FILE.clear"
  sleep 0.6
  DICTATION_FROM=$(date +%s%3N)   # paste_path looks at what the app did from here on
  focus_target_once
  sleep 0.5
  # Right after a (re)launch the app's own window can take focus back as it comes up
  # (GNOME, Fedora 42: the box was focused and lost it in the same millisecond, so the
  # first dictation went to the app's window). Focus once more, as a person would click
  # back; each retry is logged, so an app that keeps taking focus still shows up.
  if [ -f "$TARGET_FILE.events" ] && ! target_has_focus; then
    echo "$(date -u +%T) refocused the text box (it had lost focus)" >> "$OUT/focus-retries.log"
    sleep 1; focus_target_once; sleep 0.5
  fi
}
target_text() { cat "$TARGET_FILE" 2>/dev/null; }
target_has_text() { [ -n "$(target_text | tr -d '[:space:]')" ]; }
wait_text() {  # wait_text SECONDS → prints the box's text once something was typed
  local deadline=$(( $(date +%s) + ${1:-30} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if target_has_text; then sleep 2; target_text; return 0; fi
    sleep 0.25
  done
  return 1
}
word_recall() {  # word_recall ACTUAL EXPECTED → % of expected words found (case/punctuation ignored)
  python3 - "$1" "$2" << 'PY'
import re, sys
norm = lambda s: re.findall(r"[a-z0-9']+", s.lower())
have, want = set(norm(sys.argv[1])), norm(sys.argv[2])
print(round(100 * sum(w in have for w in want) / len(want)) if want else 0)
PY
}
paste_path() {  # GNOME and KDE: how the app tried to type since focus_target, from the
  # paste tools it ran (paste-tools.log) and its portal calls and notices (portal-dbus.log)
  "$PY" "$here_lib/paste-path.py" "${DICTATION_FROM:-0}" "$OUT/paste-tools.log" "$OUT/portal-dbus.log" "$TARGET_FILE.events" 2> /dev/null
}
judge() {  # judge CHECK EXPECTED ACTUAL [MIN_RECALL%]
  local how=""
  [ -n "$DESKTOP" ] && how=$(paste_path)   # say which way the text went (or didn't)
  judge_plain "$1" "$2" "$3" "${4:-70}" "${how:+; typing path: $how}"
}
judge_plain() {
  local name="$1" expected="$2" actual="$3" min="$4" extra="$5" recall shown
  # GNOME and KDE: with a portal that doesn't answer (session.sh's probe), nothing the
  # app does can paste; say so rather than blame it.
  local FAIL=FAIL; [ -n "$DESKTOP" ] && [ -f "$OUT/.portal-broken" ] && { FAIL=HARNESS; extra="$extra (the desktop's portal didn't answer the test's own probe)"; }
  if [ -z "$(printf '%s' "$actual" | tr -d '[:space:]')" ]; then
    local got wt=""; got=$(tail -n 6 "$TARGET_FILE.events" 2>/dev/null | cut -c14- | paste -sd, - | cut -c1-200)
    # On Wayland, say whether the app typed at all, and whether its overlay was up then.
    [ "$SESSION" = wayland ] && [ -s "$OUT/wtype-calls.log" ] && wt="; last wtype call: $(tail -n 1 "$OUT/wtype-calls.log")"
    record $FAIL "$name" "nothing was typed into the text box within 30 s; the box got: ${got:-nothing}$wt$extra"
    return 1
  fi
  recall=$(word_recall "$actual" "$expected")
  shown=$(printf '%s' "$actual" | tr '\n' ' ' | cut -c1-140)
  if [ "$recall" -ge "$min" ]; then record PASS "$name" "$recall% of the spoken words; typed: \"$shown\"$extra"
  else record $FAIL "$name" "$recall% of the spoken words (need $min%); typed: \"$shown\"$extra"; return 1; fi
}
