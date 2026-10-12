/*
 * steamclient64.dll - PeakPack for Mac Steam bridge forwarder.
 * Copyright (c) 2026 the PeakPack project. MIT licence (see docs/README.md).
 *
 * All exports live in steamclient64.def as PE forwarders to lsteamclient.dll.
 * This file only supplies the DLL entry point, so the DLL needs no C runtime
 * and imports nothing: the Windows loader (Wine's here) resolves each
 * forwarded export by loading lsteamclient.dll on first use.
 *
 * Built with -nostdlib (no headers needed): on x86_64 the entry point is
 * BOOL WINAPI DllMain(HINSTANCE, DWORD, LPVOID) with the one Win64 ABI.
 */

int peakpack_forwarder_entry(void *instance, unsigned long reason, void *reserved)
{
    (void)instance;
    (void)reason;
    (void)reserved;
    return 1; /* TRUE */
}
