#!/bin/bash
# Installs the AppImage the way the website's Linux guide says, as the user who runs it:
#   1. Update path (latest published release only; the updater never sees drafts): the
#      previous release's AppImage runs and must be offered this version.
#   2. ~/.local/bin/BlipAI.AppImage, chmod +x.
#   3. FUSE: does it start as downloaded? If not because libfuse2 is missing, install it as
#      the guide's FAQ says; if FUSE still can't mount (some containers), run with
#      APPIMAGE_EXTRACT_AND_RUN=1, the guide's other fallback.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
env_out() { echo "export $1=$(printf '%q' "$2")" >> "$SESSION_ENV"; export "$1=$2"; }
mkdir -p "$APP_DIR"

# Does the AppImage runtime mount itself? (--appimage-mount mounts, prints the mount
# point and waits; nothing of the app runs.)
fuse_check() {
  local out
  out=$(timeout 10 "$1" --appimage-mount 2>&1 | head -n 3)
  pkill -f -- "--appimage-mount" 2> /dev/null
  if grep -q '^/tmp/' <<< "$out"; then echo ok; else echo "$out" | tr '\n' ' ' | cut -c1-200; fi
}
install_libfuse() {
  . /etc/os-release
  case "${ID}:${ID_LIKE:-}" in
    ubuntu:*|debian:*|*:*debian*)
      pkg=$(apt-cache show libfuse2t64 > /dev/null 2>&1 && echo libfuse2t64 || echo libfuse2)
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" fuse3 > /dev/null 2>&1; echo "sudo apt install $pkg" ;;
    fedora:*) sudo dnf install -y -q fuse-libs fuse > /dev/null 2>&1; echo "sudo dnf install fuse-libs fuse" ;;
    arch:*|*:*arch*) sudo pacman -S --noconfirm --needed fuse2 > /dev/null 2>&1; echo "sudo pacman -S fuse2" ;;
  esac
}
clean_install() {  # forget a previous run of the app: settings, logs, desktop integration
  rm -rf "$HOME/.config/blip-ai" "$HOME/.config/Blip-AI" "$HOME/.local/share/applications/blip-ai.desktop" \
    "$APP_DIR/blip-ai"
  sed -i '/blipai/d' "$HOME/.config/mimeapps.list" 2> /dev/null || true
}

# --- FUSE, on the release under test ----------------------------------------------
cp "$APPIMAGE_FILE" "$APPIMAGE_PATH" && chmod +x "$APPIMAGE_PATH"
fuse=$(fuse_check "$APPIMAGE_PATH")
if [ "$fuse" = ok ]; then
  record PASS "AppImage mounts itself (FUSE)" "no extra packages needed on $(distro)"
else
  record INFO "AppImage mounts itself (FUSE)" "not as downloaded on $(distro): $fuse"
  how=$(install_libfuse)
  fuse=$(fuse_check "$APPIMAGE_PATH")
  if [ "$fuse" = ok ]; then
    record PASS "AppImage mounts itself after the guide's FUSE fix" "$how"
  else
    record INFO "AppImage mounts itself after the guide's FUSE fix" "still no ($fuse); running it with APPIMAGE_EXTRACT_AND_RUN=1, the guide's other fallback"
    env_out APPIMAGE_EXTRACT_AND_RUN 1
    # Keep the extracted copy when an instance exits: a second launch (sign-in link) would
    # otherwise delete files under the running primary.
    env_out NO_CLEANUP 1
  fi
fi

# --- 1. update path ---------------------------------------------------------------
if [ -z "${PREV_APPIMAGE:-}" ]; then
  record SKIP "Previous release is offered this update" "$TAG isn't the latest published release (${LATEST_TAG:-?}), so no installed app would be offered it yet"
else
  clean_install
  cp "$PREV_APPIMAGE" "$APPIMAGE_PATH" && chmod +x "$APPIMAGE_PATH"
  launch_app
  found=""
  wait_until 90 bash -c "grep -aqE 'Found version|is not available|Error: ' \"\$(find '$HOME/.config' -maxdepth 4 -ipath '*blip*' -name main.log | head -n 1)\""
  found=$(grep -aE 'Found version|is not available|Error: ' "$(app_log)" 2>/dev/null | head -n 1)
  screenshot previous-release-update-check
  prev_name=$(basename "$PREV_APPIMAGE")
  if grep -q "Found version $VERSION" <<< "$found"; then record PASS "Previous release is offered this update" "$prev_name found $VERSION"
  elif [ -n "$found" ]; then record FAIL "Previous release is offered this update" "$prev_name logged: $(cut -c1-160 <<< "$found")"
  else record FAIL "Previous release is offered this update" "$prev_name logged no update check within 90 s"; fi
  quit_app || pkill -9 -x "$APP_PROCESS"
  log=$(app_log); [ -n "$log" ] && cp "$log" "$OUT/previous-release-main.log"
fi

# --- 2. install this release as the website says ----------------------------------
clean_install
cp "$APPIMAGE_FILE" "$APPIMAGE_PATH" && chmod +x "$APPIMAGE_PATH"
record PASS "Installed as the website says" "$APPIMAGE_PATH ($(stat -c %s "$APPIMAGE_PATH") bytes, executable)"

# Features the build has (the HTML in app.asar names them), for run-app.sh.
asar_dir="$RUNNER_TEMP/asar"
rm -rf "$asar_dir"; mkdir -p "$asar_dir"
( cd "$asar_dir" && "$APPIMAGE_PATH" --appimage-extract 'resources/app.asar' > /dev/null 2>&1 )
asar=$(find "$asar_dir" -name app.asar | head -n 1)
[ -n "$asar" ] && env_out APP_ASAR "$asar"
# The X11 hotkey helper keyspy ships (the app downloads it from keyspy's GitHub release
# at build time), so run-app.sh can run it on its own and report why it won't start.
( cd "$asar_dir" && "$APPIMAGE_PATH" --appimage-extract 'resources/app.asar.unpacked/node_modules/keyspy/runtime/X11KeyServer' > /dev/null 2>&1 )
key_server=$(find "$asar_dir" -name X11KeyServer -type f | head -n 1)
[ -n "$key_server" ] && env_out KEY_SERVER "$key_server"
