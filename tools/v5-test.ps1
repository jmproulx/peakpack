# v5: end-to-end tests for PeakPack v0.5, against sandbox\v5 only (copies of sandbox\PEAK and a private publisher work dir).
#   A  publish: Mac extra args + Mac config defaults (ifMissing, config/ only), bundle path, asset files
#   B  Windows friend (CLI install): Windows config, no Mac-only config, bundle copied intact, no Mac launch args
#   C  Mac friend (headless sync, simulated Wine): Mac replaces the Windows config, Mac-only config, -force-d3d11 saved
#   D  ifMissing: a friend's edit survives a new revision with a changed Mac default
#   E  Mac headless launch (simulated Wine): doorstop flags, extra args, no registry write
#   F  Windows headless launch: no Mac args, no Wine simulation
#   G  headless status: "Ready to play", and a missing manifest -> exit 1 with a plain-language heading
#   H  shortcuts: none under Wine; the Windows selfinstall creates the PEAK (Modded) shortcut
#   I  live update of a changed JetpackBoost.dll: applied; the hot-update result lists the plugin
#   J  a failure mid-replace is undone (HeliPilot locked for writing); J2: fully locked file fails before any change
#   K  a bundle-only change is restart-only and the bundle on disk is untouched
#   L  manifest validation refuses a bad Mac launch argument and a Mac config outside config/
#   M  release dry run: a local revision above the live one is used, so rev-10 is planned (never reuses a number)
# Ends with "ALL V5 CHECKS PASSED" or "N V5 CHECK(S) FAILED"; exit code = number of failures.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
$sb = Join-Path $root 'sandbox'
$v5 = Join-Path $sb 'v5'
$script:fails = 0
$script:passes = 0

function Check($cond, $msg) {
    if ($cond) { $script:passes++; Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { $script:fails++; Write-Host "  FAIL  $msg" -ForegroundColor Red }
}
function Step([string]$name, [scriptblock]$body) {
    Write-Host "== $name"
    try { & $body }
    catch { $script:fails++; Write-Host "  FAIL  $name threw: $($_.Exception.Message)" -ForegroundColor Red }
}
function PP { $ErrorActionPreference = 'Continue'; & $script:cli @args 2>&1 | ForEach-Object { "$_" } }
function PPMac {
    $env:PEAKPACK_FAKE_PLATFORM = 'wine-mac'
    try { PP @args } finally { Remove-Item Env:PEAKPACK_FAKE_PLATFORM -ErrorAction SilentlyContinue }
}
function Q([string]$s) { if ($s -match '\s') { '"' + $s + '"' } else { $s } }
function Invoke-PeakApp([string[]]$argv, [switch]$Mac) {
    if ($Mac) { $env:PEAKPACK_FAKE_PLATFORM = 'wine-mac' }
    try {
        $p = Start-Process -FilePath $script:appExe -ArgumentList ($argv | ForEach-Object { Q $_ }) -Wait -PassThru -WindowStyle Hidden
        return [int]$p.ExitCode
    } finally { Remove-Item Env:PEAKPACK_FAKE_PLATFORM -ErrorAction SilentlyContinue }
}
function Sha([string]$f) { if (Test-Path -LiteralPath $f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() } else { '' } }
function Json([string]$f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }
function ReadText([string]$f) { if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllText($f) } else { $null } }
function WriteText([string]$f, [string]$t) {
    $d = Split-Path -Parent $f
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [IO.File]::WriteAllText($f, $t, (New-Object Text.UTF8Encoding($false)))
}
function Build-Variant([string]$src, [string]$dst, [string]$tag) {
    # A "new build": same plugin bytes plus a trailing marker (still a valid PE; different SHA-256).
    $bytes = [IO.File]::ReadAllBytes($src) + [Text.Encoding]::ASCII.GetBytes("BUILD:$tag")
    [IO.File]::WriteAllBytes($dst, $bytes)
}
function Wait-Lines([string]$file, [int]$before, [int]$seconds = 20) {
    $end = (Get-Date).AddSeconds($seconds)
    do {
        if (Test-Path -LiteralPath $file) { $n = @(Get-Content -LiteralPath $file).Count; if ($n -gt $before) { return $n } }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $end)
    return $before
}
function LogHas([string]$file, [string]$text) {
    (Test-Path -LiteralPath $file) -and [bool](Select-String -LiteralPath $file -SimpleMatch -Pattern $text -Quiet)
}
function Wait-Others {
    # Another agent runs other suites (tools\*-test.ps1, gui-selftest, host-selftest). Don't build or run over them.
    $pattern = 'tools\\[^\s"]*-test\.ps1|selftest'
    $deadline = (Get-Date).AddMinutes(45)
    while ($true) {
        $busy = @(Get-CimInstance Win32_Process | Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -and ($_.CommandLine -match $pattern) -and ($_.CommandLine -notmatch 'v5-test')
        })
        if ($busy.Count -eq 0) { return }
        if ((Get-Date) -gt $deadline) { throw 'other test suites still running after 45 minutes' }
        Write-Host ("  waiting: {0} other test process(es) running: {1}" -f $busy.Count, (($busy | ForEach-Object { $_.ProcessId }) -join ', '))
        Start-Sleep -Seconds 20
    }
}

# ---- paths (no spaces anywhere, so the command lines stay simple) ----
$jbReal = 'C:\Users\joshu\PeakMods\JetpackBoost\bin\Release\JetpackBoost.dll'
$G1 = Join-Path $v5 'PEAK'              # Windows game folder (copy of sandbox\PEAK)
$G2 = Join-Path $v5 'PEAK-mac'          # Mac game folder (separate copy)
$W = Join-Path $v5 'data-windows'       # Windows friend's data folder
$M = Join-Path $v5 'data-mac'           # Mac friend's data folder
$D3 = Join-Path $v5 'data-selfinstall-mac'; $S3 = Join-Path $v5 'shortcuts-mac'
$D4 = Join-Path $v5 'data-selfinstall-win'; $S4 = Join-Path $v5 'shortcuts-win'
$work = Join-Path $v5 'work'; $index = Join-Path $work 'peak-index.json'
$workLatest = Join-Path $v5 'work-latest'
$out = Join-Path $v5 'published'; $manifest = Join-Path $out 'manifest.json'
$custom = Join-Path $v5 'custom'
$key = Join-Path $v5 'test-key.pem'
$cfgFile = Join-Path $v5 'publish.json'
$jb = Join-Path $custom 'JetpackBoost.dll'; $hp = Join-Path $custom 'HeliPilot.dll'
$bundle = Join-Path $custom 'HeliPilot_cockpit.bundle'
$itWin = Join-Path $custom 'itemtuner-windows.cfg'
$macJb = Join-Path $custom 'mac-jetpackboost.cfg'; $macIt = Join-Path $custom 'mac-itemtuner.cfg'
$wProfile = Join-Path $W 'profile\BepInEx'; $mProfile = Join-Path $M 'profile\BepInEx'
$jbW = Join-Path $wProfile 'plugins\Joshua-JetpackBoost\JetpackBoost.dll'
$hpW = Join-Path $wProfile 'plugins\Joshua-HeliPilot\HeliPilot.dll'
$bundleW = Join-Path $wProfile 'plugins\Joshua-HeliPilot\HeliPilot_cockpit.bundle'
$itW = Join-Path $wProfile 'config\com.joshua.itemtuner.cfg'
$jbCfgW = Join-Path $wProfile 'config\com.joshua.jetpackboost.cfg'
$itM = Join-Path $mProfile 'config\com.joshua.itemtuner.cfg'
$jbCfgM = Join-Path $mProfile 'config\com.joshua.jetpackboost.cfg'
$bundleM = Join-Path $mProfile 'plugins\Joshua-HeliPilot\HeliPilot_cockpit.bundle'
$piW = Join-Path $wProfile 'PeakPack\pack-info.json'
$hotResW = Join-Path $wProfile 'PeakPack\hot-update-result.json'

function New-Cfg([string]$notes) {
    [ordered]@{
        packName = "Joshua's PEAK mods (v5 test)"; hostName = 'Joshua'; notes = $notes
        loader = 'BepInEx-BepInExPack_PEAK'; mods = @('Sapphire009-InfiniteJetpack-1.0.1')
        customFiles = @(
            @{ id = 'Joshua-JetpackBoost'; version = '0.1.0'; title = 'Jetpack Boost'; source = $jb; dest = 'plugins/Joshua-JetpackBoost/JetpackBoost.dll'; reloadSafe = $true },
            @{ id = 'Joshua-HeliPilot'; version = '0.1.0'; title = 'Heli Pilot'; source = $hp; dest = 'plugins/Joshua-HeliPilot/HeliPilot.dll'; reloadSafe = $true },
            @{ id = 'Joshua-HeliPilot'; version = '0.1.0'; title = 'Heli Pilot cockpit'; source = $bundle; dest = 'plugins/Joshua-HeliPilot/HeliPilot_cockpit.bundle' },
            @{ id = 'Joshua-ItemTuner'; version = '1.0.0'; title = 'Item Tuner'; source = $itWin; dest = 'config/com.joshua.itemtuner.cfg'; overwrite = 'ifMissing' }
        )
        lobby = [ordered]@{ testLobby = $true; diagnostics = $true; hostIds = @('host-123') }
        mac = [ordered]@{
            extraArgs = @('-force-d3d11')
            configFiles = @(
                @{ id = 'Joshua-JetpackBoost'; version = '0.1.0'; source = $macJb; dest = 'config/com.joshua.jetpackboost.cfg' },
                @{ id = 'Joshua-ItemTuner'; version = '1.0.0'; source = $macIt; dest = 'config/com.joshua.itemtuner.cfg' }
            )
        }
        signingKey = $key; gameDir = $G1; companion = ''
    }
}
function Pub([string]$notes) {
    WriteText $cfgFile ((New-Cfg $notes) | ConvertTo-Json -Depth 8)
    $o = PP publish --config $cfgFile --out $out --work $work --index $index
    if ($LASTEXITCODE -ne 0) { throw "publish failed: $($o -join ' | ')" }
    return (Json $manifest)
}
function Invoke-HotUpdate([string]$dataDir) {
    # Exactly what the companion starts: the installed app (pack-info appExe) + appArgs + --hot-update.
    $info = Json (Join-Path $dataDir 'profile\BepInEx\PeakPack\pack-info.json')
    $res = Join-Path $dataDir 'profile\BepInEx\PeakPack\hot-update-result.json'
    Remove-Item -LiteralPath $res -ErrorAction SilentlyContinue
    $argv = @($info.appArgs) + @('--hot-update', '--allow-local', '--public-key', $pub)
    $p = Start-Process -FilePath $info.appExe -ArgumentList ($argv | ForEach-Object { Q $_ }) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(60000)) { $p.Kill(); return $null }
    if (Test-Path -LiteralPath $res) { return Json $res } else { return $null }
}

Write-Host '== wait for other test suites'
Wait-Others

Write-Host '== build'
& $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'CLI build failed'; exit 1 }
$script:cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
& $dn publish (Join-Path $root 'src\PeakPack.App') -c Release -o (Join-Path $root 'publish-out') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'app publish failed'; exit 1 }
$script:appExe = Join-Path $root 'publish-out\PeakPack.exe'
if (-not (Test-Path -LiteralPath (Join-Path $sb 'PEAK\PEAK.exe'))) { Write-Host 'sandbox\PEAK missing: run tools\sandbox-test.ps1 first.'; exit 1 }
if (-not (Test-Path -LiteralPath $jbReal)) { Write-Host "real JetpackBoost.dll missing: $jbReal"; exit 1 }

Write-Host '== setup (fresh sandbox\v5)'
Remove-Item -LiteralPath $v5 -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @('custom', 'work', 'work-latest')) { New-Item -ItemType Directory -Force -Path (Join-Path $v5 $d) | Out-Null }
foreach ($g in $G1, $G2) {
    Copy-Item -LiteralPath (Join-Path $sb 'PEAK') -Destination $g -Recurse
    Get-ChildItem -LiteralPath $g -Force | Where-Object { $_.Name -in 'winhttp.dll', 'doorstop_config.ini', '.doorstop_version', 'BepInEx', 'launch-log.txt' } | Remove-Item -Recurse -Force
}
Copy-Item -LiteralPath (Join-Path $sb 'publisher\peak-index.json') -Destination $index
if (Test-Path -LiteralPath (Join-Path $sb 'publisher\cache')) { Copy-Item -LiteralPath (Join-Path $sb 'publisher\cache') -Destination (Join-Path $work 'cache') -Recurse }
$pub = (PP keygen --out $key | Select-Object -Last 1).Trim()
Build-Variant $jbReal $jb 'r1'
Build-Variant $jbReal $hp 'h1'
WriteText $bundle 'BUNDLE-1'
WriteText $itWin 'WINDOWS-CFG'
WriteText $macJb 'MAC-JB'
WriteText $macIt 'MAC-IT'

Step 'A: publish rev 1 (Mac args + Mac config defaults, bundle, asset files)' {
    $m1 = Pub 'v5 rev 1'
    Check ($m1.revision -eq 1) "rev 1 published (got $($m1.revision))"
    $mac = $m1.platforms.mac
    Check (@($mac.extraArgs).Count -eq 1 -and $mac.extraArgs[0] -eq '-force-d3d11') 'A: platforms.mac.extraArgs = -force-d3d11'
    $macFiles = @($mac.files)
    Check ($macFiles.Count -eq 2) "A: platforms.mac.files has 2 entries (got $($macFiles.Count))"
    Check (@($macFiles | Where-Object { $_.overwrite -eq 'ifMissing' }).Count -eq 2) 'A: both Mac files are overwrite ifMissing'
    Check (@($macFiles | Where-Object { $_.path -like 'config/*' }).Count -eq 2) 'A: both Mac files are under config/'
    Check (@($macFiles | Where-Object { Test-Path -LiteralPath (Join-Path $out $_.url) }).Count -eq 2) 'A: the Mac asset files exist in the output folder'
    Check (@($m1.files | Where-Object { $_.path -eq 'plugins/Joshua-HeliPilot/HeliPilot_cockpit.bundle' }).Count -eq 1) 'A: bundle entry path is exactly plugins/Joshua-HeliPilot/HeliPilot_cockpit.bundle'
}

Step 'B: Windows friend, CLI install (no PEAKPACK_FAKE_PLATFORM)' {
    PP selfinstall --exe $script:appExe --data-dir $W --game-dir $G1 | Out-Null
    $o = PP install --manifest $manifest --data-dir $W --game-dir $G1 --allow-local --public-key $pub
    Check (($o -join ' ') -match 'Now on revision 1\.') 'B: installed revision 1'
    Check ((ReadText $itW) -eq 'WINDOWS-CFG') 'B: Windows config is WINDOWS-CFG'
    Check (-not (Test-Path -LiteralPath $jbCfgW)) 'B: the Mac-only jetpackboost config is NOT on Windows'
    Check ((Test-Path -LiteralPath $bundleW) -and (Test-Path -LiteralPath $hpW) -and ((Sha $bundleW) -eq (Sha $bundle))) 'B: HeliPilot_cockpit.bundle sits next to HeliPilot.dll with the same SHA-256'
    $stW = Json (Join-Path $W 'state.json')
    Check (@($stW.launchExtraArgs | Where-Object { $_ }).Count -eq 0) 'B: state.json launchExtraArgs is empty on Windows'
}

Step 'C: Mac friend, headless sync (PEAKPACK_FAKE_PLATFORM=wine-mac)' {
    $stC = Join-Path $v5 'status-c.json'
    $rc = Invoke-PeakApp -Mac @('--headless', '--sync', '--data-dir', $M, '--game-dir', $G2, '--manifest', $manifest, '--allow-local', '--public-key', $pub, '--status-out', $stC)
    Check ($rc -eq 0) "C: headless sync exits 0 (got $rc)"
    $sC = Json $stC
    Check ($sC.state -eq 'done') "C: status state done (got $($sC.state): $($sC.message))"
    Check ($sC.platform -match 'macOS') "C: status platform names macOS ($($sC.platform))"
    Check ((ReadText $itM) -eq 'MAC-IT') 'C: Mac replaced the Windows itemtuner config (MAC-IT)'
    Check ((ReadText $jbCfgM) -eq 'MAC-JB') 'C: Mac jetpackboost config installed (MAC-JB)'
    Check (Test-Path -LiteralPath $bundleM) 'C: bundle present on Mac'
    $stateM = Json (Join-Path $M 'state.json')
    Check (@($stateM.launchExtraArgs) -contains '-force-d3d11') 'C: state.json launchExtraArgs contains -force-d3d11'
}

Step 'D: ifMissing keeps a friend edit when the Mac default changes in a new revision' {
    WriteText $jbCfgM 'FRIEND-EDIT'
    WriteText $macJb 'MAC-JB-2'
    $m2 = Pub 'v5 rev 2 (Mac jetpackboost default changed)'
    $stD = Join-Path $v5 'status-d.json'
    $rc = Invoke-PeakApp -Mac @('--headless', '--sync', '--data-dir', $M, '--game-dir', $G2, '--manifest', $manifest, '--allow-local', '--public-key', $pub, '--status-out', $stD)
    $sD = Json $stD
    Check ($rc -eq 0 -and $sD.installedRevision -eq $m2.revision) "D: sync to revision $($m2.revision) (exit $rc, installedRevision $($sD.installedRevision))"
    Check ((ReadText $jbCfgM) -eq 'FRIEND-EDIT') "D: friend's edit kept (content now '$(ReadText $jbCfgM)')"
}

Step 'E: Mac headless launch, simulated Wine' {
    $log2 = Join-Path $G2 'launch-log.txt'
    Remove-Item -LiteralPath $log2 -ErrorAction SilentlyContinue
    $stE = Join-Path $v5 'status-e-modded.json'
    $rc = Invoke-PeakApp -Mac @('--headless', '--launch', '--launch-method', 'direct', '--data-dir', $M, '--game-dir', $G2, '--manifest', $manifest, '--allow-local', '--public-key', $pub, '--status-out', $stE)
    $n = Wait-Lines $log2 0
    $sE = Json $stE
    Check ($rc -eq 0 -and $sE.launched -eq 'modded') "E: modded launch, status launched=modded (exit $rc, launched $($sE.launched))"
    $lines = @(Get-Content -LiteralPath $log2 -ErrorAction SilentlyContinue)
    $last = if ($lines.Count -gt 0) { $lines[-1] } else { '' }
    Check ($n -ge 1 -and $last -match '--doorstop-enabled \| true' -and $last -match '-force-d3d11') "E: launch-log has --doorstop-enabled | true and -force-d3d11 ($last)"
    Check (LogHas (Join-Path $M 'log.txt') 'would set HKCU\Software\Wine\AppDefaults') 'E: Mac log says the Wine DLL override was simulated'
    Check (-not (Test-Path 'HKCU:\Software\Wine\AppDefaults\PEAK.exe')) 'E: the simulation did not write HKCU\Software\Wine\AppDefaults\PEAK.exe'

    Start-Sleep -Seconds 2
    $before = @(Get-Content -LiteralPath $log2).Count
    $stE2 = Join-Path $v5 'status-e-vanilla.json'
    $rc2 = Invoke-PeakApp -Mac @('--headless', '--launch', '--vanilla', '--launch-method', 'direct', '--data-dir', $M, '--game-dir', $G2, '--allow-local', '--public-key', $pub, '--status-out', $stE2)
    $null = Wait-Lines $log2 $before
    $lines2 = @(Get-Content -LiteralPath $log2)
    $last2 = if ($lines2.Count -gt 0) { $lines2[-1] } else { '' }
    $sE2 = Json $stE2
    Check ($rc2 -eq 0 -and $sE2.launched -eq 'vanilla' -and $last2 -match '--doorstop-enabled \| false') "E: vanilla launch, last log line has --doorstop-enabled | false (exit $rc2)"
}

Step 'F: Windows headless launch (no PEAKPACK_FAKE_PLATFORM)' {
    $log1 = Join-Path $G1 'launch-log.txt'
    Remove-Item -LiteralPath $log1 -ErrorAction SilentlyContinue
    $stF = Join-Path $v5 'status-f.json'
    $rc = Invoke-PeakApp @('--headless', '--launch', '--launch-method', 'direct', '--data-dir', $W, '--game-dir', $G1, '--manifest', $manifest, '--allow-local', '--public-key', $pub, '--status-out', $stF)
    $n = Wait-Lines $log1 0
    $lines = @(Get-Content -LiteralPath $log1 -ErrorAction SilentlyContinue)
    $last = if ($lines.Count -gt 0) { $lines[-1] } else { '' }
    $sF = Json $stF
    Check ($rc -eq 0 -and $sF.launched -eq 'modded' -and $n -ge 1) "F: Windows modded launch (exit $rc, launched $($sF.launched))"
    Check ($last -match '--doorstop-enabled \| true' -and $last -notmatch 'force-d3d11') "F: Windows launch-log has no -force-d3d11 ($last)"
    Check (-not (LogHas (Join-Path $W 'log.txt') 'simulated Wine')) 'F: Windows log has no simulated Wine lines'
}

Step 'G: headless status and errors' {
    $stG = Join-Path $v5 'status-g.json'
    $rc = Invoke-PeakApp -Mac @('--headless', '--status', '--data-dir', $M, '--manifest', $manifest, '--allow-local', '--public-key', $pub, '--status-out', $stG)
    $sG = Json $stG
    Check ($rc -eq 0 -and $sG.message -eq 'Ready to play') "G: --status on the Mac friend says 'Ready to play' (exit $rc, message '$($sG.message)')"
    $stG2 = Join-Path $v5 'status-g-missing.json'
    $rc2 = Invoke-PeakApp @('--headless', '--status', '--data-dir', $M, '--manifest', (Join-Path $v5 'no-such-manifest.json'), '--allow-local', '--public-key', $pub, '--status-out', $stG2)
    $sG2 = Json $stG2
    Check ($rc2 -eq 1 -and $sG2.state -eq 'failed' -and $sG2.problem.heading -eq "The mod list isn't available") "G: missing manifest -> exit 1, state failed, heading (exit $rc2, heading '$($sG2.problem.heading)')"
}

Step 'H: shortcuts (none under Wine; Windows gets PEAK (Modded).lnk)' {
    $null = PPMac selfinstall --exe $script:appExe --data-dir $D3 --shortcut-dir $S3 --game-dir $G2
    $rcMac = $LASTEXITCODE
    $lnkMac = @(Get-ChildItem -LiteralPath $S3 -Recurse -Filter *.lnk -ErrorAction SilentlyContinue)
    Check ($rcMac -eq 0 -and $lnkMac.Count -eq 0) "H: under Wine, selfinstall creates no .lnk shortcut (found $($lnkMac.Count))"
    $null = PP selfinstall --exe $script:appExe --data-dir $D4 --shortcut-dir $S4 --game-dir $G1
    $rcWin = $LASTEXITCODE
    Check ($rcWin -eq 0 -and (Test-Path -LiteralPath (Join-Path $S4 'Desktop\PEAK (Modded).lnk'))) 'H: on Windows, selfinstall creates S4\Desktop\PEAK (Modded).lnk'
}

Step 'I: live update of a changed JetpackBoost.dll' {
    PP options --data-dir $W --live-updates on | Out-Null
    Check ((Json $piW).liveUpdates -eq $true) 'I: friend opted in (pack-info liveUpdates = true)'
    Build-Variant $jbReal $jb 'r3'
    $m3 = Pub 'JetpackBoost tweak (rev 3)'
    $r = Invoke-HotUpdate $W
    Check ($r -and $r.status -eq 'applied') "I: hot update applied ($($r.status): $($r.message))"
    Check ((Sha $jbW) -eq (Sha $jb)) 'I: new JetpackBoost build written in place'
    Check ((Json (Join-Path $W 'state.json')).installedRevision -eq $m3.revision) "I: state at revision $($m3.revision)"
    $pl = @($r.plugins | Where-Object { ($_ -like 'com.joshua.jetpackboost|*') -and ($_ -like '*|plugins/Joshua-JetpackBoost/JetpackBoost.dll') })
    Check ($pl.Count -eq 1) "I: result.plugins lists com.joshua.jetpackboost|version|plugins/Joshua-JetpackBoost/JetpackBoost.dll (got: $($r.plugins -join '; '))"
    Check (Test-Path -LiteralPath (Join-Path $W 'rollback\last.json')) 'I: previous build kept for undo'
}

Step 'J: failed mid-replace is undone (HeliPilot.dll locked against writes)' {
    Build-Variant $jbReal $jb 'r4'
    Build-Variant $jbReal $hp 'h4'
    $m4 = Pub 'JetpackBoost and HeliPilot tweaks (rev 4)'
    $jbShaBefore = Sha $jbW; $hpShaBefore = Sha $hpW
    $revBefore = (Json (Join-Path $W 'state.json')).installedRevision
    # FileShare.Read (not None): the backup read of HeliPilot.dll succeeds, the replace write is refused, so the
    # failure really happens mid-replace (after JetpackBoost.dll was written). FileShare.None would fail at the backup
    # step before anything is written; that case is J2.
    $lock = [IO.File]::Open($hpW, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $r = Invoke-HotUpdate $W } finally { $lock.Dispose() }
    $stJ = Json (Join-Path $W 'state.json')
    Check ($r -and $r.status -eq 'failed' -and $r.message -match 'put back') "J: failed and the earlier builds were put back ($($r.status): $($r.message))"
    Check ((Sha $jbW) -eq $jbShaBefore) 'J: JetpackBoost.dll restored to the pre-update build (SHA-256 unchanged)'
    Check ((Sha $hpW) -eq $hpShaBefore) 'J: HeliPilot.dll unchanged'
    Check ($stJ.installedRevision -eq $revBefore) "J: state installedRevision unchanged ($revBefore)"
    Check (-not (Test-Path -LiteralPath (Join-Path $W 'rollback\last.json'))) 'J: no undo record left behind'
    $tmp = @(Get-ChildItem -LiteralPath (Split-Path -Parent $hpW) -Filter 'HeliPilot.dll.pp-*' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    Write-Host "  NOTE  temp files left in the plugin folder after the failed update: $(if ($tmp.Count) { $tmp -join ', ' } else { 'none' })"
}

Step 'J2: same update with HeliPilot.dll fully locked (FileShare.None)' {
    $jbShaBefore = Sha $jbW; $hpShaBefore = Sha $hpW
    $revBefore = (Json (Join-Path $W 'state.json')).installedRevision
    $lock = [IO.File]::Open($hpW, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { $r = Invoke-HotUpdate $W } finally { $lock.Dispose() }
    Write-Host "  INFO  J2 message: $($r.message)"
    Check ($r -and $r.status -eq 'failed' -and ((Sha $jbW) -eq $jbShaBefore) -and ((Sha $hpW) -eq $hpShaBefore)) 'J2: fully locked file -> failed, nothing replaced'
    Check ((Json (Join-Path $W 'state.json')).installedRevision -eq $revBefore) 'J2: state unchanged'
    # Bring the Windows friend up to date with the normal sync (what a restart from the icon does).
    $o = PP install --manifest $manifest --data-dir $W --game-dir $G1 --allow-local --public-key $pub
    Check (($o -join ' ') -match 'Now on revision \d+\.') 'J2: normal restart-sync brings the friend to the latest revision'
}

Step 'K: bundle-only change is restart-only' {
    $bundleBefore = ReadText $bundleW
    WriteText $bundle 'BUNDLE-2'
    $m5 = Pub 'cockpit bundle only (rev 5)'
    $r = Invoke-HotUpdate $W
    Check ($r -and $r.status -eq 'restart-needed') "K: bundle-only change -> restart-needed (got $($r.status): $($r.message))"
    Check ((ReadText $bundleW) -eq $bundleBefore) "K: bundle on disk unchanged (still '$(ReadText $bundleW)')"
}

Step 'L: manifest validation refuses bad Mac entries' {
    $cfgL1 = New-Cfg 'bad mac launch arg'
    $cfgL1['mac']['extraArgs'] = @('--doorstop-target-assembly', 'x.dll')
    WriteText (Join-Path $v5 'publish-bad-args.json') ($cfgL1 | ConvertTo-Json -Depth 8)
    $oL1 = PP publish --config (Join-Path $v5 'publish-bad-args.json') --out (Join-Path $v5 'bad-args-out') --work $work --index $index
    $rcL1 = $LASTEXITCODE
    Check ($rcL1 -ne 0 -and (($oL1 -join ' ') -match "isn't allowed")) "L: mac extraArgs with --doorstop-... refused (exit $($rcL1): $($oL1 | Select-Object -Last 1))"
    $cfgL2 = New-Cfg 'bad mac config dest'
    $cfgL2['mac']['configFiles'][0]['dest'] = 'plugins/x.dll'
    WriteText (Join-Path $v5 'publish-bad-dest.json') ($cfgL2 | ConvertTo-Json -Depth 8)
    $oL2 = PP publish --config (Join-Path $v5 'publish-bad-dest.json') --out (Join-Path $v5 'bad-dest-out') --work $work --index $index
    $rcL2 = $LASTEXITCODE
    Check ($rcL2 -ne 0 -and (($oL2 -join ' ') -match 'must go under config/')) "L: mac config dest plugins/x.dll refused (exit $($rcL2): $($oL2 | Select-Object -Last 1))"
}

Step 'M: release dry run never reuses a revision the friends have' {
    Copy-Item -LiteralPath $index -Destination (Join-Path $workLatest 'peak-index.json')
    $curDir = Join-Path $workLatest 'current'
    $txt = [IO.File]::ReadAllText($manifest)
    $txt9 = ([regex]'"revision"\s*:\s*\d+').Replace($txt, '"revision": 9', 1)
    WriteText (Join-Path $curDir 'manifest.json') $txt9
    $cfgM = New-Cfg 'release dry run'
    $cfgM['githubRepo'] = 'jmproulx/peakpack'
    $cfgM['app'] = @{ version = '0.4.1'; source = $script:appExe }
    WriteText (Join-Path $v5 'publish-release.json') ($cfgM | ConvertTo-Json -Depth 8)
    $oM = PP release --config (Join-Path $v5 'publish-release.json') --work $workLatest --index (Join-Path $workLatest 'peak-index.json') --dry-run
    $rcM = $LASTEXITCODE
    $textM = $oM -join "`n"
    Check ($rcM -eq 0) "M: dry run exits 0 (got $rcM)"
    Check ($textM -match '"latest" serves revision') 'M: warns that "latest" serves an older revision'
    Check ($textM -match 'release create rev-10') 'M: plans rev-10 (above the local revision 9)'
    Check ($textM -match 'Mac friends also get') 'M: summary says what Mac friends get'
    Check ((Json (Join-Path $curDir 'manifest.json')).revision -eq 9) 'M: the local release record is untouched by the dry run'
}

Write-Host ''
if ($script:fails -eq 0) { Write-Host "ALL V5 CHECKS PASSED ($script:passes checks)" -ForegroundColor Green }
else { Write-Host "$($script:fails) V5 CHECK(S) FAILED ($script:passes passed)" -ForegroundColor Red }
exit $script:fails
