import Foundation
import PeakModdedCore

/// `PEAK Modded --print-status [--data-dir D]`: one JSON object on stdout for test gates.
/// Read-only: no windows, no prompts, no network, no Steam login/config files.
enum StatusCLI {
    /// JSON value or null.
    static func j(_ v: Any?) -> Any { v ?? NSNull() }

    @MainActor
    static func run(options: LaunchOptions) -> Int32 {
        let env: AppEnvironment
        do { env = try AppEnvironment(options: options) } catch {
            print(#"{"schema":1,"error":"\#(error)"}"#)
            return 4
        }
        let sem = DispatchSemaphore(value: 0)
        final class Box { var text = "{}" }
        let out = Box()
        Task.detached {
            let snap = await SystemProbe.snapshot(env, wantedRuntime: env.kit.runtime.id)
            let lastStatus = (try? Data(contentsOf: env.paths.statusFile)).flatMap { String(data: $0, encoding: .utf8) }
            var o: [String: Any] = [
                "schema": 1,
                "appVersion": AppInfo.version,
                "dataRoot": env.paths.dataRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                "macOS": snap.macOS.description,
                "minMacOS": snap.minMacOS.description,
                "appleSilicon": snap.appleSilicon,
                "rosetta": snap.rosettaInstalled,
                "runtimeActive": j(env.state.runtimeId),
                "runtimeWanted": snap.wantedRuntimeId,
                "runtimeFilesPresent": snap.runtimeFilesPresent,
                "prefixRuntimeId": j(snap.prefixRuntimeId),
                "steamInstalled": snap.steamInstalled,
                "steamRunning": snap.steamRunning,
                "steamClientPresent": snap.steamClientPresent,
                "gameComplete": snap.gameComplete,
                "peakPackInstalled": snap.peakPackInstalled,
                "modsInstalled": snap.modsInstalled,
                "setupComplete": env.state.setupComplete,
                "nextStep": j(SetupPlan.next(snap)?.rawValue),
                "readyToPlay": SetupPlan.readyToPlay(snap),
                "packRevision": j(env.state.packRevision),
                "showFPS": env.state.showFPS,
                "peakRunning": await SystemProbe.peakRunning(),
                "holdUntilExit": env.installedRuntimeDir.flatMap { RuntimeManifest.load(runtimeDir: $0)?.supportsHoldUntilExit } ?? false,
            ]
            if let g = env.state.game {
                o["game"] = ["version": j(g.version), "revision": j(g.revision), "manifestId": j(g.manifestId),
                             "files": g.files, "bytes": g.bytes] as [String: Any]
            }
            if let b = AppInfoVDF.buildInfo(fileAt: env.paths.steamAppInfo, appId: env.kit.game.appId, depotId: env.kit.game.depotId) {
                o["steamAppInfo"] = ["publicBuildId": j(b.publicBuildId), "depotPublicManifest": j(b.depotPublicManifest)] as [String: Any]
            } else {
                o["steamAppInfo"] = NSNull()
            }
            if let s = lastStatus, let d = s.data(using: .utf8), let j = try? JSONSerialization.jsonObject(with: d) { o["lastStatus"] = j }
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
                out.text = String(decoding: d, as: UTF8.self)
            }
            sem.signal()
        }
        // Block the main thread only in this non-GUI mode; the probes never need it.
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        print(out.text)
        return 0
    }
}
