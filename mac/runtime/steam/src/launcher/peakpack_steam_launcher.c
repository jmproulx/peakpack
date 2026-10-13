/*
 * peakpack_steam_launcher.exe - starts PEAK.exe inside our Wine prefix so that
 * Valve's steam_api64.dll finds the PeakPack Steam bridge.
 *
 * Copyright (c) 2026 the PeakPack project. MIT licence (see docs/README.md).
 *
 * Written from scratch for PeakPack for Mac. The design follows Valve's
 * Proton steam_helper (steam.exe, BSD-3-Clause, Copyright (c) 2015-2022
 * Valve Corporation) and lsteamclient's registry setup: advertise this
 * process as the running Steam (ActiveProcess\pid, kept alive while the game
 * runs), point SteamClientDll64 at our steamclient64.dll forwarder, mark the
 * app installed/running, set SteamAppId/SteamGameId, start the game and wait.
 * No code was copied from Proton or from NotProton.
 *
 * Ticket warm-up (0.2.0): before starting the game, the launcher asks the Mac
 * Steam client (through the forwarder -> lsteamclient -> steamclient.dylib) for
 * one auth session ticket exactly as PEAK does (1024-byte buffer, identity =
 * the player's own SteamID), waits up to 3 s for GetAuthSessionTicketResponse,
 * retries once if the first request returned nothing, then cancels it. PEAK's
 * EOS login asks for its ticket once, right after SteamAPI init, and never
 * retries; a cold client (app ownership ticket not ready yet, e.g. a friend's
 * very first launch) would give it an empty ticket. Costs ~0.1 s when warm.
 * The ticket bytes are never logged. --no-warmup turns it off.
 *
 * It never touches the Steam client: the real Mac Steam client, logged in
 * with the player's own account, does every licence check through Valve's
 * own steamclient.dylib.
 *
 * Usage: peakpack_steam_launcher.exe [options] [--] <game.exe> [game args...]
 * See usage() below. Safety: outside Wine it refuses to write the real
 * registry; tests use --dry-run or --registry-root Software\PeakPackTest.
 */
#define WIN32_LEAN_AND_MEAN
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "../../tests/probe/steam_abi_min.h"

#define LAUNCHER_VERSION L"0.2.0"
#define PEAK_APPID 3527290u
#define DEFAULT_STEAM_DIR L"C:\\Program Files (x86)\\Steam"

/* exit codes of the launcher itself; otherwise the game's exit code */
#define EXIT_USAGE 120
#define EXIT_REFUSED 121
#define EXIT_REGISTRY 122
#define EXIT_LAUNCH 123
#define EXIT_INSTALL 124

enum hive { HIVE_HKCU, HIVE_HKLM64, HIVE_HKLM32 };
static const wchar_t *hive_name[] = { L"HKCU", L"HKLM", L"HKLM32" };

struct options
{
    unsigned int appid;
    const wchar_t *steam_dir;
    const wchar_t *client_dll;
    const wchar_t *forwarder_src;
    const wchar_t *steam_client_dir; /* unix path for STEAM_COMPAT_CLIENT_INSTALL_PATH */
    const wchar_t *language;
    const wchar_t *registry_root;
    const wchar_t *cwd;
    const wchar_t *log_path;
    const wchar_t *connect_lobby;
    int dry_run;
    int no_launch;
    int no_install;
    int keep_registry;
    int delete_test_root;
    int steam_dir_given;
    int no_warmup;
    DWORD hold_ms;
    int game_index; /* index into argv of the game exe */
};

static struct options opt;
static HANDLE log_file = INVALID_HANDLE_VALUE;
static int under_wine;

/* ---------- logging ---------- */

static void write_utf8(HANDLE h, const wchar_t *s)
{
    char buf[8192];
    DWORD written;
    int n;
    if (h == INVALID_HANDLE_VALUE || !h) return;
    n = WideCharToMultiByte(CP_UTF8, 0, s, -1, buf, sizeof(buf), NULL, NULL);
    if (n > 1) WriteFile(h, buf, (DWORD)(n - 1), &written, NULL);
}

static void logmsg(const wchar_t *fmt, ...)
{
    wchar_t buf[4096];
    va_list ap;
    int n = swprintf(buf, ARRAYSIZE(buf) - 2, L"[peakpack-steam] ");
    va_start(ap, fmt);
    vswprintf(buf + n, ARRAYSIZE(buf) - n - 2, fmt, ap);
    va_end(ap);
    wcscat(buf, L"\n");
    write_utf8(GetStdHandle(STD_ERROR_HANDLE), buf);
    write_utf8(log_file, buf);
}

static void usage(void)
{
    logmsg(L"PeakPack Steam launcher " LAUNCHER_VERSION);
    logmsg(L"usage: peakpack_steam_launcher.exe [options] [--] <game.exe> [game args...]");
    logmsg(L"  --appid N                 Steam app id (default 3527290, PEAK)");
    logmsg(L"  --steam-dir WINPATH       Steam dir in the prefix (default C:\\Program Files (x86)\\Steam)");
    logmsg(L"  --client-dll WINPATH      SteamClientDll64 value (default <steam-dir>\\steamclient64.dll)");
    logmsg(L"  --forwarder-src WINPATH   forwarder to install at --client-dll (default: next to this exe)");
    logmsg(L"  --no-install              do not copy the forwarder");
    logmsg(L"  --steam-client-dir UNIX   sets STEAM_COMPAT_CLIENT_INSTALL_PATH (dir of steamclient.dylib)");
    logmsg(L"  --language LANG           writes HKCU\\Software\\Valve\\Steam\\language");
    logmsg(L"  --connect-lobby ID        appends +connect_lobby ID to the game arguments");
    logmsg(L"  --cwd WINPATH             game working dir (default: the game exe's dir)");
    logmsg(L"  --log WINPATH             also append log lines to this file");
    logmsg(L"  --dry-run                 print every action; write nothing, launch nothing");
    logmsg(L"  --registry-root SUBKEY    test mode: redirect every registry write to HKCU\\SUBKEY\\<hive>\\...");
    logmsg(L"  --delete-test-root        test mode: delete HKCU\\SUBKEY at exit");
    logmsg(L"  --no-launch               set up and clean up, but do not start the game");
    logmsg(L"  --hold-ms N               with --no-launch: stay alive N ms (stands in for the game)");
    logmsg(L"  --keep-registry           do not reset pid/Running at exit");
    logmsg(L"  --no-warmup               skip the auth-ticket warm-up before the game starts");
    logmsg(L"A first argument starting with steam:// is accepted and ignored (exit 0).");
}

/* ---------- small helpers ---------- */

static int ieq_prefix(const wchar_t *s, const wchar_t *prefix)
{
    return _wcsnicmp(s, prefix, wcslen(prefix)) == 0;
}

static wchar_t *wdup_printf(const wchar_t *fmt, ...)
{
    wchar_t buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vswprintf(buf, ARRAYSIZE(buf), fmt, ap);
    va_end(ap);
    return _wcsdup(buf);
}

static int all_digits(const wchar_t *s)
{
    if (!*s) return 0;
    for (; *s; s++) if (*s < L'0' || *s > L'9') return 0;
    return 1;
}

static int detect_wine(void)
{
    HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    return ntdll && GetProcAddress(ntdll, "wine_get_version") != NULL;
}

/* Append one argument to cmd with the quoting CommandLineToArgvW and the MSVC
 * CRT undo (backslashes are literal unless they precede a quote). */
static void append_arg(wchar_t *cmd, size_t cap, const wchar_t *arg)
{
    size_t len = wcslen(cmd);
    int quote = !*arg || wcspbrk(arg, L" \t\n\v\"") != NULL;
    const wchar_t *p;

#define PUT(c) do { if (len + 1 < cap) cmd[len++] = (c); } while (0)
    if (len) PUT(L' ');
    if (!quote)
    {
        for (p = arg; *p; p++) PUT(*p);
        cmd[len] = 0;
        return;
    }
    PUT(L'"');
    for (p = arg; ; p++)
    {
        unsigned int backslashes = 0;
        while (*p == L'\\') { backslashes++; p++; }
        if (!*p)
        {
            while (backslashes--) { PUT(L'\\'); PUT(L'\\'); }
            break;
        }
        if (*p == L'"')
        {
            while (backslashes--) { PUT(L'\\'); PUT(L'\\'); }
            PUT(L'\\'); PUT(L'"');
        }
        else
        {
            while (backslashes--) PUT(L'\\');
            PUT(*p);
        }
    }
    PUT(L'"');
    cmd[len] = 0;
#undef PUT
}

/* ---------- registry abstraction ---------- */

static int validate_test_root(const wchar_t *root)
{
    if (!root || !*root) return 0;
    if (!ieq_prefix(root, L"Software\\")) return 0;
    if (ieq_prefix(root, L"Software\\Valve")) return 0;
    if (wcsstr(root, L"..") || root[wcslen(root) - 1] == L'\\') return 0;
    return 1;
}

/* Opens/creates the key that stands for <hive>\<subkey>. */
static LONG open_key(enum hive hive, const wchar_t *subkey, HKEY *out)
{
    REGSAM sam = KEY_SET_VALUE | KEY_QUERY_VALUE;
    HKEY root = HKEY_LOCAL_MACHINE;
    wchar_t path[1024];

    if (opt.registry_root)
    {
        swprintf(path, ARRAYSIZE(path), L"%ls\\%ls\\%ls", opt.registry_root, hive_name[hive], subkey);
        return RegCreateKeyExW(HKEY_CURRENT_USER, path, 0, NULL, 0, sam, NULL, out, NULL);
    }
    switch (hive)
    {
    case HIVE_HKCU:   root = HKEY_CURRENT_USER; break;
    case HIVE_HKLM64: sam |= KEY_WOW64_64KEY; break;
    case HIVE_HKLM32: sam |= KEY_WOW64_32KEY; break;
    }
    return RegCreateKeyExW(root, subkey, 0, NULL, 0, sam, NULL, out, NULL);
}

static const wchar_t *where(enum hive hive)
{
    static wchar_t buf[512];
    if (opt.registry_root) swprintf(buf, ARRAYSIZE(buf), L"HKCU\\%ls\\%ls", opt.registry_root, hive_name[hive]);
    else wcscpy(buf, hive_name[hive]);
    return buf;
}

static int reg_set_sz(enum hive hive, const wchar_t *subkey, const wchar_t *name, const wchar_t *value)
{
    HKEY key;
    LONG r;
    logmsg(L"%lsset %ls\\%ls  %ls = \"%ls\" (REG_SZ)", opt.dry_run ? L"[dry-run] " : L"",
           where(hive), subkey, name, value);
    if (opt.dry_run) return 1;
    if ((r = open_key(hive, subkey, &key)))
    {
        logmsg(L"ERROR: cannot open %ls\\%ls (%ld)", where(hive), subkey, r);
        return 0;
    }
    r = RegSetValueExW(key, name, 0, REG_SZ, (const BYTE *)value, (DWORD)((wcslen(value) + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    if (r) logmsg(L"ERROR: cannot set %ls (%ld)", name, r);
    return r == ERROR_SUCCESS;
}

static int reg_set_dword(enum hive hive, const wchar_t *subkey, const wchar_t *name, DWORD value)
{
    HKEY key;
    LONG r;
    logmsg(L"%lsset %ls\\%ls  %ls = %lu (REG_DWORD)", opt.dry_run ? L"[dry-run] " : L"",
           where(hive), subkey, name, (unsigned long)value);
    if (opt.dry_run) return 1;
    if ((r = open_key(hive, subkey, &key)))
    {
        logmsg(L"ERROR: cannot open %ls\\%ls (%ld)", where(hive), subkey, r);
        return 0;
    }
    r = RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE *)&value, sizeof(value));
    RegCloseKey(key);
    if (r) logmsg(L"ERROR: cannot set %ls (%ld)", name, r);
    return r == ERROR_SUCCESS;
}

static int reg_get_dword(enum hive hive, const wchar_t *subkey, const wchar_t *name, DWORD *value)
{
    HKEY key;
    DWORD type, size = sizeof(*value);
    LONG r;
    if (opt.dry_run) return 0;
    if (open_key(hive, subkey, &key)) return 0;
    r = RegQueryValueExW(key, name, NULL, &type, (BYTE *)value, &size);
    RegCloseKey(key);
    return r == ERROR_SUCCESS && type == REG_DWORD;
}

/* ---------- forwarder install ---------- */

static int files_equal(const wchar_t *a, const wchar_t *b)
{
    HANDLE ha, hb;
    char ba[65536], bb[65536];
    DWORD ra, rb;
    int same = 1;
    ha = CreateFileW(a, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    hb = CreateFileW(b, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (ha == INVALID_HANDLE_VALUE || hb == INVALID_HANDLE_VALUE) same = 0;
    while (same)
    {
        if (!ReadFile(ha, ba, sizeof(ba), &ra, NULL) || !ReadFile(hb, bb, sizeof(bb), &rb, NULL)) { same = 0; break; }
        if (ra != rb || memcmp(ba, bb, ra)) { same = 0; break; }
        if (!ra) break;
    }
    if (ha != INVALID_HANDLE_VALUE) CloseHandle(ha);
    if (hb != INVALID_HANDLE_VALUE) CloseHandle(hb);
    return same;
}

static void make_dirs(const wchar_t *dir)
{
    wchar_t buf[MAX_PATH * 2];
    wchar_t *p;
    wcsncpy(buf, dir, ARRAYSIZE(buf) - 1);
    buf[ARRAYSIZE(buf) - 1] = 0;
    for (p = buf + 3; *p; p++)
    {
        if (*p != L'\\' && *p != L'/') continue;
        *p = 0;
        CreateDirectoryW(buf, NULL);
        *p = L'\\';
    }
    CreateDirectoryW(buf, NULL);
}

static int install_forwarder(void)
{
    wchar_t probe[MAX_PATH * 2];

    if (opt.no_install) { logmsg(L"forwarder install skipped (--no-install)"); return 1; }
    if (GetFileAttributesW(opt.forwarder_src) == INVALID_FILE_ATTRIBUTES)
    {
        if (GetFileAttributesW(opt.client_dll) != INVALID_FILE_ATTRIBUTES)
        {
            logmsg(L"forwarder source %ls not found; using existing %ls", opt.forwarder_src, opt.client_dll);
            return 1;
        }
        logmsg(L"%lsERROR: neither %ls nor %ls exists", opt.dry_run ? L"[dry-run] " : L"",
               opt.forwarder_src, opt.client_dll);
        return opt.dry_run;
    }
    if (!under_wine)
    {
        /* Never write into a real Windows Steam install on a developer PC. */
        swprintf(probe, ARRAYSIZE(probe), L"%ls\\steam.exe", opt.steam_dir);
        if (!opt.steam_dir_given || GetFileAttributesW(probe) != INVALID_FILE_ATTRIBUTES)
        {
            logmsg(L"%lsrefusing to install the forwarder outside Wine unless --steam-dir names a "
                   L"directory without steam.exe", opt.dry_run ? L"[dry-run] " : L"");
            return opt.dry_run;
        }
    }
    if (GetFileAttributesW(opt.client_dll) != INVALID_FILE_ATTRIBUTES && files_equal(opt.forwarder_src, opt.client_dll))
    {
        logmsg(L"forwarder %ls is current", opt.client_dll);
        return 1;
    }
    logmsg(L"%lscopy %ls -> %ls", opt.dry_run ? L"[dry-run] " : L"", opt.forwarder_src, opt.client_dll);
    if (opt.dry_run) return 1;
    {
        wchar_t dir[MAX_PATH * 2], *slash;
        wcsncpy(dir, opt.client_dll, ARRAYSIZE(dir) - 1);
        dir[ARRAYSIZE(dir) - 1] = 0;
        if ((slash = wcsrchr(dir, L'\\'))) { *slash = 0; make_dirs(dir); }
    }
    if (!CopyFileW(opt.forwarder_src, opt.client_dll, FALSE))
    {
        logmsg(L"ERROR: copy failed (%lu)", GetLastError());
        return 0;
    }
    return 1;
}

/* ---------- main flow ---------- */

static int set_env(const wchar_t *name, const wchar_t *value)
{
    logmsg(L"%lsenv %ls=%ls", opt.dry_run ? L"[dry-run] " : L"", name, value);
    return opt.dry_run || SetEnvironmentVariableW(name, value);
}

static int setup_registry(const wchar_t *self_path)
{
    wchar_t apps_key[128];
    int ok = 1;

    swprintf(apps_key, ARRAYSIZE(apps_key), L"Software\\Valve\\Steam\\Apps\\%u", opt.appid);
    ok &= reg_set_sz(HIVE_HKCU, L"Software\\Valve\\Steam", L"SteamPath", opt.steam_dir);
    ok &= reg_set_sz(HIVE_HKCU, L"Software\\Valve\\Steam", L"SteamExe", self_path);
    if (opt.language) ok &= reg_set_sz(HIVE_HKCU, L"Software\\Valve\\Steam", L"language", opt.language);
    ok &= reg_set_sz(HIVE_HKLM64, L"Software\\Valve\\Steam", L"InstallPath", opt.steam_dir);
    ok &= reg_set_sz(HIVE_HKLM32, L"Software\\Valve\\Steam", L"InstallPath", opt.steam_dir);
    ok &= reg_set_sz(HIVE_HKCU, L"Software\\Valve\\Steam\\ActiveProcess", L"SteamClientDll64", opt.client_dll);
    ok &= reg_set_dword(HIVE_HKCU, L"Software\\Valve\\Steam\\ActiveProcess", L"pid", GetCurrentProcessId());
    ok &= reg_set_dword(HIVE_HKCU, apps_key, L"Installed", 1);
    ok &= reg_set_dword(HIVE_HKCU, apps_key, L"Running", 1);
    ok &= reg_set_dword(HIVE_HKCU, apps_key, L"Updating", 0);
    return ok;
}

static void cleanup_registry(void)
{
    wchar_t apps_key[128];
    DWORD pid;

    if (opt.keep_registry) { logmsg(L"registry left as is (--keep-registry)"); return; }
    swprintf(apps_key, ARRAYSIZE(apps_key), L"Software\\Valve\\Steam\\Apps\\%u", opt.appid);
    reg_set_dword(HIVE_HKCU, apps_key, L"Running", 0);
    /* Only clear the pid if no newer launcher has taken over. */
    if (opt.dry_run || (reg_get_dword(HIVE_HKCU, L"Software\\Valve\\Steam\\ActiveProcess", L"pid", &pid)
                        && pid == GetCurrentProcessId()))
        reg_set_dword(HIVE_HKCU, L"Software\\Valve\\Steam\\ActiveProcess", L"pid", 0);
    if (opt.registry_root && opt.delete_test_root)
    {
        logmsg(L"%lsdelete HKCU\\%ls", opt.dry_run ? L"[dry-run] " : L"", opt.registry_root);
        if (!opt.dry_run)
        {
            RegDeleteTreeW(HKEY_CURRENT_USER, opt.registry_root);
            RegDeleteKeyW(HKEY_CURRENT_USER, opt.registry_root);
        }
    }
}

/* ---------- auth-ticket warm-up ---------- */

/* Win64 (MSVC ABI) views of the vtable entries we call; GetSteamID returns CSteamID through a hidden
 * result pointer under this ABI (see steam_abi_min.h). */
typedef HSteamPipe (*w_pipe)(void *);
typedef bool (*w_release_pipe)(void *, HSteamPipe);
typedef HSteamUser (*w_connect)(void *, HSteamPipe);
typedef void (*w_release_user)(void *, HSteamPipe, HSteamUser);
typedef void *(*w_get_iface_user)(void *, HSteamUser, HSteamPipe, const char *);
typedef uint64_t *(*w_steamid)(void *, uint64_t *);
typedef HAuthTicket (*w_ticket)(void *, void *, int, uint32_t *, const struct SteamNetworkingIdentity *);
typedef void (*w_cancel)(void *, HAuthTicket);

/* drain callbacks; returns the GetAuthSessionTicketResponse result for `want` if seen, else -1 */
static int warm_pump(pfn_Steam_BGetCallback getcb, pfn_Steam_FreeLastCallback freecb, HSteamPipe pipe, HAuthTicket want)
{
    CallbackMsg msg;
    int32_t call = 0;
    int seen = -1;
    while (getcb(pipe, &msg, &call))
    {
        if (want && msg.callback_id == CALLBACK_GET_AUTH_SESSION_TICKET_RESPONSE &&
            msg.param_size >= (int32_t)sizeof(struct GetAuthSessionTicketResponse))
        {
            struct GetAuthSessionTicketResponse r;
            memcpy(&r, msg.param, sizeof(r));
            if (r.ticket == want) seen = r.result;
        }
        freecb(pipe);
    }
    return seen;
}

static void warm_ticket(void)
{
    static unsigned char buf[1024];
    HMODULE lib;
    pfn_CreateInterface create;
    pfn_Steam_BGetCallback getcb;
    pfn_Steam_FreeLastCallback freecb;
    void *client, *user_if;
    HSteamPipe pipe;
    HSteamUser user;
    uint64_t sid = 0;
    DWORD t0 = GetTickCount();
    int attempt, err = 0;

    lib = LoadLibraryW(opt.client_dll);
    if (!lib) { logmsg(L"warm-up: cannot load %ls (error %lu); skipped", opt.client_dll, GetLastError()); return; }
    create = (pfn_CreateInterface)(void *)GetProcAddress(lib, "CreateInterface");
    getcb = (pfn_Steam_BGetCallback)(void *)GetProcAddress(lib, "Steam_BGetCallback");
    freecb = (pfn_Steam_FreeLastCallback)(void *)GetProcAddress(lib, "Steam_FreeLastCallback");
    if (!create || !getcb || !freecb) { logmsg(L"warm-up: Steam client exports missing; skipped"); return; }
    if (!(client = create(STEAMCLIENT_VERSION, &err))) { logmsg(L"warm-up: CreateInterface failed (%d); skipped", err); return; }
    pipe = ((w_pipe)VFUNC(client, SC_CreateSteamPipe))(client);
    user = pipe ? ((w_connect)VFUNC(client, SC_ConnectToGlobalUser))(client, pipe) : 0;
    if (!pipe || !user)
    {
        logmsg(L"warm-up: Mac Steam not reachable (pipe %d, user %d); skipped", pipe, user);
        if (pipe) ((w_release_pipe)VFUNC(client, SC_BReleaseSteamPipe))(client, pipe);
        return;
    }
    user_if = ((w_get_iface_user)VFUNC(client, SC_GetISteamUser))(client, user, pipe, STEAMUSER_VERSION);
    if (user_if)
    {
        ((w_steamid)VFUNC(user_if, SU_GetSteamID))(user_if, &sid);
        for (attempt = 1; attempt <= 2; attempt++)
        {
            struct SteamNetworkingIdentity ident;
            uint32_t len = 0;
            int result = -1;
            HAuthTicket h;
            DWORD until;
            memset(&ident, 0, sizeof(ident));
            ident.type = STEAMNETWORKINGIDENTITY_TYPE_STEAMID;
            ident.size = (int32_t)sizeof(uint64_t);
            ident.u.steamid64 = sid;
            h = ((w_ticket)VFUNC(user_if, SU_GetAuthSessionTicket))(user_if, buf, (int)sizeof(buf), &len, &ident);
            until = GetTickCount() + (h ? 3000 : 1500);
            /* with a handle: wait for its response; without: let the client fetch what it needs, then retry */
            while ((int)(until - GetTickCount()) > 0)
            {
                result = warm_pump(getcb, freecb, pipe, h);
                if (h && result >= 0) break;
                Sleep(50);
            }
            logmsg(L"warm-up: ticket request %d: handle %u, %u bytes, response %d%ls", attempt, h, len, result,
                   (h && len && result == 1) ? L" (OK)" : L"");
            if (h) ((w_cancel)VFUNC(user_if, SU_CancelAuthTicket))(user_if, h);
            if (h && len && result == 1) break;
        }
        SecureZeroMemory(buf, sizeof(buf));
    }
    else logmsg(L"warm-up: no %hs interface; skipped", STEAMUSER_VERSION);
    ((w_release_user)VFUNC(client, SC_ReleaseUser))(client, pipe, user);
    ((w_release_pipe)VFUNC(client, SC_BReleaseSteamPipe))(client, pipe);
    /* the library stays loaded: unloading lsteamclient while its unix side runs is not worth the risk */
    logmsg(L"warm-up: done in %lu ms", (unsigned long)(GetTickCount() - t0));
}

static BOOL WINAPI ctrl_handler(DWORD type)
{
    (void)type;
    return TRUE; /* let the game decide; we exit when it does */
}

int main(void)
{
    int argc, i, exit_code = 0;
    wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    wchar_t self_path[MAX_PATH * 2], self_dir[MAX_PATH * 2], *slash;
    wchar_t *cmdline, *game_dir = NULL;
    size_t cap;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code;

    if (!argv) return EXIT_USAGE;
    under_wine = detect_wine();
    opt.appid = PEAK_APPID;
    opt.steam_dir = DEFAULT_STEAM_DIR;

    GetModuleFileNameW(NULL, self_path, ARRAYSIZE(self_path));
    wcscpy(self_dir, self_path);
    if ((slash = wcsrchr(self_dir, L'\\'))) *slash = 0;

    if (argc > 1 && ieq_prefix(argv[1], L"steam://"))
    {
        logmsg(L"ignoring %ls (no Steam client inside the prefix)", argv[1]);
        return 0;
    }

    for (i = 1; i < argc; i++)
    {
        const wchar_t *a = argv[i];
#define NEXT() (i + 1 < argc ? argv[++i] : (usage(), exit(EXIT_USAGE), (wchar_t *)NULL))
        if (!wcscmp(a, L"--")) { i++; break; }
        else if (!wcscmp(a, L"--appid")) { const wchar_t *v = NEXT(); if (!all_digits(v)) { usage(); return EXIT_USAGE; } opt.appid = (unsigned int)wcstoul(v, NULL, 10); }
        else if (!wcscmp(a, L"--steam-dir")) { opt.steam_dir = NEXT(); opt.steam_dir_given = 1; }
        else if (!wcscmp(a, L"--client-dll")) opt.client_dll = NEXT();
        else if (!wcscmp(a, L"--forwarder-src")) opt.forwarder_src = NEXT();
        else if (!wcscmp(a, L"--no-install")) opt.no_install = 1;
        else if (!wcscmp(a, L"--steam-client-dir")) opt.steam_client_dir = NEXT();
        else if (!wcscmp(a, L"--language")) opt.language = NEXT();
        else if (!wcscmp(a, L"--connect-lobby")) opt.connect_lobby = NEXT();
        else if (!wcscmp(a, L"--cwd")) opt.cwd = NEXT();
        else if (!wcscmp(a, L"--log")) opt.log_path = NEXT();
        else if (!wcscmp(a, L"--dry-run")) opt.dry_run = 1;
        else if (!wcscmp(a, L"--registry-root")) opt.registry_root = NEXT();
        else if (!wcscmp(a, L"--delete-test-root")) opt.delete_test_root = 1;
        else if (!wcscmp(a, L"--no-launch")) opt.no_launch = 1;
        else if (!wcscmp(a, L"--hold-ms")) opt.hold_ms = (DWORD)wcstoul(NEXT(), NULL, 10);
        else if (!wcscmp(a, L"--keep-registry")) opt.keep_registry = 1;
        else if (!wcscmp(a, L"--no-warmup")) opt.no_warmup = 1;
        else if (!wcscmp(a, L"--help") || !wcscmp(a, L"-h")) { usage(); return 0; }
        else if (a[0] == L'-' && a[1] == L'-') { logmsg(L"unknown option %ls", a); usage(); return EXIT_USAGE; }
        else break;
#undef NEXT
    }
    opt.game_index = i;

    if (opt.log_path)
    {
        log_file = CreateFileW(opt.log_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                               OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    }
    logmsg(L"PeakPack Steam launcher " LAUNCHER_VERSION L" (pid %lu, %ls%ls%ls)", GetCurrentProcessId(),
           under_wine ? L"under Wine" : L"NOT under Wine",
           opt.dry_run ? L", dry run" : L"", opt.registry_root ? L", test registry root" : L"");

    if (opt.game_index >= argc && !opt.no_launch)
    {
        logmsg(L"no game executable given");
        usage();
        return EXIT_USAGE;
    }
    if (opt.connect_lobby && !all_digits(opt.connect_lobby))
    {
        logmsg(L"--connect-lobby needs a numeric lobby id");
        return EXIT_USAGE;
    }
    if (opt.registry_root && !validate_test_root(opt.registry_root))
    {
        logmsg(L"--registry-root must be under Software\\ and must not be under Software\\Valve");
        return EXIT_USAGE;
    }
    /* Safety: on a real Windows machine the Valve keys belong to the real Steam. */
    if (!under_wine && !opt.dry_run && !opt.registry_root)
    {
        logmsg(L"refusing: not running under Wine. Use --dry-run or --registry-root Software\\PeakPackTest.");
        return EXIT_REFUSED;
    }

    if (!opt.client_dll) opt.client_dll = wdup_printf(L"%ls\\steamclient64.dll", opt.steam_dir);
    if (!opt.forwarder_src) opt.forwarder_src = wdup_printf(L"%ls\\steamclient64.dll", self_dir);
    logmsg(L"appid %u, steam dir %ls, SteamClientDll64 %ls", opt.appid, opt.steam_dir, opt.client_dll);

    if (!install_forwarder()) return EXIT_INSTALL;

    /* environment inherited by the game */
    {
        wchar_t appid[16], cur[1024];
        swprintf(appid, ARRAYSIZE(appid), L"%u", opt.appid);
        set_env(L"SteamAppId", appid);
        set_env(L"SteamGameId", appid);
        set_env(L"SteamPath", opt.steam_dir);
        if (opt.steam_client_dir) set_env(L"STEAM_COMPAT_CLIENT_INSTALL_PATH", opt.steam_client_dir);
        else if (GetEnvironmentVariableW(L"STEAM_COMPAT_CLIENT_INSTALL_PATH", cur, ARRAYSIZE(cur)))
            logmsg(L"inherited STEAM_COMPAT_CLIENT_INSTALL_PATH=%ls", cur);
        else
            logmsg(L"STEAM_COMPAT_CLIENT_INSTALL_PATH not set; lsteamclient falls back to the stock Mac Steam path");
    }

    if (!setup_registry(self_path))
    {
        cleanup_registry();
        return EXIT_REGISTRY;
    }

    SetConsoleCtrlHandler(ctrl_handler, TRUE);

    /* cold-start defence for PEAK's one-shot EOS login (see the header comment) */
    /* only under Wine and never in test mode: outside Wine it would reach a real Windows Steam */
    if (!opt.dry_run && !opt.no_warmup && under_wine && !opt.registry_root) warm_ticket();
    else logmsg(L"auth-ticket warm-up skipped (%ls)", opt.dry_run ? L"dry run" : opt.no_warmup ? L"--no-warmup"
                : !under_wine ? L"not under Wine" : L"test registry root");

    if (opt.no_launch)
    {
        logmsg(L"--no-launch: not starting a game%ls", opt.hold_ms ? L", holding" : L"");
        if (opt.hold_ms && !opt.dry_run) Sleep(opt.hold_ms);
        cleanup_registry();
        return 0;
    }

    /* command line: game exe + its args (+connect_lobby id) */
    cap = 32768;
    cmdline = calloc(cap, sizeof(wchar_t));
    for (i = opt.game_index; i < argc; i++) append_arg(cmdline, cap, argv[i]);
    if (opt.connect_lobby)
    {
        append_arg(cmdline, cap, L"+connect_lobby");
        append_arg(cmdline, cap, opt.connect_lobby);
    }
    if (opt.cwd) game_dir = _wcsdup(opt.cwd);
    else
    {
        game_dir = _wcsdup(argv[opt.game_index]);
        if ((slash = wcsrchr(game_dir, L'\\')) || (slash = wcsrchr(game_dir, L'/'))) *slash = 0;
        else { free(game_dir); game_dir = NULL; }
    }
    logmsg(L"%lsstart %ls", opt.dry_run ? L"[dry-run] " : L"", cmdline);
    logmsg(L"%ls  in %ls", opt.dry_run ? L"[dry-run] " : L"", game_dir ? game_dir : L"(current dir)");

    if (opt.dry_run)
    {
        logmsg(L"[dry-run] wait for the game, then reset Running/pid");
        cleanup_registry();
        return 0;
    }

    memset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    if (!CreateProcessW(argv[opt.game_index], cmdline, NULL, NULL, FALSE, CREATE_UNICODE_ENVIRONMENT,
                        NULL, game_dir, &si, &pi))
    {
        logmsg(L"ERROR: CreateProcess failed (%lu)", GetLastError());
        cleanup_registry();
        return EXIT_LAUNCH;
    }
    CloseHandle(pi.hThread);
    logmsg(L"game pid %lu; this process stays alive as the advertised Steam pid", pi.dwProcessId);
    WaitForSingleObject(pi.hProcess, INFINITE);
    code = 0;
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    exit_code = (int)code;
    logmsg(L"game exited with code %lu", (unsigned long)code);

    cleanup_registry();
    if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
    LocalFree(argv);
    return exit_code;
}
