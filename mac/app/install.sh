#!/bin/bash
# PEAK (Modded) for Mac: one-line installer.
#   curl -fsSL https://raw.githubusercontent.com/jmproulx/peakpack/master/mac/app/install.sh | bash
# Downloads the app release pinned below, checks its SHA-256, puts it in Applications and opens it.
# Uses only macOS built-ins. Never uses sudo. Touches nothing but a temp folder and the app itself.
set -euo pipefail

APP_VERSION="0.1.6"
APP_TAG="mac-build-app-${APP_VERSION}"
APP_ZIP="PEAK-Modded-Mac-${APP_VERSION}.zip"
APP_SHA256="0e25a2cde64452d253cfc41187b4cb418a8eaafab9d3ba60076dd7a06f96b99a"
APP_NAME="PEAK (Modded).app"
BASE="https://github.com/jmproulx/peakpack/releases/download/${APP_TAG}"

say()  { printf '%s\n' "$*"; }
fail() { printf '\nSorry, the install stopped: %s\nNothing was changed. Send this message to Joshua.\n' "$*" >&2; exit 1; }

# ---- checks
[ "$(uname -s)" = "Darwin" ] || fail "this installer is for macOS."
[ "$(uname -m)" = "arm64" ] || fail "PEAK for Mac needs an Apple silicon Mac (M1 or newer)."
os_major=$(sw_vers -productVersion | cut -d. -f1)
[ "${os_major:-0}" -ge 14 ] || fail "PEAK for Mac needs macOS 14 Sonoma or newer (this Mac has $(sw_vers -productVersion)). Update in System Settings > General > Software Update."

TMP=$(mktemp -d "${TMPDIR:-/tmp}/peak-modded-install.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

say "Installing PEAK (Modded) ${APP_VERSION}..."

# ---- download + verify (pinned hash, cross-checked against the release's SHA256SUMS)
[ "${PEAK_INSTALL_DRYRUN:-0}" = 1 ] && { say "(dry run: checks passed, stopping before the download)"; exit 0; }
curl -fsSL --retry 3 -o "$TMP/$APP_ZIP" "$BASE/$APP_ZIP" || fail "couldn't download the app. Check your internet connection and try again."
got=$(shasum -a 256 "$TMP/$APP_ZIP" | awk '{print $1}')
[ "$got" = "$APP_SHA256" ] || fail "the download didn't match the expected fingerprint."
if curl -fsSL --retry 2 -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS"; then
  listed=$(awk -v f="$APP_ZIP" '$2==f || $2=="*"f {print $1}' "$TMP/SHA256SUMS" | head -1)
  [ -z "$listed" ] || [ "$listed" = "$APP_SHA256" ] || fail "the release's checksum list disagrees with this installer."
fi

# ---- unpack
mkdir -p "$TMP/unzip"
ditto -x -k "$TMP/$APP_ZIP" "$TMP/unzip" || fail "couldn't unpack the download."
src=$(find "$TMP/unzip" -maxdepth 2 -type d -name "$APP_NAME" | head -1)
[ -n "$src" ] && [ -d "$src/Contents/MacOS" ] || fail "the download didn't contain the app."
codesign --verify --deep "$src" >/dev/null 2>&1 || fail "the app's signature check failed."

# ---- install into /Applications (or ~/Applications if that isn't writable), replacing an older copy
dest_dir="/Applications"
[ -w "$dest_dir" ] || { dest_dir="$HOME/Applications"; mkdir -p "$dest_dir"; }
dest="$dest_dir/$APP_NAME"
# quit an older copy if it's open (plain substring match on its own path, no regex)
old_pids=$(ps -axo pid=,command= | awk -v p="$dest/Contents/MacOS/" 'index($0, p) { print $1 }')
# shellcheck disable=SC2086  # one PID per word, on purpose
[ -z "$old_pids" ] || { kill $old_pids 2>/dev/null || true; sleep 1; }
if [ -e "$dest" ]; then
  rm -rf "$dest.previous"
  mv "$dest" "$dest.previous"
fi
if ditto "$src" "$dest"; then
  rm -rf "$dest.previous"
else
  [ -e "$dest.previous" ] && mv "$dest.previous" "$dest"
  fail "couldn't copy the app into $dest_dir."
fi
# Our own freshly verified bundle only: make sure macOS doesn't treat it as a browser download.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

say "Installed to $dest"

# ---- Steam for Mac: PEAK (Modded) needs it signed in with your own account. If it's missing,
# install Valve's official Steam.app (from Valve's CDN, checked against Apple's notarization and
# Valve's signature). If anything about that fails, open Steam's download page instead.
steam_app=""
for d in /Applications "$HOME/Applications"; do [ -d "$d/Steam.app" ] && steam_app="$d/Steam.app" && break; done
if [ -z "$steam_app" ]; then
  say "Steam isn't installed yet, so getting Steam for Mac from Valve..."
  steam_ok=0
  if curl -fsSL --retry 3 -o "$TMP/steam.dmg" "https://cdn.fastly.steamstatic.com/client/installer/steam.dmg"; then
    mnt="$TMP/steam-mnt"; mkdir -p "$mnt"
    if hdiutil attach -nobrowse -readonly -quiet -mountpoint "$mnt" "$TMP/steam.dmg"; then
      signer=""
      [ -d "$mnt/Steam.app" ] && signer=$(codesign -dv --verbose=2 "$mnt/Steam.app" 2>&1 || true)
      case "$signer" in
        *"Authority=Developer ID Application: Valve Corporation"*)
          if codesign --verify --deep --strict "$mnt/Steam.app" >/dev/null 2>&1 \
             && spctl --assess --type execute "$mnt/Steam.app" >/dev/null 2>&1; then
            ditto "$mnt/Steam.app" "$dest_dir/Steam.app" && steam_app="$dest_dir/Steam.app" && steam_ok=1
          fi ;;
      esac
      hdiutil detach -quiet "$mnt" 2>/dev/null || hdiutil detach -force -quiet "$mnt" 2>/dev/null || true
    fi
  fi
  if [ "$steam_ok" = 1 ]; then
    say "Steam installed. It opens now: sign in with YOUR Steam account (the one that owns PEAK)."
    say "Let Steam finish updating itself, then come back to PEAK (Modded)."
    open "$steam_app"
  else
    say "Couldn't install Steam automatically, so opening Steam's download page. Install it, open it, and sign in."
    open "https://store.steampowered.com/about/"
  fi
elif ! pgrep -xq steam_osx; then
  say "Opening Steam: sign in if it asks."
  open "$steam_app"
fi

say "Opening PEAK (Modded) now. Click \"Set Up PEAK\" and follow the steps."
open "$dest"
