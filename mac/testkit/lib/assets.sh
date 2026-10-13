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
wine_user() {  # the prefix's Windows user folder name (Wine uses the Mac user name)
  local u
  for u in "$PFX"/drive_c/users/*; do
    [ -d "$u" ] || continue
    case "$(basename "$u")" in Public|public|crossover) continue ;; esac
    basename "$u"; return 0
  done
  id -un
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
  local url=${PP_PEAKPACK_URL:-https://github.com/$PP_REPO/releases/latest/download/PeakPack.exe} d
  d=$(peakpack_win_dir)
  if [ ! -s "$DL/PeakPack.exe" ]; then
    if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/PeakPack.exe" ]; then cp "$PP_ASSETS_DIR/PeakPack.exe" "$DL/PeakPack.exe"
    else log "downloading PeakPack.exe ($url)"; fetch_url "$url" "$DL/PeakPack.exe" || return 1
    fi
  fi
  # Pack releases since app 0.4.2 carry PeakPack.exe.sha256 ("<sha256>  PeakPack.exe"); verify when present.
  local have want=""
  have=$(sha256_of "$DL/PeakPack.exe")
  if [ -n "${PP_ASSETS_DIR:-}" ] && [ -f "$PP_ASSETS_DIR/PeakPack.exe.sha256" ]; then cp "$PP_ASSETS_DIR/PeakPack.exe.sha256" "$DL/PeakPack.exe.sha256"
  elif [ ! -s "$DL/PeakPack.exe.sha256" ]; then fetch_url "$url.sha256" "$DL/PeakPack.exe.sha256" >/dev/null 2>&1 || rm -f "$DL/PeakPack.exe.sha256"
  fi
  [ -s "$DL/PeakPack.exe.sha256" ] && want=$(awk 'NR == 1 { print tolower($1) }' "$DL/PeakPack.exe.sha256" | tr -d '\r')
  if [ -n "$want" ] && [ "$want" != "$have" ]; then
    log "PeakPack.exe SHA-256 mismatch: got $have, release says $want"
    rm -f "$DL/PeakPack.exe"
    return 1
  fi
  mkdir -p "$d"
  [ -f "$d/PeakPack.exe" ] || cp "$DL/PeakPack.exe" "$d/PeakPack.exe"
  version_set peakpack_exe_sha256 "$have"
  if [ -n "$want" ]; then version_set peakpack_exe_verified "yes (PeakPack.exe.sha256)"; else version_set peakpack_exe_verified "no (release has no PeakPack.exe.sha256)"; fi
  return 0
}
# Newest PEAK Player.log in the prefix (Unity: AppData/LocalLow/LandCrab/PEAK/Player.log)
player_log_path() { printf '%s/drive_c/users/%s/AppData/LocalLow/%s/%s/Player.log' "$PFX" "$(wine_user)" "$UNITY_COMPANY" "$UNITY_PRODUCT"; }
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
