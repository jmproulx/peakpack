# v0.4: testing with friends, end to end against the SANDBOX (never the real game). Run sandbox-test.ps1 first.
#   - publisher: reload-safe flag -> manifest hotReload, test lobby adds AutoReload, host ids
#   - friend consent switches -> pack-info.json (what the companion reads)
#   - live update via the REAL installed PeakPack.exe --hot-update (exactly what the companion starts):
#     applied / undo / not reload-safe / Thunderstore change / opted out / unsigned / tampered / test lobby off
#   - hotfix: DLL checks (OnDestroy + embedded PDB), dry run prints the gh command and changes nothing
#   - lobby command files for the host's companion (snapshot, hot-update)
#   - companion: IlScan (no direct non-public game access) and the pure-logic unit tests
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
$sb = Join-Path $root 'sandbox'
$v4 = Join-Path $sb 'v4'
$game = Join-Path $v4 'PEAK'
$fails = 0
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green } else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fails++ } }
function PP { $ErrorActionPreference = 'Continue'; & $script:cli @args 2>&1 | ForEach-Object { "$_" } }
function Sha($f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() }
function Json($f) { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json }

Write-Host '== build'
& $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo | Out-Null
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
& $dn publish (Join-Path $root 'src\PeakPack.App') -c Release -o (Join-Path $root 'publish-out') -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host 'app publish failed'; exit 1 }
$appExe = Join-Path $root 'publish-out\PeakPack.exe'
if (-not (Test-Path (Join-Path $sb 'PEAK\PEAK.exe'))) { Write-Host 'Run tools\sandbox-test.ps1 first.'; exit 1 }

# Real plugin DLLs for the DLL checks (read-only copies): JetpackBoost is reload-safe (OnDestroy + embedded PDB);
# the real-PC test plugin has no OnDestroy.
$jbReal = 'C:\Users\joshu\PeakMods\JetpackBoost\bin\Release\JetpackBoost.dll'
& $dn build (Join-Path $PSScriptRoot 'RealPcTestPlugin') -c Release -v q --nologo | Out-Null
$plainPlugin = Join-Path $PSScriptRoot 'RealPcTestPlugin\bin\Release\PeakPackRealPcTest.dll'

Remove-Item -Recurse -Force $v4 -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $v4, (Join-Path $v4 'custom'), (Join-Path $v4 'work'), (Join-Path $v4 'hostgame\BepInEx') | Out-Null
Copy-Item (Join-Path $sb 'PEAK') $game -Recurse
Get-ChildItem $game -Force | Where-Object { $_.Name -in 'winhttp.dll','doorstop_config.ini','.doorstop_version','BepInEx','launch-log.txt' } | Remove-Item -Recurse -Force
Copy-Item (Join-Path $sb 'publisher\peak-index.json') (Join-Path $v4 'work\peak-index.json')
if (Test-Path (Join-Path $sb 'publisher\cache')) { Copy-Item (Join-Path $sb 'publisher\cache') (Join-Path $v4 'work\cache') -Recurse }
$key = Join-Path $v4 'test-key.pem'
$pub = (PP keygen --out $key | Select-Object -Last 1).Trim()
$out = Join-Path $v4 'published'; $manifest = Join-Path $out 'manifest.json'
$data = Join-Path $v4 'PeakPack Data'   # with a space, like a real user name might have
$jb = Join-Path $v4 'custom\JetpackBoost.dll'; $tp = Join-Path $v4 'custom\TestPlugin.dll'

function Build-Variant($src, $dst, $tag) {
    # A "new build": same plugin bytes plus a trailing marker (still a valid PE; different SHA-256).
    $bytes = [IO.File]::ReadAllBytes($src) + [Text.Encoding]::ASCII.GetBytes("BUILD:$tag")
    [IO.File]::WriteAllBytes($dst, $bytes)
}
function Publish($mods, $testLobby, $notes, [switch]$NoDiag) {
    $cfg = [ordered]@{
        packName = "Joshua's PEAK mods (v4 test)"; hostName = 'Joshua'; notes = $notes; loader = 'BepInEx-BepInExPack_PEAK'; mods = $mods
        customFiles = @(
            @{ id = 'Joshua-JetpackBoost'; version = '0.1.0'; title = 'Jetpack Boost'; source = $jb; dest = 'plugins/Joshua-JetpackBoost/JetpackBoost.dll'; reloadSafe = $true },
            @{ id = 'Joshua-TestPlugin'; version = '1.0.0'; title = 'Test Plugin'; source = $tp; dest = 'plugins/Joshua-TestPlugin/TestPlugin.dll'; reloadSafe = $false })
        lobby = @{ testLobby = $testLobby; diagnostics = (-not $NoDiag); hostIds = @('host-123') }
        signingKey = $key; gameDir = $game; companion = ''
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v4 'publish.json') -Encoding utf8
    PP publish --config (Join-Path $v4 'publish.json') --out $out --work (Join-Path $v4 'work') | Out-Null
}
$installed = Join-Path $data 'PeakPack.exe'
$common = @('--data-dir', $data, '--game-dir', $game, '--allow-local', '--public-key', $pub)
function HotUpdate([string[]]$extra) {
    # Exactly what the companion starts (appExe + appArgs + --hot-update), plus the test-only manifest/key overrides.
    $info = Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')
    $argv = @($info.appArgs) + @('--hot-update', '--allow-local', '--public-key', $pub) + $extra
    $p = Start-Process -FilePath $info.appExe -ArgumentList ($argv | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit(60000)) { $p.Kill(); return $null }
    Json (Join-Path $data 'profile\BepInEx\PeakPack\hot-update-result.json')
}
$jbDest = Join-Path $data 'profile\BepInEx\plugins\Joshua-JetpackBoost\JetpackBoost.dll'

Write-Host '== publish rev 1 (test lobby, reload-safe JetpackBoost)'
Build-Variant $jbReal $jb 'r1'; Copy-Item $plainPlugin $tp
Publish @('Sapphire009-InfiniteJetpack-1.0.1') $true 'Test lobby on'
$m = Json $manifest
Check (@($m.packages | Where-Object id -like 'Hamunii-AutoReload-*').Count -eq 1) 'test lobby adds AutoReload to the friends'' pack'
Check (($m.files | Where-Object id -eq 'Joshua-JetpackBoost').hotReload -eq $true -and -not ($m.files | Where-Object id -eq 'Joshua-TestPlugin').hotReload) 'hotReload only for the reload-safe own mod'
Check ($m.lobby.testLobby -eq $true -and $m.lobby.hostIds[0] -eq 'host-123') 'manifest carries test lobby + host ids'

Write-Host '== friend installs; consent switches -> pack-info'
PP selfinstall --exe $appExe --data-dir $data --game-dir $game | Out-Null
$o = PP install --manifest $manifest @common
Check ($o -match 'Now on revision 1') 'installed revision 1'
$info = Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')
Check ($info.diagnostics -eq $true -and $info.liveUpdates -eq $false) 'defaults: logs shared (consent default on), live updates off'
Check ($info.appExe -eq $installed -and $info.appArgs[1] -eq $data) "pack-info points the companion at the installed app ($($info.appExe))"
Check ($info.hotMods[0] -eq 'plugins/Joshua-JetpackBoost|Jetpack Boost' -and $info.ownModFolders -contains 'plugins/Joshua-TestPlugin') 'pack-info lists own mod folders + hot mods'
Check ($info.hostIds[0] -eq 'host-123') 'pack-info carries host ids (companion relays only to them)'
PP options --data-dir $data --diagnostics off | Out-Null
Check ((Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')).diagnostics -eq $false) 'turning sharing off updates pack-info at once'
PP options --data-dir $data --diagnostics on --live-updates on | Out-Null
$info = Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')
Check ($info.diagnostics -and $info.liveUpdates) 'opt in to live updates'

Write-Host '== rev 2: new JetpackBoost build -> live update (real PeakPack.exe --hot-update)'
$before = Sha $jbDest
Build-Variant $jbReal $jb 'r2'
Publish @('Sapphire009-InfiniteJetpack-1.0.1') $true 'JetpackBoost tweak'
$r = HotUpdate @()
Check ($r.status -eq 'applied' -and $r.mods[0] -eq 'Jetpack Boost' -and $r.revision -eq 2) "applied: $($r.status) $($r.message)"
Check ((Sha $jbDest) -eq (Sha $jb)) 'new build written in place (AutoReload sees a file change)'
Check ((Json (Join-Path $data 'state.json')).installedRevision -eq 2) 'state now revision 2'
Check ((Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')).revision -eq 2) 'pack-info now revision 2 (lobby check matches the host)'
Check (Test-Path (Join-Path $data 'rollback\last.json')) 'previous build kept for undo'

Write-Host '== undo'
$p = Start-Process -FilePath $installed -ArgumentList @('--data-dir', "`"$data`"", '--hot-rollback') -PassThru -WindowStyle Hidden; [void]$p.WaitForExit(30000)
$r = Json (Join-Path $data 'profile\BepInEx\PeakPack\hot-update-result.json')
Check ($r.status -eq 'rolled-back' -and (Sha $jbDest) -eq $before) 'undo restores the previous build'
Check ((Json (Join-Path $data 'state.json')).installedRevision -eq 1 -and (Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')).revision -eq 1) 'undo returns to revision 1'
$r = HotUpdate @()
Check ($r.status -eq 'applied') 're-apply after undo'

Write-Host '== things that must NOT be applied live'
Build-Variant $plainPlugin $tp 'r3'
Publish @('Sapphire009-InfiniteJetpack-1.0.1') $true 'TestPlugin change'
$tpDest = Join-Path $data 'profile\BepInEx\plugins\Joshua-TestPlugin\TestPlugin.dll'; $tpBefore = Sha $tpDest
$r = HotUpdate @()
Check ($r.status -eq 'restart-needed' -and (Sha $tpDest) -eq $tpBefore) "non-reload-safe mod -> restart-needed, nothing changed ($($r.message))"
PP install @common | Out-Null   # friend restarts from the icon: normal sync to rev 3
Build-Variant $jbReal $jb 'r4'
Publish @('Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider') $true 'JetpackBoost + glider'
$jbBefore = Sha $jbDest
$r = HotUpdate @()
Check ($r.status -eq 'restart-needed' -and (Sha $jbDest) -eq $jbBefore) "Thunderstore change in the same revision -> restart-needed, nothing applied ($($r.message))"
PP install @common | Out-Null
PP options --data-dir $data --live-updates off | Out-Null
Build-Variant $jbReal $jb 'r5'
Publish @('Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider') $true 'JetpackBoost r5'
$jbBefore = Sha $jbDest
$r = HotUpdate @()
Check ($r.status -eq 'not-allowed' -and (Sha $jbDest) -eq $jbBefore) 'friend opted out -> not applied'
PP options --data-dir $data --live-updates on | Out-Null
$info = Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')
$p = Start-Process -FilePath $info.appExe -ArgumentList (@($info.appArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) + @('--hot-update', '--allow-local')) -PassThru -WindowStyle Hidden; [void]$p.WaitForExit(60000)
$r = Json (Join-Path $data 'profile\BepInEx\PeakPack\hot-update-result.json')
Check ($r.status -ne 'applied' -and (Sha $jbDest) -eq $jbBefore) "no matching key (sandbox manifest vs the app's built-in key) -> refused ($($r.status): $($r.message))"
Copy-Item $manifest "$manifest.bak"
(Get-Content $manifest -Raw).Replace('"testLobby": true', '"testLobby": true ') | Set-Content $manifest -NoNewline
$r = HotUpdate @()
Check ($r.status -eq 'failed' -and $r.message -match 'signature' -and (Sha $jbDest) -eq $jbBefore) 'tampered manifest -> signature check fails, nothing applied'
Move-Item "$manifest.bak" $manifest -Force
Publish @('Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider') $false 'Test lobby off'
$r = HotUpdate @()
Check ($r.status -eq 'not-allowed' -and (Sha $jbDest) -eq $jbBefore) 'pack not in test-lobby mode -> not applied'
PP install @common | Out-Null
Check ((Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')).liveUpdates -eq $false) 'pack-info: live updates off when the pack isn''t a test lobby'
Publish @('Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider') $false 'no diagnostics' -NoDiag
PP install @common | Out-Null
Check ((Json (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json')).diagnostics -eq $false) 'pack-info: no log sharing when the host turned diagnostics off'

Write-Host '== hotfix (dry run) and DLL checks'
$cfgH = Json (Join-Path $v4 'publish.json')
$cfgH | Add-Member githubRepo 'jmproulx/peakpack' -Force
$cfgH | Add-Member app @{ version = '0.4.0'; source = $appExe } -Force
$cfgH.lobby.testLobby = $true
$cfgH | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v4 'publish-hotfix.json') -Encoding utf8
$cfgBefore = Get-Content (Join-Path $v4 'publish-hotfix.json') -Raw
$o = PP hotfix --mod JetpackBoost --dll $jbReal --config (Join-Path $v4 'publish-hotfix.json') --work (Join-Path $v4 'work') --previous (Join-Path $v4 'none.json') --index (Join-Path $v4 'work\peak-index.json') --notify (Join-Path $v4 'hostgame\BepInEx')
Check ($o -match 'embedded PDB: True; OnDestroy: True') 'JetpackBoost build passes the reload-safe check'
Check ($o -match 'DRY RUN, would run: .*release create rev-1 ' -and $o -match '--latest') 'hotfix dry run prints the gh release command (pack release, latest)'
Check ($o -match 'PeakPack\.exe ' -or $o -match 'PeakPack\.exe"') 'release keeps the stable PeakPack.exe asset'
Check ($o -match 'tell the lobby \(live update for friends who opted in\)') 'dry run says it would announce a live update'
Check ((Get-Content (Join-Path $v4 'publish-hotfix.json') -Raw) -eq $cfgBefore) 'dry run left publish.json unchanged'
Check (-not (Test-Path (Join-Path $v4 'hostgame\BepInEx\PeakPack\commands'))) 'dry run wrote no lobby command'
$o = PP hotfix --mod JetpackBoost --dll $plainPlugin --config (Join-Path $v4 'publish-hotfix.json') --work (Join-Path $v4 'work') --previous (Join-Path $v4 'none.json') --index (Join-Path $v4 'work\peak-index.json')
Check ($o -match 'NOT reload-safe for this build' -and $o -match 'restart notice') 'a build without OnDestroy is published as restart-only'
$o = PP hotfix --mod NoSuchMod --config (Join-Path $v4 'publish-hotfix.json') --work (Join-Path $v4 'work')
Check ($o -match "isn't one of your own builds") 'unknown mod name is refused with the list of own builds'

Write-Host '== lobby commands for the host''s companion'
$hb = Join-Path $v4 'hostgame\BepInEx'
PP lobby snapshot --bepinex $hb | Out-Null
PP lobby hot-update --revision 9 --bepinex $hb | Out-Null
$cmds = @(Get-ChildItem (Join-Path $hb 'PeakPack\commands') -Filter *.json | ForEach-Object { Json $_.FullName })
Check (@($cmds | Where-Object command -eq 'snapshot').Count -eq 1 -and @($cmds | Where-Object { $_.command -eq 'hot-update' -and $_.revision -eq 9 }).Count -eq 1) 'snapshot + hot-update command files written'

Write-Host '== companion build checks'
& $dn build (Join-Path $root 'src\PeakPack.Companion') -c Release --nologo 2>&1 | Out-String | Set-Variable cb
Check ($cb -match 'IlScan: 0 direct non-public references in PeakPack\.Companion\.dll') 'IlScan: no direct non-public game access'
$o = & $dn run --project (Join-Path $PSScriptRoot 'LobbyCheckTests') -v q 2>&1 | ForEach-Object { "$_" }
Check ($LASTEXITCODE -eq 0 -and ($o -match 'ALL LOBBY CHECKS PASSED')) 'companion pure-logic unit tests'

Write-Host ''
if ($fails -eq 0) { Write-Host 'ALL V4 CHECKS PASSED' -ForegroundColor Green } else { Write-Host "$fails V4 CHECK(S) FAILED" -ForegroundColor Red }
exit $fails
