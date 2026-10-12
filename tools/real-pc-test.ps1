# Real-PC test (NON-DESTRUCTIVE) against Joshua's real PEAK install.
#
# Proves that PeakPack's launch method loads BepInEx from a separate profile folder OUTSIDE the game folder,
# without changing anything in the game folder:
#   Joshua's game folder already has Doorstop (winhttp.dll + doorstop_config.ini, enabled = true, target =
#   BepInEx\core\BepInEx.Preloader.dll). Doorstop 4 reads the ini first and the command line second, and the
#   command line value replaces the ini's target (UnityDoorstop v4.4.0 src/windows/config.c load_config(),
#   load_str_argv()). BepInEx takes its root from the preloader's location (BepInEx v5-lts Entrypoint.cs).
#   So "--doorstop-target-assembly <test profile>\BepInEx\core\BepInEx.Preloader.dll" loads the TEST profile,
#   and Joshua's own BepInEx folder is not loaded at all.
#
# Phases (each one starts PEAK once; the test plugin quits PEAK by itself after a few seconds):
#   A  steam.exe -applaunch 3527290 --doorstop-enabled true --doorstop-target-assembly "<path WITH SPACES>"
#      (exactly what PeakPack runs, via PeakPack.Cli launch --no-proxy)            [always]
#   B  PEAK.exe started directly with SteamAppId set (fallback if Steam prompts)   [-AlsoDirect]
#   C  --doorstop-enabled false: nothing loads, not even Joshua's own BepInEx       [-AlsoVanilla]
#
# Safety:
#   - refuses to start if PEAK.exe is already running; never closes a PEAK it didn't start
#     (it only ever closes a PEAK.exe whose command line contains this test's profile path or "--doorstop-enabled false"
#     AND that started after this script launched it);
#   - snapshots the whole game folder (path, size, timestamp) before and after and reports any difference;
#   - all test files live under sandbox\real-pc-test\.
param(
    [string]$GameDir = 'D:\SteamLibrary\steamapps\common\PEAK',
    [int]$AutoQuitSeconds = 15,
    [int]$TimeoutSeconds = 240,
    [switch]$AlsoDirect,
    [switch]$AlsoVanilla,
    [switch]$SkipSteam,
    [switch]$WithCompanion   # also load PeakPack.Companion (+ a test pack-info.json) in the test profile and check it starts cleanly
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$dn = 'C:\Program Files\dotnet\dotnet.exe'
$work = Join-Path $root 'sandbox\real-pc-test'
$dataDir = Join-Path $work 'PeakPack Test Data'          # deliberately contains spaces
$profileBep = Join-Path $dataDir 'profile\BepInEx'
$preloader = Join-Path $profileBep 'core\BepInEx.Preloader.dll'
$resultJson = Join-Path $dataDir 'profile\real-pc-test-result.json'
$report = Join-Path $work 'report.txt'
$loaderZip = Join-Path $root 'sandbox\publisher\cache\a71432613ab0b2f560046bc341d949c9d853b4f5d5223ab5e7f2ef1f113522e7.bin'
$loaderUrl = 'https://thunderstore.io/package/download/BepInEx/BepInExPack_PEAK/5.4.75301/'
$loaderSha = 'a71432613ab0b2f560046bc341d949c9d853b4f5d5223ab5e7f2ef1f113522e7'
$fails = 0
$lines = New-Object System.Collections.Generic.List[string]
function Say($s, $color = 'Gray') { Write-Host $s -ForegroundColor $color; $script:lines.Add($s) }
function Check($cond, $msg) { if ($cond) { Say "  PASS  $msg" Green } else { Say "  FAIL  $msg" Red; $script:fails++ } }

Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class Win {
  delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public static List<string> Visible() {
    var r = new List<string>();
    EnumWindows((h, l) => { if (IsWindowVisible(h)) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512);
      uint pid; GetWindowThreadProcessId(h, out pid); if (sb.Length > 0) r.Add(pid + "|" + sb); } return true; }, IntPtr.Zero);
    return r;
  }
}
"@

function Get-SteamWindows {
    $steamPids = @(Get-Process steam, steamwebhelper -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    [Win]::Visible() | Where-Object { $steamPids -contains [int]($_.Split('|')[0]) } | ForEach-Object { $_.Split('|', 2)[1] }
}
function Get-PeakProcs { @(Get-CimInstance Win32_Process -Filter "Name='PEAK.exe'" -ErrorAction SilentlyContinue) }
function Snapshot-Game {
    Get-ChildItem -LiteralPath $GameDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object { "{0}|{1}|{2}" -f $_.FullName.Substring($GameDir.Length), $_.Length, $_.LastWriteTimeUtc.Ticks }
}

Say "PeakPack real-PC test  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Say "Game folder: $GameDir"

# ---- preconditions -------------------------------------------------------------------------------
if (Get-PeakProcs) { Say 'PEAK.exe is running. Close PEAK first; this test never closes a game it did not start.' Red; exit 2 }
foreach ($f in 'PEAK.exe', 'winhttp.dll', 'doorstop_config.ini') {
    if (-not (Test-Path -LiteralPath (Join-Path $GameDir $f))) { Say "Missing $f in the game folder; this test expects Joshua's existing Doorstop install." Red; exit 2 }
}
$ini = Get-Content -LiteralPath (Join-Path $GameDir 'doorstop_config.ini')
Say ("Game-folder doorstop_config.ini (read only): " + (($ini | Where-Object { $_ -match '^\s*(enabled|target_assembly)\s*=' }) -join '; '))
Say ("Game-folder .doorstop_version: " + ((Get-Content -LiteralPath (Join-Path $GameDir '.doorstop_version') -ErrorAction SilentlyContinue) -join ''))
$steamExe = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamExe
Say "Steam: $steamExe (running: $([bool](Get-Process steam -ErrorAction SilentlyContinue)))"

# ---- build the test profile (outside the game folder) ----------------------------------------------
Say "`n== preparing test profile: $dataDir"
& $dn build (Join-Path $root 'src\PeakPack.Cli') -v q --nologo | Out-Null
& $dn build (Join-Path $PSScriptRoot 'RealPcTestPlugin') -c Release -v q --nologo "-p:GameDir=$GameDir" | Out-Null
if ($LASTEXITCODE -ne 0) { Say 'test plugin build failed' Red; exit 1 }
$cli = Join-Path $root 'src\PeakPack.Cli\bin\Debug\net10.0-windows\PeakPack.Cli.exe'
if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $profileBep 'plugins\PeakPack-RealPcTest') | Out-Null
if (-not (Test-Path -LiteralPath $loaderZip)) {
    New-Item -ItemType Directory -Force (Split-Path $loaderZip) | Out-Null
    Invoke-WebRequest $loaderUrl -OutFile $loaderZip -UseBasicParsing
}
if ((Get-FileHash -LiteralPath $loaderZip -Algorithm SHA256).Hash.ToLower() -ne $loaderSha) { Say 'BepInExPack_PEAK zip hash mismatch' Red; exit 1 }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($loaderZip)
try {
    foreach ($e in $zip.Entries) {
        if ($e.FullName -match '^BepInExPack_PEAK/BepInEx/(core|config)/(.+)$' -and $e.Name) {
            $dest = Join-Path $profileBep ("{0}\{1}" -f $Matches[1], $Matches[2].Replace('/', '\'))
            New-Item -ItemType Directory -Force (Split-Path $dest) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    }
} finally { $zip.Dispose() }
Copy-Item (Join-Path $PSScriptRoot 'RealPcTestPlugin\bin\Release\PeakPackRealPcTest.dll') (Join-Path $profileBep 'plugins\PeakPack-RealPcTest\')
Set-Content -LiteralPath (Join-Path $profileBep 'plugins\PeakPack-RealPcTest\autoquit-seconds.txt') $AutoQuitSeconds
Check (Test-Path -LiteralPath $preloader) "test profile preloader at $preloader"
if ($WithCompanion) {
    & $dn build (Join-Path $root 'src\PeakPack.Companion') -c Release -v q --nologo "-p:GameDir=$GameDir" | Out-Null
    $comp = Join-Path $root 'src\PeakPack.Companion\bin\Release\PeakPack.Companion.dll'
    New-Item -ItemType Directory -Force (Join-Path $profileBep 'plugins\PeakPack-Companion'), (Join-Path $profileBep 'PeakPack') | Out-Null
    Copy-Item $comp (Join-Path $profileBep 'plugins\PeakPack-Companion\')
    @'
{
  "schema": 1, "packId": "real-pc-test", "packName": "Real PC test", "hostName": "Joshua", "revision": 1,
  "published": "2026-10-11T00:00:00+00:00", "shortcutName": "PEAK (Modded)", "modsRequiredToJoin": false,
  "mismatchPolicy": "warn", "liveSettings": [ "com.joshua.jetpackboost|Boost|ThrustMultiplier" ]
}
'@ | Set-Content -LiteralPath (Join-Path $profileBep 'PeakPack\pack-info.json') -Encoding utf8
    Check (Test-Path -LiteralPath (Join-Path $profileBep 'plugins\PeakPack-Companion\PeakPack.Companion.dll')) 'companion + pack-info.json in the test profile'
}

$before = Snapshot-Game
$hisLog = Join-Path $GameDir 'BepInEx\LogOutput.log'
$hisLogTime = if (Test-Path -LiteralPath $hisLog) { (Get-Item -LiteralPath $hisLog).LastWriteTimeUtc } else { $null }
Say "Game folder snapshot: $($before.Count) files. Joshua's own BepInEx\LogOutput.log last written $hisLogTime (UTC)"

# ---- one launch ----------------------------------------------------------------------------------
function Run-Phase($name, [string[]]$cliArgs, $marker, [bool]$expectLoad) {
    Say "`n== phase $name"
    if (Get-PeakProcs) { Say '  PEAK.exe is running; skipping this phase.' Yellow; return }
    if (Test-Path -LiteralPath $resultJson) { Remove-Item -LiteralPath $resultJson }
    $winBefore = @(Get-SteamWindows)
    $t0 = Get-Date
    # Start-Process + output file (not a pipe): a directly started PEAK.exe inherits the launcher's stdout, and a
    # pipe would make this script wait until PEAK exits.
    $tmpOut = Join-Path $work 'launcher-out.txt'
    $lp = Start-Process -FilePath $cli -ArgumentList ($cliArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $tmpOut
    [void]$lp.WaitForExit(30000)
    Say "  $((Get-Content -LiteralPath $tmpOut -TotalCount 1 -ErrorAction SilentlyContinue))"
    $seenWindows = New-Object System.Collections.Generic.HashSet[string]
    $ourPid = $null; $started = $null; $gone = $false
    while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSeconds) {
        Start-Sleep -Milliseconds 700
        foreach ($w in @(Get-SteamWindows)) { if ($winBefore -notcontains $w -and $seenWindows.Add($w)) { Say "  new Steam window: '$w' (+$([int]((Get-Date) - $t0).TotalSeconds) s)" Yellow } }
        if (-not $ourPid) {
            foreach ($p in Get-PeakProcs) {
                if ($p.CreationDate -lt $t0.AddSeconds(-2)) { continue }
                if ($p.CommandLine -like "*$marker*") {
                    $ourPid = $p.ProcessId; $started = Get-Date
                    Say ("  PEAK.exe started after {0:n1} s, pid {1}" -f ($started - $t0).TotalSeconds, $ourPid)
                    Say "  its command line: $($p.CommandLine)"
                } elseif ($seenWindows.Add("peak-without-args-$($p.ProcessId)")) {
                    Say "  a PEAK.exe WITHOUT our arguments started (pid $($p.ProcessId)): $($p.CommandLine)" Yellow
                    $script:bounced = Get-Date
                }
            }
            if ($script:bounced -and ((Get-Date) - $script:bounced).TotalSeconds -gt 25) { break }
        }
        elseif (-not (Get-Process -Id $ourPid -ErrorAction SilentlyContinue)) { $gone = $true; break }
        if ($ourPid -and -not $expectLoad -and ((Get-Date) - $started).TotalSeconds -gt 45) { break }
        if ($ourPid -and $expectLoad -and ((Get-Date) - $started).TotalSeconds -gt ($AutoQuitSeconds + 90)) { break }
    }
    # Close only what this phase started: PEAK.exe processes created after this phase's launch.
    function Close-Ours {
        foreach ($p in Get-PeakProcs) {
            if ($p.CreationDate -lt $t0.AddSeconds(-2)) { continue }
            $gp = Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue
            if ($gp) { Say "  closing the test instance this phase started (pid $($p.ProcessId))"; [void]$gp.CloseMainWindow(); if (-not $gp.WaitForExit(20000)) { $gp.Kill() } }
        }
    }
    if (-not $ourPid) {
        Say '  PEAK did not start with our arguments (see above: a Steam dialog waiting for a click, or Steam relaunched PEAK without them).' Red
        $script:fails++; Close-Ours; $script:bounced = $null; return
    }
    if (-not $gone) { Close-Ours }
    $script:bounced = $null
    Start-Sleep -Seconds 2
    $res = if (Test-Path -LiteralPath $resultJson) { Get-Content -LiteralPath $resultJson -Raw | ConvertFrom-Json } else { $null }
    if ($expectLoad) {
        Check ($null -ne $res) 'test plugin ran (wrote real-pc-test-result.json)'
        if ($res) {
            Check ($res.bepinexRoot -eq $profileBep) "BepInEx root is the test profile: $($res.bepinexRoot)"
            Check ($res.gameRoot.TrimEnd('\') -eq $GameDir.TrimEnd('\')) "game root is the real game folder: $($res.gameRoot)"
            $i = [array]::IndexOf([string[]]$res.args, '--doorstop-target-assembly')
            Check ($i -ge 0 -and $res.args[$i + 1] -eq $preloader) "path with spaces arrived as ONE argument: '$($res.args[$i + 1])'"
            Say "  game saw args: $($res.args -join ' | ')"
        }
        $log = Join-Path $profileBep 'LogOutput.log'
        $hit = if (Test-Path -LiteralPath $log) { @(Select-String -LiteralPath $log -Pattern 'PEAKPACK-REAL-PC-TEST|BepInEx \d|Chainloader' | ForEach-Object { $_.Line }) } else { @() }
        Check ($hit -match 'PEAKPACK-REAL-PC-TEST loaded') "test profile LogOutput.log has the plugin's line ($log)"
        if ($WithCompanion) {
            $all = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log } else { @() }
            Check (($all -match "PeakPack pack 'real-pc-test' rev 1").Count -gt 0) 'companion loaded and read pack-info.json'
            $compErr = @($all | Where-Object { $_ -match 'PeakPack Companion|PeakPack\]' -and $_ -match 'Error|Exception' })
            Check ($compErr.Count -eq 0) "no companion errors in the log ($($compErr -join ' / '))"
            $all | Where-Object { $_ -match 'PeakPack Companion' } | Select-Object -First 4 | ForEach-Object { Say "    | $_" }
        }
        $hit | Select-Object -First 8 | ForEach-Object { Say "    | $_" }
    } else {
        Check ($null -eq $res) 'no plugin ran (vanilla)'
        $now = if (Test-Path -LiteralPath $hisLog) { (Get-Item -LiteralPath $hisLog).LastWriteTimeUtc } else { $null }
        Check ($now -eq $hisLogTime) "Joshua's own BepInEx did not load either (his LogOutput.log unchanged: $now)"
    }
    if ($expectLoad) {
        $now = if (Test-Path -LiteralPath $hisLog) { (Get-Item -LiteralPath $hisLog).LastWriteTimeUtc } else { $null }
        Check ($now -eq $hisLogTime) "Joshua's own BepInEx was NOT loaded (his LogOutput.log unchanged)"
    }
    Check ($seenWindows.Count -eq 0) "no new Steam window/dialog appeared ($($seenWindows.Count) seen)"
}

$common = @('--game-dir', $GameDir, '--data-dir', $dataDir, '--no-proxy')
if (-not $SkipSteam) { Run-Phase 'A: Steam -applaunch + Doorstop override (what PeakPack does)' (@('launch', '--modded', '--method', 'steam') + $common) 'PeakPack Test Data' $true }
if ($AlsoDirect) { Run-Phase 'B: PEAK.exe directly, SteamAppId env set' (@('launch', '--modded', '--method', 'direct') + $common) 'PeakPack Test Data' $true }
if ($AlsoVanilla) { Run-Phase 'C: Steam -applaunch --doorstop-enabled false' (@('launch', '--vanilla', '--method', 'steam') + $common) '--doorstop-enabled false' $false }

# ---- game folder unchanged? ------------------------------------------------------------------------
$after = Snapshot-Game
$diff = @(Compare-Object $before $after)
Say "`n== game folder"
Check ($diff.Count -eq 0) "game folder unchanged ($($after.Count) files, path+size+timestamp)"
$diff | Select-Object -First 20 | ForEach-Object { Say ("    {0} {1}" -f $_.SideIndicator, $_.InputObject) Yellow }

Say ""
if ($fails -eq 0) { Say 'REAL-PC TEST PASSED' Green } else { Say "$fails CHECK(S) FAILED" Red }
$lines | Set-Content -LiteralPath $report -Encoding utf8
Write-Host "Report: $report"
exit $fails
