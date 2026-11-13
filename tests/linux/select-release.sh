#!/bin/bash
# Picks the release to test and downloads its Linux files into $DL (on the runner itself,
# with gh; the distro containers get them through a shared folder).
#   REQUESTED_TAG empty → the latest published release (what users and the auto-updater get)
#   REQUESTED_TAG=v0.5.10 → that release, drafts included, so a build can be tested before publishing
#   or, on a push, a "Test-tag: v0.5.10" line in the commit message
# When the release is the latest, the previous release's AppImage comes too, for the
# update-path check (install-app.sh).
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO="${REPO:-$GITHUB_REPOSITORY}"
DL="${DL:-$RUNNER_TEMP/release}"
mkdir -p "$DL"

TAG="${REQUESTED_TAG:-}"
if [ -z "$TAG" ]; then
  TAG=$(grep -oE '^Test-tag: *v[0-9][^ ]*' <<< "${COMMIT_MESSAGE:-}" | head -n 1 | sed 's/^Test-tag: *//' || true)   # no such line: grep fails, and pipefail would end the script
fi
latest=$(retry gh release view -R "$REPO" --json tagName -q .tagName)
[ -n "$TAG" ] || TAG="$latest"
VERSION="${TAG#v}"

APPIMAGE_FILE="Blip-AI-$VERSION.AppImage"   # what blipai.app/download/linux points to
has_appimage() {
  gh release view "$TAG" -R "$REPO" --json tagName,isDraft,publishedAt,assets > "$OUT/release.json" 2> /dev/null &&
    jq -e --arg n "$APPIMAGE_FILE" '.assets[] | select(.name == $n)' "$OUT/release.json" > /dev/null
}
# A tag asked for by name may still be building (the test is often started right after
# blip-ai-linux's build-linux.yml): wait up to 30 min for its AppImage.
if [ "$TAG" != "$latest" ]; then
  for i in $(seq 1 60); do has_appimage && break; [ "$i" = 1 ] && echo "waiting for $APPIMAGE_FILE on $TAG"; sleep 30; done
fi
retry gh release view "$TAG" -R "$REPO" --json tagName,isDraft,publishedAt,assets > "$OUT/release.json"
record INFO "Release under test" "$TAG (draft: $(jq -r .isDraft "$OUT/release.json"), published: $(jq -r '.publishedAt // "not published"' "$OUT/release.json"))"

if ! jq -e --arg n "$APPIMAGE_FILE" '.assets[] | select(.name == $n)' "$OUT/release.json" > /dev/null; then
  record FAIL "Release has the Linux AppImage" "$TAG has no $APPIMAGE_FILE asset"
  exit 1
fi
patterns=(-p "$APPIMAGE_FILE")
jq -e '.assets[] | select(.name == "latest-linux.yml")' "$OUT/release.json" > /dev/null && patterns+=(-p latest-linux.yml)
retry gh release download "$TAG" -R "$REPO" -D "$DL" --clobber "${patterns[@]}"
chmod +x "$DL/$APPIMAGE_FILE"

PREV_APPIMAGE=""
if [ "$TAG" = "$latest" ]; then
  prev=$(gh release list -R "$REPO" --exclude-drafts --exclude-pre-releases --limit 30 --json tagName,publishedAt \
    | jq -r --arg t "$TAG" '[.[] | select(.tagName != $t)] | sort_by(.publishedAt) | reverse | .[0].tagName // empty')
  if [ -n "$prev" ] && retry gh release download "$prev" -R "$REPO" -D "$DL/previous" --clobber -p "Blip-AI-${prev#v}.AppImage"; then
    PREV_APPIMAGE="$DL/previous/Blip-AI-${prev#v}.AppImage"
    chmod +x "$PREV_APPIMAGE"
  fi
fi
ls -la "$DL"

{
  echo "TAG=$TAG"
  echo "VERSION=$VERSION"
  echo "LATEST_TAG=$latest"
  echo "DL=$DL"
  echo "APPIMAGE_FILE=$DL/$APPIMAGE_FILE"
  echo "PREV_APPIMAGE=$PREV_APPIMAGE"
} >> "$GITHUB_ENV"
