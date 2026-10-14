import Foundation

/// "Copy diagnostics": plain text a friend can paste to Joshua. Redacts the Mac user name (also as
/// Wine's C:\users\<name>) and SteamIDs. Never contains credentials (the app never has any).
public enum Diagnostics {
    /// Wine paths of both the Mac user and the prefix user ("crossover") become <you>, so reports look the same on every Mac.
    public static func redact(_ text: String, userName: String) -> String {
        var s = text
        for name in [userName, AppPaths.prefixUser] where !name.isEmpty {
            s = s.replacingOccurrences(of: #"C:\users\\#(name)"#, with: #"C:\users\<you>"#, options: .caseInsensitive)
            s = s.replacingOccurrences(of: "users/\(name)/", with: "users/<you>/")
        }
        if !userName.isEmpty {
            s = s.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/<you>")
            s = s.replacingOccurrences(of: #"C:\users\\#(userName)"#, with: #"C:\users\<you>"#, options: .caseInsensitive)
            s = s.replacingOccurrences(of: "users/\(userName)/", with: "users/<you>/")
        }
        s = redactSecrets(s)
        // 64-bit SteamIDs of individual accounts start with 7656119 and have 17 digits.
        if let re = try? NSRegularExpression(pattern: #"\b7656119\d{6}(\d{4})\b"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[SteamID …$1]")
        }
        return s
    }

    /// Auth material that PEAK, EOS, Steam or the bridge may log: "...using token <t> and provider steam",
    /// "ticket: <hex>", "access_token=<jwt>". The value after such a keyword goes, and so does any very long
    /// hex or base64 run on its own. SHA-256 hashes (64 hex) and build/manifest ids stay readable.
    public static func redactSecrets(_ text: String) -> String {
        var s = text
        let rules: [(String, String)] = [
            // keyword + value: token, ticket, auth/session ticket, access/refresh/id token, bearer, password-like
            (#"(?i)\b((?:access|refresh|id|auth|session|steam|eos|app)?_?(?:token|ticket)s?|bearer|authorization)(\s*[:=]\s*|\s+)("[^"]{8,}"|[A-Za-z0-9+/=_\-\.]{16,})"#, "$1$2[redacted]"),
            // JWTs anywhere (three base64url parts)
            (#"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\b"#, "[redacted]"),
            // very long hex runs (tickets are hundreds of hex chars; a SHA-256 is 64)
            (#"\b[0-9A-Fa-f]{100,}\b"#, "[redacted hex]"),
            // very long base64 runs
            (#"[A-Za-z0-9+/]{120,}={0,2}"#, "[redacted]"),
        ]
        for (pattern, template) in rules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    public static func report(title: String, facts: [(String, String)], error: String?, logTail: String,
                              userName: String) -> String {
        var lines = ["PEAK (Modded) for Mac: diagnostics", title, ""]
        for (k, v) in facts { lines.append("\(k): \(v)") }
        if let error { lines += ["", "Last problem:", error] }
        if !logTail.isEmpty { lines += ["", "Recent log:", logTail] }
        return redact(lines.joined(separator: "\n"), userName: userName)
    }

    /// Newest file in `dir` whose name starts with `prefix` and ends with `suffix` (by modification date).
    public static func newestFile(in dir: URL, prefix: String, suffix: String) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return nil }
        return items.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(suffix) }
            .max { a, b in
                let da = (try? a.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return da < db
            }
    }

    /// The last `maxBytes` of a file, starting at a line boundary.
    public static func lastBytes(of url: URL, maxBytes: Int) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        var text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        if start > 0, let nl = text.firstIndex(where: { $0.isNewline }) { text = String(text[text.index(after: nl)...]) }
        return text
    }

    public static func tail(of url: URL, maxLines: Int = 60, maxBytes: Int = 64 * 1024) -> String {
        guard let h = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}
