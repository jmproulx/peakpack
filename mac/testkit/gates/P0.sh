#!/bin/bash
# TITLE: Preflight: detect and report the Mac's state (never installs anything)
# Part of PeakPack for Mac (mac/testkit). MIT licence. Run through run_gate.sh.
#
# Reports: macOS version/build, arch, model, memory, free disk, Rosetta 2, Xcode CLT (+python3),
# Mac Steam installed/bootstrapped/running/logged in (best effort), screen capture, network
# reachability (github.com, download.unity3d.com), stray Wine processes, display.
# Status: fail = not an Apple Silicon Mac or the job dir is unusable; blocked = Rosetta missing,
# disk < 12 GB free or GitHub unreachable (every Wine/Steam gate depends on them); else pass.
# CLT, Steam and screen capture are reported, not required here (the gates that need them check).
set -u
. "$PP_KIT_DIR/lib/common.sh"
gate_begin P0 "Preflight"
gate_require_mac

# --- system
osv=$(sw_vers -productVersion 2>/dev/null); osb=$(sw_vers -buildVersion 2>/dev/null)
arch=$(uname -m); model=$(sysctl -n hw.model 2>/dev/null); cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
mem_gb=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
version_set macos "$osv"; version_set macos_build "$osb"; version_set arch "$arch"; version_set model "$model"
version_set cpu "$cpu"; version_set memory_gb "$mem_gb"
metric macos "$osv" str; metric macos_build "$osb" str; metric arch "$arch"; metric model "$model"; metric cpu "$cpu"; metric memory_gb "$mem_gb"
metric user "$(id -un)"
{ sw_vers; uname -a; sysctl hw.model hw.memsize machdep.cpu.brand_string 2>/dev/null; } > "$GLOG/system.txt" 2>&1
if [ "$arch" = arm64 ]; then crit arch pass "Apple Silicon (arm64)" "$cpu, $model, ${mem_gb} GB"
else crit arch fail "Apple Silicon (arm64) expected" "uname -m = $arch"; fi
osmaj=${osv%%.*}
if [ "${osmaj:-0}" -ge 12 ] 2>/dev/null; then crit macos pass "macOS 12 or newer" "$osv ($osb)"; else crit macos warn "macOS 12 or newer recommended" "$osv"; fi

# --- Rosetta (detect only; installing is the hub's/Joshua's call)
if rosetta_ok; then crit rosetta pass "Rosetta 2 installed (arch -x86_64 works)"; metric rosetta true
else crit rosetta fail "Rosetta 2 installed" "missing: the hub/Joshua installs it (softwareupdate --install-rosetta); this kit never installs it"; metric rosetta false; fi

# --- Xcode Command Line Tools (detect only; calling a shim without them pops up an install dialog)
if d=$(clt_dir); then
  crit clt info "Xcode Command Line Tools present" "$d"
  metric clt true; version_set clt "$(pkgutil --pkg-info=com.apple.pkg.CLTools_Executables 2>/dev/null | sed -n 's/^version: //p')"
else
  crit clt info "Xcode Command Line Tools absent" "G-B0 uses a no-CLT fallback; G-B1 needs a prebuilt probe or the CLT"
  metric clt false
fi
if py=$(python3_path); then metric python3 "$py" str; else metric python3 none str; fi

# --- disk
fg=$(free_gb); metric free_disk_gb "$fg"
if [ "$fg" -ge 20 ]; then crit disk pass "free disk >= 20 GB in \$HOME" "${fg} GB"
elif [ "$fg" -ge 12 ]; then crit disk warn "free disk >= 20 GB recommended (slot 1 needs about 8 GB, G-C0 another 6 GB)" "${fg} GB"
else crit disk fail "free disk >= 12 GB" "${fg} GB"; fi

# --- job dir sanity
if touch "$JOB/tmp/.w" 2>/dev/null && rm -f "$JOB/tmp/.w"; then crit jobdir pass "job dir writable" "$JOB"; else crit jobdir fail "job dir writable" "$JOB"; fi
metric job_dir "$JOB" str

# --- network
for u in https://github.com https://objects.githubusercontent.com https://download.unity3d.com; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 15 -I "$u" 2>/dev/null)
  metric "http_$(printf '%s' "$u" | sed 's#https://##; s#[^a-z0-9]#_#g')" "$code" str
  case "$u" in
    https://github.com) case "$code" in 2*|3*) crit net_github pass "github.com reachable" "HTTP $code" ;; *) crit net_github fail "github.com reachable" "HTTP ${code:-none}" ;; esac ;;
    *download.unity3d*) case "$code" in 2*|3*|403) crit net_unity info "download.unity3d.com reachable (G-C0 only)" "HTTP $code" ;; *) crit net_unity warn "download.unity3d.com reachable (G-C0 only)" "HTTP ${code:-none}" ;; esac ;;
  esac
done

# --- Mac Steam (read-only; this kit never starts, stops or changes Steam)
if a=$(steam_app_path); then crit steam_app info "Steam.app installed" "$a"; metric steam_app "$a" str
  version_set steam_app_version "$(defaults read "$a/Contents/Info" CFBundleShortVersionString 2>/dev/null)"
else crit steam_app info "Steam.app not found in /Applications or ~/Applications" "G-B gates will be blocked"; metric steam_app none str; fi
if [ -f "$STEAM_MACOS_DIR/steamclient.dylib" ]; then crit steam_boot info "Steam client bootstrapped (steamclient.dylib present)"; metric steam_bootstrapped true
else crit steam_boot info "Steam client not bootstrapped yet (no steamclient.dylib)"; metric steam_bootstrapped false; fi
cv=$(steam_client_version); [ -n "$cv" ] && { version_set steam_client "$cv"; metric steam_client_version "$cv" str; }
if steam_running; then metric steam_running true; else metric steam_running false; fi
# Steam login/config files are never read (hub rule); G-B1's BLoggedOn proves the login.
gs=$(gui_session); metric gui_session "$gs" str
if [ "$gs" = Aqua ]; then crit gui_session pass "running inside the logged-in GUI (Aqua) session" "$gs"
else crit gui_session warn "running inside the logged-in GUI (Aqua) session" "launchctl managername = $gs: Wine windows (G-A1, G-B2, G-D2, G-A2-lite, G-C0) will be blocked; start the kit inside the desktop session"; fi

# --- screen capture: only with PP_SCREENSHOTS=1 (screencapture raises the Screen Recording prompt otherwise)
if ! screenshots_on; then
  crit screencapture info "in-kit screenshots" "off (default; PP_SCREENSHOTS=1 enables them; evidence screenshots are the hub's)"
  metric screencapture off str
elif command -v screencapture >/dev/null 2>&1 && screencapture -x -t png "$GEVID/p0-screen.png" 2>/dev/null && [ -s "$GEVID/p0-screen.png" ]; then
  crit screencapture pass "screencapture -x works" "$(file_size "$GEVID/p0-screen.png") bytes (if it shows only wallpaper, the grant is missing)"
  metric screencapture true
else
  crit screencapture warn "screencapture -x works" "failed: gates fall back to the hub's own computer-use screenshots"
  metric screencapture false
fi
system_profiler SPDisplaysDataType > "$GLOG/displays.txt" 2>/dev/null
metric display "$(sed -n 's/^ *Resolution: //p' "$GLOG/displays.txt" | head -1)" str
metric gpu "$(sed -n 's/^ *Chipset Model: //p' "$GLOG/displays.txt" | head -1)" str

# --- tools the kit relies on (all macOS base system)
missing=""
for t in curl shasum tar awk sed grep pgrep pkill plutil pkgutil codesign screencapture memory_pressure vm_stat sysctl caffeinate defaults file od dd; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -z "$missing" ]; then crit tools pass "base tools present"; else crit tools fail "base tools present" "missing:$missing"; fi
tar --version > "$GLOG/tar-version.txt" 2>&1

# --- leftovers that would disturb the tests
wp=$(pgrep -fl 'wineserver|wine64-preloader|wine-preloader|PEAK\.exe' 2>/dev/null | grep -v pgrep)
if [ -n "$wp" ]; then printf '%s\n' "$wp" > "$GLOG/wine-processes.txt"; crit stray_wine warn "no Wine/PEAK processes running before the job" "$(printf '%s' "$wp" | wc -l | tr -d ' ') found (see wine-processes.txt; not ours, left alone)"
else crit stray_wine pass "no Wine/PEAK processes running before the job"; fi
for p in "$STEAM_DATA/steamapps/content/app_$PEAK_APPID" "$STEAM_MACOS_DIR/steamapps/content/app_$PEAK_APPID"; do
  [ -e "$p" ] && note "pre-existing Steam depot folder (not ours, cleanup leaves it): $p"
done
cp "$PRE_TSV" "$GLOG/preexisting.tsv" 2>/dev/null

# --- verdict: arch/jobdir/tools failures = fail; rosetta/disk/github = blocked; warnings do not fail
if crit_failed arch || crit_failed jobdir || crit_failed tools; then gate_end; fi
if crit_failed rosetta || crit_failed disk || crit_failed net_github; then
  gate_finish_as blocked "preconditions missing for the Wine/Steam gates (see criteria rosetta, disk, net_github)"
fi
gate_end
