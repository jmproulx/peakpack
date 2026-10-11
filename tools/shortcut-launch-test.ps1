# Simulates the friend double-clicking the "PEAK (Modded)" desktop shortcut created by gui-selftest.ps1:
# reads the .lnk, runs exactly its target + arguments, and checks the fake PEAK.exe got the modded args.
# Also tests a pack update arriving between launches (republish revision N+1, then launch again).
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sb = Join-Path $root 'sandbox'
$lnkPath = Join-Path $sb 'shortcuts-gui\Desktop\PEAK (Modded).lnk'
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut($lnkPath)
Write-Host "Shortcut target : $($lnk.TargetPath)"
Write-Host "Shortcut args   : $($lnk.Arguments)"
Write-Host "Shortcut icon   : $($lnk.IconLocation)"
$log = Join-Path $sb 'PEAK\launch-log.txt'; if (Test-Path $log) { Remove-Item $log }

function Run-Shortcut {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $lnk.WorkingDirectory -PassThru
    if (-not $p.WaitForExit(120000)) { Write-Host 'TIMEOUT'; $p.Kill(); exit 1 }
    Write-Host ("  PeakPack exited with {0} after {1:n1}s" -f $p.ExitCode, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 1
}

Write-Host "`n== launch 1 (up to date: should show no window, just start the game)"
Run-Shortcut
Get-Content $log

Write-Host "`n== host publishes an update (HeliPilot v0.3), friend double-clicks again"
$custom = Join-Path $sb 'custom'
[IO.File]::WriteAllBytes((Join-Path $custom 'HeliPilot.dll'), [Text.Encoding]::ASCII.GetBytes('FAKE HELIPILOT v0.3'))
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
& $cli publish --config (Join-Path $sb 'publisher\publish.json') --out (Join-Path $sb 'published') --work (Join-Path $sb 'publisher') | Select-String 'Published revision|^\s+[+-] '
Run-Shortcut
Get-Content $log
$heli = Get-Content (Join-Path $sb 'data-gui\profile\BepInEx\plugins\Joshua-HeliPilot\HeliPilot.dll') -Raw
Write-Host "Installed HeliPilot now: $heli"
Get-Content (Join-Path $sb 'data-gui\log.txt') | Select-Object -Last 4
