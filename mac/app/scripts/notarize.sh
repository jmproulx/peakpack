#!/bin/bash
# Optional: Developer ID signing + notarisation + stapling. Runs in CI only when the MAC_DEVID_* secrets
# exist (Joshua's decision: an Apple Developer ID). Without them the ad-hoc build from build_app.sh ships.
# Inputs (env): MAC_DEVID_P12 (base64 .p12), MAC_DEVID_P12_PASSWORD, MAC_DEVID_IDENTITY
#   ("Developer ID Application: Name (TEAMID)"), MAC_NOTARY_APPLE_ID, MAC_NOTARY_TEAM_ID,
#   MAC_NOTARY_PASSWORD (app-specific password), APP_VERSION, APP_BUILD.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
: "${MAC_DEVID_P12:?}" "${MAC_DEVID_P12_PASSWORD:?}" "${MAC_DEVID_IDENTITY:?}"
: "${MAC_NOTARY_APPLE_ID:?}" "${MAC_NOTARY_TEAM_ID:?}" "${MAC_NOTARY_PASSWORD:?}"
kc="$RUNNER_TEMP/devid.keychain-db"; kcpw="$(uuidgen)"
security create-keychain -p "$kcpw" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$kcpw" "$kc"
printf '%s' "$MAC_DEVID_P12" | base64 --decode > "$RUNNER_TEMP/devid.p12"
security import "$RUNNER_TEMP/devid.p12" -k "$kc" -P "$MAC_DEVID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$kcpw" "$kc" >/dev/null
# shellcheck disable=SC2046  # word splitting of the existing keychain list is intended
security list-keychains -d user -s "$kc" $(security list-keychains -d user | tr -d '"')
rm -f "$RUNNER_TEMP/devid.p12"
# Rebuild with the real identity (same script, same entitlements, hardened runtime already on).
SIGN_IDENTITY="$MAC_DEVID_IDENTITY" bash "$here/scripts/build_app.sh"
zip="$here/out/PEAK-Modded-Mac-$APP_VERSION.zip"
xcrun notarytool submit "$zip" --apple-id "$MAC_NOTARY_APPLE_ID" --team-id "$MAC_NOTARY_TEAM_ID" \
  --password "$MAC_NOTARY_PASSWORD" --wait --timeout 30m
xcrun stapler staple "$here/out/PEAK (Modded).app"
spctl --assess --type execute --verbose "$here/out/PEAK (Modded).app"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$here/out/PEAK (Modded).app" "$zip"
(cd "$here/out" && shasum -a 256 "$(basename "$zip")" > SHA256SUMS)
security delete-keychain "$kc"
