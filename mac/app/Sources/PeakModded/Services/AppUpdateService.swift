import AppKit
import PeakModdedCore

/// Self-update of the app from `mac-build-app-<version>` prereleases (never "latest").
/// Trust today: HTTPS from our own repo + the release's SHA256SUMS + a valid code signature of the staged
/// bundle with our bundle id and the expected version. With a Developer ID later, add a Team ID check here.
struct AppUpdateService {
    let env: AppEnvironment
    let log = AppLog.shared

    func check() async throws -> AppUpdateCandidate? {
        let dl = FileDownloader(isAllowed: env.kit.isAllowed)
        let data = try await dl.fetchData(env.kit.releasesAPIURL, accept: "application/vnd.github+json")
        let releases = try GitHubRelease.decodeList(data)
        env.update { $0.lastAppUpdateCheck = Date() }
        guard let current = DottedVersion(AppInfo.version) else { return nil }
        return AppUpdateFinder.newest(in: releases, tagPrefix: env.kit.app.releaseTagPrefix, zipPrefix: env.kit.app.zipPrefix, current: current)
    }

    var canReplaceSelf: Bool {
        let path = Bundle.main.bundlePath
        guard !AppLocation.isTranslocated(path) else { return false }
        return FileManager.default.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
    }

    /// Download, verify and stage the new bundle; then hand over to the watchdog and quit.
    func install(_ c: AppUpdateCandidate, progress: @escaping (String, Double?) -> Void) async throws {
        let fm = FileManager.default
        let dl = FileDownloader(isAllowed: env.kit.isAllowed)
        let sums = ChecksumList(text: String(decoding: try await dl.fetchData(c.sumsURL), as: UTF8.self))
        let expected = try Integrity.expectedHash(asset: c.zipName, pinned: nil, sums: sums)
        let zip = env.paths.downloads.appendingPathComponent(c.zipName)
        try await dl.download(c.zipURL, to: zip, expectedSize: c.size) { p in
            progress(String(format: "Downloading version %@… %.0f MB", c.version.description, Double(p.received) / 1e6), p.fraction)
        }
        try Integrity.verify(file: zip, name: c.zipName, expected: expected)

        progress("Checking the new version…", nil)
        let staging = env.paths.frontEnd.appendingPathComponent("update-staging", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let unzip = try await ProcessRunner.run(ProcessSpec(executable: "/usr/bin/ditto", arguments: ["-x", "-k", zip.path, staging.path],
                                                            environment: ["PATH": "/usr/bin:/bin"]), timeout: 300)
        let appName = (Bundle.main.bundlePath as NSString).lastPathComponent
        let staged = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" }
        guard unzip.exitCode == 0, let staged, let b = Bundle(url: staged),
              b.bundleIdentifier == AppInfo.bundleID,
              (b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(DottedVersion.init) == c.version
        else { throw FriendError(code: "update-bad-bundle", heading: "The update didn't check out", advice: "Nothing was changed. Try again later.",
                                 details: "unzip \(unzip.exitCode), bundle \(staged?.lastPathComponent ?? "none")", actions: [.cancel]) }
        let (sig, sigOut) = await ProcessRunner.capture("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path], timeout: 60)
        guard sig == 0 else {
            throw FriendError(code: "update-bad-signature", heading: "The update didn't check out", advice: "Nothing was changed. Try again later.",
                              details: "codesign: \(sigOut)", actions: [.cancel])
        }
        // Downloaded by us, so no quarantine attribute; clear any anyway so no Gatekeeper prompt appears.
        _ = await ProcessRunner.capture("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        let finalStaged = staging.appendingPathComponent("ready-" + appName)
        try fm.moveItem(at: staged, to: finalStaged)

        let script = env.paths.frontEnd.appendingPathComponent("self-update.sh")
        try SelfUpdateScript.text.write(to: script, atomically: true, encoding: .utf8)
        let result = env.paths.logs.appendingPathComponent("self-update.log")
        env.update {
            $0.pendingAppUpdate = .init(fromVersion: AppInfo.version, toVersion: c.version.description,
                                        backupPath: env.paths.appBackup.path, startedAt: Date())
        }
        let args = SelfUpdateScript.arguments(scriptPath: script.path, oldPid: ProcessInfo.processInfo.processIdentifier,
                                              installedApp: Bundle.main.bundlePath, stagedApp: finalStaged.path,
                                              backupDir: env.paths.appBackup.path, healthMarker: env.paths.healthMarker.path,
                                              resultFile: result.path)
        _ = try ProcessRunner.start(ProcessSpec(executable: "/bin/bash", arguments: args, environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]),
                                    logTo: result)
        log.info("self-update to \(c.version) staged; quitting for the swap")
        try? fm.removeItem(at: zip)
    }

    /// Called early by every start: report health to a waiting watchdog and settle the pending record.
    func markStarted() -> String? {
        try? Data("\(AppInfo.version)\n".utf8).write(to: env.paths.healthMarker)
        var note: String?
        if let p = env.state.pendingAppUpdate {
            if p.toVersion == AppInfo.version { note = "Updated to version \(AppInfo.version)." }
            else if p.fromVersion == AppInfo.version { note = "The update to \(p.toVersion) didn't start, so version \(AppInfo.version) was put back." }
            env.update { $0.pendingAppUpdate = nil }
        }
        env.update { $0.lastStartedAppVersion = AppInfo.version }
        return note
    }
}
