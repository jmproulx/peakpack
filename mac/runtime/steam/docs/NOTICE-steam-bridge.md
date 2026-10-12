# PeakPack for Mac: Steam bridge notices

Shipped in `LICENSES/` of every `peakpack-steam-bridge-*` package.

| Part | Origin | Licence |
|---|---|---|
| `lib/wine/x86_64-windows/lsteamclient.dll`, `lib/wine/x86_64-unix/lsteamclient.so` | Built from Valve's `lsteamclient` in [ValveSoftware/Proton](https://github.com/ValveSoftware/Proton), tag `proton-11.0-2e`, commit `bc896217ffcd67f892f952b010f898fe7bd0f0a1`, plus the PeakPack patches in `mac/runtime/steam/patches/`. | Steamworks SDK licence (`lsteamclient-Steamworks-SDK-LICENSE.txt`). The sources are fetched from Valve's repository at build time and are not redistributed by PeakPack. |
| `cxx.h`, compiled into `lsteamclient.dll` | Wine project, via Proton | LGPL-2.1-or-later. The source is in the Proton commit above and in the Wine sources published with the PeakPack runtime. |
| Wine headers and import libraries used for the build | Wine, from CodeWeavers' CrossOver LGPL source release (see the runtime's `LICENSES/`) | LGPL-2.1-or-later |
| `share/peakpack/steam/steamclient64.dll` (export forwarder) | PeakPack | see `LICENSE-PeakPack-steam.txt` |
| `share/peakpack/steam/peakpack_steam_launcher.exe` | PeakPack, written from scratch. Its design follows Proton's `steam_helper` (`steam.exe`), which is BSD-3-Clause, Copyright (c) 2015, 2019, 2020, 2021, 2022 Valve Corporation. No Proton code is included. | see `LICENSE-PeakPack-steam.txt` |

PeakPack does not include, modify or redistribute the Steam client. The bridge
loads the `steamclient.dylib` of the player's own Mac Steam installation, and
every login and licence check is done by Valve's client.

NotProton (GPL-3) was read as a reference only. None of its code or scripts are
included.
