# Installs the release the way users get it, and checks the installed app.
#   1. Update path (latest published release only; the updater never sees drafts):
#      install the previous release, launch it, and check its updater is offered this
#      version. The new installer then installs over it, as an update does.
#   2. Install this release's Setup exe silently (/S, per-user, no admin), then check
#      version, signature, shortcuts, uninstall entry, the blipai:// handler and the
#      key listener helper (WinKeyServer.exe).
. "$PSScriptRoot/lib.ps1"
$repo = if ($env:REPO) { $env:REPO } else { $env:GITHUB_REPOSITORY }

function Find-AppExe {
  Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs') -Filter 'Blip-AI.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
    Select-Object -First 1 -ExpandProperty FullName
}
function Install-Setup([string]$Path) {
  $p = Start-Process -FilePath $Path -ArgumentList '/S' -PassThru -Wait
  Start-Sleep -Seconds 3
  Get-Process -Name $APP_PROCESS -ErrorAction SilentlyContinue | Stop-Process -Force   # some installers launch the app
  return $p.ExitCode
}

# --- 1. update path ---------------------------------------------------------------
$latest = gh release view -R $repo --json tagName -q .tagName
if ($env:TAG -ne $latest) {
  Record SKIP 'Previous release is offered this update' "$env:TAG isn't the latest published release ($latest), so no installed app would be offered it yet"
} else {
  $previous = (gh release list -R $repo --exclude-drafts --exclude-pre-releases --limit 30 --json tagName,publishedAt | ConvertFrom-Json |
    Sort-Object publishedAt -Descending | Where-Object { $_.tagName -ne $env:TAG } | Select-Object -First 1).tagName
  $prevSetup = "Blip-AI-Setup-$($previous.TrimStart('v')).exe"
  $prevDir = Join-Path $env:RUNNER_TEMP 'previous'
  if ($previous -and (Invoke-Retry { gh release download $previous -R $repo -D $prevDir --clobber -p $prevSetup })) {
    $code = Install-Setup (Join-Path $prevDir $prevSetup)
    $oldExe = Find-AppExe
    if ($code -ne 0 -or -not $oldExe) {
      Record FAIL 'Previous release is offered this update' "$previous didn't install (exit $code)"
    } else {
      Start-Process -FilePath $oldExe | Out-Null
      $found = $null
      Wait-Until 90 { $log = App-Log; if ($log) { $script:found = Select-String -Path $log -Pattern 'Found version|is not available|Error: ' | Select-Object -First 1 }; [bool]$script:found } | Out-Null
      Screenshot 'previous-release-update-check'
      if ($found -and $found.Line -match "Found version $([regex]::Escape($env:VERSION))") { Record PASS 'Previous release is offered this update' "$previous found $env:VERSION after launch" }
      elseif ($found) { Record FAIL 'Previous release is offered this update' "$previous logged: $($found.Line)" }
      else { Record FAIL 'Previous release is offered this update' "$previous logged no update check within 90 s (log: $(App-Log))" }
      Stop-App | Out-Null
      $log = App-Log; if ($log) { Copy-Item $log (Join-Path $OUT 'previous-release-main.log') }
    }
  } else {
    Record SKIP 'Previous release is offered this update' "no earlier release with $prevSetup"
  }
}

# --- 2. install this release ------------------------------------------------------
$code = Install-Setup $env:SETUP
$exe = Find-AppExe
if ($code -ne 0 -or -not $exe) { Record FAIL 'Installer runs silently (/S)' "exit $code, Blip-AI.exe found: $([bool]$exe)"; exit 1 }
Record PASS 'Installer runs silently (/S)' $exe
$dir = Split-Path $exe
Add-Env APP_EXE $exe
Add-Env INSTALL_DIR $dir

$v = (Get-Item $exe).VersionInfo.ProductVersion
if ($v -eq $env:VERSION -or $v -like "$env:VERSION.*") { Record PASS 'App version' $v } else { Record FAIL 'App version' "app says $v, release is $env:VERSION" }

$sig = Get-AuthenticodeSignature -FilePath $exe
if ($sig.Status -eq 'Valid') { Record PASS 'App is code-signed' $sig.SignerCertificate.Subject }
else { Record WARN 'App is code-signed' "$($sig.Status): unsigned apps get more antivirus and SmartScreen warnings" }

$uninstall = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
  ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DisplayName -like 'Blip*' } | Select-Object -First 1
if ($uninstall -and $uninstall.DisplayVersion -eq $env:VERSION) { Record PASS 'Listed in Installed apps' "$($uninstall.DisplayName) $($uninstall.DisplayVersion)" }
else { Record FAIL 'Listed in Installed apps' "uninstall entry: $(if ($uninstall) { "$($uninstall.DisplayName) $($uninstall.DisplayVersion)" } else { 'none' })" }

$startMenu = Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') -Filter 'Blip*.lnk' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($startMenu) { Record PASS 'Start menu shortcut' $startMenu.Name } else { Record FAIL 'Start menu shortcut' 'none' }
$desktop = Get-ChildItem ([Environment]::GetFolderPath('Desktop')) -Filter 'Blip*.lnk' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($desktop) { Record PASS 'Desktop shortcut' $desktop.Name } else { Record WARN 'Desktop shortcut' 'none' }

$handler = (Get-ItemProperty 'HKCU:\Software\Classes\blipai\shell\open\command' -ErrorAction SilentlyContinue).'(default)'
# The app registers blipai:// when it first runs; run-app.ps1 checks it then.
Record INFO 'blipai:// handler right after install' "$(if ($handler) { $handler } else { 'not yet (the app registers it on first launch)' })" 

$keyServer = Get-ChildItem -Path $dir -Filter 'WinKeyServer.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if ($keyServer) { Record PASS 'Key listener helper (WinKeyServer.exe)' "$([math]::Round($keyServer.Length / 1KB)) KB" }
else { Record FAIL 'Key listener helper (WinKeyServer.exe)' 'not in the install: the push-to-talk shortcut can''t work' }

# A clean first launch for run-app.ps1: no settings or logs from the previous release.
Get-ChildItem $env:APPDATA -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^blip' } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
exit 0
