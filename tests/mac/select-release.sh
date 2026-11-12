#!/bin/bash
# Picks the release to test and downloads its Mac assets into $DL.
#   REQUESTED_TAG empty → the latest published release (what users and the auto-updater get)
#   REQUESTED_TAG=v0.5.10 → that release, drafts included, so a build can be tested before publishing
set -euo pipefail
source "$(dirname "$0")/lib.sh"

REPO="${REPO:-$GITHUB_REPOSITORY}"
DL="${DL:-$RUNNER_TEMP/release}"
mkdir -p "$DL"

TAG="${REQUESTED_TAG:-}"
if [ -z "$TAG" ]; then
  TAG=$(gh release view -R "$REPO" --json tagName -q .tagName)
fi
VERSION="${TAG#v}"

gh release view "$TAG" -R "$REPO" --json tagName,isDraft,isPrerelease,publishedAt,assets > "$OUT/release.json"
draft=$(jq -r .isDraft "$OUT/release.json")
published=$(jq -r '.publishedAt // "not published"' "$OUT/release.json")
record INFO "Release under test" "$TAG (draft: $draft, published: $published)"

DMG="Blip-AI-$VERSION-universal.dmg"   # the file blipai.app/download/mac points to
if ! jq -e --arg n "$DMG" '.assets[] | select(.name == $n)' "$OUT/release.json" > /dev/null; then
  record FAIL "Release has the universal DMG" "$TAG has no $DMG asset"
  exit 1
fi

# The DMG people download, the updater's metadata, and the zips the updater installs.
# verify-release.sh reports anything latest-mac.yml names that the release lacks.
patterns=()
for name in "$DMG" latest-mac.yml "Blip-AI-$VERSION-arm64-mac.zip" "Blip-AI-$VERSION-mac.zip" \
            "Blip-AI-$VERSION-universal-mac.zip"; do
  if jq -e --arg n "$name" '.assets[] | select(.name == $n)' "$OUT/release.json" > /dev/null; then
    patterns+=(-p "$name")
  fi
done
gh release download "$TAG" -R "$REPO" -D "$DL" --clobber "${patterns[@]}"
ls -la "$DL"

{
  echo "TAG=$TAG"
  echo "VERSION=$VERSION"
  echo "DL=$DL"
  echo "DMG=$DL/$DMG"
} >> "$GITHUB_ENV"
