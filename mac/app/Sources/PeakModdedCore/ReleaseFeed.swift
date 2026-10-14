import Foundation

/// Minimal GitHub release JSON (api.github.com/repos/<repo>/releases).
public struct GitHubRelease: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public var name: String
        public var browser_download_url: String
        public var size: Int64?
    }
    public var tag_name: String
    public var prerelease: Bool
    public var draft: Bool
    public var assets: [Asset]

    public static func decodeList(_ data: Data) throws -> [GitHubRelease] {
        try JSONDecoder().decode([GitHubRelease].self, from: data)
    }
}

public struct AppUpdateCandidate: Equatable {
    public var version: DottedVersion
    public var tag: String
    public var zipName: String
    public var zipURL: URL
    public var sumsURL: URL
    public var size: Int64?
    /// From the signed manifest's `platforms.mac.frontEnd` (proposed); then the zip must match it too.
    public var pinnedSha256: String?
}

public enum AppUpdateFinder {
    /// A signed front-end pin newer than `current` wins over the release list.
    public static func fromSigned(_ pin: PackManifest.FrontEndPin?, repo: String, current: DottedVersion) -> AppUpdateCandidate? {
        guard let pin, pin.isWellFormed, let v = DottedVersion(pin.version), v > current,
              let zu = URL(string: "https://github.com/\(repo)/releases/download/\(pin.tag)/\(pin.zip)"),
              let su = URL(string: "https://github.com/\(repo)/releases/download/\(pin.tag)/SHA256SUMS") else { return nil }
        return AppUpdateCandidate(version: v, tag: pin.tag, zipName: pin.zip, zipURL: zu, sumsURL: su, size: nil,
                                  pinnedSha256: pin.sha256.lowercased())
    }

    /// Newest `mac-build-app-<version>` release (prerelease, not draft) newer than `current`,
    /// that carries both the zip and SHA256SUMS. Tags must belong to our own repo's release list.
    public static func newest(in releases: [GitHubRelease], tagPrefix: String, zipPrefix: String,
                              current: DottedVersion) -> AppUpdateCandidate? {
        var best: AppUpdateCandidate?
        for r in releases where !r.draft && r.tag_name.hasPrefix(tagPrefix) {
            let vs = String(r.tag_name.dropFirst(tagPrefix.count))
            guard let v = DottedVersion(vs), v > current else { continue }
            let zipName = "\(zipPrefix)\(vs).zip"
            guard let zip = r.assets.first(where: { $0.name == zipName }),
                  let sums = r.assets.first(where: { $0.name == "SHA256SUMS" }),
                  let zu = URL(string: zip.browser_download_url), let su = URL(string: sums.browser_download_url)
            else { continue }
            if best == nil || v > best!.version {
                best = AppUpdateCandidate(version: v, tag: r.tag_name, zipName: zipName, zipURL: zu, sumsURL: su, size: zip.size, pinnedSha256: nil)
            }
        }
        return best
    }

    /// The signed pack can require a newer front end (`platforms.mac.minFrontEnd`).
    public static func isRequired(current: DottedVersion, minFrontEnd: String?) -> Bool {
        guard let m = minFrontEnd, let mv = DottedVersion(m) else { return false }
        return current < mv
    }
}
