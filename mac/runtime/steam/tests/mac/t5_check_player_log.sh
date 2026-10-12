#!/bin/bash
# t5_check_player_log.sh - T5: does PEAK's Player.log show Steam initialised
# with the real persona (DESIGN.md gate G-B2)? Read-only for the game and the
# Steam client; writes only into the logs dir.
#
# Usage: t5_check_player_log.sh [--player-log FILE] [--wineprefix DIR]
#                               [--expect-persona NAME] [--logs DIR]
#   --wineprefix defaults to $WINEPREFIX. --logs defaults to ./logs-<timestamp>
#   and receives a copy of Player.log plus t5_summary.txt.
# Exit: 0 all PASS, 1 any FAIL, 2 usage error or no log found.
#
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Log strings. Literals found in PEAK's Managed DLLs (PEAK_Data/Managed) on Joshua's
# PC and in the decompiled sources (_decompiled/); the Player.log of 2025-10-11 has them.
#   a PASS  "Steam runtime manager initialized: True"                 SteamCommon.dll
#   b FAIL  "[Steamworks.NET] SteamAPI_Init() failed."                SteamManagerAssembly.dll
#           "[Steamworks.NET] Could not load [lib]steam_api",
#           "[Steamworks.NET] Packsize Test returned false",
#           "[Steamworks.NET] DllCheck Test returned false",
#           "[Steamworks.NET] Shutting down because RestartAppIfNecessary returned true"
#                                                                     SteamManagerAssembly.dll
#           "[Steamworks.NET] Failed to initialize CSteamAPIContext"  com.rlabrecque.steamworks.net.dll
#           "Steam runtime manager initialized: False"                SteamCommon.dll
#         "Steam is not running" is NOT a PEAK literal: PEAK only tests SteamAPI.IsSteamRunning()
#         (Assembly-CSharp/Peak.Network/NetworkingUtilities.cs:51) and falls back to a random ID.
#   c       "Spawning myself (<NAME> [<seat>]) at ..."                Assembly-CSharp/CharacterSpawner.cs:242
#   d info  T6 "Lobby Created: <id>" (SteamLobbyHandler.cs:407), "Entered Steam Lobby: <id>" (:121)
#           T7 "Successfully got user token" (User/Portningsbolaget.Platforms/UserManager.cs),
#              "Photon Start" (Assembly-CSharp/Peak.Network/PhotonShim.cs:96)
#           T9 "Received User Stats from Steam"                       SteamCommon.dll
#      WARN "Failed to authenticate:" (UserManager.cs:118), "OnCustomAuthenticationFailed("
#           (PhotonRealtime/Photon.Realtime/SupportLogger.cs:284)
set -u

player=""
prefix="${WINEPREFIX:-}"
persona=""
logs=""

usage() {
  echo "usage: $0 [--player-log FILE] [--wineprefix DIR] [--expect-persona NAME] [--logs DIR]" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --player-log)     [ $# -ge 2 ] || usage; player=$2; shift 2 ;;
    --wineprefix)     [ $# -ge 2 ] || usage; prefix=$2; shift 2 ;;
    --expect-persona) [ $# -ge 2 ] || usage; persona=$2; shift 2 ;;
    --logs)           [ $# -ge 2 ] || usage; logs=$2; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$logs" ] || logs="./logs-$(date +%Y%m%d-%H%M%S)"

# Newest PEAK Player.log under the prefix: drive_c/users/*/AppData/LocalLow/<company>/PEAK/.
# "PEAK" is matched case-insensitively. Prints the chosen path, or nothing.
find_player_log() {
  best=""
  while IFS= read -r f; do
    if [ -z "$best" ] || [ "$f" -nt "$best" ]; then best=$f; fi
  done < <(find "$1/drive_c/users" -type f -iname 'Player.log' 2>/dev/null \
           | grep -i '/AppData/LocalLow/[^/]*/PEAK/Player\.log$')
  printf '%s' "$best"
}

if [ -z "$player" ]; then
  [ -n "$prefix" ] || { echo "give --player-log, --wineprefix, or set WINEPREFIX" >&2; usage; }
  player=$(find_player_log "$prefix")
  [ -n "$player" ] || { echo "no PEAK Player.log under $prefix/drive_c/users" >&2; exit 2; }
fi
[ -f "$player" ] || { echo "not a file: $player" >&2; exit 2; }

mkdir -p "$logs" || { echo "cannot create $logs" >&2; exit 2; }
copy="$logs/Player.log"
summary="$logs/t5_summary.txt"
cp "$player" "$copy" || { echo "cannot copy $player" >&2; exit 2; }
echo "Player.log: $player" | tee "$summary"

fails=0
row() {  # $1 check, $2 result, $3 detail
  printf '%-26s %-5s %s\n' "$1" "$2" "$3" | tee -a "$summary"
}
count() {  # lines containing the fixed string $1
  n=$(grep -a -F -c -- "$1" "$copy" 2>/dev/null)
  echo "${n:-0}"
}
first() {  # first line containing the fixed string $1, CR stripped
  grep -a -F -m1 -- "$1" "$copy" | tr -d '\r' | cut -c1-120
}

row "CHECK" "RES" "DETAIL"

# (a) Steam initialised with True
init_line=$(first 'Steam runtime manager initialized:')
if [ "$(count 'Steam runtime manager initialized: True')" -gt 0 ]; then
  row "a steam initialised" PASS "$init_line"
else
  row "a steam initialised" FAIL "${init_line:-line not found}"
  fails=$((fails + 1))
fi

# (b) no Steamworks.NET / Steam init failure strings
bad_found=""
bad_hits=0
while IFS= read -r pat; do
  [ -n "$pat" ] || continue
  n=$(count "$pat")
  if [ "$n" -gt 0 ]; then
    bad_hits=$((bad_hits + n))
    bad_found="$bad_found [$pat]"
  fi
done <<'EOF'
[Steamworks.NET] SteamAPI_Init() failed.
[Steamworks.NET] Could not load [lib]steam_api
[Steamworks.NET] Packsize Test returned false
[Steamworks.NET] DllCheck Test returned false
[Steamworks.NET] Shutting down because RestartAppIfNecessary returned true
[Steamworks.NET] Failed to initialize CSteamAPIContext
Steam runtime manager initialized: False
EOF
if [ "$bad_hits" -eq 0 ]; then
  row "b no steam init failures" PASS "0 failure lines"
else
  row "b no steam init failures" FAIL "$bad_hits line(s):$bad_found"
  fails=$((fails + 1))
fi

# (c) persona in the log (only when --expect-persona is given)
if [ -n "$persona" ]; then
  if [ "$(count "$persona")" -gt 0 ]; then
    spawn=$(first "Spawning myself ($persona [")
    row "c persona" PASS "'$persona' found; ${spawn:-no 'Spawning myself' line}"
  else
    row "c persona" FAIL "'$persona' not in log"
    fails=$((fails + 1))
  fi
else
  row "c persona" SKIP "no --expect-persona given"
fi

# (d) info for T6, T7, T9; warnings for the login and Photon auth failures
info() {  # $1 label, $2 fixed string
  n=$(count "$2")
  if [ "$n" -gt 0 ]; then row "$1" INFO "x$n  $(first "$2")"; else row "$1" INFO "not found"; fi
}
warn() {  # $1 label, $2 fixed string (presence is a warning)
  n=$(count "$2")
  if [ "$n" -gt 0 ]; then row "$1" WARN "x$n  $(first "$2")"; else row "$1" OK "absent"; fi
}
info "d T6 lobby created"    "Lobby Created: "
info "d T6 lobby entered"    "Entered Steam Lobby: "
info "d T7 login token ok"   "Successfully got user token"
info "d T7 photon start"     "Photon Start"
warn "d T7 login failed"     "Failed to authenticate:"
warn "d T7 photon auth fail" "OnCustomAuthenticationFailed("
info "d T9 user stats"       "Received User Stats from Steam"

echo "" | tee -a "$summary"
if [ "$fails" -eq 0 ]; then
  echo "T5 RESULT: PASS (summary: $summary)" | tee -a "$summary"
  exit 0
fi
echo "T5 RESULT: FAIL, $fails check(s) failed (summary: $summary)" | tee -a "$summary"
exit 1
