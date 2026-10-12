# PeakPack for Mac (build side)

Build scripts for running PEAK and the PeakPack mods on Apple Silicon Macs. These files are not
part of the Windows PeakPack app, and friends never download them: they download built files from
`mac-build-*` **prereleases**, which are never marked "latest". `releases/latest` always points to the
newest PeakPack pack release.

- `runtime/`: our pinned Wine runtime (CodeWeavers' CrossOver 26.3 LGPL sources, Wine 11.0 + msync)
  with DXMT, DXVK and MoltenVK; the Wine prefix settings; and the Steam bridge in `runtime/steam/`,
  which lets the game talk to the real Mac Steam client.
- Workflows: `.github/workflows/mac-runtime.yml` (manual build, optional prerelease) and
  `mac-runtime-lint.yml` (static checks).
- Corresponding sources: every runtime release carries `peakpack-runtime-src-*.tar.xz`. The unchanged
  CrossOver sources are in release `mac-build-src-cx<version>`.
- Valve's `lsteamclient` (Steamworks SDK licence) is fetched at build time from a pinned, hash-checked
  Proton commit. It is never committed here, and its sources are never published.

Licences: our own code under `mac/` is MIT (`LICENSE`). Third-party components keep their own
licences; see `runtime/docs/LICENSES.md`.
