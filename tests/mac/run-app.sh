#!/bin/bash
# Runs the installed app the way a new user does and checks what they'd see:
#   1. first launch, signed out: the app starts, stays up and shows onboarding
#   2. sign-in through the blipai://auth link the website opens (needs the test account)
#   3. relaunch signed in: home window, Fn key listener running
#   4. dictation into TextEdit: push-to-talk, hands-free, filler words, Esc to cancel,
#      Paste last transcript, system audio muted while recording and restored after
#   5. quit: the app and its key listener exit
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
speak() { say -a "BlackHole 2ch" "$1"; }
muted() { osascript -e 'output muted of (get volume settings)' 2>/dev/null || echo unknown; }
key_server_running() { pgrep -f 'MacKeyServer' > /dev/null; }
signed_in() {
  local config; config=$(app_config)
  [ -n "$config" ] && python3 -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("authToken") else 1)' "$config"
}
launch() {  # like launch_app, keeping the app's stdout/stderr (console.error survives in release builds)
  open --stdout "$OUT/app-stdout.log" --stderr "$OUT/app-stderr.log" -a "$APP"
  wait_until 30 app_running
}
ui_dump() {  # ui_dump NAME → $OUT/ui-NAME.txt
  osascript "$here/ui-text.applescript" "$APP_PROCESS" > "$OUT/ui-$1.txt" 2>&1 || true
}
focus_textedit() {
  osascript > /dev/null << 'OSA'
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
    record FAIL "$name" "nothing was typed into TextEdit within 30 s"
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
update_line=$(grep -m1 -E "Found version|is not available|Error: " "$(app_log)" 2>/dev/null)
latest=$(gh release view -R "${REPO:-$GITHUB_REPOSITORY}" --json tagName -q .tagName 2>/dev/null)
if [ -z "$update_line" ]; then
  record FAIL "Update check on launch" "no update check in main.log 15 s after launch"
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

session=$(curl -sS -X POST "$SUPABASE_URL/auth/v1/token?grant_type=password" \
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

# 4a. Push-to-talk: hold Fn, speak, release.
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
  record INFO "Push-to-talk: Fn released → text in TextEdit" "$((t1 - t0)) ms"
screenshot push-to-talk
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
"$KEYS" chord fn+space > /dev/null 2>&1 || true   # in case Esc didn't stop it
sleep 3
osascript -e 'tell application "TextEdit" to set text of document 1 to ""' > /dev/null 2>&1 || true

# 4e. Paste last transcript (Cmd+Ctrl+V) pastes the last finished dictation again.
focus_textedit
"$KEYS" chord cmd+ctrl+v
pasted=$(wait_text 15)
if [ -z "$last_text" ]; then
  record SKIP "Paste last transcript (Cmd+Ctrl+V)" "no earlier dictation to paste"
else
  judge "Paste last transcript (Cmd+Ctrl+V)" "$last_text" "$pasted" 90
fi

# What the app logged about each dictation (release builds log only these lines).
log=$(app_log)
if [ -n "$log" ]; then
  tail -n +"$((log_before + 1))" "$log" | grep -E '\[(stt|paste)-timing\]' > "$OUT/dictation-timing.txt" || true
  record INFO "App's dictation timing lines" "$(wc -l < "$OUT/dictation-timing.txt" | tr -d ' ') lines: $(grep -m1 'stt-timing\] client' "$OUT/dictation-timing.txt" | sed 's/.*\[stt-timing\]//' | cut -c1-160)"
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

# --- 5. Quit ------------------------------------------------------------------
if quit_app; then record PASS "Quits" ""; else record FAIL "Quits" "still running 15 s after quit"; fi
sleep 2
if key_server_running; then record FAIL "Key listener exits with the app" "MacKeyServer still running"
else record PASS "Key listener exits with the app" ""; fi
collect_crash_reports

# End this session so its refresh token stops working (the logs are public).
curl -sS -o /dev/null -X POST "$SUPABASE_URL/auth/v1/logout?scope=local" \
  -H "apikey: $SUPABASE_KEY" -H "Authorization: Bearer $access" || true
exit 0
