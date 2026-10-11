# Joshua's one-command publish (headless; the Host window does the same thing):
#   build the friend app, stage pack revision N+1 from publish.json, and upload it as GitHub release rev-N.
#
#   .\tools\publish-release.ps1 -DryRun                      # show what friends will get + the exact gh command; uploads nothing
#   .\tools\publish-release.ps1 -Notes "Added InfiniteGlider" # real release (needs gh logged in and the repo to exist)
#
# Steps: dotnet publish (PeakPack.exe) -> build the companion -> PeakPack.Cli release (prepare + gh release create --latest)
#        -> optional -Stamp: write the companion + pack-info.json into Joshua's own BepInEx so his game announces the new revision.
param(
    [string]$Config = (Join-Path $env:LOCALAPPDATA 'PeakPack-publisher\publish.json'),
    [string]$Notes,
    [string]$Work = (Join-Path $env:LOCALAPPDATA 'PeakPack-publisher'),
    [string]$Stamp,
    [switch]$DryRun,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
if (-not (Test-Path $Config)) { throw "No publish.json at $Config (start from examples\first-pack.publish.json)" }
if (-not $SkipBuild) {
    & $dn publish (Join-Path $root 'src\PeakPack.App') -c Release -o (Join-Path $root 'publish-out') -v q --nologo
    if ($LASTEXITCODE -ne 0) { throw 'app publish failed' }
    & $dn build (Join-Path $root 'src\PeakPack.Companion') -c Release -v q --nologo
    if ($LASTEXITCODE -ne 0) { throw 'companion build failed (is PEAK installed?)' }
    & $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo
    if ($LASTEXITCODE -ne 0) { throw 'CLI build failed' }
}
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
$cliArgs = @('release', '--config', $Config, '--work', $Work)
if ($Notes) { $cliArgs += @('--notes', $Notes) }
if ($DryRun) { $cliArgs += '--dry-run' }
if ($Stamp) { $cliArgs += @('--stamp', $Stamp) }
& $cli @cliArgs
exit $LASTEXITCODE
