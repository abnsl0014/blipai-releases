#!/bin/bash
# Runs the test on this GitHub runner (IMAGE empty: Ubuntu as GitHub provides it), or in a
# container of IMAGE (debian:trixie, fedora:42, archlinux:latest) on it. Containers get
# the runner's /dev (FUSE, /dev/uinput and the input devices the app reads on Wayland)
# and run privileged, so the app, FUSE and iptables work as on a normal install.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
sudo modprobe uinput 2> /dev/null || true

if [ -z "${IMAGE:-}" ]; then
  sudo --preserve-env=RUNNER_TEMP TEST_USER="$(id -un)" bash "$here/setup-runner.sh" || exit 1
  [ -e /dev/uinput ] && sudo chmod 0666 /dev/uinput
  bash "$here/user-steps.sh"
else
  input_gid=$(getent group input | cut -d: -f3)
  docker pull -q "$IMAGE" > /dev/null || retry docker pull -q "$IMAGE" > /dev/null
  docker run --rm --privileged -v /dev:/dev \
    -v "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE" -v "$RUNNER_TEMP:$RUNNER_TEMP" -w "$GITHUB_WORKSPACE" \
    -e HOST_UID="$(id -u)" -e HOST_INPUT_GID="$input_gid" \
    -e RUNNER_TEMP -e OUT -e SESSION -e TAG -e VERSION -e LATEST_TAG -e DL -e APPIMAGE_FILE -e PREV_APPIMAGE \
    -e SPEECH_DIR -e BLIP_TEST_EMAIL -e BLIP_TEST_PASSWORD -e PUBLISH_SIGNED_IN_SCREENSHOTS \
    "$IMAGE" bash "$here/in-container.sh"
fi
