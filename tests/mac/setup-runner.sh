#!/bin/bash
# Prepares the runner to stand in for a person at a Mac:
#   • a microphone: BlackHole 2ch is the default input, and the test "speaks" into it
#     (speech from `say`, played into BlackHole 2ch with sox; see speak() in lib.sh).
#     The default output is BlackHole 16ch, so Blip's
#     mute-system-audio-while-dictating mutes that device and not the test's voice.
#   • a keyboard: tests/mac/keys.swift, which posts real Fn/Space/Esc key events.
#   • the Fn (globe) key set to "Do Nothing", as Blip's onboarding asks people to,
#     so macOS doesn't open the emoji picker or change input source on Fn.
#   • TextEdit opening a blank plain-text document, the target of the dictations.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

record INFO "Runner" "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"

# --- keyboard tool (also reports this runner's own privacy state) -------------
if ! swiftc -O "$(dirname "$0")/keys.swift" -o "$KEYS" > "$OUT/swiftc.txt" 2>&1; then
  record FAIL "Build the key tool" "$(tail -n 3 "$OUT/swiftc.txt")"
  exit 0
fi
record INFO "Key tool permissions" "$("$KEYS" access)"

# --- virtual microphone -------------------------------------------------------
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
retry brew install --cask blackhole-2ch blackhole-16ch > "$OUT/brew-blackhole.txt" 2>&1 \
  || { tail -n 20 "$OUT/brew-blackhole.txt"; record FAIL "Install BlackHole (virtual audio)" "brew failed"; }
retry brew install switchaudio-osx sox > "$OUT/brew-tools.txt" 2>&1 \
  || { tail -n 20 "$OUT/brew-tools.txt"; record FAIL "Install SwitchAudioSource and sox" "brew failed"; }
# coreaudiod only loads new drivers when it starts.
sudo killall coreaudiod 2>/dev/null || true
wait_until 30 bash -c 'SwitchAudioSource -a -t input | grep -q "BlackHole 2ch"'
{ echo "inputs:"; SwitchAudioSource -a -t input; echo "outputs:"; SwitchAudioSource -a -t output; } > "$OUT/audio-devices.txt" 2>&1
cat "$OUT/audio-devices.txt"
SwitchAudioSource -t input -s "BlackHole 2ch" && SwitchAudioSource -t output -s "BlackHole 16ch"
record INFO "Audio devices" "input: $(SwitchAudioSource -c -t input), output: $(SwitchAudioSource -c -t output)"

# The loopback check below records with sox, which macOS charges to the runner's
# "responsible" process. GitHub's images grant that process the microphone, but not
# every image does (macOS 26 recorded pure silence); grant it the way we grant Blip.
responsible=$("$KEYS" responsible 2>&1)
mic_before=$("$KEYS" mic 2>&1)
if [ "$mic_before" != "authorized" ] && [ -x "$responsible" ]; then
  now=$(date +%s)
  sql="INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason,
      auth_version, csreq, policy_id, indirect_object_identifier_type, indirect_object_identifier,
      indirect_object_code_identity, flags, last_modified)
    VALUES ('kTCCServiceMicrophone', '$responsible', 1, 2, 4, 1, NULL, NULL, 0, 'UNUSED', NULL, 0, $now);"
  sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "$sql"
  sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "$sql"
  sudo killall tccd 2>/dev/null || true
  killall tccd 2>/dev/null || true
  sleep 2
fi
record INFO "Runner's microphone access" "responsible process: $responsible; before: $mic_before, now: $("$KEYS" mic 2>&1)"

# Loopback check: what `say` plays into BlackHole 2ch must come back out of the default
# input. If this fails, a dictation failure later says nothing about the app.
phrase="Testing the virtual microphone."
render_speech "$phrase" 2> "$OUT/say.txt" || echo "say exited $?" >> "$OUT/say.txt"
rec -q -c 1 -r 16000 "$OUT/loopback.wav" trim 0 5 2> "$OUT/rec.txt" &
rec_pid=$!
sleep 1
speak "$phrase" 2>> "$OUT/say.txt" || echo "sox play exited $?" >> "$OUT/say.txt"
wait "$rec_pid"
rms=$(sox "$OUT/loopback.wav" -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
if awk -v r="${rms:-0}" 'BEGIN { exit !(r > 0.003) }'; then
  record PASS "Virtual microphone carries speech" "RMS $rms"
else
  record FAIL "Virtual microphone carries speech" "RMS ${rms:-none}: the default input heard nothing. say: $(head -c 120 "$OUT/say.txt") rec: $(head -c 120 "$OUT/rec.txt")"
fi

# --- synthetic keys reach an event tap ---------------------------------------
"$KEYS" watch 4 > "$OUT/key-watch.txt" 2>&1 &
watch_pid=$!
wait_until 5 grep -q TAP_READY "$OUT/key-watch.txt"
"$KEYS" chord fn+space
wait "$watch_pid"
if grep -q 'code=63' "$OUT/key-watch.txt" && grep -q 'code=49' "$OUT/key-watch.txt"; then
  record PASS "Synthetic Fn+Space reaches an event tap" "$(grep -c '^event' "$OUT/key-watch.txt") events seen"
else
  record FAIL "Synthetic Fn+Space reaches an event tap" "$(head -c 200 "$OUT/key-watch.txt")"
fi

defaults write com.apple.HIToolbox AppleFnUsageType -int 0

# --- TextEdit -----------------------------------------------------------------
defaults write com.apple.TextEdit RichText -int 0
defaults write com.apple.TextEdit NSShowAppCentricOpenPanelInsteadOfUntitledFile -bool false
exit 0
