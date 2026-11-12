# Prepares a GitHub Windows runner to stand in for a person at a PC:
#   - a microphone: Windows Server runners have no sound devices, so this turns the
#     audio service on and installs VB-CABLE. Its "CABLE Input" is the default output
#     and "CABLE Output" the default input, so speech played on the output reaches
#     any app recording from the default microphone.
#   - a keyboard and screen: wtool.cs (SendInput keys, a keyboard hook, UI Automation,
#     screenshots, and a text box the dictations type into).
. "$PSScriptRoot/lib.ps1"

$os = Get-CimInstance Win32_OperatingSystem
Record INFO 'Runner' "$($os.Caption) $($os.Version), $env:PROCESSOR_ARCHITECTURE"

# --- helper tool ------------------------------------------------------------------
$fx = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $fx 'csc.exe'
$refs = @('System.Windows.Forms.dll', 'System.Drawing.dll')
foreach ($dll in 'UIAutomationClient.dll', 'UIAutomationTypes.dll', 'WindowsBase.dll', 'System.Speech.dll') {
  $path = Get-ChildItem -Path $fx -Filter $dll -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  if (-not $path) {   # the reference assemblies, if the runtime folder doesn't have it
    $path = Get-ChildItem -Path "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework" -Filter $dll -Recurse -ErrorAction SilentlyContinue |
      Select-Object -Last 1 -ExpandProperty FullName
  }
  $refs += $(if ($path) { $path } else { $dll })
}
$cscOut = & $csc /nologo /optimize "/out:$WTOOL" ($refs | ForEach-Object { "/r:$_" }) (Join-Path $PSScriptRoot 'wtool.cs') 2>&1
$cscOut | Set-Content (Join-Path $OUT 'csc.txt')
if ($LASTEXITCODE -ne 0) { Record FAIL 'Build the helper tool' (($cscOut | Select-Object -Last 3) -join ' '); exit 0 }

# --- audio --------------------------------------------------------------------------
foreach ($svc in 'AudioEndpointBuilder', 'Audiosrv') {
  Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
  Start-Service -Name $svc -ErrorAction SilentlyContinue
}
Record INFO 'Windows Audio service' ((Get-Service Audiosrv, AudioEndpointBuilder | ForEach-Object { "$($_.Name)=$($_.Status)" }) -join ', ')

$chocoLog = Join-Path $OUT 'choco-vbcable.txt'
foreach ($try in 1, 2) {
  choco install vb-cable -y --no-progress *> $chocoLog
  $code = $LASTEXITCODE
  if ($code -in 0, 1641, 3010) { break }   # 3010/1641: installed, a reboot is "suggested"
  Start-Sleep -Seconds 15
}
if ($code -notin 0, 1641, 3010) { Record FAIL 'Install VB-CABLE (virtual audio)' "choco exit ${code}: $((Get-Content $chocoLog -Tail 5) -join ' ')" }
choco install sox.portable -y --no-progress *> (Join-Path $OUT 'choco-sox.txt')
Restart-Service -Name Audiosrv -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Make CABLE the default playback and recording device (AudioDeviceCmdlets runs in
# Windows PowerShell 5.1).
$devices = powershell.exe -NoProfile -Command @'
$ErrorActionPreference = 'Stop'
try {
  if (-not (Get-Module -ListAvailable AudioDeviceCmdlets)) {
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    Install-Module -Name AudioDeviceCmdlets -Force -Scope CurrentUser -AllowClobber
  }
  Import-Module AudioDeviceCmdlets
  $list = Get-AudioDevice -List
  $list | Where-Object { $_.Type -eq 'Playback' -and $_.Name -like 'CABLE Input*' } | Select-Object -First 1 | Set-AudioDevice | Out-Null
  $list | Where-Object { $_.Type -eq 'Recording' -and $_.Name -like 'CABLE Output*' } | Select-Object -First 1 | Set-AudioDevice | Out-Null
  Get-AudioDevice -List | ForEach-Object { "$($_.Type): $($_.Name)$(if ($_.Default) { ' (default)' })" }
} catch { "AudioDeviceCmdlets: $_" }
'@
$devices | Set-Content -Path (Join-Path $OUT 'audio-devices.txt')
Write-Host ($devices -join "`n")
Record INFO 'Audio devices' (($devices | Where-Object { $_ -match 'default|AudioDeviceCmdlets' }) -join '; ')

# Microphone privacy: let desktop apps use the microphone (on by default on desktops).
foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
               'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone') {
  New-Item -Path $k -Force -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $k -Name Value -Value 'Allow' -ErrorAction SilentlyContinue
}

# Loopback: what is played on the default output must come back on the default input.
$phrase = 'Testing the virtual microphone.'
Render-Speech @($phrase)
$sox = (Get-Command sox -ErrorAction SilentlyContinue).Source
$wav = Join-Path $OUT 'loopback.wav'
if ($sox) {
  $rec = Start-Process -FilePath $sox -ArgumentList '-q', '-t', 'waveaudio', 'default', "`"$wav`"", 'trim', '0', '5' -PassThru -NoNewWindow
  Start-Sleep -Seconds 1
  Speak $phrase
  if (-not $rec.WaitForExit(15000)) { $rec.Kill() }
  $stat = & $sox $wav -n stat 2>&1
  $m = $stat | Select-String 'RMS\s+amplitude:\s+([0-9.]+)' | Select-Object -First 1
  $rms = if ($m) { $m.Matches[0].Groups[1].Value } else { '' }
  if ([double]("0$rms") -gt 0.003) { Record PASS 'Virtual microphone carries speech' "RMS $rms" }
  else { Record FAIL 'Virtual microphone carries speech' "RMS $(if ($rms) { $rms } else { 'none' }): the default input heard nothing" }
} else {
  Record SKIP 'Virtual microphone carries speech' 'sox did not install; the dictation checks will show it'
}

# --- synthetic keys reach a low-level keyboard hook (as Blip's WinKeyServer uses) -----
$watchLog = Join-Path $OUT 'key-watch.txt'
$watch = Start-Process -FilePath $WTOOL -ArgumentList 'watch', '4' -RedirectStandardOutput $watchLog -PassThru -NoNewWindow
Wait-Until 5 { (Test-Path $watchLog) -and (Select-String -Path $watchLog -Pattern HOOK_READY -Quiet) } | Out-Null
W keys chord ctrl+win+space | Out-Null
$watch.WaitForExit(8000) | Out-Null
W keys tap escape | Out-Null          # close the Start menu if Win opened it
$seen = Get-Content $watchLog -ErrorAction SilentlyContinue
if (($seen -match 'vk=0xa2') -and ($seen -match 'vk=0x5b') -and ($seen -match 'vk=0x20')) {
  Record PASS 'Synthetic Ctrl+Win+Space reaches a keyboard hook' "$(@($seen -match '^event').Count) events seen"
} else {
  Record FAIL 'Synthetic Ctrl+Win+Space reaches a keyboard hook' (($seen | Select-Object -First 4) -join ' ')
}
exit 0
