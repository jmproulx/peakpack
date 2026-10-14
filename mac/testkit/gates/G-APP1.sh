#!/bin/bash
# TITLE: G-APP1 PEAK (Modded).app: release download and verification, static checks, first-run setup up to the game step
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# The app is the asset PEAK-Modded-Mac-<version>.zip of the prerelease mac-build-app-<version>. curl downloads carry
# no quarantine flag, so macOS shows no Gatekeeper dialog; that is intended (G-APP1.md explains the friend path).
# The zip is verified against SHA256SUMS and unpacked with ditto into $JOB/apps. The app is then started with
# --no-autoplay and runs its own first-run setup. The script waits for the game step, where the app waits for the
# Steam console paste (G-APP2). The app is left running for G-APP2.
# Args: [--app-release TAG] (or env PP_APP_RELEASE, or the job's APP_RELEASE)  [--setup-timeout S] (default 1800)
set -u
. "$PP_KIT_DIR/lib/common.sh"
. "$PP_KIT_DIR/lib/assets.sh"
. "$PP_KIT_DIR/lib/app.sh"
gate_begin G-APP1 "PEAK (Modded).app first run up to the game step"
gate_require_mac
tag_arg=""; setup_to=1800
while [ $# -gt 0 ]; do
  case "$1" in --app-release) tag_arg=$2; shift 2 ;; --setup-timeout) setup_to=$2; shift 2 ;; *) shift ;; esac
done
keep_awake
app_tag_resolve "$tag_arg" || gate_finish_as blocked "no app release tag: pass --app-release mac-build-app-<version>, or set PP_APP_RELEASE"
crit app_tag pass "app release tag" "$APP_TAG"
GATE_CLEANUP=app_noop   # the app is meant to keep running for G-APP2

# ---- 1. download, verify, unpack
ensure_app; rc=$?
case $rc in
  0) crit app_download pass "app zip downloaded and matches its SHA256SUMS" "$(app_ver).zip sha256 $(printf '%s' "$APP_ZIP_SHA" | cut -c1-16)..." ;;
  2) crit app_download fail "app zip matches its SHA256SUMS" "mismatch, or the zip is not listed (logs/G-APP1/curl.log; the .bad file is in downloads/)"; gate_end ;;
  *) gate_finish_as blocked "app release $APP_TAG could not be downloaded (network, or the release is missing)" ;;
esac
crit app_bundle pass "$APP_NAME unpacked into the job dir" "$APP_BUNDLE"

# ---- 2. static checks (no GUI needed)
if codesign --verify --deep --strict "$APP_BUNDLE" > "$GLOG/codesign.txt" 2>&1; then
  crit codesign pass "codesign --verify --deep --strict" "$(head -c 160 "$GLOG/codesign.txt" | tr '\n' ' ')"
else
  crit codesign fail "codesign --verify --deep --strict" "$(head -c 300 "$GLOG/codesign.txt" | tr '\n' ' ')"
fi
if clt_ok; then
  archs=$("$(clt_dir)/usr/bin/lipo" -archs "$APP_EXE" 2>/dev/null)
  la=0; lx=0
  case "$archs" in *arm64*) la=1 ;; esac
  case "$archs" in *x86_64*) lx=1 ;; esac
  if [ "$la" = 1 ] && [ "$lx" = 1 ]; then crit lipo_archs pass "executable has arm64 and x86_64 slices" "$archs"
  else crit lipo_archs fail "executable has arm64 and x86_64 slices" "lipo -archs: '$archs'"; fi
else
  crit lipo_archs skip "executable has arm64 and x86_64 slices" "Command Line Tools not installed: lipo is a shim that would pop an install dialog"
fi
plist="$APP_BUNDLE/Contents/Info.plist"
minos=$(plutil -extract LSMinimumSystemVersion raw "$plist" 2>/dev/null)
metric app_min_macos "$minos" str
if [ "$minos" = 12.0 ]; then crit min_macos pass "Info.plist LSMinimumSystemVersion is 12.0" "$minos"
else crit min_macos fail "Info.plist LSMinimumSystemVersion is 12.0" "got '$minos'"; fi
if plutil -extract NSMicrophoneUsageDescription raw "$plist" >/dev/null 2>&1; then
  crit mic_usage pass "Info.plist has NSMicrophoneUsageDescription"
else crit mic_usage fail "Info.plist has NSMicrophoneUsageDescription"; fi
if app_cli 60 --version; then rc=0; else rc=$?; fi
ver_line=$(head -1 "$GTMP/cli.out" 2>/dev/null | tr -d '\r')
cp "$GTMP/cli.out" "$GLOG/version.out" 2>/dev/null
if [ "$rc" = 0 ] && [ -n "$ver_line" ]; then crit version_cli pass "'$APP_EXE_NAME --version' prints a version and exits" "$ver_line"
else crit version_cli fail "'$APP_EXE_NAME --version' prints a version and exits" "exit $rc: $(head -c 200 "$GTMP/cli.err" 2>/dev/null | tr '\n' ' ')"; fi
if app_cli 60 --print-status --data-dir "$APP_DATA"; then rc=0; else rc=$?; fi
cp "$GTMP/cli.out" "$GLOG/print-status-fresh.json" 2>/dev/null
schema=$(json_get "$GLOG/print-status-fresh.json" schema)
if [ "$rc" = 0 ] && [ "$schema" = 1 ] && app_has_key "$GLOG/print-status-fresh.json" nextStep; then
  crit print_status pass "--print-status JSON has schema 1 and nextStep" "nextStep=$(json_get "$GLOG/print-status-fresh.json" nextStep)"
else
  crit print_status fail "--print-status JSON has schema 1 and nextStep" "exit $rc, schema '$schema'"
fi
version_set app_version "$(json_get "$GLOG/print-status-fresh.json" appVersion)"
version_set app_macos_min "$minos"

# ---- 3. GUI session and Rosetta (the app needs both; Rosetta's install prompt is never clicked)
gate_require_gui
rosetta_ok || gate_finish_as needs-human "Rosetta 2 is not installed on this Mac" \
  "Joshua (or the hub with Joshua present) installs Rosetta 2 with macOS's own prompt, which needs an administrator password. The kit and the agent never click that prompt or type a password. Then re-run G-APP1."

# ---- 4. launch with --no-autoplay: the app opens at its welcome screen
t_launch=$(now_s)
app_launch --no-autoplay || gate_finish_as error "could not start the app (open -n failed or $APP_EXE is missing)"
wait_for_phase welcome 60; rc=$?
case $rc in
  0) crit first_run_welcome pass "app shows the welcome screen (phase welcome)" "after $(( $(now_s) - t_launch )) s" ;;
  2) crit first_run_welcome fail "app shows the welcome screen" "phase error: $(app_status_get problem.code) $(app_status_get problem.heading)"; gate_end ;;
  *) crit first_run_welcome fail "app shows the welcome screen within 60 s (a fresh job dir is needed: the app was already set up)" "phase '$APP_PHASE_SEEN'"; gate_end ;;
esac

# ---- 5. CU-welcome: the agent clicks Set Up PEAK
cu_request welcome 600 "The PEAK (Modded) welcome window is open (bottom right: the 'Set Up PEAK' button). Click 'Set Up PEAK' once. Do not click anything else, and do not type anything. Take the screenshot: bash testkit/cu.sh \"$JOB\" shot G-APP1 app-welcome (before the click). Answer ok once the setup screen has started (bash testkit/cu.sh \"$JOB\" done G-APP1.welcome ok \"setup started\"), or fail with what you see. If a macOS prompt appears (Rosetta, microphone, files), do NOT click it: screenshot it as dialog-1 and answer fail with its text."
rc=$?
case $rc in
  0) crit cu_welcome pass "agent clicked Set Up PEAK (CU-welcome)" "$CU_NOTE" ;;
  1) crit cu_welcome fail "agent clicked Set Up PEAK (CU-welcome)" "$CU_NOTE"; gate_end ;;
  2) gate_finish_as blocked "computer use is off (--no-cu): the welcome button needs a click" ;;
  *) gate_finish_as error "no answer to CU-welcome within 600 s" ;;
esac

# ---- 6. setup runs by itself up to the game step; record the time per step
t_setup=$(now_s); step_prev=""; step_t0=$(now_s); steam_t0=""
deadline=$(( $(now_s) + setup_to ))
while :; do
  ph=$(app_status_get phase); st=$(app_status_get step); ss=$(app_status_get stepState)
  if [ "$st" != "$step_prev" ]; then
    if [ -n "$step_prev" ] && [ "$step_prev" != null ]; then metric "step_${step_prev}_s" "$(( $(now_s) - step_t0 ))"; fi
    step_prev=$st; step_t0=$(now_s)
    log "setup step: ${st} (${ss})"
  fi
  if [ "$ph" = error ]; then
    crit setup_error fail "app setup runs without an error" "step $st: $(app_status_get problem.code): $(app_status_get problem.heading)"
    gate_end
  fi
  if [ "$st" = game ] && [ "$ss" = waiting-for-user ]; then break; fi
  if [ "$st" = steam ] && [ "$ss" != "done" ]; then
    [ -n "$steam_t0" ] || steam_t0=$(now_s)
    if [ $(( $(now_s) - steam_t0 )) -gt 180 ]; then
      gate_finish_as needs-human "the app has waited more than 3 min at step steam" \
        "Mac Steam must be running and signed in under the fleet user. The app opens Steam itself when it is not running. Joshua signs in once (gate H-STEAM), then re-run G-APP1: setup resumes."
    fi
  else
    steam_t0=""
  fi
  if [ "$(now_s)" -ge "$deadline" ]; then
    crit setup_to_game fail "app reaches the game step (waiting for user) within ${setup_to}s" "step $st ($ss), phase $ph"
    gate_end
  fi
  sleep 3
done
metric time_to_game_s "$(( $(now_s) - t_setup ))"
crit setup_to_game pass "app reaches the game step and waits for the Steam console paste" "after $(( $(now_s) - t_setup )) s"

# ---- 7. what the setup produced
rid=$(app_status_get runtimeId)
if [ -n "$rid" ] && [ "$rid" != null ]; then
  version_set app_runtime_id "$rid"
  crit runtime_id pass "app runtime id reported" "$rid"
else crit runtime_id fail "app runtime id reported" "runtimeId empty"; fi
if [ -f "$APP_PFX/peakpack/prefix.json" ]; then crit prefix_stamp pass "Wine prefix stamp exists (appdata/prefix/peakpack/prefix.json)"
else crit prefix_stamp fail "Wine prefix stamp exists (appdata/prefix/peakpack/prefix.json)"; fi
if app_no_problem; then crit no_problem pass "status has no problem"
else crit no_problem fail "status has no problem" "$(app_status_get problem.code): $(app_status_get problem.heading)"; fi
metric app_setup_version "$(app_status_get appVersion)" str
version_set app_status_version "$(app_status_get appVersion)"
log "the app stays running for G-APP2"
gate_end
