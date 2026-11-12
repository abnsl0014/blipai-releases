# Shared helpers for the Mac release test. Sourced by the other scripts.
# Every check appends one line to $RESULTS:  STATUS<TAB>check<TAB>detail
# STATUS is PASS, FAIL, WARN (a real finding that doesn't break users), SKIP or INFO.
# report.sh turns the file into the job summary and fails the job if any line is FAIL.

: "${OUT:=$RUNNER_TEMP/blip-test}"          # everything uploaded as the run's artifact
: "${RESULTS:=$OUT/results.tsv}"
: "${APP:=/Applications/Blip-AI.app}"
: "${APP_PROCESS:=Blip-AI}"
: "${KEYS:=$RUNNER_TEMP/keys}"
mkdir -p "$OUT/screens"
touch "$RESULTS"

record() {  # record STATUS "check" "detail"
  local status="$1" check="$2" detail="${3:-}"
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\n' "$status" "$check" "$detail" >> "$RESULTS"
  case "$status" in
    FAIL) echo "::error title=$check::$detail" ;;
    WARN|SKIP) echo "::warning title=$check::$detail" ;;
    *) echo "$status  $check  $detail" ;;
  esac
}

check() {  # check "name" command...  → PASS if the command succeeds, FAIL otherwise
  local name="$1"; shift
  local output
  if output="$("$@" 2>&1)"; then
    record PASS "$name" "$(printf '%s' "$output" | tail -n 1 | cut -c1-200)"
  else
    record FAIL "$name" "$(printf '%s' "$output" | tail -n 3 | tr '\n' ' ' | cut -c1-300)"
  fi
}

screenshot() {  # screenshot name  → $OUT/screens/NN-name.png
  # Once the test account is signed in, the screen shows its email, plan and usage, and
  # the artifact is public. Those screenshots stay on the runner unless
  # PUBLISH_SIGNED_IN_SCREENSHOTS=1; the window text (redacted) still goes up.
  local dir="$OUT/screens" n
  if [ -f "$OUT/.signed-in" ] && [ "${PUBLISH_SIGNED_IN_SCREENSHOTS:-0}" != 1 ]; then
    dir="$RUNNER_TEMP/private-screens"
    mkdir -p "$dir"
  fi
  n=$( (find "$OUT/screens" "$RUNNER_TEMP/private-screens" -name '*.png' 2>/dev/null) | wc -l | tr -d ' ')
  screencapture -x "$dir/$(printf '%02d' $((n + 1)))-$1.png" 2>/dev/null || true
}

wait_until() {  # wait_until SECONDS command...  → 0 as soon as the command succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" > /dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

with_timeout() {  # with_timeout SECONDS COMMAND... → the command, killed (exit 142) if it runs longer
  local seconds="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}
# osascript can wait forever, e.g. on an automation prompt nobody can click.
osa() { with_timeout 20 osascript "$@"; }

retry() {  # retry COMMAND...: up to 4 tries, 10/20/30 s apart, for network blips on the runner
  local try
  for try in 1 2 3 4; do
    "$@" && return 0
    [ "$try" -lt 4 ] && { echo "retrying in $((try * 10)) s: $*" >&2; sleep $((try * 10)); }
  done
  return 1
}

# Speech into the virtual mic. Each phrase is synthesized to a file once and then played
# with sox, which starts at once: `say` itself can take ~3 s to start talking on a cold
# runner (seen on macOS 26), which would put unpredictable silence into every dictation.
speech_file() { echo "$RUNNER_TEMP/speech-$(printf '%s' "$1" | shasum | cut -c1-12).aiff"; }
render_speech() {  # render_speech "text"... → synthesize ahead of time
  local text
  for text in "$@"; do
    [ -s "$(speech_file "$text")" ] || with_timeout 60 say -o "$(speech_file "$text")" "$text"
  done
}
speak() {  # speak "text" → plays it into BlackHole 2ch and returns when it has finished
  speak_to "BlackHole 2ch" "$1"
}
speak_to() {  # speak_to DEVICE "text" → the same, into another virtual device
  render_speech "$2"
  with_timeout 30 sox -q "$(speech_file "$2")" -t coreaudio "$1"
}

app_running() { pgrep -x "$APP_PROCESS" > /dev/null; }

app_windows() {  # names of the app's windows, comma separated
  osa -e "tell application \"System Events\" to get name of every window of process \"$APP_PROCESS\"" 2>/dev/null || true
}

app_log() {  # path of the app's electron-log file (it only exists once something was logged)
  find "$HOME/Library/Logs" "$HOME/Library/Application Support" -maxdepth 3 -ipath '*blip*' \
    -name 'main.log' 2>/dev/null | head -n 1
}

app_config() {  # path of the app's electron-store file
  find "$HOME/Library/Application Support" -maxdepth 2 -ipath '*blip*' -name 'config.json' 2>/dev/null | head -n 1
}

log_files() {  # logs written in the last 15 minutes, for a check that found none of the app's
  find "$HOME/Library/Logs" "$HOME/Library/Application Support" -maxdepth 4 -name '*.log' -mmin -15 \
    2>/dev/null | head -n 8 | xargs
}

launch_app() {
  # Through LaunchServices, like a person double-clicking it. Running the binary from
  # this shell would make the shell the "responsible process" for macOS privacy
  # checks, and the test would then use the runner's permissions, not the app's.
  open -a "$APP"
  wait_until 30 app_running
}

quit_app() {  # quit the way the tray's Quit does, then make sure nothing is left behind
  osa -e "tell application \"$APP_PROCESS\" to quit" > /dev/null 2>&1 || true
  wait_until 15 bash -c "! pgrep -x '$APP_PROCESS'"
}

textedit_text() {
  osa -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null || true
}

# Words of $2 (expected) found in $1 (actual), as a percentage. Case and punctuation
# are ignored; numbers are kept as written by the transcriber.
word_recall() {
  python3 - "$1" "$2" << 'PY'
import re, sys
norm = lambda s: re.findall(r"[a-z0-9']+", s.lower())
actual, expected = set(norm(sys.argv[1])), norm(sys.argv[2])
print(round(100 * sum(w in actual for w in expected) / max(1, len(expected))))
PY
}
