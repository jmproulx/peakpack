import Foundation

public struct DepotCompletion: Equatable {
    public var path: String
    public var manifestId: String?
}

public enum ConsoleEvent: Equatable {
    /// Steam echoed our command (the friend pasted it and pressed Return).
    case commandSeen
    case completed(DepotCompletion)
    /// A line that looks like a refusal/failure of our download (shown to the friend verbatim).
    case failed(String)
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
            let lower = line.lowercased()
            let mentionsOurs = lower.contains("download_depot") || lower.contains("depot \(depotId)")
                || lower.contains("depot_\(depotId)") || lower.contains("app \(appId)")
            if lower.contains(command) && !Self.failureWords.contains(where: lower.contains) {
                out.append(.commandSeen); continue
            }
            if mentionsOurs || lower.contains("depot download") {
                if Self.failureWords.contains(where: lower.contains) { out.append(.failed(Self.clean(line))) }
            }
        }
        return out
    }

    static let failureWords = ["failed", "error", "invalid", "denied", "not available", "no license",
                               "no subscription", "not owned", "unknown command", "access denied", "timed out", "timeout"]

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
