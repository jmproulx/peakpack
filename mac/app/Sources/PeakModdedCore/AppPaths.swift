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

    /// Wine names the prefix user after the Mac user; read it from the prefix when it exists.
    public func wineUser(fallback: String = NSUserName()) -> String {
        let users = driveC.appendingPathComponent("users", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: users.path) {
            for n in names.sorted() where !["Public", "public", "crossover"].contains(n) && !n.hasPrefix(".") {
                return n
            }
        }
        return fallback
    }
    public func peakPackDir(user: String) -> URL {
        driveC.appendingPathComponent("users/\(user)/AppData/Local/PeakPack", isDirectory: true)
    }
    public func peakPackExe(user: String) -> URL { peakPackDir(user: user).appendingPathComponent("PeakPack.exe") }
    public func peakPackExeWinPath(user: String) -> String { #"C:\users\"# + user + #"\AppData\Local\PeakPack\PeakPack.exe"# }
    public func playerLog(user: String) -> URL {
        driveC.appendingPathComponent("users/\(user)/AppData/LocalLow/LandCrab/PEAK/Player.log")
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
