#!/bin/bash
# TITLE: G-A1 runtime boots: assets verified, prefix created in the job dir, wineboot, cmd/reg/regedit, D3D11 via DXMT
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# 1. Download + verify (SHA256SUMS) the runtime, manifest and Steam test kit of the release.
# 2. Unpack the runtime; with the Xcode CLT also run the runtime's own verify_runtime.sh (static checks).
# 3. pp-create-prefix.sh <runtime> <job>/prefix dxmt (wineboot --init, sandboxed user folders, reg imports, DXMT).
# 4. wine cmd /c ver; reg query of the PEAK.exe overrides and the Mac driver key; regedit /E export.
# 5. D3D11 render check: probes/d3d11_clear.exe run AS "PEAK.exe" (so the production PEAK.exe-scoped
#    DllOverrides apply), logs mode. Pass = device + read-back OK, non-builtin d3d11.dll + winemetal.dll
#    loaded (DXMT). If the probe exe is not available yet, the check is deferred to PEAK's main menu
#    render in G-B2/G-D2 (criterion "skip"). The script screenshots the probe window itself; no CU step.
# Must run inside the logged-in GUI (Aqua) session: from a remote shell Wine's Mac driver cannot open
# windows, so the gate ends BLOCKED (exit 2) up front after recording the session + winemac.so diagnostics.
# Diagnostics (to tell "no GUI session" from "winemac.so does not load"): launchctl managername,
# WindowServer, console user, winemac.so load commands resolved on this Mac (with the CLT), and the
# prefix boot + probe run with WINEDEBUG=err+all,warn+module,warn+macdrv,+winediag,+loaddll.
# Args: [--probe PATH_TO_d3d11_clear.exe] [--keep-wine]
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-A1 "Runtime boots"
gate_require_mac
probe=""; keep=0
while [ $# -gt 0 ]; do case "$1" in --probe) probe=$2; shift 2 ;; --keep-wine) keep=1; shift ;; *) shift ;; esac; done
rosetta_ok || gate_finish_as blocked "Rosetta 2 is not installed (P0)"
keep_awake
stop_all() { [ "$keep" = 1 ] || wine_stop; }
GATE_CLEANUP=stop_all

# ---- 1. assets
if ensure_sums; then crit sums pass "SHA256SUMS downloaded" "$(release_tag): $(asset_names | wc -l | tr -d ' ') assets listed"; cp "$DL/SHA256SUMS" "$GLOG/"
else gate_finish_as blocked "release $(release_tag) not reachable (no SHA256SUMS at $(release_base))"; fi
if ensure_runtime; then crit runtime_asset pass "runtime tarball verified and unpacked" "$(basename "$RT")"
else gate_finish_as error "runtime asset missing or SHA-256 mismatch (see logs/G-A1/console.log)"; fi
if ensure_manifest; then crit manifest_asset pass "manifest verified"; else crit manifest_asset warn "manifest-*.json not in the release"; fi
if ensure_tests; then crit tests_asset pass "Steam test kit available" "$(basename "$TESTS")"; else crit tests_asset warn "Steam test kit not available (G-B gates will be blocked)"; fi
wv=$(pp_wine normal --version 2>/dev/null | tr -d '\r'); version_set wine "$wv"; metric wine_version "$wv" str
case "$wv" in wine-*) crit wine_version pass "wine --version" "$wv" ;; *) crit wine_version fail "wine --version" "${wv:-no output}" ;; esac
du -sk "$RT" 2>/dev/null | awk '{ printf "%d\n", $1/1024 }' > "$GTMP/rtmb"; metric runtime_mb "$(cat "$GTMP/rtmb")"
for f in lib/wine/x86_64-unix/lsteamclient.so lib/wine/x86_64-windows/lsteamclient.dll share/peakpack/steam/steamclient64.dll share/peakpack/steam/peakpack_steam_launcher.exe lib/peakpack/dxmt/x86_64-windows/d3d11.dll lib/wine/x86_64-windows/winemetal.dll; do
  if [ -f "$RT/$f" ]; then crit "rt_$(basename "$f")" pass "runtime has $f"; else crit "rt_$(basename "$f")" fail "runtime has $f"; fi
done

# ---- 2. static runtime checks (needs CLT: lipo/otool/nm/strings/python3)
if clt_ok && [ -f "$RT/manifest.json" ] && [ -f "${PP_KIT_DIR}/../runtime/build/verify_runtime.sh" ]; then
  if bash "$PP_KIT_DIR/../runtime/build/verify_runtime.sh" "$RT" > "$GLOG/verify_runtime.log" 2>&1; then crit verify_runtime pass "verify_runtime.sh (static)" "ALL PASS"
  else crit verify_runtime fail "verify_runtime.sh (static)" "$(grep '^FAIL' "$GLOG/verify_runtime.log" | head -3 | tr '\n' ';')"; fi
else
  why=""; clt_ok || why="$why no-CLT"; [ -f "$RT/manifest.json" ] || why="$why no-runtime-manifest.json"
  [ -f "${PP_KIT_DIR}/../runtime/build/verify_runtime.sh" ] || why="$why no-$(cd "$PP_KIT_DIR/.." && pwd)/runtime/build/verify_runtime.sh(kit-only-download)"
  crit verify_runtime skip "verify_runtime.sh (static)" "skipped:$why (CI already ran it for this release)"
fi

# ---- 2b. Mac driver diagnostics: GUI session vs winemac.so loading (recorded before any window is needed)
gs=$(gui_session); metric gui_session "$gs" str
if pgrep -x WindowServer >/dev/null 2>&1; then metric windowserver_running true; else metric windowserver_running false; fi
metric console_user "$(stat -f %Su /dev/console 2>/dev/null)" str
metric run_user "$(id -un)" str
wm="$RT/lib/wine/x86_64-unix/winemac.so"
if [ ! -f "$wm" ]; then crit winemac_so fail "runtime has winemac.so" "missing $wm"
elif clt_ok; then
  if macho_links_resolve "$wm" > "$GLOG/winemac-links.txt" 2>&1; then crit winemac_links pass "winemac.so load commands resolve on this Mac" "$(grep -c '^ok ' "$GLOG/winemac-links.txt") non-system libs found"
  else crit winemac_links fail "winemac.so load commands resolve on this Mac" "$(grep '^MISSING' "$GLOG/winemac-links.txt" | head -3 | tr '\n' ';')"; fi
else crit winemac_links skip "winemac.so load commands resolve on this Mac" "needs the Xcode CLT (otool); the boot trace below still shows a dlopen failure"; fi
if ! gui_session_ok; then
  gate_require_gui   # ends the gate: blocked, exit 2, with how to start inside the GUI session
fi
[ "$gs" = Aqua ] && crit gui_session pass "running inside the logged-in GUI (Aqua) session" "$gs" || crit gui_session warn "GUI session" "managername=$gs but PP_ASSUME_GUI=1"
# Wine debug channels for the boot and the probe (the runtime's pp-env.sh honours PP_WINEDEBUG)
export PP_WINEDEBUG="err+all,warn+module,warn+macdrv,+winediag,+loaddll,fixme-all"
macdrv_state() {  # macdrv_state LOGFILE -> ok | unixlib-load-failed | no-driver | not-loaded
  local f=$1
  if grep -a -i -E 'winemac\.so.*(fail|error|not loaded|image not found)|(fail|error).*winemac\.so' "$f" >/dev/null 2>&1; then echo unixlib-load-failed
  elif grep -a -E 'nodrv_CreateWindow|graphics driver is missing' "$f" >/dev/null 2>&1; then echo no-driver
  elif grep -a -E 'Loaded L".*winemac\.drv"' "$f" >/dev/null 2>&1; then echo ok
  else echo not-loaded; fi
}

# ---- 3. prefix
t0=$(now_s)
if ensure_prefix; then crit prefix_create pass "pp-create-prefix.sh created the prefix in the job dir" "$(( $(now_s) - t0 )) s"
else tail -40 "$GLOG/create-prefix.log"; crit prefix_create fail "pp-create-prefix.sh" "see logs/G-A1/create-prefix.log"; gate_end; fi
metric prefix_create_s "$(( $(now_s) - t0 ))"
[ -f "$PFX/system.reg" ] && crit wineboot pass "wineboot wrote system.reg" || crit wineboot fail "wineboot wrote system.reg"
if [ -f "$GLOG/create-prefix.log" ]; then
  ms=$(macdrv_state "$GLOG/create-prefix.log"); metric macdrv_boot "$ms" str
  grep -a -E 'winemac|macdrv|winediag|nodrv_|explorer' "$GLOG/create-prefix.log" | head -40 > "$GLOG/macdrv-boot-excerpt.txt"
  case "$ms" in ok) crit macdrv_boot pass "Mac driver loaded during wineboot" ;; *) crit macdrv_boot fail "Mac driver loaded during wineboot" "$ms (logs/G-A1/macdrv-boot-excerpt.txt)" ;; esac
fi
stamp="$PFX/peakpack/prefix.json"
[ -f "$stamp" ] && grep -q "\"backend\": *\"dxmt\"" "$stamp" && crit prefix_stamp pass "prefix stamp: backend dxmt" "$(tr -d '\n' < "$stamp")" || crit prefix_stamp fail "prefix stamp with backend dxmt"
if cmp -s "$RT/lib/peakpack/dxmt/x86_64-windows/d3d11.dll" "$PFX/drive_c/windows/system32/d3d11.dll"; then crit dxmt_installed pass "system32/d3d11.dll is DXMT's"; else crit dxmt_installed fail "system32/d3d11.dll is DXMT's"; fi
wu=$(wine_user); metric wine_user "$wu" str
sandboxed=1; for d in Desktop Documents Downloads; do [ -L "$PFX/drive_c/users/$wu/$d" ] && sandboxed=0; done
[ "$sandboxed" = 1 ] && crit sandbox pass "user shell folders are real folders (no links to the Mac home)" || crit sandbox fail "user shell folders are real folders"
du -sk "$PFX" 2>/dev/null | awk '{ printf "%d\n", $1/1024 }' > "$GTMP/pfxmb"; metric prefix_mb "$(cat "$GTMP/pfxmb")"

# ---- 4. cmd / reg / regedit
out=$(pp_wine normal cmd /c ver 2>"$GLOG/cmd.err" | tr -d '\r'); printf '%s\n' "$out" > "$GLOG/cmd-ver.txt"
case "$out" in *Windows*) crit cmd_ver pass "wine cmd /c ver" "$(printf '%s' "$out" | grep -m1 Windows)" ;; *) crit cmd_ver fail "wine cmd /c ver" "$(head -c 200 "$GLOG/cmd.err")" ;; esac
q=$(pp_wine normal reg query 'HKCU\Software\Wine\AppDefaults\PEAK.exe\DllOverrides' 2>/dev/null | tr -d '\r'); printf '%s\n' "$q" > "$GLOG/reg-peak-overrides.txt"
printf '%s' "$q" | grep -qi 'winhttp.*native,builtin' && crit reg_winhttp pass "PEAK.exe winhttp=native,builtin" || crit reg_winhttp fail "PEAK.exe winhttp=native,builtin"
printf '%s' "$q" | grep -qi 'd3d11.*native,builtin' && crit reg_d3d11 pass "PEAK.exe d3d11=native,builtin (DXMT)" || crit reg_d3d11 fail "PEAK.exe d3d11=native,builtin"
q2=$(pp_wine normal reg query 'HKCU\Software\Wine\Mac Driver' 2>/dev/null | tr -d '\r'); printf '%s\n' "$q2" > "$GLOG/reg-macdriver.txt"
printf '%s' "$q2" | grep -qi 'RetinaMode.*n' && crit reg_retina pass "Mac Driver RetinaMode=n" || crit reg_retina fail "Mac Driver RetinaMode=n"
pp_wine normal regedit /E 'C:\pp-wine-export.reg' 'HKEY_CURRENT_USER\Software\Wine' >/dev/null 2>&1
exp="$PFX/drive_c/pp-wine-export.reg"
if [ -s "$exp" ]; then
  LC_ALL=C tr -d '\000' < "$exp" > "$GLOG/regedit-export-hkcu-wine.reg"; rm -f "$exp"
  grep -qi 'AppDefaults\\PEAK\.exe' "$GLOG/regedit-export-hkcu-wine.reg" && crit regedit pass "regedit /E export contains the PEAK.exe AppDefaults" || crit regedit fail "regedit /E export contains the PEAK.exe AppDefaults"
else crit regedit fail "regedit /E produced an export"; fi
wine_stop

# ---- 5. D3D11 via DXMT
[ -n "$probe" ] || for c in "${TESTS:-/nonexistent}/probe/d3d11_clear.exe" "$PP_KIT_DIR/probes/out/d3d11_clear.exe" "$PP_KIT_DIR/probes/d3d11_clear.exe"; do [ -f "$c" ] && { probe=$c; break; }; done
if [ -z "$probe" ]; then
  crit d3d11_render skip "D3D11 renders through DXMT" "no d3d11_clear.exe yet (NOTES-for-lead.md R1); DXMT proof deferred to PEAK's main menu in G-B2/G-D2"
  metric dxmt_proof deferred str
  gate_end
fi
pdir="$PFX/drive_c/PeakPackTests/dxprobe"; mkdir -p "$pdir"; cp "$probe" "$pdir/PEAK.exe"
metric probe_sha256 "$(sha256_of "$probe")" str
( sleep 8; snap d3d11-probe-window ) &
snap_pid=$!
pp_wine logs 'C:\PeakPackTests\dxprobe\PEAK.exe' --frames 600 --width 1280 --height 720 --hold-ms 8000 > "$GLOG/d3d11-probe.out" 2>&1; prc=$?
wait "$snap_pid" 2>/dev/null
tr -d '\r' < "$GLOG/d3d11-probe.out" > "$GLOG/d3d11-probe.txt"
rv() { sed -n "s/^RESULT $1=//p" "$GLOG/d3d11-probe.txt" | tail -1; }
mp=$(macdrv_state "$GLOG/d3d11-probe.txt"); metric macdrv_probe "$mp" str
grep -a -E 'winemac|macdrv|winediag|nodrv_' "$GLOG/d3d11-probe.txt" | head -40 > "$GLOG/macdrv-probe-excerpt.txt"
[ "$mp" = ok ] || note "probe run: Mac driver state $mp (logs/G-A1/macdrv-probe-excerpt.txt)"
metric probe_exit "$prc"; metric adapter "$(rv adapter)" str; metric feature_level "$(rv feature_level)" str
metric fps "$(rv fps)"; metric frames "$(rv frames)"; metric swap_effect "$(rv swap_effect)" str
metric d3d11_path "$(rv d3d11_path)" str
dx_logs=$(find "$GLOG/wine" -type f 2>/dev/null | grep -E -i -c 'd3d11|dxgi|dxmt' | tr -d ' ')
metric dxmt_log_files "${dx_logs:-0}"
[ "$(rv device)" = ok ] && crit d3d11_device pass "D3D11 device + swap chain" "$(rv adapter), FL $(rv feature_level), $(rv swap_effect)" || crit d3d11_device fail "D3D11 device + swap chain" "create_hr=$(rv create_hr)"
[ "$(rv readback_ok)" = 1 ] && crit d3d11_readback pass "cleared colour reads back" "$(rv readback)" || crit d3d11_readback fail "cleared colour reads back" "$(rv readback) vs $(rv readback_expected)"
if [ "$(rv d3d11_wine_builtin)" = 0 ] && [ "$(rv winemetal_loaded)" = 1 ]; then
  crit d3d11_dxmt pass "DXMT handled it (native-style d3d11.dll + winemetal.dll loaded)" "$(rv d3d11_path)"
  metric dxmt_proof probe str
else
  crit d3d11_dxmt fail "DXMT handled it (native-style d3d11.dll + winemetal.dll loaded)" "builtin=$(rv d3d11_wine_builtin) winemetal=$(rv winemetal_loaded)"
fi
[ "$(rv present_failures)" = 0 ] && crit d3d11_present pass "all frames presented" "$(rv frames) frames, $(rv fps) fps" || crit d3d11_present fail "all frames presented" "$(rv present_failures) failures"
gate_end
