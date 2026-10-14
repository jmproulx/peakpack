import Foundation
import PeakModdedCore

/// Creates or updates the Wine prefix with the runtime's own pp-create-prefix.sh (INTERFACES §3.1).
struct PrefixService {
    let env: AppEnvironment
    let log = AppLog.shared

    func ensureGUISession() async throws {
        let s = await SystemProbe.guiSession()
        guard s == "Aqua" else {
            throw FriendError(code: "no-gui-session", heading: "Open PEAK (Modded) from your Mac's desktop",
                              advice: "PEAK needs your normal desktop session. Quit this copy and open the app from Applications or the Dock.",
                              details: "launchctl managername = \(s.isEmpty ? "unknown" : s)", actions: [.cancel])
        }
    }

    /// Runs pp-create-prefix.sh for `runtimeId` (idempotent). Throws a FriendError with the log tail on failure.
    func create(runtimeId: String) async throws {
        try await ensureGUISession()
        let rt = env.paths.runtime(runtimeId)
        let wine = WineCommand(runtime: rt, prefix: env.paths.prefix, logDir: env.paths.logs.appendingPathComponent("wine", isDirectory: true))
        // Make sure no Wine process of ours holds the prefix (e.g. a crashed earlier run).
        _ = try? await ProcessRunner.run(wine.killServer(), timeout: 20)
        let logFile = env.paths.logs.appendingPathComponent("prefix.log")
        log.info("creating/updating the prefix with \(runtimeId)")
        let r = try await ProcessRunner.run(wine.createPrefix(), logTo: logFile, timeout: 600)
        let stamp = SystemProbe.prefixRuntimeId(env.paths)
        guard r.exitCode == 0, stamp == runtimeId else {
            throw FriendError(code: "prefix", heading: "Couldn't prepare PEAK's Windows folder",
                              advice: "Click Try Again. If it fails again, click Copy Diagnostics and send it to \(env.kit.hostName).",
                              details: "pp-create-prefix exit \(r.exitCode)\(r.timedOut ? " (timed out)" : ""), stamp \(stamp ?? "none")\n\(r.output.suffix(1500))",
                              actions: [.retry, .openLogs])
        }
        log.info("prefix ready (\(runtimeId))")
    }

    func stopWine() async {
        guard let w = try? env.wine() else { return }
        _ = try? await ProcessRunner.run(w.killServer(), timeout: 20)
    }
}
