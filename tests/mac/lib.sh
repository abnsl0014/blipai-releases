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
  local n
  n=$(find "$OUT/screens" -name '*.png' | wc -l | tr -d ' ')
  screencapture -x "$OUT/screens/$(printf '%02d' $((n + 1)))-$1.png" 2>/dev/null || true
}

wait_until() {  # wait_until SECONDS command...  → 0 as soon as the command succeeds
  local deadline=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$@" > /dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

retry() {  # retry COMMAND...: up to 4 tries, 10/20/30 s apart, for network blips on the runner
  local try
  for try in 1 2 3 4; do
    "$@" && return 0
    [ "$try" -lt 4 ] && { echo "retrying in $((try * 10)) s: $*" >&2; sleep $((try * 10)); }
  done
  return 1
}

app_running() { pgrep -x "$APP_PROCESS" > /dev/null; }

app_windows() {  # names of the app's windows, comma separated
  osascript -e "tell application \"System Events\" to get name of every window of process \"$APP_PROCESS\"" 2>/dev/null || true
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
  osascript -e "tell application \"$APP_PROCESS\" to quit" > /dev/null 2>&1 || true
  wait_until 15 bash -c "! pgrep -x '$APP_PROCESS'"
}

textedit_text() {
  osascript -e 'tell application "TextEdit" to get text of document 1' 2>/dev/null || true
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
