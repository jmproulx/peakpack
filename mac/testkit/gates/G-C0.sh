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
#   PEAK's assemblies with the Mac player's 160 UnityEngine.* on top; Mac Mono etc/; minimal Info.plist; ad-hoc
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
#       [--harmony-plugin DLL] [--phase a|b|ab] (default ab) [--converted DIR] [--bundle-variant] [--jobs N]
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
gate_begin G-C0 "Native smoke (Unity Mac player + PEAK data)"
gate_require_mac
UNITY_VER=6000.3.15f1
UNITY_URL="https://download.unity3d.com/download_unity/c1aa84e375f6/MacEditorTargetInstaller/UnitySetup-Mac-Mono-Support-for-Editor-$UNITY_VER.pkg"
UNITY_PKG_BYTES=724929213
pkg="$DL/UnitySetup-Mac-Mono-Support-for-Editor-$UNITY_VER.pkg"; download=0; variation=macos_arm64_player_development_mono
run_s=150; bep_zip=""; hplug=""; phase=ab; converted=""; bundle_variant=0; jobs=""
while [ $# -gt 0 ]; do
  case "$1" in --download) download=1; shift ;; --pkg) pkg=$2; shift 2 ;; --variation) variation=$2; shift 2 ;;
    --run-seconds) run_s=$2; shift 2 ;; --bepinex-zip) bep_zip=$2; shift 2 ;; --harmony-plugin) hplug=$2; shift 2 ;;
    --phase) phase=$2; shift 2 ;; --converted) converted=$2; shift 2 ;; --bundle-variant) bundle_variant=1; shift ;;
    --jobs) jobs=$2; shift 2 ;; *) shift ;; esac
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
  xattr -cr "$app" 2>/dev/null
  for e in "$app"/Contents/Frameworks/*.dylib; do [ -f "$e" ] && codesign --force -s - "$e" >> "$GLOG/codesign.log" 2>&1; done
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
  if [ "$bep" = 1 ] && [ "$tag" = a ] && [ -f "$JOB/native/run_bepinex.sh" ]; then
    ( cd "$JOB/native" && bash ./run_bepinex.sh "$app" -logFile "$plog" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 ) > "$GLOG/$tag-run.out" 2>&1 &
  else
    "$app/Contents/MacOS/UnityPlayer" -logFile "$plog" -screen-fullscreen 0 -screen-width 1280 -screen-height 720 > "$GLOG/$tag-run.out" 2>&1 &
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
  return 0
}

bep=0
# ================= phase (a): stock Windows data =================
if [ "$phase" != b ]; then
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
  analyse "$GLOG/a-player.log" a_
  grep -a -i -E "EOS|Epic" "$GLOG/a-player.log" 2>/dev/null | head -20 > "$GLOG/eos-lines.txt"
  crit a_dllnotfound info "native plugins that failed to load (expected: EOS, steam_api64, opus_egpv, AudioIn, ...)" "$(wc -l < "$GLOG/a_dllnotfound.txt" 2>/dev/null | tr -d ' ') unique"
  crit a_eos_absent info "EOS-absent behaviour recorded" "$(head -3 "$GLOG/eos-lines.txt" | tr '\n' ' ' | cut -c1-300)"
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
if [ "$phase" != a ]; then
  out="$JOB/native/convert"
  if [ -n "$converted" ]; then
    [ -d "$converted/Data" ] && out=$converted || crit b_converter fail "phase b: --converted has a Data/ folder" "$converted"
  elif [ ! -d "$out/Data" ]; then
    # detect the converter environment (never install)
    py=${PP_CONVERTER_PYTHON:-}; [ -n "$py" ] || py=$(python3_path 2>/dev/null)
    pm="$PP_KIT_DIR/../native/pm.py"
    why=""
    [ -f "$pm" ] || why="$why native/pm.py not next to the kit (repo layout mac/native);"
    if [ -z "$py" ] || [ ! -x "$py" ]; then why="$why no python3 (Xcode CLT or Homebrew; PP_CONVERTER_PYTHON);"
    else
      pyv=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null); metric converter_python "$py $pyv" str
      "$py" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null || why="$why python $pyv < 3.11;"
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
      if [ "$rc" = 0 ] && [ -d "$out/Data" ]; then crit b_convert pass "phase b: converter produced loose Data files" "$(tail -1 "$GLOG/convert.log" | cut -c1-200)"
      else crit b_convert fail "phase b: converter produced loose Data files" "exit $rc (logs/G-C0/convert.log)"; fi
    fi
  fi
  if [ -d "$out/Data" ]; then
    APP_B="$JOB/native/b-converted/PEAK.app"; mkdir -p "$(dirname "$APP_B")"
    if assemble "$APP_B" "$out/Data"; then crit b_assemble pass "phase b: bundle with converted loose files (no data.unity3d), signed"
    else crit b_assemble fail "phase b: bundle assembled and signed"; fi
    [ -f "$APP_B/Contents/Resources/Data/data.unity3d" ] && crit b_no_archive fail "phase b: no data.unity3d next to the loose files" || crit b_no_archive pass "phase b: no data.unity3d next to the loose files"
    run_player "$APP_B" b
    cu_request menu 240 "Phase b (converted Metal shaders): when PEAK's main menu shows, screenshot: bash testkit/cu.sh \$JOB shot G-C0 native-b-menu. Then click Play and wait for the Airport lobby (up to 2 min); screenshot native-b-level. Look for and report: upside-down or mirrored image (y orientation), objects drawn through each other (depth), washed-out or too dark colours (sRGB), black/garbled full-screen copies (framebuffer fetch, CoreCopy), flickering or repeated objects (instancing), pink/missing materials. Answer: ok menu=<yes|no> level=<yes|no> yflip=<ok|bad> depth=<ok|bad> srgb=<ok|bad> fbfetch=<ok|bad> instancing=<ok|bad> missing=<none|list>, or fail <what happened> if it crashed or stayed black."
    cub=$?
    for k in menu level yflip depth srgb fbfetch instancing missing; do v=$(cu_kv "$k"); [ -n "$v" ] && metric "b_visual_$k" "$v" str; done
    finish_player b
    analyse "$GLOG/b-player.log" b_
    case $cub in 0) crit b_visual pass "phase b: renders without crash/black screen (agent; visual findings in metrics b_visual_*)" "$CU_NOTE" ;; 1) crit b_visual fail "phase b: renders without crash/black screen (agent)" "$CU_NOTE" ;; *) crit b_visual skip "phase b: agent's visual check" "$CU_ANSWER" ;; esac
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
gate_end
