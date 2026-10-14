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

/// What a failed PeakPack run was about, judged only from its status file (never its log).
public enum PeakPackProblemKind: Equatable {
    /// PeakPack could not confirm the mod list's signature. Under Wine this has been the platform verifier
    /// (CNG/NCrypt) failing, not tampering, when the app's own CryptoKit check of the same manifest passed.
    case signatureCheck
    /// A downloaded file did not match its pinned SHA-256.
    case downloadIntegrity
    case other

    public static func classify(_ s: HeadlessStatus?) -> PeakPackProblemKind {
        let text = [s?.problem?.heading, s?.problem?.advice, s?.problem?.details, s?.message]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("signature") || text.contains("tampered") || text.contains("ecdsa")
            || text.contains("cryptographic") || text.contains("ncrypt") || text.contains("verifier") { return .signatureCheck }
        if text.contains("safety check") || text.contains("sha-256") || text.contains("sha256") || text.contains("hash") { return .downloadIntegrity }
        return .other
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
