# Linux release test

`.github/workflows/linux-release-test.yml` tests a Blip AI Linux release the way a user gets
it, on every distro the website's Linux guide names and both session types:

| Distro | Where it runs | Sessions |
|---|---|---|
| Ubuntu 24.04 | GitHub's Ubuntu 24.04 runner | X11, Wayland |
| Ubuntu 22.04 | GitHub's Ubuntu 22.04 runner | X11, Wayland |
| Debian 13 | `debian:trixie` container on an Ubuntu runner | X11, Wayland |
| Debian 12 | `debian:bookworm` container on an Ubuntu runner | X11, Wayland |
| Fedora 42 | `fedora:42` container on an Ubuntu runner | X11, Wayland |
| Arch | `archlinux:latest` container on an Ubuntu runner | X11, Wayland |

The containers run privileged with the runner's `/dev`, so FUSE, `/dev/uinput` and the input
devices the app reads on Wayland work as on a normal install. They share the runner's kernel.

It costs nothing on this public repo. It runs at the same times as the Mac and Windows tests
(a release is published, **Run workflow** by hand with an optional tag, or a change to
`tests/linux/**` with a `Test-tag: v0.5.10` line in the commit message), and it needs the same
two secrets, `BLIP_TEST_EMAIL` and `BLIP_TEST_PASSWORD` (see [the Mac README](../mac/README.md)).
Screenshots taken after sign-in stay on the runner, and emails and tokens are removed from the
uploaded logs.

## What it checks

| Step | Script | Checks |
|---|---|---|
| The voice | workflow `voice` job | macOS's `say` speaks `phrases.txt` into WAV files (the Mac test's voice). |
| Release files | `select-release.sh` | Downloads `Blip-AI-<version>.AppImage` (what `/download/linux` points to) and `latest-linux.yml`. |
| Updater files | `verify-release.sh` | `latest-linux.yml` names this version; the AppImage has the size and sha512 it gives; it's an x86_64 executable. |
| Runner setup | `setup-runner.sh`, `session.sh` | The display (X11: Xvfb + Openbox; Wayland: headless Sway with XWayland, the guide's wlroots path), PulseAudio with a virtual mic, the accessibility bus, the test's text box, and the guide's Wayland step: the user joins the `input` group. |
| Install | `install-app.sh` | Whether the AppImage mounts itself (FUSE) as downloaded, and after the guide's `libfuse2` fix if not. On the latest release, the previous release is offered this update. Then `~/.local/bin/BlipAI.AppImage`, as the guide says. |
| The app | `run-app.sh` | See below. |
| Report | `report.sh` | The job summary; fails the job if any check failed. |

`run-app.sh` checks, in order:

1. **First launch.** The app starts and stays up (if Chromium's sandbox stops it, as Ubuntu
   24.04's AppArmor limit on user namespaces does, that's a failure, and the test lifts the
   limit and goes on), shows onboarding, registers the `blipai://` handler and the `blip-ai`
   command, and checks for updates. On X11 it also runs the app's hotkey helper
   (`X11KeyServer`) on its own, which fails where the distro's glibc is older than the helper
   was built for.
2. **Sign-in** through the `blipai://auth` link, opened with `xdg-open` as Chrome would, then
   with `gio open` (GNOME, Firefox) if that fails.
3. **Relaunch signed in.** After the first dictation, the key listener is checked: on X11,
   `X11KeyServer`; on Wayland, the app holding `/dev/input` devices open.
4. **Dictation into the text box:** push-to-talk (hold Ctrl+Super), hands-free
   (Ctrl+Super+Space), filler words, Esc, Paste last transcript (Shift+Alt+Z), a failed
   transcription kept as a Missed item with Save audio and Retry, and history.
5. **Session ended** while the app runs: the "You're signed out" notice where the build has it,
   otherwise what the overlay shows.
6. **Quit** (SIGTERM, as at logout): the app, its key listener and its AppImage mount go away,
   and relaunching with the ended session asks to sign in.

## How it stands in for a person

- **Microphone.** PulseAudio has a "voice" sink whose monitor is the default input; the test
  plays the WAV files into it. The app's own sounds go to separate "speakers".
- **Keyboard.** On X11, `xdotool` sends key presses through XTEST, which the app's
  `X11KeyServer` (XInput2) sees like a keyboard. On Wayland, `keys.py` plugs in a virtual
  keyboard through `/dev/uinput`, which the app reads from `/dev/input` like a real one.
- **Typing target.** `target.py` is a GTK window with a text box that mirrors its text to a file
  and logs the keys and focus changes it gets. On Wayland it's a native Wayland window, so the
  app's `wtype` path is what types into it.
- **Reading and pressing the UI.** `atspi.py` uses AT-SPI, the accessibility bus screen readers
  use; the app is started with `--force-renderer-accessibility`. Release builds of the Linux
  app don't log much, so the test goes by what the app shows and does.

## Limits

- No GNOME or KDE session yet: their Wayland path (paste through the RemoteDesktop portal, after
  the desktop's one-time "allow" dialog) isn't covered; Sway covers the wlroots path (`wtype`).
  X11 runs with Openbox.
- Containers share the Ubuntu runner's kernel, so kernel-level differences between distros aren't
  covered; the distro's own libraries, FUSE, packages and desktop tools are.
- No sleep and wake, real microphones or Bluetooth; one synthetic voice.
