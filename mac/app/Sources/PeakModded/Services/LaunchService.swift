import AppKit
import PeakModdedCore

/// Starts PEAK through the Steam bridge (the testkit G-D2 contract, PeakPack DESIGN §18.6 path B2):
///  1. peakpack_steam_launcher.exe --no-launch holds "Steam is running" for the prefix (and, from launcher
///     0.2.0, warms the auth ticket first, so PEAK's one-shot EOS login gets a ticket);
///  2. PeakPack.exe --headless --launch --launch-method direct syncs the mods and starts PEAK.exe;
///  3. when PEAK exits the hold ends: by itself with --hold-until-exit (runtimes whose manifest says so),
///     else we watch for PEAK.exe and stop our prefix's Wine processes.
final class LaunchService {
    let env: AppEnvironment
    let mods: ModsService
    let log = AppLog.shared
    private var hold: Process?

    init(env: AppEnvironment) {
        self.env = env
        mods = ModsService(env: env)
    }

    var holdUntilExitSupported: Bool {
        guard let rt = env.installedRuntimeDir else { return false }
        return RuntimeManifest.load(runtimeDir: rt)?.supportsHoldUntilExit ?? false
    }

    /// Open Mac Steam if needed and wait until it runs and its client library exists.
    func ensureSteam(onWaiting: @escaping (String) -> Void) async throws {
        if await SystemProbe.steamRunning(), FileManager.default.fileExists(atPath: env.paths.steamClientDylib.path) { return }
        guard let steam = SystemProbe.steamAppURL else {
            throw FriendError(code: "steam-missing", heading: "Steam isn't installed",
                              advice: "Install Steam for Mac from steampowered.com, sign in, then try again.", actions: [.getSteam, .retry])
        }
        onWaiting("Opening Steam… sign in if Steam asks you to.")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: steam, configuration: cfg)
        for _ in 0..<90 {
            if await SystemProbe.steamRunning(), FileManager.default.fileExists(atPath: env.paths.steamClientDylib.path) {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // give Steam a moment to sign in
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw FriendError(code: "steam-not-running", heading: "Steam didn't start",
                          advice: "Open Steam yourself, sign in, then click Try Again.", actions: [.openSteam, .retry])
    }

    /// Our launcher + forwarder (from the runtime) into C:\PeakPackMac, refreshed when the runtime changes.
    func stageBridgeFiles() throws {
        guard let rt = env.installedRuntimeDir else { throw FriendError.internalError("no runtime") }
        let fm = FileManager.default
        try fm.createDirectory(at: env.paths.macHelperDir, withIntermediateDirectories: true)
        for name in ["peakpack_steam_launcher.exe", "steamclient64.dll"] {
            let src = rt.appendingPathComponent("share/peakpack/steam/\(name)")
            let dst = env.paths.macHelperDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else {
                throw FriendError(code: "bridge-missing", heading: "The Steam connection files are missing",
                                  advice: "Click Repair to download the game engine again.", details: src.path, actions: [.repair])
            }
            if (try? Hashing.sha256Hex(fileAt: src)) != (try? Hashing.sha256Hex(fileAt: dst)) {
                try? fm.removeItem(at: dst)
                try fm.copyItem(at: src, to: dst)
            }
        }
    }

    /// Step 1: start the hold and wait for it to be ready (warm-up done) — at most ~15 s.
    func startHold() async throws {
        await stopHold()
        let wine = try env.wine()
        let launcherLog = env.paths.macHelperDir.appendingPathComponent("launcher.log")
        try? FileManager.default.removeItem(at: launcherLog)
        let args = SteamLauncherArgs.hold(helperWinDir: env.paths.macHelperWinPath, logWinPath: env.paths.macHelperWinPath + #"\launcher.log"#,
                                          holdUntilExit: holdUntilExitSupported)
        let spec = wine.wine(args, knobs: WineCommand.Knobs(hud: env.state.showFPS))
        hold = try ProcessRunner.start(spec, logTo: env.paths.logs.appendingPathComponent("launcher.log"))
        log.info("Steam launcher hold started (hold-until-exit: \(holdUntilExitSupported))")
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let t = try? String(contentsOf: launcherLog, encoding: .utf8),
               t.contains("--no-launch") || t.contains("hold:") { return }
            if hold?.isRunning == false {
                throw FriendError(code: "launcher-failed", heading: "Couldn't connect PEAK to Steam",
                                  advice: "Make sure Steam is open and you're signed in, then click Try Again.",
                                  details: "launcher exit \(hold?.terminationStatus ?? -1)", actions: [.retry, .openLogs])
            }
        }
        log.warn("launcher log did not confirm readiness within 15 s; continuing")
    }

    func stopHold() async {
        if let h = hold, h.isRunning { h.terminate() }
        hold = nil
    }

    /// Wait for PEAK to appear (up to `appearTimeout`), then until it exits. Returns false if it never appeared.
    func waitForPeakToFinish(appearTimeout: TimeInterval = 180) async -> Bool {
        let start = Date()
        var seen = false
        var goneStreak = 0
        while !Task.isCancelled {
            let running = await SystemProbe.peakRunning()
            if running { seen = true; goneStreak = 0 } else if seen { goneStreak += 1 }
            if seen && goneStreak >= 2 { break }
            if !seen && Date().timeIntervalSince(start) > appearTimeout { return false }
            if let h = hold, !h.isRunning, holdUntilExitSupported {
                // --hold-until-exit: the launcher ends when PEAK exits (exit 0) or never appeared (125).
                let code = h.terminationStatus
                if code == 125 && !seen { return false }
                if seen || code == 0 { break }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return seen
    }

    /// After PEAK: end the hold and stop our prefix's leftover Wine processes (only if PEAK is gone).
    func cleanupAfterGame() async {
        await stopHold()
        if !(await SystemProbe.peakRunning()), let w = try? env.wine() {
            _ = try? await ProcessRunner.run(w.killServer(), timeout: 20)
        }
        log.info("game session ended; Wine stopped")
    }
}
