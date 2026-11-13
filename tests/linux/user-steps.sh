#!/bin/bash
# The part that runs as the user, in order: start the session, install the AppImage the
# way the website says, run the app. Same on the runner and inside a distro container.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib.sh"
distro > "$OUT/distro.txt"
record INFO "Runner" "$(distro), kernel $(uname -r), $(uname -m)$( [ -f /.dockerenv ] && echo ', in a container on the GitHub runner')"
[ -r /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
  record INFO "AppArmor limits on user namespaces" "apparmor_restrict_unprivileged_userns=$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)"
if [ "$SESSION" = wayland ] && read -r rc cmd < "$OUT/website-wayland-tools.txt" 2> /dev/null; then
  cmd="${cmd/ --noconfirm/}"
  if [ "$rc" = 0 ]; then record PASS "The website's Wayland tools command works" "$cmd"
  else record FAIL "The website's Wayland tools command works" "\`$cmd\` exits with $rc on $(distro) and installs nothing: $(grep -m1 -iE 'unable|no match|not found|error' "$OUT/website-wayland-tools.log" | cut -c1-140). The test goes on with wtype and wl-clipboard"
  fi
fi
bash "$here/session.sh"
source "$SESSION_ENV"
bash "$here/install-app.sh"
source "$SESSION_ENV"
bash "$here/run-app.sh"
