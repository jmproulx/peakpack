#!/bin/bash
# TITLE: G-C0 native smoke: Unity 6000.3.15f1 Mac player + PEAK data, (a) stock Windows data, (b) converted Metal shaders
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh. Later slot (slot 4).
#
# Inputs (all inside the job dir):
#   downloads/UnitySetup-Mac-Mono-Support-for-Editor-6000.3.15f1.pkg from Unity's own server (the hub fetches it,
#     or this gate does with --download): expanded with `pkgutil --expand-full`, NEVER installed, never shipped.
#   game/PEAK (G-B5): PEAK_Data is cloned (cp -c, APFS) into player bundles in the job dir.
#   optional --bepinex-zip ZIP (BepInEx 5.4.23.x macOS build, github.com/BepInEx/BepInEx/releases) plus the
#     pack plugins from G-D2's profile, or --harmony-plugin DLL (a HarmonyX test plugin): HarmonyX-on-arm64 check.
# Phase (a) stock data. Assembly recipe v0 (Track C owns refinements, DESIGN §6.1): UnityPlayer.app of the arm64
#   development Mono variation; Data = PEAK_Data minus Managed/Plugins/"unity default resources"; Managed =
#   PEAK's assemblies with the Mac player's 80 UnityEngine.* on top; Mac Mono etc/; minimal Info.plist; ad-hoc
#   signature. Checks: build-target acceptance, main-menu log markers, shader errors (pink expected),
#   DllNotFound list, EOS-absent behaviour, HarmonyX arm64.
# Phase (b) converted shaders (DESIGN §6.3a/b, native/README.md): the converter (native/pm.py, run HERE from the
#   test depot: derived data is never downloaded) writes loose Data files; the second bundle uses them with NO
#   data.unity3d (plus the game's *.resource files). Needs python3 >= 3.11 with UnityPy + lz4 and spirv-cross:
#   detected and reported, never installed (PP_CONVERTER_PYTHON, PEAKMETAL_SPIRV_CROSS or PEAKMETAL_BIN point at
#   them). --converted DIR uses an existing convert output (DIR/Data). Agent: main menu + a level screenshots,
#   looks for y-orientation, depth, sRGB, framebuffer fetch (CoreCopy), instancing artefacts, missing materials.
#   --bundle-variant additionally tries the repacked data.unity3d when the loose run does not reach the menu.
# Paths outside the job dir: Unity's per-user folders for LandCrab/PEAK (prefs plist, Application Support,
# Saved Application State, Caches) - recorded; cleanup.sh removes those that did not exist before the job.
# Args: [--download] [--pkg FILE] [--variation NAME] [--run-seconds N] (default 150) [--bepinex-zip ZIP]
#       [--harmony-plugin DLL] [--phase a|b|m (any combination, default abm)] [--converted DIR] [--bundle-variant]
#       [--jobs N] [--join-test] [--mods-seconds N] (default 90) [--mods-baseline]
# Phase (m) mods on native (DESIGN 6.3f): BepInEx 5 + HarmonyX in the Unity Mac player, universal variation,
#   matrix: (1) native arm64 + BepInEx v5-lts master build (PR #1402) + Doorstop 4.6.0 ci (doorstop_jit_memcpy),
#   (2) the same under Rosetta x86_64 (control), (3) with --mods-baseline: stock BepInEx 5.4.23.5 under Rosetta.
#   Plugins each run: the HarmonyX probe (tests package probe/HarmonyProbe.dll) + JetpackBoost (rev-5 asset).
#   Every input is fetched at job time from its own release and SHA-256 pinned below; Doorstop's settings are
#   passed with `arch -e` (SIP strips exported DYLD_* when exec'ing /usr/bin/arch).
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-C0 "Native smoke (Unity Mac player + PEAK data)"
gate_require_mac
gate_require_gui   # Wine/Unity windows need the logged-in GUI session (blocked otherwise)
UNITY_VER=6000.3.15f1
UNITY_URL="https://download.unity3d.com/download_unity/c1aa84e375f6/MacEditorTargetInstaller/UnitySetup-Mac-Mono-Support-for-Editor-$UNITY_VER.pkg"
UNITY_PKG_BYTES=724929213
UNITY_PKG_MD5_B64=gI5nOkoLtZhU0O48yRsAQQ==   # Unity release API integrity "md5-..." for module mac-mono (DESIGN 6.1a)
pkg="$DL/UnitySetup-Mac-Mono-Support-for-Editor-$UNITY_VER.pkg"; download=0; variation=macos_arm64_player_development_mono
run_s=150; bep_zip=""; hplug=""; phase=abm; converted=""; bundle_variant=0; jobs=""; join_test=0; mods_s=90; mods_baseline=0
while [ $# -gt 0 ]; do
  case "$1" in --download) download=1; shift ;; --pkg) pkg=$2; shift 2 ;; --variation) variation=$2; shift 2 ;;
    --run-seconds) run_s=$2; shift 2 ;; --bepinex-zip) bep_zip=$2; shift 2 ;; --harmony-plugin) hplug=$2; shift 2 ;;
    --phase) phase=$2; shift 2 ;; --converted) converted=$2; shift 2 ;; --bundle-variant) bundle_variant=1; shift ;;
    --jobs) jobs=$2; shift 2 ;; --join-test) join_test=1; shift ;;
    --mods-seconds) mods_s=$2; shift 2 ;; --mods-baseline) mods_baseline=1; shift ;; *) shift ;; esac
done
keep_awake
[ -f "$GAME_DIR/PEAK_Data/data.unity3d" ] || gate_finish_as blocked "PEAK's Windows files are not in the job dir (run G-B5 first)"
if [ ! -f "$pkg" ]; then
  [ "$download" = 1 ] || gate_finish_as blocked "Unity Mac Mono support pkg not in downloads/ (the hub downloads $UNITY_URL, or re-run with --download)"
  log "downloading the Unity Mac Mono support pkg from Unity's server (725 MB)"
  fetch_url "$UNITY_URL" "$pkg" || gate_finish_as blocked "download from download.unity3d.com failed"
fi
psz=$(file_size "$pkg"); metric unity_pkg_bytes "$psz"; metric unity_pkg_sha256 "$(sha256_of "$pkg")" str
version_set unity_player "$UNITY_VER $variation"
[ "$psz" = "$UNITY_PKG_BYTES" ] && crit unity_pkg pass "Unity pkg size matches DESIGN §6.1" "$psz bytes" || crit unity_pkg warn "Unity pkg size matches DESIGN §6.1 ($UNITY_PKG_BYTES)" "$psz bytes"
pm5=$(openssl dgst -md5 -binary "$pkg" 2>/dev/null | base64); metric unity_pkg_md5_b64 "$pm5" str
[ "$pm5" = "$UNITY_PKG_MD5_B64" ] && crit unity_pkg_md5 pass "pkg MD5 matches Unity's published integrity" "$pm5" || crit unity_pkg_md5 fail "pkg MD5 matches Unity's published integrity ($UNITY_PKG_MD5_B64)" "$pm5"
pkgutil --check-signature "$pkg" > "$GLOG/pkg-signature.txt" 2>&1 && crit unity_pkg_sig pass "pkg signature valid" "$(grep -m1 -i 'unity' "$GLOG/pkg-signature.txt" | tr -s ' ')" || crit unity_pkg_sig fail "pkg signature valid" "$(head -3 "$GLOG/pkg-signature.txt" | tr '\n' ' ')"

# ---- expand (no install)
X="$JOB/unity/expanded"
if [ ! -d "$X" ]; then mkdir -p "$JOB/unity"; pkgutil --expand-full "$pkg" "$X" > "$GLOG/pkgutil.log" 2>&1 || gate_finish_as error "pkgutil --expand-full failed (logs/G-C0/pkgutil.log)"; fi
VAR=$(find "$X" -type d -name Variations -path '*MacStandaloneSupport*' 2>/dev/null | head -1)
[ -n "$VAR" ] && [ -d "$VAR/$variation/UnityPlayer.app" ] || gate_finish_as error "no Variations/$variation/UnityPlayer.app in the expanded pkg"
MSS=$(dirname "$VAR")
crit expanded pass "pkg expanded into the job dir (not installed)" "$(rel_to_job "$VAR")"
ls "$VAR" > "$GLOG/variations.txt"
pv=$(head -1 "$GAME_DIR/version.txt" 2>/dev/null | tr -d '\r ')
mkdir -p "$JOB/native"
clone() { cp -c -R "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; }

# ---- Steam for the native player: Valve's macOS libsteam_api (universal) from Steamworks.NET 2024.8.0, the
# exact Steamworks.NET version PEAK ships (SDK 1.61). Fetched at job time from its GitHub release (MIT repo,
# Valve redistributable); never redistributed by us. Installed unmodified (Valve's signature intact).
SWN_URL=https://github.com/rlabrecque/Steamworks.NET/releases/download/2024.8.0/Steamworks.NET-Standalone_2024.8.0.zip
SWN_SHA256=08094d1372c6d793d6b5b87c59f1362a10fe8580acb1db6bfaf081a511f6758c   # verified-local 12 Oct 2026, 892008 bytes
steam_bundle=""
swn_zip="$DL/Steamworks.NET-Standalone_2024.8.0.zip"
if [ -s "$swn_zip" ] || fetch_url "$SWN_URL" "$swn_zip"; then
  if [ "$(sha256_of "$swn_zip")" = "$SWN_SHA256" ]; then
    rm -rf "$JOB/native/swn" && mkdir -p "$JOB/native/swn"
    unzip -o -q "$swn_zip" 'OSX-Linux-x64/steam_api.bundle/*' -d "$JOB/native/swn" 2>> "$GLOG/steam-lib.log"
    steam_bundle="$JOB/native/swn/OSX-Linux-x64/steam_api.bundle"
    find "$steam_bundle" -name '*.meta' -delete 2>/dev/null
    if [ -f "$steam_bundle/Contents/MacOS/libsteam_api.dylib" ]; then
      crit steam_lib pass "Valve libsteam_api (Steamworks.NET 2024.8.0) fetched and verified" "$(lipo -archs "$steam_bundle/Contents/MacOS/libsteam_api.dylib" 2>/dev/null || file -b "$steam_bundle/Contents/MacOS/libsteam_api.dylib" | cut -c1-80)"
    else steam_bundle=""; crit steam_lib fail "libsteam_api.dylib extracted" "see logs/G-C0/steam-lib.log"; fi
  else crit steam_lib fail "Steamworks.NET zip SHA-256" "got $(sha256_of "$swn_zip")"; rm -f "$swn_zip"; fi
else crit steam_lib fail "Steamworks.NET zip download" "$SWN_URL"; fi

# assemble APP DATA_SRC  (DATA_SRC: "stock" = PEAK_Data; else a convert output Data dir, used without data.unity3d)
assemble() {
  local app=$1 src=$2 d e b r m n_mac=0
  rm -rf "$app"; cp -R "$VAR/$variation/UnityPlayer.app" "$app"
  d="$app/Contents/Resources/Data"; mkdir -p "$d/Managed" "$d/Resources"
  if [ "$src" = stock ]; then
    for e in "$GAME_DIR"/PEAK_Data/*; do
      b=$(basename "$e")
      case "$b" in Managed|Plugins) continue ;;
        Resources) for r in "$e"/*; do [ "$(basename "$r")" = "unity default resources" ] || clone "$r" "$d/Resources/"; done; continue ;; esac
      clone "$e" "$d/"
    done
  else
    for e in "$src"/*; do
      b=$(basename "$e")
      case "$b" in Managed|Plugins|data.unity3d) continue ;;
        Resources) for r in "$e"/*; do [ "$(basename "$r")" = "unity default resources" ] || clone "$r" "$d/Resources/"; done; continue ;; esac
      clone "$e" "$d/"
    done
    # the archive's companions (*.resource, StreamingAssets, json, boot.config) come from the game
    for e in "$GAME_DIR"/PEAK_Data/*; do
      b=$(basename "$e")
      case "$b" in Managed|Plugins|Resources|data.unity3d) continue ;; esac
      [ -e "$d/$b" ] || clone "$e" "$d/"
    done
    rm -f "$d/data.unity3d"
  fi
  cp "$GAME_DIR"/PEAK_Data/Managed/* "$d/Managed/"
  for m in "$VAR"/mono/Managed/*.dll; do [ -f "$m" ] && { cp "$m" "$d/Managed/"; n_mac=$(( n_mac + 1 )); }; done
  ASM_N_MAC=$n_mac
  if [ -d "$MSS/MonoBleedingEdge/etc" ]; then mkdir -p "$app/Contents/MonoBleedingEdge"; cp -R "$MSS/MonoBleedingEdge/etc" "$app/Contents/MonoBleedingEdge/"; fi
  cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleExecutable</key><string>UnityPlayer</string>
 <key>CFBundleIdentifier</key><string>com.peakpack.testkit.native</string>
 <key>CFBundleName</key><string>PEAK native smoke</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>${pv:-0}</string>
 <key>CFBundleVersion</key><string>1</string>
 <key>NSPrincipalClass</key><string>PlayerApplication</string>
 <key>NSHighResolutionCapable</key><true/>
 <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict></plist>
EOF
  plutil -lint "$app/Contents/Info.plist" > /dev/null 2>&1 || return 1
  # Steam: PEAK's Steamworks.NET was built for Windows and imports "steam_api64"; offer the macOS library under
  # every name Unity's Mono may probe (bundle and dylib, PlugIns and Frameworks). App id for SteamAPI_Init and
  # so RestartAppIfNecessary does not relaunch through Steam.
  if [ -n "$steam_bundle" ]; then
    mkdir -p "$app/Contents/PlugIns"
    cp -R "$steam_bundle" "$app/Contents/PlugIns/steam_api64.bundle"
    cp -R "$steam_bundle" "$app/Contents/PlugIns/steam_api.bundle"
    cp "$steam_bundle/Contents/MacOS/libsteam_api.dylib" "$app/Contents/PlugIns/libsteam_api64.dylib"
    cp "$steam_bundle/Contents/MacOS/libsteam_api.dylib" "$app/Contents/Frameworks/libsteam_api64.dylib"
  fi
  printf '3527290\n' > "$app/Contents/MacOS/steam_appid.txt"
  xattr -cr "$app" 2>/dev/null
  # Re-sign only Unity's own dylibs; Valve's libsteam_api keeps its own signature.
  for e in "$app"/Contents/Frameworks/*.dylib; do
    case "$(basename "$e")" in libsteam_api64.dylib) continue ;; esac
    [ -f "$e" ] && codesign --force -s - "$e" >> "$GLOG/codesign.log" 2>&1
  done
  codesign --force -s - "$app" >> "$GLOG/codesign.log" 2>&1
  codesign --verify --deep --strict "$app" >> "$GLOG/codesign.log" 2>&1
}

# Unity's per-user folders (both phases use the same bundle id)
for p in "$HOME/Library/Preferences/unity.$UNITY_COMPANY.$UNITY_PRODUCT.plist" "$HOME/Library/Application Support/unity.$UNITY_COMPANY.$UNITY_PRODUCT" \
         "$HOME/Library/Application Support/$UNITY_COMPANY" "$HOME/Library/Saved Application State/com.peakpack.testkit.native.savedState" \
         "$HOME/Library/Caches/com.peakpack.testkit.native" "$HOME/Library/Caches/$UNITY_COMPANY" "$HOME/Library/Logs/$UNITY_COMPANY"; do
  preexisted "$p" || outside_record "$p" created-by-us "Unity Mac player per-user data (G-C0); removed by cleanup.sh if present"
done
stop_player() { pkill -TERM -U "$(id -u)" -f "$JOB/native/.*/Contents/MacOS/UnityPlayer" 2>/dev/null; sleep 3; pkill -KILL -U "$(id -u)" -f "$JOB/native/.*/Contents/MacOS/UnityPlayer" 2>/dev/null; return 0; }
GATE_CLEANUP=stop_player

# run_player APP TAG -> player log in logs/G-C0/<TAG>-player.log; RUN_ALIVE=1 when it was still running at the end
run_player() {
  local app=$1 tag=$2 t0 ppid plog="$GLOG/$2-player.log"
  t0=$(now_s)
  # SteamAppId/SteamGameId + cwd = Contents/MacOS (steam_appid.txt): Steam treats the run as app 3527290.
  if [ "$bep" = 1 ] && [ "$tag" = a ] && [ -f "$JOB/native/run_bepinex.sh" ]; then
    ( cd "$JOB/native" && SteamAppId=3527290 SteamGameId=3527290 bash ./run_bepinex.sh "$app" -logFile "$plog" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 ) > "$GLOG/$tag-run.out" 2>&1 &
  else
    ( cd "$app/Contents/MacOS" && SteamAppId=3527290 SteamGameId=3527290 ./UnityPlayer -logFile "$plog" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 ) > "$GLOG/$tag-run.out" 2>&1 &
  fi
  ppid=$!
  sleep 45
  snap "native-$tag-45s"
  RUN_PPID=$ppid; RUN_T0=$t0
}
finish_player() {  # TAG
  while kill -0 "$RUN_PPID" 2>/dev/null && [ $(( $(now_s) - RUN_T0 )) -lt "$run_s" ]; do sleep 5; done
  RUN_ALIVE=0; kill -0 "$RUN_PPID" 2>/dev/null && RUN_ALIVE=1
  metric "$1_alive_after_s" "$(( $(now_s) - RUN_T0 ))"; metric "$1_still_running" "$RUN_ALIVE"
  snap "native-$1-end"
  stop_player
  wait "$RUN_PPID" 2>/dev/null
}
# analyse LOG PREFIX (criterion ids get the prefix: a_..., b_...)
analyse() {
  local plog=$1 p=$2 bt mm m
  [ -f "$plog" ] || { crit "${p}player_log" fail "phase $p: the player wrote a log" "none (crashed before logging?) - see logs/G-C0/${p%_}-run.out"; return 1; }
  bt=$(grep -a -c 'created for another build target' "$plog" | tr -d ' ')
  metric "${p}build_target_errors" "$bt"
  [ "$bt" = 0 ] && crit "${p}build_target" pass "phase ${p%_}: data accepted by the Mac player (no build-target error)" || crit "${p}build_target" fail "phase ${p%_}: data accepted by the Mac player" "$bt build-target error line(s)"
  mm=0; for m in "Loaded Server Settings" "Photon StartPeerCreated" "Has Valid Quicksave"; do grep -a -q -F "$m" "$plog" && mm=$(( mm + 1 )); done
  metric "${p}main_menu_markers" "$mm"
  [ "$mm" -ge 2 ] && crit "${p}main_menu" pass "phase ${p%_}: game scripts reach the main menu (log markers)" "$mm of 3" || crit "${p}main_menu" fail "phase ${p%_}: game scripts reach the main menu (log markers)" "$mm of 3"
  grep -a -E -i "shader.*(error|not supported|unsupported)|(error|failed).*shader" "$plog" > "$GLOG/${p}shader-errors.txt"
  metric "${p}shader_error_lines" "$(wc -l < "$GLOG/${p}shader-errors.txt" | tr -d ' ')"
  grep -a -o -E "DllNotFoundException: [^ ]+|Unable to load DLL '[^']+'|Failed to load '[^']+'|Fallback handler could not load library [^ ]+" "$plog" | sort | uniq -c | sort -rn > "$GLOG/${p}dllnotfound.txt"
  metric "${p}dllnotfound_unique" "$(wc -l < "$GLOG/${p}dllnotfound.txt" | tr -d ' ')"
  metric "${p}dllnotfound_list" "$(awk '{ $1 = ""; print }' "$GLOG/${p}dllnotfound.txt" | tr '\n' ';' | cut -c1-900)" str
  metric "${p}crash_markers" "$(grep -a -c -E 'Crash!!!|SIGSEGV|SIGBUS|Got a SIG' "$plog" | tr -d ' ')"
  grep -a -q "Update current scene: Airport" "$plog" && metric "${p}reached_airport" true || metric "${p}reached_airport" false
  analyse_online "$plog" "$p"
  return 0
}
# EOS-absent behaviour, Steam and lobbies (observe and record only: nothing is stubbed or patched).
# EOS sign-in creates the online player id, so whether Steam lobbies still work without EOS is the key finding.
analyse_online() {
  local plog=$1 p=$2 n v
  grep -a -n -i -E "EOS|Epic|EOSSDK|Sanction|ProductUser|PlatformInterface|UserManager" "$plog" | head -80 > "$GLOG/${p}eos-lines.txt"
  n=$(wc -l < "$GLOG/${p}eos-lines.txt" | tr -d ' '); metric "${p}eos_line_count" "$n"
  metric "${p}eos_first_lines" "$(head -5 "$GLOG/${p}eos-lines.txt" | cut -c1-200 | tr '\n' ';' | cut -c1-900)" str
  grep -a -q -i -E "EOSSDK.*(DllNotFound|Unable to load|not found)|DllNotFoundException: EOSSDK" "$plog" && metric "${p}eos_library_missing" true || metric "${p}eos_library_missing" false
  crit "${p}eos_absent" info "phase ${p%_}: EOS-absent behaviour recorded (all EOS/Epic lines in logs/G-C0/${p}eos-lines.txt)" "$n line(s); first: $(head -1 "$GLOG/${p}eos-lines.txt" | cut -c1-160)"
  # Steam
  v=$(grep -a -o -E "Steam runtime manager initialized: (True|False)" "$plog" | tail -1)
  metric "${p}steam_runtime" "${v:-not logged}" str
  grep -a -q "Steam Lobby Handler initialized" "$plog" && metric "${p}steam_lobby_handler" true || metric "${p}steam_lobby_handler" false
  case "$v" in *True) crit "${p}steam_init" pass "phase ${p%_}: Steamworks initialised in the native player" "$v" ;;
    *False) crit "${p}steam_init" fail "phase ${p%_}: Steamworks initialised in the native player" "$v" ;;
    *) crit "${p}steam_init" info "phase ${p%_}: Steamworks init line" "not logged (see dllnotfound list for steam_api64)" ;; esac
  # Lobbies (SteamLobbyHandler's own log lines)
  grep -a -n -E "Lobby Created: |Entered Steam Lobby: |Joining lobby: |Set Photon Region to steam lobby data|Set current scene to: |Failed to (set|fetch) (steam )?lobby|Not in a lobby|Game version mismatch|Steam invite detected" "$plog" > "$GLOG/${p}lobby-lines.txt"
  metric "${p}lobby_created" "$(grep -a -c 'Lobby Created: ' "$plog" | tr -d ' ')"
  metric "${p}lobby_entered" "$(grep -a -c 'Entered Steam Lobby: ' "$plog" | tr -d ' ')"
  metric "${p}lobby_joining" "$(grep -a -c 'Joining lobby: ' "$plog" | tr -d ' ')"
  metric "${p}lobby_errors" "$(grep -a -c -E 'Failed to (set|fetch) (steam )?lobby|Not in a lobby' "$plog" | tr -d ' ')"
  metric "${p}lobby_lines" "$(head -8 "$GLOG/${p}lobby-lines.txt" | cut -c1-160 | tr '\n' ';' | cut -c1-900)" str
  grep -a -n -i -E "photon.*(connect|disconnect|auth|failed)|CustomAuthentication|OnJoinedRoom|OnCreatedRoom" "$plog" | head -40 > "$GLOG/${p}photon-lines.txt"
  metric "${p}photon_line_count" "$(wc -l < "$GLOG/${p}photon-lines.txt" | tr -d ' ')"
}

bep=0
# ================= phase (a): stock Windows data =================
if case "$phase" in *a*) true ;; *) false ;; esac; then
  APP_A="$JOB/native/a-stock/PEAK.app"; mkdir -p "$(dirname "$APP_A")"
  if assemble "$APP_A" stock; then crit a_assemble pass "phase a: bundle assembled, Info.plist valid, ad-hoc signature verifies" "$ASM_N_MAC Mac UnityEngine assemblies"
  else crit a_assemble fail "phase a: bundle assembled and signed" "see logs/G-C0/codesign.log"; fi
  metric mac_unityengine_assemblies "$ASM_N_MAC"
  metric exe_archs "$(file -b "$APP_A/Contents/MacOS/UnityPlayer" | tr '\n' ' ')" str
  # optional BepInEx (HarmonyX on arm64), installed next to the bundle inside the job dir
  if [ -n "$bep_zip" ] && [ -f "$bep_zip" ]; then
    ditto -x -k "$bep_zip" "$JOB/native" > "$GLOG/bepinex-unzip.log" 2>&1 && bep=1
    if [ "$bep" = 1 ]; then
      mkdir -p "$JOB/native/BepInEx/plugins"
      prof="$(peakpack_win_dir 2>/dev/null)/profile/BepInEx/plugins"
      [ -d "$prof" ] && { cp -R "$prof"/. "$JOB/native/BepInEx/plugins/"; note "pack plugins copied from G-D2's profile for the HarmonyX check"; }
      [ -n "$hplug" ] && [ -f "$hplug" ] && cp "$hplug" "$JOB/native/BepInEx/plugins/"
      for f in "$JOB"/native/*.dylib "$JOB"/native/doorstop_libs/*.dylib; do [ -f "$f" ] && codesign --force -s - "$f" >> "$GLOG/codesign.log" 2>&1; done
      version_set bepinex_mac "$(basename "$bep_zip")"
    fi
  fi
  run_player "$APP_A" a
  cu_request look 120 "Phase a: a window 'PEAK native smoke' (Unity Mac player with PEAK's stock Windows data) should be open. Screenshot: bash testkit/cu.sh \$JOB shot G-C0 native-a-window. Describe it: black, pink/magenta surfaces (expected: no Metal shaders yet), a recognisable PEAK main menu (even pink), an error dialog, or nothing (crashed). Answer ok <description> (any of these is data, not a failure), or skip if nothing appeared. Do not click in the window."
  finish_player a
  analyse "$GLOG/a-player.log" a_   # also records EOS-absent lines, Steam init and lobby lines (analyse_online)
  crit a_dllnotfound info "native plugins that failed to load (expected: EOSSDK, opus_egpv, AudioIn, webrtc-audio, MemoryWrapper; steam_api64 should load)" "$(wc -l < "$GLOG/a_dllnotfound.txt" 2>/dev/null | tr -d ' ') unique"
  if [ "$bep" = 1 ]; then
    bl="$JOB/native/BepInEx/LogOutput.log"
    if [ -f "$bl" ]; then
      cp "$bl" "$GLOG/LogOutput-native.log"
      he=$(grep -a -c -i -E "harmony.*(exception|error|fail)|mprotect|EACCES|SIGILL" "$bl" | tr -d ' ')
      hl=$(grep -a -c '\] Loading \[' "$bl" | tr -d ' ')
      metric harmony_error_lines "$he"; metric native_plugins_loaded "$hl"
      if grep -a -q "Chainloader startup complete" "$bl" && [ "$he" = 0 ]; then crit a_harmonyx_arm64 pass "BepInEx + HarmonyX run on arm64 Mono" "$hl plugins loaded, no Harmony errors"
      else crit a_harmonyx_arm64 fail "BepInEx + HarmonyX run on arm64 Mono" "chainloader complete: $(grep -a -c 'Chainloader startup complete' "$bl"), harmony errors: $he"; fi
    else crit a_harmonyx_arm64 fail "BepInEx wrote LogOutput.log" "none (Doorstop did not inject?)"; fi
  else
    crit a_harmonyx_arm64 skip "HarmonyX on arm64" "no --bepinex-zip given"
  fi
fi

# ================= phase (b): converted Metal shaders, loose files =================
if case "$phase" in *b*) true ;; *) false ;; esac; then
  out="$JOB/native/convert"
  if [ -n "$converted" ]; then
    [ -d "$converted/Data" ] && out=$converted || crit b_converter fail "phase b: --converted has a Data/ folder" "$converted"
  elif [ ! -d "$out/Data" ]; then
    # Preferred: the self-contained converter bundle (CI prerelease mac-build-native-tools-<ver>: CPython,
    # hash-locked UnityPy/lz4, spirv-cross, our converter; no game data). Extracted into the job dir only.
    nt_tag=${PP_NATIVE_TOOLS_TAG:-mac-build-native-tools-0.2.0}; nt_ver=${nt_tag#mac-build-native-tools-}
    nt_name="peakpack-native-tools-$nt_ver-macos-arm64"; nt_base="https://github.com/$PP_REPO/releases/download/$nt_tag"
    nt_dir="$JOB/native/tools/$nt_name"
    if [ ! -x "$nt_dir/bin/pm" ]; then
      mkdir -p "$JOB/native/tools"
      if fetch_url "$nt_base/$nt_name.tar.xz" "$DL/$nt_name.tar.xz" && fetch_url "$nt_base/$nt_name.tar.xz.sha256" "$DL/$nt_name.tar.xz.sha256"; then
        want=$(awk 'NR == 1 { print tolower($1) }' "$DL/$nt_name.tar.xz.sha256"); have=$(sha256_of "$DL/$nt_name.tar.xz")
        if [ "$want" = "$have" ]; then tar -xJf "$DL/$nt_name.tar.xz" -C "$JOB/native/tools"
        else crit b_tools_sha fail "phase b: converter bundle SHA-256" "got $have, release says $want"; fi
      else note "converter bundle $nt_tag not downloadable; falling back to a local converter environment"; fi
    fi
    if [ -x "$nt_dir/bin/pm" ]; then
      "$nt_dir/bin/pm" doctor > "$GLOG/pm-doctor.log" 2>&1; drc=$?; metric converter_doctor_exit "$drc"; metric converter_bundle "$nt_tag" str
      if [ "$drc" = 0 ]; then crit b_tools pass "phase b: converter bundle $nt_ver present and pm doctor ok" "$(tail -1 "$GLOG/pm-doctor.log" | cut -c1-120)"
      else crit b_tools fail "phase b: converter bundle pm doctor" "exit $drc (logs/G-C0/pm-doctor.log)"; fi
    fi
    # detect the converter environment (never install)
    py=${PP_CONVERTER_PYTHON:-}; [ -n "$py" ] || py=$(python3_path 2>/dev/null)
    pm="$PP_KIT_DIR/../native/pm.py"
    why=""
    if [ -x "$nt_dir/bin/pm" ] && [ "${drc:-1}" = 0 ]; then
      log "converting PEAK's shaders on this Mac with the bundle (loose files; derived data stays in the job dir)"
      t0=$(now_s)
      "$nt_dir/bin/pm" convert "$GAME_DIR/PEAK_Data/data.unity3d" --out "$out" \
          --mode "$( [ "$bundle_variant" = 1 ] && echo both || echo loose )" ${jobs:+--jobs "$jobs"} > "$GLOG/convert.log" 2>&1
      rc=$?; metric convert_s "$(( $(now_s) - t0 ))"; metric convert_exit "$rc"
      cp "$out/convert_report.txt" "$out/convert_summary.json" "$GLOG/" 2>/dev/null
      # 0 = ok, 3 = finished with fallbacks listed in convert_summary.json (still usable)
      if { [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && [ -d "$out/Data" ]; then crit b_convert pass "phase b: converter produced loose Data files (bundle)" "exit $rc; $(tail -1 "$GLOG/convert.log" | cut -c1-160)"
      else crit b_convert fail "phase b: converter produced loose Data files (bundle)" "exit $rc (logs/G-C0/convert.log)"; fi
      why="__done__"
    fi
    if [ "$why" != "__done__" ]; then   # fallback: a local converter environment (no bundle)
    [ -f "$pm" ] || why="$why native/pm.py not next to the kit (repo layout mac/native);"
    if [ -z "$py" ] || [ ! -x "$py" ]; then why="$why no python3 (Xcode CLT or Homebrew; PP_CONVERTER_PYTHON);"
    else
      pyv=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null); metric converter_python "$py $pyv" str
      "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null || why="$why python $pyv < 3.10;"
      "$py" -I -c 'import UnityPy, lz4' 2>/dev/null || why="$why UnityPy/lz4 not importable;"
    fi
    sc=${PEAKMETAL_SPIRV_CROSS:-}; [ -n "$sc" ] || { [ -n "${PEAKMETAL_BIN:-}" ] && sc="$PEAKMETAL_BIN/spirv-cross"; }; [ -n "$sc" ] || sc=$(command -v spirv-cross 2>/dev/null)
    [ -n "$sc" ] && [ -x "$sc" ] || why="$why no spirv-cross (PEAKMETAL_SPIRV_CROSS / PEAKMETAL_BIN / PATH);"
    if [ -n "$why" ]; then
      crit b_converter skip "phase b: shader converter environment present" "missing:$why (detected only; see NOTES-for-lead.md R10)"
    else
      log "converting PEAK's shaders on this Mac (loose files; derived data stays in the job dir)"
      t0=$(now_s)
      ( cd "$PP_KIT_DIR/../native" && PEAKMETAL_SPIRV_CROSS="$sc" "$py" -I pm.py convert "$GAME_DIR/PEAK_Data/data.unity3d" --out "$out" \
          --mode "$( [ "$bundle_variant" = 1 ] && echo both || echo loose )" ${jobs:+--jobs "$jobs"} ) > "$GLOG/convert.log" 2>&1
      rc=$?; metric convert_s "$(( $(now_s) - t0 ))"; metric convert_exit "$rc"
      cp "$out/convert_report.txt" "$GLOG/" 2>/dev/null
      if { [ "$rc" = 0 ] || [ "$rc" = 3 ]; } && [ -d "$out/Data" ]; then crit b_convert pass "phase b: converter produced loose Data files" "exit $rc; $(tail -1 "$GLOG/convert.log" | cut -c1-200)"
      else crit b_convert fail "phase b: converter produced loose Data files" "exit $rc (logs/G-C0/convert.log)"; fi
    fi
    fi   # end fallback
  fi
  if [ -d "$out/Data" ]; then
    APP_B="$JOB/native/b-converted/PEAK.app"; mkdir -p "$(dirname "$APP_B")"
    if assemble "$APP_B" "$out/Data"; then crit b_assemble pass "phase b: bundle with converted loose files (no data.unity3d), signed"
    else crit b_assemble fail "phase b: bundle assembled and signed"; fi
    [ -f "$APP_B/Contents/Resources/Data/data.unity3d" ] && crit b_no_archive fail "phase b: no data.unity3d next to the loose files" || crit b_no_archive pass "phase b: no data.unity3d next to the loose files"
    run_player "$APP_B" b
    cu_request menu 240 "Phase b (converted Metal shaders): when PEAK's main menu shows, screenshot: bash testkit/cu.sh \$JOB shot G-C0 native-b-menu. Then click Play and wait for the Airport lobby (up to 2 min); screenshot native-b-level. Look for and report: upside-down or mirrored image (y orientation), objects drawn through each other (depth), washed-out or too dark colours (sRGB), black/garbled full-screen copies (framebuffer fetch, CoreCopy), flickering or repeated objects (instancing), pink/missing materials. Answer: ok menu=<yes|no> level=<yes|no> yflip=<ok|bad> depth=<ok|bad> srgb=<ok|bad> fbfetch=<ok|bad> instancing=<ok|bad> missing=<none|list>, or fail <what happened> if it crashed or stayed black."
    cub=$?; visual_note=$CU_NOTE; visual_ans=$CU_ANSWER
    for k in menu level yflip depth srgb fbfetch instancing missing; do v=$(cu_kv "$k"); [ -n "$v" ] && metric "b_visual_$k" "$v" str; done
    # Key finding: does a Steam lobby still work without EOS (EOS sign-in creates the online player id)?
    # Clicking Play hosts: PEAK creates a Photon room + Steam lobby ("Lobby Created: <id>" in Player.log).
    cu_request lobby 180 "Phase b, Steam lobby without EOS: you should now be in the Airport after clicking Play (if not, click Play on the main menu now and wait up to 2 min). Screenshot native-b-lobby. Note any error or 'offline'/'connection' message shown in the game. Answer ok hosted=<yes|no> message=<text or none>, or fail <what happened>."
    cul=$?; lobby_hosted=$(cu_kv hosted); lobby_msg=$(cu_kv message); lobby_ans=$CU_ANSWER
    [ -n "$lobby_hosted" ] && metric b_lobby_hosted_agent "$lobby_hosted" str; [ -n "$lobby_msg" ] && metric b_lobby_message "$lobby_msg" str
    if [ "$join_test" = 1 ]; then
      # Needs Joshua at his Windows PC (his own Steam account and PEAK); nobody types credentials anywhere.
      cu_request join 900 "NEEDS JOSHUA (join test): ask Joshua, on his Windows PC with PEAK running, to open his Steam friends list, right-click the Mac's account and choose Join Game (or type the room code shown in the Mac's pause menu). Wait until he is in or reports an error (up to 10 min). Screenshot native-b-join on the Mac. Answer ok joined=<yes|no> windows_message=<what Joshua saw> mac_message=<what the Mac showed>, or skip if Joshua is not available."
      cuj=$?; join_joined=$(cu_kv joined); join_win=$(cu_kv windows_message); join_mac=$(cu_kv mac_message); join_ans=$CU_ANSWER; join_note=$CU_NOTE
      [ -n "$join_joined" ] && metric b_join_joined "$join_joined" str; [ -n "$join_win" ] && metric b_join_windows_message "$join_win" str; [ -n "$join_mac" ] && metric b_join_mac_message "$join_mac" str
    fi
    finish_player b
    analyse "$GLOG/b-player.log" b_
    case $cub in 0) crit b_visual pass "phase b: renders without crash/black screen (agent; visual findings in metrics b_visual_*)" "$visual_note" ;; 1) crit b_visual fail "phase b: renders without crash/black screen (agent)" "$visual_note" ;; *) crit b_visual skip "phase b: agent's visual check" "$visual_ans" ;; esac
    lc=$(grep -a -c 'Lobby Created: ' "$GLOG/b-player.log" 2>/dev/null | tr -d ' ')
    if [ "${lc:-0}" -gt 0 ]; then crit b_lobby_create pass "phase b: Steam lobby created WITHOUT EOS (key finding)" "$(grep -a -m1 'Lobby Created: ' "$GLOG/b-player.log" | cut -c1-120)"
    elif [ "$cul" = 0 ]; then crit b_lobby_create fail "phase b: Steam lobby created WITHOUT EOS (key finding)" "no 'Lobby Created' line; agent: hosted=$lobby_hosted message=$lobby_msg; see logs/G-C0/b_lobby-lines.txt, b_eos-lines.txt"
    else crit b_lobby_create skip "phase b: Steam lobby created without EOS" "agent could not run the step ($lobby_ans)"; fi
    if [ "$join_test" = 1 ]; then
      case $cuj in
        0) if [ "$join_joined" = yes ]; then crit b_lobby_join pass "phase b: Windows player joined the native Mac lobby without EOS (key finding)" "$join_win"
           else crit b_lobby_join fail "phase b: Windows player joined the native Mac lobby without EOS (key finding)" "windows: $join_win; mac: $join_mac"; fi ;;
        3|2) crit b_lobby_join skip "phase b: join test" "Joshua not available ($join_ans)" ;;
        *) crit b_lobby_join fail "phase b: join test" "$join_note" ;;
      esac
    else
      crit b_lobby_join skip "phase b: join test (needs Joshua at his Windows PC)" "not requested (pass --join-test when Joshua is available)"
    fi
    if [ "$bundle_variant" = 1 ] && crit_failed b_main_menu && [ -f "$out/data.unity3d" ]; then
      APP_C="$JOB/native/c-bundle/PEAK.app"; mkdir -p "$(dirname "$APP_C")"
      assemble "$APP_C" stock && rm -f "$APP_C/Contents/Resources/Data/data.unity3d" && clone "$out/data.unity3d" "$APP_C/Contents/Resources/Data/" \
        && codesign --force -s - "$APP_C" >> "$GLOG/codesign.log" 2>&1
      run_player "$APP_C" c
      finish_player c
      analyse "$GLOG/c-player.log" c_
    fi
  elif ! crit_failed b_convert; then
    note "phase b not run (converter environment missing); phase a results stand alone"
  fi
fi
# ================= phase (m): mods on native (BepInEx 5 + HarmonyX), arm64 vs Rosetta =================
# Pins (DESIGN 6.3f). Fetched at job time from the projects' own releases; nothing redistributed by the kit.
BEPM_TAG=mac-build-bepinex5-f4c1b110
BEPM_URL="https://github.com/$PP_REPO/releases/download/$BEPM_TAG/BepInEx_macos_universal_v5lts-f4c1b110.zip"
BEPM_SHA256=0ec5aa3326e9363ba11d783282d01467dff90f526482531df687f9091e09b74a       # our CI build of upstream v5-lts f4c1b110 (PR #1402), MIT, Doorstop removed
DS46_URL=https://github.com/NeighTools/UnityDoorstop/releases/download/ci/doorstop_macos_release_4.6.0.zip
DS46_SHA256=22790b63ef25a3737eb4a80dfe49ea80cfce3bb2f48689ef19dc11bcdd390c6f   # ci tag @3035af7, has doorstop_jit_memcpy
BEPS_URL=https://github.com/BepInEx/BepInEx/releases/download/v5.4.23.5/BepInEx_macos_universal_5.4.23.5.zip
BEPS_SHA256=01c2ae782eb016dfd6c345a18dbd2dcafffb3d9d318449d6486689f426b4a323   # stock 5.4.23.5 (Doorstop 4.5.0 inside)
JB_URL="https://github.com/$PP_REPO/releases/download/rev-5/Joshua-JetpackBoost-90c792a7-JetpackBoost.dll"
JB_SHA256=90c792a7744d99d566293e59d787ad4d2aebdaee6a0c6bd0c70cd967f29a9751
if case "$phase" in *m*) true ;; *) false ;; esac; then
  mvar=macos_x64arm64_player_development_mono   # universal: the same bundle runs native arm64 and under Rosetta
  if [ ! -d "$VAR/$mvar/UnityPlayer.app" ]; then
    crit m_player skip "phase m: universal player variation" "no $mvar in the pkg"
  else
    # get FILE URL SHA -> $DL/<FILE>, verified; 0 ok
    mget() { local f="$DL/$1"; { [ -f "$f" ] && [ "$(sha256_of "$f")" = "$3" ]; } && return 0
      fetch_url "$2" "$f" || { log "download failed: $2"; return 1; }
      [ "$(sha256_of "$f")" = "$3" ] || { log "SHA-256 mismatch: $1 ($(sha256_of "$f"))"; mv "$f" "$f.bad"; return 1; }; }
    hp=""; ensure_tests >/dev/null 2>&1 && [ -f "${TESTS:-/nonexistent}/probe/HarmonyProbe.dll" ] && hp="$TESTS/probe/HarmonyProbe.dll"
    [ -n "$hp" ] || note "phase m: no HarmonyProbe.dll in the Steam test kit (needs mac-build-steam-tests-1.2.0+); JetpackBoost only"
    jb=""; mget JetpackBoost.dll "$JB_URL" "$JB_SHA256" && jb="$DL/JetpackBoost.dll"
    bepm=""; [ "$BEPM_SHA256" != "__BEPM_SHA256__" ] && mget "$(basename "$BEPM_URL")" "$BEPM_URL" "$BEPM_SHA256" && bepm="$DL/$(basename "$BEPM_URL")"
    ds46=""; mget "$(basename "$DS46_URL")" "$DS46_URL" "$DS46_SHA256" && ds46="$DL/$(basename "$DS46_URL")"
    beps=""; [ "$mods_baseline" = 1 ] && mget "$(basename "$BEPS_URL")" "$BEPS_URL" "$BEPS_SHA256" && beps="$DL/$(basename "$BEPS_URL")"
    metric m_inputs "probe=$([ -n "$hp" ] && echo y || echo n) jetpack=$([ -n "$jb" ] && echo y || echo n) bepinex_master=$([ -n "$bepm" ] && echo y || echo n) doorstop46=$([ -n "$ds46" ] && echo y || echo n) stock=$([ -n "$beps" ] && echo y || echo n)" str
    VAR_SAVE=$variation; variation=$mvar
    APP_U="$JOB/native/m-universal/PEAK.app"; mkdir -p "$(dirname "$APP_U")"
    if assemble "$APP_U" stock; then crit m_assemble pass "phase m: universal bundle assembled and signed" "$(file -b "$APP_U/Contents/MacOS/UnityPlayer" | cut -c1-120)"
    else crit m_assemble fail "phase m: universal bundle assembled and signed" "see logs/G-C0/codesign.log"; fi
    variation=$VAR_SAVE
    # mods_run CONFIG ARCH BEPZIP DOORSTOPZIP(or "") -> crit m_<CONFIG>
    mods_run() {
      local c=$1 a=$2 bz=$3 dz=$4 root="$JOB/native/m-$1" plog="$GLOG/m-$1-player.log" t0 pid bl he pr ar jl
      rm -rf "$root"; mkdir -p "$root"
      clone "$APP_U" "$root/PEAK.app"
      ditto -x -k "$bz" "$root" > "$GLOG/m-$c-unzip.log" 2>&1 || { crit "m_$c" fail "phase m $c: unzip BepInEx" "logs/G-C0/m-$c-unzip.log"; return; }
      if [ -n "$dz" ]; then ditto -x -k "$dz" "$root/.ds" >> "$GLOG/m-$c-unzip.log" 2>&1 && cp "$root/.ds/universal/libdoorstop.dylib" "$root/libdoorstop.dylib"; fi
      [ -f "$root/libdoorstop.dylib" ] || { crit "m_$c" fail "phase m $c: libdoorstop.dylib present" "missing"; return; }
      codesign --force -s - "$root/libdoorstop.dylib" >> "$GLOG/codesign.log" 2>&1
      mkdir -p "$root/BepInEx/plugins"
      [ -n "$hp" ] && cp "$hp" "$root/BepInEx/plugins/"
      [ -n "$jb" ] && cp "$jb" "$root/BepInEx/plugins/"
      xattr -cr "$root" 2>/dev/null
      t0=$(now_s)
      ( cd "$root/PEAK.app/Contents/MacOS" && arch -"$a" \
          -e DYLD_INSERT_LIBRARIES="$root/libdoorstop.dylib" -e DOORSTOP_ENABLED=1 \
          -e DOORSTOP_TARGET_ASSEMBLY="$root/BepInEx/core/BepInEx.Preloader.dll" -e DOORSTOP_IGNORE_DISABLED_ENV=0 \
          -e DOORSTOP_MONO_DLL_SEARCH_PATH_OVERRIDE= -e DOORSTOP_MONO_DEBUG_ENABLED=0 -e DOORSTOP_MONO_DEBUG_SUSPEND=0 \
          -e DOORSTOP_MONO_DEBUG_ADDRESS=127.0.0.1:10000 -e DOORSTOP_BOOT_CONFIG_OVERRIDE= \
          -e DOORSTOP_CLR_RUNTIME_CORECLR_PATH=.dylib -e DOORSTOP_CLR_CORLIB_DIR= \
          -e SteamAppId=3527290 -e SteamGameId=3527290 \
          ./UnityPlayer -logFile "$plog" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 ) > "$GLOG/m-$c-run.out" 2>&1 &
      pid=$!
      while kill -0 "$pid" 2>/dev/null && [ $(( $(now_s) - t0 )) -lt "$mods_s" ]; do
        grep -a -q "Chainloader startup complete" "$root/BepInEx/LogOutput.log" 2>/dev/null && [ $(( $(now_s) - t0 )) -ge 30 ] && break
        sleep 3
      done
      stop_player; wait "$pid" 2>/dev/null
      bl="$root/BepInEx/LogOutput.log"
      [ -f "$bl" ] && cp "$bl" "$GLOG/m-$c-LogOutput.log"
      find "$root" -maxdepth 5 -name 'preloader_*.log' -exec sh -c 'cp "$1" "$2/m-$3-$(basename "$1")"' _ {} "$GLOG" "$c" \; 2>/dev/null
      he=$(cat "$bl" "$root"/PEAK.app/Contents/MacOS/preloader_*.log "$root"/preloader_*.log 2>/dev/null | grep -a -c -i -E "harmony.*(exception|error|fail)|mprotect|EACCES|GetIdentifiable|AppleSilicon.*(fail|could not)" | tr -d ' ')
      pr=$(grep -a -o "HARMONYPROBE RESULT [A-Z]*.*" "$bl" 2>/dev/null | tail -1)
      ar=$(grep -a -o "HARMONYPROBE start .*arch=[A-Za-z0-9]*" "$bl" 2>/dev/null | sed 's/.*arch=//' | tail -1)
      jl=$(grep -a -c "JetpackBoost 0.1.0 loaded" "$bl" 2>/dev/null | tr -d ' ')
      metric "m_${c}_chainloader" "$(grep -a -c 'Chainloader startup complete' "$bl" 2>/dev/null | tr -d ' ')"
      metric "m_${c}_probe" "${pr:-none}" str; metric "m_${c}_arch" "${ar:-unknown}" str
      metric "m_${c}_jetpack_loaded" "${jl:-0}"; metric "m_${c}_harmony_error_lines" "${he:-0}"
      metric "m_${c}_plugins_loaded" "$(grep -a -c '\] Loading \[' "$bl" 2>/dev/null | tr -d ' ')"
      if grep -a -q "Chainloader startup complete" "$bl" 2>/dev/null && { [ -z "$hp" ] || [ "${pr#HARMONYPROBE RESULT }" = PASS ]; } \
         && { [ -z "$jb" ] || [ "${jl:-0}" -ge 1 ]; }; then
        crit "m_$c" pass "phase m $c: BepInEx + HarmonyX + JetpackBoost on the native Mac player ($a)" "arch=${ar:-?} probe=${pr:-n/a} jetpack=${jl:-0}"
      else
        crit "m_$c" fail "phase m $c: BepInEx + HarmonyX + JetpackBoost on the native Mac player ($a)" "chainloader=$(grep -a -c 'Chainloader startup complete' "$bl" 2>/dev/null) probe=${pr:-none} jetpack=${jl:-0} harmony_errors=${he:-0} (logs/G-C0/m-$c-*)"
      fi
    }
    if [ -n "$bepm" ] && [ -n "$ds46" ]; then
      mods_run arm64-master arm64 "$bepm" "$ds46"
      mods_run x64-master x86_64 "$bepm" "$ds46"
    else
      crit m_arm64-master skip "phase m: master builds available" "BepInEx master build or Doorstop 4.6.0 missing (see m_inputs)"
    fi
    [ -n "$beps" ] && mods_run x64-stock x86_64 "$beps" ""
    # Verdict for DESIGN 6.3f: native arm64 mods, else the Rosetta x86_64 fallback
    if grep -q '^{"id": "m_arm64-master", "result": "pass"' "$GTMP/criteria.jsonl" 2>/dev/null; then metric m_verdict native-arm64 str
    elif grep -q '^{"id": "m_x64-master", "result": "pass"' "$GTMP/criteria.jsonl" 2>/dev/null; then metric m_verdict rosetta-x86_64-fallback str
    else metric m_verdict none str; fi
  fi
fi
gate_end
