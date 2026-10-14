import Foundation

public struct DepotInspection: Equatable {
    public var missing: [String]
    public var version: String?
    public var revision: String?
    public var files: Int
    public var bytes: Int64

    public var isComplete: Bool { missing.isEmpty }
}

/// Checks a folder that should hold PEAK's Windows depot (3527291), like testkit G-B5.
public enum DepotInspector {
    public static func inspect(_ dir: URL, requiredFiles: [String], countSizes: Bool = true) -> DepotInspection {
        let fm = FileManager.default
        let missing = requiredFiles.filter { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        var version: String?, revision: String?
        if let txt = try? String(contentsOf: dir.appendingPathComponent("version.txt"), encoding: .utf8) {
            let lines = txt.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            version = lines.first.flatMap { $0.isEmpty ? nil : $0 }
            revision = lines.count > 1 && !lines[1].isEmpty ? lines[1] : nil
        }
        var files = 0
        var bytes: Int64 = 0
        if countSizes { (files, bytes) = FolderSize.measure(dir) }
        return DepotInspection(missing: missing, version: version, revision: revision, files: files, bytes: bytes)
    }

    /// Plausibility like G-B5: at least 200 files and 1.5–3 GB for 2.6.x; scaled from the pinned size.
    public static func sizeLooksRight(_ i: DepotInspection, expectedBytes: Int64) -> Bool {
        let lo = Int64(Double(expectedBytes) * 0.75), hi = Int64(Double(expectedBytes) * 1.6)
        return i.files >= 200 && i.bytes >= lo && i.bytes <= hi
    }
}

public enum FolderSize {
    /// (regular files, logical bytes). Symlinks are not followed.
    public static func measure(_ dir: URL) -> (Int, Int64) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        else { return (0, 0) }
        var n = 0
        var total: Int64 = 0
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            n += 1
            total += Int64(v.fileSize ?? 0)
        }
        return (n, total)
    }
}

public enum GameUpdateVerdict: Equatable {
    case notInstalled
    case upToDate
    case updateAvailable(reason: String)
    /// Nothing to compare against; the friend can still run "Check for PEAK update" by hand.
    case unknown
}

/// Decides whether PEAK's files need a re-download (MacPort DESIGN §5.4 item e).
/// Inputs, best first: Steam's public manifest id for depot 3527291 (from Mac Steam's appinfo cache),
/// then the signed pack's `gameVersion` (what Joshua's pack was built against).
public enum GameUpdatePolicy {
    public static func decide(installed: GameRecord?, steamPublicManifest: String?, packGameVersion: String?) -> GameUpdateVerdict {
        guard let installed else { return .notInstalled }
        if let steam = steamPublicManifest, !steam.isEmpty, let mine = installed.manifestId, !mine.isEmpty {
            return steam == mine ? .upToDate : .updateAvailable(reason: "Steam has a newer PEAK build")
        }
        if let pack = packGameVersion, let mine = installed.version, GameVersion.compare(pack, mine) > 0 {
            return .updateAvailable(reason: "the mod pack is made for PEAK \(pack); you have \(mine)")
        }
        if packGameVersion != nil && installed.version != nil { return .upToDate }
        return .unknown
    }
}
