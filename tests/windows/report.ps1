# Writes the job summary from results.tsv, removes tokens and email addresses from every
# text file in the artifact (the repo and its artifacts are public), and fails the job
# if any check failed.
. "$PSScriptRoot/lib.ps1"

function Redact([string]$s) {
  $s = $s -replace 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+', '<jwt>'
  $s = $s -replace '((access_|refresh_)?token)=[^&" ]+', '$1=<redacted>'
  $s = $s -replace '(Bearer )[A-Za-z0-9._~+/-]+', '$1<redacted>'
  $s -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '<email>'
}

$log = App-Log
if ($log) { Copy-Item $log (Join-Path $OUT 'main.log') -Force }
Get-ChildItem $OUT -File -Include *.log, *.txt, *.tsv -Recurse | ForEach-Object {
  $c = Get-Content -Raw $_.FullName
  if ($null -ne $c) { Set-Content -Path $_.FullName -Value (Redact $c) -NoNewline }
}

$lines = @(Get-Content $RESULTS | Where-Object { $_ })
$count = { param($s) @($lines | Where-Object { $_ -like "$s`t*" }).Count }
$pass = & $count 'PASS'; $fail = & $count 'FAIL'; $warn = & $count 'WARN'; $skip = & $count 'SKIP'
$os = Get-CimInstance Win32_OperatingSystem
$md = @("## Blip $env:TAG on $($os.Caption) ($env:PROCESSOR_ARCHITECTURE)", '',
        "**$pass passed, $fail failed, $warn warnings, $skip skipped.** Screenshots and redacted logs are in the run's artifact.", '',
        '| | Check | Detail |', '|---|---|---|')
foreach ($l in $lines) {
  $status, $name, $detail = $l -split "`t", 3
  $icon = switch ($status) { 'PASS' { '✅' } 'FAIL' { '❌' } { $_ -in 'WARN', 'SKIP' } { '⚠️' } default { 'ℹ️' } }
  $md += "| $icon | $name | $(($detail -replace '\|', '\|')) |"
}
Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value (Redact ($md -join "`n")) -Encoding utf8
Write-Host "$pass passed, $fail failed, $warn warnings, $skip skipped"
if ($fail -gt 0) { exit 1 }
exit 0
