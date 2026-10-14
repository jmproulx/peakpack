import CryptoKit
import Foundation

/// The parts of PeakPack's signed manifest (FriendInstaller DESIGN §5, §18) the Mac front end reads.
/// The front end never installs mods itself; PeakPack.exe does, with the same verification as on Windows.
public struct PackManifest: Decodable, Equatable {
    public struct AppEntry: Decodable, Equatable {
        public var version: String
        public var url: String
        public var sha256: String
        public var size: Int64?
    }
    public struct RuntimePin: Decodable, Equatable {
        public var id: String
        public var tag: String
        public var asset: String
        public var sha256: String
        public var size: Int64?

        public var isWellFormed: Bool {
            let idOK = id.range(of: #"^pp[0-9]+-cx[0-9.]+$"#, options: .regularExpression) != nil
            return idOK && tag.hasPrefix("mac-build-runtime-") && asset.hasSuffix(".tar.xz")
                && !asset.contains("/") && Hashing.isSHA256Hex(sha256)
        }
    }
    /// Proposed (mac/app/proposals): the signed app release to update to.
    public struct FrontEndPin: Decodable, Equatable {
        public var version: String
        public var tag: String
        public var zip: String
        public var sha256: String

        public var isWellFormed: Bool {
            DottedVersion(version) != nil && tag == "mac-build-app-\(version)" && zip.hasSuffix(".zip") && !zip.contains("/")
                && Hashing.isSHA256Hex(sha256)
        }
    }
    /// Proposed: the PEAK depot build the pack was made against (from Joshua's own install).
    public struct GameDepot: Decodable, Equatable {
        public var appId: Int?
        public var depotId: Int?
        public var manifestId: String?
        public var buildId: String?
    }
    public struct Mac: Decodable, Equatable {
        public var extraArgs: [String]?
        public var minFrontEnd: String?
        public var runtime: RuntimePin?
        public var frontEnd: FrontEndPin?
        public var gameDepot: GameDepot?
    }
    public struct Platforms: Decodable, Equatable {
        public var mac: Mac?
    }

    public var schema: Int
    public var revision: Int
    public var packName: String?
    public var gameAppId: Int?
    public var gameVersion: String?
    public var notes: String?
    public var app: AppEntry?
    public var platforms: Platforms?
    public var gameDepot: GameDepot?

    /// The pack's depot manifest id, wherever the publisher put it.
    public var packDepotManifestId: String? { platforms?.mac?.gameDepot?.manifestId ?? gameDepot?.manifestId }

    public static func decode(_ data: Data) throws -> PackManifest {
        try JSONDecoder().decode(PackManifest.self, from: data)
    }
}

public enum ManifestSignature {
    /// ECDSA P-256 / SHA-256 over the exact manifest bytes (FriendInstaller ManifestSigner). .NET's
    /// SignData emits IEEE P1363 (r||s, 64 bytes); DER is accepted too. The key is base64 SubjectPublicKeyInfo.
    public static func verify(manifest: Data, signatureBase64: String, publicKeySPKIBase64: String) -> Bool {
        guard let keyData = Data(base64Encoded: publicKeySPKIBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let sigData = Data(base64Encoded: signatureBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? P256.Signing.PublicKey(derRepresentation: keyData)
        else { return false }
        if sigData.count == 64, let sig = try? P256.Signing.ECDSASignature(rawRepresentation: sigData) {
            return key.isValidSignature(sig, for: manifest)
        }
        if let sig = try? P256.Signing.ECDSASignature(derRepresentation: sigData) {
            return key.isValidSignature(sig, for: manifest)
        }
        return false
    }

    /// Verifies, then decodes. Throws on a bad signature, so callers can never use unsigned data by accident.
    public static func verifiedManifest(manifest: Data, signatureBase64: String, publicKey: String) throws -> PackManifest {
        guard verify(manifest: manifest, signatureBase64: signatureBase64, publicKeySPKIBase64: publicKey) else {
            throw ManifestError.badSignature
        }
        return try PackManifest.decode(manifest)
    }
}

public enum ManifestError: Error, Equatable {
    case badSignature
    case noAppEntry
}
