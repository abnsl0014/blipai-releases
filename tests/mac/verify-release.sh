#!/bin/bash
# Checks what the auto-updater relies on. Runs after install-app.sh, because an update
# is only accepted if it is signed by the same identity as the app already installed.
#   • latest-mac.yml names this version and lists zips that are on the release with the
#     size it promises (electron-updater on macOS only ever downloads the zips)
#   • the downloaded files hash to the sha512 it lists
#   • each zip holds an app of this version, for the right CPU, whose signature is valid
#     and satisfies the installed app's designated requirement (what Squirrel.Mac checks
#     before swapping the app)
set -uo pipefail
source "$(dirname "$0")/lib.sh"

yml="$DL/latest-mac.yml"
if [ ! -f "$yml" ]; then
  record FAIL "Updater metadata (latest-mac.yml)" "not on the release: Mac users would never be offered $TAG"
  exit 0
fi
ruby -ryaml -rjson -e 'puts JSON.dump(YAML.safe_load(File.read(ARGV[0])))' "$yml" > "$OUT/latest-mac.json"

yml_version=$(jq -r .version "$OUT/latest-mac.json")
if [ "$yml_version" = "$VERSION" ]; then
  record PASS "latest-mac.yml version" "$yml_version"
else
  record FAIL "latest-mac.yml version" "says $yml_version, release is $VERSION"
fi

# Every zip the updater may fetch must exist with the size the yml promises. Other
# entries (DMGs) are never downloaded by the updater, so a missing one is only a warning.
broken_zips=()
missing_other=()
while IFS=$'\t' read -r url size; do
  actual=$(jq -r --arg n "$url" '.assets[] | select(.name == $n) | .size' "$OUT/release.json")
  problem=""
  if [ -z "$actual" ]; then problem="$url (not on the release)"
  elif [ "$actual" != "$size" ]; then problem="$url (yml $size bytes, asset $actual)"; fi
  [ -z "$problem" ] && continue
  case "$url" in
    *.zip) broken_zips+=("$problem") ;;
    *) missing_other+=("$problem") ;;
  esac
done < <(jq -r '.files[] | [.url, (.size|tostring)] | @tsv' "$OUT/latest-mac.json")
if [ ${#broken_zips[@]} -eq 0 ]; then
  record PASS "Updater zips listed in latest-mac.yml are on the release" "$(jq '[.files[] | select(.url | endswith(".zip"))] | length' "$OUT/latest-mac.json") zips, sizes match"
else
  record FAIL "Updater zips listed in latest-mac.yml are on the release" "${broken_zips[*]}"
fi
if [ ${#missing_other[@]} -gt 0 ]; then
  record WARN "latest-mac.yml lists files the release doesn't have" "${missing_other[*]}. Harmless (the updater only downloads zips), but the yml is out of step with the release."
fi

path=$(jq -r .path "$OUT/latest-mac.json")
if jq -e --arg p "$path" --arg s "$(jq -r .sha512 "$OUT/latest-mac.json")" \
     '.files[] | select(.url == $p and .sha512 == $s)' "$OUT/latest-mac.json" > /dev/null; then
  record PASS "latest-mac.yml default path" "$path"
else
  record FAIL "latest-mac.yml default path" "$path is not one of its files, or its sha512 differs"
fi

# sha512 of every file we downloaded, as electron-updater computes it (base64 of the digest).
for f in "$DL"/*.zip "$DL"/*.dmg; do
  [ -f "$f" ] || continue
  name=$(basename "$f")
  want=$(jq -r --arg n "$name" '.files[] | select(.url == $n) | .sha512' "$OUT/latest-mac.json")
  [ -n "$want" ] || { record INFO "sha512 $name" "not listed in latest-mac.yml"; continue; }
  got=$(openssl dgst -sha512 -binary "$f" | base64)
  if [ "$got" = "$want" ]; then record PASS "sha512 $name" "matches latest-mac.yml"
  else record FAIL "sha512 $name" "file hashes to a different value than latest-mac.yml says"; fi
done

# The installed app's designated requirement: an update must satisfy it.
requirement=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')
record INFO "Installed app's designated requirement" "$requirement"

want_archs() {
  case "$1" in
    *-arm64-mac.zip) echo "arm64" ;;
    *-universal-mac.zip) echo "arm64 x86_64" ;;
    *) echo "x86_64" ;;
  esac
}
for zip in "$DL"/*-mac.zip; do
  [ -f "$zip" ] || continue
  name=$(basename "$zip")
  dir=$(mktemp -d)
  if ! ditto -x -k "$zip" "$dir"; then record FAIL "Updater zip $name" "does not unzip"; continue; fi
  app=$(find "$dir" -maxdepth 1 -name '*.app' | head -n 1)
  if [ -z "$app" ]; then record FAIL "Updater zip $name" "no .app inside"; continue; fi
  v=$(defaults read "$app/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  archs=$(lipo -archs "$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)" | tr ' ' '\n' | sort | xargs)
  problems=()
  [ "$v" = "$VERSION" ] || problems+=("version $v")
  [ "$archs" = "$(want_archs "$name")" ] || problems+=("archs '$archs', expected '$(want_archs "$name")'")
  if ! codesign --verify --deep --strict --test-requirement="=$requirement" "$app" 2> "$OUT/codesign-$name.txt"; then
    problems+=("signature: $(tail -n 1 "$OUT/codesign-$name.txt")")
  fi
  if [ ${#problems[@]} -eq 0 ]; then
    record PASS "Updater zip $name" "$v, $archs, signed by the same identity as the installed app"
  else
    record FAIL "Updater zip $name" "${problems[*]}"
  fi
  # Gatekeeper doesn't assess an app the updater installs (it isn't quarantined), but it
  # does if someone downloads this zip from the release page and opens it.
  spctl --assess --type execute --verbose=2 "$app" > "$OUT/spctl-$name.txt" 2>&1
  if grep -q 'accepted' "$OUT/spctl-$name.txt"; then
    record PASS "Gatekeeper accepts the app in $name" "$(grep -o 'source=.*' "$OUT/spctl-$name.txt")"
  else
    record WARN "Gatekeeper accepts the app in $name" "$(grep -o 'source=.*' "$OUT/spctl-$name.txt" || tail -n 1 "$OUT/spctl-$name.txt"). Auto-updates still install (Gatekeeper skips them), but opening this zip from the release page is blocked."
  fi
  rm -rf "$dir"
done
exit 0
