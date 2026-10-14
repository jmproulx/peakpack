import AppKit
import PeakModdedCore

/// Rosetta, logs, diagnostics, uninstall.
struct MaintenanceService {
    let env: AppEnvironment
    let log = AppLog.shared

    /// Opens a tiny Intel-only helper app; macOS itself then offers to install Rosetta (its own prompt).
    func askMacOSToInstallRosetta() async {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PEAK Rosetta Check.app")
        guard FileManager.default.fileExists(atPath: helper.path) else {
            log.warn("Rosetta helper missing at \(helper.path)")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do { _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: cfg) }
        catch { log.info("Rosetta helper open: \(error.localizedDescription) (expected while Rosetta is missing)") }
    }

    /// Copies PeakPack's and PEAK's logs next to ours, then shows the folder in Finder.
    func openLogs() {
        let fm = FileManager.default
        let user = env.wineUser
        let dest = env.paths.logs.appendingPathComponent("game", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let picks: [(URL, String)] = [
            (env.paths.peakPackDir(user: user).appendingPathComponent("log.txt"), "PeakPack log.txt"),
            (env.paths.bepInExLog(user: user), "BepInEx LogOutput.log"),
            (env.paths.playerLog(user: user), "PEAK Player.log"),
            (env.paths.macHelperDir.appendingPathComponent("launcher.log"), "Steam launcher.log"),
        ]
        for (src, name) in picks where fm.fileExists(atPath: src.path) {
            let d = dest.appendingPathComponent(name)
            try? fm.removeItem(at: d)
            try? fm.copyItem(at: src, to: d)
        }
        NSWorkspace.shared.activateFileViewerSelecting([AppLog.shared.fileURL ?? env.paths.logs])
    }

    func diagnostics(lastError: FriendError?, extra: [(String, String)] = []) async -> String {
        let p = env.paths
        var facts: [(String, String)] = [
            ("App", "\(AppInfo.version) (\(AppInfo.build))"),
            ("macOS", SystemProbe.macOSVersion.description),
            ("Chip", SystemProbe.isAppleSilicon ? "Apple Silicon" : "Intel (untested)"),
            ("Rosetta", await SystemProbe.rosettaInstalled() ? "installed" : "missing"),
            ("Desktop session", await SystemProbe.guiSession()),
            ("Runtime", env.state.runtimeId ?? "none"),
            ("Prefix", SystemProbe.prefixRuntimeId(p) ?? "none"),
            ("Steam", SystemProbe.steamAppURL == nil ? "not installed" : (await SystemProbe.steamRunning() ? "running" : "installed, not running")),
            ("Steam client library", FileManager.default.fileExists(atPath: p.steamClientDylib.path) ? "present" : "missing"),
            ("PEAK files", env.state.game.map { "\($0.version ?? "?") (\($0.files) files, manifest \($0.manifestId ?? "?"))" } ?? "not installed"),
            ("Mod pack revision", env.state.packRevision.map(String.init) ?? "unknown"),
            ("Free space", SystemProbe.freeBytes(at: p.dataRoot).map { String(format: "%.1f GB", Double($0) / 1e9) } ?? "?"),
            ("Show FPS", env.state.showFPS ? "on" : "off"),
        ]
        if let o = env.testPeakPack { facts.append(("TEST", o.label)) }
        if let sig = lastSignatureLine() { facts.append(("PeakPack signature check", sig)) }
        facts += extra
        let err = lastError.map { "\($0.heading) [\($0.code)]\n\($0.advice)\n\($0.details)" }
        let tail = AppLog.shared.fileURL.map { Diagnostics.tail(of: $0, maxLines: 80) } ?? ""
        return Diagnostics.report(title: Date().description, facts: facts, error: err, logTail: tail, userName: NSUserName())
    }

    /// PeakPack 0.4.3+ logs why a manifest signature check failed ("signature check (…)" lines in log.txt).
    func lastSignatureLine() -> String? {
        let f = env.paths.peakPackDir(user: env.wineUser).appendingPathComponent("log.txt")
        let tail = Diagnostics.tail(of: f, maxLines: 400, maxBytes: 256 * 1024)
        return tail.split(whereSeparator: { $0.isNewline }).last { $0.contains("signature check") }.map { String($0.suffix(400)) }
    }

    /// Moves our data, logs and the app itself to the Trash (recoverable). Steam and its files are untouched.
    func uninstall() async -> [String] {
        await PrefixService(env: env).stopWine()
        var trashed: [URL] = []
        var failed: [String] = []
        var targets = [env.paths.dataRoot, env.paths.logs]
        if !env.options.isTestRun { targets.append(Bundle.main.bundleURL) }
        let fm = FileManager.default
        for u in targets where fm.fileExists(atPath: u.path) {
            do {
                if let dest = env.options.uninstallTo {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    try fm.moveItem(at: u, to: dest.appendingPathComponent(u.lastPathComponent + "-" + String(Int(Date().timeIntervalSince1970))))
                } else {
                    try fm.trashItem(at: u, resultingItemURL: nil)
                }
                trashed.append(u)
            } catch { failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        log.info("uninstall: trashed \(trashed.map(\.path)), failed \(failed)")
        return failed
    }
}
