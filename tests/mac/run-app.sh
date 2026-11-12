#!/bin/bash
# Runs the installed app the way a new user does and checks what they'd see:
#   1. first launch, signed out: the app starts, stays up and shows onboarding
#   2. sign-in through the blipai://auth link the website opens (needs the test account)
#   3. relaunch signed in: home window, Fn key listener running
#   4. dictation into TextEdit: push-to-talk, hands-free, filler words, Esc to cancel,
#      Paste last transcript, system audio muted while recording and restored after,
#      dictating after the speakers change and after a new default mic appears, and,
#      when the app has them (0.5.10+): the "No sound" notice and its Open Settings,
#      a failed transcription kept as a Missed item with Save audio and Retry
#   5. (0.5.10+) the session ends while the app runs: "You're signed out" and Sign in
#   6. quit: the app and its key listener exit; relaunching then shows sign-in
# Speech comes from `say` into the virtual mic, keys from tests/mac/keys.swift.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
touch "$OUT/.started"

# Public values the app itself ships with (auth.js): the Supabase project and its
# publishable key. The test signs in with email and password, as blipai.app does.
SUPABASE_URL="${SUPABASE_URL:-https://hqwmccawtepvundsgnil.supabase.co}"
SUPABASE_KEY="${SUPABASE_KEY:-sb_publishable_TCu8hwzGitgxmzCu2rYHiA_6r3MImeD}"

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
muted() { osa -e 'output muted of (get volume settings)' 2>/dev/null || echo unknown; }
key_server_running() { pgrep -f 'MacKeyServer' > /dev/null; }
signed_in() {
  local config; config=$(app_config)
  [ -n "$config" ] && python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("authToken") else 1)' "$config"
}
launch() {  # like launch_app, keeping the app's stdout/stderr (console.error survives in release builds)
  open --stdout "$OUT/app-stdout.log" --stderr "$OUT/app-stderr.log" -a "$APP"
  wait_until 30 app_running
}
ui_dump() {  # ui_dump NAME [WINDOW] → $OUT/ui-NAME.txt (Chromium can take a moment to build its tree)
  local try
  for try in 1 2 3; do
    with_timeout 90 osascript "$here/ui-text.applescript" "$APP_PROCESS" ${2:+"$2"} > "$OUT/ui-$1.txt" 2>&1 || true
    grep -qv '^== window' "$OUT/ui-$1.txt" && return 0
    sleep 3
  done
}
focus_textedit() {
  osa > /dev/null << 'OSA'
tell application "TextEdit"
  if (count of documents) is 0 then make new document
  set text of document 1 to ""
  activate
end tell
OSA
  sleep 1.5
}
textedit_has_text() { [ -n "$(textedit_text | tr -d '[:space:]')" ]; }
wait_text() {  # wait_text SECONDS → prints TextEdit's text once something was typed (or nothing)
  local deadline=$(( $(date +%s) + ${1:-30} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if textedit_has_text; then sleep 2; textedit_text; return 0; fi
    sleep 0.25
  done
  return 1
}
judge() {  # judge CHECK EXPECTED ACTUAL [MIN_RECALL%]
  local name="$1" expected="$2" actual="$3" min="${4:-70}" recall
  if [ -z "$(printf '%s' "$actual" | tr -d '[:space:]')" ]; then
    # What the app showed instead (its overlay message), for the report.
    local slug; slug=$(tr -cs 'A-Za-z0-9' '-' <<< "$name" | cut -c1-40)
    ui_dump "nothing-typed-$slug"
    record FAIL "$name" "nothing was typed into TextEdit within 30 s; app showed: $(grep -v '^== window' "$OUT/ui-nothing-typed-$slug.txt" | grep -viE 'claim your gift|learn more' | head -n 6 | tr '\n' '|' | cut -c1-200)"
    return 1
  fi
  recall=$(word_recall "$actual" "$expected")
  local shown; shown=$(printf '%s' "$actual" | tr '\n' ' ' | cut -c1-140)
  if [ "$recall" -ge "$min" ]; then record PASS "$name" "$recall% of the spoken words; typed: \"$shown\""
  else record FAIL "$name" "$recall% of the spoken words (need $min%); typed: \"$shown\""; return 1; fi
}
collect_crash_reports() {
  find "$HOME/Library/Logs/DiagnosticReports" /Library/Logs/DiagnosticReports \
    \( -name "${APP_PROCESS}*" -o -name 'MacKeyServer*' \) -newer "$OUT/.started" 2>/dev/null \
    | while read -r f; do cp "$f" "$OUT/"; done
}

# --- 1. First launch, signed out ---------------------------------------------
if launch; then record PASS "Launches from /Applications" "pid $(pgrep -x "$APP_PROCESS" | head -n 1)"
else record FAIL "Launches from /Applications" "no $APP_PROCESS process after 30 s"; collect_crash_reports; exit 0; fi
sleep 15
screenshot first-launch
if app_running; then record PASS "Stays up on first launch (15 s)" ""
else record FAIL "Stays up on first launch (15 s)" "the app exited"; collect_crash_reports; exit 0; fi
windows=$(app_windows)
if [ -n "$windows" ]; then record PASS "Shows onboarding on first launch" "windows: $windows"
else record FAIL "Shows onboarding on first launch" "no window"; fi
ui_dump onboarding
record INFO "Onboarding text" "$(grep -v '^== window' "$OUT/ui-onboarding.txt" | head -n 12 | tr '\n' '|' | cut -c1-300)"

# The updater checks 5 s after launch. On the latest release it must find nothing newer.
log_path=$(app_log)
update_line=$(grep -m1 -E "Found version|is not available|Error: " "$log_path" 2>/dev/null)
latest=$(retry gh release view -R "${REPO:-$GITHUB_REPOSITORY}" --json tagName -q .tagName 2>/dev/null)
if [ -z "$update_line" ]; then
  record FAIL "Update check on launch" "no update check in the app's main.log 15 s after launch (log: ${log_path:-none}; recent logs: $(log_files))"
elif [ "$TAG" = "$latest" ] && grep -q "is not available" <<< "$update_line"; then
  record PASS "Update check on launch" "up to date: $(cut -c1-160 <<< "$update_line" | sed 's/.*\] //')"
elif [ "$TAG" = "$latest" ]; then
  record FAIL "Update check on launch" "$(cut -c1-200 <<< "$update_line")"
else
  record INFO "Update check on launch" "$(cut -c1-200 <<< "$update_line")"
fi

# --- 2. Sign in ---------------------------------------------------------------
if [ -z "${BLIP_TEST_EMAIL:-}" ] || [ -z "${BLIP_TEST_PASSWORD:-}" ]; then
  record SKIP "Sign in and dictation" "add the BLIP_TEST_EMAIL and BLIP_TEST_PASSWORD secrets to test them"
  if quit_app; then record PASS "Quits" ""; else record FAIL "Quits" "still running 15 s after quit"; fi
  exit 0
fi

session=$(curl -sS --max-time 30 -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
  -H "apikey: $SUPABASE_KEY" -H 'Content-Type: application/json' \
  -d "$(jq -n --arg e "$BLIP_TEST_EMAIL" --arg p "$BLIP_TEST_PASSWORD" '{email: $e, password: $p}')")
access=$(jq -r '.access_token // empty' <<< "$session")
refresh=$(jq -r '.refresh_token // empty' <<< "$session")
if [ -z "$access" ]; then
  record FAIL "Test account signs in (Supabase)" "$(jq -r '.error_description // .msg // .error // "no token"' <<< "$session")"
  quit_app
  exit 0
fi
echo "::add-mask::$access"
echo "::add-mask::$refresh"
record PASS "Test account signs in (Supabase)" "password grant returned a session"

touch "$OUT/.signed-in"   # from here on, screenshots stay private (see screenshot() in lib.sh)
open "blipai://auth?token=$access&refresh_token=$refresh"
if wait_until 45 signed_in; then record PASS "Signs in through the blipai://auth link" "token saved by the app"
else record FAIL "Signs in through the blipai://auth link" "no token saved within 45 s"; fi
sleep 3
screenshot signed-in
ui_dump signed-in

# --- 3. Relaunch signed in ----------------------------------------------------
if quit_app; then record PASS "Quits after onboarding" ""
else record FAIL "Quits after onboarding" "still running 15 s after quit"; pkill -9 -x "$APP_PROCESS"; fi
sleep 2
# Auto-detect prefers a real microphone to a virtual default one. Apple-silicon runners
# have one ("Apple Virtual Sound Device") that hears nothing, so there the test picks
# BlackHole 2ch, as a user picks a mic in Settings. The app finds a saved mic by its
# name when its id has changed, so the name is enough: the name the app lists, which
# has the connection type that Chromium adds ("BlackHole 2ch (Virtual)"; without it,
# run 13 found no such mic). Intel runners have no other mic and test Auto-detect.
mic_mode=auto
other_inputs=$(SwitchAudioSource -a -t input | grep -vE '^(BlackHole|Null Audio Device)' | paste -sd, -)
if [ -n "$other_inputs" ]; then
  mic_mode=manual
  python3 - "$(app_config)" << 'PY'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
cfg.update(selectedMicrophoneId="chosen-in-settings", selectedMicrophoneLabel="BlackHole 2ch (Virtual)")
json.dump(cfg, open(path, "w"))
PY
  record INFO "Microphone" "BlackHole 2ch chosen in the app (this runner also has $other_inputs, which hears nothing and which Auto-detect would pick)"
else
  record INFO "Microphone" "Auto-detect (the default input is BlackHole 2ch and the runner has no other mic)"
fi
launch
sleep 15
screenshot relaunch-signed-in
if app_running; then record PASS "Relaunches signed in" "windows: $(app_windows)"
else record FAIL "Relaunches signed in" "the app exited"; collect_crash_reports; exit 0; fi
if wait_until 20 key_server_running; then record PASS "Fn key listener running (MacKeyServer)" ""
else record FAIL "Fn key listener running (MacKeyServer)" "not started: push-to-talk can't work"; fi
ui_dump home

# --- 4. Dictation -------------------------------------------------------------
log_before=$(wc -l < "$(app_log)" 2>/dev/null || echo 0)
render_speech "The quick brown fox jumps over the lazy dog near the river bank." \
  "Please send the quarterly report to the whole team before Friday afternoon." \
  "Um, so I think we should, uh, move the meeting to next week." \
  "This sentence should never be typed."

# 4a. Push-to-talk: hold Fn, speak, release. (After it, the app's log says which mic it used.)
phrase="The quick brown fox jumps over the lazy dog near the river bank."
focus_textedit
before_mute=$(muted)
"$KEYS" down fn
sleep 0.6
during_mute=$(muted)
speak "$phrase"
sleep 0.8
"$KEYS" up fn
t0=$(now_ms)
text=$(wait_text 30)
t1=$(now_ms)
judge "Push-to-talk (hold Fn) types into the focused app" "$phrase" "$text" && \
  record INFO "Push-to-talk: Fn released → text in TextEdit" "$((t1 - t0 - 2000)) ms (TextEdit is checked every 0.25 s)"
screenshot push-to-talk
mic_line=$(grep -a '\[mic\] active mode=' "$(app_log)" 2>/dev/null | tail -n 1 | sed 's/.*\[mic\] active //' | cut -c1-120)
if [ "$mic_mode" = manual ]; then
  if grep -q '^mode=manual ' <<< "$mic_line"; then record PASS "Uses the microphone chosen in Settings" "$mic_line"
  else record FAIL "Uses the microphone chosen in Settings" "app logged: ${mic_line:-nothing}"; fi
else
  record INFO "Microphone the app picked" "${mic_line:-not logged}"
fi
sleep 2
after_mute=$(muted)
record INFO "System audio muted while dictating" "before: $before_mute, during: $during_mute, after: $after_mute"
if [ "$during_mute" = "true" ] && [ "$after_mute" = "true" ] && [ "$before_mute" = "false" ]; then
  record FAIL "System audio restored after dictating" "still muted after the dictation ended"
elif [ "$during_mute" = "true" ]; then
  record PASS "System audio restored after dictating" "muted while recording, unmuted after"
fi

# 4b. Hands-free: Fn+Space starts, Fn+Space stops.
phrase="Please send the quarterly report to the whole team before Friday afternoon."
focus_textedit
"$KEYS" chord fn+space
sleep 0.8
speak "$phrase"
sleep 0.8
"$KEYS" chord fn+space
judge "Hands-free (Fn+Space to start and stop)" "$phrase" "$(wait_text 30)"
screenshot hands-free

# 4c. Filler words.
spoken="Um, so I think we should, uh, move the meeting to next week."
focus_textedit
"$KEYS" down fn
sleep 0.6
speak "$spoken"
sleep 0.8
"$KEYS" up fn
last_text=$(wait_text 30)
judge "Dictation with filler words" "I think we should move the meeting to next week" "$last_text"
if [ -n "$last_text" ]; then
  if grep -qiwE 'um|uh' <<< "$last_text"; then record FAIL "Filler words left out" "typed: \"$last_text\""
  else record PASS "Filler words left out" "no um/uh in \"$(printf '%s' "$last_text" | cut -c1-120)\""; fi
fi

# 4d. Esc cancels a hands-free dictation: nothing is typed.
focus_textedit
"$KEYS" chord fn+space
sleep 0.8
speak "This sentence should never be typed."
"$KEYS" tap escape
sleep 10
if textedit_has_text; then record FAIL "Esc cancels a hands-free dictation" "typed: \"$(textedit_text | cut -c1-120)\""
else record PASS "Esc cancels a hands-free dictation" "nothing typed in 10 s"; fi
# The app mutes system audio while it records, so "still muted" means Esc left the
# recording running: stop it, or every later shortcut is ignored.
if [ "$(muted)" = "true" ]; then
  record FAIL "Esc stops the recording" "still recording 10 s after Esc"
  "$KEYS" chord fn+space > /dev/null 2>&1 || true
  sleep 3
fi
osa -e 'tell application "TextEdit" to set text of document 1 to ""' > /dev/null 2>&1 || true

# 4e. Paste last transcript (Cmd+Ctrl+V) pastes the last finished dictation again.
focus_textedit
"$KEYS" chord cmd+ctrl+v
pasted=$(wait_text 15)
if [ -z "$last_text" ]; then
  record SKIP "Paste last transcript (Cmd+Ctrl+V)" "no earlier dictation to paste"
else
  judge "Paste last transcript (Cmd+Ctrl+V)" "$last_text" "$pasted" 90
fi

# --- 4f. Audio devices change while the app runs (no restart) ------------------
# Switching speakers, or a headset becoming the default mic, between dictations.
outputs_before=$(SwitchAudioSource -c -t output)
if SwitchAudioSource -t output -s "Null Audio Device" > /dev/null 2>&1; then
  phrase="The weather today is sunny with a light breeze from the west."
  focus_textedit
  "$KEYS" down fn; sleep 0.6; speak "$phrase"; sleep 0.8; "$KEYS" up fn
  judge "Dictates after the speakers change (no restart)" "$phrase" "$(wait_text 30)"
  SwitchAudioSource -t output -s "$outputs_before" > /dev/null 2>&1
else
  record SKIP "Dictates after the speakers change (no restart)" "no second output device on this runner"
fi
# The app mutes the default output while it records; BlackHole 16ch is both, so move
# the output away first, or the new mic is muted too (as a real headset's mic isn't).
SwitchAudioSource -t output -s "Null Audio Device" > /dev/null 2>&1
SwitchAudioSource -t input -s "BlackHole 16ch" > /dev/null 2>&1
phrase="Our new office opens on the first floor next month."
focus_textedit
if [ "$mic_mode" = auto ]; then
  "$KEYS" down fn; sleep 0.6; speak_to "BlackHole 16ch" "$phrase"; sleep 0.8; "$KEYS" up fn
  judge "Follows a new default microphone (no restart)" "$phrase" "$(wait_text 30)"
else
  "$KEYS" down fn; sleep 0.6; speak "$phrase"; sleep 0.8; "$KEYS" up fn
  judge "Keeps the chosen microphone when the default mic changes" "$phrase" "$(wait_text 30)"
fi
SwitchAudioSource -t input -s "BlackHole 2ch" > /dev/null 2>&1
SwitchAudioSource -t output -s "$outputs_before" > /dev/null 2>&1
record SKIP "First dictation after the Mac wakes from sleep" "a GitHub runner can't sleep and wake; check by hand"
record SKIP "Real AirPods or a USB mic plugged in or out mid-dictation" "no Bluetooth or USB hardware on a runner; the default-mic switch above is the closest check"

# Features newer than 0.5.9 are tested only when the installed app has them.
asar="$APP/Contents/Resources/app.asar"
app_has() { grep -qaF -- "$1" "$asar"; }
press() {  # press LABEL [WINDOW] → "pressed …", or the reason it couldn't
  with_timeout 70 osascript "$here/ui-press.applescript" "$APP_PROCESS" "$@" 2>&1 | sed 's/^.*execution error: //; s/ ([0-9-]*)$//'
}
newest_record() {  # prints "<status> <timestamp> <text…>" of the newest history record
  python3 -c '
import json, sys
items = json.load(open(sys.argv[1])).get("transcriptionHistory", [])
r = items[0] if items else {}
print(r.get("status") or "ok", r.get("timestamp") or 0, (r.get("text") or "").replace("\n", " "))
' "$(app_config)" 2>/dev/null
}

# --- 4g. Failed transcription: a "Missed" item with Retry and Save audio --------
if app_has 'data-missed-action'; then
  ips=$( (dig +short A proxy.tryblipai.com; dig +short A api.groq.com; dig +short AAAA proxy.tryblipai.com; dig +short AAAA api.groq.com) \
    | grep -E '^[0-9a-f.:]+$' | grep -E '[.:]' | sort -u | xargs)
  printf 'block return out quick proto { tcp udp } to { %s }\n' "$(sed 's/ /, /g' <<< "$ips")" > "$RUNNER_TEMP/pf-block.conf"
  sudo pfctl -E > /dev/null 2>&1
  sudo pfctl -f "$RUNNER_TEMP/pf-block.conf" > /dev/null 2>&1
  for ip in $ips; do sudo pfctl -k 0.0.0.0/0 -k "$ip" > /dev/null 2>&1; sudo pfctl -k ::/0 -k "$ip" > /dev/null 2>&1; done
  record INFO "Transcription servers blocked" "proxy.tryblipai.com and api.groq.com ($ips)"
  phrase="Remember to water the plants on Saturday morning."
  focus_textedit
  "$KEYS" down fn; sleep 0.6; speak "$phrase"; sleep 0.8; "$KEYS" up fn
  missed_ts=""
  deadline=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    read -r st ts _ <<< "$(newest_record)"
    if [ "$st" = "missed" ]; then missed_ts="$ts"; break; fi
    sleep 1
  done
  ui_dump missed-error
  sudo pfctl -f /etc/pf.conf > /dev/null 2>&1   # back online
  if [ -n "$missed_ts" ]; then
    record PASS "Failed transcription is kept as a Missed item" "overlay: $(grep -v '^== window' "$OUT/ui-missed-error.txt" | grep -iE 'fail|couldn|error|missed|retry|connect|internet' | head -n 1 | cut -c1-100)"
    open -a "$APP"; sleep 3
    touch "$OUT/.before-save"
    pressed=$(press "Save audio" "Blip AI")
    # Click Save in the save panel (a sheet on the home window). A Return key went to
    # whichever app was in front, which wasn't always Blip (run 16).
    save_click=$(osa - "$APP_PROCESS" << 'OSA' 2>&1
on run argv
  tell application "System Events" to tell process (item 1 of argv)
    repeat 20 times
      repeat with w in windows
        try
          if exists sheet 1 of w then
            click button "Save" of sheet 1 of w
            return "clicked Save in a sheet of " & (name of w)
          end if
        end try
        try
          if (name of w) is "Save" then
            click button "Save" of w
            return "clicked Save in the Save window"
          end if
        end try
      end repeat
      delay 0.5
    end repeat
  end tell
  return "no save panel within 10 s"
end run
OSA
)
    pressed="$pressed; $save_click"
    sleep 3
    saved=$(find "$HOME/Documents" "$HOME/Downloads" "$HOME/Desktop" "$HOME" -maxdepth 1 -type f \
              \( -name '*.wav' -o -name '*.mp3' \) -newer "$OUT/.before-save" 2>/dev/null | head -n 1)
    if [ -n "$saved" ] && [ "$(stat -f %z "$saved")" -gt 10000 ]; then
      record PASS "Missed item: Save audio writes the recording" "$(basename "$saved"), $(stat -f %z "$saved") bytes, $(afinfo "$saved" 2>/dev/null | grep -m1 'estimated duration' | sed 's/.*: //')"
    else
      record FAIL "Missed item: Save audio writes the recording" "press: $(cut -c1-120 <<< "$pressed"); no new .wav/.mp3 in Documents, Downloads, Desktop or home"
    fi
    pressed=$(press "Retry" "Blip AI")
    retried=""
    deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      retried=$(python3 -c '
import json, sys
items = json.load(open(sys.argv[1])).get("transcriptionHistory", [])
r = next((x for x in items if str(x.get("timestamp")) == sys.argv[2]), None)
print("" if r is None or r.get("status") == "missed" else (r.get("text") or "").replace("\n", " "))
' "$(app_config)" "$missed_ts" 2>/dev/null)
      [ -n "$retried" ] && break
      sleep 1
    done
    if [ -n "$retried" ]; then judge "Missed item: Retry transcribes it" "$phrase" "$retried"
    else record FAIL "Missed item: Retry transcribes it" "press: $(cut -c1-120 <<< "$pressed"); still Missed after 60 s"; fi
  else
    read -r st ts text <<< "$(newest_record)"
    record FAIL "Failed transcription is kept as a Missed item" "newest history item: $st \"$(cut -c1-80 <<< "$text")\"; overlay: $(grep -v '^== window' "$OUT/ui-missed-error.txt" | head -n 4 | tr '\n' '|' | cut -c1-160)"
  fi
  osa -e 'tell application "TextEdit" to set text of document 1 to ""' > /dev/null 2>&1 || true
else
  record SKIP "Failed transcription is kept as a Missed item" "this version has no Missed items (added in 0.5.10)"
fi

# --- 4h. Silent microphone: "No sound" notice with "Open Settings" -------------
if app_has 'id="status-action"'; then
  focus_textedit
  "$KEYS" down fn
  sleep 4.5            # digital silence from the virtual mic; the app warns after 2.5 s
  ui_dump no-sound
  screenshot no-sound
  notice=$(grep -m1 -iE "no sound|can't hear|couldn't hear|is muted" "$OUT/ui-no-sound.txt")
  if [ -n "$notice" ]; then record PASS "Silent mic: 'No sound' notice" "$(cut -c1-120 <<< "$notice")"
  else record FAIL "Silent mic: 'No sound' notice" "overlay showed: $(grep -v '^== window' "$OUT/ui-no-sound.txt" | head -n 6 | tr '\n' '|' | cut -c1-200)"; fi
  pressed=$(press "Open Settings" "Blip AI Overlay")
  sleep 3
  "$KEYS" up fn
  sleep 2
  ui_dump open-settings
  if grep -q '^pressed' <<< "$pressed" && grep -qiE "test microphone|microphone" "$OUT/ui-open-settings.txt"; then
    record PASS "'Open Settings' opens the microphone settings" "$(cut -c1-80 <<< "$pressed")"
  else
    record FAIL "'Open Settings' opens the microphone settings" "press: $(cut -c1-120 <<< "$pressed"); windows: $(app_windows)"
  fi
  if textedit_has_text; then record FAIL "Silent dictation types nothing" "typed: \"$(textedit_text | cut -c1-80)\""
  else record PASS "Silent dictation types nothing" ""; fi
  osa -e 'tell application "System Events" to key code 53' > /dev/null 2>&1 || true   # close the settings sheet
else
  record SKIP "Silent mic: 'No sound' notice" "this version has no microphone notices (added in 0.5.10)"
fi

# What the app logged about each dictation (release builds log only these lines).
log=$(app_log)
if [ -n "$log" ]; then
  tail -n +"$((log_before + 1))" "$log" | grep -E '\[(stt|paste)-timing\]' > "$OUT/dictation-timing.txt" || true
  record INFO "App's dictation timing lines" "$(wc -l < "$OUT/dictation-timing.txt" | tr -d ' ') lines: $(grep -m1 'stt-timing\] client' "$OUT/dictation-timing.txt" | sed 's/.*\[stt-timing\]//' | cut -c1-160)"
fi

if [ -s "$OUT/sox-retries.txt" ]; then
  record INFO "Test voice played a second time" "$(wc -l < "$OUT/sox-retries.txt" | tr -d ' ') time(s): sox hung opening the virtual device (sox-retries.txt)"
fi

# History: the app keeps finished dictations in its store (the home window lists them).
ui_dump after-dictation
history=$(python3 -c '
import json, sys
items = json.load(open(sys.argv[1])).get("transcriptionHistory", [])
text = json.dumps(items).lower()
print(len(items), "quick brown fox" in text, "quarterly report" in text)
' "$(app_config)" 2>/dev/null)
read -r history_count has_ptt has_handsfree <<< "${history:-0 False False}"
if [ "$has_ptt" = "True" ] && [ "$has_handsfree" = "True" ]; then
  record PASS "Dictations saved to history" "$history_count entries, including the push-to-talk and hands-free ones"
else
  record FAIL "Dictations saved to history" "$history_count entries; push-to-talk found: $has_ptt, hands-free found: $has_handsfree"
fi

# --- 5. The session ends while the app runs: "Sign in" notice (0.5.10+) ---------
# What a user sees when their session can no longer be renewed. End this session on
# the server (scope=local: only this runner's session, never the account's other
# devices; also needed because the logs are public), then give the running app an
# expired access token, as after a long sleep. electron-store reads its file on
# every access, so the running app sees it at the next Fn press.
curl -sS --max-time 30 -o /dev/null -X POST "$SUPABASE_URL/auth/v1/logout?scope=local" \
  -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $access" || true
if app_has 'id="status-action"'; then
  python3 - "$(app_config)" << 'PY'
import base64, json, sys, time
path = sys.argv[1]
cfg = json.load(open(path))
b64 = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
token = cfg.get("authToken") or ""
try:
    part = token.split(".")[1]
    payload = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))
except Exception:
    payload = {}
payload["exp"] = int(time.time()) - 3600
cfg["authToken"] = b64({"alg": "HS256", "typ": "JWT"}) + "." + b64(payload) + ".expired"
json.dump(cfg, open(path, "w"))
PY
  # The notice shows for about 8 s, so look at the overlay alone (quick) and press its
  # button straight away.
  overlay_notice() { ui_dump "$1" "Blip AI Overlay"; grep -m1 -iE "signed out|sign in to keep" "$OUT/ui-$1.txt"; }
  focus_textedit
  "$KEYS" down fn
  sleep 2.5
  notice=$(overlay_notice signed-out)
  [ -n "$notice" ] && pressed=$(press "Sign in" "Blip AI Overlay")
  "$KEYS" up fn
  if [ -z "$notice" ]; then    # shown at release instead
    sleep 1
    notice=$(overlay_notice signed-out-after)
    [ -n "$notice" ] && pressed=$(press "Sign in" "Blip AI Overlay")
  fi
  if [ -n "$notice" ]; then
    record PASS "Session ended: 'You're signed out' notice" "$(cut -c1-100 <<< "$notice")"
    sleep 6
    # The app logs "[auth] sign-in started from=overlay" and opens its sign-in window.
    if grep -q '^pressed' <<< "$pressed" && { grep -q 'sign-in started' "$(app_log)" 2>/dev/null || pgrep -x Safari > /dev/null || app_windows | grep -qiE 'welcome|sign'; }; then
      record PASS "'Sign in' starts signing in again" "windows: $(app_windows)"
    else
      record FAIL "'Sign in' starts signing in again" "press: $(cut -c1-120 <<< "$pressed"); windows: $(app_windows)"
    fi
  else
    record FAIL "Session ended: 'You're signed out' notice" "app windows: $(app_windows); text: $(grep -v '^== window' "$OUT/ui-signed-out.txt" | grep -viE 'claim your gift|learn more' | head -n 5 | tr '\n' '|' | cut -c1-200)"
  fi
  if textedit_has_text; then record FAIL "Signed out: nothing is typed" "typed: \"$(textedit_text | cut -c1-80)\""; fi
else
  record SKIP "Session ended: 'You're signed out' notice" "this version has no sign-in notice (added in 0.5.10)"
fi

# --- 6. Quit ------------------------------------------------------------------
if quit_app; then record PASS "Quits" ""; else record FAIL "Quits" "still running 15 s after quit"; pkill -9 -x "$APP_PROCESS"; fi
sleep 2
if key_server_running; then record FAIL "Key listener exits with the app" "MacKeyServer still running"
else record PASS "Key listener exits with the app" ""; fi
collect_crash_reports

# Relaunching with that ended session asks the user to sign in again.
if app_has 'id="status-action"'; then
  launch
  sleep 15
  if app_windows | grep -qi welcome; then record PASS "Relaunch with an ended session shows sign-in" "windows: $(app_windows)"
  else record FAIL "Relaunch with an ended session shows sign-in" "windows: $(app_windows)"; fi
  quit_app || pkill -9 -x "$APP_PROCESS"
fi
exit 0
