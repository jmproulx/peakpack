import AppKit
import PeakModdedCore

/// Live checks of this Mac. Nothing here writes anything, starts Steam, or reads Steam's login/config files.
enum SystemProbe {
    static let steamBundleID = "com.valvesoftware.steam"

    static var macOSVersion: DottedVersion {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DottedVersion(major: v.majorVersion, minor: v.minorVersion, patch: v.patchVersion)
    }

    /// True on Apple Silicon even when this process runs translated.
    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static func rosettaInstalled() async -> Bool {
        guard isAppleSilicon else { return true }
        guard FileManager.default.fileExists(atPath: "/Library/Apple/usr/share/rosetta/rosetta") else { return false }
        let (code, _) = await ProcessRunner.capture("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], timeout: 15)
        return code == 0
    }

    static var steamAppURL: URL? {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: steamBundleID) { return u }
        for p in ["/Applications/Steam.app", NSHomeDirectory() + "/Applications/Steam.app"]
        where FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        return nil
    }

    static func steamRunning() async -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: steamBundleID).isEmpty { return true }
        let (code, _) = await ProcessRunner.capture("/usr/bin/pgrep", ["-x", "steam_osx"])
        return code == 0
    }

    /// Wine's Mac driver needs the logged-in desktop (Aqua) session (INTERFACES §4 "GUI session").
    static func guiSession() async -> String {
        let (_, out) = await ProcessRunner.capture("/bin/launchctl", ["managername"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PEAK.exe processes of this user (Wine shows the Windows exe in the process arguments).
    static func peakRunning() async -> Bool {
        let (code, _) = await ProcessRunner.capture("/usr/bin/pgrep", ["-u", String(getuid()), "-f", #"(^|[/\\])PEAK\.exe"#])
        return code == 0
    }

    static func freeBytes(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        let v = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func prefixRuntimeId(_ paths: AppPaths) -> String? {
        guard let d = try? Data(contentsOf: paths.prefixStamp),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["runtime_id"] as? String
    }

    static func snapshot(_ env: AppEnvironment, wantedRuntime: String) async -> ProbeSnapshot {
        let p = env.paths
        let user = env.wineUser
        let fm = FileManager.default
        let rtOK: Bool = {
            let d = p.runtime(wantedRuntime)
            return fm.isExecutableFile(atPath: d.appendingPathComponent("bin/wine").path)
                && fm.fileExists(atPath: d.appendingPathComponent("share/peakpack/prefix/pp-env.sh").path)
        }()
        let game = DepotInspector.inspect(p.gameDir, requiredFiles: env.kit.game.requiredFiles, countSizes: false)
        return ProbeSnapshot(
            macOS: macOSVersion,
            minMacOS: DottedVersion(env.kit.minMacOS) ?? DottedVersion(major: 14, minor: 0),
            appleSilicon: isAppleSilicon,
            rosettaInstalled: await rosettaInstalled(),
            installedRuntimeId: env.state.runtimeId,
            wantedRuntimeId: wantedRuntime,
            runtimeFilesPresent: rtOK,
            prefixRuntimeId: prefixRuntimeId(p),
            steamInstalled: steamAppURL != nil,
            steamRunning: await steamRunning(),
            steamClientPresent: fm.fileExists(atPath: p.steamClientDylib.path),
            gameComplete: game.isComplete,
            peakPackInstalled: fm.fileExists(atPath: p.peakPackExe(user: user).path),
            modsInstalled: fm.fileExists(atPath: p.peakPackDir(user: user).appendingPathComponent("profile/BepInEx/core/BepInEx.Preloader.dll").path)
        )
    }
}
