# Mac release test

`.github/workflows/mac-release-test.yml` tests a Blip AI Mac release on one of GitHub's
Mac runners, the way a user gets it. It downloads the DMG from this repo, installs it,
launches it, signs in, dictates into TextEdit and quits. It also checks the files the
auto-updater installs.

It costs nothing: this repo is public, and GitHub doesn't charge for its standard runners,
Mac included, on public repos.

## When it runs

- **When a release is published here.** That's the moment it becomes "latest" for the
  updater.
- **By hand.** Actions → **Mac release test** → **Run workflow**. Enter a tag such as
  `v0.5.10` to test a draft before you publish it, or leave it empty for the latest release.
- **When the test itself changes** (`tests/mac/**` or the workflow).

## Setup: a test account

Sign-in and dictation need a Blip account. In this repo, go to Settings → Secrets and
variables → Actions and add:

| Secret | Value |
|---|---|
| `BLIP_TEST_EMAIL` | the test account's email |
| `BLIP_TEST_PASSWORD` | its password |

Use an account that signs in with email and password, and isn't anyone's real account.
Ideally it's on Pro, so repeated runs don't hit the free word limit. Without these secrets,
sign-in and dictation are skipped with a warning, and everything else still runs.

## What it checks

| Step | Script | Checks |
|---|---|---|
| Runner setup | `setup-runner.sh` | A virtual mic (BlackHole) carries speech. Synthetic Fn+Space reaches an event tap. |
| Release files | `select-release.sh`, `verify-release.sh` | `latest-mac.yml` names this version, and every file it lists is on the release with that size. Downloaded files match its sha512. Each updater zip holds a signed, notarized app of this version for the right CPU. |
| Install | `install-app.sh` | DMG checksum and Applications shortcut. Version and universal binary. `codesign`, Gatekeeper and the stapled ticket. Mic and Apple Events entitlements and their Info.plist reasons. The `blipai://` scheme. A signed `MacKeyServer`. |
| Permissions | `grant-permissions.sh` | Grants Microphone, Accessibility, Input Monitoring and Automation of System Events, as a person does during onboarding. |
| The app | `run-app.sh` | See below. |
| Report | `report.sh` | Writes the job summary, removes tokens and emails from the logs, and fails the job if any check failed. |

`run-app.sh` checks, in order:

1. **First launch.** The app launches, stays up and shows onboarding.
2. **Sign-in.** The test account signs in through the `blipai://auth` link, the same link
   the website opens.
3. **Relaunch signed in.** The app relaunches and the Fn key listener is running.
4. **Dictation into TextEdit:**
   - push-to-talk (hold Fn)
   - hands-free (Fn+Space to start and stop)
   - filler words are left out
   - Esc cancels a hands-free dictation
   - Paste last transcript (Cmd+Ctrl+V)
   - system audio is muted while recording and restored after
5. **Quit.** The app quits and its key listener exits with it.

The run's summary lists every check. The artifact `mac-release-test-<os>` holds screenshots
of each stage, the app's text at each stage, and the redacted logs.

## How it stands in for a person

- **Microphone.** BlackHole 2ch is the default input, and the test speaks into it with
  `say -a "BlackHole 2ch"`. The default output is BlackHole 16ch, so Blip's "mute system
  audio while dictating" mutes that device and not the test's voice.
- **Keyboard.** `keys.swift` posts Fn, Space, Esc and Cmd+Ctrl+V as HID events, the same
  events a keyboard produces. MacKeyServer's event tap and Electron's global shortcuts see
  them as real key presses. The Fn key is set to "Do Nothing" first, as onboarding asks.
- **Permissions.** A person clicks Allow. The test writes the same rows into the TCC
  databases, which works because SIP is off on GitHub's Mac images. This is the only step
  that differs from a real install. The app is launched through LaunchServices, so macOS
  checks the app's own permissions and entitlements, not the runner's.

## Limits

- It tests one machine per macOS version in the matrix, with a synthetic voice. Accents,
  noisy rooms and real microphones aren't covered.
- Clicking through onboarding isn't automated. The test signs in through the deep link,
  then relaunches the app.
- The logs and artifacts are public. `report.sh` strips tokens and email addresses, and
  the session is signed out at the end, but don't dictate anything private here.
