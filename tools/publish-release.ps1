# Joshua's one-command publish: build the manifest from publish.json, then upload it as a GitHub Release.
# NOT run by the prototype work - nothing has been published anywhere. Requires the GitHub CLI (gh) logged in.
#
#   .\tools\publish-release.ps1 -Config C:\Users\joshu\PeakPack\publish.json -Repo joshua/peak-pack
#
# What it does:
#   1. PeakPack.Cli publish  -> resolves deps, pins versions + SHA-256, signs, writes out\manifest.json
#   2. gh release create rev-N  with manifest.json, manifest.json.sig and the custom files the manifest references
#      (marked "latest", so friends' apps find it at .../releases/latest/download/manifest.json)
param(
    [Parameter(Mandatory)] [string]$Config,
    [Parameter(Mandatory)] [string]$Repo,
    [string]$OutDir = (Join-Path $env:LOCALAPPDATA 'PeakPack-publisher\out'),
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
if (-not (Test-Path $cli)) { & "C:\Program Files\dotnet\dotnet.exe" build (Join-Path $root 'src\PeakPack.Cli') -v q | Out-Null }

& $cli publish --config $Config --out $OutDir
if ($LASTEXITCODE -ne 0) { throw "publish failed" }

$manifestPath = Join-Path $OutDir 'manifest.json'
$m = Get-Content $manifestPath -Raw | ConvertFrom-Json
$tag = "rev-$($m.revision)"
$assets = @($manifestPath)
if (Test-Path "$manifestPath.sig") { $assets += "$manifestPath.sig" }
foreach ($f in $m.files) { if ($f.url -notmatch '^https?://') { $assets += (Join-Path $OutDir $f.url) } else { $assets += (Join-Path $OutDir ($f.url -split '/')[-1]) } }
if ($m.app) { $assets += (Join-Path $OutDir (($m.app.url -split '/')[-1])) }
$notes = if ($m.notes) { $m.notes } else { "PEAK mod pack revision $($m.revision)" }

Write-Host "`nRelease $tag on $Repo with:"; $assets | ForEach-Object { "  $_" }
if ($DryRun) { Write-Host "(dry run - nothing uploaded)"; exit 0 }
gh release create $tag @assets --repo $Repo --title "Pack revision $($m.revision)" --notes $notes --latest
Write-Host "Done. Friends get it next time they launch PEAK (Modded)."
