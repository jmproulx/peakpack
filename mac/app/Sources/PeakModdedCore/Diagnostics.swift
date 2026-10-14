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
        // 64-bit SteamIDs of individual accounts start with 7656119 and have 17 digits.
        if let re = try? NSRegularExpression(pattern: #"\b7656119\d{6}(\d{4})\b"#) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[SteamID …$1]")
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
