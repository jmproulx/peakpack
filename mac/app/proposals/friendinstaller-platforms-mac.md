# Proposal to the FriendInstaller/PeakPack owner: three signed `platforms.mac` fields

*From the Mac app lead (mac/app), 14 Oct 2026. Routed through main. All three fields are optional and additive. Manifest schema 1 stays as it is: the Windows app and older Mac builds ignore unknown fields.*

The Mac app already verifies `manifest.json` + `.sig` with the pack's public key. It takes PeakPack.exe from the signed `app` entry, and it honours `platforms.mac.minFrontEnd`. Today two things it installs are trusted only through HTTPS and the release's `SHA256SUMS`: the Wine runtime (whose pin is baked into each app version) and the app's own self-update. These fields move both under Joshua's signature, and they make PEAK-update detection exact.

## 1. `platforms.mac.runtime` (priority: high)

```json
"platforms": { "mac": {
  "runtime": {
    "id": "pp2-cx26.3.0",
    "tag": "mac-build-runtime-pp2-cx26.3.0",
    "asset": "peakpack-runtime-pp2-cx26.3.0-x86_64.tar.xz",
    "sha256": "<64 hex>",
    "size": 160000000
  }
}}
```

**Publisher:**
- `publish.json` `mac.runtime.tag` names a `mac-build-runtime-*` prerelease.
- At `prepare`, the publisher downloads that release's `SHA256SUMS` and takes the line for `peakpack-runtime-<id>-x86_64.tar.xz`.
- It fills in `id`/`asset`/`sha256`/`size`, and prints them in "What friends will get".

**Validation** (refuse to publish otherwise; the app enforces the same rules and falls back to its embedded pin):
- `id` matches `^pp[0-9]+-cx[0-9.]+$`;
- `tag` = `mac-build-runtime-` + `id`;
- `asset` ends in `.tar.xz` and contains no `/`;
- `sha256` is 64 hex characters.

**Front end:**
- When the signed pin differs from the active runtime, the app downloads the new runtime and verifies it against the pin AND the release's `SHA256SUMS`.
- It unpacks it next to the old one and updates the prefix.
- Only then does it switch. On failure it keeps the old one.

**Why:** a runtime update (for example pp2 with the launcher's auth-ticket warm-up and `--hold-until-exit`) can then reach friends with a pack revision, without a new app build. It is also signed by Joshua's key instead of trusting GitHub alone.

## 2. `platforms.mac.frontEnd` (priority: medium)

```json
"frontEnd": { "version": "0.2.0", "tag": "mac-build-app-0.2.0",
              "zip": "PEAK-Modded-Mac-0.2.0.zip", "sha256": "<64 hex>" }
```

**Publisher:** reads the app release's `SHA256SUMS`, the same way as for the runtime.

**Front end:**
- When present, self-update uses exactly this version and requires the zip's SHA-256 to match the signed value. Without it, the app falls back to "the newest `mac-build-app-*` prerelease + its SHA256SUMS".
- `minFrontEnd` keeps its current meaning: "you must update before playing".

**Why:** until there is an Apple Developer ID, this is the only provenance check stronger than HTTPS for the app's self-update.

## 3. `gameDepot` (priority: medium; top level or under `platforms.mac`)

```json
"gameDepot": { "appId": 3527290, "depotId": 3527291, "manifestId": "<gid>", "buildId": "25739797" }
```

**Publisher:**
- Reads the depot manifest gid and build id from Joshua's own install's `steamapps/appmanifest_3527290.acf` (`InstalledDepots/3527291/manifest`, `buildid`).
- That file is an install record, not a login or config file. If it is unreadable, the field is omitted.

**Front end:**
- If the installed copy's manifest id (recorded from `download_depot`'s completion line) differs from `gameDepot.manifestId`, and the pack is newer than the install, the app offers "PEAK has an update". The friend then does the same one-paste download.
- Today the app infers this from Mac Steam's appinfo cache and `gameVersion`. This field makes it exact, and it tells friends to update exactly when Joshua's own game did.

## Not proposed

- `NativeMac` platform kind (MacPort DESIGN §6.3e): Track C's request, unchanged; it belongs to the native track.
- Anything that downloads or runs code from the manifest: the manifest stays pure data.
