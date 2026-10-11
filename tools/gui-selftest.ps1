# Drives the real GUI (PeakPack.exe --selftest) against the sandbox: Install -> Play Modded -> Play normal,
# saving a screenshot after each step to sandbox\shots. Run sandbox-test.ps1 first (it publishes sandbox\published).
# -Published uses the single-file Release exe from publish-out\ (needed for shortcut-launch-test.ps1, because the
# app copies itself into the data folder and only a single-file exe works on its own).
param([switch]$Published)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = "C:\Program Files\dotnet\dotnet.exe"
& $dn build (Join-Path $root 'src\PeakPack.App') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'BUILD FAILED'; exit 1 }
$app = Join-Path $root 'src\PeakPack.App\bin\Debug\net10.0-windows\PeakPack.exe'
if ($Published) {
    & $dn publish (Join-Path $root 'src\PeakPack.App') -c Release -o (Join-Path $root 'publish-out') -v q --nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'PUBLISH FAILED'; exit 1 }
    $app = Join-Path $root 'publish-out\PeakPack.exe'
}
$sb = Join-Path $root 'sandbox'
foreach ($d in 'data-gui', 'shots', 'shortcuts-gui') { $p = Join-Path $sb $d; if (Test-Path $p) { Remove-Item -Recurse -Force $p } }
$log = Join-Path $sb 'PEAK\launch-log.txt'; if (Test-Path $log) { Remove-Item $log }

$argList = @('--selftest', "$sb\shots", '--game-dir', "$sb\PEAK", '--data-dir', "$sb\data-gui",
             '--manifest', "$sb\published\manifest.json", '--allow-local',
             '--shortcut-dir', "$sb\shortcuts-gui", '--launch-method', 'direct')
$proc = Start-Process $app -ArgumentList $argList -PassThru
if (-not $proc.WaitForExit(120000)) { Write-Host 'TIMEOUT (a dialog is probably open off-screen)'; $proc.Kill(); exit 1 }
Start-Sleep -Seconds 2
Write-Host "Screenshots:"; Get-ChildItem "$sb\shots" -Filter *.png | ForEach-Object { "  " + $_.FullName }
Write-Host "Final status text:"; Get-Content "$sb\shots\status.txt"
Write-Host "Fake PEAK.exe saw:"; Get-Content $log
Write-Host "Shortcuts created:"
Get-ChildItem "$sb\shortcuts-gui" -Recurse -Filter *.lnk | ForEach-Object { "  " + $_.FullName }
