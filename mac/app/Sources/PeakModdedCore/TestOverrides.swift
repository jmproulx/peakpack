import Foundation

/// TEST-ONLY: install a specific PeakPack.exe instead of the signed manifest's `app` entry, so Mac test slots can
/// try a PeakPack test build before Joshua publishes a pack revision. Accepted only in test mode (`--data-dir`),
/// only from this repo's GitHub release assets, and only with an exact SHA-256. Never stored anywhere.
public struct TestPeakPackOverride: Equatable {
    public let url: URL
    public let sha256: String

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case notTestMode, incomplete, badURL(String), badHash
        public var description: String {
            switch self {
            case .notTestMode: return "ignored: only honoured together with --data-dir (test mode)"
            case .incomplete: return "ignored: --test-peakpack-url and --test-peakpack-sha256 must be given together"
            case .badURL(let u): return "ignored: not a https://github.com/<repo>/releases/download/<tag>/<asset>.exe URL: \(u)"
            case .badHash: return "ignored: --test-peakpack-sha256 must be 64 hex characters"
            }
        }
    }

    /// nil, nil when neither flag was given.
    public static func validate(url: String?, sha256: String?, repo: String, testMode: Bool) -> (TestPeakPackOverride?, Rejection?) {
        if url == nil && sha256 == nil { return (nil, nil) }
        guard testMode else { return (nil, .notTestMode) }
        guard let url, let sha256 else { return (nil, .incomplete) }
        let prefix = "https://github.com/\(repo)/releases/download/"
        guard url.hasPrefix(prefix), let u = URL(string: url), u.scheme == "https", u.host == "github.com",
              u.query == nil, u.fragment == nil, !url.contains(".."), !url.contains("%"),
              u.path.lowercased().hasSuffix(".exe") else { return (nil, .badURL(url)) }
        let rest = String(url.dropFirst(prefix.count)).split(separator: "/")
        guard rest.count == 2, !rest[0].isEmpty, !rest[1].isEmpty else { return (nil, .badURL(url)) }
        let h = sha256.lowercased()
        guard Hashing.isSHA256Hex(h) else { return (nil, .badHash) }
        return (TestPeakPackOverride(url: u, sha256: h), nil)
    }

    public var label: String { "TEST PeakPack override: \(url.absoluteString) (sha256 \(sha256.prefix(16))…)" }
}
