# shellcheck shell=bash
# lib/assets.sh - release download + verification, runtime/prefix/bridge/game setup, Wine helpers.
# Part of PeakPack for Mac (mac/testkit). MIT licence. Source after lib/common.sh.
#
# Everything lands inside the job dir:
#   downloads/  SHA256SUMS + release assets (verified) + PeakPack.exe
#   runtime/<RUNTIME_ID>/   unpacked runtime      steam-tests/<name>/  unpacked Steam test kit
#   bridge/     the folder t3_t5/t16 call --bridge  prefix/  the WINEPREFIX   game/PEAK  the depot
# The release is public (github.com/$PP_REPO); SHA256SUMS comes from the same release over HTTPS.
# PP_ASSETS_DIR=<dir>: use files the hub already downloaded (still verified against SHA256SUMS).

release_tag() { printf '%s' "${PP_RELEASE:-$PP_DEFAULT_RELEASE}"; }
release_base() { printf 'https://github.com/%s/releases/download/%s' "$PP_REPO" "$(release_tag)"; }
runtime_id() {
  local t; t=$(release_tag)
  case "$t" in mac-build-runtime-*) printf '%s' "${t#mac-build-runtime-}"; return ;; esac
  [ -f "$DL/SHA256SUMS" ] && sed -n 's/^[0-9a-f]* [ *]*peakpack-runtime-\(.*\)-x86_64\.tar\.xz$/\1/p' "$DL/SHA256SUMS" | head -1
}
fetch_url() {  # fetch_url URL OUT  (resumable, retried; no output on success)
  mkdir -p "$(dirname "$2")"
  curl -fL --retry 3 --retry-delay 5 --connect-timeout 30 -sS -C - -o "$2.part" "$1" 2>>"${GLOG:-$JOB/logs}/curl.log" \
    || curl -fL --retry 2 --retry-delay 5 --connect-timeout 30 -sS -o "$2.part" "$1" 2>>"${GLOG:-$JOB/logs}/curl.log" \
    || { rm -f "$2.part"; return 1; }
  mv "$2.part" "$2"
}
ensure_sums() {
  [ -s "$DL/SHA256SUMS" ] && return 0
  mkdir -p "$DL"
  if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/SHA256SUMS" ]; then cp "$PP_ASSETS_DIR/SHA256SUMS" "$DL/SHA256SUMS"; return 0; fi
  log "downloading SHA256SUMS of $(release_tag)"
  fetch_url "$(release_base)/SHA256SUMS" "$DL/SHA256SUMS"
}
asset_names() { [ -f "$DL/SHA256SUMS" ] && awk '{ n = $2; sub(/^\*/, "", n); print n }' "$DL/SHA256SUMS"; }
asset_match() { asset_names | grep -E "$1" | head -1; }   # asset_match REGEX -> first asset name
asset_expected() { awk -v n="$1" '{ m = $2; sub(/^\*/, "", m) } m == n { print $1 }' "$DL/SHA256SUMS" | head -1; }
# ensure_asset NAME -> downloads (or copies from PP_ASSETS_DIR) and verifies; 0 ok, 1 missing, 2 bad hash
ensure_asset() {
  local name=$1 exp got f="$DL/$1"
  exp=$(asset_expected "$name")
  [ -n "$exp" ] || { log "asset $name is not listed in SHA256SUMS"; return 1; }
  if [ -f "$f" ] && [ "$(sha256_of "$f")" = "$exp" ]; then return 0; fi
  if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/$name" ]; then cp "$PP_ASSETS_DIR/$name" "$f"
  else log "downloading $name"; fetch_url "$(release_base)/$name" "$f" || { log "download failed: $name"; return 1; }
  fi
  got=$(sha256_of "$f")
  if [ "$got" != "$exp" ]; then log "SHA-256 mismatch for $name: got $got, expected $exp"; mv "$f" "$f.bad"; return 2; fi
  return 0
}

# ensure_runtime -> sets RT (unpacked runtime dir); 0 ok, 1 not available
ensure_runtime() {
  local rid name
  ensure_sums || return 1
  rid=$(runtime_id); [ -n "$rid" ] || return 1
  RT="$JOB/runtime/$rid"
  if [ ! -x "$RT/bin/wine" ]; then
    name="peakpack-runtime-$rid-x86_64.tar.xz"
    ensure_asset "$name" || return 1
    mkdir -p "$JOB/runtime"
    log "unpacking $name"
    tar -xJf "$DL/$name" -C "$JOB/runtime" || return 1
    [ -x "$RT/bin/wine" ] || { log "runtime tarball did not contain $rid/bin/wine"; return 1; }
  fi
  # Exec bits do not always survive a Windows checkout; ours is a private copy, so set them.
  find "$RT/share/peakpack" -name '*.sh' -exec chmod +x {} + 2>/dev/null
  version_set runtime_id "$rid"
  [ -f "$RT/manifest.json" ] && version_set runtime_built_at "$(json_get "$RT/manifest.json" built_at)"
  return 0
}
# ensure_manifest -> downloads manifest-<rid>.json (informational)
ensure_manifest() { local n; n=$(asset_match '^manifest-.*\.json$'); [ -n "$n" ] && ensure_asset "$n"; }

# ensure_tests -> sets TESTS (dir with mac/ and probe/); release tarball first, repo copy as fallback.
ensure_tests() {
  local name top
  TESTS=""
  ensure_sums >/dev/null 2>&1
  # A separate tests-only prerelease (mac-build-steam-tests-<ver>, CI workflow mac-steam-tests.yml) wins
  # over the runtime release's tests package: pinned by PP_STEAM_TESTS_TAG (run_slot exports the slot
  # file's steam_tests.tag; run_gate keeps it in job.env).
  local ttag; ttag=${PP_STEAM_TESTS_TAG:-$(job_env_get STEAM_TESTS_TAG)}
  if [ -n "$ttag" ]; then
    case "$ttag" in mac-build-steam-tests-*) ;; *) log "PP_STEAM_TESTS_TAG must be mac-build-steam-tests-*: $ttag"; return 1 ;; esac
    local tdl="$DL/$ttag" tbase="https://github.com/$PP_REPO/releases/download/$ttag" exp
    mkdir -p "$tdl"
    [ -s "$tdl/SHA256SUMS" ] || fetch_url "$tbase/SHA256SUMS" "$tdl/SHA256SUMS" || { log "no SHA256SUMS in $ttag"; return 1; }
    name=$(awk '{ n = $2; sub(/^\*/, "", n); print n }' "$tdl/SHA256SUMS" | grep -E '^peakpack-steam-tests-.*\.tar\.xz$' | head -1)
    [ -n "$name" ] || { log "$ttag lists no peakpack-steam-tests-*.tar.xz"; return 1; }
    exp=$(awk -v n="$name" '{ m = $2; sub(/^\*/, "", m) } m == n { print $1 }' "$tdl/SHA256SUMS" | head -1)
    if ! { [ -f "$tdl/$name" ] && [ "$(sha256_of "$tdl/$name")" = "$exp" ]; }; then
      log "downloading $name ($ttag)"; fetch_url "$tbase/$name" "$tdl/$name" || { log "download failed: $name"; return 1; }
      [ "$(sha256_of "$tdl/$name")" = "$exp" ] || { log "SHA-256 mismatch for $name"; mv "$tdl/$name" "$tdl/$name.bad"; return 1; }
    fi
    top=${name%.tar.xz}
    if [ ! -d "$JOB/steam-tests/$top" ]; then mkdir -p "$JOB/steam-tests"; tar -xJf "$tdl/$name" -C "$JOB/steam-tests" || return 1; fi
    TESTS="$JOB/steam-tests/$top"
    version_set steam_tests "$top ($ttag)"
    find "$TESTS" -name '*.sh' -exec chmod +x {} + 2>/dev/null
    return 0
  fi
  name=$(asset_match '^peakpack-steam-tests-.*\.tar\.xz$')
  if [ -n "$name" ] && ensure_asset "$name"; then
    top=${name%.tar.xz}
    if [ ! -d "$JOB/steam-tests/$top" ]; then mkdir -p "$JOB/steam-tests"; tar -xJf "$DL/$name" -C "$JOB/steam-tests" || return 1; fi
    TESTS="$JOB/steam-tests/$top"
    version_set steam_tests "$top"
    # The kit may carry newer test scripts and probe SOURCES than the release (kit-only fixes, e.g. the
    # PEAK-style ticket call in kit 0.2.2): overlay them on a copy; prebuilt binaries stay the release's.
    local ksrc="$PP_KIT_DIR/../runtime/steam/tests"
    if [ "${PP_STEAM_TESTS:-kit}" != release ] && [ -d "$ksrc/mac" ] && [ -f "$ksrc/probe/steam_client_probe.c" ]; then
      local merged="$JOB/steam-tests/$top+kit"
      if [ ! -d "$merged" ]; then
        cp -R "$TESTS" "$merged" || return 1
        cp "$ksrc"/mac/*.sh "$merged/mac/" 2>/dev/null
        cp "$ksrc"/probe/*.c "$ksrc"/probe/*.h "$merged/probe/" 2>/dev/null
      fi
      TESTS="$merged"
      version_set steam_tests "$top + kit $PP_KIT_VERSION scripts/probe sources (PP_STEAM_TESTS=release to disable)"
    fi
  elif [ -d "$PP_KIT_DIR/../runtime/steam/tests/mac" ]; then
    mkdir -p "$JOB/steam-tests/repo"
    cp -R "$PP_KIT_DIR/../runtime/steam/tests/mac" "$PP_KIT_DIR/../runtime/steam/tests/probe" "$JOB/steam-tests/repo/" 2>/dev/null
    TESTS="$JOB/steam-tests/repo"
    version_set steam_tests "repo-copy (no tests tarball in $(release_tag))"
  else
    return 1
  fi
  find "$TESTS" -name '*.sh' -exec chmod +x {} + 2>/dev/null
  return 0
}

# ensure_bridge -> $BRIDGE with what t3_t5/t16 expect; 0 ok, 1 something missing (listed in BRIDGE_MISSING)
ensure_bridge() {
  BRIDGE_MISSING=""
  mkdir -p "$BRIDGE"
  local f src
  for f in steamclient64.dll peakpack_steam_launcher.exe; do
    src="$RT/share/peakpack/steam/$f"; [ -f "$src" ] && cp "$src" "$BRIDGE/" || BRIDGE_MISSING="$BRIDGE_MISSING $f"
  done
  for f in steam_client_probe.exe steam_api_probe.exe; do
    src="$TESTS/probe/$f"; [ -f "$src" ] || src="$TESTS/probe/out/$f"
    [ -f "$src" ] && cp "$src" "$BRIDGE/" || BRIDGE_MISSING="$BRIDGE_MISSING $f"
  done
  [ -f "$RT/lib/wine/x86_64-windows/lsteamclient.dll" ] && cp "$RT/lib/wine/x86_64-windows/lsteamclient.dll" "$BRIDGE/" || BRIDGE_MISSING="$BRIDGE_MISSING lsteamclient.dll"
  [ -f "$RT/lib/wine/x86_64-unix/lsteamclient.so" ] && cp "$RT/lib/wine/x86_64-unix/lsteamclient.so" "$BRIDGE/" || BRIDGE_MISSING="$BRIDGE_MISSING lsteamclient.so"
  [ -z "$BRIDGE_MISSING" ]
}

# ---------------------------------------------------------------- Wine
# pp_wine MODE PROGRAM [ARGS...]  (MODE normal|logs). Runs the runtime's wine with the environment from
# the runtime's own pp-env.sh (INTERFACES.md §4), in a subshell. PP_EXTRA_OVERRIDES, when set, becomes
# WINEDLLOVERRIDES for this call only (PeakPack calls: winhttp=n,b).
pp_wine() {
  local mode=$1; shift
  (
    # shellcheck source=/dev/null
    . "$RT/share/peakpack/prefix/pp-env.sh"
    pp_env "$RT" "$PFX" "$mode" >/dev/null || exit 97
    [ -n "${PP_EXTRA_OVERRIDES:-}" ] && export WINEDLLOVERRIDES="$PP_EXTRA_OVERRIDES"
    exec "$RT/bin/wine" "$@"
  )
}
wine_stop() {  # kills every Wine process of OUR prefix only
  [ -n "${RT:-}" ] && [ -x "$RT/bin/wineserver" ] && [ -d "$PFX" ] || return 0
  WINEPREFIX="$PFX" "$RT/bin/wineserver" -k >/dev/null 2>&1
  sleep 2
  return 0
}
wine_user() {  # the prefix's Windows user folder name
  # Our CrossOver-derived Wine names the Windows user "crossover" (CrossOver Hack 12735 in advapi32 GetUserName;
  # CX_REPORT_REAL_USERNAME is not set), so drive_c/users/crossover is THE user folder whenever it exists. A kept
  # job dir can also hold a stale users/<mac user> folder that kits before 0.3.9 created (with an older PeakPack
  # copy and profile), so crossover always wins; otherwise the folder whose AppData changed last.
  prefix_user_of "$PFX"
}
# ensure_prefix -> creates $PFX with the runtime's pp-create-prefix.sh when missing/stale. Log: $GLOG/create-prefix.log
ensure_prefix() {
  local stamp="$PFX/peakpack/prefix.json" rid; rid=$(basename "$RT")
  if [ -f "$stamp" ] && grep -q "\"runtime_id\": *\"$rid\"" "$stamp"; then return 0; fi
  log "creating the Wine prefix in the job dir (pp-create-prefix.sh, backend dxmt)"
  bash "$RT/share/peakpack/prefix/pp-create-prefix.sh" "$RT" "$PFX" dxmt > "$GLOG/create-prefix.log" 2>&1
}
# ensure_game_in_prefix -> drive_c/Games/PEAK -> the depot copy in the job dir (G-B5) or PP_GAME_DIR
ensure_game_in_prefix() {
  local src=$GAME_DIR
  [ -n "${PP_GAME_DIR:-}" ] && src=$PP_GAME_DIR
  [ -f "$src/PEAK.exe" ] || return 1
  mkdir -p "$PFX/drive_c/Games"
  if [ ! -e "$PFX/drive_c/Games/PEAK" ] || [ -L "$PFX/drive_c/Games/PEAK" ]; then ln -sfn "$src" "$PFX/drive_c/Games/PEAK"; fi
  [ -f "$PFX/drive_c/Games/PEAK/PEAK.exe" ]
}
peakpack_win_dir() { printf '%s/drive_c/users/%s/AppData/Local/PeakPack' "$PFX" "$(wine_user)"; }
# ensure_peakpack -> PeakPack.exe (latest pack release) at C:\users\<u>\AppData\Local\PeakPack\PeakPack.exe
ensure_peakpack() {
  # Source: PP_PEAKPACK_TAG (run_slot exports the slot file's peakpack.tag; run_gate keeps it in job.env) =
  # a mac-build-peakpack-* or rev-* release, verified against that release's SHA256SUMS; else releases/latest
  # (verified against PeakPack.exe.sha256 when the release has it). Each source has its own cache folder, and
  # the copy in the prefix is replaced whenever it differs, so a kept job dir never keeps an older PeakPack.
  local tag url d sub want="" have src verified
  tag=${PP_PEAKPACK_TAG:-$(job_env_get PEAKPACK_TAG)}
  d=$(peakpack_win_dir)
  if [ -n "$tag" ]; then
    case "$tag" in mac-build-peakpack-*|rev-*) ;; *) log "PP_PEAKPACK_TAG must be mac-build-peakpack-* or rev-*: $tag"; return 1 ;; esac
    url="https://github.com/$PP_REPO/releases/download/$tag"; sub="$DL/peakpack-$tag"; mkdir -p "$sub"
    [ -s "$sub/SHA256SUMS" ] || fetch_url "$url/SHA256SUMS" "$sub/SHA256SUMS" || { log "no SHA256SUMS in $tag"; return 1; }
    want=$(tr -d '\r' < "$sub/SHA256SUMS" | awk '{ n = $2; sub(/^\*/, "", n) } n == "PeakPack.exe" { print tolower($1); exit }')
    [ -n "$want" ] || { log "$tag SHA256SUMS does not list PeakPack.exe"; return 1; }
    if ! { [ -s "$sub/PeakPack.exe" ] && [ "$(sha256_of "$sub/PeakPack.exe")" = "$want" ]; }; then
      log "downloading PeakPack.exe ($tag)"; fetch_url "$url/PeakPack.exe" "$sub/PeakPack.exe" || return 1
    fi
    verified="yes (SHA256SUMS of $tag)"
  else
    url=${PP_PEAKPACK_URL:-https://github.com/$PP_REPO/releases/latest/download/PeakPack.exe}; sub="$DL/peakpack-latest"; mkdir -p "$sub"
    if [ ! -s "$sub/PeakPack.exe" ]; then
      if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/PeakPack.exe" ]; then cp "$PP_ASSETS_DIR/PeakPack.exe" "$sub/PeakPack.exe"
      else log "downloading PeakPack.exe ($url)"; fetch_url "$url" "$sub/PeakPack.exe" || return 1
      fi
    fi
    if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/PeakPack.exe.sha256" ]; then cp "$PP_ASSETS_DIR/PeakPack.exe.sha256" "$sub/PeakPack.exe.sha256"
    elif [ ! -s "$sub/PeakPack.exe.sha256" ]; then fetch_url "$url.sha256" "$sub/PeakPack.exe.sha256" >/dev/null 2>&1 || rm -f "$sub/PeakPack.exe.sha256"
    fi
    [ -s "$sub/PeakPack.exe.sha256" ] && want=$(awk 'NR == 1 { print tolower($1) }' "$sub/PeakPack.exe.sha256" | tr -d '\r')
    if [ -n "$want" ]; then verified="yes (PeakPack.exe.sha256)"; else verified="no (release has no PeakPack.exe.sha256)"; fi
  fi
  src="$sub/PeakPack.exe"; have=$(sha256_of "$src")
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    log "PeakPack.exe SHA-256 mismatch: got $have, release says $want"; rm -f "$src"; return 1
  fi
  cp "$src" "$DL/PeakPack.exe"   # the selected copy (G-D2 records its hash)
  mkdir -p "$d"
  cmp -s "$src" "$d/PeakPack.exe" || cp "$src" "$d/PeakPack.exe"
  version_set peakpack_source "${tag:-releases/latest}"
  version_set peakpack_exe_sha256 "$have"
  version_set peakpack_exe_verified "$verified"
  return 0
}
# bepinex_load_errors LOGOUTPUT -> writes $GLOG/bepinex-errors.txt (load errors) and $GLOG/bepinex-benign.txt
# (known-benign lines from expect/bepinex-benign.txt, each backed by the Windows baseline); records the metric
# bepinex_benign_lines and, when any matched, the info criterion benign_bepinex_lines. Used by G-D2 and G-APP4.
bepinex_load_errors() {
  local log=$1 list="$PP_KIT_DIR/expect/bepinex-benign.txt" n
  grep -a -E '\[(Error|Fatal) *: *BepInEx\]|Could not load \[|Skipping \[|Error loading \[|missing dependenc|incompatible' "$log" \
    > "$GLOG/bepinex-errors-raw.txt"
  grep -v -E '^[[:space:]]*(#|$)' "$list" 2>/dev/null > "$GTMP/benign.txt"
  if [ -s "$GTMP/benign.txt" ]; then
    grep -a -v -F -f "$GTMP/benign.txt" "$GLOG/bepinex-errors-raw.txt" > "$GLOG/bepinex-errors.txt"
    grep -a -F -f "$GTMP/benign.txt" "$GLOG/bepinex-errors-raw.txt" > "$GLOG/bepinex-benign.txt"
  else
    cp "$GLOG/bepinex-errors-raw.txt" "$GLOG/bepinex-errors.txt"; : > "$GLOG/bepinex-benign.txt"
  fi
  n=$(wc -l < "$GLOG/bepinex-benign.txt" | tr -d ' ')
  metric bepinex_benign_lines "$n"
  [ "$n" = 0 ] || crit benign_bepinex_lines info "known-benign BepInEx lines (also logged on Windows; expect/bepinex-benign.txt)" \
    "$n line(s): $(sort -u "$GLOG/bepinex-benign.txt" | head -3 | tr '\n' ' ')"
  return 0
}
# Newest PEAK Player.log in the prefix (Unity: AppData/LocalLow/LandCrab/PEAK/Player.log)
# PEAK's Player.log: Unity writes it to C:\users\<user>\AppData\LocalLow\LandCrab\PEAK. The user folder Wine uses
# can differ from the one the prefix was created with (USER differs between a remote shell and the GUI session's
# LaunchAgent), so every candidate is considered and the newest one wins (as t5_check_player_log.sh does).
# player_log_candidates -> one path per line (existing files only)
player_log_candidates() {
  local f
  for f in "$PFX"/drive_c/users/*/AppData/LocalLow/"$UNITY_COMPANY"/"$UNITY_PRODUCT"/Player.log \
           "$PFX"/drive_c/users/*/"Local Settings"/"Application Data"/"$UNITY_COMPANY"/"$UNITY_PRODUCT"/Player.log; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
}
# player_log_path [SINCE_EPOCH] -> the newest candidate (modified at/after SINCE if given); else the default path
player_log_path() {
  local since=${1:-0} best="" bm=-1 f m
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    m=$(mtime_of "$f"); [ "$m" -ge "$since" ] || continue
    if [ "$m" -gt "$bm" ]; then best=$f; bm=$m; fi
  done <<EOF
$(player_log_candidates)
EOF
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  printf '%s/drive_c/users/%s/AppData/LocalLow/%s/%s/Player.log' "$PFX" "$(wine_user)" "$UNITY_COMPANY" "$UNITY_PRODUCT"
}
# player_log_detail [SINCE] -> where Player.log was looked for and what was found (for failure details)
player_log_detail() {
  local since=${1:-0} f n=0 out=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue; n=$((n + 1))
    out="$out $(rel_to_job "$f") (modified $(( $(mtime_of "$f") - since )) s after the launch, last line: $(tail -1 "$f" 2>/dev/null | cut -c1-120));"
  done <<EOF
$(player_log_candidates)
EOF
  if [ "$n" = 0 ]; then
    printf 'no Player.log under %s/drive_c/users/*/AppData/LocalLow/%s/%s (prefix users: %s)' \
      "$(rel_to_job "$PFX")" "$UNITY_COMPANY" "$UNITY_PRODUCT" "$(users_seen "$PFX")"
  else
    printf 'looked for "Steam runtime manager initialized" in Player.log written since the launch; candidates:%s' "$out"
  fi
}
# wait_for_player_log FIXED_STRING TIMEOUT_S SINCE_EPOCH -> 0 when the newest Player.log written since SINCE has it;
# PLAYER_LOG_USED = the file that was checked last (recorded by the gates)
# shellcheck disable=SC2034  # PLAYER_LOG_USED is read by the gates
wait_for_player_log() {
  local s=$1 to=$2 since=$3 t0 f; t0=$(now_s); PLAYER_LOG_USED=""
  while [ $(( $(now_s) - t0 )) -lt "$to" ]; do
    f=$(player_log_path "$since")
    if [ -f "$f" ] && [ "$(mtime_of "$f")" -ge "$since" ]; then
      PLAYER_LOG_USED=$f
      grep -a -F -q -- "$s" "$f" 2>/dev/null && return 0
    fi
    sleep 5
  done
  return 1
}
# ---------------------------------------------------------------- PEAK start-up progress (busy vs blocked)
# progress_monitor_start NAME: every 15 s append to logs/<gate>/progress-NAME.tsv: seconds since start, Player.log
# bytes/lines, DXMT shader cache files/KB (grows while DXMT translates shaders), and CPU%/CPU time/RSS of the
# Wine processes running PEAK.exe. Read-only (ps, wc, du): no debugger attach, so no macOS prompt.
progress_monitor_start() {
  local name=$1 out="$GLOG/progress-$1.tsv" plog cache t0
  cache="$PFX/peakpack/dxmt-cache"; t0=$(now_s)
  printf 's\tplayer_log_bytes\tplayer_log_lines\tdxmt_cache_files\tdxmt_cache_kb\tpeak_procs(pid:%%cpu:cputime:rss_mb)\n' > "$out"
  local gate_shell=$$
  (
    # ends by itself with the gate's shell; no stdout/stderr (the gate's output is a pipe that run_gate waits on)
    while kill -0 "$gate_shell" 2>/dev/null; do
      pb=0; pl=0; cf=0; ck=0; plog=$(player_log_path "$t0")
      [ -f "$plog" ] && { pb=$(file_size "$plog"); pl=$(wc -l < "$plog" | tr -d ' '); }
      [ -d "$cache" ] && { cf=$(find "$cache" -type f 2>/dev/null | wc -l | tr -d ' '); ck=$(du -sk "$cache" 2>/dev/null | cut -f1); }
      pp=$(ps -axo pid=,pcpu=,time=,rss=,command= 2>/dev/null | grep -i 'PEAK\.exe' | grep -v grep \
           | awk '{ printf "%s:%s:%s:%d ", $1, $2, $3, $4 / 1024 }')
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(( $(now_s) - t0 ))" "$pb" "$pl" "$cf" "${ck:-0}" "${pp:-none}" >> "$out"
      sleep 15
    done
  ) > /dev/null 2>&1 &
  PROGRESS_PID=$!
}
progress_monitor_stop() { [ -n "${PROGRESS_PID:-}" ] && kill "$PROGRESS_PID" 2>/dev/null; PROGRESS_PID=""; return 0; }
# hang_snapshot NAME: what PEAK was doing when a start-up wait ran out (logs/<gate>/hang-NAME/)
hang_snapshot() {
  local d="$GLOG/hang-$1" plog
  mkdir -p "$d"; plog=$(player_log_path)
  [ -f "$plog" ] && { tr -d '\r' < "$plog" | tail -n 80 > "$d/Player.log.tail"; wc -l < "$plog" > "$d/Player.log.lines"; }
  ps -axo pid,ppid,pcpu,time,rss,state,command 2>/dev/null | grep -i -E 'wine|PEAK\.exe' | grep -v grep > "$d/wine-processes.txt"
  [ -d "$PFX/peakpack/dxmt-cache" ] && du -sk "$PFX/peakpack/dxmt-cache" > "$d/dxmt-cache-kb.txt" 2>/dev/null
  tail -n 5 "$GLOG/progress-$1.tsv" > "$d/progress-last.tsv" 2>/dev/null
  note "start-up snapshot in logs/$GATE_ID/hang-$1: Player.log ends with '$(tail -n 1 "$d/Player.log.tail" 2>/dev/null | cut -c1-120)'"
}
# progress_verdict NAME -> "busy" (PEAK used CPU or the shader cache grew in the last minute), "idle", or "unknown"
progress_verdict() {
  local f="$GLOG/progress-$1.tsv"
  [ -s "$f" ] || { echo unknown; return; }
  tail -n 5 "$f" | awk -F'\t' 'NR == 1 { c0 = $5 } { c1 = $5; n = split($6, p, " "); for (i = 1; i <= n; i++) { split(p[i], q, ":"); if (q[2] + 0 > 20) busy = 1 } }
    END { if (busy || c1 > c0) print "busy"; else print "idle" }'
}
# wait_for_file_text FILE FIXED_STRING TIMEOUT_S [NEWER_THAN_EPOCH] -> 0 when found
wait_for_file_text() {
  local f=$1 s=$2 to=$3 newer=${4:-0} t0; t0=$(now_s)
  while [ $(( $(now_s) - t0 )) -lt "$to" ]; do
    if [ -f "$f" ] && [ "$(mtime_of "$f")" -ge "$newer" ] && grep -a -F -q -- "$s" "$f" 2>/dev/null; then return 0; fi
    sleep 5
  done
  return 1
}
# Background helper: keep the Mac awake while the gate runs (process assertion only, nothing persistent).
keep_awake() { command -v caffeinate >/dev/null 2>&1 && ( caffeinate -dims -w $$ >/dev/null 2>&1 & ); return 0; }  # detached: never a direct child, so a bare `wait` cannot block on it
