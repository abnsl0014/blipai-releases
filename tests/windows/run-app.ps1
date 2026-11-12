# Runs the installed Windows app the way a new user does (mirrors tests/mac/run-app.sh):
#   1. first launch, signed out: the app starts, stays up and shows onboarding; on the
#      latest release its update check finds nothing newer
#   2. sign-in through the blipai://auth link the website opens (test account)
#   3. relaunch signed in: main window, key listener (WinKeyServer) running
#   4. dictation into a text box: push-to-talk (hold Ctrl+Win), hands-free
#      (Ctrl+Win+Space), filler words, Esc to cancel, Paste last transcript
#      (Shift+Alt+Z), history; and, when the app has them (0.5.10+): the "No sound"
#      notice and Open Settings, a failed transcription kept as a Missed item with
#      Save audio and Retry
#   5. quit
#   6. (0.5.10+) the session ends: the "You're signed out" notice and Sign in
. "$PSScriptRoot/lib.ps1"
New-Item -ItemType File -Force -Path (Join-Path $OUT '.started') | Out-Null

# Public values the app itself ships with: the Supabase project and its publishable key.
$SUPABASE_URL = if ($env:SUPABASE_URL) { $env:SUPABASE_URL } else { 'https://hqwmccawtepvundsgnil.supabase.co' }
$SUPABASE_KEY = if ($env:SUPABASE_KEY) { $env:SUPABASE_KEY } else { 'sb_publishable_TCu8hwzGitgxmzCu2rYHiA_6r3MImeD' }
$repo = if ($env:REPO) { $env:REPO } else { $env:GITHUB_REPOSITORY }
$asar = Join-Path $env:INSTALL_DIR 'resources\app.asar'
function App-Has([string]$s) { [bool](Select-String -Path $asar -SimpleMatch -Pattern $s -Quiet) }
function Key-Server-Running { [bool](Get-Process -Name WinKeyServer -ErrorAction SilentlyContinue) }
function Signed-In { $c = App-Config; $c -and ((Get-Content -Raw $c | ConvertFrom-Json).authToken) }
function Ui-Dump([string]$Name) {
  $file = Join-Path $OUT "ui-$Name.txt"
  foreach ($try in 1..3) {
    W uia-text $APP_PROCESS | Set-Content -Path $file
    if (@(Get-Content $file | Where-Object { $_ -notmatch '^== window' }).Count) { return }
    Start-Sleep -Seconds 3
  }
}
function Ui-Text([string]$Name) { (Get-Content (Join-Path $OUT "ui-$Name.txt") -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch '^== window' }) -join '|' }
function Launch { Start-Process -FilePath $env:APP_EXE | Out-Null; Wait-Until 30 { App-Running } }
function Ptt([string]$Phrase) {   # hold Ctrl+Win, speak, release
  W keys down ctrl | Out-Null; W keys down win | Out-Null
  Start-Sleep -Milliseconds 600
  if ($Phrase) { Speak $Phrase }
  Start-Sleep -Milliseconds 800
  W keys up win | Out-Null; W keys up ctrl | Out-Null
}
function History {
  $c = App-Config
  if (-not $c) { return @() }
  $h = (Get-Content -Raw $c | ConvertFrom-Json).transcriptionHistory
  if ($h) { return @($h) } else { return @() }
}
function Collect-CrashReports {
  Get-ChildItem (Join-Path $env:APPDATA) -Recurse -Depth 4 -Filter '*.dmp' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'blip' -and $_.LastWriteTime -gt (Get-Item (Join-Path $OUT '.started')).LastWriteTime } |
    ForEach-Object { Copy-Item $_.FullName $OUT }
}

# One virtual cable here: the default output is the test's voice, so turn off Blip's
# "mute system audio while dictating" before first launch (Windows paths ignore case,
# so this is the app's own settings folder).
$seedDir = Join-Path $env:APPDATA 'Blip-AI'
New-Item -ItemType Directory -Force -Path $seedDir | Out-Null
'{"muteSystemAudioDuringDictation": false}' | Set-Content -Path (Join-Path $seedDir 'config.json') -Encoding utf8
Record INFO 'System audio mute while dictating' 'turned off on Windows: the runner has one virtual audio device, and muting it would silence the test voice'

# --- 1. First launch, signed out ---------------------------------------------------
if (Launch) { Record PASS 'Launches after install' "pid $((Get-Process -Name $APP_PROCESS | Select-Object -First 1).Id)" }
else { Record FAIL 'Launches after install' "no $APP_PROCESS process after 30 s"; Collect-CrashReports; exit 0 }
Start-Sleep -Seconds 15
Screenshot 'first-launch'
if (App-Running) { Record PASS 'Stays up on first launch (15 s)' '' } else { Record FAIL 'Stays up on first launch (15 s)' 'the app exited'; Collect-CrashReports; exit 0 }
$windows = App-Windows
if ($windows) { Record PASS 'Shows onboarding on first launch' "windows: $windows" } else { Record FAIL 'Shows onboarding on first launch' 'no window' }
Ui-Dump 'onboarding'
Record INFO 'Onboarding text' ((Ui-Text 'onboarding').Substring(0, [math]::Min(300, (Ui-Text 'onboarding').Length)))

$log = App-Log
$update = if ($log) { Select-String -Path $log -Pattern 'Found version|is not available|Error: ' | Select-Object -First 1 } else { $null }
$latest = gh release view -R $repo --json tagName -q .tagName
if (-not $update) { Record FAIL 'Update check on launch' "no update check in the app's main.log 15 s after launch (log: $log)" }
elseif ($env:TAG -eq $latest -and $update.Line -match 'is not available') { Record PASS 'Update check on launch' "up to date: $($update.Line -replace '^.*\] ', '')" }
elseif ($env:TAG -eq $latest) { Record FAIL 'Update check on launch' $update.Line }
else { Record INFO 'Update check on launch' $update.Line }

# --- 2. Sign in ---------------------------------------------------------------------
if (-not $env:BLIP_TEST_EMAIL -or -not $env:BLIP_TEST_PASSWORD) {
  Record SKIP 'Sign in and dictation' 'add the BLIP_TEST_EMAIL and BLIP_TEST_PASSWORD secrets to test them'
  Record INFO 'Stopped' "window close, then $(Stop-App)"
  exit 0
}
$body = @{ email = $env:BLIP_TEST_EMAIL; password = $env:BLIP_TEST_PASSWORD } | ConvertTo-Json
try {
  $session = Invoke-RestMethod -Method Post -Uri "$SUPABASE_URL/auth/v1/token?grant_type=password" -TimeoutSec 30 `
    -Headers @{ apikey = $SUPABASE_KEY } -ContentType 'application/json' -Body $body
} catch { $session = $null; $authError = $_.ErrorDetails.Message }
if (-not $session.access_token) { Record FAIL 'Test account signs in (Supabase)' "$authError"; Stop-App | Out-Null; exit 0 }
$access = $session.access_token; $refresh = $session.refresh_token
Write-Host "::add-mask::$access"
Write-Host "::add-mask::$refresh"
Record PASS 'Test account signs in (Supabase)' 'password grant returned a session'

New-Item -ItemType File -Force -Path (Join-Path $OUT '.signed-in') | Out-Null   # screenshots stay private from here
Start-Process "blipai://auth?token=$access&refresh_token=$refresh"
if (Wait-Until 45 { Signed-In }) { Record PASS 'Signs in through the blipai://auth link' 'token saved by the app' }
else { Record FAIL 'Signs in through the blipai://auth link' 'no token saved within 45 s' }
Start-Sleep -Seconds 3
Screenshot 'signed-in'
Ui-Dump 'signed-in'

# --- 3. Relaunch signed in ------------------------------------------------------------
Record INFO 'Stopped after onboarding' "$(Stop-App)"
Launch | Out-Null
Start-Sleep -Seconds 15
Screenshot 'relaunch-signed-in'
if (App-Running) { Record PASS 'Relaunches signed in' "windows: $(App-Windows)" } else { Record FAIL 'Relaunches signed in' 'the app exited'; Collect-CrashReports; exit 0 }
if (Wait-Until 20 { Key-Server-Running }) { Record PASS 'Key listener running (WinKeyServer)' '' }
else { Record FAIL 'Key listener running (WinKeyServer)' 'not started: the Ctrl+Win shortcut can''t work' }
Ui-Dump 'home'

# --- 4. Dictation ---------------------------------------------------------------------
$phrases = @(
  'The quick brown fox jumps over the lazy dog near the river bank.',
  'Please send the quarterly report to the whole team before Friday afternoon.',
  'Um, so I think we should, uh, move the meeting to next week.',
  'This sentence should never be typed.',
  'Remember to water the plants on Saturday morning.')
Render-Speech $phrases

# 4a. Push-to-talk.
Focus-Target
$t0 = Get-Date
Ptt $phrases[0]
$released = Get-Date
$text = Wait-Text 30
if (Judge 'Push-to-talk (hold Ctrl+Win) types into the focused app' $phrases[0] $text) {
  Record INFO 'Push-to-talk: keys released -> text in the window' "$([int]((Get-Date) - $released).TotalMilliseconds - 2000) ms"
}
Screenshot 'push-to-talk'

# 4b. Hands-free.
Focus-Target
W keys chord ctrl+win+space | Out-Null
Start-Sleep -Milliseconds 800; Speak $phrases[1]; Start-Sleep -Milliseconds 800
W keys chord ctrl+win+space | Out-Null
Judge 'Hands-free (Ctrl+Win+Space to start and stop)' $phrases[1] (Wait-Text 30) | Out-Null

# 4c. Filler words.
Focus-Target
Ptt $phrases[2]
$lastText = Wait-Text 30
Judge 'Dictation with filler words' 'I think we should move the meeting to next week' $lastText | Out-Null
if ($lastText) {
  if ($lastText -match '(?i)\b(um|uh)\b') { Record FAIL 'Filler words left out' "typed: `"$lastText`"" }
  else { Record PASS 'Filler words left out' "no um/uh in `"$lastText`"" }
}

# 4d. Esc cancels a hands-free dictation.
Focus-Target
W keys chord ctrl+win+space | Out-Null
Start-Sleep -Milliseconds 800; Speak $phrases[3]
W keys tap escape | Out-Null
Start-Sleep -Seconds 10
if ((Target-Text).Trim()) { Record FAIL 'Esc cancels a hands-free dictation' "typed: `"$(Target-Text)`"" }
else { Record PASS 'Esc cancels a hands-free dictation' 'nothing typed in 10 s' }
Start-Sleep -Seconds 2

# 4e. Paste last transcript.
Focus-Target
W keys chord shift+alt+z | Out-Null
$pasted = Wait-Text 15
if (-not $lastText) { Record SKIP 'Paste last transcript (Shift+Alt+Z)' 'no earlier dictation to paste' }
else { Judge 'Paste last transcript (Shift+Alt+Z)' $lastText $pasted 90 | Out-Null }

Record SKIP 'Dictates after the speakers or default mic change' 'the Windows runner has one virtual audio device; tested on Mac'
Record SKIP 'First dictation after the PC wakes from sleep' 'a GitHub runner can''t sleep and wake; check by hand'
Record SKIP 'Real Bluetooth or USB mic plugged in or out mid-dictation' 'no such hardware on a runner'

# 4g. Silent microphone: "No sound" notice with "Open Settings" (0.5.10+).
if (App-Has 'id="status-action"') {
  Focus-Target
  W keys down ctrl | Out-Null; W keys down win | Out-Null
  Start-Sleep -Milliseconds 4500
  Ui-Dump 'no-sound'
  Screenshot 'no-sound'
  $notice = (Get-Content (Join-Path $OUT 'ui-no-sound.txt')) -match "(?i)no sound|can.t hear|couldn.t hear|is muted" | Select-Object -First 1
  if ($notice) { Record PASS 'Silent mic: ''No sound'' notice' $notice } else { Record FAIL 'Silent mic: ''No sound'' notice' "overlay showed: $(Ui-Text 'no-sound')" }
  $pressed = W uia-press $APP_PROCESS 'Open Settings'
  Start-Sleep -Seconds 3
  W keys up win | Out-Null; W keys up ctrl | Out-Null
  Start-Sleep -Seconds 2
  Ui-Dump 'open-settings'
  if ("$pressed" -like 'pressed*' -and (Ui-Text 'open-settings') -match '(?i)microphone') { Record PASS '''Open Settings'' opens the microphone settings' "$pressed" }
  else { Record FAIL '''Open Settings'' opens the microphone settings' "press: $pressed; windows: $(App-Windows)" }
  if ((Target-Text).Trim()) { Record FAIL 'Silent dictation types nothing' "typed: `"$(Target-Text)`"" } else { Record PASS 'Silent dictation types nothing' '' }
  W keys tap escape | Out-Null
} else {
  Record SKIP 'Silent mic: ''No sound'' notice' 'this version has no microphone notices (added in 0.5.10)'
}

# 4h. Failed transcription: a "Missed" item with Retry and Save audio (0.5.10+).
if (App-Has 'data-missed-action') {
  $ips = @(Resolve-DnsName -Name 'proxy.tryblipai.com', 'api.groq.com' -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress }) | Sort-Object -Unique
  $profilesOff = @(Get-NetFirewallProfile | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
  if ($profilesOff) { Set-NetFirewallProfile -Name $profilesOff -Enabled True }
  New-NetFirewallRule -DisplayName 'blip-test-block-stt' -Direction Outbound -RemoteAddress $ips -Action Block | Out-Null
  Record INFO 'Transcription servers blocked' "proxy.tryblipai.com and api.groq.com ($($ips -join ', '))"
  Focus-Target
  Ptt $phrases[4]
  $missed = $null
  Wait-Until 60 { $n = History | Select-Object -First 1; if ($n -and $n.status -eq 'missed') { $script:missed = $n }; [bool]$script:missed } | Out-Null
  Ui-Dump 'missed-error'
  Remove-NetFirewallRule -DisplayName 'blip-test-block-stt' -ErrorAction SilentlyContinue
  if ($profilesOff) { Set-NetFirewallProfile -Name $profilesOff -Enabled False }
  if ($missed) {
    Record PASS 'Failed transcription is kept as a Missed item' "overlay: $((Ui-Text 'missed-error') -replace '^(.{0,140}).*$', '$1')"
    Start-Process -FilePath $env:APP_EXE | Out-Null       # brings the main window up
    Start-Sleep -Seconds 3
    $before = Get-Date
    $pressed = W uia-press $APP_PROCESS 'Save audio'
    Start-Sleep -Seconds 3
    W keys tap return | Out-Null                             # the Save dialog's default button
    Start-Sleep -Seconds 3
    $saved = Get-ChildItem -Path ([Environment]::GetFolderPath('MyDocuments')), (Join-Path $env:USERPROFILE 'Downloads'), ([Environment]::GetFolderPath('Desktop')), ([Environment]::GetFolderPath('MyMusic')) -Include *.wav, *.mp3 -Recurse -Depth 1 -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -gt $before } | Select-Object -First 1
    if ($saved -and $saved.Length -gt 10000) { Record PASS 'Missed item: Save audio writes the recording' "$($saved.Name), $($saved.Length) bytes" }
    else { Record FAIL 'Missed item: Save audio writes the recording' "press: $pressed; no new .wav/.mp3 in Documents, Downloads, Desktop or Music" }
    $pressed = W uia-press $APP_PROCESS 'Retry'
    $retried = $null
    Wait-Until 60 { $r = History | Where-Object { "$($_.timestamp)" -eq "$($missed.timestamp)" } | Select-Object -First 1; if ($r -and $r.status -ne 'missed' -and $r.text) { $script:retried = $r.text }; [bool]$script:retried } | Out-Null
    if ($retried) { Judge 'Missed item: Retry transcribes it' $phrases[4] $retried | Out-Null }
    else { Record FAIL 'Missed item: Retry transcribes it' "press: $pressed; still Missed after 60 s" }
  } else {
    $n = History | Select-Object -First 1
    Record FAIL 'Failed transcription is kept as a Missed item' "newest history item: $(if ($n) { "$($n.status) `"$($n.text)`"" } else { 'none' }); overlay: $(Ui-Text 'missed-error')"
  }
} else {
  Record SKIP 'Failed transcription is kept as a Missed item' 'this version has no Missed items (added in 0.5.10)'
}

# History.
$all = (History | ForEach-Object { $_.text }) -join ' '
if ($all -match '(?i)quick brown fox' -and $all -match '(?i)quarterly report') { Record PASS 'Dictations saved to history' "$(@(History).Count) entries, including the push-to-talk and hands-free ones" }
else { Record FAIL 'Dictations saved to history' "$(@(History).Count) entries" }
$log = App-Log
if ($log) { Select-String -Path $log -Pattern '\[(stt|paste)-timing\]' | ForEach-Object { $_.Line } | Set-Content (Join-Path $OUT 'dictation-timing.txt') }

# --- 5. Quit ----------------------------------------------------------------------------
$how = Stop-App
Record INFO 'Stopped' "$how (closing the window keeps Blip in the tray)"
Start-Sleep -Seconds 5
if (Key-Server-Running) {
  Record WARN 'Key listener exits with the app' "WinKeyServer still running 5 s after the app was $how"
  Get-Process WinKeyServer | Stop-Process -Force
} else { Record PASS 'Key listener exits with the app' "after the app was $how" }
Collect-CrashReports

# End this session on the server (scope=local: only this runner's session).
try { Invoke-RestMethod -Method Post -Uri "$SUPABASE_URL/auth/v1/logout?scope=local" -TimeoutSec 30 -Headers @{ apikey = $SUPABASE_KEY; Authorization = "Bearer $access" } | Out-Null } catch { }

# --- 6. The session ended: "Sign in" notice (0.5.10+) --------------------------------
if (App-Has 'id="status-action"') {
  $cfgPath = App-Config
  $cfg = Get-Content -Raw $cfgPath | ConvertFrom-Json
  $b64 = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
  $payload = @{ sub = 'expired'; exp = [int][double]::Parse((Get-Date -UFormat %s)) - 3600 }
  try {
    $p = $cfg.authToken.Split('.')[1].Replace('-', '+').Replace('_', '/'); $p += '=' * ((4 - $p.Length % 4) % 4)
    $payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) | ConvertFrom-Json
    $payload.exp = [int][double]::Parse((Get-Date -UFormat %s)) - 3600
  } catch { }
  $cfg.authToken = (& $b64 @{ alg = 'HS256'; typ = 'JWT' }) + '.' + (& $b64 $payload) + '.expired'
  $cfg | ConvertTo-Json -Depth 20 | Set-Content -Path $cfgPath -Encoding utf8
  Launch | Out-Null
  Start-Sleep -Seconds 15
  Focus-Target
  W keys down ctrl | Out-Null; W keys down win | Out-Null
  Start-Sleep -Milliseconds 2500
  Ui-Dump 'signed-out'
  W keys up win | Out-Null; W keys up ctrl | Out-Null
  Start-Sleep -Seconds 2
  Ui-Dump 'signed-out-after'
  $notice = @(Get-Content (Join-Path $OUT 'ui-signed-out.txt'), (Join-Path $OUT 'ui-signed-out-after.txt') -ErrorAction SilentlyContinue) -match '(?i)signed out|sign in to keep' | Select-Object -First 1
  if ($notice) {
    Record PASS 'Ended session: ''You''re signed out'' notice' $notice
    $browsersBefore = @(Get-Process msedge, chrome, firefox -ErrorAction SilentlyContinue).Count
    $pressed = W uia-press $APP_PROCESS 'Sign in'
    Start-Sleep -Seconds 6
    $browser = @(Get-Process msedge, chrome, firefox -ErrorAction SilentlyContinue).Count -gt $browsersBefore
    if ("$pressed" -like 'pressed*' -and ($browser -or (App-Windows) -match '(?i)welcome')) { Record PASS '''Sign in'' starts signing in again' "opened $(if ($browser) { 'the browser' } else { 'onboarding' })" }
    else { Record FAIL '''Sign in'' starts signing in again' "press: $pressed; windows: $(App-Windows)" }
  } else {
    Record FAIL 'Ended session: ''You''re signed out'' notice' "windows: $(App-Windows); text: $(Ui-Text 'signed-out')"
  }
  Stop-App | Out-Null
} else {
  Record SKIP 'Ended session: ''You''re signed out'' notice' 'this version has no sign-in notice (added in 0.5.10)'
}
exit 0
