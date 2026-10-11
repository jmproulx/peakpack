# End-to-end test of PeakPack against the SANDBOX fake game (never the real PEAK folder).
# Exercises: publish -> install -> idempotent re-sync -> update (add/remove/change) -> strict cleanup ->
# repair of deleted files -> tamper detection (hash + signature) -> launch modes -> foreign loader
# adoption -> full uninstall back to vanilla.
# Needs network access to thunderstore.io (packages are downloaded for real).
param([switch]$KeepData)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$dn = "C:\Program Files\dotnet\dotnet.exe"
$sb = Join-Path $root 'sandbox'
$game = Join-Path $sb 'PEAK'
$data = Join-Path $sb 'data'
$pubDir = Join-Path $sb 'publisher'
$out = Join-Path $sb 'published'
$custom = Join-Path $sb 'custom'
$fails = 0

function Check($cond, $msg) {
    if ($cond) { Write-Host "  PASS  $msg" -ForegroundColor Green }
    else { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:fails++ }
}
function PP { $ErrorActionPreference = "Continue"; & $script:cli @args 2>&1 | ForEach-Object { "$_" } }

Write-Host "== build"
& $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo | Out-Null
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
if (-not (Test-Path (Join-Path $game 'PEAK.exe'))) { & (Join-Path $PSScriptRoot 'make-sandbox.ps1') }

# Fresh state
Remove-Item -Recurse -Force $data, $out, (Join-Path $sb 'PeakPack-backups'), (Join-Path $sb 'shortcuts') -ErrorAction SilentlyContinue
Get-ChildItem $game -Force | Where-Object { $_.Name -in 'winhttp.dll','doorstop_config.ini','.doorstop_version','BepInEx','launch-log.txt' } | Remove-Item -Recurse -Force
New-Item -ItemType Directory -Force $pubDir, $custom | Out-Null
$gameFilesBefore = (Get-ChildItem $game -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object) -join "`n"

# Fresh throwaway signing key for the test (keygen prints the public key on its last line)
$key = Join-Path $pubDir 'test-signing-key.pem'
Remove-Item $key -ErrorAction SilentlyContinue
$pubKey = (PP keygen --out $key | Select-Object -Last 1).Trim()

function Write-PublishJson($mods, $heliText) {
    [IO.File]::WriteAllBytes((Join-Path $custom 'HeliPilot.dll'), [Text.Encoding]::ASCII.GetBytes($heliText))
    "[General]`r`nAltitude = 120`r`n" | Set-Content (Join-Path $custom 'HeliPilot.cfg')
    $cfg = [ordered]@{
        packName = "Joshua's PEAK mods (sandbox test)"
        loader = 'BepInEx-BepInExPack_PEAK'
        mods = $mods
        hostOnly = @('glarmer-PEAK_Unlimited')
        customFiles = @(
            [ordered]@{ id = 'Joshua-HeliPilot'; version = '0.1.0'; source = (Join-Path $custom 'HeliPilot.dll'); dest = 'plugins/Joshua-HeliPilot/HeliPilot.dll' },
            [ordered]@{ id = 'Joshua-HeliPilot'; version = '0.1.0'; source = (Join-Path $custom 'HeliPilot.cfg'); dest = 'config/HeliPilot.cfg'; overwrite = 'ifMissing' }
        )
        gameDir = $game
        signingKey = $key
    }
    $cfg | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $pubDir 'publish.json') -Encoding utf8
}

$common = @('--game-dir', $game, '--data-dir', $data)
$manifest = Join-Path $out 'manifest.json'

Write-Host "== publish revision 1"
Write-PublishJson @('Hamunii-AutoReload', 'Sapphire009-InfiniteJetpack-1.0.1', 'Sapphire009-InfiniteGlider', 'PEAKModding-PEAKLib_Core') 'FAKE HELIPILOT v0.1'
$o = PP publish --config (Join-Path $pubDir 'publish.json') --out $out --work $pubDir
Check ($o -match 'Published revision 1') 'publisher wrote revision 1'
Check (Test-Path "$manifest.sig") 'manifest is signed'
$m = Get-Content $manifest -Raw | ConvertFrom-Json
Check (@($m.packages | Where-Object id -like 'glarmer-*').Count -eq 0) 'host-only mod excluded from friend manifest'
Check (@($m.packages | Where-Object id -like 'MonoDetour-MonoDetour_BepInEx_5-*').Count -eq 1) 'dependencies resolved (PEAKLib_Core -> MonoDetour_BepInEx_5)'

Write-Host "== install"
$o = PP install --manifest $manifest --allow-local --public-key $pubKey @common
Check ($o -match 'signature OK') 'signature verified'
Check ($o -match 'Now on revision 1') 'installed revision 1'
$bep = Join-Path $data 'profile\BepInEx'
Check (Test-Path "$bep\core\BepInEx.Preloader.dll") 'BepInEx installed in profile (not game folder)'
Check (Test-Path "$bep\plugins\Sapphire009-InfiniteGlider\InfiniteGlider.dll") 'Thunderstore mod installed'
Check (Test-Path "$bep\patchers\MonoDetour-MonoDetour_BepInEx_5") 'patchers/ routed per r2modman rules'
Check (Test-Path "$bep\plugins\Joshua-HeliPilot\HeliPilot.dll") 'custom DLL installed'
Check (-not (Test-Path "$game\BepInEx")) 'game folder has no BepInEx folder'
Check ((Get-Content "$game\doorstop_config.ini") -contains 'enabled = false') 'game-folder doorstop_config.ini has enabled = false (Steam launch = vanilla)'
$o = PP install --allow-local --public-key $pubKey @common
Check ($o -match 'Already up to date') 'second sync is a no-op'

Write-Host "== launch modes (direct to fake PEAK.exe)"
PP launch --modded --method direct @common | Out-Null
Start-Sleep -Seconds 2
$log = Get-Content "$game\launch-log.txt" -Raw
Check ($log -match '--doorstop-enabled \| true \| --doorstop-target-assembly \| .*sandbox\\data\\profile\\BepInEx\\core\\BepInEx.Preloader.dll') 'modded launch passes doorstop args with profile preloader path'
PP launch --vanilla --method direct @common | Out-Null
Start-Sleep -Seconds 2
Check ((Get-Content "$game\launch-log.txt" | Select-Object -Last 1) -match '--doorstop-enabled \| false') 'vanilla launch passes --doorstop-enabled false'
$o = PP launch --modded --method dry @common
Check ($o -match 'steam\.exe.*-applaunch 3527290 --doorstop-enabled true') 'Steam launch command line (dry run) is steam.exe -applaunch 3527290 ...'
Remove-Item "$game\launch-log.txt"
$o = PP status @common
Check ($o -match 'Last launch : Vanilla') 'status shows last launch mode'

Write-Host "== update to revision 2: drop InfiniteGlider, change HeliPilot, add stray file + delete a file"
New-Item -ItemType Directory -Force "$bep\plugins\SomethingTheFriendAdded" | Out-Null
Set-Content "$bep\plugins\SomethingTheFriendAdded\x.dll" 'x'
Remove-Item "$bep\plugins\Hamunii-AutoReload\com.github.Hamunii.AutoReload.dll"
'Altitude = 999 (friend tweak)' | Set-Content "$bep\config\HeliPilot.cfg"
Write-PublishJson @('Hamunii-AutoReload', 'Sapphire009-InfiniteJetpack-1.0.1', 'PEAKModding-PEAKLib_Core') 'FAKE HELIPILOT v0.2'
$o = PP publish --config (Join-Path $pubDir 'publish.json') --out $out --work $pubDir
Check ($o -match 'Published revision 2') 'publisher bumped to revision 2'
Check ($o -match '- Sapphire009-InfiniteGlider') 'publisher diff shows removal'
$o = PP install --allow-local --public-key $pubKey @common
Check ($o -match 'Now on revision 2') 'synced to revision 2'
Check (-not (Test-Path "$bep\plugins\Sapphire009-InfiniteGlider")) 'removed mod folder gone'
Check (-not (Test-Path "$bep\plugins\SomethingTheFriendAdded")) 'unmanaged plugin removed (strict mode)'
Check (Test-Path "$bep\plugins\Hamunii-AutoReload\com.github.Hamunii.AutoReload.dll") 'deleted mod file repaired'
Check ((Get-Content "$bep\plugins\Joshua-HeliPilot\HeliPilot.dll" -Raw) -match 'v0.2') 'custom DLL updated'
Check ((Get-Content "$bep\config\HeliPilot.cfg" -Raw) -match '999') 'friend-tweaked ifMissing config preserved'

Write-Host "== tamper detection"
Copy-Item $manifest "$manifest.bak"; Copy-Item "$manifest.sig" "$manifest.sig.bak"
(Get-Content $manifest -Raw).Replace('"revision": 2', '"revision": 3') | Set-Content $manifest -NoNewline
$o = PP install --allow-local --public-key $pubKey @common
Check ($o -match 'signature is invalid') 'edited manifest rejected (bad signature)'
Copy-Item "$manifest.bak" $manifest -Force
# Swap a hosted file for a different one; drop the cache entry so it must be re-fetched.
$heliAsset = Get-ChildItem $out -Filter 'Joshua-HeliPilot-*-HeliPilot.dll' | Sort-Object LastWriteTime | Select-Object -Last 1
$heliSha = (Get-FileHash $heliAsset.FullName -Algorithm SHA256).Hash.ToLower()
Remove-Item (Join-Path $data "cache\$heliSha.bin") -ErrorAction SilentlyContinue
Remove-Item "$bep\plugins\Joshua-HeliPilot\HeliPilot.dll"
Copy-Item $heliAsset.FullName "$($heliAsset.FullName).bak"
Set-Content $heliAsset.FullName 'EVIL'
$o = PP install --allow-local --public-key $pubKey @common
Check ($o -match 'Hash mismatch') 'tampered download rejected (SHA-256 mismatch)'
Check (-not (Test-Path "$bep\plugins\Joshua-HeliPilot\HeliPilot.dll")) 'tampered file not installed'
Move-Item "$($heliAsset.FullName).bak" $heliAsset.FullName -Force
Remove-Item "$manifest.bak", "$manifest.sig.bak"
$o = PP install --allow-local --public-key $pubKey @common
Check (Test-Path "$bep\plugins\Joshua-HeliPilot\HeliPilot.dll") 'recovered after the host file is fixed'
$o = PP install --allow-local @common --manifest 'https://example.com/manifest.json'
Check ($o -match 'allowlist') 'non-allowlisted host refused'

Write-Host "== r2modman/Gale overwrote our proxy: launch repairs it"
Set-Content "$game\doorstop_config.ini" "[General]`r`nenabled = true`r`ntarget_assembly=BepInEx\core\BepInEx.Preloader.dll"
PP launch --modded --method dry @common | Out-Null
Check ((Get-Content "$game\doorstop_config.ini") -contains 'enabled = false') 'launch rewrote ini back to enabled = false'

Write-Host "== uninstall -> game folder exactly vanilla"
$o = PP uninstall @common --shortcut-dir (Join-Path $sb 'shortcuts')
$gameFilesAfter = (Get-ChildItem $game -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object) -join "`n"
Check ($gameFilesAfter -eq $gameFilesBefore) 'game folder file list identical to before install'
Check (-not (Test-Path $data)) 'data folder removed'

Write-Host "== foreign loader (manual BepInEx install already in game folder)"
New-Item -ItemType Directory -Force "$game\BepInEx\plugins" | Out-Null
Set-Content "$game\BepInEx\plugins\OldMod.dll" 'old'
Set-Content "$game\winhttp.dll" 'someone elses doorstop'
$o = PP install --manifest $manifest --allow-local --public-key $pubKey @common
Check ($o -match 'already has a mod loader') 'refuses to touch a foreign loader without consent'
$o = PP install --manifest $manifest --allow-local --public-key $pubKey --adopt @common
Check ($o -match 'Moved the old mod loader') 'with --adopt it backs up and takes over'
$bk = Get-ChildItem (Join-Path $sb 'PeakPack-backups') -Directory | Select-Object -First 1
Check ($bk -and (Test-Path "$($bk.FullName)\BepInEx\plugins\OldMod.dll")) 'old files preserved in backup folder'
$o = PP uninstall @common --shortcut-dir (Join-Path $sb 'shortcuts')
Check ($o -match 'backup is still at') 'uninstall points to the backup'
$gameFilesAfter = (Get-ChildItem $game -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object) -join "`n"
Check ($gameFilesAfter -eq $gameFilesBefore) 'game folder vanilla again after uninstall'

Write-Host ""
if ($fails -eq 0) { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green } else { Write-Host "$fails CHECK(S) FAILED" -ForegroundColor Red }
exit $fails
