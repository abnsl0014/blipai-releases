#!/bin/bash
# Checks what the auto-updater relies on, before anything is installed:
#   latest-mac.yml names this version, every file it lists is on the release with that
#   size, the downloaded files hash to its sha512, and each updater zip holds a signed,
#   notarized app of this version for the right CPU.
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

# Every file the updater may fetch must exist with the size the yml promises.
missing=()
while IFS=$'\t' read -r url size; do
  actual=$(jq -r --arg n "$url" '.assets[] | select(.name == $n) | .size' "$OUT/release.json")
  if [ -z "$actual" ]; then missing+=("$url (missing)")
  elif [ "$actual" != "$size" ]; then missing+=("$url (yml $size, asset $actual)"); fi
done < <(jq -r '.files[] | [.url, (.size|tostring)] | @tsv' "$OUT/latest-mac.json")
if [ ${#missing[@]} -eq 0 ]; then
  record PASS "Files listed in latest-mac.yml are on the release" "$(jq '.files | length' "$OUT/latest-mac.json") files, sizes match"
else
  record FAIL "Files listed in latest-mac.yml are on the release" "${missing[*]}"
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

# What the updater installs: each zip must hold a signed, notarized app of this version.
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
  codesign --verify --deep --strict "$app" 2> "$OUT/codesign-$name.txt" || problems+=("codesign: $(tail -n 1 "$OUT/codesign-$name.txt")")
  spctl --assess --type execute "$app" 2> "$OUT/spctl-$name.txt" || problems+=("Gatekeeper: $(tail -n 1 "$OUT/spctl-$name.txt")")
  if [ ${#problems[@]} -eq 0 ]; then
    record PASS "Updater zip $name" "$v, $archs, signed and accepted by Gatekeeper"
  else
    record FAIL "Updater zip $name" "${problems[*]}"
  fi
  rm -rf "$dir"
done
exit 0
