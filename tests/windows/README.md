# Windows release test

`.github/workflows/windows-release-test.yml` tests a Blip AI Windows release on GitHub's
Windows runners (Windows Server 2025 and 2022), the way a user gets it. It downloads the
installer from this repo, installs it silently, launches it, signs in, dictates into a
text box and quits. It also checks the files the auto-updater uses.

It costs nothing on this public repo. It runs at the same times as the Mac test (a release
is published, **Run workflow** by hand with an optional tag, or a change to
`tests/windows/**` with a `Test-tag: v0.5.10` line in the commit message), and it needs the
same two secrets, `BLIP_TEST_EMAIL` and `BLIP_TEST_PASSWORD`: see
[the Mac README](../mac/README.md) for both. The same privacy rules apply: screenshots taken
after sign-in stay on the runner, and emails and tokens are removed from uploaded logs.

## What it checks

| Step | Script | Checks |
|---|---|---|
| Runner setup | `setup-runner.ps1` | Builds the helper tool (`wtool.cs`). Installs VB-CABLE, makes it the default playback and recording device, and checks that speech played on it comes back on the mic. Synthetic Ctrl+Win+Space reaches a low-level keyboard hook. |
| Release files | `select-release.ps1` | Downloads `Blip-AI-Setup-<version>.exe`, its blockmap and `latest.yml`. |
| Updater files | `verify-release.ps1` | `latest.yml` names this version; its files are on the release with that size and sha512; the blockmap for differential updates is there. An unsigned installer is a warning. |
| Update path and install | `install-app.ps1` | On the latest published release: installs the previous one, launches it, and checks that its updater is offered this version. Then installs this release with `/S` (per user, no admin), and checks the version, signature, Installed apps entry, Start menu and desktop shortcuts and `WinKeyServer.exe`. A failed installer is retried once; each failure is a warning with the crash Windows logged. |
| The app | `run-app.ps1` | See below. |
| Report | `report.ps1` | The job summary; fails the job if any check failed. |

`run-app.ps1` checks, in order:

1. **First launch.** The app starts, stays up and shows onboarding; the `blipai://` link is
   registered; on the latest release, the update check finds nothing newer.
2. **Sign-in** through the `blipai://auth` link, then a relaunch signed in.
3. **Dictation into a text box:** push-to-talk (hold Ctrl+Win), hands-free (Ctrl+Win+Space),
   filler words left out, Esc cancels, Paste last transcript (Shift+Alt+Z), and history.
   On 0.5.10+: a failed transcription (the transcription servers blocked by the firewall
   for a moment) becomes a **Missed** item whose Save audio and Retry work; a silent mic
   shows "No sound" and its **Open Settings** opens the microphone settings.
4. **Session ended (0.5.10+).** With the session ended on the server and an expired token
   in the app, the shortcut shows "You're signed out", and **Sign in** starts signing in.
5. **Quit**, the key listener exits, and relaunching with the ended session shows sign-in.

For the overlay's buttons (Open Settings, Sign in) it also checks that a real mouse
click works, separately from what the button does: the test clicks twice with the mouse,
then posts the same click straight to the window, which skips Windows' mouse-activation
step. On v0.5.10 only the posted click worked, on both runners: the page handles the
click, but the real clicks were dropped before it. That check fails until someone
confirms with a mouse on a real PC either way.

If the runner's virtual mic hears nothing, the dictation checks are skipped with that
reason rather than failed one by one.

## How it stands in for a person

- **Microphone.** The runner has no sound card. VB-CABLE's "CABLE Input" is the default
  output and "CABLE Output" the default mic, so what plays comes back as the mic. Phrases
  are synthesized with Windows' own voice and played by `wtool play`.
- **Two of the app's settings differ from a new install**, because the runner's only
  speaker is wired into its mic: "mute system audio while dictating" is off (it would
  silence the test's voice) and the app's sound effects are off (its start chime would be
  heard as the mic picking up sound). The report says so.
- **Keyboard and mouse.** `wtool keys` sends key presses with `SendInput`, as a keyboard
  does; Blip's `WinKeyServer` hook sees them as real. Buttons are clicked with the mouse
  at their position from UI Automation, after the pointer moves onto them (the test's
  text box, which stays on top, is minimized first when a home-window button is clicked).
- **Where the text goes.** `wtool target` is a window with a text box that mirrors its text
  to a file, and logs the keys and focus changes it gets (`target-box-events.txt` in the
  artifact). Before each dictation the test brings it to the front and checks that it is
  the front window.

## Limits

- Windows Server, not Windows 11, and no real audio hardware: sleep and wake, Bluetooth
  and USB mics, and speaker or mic changes aren't covered (the Mac test covers device
  changes).
- The installer and app are tested as published: unsigned builds are reported as warnings.
