import Foundation

/// Dotted numeric versions ("0.1.0", "14.0", "1.2.3-beta"); a pre-release suffix sorts below the plain version.
public struct DottedVersion: Comparable, CustomStringConvertible, Equatable {
    public let parts: [Int]
    public let suffix: String

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let main: Substring
        if let dash = s.firstIndex(of: "-") {
            main = s[..<dash]; suffix = String(s[s.index(after: dash)...])
        } else { main = Substring(s); suffix = "" }
        let nums = main.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, !nums.contains(where: { $0 == nil }) else { return nil }
        parts = nums.compactMap { $0 }
    }

    public init(major: Int, minor: Int, patch: Int = 0) { parts = [major, minor, patch]; suffix = "" }

    public var description: String { parts.map(String.init).joined(separator: ".") + (suffix.isEmpty ? "" : "-\(suffix)") }

    public static func < (a: DottedVersion, b: DottedVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        for i in 0..<n {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        if a.suffix.isEmpty != b.suffix.isEmpty { return !a.suffix.isEmpty }
        return a.suffix < b.suffix
    }

    public static func == (a: DottedVersion, b: DottedVersion) -> Bool { !(a < b) && !(b < a) }
}

/// PEAK's own version strings ("2.6.b", "2.6.c", "2.7.a", "1.10"): compares numbers numerically and
/// letters alphabetically, token by token.
public enum GameVersion {
    enum Token: Equatable { case num(Int), word(String) }

    static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var cur = ""
        var curIsDigit: Bool?
        func flush() {
            guard !cur.isEmpty else { return }
            if curIsDigit == true, let n = Int(cur) { out.append(.num(n)) } else { out.append(.word(cur.lowercased())) }
            cur = ""
        }
        for ch in s {
            if ch.isNumber {
                if curIsDigit == false { flush() }
                curIsDigit = true; cur.append(ch)
            } else if ch.isLetter {
                if curIsDigit == true { flush() }
                curIsDigit = false; cur.append(ch)
            } else { flush(); curIsDigit = nil }
        }
        flush()
        return out
    }

    /// -1, 0, 1
    public static func compare(_ a: String, _ b: String) -> Int {
        let ta = tokens(a), tb = tokens(b)
        for i in 0..<max(ta.count, tb.count) {
            guard i < ta.count else { return -1 }
            guard i < tb.count else { return 1 }
            switch (ta[i], tb[i]) {
            case let (.num(x), .num(y)) where x != y: return x < y ? -1 : 1
            case let (.word(x), .word(y)) where x != y: return x < y ? -1 : 1
            case (.num, .word): return 1
            case (.word, .num): return -1
            default: continue
            }
        }
        return 0
    }
}
