import CryptoKit
import Foundation

public enum Hashing {
    public static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Streams the file in 1 MiB chunks (runtime tarball is ~160 MB).
    public static func sha256Hex(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func isSHA256Hex(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }
}

/// `SHA256SUMS` as published with every mac-build-* release: "<hex>  <name>" or "<hex> *<name>".
public struct ChecksumList: Equatable {
    public private(set) var entries: [String: String] = [:]

    public init(text: String) {
        for raw in text.split(whereSeparator: { $0.isNewline }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).lowercased()
            var name = String(parts[1]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("*") { name.removeFirst() }
            guard Hashing.isSHA256Hex(hash), !name.isEmpty else { continue }
            entries[name] = hash
        }
    }

    public func hash(for name: String) -> String? { entries[name] }
}

public enum IntegrityError: Error, Equatable, CustomStringConvertible {
    case notListed(String)
    case pinMismatch(file: String, expected: String, listed: String)
    case hashMismatch(file: String, expected: String, actual: String)

    public var description: String {
        switch self {
        case .notListed(let f): return "\(f) is not listed in SHA256SUMS"
        case .pinMismatch(let f, let e, let l): return "\(f): SHA256SUMS lists \(l.prefix(12))…, the app expects \(e.prefix(12))…"
        case .hashMismatch(let f, let e, let a): return "\(f): downloaded file is \(a.prefix(12))…, expected \(e.prefix(12))…"
        }
    }
}

public enum Integrity {
    /// The pin baked into the app (or the signed manifest) is the trust anchor; SHA256SUMS from the
    /// same release must agree with it. Returns the expected hash for the download.
    public static func expectedHash(asset: String, pinned: String?, sums: ChecksumList) throws -> String {
        guard let listed = sums.hash(for: asset) else { throw IntegrityError.notListed(asset) }
        if let pinned = pinned?.lowercased(), pinned != listed {
            throw IntegrityError.pinMismatch(file: asset, expected: pinned, listed: listed)
        }
        return listed
    }

    public static func verify(file: URL, name: String, expected: String) throws {
        let actual = try Hashing.sha256Hex(fileAt: file)
        if actual != expected.lowercased() { throw IntegrityError.hashMismatch(file: name, expected: expected, actual: actual) }
    }
}
