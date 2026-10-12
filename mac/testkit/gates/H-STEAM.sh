#!/bin/bash
# TITLE: Mac Steam signed in under this macOS user (needs Joshua when it is not)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Read-only check: Steam.app present, client bootstrapped, steam_osx running, and a logged-in
# account (registry.vdf ActiveUser, else a remembered login in loginusers.vdf). The real proof is
# G-B1 (BLoggedOn through Valve's steamclient.dylib).
#   pass         Steam running and logged in
#   needs-human  Steam installed but not logged in / not running with a remembered login (exit 3)
#   blocked      Steam.app is not installed (the hub installs it; exit 2)
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin H-STEAM "Mac Steam signed in"
gate_require_mac

INSTR="Joshua, on the iMac, macOS user 'fleet':
 1. Open Steam (Applications > Steam). If it updates itself, wait until the sign-in window appears.
 2. Sign in with your own Steam account (the one that owns PEAK). Approve the Steam Guard prompt on your phone or type the code.
 3. Tick 'Remember me' so the hub's agents never need you again for this.
 4. Leave Steam running (closing the window is fine; do not quit Steam).
 5. Tell the hub 'Steam is signed in'; it re-runs H-STEAM (about 10 seconds).
Nothing else is needed from you for slot 1."

if a=$(steam_app_path); then crit steam_app pass "Steam.app installed" "$a"
else
  crit steam_app fail "Steam.app installed" "not in /Applications or ~/Applications"
  gate_finish_as blocked "Mac Steam is not installed (the hub installs it from store.steampowered.com/about; no sign-in needed for that)"
fi
if [ -f "$STEAM_MACOS_DIR/steamclient.dylib" ]; then crit steam_boot pass "client bootstrapped (steamclient.dylib present)"
else crit steam_boot info "client not bootstrapped yet" "first start downloads it"; fi
if steam_running; then crit steam_running pass "steam_osx running"; else crit steam_running info "steam_osx not running"; fi
st=$(steam_login_state)
metric login_state "${st%% *}" str; metric login_evidence "${st#* }" str
case "$st" in
  yes*) crit steam_login pass "an account is logged in" "${st#* }" ;;
  *)    crit steam_login info "an account is logged in" "$st" ;;
esac
cv=$(steam_client_version); [ -n "$cv" ] && version_set steam_client "$cv"
snap h-steam-screen

case "$st" in yes*) gate_end ;; esac
# Files are not conclusive (registry.vdf/loginusers.vdf layouts on Mac are best effort): when Steam
# runs, let the hub's agent look at the window before asking Joshua.
if steam_running; then
  if cu_request signed_in 300 "Bring the Steam window to the front (click its Dock icon). Is an account signed in (Store/Library visible, account name at the top right) rather than the sign-in window? Take a screenshot evidence/H-STEAM/steam-window.png. Answer ok if signed in, fail if the sign-in window or a Steam Guard prompt shows. Do not type any credentials."; then
    crit steam_login_cu pass "agent sees a signed-in Steam window" "$CU_NOTE"
    gate_end
  fi
  crit steam_login_cu info "agent check of the Steam window" "$CU_ANSWER $CU_NOTE"
fi
case "$st" in
  unknown\ remembered*)
    gate_finish_as needs-human "Steam has a remembered login but is not running; the hub may simply open Steam (open -a Steam) and re-run H-STEAM. If the sign-in window appears, Joshua is needed." "$INSTR" ;;
  *) gate_finish_as needs-human "Mac Steam is not signed in" "$INSTR" ;;
esac
