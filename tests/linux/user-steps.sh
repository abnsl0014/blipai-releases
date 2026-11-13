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
bash "$here/session.sh"
source "$SESSION_ENV"
bash "$here/install-app.sh"
source "$SESSION_ENV"
bash "$here/run-app.sh"
