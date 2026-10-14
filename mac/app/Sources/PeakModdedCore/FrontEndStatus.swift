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
    /// Test-only overrides in effect for this run (e.g. "peakpack"); absent in normal use.
    public var testOverrides: [String]?
    public var sessionStarted: Date?
    /// Set only in the final status an ending app writes (phase "exited"): why it ended and when.
    public var exitReason: String?
    public var endedAt: Date?
    public var updatedAt: Date

    public init(appVersion: String, phase: String) {
        self.appVersion = appVersion
        self.phase = phase
        self.updatedAt = Date()
    }

    /// The status an app writes as it ends (normal quit, after PEAK exits, SIGTERM): phase "exited", no live pid,
    /// so the next run's gates never mistake it for a running "playing"/"launching" app. The last problem,
    /// game and launch facts are kept for the record.
    public func finalized(reason: String, at date: Date = Date()) -> FrontEndStatus {
        var s = self
        s.phase = "exited"
        s.stepState = "done"
        s.message = nil
        s.progress = nil
        s.pid = nil
        s.exitReason = reason
        s.endedAt = date
        s.updatedAt = date
        return s
    }

    public func write(to url: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        if let d = try? e.encode(self) { try? AtomicFile.write(d, to: url) }
    }
}
