# Windows compatibility of the optional signed Mac pins + gameDepot (manifest v0.6 fields), tested against the
# friend app EXACTLY as shipped in rev-5 (PeakPack 0.4.2), not a rebuild:
#   1  the exe under test is byte-identical to the one the rev-5 manifest advertises (app.sha256)
#   2  the rev-5 manifest + platforms.mac.runtime + platforms.mac.frontEnd + gameDepot, signed with a throwaway key:
#      headless --status (Windows, simulated Mac) reads it like the unmodified manifest: same state, revision 5
#   3  negative controls: the same file with schema 99 fails (so the parse path really ran), and a wrong key fails
#   4  headless --sync (Windows, simulated Mac) installs revision 5 from it into a sandbox profile + sandbox game copy
#      (downloads the rev-5 assets from GitHub/Thunderstore, exactly like a friend), then --status = "Ready to play"
# Touches only sandbox\pins-compat. Never Joshua's game folder, never his signing key, never a release.
# Ends with "ALL PIN COMPAT CHECKS PASSED" or "N PIN COMPAT CHECK(S) FAILED"; exit code = failures.
param(
    [string]$Rev5 = (Join-Path $env:LOCALAPPDATA 'PeakPack-publisher\history\rev-5'),
    [switch]$SkipSync
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
$sb = Join-Path $root 'sandbox'
$T = Join-Path $sb 'pins-compat'
$script:fails = 0; $script:passes = 0
function Check($cond, $msg) {
    if ($cond) { $script:passes++; Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { $script:fails++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
}
function Q([string]$s) { if ($s -match '\s') { '"' + $s + '"' } else { $s } }
function Run-Old([string[]]$argv, [switch]$Mac) {
    if ($Mac) { $env:PEAKPACK_FAKE_PLATFORM = 'wine-mac' }
    try {
        $p = Start-Process -FilePath $script:exe -ArgumentList ($argv | ForEach-Object { Q $_ }) -Wait -PassThru -WindowStyle Hidden
        return [int]$p.ExitCode
    } finally { Remove-Item Env:PEAKPACK_FAKE_PLATFORM -ErrorAction SilentlyContinue }
}
function Json([string]$f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }

if (-not (Test-Path -LiteralPath (Join-Path $sb 'PEAK\PEAK.exe'))) { Write-Host 'sandbox\PEAK missing: run tools\sandbox-test.ps1 first.'; exit 1 }
Remove-Item -LiteralPath $T -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $T | Out-Null

Write-Host '== 1: the shipped rev-5 friend app'
$rev5Manifest = Join-Path $Rev5 'manifest.json'
$m5 = Json $rev5Manifest
$src = Join-Path $Rev5 'PeakPack.exe'
$sha = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLower()
Check ($m5.revision -eq 5 -and $m5.app.version -eq '0.4.2') "rev-5 manifest advertises app $($m5.app.version)"
Check ($sha -eq $m5.app.sha256) "PeakPack.exe under test = rev-5 app.sha256 ($($sha.Substring(0,12))...)"
Check ($null -eq $m5.gameDepot -and $null -eq $m5.platforms.mac.runtime) 'the real rev-5 manifest has none of the new fields (baseline)'
$script:exe = Join-Path $T 'PeakPack-0.4.2.exe'
Copy-Item -LiteralPath $src -Destination $script:exe

Write-Host '== fixtures (throwaway keys; never the real signing key)'
& $dn build (Join-Path $root 'tools\ManifestPinsTests') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'ManifestPinsTests build failed'; exit 1 }
$fx = Join-Path $root 'tools\ManifestPinsTests\bin\Debug\net10.0-windows\ManifestPinsTests.exe'
$F = @{ base = (Join-Path $T 'fx-base'); pins = (Join-Path $T 'fx-pins'); bad = (Join-Path $T 'fx-bad') }
& $fx compat-fixture $rev5Manifest $F.base --no-fields
& $fx compat-fixture $rev5Manifest $F.pins
& $fx compat-fixture $rev5Manifest $F.bad --bad-schema
$mp = Json (Join-Path $F.pins 'manifest.json')
Check ($mp.platforms.mac.runtime.id -eq 'pp2-cx26.3.0' -and $mp.platforms.mac.frontEnd.version -eq '0.2.0' -and $mp.gameDepot.manifestId -and $mp.revision -eq 5 -and @($mp.platforms.mac.files).Count -eq @($m5.platforms.mac.files).Count) 'fixture = rev-5 manifest + the three fields'
$pub = @{}; foreach ($k in $F.Keys) { $pub[$k] = (Get-Content -LiteralPath (Join-Path $F[$k] 'public-key.txt') -Raw).Trim() }

function Status([string]$name, [string]$fixture, [string]$key, [switch]$Mac, [string]$gameDir = (Join-Path $sb 'PEAK')) {
    $data = Join-Path $T "data-$name"; $out = Join-Path $T "status-$name.json"
    $argv = @('--headless', '--status', '--data-dir', $data, '--game-dir', $gameDir, '--manifest', (Join-Path $fixture 'manifest.json'), '--allow-local', '--public-key', $key, '--status-out', $out)
    $rc = Run-Old $argv -Mac:$Mac
    $s = if (Test-Path -LiteralPath $out) { Json $out } else { $null }
    return @{ rc = $rc; s = $s }
}

Write-Host '== 2: headless --status reads the manifest with the new fields'
foreach ($mac in $false, $true) {
    $tag = if ($mac) { 'mac' } else { 'win' }
    $b = Status "base-$tag" $F.base $pub.base -Mac:$mac
    $p = Status "pins-$tag" $F.pins $pub.pins -Mac:$mac
    Check ($p.s -and $p.s.state -ne 'failed' -and $p.s.latestRevision -eq 5) "${tag}: with the new fields: exit $($p.rc), state '$($p.s.state)', '$($p.s.message)', latestRevision $($p.s.latestRevision)"
    Check ($p.rc -eq $b.rc -and $p.s.state -eq $b.s.state -and $p.s.message -eq $b.s.message -and $p.s.latestRevision -eq $b.s.latestRevision) "${tag}: identical to the unmodified rev-5 manifest (exit $($b.rc), '$($b.s.message)')"
}

Write-Host '== 3: negative controls'
$n1 = Status 'bad-schema' $F.bad $pub.bad
Check ($n1.rc -eq 1 -and $n1.s.state -eq 'failed') "schema 99 + new fields -> exit 1 / failed (the old parser really ran; '$($n1.s.problem.heading)')"
$n2 = Status 'wrong-key' $F.pins $pub.base
Check ($n2.rc -eq 1 -and $n2.s.state -eq 'failed') "wrong key -> exit 1 / failed (the signature really was checked; '$($n2.s.problem.heading)')"

if (-not $SkipSync) {
    Write-Host '== 4: headless --sync installs revision 5 from it (sandbox game copies)'
    foreach ($mac in $false, $true) {
        $tag = if ($mac) { 'mac' } else { 'win' }
        $g = Join-Path $T "PEAK-$tag"
        Copy-Item -LiteralPath (Join-Path $sb 'PEAK') -Destination $g -Recurse
        Get-ChildItem -LiteralPath $g -Force | Where-Object { $_.Name -in 'winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'BepInEx', 'launch-log.txt' } | Remove-Item -Recurse -Force
        $data = Join-Path $T "data-sync-$tag"; $out = Join-Path $T "sync-$tag.json"
        $rc = Run-Old @('--headless', '--sync', '--data-dir', $data, '--game-dir', $g, '--manifest', (Join-Path $F.pins 'manifest.json'), '--allow-local', '--public-key', $pub.pins, '--status-out', $out) -Mac:$mac
        $s = Json $out
        Check ($rc -eq 0 -and $s.state -eq 'done' -and $s.installedRevision -eq 5) "${tag}: sync exit $rc, state '$($s.state)', installedRevision $($s.installedRevision) $(if ($s.problem) { '/ ' + $s.problem.heading + ' / ' + $s.problem.details })"
        $prof = Join-Path $data 'profile\BepInEx'
        $heli = Join-Path $prof 'plugins\Joshua-HeliPilot\HeliPilot.dll'
        $preset = Join-Path $prof 'plugins\PeakPack-MacPreset\PeakPack.MacPreset.dll'
        $heliSha = ($m5.files | Where-Object { $_.path -eq 'plugins/Joshua-HeliPilot/HeliPilot.dll' }).sha256
        Check ((Test-Path -LiteralPath $heli) -and (Get-FileHash -LiteralPath $heli -Algorithm SHA256).Hash.ToLower() -eq $heliSha) "${tag}: HeliPilot.dll installed with the rev-5 SHA-256"
        if ($mac) { Check (Test-Path -LiteralPath $preset) 'mac: Mac preset installed (platforms.mac.files still honoured next to the pins)' }
        else { Check (-not (Test-Path -LiteralPath $preset)) 'win: no Mac-only plugin on Windows' }
        $outS = Join-Path $T "ready-$tag.json"
        $rcS = Run-Old @('--headless', '--status', '--data-dir', $data, '--game-dir', $g, '--manifest', (Join-Path $F.pins 'manifest.json'), '--allow-local', '--public-key', $pub.pins, '--status-out', $outS) -Mac:$mac
        $sS = Json $outS
        Check ($rcS -eq 0 -and $sS.message -eq 'Ready to play' -and $sS.installedRevision -eq 5) "${tag}: then --status: exit $rcS, '$($sS.message)'"
    }
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host "ALL $($script:passes) PIN COMPAT CHECKS PASSED" -ForegroundColor Green }
else { Write-Host "$($script:fails) PIN COMPAT CHECK(S) FAILED ($($script:passes) passed)" -ForegroundColor Red }
exit $script:fails
