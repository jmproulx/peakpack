/*
 * steam_api_probe.exe - test T4: drive PEAK's own steam_api64.dll (SDK 1.61)
 * the way PEAK's Steamworks.NET does, inside the PeakPack Wine prefix.
 * Copyright (c) 2026 the PeakPack project. MIT licence (see ../../docs/README.md).
 *
 * Loads the given steam_api64.dll (PEAK_Data\Plugins\x86_64\steam_api64.dll),
 * then: SteamAPI_RestartAppIfNecessary(appid) (want false), SteamAPI_IsSteamRunning,
 * SteamInternal_SteamAPI_Init(<InitEx interface list>) (want OK), manual
 * dispatch like PEAK, SteamUser023 GetSteamID/BLoggedOn, SteamFriends017
 * GetPersonaName, SteamUtils010 GetAppID, GetAuthSessionTicket and its
 * callback, SteamAPI_Shutdown. Prints "RESULT key=value" lines.
 *
 * Only runs under Wine (refuses on a real Windows install, where it would
 * talk to the real Windows Steam); --dry-run prints the plan anywhere.
 * Run it through peakpack_steam_launcher.exe so the registry and
 * SteamAppId are set up exactly as for PEAK.
 *
 * Build: zig cc -target x86_64-windows-gnu -O1 -o steam_api_probe.exe steam_api_probe.c
 * Usage: steam_api_probe.exe <path\to\steam_api64.dll> [--appid N] [--no-ticket] [--dry-run]
 * Exit:  0 ok, 2 usage, 3 load, 4 restart-needed, 5 init failed, 6 not logged on/ticket, 7 refused
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "steam_abi_min.h"

typedef bool (__cdecl *fn_restart)(uint32_t);
typedef bool (__cdecl *fn_void_bool)(void);
typedef int (__cdecl *fn_init)(const char *versions, char *errmsg);   /* ESteamAPIInitResult */
typedef void (__cdecl *fn_void)(void);
typedef HSteamPipe (__cdecl *fn_pipe)(void);
typedef void *(__cdecl *fn_accessor)(void);
typedef void (__cdecl *fn_run_frame)(HSteamPipe);
typedef bool (__cdecl *fn_next_cb)(HSteamPipe, CallbackMsg *);
typedef void (__cdecl *fn_free_cb)(HSteamPipe);
typedef uint64_t (__cdecl *fn_user_steamid)(void *);
typedef bool (__cdecl *fn_obj_bool)(void *);
typedef const char *(__cdecl *fn_obj_str)(void *);
typedef uint32_t (__cdecl *fn_obj_u32)(void *);
typedef HAuthTicket (__cdecl *fn_ticket)(void *, void *, int, uint32_t *, const struct SteamNetworkingIdentity *);
typedef void (__cdecl *fn_cancel)(void *, HAuthTicket);

static HMODULE api;
static void *sym(const char *name)
{
    void *p = (void *)GetProcAddress(api, name);
    if (!p) printf("RESULT missing_export=%s\n", name);
    return p;
}

int main(int argc, char **argv)
{
    const char *dll = NULL;
    uint32_t appid = 3527290;
    int want_ticket = 1, dry_run = 0, i, rc = 0, init;
    char errmsg[1024] = "", envbuf[32];
    HMODULE ntdll;

    setvbuf(stdout, NULL, _IONBF, 0);
    for (i = 1; i < argc; i++)
    {
        if (!strcmp(argv[i], "--appid") && i + 1 < argc) appid = (uint32_t)strtoul(argv[++i], NULL, 10);
        else if (!strcmp(argv[i], "--no-ticket")) want_ticket = 0;
        else if (!strcmp(argv[i], "--dry-run")) dry_run = 1;
        else if (!dll && argv[i][0] != '-') dll = argv[i];
        else { fprintf(stderr, "usage: %s <steam_api64.dll> [--appid N] [--no-ticket] [--dry-run]\n", argv[0]); return 2; }
    }
    if (!dll) { fprintf(stderr, "usage: %s <steam_api64.dll> [--appid N] [--no-ticket] [--dry-run]\n", argv[0]); return 2; }

    if (!GetEnvironmentVariableA("SteamAppId", envbuf, sizeof(envbuf))) strcpy(envbuf, "(unset)");
    printf("RESULT steam_api=%s\nRESULT appid=%u\nRESULT env_SteamAppId=%s\n", dll, appid, envbuf);
    if (dry_run)
    {
        printf("dry run: would load %s; RestartAppIfNecessary(%u) (expect 0); IsSteamRunning;\n"
               "  SteamInternal_SteamAPI_Init(26 SDK 1.61 interface versions) (expect 0 = OK); ManualDispatch_Init;\n"
               "  SteamUser023 GetSteamID/BLoggedOn; SteamFriends017 GetPersonaName; SteamUtils010 GetAppID;%s Shutdown\n",
               dll, appid, want_ticket ? " GetAuthSessionTicket + callback 163;" : "");
        return 0;
    }
    ntdll = GetModuleHandleA("ntdll.dll");
    if (!ntdll || !GetProcAddress(ntdll, "wine_get_version"))
    {
        fprintf(stderr, "refusing: only runs under the PeakPack Wine runtime. Use --dry-run.\n");
        return 7;
    }

    if (!(api = LoadLibraryA(dll)))
    {
        printf("RESULT load=fail (error %lu)\n", GetLastError());
        return 3;
    }
    printf("RESULT load=ok\n");

    {
        fn_restart restart = (fn_restart)sym("SteamAPI_RestartAppIfNecessary");
        fn_void_bool running = (fn_void_bool)sym("SteamAPI_IsSteamRunning");
        if (!restart || !running) return 3;
        printf("RESULT restart_app_if_necessary=%d\n", restart(appid));
        printf("RESULT is_steam_running=%d\n", running());
    }

    {
        fn_init init_fn = (fn_init)sym("SteamInternal_SteamAPI_Init");
        if (!init_fn) return 3;
        init = init_fn(STEAMAPI_161_INIT_VERSIONS, errmsg);
        printf("RESULT init=%d\nRESULT init_errmsg=%s\n", init, errmsg);
        if (init != 0) return 5;
    }

    {
        fn_void md_init = (fn_void)sym("SteamAPI_ManualDispatch_Init");
        fn_pipe get_pipe = (fn_pipe)sym("SteamAPI_GetHSteamPipe");
        fn_run_frame run_frame = (fn_run_frame)sym("SteamAPI_ManualDispatch_RunFrame");
        fn_next_cb next_cb = (fn_next_cb)sym("SteamAPI_ManualDispatch_GetNextCallback");
        fn_free_cb free_cb = (fn_free_cb)sym("SteamAPI_ManualDispatch_FreeLastCallback");
        void *user = ((fn_accessor)sym("SteamAPI_SteamUser_v023"))();
        void *friends = ((fn_accessor)sym("SteamAPI_SteamFriends_v017"))();
        void *utils = ((fn_accessor)sym("SteamAPI_SteamUtils_v010"))();
        HSteamPipe pipe;
        uint64_t id;

        if (md_init) md_init();
        pipe = get_pipe ? get_pipe() : 0;
        printf("RESULT pipe=%d\nRESULT iface_user=%d iface_friends=%d iface_utils=%d\n",
               pipe, !!user, !!friends, !!utils);
        if (!user) { rc = 6; goto shutdown; }
        id = ((fn_user_steamid)sym("SteamAPI_ISteamUser_GetSteamID"))(user);
        printf("RESULT logged_on=%d\n", ((fn_obj_bool)sym("SteamAPI_ISteamUser_BLoggedOn"))(user));
        printf("RESULT steamid=%llu\nRESULT steamid_account=%u universe=%u type=%u\n", (unsigned long long)id,
               STEAMID_ACCOUNT(id), STEAMID_UNIVERSE(id), STEAMID_TYPE(id));
        if (friends) printf("RESULT persona=%s\n", ((fn_obj_str)sym("SteamAPI_ISteamFriends_GetPersonaName"))(friends));
        if (utils) printf("RESULT utils_appid=%u\n", ((fn_obj_u32)sym("SteamAPI_ISteamUtils_GetAppID"))(utils));
        if (!id) rc = 6;

        if (want_ticket && run_frame && next_cb && free_cb)
        {
            /* exactly like PEAK's SteamAuthTicketService: 1024-byte buffer, identity = own SteamID */
            static unsigned char ticket[1024];
            struct SteamNetworkingIdentity ident;
            uint32_t len = 0;
            int waited, result = -1;
            HAuthTicket h;
            memset(&ident, 0, sizeof(ident));
            ident.type = STEAMNETWORKINGIDENTITY_TYPE_STEAMID;
            ident.size = (int32_t)sizeof(uint64_t);
            ident.u.steamid64 = id;
            /* cold request right after SteamAPI init + ManualDispatch_Init, nothing dispatched yet: the
             * order PEAK's EOS login (UserManager.Initialize -> SteamIdentityProvider) uses at startup */
            h = ((fn_ticket)sym("SteamAPI_ISteamUser_GetAuthSessionTicket"))(user, ticket, sizeof(ticket), &len, &ident);
            printf("RESULT ticket_identity=steamid\n");
            printf("RESULT ticket_first_handle=%u\nRESULT ticket_first_len=%u\n", h, len);
            if (!h || !len)
            {
                /* one retry after 3 s of callback dispatch (diagnoses a cold-start "first ticket = 0") */
                if (h) ((fn_cancel)sym("SteamAPI_ISteamUser_CancelAuthTicket"))(user, h);
                for (waited = 0; waited < 3000; waited += 100)
                {
                    CallbackMsg msg;
                    run_frame(pipe);
                    while (next_cb(pipe, &msg)) free_cb(pipe);
                    Sleep(100);
                }
                len = 0;
                h = ((fn_ticket)sym("SteamAPI_ISteamUser_GetAuthSessionTicket"))(user, ticket, sizeof(ticket), &len, &ident);
                printf("RESULT ticket_retry=1\n");
            }
            else
                printf("RESULT ticket_retry=0\n");
            printf("RESULT ticket_handle=%u\nRESULT ticket_len=%u\n", h, len);
            for (waited = 0; h && result < 0 && waited < 15000; waited += 100)
            {
                CallbackMsg msg;
                run_frame(pipe);
                while (next_cb(pipe, &msg))
                {
                    printf("callback %d (%d bytes)\n", msg.callback_id, msg.param_size);
                    if (msg.callback_id == CALLBACK_GET_AUTH_SESSION_TICKET_RESPONSE &&
                        msg.param_size >= (int)sizeof(struct GetAuthSessionTicketResponse))
                    {
                        struct GetAuthSessionTicketResponse r;
                        memcpy(&r, msg.param, sizeof(r));
                        if (r.ticket == h) result = r.result;
                    }
                    free_cb(pipe);
                }
                if (result < 0) Sleep(100);
            }
            printf("RESULT ticket_callback_result=%d\n", result);
            if (!h || !len || result != 1) rc = rc ? rc : 6;
            if (h) ((fn_cancel)sym("SteamAPI_ISteamUser_CancelAuthTicket"))(user, h);
        }
    }

shutdown:
    ((fn_void)sym("SteamAPI_Shutdown"))();
    printf("RESULT exit=%d\n", rc);
    return rc;
}
