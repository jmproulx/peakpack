#!/bin/bash
# TITLE: Mac Steam running under this macOS user (signed-in proof is G-B1)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Never reads Steam's login or config files (registry.vdf, loginusers.vdf, config/*): hub rule.
# Checks only: Steam.app present, client bootstrapped (steamclient.dylib exists), steam_osx running.
# "Signed in" is proven by G-B1 (ISteamUser::BLoggedOn through the running client's public API).
# Optional: --confirm-window asks the hub's agent for a screenshot of the Steam window (computer use).
#   pass         steam_osx is running
#   needs-human  Steam installed but not running (exit 3; the hub may simply run: open -a Steam), or the
#                agent saw a sign-in window (--confirm-window)
#   blocked      Steam.app is not installed (the hub installs it; exit 2)
# Args: [--confirm-window]
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin H-STEAM "Mac Steam running"
gate_require_mac
confirm=0
while [ $# -gt 0 ]; do case "$1" in --confirm-window) confirm=1; shift ;; *) shift ;; esac; done

INSTR="Joshua, on the iMac, macOS user 'fleet':
 1. Open Steam (Applications > Steam). If it updates itself, wait until it finishes.
 2. If a sign-in window shows: sign in with your own Steam account (the one that owns PEAK), approve Steam Guard, tick 'Remember me'.
 3. Leave Steam running (closing the window is fine; do not quit Steam).
 4. Tell the hub 'Steam is running'; it re-runs H-STEAM (about 10 seconds) and G-B1 confirms the login."

if a=$(steam_app_path); then crit steam_app pass "Steam.app installed" "$a"
  version_set steam_app_version "$(defaults read "$a/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
else
  crit steam_app fail "Steam.app installed" "not in /Applications or ~/Applications"
  gate_finish_as blocked "Mac Steam is not installed (the hub installs it from store.steampowered.com/about; no sign-in needed for that)"
fi
if [ -f "$STEAM_MACOS_DIR/steamclient.dylib" ]; then crit steam_boot pass "client bootstrapped (steamclient.dylib present)"
else crit steam_boot info "client not bootstrapped yet" "first start downloads it"; fi
cv=$(steam_client_version); [ -n "$cv" ] && version_set steam_client "$cv"

if ! steam_running; then
  crit steam_running fail "steam_osx running"
  gate_finish_as needs-human "Mac Steam is not running. The hub may start it with: open -a Steam (no credentials), wait ~30 s and re-run H-STEAM. Joshua is needed only if a sign-in window appears." "$INSTR"
fi
crit steam_running pass "steam_osx running"
note "signed-in state is not checked here (no login files are read); G-B1's BLoggedOn decides"

if [ "$confirm" = 1 ]; then
  if cu_request steam_window 300 "Bring the Steam window to the front (click its Dock icon). Take a screenshot evidence/H-STEAM/steam-window.png (bash testkit/cu.sh <job-dir> shot H-STEAM steam-window). Answer ok if the Store/Library shows, fail if a sign-in window or Steam Guard prompt shows. Do not type any credentials."; then
    crit steam_window pass "agent sees the Steam main window" "$CU_NOTE"
  elif [ "${CU_ANSWER:-}" = fail ]; then
    crit steam_window fail "agent sees the Steam main window" "$CU_NOTE"
    gate_finish_as needs-human "Steam shows a sign-in window or Steam Guard prompt" "$INSTR"
  else
    crit steam_window info "agent check of the Steam window" "${CU_ANSWER:-no answer} ${CU_NOTE:-}"
  fi
fi
gate_end
