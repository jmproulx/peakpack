import Foundation

/// PeakPack's headless status file (FriendInstaller DESIGN §18.8 R6c): camelCase, written atomically,
/// poll while `state == "working"`. Never parse PeakPack's log; use this and the exit code.
public struct HeadlessStatus: Decodable, Equatable {
    public struct Problem: Decodable, Equatable {
        public var heading: String?
        public var advice: String?
        public var details: String?
    }
    public var state: String?
    public var step: String?
    public var message: String?
    public var progress: Double?
    public var platform: String?
    public var appVersion: String?
    public var installedRevision: Int?
    public var latestRevision: Int?
    public var changes: [String]?
    public var launched: String?
    public var commandLine: String?
    public var problem: Problem?
    public var exitCode: Int?

    public var isWorking: Bool { state == "working" }

    public static func read(_ url: URL) -> HeadlessStatus? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(HeadlessStatus.self, from: d)
    }
}

/// `PeakPack.exe --headless` exit codes (FriendInstaller DESIGN §18.1).
public enum PeakPackExit: Int32, Equatable {
    case ok = 0, failed = 1, noPeak = 2, foreignLoader = 3, peakRunning = 4, notInstalled = 5

    public static func from(_ code: Int32) -> PeakPackExit? { PeakPackExit(rawValue: code) }
}

public enum HeadlessCommand {
    /// Arguments after the exe for one headless call (always with our game dir and a status file).
    public static func arguments(_ mode: Mode, gameWinPath: String, statusWinPath: String) -> [String] {
        var a = ["--headless"]
        switch mode {
        case .status: a.append("--status")
        case .sync(let adopt): a.append("--sync"); if adopt { a.append("--adopt") }
        case .launch(let vanilla, let onSyncFail):
            a.append("--launch")
            if vanilla { a.append("--vanilla") }
            a += ["--on-sync-fail", onSyncFail.rawValue, "--launch-method", "direct"]
        }
        a += ["--game-dir", gameWinPath, "--status-out", statusWinPath]
        return a
    }

    public enum OnSyncFail: String { case stop, installed, vanilla }

    public enum Mode: Equatable {
        case status
        case sync(adopt: Bool)
        case launch(vanilla: Bool, onSyncFail: OnSyncFail)
    }
}
