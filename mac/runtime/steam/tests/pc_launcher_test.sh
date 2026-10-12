#!/bin/bash
# pc_launcher_test.sh - safe test of peakpack_steam_launcher.exe on a Windows
# developer PC that has a REAL Steam install. Part of PeakPack for Mac.
#
# Never touches HKCU\Software\Valve, the Steam install or any game: it uses
#   - --dry-run (prints actions only),
#   - --registry-root Software\PeakPackTest (throwaway key, deleted at the end),
#   - a fake Steam dir in a temp folder, and cmd.exe as the stand-in "game".
# It also checks that the launcher refuses real-registry mode outside Wine.
#
# Usage: pc_launcher_test.sh <launcher.exe> <steamclient64.dll forwarder> [tmpdir]
set -uo pipefail
# $1 is run directly; Windows paths for arguments come from cygpath
fwd=$(cygpath -w "$2")
tmp=${3:-$(mktemp -d)}
mkdir -p "$tmp/FakeSteam"
fake=$(cygpath -w "$tmp/FakeSteam")
root='Software\PeakPackTest'
pass=0; fail=0
ok()   { echo "PASS: $*"; pass=$((pass+1)); }
bad()  { echo "FAIL: $*"; fail=$((fail+1)); }
regq() { MSYS2_ARG_CONV_EXCL='*' reg query "$@" 2>/dev/null; }

valve_before=$(MSYS2_ARG_CONV_EXCL='*' reg query 'HKCU\Software\Valve\Steam\ActiveProcess' 2>/dev/null | md5sum)

# 1. refuse real registry outside Wine (writes nothing)
MSYS2_ARG_CONV_EXCL='*' "$1" 'C:\Windows\System32\cmd.exe' /c exit 0 >"$tmp/t1.log" 2>&1; rc=$?
[ $rc = 121 ] && grep -q "refusing: not running under Wine" "$tmp/t1.log" && ok "refuses real registry outside Wine (rc $rc)" || bad "real-mode refusal (rc $rc)"

# 2. refuse a test root under Software\Valve
MSYS2_ARG_CONV_EXCL='*' "$1" --registry-root 'Software\Valve\Steam' --no-launch >"$tmp/t2.log" 2>&1; rc=$?
[ $rc = 120 ] && ok "refuses --registry-root under Software\\Valve" || bad "Valve root refusal (rc $rc)"

# 3. dry run of the real plan for PEAK (nothing written, nothing launched)
MSYS2_ARG_CONV_EXCL='*' "$1" --dry-run --forwarder-src "$fwd" --connect-lobby 109775241234567890 --language english \
    -- 'D:\SteamLibrary\steamapps\common\PEAK\PEAK.exe' -force-d3d11 --doorstop-enabled true \
    --doorstop-target-assembly 'C:\Games\PEAK\BepInEx\core\BepInEx.Preloader.dll' >"$tmp/t3.log" 2>&1; rc=$?
cat "$tmp/t3.log"
if [ $rc = 0 ] && grep -q '\[dry-run\] set HKCU\\Software\\Valve\\Steam\\ActiveProcess  SteamClientDll64' "$tmp/t3.log" \
   && grep -q '+connect_lobby 109775241234567890' "$tmp/t3.log" && grep -q 'refusing to install the forwarder outside Wine' "$tmp/t3.log"; then
    ok "dry run prints the full plan, refuses to touch the real Steam dir"
else bad "dry run (rc $rc)"; fi

# 4. throwaway registry root + fake Steam dir + cmd.exe as the game
MSYS2_ARG_CONV_EXCL='*' "$1" --registry-root "$root" --steam-dir "$fake" --forwarder-src "$fwd" --keep-registry \
    --steam-client-dir '/Users/test/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS' \
    -- 'C:\Windows\System32\cmd.exe' /c 'echo GAME_ENV appid=%SteamAppId% gameid=%SteamGameId% compat=%STEAM_COMPAT_CLIENT_INSTALL_PATH%& exit 7' \
    >"$tmp/t4.log" 2>&1; rc=$?
cat "$tmp/t4.log"
[ $rc = 7 ] && ok "game exit code propagated (7)" || bad "exit code $rc"
grep -q 'GAME_ENV appid=3527290 gameid=3527290 compat=/Users/test/Library' "$tmp/t4.log" && ok "SteamAppId/SteamGameId/STEAM_COMPAT_CLIENT_INSTALL_PATH reach the game" || bad "game env"
[ -f "$tmp/FakeSteam/steamclient64.dll" ] && cmp -s "$tmp/FakeSteam/steamclient64.dll" "$2" && ok "forwarder installed into the (fake) Steam dir" || bad "forwarder install"
q=$(regq "HKCU\\$root\\HKCU\\Software\\Valve\\Steam\\ActiveProcess")
echo "$q"
echo "$q" | grep -q 'SteamClientDll64.*REG_SZ.*FakeSteam\\steamclient64.dll' && ok "SteamClientDll64 written under the test root" || bad "SteamClientDll64"
echo "$q" | grep -Eq 'pid +REG_DWORD +0x[1-9a-f]' && ok "pid kept (--keep-registry)" || bad "pid"
q=$(regq "HKCU\\$root\\HKCU\\Software\\Valve\\Steam\\Apps\\3527290")
echo "$q" | grep -Eq 'Installed +REG_DWORD +0x1' && echo "$q" | grep -Eq 'Updating +REG_DWORD +0x0' && ok "Apps\\3527290 Installed/Updating" || bad "Apps key"
regq "HKCU\\$root\\HKLM\\Software\\Valve\\Steam" | grep -q 'InstallPath' && ok "HKLM InstallPath redirected under test root" || bad "HKLM InstallPath"

# 5. cleanup path: pid reset + Running=0, then delete the test root
MSYS2_ARG_CONV_EXCL='*' "$1" --registry-root "$root" --steam-dir "$fake" --forwarder-src "$fwd" --no-launch --hold-ms 200 >"$tmp/t5.log" 2>&1
q=$(regq "HKCU\\$root\\HKCU\\Software\\Valve\\Steam\\ActiveProcess")
echo "$q" | grep -Eq 'pid +REG_DWORD +0x0$' && ok "pid reset to 0 at exit" || bad "pid reset"
regq "HKCU\\$root\\HKCU\\Software\\Valve\\Steam\\Apps\\3527290" | grep -Eq 'Running +REG_DWORD +0x0' && ok "Running reset to 0 at exit" || bad "Running reset"
MSYS2_ARG_CONV_EXCL='*' "$1" --registry-root "$root" --steam-dir "$fake" --no-install --no-launch --delete-test-root >"$tmp/t6.log" 2>&1
regq "HKCU\\$root" >/dev/null && bad "test root still present" || ok "test root HKCU\\$root deleted"

valve_after=$(MSYS2_ARG_CONV_EXCL='*' reg query 'HKCU\Software\Valve\Steam\ActiveProcess' 2>/dev/null | md5sum)
[ "$valve_before" = "$valve_after" ] && ok "real HKCU\\Software\\Valve\\Steam\\ActiveProcess unchanged" || bad "REAL VALVE KEY CHANGED"

echo "== $pass passed, $fail failed (logs in $tmp)"
[ $fail = 0 ]
