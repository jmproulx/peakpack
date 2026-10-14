import Foundation

/// Binary KeyValues node from Steam's appinfo cache.
public indirect enum KVNode: Equatable {
    case map([(String, KVNode)])
    case string(String)
    case int(Int64)
    case uint(UInt64)
    case float(Float)

    public static func == (a: KVNode, b: KVNode) -> Bool {
        switch (a, b) {
        case let (.map(x), .map(y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.string(x), .string(y)): return x == y
        case let (.int(x), .int(y)): return x == y
        case let (.uint(x), .uint(y)): return x == y
        case let (.float(x), .float(y)): return x == y
        default: return false
        }
    }

    public subscript(key: String) -> KVNode? {
        guard case .map(let kids) = self else { return nil }
        return kids.first { $0.0.caseInsensitiveCompare(key) == .orderedSame }?.1
    }

    public var text: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .uint(let u): return String(u)
        case .float(let f): return String(f)
        case .map: return nil
        }
    }
}

public struct SteamBuildInfo: Equatable {
    public var publicBuildId: String?
    public var depotPublicManifest: String?
}

public enum AppInfoError: Error, Equatable {
    case badMagic(UInt32)
    case truncated
    case appNotFound
}

/// Read-only parser for Mac Steam's `appcache/appinfo.vdf` (the client's PICS cache of public app
/// metadata; not a login or config file). Versions: 0x07564427 (v39), 0x07564428 (v40, binary SHA-1),
/// 0x07564429 (v41, keys are indices into a string table at the offset in the header).
/// Format reference: github.com/SteamDatabase/SteamAppInfo. Only the requested app's entry is decoded.
public enum AppInfoVDF {
    public static let magicV39: UInt32 = 0x0756_4427
    public static let magicV40: UInt32 = 0x0756_4428
    public static let magicV41: UInt32 = 0x0756_4429

    public static func node(for appId: UInt32, in data: Data) throws -> KVNode {
        var r = ByteReader(data)
        let magic = try r.u32()
        guard [magicV39, magicV40, magicV41].contains(magic) else { throw AppInfoError.badMagic(magic) }
        _ = try r.u32() // universe
        var strings: [String]?
        if magic == magicV41 {
            let tableOffset = try r.i64()
            guard tableOffset > 0, tableOffset < Int64(data.count) else { throw AppInfoError.truncated }
            var t = ByteReader(data, at: Int(tableOffset))
            let count = try t.u32()
            var list: [String] = []
            list.reserveCapacity(Int(min(count, 1_000_000)))
            for _ in 0..<count { list.append(try t.cString()) }
            strings = list
        }
        while true {
            let app = try r.u32()
            if app == 0 { break }
            let size = Int(try r.u32())
            let entryStart = r.pos
            guard entryStart + size <= data.count else { throw AppInfoError.truncated }
            if app == appId {
                // info_state u32, last_updated u32, pics_token u64, sha1[20], change_number u32, (v40+) binary sha1[20]
                try r.skip(4 + 4 + 8 + 20 + 4)
                if magic != magicV39 { try r.skip(20) }
                var kv = ByteReader(data.subdata(in: r.pos..<(entryStart + size)))
                return try parseMap(&kv, strings: strings)
            }
            r.pos = entryStart + size
        }
        throw AppInfoError.appNotFound
    }

    static func parseMap(_ r: inout ByteReader, strings: [String]?) throws -> KVNode {
        var kids: [(String, KVNode)] = []
        while !r.atEnd {
            let type = try r.u8()
            if type == 0x08 || type == 0x0B { break }
            let key: String
            if let strings {
                let idx = Int(try r.u32())
                guard idx < strings.count else { throw AppInfoError.truncated }
                key = strings[idx]
            } else { key = try r.cString() }
            switch type {
            case 0x00: kids.append((key, try parseMap(&r, strings: strings)))
            case 0x01: kids.append((key, .string(try r.cString())))
            case 0x02: kids.append((key, .int(Int64(Int32(bitPattern: try r.u32())))))
            case 0x03: kids.append((key, .float(Float(bitPattern: try r.u32()))))
            case 0x04, 0x06: kids.append((key, .uint(UInt64(try r.u32())))) // pointer, colour
            case 0x07: kids.append((key, .uint(try r.u64())))
            case 0x0A: kids.append((key, .int(try r.i64())))
            case 0x05: // wide string: UTF-16LE, NUL-terminated
                var units: [UInt16] = []
                while true { let u = UInt16(try r.u8()) | (UInt16(try r.u8()) << 8); if u == 0 { break }; units.append(u) }
                kids.append((key, .string(String(decoding: units, as: UTF16.self))))
            default: throw AppInfoError.truncated
            }
        }
        return .map(kids)
    }

    /// Public branch build id and the depot's public manifest gid. Handles both manifest layouts:
    /// `manifests/public = "<gid>"` (older) and `manifests/public/gid = "<gid>"` (2024+).
    public static func buildInfo(from root: KVNode, depotId: Int) -> SteamBuildInfo {
        let info = root["appinfo"] ?? root
        let depots = info["depots"]
        let build = depots?["branches"]?["public"]?["buildid"]?.text
        var manifest: String?
        if let pub = depots?[String(depotId)]?["manifests"]?["public"] {
            manifest = pub["gid"]?.text ?? pub.text
        }
        return SteamBuildInfo(publicBuildId: build, depotPublicManifest: manifest)
    }

    public static func buildInfo(fileAt url: URL, appId: Int, depotId: Int) -> SteamBuildInfo? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let node = try? node(for: UInt32(appId), in: data) else { return nil }
        return buildInfo(from: node, depotId: depotId)
    }
}

struct ByteReader {
    let data: Data
    var pos: Int

    init(_ data: Data, at pos: Int = 0) {
        // Normalise indices (a Data slice may not start at 0).
        self.data = data.startIndex == 0 ? data : Data(data)
        self.pos = pos
    }

    var atEnd: Bool { pos >= data.count }

    mutating func need(_ n: Int) throws { if pos + n > data.count { throw AppInfoError.truncated } }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return data[pos] }
    mutating func u32() throws -> UInt32 {
        try need(4)
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[pos + i]) << (8 * UInt32(i)) }
        pos += 4
        return v
    }
    mutating func u64() throws -> UInt64 {
        try need(8)
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(data[pos + i]) << (8 * UInt64(i)) }
        pos += 8
        return v
    }
    mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }
    mutating func cString() throws -> String {
        guard let end = data[pos...].firstIndex(of: 0) else { throw AppInfoError.truncated }
        let s = String(decoding: data[pos..<end], as: UTF8.self)
        pos = end + 1
        return s
    }
}
