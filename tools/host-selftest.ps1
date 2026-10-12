# Drives the Host / Publisher window (PeakPack.exe --host-selftest) against the sandbox at 100%, 125% and 150%:
# screenshots of every tab and dialog, then "Check what friends will get", a forced test-run Publish (gh dry run)
# and a dry "Play as a friend" sync. Never uploads, never launches PEAK, never touches the real game folder.
# Also (v0.4): a hotfix test run for the sandbox HeliPilot build and a "request logs" command into sandbox\host\game\BepInEx.
# Output: sandbox\host\shots\<100|125|150>\*.png and status.txt. Thunderstore downloads are cached in sandbox\host\work.
param([double[]]$Scales = @(1.0, 1.25, 1.5))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = "C:\Program Files\dotnet\dotnet.exe"
& $dn build (Join-Path $root 'src\PeakPack.App') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'BUILD FAILED'; exit 1 }
$app = Join-Path $root 'src\PeakPack.App\bin\Debug\net10.0-windows\PeakPack.exe'

$sb = Join-Path $root 'sandbox'
$hostDir = Join-Path $sb 'host'
$work = Join-Path $hostDir 'work'
$shots = Join-Path $hostDir 'shots'
New-Item -ItemType Directory -Force $work | Out-Null
if (Test-Path $shots) { Remove-Item -Recurse -Force $shots }

# Sandbox config = the publisher sandbox config + what a real publish needs. "xTestUnknownField" checks that the
# window keeps fields it doesn't show when it saves.
$cfg = Get-Content (Join-Path $sb 'publisher\publish.json') -Raw | ConvertFrom-Json
$cfg | Add-Member -Force NoteProperty githubRepo 'jmproulx/peakpack'
$cfg | Add-Member -Force NoteProperty signingKey (Join-Path $sb 'publisher\test-signing-key.pem')
$cfg | Add-Member -Force NoteProperty app ([pscustomobject]@{ version = ''; source = $app })
$cfg | Add-Member -Force NoteProperty notes 'Sandbox host test'
$cfg | Add-Member -Force NoteProperty xTestUnknownField 'kept'
# v0.4: a sandbox "own game" with a BepInEx folder (host BepInEx for lobby commands), test lobby on, HeliPilot reload-safe.
$game = Join-Path $hostDir 'game'
if (-not (Test-Path (Join-Path $game 'PEAK.exe'))) { Copy-Item (Join-Path $sb 'PEAK') $game -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $game 'BepInEx\plugins') | Out-Null
$commands = Join-Path $game 'BepInEx\PeakPack\commands'
if (Test-Path $commands) { Remove-Item -Recurse -Force $commands }
$cfg | Add-Member -Force NoteProperty gameDir $game
$cfg | Add-Member -Force NoteProperty lobby ([pscustomobject]@{ mismatchPolicy = 'warn'; testLobby = $true; diagnostics = $true })
($cfg.customFiles | Where-Object { $_.dest -like '*.dll' } | Select-Object -First 1) | Add-Member -Force NoteProperty reloadSafe $true
$config = Join-Path $hostDir 'publish.json'
$cfg | ConvertTo-Json -Depth 10 | Set-Content $config -Encoding utf8

# Thunderstore index from the publisher sandbox, marked fresh so the window doesn't download it again.
$index = Join-Path $work 'peak-index.json'
Copy-Item (Join-Path $sb 'publisher\peak-index.json') $index -Force
(Get-Item $index).LastWriteTime = Get-Date
# No live repo yet: a non-existent previous manifest = first publish, and no request to GitHub.
$previous = Join-Path $work 'no-previous-manifest.json'

$failed = $false
foreach ($s in $Scales) {
    $pct = [int][Math]::Round($s * 100)
    $out = Join-Path $shots $pct
    $scale = $s.ToString([Globalization.CultureInfo]::InvariantCulture)
    Write-Host "=== $pct% ==="
    $argList = @('--host-selftest', "`"$out`"", '--host-config', "`"$config`"", '--work', "`"$work`"", '--previous', "`"$previous`"", '--ui-scale', $scale)
    $proc = Start-Process $app -ArgumentList $argList -PassThru
    if (-not $proc.WaitForExit(600000)) { Write-Host 'TIMEOUT (a dialog is probably open off-screen)'; $proc.Kill(); $failed = $true; continue }
    $status = Join-Path $out 'status.txt'
    if (-not (Test-Path $status)) { Write-Host 'NO status.txt'; $failed = $true; continue }
    Get-ChildItem $out -Filter *.png | ForEach-Object { "  " + $_.FullName }
    $lines = Get-Content $status
    if ($pct -eq 100) { $lines | Select-Object -First 70 } else { $lines | Select-Object -First 3 }
    if ($pct -ne 100) { $lines | Where-Object { $_ -like 'Hotfix test run:*' -or $_ -like 'Request logs:*' } | ForEach-Object { '  ' + $_ } }
    if ($lines -match 'SELF-TEST EXCEPTION') { $failed = $true }
    $saved = Join-Path $out 'saved-publish.json'
    if ((Test-Path $saved) -and ((Get-Content $saved -Raw) -match '"xTestUnknownField"')) { Write-Host '  saved publish.json keeps unknown fields: OK' }
    else { Write-Host '  saved publish.json LOST unknown fields'; $failed = $true }
}
if ($failed) { Write-Host 'HOST SELF-TEST FAILED'; exit 1 }
Write-Host 'HOST SELF-TEST OK'
