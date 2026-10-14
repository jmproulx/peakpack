import Foundation

/// The installed runtime's own `manifest.json` (INTERFACES §5). The app reads two things from it:
/// the Steam launcher's capabilities (the `launcher` block, pp2+; absent on pp1 = no hold mode, no warm-up)
/// and the per-file SHA-256 list that Repair uses to check the runtime is intact.
public struct RuntimeManifest: Decodable, Equatable {
    public struct Launcher: Decodable, Equatable {
        public var version: String?
        public var features: [String]?
        public var warmup: Bool?
        public var holdUntilExit: Bool?
    }
    public var schema: Int?
    public var runtime_id: String?
    public var launcher: Launcher?
    public var files: [String: String]?

    public static func load(runtimeDir: URL) -> RuntimeManifest? {
        guard let d = try? Data(contentsOf: runtimeDir.appendingPathComponent("manifest.json")) else { return nil }
        return try? JSONDecoder().decode(RuntimeManifest.self, from: d)
    }

    public var supportsHoldUntilExit: Bool {
        launcher?.holdUntilExit == true || (launcher?.features ?? []).contains("hold-until-exit")
    }

    /// Files whose hash differs or that are missing (relative paths). Unknown entries are ignored.
    public func damagedFiles(in runtimeDir: URL, limit: Int = 50) -> [String] {
        guard let files else { return [] }
        var bad: [String] = []
        for (rel, want) in files.sorted(by: { $0.key < $1.key }) {
            guard Hashing.isSHA256Hex(want.lowercased()), !rel.contains("..") else { continue }
            let u = runtimeDir.appendingPathComponent(rel)
            guard let got = try? Hashing.sha256Hex(fileAt: u) else { bad.append(rel); if bad.count >= limit { break }; continue }
            if got != want.lowercased() { bad.append(rel); if bad.count >= limit { break } }
        }
        return bad
    }
}
