import Foundation
import PeakModdedCore

/// Joshua's signed pack: verifies manifest.json(.sig) with the same public key as the Windows app,
/// installs PeakPack.exe from the manifest's signed `app` entry, and drives PeakPack's headless CLI.
/// The front end never downloads mods itself (FriendInstaller DESIGN §18.6).
struct ModsService {
    let env: AppEnvironment
    let log = AppLog.shared

    /// Fresh signed manifest (cached copy as fallback when offline; the cache is re-verified too).
    func signedManifest(allowCache: Bool = true) async throws -> PackManifest {
        let dl = FileDownloader(isAllowed: env.kit.isAllowed)
        guard let url = URL(string: env.kit.pack.manifestUrl) else { throw FriendError.internalError("bad manifest URL") }
        var lastError: Error?
        for _ in 0..<2 { // a release landing between the two fetches makes them disagree once
            do {
                let m = try await dl.fetchData(url)
                let s = try await dl.fetchData(url.appendingPathExtension("sig"))
                let manifest = try ManifestSignature.verifiedManifest(manifest: m, signatureBase64: String(decoding: s, as: UTF8.self),
                                                                      publicKey: env.kit.pack.publicKey)
                try? AtomicFile.write(m, to: env.paths.cachedManifest)
                try? AtomicFile.write(s, to: env.paths.cachedManifestSig)
                return manifest
            } catch { lastError = error }
        }
        if allowCache, let m = try? Data(contentsOf: env.paths.cachedManifest), let s = try? Data(contentsOf: env.paths.cachedManifestSig),
           let manifest = try? ManifestSignature.verifiedManifest(manifest: m, signatureBase64: String(decoding: s, as: UTF8.self),
                                                                  publicKey: env.kit.pack.publicKey) {
            log.warn("using the cached signed manifest (rev \(manifest.revision)): \(lastError.map { "\($0)" } ?? "")")
            return manifest
        }
        throw FriendError.from(lastError ?? ManifestError.badSignature, context: "signed manifest")
    }

    /// The cached manifest, verified, without network (for quick checks at launch).
    func cachedManifest() -> PackManifest? {
        guard let m = try? Data(contentsOf: env.paths.cachedManifest), let s = try? Data(contentsOf: env.paths.cachedManifestSig) else { return nil }
        return try? ManifestSignature.verifiedManifest(manifest: m, signatureBase64: String(decoding: s, as: UTF8.self), publicKey: env.kit.pack.publicKey)
    }

    /// PeakPack.exe at C:\users\<u>\AppData\Local\PeakPack\PeakPack.exe (the only supported place).
    /// PeakPack updates itself afterwards; we only install it when it is missing or damaged.
    func installPeakPack(manifest: PackManifest, progress: @escaping (String, Double?) -> Void) async throws {
        guard let app = manifest.app, let url = URL(string: app.url), Hashing.isSHA256Hex(app.sha256) else {
            throw FriendError.from(ManifestError.noAppEntry, context: "manifest app entry")
        }
        let user = env.wineUser
        let dest = env.paths.peakPackExe(user: user)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { return } // PeakPack self-updates; never downgrade it
        let tmp = env.paths.downloads.appendingPathComponent("PeakPack-\(app.version).exe")
        let dl = FileDownloader(isAllowed: env.kit.isAllowed)
        if !(fm.fileExists(atPath: tmp.path) && (try? Hashing.sha256Hex(fileAt: tmp)) == app.sha256.lowercased()) {
            do {
                try await dl.download(url, to: tmp, expectedSize: app.size) { p in
                    progress(String(format: "Downloading PeakPack… %.0f of %.0f MB", Double(p.received) / 1e6, Double(p.total ?? app.size ?? 0) / 1e6), p.fraction)
                }
                try Integrity.verify(file: tmp, name: "PeakPack.exe", expected: app.sha256)
            } catch {
                try? fm.removeItem(at: tmp)
                throw FriendError.from(error, context: "PeakPack.exe")
            }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: dest)
        env.update { $0.peakPackSha256 = app.sha256.lowercased() }
        log.info("PeakPack \(app.version) installed")
    }

    struct HeadlessOutcome {
        var exit: Int32
        var status: HeadlessStatus?
        var timedOut: Bool
    }

    /// One `PeakPack.exe --headless …` call; polls its status file every 250 ms into `onStatus`.
    func headless(_ mode: HeadlessCommand.Mode, name: String, timeout: TimeInterval,
                  onStatus: @escaping (HeadlessStatus) -> Void) async throws -> HeadlessOutcome {
        let wine = try env.wine()
        let user = env.wineUser
        let helper = env.paths.macHelperDir
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        let statusFile = helper.appendingPathComponent("status-\(name).json")
        try? FileManager.default.removeItem(at: statusFile)
        let args = [env.paths.peakPackExeWinPath(user: user)]
            + HeadlessCommand.arguments(mode, gameWinPath: env.paths.gameWinPath, statusWinPath: env.paths.macHelperWinPath + "\\status-\(name).json")
        let spec = wine.wine(args, winhttpOverride: true, knobs: WineCommand.Knobs(hud: env.state.showFPS))
        log.info("PeakPack --headless \(name)")
        let poller = Task {
            var last: HeadlessStatus?
            while !Task.isCancelled {
                if let s = HeadlessStatus.read(statusFile), s != last { last = s; onStatus(s) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        let r = try await ProcessRunner.run(spec, logTo: env.paths.logs.appendingPathComponent("peakpack.log"), timeout: timeout)
        poller.cancel()
        let final = HeadlessStatus.read(statusFile)
        if let final { onStatus(final) }
        log.info("PeakPack \(name) exit \(r.exitCode)\(r.timedOut ? " (timeout)" : "") state=\(final?.state ?? "-") msg=\(final?.message ?? "-")")
        if let rev = final?.installedRevision { env.update { $0.packRevision = rev } }
        return HeadlessOutcome(exit: r.exitCode, status: final, timedOut: r.timedOut)
    }

    /// Friendly error for a failed headless call (never parse PeakPack's log; use exit code + problem).
    /// `appVerifiedManifest`: the app's own CryptoKit check of the same signed manifest passed in this run.
    func error(for o: HeadlessOutcome, during: String, appVerifiedManifest: Bool = false) -> FriendError {
        if o.timedOut {
            return FriendError(code: "peakpack-timeout", heading: "Installing the mods is taking too long",
                               advice: "Check your internet connection, then click Try Again.", details: during, actions: [.retry, .openLogs])
        }
        let p = o.status?.problem
        switch PeakPackExit.from(o.exit) {
        case .noPeak:
            return FriendError(code: "peakpack-no-peak", heading: "PEAK's files are missing",
                               advice: "Click Repair to get PEAK from Steam again.", details: p?.details ?? "", actions: [.repair])
        case .peakRunning:
            return FriendError(code: "peak-running", heading: "PEAK is already running",
                               advice: "Quit PEAK first, then try again.", actions: [.retry])
        case .notInstalled:
            return FriendError(code: "peakpack-not-installed", heading: "The mods aren't installed yet",
                               advice: "Click Repair to install them.", actions: [.repair])
        default:
            let kind = PeakPackProblemKind.classify(o.status)
            if kind == .signatureCheck && appVerifiedManifest {
                // The mod list IS genuine (the app checked it); PeakPack's own check could not run here.
                return FriendError(code: "peakpack-verifier", heading: "PEAK for Mac couldn't check the mod list",
                                   advice: "Your mods weren't changed. Click Repair. If it happens again, click Copy Diagnostics and send it to \(env.kit.hostName).",
                                   details: "\(during): exit \(o.exit). PeakPack: \(p?.heading ?? "") \(p?.details ?? o.status?.message ?? ""). The app's own signature check of the same manifest passed.",
                                   actions: [.repair, .retry, .openLogs])
            }
            return FriendError(code: kind == .signatureCheck ? "peakpack-signature" : (kind == .downloadIntegrity ? "peakpack-integrity" : "peakpack-failed"),
                               heading: p?.heading ?? "Couldn't update the mods",
                               advice: p?.advice ?? "Check your internet connection and click Try Again.",
                               details: "\(during): exit \(o.exit). \(p?.details ?? o.status?.message ?? "")", actions: [.retry, .openLogs])
        }
    }
}
