# v0.3 behaviours, end to end against the SANDBOX (never the real game folder). Run tools\sandbox-test.ps1 first
# (it builds the fake game and caches the Thunderstore packages). Everything here lives in sandbox\v3\.
#   - manifest: friendly titles/descriptions, hostName, packId, changelog, companion auto-included
#   - friend sync writes pack-info.json (for the in-game companion) and installed-manifest.json
#   - "check": Update available / Up to date, with plain-language changes
#   - host/dev sync options: --keep-extra keeps extra plugins; --no-game-folder never touches the game folder
#   - first-run self-install: the installed copy has NO Mark-of-the-Web, shortcuts point at the installed copy
#   - publish pipeline: release --dry-run prints the exact gh command and changes nothing; stamp for the host's game
#   - companion lobby logic unit tests (tools\LobbyCheckTests)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
$sb = Join-Path $root 'sandbox'
$v3 = Join-Path $sb 'v3'
$game = Join-Path $v3 'PEAK'
$fails = 0
function Check($cond, $msg) { if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green } else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fails++ } }
function PP { $ErrorActionPreference = 'Continue'; & $script:cli @args 2>&1 | ForEach-Object { "$_" } }
function Files($d) { (Get-ChildItem -LiteralPath $d -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($d.Length) + '|' + $_.Length } | Sort-Object) -join "`n" }

Write-Host '== build'
& $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo | Out-Null
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
$companionBuilt = $false
& $dn build (Join-Path $root 'src\PeakPack.Companion') -c Release -v q --nologo | Out-Null
if ($LASTEXITCODE -eq 0) { $companionBuilt = $true } else { Write-Host '  (companion not built: PEAK DLLs missing? companion checks skipped)' -ForegroundColor Yellow }
if (-not (Test-Path (Join-Path $sb 'PEAK\PEAK.exe'))) { Write-Host 'Run tools\sandbox-test.ps1 first.'; exit 1 }

Remove-Item -Recurse -Force $v3 -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $v3, (Join-Path $v3 'custom'), (Join-Path $v3 'work') | Out-Null
# A private copy of the fake game (vanilla), so these tests never interfere with the other scripts.
Copy-Item (Join-Path $sb 'PEAK') $game -Recurse
Get-ChildItem $game -Force | Where-Object { $_.Name -in 'winhttp.dll','doorstop_config.ini','.doorstop_version','BepInEx','launch-log.txt' } | Remove-Item -Recurse -Force
Copy-Item (Join-Path $sb 'publisher\peak-index.json') (Join-Path $v3 'work\peak-index.json')
if (Test-Path (Join-Path $sb 'publisher\cache')) { Copy-Item (Join-Path $sb 'publisher\cache') (Join-Path $v3 'work\cache') -Recurse }
$key = Join-Path $v3 'test-key.pem'
$pub = (PP keygen --out $key | Select-Object -Last 1).Trim()
$out = Join-Path $v3 'published'
$manifest = Join-Path $out 'manifest.json'
$data = Join-Path $v3 'data'
$common = @('--game-dir', $game, '--data-dir', $data, '--allow-local', '--public-key', $pub)

function Write-Config($mods, $jet, $notes) {
    [IO.File]::WriteAllBytes((Join-Path $v3 'custom\JetpackBoost.dll'), [Text.Encoding]::ASCII.GetBytes($jet))
    $cfg = [ordered]@{
        packName = "Joshua's PEAK mods (v3 test)"; hostName = 'Joshua'; notes = $notes
        loader = 'BepInEx-BepInExPack_PEAK'; mods = $mods
        modInfo = @{ 'Sapphire009-InfiniteJetpack' = @{ title = 'Infinite Jetpack'; description = 'The jetpack never runs out of fuel.' } }
        customFiles = @(@{ id = 'Joshua-JetpackBoost'; version = '0.1.0'; title = 'Jetpack Boost'; description = 'Stronger jetpack thrust and a forward push.'
                           source = (Join-Path $v3 'custom\JetpackBoost.dll'); dest = 'plugins/Joshua-JetpackBoost/JetpackBoost.dll' })
        lobby = @{ mismatchPolicy = 'warn'; liveSettings = @(@{ plugin = 'com.joshua.jetpackboost'; section = 'Boost'; key = 'ThrustMultiplier' }) }
        githubRepo = 'jmproulx/peakpack'
        signingKey = $key; gameDir = $game
        app = @{ version = '0.3.0'; source = $cli }   # any file works as the "app" asset for the pipeline test
    }
    $cfg | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v3 'publish.json') -Encoding utf8
}

Write-Host '== publish revision 1 (friendly fields, companion)'
Write-Config @('Sapphire009-InfiniteJetpack-1.0.1') 'JETPACKBOOST v1' 'First pack: Infinite Jetpack + JetpackBoost'
$o = PP publish --config (Join-Path $v3 'publish.json') --out $out --work (Join-Path $v3 'work')
Check ($o -match 'Published revision 1') 'published revision 1'
$m = Get-Content $manifest -Raw | ConvertFrom-Json
Check ($m.hostName -eq 'Joshua' -and $m.packId -eq 'joshuas-peak-mods-v3-test') "hostName + packId ($($m.packId))"
$ij = $m.packages | Where-Object id -like 'Sapphire009-InfiniteJetpack-*'
Check ($ij.title -eq 'Infinite Jetpack' -and $ij.description -eq 'The jetpack never runs out of fuel.') 'modInfo title/description override'
Check ($m.changelog[0].revision -eq 1 -and $m.changelog[0].notes -match 'First pack') 'changelog entry for revision 1'
Check (@($m.lobby.liveSettings).Count -eq 1) 'lobby live settings in manifest'
Check ($m.files[0].url -like 'https://github.com/jmproulx/peakpack/releases/download/rev-1/*') "own files point at the rev-1 release ($($m.files[0].url))"
if ($companionBuilt) { Check (@($m.files | Where-Object id -eq 'PeakPack-Companion').Count -eq 1) 'companion auto-included' }

# The publish above points own files at GitHub; for the local install test, republish with relative URLs.
$cfgJson = Get-Content (Join-Path $v3 'publish.json') -Raw | ConvertFrom-Json
$cfgJson.githubRepo = $null
$cfgJson | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v3 'publish-local.json') -Encoding utf8
Remove-Item -Recurse -Force $out
$o = PP publish --config (Join-Path $v3 'publish-local.json') --out $out --work (Join-Path $v3 'work')

Write-Host '== check before install / install / check after'
$o = PP check --manifest $manifest @common
Check ($o -match 'Not installed') 'check: not installed'
$o = PP install --manifest $manifest @common
Check ($o -match 'Now on revision 1') 'installed revision 1'
$info = Get-Content (Join-Path $data 'profile\BepInEx\PeakPack\pack-info.json') -Raw | ConvertFrom-Json
Check ($info.revision -eq 1 -and $info.packId -eq 'joshuas-peak-mods-v3-test' -and $info.hostName -eq 'Joshua') 'pack-info.json written for the companion'
Check ($info.liveSettings[0] -eq 'com.joshua.jetpackboost|Boost|ThrustMultiplier' -and $info.mismatchPolicy -eq 'warn') 'pack-info lists live settings + policy'
Check (Test-Path (Join-Path $data 'installed-manifest.json')) 'installed-manifest.json saved'
$o = PP check --manifest $manifest @common
Check ($o -match 'Up to date \(revision 1\)') 'check: up to date'

Write-Host '== revision 2: new JetpackBoost build + add a mod -> "Update available: 2 mods changed"'
Write-Config @('Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider') 'JETPACKBOOST v2' 'Glider added, JetpackBoost tuned'
$cfgJson = Get-Content (Join-Path $v3 'publish.json') -Raw | ConvertFrom-Json; $cfgJson.githubRepo = $null
$cfgJson | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v3 'publish-local.json') -Encoding utf8
$o = PP publish --config (Join-Path $v3 'publish-local.json') --out $out --work (Join-Path $v3 'work')
$o = PP check --manifest $manifest @common
Check ($o -match 'Update available: revision 1 -> 2, 2 mods changed') "check: update available ($(($o | Select-String 'Update available') -join ''))"
Check ($o -match 'Added Infinite Glider' -and $o -match 'Updated Jetpack Boost \(new build\)') 'plain-language change list'
$o = PP install @common
$m2 = Get-Content $manifest -Raw | ConvertFrom-Json
Check ($m2.changelog.Count -eq 2 -and $m2.changelog[0].revision -eq 2) 'changelog keeps history, newest first'

Write-Host '== host/dev profile options'
$dataHost = Join-Path $v3 'data-host'
$gameBefore = Files $game
$o = PP install --manifest $manifest --game-dir $game --data-dir $dataHost --allow-local --public-key $pub --no-game-folder
Check ($o -match 'Now on revision 2') '--no-game-folder sync works'
# the game folder already has OUR proxy from the friend install above; --no-game-folder must not change anything
Check ((Files $game) -eq $gameBefore) '--no-game-folder left the game folder untouched'
New-Item -ItemType Directory -Force (Join-Path $dataHost 'profile\BepInEx\plugins\Joshua-DevBuild') | Out-Null
Set-Content (Join-Path $dataHost 'profile\BepInEx\plugins\Joshua-DevBuild\Dev.dll') 'dev'
$o = PP install --game-dir $game --data-dir $dataHost --allow-local --public-key $pub --no-game-folder --keep-extra
Check (Test-Path (Join-Path $dataHost 'profile\BepInEx\plugins\Joshua-DevBuild\Dev.dll')) '--keep-extra keeps a dev build in plugins'
$o = PP install --game-dir $game --data-dir $dataHost --allow-local --public-key $pub --no-game-folder
Check (-not (Test-Path (Join-Path $dataHost 'profile\BepInEx\plugins\Joshua-DevBuild'))) 'strict (default) removes it, as for friends'

Write-Host '== first-run self-install: no Mark-of-the-Web on the installed copy'
$dl = Join-Path $v3 'Downloads'; New-Item -ItemType Directory -Force $dl | Out-Null
$fake = Join-Path $dl 'PeakPack.exe'
Copy-Item $cli $fake
Set-Content -LiteralPath $fake -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/"
Check ($null -ne (Get-Item -LiteralPath $fake -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'simulated download carries Mark-of-the-Web (ZoneId=3)'
$plainCopy = Join-Path $dl 'FileCopy.exe'; [IO.File]::Copy($fake, $plainCopy, $true)
Check ($null -ne (Get-Item -LiteralPath $plainCopy -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'fact: File.Copy (v0.2 behaviour) carries the Mark-of-the-Web over'
$dataApp = Join-Path $v3 'data-app'; $sc = Join-Path $v3 'shortcuts'
$o = PP selfinstall --exe $fake --data-dir $dataApp --shortcut-dir $sc --game-dir $game
$inst = Join-Path $dataApp 'PeakPack.exe'
Check ((Test-Path $inst) -and ((Get-FileHash $inst).Hash -eq (Get-FileHash $fake).Hash)) 'installed copy is byte-identical'
Check ($null -eq (Get-Item -LiteralPath $inst -Stream Zone.Identifier -ErrorAction SilentlyContinue)) 'installed copy has NO Mark-of-the-Web'
$sh = New-Object -ComObject WScript.Shell
$lnk = $sh.CreateShortcut((Join-Path $sc 'Desktop\PEAK (Modded).lnk'))
Check ($lnk.TargetPath -eq $inst -and $lnk.Arguments -like '--launch*') "desktop 'PEAK (Modded)' -> installed copy --launch"
Check ($lnk.IconLocation -like "*PEAK.exe,0") 'desktop shortcut uses PEAK.exe icon'
Check ((Test-Path (Join-Path $sc 'StartMenu\PeakPack.lnk')) -and (Test-Path (Join-Path $sc 'StartMenu\PEAK (Modded).lnk'))) "Start Menu: 'PEAK (Modded)' + 'PeakPack'"
$o = PP selfinstall --exe $fake --data-dir $dataApp --shortcut-dir $sc --game-dir $game
Check ($o -match 'copied: False') 'opening the same download again does not rewrite the installed copy'

Write-Host '== publish pipeline (dry run only: nothing is uploaded)'
$work = Join-Path $v3 'work'
$o = PP release --config (Join-Path $v3 'publish.json') --work $work --previous (Join-Path $v3 'none.json') --dry-run --notes 'Dry-run test'
Check ($o -match 'DRY RUN, would run: .*gh(\.exe)?"? release create rev-1 ') 'dry run prints the gh release command'
Check ($o -match '--repo jmproulx/peakpack' -and $o -match '--latest') 'targets jmproulx/peakpack, marked latest'
Check (-not ($o -match 'NOT READY')) "pipeline reports ready ($(($o | Select-String 'NOT READY') -join '; '))"
Check (Test-Path (Join-Path $work 'staging\PeakPack.exe')) 'stable PeakPack.exe asset staged'
Check (-not (Test-Path (Join-Path $work 'current'))) 'dry run did not mark anything as released'
$cfgNoKey = Get-Content (Join-Path $v3 'publish.json') -Raw | ConvertFrom-Json; $cfgNoKey.signingKey = $null
$cfgNoKey | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $v3 'publish-nokey.json') -Encoding utf8
$o = PP release --config (Join-Path $v3 'publish-nokey.json') --work $work --previous (Join-Path $v3 'none.json')
Check ($o -match 'NOT READY: The manifest isn''t signed' -and $LASTEXITCODE -ne 0) 'a real release without a signing key is refused'

Write-Host '== stamp the host''s own game (companion + pack-info)'
$hostBep = Join-Path $v3 'hostgame\BepInEx'; New-Item -ItemType Directory -Force (Join-Path $hostBep 'plugins') | Out-Null
$o = PP stamp --manifest (Join-Path $work 'staging') --bepinex $hostBep
$hi = Get-Content (Join-Path $hostBep 'PeakPack\pack-info.json') -Raw | ConvertFrom-Json
Check ($hi.revision -eq 1) 'host pack-info.json stamped'
if ($companionBuilt) {
    $hc = Join-Path $hostBep 'plugins\PeakPack-Companion\PeakPack.Companion.dll'
    Check (Test-Path $hc) 'host companion installed'
    $o = PP stamp --manifest (Join-Path $work 'staging') --bepinex $hostBep
    Check ($o -match 'already this build') 'stamp again: identical companion is not copied'
    # The running game keeps the DLL it loaded at startup locked: stamp must still update pack-info.
    [IO.File]::WriteAllText($hc, 'older build')
    (Get-Content (Join-Path $hostBep 'PeakPack\pack-info.json') -Raw).Replace('"revision": 1', '"revision": 0') | Set-Content (Join-Path $hostBep 'PeakPack\pack-info.json')
    $lock = [IO.File]::Open($hc, 'Open', 'Read', 'Read')
    try { $o = PP stamp --manifest (Join-Path $work 'staging') --bepinex $hostBep } finally { $lock.Dispose() }
    Check ($o -match 'in use by the running game' -and (Get-Content $hc -Raw) -eq 'older build') 'locked companion: left as is and reported'
    Check ((Get-Content (Join-Path $hostBep 'PeakPack\pack-info.json') -Raw | ConvertFrom-Json).revision -eq 1) 'locked companion: pack-info still updated'
}

Write-Host '== companion lobby logic'
if (Test-Path (Join-Path $PSScriptRoot 'LobbyCheckTests')) {
    $o = & $dn run --project (Join-Path $PSScriptRoot 'LobbyCheckTests') -v q 2>&1 | ForEach-Object { "$_" }
    Check ($LASTEXITCODE -eq 0 -and ($o -match 'ALL LOBBY CHECKS PASSED')) 'LobbyCheck unit tests'
}

Write-Host ''
if ($fails -eq 0) { Write-Host 'ALL V3 CHECKS PASSED' -ForegroundColor Green } else { Write-Host "$fails V3 CHECK(S) FAILED" -ForegroundColor Red }
exit $fails
