import Foundation

public struct DepotCompletion: Equatable {
    public var path: String
    public var manifestId: String?
}

/// Why Steam refused or stopped `download_depot` (drives the friend-facing error card).
public enum DepotFailureKind: String, Equatable {
    /// Steam has no connection to its servers (seen on the iMac, 14 Oct 2026: the console answered "No connection").
    case noConnection
    /// The signed-in account has no licence for PEAK.
    case notOwned
    /// Steam does not know the depot/app (or not right now, e.g. while it updates its app info).
    case invalidDepot
    case other
}

public struct DepotFailure: Equatable {
    public var kind: DepotFailureKind
    public var line: String
    /// The line does not name our command or depot (e.g. a bare "No connection"); it only counts once the
    /// command has been seen in the console, so unrelated console noise never fails the step.
    public var standalone: Bool
    public init(kind: DepotFailureKind, line: String, standalone: Bool) { self.kind = kind; self.line = line; self.standalone = standalone }
}

public enum ConsoleEvent: Equatable {
    /// Steam echoed our command (the friend pasted it and pressed Return).
    case commandSeen
    case completed(DepotCompletion)
    /// A refusal or failure of our download.
    case failed(DepotFailure)
}

/// Reads Mac Steam's `logs/console_log.txt` (a log file, never a login/config file; read-only).
/// MacPort DESIGN §5.4: completion prints `Depot download complete : "<path>" (manifest <id>)`.
public struct SteamConsoleParser {
    public let appId: Int
    public let depotId: Int

    public init(appId: Int, depotId: Int) { self.appId = appId; self.depotId = depotId }

    public var command: String { "download_depot \(appId) \(depotId)" }

    public func events(in text: String) -> [ConsoleEvent] {
        var out: [ConsoleEvent] = []
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(raw)
            if let c = completion(in: line) { out.append(.completed(c)); continue }
            let cleaned = Self.clean(line)
            let lower = cleaned.lowercased()
            let mentionsOurs = lower.contains("download_depot") || lower.contains("depot \(depotId)")
                || lower.contains("depot_\(depotId)") || lower.contains("app \(appId)") || lower.contains("depot download")
            let kind = Self.kind(of: lower)
            if lower.contains(command) && kind == nil {
                out.append(.commandSeen); continue
            }
            if let kind {
                if mentionsOurs {
                    out.append(.failed(DepotFailure(kind: kind, line: cleaned, standalone: false)))
                } else if kind != .other && Self.isStandaloneReply(lower) {
                    out.append(.failed(DepotFailure(kind: kind, line: cleaned, standalone: true)))
                }
            }
        }
        return out
    }

    static let failureWords = ["failed", "error", "invalid", "denied", "not available", "no license",
                               "no subscription", "not owned", "unknown command", "access denied", "timed out", "timeout"]
    static let connectionWords = ["no connection", "not connected", "offline", "connection lost", "lost connection",
                                  "no network", "timed out", "timeout", "noconnection"]
    static let ownershipWords = ["no license", "no licence", "no subscription", "not subscribed", "not owned",
                                 "access denied", "accessdenied", "doesn't own", "does not own", "no access"]
    static let invalidWords = ["invalid depot", "invalid app", "unknown depot", "unknown app", "depot not found",
                               "invalid manifest", "manifest not available", "not available"]

    /// The failure class of a console line, or nil when it is not a failure line.
    static func kind(of lower: String) -> DepotFailureKind? {
        if connectionWords.contains(where: lower.contains) { return .noConnection }
        if ownershipWords.contains(where: lower.contains) { return .notOwned }
        if invalidWords.contains(where: lower.contains) { return .invalidDepot }
        if failureWords.contains(where: lower.contains) { return .other }
        return nil
    }

    /// A short reply line of its own ("No connection", "Not connected to Steam"), not a long log line that
    /// merely contains a word like "offline".
    static func isStandaloneReply(_ lower: String) -> Bool {
        let t = lower.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return t.count <= 60 && (t.hasPrefix("no connection") || t.hasPrefix("not connected") || t.hasPrefix("no license")
            || t.hasPrefix("no subscription") || t.hasPrefix("access denied") || t.hasPrefix("invalid depot")
            || t.hasPrefix("depot download failed") || t.hasPrefix("connection lost") || t.hasPrefix("offline"))
    }

    func completion(in line: String) -> DepotCompletion? {
        guard let r = line.range(of: "Depot download complete") else { return nil }
        let rest = line[r.upperBound...]
        var path: String?
        if let q1 = rest.firstIndex(of: "\"") {
            let after = rest[rest.index(after: q1)...]
            if let q2 = after.firstIndex(of: "\"") { path = String(after[..<q2]) }
        }
        var manifest: String?
        if let m = rest.range(of: #"manifest\s+([0-9]+)"#, options: .regularExpression) {
            manifest = String(rest[m]).components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        }
        guard let p = path else { return nil }
        // Only our depot counts (another download_depot the friend ran must not finish our step).
        guard p.contains("depot_\(depotId)") || p.contains("app_\(appId)") else { return nil }
        return DepotCompletion(path: p, manifestId: manifest)
    }

    static func clean(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        // "[2026-10-13 12:00:00] message" -> "message"
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        return String(s.prefix(300))
    }
}

/// Incremental reader: remembers the byte offset, so only lines written after `start` count.
/// A truncated/rotated log restarts at 0.
public final class LogTail {
    public let url: URL
    public private(set) var offset: UInt64 = 0
    private var carry = ""

    public init(url: URL) { self.url = url }

    public func startAtEnd() {
        offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        carry = ""
    }

    /// Complete new lines since the last call ("" if none).
    public func readNew() -> String {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value else { return "" }
        if size < offset { offset = 0; carry = "" }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        do { try h.seek(toOffset: offset) } catch { return "" }
        let data = (try? h.read(upToCount: Int(min(size - offset, 8 << 20)))) ?? Data()
        offset += UInt64(data.count)
        let text = carry + String(decoding: data, as: UTF8.self)
        if let lastNL = text.lastIndex(where: { $0.isNewline }) {
            carry = String(text[text.index(after: lastNL)...])
            return String(text[...lastNL])
        }
        carry = text
        return ""
    }
}
