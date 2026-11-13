# Checks what the Windows auto-updater relies on: latest.yml names this version and
# lists the installer with the size and sha512 of the file on the release; the
# blockmap (for differential updates) is there; and the installer's Authenticode
# signature, which decides whether SmartScreen warns people who run it.
. "$PSScriptRoot/lib.ps1"

$yml = Join-Path $env:DL 'latest.yml'
if (-not (Test-Path $yml)) { Record FAIL 'Updater metadata (latest.yml)' "not on the release: Windows users would never be offered $env:TAG"; exit 0 }
$text = Get-Content -Raw $yml
$ymlVersion = if ($text -match '(?m)^version:\s*(\S+)') { $Matches[1] } else { '' }
if ($ymlVersion -eq $env:VERSION) { Record PASS 'latest.yml version' $ymlVersion }
else { Record FAIL 'latest.yml version' "says $ymlVersion, release is $env:VERSION" }

$rel = Get-Content -Raw (Join-Path $OUT 'release.json') | ConvertFrom-Json
$files = [regex]::Matches($text, '(?ms)-\s*url:\s*(\S+)\s*\r?\n\s*sha512:\s*(\S+)\s*\r?\n\s*size:\s*(\d+)')
$problems = @()
foreach ($f in $files) {
  $name = $f.Groups[1].Value; $size = [long]$f.Groups[3].Value
  $asset = $rel.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
  if (-not $asset) { $problems += "$name (not on the release)" }
  elseif ([long]$asset.size -ne $size) { $problems += "$name (yml $size bytes, asset $($asset.size))" }
  $local = Join-Path $env:DL $name
  if (Test-Path $local) {
    $sha = [Convert]::ToBase64String([System.Security.Cryptography.SHA512]::Create().ComputeHash([IO.File]::ReadAllBytes($local)))
    if ($sha -eq $f.Groups[2].Value) { Record PASS "sha512 $name" 'matches latest.yml' }
    else { Record FAIL "sha512 $name" 'file hashes to a different value than latest.yml says' }
  }
}
if ($files.Count -eq 0) { Record FAIL 'Files listed in latest.yml' 'no files found in latest.yml' }
elseif ($problems.Count -eq 0) { Record PASS 'Files listed in latest.yml are on the release' "$($files.Count) file(s), sizes match" }
else { Record FAIL 'Files listed in latest.yml are on the release' ($problems -join '; ') }

$blockmap = "$(Split-Path -Leaf $env:SETUP).blockmap"
if (@($rel.assets | Where-Object { $_.name -eq $blockmap }).Count) { Record PASS 'Installer blockmap on the release' "$blockmap (differential updates)" }
else { Record WARN 'Installer blockmap on the release' "$blockmap missing: updates download the whole installer" }

$sig = Get-AuthenticodeSignature -FilePath $env:SETUP
if ($sig.Status -eq 'Valid') { Record PASS 'Installer is code-signed' $sig.SignerCertificate.Subject }
else { Record WARN 'Installer is code-signed' "$($sig.Status): Windows SmartScreen warns people who download and run it" }
exit 0
