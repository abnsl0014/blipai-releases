#!/bin/bash
# Entry point inside a distro container (Debian, Fedora, Arch): install the test's
# packages as root, make a normal user like the runner's (same uid, so the shared folder
# stays writable for both; in the `input` group with the same gid as the runner's device
# nodes, because /dev comes from the runner), then run user-steps.sh as that user.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${HOST_UID:=1001}"
: "${HOST_INPUT_GID:=}"

# Arch's image ships without a keyring set up; pacman needs one before -Syu.
if command -v pacman > /dev/null; then pacman-key --init > /dev/null 2>&1; pacman-key --populate archlinux > /dev/null 2>&1; fi
if command -v dnf > /dev/null; then dnf install -y -q shadow-utils sudo > /dev/null 2>&1; fi
if command -v apt-get > /dev/null; then apt-get update -qq > /dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sudo passwd > /dev/null 2>&1; fi

if [ -n "$HOST_INPUT_GID" ]; then
  # The image may use that gid for another group (Arch did: groupmod failed, the app's
  # user wasn't in the group the device nodes have, and it couldn't read the keyboard).
  other=$(getent group "$HOST_INPUT_GID" | cut -d: -f1)
  if [ -n "$other" ] && [ "$other" != input ]; then
    free=$(( HOST_INPUT_GID + 1000 )); while getent group "$free" > /dev/null; do free=$(( free + 1 )); done
    groupmod -g "$free" "$other"
  fi
  if getent group input > /dev/null; then groupmod -g "$HOST_INPUT_GID" input
  else groupadd -g "$HOST_INPUT_GID" input; fi
  echo "input group in the container: $(getent group input)${other:+ (moved $other off gid $HOST_INPUT_GID)}"
fi
id tester > /dev/null 2>&1 || useradd -m -u "$HOST_UID" -s /bin/bash tester
echo 'tester ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/tester
chmod 0440 /etc/sudoers.d/tester

TEST_USER=tester bash "$here/setup-runner.sh" || exit 1
# Keep the variables the scripts need; HOME and USER become the test user's.
exec sudo -u tester --preserve-env=RUNNER_TEMP,OUT,SESSION,TAG,VERSION,LATEST_TAG,DL,APPIMAGE_FILE,PREV_APPIMAGE,SPEECH_DIR,BLIP_TEST_EMAIL,BLIP_TEST_PASSWORD,PUBLISH_SIGNED_IN_SCREENSHOTS \
  env HOME=/home/tester USER=tester LOGNAME=tester bash "$here/user-steps.sh"
