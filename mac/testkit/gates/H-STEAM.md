# H-STEAM: Mac Steam running

| | |
|---|---|
| Slot | 1 (also 3 and 4) |
| Needs a human | only if Steam is not running and a sign-in window appears when it is opened |
| Expected run time | under 1 min (timeout 3 min) |
| Requires | nothing |
| Run by | `run_slot.sh`, or by hand with `run_gate.sh` |

## Purpose

Checks that Mac Steam is installed and its client process (`steam_osx`) is running under this macOS user.

**This gate never opens or reads Steam's login or config files** (`registry.vdf`, `config/loginusers.vdf`, `config/*`). That is a hub rule. Whether an account is signed in is proven by G-B1: its probe calls `ISteamUser::BLoggedOn` through the running client's public API.

The gate never starts, stops or changes Steam, and it never types credentials.

## Command

```sh
cd "$JOB/kit"
bash testkit/run_gate.sh H-STEAM --job-dir "$JOB" [-- --confirm-window]
```

`--confirm-window` (optional) asks the hub's agent for a screenshot of the Steam window.

## What the script does

1. Checks that `Steam.app` is in `/Applications` or `~/Applications` (`steam_app`). If it is missing, the gate ends blocked (exit 2). Records the app's `CFBundleShortVersionString`.
2. Checks that `steamclient.dylib` exists (`steam_boot`, info if missing). It checks existence only.
3. Records the client version from `package/steam_client_osx.manifest` (the client package manifest, not a login or config file).
4. Checks whether `steam_osx` is running (`steam_running`). If it is not, the gate ends needs-human (exit 3). The hub may run `open -a Steam` (no credentials), wait about 30 s and re-run the gate.
5. Only with `--confirm-window`: requests computer-use step `steam_window` (300 s timeout).
   - ok: the agent sees the Store or Library.
   - fail: a sign-in window or Steam Guard prompt shows. The gate ends needs-human.
   - No answer or skip: recorded as info.

## Computer-use step (optional)

### CU-steam_window

1. Click Steam's Dock icon.
2. Take a screenshot: `bash testkit/cu.sh "$JOB" shot H-STEAM steam-window`.
3. Answer with one of:
   - `bash testkit/cu.sh "$JOB" done H-STEAM.steam_window ok "main window"`
   - `... fail "sign-in window"`

Type no credentials.

## Pass / fail criteria

| Criterion id | Check | Pass when |
|---|---|---|
| `steam_app` | Steam.app installed | Found. Not found: blocked (exit 2). |
| `steam_boot` | Client bootstrapped | `steamclient.dylib` exists. Info otherwise. |
| `steam_running` | `steam_osx` running | Running. Not running: needs-human (exit 3). |
| `steam_window` | Agent sees the main window (optional) | The agent answers ok. A fail answer means needs-human. |

## Paths outside the job dir (read-only)

- `Steam.app`: existence, plus `Info.plist` for the version.
- `steamclient.dylib`: existence only.
- `package/steam_client_osx.manifest`: version.
- The process list.

Never read: `registry.vdf`, `config/loginusers.vdf`, `config/*`.

## If it fails or is blocked

- `Steam.app` missing: the hub installs Steam (no sign-in is needed to install it).
- Not running: run `open -a Steam` and re-run the gate. If a sign-in window appears, relay the printed instructions to Joshua: sign in with Remember me and leave Steam running.
- Never quit Steam. Never click Allow on a macOS privacy prompt.
