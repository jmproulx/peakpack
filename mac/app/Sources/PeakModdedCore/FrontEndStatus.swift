import Foundation

/// Machine-readable status the app keeps current in `frontend/status.json`, for test gates and support.
/// It contains no personal data (no user names, no SteamIDs).
public struct FrontEndStatus: Codable, Equatable {
    public struct Problem: Codable, Equatable {
        public var code: String
        public var heading: String
        public var advice: String
        public init(code: String, heading: String, advice: String) { self.code = code; self.heading = heading; self.advice = advice }
    }
    public struct Game: Codable, Equatable {
        public var version: String?
        public var manifestId: String?
        public var files: Int?
        public init(version: String?, manifestId: String?, files: Int?) { self.version = version; self.manifestId = manifestId; self.files = files }
    }

    public var schema = 1
    public var appVersion: String
    /// welcome | setup | ready | launching | playing | updating | repairing | uninstalling | error | done
    public var phase: String
    public var step: String?
    /// working | waiting-for-user | done | failed
    public var stepState: String?
    public var message: String?
    public var progress: Double?
    public var problem: Problem?
    public var runtimeId: String?
    public var game: Game?
    public var packRevision: Int?
    public var lastLaunch: String?
    /// The app process that wrote this file, and when that process started (stale-file detection for gates).
    public var pid: Int32?
    public var sessionStarted: Date?
    public var updatedAt: Date

    public init(appVersion: String, phase: String) {
        self.appVersion = appVersion
        self.phase = phase
        self.updatedAt = Date()
    }

    public func write(to url: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(self) { try? AtomicFile.write(d, to: url) }
    }
}
