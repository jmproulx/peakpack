import Foundation

public struct GameRecord: Codable, Equatable {
    public var version: String?
    public var revision: String?
    public var manifestId: String?
    public var files: Int
    public var bytes: Int64
    public var installedAt: Date

    public init(version: String?, revision: String?, manifestId: String?, files: Int, bytes: Int64, installedAt: Date = Date()) {
        self.version = version; self.revision = revision; self.manifestId = manifestId
        self.files = files; self.bytes = bytes; self.installedAt = installedAt
    }
}

/// What the front end remembers between runs (`frontend/state.json`). Everything else is probed live.
public struct FrontEndState: Codable, Equatable {
    public var schema: Int = 1
    public var runtimeId: String?
    public var previousRuntimeId: String?
    public var game: GameRecord?
    public var peakPackSha256: String?
    public var packRevision: Int?
    public var setupComplete: Bool = false
    public var showFPS: Bool = false
    public var lastAppUpdateCheck: Date?
    /// Set before the app replaces itself; cleared by the new version once it has started.
    public var pendingAppUpdate: PendingAppUpdate?
    public var lastStartedAppVersion: String?

    public struct PendingAppUpdate: Codable, Equatable {
        public var fromVersion: String
        public var toVersion: String
        public var backupPath: String
        public var startedAt: Date
    }

    public init() {}
}

public final class StateStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A missing or unreadable file gives a fresh state (setup simply re-probes everything).
    public func load() -> FrontEndState {
        guard let data = try? Data(contentsOf: url),
              let s = try? StateStore.decoder.decode(FrontEndState.self, from: data) else { return FrontEndState() }
        return s
    }

    public func save(_ state: FrontEndState) throws {
        try AtomicFile.write(StateStore.encoder.encode(state), to: url)
    }
}

public enum AtomicFile {
    /// Write to a temp file in the same folder, then rename over the target.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
