import Foundation

/// Where everything lives (MacPort DESIGN §3.1, runtime INTERFACES §3). `dataRoot` and `logs` can be
/// redirected (`--data-dir`, `--logs-dir`) so test gates keep everything inside their job dir.
public struct AppPaths: Equatable {
    public let home: URL
    public let dataRoot: URL
    public let logs: URL
    public let steamData: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, dataRoot: URL? = nil, logs: URL? = nil,
                steamData: URL? = nil) {
        self.home = home
        self.dataRoot = dataRoot ?? home.appendingPathComponent("Library/Application Support/PeakPack", isDirectory: true)
        if let logs { self.logs = logs } else if dataRoot != nil {
            self.logs = self.dataRoot.appendingPathComponent("Logs", isDirectory: true)
        } else {
            self.logs = home.appendingPathComponent("Library/Logs/PEAK Modded", isDirectory: true)
        }
        self.steamData = steamData ?? home.appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
    }

    // ---- ours
    public var runtimes: URL { dataRoot.appendingPathComponent("runtime", isDirectory: true) }
    public func runtime(_ id: String) -> URL { runtimes.appendingPathComponent(id, isDirectory: true) }
    public var prefix: URL { dataRoot.appendingPathComponent("prefix", isDirectory: true) }
    public var frontEnd: URL { dataRoot.appendingPathComponent("frontend", isDirectory: true) }
    public var stateFile: URL { frontEnd.appendingPathComponent("state.json") }
    public var statusFile: URL { frontEnd.appendingPathComponent("status.json") }
    public var downloads: URL { frontEnd.appendingPathComponent("downloads", isDirectory: true) }
    public var appBackup: URL { frontEnd.appendingPathComponent("app-backup", isDirectory: true) }
    public var healthMarker: URL { frontEnd.appendingPathComponent("launched-ok") }
    public var cachedManifest: URL { frontEnd.appendingPathComponent("manifest.json") }
    public var cachedManifestSig: URL { frontEnd.appendingPathComponent("manifest.json.sig") }

    // ---- inside the prefix
    public var driveC: URL { prefix.appendingPathComponent("drive_c", isDirectory: true) }
    public var gameDir: URL { driveC.appendingPathComponent("Games/PEAK", isDirectory: true) }
    public var gameDirOld: URL { driveC.appendingPathComponent("Games/PEAK.old", isDirectory: true) }
    public var gameWinPath: String { #"C:\Games\PEAK"# }
    /// Our helper folder in the prefix: launcher, forwarder, PeakPack status files.
    public var macHelperDir: URL { driveC.appendingPathComponent("PeakPackMac", isDirectory: true) }
    public var macHelperWinPath: String { #"C:\PeakPackMac"# }
    public var prefixStamp: URL { prefix.appendingPathComponent("peakpack/prefix.json") }

    /// The Windows user of our prefix. Our CrossOver-derived Wine always reports "crossover" (CrossOver hack 12735
    /// in advapi32 GetUserName; INTERFACES §3.1), so that is where PeakPack, BepInEx and PEAK write, even though
    /// wineboot may also create a folder named after the Mac user. Another name is only a fallback for other Wines.
    public static let prefixUser = "crossover"

    public func wineUser() -> String {
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: users.appendingPathComponent(AppPaths.prefixUser).path) { return AppPaths.prefixUser }
        if let names = try? fm.contentsOfDirectory(atPath: users.path) {
            for n in names.sorted() where !["Public", "public"].contains(n) && !n.hasPrefix(".") { return n }
        }
        return AppPaths.prefixUser
    }
    public func peakPackDir(user: String) -> URL {
        driveC.appendingPathComponent("users/\(user)/AppData/Local/PeakPack", isDirectory: true)
    }
    public func peakPackExe(user: String) -> URL { peakPackDir(user: user).appendingPathComponent("PeakPack.exe") }
    public func peakPackExeWinPath(user: String) -> String { #"C:\users\"# + user + #"\AppData\Local\PeakPack\PeakPack.exe"# }
    public func playerLog(user: String) -> URL {
        driveC.appendingPathComponent("users/\(user)/AppData/LocalLow/LandCrab/PEAK/Player.log")
    }
    /// PeakSession (rev-6) writes session-*.jsonl here.
    public func peakSessionDir(user: String) -> URL {
        peakPackDir(user: user).appendingPathComponent("profile/BepInEx/PeakSession", isDirectory: true)
    }
    public func bepInExLog(user: String) -> URL {
        peakPackDir(user: user).appendingPathComponent("profile/BepInEx/LogOutput.log")
    }

    // ---- Mac Steam (read-only, except moving our own download_depot output)
    public var steamMacOSDir: URL { steamData.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS", isDirectory: true) }
    public var steamClientDylib: URL { steamMacOSDir.appendingPathComponent("steamclient.dylib") }
    public var steamConsoleLog: URL { steamData.appendingPathComponent("logs/console_log.txt") }
    public var steamAppInfo: URL { steamData.appendingPathComponent("appcache/appinfo.vdf") }
    public func depotCandidates(appId: Int, depotId: Int) -> [URL] {
        [steamData, steamMacOSDir].map {
            $0.appendingPathComponent("steamapps/content/app_\(appId)/depot_\(depotId)", isDirectory: true)
        }
    }
}
