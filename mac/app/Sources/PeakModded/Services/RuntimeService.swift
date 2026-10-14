import Foundation
import PeakModdedCore

/// Downloads, verifies, unpacks and switches the Wine runtime (Track A + B2 bridge in one tarball).
/// A new runtime goes into runtime/<id> next to the old one; the state only points at it after the
/// prefix has been updated with it, and the previous one is kept for rollback.
struct RuntimeService {
    let env: AppEnvironment
    let log = AppLog.shared

    /// Signed manifest pin if present (FriendInstaller proposal), else the app's embedded pin.
    func effectivePin(signed: PackManifest?) -> KitConfig.Runtime {
        RuntimePinResolver.effective(embedded: env.kit.runtime, signedManifest: signed)
    }

    func isInstalled(_ pin: KitConfig.Runtime) -> Bool {
        let d = env.paths.runtime(pin.id)
        return FileManager.default.isExecutableFile(atPath: d.appendingPathComponent("bin/wine").path)
            && FileManager.default.fileExists(atPath: d.appendingPathComponent("share/peakpack/prefix/pp-env.sh").path)
    }

    /// Download + verify + unpack. Does not switch.
    func install(_ pin: KitConfig.Runtime, progress: @escaping (String, Double?) -> Void) async throws {
        if isInstalled(pin) { return }
        let fm = FileManager.default
        let dl = FileDownloader(isAllowed: env.kit.isAllowed)
        progress("Checking the download list…", nil)
        let sumsData: Data
        do { sumsData = try await dl.fetchData(env.kit.releaseDownloadURL(tag: pin.tag, asset: "SHA256SUMS")) }
        catch { throw FriendError.from(error, context: "SHA256SUMS of \(pin.tag)") }
        let sums = ChecksumList(text: String(decoding: sumsData, as: UTF8.self))
        let expected: String
        do { expected = try Integrity.expectedHash(asset: pin.asset, pinned: pin.sha256, sums: sums) }
        catch { throw FriendError.from(error, context: "runtime pin") }

        if let free = SystemProbe.freeBytes(at: env.paths.dataRoot), free < 2_000_000_000 {
            throw FriendError(code: "disk-full", heading: "Your Mac is almost out of space",
                              advice: "Setup needs about 6 GB free in total. Free up some space, then click Try Again.",
                              details: "free: \(free) bytes", actions: [.retry])
        }

        let tarball = env.paths.downloads.appendingPathComponent(pin.asset)
        let haveGood = fm.fileExists(atPath: tarball.path) && (try? Hashing.sha256Hex(fileAt: tarball)) == expected
        if !haveGood {
            log.info("downloading runtime \(pin.asset)")
            do {
                try await dl.download(env.kit.releaseDownloadURL(tag: pin.tag, asset: pin.asset), to: tarball, expectedSize: pin.size) { p in
                    let mb = Double(p.received) / 1_000_000
                    let total = p.total.map { String(format: " of %.0f MB", Double($0) / 1_000_000) } ?? ""
                    let speed = p.bytesPerSecond > 0 ? String(format: " · %.1f MB/s", p.bytesPerSecond / 1_000_000) : ""
                    progress(String(format: "Downloading… %.0f MB", mb) + total + speed, p.fraction)
                }
            } catch { throw FriendError.from(error, context: "runtime download") }
            progress("Checking the download…", nil)
            do { try Integrity.verify(file: tarball, name: pin.asset, expected: expected) } catch {
                try? fm.removeItem(at: tarball)
                throw FriendError.from(error, context: "runtime verify")
            }
        }
        log.info("runtime \(pin.asset) verified (\(expected.prefix(12)))")

        progress("Unpacking…", nil)
        let staging = env.paths.runtimes.appendingPathComponent(".unpack-\(pin.id)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let tar = ProcessSpec(executable: "/usr/bin/tar", arguments: ["-xJf", tarball.path, "-C", staging.path],
                              environment: ["PATH": "/usr/bin:/bin"])
        let r = try await ProcessRunner.run(tar, logTo: env.paths.logs.appendingPathComponent("setup.log"), timeout: 900)
        let unpacked = staging.appendingPathComponent(pin.id, isDirectory: true)
        guard r.exitCode == 0, fm.isExecutableFile(atPath: unpacked.appendingPathComponent("bin/wine").path) else {
            try? fm.removeItem(at: staging)
            throw FriendError(code: "runtime-unpack", heading: "Couldn't unpack the game engine",
                              advice: "Click Try Again. If your Mac is low on space, free some up first.",
                              details: "tar exit \(r.exitCode): \(r.output.suffix(400))", actions: [.retry])
        }
        let final = env.paths.runtime(pin.id)
        try? fm.removeItem(at: final)
        try fm.moveItem(at: unpacked, to: final)
        try? fm.removeItem(at: staging)
        try? fm.removeItem(at: tarball)
        log.info("runtime \(pin.id) unpacked to \(final.path)")
    }

    /// Point the state at `id` (after the prefix accepted it), remembering the previous one.
    func activate(_ id: String) {
        env.update { s in
            if s.runtimeId != id { s.previousRuntimeId = s.runtimeId }
            s.runtimeId = id
        }
        prune(keep: [id, env.state.previousRuntimeId].compactMap { $0 })
    }

    /// Delete runtimes other than the active and the previous one.
    func prune(keep: [String]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: env.paths.runtimes.path) else { return }
        for n in names where !keep.contains(n) && !n.hasPrefix(".") && n.hasPrefix("pp") {
            log.info("removing old runtime \(n)")
            try? fm.removeItem(at: env.paths.runtime(n))
        }
    }

    /// Repair: compare every file with the runtime's own manifest.
    func damagedFiles() -> [String] {
        guard let rt = env.installedRuntimeDir, let m = RuntimeManifest.load(runtimeDir: rt) else { return ["manifest.json"] }
        return m.damagedFiles(in: rt)
    }

    func remove(_ id: String) { try? FileManager.default.removeItem(at: env.paths.runtime(id)) }
}
