#!/bin/bash
# Prepares the runner to stand in for a person at a Mac:
#   • a microphone: BlackHole 2ch is the default input, and the test "speaks" into it
#     with `say -a "BlackHole 2ch"`. The default output is BlackHole 16ch, so Blip's
#     mute-system-audio-while-dictating mutes that device and not the test's voice.
#   • a keyboard: tests/mac/keys.swift, which posts real Fn/Space/Esc key events.
#   • the Fn (globe) key set to "Do Nothing", as Blip's onboarding asks people to,
#     so macOS doesn't open the emoji picker or change input source on Fn.
#   • TextEdit opening a blank plain-text document, the target of the dictations.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

record INFO "Runner" "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"

# --- virtual microphone -------------------------------------------------------
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install --cask blackhole-2ch blackhole-16ch > "$OUT/brew-blackhole.txt" 2>&1 \
  || { tail -n 20 "$OUT/brew-blackhole.txt"; record FAIL "Install BlackHole (virtual audio)" "brew failed"; }
brew install switchaudio-osx sox > "$OUT/brew-tools.txt" 2>&1 \
  || { tail -n 20 "$OUT/brew-tools.txt"; record FAIL "Install SwitchAudioSource and sox" "brew failed"; }
# coreaudiod only loads new drivers when it starts.
sudo killall coreaudiod 2>/dev/null || true
wait_until 30 bash -c 'SwitchAudioSource -a -t input | grep -q "BlackHole 2ch"'
{ echo "inputs:"; SwitchAudioSource -a -t input; echo "outputs:"; SwitchAudioSource -a -t output; } > "$OUT/audio-devices.txt" 2>&1
cat "$OUT/audio-devices.txt"
SwitchAudioSource -t input -s "BlackHole 2ch" && SwitchAudioSource -t output -s "BlackHole 16ch"
record INFO "Audio devices" "input: $(SwitchAudioSource -c -t input), output: $(SwitchAudioSource -c -t output)"

# Loopback check: what `say` plays into BlackHole 2ch must come back out of the default
# input. If this fails, a dictation failure later says nothing about the app.
rec -q -c 1 -r 16000 "$OUT/loopback.wav" trim 0 4 &
rec_pid=$!
sleep 0.7
say -a "BlackHole 2ch" "Testing the virtual microphone."
wait "$rec_pid"
rms=$(sox "$OUT/loopback.wav" -n stat 2>&1 | awk '/RMS +amplitude/ {print $3}')
if awk -v r="${rms:-0}" 'BEGIN { exit !(r > 0.003) }'; then
  record PASS "Virtual microphone carries speech" "RMS $rms"
else
  record FAIL "Virtual microphone carries speech" "RMS ${rms:-none}: the default input heard nothing"
fi

# --- keyboard -----------------------------------------------------------------
if swiftc -O "$(dirname "$0")/keys.swift" -o "$KEYS" > "$OUT/swiftc.txt" 2>&1; then
  record INFO "Key tool permissions" "$("$KEYS" access)"
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
else
  record FAIL "Build the key tool" "$(tail -n 3 "$OUT/swiftc.txt")"
fi

defaults write com.apple.HIToolbox AppleFnUsageType -int 0

# --- TextEdit -----------------------------------------------------------------
defaults write com.apple.TextEdit RichText -int 0
defaults write com.apple.TextEdit NSShowAppCentricOpenPanelInsteadOfUntitledFile -bool false
exit 0
