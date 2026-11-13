#!/bin/bash
# Checks the files the Linux auto-updater (electron-updater's AppImage updater) uses:
# latest-linux.yml names this version, and the AppImage it lists is on the release with
# the size and sha512 it gives (the updater refuses a download whose hash doesn't match).
set -uo pipefail
source "$(dirname "$0")/lib.sh"
yml="$DL/latest-linux.yml"

if [ ! -f "$yml" ]; then
  record FAIL "Updater metadata (latest-linux.yml)" "not on the release: Linux users would never be offered $TAG"
  exit 0
fi
cp "$yml" "$OUT/"
v=$(sed -n 's/^version: *//p' "$yml" | tr -d "'\"")
[ "$v" = "$VERSION" ] && record PASS "latest-linux.yml version" "$v" || record FAIL "latest-linux.yml version" "says $v, release is $VERSION"

url=$(sed -n 's/^ *- url: *//p' "$yml" | head -n 1)
want_sha=$(sed -n 's/^ *sha512: *//p' "$yml" | head -n 1)
want_size=$(sed -n 's/^ *size: *//p' "$yml" | head -n 1)
f="$DL/$url"
if [ ! -f "$f" ]; then
  record FAIL "File listed in latest-linux.yml is on the release" "$url isn't (the AppImage is $(basename "$APPIMAGE_FILE"))"
  exit 0
fi
size=$(stat -c %s "$f")
[ "$size" = "$want_size" ] && record PASS "AppImage size matches latest-linux.yml" "$size bytes" \
  || record FAIL "AppImage size matches latest-linux.yml" "file is $size bytes, yml says $want_size"
sha=$(python3 -c 'import base64, hashlib, sys; print(base64.b64encode(hashlib.sha512(open(sys.argv[1], "rb").read()).digest()).decode())' "$f")
[ "$sha" = "$want_sha" ] && record PASS "AppImage sha512 matches latest-linux.yml" "" \
  || record FAIL "AppImage sha512 matches latest-linux.yml" "the updater would reject the download"

kind=$(file -b "$f")
case "$kind" in
  *ELF\ 64-bit*x86-64*) record PASS "AppImage is an x86_64 executable" "$(cut -c1-80 <<< "$kind")" ;;
  *) record FAIL "AppImage is an x86_64 executable" "$kind" ;;
esac
