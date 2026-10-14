# shellcheck shell=bash
# shellcheck disable=SC2034  # APP_* globals set here are read by the G-APP gates that source this file
# lib/app.sh - helpers for the PEAK (Modded).app gates (G-APP1 .. G-APP6).
# Part of PeakPack for Mac (mac/testkit). MIT licence. Source after lib/common.sh and lib/assets.sh.
#
# Everything the app writes lives in $JOB/appdata (its --data-dir): its own runtime (appdata/runtime),
# its Wine prefix (appdata/prefix), frontend/status.json, Logs/. The kit's runtime/, prefix/ and game/ folders
# are NOT used by these gates.
#
# Release: prerelease mac-build-app-<version> of $PP_REPO with the assets PEAK-Modded-Mac-<version>.zip and
# SHA256SUMS. The tag comes from the gate argument --app-release TAG, else PP_APP_RELEASE, else the job's
# job.env (APP_RELEASE, saved by G-APP1).
#
# Privacy: this file never reads Steam login or config files and never reads the clipboard. The only Steam
# file it reads is logs/console_log.txt, read-only, from a byte offset. No osascript, no AppleScript, no
# screencapture (snap() is a no-op unless PP_SCREENSHOTS=1), no tccutil, no defaults, no sudo.

APP_NAME="PEAK (Modded).app"
APP_EXE_NAME="PEAK Modded"
APP_BUNDLE="$JOB/apps/$APP_NAME"
APP_EXE="$APP_BUNDLE/Contents/MacOS/$APP_EXE_NAME"
APP_DATA="$JOB/appdata"
APP_PFX="$APP_DATA/prefix"
APP_STATUS="$APP_DATA/frontend/status.json"
APP_STATEFILE="$APP_DATA/frontend/state.json"
APP_UNINSTALL_TO="$JOB/uninstalled"
APP_TAG=""; APP_ZIP_SHA=""; APP_PHASE_SEEN=""; END_METHOD=""; END_CU_RC=""

app_noop() { :; }
app_wine_stop_gate() { app_wine_stop; }   # GATE_CLEANUP for the gates that may leave Wine running

# ---------------------------------------------------------------- release tag and download
# app_tag_resolve [TAG] -> sets APP_TAG (argument > PP_APP_RELEASE > job.env); saves it to job.env; 1 if none/malformed
app_tag_resolve() {
  APP_TAG=${1:-}
  [ -n "$APP_TAG" ] || APP_TAG=${PP_APP_RELEASE:-}
  [ -n "$APP_TAG" ] || APP_TAG=$(job_env_get APP_RELEASE)
  case "$APP_TAG" in mac-build-app-[0-9]*) ;; *) APP_TAG=""; return 1 ;; esac
  case "$APP_TAG" in *[!A-Za-z0-9._-]*) APP_TAG=""; return 1 ;; esac
  job_env_set APP_RELEASE "$APP_TAG"
  version_set app_release "$APP_TAG"
  return 0
}
app_ver() { printf '%s' "${APP_TAG#mac-build-app-}"; }

# ensure_app -> downloads (or copies from PP_ASSETS_DIR) the zip, verifies it, unpacks it into $JOB/apps.
# 0 ok; 1 not downloadable (blocked); 2 SHA-256 mismatch or the zip is not listed (fail)
ensure_app() {
  local adl="$DL/$APP_TAG" base zname exp got f
  base="https://github.com/$PP_REPO/releases/download/$APP_TAG"
  [ -n "$APP_TAG" ] || return 1
  mkdir -p "$adl"
  if [ ! -s "$adl/SHA256SUMS" ]; then
    if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/SHA256SUMS" ]; then cp "$PP_ASSETS_DIR/SHA256SUMS" "$adl/SHA256SUMS"
    else log "downloading SHA256SUMS of $APP_TAG"; fetch_url "$base/SHA256SUMS" "$adl/SHA256SUMS" || return 1
    fi
  fi
  zname="PEAK-Modded-Mac-$(app_ver).zip"
  exp=$(awk -v n="$zname" '{ m = $2; sub(/^\*/, "", m) } m == n { print $1 }' "$adl/SHA256SUMS" | head -1)
  [ -n "$exp" ] || { log "$zname is not listed in the SHA256SUMS of $APP_TAG"; return 2; }
  f="$adl/$zname"
  if [ ! -f "$f" ] || [ "$(sha256_of "$f")" != "$exp" ]; then
    rm -f "$f"
    if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/$zname" ]; then cp "$PP_ASSETS_DIR/$zname" "$f"
    else log "downloading $zname"; fetch_url "$base/$zname" "$f" || { log "download failed: $zname"; return 1; }
    fi
  fi
  got=$(sha256_of "$f")
  if [ "$got" != "$exp" ]; then log "SHA-256 mismatch for $zname: got $got, expected $exp"; mv "$f" "$f.bad"; return 2; fi
  APP_ZIP_SHA=$got
  version_set app_zip_sha256 "$got"
  if [ ! -x "$APP_EXE" ]; then
    mkdir -p "$JOB/apps"
    log "unpacking $zname into $JOB/apps (ditto)"
    ditto -x -k "$f" "$JOB/apps" || return 1
  fi
  [ -x "$APP_EXE" ] || { log "the zip did not contain $APP_NAME/Contents/MacOS/$APP_EXE_NAME"; return 2; }
  return 0
}

# ---------------------------------------------------------------- the app process
# Regex for pkill/pgrep -f: the bundle path with its regex metacharacters escaped (the name has spaces and parentheses).
app_pattern() { printf '%s' "$APP_BUNDLE/Contents/MacOS/" | sed 's/[][\\.*^$(){}?+|]/\\&/g'; }
app_running() { pgrep -f "$(app_pattern)" >/dev/null 2>&1; }
# app_quit: TERM to the app's own processes, then up to 30 s for them to go. 0 when none is left.
app_quit() {
  local i=0
  app_running || return 0
  pkill -f "$(app_pattern)" >/dev/null 2>&1
  while app_running && [ "$i" -lt 30 ]; do sleep 1; i=$((i + 1)); done
  ! app_running
}
# ---------------------------------------------------------------- test-only PeakPack override (app 0.1.3+)
# When the slot pins peakpack.tag (PP_PEAKPACK_TAG, kept in job.env), the app gets
#   --test-peakpack-url <release>/PeakPack.exe --test-peakpack-sha256 <sha from that release's SHA256SUMS>
# (honoured by the app only together with --data-dir). Nothing is hard-coded here.
APP_PP_ARGS=(); APP_PP_TAG=""; APP_OVERRIDE_CHECKED=0
app_peakpack_override() {
  local tag sums sha
  APP_PP_ARGS=(); APP_PP_TAG=""
  tag=${PP_PEAKPACK_TAG:-$(job_env_get PEAKPACK_TAG)}
  [ -n "$tag" ] || return 0
  case "$tag" in mac-build-peakpack-*|rev-*) ;; *) log "PP_PEAKPACK_TAG must be mac-build-peakpack-* or rev-*: $tag"; return 1 ;; esac
  sums="$DL/peakpack-$tag/SHA256SUMS"; mkdir -p "$(dirname "$sums")"
  [ -s "$sums" ] || fetch_url "https://github.com/$PP_REPO/releases/download/$tag/SHA256SUMS" "$sums" || { log "no SHA256SUMS in $tag"; return 1; }
  sha=$(tr -d '\r' < "$sums" | awk '{ n = $2; sub(/^\*/, "", n) } n == "PeakPack.exe" { print tolower($1); exit }')
  case "$sha" in [0-9a-f]*) [ "${#sha}" = 64 ] || return 1 ;; *) log "$tag SHA256SUMS does not list PeakPack.exe"; return 1 ;; esac
  APP_PP_TAG=$tag
  APP_PP_ARGS=(--test-peakpack-url "https://github.com/$PP_REPO/releases/download/$tag/PeakPack.exe" --test-peakpack-sha256 "$sha")
  version_set app_peakpack_override "$tag ($sha)"
  return 0
}
# app_check_overrides: once per gate, on the first fresh status: with an override, status.json must list
# "peakpack" in testOverrides (recorded either way)
app_check_overrides() {
  local ov
  [ "$APP_OVERRIDE_CHECKED" = 0 ] || return 0
  APP_OVERRIDE_CHECKED=1
  ov=$(json_flat "$APP_STATUS" 2>/dev/null | awk -F'\t' '$1 ~ /^testOverrides\.[0-9]+$/ { printf "%s%s", s, $2; s = "," }')
  metric app_test_overrides "${ov:-none}" str
  [ -n "$APP_PP_TAG" ] || return 0
  case ",$ov," in *,peakpack,*) crit test_override_peakpack pass "app uses the test PeakPack ($APP_PP_TAG): status testOverrides lists peakpack" "$ov" ;;
    *) crit test_override_peakpack fail "app uses the test PeakPack ($APP_PP_TAG): status testOverrides lists peakpack" "testOverrides: ${ov:-none}" ;; esac
}

# app_launch [EXTRA_ARGS...]: a fresh instance with all data in the job dir. A running instance is quit first.
# Without extra args the app autoplays (a Dock click); pass --no-autoplay or --options as the gate needs.
app_launch() {
  if app_running; then log "quitting the running app before the launch"; app_quit || return 1; fi
  [ -x "$APP_EXE" ] || return 1
  mkdir -p "$APP_DATA" "$APP_UNINSTALL_TO" "$STATE"
  # a status file from an earlier session must never satisfy a wait: remove it, remember the launch time
  rm -f "$APP_STATUS"; now_s > "$STATE/app-launch-epoch"
  app_peakpack_override || return 1
  open -n "$APP_BUNDLE" --args --data-dir "$APP_DATA" --skip-update-check --uninstall-to "$APP_UNINSTALL_TO" \
    ${APP_PP_ARGS[@]+"${APP_PP_ARGS[@]}"} "$@"
}
# app_cli SECONDS ARGS... -> runs the executable without the GUI; output in $GTMP/cli.out; 124 on timeout
app_cli() {
  local to=$1 pid t0 rc; shift
  "$APP_EXE" "$@" > "$GTMP/cli.out" 2> "$GTMP/cli.err" &
  pid=$!; t0=$(now_s)
  while kill -0 "$pid" 2>/dev/null; do
    if [ $(( $(now_s) - t0 )) -ge "$to" ]; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1
  done
  wait "$pid"; rc=$?
  return "$rc"
}

# ---------------------------------------------------------------- status file (frontend/status.json)
app_status_get() { json_get "$APP_STATUS" "$1"; }
app_has_key() { json_flat "$1" 2>/dev/null | awk -F'\t' -v k="$2" '$1 == k { f = 1 } END { exit !f }'; }
# iso_epoch ISO8601 -> epoch seconds (UTC "…Z", optional fractional seconds); empty if unparsable
iso_epoch() {
  local t=${1%%.*}; t=${t%Z}; t=${t%%+*}
  date -j -u -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null || date -u -d "${t}Z" +%s 2>/dev/null
}
# app_status_fresh: the status belongs to a live app instance (its pid runs) and, when this job launched the
# app, to a session that started at or after that launch (5 s slack). Used by every wait below.
app_status_fresh() {
  local pid ss le se
  [ -s "$APP_STATUS" ] || return 1
  pid=$(app_status_get pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  le=$(cat "$STATE/app-launch-epoch" 2>/dev/null); ss=$(app_status_get sessionStarted)
  if [ -n "$le" ] && [ -n "$ss" ]; then
    se=$(iso_epoch "$ss"); [ -n "$se" ] && [ "$se" -ge $(( le - 5 )) ] || return 1
  fi
  return 0
}
# app_no_problem: status has no problem.code (null or absent counts as none)
app_no_problem() { local c; c=$(app_status_get problem.code); [ -z "$c" ] || [ "$c" = null ]; }
# wait_for_phase PHASE[|PHASE...] TIMEOUT_S -> 0 reached, 1 timeout, 2 the app reported phase error
# (a wait that names "error" returns 0 for it). The phase seen last is in APP_PHASE_SEEN.
wait_for_phase() {
  local want=$1 to=$2 t0 ph
  t0=$(now_s)
  while :; do
    if app_status_fresh; then ph=$(app_status_get phase); app_check_overrides; else ph="(no fresh status)"; fi
    APP_PHASE_SEEN=$ph
    case "|$want|" in *"|$ph|"*) return 0 ;; esac
    if [ "$ph" = error ]; then return 2; fi
    [ $(( $(now_s) - t0 )) -lt "$to" ] || return 1
    sleep 3
  done
}
# wait_for_step STEP STATE TIMEOUT_S -> 0 reached, 1 timeout, 2 phase error
wait_for_step() {
  local st=$1 ss=$2 to=$3 t0 cs cst ph
  t0=$(now_s)
  while :; do
    if app_status_fresh; then ph=$(app_status_get phase); cst=$(app_status_get step); cs=$(app_status_get stepState); app_check_overrides
    else ph="(no fresh status)"; cst=""; cs=""; fi
    APP_PHASE_SEEN=$ph
    if [ "$cst" = "$st" ] && [ "$cs" = "$ss" ]; then return 0; fi
    if [ "$ph" = error ]; then return 2; fi
    [ $(( $(now_s) - t0 )) -lt "$to" ] || return 1
    sleep 3
  done
}

# ---------------------------------------------------------------- app-side paths (the app's own prefix)
app_wine_user() {  # the Windows user folder of the app's own prefix (see wine_user)
  # Our CrossOver-derived Wine names the Windows user "crossover" (CrossOver Hack 12735 in advapi32 GetUserName;
  # CX_REPORT_REAL_USERNAME is not set), so drive_c/users/crossover is THE user folder whenever it exists. A kept
  # job dir can also hold a stale users/<mac user> folder that kits before 0.3.9 created (with an older PeakPack
  # copy and profile), so crossover always wins; otherwise the folder whose AppData changed last.
  prefix_user_of "$APP_PFX"
}
app_pp_dir() { printf '%s/drive_c/users/%s/AppData/Local/PeakPack' "$APP_PFX" "$(app_wine_user)"; }
app_player_log() { printf '%s/drive_c/users/%s/AppData/LocalLow/%s/%s/Player.log' "$APP_PFX" "$(app_wine_user)" "$UNITY_COMPANY" "$UNITY_PRODUCT"; }
app_bepinex_log() { printf '%s/profile/BepInEx/LogOutput.log' "$(app_pp_dir)"; }
app_game_dir() { printf '%s/drive_c/Games/PEAK' "$APP_PFX"; }
app_runtime_dir() {  # the app's unpacked runtime (appdata/runtime/<id>)
  local w
  for w in "$APP_DATA"/runtime/*/bin/wineserver; do
    [ -x "$w" ] && { dirname "$(dirname "$w")"; return 0; }
  done
  return 1
}
# Stops the wineserver of the APP's prefix only (every Wine process of that prefix, PEAK included).
app_wine_stop() {
  local w
  for w in "$APP_DATA"/runtime/*/bin/wineserver; do
    [ -x "$w" ] && WINEPREFIX="$APP_PFX" "$w" -k >/dev/null 2>&1
  done
  return 0
}
# PEAK itself (a Wine process: its command line names PEAK.exe)
# app_pid_is_ours PID -> 0 when PID is alive and runs this job's app bundle (never touches other processes)
app_pid_is_ours() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null || return 1
  case "$(ps -p "$1" -o command= 2>/dev/null)" in *"$APP_BUNDLE/Contents/MacOS/"*) return 0 ;; esac
  return 1
}
# app_job_stop_leftovers -> stops only what this job started: the app's recorded pid (if it is this job's bundle),
# any other process of this job's app bundle, and the Wine processes of this job's app prefix (wineserver -k with
# WINEPREFIX=$APP_PFX). A PEAK.exe that survives belongs to another prefix and is only reported.
app_job_stop_leftovers() {
  local pid t0
  pid=$(app_status_get pid)
  if app_pid_is_ours "$pid"; then
    log "stopping this job's app (recorded pid $pid)"; kill -TERM "$pid" 2>/dev/null
    t0=$(now_s); while kill -0 "$pid" 2>/dev/null && [ $(( $(now_s) - t0 )) -lt 20 ]; do sleep 1; done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  fi
  app_quit || log "app processes of $APP_BUNDLE still running after TERM"
  app_wine_stop; sleep 2
  if app_peak_running; then log "a PEAK.exe is still running after stopping this job's prefix: not ours, left alone"; return 1; fi
  return 0
}
# app_require_setup HINT -> returns when the app is set up in this job. A phase left by an interrupted earlier
# gate (launching|playing|error|message; e.g. PEAK sat on its mic chooser and the quit step timed out) is
# recovered when frontend/state.json has setupComplete=true and the recorded app pid is gone or is this job's
# app: this job's leftovers are stopped and status.json is set aside (the app rewrites it on its next start).
app_require_setup() {
  local hint=$1 ph sc mods sst keep
  ph=$(app_status_get phase)
  case "$ph" in done|ready) return 0 ;; launching|playing|error|message) ;;
    *) gate_finish_as blocked "the app is not set up in this job (phase '${ph:-none}'): $hint" ;; esac
  sc=$(json_get "$APP_STATEFILE" setupComplete); mods=$(json_get "$APP_STATEFILE" modsSynced); sst=$(app_status_get stepState)
  # set up = state.json setupComplete, or the stale status itself says the setup step finished (stepState done)
  [ "$sc" = true ] || [ "$sst" = "done" ] ||
    gate_finish_as blocked "the app is not set up in this job (phase '$ph', state.json setupComplete '${sc:-missing}', stepState '${sst:-missing}'): $hint"
  log "stale app phase '$ph' from an earlier run (setupComplete=${sc:-unset}, stepState=${sst:-unset}): recovering"
  app_job_stop_leftovers || gate_finish_as error "PEAK is still running outside this job's prefix; stop it first"
  keep="$APP_STATUS.stale-$ph-$(now_s)"; mv "$APP_STATUS" "$keep" 2>/dev/null
  metric stale_phase_recovered "$ph" str
  crit stale_phase info "stale app phase from an earlier run recovered" "phase '$ph', setupComplete=${sc:-unset}, stepState=${sst:-unset}, modsSynced=${mods:-unset}; status.json kept as $(rel_to_job "$keep")"
  return 0
}
app_peak_running() { pgrep -f '(^|[/\\])PEAK\.exe' >/dev/null 2>&1; }

# app_end_peak STEP TEXT -> 0 when PEAK is gone. Gives the agent 60 s to quit PEAK from its main menu
# (computer-use step STEP); then, if PEAK still runs, stops the app's prefix with wineserver -k.
# Sets END_METHOD (menu|wineserver) and END_CU_RC (the cu_request code).
app_peak_gone() { ! app_peak_running; }
app_end_peak() {
  local step=$1 text=$2 t0
  END_METHOD=menu
  # 180 s: the hub's agent can be busy elsewhere (0.3.10 missed 60 s); the step also ends as soon as PEAK is gone
  cu_request "$step" "${PP_CU_QUIT_S:-180}" "$text" app_peak_gone; END_CU_RC=$?
  t0=$(now_s)
  while app_peak_running && [ $(( $(now_s) - t0 )) -lt 30 ]; do sleep 3; done
  if app_peak_running; then
    END_METHOD=wineserver
    log "PEAK still running after the menu step: wineserver -k of the app prefix (fallback)"
    app_wine_stop
    t0=$(now_s)
    while app_peak_running && [ $(( $(now_s) - t0 )) -lt 30 ]; do sleep 2; done
  fi
  ! app_peak_running
}

# ---------------------------------------------------------------- depot checks (same pipeline as G-B5)
# app_hash_depot DIR OUT: same as G-B5 (lib/common.sh depot_manifest: no BepInEx/Doorstop/changelog.txt, no caches)
app_hash_depot() { depot_manifest "$1" "$2"; }
# app_ref_manifest VERSION -> expect/peak-win-<VERSION>-*.manifest, empty when none
app_ref_manifest() {
  local ref="" e
  [ -n "${1:-}" ] || return 0
  for e in "$PP_KIT_DIR"/expect/peak-win-"$1"-*.manifest; do [ -f "$e" ] && ref=$e; done
  printf '%s' "$ref"
}
app_steam_content_dirs() {
  printf '%s\n%s\n' "$STEAM_DATA/steamapps/content/app_$PEAK_APPID" "$STEAM_MACOS_DIR/steamapps/content/app_$PEAK_APPID"
}
# Steam's console_log.txt: read-only, only bytes added after OFFSET are looked at
app_console_log() { printf '%s/logs/console_log.txt' "$STEAM_DATA"; }
app_console_done_since() {  # app_console_done_since OFFSET -> 0 when "Depot download complete" was added after OFFSET
  local f; f=$(app_console_log); [ -f "$f" ] || return 1
  tail -c +"$(( $1 + 1 ))" "$f" 2>/dev/null | grep -a -q "Depot download complete"
}
app_console_line_since() {
  local f; f=$(app_console_log); [ -f "$f" ] || return 0
  tail -c +"$(( $1 + 1 ))" "$f" 2>/dev/null | grep -a "Depot download complete" | tail -1
}
# outside_record for the depotcache entries Steam wrote for the download (cleanup.sh removes them)
app_record_depotcache() {
  local d f
  while IFS= read -r d; do
    for f in "$d/${PEAK_DEPOT}"_*.manifest; do
      [ -e "$f" ] && ! preexisted "$f" && outside_record "$f" created-by-us "Steam depotcache entry from the app's download_depot"
    done
  done <<EOF
$(depotcache_dirs)
EOF
  return 0
}
