/*
 * steam_client_probe - talks to a Steam client library through the
 * Steamworks client ABI, the way steam_api does. Tests T1/T2 and T3.
 * Copyright (c) 2026 the PeakPack project. MIT licence (see ../../docs/README.md).
 *
 *   macOS x86_64 (T1/T2, under Rosetta): dlopen()s Valve's native
 *     steamclient.dylib from the running Mac Steam client.
 *   Windows x86_64 (T3, under OUR Wine only): LoadLibrary()s the PeakPack
 *     steamclient64.dll forwarder -> Wine's lsteamclient.dll -> lsteamclient.so
 *     -> steamclient.dylib.
 *
 * Calls: CreateInterface(SteamClient021) -> CreateSteamPipe -> ConnectToGlobalUser
 *   -> GetISteamUser(SteamUser023): BLoggedOn, GetSteamID
 *   -> GetISteamFriends(SteamFriends017): GetPersonaName
 *   -> GetISteamUtils(SteamUtils010): GetAppID
 *   -> (T2) GetAuthSessionTicket + wait for GetAuthSessionTicketResponse_t, CancelAuthTicket
 *   -> optional --hold N seconds (pumping callbacks) so Mac Steam shows "Playing PEAK".
 * It uses the player's real login; nothing is spoofed and the Steam client
 * is not modified. Output lines starting with "RESULT " are parsed by the
 * gate scripts. The ticket itself is never printed.
 *
 * Build: macOS:  clang -arch x86_64 -O1 -o steam_client_probe steam_client_probe.c
 *        Windows: zig cc -target x86_64-windows-gnu -o steam_client_probe.exe steam_client_probe.c -ladvapi32
 * Usage: steam_client_probe [--lib PATH] [--appid N] [--no-ticket] [--hold SECONDS] [--dry-run]
 * Exit:  0 ok, 2 usage, 3 library/exports, 4 interface, 5 not connected/logged on, 6 ticket failed,
 *        7 refused (Windows build outside Wine)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "steam_abi_min.h"

#ifdef _WIN32
#include <windows.h>
typedef HMODULE lib_t;
static lib_t lib_open(const char *p) { return LoadLibraryA(p); }
static void *lib_sym(lib_t l, const char *n) { return (void *)GetProcAddress(l, n); }
static const char *lib_err(void) { static char b[32]; snprintf(b, sizeof(b), "error %lu", GetLastError()); return b; }
static void sleep_ms(unsigned ms) { Sleep(ms); }
static void set_env(const char *n, const char *v) { SetEnvironmentVariableA(n, v); }
static int get_env(const char *n, char *buf, size_t len) { DWORD r = GetEnvironmentVariableA(n, buf, (DWORD)len); return r && r < len; }
#else
#include <dlfcn.h>
#include <unistd.h>
typedef void *lib_t;
static lib_t lib_open(const char *p) { return dlopen(p, RTLD_NOW | RTLD_LOCAL); }
static void *lib_sym(lib_t l, const char *n) { return dlsym(l, n); }
static const char *lib_err(void) { const char *e = dlerror(); return e ? e : "?"; }
static void sleep_ms(unsigned ms) { usleep(ms * 1000u); }
static void set_env(const char *n, const char *v) { setenv(n, v, 1); }
static int get_env(const char *n, char *buf, size_t len) { const char *v = getenv(n); if (!v || strlen(v) >= len) return 0; strcpy(buf, v); return 1; }
#endif

/* vtable entry types (x86_64: object pointer first, one ABI except GetSteamID) */
typedef HSteamPipe (*fn_pipe)(void *);
typedef bool (*fn_release_pipe)(void *, HSteamPipe);
typedef HSteamUser (*fn_connect)(void *, HSteamPipe);
typedef void (*fn_release_user)(void *, HSteamPipe, HSteamUser);
typedef void *(*fn_get_iface_user)(void *, HSteamUser, HSteamPipe, const char *);
typedef void *(*fn_get_iface_pipe)(void *, HSteamPipe, const char *);
typedef bool (*fn_bool)(void *);
typedef const char *(*fn_str)(void *);
typedef uint32_t (*fn_u32)(void *);
typedef HAuthTicket (*fn_ticket)(void *, void *, int, uint32_t *, const void *);
typedef void (*fn_cancel)(void *, HAuthTicket);
#ifdef _WIN32
typedef uint64_t *(*fn_steamid)(void *, uint64_t *ret); /* MSVC ABI: hidden result pointer */
#else
typedef uint64_t (*fn_steamid)(void *);                 /* Itanium ABI: returned in RAX */
#endif

static pfn_Steam_BGetCallback p_BGetCallback;
static pfn_Steam_FreeLastCallback p_FreeLastCallback;

/* Drain pending callbacks; returns the ticket response result if seen, else -1. */
static int pump(HSteamPipe pipe, HAuthTicket want_ticket)
{
    CallbackMsg msg;
    int32_t call = 0;
    int seen = -1;
    while (p_BGetCallback(pipe, &msg, &call))
    {
        if (msg.callback_id == CALLBACK_GET_AUTH_SESSION_TICKET_RESPONSE &&
            msg.param_size >= (int32_t)sizeof(struct GetAuthSessionTicketResponse))
        {
            struct GetAuthSessionTicketResponse r;
            memcpy(&r, msg.param, sizeof(r));
            printf("callback 163 GetAuthSessionTicketResponse ticket=%u result=%d\n", r.ticket, r.result);
            if (r.ticket == want_ticket) seen = r.result;
        }
        else
            printf("callback %d (%d bytes)\n", msg.callback_id, msg.param_size);
        p_FreeLastCallback(pipe);
    }
    return seen;
}

static void default_lib(char *out, size_t len)
{
#ifdef _WIN32
    /* What steam_api64.dll would load: ActiveProcess\SteamClientDll64 (read only). */
    DWORD size = (DWORD)len;
    if (RegGetValueA(HKEY_CURRENT_USER, "Software\\Valve\\Steam\\ActiveProcess", "SteamClientDll64",
                     RRF_RT_REG_SZ, NULL, out, &size) != ERROR_SUCCESS)
        snprintf(out, len, "steamclient64.dll");
#else
    char dir[1024];
    if (get_env("STEAM_COMPAT_CLIENT_INSTALL_PATH", dir, sizeof(dir)))
        snprintf(out, len, "%s/steamclient.dylib", dir);
    else
        snprintf(out, len, "%s/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib",
                 getenv("HOME") ? getenv("HOME") : "");
#endif
}

int main(int argc, char **argv)
{
    char lib_path[2048] = "", appid[16] = "3527290", envbuf[64];
    int want_ticket = 1, dry_run = 0, hold = 0, i, rc = 0, err = 0;
    lib_t lib;
    pfn_CreateInterface p_CreateInterface;
    pfn_Steam_IsKnownInterface p_IsKnown;
    void *client, *user_if, *friends_if, *utils_if;
    HSteamPipe pipe;
    HSteamUser user;
    uint64_t steamid = 0;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--lib") && i + 1 < argc) snprintf(lib_path, sizeof(lib_path), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--appid") && i + 1 < argc) snprintf(appid, sizeof(appid), "%s", argv[++i]);
        else if (!strcmp(argv[i], "--no-ticket")) want_ticket = 0;
        else if (!strcmp(argv[i], "--hold") && i + 1 < argc) hold = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--dry-run")) dry_run = 1;
        else { fprintf(stderr, "usage: %s [--lib PATH] [--appid N] [--no-ticket] [--hold SECONDS] [--dry-run]\n", argv[0]); return 2; }
    }
#ifdef _WIN32
    {
        /* Outside Wine this would reach a real Windows Steam: dry run only,
         * and do not even read the real Valve registry keys. */
        HMODULE ntdll = GetModuleHandleA("ntdll.dll");
        if (!ntdll || !GetProcAddress(ntdll, "wine_get_version"))
        {
            if (!dry_run)
            {
                fprintf(stderr, "refusing: the Windows probe only runs under the PeakPack Wine runtime "
                                "(it would talk to a real Windows Steam otherwise). Use --dry-run.\n");
                return 7;
            }
            if (!*lib_path) snprintf(lib_path, sizeof(lib_path), "<ActiveProcess\\SteamClientDll64 from the prefix registry>");
        }
    }
#endif
    if (!*lib_path) default_lib(lib_path, sizeof(lib_path));

    /* The native client reads the app id from the environment of the process. */
    if (!get_env("SteamAppId", envbuf, sizeof(envbuf))) set_env("SteamAppId", appid);
    if (!get_env("SteamGameId", envbuf, sizeof(envbuf))) set_env("SteamGameId", appid);
    get_env("SteamAppId", envbuf, sizeof(envbuf));
    printf("RESULT platform=%s\nRESULT lib=%s\nRESULT env_SteamAppId=%s\n",
#ifdef _WIN32
           "windows-x86_64",
#else
           "macos-x86_64",
#endif
           lib_path, envbuf);

    if (dry_run)
    {
        printf("dry run: would load %s and call CreateInterface(%s), CreateSteamPipe, ConnectToGlobalUser,\n"
               "  GetISteamUser(%s): BLoggedOn/GetSteamID, GetPersonaName, GetAppID%s%s\n",
               lib_path, STEAMCLIENT_VERSION, STEAMUSER_VERSION, want_ticket ? ", GetAuthSessionTicket" : "",
               hold ? ", then hold" : "");
        return 0;
    }
    if (!(lib = lib_open(lib_path)))
    {
        printf("RESULT load=fail (%s)\n", lib_err());
        return 3;
    }
    printf("RESULT load=ok\n");
    p_CreateInterface = (pfn_CreateInterface)lib_sym(lib, "CreateInterface");
    p_BGetCallback = (pfn_Steam_BGetCallback)lib_sym(lib, "Steam_BGetCallback");
    p_FreeLastCallback = (pfn_Steam_FreeLastCallback)lib_sym(lib, "Steam_FreeLastCallback");
    p_IsKnown = (pfn_Steam_IsKnownInterface)lib_sym(lib, "Steam_IsKnownInterface");
    printf("RESULT export_CreateInterface=%d\nRESULT export_Steam_BGetCallback=%d\n"
           "RESULT export_Steam_FreeLastCallback=%d\nRESULT export_Steam_GetAPICallResult=%d\n"
           "RESULT export_Steam_ReleaseThreadLocalMemory=%d\nRESULT export_Steam_IsKnownInterface=%d\n"
           "RESULT export_Steam_NotifyMissingInterface=%d\n",
           !!p_CreateInterface, !!p_BGetCallback, !!p_FreeLastCallback,
           !!lib_sym(lib, "Steam_GetAPICallResult"), !!lib_sym(lib, "Steam_ReleaseThreadLocalMemory"),
           !!p_IsKnown, !!lib_sym(lib, "Steam_NotifyMissingInterface"));
    if (!p_CreateInterface || !p_BGetCallback || !p_FreeLastCallback) return 3;
    if (p_IsKnown)
        printf("RESULT known_%s=%d\nRESULT known_%s=%d\n", STEAMCLIENT_VERSION, p_IsKnown(STEAMCLIENT_VERSION),
               STEAMUSER_VERSION, p_IsKnown(STEAMUSER_VERSION));

    if (!(client = p_CreateInterface(STEAMCLIENT_VERSION, &err)))
    {
        printf("RESULT client=fail (return code %d)\n", err);
        return 4;
    }
    printf("RESULT client=ok\n");
    pipe = ((fn_pipe)VFUNC(client, SC_CreateSteamPipe))(client);
    user = pipe ? ((fn_connect)VFUNC(client, SC_ConnectToGlobalUser))(client, pipe) : 0;
    printf("RESULT pipe=%d\nRESULT user=%d\n", pipe, user);
    if (!pipe || !user)
    {
        printf("RESULT connected=0 (is Mac Steam running and logged in?)\n");
        if (pipe) ((fn_release_pipe)VFUNC(client, SC_BReleaseSteamPipe))(client, pipe);
        return 5;
    }

    user_if = ((fn_get_iface_user)VFUNC(client, SC_GetISteamUser))(client, user, pipe, STEAMUSER_VERSION);
    friends_if = ((fn_get_iface_user)VFUNC(client, SC_GetISteamFriends))(client, user, pipe, STEAMFRIENDS_VERSION);
    utils_if = ((fn_get_iface_pipe)VFUNC(client, SC_GetISteamUtils))(client, pipe, STEAMUTILS_VERSION);
    printf("RESULT iface_user=%d\nRESULT iface_friends=%d\nRESULT iface_utils=%d\n",
           !!user_if, !!friends_if, !!utils_if);
    if (!user_if) { rc = 4; goto out; }

    printf("RESULT logged_on=%d\n", ((fn_bool)VFUNC(user_if, SU_BLoggedOn))(user_if));
#ifdef _WIN32
    ((fn_steamid)VFUNC(user_if, SU_GetSteamID))(user_if, &steamid);
#else
    steamid = ((fn_steamid)VFUNC(user_if, SU_GetSteamID))(user_if);
#endif
    printf("RESULT steamid=%llu\nRESULT steamid_account=%u universe=%u type=%u instance=%u\n",
           (unsigned long long)steamid, STEAMID_ACCOUNT(steamid), STEAMID_UNIVERSE(steamid),
           STEAMID_TYPE(steamid), STEAMID_INSTANCE(steamid));
    if (friends_if) printf("RESULT persona=%s\n", ((fn_str)VFUNC(friends_if, SF_GetPersonaName))(friends_if));
    if (utils_if) printf("RESULT appid=%u\n", ((fn_u32)VFUNC(utils_if, SU10_GetAppID))(utils_if));
    if (!steamid) rc = 5;

    if (want_ticket)
    {
        static unsigned char ticket[4096];
        uint32_t len = 0;
        int result = -1, waited;
        HAuthTicket h = ((fn_ticket)VFUNC(user_if, SU_GetAuthSessionTicket))(user_if, ticket, (int)sizeof(ticket), &len, NULL);
        printf("RESULT ticket_handle=%u\nRESULT ticket_len=%u\n", h, len);
        for (waited = 0; h && result < 0 && waited < 15000; waited += 100)
        {
            result = pump(pipe, h);
            if (result < 0) sleep_ms(100);
        }
        printf("RESULT ticket_callback_result=%d\n", result);
        if (!h || !len || result != 1) rc = rc ? rc : 6;
        if (h) ((fn_cancel)VFUNC(user_if, SU_CancelAuthTicket))(user_if, h);
    }

    if (hold > 0)
    {
        int t;
        printf("holding %d s: check that Mac Steam shows the app as running\n", hold);
        for (t = 0; t < hold * 10; t++) { pump(pipe, 0); sleep_ms(100); }
    }

out:
    ((fn_release_user)VFUNC(client, SC_ReleaseUser))(client, pipe, user);
    ((fn_release_pipe)VFUNC(client, SC_BReleaseSteamPipe))(client, pipe);
    ((fn_bool)VFUNC(client, SC_BShutdownIfAllPipesClosed))(client);
    printf("RESULT exit=%d\n", rc);
    return rc;
}
