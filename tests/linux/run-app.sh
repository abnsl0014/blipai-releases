#!/bin/bash
# Runs the installed AppImage the way a new user does and checks what they'd see:
#   1. first launch, signed out: the app starts, stays up and shows onboarding; it registers
#      the blipai:// link handler and the blip-ai command, and checks for updates
#   2. sign-in through the blipai://auth link, opened with xdg-open as a browser would
#   3. relaunch signed in: home window, key listener running (X11: X11KeyServer;
#      Wayland: the app reading /dev/input)
#   4. dictation into the text box: push-to-talk (hold Ctrl+Super), hands-free
#      (Ctrl+Super+Space), filler words, Esc to cancel, Paste last transcript (Shift+Alt+Z),
#      a failed transcription kept as a Missed item with Save audio and Retry, history
#   5. the session ends while the app runs (with the 0.5.10 notices where the build has them)
#   6. quit: the app, its key listener and its AppImage mount go away; relaunching with the
#      ended session asks to sign in
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
touch "$OUT/.started"
# The report runs outside a distro container, so leave the app's log (redacted there) and
# the text box's event log in the shared folder, however this script ends.
keep_logs() {
  local l; l=$(app_log)
  [ -n "$l" ] && cp "$l" "$OUT/main.log"
  [ -f "$TARGET_FILE.events" ] && cp "$TARGET_FILE.events" "$OUT/target-box-events.txt"
}
trap keep_logs EXIT

SUPABASE_URL="${SUPABASE_URL:-https://hqwmccawtepvundsgnil.supabase.co}"   # public, from auth.js
SUPABASE_KEY="${SUPABASE_KEY:-sb_publishable_TCu8hwzGitgxmzCu2rYHiA_6r3MImeD}"
app_has() { [ -n "${APP_ASAR:-}" ] && grep -qaF -- "$1" "$APP_ASAR"; }
signed_in() {
  local c; c=$(app_config)
  [ -n "$c" ] && python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("authToken") else 1)' "$c"
}
key_listener() {  # prints how the app listens for the hotkey, or nothing
  local pid; pid=$(pgrep -x "$APP_PROCESS" | head -n 1)
  if [ "$SESSION" = wayland ]; then
    local n; n=$(ls -l /proc/$pid/fd 2>/dev/null | grep -c '/dev/input/event')
    [ "$n" -gt 0 ] && echo "the app has $n input devices open (evdev)"
  else
    pgrep -f X11KeyServer > /dev/null && echo "X11KeyServer running"
  fi
}
appimage_mounts() { mount 2>/dev/null | grep -c '/tmp/.mount_Blip' ; }
newest_record() {  # "<status> <timestamp> <text>" of the newest history item
  python3 -c '
import json, sys
h = json.load(open(sys.argv[1])).get("transcriptionHistory") or []
r = h[0] if h else {}
print(r.get("status") or "ok", r.get("timestamp") or 0, (r.get("text") or "").replace("\n", " "))
' "$(app_config)" 2>/dev/null
}
ptt() {  # ptt "phrase": hold Ctrl+Super, speak, release
  key down ctrl; key down super; sleep 0.6
  [ -n "${1:-}" ] && speak "$1"
  sleep 0.8; key up super; key up ctrl
  RELEASED_AT=$(date +%s%3N)
}
render_speech "The quick brown fox jumps over the lazy dog near the river bank." \
  "Please send the quarterly report to the whole team before Friday afternoon." \
  "Um, so I think we should, uh, move the meeting to next week." \
  "This sentence should never be typed." "Remember to water the plants on Saturday morning."
[ -s "$OUT/speech-fallback.txt" ] && record INFO "Test voice" "espeak-ng (the voice job's recordings were missing)"

# --- 1. First launch, signed out ---------------------------------------------------
if ! launch_app; then
  record FAIL "Launches" "no $APP_PROCESS process after 40 s: $(tail -n 3 "$OUT/app-stderr.log" | tr '\n' ' ' | cut -c1-250)"
fi
sleep 15
if ! app_running && grep -qiE 'sandbox|setuid' "$OUT/app-stderr.log"; then
  # What a person sees when Chromium's sandbox can't start (e.g. Ubuntu 24.04's AppArmor
  # limits on user namespaces): the app exits at once. Note it, and go on with --no-sandbox.
  record FAIL "Starts without extra flags" "exits at once: $(grep -m1 -iE 'sandbox|setuid' "$OUT/app-stderr.log" | cut -c1-220)"
  echo "export APP_EXTRA_ARGS=--no-sandbox" >> "$SESSION_ENV"; export APP_EXTRA_ARGS=--no-sandbox
  launch_app; sleep 15
fi
screenshot first-launch
if app_running; then record PASS "Starts and stays up (15 s)" "on $(distro), ${SESSION}"
else record FAIL "Starts and stays up (15 s)" "exited: $(tail -n 3 "$OUT/app-stderr.log" | tr '\n' ' ' | cut -c1-250)"; exit 0; fi
windows=$(app_windows)
if grep -qi welcome <<< "$windows"; then record PASS "Shows onboarding on first launch" "windows: $windows"
else record FAIL "Shows onboarding on first launch" "windows: ${windows:-none readable over AT-SPI}"; fi
ui_dump onboarding
record INFO "Onboarding text" "$(grep -v '^== window' "$OUT/ui-onboarding.txt" | awk 'NF' | head -n 12 | paste -sd'|' | cut -c1-300)"

handler=$(xdg-mime query default x-scheme-handler/blipai 2>/dev/null)
exec_line=$(grep -m1 '^Exec=' "$HOME/.local/share/applications/${handler:-blip-ai.desktop}" 2>/dev/null)
if [ -n "$handler" ] && grep -qF "$APPIMAGE_PATH" <<< "$exec_line"; then record PASS "Registers the blipai:// link handler" "$handler: $exec_line"
else record FAIL "Registers the blipai:// link handler" "handler: ${handler:-none}; ${exec_line:-no desktop entry}"; fi
shim=$(readlink "$APP_DIR/blip-ai" 2>/dev/null)
[ "$shim" = "$APPIMAGE_PATH" ] && record PASS "Installs the blip-ai command" "$APP_DIR/blip-ai → $shim" \
  || record WARN "Installs the blip-ai command" "$APP_DIR/blip-ai → ${shim:-missing} (the website's compositor keybindings use it)"

update_line=$(grep -m1 -aE "Found version|is not available|Error: " "$(app_log)" 2>/dev/null)
if [ -z "$update_line" ]; then record FAIL "Update check on launch" "no update check in main.log 15 s after launch"
elif [ "$TAG" = "${LATEST_TAG:-}" ] && grep -q "is not available" <<< "$update_line"; then record PASS "Update check on launch" "up to date: $(sed 's/.*\] //' <<< "$update_line" | cut -c1-160)"
elif [ "$TAG" = "${LATEST_TAG:-}" ]; then record FAIL "Update check on launch" "$(cut -c1-200 <<< "$update_line")"
else record INFO "Update check on launch" "$(sed 's/.*\] //' <<< "$update_line" | cut -c1-200)"; fi

# --- 2. Sign in ---------------------------------------------------------------------
if [ -z "${BLIP_TEST_EMAIL:-}" ] || [ -z "${BLIP_TEST_PASSWORD:-}" ]; then
  record SKIP "Sign in and dictation" "add the BLIP_TEST_EMAIL and BLIP_TEST_PASSWORD secrets to test them"
  quit_app && record PASS "Quits" "" || record FAIL "Quits" "still running 20 s after SIGTERM"
  exit 0
fi
session=$(curl -sS --max-time 30 -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_KEY" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$BLIP_TEST_EMAIL" --arg p "$BLIP_TEST_PASSWORD" '{email: $e, password: $p}')")
access=$(jq -r '.access_token // empty' <<< "$session")
refresh=$(jq -r '.refresh_token // empty' <<< "$session")
if [ -z "$access" ]; then
  record FAIL "Test account signs in (Supabase)" "$(jq -r '.error_description // .msg // .error // "no token"' <<< "$session")"
  quit_app; exit 0
fi
echo "::add-mask::$access"; echo "::add-mask::$refresh"
record PASS "Test account signs in (Supabase)" "password grant returned a session"
touch "$OUT/.signed-in"   # from here on, screenshots stay private (lib.sh)
xdg-open "blipai://auth?token=$access&refresh_token=$refresh" > "$OUT/xdg-open.log" 2>&1 &
if wait_until 45 signed_in; then record PASS "Signs in through the blipai://auth link (xdg-open)" "token saved by the app"
else record FAIL "Signs in through the blipai://auth link (xdg-open)" "no token saved within 45 s; xdg-open: $(tail -n 2 "$OUT/xdg-open.log" | tr '\n' ' ' | cut -c1-150)"; fi
sleep 3
ui_dump signed-in

# --- 3. Relaunch signed in ------------------------------------------------------------
mounts_before=$(appimage_mounts)
quit_app && record PASS "Quits after onboarding" "" || { record FAIL "Quits after onboarding" "still running 20 s after SIGTERM"; pkill -9 -x "$APP_PROCESS"; }
sleep 2
launch_app; sleep 15
screenshot relaunch-signed-in
if app_running; then record PASS "Relaunches signed in" "windows: $(app_windows)"
else record FAIL "Relaunches signed in" "the app exited"; exit 0; fi
kl=""
for i in $(seq 1 40); do kl=$(key_listener); [ -n "$kl" ] && break; sleep 0.5; done
if [ -n "$kl" ]; then
  record PASS "Key listener running" "$kl"
else
  record FAIL "Key listener running" "$( [ "$SESSION" = wayland ] && echo "no /dev/input device open: push-to-talk can't work (is the user in the input group?)" || echo "X11KeyServer not running: push-to-talk can't work")"
fi
ui_dump home

# --- 4. Dictation -------------------------------------------------------------------
# 4a. Push-to-talk.
phrase="The quick brown fox jumps over the lazy dog near the river bank."
focus_target
ptt "$phrase"
text=$(wait_text 30)
if judge "Push-to-talk (hold Ctrl+Super) types into the focused app" "$phrase" "$text"; then
  # The box writes its file when text arrives; xdotool/keys.py return right after the release.
  written=$(stat -c %.3Y "$TARGET_FILE" | tr -d .)
  record INFO "Push-to-talk: keys released → text in the box" "$(( written - RELEASED_AT )) ms"
fi
screenshot push-to-talk

# 4b. Hands-free.
phrase="Please send the quarterly report to the whole team before Friday afternoon."
focus_target
chord ctrl+super+space; sleep 0.8; speak "$phrase"; sleep 0.8; chord ctrl+super+space
judge "Hands-free (Ctrl+Super+Space to start and stop)" "$phrase" "$(wait_text 30)"

# 4c. Filler words.
focus_target
ptt "Um, so I think we should, uh, move the meeting to next week."
last_text=$(wait_text 30)
judge "Dictation with filler words" "I think we should move the meeting to next week" "$last_text"
if [ -n "$last_text" ]; then
  if grep -qiwE 'um|uh' <<< "$last_text"; then record FAIL "Filler words left out" "typed: \"$last_text\""
  else record PASS "Filler words left out" "no um/uh in \"$(cut -c1-120 <<< "$last_text")\""; fi
fi

# 4d. Esc cancels a hands-free dictation.
focus_target
chord ctrl+super+space; sleep 0.8; speak "This sentence should never be typed."
key tap escape
sleep 10
if target_has_text; then record FAIL "Esc cancels a hands-free dictation" "typed: \"$(target_text | cut -c1-120)\""
else record PASS "Esc cancels a hands-free dictation" "nothing typed in 10 s"; fi
sleep 2

# 4e. Paste last transcript.
focus_target
chord shift+alt+z
pasted=$(wait_text 15)
if [ -z "$last_text" ]; then record SKIP "Paste last transcript (Shift+Alt+Z)" "no earlier dictation to paste"
else judge "Paste last transcript (Shift+Alt+Z)" "$last_text" "$pasted" 90; fi

record SKIP "Dictates after the speakers or default mic change" "tested on Mac; this runner has one virtual sound card"
record SKIP "First dictation after waking from sleep" "a runner can't sleep and wake; check by hand"
record SKIP "Real Bluetooth or USB mic plugged in or out" "no such hardware on a runner"

# 4f. Failed transcription: a "Missed" item with Save audio and Retry.
if app_has 'data-missed-action'; then
  ips=$( (getent ahosts proxy.tryblipai.com; getent ahosts api.groq.com) | awk '{print $1}' | sort -u | xargs)
  for ip in $ips; do
    case "$ip" in *:*) sudo ip6tables -I OUTPUT -d "$ip" -j REJECT 2>/dev/null ;; *) sudo iptables -I OUTPUT -d "$ip" -j REJECT ;; esac
  done
  record INFO "Transcription servers blocked" "proxy.tryblipai.com and api.groq.com ($ips)"
  phrase="Remember to water the plants on Saturday morning."
  focus_target
  ptt "$phrase"
  missed_ts=""
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    read -r st ts _ <<< "$(newest_record)"
    [ "$st" = missed ] && { missed_ts="$ts"; break; }
    sleep 1
  done
  ui_dump missed-error
  for ip in $ips; do
    case "$ip" in *:*) sudo ip6tables -D OUTPUT -d "$ip" -j REJECT 2>/dev/null ;; *) sudo iptables -D OUTPUT -d "$ip" -j REJECT ;; esac
  done
  if [ -n "$missed_ts" ]; then
    record PASS "Failed transcription is kept as a Missed item" "overlay: $(grep -v '^== window' "$OUT/ui-missed-error.txt" | grep -iE 'fail|couldn|error|missed|saved' | head -n 1 | cut -c1-100)"
    setsid "$APPIMAGE_PATH" ${APP_EXTRA_ARGS:-} > /dev/null 2>&1 < /dev/null &   # opening the app again brings its window up
    sleep 4
    pressed=$(press "Save audio")
    sleep 2
    saved_to="$HOME/Documents/BlipAI-saved-by-test.wav"; mkdir -p "$HOME/Documents"
    dialog=$(with_timeout 40 "$PY" "$here/atspi.py" save-as "$APP_PROCESS" "$saved_to" 2>&1)
    sleep 3
    if [ -s "$saved_to" ] && [ "$(stat -c %s "$saved_to")" -gt 10000 ]; then
      record PASS "Missed item: Save audio writes the recording" "$(stat -c %s "$saved_to") bytes ($dialog)"
    else
      record FAIL "Missed item: Save audio writes the recording" "press: $(cut -c1-80 <<< "$pressed"); dialog: $(cut -c1-100 <<< "$dialog")"
    fi
    pressed=$(press "Retry")
    retried=""
    deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      retried=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1])).get("transcriptionHistory") or []
r = next((x for x in h if str(x.get("timestamp")) == sys.argv[2]), None)
print("" if r is None or r.get("status") == "missed" else (r.get("text") or "").replace("\n", " "))
' "$(app_config)" "$missed_ts" 2>/dev/null)
      [ -n "$retried" ] && break
      sleep 1
    done
    if [ -n "$retried" ]; then judge "Missed item: Retry transcribes it" "$phrase" "$retried"
    else record FAIL "Missed item: Retry transcribes it" "press: $(cut -c1-80 <<< "$pressed"); still Missed after 60 s"; fi
  else
    read -r st ts text <<< "$(newest_record)"
    record FAIL "Failed transcription is kept as a Missed item" "newest history item: $st \"$(cut -c1-80 <<< "$text")\"; overlay: $(grep -v '^== window' "$OUT/ui-missed-error.txt" | head -n 4 | paste -sd'|' | cut -c1-160)"
  fi
else
  record SKIP "Failed transcription is kept as a Missed item" "this build has no Missed items"
fi

# History.
history=$(python3 -c '
import json, sys
h = json.load(open(sys.argv[1])).get("transcriptionHistory") or []
t = json.dumps(h).lower()
print(len(h), "quick brown fox" in t, "quarterly report" in t)
' "$(app_config)" 2>/dev/null)
read -r n has_ptt has_hf <<< "${history:-0 False False}"
if [ "$has_ptt" = True ] && [ "$has_hf" = True ]; then record PASS "Dictations saved to history" "$n entries, including the push-to-talk and hands-free ones"
else record FAIL "Dictations saved to history" "$n entries; push-to-talk found: $has_ptt, hands-free found: $has_hf"; fi

# --- 5. The session ends while the app runs -----------------------------------------
# End this session on the server (scope=local: only this runner's session, never the
# account's other devices), then give the running app an expired access token, as after
# a long sleep. The app reads its store on every access.
curl -sS --max-time 30 -o /dev/null -X POST "$SUPABASE_URL/auth/v1/logout?scope=local" \
  -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $access" || true
python3 - "$(app_config)" << 'PY'
import base64, json, sys, time
p = sys.argv[1]; cfg = json.load(open(p))
b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
try:
    part = (cfg.get("authToken") or "").split(".")[1]
    payload = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
except Exception:
    payload = {}
payload["exp"] = int(time.time()) - 3600
cfg["authToken"] = b64({"alg": "HS256", "typ": "JWT"}) + "." + b64(payload) + ".expired"
json.dump(cfg, open(p, "w"))
PY
focus_target
key down ctrl; key down super; sleep 2.5
ui_dump signed-out
key up super; key up ctrl
sleep 3
ui_dump signed-out-after
seen=$(cat "$OUT/ui-signed-out.txt" "$OUT/ui-signed-out-after.txt" 2>/dev/null | grep -v '^== window' | grep -iE "sign|session|expired|log ?in|fail|error" | head -n 2 | paste -sd'|' | cut -c1-200)
if app_has 'id="status-action"'; then
  if grep -qiE "signed out|sign in to keep" <<< "$seen"; then record PASS "Session ended: 'You're signed out' notice" "$seen"
  else record FAIL "Session ended: 'You're signed out' notice" "overlay showed: ${seen:-nothing readable}"; fi
else
  record INFO "Session ended while running: what the overlay shows" "${seen:-nothing readable} (this build has no 'You're signed out' notice, added on Mac and Windows in 0.5.10)"
fi
target_has_text && record FAIL "Signed out: nothing is typed" "typed: \"$(target_text | cut -c1-80)\""

# --- 6. Quit ----------------------------------------------------------------------------
quit_app && record PASS "Quits (SIGTERM, as at logout)" "" || { record FAIL "Quits (SIGTERM, as at logout)" "still running 20 s after SIGTERM"; pkill -9 -x "$APP_PROCESS"; }
sleep 2
if pgrep -f X11KeyServer > /dev/null; then record FAIL "Key listener exits with the app" "X11KeyServer still running"
else record PASS "Key listener exits with the app" ""; fi
if [ -z "${APPIMAGE_EXTRACT_AND_RUN:-}" ]; then
  [ "$(appimage_mounts)" -eq 0 ] && record PASS "AppImage mount is cleaned up" "" \
    || record FAIL "AppImage mount is cleaned up" "$(mount | grep /tmp/.mount_Blip | cut -c1-120)"
fi

# Relaunching with that ended session asks the user to sign in again.
launch_app; sleep 15
if app_windows | grep -qi welcome; then record PASS "Relaunch with an ended session shows sign-in" "windows: $(app_windows)"
else record FAIL "Relaunch with an ended session shows sign-in" "windows: $(app_windows)"; fi
quit_app || pkill -9 -x "$APP_PROCESS"
exit 0
