import AppKit
import PeakModdedCore

/// Gets PEAK's Windows files with the friend's OWN licence through Valve's client (MacPort DESIGN §5.4):
/// the friend pastes `download_depot 3527290 3527291` into Mac Steam's console (one paste + Return);
/// we watch console_log.txt (read-only) and the depot folder size, verify, and move the result into the prefix.
/// Updates: the installed copy is CLONED (APFS clonefile) into Steam's content path first so download_depot
/// can reuse unchanged files; the installed copy is only replaced after the new one verifies.
final class GameService {
    enum Poll: Equatable {
        case waiting
        case downloading(bytes: Int64)
        case completed(DepotCompletion)
        case failed(String)
    }

    let env: AppEnvironment
    let log = AppLog.shared
    private let parser: SteamConsoleParser
    private var tail: LogTail
    private var commandSeen = false
    private var startedAt = Date()
    private var startSize: Int64 = 0
    private var createdAppFolder: URL?
    private(set) var clonedForUpdate: URL?

    init(env: AppEnvironment) {
        self.env = env
        parser = SteamConsoleParser(appId: env.kit.game.appId, depotId: env.kit.game.depotId)
        tail = LogTail(url: env.paths.steamConsoleLog)
    }

    var command: String { parser.command }
    var expectedBytes: Int64 { env.kit.game.expectedBytes }

    /// Where Steam will write: the folder that already exists, else the first candidate.
    var depotTarget: URL {
        let c = env.paths.depotCandidates(appId: env.kit.game.appId, depotId: env.kit.game.depotId)
        return c.first { FileManager.default.fileExists(atPath: $0.path) } ?? c[0]
    }

    func checkSpace(update: Bool) throws {
        let need = Int64(Double(expectedBytes) * (update ? 0.6 : 1.3)) + 1_000_000_000
        if let free = SystemProbe.freeBytes(at: env.paths.steamData), free < need {
            throw FriendError(code: "disk-full", heading: "Not enough free space for PEAK",
                              advice: String(format: "PEAK needs about %.1f GB free. Free up some space, then click Try Again.", Double(need) / 1e9),
                              details: "free \(free), need \(need)", actions: [.retry])
        }
    }

    /// For an update: clone the installed game where download_depot writes, so it only fetches changes.
    func prepareUpdateClone() {
        let fm = FileManager.default
        let target = env.paths.depotCandidates(appId: env.kit.game.appId, depotId: env.kit.game.depotId)[0]
        guard fm.fileExists(atPath: env.paths.gameDir.appendingPathComponent("PEAK.exe").path),
              !fm.fileExists(atPath: target.path) else { return }
        let appFolder = target.deletingLastPathComponent()
        if !fm.fileExists(atPath: appFolder.path) { createdAppFolder = appFolder }
        do {
            try fm.createDirectory(at: appFolder, withIntermediateDirectories: true)
            try fm.copyItem(at: env.paths.gameDir, to: target) // APFS: clonefile, instant, no extra space
            clonedForUpdate = target
            log.info("cloned the installed game into \(target.path) for an update")
        } catch {
            log.warn("could not clone the game for the update (\(error)); Steam will download everything")
        }
    }

    /// Copy the command and open Steam's console. Clipboard is written only; the app never reads it.
    func openConsoleWithCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(command, forType: .string)
        if let u = URL(string: "steam://open/console") { NSWorkspace.shared.open(u) }
        log.info("copied '\(command)' and opened steam://open/console")
    }

    func copyCommandAgain() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    /// Start watching: only console lines written from now on count.
    func beginWatching() {
        tail = LogTail(url: env.paths.steamConsoleLog)
        tail.startAtEnd()
        commandSeen = false
        startedAt = Date()
        let appFolder = depotTarget.deletingLastPathComponent()
        if createdAppFolder == nil, !FileManager.default.fileExists(atPath: appFolder.path) { createdAppFolder = appFolder }
        startSize = FolderSize.measure(depotTarget).1
    }

    var secondsWaiting: TimeInterval { Date().timeIntervalSince(startedAt) }

    func poll() -> Poll {
        for ev in parser.events(in: tail.readNew()) {
            switch ev {
            case .completed(let c): return .completed(c)
            case .failed(let line): return .failed(line)
            case .commandSeen: commandSeen = true
            }
        }
        let size = FolderSize.measure(depotTarget).1
        if commandSeen || size > startSize + 1_000_000 { return .downloading(bytes: size) }
        return .waiting
    }

    /// Verify the finished depot and put it in the prefix. The old copy stays until the new one is in place.
    func install(_ completion: DepotCompletion) throws -> GameRecord {
        let fm = FileManager.default
        var src = URL(fileURLWithPath: completion.path, isDirectory: true)
        if !fm.fileExists(atPath: src.appendingPathComponent("PEAK.exe").path) { src = depotTarget }
        let insp = DepotInspector.inspect(src, requiredFiles: env.kit.game.requiredFiles)
        guard insp.isComplete else {
            throw FriendError(code: "game-incomplete", heading: "PEAK's download is incomplete",
                              advice: "Click Try Again and paste the command into Steam's console once more. Steam will finish the missing files.",
                              details: "missing: \(insp.missing.joined(separator: ", ")) in \(src.path)", actions: [.retry])
        }
        if !DepotInspector.sizeLooksRight(insp, expectedBytes: expectedBytes) {
            log.warn("depot size unusual: \(insp.files) files, \(insp.bytes) bytes (expected ~\(expectedBytes))")
        }
        try place(src)
        cleanupSteamSide()
        let rec = GameRecord(version: insp.version, revision: insp.revision, manifestId: completion.manifestId, files: insp.files, bytes: insp.bytes,
                             steamManifestAtInstall: steamBuildInfo()?.depotPublicManifest)
        env.update { $0.game = rec }
        log.info("PEAK \(insp.version ?? "?") installed (\(insp.files) files, manifest \(completion.manifestId ?? "?"))")
        return rec
    }

    /// Advanced: use a folder the friend already has (still needs their own Steam licence to play).
    func importFolder(_ folder: URL) throws -> GameRecord {
        let insp = DepotInspector.inspect(folder, requiredFiles: env.kit.game.requiredFiles)
        guard insp.isComplete else {
            throw FriendError(code: "game-folder-wrong", heading: "That folder isn't PEAK for Windows",
                              advice: "Choose the folder that contains PEAK.exe.", details: "missing: \(insp.missing.joined(separator: ", "))",
                              actions: [.retry])
        }
        let staged = env.paths.driveC.appendingPathComponent("Games/PEAK.new", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: staged)
        try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: folder, to: staged)
        try place(staged)
        let rec = GameRecord(version: insp.version, revision: insp.revision, manifestId: nil, files: insp.files, bytes: insp.bytes,
                             steamManifestAtInstall: steamBuildInfo()?.depotPublicManifest)
        env.update { $0.game = rec }
        return rec
    }

    /// Swap `src` into Games/PEAK: old → PEAK.old, new → PEAK, then delete PEAK.old. On failure the old copy comes back.
    private func place(_ src: URL) throws {
        let fm = FileManager.default
        let game = env.paths.gameDir, old = env.paths.gameDirOld
        try fm.createDirectory(at: game.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: old)
        let hadOld = fm.fileExists(atPath: game.path)
        // A symlink left by an older test layout is replaced, never followed.
        if hadOld { try fm.moveItem(at: game, to: old) }
        do {
            try fm.moveItem(at: src, to: game) // same volume: a rename; otherwise a copy
        } catch {
            if hadOld { try? fm.moveItem(at: old, to: game) }
            throw FriendError(code: "game-move", heading: "Couldn't move PEAK's files into place",
                              advice: "Your old copy of PEAK was kept. Click Try Again.", details: "\(error)", actions: [.retry])
        }
        if hadOld { try? fm.removeItem(at: old) }
    }

    /// Remove only what our download created in Steam's folders (the emptied app_3527290 folder, our update clone).
    func cleanupSteamSide() {
        let fm = FileManager.default
        if let c = clonedForUpdate, fm.fileExists(atPath: c.path) { try? fm.removeItem(at: c) }
        clonedForUpdate = nil
        if let a = createdAppFolder, let items = try? fm.contentsOfDirectory(atPath: a.path), items.filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: a)
        }
        createdAppFolder = nil
    }

    /// Friend cancelled or the download failed: keep the installed copy, drop our clone.
    func abandon() {
        if clonedForUpdate != nil { log.info("update abandoned; installed copy kept") }
        cleanupSteamSide()
    }

    // MARK: update detection (read-only)

    func steamBuildInfo() -> SteamBuildInfo? {
        AppInfoVDF.buildInfo(fileAt: env.paths.steamAppInfo, appId: env.kit.game.appId, depotId: env.kit.game.depotId)
    }

    func updateVerdict(packGameVersion: String?) -> GameUpdateVerdict {
        let steam = steamBuildInfo()
        let v = GameUpdatePolicy.decide(installed: env.state.game, steamPublicManifest: steam?.depotPublicManifest, packGameVersion: packGameVersion)
        log.info("game update check: \(v) (steam manifest \(steam?.depotPublicManifest ?? "unknown"), build \(steam?.publicBuildId ?? "?"), pack \(packGameVersion ?? "?"), installed \(env.state.game?.manifestId ?? "?")/\(env.state.game?.version ?? "?"))")
        return v
    }
}
