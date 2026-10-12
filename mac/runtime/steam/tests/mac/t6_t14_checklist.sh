#!/bin/bash
# t6_t14_checklist.sh - prints the manual checklist for tests T6 to T14 of the
# PEAK Steam bridge (DESIGN.md gates G-B3 and G-B4) and checks a collected
# Player.log for the evidence lines that T5 uses (t5_check_player_log.sh).
# Non-interactive and read-only: it prints text and reads the log argument only.
#
# Usage: t6_t14_checklist.sh PLAYER_LOG
#   FOUND / NOT FOUND: a log marker exists for that test (first matching line shown).
#   MANUAL: no log marker; a person has to watch the game (steps printed below).
#   Exit 0 when the log was read; 2 on usage error. FOUND/NOT FOUND does not set the exit code.
#
# Part of PeakPack for Mac (runtime/steam). MIT licence (see ../../docs/README.md).
#
# Log markers (literals and sources are listed in t5_check_player_log.sh):
#   T6  "Lobby Created: <digits>", "Entered Steam Lobby: <digits>"
#   T7  "Successfully got user token" (no "Failed to authenticate:" or "OnCustomAuthenticationFailed(")
#   T8  "Entered Steam Lobby:" (joiner side), "On Lobby Join Requested:", "Steam invite detected!"
#   T9  "Received User Stats from Steam"
set -u

if [ $# -ne 1 ] || [ ! -f "$1" ]; then
  echo "usage: $0 PLAYER_LOG" >&2
  exit 2
fi
log=$1

has()   { grep -a -E -q -- "$1" "$log"; }
first() { grep -a -E -m1 -- "$1" "$log" | tr -d '\r' | cut -c1-110; }
hits()  { n=$(grep -a -E -c -- "$1" "$log" 2>/dev/null); echo "${n:-0}"; }

# block <id> <title> <manual steps> <status> <detail>
block() {
  echo ""
  echo "== $1  $2"
  echo "   Manual: $3"
  echo "   Log:    $4${5:+  ($5)}"
}

echo "Checklist for T6 to T14. Player.log: $log ($(wc -l < "$log" | tr -d ' ') lines)"
echo "Each test: what it proves, the manual steps, and the log evidence status."

# T6
if has 'Lobby Created: [0-9]{10,}|Entered Steam Lobby: [0-9]{10,}'; then s=FOUND; d=$(first 'Lobby Created: [0-9]{10,}|Entered Steam Lobby: [0-9]{10,}'); else s="NOT FOUND"; d="no numeric lobby id"; fi
block T6 "Lobby create/enter gives valid lobby IDs (callback struct packing works)" \
  "on the Mac, create a lobby, then join it from Windows; IDs should be 64-bit numbers, never 0." "$s" "$d"

# T7
if has 'Successfully got user token' && ! has 'Failed to authenticate:' && ! has 'OnCustomAuthenticationFailed\('; then
  s=FOUND; d=$(first 'Successfully got user token')
else
  s="NOT FOUND"; d="fail lines: $(hits 'Failed to authenticate:') login, $(hits 'OnCustomAuthenticationFailed\(') photon"
fi
block T7 "Photon Steam auth succeeds" \
  "start PEAK on the Mac and reach the main menu; Photon should connect without an auth error. Note: PEAK sends CustomAuthenticationType.None with the SteamID as UserId (Assembly-CSharp/Peak.Network/NetworkingUtilities.cs:72), so the Steam ticket only goes to the login step (UserManager.cs)." "$s" "$d"

# T8
if has 'Entered Steam Lobby: |On Lobby Join Requested:|Steam invite detected!'; then s=FOUND; d=$(first 'Entered Steam Lobby: |On Lobby Join Requested:|Steam invite detected!'); else s="NOT FOUND"; d="no join markers"; fi
block T8 "Mac and Windows join each other both ways (friends list and +connect_lobby)" \
  "run two logs: Mac joins Windows's lobby (friends list, then +connect_lobby), and Windows joins the Mac's. Each side's Player.log needs a join marker." "$s" "$d"

# T9
if has 'Received User Stats from Steam'; then s=FOUND; d=$(first 'Received User Stats from Steam'); else s="NOT FOUND"; d=""; fi
block T9 "UserStatsReceived OK, reads work (no unlocks)" \
  "check that stats load and the achievement page reads values. Confirm nothing unlocked." "$s" "$d"

# T10
block T10 "avatars render" \
  "join a lobby and check that every player's Steam avatar shows on the lobby and HUD screens." "MANUAL" "no log marker"

# T11
crash_n=$(grep -a -i -E -c 'unhandled exception|NullReferenceException|access violation|segmentation fault' "$log" 2>/dev/null)
crash_n=${crash_n:-0}
block T11 "overlay invite button fails gracefully (no crash)" \
  "press the in-game invite button (the Steam overlay does not work on Mac). Expect nothing or a message, and no crash." "MANUAL" "crash markers in log: $crash_n"

# T12
block T12 "60 min on 8 GB memory/swap acceptable" \
  "run t12_memsample.sh --duration-min 60 while playing, then read its summary (swap growth under 1 GB)." "MANUAL" "see t12_memsample.sh"

# T13
block T13 "Steam client update/beta: T1 and T5 still pass" \
  "after a Steam client update or beta switch, rerun the T1 probe and t5_check_player_log.sh on a fresh Player.log." "MANUAL" "rerun t5_check_player_log.sh"

# T14
block T14 "restart Steam mid-game: no hard crash" \
  "start a game, quit and restart the Steam client, and check that PEAK keeps running or disconnects cleanly." "MANUAL" "crash markers in log: $crash_n"

echo ""
echo "Done. MANUAL items need a person at the Mac or the Windows PC."
exit 0
