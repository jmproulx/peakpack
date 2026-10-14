#!/bin/bash
# Builds "PEAK (Modded).app" (universal arm64 + x86_64) and its release zip. macOS only (CI runner).
#   APP_VERSION=0.1.0 APP_BUILD=42 bash mac/app/scripts/build_app.sh
# Signing: SIGN_IDENTITY defaults to "-" (ad-hoc). With a Developer ID later, set SIGN_IDENTITY to the
# "Developer ID Application: …" identity in the runner's keychain; nothing else changes (hardened runtime
# and entitlements are already applied). Notarisation is a separate optional step (notarize.sh).
# Output: mac/app/out/PEAK (Modded).app, mac/app/out/PEAK-Modded-Mac-<ver>.zip, mac/app/out/SHA256SUMS
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
VERSION="${APP_VERSION:?set APP_VERSION}"
BUILD="${APP_BUILD:-1}"
SIGN="${SIGN_IDENTITY:--}"
case "$VERSION" in *[!0-9.]*|"") echo "APP_VERSION must be dotted numbers: $VERSION" >&2; exit 2 ;; esac

OUT="$here/out"
APP="$OUT/PEAK (Modded).app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/LICENSES" "$APP/Contents/Helpers"

echo "== swift build (universal)"
swift build -c release --arch arm64 --arch x86_64 --product "PEAK Modded"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_DIR/PEAK Modded" "$APP/Contents/MacOS/PEAK Modded"
archs="$(lipo -archs "$APP/Contents/MacOS/PEAK Modded")"
echo "archs: $archs"
case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *) echo "not universal: $archs" >&2; exit 1 ;; esac

echo "== Info.plist + resources"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp kit/mac-kit.json "$APP/Contents/Resources/mac-kit.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$APP/Contents/Resources/mac-kit.json"
cp ../LICENSE "$APP/Contents/Resources/LICENSES/LICENSE-PEAK-Modded.txt"
cp packaging/NOTICE.txt "$APP/Contents/Resources/LICENSES/NOTICE.txt"

echo "== icon"
swift scripts/make_icon.swift "$OUT/icon_1024.png"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s" "$OUT/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); sips -z "$d" "$d" "$OUT/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "== Rosetta helper (x86_64 only)"
H="$APP/Contents/Helpers/PEAK Rosetta Check.app"
mkdir -p "$H/Contents/MacOS"
swiftc -O -target x86_64-apple-macos12.0 Helpers/RosettaCheck/main.swift -o "$H/Contents/MacOS/PEAK Rosetta Check"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@BUILD@/$BUILD/g" Helpers/RosettaCheck/Info.plist > "$H/Contents/Info.plist"
[ "$(lipo -archs "$H/Contents/MacOS/PEAK Rosetta Check")" = x86_64 ] || { echo "helper must be x86_64 only" >&2; exit 1; }

echo "== sign ($SIGN)"
ts=(); [ "$SIGN" != "-" ] && ts=(--timestamp)
codesign --force --options runtime ${ts[@]+"${ts[@]}"} --sign "$SIGN" "$H"
codesign --force --options runtime ${ts[@]+"${ts[@]}"} --entitlements packaging/entitlements.plist --sign "$SIGN" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input || { echo "entitlements missing" >&2; exit 1; }

echo "== zip"
ZIP="$OUT/PEAK-Modded-Mac-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS)
cat "$OUT/SHA256SUMS"
du -sh "$APP" "$ZIP"
