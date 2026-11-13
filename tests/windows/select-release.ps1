# Picks the release to test and downloads its Windows files.
#   REQUESTED_TAG empty -> the latest published release (what users and the updater get)
#   REQUESTED_TAG=v0.5.10 -> that release, drafts included; or, on a push, a
#   "Test-tag: v0.5.10" line in the commit message
. "$PSScriptRoot/lib.ps1"
$ErrorActionPreference = 'Stop'

$repo = if ($env:REPO) { $env:REPO } else { $env:GITHUB_REPOSITORY }
$dl = Join-Path $env:RUNNER_TEMP 'release'
New-Item -ItemType Directory -Force -Path $dl | Out-Null

$tag = $env:REQUESTED_TAG
if (-not $tag -and $env:COMMIT_MESSAGE -match '(?m)^Test-tag:\s*(v\S+)') { $tag = $Matches[1] }
if (-not $tag) { $tag = gh release view -R $repo --json tagName -q .tagName }
$version = $tag.TrimStart('v')

$json = gh release view $tag -R $repo --json tagName,isDraft,isPrerelease,publishedAt,assets
$json | Set-Content -Path (Join-Path $OUT 'release.json')
$rel = $json | ConvertFrom-Json
Record INFO 'Release under test' "$tag (draft: $($rel.isDraft), published: $(if ($rel.publishedAt) { $rel.publishedAt } else { 'not published' }))"

$setup = "Blip-AI-Setup-$version.exe"   # the file blipai.app/download/windows points to
$names = @($rel.assets | ForEach-Object { $_.name })
if ($names -notcontains $setup) { Record FAIL 'Release has the Windows installer' "$tag has no $setup"; exit 1 }

$patterns = @($setup, "$setup.blockmap", 'latest.yml') | Where-Object { $names -contains $_ } | ForEach-Object { '-p', $_ }
$ok = Invoke-Retry { gh release download $tag -R $repo -D $dl --clobber @patterns }
if (-not $ok) { Record FAIL 'Download the Windows files' "gh release download $tag failed"; exit 1 }
Get-ChildItem $dl | Format-Table Name, Length | Out-String | Write-Host

Add-Env TAG $tag
Add-Env VERSION $version
Add-Env DL $dl
Add-Env SETUP (Join-Path $dl $setup)
exit 0
