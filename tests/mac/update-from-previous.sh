#!/bin/bash
# The update path: installs the release before this one, launches it, and checks that
# its auto-updater (electron-updater, which checks 5 s after launch and logs to
# main.log) is offered this version. Then removes it, so install-app.sh starts clean.
# Only meaningful for the latest published release: the updater never sees drafts.
set -uo pipefail
source "$(dirname "$0")/lib.sh"

REPO="${REPO:-$GITHUB_REPOSITORY}"
latest=$(gh release view -R "$REPO" --json tagName -q .tagName)
if [ "$TAG" != "$latest" ]; then
  record SKIP "Previous release is offered this update" "$TAG isn't the latest published release ($latest), so no installed app would be offered it yet"
  exit 0
fi

previous=$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 \
  --json tagName,publishedAt -q 'sort_by(.publishedAt) | reverse | map(.tagName) | map(select(. != "'"$TAG"'")) | .[0] // empty')
prev_dmg="Blip-AI-${previous#v}-universal.dmg"
if [ -z "$previous" ] || ! gh release download "$previous" -R "$REPO" -D "$RUNNER_TEMP/previous" --clobber -p "$prev_dmg"; then
  record SKIP "Previous release is offered this update" "no earlier release with $prev_dmg"
  exit 0
fi

mnt="$RUNNER_TEMP/previous-dmg"
mkdir -p "$mnt"
hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$RUNNER_TEMP/previous/$prev_dmg" > /dev/null
old_app="/Applications/$(basename "$(find "$mnt" -maxdepth 1 -name '*.app' | head -n 1)")"
sudo rm -rf "$old_app"
ditto "$mnt/$(basename "$old_app")" "$old_app"
hdiutil detach "$mnt" -quiet

log_dir="$HOME/Library/Logs"
open -a "$old_app"
found=""
deadline=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  log=$(app_log)
  if [ -n "$log" ] && found=$(grep -m1 -E "Found version|is not available|Error: " "$log"); then break; fi
  sleep 2
done
screenshot previous-release-update-check
if grep -q "Found version ${VERSION}" <<< "$found"; then
  record PASS "Previous release is offered this update" "$previous found $VERSION 5 s after launch"
elif [ -n "$found" ]; then
  record FAIL "Previous release is offered this update" "$previous logged: $(cut -c1-200 <<< "$found")"
else
  record FAIL "Previous release is offered this update" "$previous logged no update check within 90 s (log: ${log:-none}; recent logs: $(log_files))"
fi

osascript -e "tell application id \"$(defaults read "$old_app/Contents/Info" CFBundleIdentifier)\" to quit" > /dev/null 2>&1 || true
wait_until 15 bash -c "! pgrep -x '$(defaults read "$old_app/Contents/Info" CFBundleExecutable)'" \
  || pkill -9 -x "$(defaults read "$old_app/Contents/Info" CFBundleExecutable)"
pkill -f MacKeyServer 2>/dev/null || true
cp "$(app_log)" "$OUT/previous-release-main.log" 2>/dev/null || true
# Leave a clean machine for the fresh-install test: no app, no settings, no log.
sudo rm -rf "$old_app"
find "$HOME/Library/Application Support" "$log_dir" -maxdepth 1 -iname '*blip*' -exec rm -rf {} +
exit 0
