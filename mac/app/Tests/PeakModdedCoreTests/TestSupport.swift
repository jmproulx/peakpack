import Foundation
@testable import PeakModdedCore
import XCTest

enum Fixture {
    static func url(_ name: String, _ ext: String) -> URL {
        guard let u = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            fatalError("missing fixture \(name).\(ext)")
        }
        return u
    }
    static func data(_ name: String, _ ext: String) -> Data { try! Data(contentsOf: url(name, ext)) }
    static func text(_ name: String, _ ext: String) -> String { String(decoding: data(name, ext), as: UTF8.self) }

    /// mac/app/kit/mac-kit.json, the file the app bundle embeds.
    static var kitURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("kit/mac-kit.json")
    }
    static var kit: KitConfig { try! KitConfig.load(from: kitURL) }
}

func tempDir(_ name: String = UUID().uuidString) -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pmtest-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// Builds binary appinfo.vdf files for the parser tests (v39/v40 inline keys, v41 string table).
struct AppInfoBuilder {
    enum V { case v39, v40, v41 }
    let version: V
    var strings: [String] = []

    init(_ v: V) { version = v }

    mutating func keyBytes(_ k: String) -> [UInt8] {
        if version == .v41 {
            let idx: Int
            if let i = strings.firstIndex(of: k) { idx = i } else { strings.append(k); idx = strings.count - 1 }
            return le32(UInt32(idx))
        }
        return Array(k.utf8) + [0]
    }

    enum Node { case map([(String, Node)]), str(String), int(Int32) }

    mutating func encode(_ kids: [(String, Node)]) -> [UInt8] {
        var b: [UInt8] = []
        for (k, v) in kids {
            switch v {
            case .map(let m): b.append(0x00); b += keyBytes(k); b += encode(m)
            case .str(let s): b.append(0x01); b += keyBytes(k); b += Array(s.utf8) + [0]
            case .int(let i): b.append(0x02); b += keyBytes(k); b += le32(UInt32(bitPattern: i))
            }
        }
        b.append(0x08)
        return b
    }

    mutating func file(apps: [(UInt32, [(String, Node)])]) -> Data {
        var entries: [UInt8] = []
        for (appid, kv) in apps {
            var body: [UInt8] = []
            body += le32(2) + le32(1_700_000_000) + le64(0) + [UInt8](repeating: 0xAB, count: 20) + le32(123)
            if version != .v39 { body += [UInt8](repeating: 0xCD, count: 20) }
            body += encode(kv)
            entries += le32(appid) + le32(UInt32(body.count)) + body
        }
        entries += le32(0)
        let magic: UInt32 = version == .v39 ? 0x0756_4427 : (version == .v40 ? 0x0756_4428 : 0x0756_4429)
        var out = le32(magic) + le32(1)
        if version == .v41 {
            let headerLen = 4 + 4 + 8
            let tableOffset = UInt64(headerLen + entries.count)
            out += le64(tableOffset) + entries
            out += le32(UInt32(strings.count))
            for s in strings { out += Array(s.utf8) + [0] }
        } else {
            out += entries
        }
        return Data(out)
    }

    func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) } }
    func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
}
