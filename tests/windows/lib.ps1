# Shared helpers for the Windows release test. Dot-sourced by the other scripts.
# Every check appends one line to $RESULTS:  STATUS<TAB>check<TAB>detail
# STATUS is PASS, FAIL, WARN (a real finding that doesn't break users), SKIP or INFO.
# report.ps1 turns the file into the job summary and fails the job if any line is FAIL.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$OUT = if ($env:OUT) { $env:OUT } else { Join-Path $env:RUNNER_TEMP 'blip-test' }
$RESULTS = Join-Path $OUT 'results.tsv'
$WTOOL = Join-Path $env:RUNNER_TEMP 'wtool.exe'
$TARGET_FILE = Join-Path $env:RUNNER_TEMP 'target.txt'
$APP_PROCESS = if ($env:APP_PROCESS) { $env:APP_PROCESS } else { 'Blip-AI' }
New-Item -ItemType Directory -Force -Path (Join-Path $OUT 'screens') | Out-Null
if (-not (Test-Path $RESULTS)) { New-Item -ItemType File -Path $RESULTS | Out-Null }

function Record([string]$Status, [string]$Check, [string]$Detail = '') {
  $Detail = $Detail -replace "[`t`r`n]+", ' '
  Add-Content -Path $RESULTS -Value "$Status`t$Check`t$Detail" -Encoding utf8
  if ($Status -eq 'FAIL') { Write-Host "::error title=${Check}::${Detail}" }
  elseif ($Status -in 'WARN', 'SKIP') { Write-Host "::warning title=${Check}::${Detail}" }
  else { Write-Host "$Status  $Check  $Detail" }
}

function Add-Env([string]$Name, [string]$Value) {
  Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value" -Encoding utf8
  Set-Item -Path "env:$Name" -Value $Value
}

function Wait-Until([int]$Seconds, [scriptblock]$Test) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if (& $Test) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Invoke-Retry([scriptblock]$Action, [int]$Tries = 4) {
  for ($i = 1; $i -le $Tries; $i++) {
    try { & $Action; if ($LASTEXITCODE -in $null, 0) { return $true } } catch { Write-Host "attempt $i failed: $_" }
    if ($i -lt $Tries) { Start-Sleep -Seconds (10 * $i) }
  }
  return $false
}

function W { & $WTOOL @args }   # the helper tool (wtool.cs)

function Screenshot([string]$Name) {
  # After sign-in the screen shows the account's email, plan and usage, and the artifact
  # is public: those screenshots stay on the runner unless PUBLISH_SIGNED_IN_SCREENSHOTS=1.
  $dir = Join-Path $OUT 'screens'
  if ((Test-Path (Join-Path $OUT '.signed-in')) -and $env:PUBLISH_SIGNED_IN_SCREENSHOTS -ne '1') {
    $dir = Join-Path $env:RUNNER_TEMP 'private-screens'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $n = @(Get-ChildItem -Path (Join-Path $OUT 'screens'), (Join-Path $env:RUNNER_TEMP 'private-screens') -Filter *.png -ErrorAction SilentlyContinue).Count
  W screenshot (Join-Path $dir ('{0:d2}-{1}.png' -f ($n + 1), $Name)) | Out-Null
}

function App-Running { [bool](Get-Process -Name $APP_PROCESS -ErrorAction SilentlyContinue) }
function App-Windows { ((W windows $APP_PROCESS) -join ', ') }
function App-Log {
  Get-ChildItem -Path $env:APPDATA -Filter main.log -Recurse -Depth 3 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'blip' } | Select-Object -First 1 -ExpandProperty FullName
}
function App-Config {
  Get-ChildItem -Path $env:APPDATA -Filter config.json -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'blip' } | Select-Object -First 1 -ExpandProperty FullName
}

# Closing Blip's window on Windows hides it to the tray (there's no scriptable Quit like
# the Mac's), so: close its windows, then end the process if it stays in the tray.
# Returns how it stopped: 'closed' or 'ended'.
function Stop-App {
  Get-Process -Name $APP_PROCESS -ErrorAction SilentlyContinue | ForEach-Object { $_.CloseMainWindow() | Out-Null }
  if (Wait-Until 5 { -not (App-Running) }) { return 'closed' }
  Get-Process -Name $APP_PROCESS -ErrorAction SilentlyContinue | Stop-Process -Force
  Wait-Until 10 { -not (App-Running) } | Out-Null
  return 'ended'
}

# Words of $Expected found in $Actual, as a percentage (case and punctuation ignored).
function Word-Recall([string]$Actual, [string]$Expected) {
  $norm = { param($s) [regex]::Matches($s.ToLower(), "[a-z0-9']+") | ForEach-Object { $_.Value } }
  $have = @(& $norm $Actual)
  $want = @(& $norm $Expected)
  if ($want.Count -eq 0) { return 0 }
  $hit = @($want | Where-Object { $have -contains $_ }).Count
  return [int][math]::Round(100 * $hit / $want.Count)
}

# Speech into the virtual microphone: each phrase is synthesized to a WAV once, then
# played on the default output (VB-CABLE's "CABLE Input"), which loops back into the
# default input ("CABLE Output").
function Speech-File([string]$Text) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))[0..5] | ForEach-Object { $_.ToString('x2') })
  Join-Path $env:RUNNER_TEMP "speech-$hash.wav"
}
function Render-Speech([string[]]$Texts) {   # wtool runs on .NET Framework, which has System.Speech
  foreach ($t in $Texts) {
    $f = Speech-File $t
    if (-not (Test-Path $f)) { W speak-file $f $t | Out-Null }
  }
}
function Speak([string]$Text) {
  Render-Speech @($Text)
  W play (Speech-File $Text) | Out-Null
}

# The dictation target: a text box (wtool target) whose text is mirrored to a file.
# Windows may refuse to bring a window to the front, and the app's own window can take
# the front while it loads, so check the front window and try again until it's the box.
function Focus-Target {
  if (-not ((W windows wtool) -match 'Blip Test Target')) {
    Start-Process -FilePath $WTOOL -ArgumentList 'target', "`"$TARGET_FILE`"" | Out-Null
    Wait-Until 15 { (W windows wtool) -match 'Blip Test Target' } | Out-Null
  }
  New-Item -ItemType File -Force -Path "$TARGET_FILE.clear" | Out-Null
  Start-Sleep -Milliseconds 600
  foreach ($try in 1..6) {
    W focus 'Blip Test Target' | Out-Null
    Start-Sleep -Milliseconds 500
    if ((W fg) -eq 'Blip Test Target') { Start-Sleep -Milliseconds 300; return }
    Start-Sleep -Milliseconds 700
  }
  Write-Host "front window is still: $(W fg)"
}

# The app's electron-store file, read with Python: PowerShell's JSON parser refuses
# objects whose keys differ only in case.
function Config-Value([string]$Key) {
  $c = App-Config
  if (-not $c) { return $null }
  $json = python -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1], encoding='utf-8')).get(sys.argv[2])))" $c $Key 2>$null
  if ($json) { return ($json | ConvertFrom-Json) } else { return $null }
}
# Get-Content -Raw gives $null for an empty file, and the caller still saw $null with a
# [string] cast (run 13), so callers wrap it: "$(Target-Text)" is always a string.
function Target-Text {
  $t = $null
  if (Test-Path $TARGET_FILE) { $t = Get-Content -Raw -Path $TARGET_FILE -ErrorAction SilentlyContinue }
  if ($null -eq $t) { return '' }
  return [string]$t
}
function Wait-Text([int]$Seconds = 30) {
  $deadline = (Get-Date).AddSeconds($Seconds)
  while ((Get-Date) -lt $deadline) {
    if ("$(Target-Text)".Trim()) { Start-Sleep -Seconds 2; return (Target-Text) }
    Start-Sleep -Milliseconds 250
  }
  return ''
}
function Judge([string]$Name, [string]$Expected, [string]$Actual, [int]$Min = 70) {
  $front = if ($script:FrontAfterRelease) { "; window in front after the keys were released: $script:FrontAfterRelease" } else { '' }
  $script:FrontAfterRelease = $null
  # What the text box itself got from 1 s before the keys were released (wtool target logs it).
  $events = "$TARGET_FILE.events"
  if ($script:ReleasedAt -and (Test-Path $events)) {
    $since = $script:ReleasedAt.AddSeconds(-1).ToString('HH:mm:ss.fff')
    $got = @(Get-Content $events -ErrorAction SilentlyContinue | Where-Object { $_.Length -ge 12 -and $_.Substring(0, 12) -ge $since } | ForEach-Object { $_.Substring(13) } | Select-Object -First 10)
    $front += "; the text box got: $(if ($got.Count) { $got -join ', ' } else { 'no keys or focus changes' })"
  }
  if (-not $Actual -or -not $Actual.Trim()) {
    Record FAIL $Name "nothing was typed into the target window within 30 s$front"
    return $false
  }
  $recall = Word-Recall $Actual $Expected
  $shown = ($Actual -replace '\s+', ' ').Trim()
  if ($shown.Length -gt 140) { $shown = $shown.Substring(0, 140) }
  if ($recall -ge $Min) { Record PASS $Name "$recall% of the spoken words; typed: `"$shown`""; return $true }
  Record FAIL $Name "$recall% of the spoken words (need $Min%); typed: `"$shown`""
  return $false
}
