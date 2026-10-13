# shellcheck shell=bash
# lib/common.sh - shared helpers for the PeakPack for Mac test kit.
# Part of PeakPack for Mac (mac/testkit). MIT licence.
#
# macOS /bin/bash 3.2 compatible: no associative arrays, no ${v,,}, no mapfile, and empty
# arrays are never expanded under set -u. Uses macOS base tools only (awk, sed, grep, shasum,
# curl, tar, plutil, pgrep, screencapture). Never calls an Xcode Command Line Tools shim
# (clang, lipo, nm, otool, strings, python3, git, make) unless clt_ok says the CLT exist,
# because a missing CLT makes those shims pop up an install dialog.
#
# Every gate script does:
#   . "$PP_KIT_DIR/lib/common.sh"
#   gate_begin G-XX "Title"
#   crit <id> pass|fail|skip|info|warn "what was checked" "detail"
#   metric <key> <value>
#   gate_end                      (status from the criteria: any fail -> fail, else pass)
#   gate_finish_as blocked|needs-human|error "reason" ["instructions for the human"]
# Exit codes: 0 pass, 1 fail, 2 blocked (precondition missing), 3 needs-human, 4 error.

: "${PP_KIT_DIR:?PP_KIT_DIR not set (run gates through run_gate.sh)}"
: "${PP_JOB_DIR:?PP_JOB_DIR not set (run gates through run_gate.sh)}"
PP_KIT_VERSION=$(tr -d '\r\n' < "$PP_KIT_DIR/VERSION" 2>/dev/null || echo 0)
PP_REPO=${PP_REPO:-jmproulx/peakpack}
PP_DEFAULT_RELEASE=${PP_DEFAULT_RELEASE:-mac-build-runtime-pp1-cx26.3.0}
PEAK_APPID=3527290
PEAK_DEPOT=3527291
STEAM_DATA="$HOME/Library/Application Support/Steam"
STEAM_MACOS_DIR="$STEAM_DATA/Steam.AppBundle/Steam/Contents/MacOS"
# Unity's per-user folders for PEAK (company LandCrab, product PEAK), used by G-C0 only.
UNITY_COMPANY=LandCrab
UNITY_PRODUCT=PEAK

# ---------------------------------------------------------------- small utilities
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_s() { date +%s; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
oneline() { printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | cut -c1-2000; }
is_num() { printf '%s' "$1" | grep -Eq '^-?(0|[1-9][0-9]*)(\.[0-9]+)?$'; }
sha256_of() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1; }
file_size() { if [ "$(uname -s)" = Darwin ]; then stat -f %z "$1"; else stat -c %s "$1"; fi 2>/dev/null || wc -c < "$1" | tr -d ' '; }
mtime_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi 2>/dev/null || echo 0; }
rel_to_job() { case "$1" in "$PP_JOB_DIR"/*) printf '%s' "${1#"$PP_JOB_DIR"/}" ;; *) printf '%s' "$1" ;; esac; }

# JSON string literal (with quotes) for arbitrary text.
json_str() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | awk '
    BEGIN { ORS = ""; printf "\"" }
    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t"); gsub(/\r/, "");
      if (NR > 1) printf "\\n"; printf "%s", $0 }
    END { printf "\"" }'
}
# json_get FILE PATH -> value of a flattened JSON path ("a.b.0"), empty when absent.
json_get() { awk -f "$PP_KIT_DIR/lib/json_flat.awk" "$1" 2>/dev/null | awk -F'\t' -v p="$2" '$1 == p { v = $2 } END { printf "%s", v }'; }
json_flat() { awk -f "$PP_KIT_DIR/lib/json_flat.awk" "$1"; }

# ---------------------------------------------------------------- job dir layout
# shellcheck disable=SC2034  # these paths are used by lib/assets.sh and the gate scripts
job_paths() {
  JOB=$PP_JOB_DIR
  DL="$JOB/downloads"; RESULTS="$JOB/results"; STATE="$JOB/state"; CU_DIR="$JOB/cu"
  PFX="$JOB/prefix"; GAME_DIR="$JOB/game/PEAK"; BRIDGE="$JOB/bridge"
  VERSIONS_TSV="$STATE/versions.tsv"; OUTSIDE_TSV="$STATE/outside-paths.tsv"; PRE_TSV="$STATE/preexisting.tsv"
}
job_paths

# job_env_get KEY / job_env_set KEY VALUE: tiny KEY=VALUE store in $JOB/job.env
job_env_get() { [ -f "$JOB/job.env" ] && sed -n "s/^$1=//p" "$JOB/job.env" | tail -1; }
job_env_set() {
  local f="$JOB/job.env"; touch "$f"
  grep -v "^$1=" "$f" > "$f.tmp" 2>/dev/null; printf '%s=%s\n' "$1" "$(oneline "$2")" >> "$f.tmp"; mv "$f.tmp" "$f"
}

# versions.tsv: key<TAB>type<TAB>value, shared by every gate's JSON "versions" block.
version_set() {
  mkdir -p "$STATE"; touch "$VERSIONS_TSV"
  local t=str; is_num "$2" && t=num
  awk -F'\t' -v k="$1" '$1 != k' "$VERSIONS_TSV" > "$VERSIONS_TSV.tmp"
  printf '%s\t%s\t%s\n' "$1" "$t" "$(oneline "$2")" >> "$VERSIONS_TSV.tmp"; mv "$VERSIONS_TSV.tmp" "$VERSIONS_TSV"
}

# ---------------------------------------------------------------- environment detection (never installs)
# CLT: present only if xcode-select points at a dir that really has clang and lipo.
clt_dir() { local d; d=$(xcode-select -p 2>/dev/null) || return 1; [ -x "$d/usr/bin/clang" ] && [ -x "$d/usr/bin/lipo" ] && printf '%s' "$d"; }
clt_ok() { clt_dir >/dev/null 2>&1; }
# python3 that is NOT the /usr/bin shim: CLT's, then Homebrew's. Empty when none.
python3_path() {
  local d; d=$(clt_dir 2>/dev/null) && [ -x "$d/usr/bin/python3" ] && { printf '%s' "$d/usr/bin/python3"; return 0; }
  for p in /opt/homebrew/bin/python3 /usr/local/bin/python3; do [ -x "$p" ] && { printf '%s' "$p"; return 0; }; done
  return 1
}
# macho_links_resolve FILE -> one line per load command: "ok DEP -> PATH" | "system DEP" (dyld shared
# cache, not on disk) | "MISSING DEP"; returns 1 if any is missing. Needs the CLT (otool).
macho_links_resolve() {
  local f=$1 ot dir dep rp cand found bad=0 self rpaths
  ot="$(clt_dir)/usr/bin/otool"; [ -x "$ot" ] || return 2
  dir=$(cd "$(dirname "$f")" && pwd -P); self=$(basename "$f")
  rpaths=$("$ot" -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}')
  echo "file $f"; echo "rpaths: $(printf '%s ' $rpaths)"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    [ "$(basename "$dep")" = "$self" ] && continue
    case "$dep" in
      /usr/lib/*|/System/*) echo "system $dep" ;;
      @loader_path/*) cand="$dir/${dep#@loader_path/}"
        if [ -e "$cand" ]; then echo "ok $dep -> $cand"; else echo "MISSING $dep ($cand)"; bad=1; fi ;;
      @rpath/*) found=""
        while IFS= read -r rp; do
          [ -n "$rp" ] || continue
          rp=${rp/@loader_path/$dir}; cand="$rp/${dep#@rpath/}"
          [ -e "$cand" ] && { found=$cand; break; }
        done <<EOF
$rpaths
EOF
        if [ -n "$found" ]; then echo "ok $dep -> $found"; else echo "MISSING $dep (rpaths: $(printf '%s ' $rpaths))"; bad=1; fi ;;
      *) if [ -e "$dep" ]; then echo "ok $dep"; else echo "MISSING $dep"; bad=1; fi ;;
    esac
  done <<EOF
$("$ot" -L "$f" | tail -n +2 | awk '{print $1}')
EOF
  echo "--- otool -L"; "$ot" -L "$f"
  return "$bad"
}
rosetta_ok() { [ -e /Library/Apple/usr/share/rosetta/rosetta ] && arch -x86_64 /usr/bin/true >/dev/null 2>&1; }
steam_app_path() { for a in /Applications/Steam.app "$HOME/Applications/Steam.app"; do [ -d "$a" ] && { printf '%s' "$a"; return 0; }; done; return 1; }
steam_running() { pgrep -x steam_osx >/dev/null 2>&1 || pgrep -f 'Steam.AppBundle/Steam/Contents/MacOS/steam_osx' >/dev/null 2>&1; }
# Steam's login/config files (registry.vdf, config/loginusers.vdf, config/*) are NEVER read by this kit
# (hub rule). "Steam running" = the steam_osx process; "signed in" is proven only by G-B1's probe
# (ISteamUser::BLoggedOn through the running client's public API).
# steam_client_version reads only the client package manifest (package/steam_client_osx.manifest).
steam_client_version() {
  local m="$STEAM_DATA/package/steam_client_osx.manifest"
  [ -f "$m" ] && grep -m1 '"version"' "$m" | sed 's/[^0-9]//g'
}
free_gb() { df -k "$HOME" | awk 'NR==2 { printf "%d", $4 / 1048576 }'; }

# ---------------------------------------------------------------- pre-existing state snapshot (for cleanup)
# Paths outside the job dir that a gate might create. Recorded once per job (first gate wins), so
# cleanup.sh removes only what did not exist before the job started.
outside_candidates() {
  cat <<EOF
$STEAM_DATA/steamapps/content/app_$PEAK_APPID
$STEAM_MACOS_DIR/steamapps/content/app_$PEAK_APPID
$STEAM_DATA/steamapps/downloading/$PEAK_APPID
$STEAM_MACOS_DIR/steamapps/downloading/$PEAK_APPID
$HOME/Library/Logs/$UNITY_COMPANY/$UNITY_PRODUCT
$HOME/Library/Logs/$UNITY_COMPANY
$HOME/Library/Application Support/$UNITY_COMPANY/$UNITY_PRODUCT
$HOME/Library/Application Support/$UNITY_COMPANY
$HOME/Library/Application Support/unity.$UNITY_COMPANY.$UNITY_PRODUCT
$HOME/Library/Preferences/unity.$UNITY_COMPANY.$UNITY_PRODUCT.plist
$HOME/Library/Saved Application State/com.peakpack.testkit.native.savedState
$HOME/Library/Caches/com.peakpack.testkit.native
$HOME/Library/Caches/$UNITY_COMPANY
EOF
}
depotcache_dirs() { printf '%s\n%s\n' "$STEAM_DATA/depotcache" "$STEAM_MACOS_DIR/depotcache"; }
snapshot_preexisting() {
  mkdir -p "$STATE"
  [ -s "$PRE_TSV" ] && return 0
  {
    printf '# taken %s\n' "$(now_utc)"
    outside_candidates | while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ -e "$p" ]; then printf '%s\t1\n' "$p"; else printf '%s\t0\n' "$p"; fi
    done
    depotcache_dirs | while IFS= read -r d; do
      [ -d "$d" ] || continue
      for f in "$d/${PEAK_DEPOT}"_*.manifest; do [ -e "$f" ] && printf '%s\t1\n' "$f"; done
    done
  } > "$PRE_TSV"
}
preexisted() { [ -f "$PRE_TSV" ] && awk -F'\t' -v p="$1" '$1 == p && $2 == 1 { f = 1 } END { exit !f }' "$PRE_TSV"; }
# outside_record PATH KIND NOTE  (KIND: created-by-us | steam-managed | system-managed)
outside_record() {
  mkdir -p "$STATE"; touch "$OUTSIDE_TSV"
  awk -F'\t' -v p="$1" '$1 != p' "$OUTSIDE_TSV" > "$OUTSIDE_TSV.tmp"
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${GATE_ID:-?}" "$(oneline "${3:-}")" >> "$OUTSIDE_TSV.tmp"; mv "$OUTSIDE_TSV.tmp" "$OUTSIDE_TSV"
}

# ---------------------------------------------------------------- gate lifecycle
gate_begin() {
  GATE_ID=$1; GATE_TITLE=$2
  GATE_START=$(now_utc); GATE_T0=$(now_s)
  GLOG="$JOB/logs/$GATE_ID"; GEVID="$JOB/evidence/$GATE_ID"; GTMP="$JOB/tmp/gate-$GATE_ID"
  mkdir -p "$GLOG" "$GEVID" "$GTMP" "$RESULTS" "$STATE" "$CU_DIR"
  : > "$GTMP/criteria.jsonl"; : > "$GTMP/metrics.tsv"; : > "$GTMP/notes.txt"; : > "$GTMP/cu.jsonl"; : > "$GTMP/evidence.txt"
  echo $$ > "$GTMP/pid"   # run_gate.sh's watchdog signals this shell directly on timeout
  GATE_STATUS=""; GATE_REASON=""; GATE_HUMAN=""; GATE_CLEANUP=""
  # Answers consumed by an earlier run of this gate are archived, so a re-run asks again.
  # Answers written ahead of time (no closed request yet, e.g. the early G-B5 download) stay.
  local f
  for f in "$CU_DIR/$GATE_ID".*.done; do
    [ -f "$f" ] && [ -f "${f%.done}.request.closed" ] || continue
    mkdir -p "$CU_DIR/history"
    mv "$f" "$CU_DIR/history/$(basename "$f").$GATE_T0"; mv "${f%.done}.request.closed" "$CU_DIR/history/$(basename "${f%.done}").request.$GATE_T0"
  done
  export PP_LOG_DIR="$GLOG/wine"
  trap 'gate_on_signal' TERM INT HUP
  log "== $GATE_ID: $GATE_TITLE (job $(basename "$JOB"), kit $PP_KIT_VERSION)"
  metric launchd_session "$(gui_session)" str   # Aqua = logged-in GUI session; Background = remote shell
}
# Gate scripts set GATE_CLEANUP to a function name that stops what they started (Wine, samplers).
gate_cleanup() { if [ -n "${GATE_CLEANUP:-}" ]; then local f=$GATE_CLEANUP; GATE_CLEANUP=""; "$f" || true; fi; }
gate_on_signal() {
  trap '' TERM INT HUP
  log "signal received: stopping (timeout or interrupt)"
  gate_cleanup
  GATE_STATUS=error; GATE_REASON="interrupted (run_gate.sh timeout or signal)"
  gate_write_json; exit 4
}
crit() {  # crit ID RESULT DESC [DETAIL]
  local id=$1 res=$2 desc=$3 det=${4:-}
  printf '{"id": %s, "result": %s, "check": %s, "detail": %s}\n' \
    "$(json_str "$id")" "$(json_str "$res")" "$(json_str "$desc")" "$(json_str "$(oneline "$det")")" >> "$GTMP/criteria.jsonl"
  printf '%-5s %s: %s%s\n' "$(printf '%s' "$res" | tr 'a-z' 'A-Z')" "$id" "$desc" "${det:+ ($(oneline "$det" | cut -c1-300))}"
}
metric() {  # metric KEY VALUE [str]   (numbers are written as JSON numbers unless "str" is given)
  local t=str; [ "${3:-}" != str ] && is_num "$2" && t=num
  case "$2" in true|false) [ "${3:-}" != str ] && t=raw ;; esac
  printf '%s\t%s\t%s\n' "$1" "$t" "$(oneline "$2")" >> "$GTMP/metrics.tsv"
}
note() { printf '%s\n' "$(oneline "$*")" >> "$GTMP/notes.txt"; log "note: $*"; }
evidence_add() { printf '%s\n' "$(rel_to_job "$1")" >> "$GTMP/evidence.txt"; }
crit_count() { grep -c "\"result\": \"$1\"" "$GTMP/criteria.jsonl" 2>/dev/null | tr -d ' '; }
crit_failed() { grep -q "^{\"id\": \"$1\", \"result\": \"fail\"" "$GTMP/criteria.jsonl" 2>/dev/null; }

# TSV (key, type, value; last value per key wins, first-seen order) -> JSON object members.
tsv_to_json_members() {
  awk -F'\t' '
    function jesc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    NF >= 3 { if (!($1 in v)) order[++n] = $1; v[$1] = $3; t[$1] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        k = order[i]
        printf "%s\n    %s: %s", (i > 1 ? "," : ""), jesc(k), (t[k] == "num" || t[k] == "raw") ? v[k] : jesc(v[k])
      }
    }' "$1"
}
lines_to_json_array() {  # file of lines -> JSON array members (sorted, unique)
  local first=1 l
  sort -u "$1" | while IFS= read -r l; do
    [ -n "$l" ] || continue
    if [ $first = 1 ]; then first=0; printf '\n    %s' "$(json_str "$l")"; else printf ',\n    %s' "$(json_str "$l")"; fi
  done
}
status_exit() { case "$1" in pass) echo 0 ;; fail) echo 1 ;; blocked) echo 2 ;; needs-human) echo 3 ;; *) echo 4 ;; esac; }

gate_write_json() {
  local f="$RESULTS/$GATE_ID.json" ev="$GTMP/evidence.all" st=${GATE_STATUS:-error}
  { cat "$GTMP/evidence.txt"
    for d in "$GLOG" "$GEVID"; do [ -d "$d" ] && find "$d" -type f 2>/dev/null | while IFS= read -r p; do rel_to_job "$p"; echo; done; done
  } > "$ev"
  local human=false; [ "$st" = needs-human ] && human=true
  {
    printf '{\n  "schema": 1,\n'
    printf '  "gate": %s,\n  "title": %s,\n' "$(json_str "$GATE_ID")" "$(json_str "$GATE_TITLE")"
    printf '  "status": %s,\n  "exit_code": %s,\n' "$(json_str "$st")" "$(status_exit "$st")"
    printf '  "reason": %s,\n' "$(json_str "$(oneline "$GATE_REASON")")"
    printf '  "started": %s,\n  "finished": %s,\n  "duration_s": %s,\n' "$(json_str "$GATE_START")" "$(json_str "$(now_utc)")" "$(( $(now_s) - GATE_T0 ))"
    printf '  "job_id": %s,\n  "host": %s,\n  "kit_version": %s,\n  "release": %s,\n' \
      "$(json_str "$(basename "$JOB")")" "$(json_str "$(hostname -s 2>/dev/null)")" "$(json_str "$PP_KIT_VERSION")" "$(json_str "${PP_RELEASE:-}")"
    printf '  "versions": {'; [ -f "$VERSIONS_TSV" ] && tsv_to_json_members "$VERSIONS_TSV"; printf '\n  },\n'
    printf '  "criteria": ['
    awk 'NR > 1 { printf "," } { printf "\n    %s", $0 }' "$GTMP/criteria.jsonl"
    printf '\n  ],\n'
    printf '  "metrics": {'; tsv_to_json_members "$GTMP/metrics.tsv"; printf '\n  },\n'
    printf '  "computer_use": ['; awk 'NR > 1 { printf "," } { printf "\n    %s", $0 }' "$GTMP/cu.jsonl"; printf '\n  ],\n'
    printf '  "evidence": ['; lines_to_json_array "$ev"; printf '\n  ],\n'
    printf '  "human": {"needed": %s, "instructions": %s},\n' "$human" "$(json_str "$GATE_HUMAN")"
    printf '  "notes": ['; lines_to_json_array "$GTMP/notes.txt"; printf '\n  ]\n}\n'
  } > "$f.tmp" && mv "$f.tmp" "$f"
}
gate_end() {
  trap '' TERM INT HUP
  gate_cleanup
  if [ -z "$GATE_STATUS" ]; then
    if [ "$(crit_count fail)" -gt 0 ]; then GATE_STATUS=fail; GATE_REASON=${GATE_REASON:-"$(crit_count fail) criterion/criteria failed"}
    elif [ "$(crit_count pass)" -gt 0 ]; then GATE_STATUS=pass
    else GATE_STATUS=error; GATE_REASON=${GATE_REASON:-"no criterion was evaluated"}
    fi
  fi
  gate_write_json
  local rc; rc=$(status_exit "$GATE_STATUS")
  if [ -n "$GATE_HUMAN" ]; then printf '\n---- NEEDS A HUMAN ----\n%s\n-----------------------\n' "$GATE_HUMAN"; fi
  log "== $GATE_ID: $(printf '%s' "$GATE_STATUS" | tr 'a-z' 'A-Z') (exit $rc) ${GATE_REASON:+- $GATE_REASON}"
  printf 'RESULT gate=%s status=%s exit=%s json=results/%s.json\n' "$GATE_ID" "$GATE_STATUS" "$rc" "$GATE_ID"
  exit "$rc"
}
gate_finish_as() {  # gate_finish_as STATUS REASON [HUMAN_INSTRUCTIONS]
  GATE_STATUS=$1; GATE_REASON=$2; GATE_HUMAN=${3:-}
  gate_end
}
# ---------------------------------------------------------------- GUI session (WindowServer access)
# Wine's Mac driver (winemac.drv) needs the logged-in user's GUI (Aqua) session. A remote shell (SSH,
# the hub's agent shell) is a "Background" session: windows cannot be created ("nodrv_CreateWindow:
# The graphics driver is missing"), explorer fails, D3D11 devices fail.
gui_session() { launchctl managername 2>/dev/null || echo unknown; }
gui_session_ok() { [ "${PP_ASSUME_GUI:-0}" = 1 ] || [ "$(gui_session)" = Aqua ]; }
GUI_HELP="Start the kit INSIDE the logged-in GUI session of this macOS user (launchctl managername must print Aqua), e.g.:
 - Terminal on the desktop (computer use): cd \$JOB/kit && bash testkit/run_slot.sh ...
 - from the remote shell: write the command into \$JOB/run.command, chmod +x it, then: open -a Terminal \$JOB/run.command
 - or, if the hub may: launchctl asuser \$(id -u) /bin/bash -c 'cd \$JOB/kit && bash testkit/run_slot.sh ...'
Check first: launchctl managername  (Aqua = OK; Background/StandardIO = remote shell). Override only for diagnostics: PP_ASSUME_GUI=1."
gate_require_gui() {
  local m; m=$(gui_session)
  gui_session_ok && return 0
  crit gui_session fail "running inside the logged-in GUI (Aqua) session" "launchctl managername = $m"
  gate_finish_as blocked "no GUI session: launchctl managername is '$m', not Aqua. Wine's Mac driver cannot open windows from a remote shell; start run_slot/run_gate inside the logged-in desktop session" "$GUI_HELP"
}
gate_require_mac() {
  [ "$(uname -s)" = Darwin ] || gate_finish_as blocked "this gate runs on macOS only (uname: $(uname -s))"
}

# ---------------------------------------------------------------- screenshots (best effort)
snap() {  # snap NAME -> evidence/<gate>/NAME.png
  [ "${PP_SNAP:-1}" = 0 ] && return 0
  command -v screencapture >/dev/null 2>&1 || return 0
  screencapture -x -t png "$GEVID/$1.png" >/dev/null 2>&1 && log "screenshot: evidence/$GATE_ID/$1.png" || log "screenshot $1 failed (no screen recording permission?)"
  return 0
}

# ---------------------------------------------------------------- computer-use handshake
# The hub's agent performs COMPUTER-USE steps that a script cannot (clicking in Steam/PEAK, reading
# the screen). A gate asks for one with cu_request; the agent answers by writing the .done file
# (testkit/cu.sh does it):
#   $JOB/cu/<gate>.<step>.request   written by the gate (key=value lines, then the instruction)
#   $JOB/cu/<gate>.<step>.done      written by the hub. Line 1: ok|fail|skip [free text];
#                                   further lines: key=value results (fps=58, path=..., answer=yes)
# An answer written before the request appears is accepted at once (pre-answered steps).
# PP_CU=none: no agent is watching; every request is answered "skip" immediately.
# cu_request STEP TIMEOUT_S "instruction" [poll_function]
#   -> 0 ok, 1 fail, 2 skip, 3 timeout. Sets CU_ANSWER, CU_NOTE, CU_DONE_FILE.
cu_request() {
  local step=$1 timeout=$2 text=$3 poll=${4:-} key req ans t0 first
  key="$GATE_ID.$step"; req="$CU_DIR/$key.request"; ans="$CU_DIR/$key.done"; CU_DONE_FILE=$ans
  CU_ANSWER=""; CU_NOTE=""
  if [ "${PP_CU:-handshake}" = none ] && [ ! -f "$ans" ]; then
    CU_ANSWER=skip; CU_NOTE="computer use disabled (PP_CU=none)"
  else
    if [ ! -f "$ans" ]; then
      { printf 'gate=%s\nstep=%s\ndoc=gates/%s.md#cu-%s\ntimeout_s=%s\ncreated=%s\nanswer_with=bash testkit/cu.sh %s done %s ok|fail|skip "note" [key=value ...]\n---\n%s\n' \
          "$GATE_ID" "$step" "$GATE_ID" "$step" "$timeout" "$(now_utc)" "$JOB" "$key" "$text"; } > "$req"
      log "[CU-REQUEST] $key (timeout ${timeout}s, see gates/$GATE_ID.md step CU-$step): $(oneline "$text" | cut -c1-240)"
    fi
    t0=$(now_s)
    while :; do
      if [ -f "$ans" ]; then
        first=$(head -1 "$ans" | tr -d '\r')
        CU_ANSWER=$(printf '%s' "$first" | awk '{print tolower($1)}'); CU_NOTE=$(printf '%s' "$first" | cut -d' ' -f2-)
        [ "$CU_NOTE" = "$first" ] && CU_NOTE=""
        break
      fi
      if [ -n "$poll" ] && "$poll"; then CU_ANSWER=ok; CU_NOTE="condition met without an answer file (auto)"; break; fi
      if [ $(( $(now_s) - t0 )) -ge "$timeout" ]; then CU_ANSWER=timeout; CU_NOTE="no answer within ${timeout}s"; break; fi
      sleep 5
    done
    [ -f "$req" ] && mv "$req" "$req.closed"
  fi
  [ -f "$ans" ] && cp "$ans" "$GLOG/cu-$step.answer.txt"
  printf '{"step": %s, "answer": %s, "note": %s, "at": %s}\n' "$(json_str "$step")" "$(json_str "$CU_ANSWER")" \
    "$(json_str "$(oneline "$CU_NOTE")")" "$(json_str "$(now_utc)")" >> "$GTMP/cu.jsonl"
  log "[CU-ANSWER] $key: $CU_ANSWER ${CU_NOTE:+- $CU_NOTE}"
  case "$CU_ANSWER" in ok) return 0 ;; skip) return 2 ;; timeout) return 3 ;; *) return 1 ;; esac
}
cu_kv() {  # value of KEY from the answer: key=value lines after line 1, or key=value words on line 1
  [ -f "${CU_DONE_FILE:-}" ] || return 0
  { sed -n '2,$p' "$CU_DONE_FILE"; head -1 "$CU_DONE_FILE" | tr ' ' '\n'; } | tr -d '\r' | sed -n "s/^$1=//p" | tail -1
}
