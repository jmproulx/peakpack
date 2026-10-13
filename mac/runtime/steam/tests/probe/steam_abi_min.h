/*
 * steam_abi_min.h - the few Steamworks client ABI facts our probes need.
 * Copyright (c) 2026 the PeakPack project. MIT licence (see ../../docs/README.md).
 *
 * Written by us from the public Steamworks interface layout (vtable slot
 * order of the published interface versions), not copied from Valve's
 * headers. Only what T1-T4 call is described. Slot numbers count every
 * virtual method in declaration order, including STEAM_PRIVATE_API ones.
 *
 * Calling convention: on x86_64 a C++ virtual call is a plain call with the
 * object pointer as the first argument, on both SysV (macOS) and Win64.
 * One ABI difference matters: a member function returning a class (CSteamID)
 * returns it in RAX on SysV (8-byte trivially copyable class), but through a
 * hidden result pointer (2nd argument) under the MSVC ABI, which is what
 * Windows-side callers of lsteamclient / steamclient64 see.
 */
#ifndef PEAKPACK_STEAM_ABI_MIN_H
#define PEAKPACK_STEAM_ABI_MIN_H

#include <stdint.h>
#include <stdbool.h>

typedef int32_t HSteamPipe;
typedef int32_t HSteamUser;
typedef uint32_t HAuthTicket;
typedef uint64_t SteamAPICall_t;

/* exported by steamclient.dylib / steamclient64.dll / lsteamclient.dll */
typedef void *(*pfn_CreateInterface)(const char *version, int *return_code);
typedef struct CallbackMsg CallbackMsg;
typedef bool (*pfn_Steam_BGetCallback)(HSteamPipe pipe, CallbackMsg *msg, int32_t *call);
typedef bool (*pfn_Steam_FreeLastCallback)(HSteamPipe pipe);
typedef bool (*pfn_Steam_IsKnownInterface)(const char *version);

/* CallbackMsg_t: same field offsets on every 64-bit platform; only the total
 * size differs (20 with Mac/Linux pack(4), 24 with Windows pack(8)). */
#if defined(_WIN32)
#pragma pack(push, 8)
#else
#pragma pack(push, 4)
#endif
struct CallbackMsg
{
    HSteamUser user;      /* 0 */
    int32_t callback_id;  /* 4 */
    uint8_t *param;       /* 8 */
    int32_t param_size;   /* 16 */
};
#pragma pack(pop)

/* GetAuthSessionTicketResponse_t: k_iSteamUserCallbacks (100) + 63; 8 bytes */
#define CALLBACK_GET_AUTH_SESSION_TICKET_RESPONSE 163
struct GetAuthSessionTicketResponse
{
    HAuthTicket ticket;
    int32_t result;       /* EResult, 1 = k_EResultOK */
};

/* ISteamClient, interface "SteamClient021" */
#define STEAMCLIENT_VERSION "SteamClient021"
enum
{
    SC_CreateSteamPipe = 0,           /* HSteamPipe () */
    SC_BReleaseSteamPipe = 1,         /* bool (HSteamPipe) */
    SC_ConnectToGlobalUser = 2,       /* HSteamUser (HSteamPipe) */
    SC_ReleaseUser = 4,               /* void (HSteamPipe, HSteamUser) */
    SC_GetISteamUser = 5,             /* void * (HSteamUser, HSteamPipe, const char *) */
    SC_GetISteamFriends = 8,          /* void * (HSteamUser, HSteamPipe, const char *) */
    SC_GetISteamUtils = 9,            /* void * (HSteamPipe, const char *) */
    SC_GetISteamGenericInterface = 12, /* void * (HSteamUser, HSteamPipe, const char *) */
    SC_BShutdownIfAllPipesClosed = 23 /* bool () */
};

/* ISteamUser, interface "SteamUser023" */
#define STEAMUSER_VERSION "SteamUser023"
enum
{
    SU_BLoggedOn = 1,                 /* bool () */
    SU_GetSteamID = 2,                /* CSteamID () */
    SU_GetAuthSessionTicket = 13,     /* HAuthTicket (void *, int, uint32 *, const SteamNetworkingIdentity *) */
    SU_GetAuthTicketForWebApi = 14,   /* HAuthTicket (const char *identity) */
    SU_CancelAuthTicket = 17          /* void (HAuthTicket) */
};

/* SteamNetworkingIdentity (steamnetworkingtypes.h): type, size, 128-byte union = 136 bytes.
 * PEAK (SteamAuthTicketService) passes one set to the player's own SteamID:
 *   SteamNetworkingIdentity id = default; id.SetSteamID(SteamUser.GetSteamID());
 *   SteamUser.GetAuthSessionTicket(buf[1024], 1024, out len, ref id); */
#define STEAMNETWORKINGIDENTITY_TYPE_STEAMID 16
struct SteamNetworkingIdentity
{
    int32_t type;                     /* ESteamNetworkingIdentityType */
    int32_t size;                     /* bytes used in the union (8 for a SteamID) */
    union { uint64_t steamid64; uint8_t raw[128]; } u;
};
_Static_assert(sizeof(struct SteamNetworkingIdentity) == 136, "SteamNetworkingIdentity is 136 bytes");

/* ISteamApps, interface "STEAMAPPS_INTERFACE_VERSION008" (via GetISteamGenericInterface) */
#define STEAMAPPS_VERSION "STEAMAPPS_INTERFACE_VERSION008"
enum { SA_BIsSubscribed = 0, SA_BIsSubscribedApp = 6 }; /* bool (); bool (AppId_t) */

/* ISteamFriends, interface "SteamFriends017" */
#define STEAMFRIENDS_VERSION "SteamFriends017"
enum { SF_GetPersonaName = 0 };       /* const char * () */

/* ISteamUtils, interface "SteamUtils010" */
#define STEAMUTILS_VERSION "SteamUtils010"
enum { SU10_GetAppID = 9 };           /* uint32 () */

#define VFUNC(obj, slot) ((*(void ***)(obj))[slot])

/* CSteamID bit layout (little endian uint64) */
#define STEAMID_ACCOUNT(id)  ((uint32_t)((id) & 0xffffffffu))
#define STEAMID_INSTANCE(id) ((uint32_t)(((id) >> 32) & 0xfffffu))
#define STEAMID_TYPE(id)     ((uint32_t)(((id) >> 52) & 0xfu))
#define STEAMID_UNIVERSE(id) ((uint32_t)(((id) >> 56) & 0xffu))

/* Interface versions SteamAPI_InitEx (SDK 1.61) asks steam_api to check:
 * the list PEAK's Steamworks.NET passes, NUL-separated, double-NUL ended. */
#define STEAMAPI_161_INIT_VERSIONS \
    "SteamUtils010\0" "SteamNetworkingUtils004\0" "STEAMAPPS_INTERFACE_VERSION008\0" \
    "SteamController008\0" "SteamFriends017\0" "SteamMatchGameSearch001\0" \
    "STEAMHTMLSURFACE_INTERFACE_VERSION_005\0" "STEAMHTTP_INTERFACE_VERSION003\0" \
    "SteamInput006\0" "STEAMINVENTORY_INTERFACE_V003\0" "SteamMatchMakingServers002\0" \
    "SteamMatchMaking009\0" "STEAMMUSICREMOTE_INTERFACE_VERSION001\0" \
    "STEAMMUSIC_INTERFACE_VERSION001\0" "SteamNetworkingMessages002\0" \
    "SteamNetworkingSockets012\0" "SteamNetworking006\0" \
    "STEAMPARENTALSETTINGS_INTERFACE_VERSION001\0" "SteamParties002\0" \
    "STEAMREMOTEPLAY_INTERFACE_VERSION002\0" "STEAMREMOTESTORAGE_INTERFACE_VERSION016\0" \
    "STEAMSCREENSHOTS_INTERFACE_VERSION003\0" "STEAMUGC_INTERFACE_VERSION020\0" \
    "STEAMUSERSTATS_INTERFACE_VERSION013\0" "SteamUser023\0" "STEAMVIDEO_INTERFACE_V007\0" "\0"

#endif
