import Foundation

/// The pins baked into the app (Contents/Resources/mac-kit.json, source: mac/app/kit/mac-kit.json).
/// A newer app version carries newer pins; the signed pack manifest's `platforms.mac.runtime` (when
/// FriendInstaller publishes it) overrides the runtime pin, see `RuntimePinResolver`.
public struct KitConfig: Codable, Equatable {
    public struct Runtime: Codable, Equatable {
        public var id: String
        public var tag: String
        public var asset: String
        public var sha256: String
        public var size: Int64?
        public init(id: String, tag: String, asset: String, sha256: String, size: Int64? = nil) {
            self.id = id; self.tag = tag; self.asset = asset; self.sha256 = sha256; self.size = size
        }
    }
    public struct Pack: Codable, Equatable {
        public var manifestUrl: String
        public var publicKey: String
        public var hostName: String?
    }
    public struct Game: Codable, Equatable {
        public var appId: Int
        public var depotId: Int
        public var expectedBytes: Int64
        public var requiredFiles: [String]
    }
    public struct App: Codable, Equatable {
        public var releaseTagPrefix: String
        public var zipPrefix: String
    }

    public var schema: Int
    public var repo: String
    public var minMacOS: String
    public var runtime: Runtime
    public var pack: Pack
    public var game: Game
    public var app: App
    public var allowedHostSuffixes: [String]

    public static func load(from url: URL) throws -> KitConfig {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(KitConfig.self, from: data)
    }

    public var hostName: String { pack.hostName ?? "Joshua" }

    public func releaseDownloadURL(tag: String, asset: String) -> URL {
        URL(string: "https://github.com/\(repo)/releases/download/\(tag)/\(asset)")!
    }

    public var releasesAPIURL: URL {
        URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=60")!
    }

    /// HTTPS and a host on the allow-list (suffix match on a label boundary).
    public func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { suffix in
            let s = suffix.lowercased()
            return host == s || host.hasSuffix("." + s)
        }
    }
}

/// Picks the runtime to use: the signed manifest's pin wins when it is present and valid,
/// otherwise the app's embedded pin. An unsigned or unverifiable manifest never changes the pin.
public enum RuntimePinResolver {
    public static func effective(embedded: KitConfig.Runtime, signedManifest: PackManifest?) -> KitConfig.Runtime {
        guard let pin = signedManifest?.platforms?.mac?.runtime, pin.isWellFormed else { return embedded }
        return KitConfig.Runtime(id: pin.id, tag: pin.tag, asset: pin.asset, sha256: pin.sha256.lowercased(),
                                 size: pin.size)
    }
}
