# Drives the real GUI (PeakPack.exe --selftest / --selftest-open) against the sandbox at each UI scale
# (default 100/125/150 %). Per scale: Install -> Play Modded -> Play normal (screenshots in sandbox\shots\<pct>),
# a "later open" with a missing manifest (error state), and after a new pack revision is published, an
# "update available" open. Run sandbox-test.ps1 first (it publishes sandbox\published and writes
# sandbox\publisher\test-public-key.txt).
# -Published uses the single-file Release exe from publish-out\ (needed for the shortcut checks, because the
# app copies itself into the data folder and only a single-file exe works on its own).
# -Scales sets the UI scales to run. Exit code = number of failed checks.
param([switch]$Published, [string[]]$Scales = @('1.0', '1.25', '1.5'))
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = "C:\Program Files\dotnet\dotnet.exe"
$sb = Join-Path $root 'sandbox'
$game = Join-Path $sb 'PEAK'
$manifest = Join-Path $sb 'published\manifest.json'
$pubFile = Join-Path $sb 'publisher\test-public-key.txt'
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
$timeoutMs = 180000
$fails = 0

function Check($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fails++ }
}
function Quote-Arg([string]$a) { if ($a -match '\s') { '"' + $a + '"' } else { $a } }
# Starts the app with an exact command line and waits. Returns the exit code, or $null after a timeout (killed).
function Start-App([string[]]$argv) {
    $line = ($argv | ForEach-Object { Quote-Arg $_ }) -join ' '
    $p = Start-Process -FilePath $app -ArgumentList $line -PassThru
    if (-not $p.WaitForExit($timeoutMs)) { $p.Kill(); return $null }
    return $p.ExitCode
}
function Invoke-Cli([string[]]$argv) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & $cli @argv 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
}
function Common-Args($n, $sc, $manifestPath) {
    @('--game-dir', $game, '--data-dir', (Join-Path $sb "data-gui-$n"), '--manifest', $manifestPath, '--allow-local',
      '--public-key', $pub, '--shortcut-dir', (Join-Path $sb "shortcuts-gui-$n"), '--launch-method', 'direct', '--ui-scale', $sc)
}

if (-not (Test-Path $manifest) -or -not (Test-Path $pubFile) -or -not (Test-Path $cli)) {
    Write-Host 'Run tools\sandbox-test.ps1 first'; exit 1
}
$pub = (Get-Content -LiteralPath $pubFile -Raw).Trim()

Write-Host "== build"
& $dn build (Join-Path $root 'src\PeakPack.App') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'BUILD FAILED'; exit 1 }
$app = Join-Path $root 'src\PeakPack.App\bin\Debug\net10.0-windows\PeakPack.exe'
if ($Published) {
    & $dn publish (Join-Path $root 'src\PeakPack.App') -c Release -o (Join-Path $root 'publish-out') -v q --nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host 'PUBLISH FAILED'; exit 1 }
    $app = Join-Path $root 'publish-out\PeakPack.exe'
}

$logPath = Join-Path $game 'launch-log.txt'
foreach ($sc in $Scales) {
    $n = [int]([double]$sc * 100)
    $dataDir = Join-Path $sb "data-gui-$n"
    $scDir = Join-Path $sb "shortcuts-gui-$n"
    $shots = Join-Path $sb "shots\$n"
    Write-Host "`n== UI scale $sc (folder $n)"

    foreach ($p in $dataDir, $scDir, $shots) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
    # Each run starts from vanilla: no launch log, no proxy/doorstop files left by an earlier run.
    Remove-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $game 'winhttp.dll'), (Join-Path $game 'doorstop_config.ini') -ErrorAction SilentlyContinue

    Write-Host "  1) first run: install, Play with mods, Play normal"
    $code = Start-App (@('--selftest', $shots) + (Common-Args $n $sc $manifest))
    if ($null -eq $code) { Write-Host "  TIMEOUT: first run still open after 180 s (killed)"; $fails++; continue }
    Write-Host "     exit code $code"

    if ($n -eq 100) {
        Write-Host "  checks (scale 1.0, first run)"
        $exe = Join-Path $dataDir 'PeakPack.exe'
        if ($Published) {
            $desk = Join-Path $scDir 'Desktop\PEAK (Modded).lnk'
            $startMenu = Join-Path $scDir 'StartMenu'
            Check (Test-Path -LiteralPath $desk) 'desktop shortcut "PEAK (Modded).lnk" created'
            Check (Test-Path -LiteralPath (Join-Path $startMenu 'PeakPack.lnk')) 'Start Menu "PeakPack.lnk" created'
            Check (Test-Path -LiteralPath (Join-Path $startMenu 'PEAK (Modded).lnk')) 'Start Menu "PEAK (Modded).lnk" created'
            if (Test-Path -LiteralPath $desk) {
                $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($desk)
                Check ($lnk.TargetPath -eq $exe) "desktop shortcut target is the installed copy ($exe)"
                Check ($lnk.Arguments -like '--launch*') 'desktop shortcut arguments start with --launch'
            }
            $hasExe = Test-Path -LiteralPath $exe
            Check $hasExe 'installed copy exists in the data folder'
            $zone = if ($hasExe) { Get-Item -LiteralPath $exe -Stream Zone.Identifier -ErrorAction SilentlyContinue } else { $null }
            Check (-not $zone) 'installed copy has no Mark-of-the-Web (Zone.Identifier)'
        } else {
            Write-Host "  SKIP shortcut checks (Debug build does not self-install)"
        }

        $logLines = if (Test-Path -LiteralPath $logPath) { @(Get-Content -LiteralPath $logPath) } else { @() }
        $iOn = -1; $iOff = -1
        for ($i = 0; $i -lt $logLines.Count; $i++) {
            if ($iOn -lt 0 -and $logLines[$i] -like '*--doorstop-enabled | true*') { $iOn = $i }
            elseif ($iOn -ge 0 -and $iOff -lt 0 -and $logLines[$i] -like '*--doorstop-enabled | false*') { $iOff = $i }
        }
        Check ($iOn -ge 0) 'launch-log: Play with mods started PEAK with --doorstop-enabled | true'
        Check ($iOff -gt $iOn) 'launch-log: a later Play normal started PEAK with --doorstop-enabled | false'

        $st = Join-Path $shots '3-ready.txt'
        Check ((Test-Path -LiteralPath $st) -and ((Get-Content -LiteralPath $st -Raw) -match 'Ready to play')) '3-ready.txt says "Ready to play"'
    }

    Write-Host "  2) later open with a missing manifest (error state)"
    $code = Start-App (@('--selftest-open', $shots, '5-error') + (Common-Args $n $sc (Join-Path $sb 'published\does-not-exist.json')))
    if ($null -eq $code) { Write-Host "  TIMEOUT: error-state open still open after 180 s (killed)"; $fails++; continue }

    $expected = '1-welcome.png', '2-done.png', '3-ready.png', '4-after-play-modded.png', 'status.txt', '5-error.png', '5-error.txt'
    $missing = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $shots $_)) })
    Check ($missing.Count -eq 0) "scale ${sc}: first run and error-state files written$(if ($missing) { ' (missing: ' + ($missing -join ', ') + ')' })"
    $e = Join-Path $shots '5-error.txt'
    Check ((Test-Path -LiteralPath $e) -and ((Get-Content -LiteralPath $e -Raw) -match 'status=Bad')) "scale ${sc}: missing manifest shows status=Bad"
}

Write-Host "`n== update available: publish a new pack revision, then open each scale"
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
[IO.File]::WriteAllBytes((Join-Path $sb 'custom\HeliPilot.dll'), [Text.Encoding]::ASCII.GetBytes("FAKE HELIPILOT v-gui-$stamp"))
$pubOut = @(Invoke-Cli @('publish', '--config', (Join-Path $sb 'publisher\publish.json'), '--out', (Join-Path $sb 'published'), '--work', (Join-Path $sb 'publisher')))
$pubOut | Where-Object { $_ -match 'Published revision|^\s+[+-] ' }
Check (($pubOut -join "`n") -match 'Published revision') 'publisher wrote a new revision'

foreach ($sc in $Scales) {
    $n = [int]([double]$sc * 100)
    $shots = Join-Path $sb "shots\$n"
    Write-Host "  scale $sc (folder $n)"
    if (-not (Test-Path -LiteralPath (Join-Path $sb "data-gui-$n"))) { Write-Host "  no installed data folder from the first run; skipped"; $fails++; continue }
    $code = Start-App (@('--selftest-open', $shots, '6-update-available') + (Common-Args $n $sc $manifest))
    if ($null -eq $code) { Write-Host "  TIMEOUT: update-available open still open after 180 s (killed)"; $fails++; continue }
    $u = Join-Path $shots '6-update-available.txt'
    Check ((Test-Path -LiteralPath $u) -and ((Get-Content -LiteralPath $u -Raw) -match 'Update available')) "scale ${sc}: update-available state shown"
    Check (Test-Path -LiteralPath (Join-Path $shots '6-update-available.png')) "scale ${sc}: 6-update-available.png written"
}

Write-Host "`n== output"
foreach ($sc in $Scales) {
    $n = [int]([double]$sc * 100)
    $shots = Join-Path $sb "shots\$n"
    Write-Host "PNGs in $shots :"
    Get-ChildItem -LiteralPath $shots -Filter *.png -ErrorAction SilentlyContinue | ForEach-Object { '  ' + $_.FullName }
    foreach ($t in @(Get-ChildItem -LiteralPath $shots -Filter *.txt -ErrorAction SilentlyContinue)) {
        Write-Host "$($t.Name) (first 3 lines):"
        Get-Content -LiteralPath $t.FullName -TotalCount 3 | ForEach-Object { '  ' + $_ }
    }
}

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green } else { Write-Host "$fails CHECK(S) FAILED" -ForegroundColor Red }
exit $fails
