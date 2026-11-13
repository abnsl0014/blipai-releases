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
  sudo --preserve-env=RUNNER_TEMP,DESKTOP TEST_USER="$(id -un)" bash "$here/setup-runner.sh" || exit 1
  [ -e /dev/uinput ] && sudo chmod 0666 /dev/uinput
  if [ -n "${DESKTOP:-}" ]; then
    sudo bash "$here/uinput-as-installed.sh"
    # As after the website's "log out and back in": a new login of the same user, now with
    # `input` among its groups. (Starting the app through `sg input` instead gives it another
    # primary group than the desktop's portal, and the kernel then won't let the portal look
    # at the app's /proc entry to tell who's asking: its CreateSession calls went unanswered.)
    exec sudo -E -u "$(id -un)" env PATH="$PATH" HOME="$HOME" bash "$here/user-steps.sh"
  fi
  bash "$here/user-steps.sh"
else
  input_gid=$(getent group input | cut -d: -f3)
  # The container shares this Ubuntu runner's kernel, including Ubuntu's AppArmor limit
  # on unprivileged user namespaces (Chromium's sandbox needs them). Debian, Fedora and
  # Arch don't set that limit, so lift it for the container's run.
  if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = 1 ]; then
    sudo sysctl -q -w kernel.apparmor_restrict_unprivileged_userns=0
    record INFO "Runner's AppArmor limit on user namespaces" "lifted for the $IMAGE container, as on that distro"
  fi
  docker pull -q "$IMAGE" > /dev/null || retry docker pull -q "$IMAGE" > /dev/null
  docker run --rm --privileged -v /dev:/dev \
    -v "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE" -v "$RUNNER_TEMP:$RUNNER_TEMP" -w "$GITHUB_WORKSPACE" \
    -e HOST_UID="$(id -u)" -e HOST_INPUT_GID="$input_gid" \
    -e RUNNER_TEMP -e OUT -e SESSION -e DESKTOP -e TAG -e VERSION -e LATEST_TAG -e DL -e APPIMAGE_FILE -e PREV_APPIMAGE \
    -e SPEECH_DIR -e BLIP_TEST_EMAIL -e BLIP_TEST_PASSWORD -e PUBLISH_SIGNED_IN_SCREENSHOTS \
    "$IMAGE" bash "$here/in-container.sh"
fi
