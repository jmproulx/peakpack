import AppKit
import PeakModdedCore
import SwiftUI

/// What the current step is waiting for from the friend.
enum UserWait: Equatable {
    case welcome
    case rosetta
    case steamInstall
    case steamStart
    case gameCommand
    case adoptConfirm
    case gameUpdateOffer(String)
}

enum UserChoice: Equatable { case proceed, alternative, cancel }

enum StepUIState: Equatable { case pending, active, done, failed, blocked }

struct Activity: Equatable {
    var title: String
    var detail: String = ""
    var progress: Double?
}

/// The guided download's live state (drives ConsoleGuideView).
struct GameDownloadUI: Equatable {
    enum Phase: Equatable { case instructions, waiting, downloading, verifying, done }
    var phase: Phase = .instructions
    var isUpdate = false
    var bytes: Int64 = 0
    var expected: Int64 = 1
    var showHint = false
}

@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable { case loading, setup, home, launching, playing, message }
    enum Flow { case setup, play(vanilla: Bool, onSyncFail: HeadlessCommand.OnSyncFail), repair, gameUpdate, appUpdate }

    @Published var screen: Screen = .loading { didSet { writeStatus() } }
    @Published var stepStates: [SetupStep: StepUIState] = [:]
    @Published var activeStep: SetupStep? { didSet { writeStatus() } }
    @Published var activity: Activity? { didSet { writeStatus() } }
    @Published var problem: FriendError? { didSet { writeStatus() } }
    @Published var waiting: UserWait? { didSet { writeStatus() } }
    @Published var game = GameDownloadUI()
    @Published var setupFinished = false
    @Published var updateCandidate: AppUpdateCandidate?
    @Published var notice: String?
    @Published var showFPS: Bool = false
    @Published var message: (title: String, body: String)? = nil {
        didSet { if message != nil { screen = .message } }
    }
    @Published var locationWarning: String?

    let env: AppEnvironment
    let log = AppLog.shared
    private let runtime: RuntimeService
    private let prefix: PrefixService
    private let mods: ModsService
    private let launch: LaunchService
    private let maintenance: MaintenanceService
    private let updater: AppUpdateService
    private var currentGame: GameService?
    private var task: Task<Void, Never>? { didSet { isBusy = task != nil } }
    private var lastFlow: Flow = .setup
    private var choice: UserChoice?
    /// After the game ends the app quits, unless the friend opened the window for something else.
    var quitWhenGameEnds = true
    private var lastStatusPhase = ""

    init(env: AppEnvironment) {
        self.env = env
        runtime = RuntimeService(env: env)
        prefix = PrefixService(env: env)
        mods = ModsService(env: env)
        launch = LaunchService(env: env)
        maintenance = MaintenanceService(env: env)
        updater = AppUpdateService(env: env)
        showFPS = env.state.showFPS
        setupFinished = env.state.setupComplete
        FriendError.hostNameForCopy = env.kit.hostName
        GameUpdatePolicy.hostNameForUpdates = env.kit.hostName
    }

    var hostName: String { env.kit.hostName }
    /// Published so buttons enable/disable when a flow ends.
    @Published private(set) var isBusy = false
    var gameCommand: String { SteamConsoleParser(appId: env.kit.game.appId, depotId: env.kit.game.depotId).command }

    var statusLine: String {
        var parts: [String] = []
        if let rev = env.state.packRevision { parts.append("Mods: revision \(rev)") }
        if let v = env.state.game?.version { parts.append("PEAK \(v)") }
        return parts.isEmpty ? "Ready to play" : "Ready to play · " + parts.joined(separator: " · ")
    }

    // MARK: entry points

    func start(showOptions: Bool, autoplay: Bool, afterUpdateNote: String?) {
        notice = afterUpdateNote
        checkLocation()
        if !env.state.setupComplete {
            screen = .setup
            waiting = .welcome
            refreshStepsQuietly()
        } else if showOptions || !autoplay {
            quitWhenGameEnds = false
            screen = .home
        } else {
            play()
        }
        if !env.options.skipUpdateCheck { checkForAppUpdate(userInitiated: false) }
    }

    func showHome() {
        quitWhenGameEnds = false
        if task == nil { screen = env.state.setupComplete ? .home : .setup }
    }

    func beginSetup() {
        waiting = nil
        if task == nil { run(.setup) }
    }

    func play(vanilla: Bool = false, onSyncFail: HeadlessCommand.OnSyncFail = .stop) {
        guard task == nil else { return }
        run(.play(vanilla: vanilla, onSyncFail: onSyncFail))
    }

    func repair() { guard task == nil else { return }; quitWhenGameEnds = false; run(.repair) }
    func updateGame() { guard task == nil else { return }; quitWhenGameEnds = false; run(.gameUpdate) }

    func toggleFPS() {
        showFPS.toggle()
        env.update { $0.showFPS = showFPS }
    }

    func choose(_ c: UserChoice) { choice = c }

    func cancelCurrent() {
        choose(.cancel)
        task?.cancel()
    }

    // MARK: flow runner

    private func run(_ flow: Flow) {
        lastFlow = flow
        problem = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                switch flow {
                case .setup: try await self.setupFlow()
                case .play(let v, let f): try await self.playFlow(vanilla: v, onSyncFail: f)
                case .repair: try await self.repairFlow()
                case .gameUpdate: try await self.gameUpdateFlow()
                case .appUpdate: try await self.appUpdateFlow()
                }
            } catch is CancellationError {
                self.log.info("flow cancelled")
                self.activity = nil
                self.screen = self.env.state.setupComplete ? .home : .setup
            } catch {
                let f = FriendError.from(error, context: "\(flow)")
                if f.code == "cancelled" {
                    self.activity = nil
                    self.screen = self.env.state.setupComplete ? .home : .setup
                } else {
                    self.log.error("\(f.code): \(f.heading) | \(f.details)")
                    if let s = self.activeStep { self.stepStates[s] = .failed }
                    self.problem = f
                    if self.screen == .playing { self.screen = .launching }
                }
            }
            self.waiting = nil
            self.task = nil
        }
    }

    func retry() {
        problem = nil
        run(lastFlow)
    }

    func perform(_ action: FriendError.Action) {
        switch action {
        case .retry: retry()
        case .repair: problem = nil; repair()
        case .openSteam:
            if let u = SystemProbe.steamAppURL { NSWorkspace.shared.openApplication(at: u, configuration: .init()) }
        case .getSteam: openURL("https://store.steampowered.com/about/")
        case .openSoftwareUpdate: openURL("x-apple.systempreferences:com.apple.preferences.softwareupdate")
        case .installRosetta: Task { await maintenance.askMacOSToInstallRosetta() }
        case .playWithInstalledMods: problem = nil; play(onSyncFail: .installed)
        case .playNormal: problem = nil; play(vanilla: true)
        case .openLogs: maintenance.openLogs()
        case .moveToApplications: moveToApplications()
        case .checkForUpdates: checkForAppUpdate(userInitiated: true)
        case .cancel:
            problem = nil
            activity = nil
            screen = env.state.setupComplete ? .home : .setup
        }
    }

    func openURL(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    /// Waits for a friend action or for `condition` to become true (polled).
    private func wait(for w: UserWait, until condition: (() async -> Bool)? = nil, every seconds: Double = 2) async throws -> UserChoice {
        choice = nil
        waiting = w
        defer { waiting = nil }
        while true {
            try Task.checkCancellation()
            if let c = choice {
                choice = nil
                if c == .cancel { throw CancellationError() }
                return c
            }
            if let condition, await condition() { return .proceed }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    private func setActivity(_ title: String, _ detail: String = "", _ progress: Double? = nil) {
        activity = Activity(title: title, detail: detail, progress: progress)
    }

    private func progressSink() -> (String, Double?) -> Void {
        { [weak self] detail, fraction in
            Task { @MainActor in
                guard let self, var a = self.activity else { return }
                a.detail = detail
                a.progress = fraction
                self.activity = a
            }
        }
    }

    // MARK: setup

    private func refreshStepsQuietly() {
        Task {
            let snap = await SystemProbe.snapshot(env, wantedRuntime: env.kit.runtime.id)
            for s in SetupStep.allCases where stepStates[s] == nil || stepStates[s] == .pending {
                stepStates[s] = SetupPlan.state(of: s, snap) == .done ? .done : .pending
            }
        }
    }

    private func setupFlow() async throws {
        screen = .setup
        let manifest = try? await mods.signedManifest()
        let pin = runtime.effectivePin(signed: manifest)
        log.info("setup: runtime pin \(pin.id), pack rev \(manifest.map { String($0.revision) } ?? "unknown")")
        var guardCount = 0
        while true {
            try Task.checkCancellation()
            let snap = await SystemProbe.snapshot(env, wantedRuntime: pin.id)
            for s in SetupStep.allCases {
                switch SetupPlan.state(of: s, snap) {
                case .done: stepStates[s] = .done
                case .blocked: stepStates[s] = .blocked
                case .todo: if stepStates[s] != .failed { stepStates[s] = .pending }
                }
            }
            guard let step = SetupPlan.next(snap) else { break }
            guardCount += 1
            if guardCount > 20 { throw FriendError.internalError("setup did not make progress at \(step.rawValue)") }
            activeStep = step
            stepStates[step] = .active
            try await perform(step, snapshot: snap, pin: pin, manifest: manifest)
        }
        activeStep = nil
        activity = nil
        env.update { $0.setupComplete = true }
        setupFinished = true
        log.info("setup complete")
        writeStatus(phaseOverride: "done")
    }

    private func perform(_ step: SetupStep, snapshot snap: ProbeSnapshot, pin: KitConfig.Runtime, manifest: PackManifest?) async throws {
        switch step {
        case .macOS:
            if case .blocked(let why) = SetupPlan.state(of: .macOS, snap) {
                throw FriendError(code: "macos-too-old", heading: "This Mac needs a newer macOS",
                                  advice: "\(why) Update macOS in System Settings → General → Software Update, then open PEAK (Modded) again.",
                                  actions: [.openSoftwareUpdate])
            }
        case .rosetta:
            setActivity("Rosetta is needed", "macOS will ask you to install it. Click Install and follow the steps.")
            await maintenance.askMacOSToInstallRosetta()
            _ = try await wait(for: .rosetta, until: { await SystemProbe.rosettaInstalled() })
        case .runtime:
            setActivity("Downloading the game engine", "About 160 MB", nil)
            try await runtime.install(pin, progress: progressSink())
        case .prefix:
            setActivity("Preparing PEAK's Windows folder", "This takes about a minute.")
            do {
                try await prefix.create(runtimeId: pin.id)
                runtime.activate(pin.id)
            } catch {
                // An engine update that the prefix rejects: go back to the engine that worked.
                if let old = env.state.runtimeId, old != pin.id, runtime.isInstalled(KitConfig.Runtime(id: old, tag: "", asset: "", sha256: "")) {
                    log.warn("prefix rejected \(pin.id); restoring \(old)")
                    try? await prefix.create(runtimeId: old)
                }
                throw error
            }
        case .steam:
            if SystemProbe.steamAppURL == nil {
                setActivity("Steam for Mac is needed", "")
                _ = try await wait(for: .steamInstall, until: { SystemProbe.steamAppURL != nil })
            }
            if !(await SystemProbe.steamRunning()) || !FileManager.default.fileExists(atPath: env.paths.steamClientDylib.path) {
                setActivity("Open Steam and sign in", "")
                let dylib = env.paths.steamClientDylib.path
                _ = try await wait(for: .steamStart, until: { await SystemProbe.steamRunning() && FileManager.default.fileExists(atPath: dylib) })
            }
        case .game:
            try await gameDownload(update: false)
        case .mods:
            try await installMods(manifest: manifest)
        }
        stepStates[step] = .done
    }

    // MARK: game files (guided paste)

    private func gameDownload(update: Bool) async throws {
        let g = GameService(env: env)
        currentGame = g
        defer { currentGame = nil }
        try g.checkSpace(update: update)
        if update { g.prepareUpdateClone() }
        game = GameDownloadUI(phase: .instructions, isUpdate: update, bytes: 0, expected: g.expectedBytes, showHint: false)
        activity = nil
        do {
            let c = try await wait(for: .gameCommand)
            if c == .alternative, let rec = currentImportResult { currentImportResult = nil; finishGame(rec); return }
            game.phase = .waiting
            while true {
                try Task.checkCancellation()
                if let c = choice {
                    choice = nil
                    if c == .cancel { throw CancellationError() }
                    if c == .alternative { g.openConsoleWithCommand() } // "Show me again"
                }
                switch g.poll() {
                case .waiting:
                    if g.secondsWaiting > 90 { game.showHint = true }
                case .downloading(let b):
                    game.phase = .downloading
                    game.bytes = b
                    game.showHint = false
                case .completed(let done):
                    game.phase = .verifying
                    let rec = try g.install(done)
                    finishGame(rec)
                    return
                case .failed(let line):
                    throw FriendError(code: "depot-failed", heading: "Steam couldn't download PEAK",
                                      advice: "Make sure Steam is signed in with the account that owns PEAK, then click Try Again.",
                                      details: "Steam console: \(line)", actions: [.retry, .openSteam])
                }
                writeStatus()
                try await Task.sleep(nanoseconds: 1_500_000_000)
            }
        } catch {
            g.abandon()
            throw error
        }
    }

    private func finishGame(_ rec: GameRecord) {
        game.phase = .done
        log.info("game files ready: \(rec.version ?? "?")")
    }

    /// Button: "Open Steam Console". Watching starts before Steam opens, so the echo is never missed.
    func openSteamConsole() {
        guard let g = currentGame else { return }
        g.beginWatching()
        g.openConsoleWithCommand()
        choose(.proceed)
    }

    func showConsoleAgain() { choose(.alternative) }
    func copyCommandAgain() { currentGame?.copyCommandAgain() }

    private var currentImportResult: GameRecord?

    /// Advanced: "Use a PEAK folder I already have…"
    func importGameFolder(_ url: URL) {
        guard let g = currentGame else { return }
        do {
            currentImportResult = try g.importFolder(url)
            choose(.alternative)
        } catch {
            problem = FriendError.from(error, context: "import folder")
        }
    }

    // MARK: mods

    private func installMods(manifest: PackManifest?) async throws {
        setActivity("Installing \(hostName)'s mods", "Checking \(hostName)'s mod list…")
        let m: PackManifest
        if let manifest { m = manifest } else { m = try await mods.signedManifest() }
        try await mods.installPeakPack(manifest: m, progress: progressSink())
        try await prefix.ensureGUISession()
        var outcome = try await mods.headless(.sync(adopt: false), name: "sync", timeout: 1800, onStatus: headlessSink())
        if outcome.exit == PeakPackExit.foreignLoader.rawValue {
            _ = try await wait(for: .adoptConfirm)
            outcome = try await mods.headless(.sync(adopt: true), name: "sync-adopt", timeout: 1800, onStatus: headlessSink())
        }
        guard outcome.exit == 0 else { throw mods.error(for: outcome, during: "sync") }
    }

    private func headlessSink() -> (HeadlessStatus) -> Void {
        { [weak self] s in
            Task { @MainActor in
                guard let self, var a = self.activity else { return }
                if let m = s.message, !m.isEmpty { a.detail = m }
                a.progress = s.progress
                self.activity = a
            }
        }
    }

    // MARK: play

    private func playFlow(vanilla: Bool, onSyncFail: HeadlessCommand.OnSyncFail) async throws {
        screen = .launching
        setActivity(vanilla ? "Starting normal PEAK" : "Starting PEAK with \(hostName)'s mods", "Checking for updates…")
        let manifest = try? await mods.signedManifest()
        if let m = manifest, let cur = DottedVersion(AppInfo.version),
           AppUpdateFinder.isRequired(current: cur, minFrontEnd: m.platforms?.mac?.minFrontEnd) {
            log.info("pack requires front end \(m.platforms?.mac?.minFrontEnd ?? "?")")
            try await appUpdateFlow(required: true)
            return
        }
        let pin = runtime.effectivePin(signed: manifest)
        var snap = await SystemProbe.snapshot(env, wantedRuntime: pin.id)
        if !SetupPlan.readyToPlay(snap) {
            // e.g. a new engine pinned by an app update, or something removed: run the missing steps.
            log.info("not ready to play (next: \(SetupPlan.next(snap)?.rawValue ?? "-")); running setup steps")
            try await setupFlow()
            screen = .launching
            setActivity(vanilla ? "Starting normal PEAK" : "Starting PEAK with \(hostName)'s mods")
            snap = await SystemProbe.snapshot(env, wantedRuntime: pin.id)
        }
        try await prefix.ensureGUISession()
        if await SystemProbe.peakRunning() {
            throw FriendError(code: "peak-running", heading: "PEAK is already running",
                              advice: "Switch to PEAK, or quit it and try again.", actions: [.retry, .cancel])
        }
        try await launch.ensureSteam { [weak self] msg in Task { @MainActor in self?.activity?.detail = msg } }

        // Game update?
        let g = GameService(env: env)
        if case .updateAvailable(let reason) = g.updateVerdict(packGameVersion: manifest?.gameVersion, packDepotManifest: manifest?.packDepotManifestId) {
            let c = try await wait(for: .gameUpdateOffer(reason))
            if c == .proceed {
                try await gameUpdateFlow()
                screen = .launching
                setActivity(vanilla ? "Starting normal PEAK" : "Starting PEAK with \(hostName)'s mods")
            }
        }

        activity?.detail = "Connecting to Steam…"
        try launch.stageBridgeFiles()
        try await launch.startHold()
        activity?.detail = vanilla ? "Starting PEAK…" : "Checking \(hostName)'s mods…"
        let outcome: ModsService.HeadlessOutcome
        do {
            outcome = try await mods.headless(.launch(vanilla: vanilla, onSyncFail: onSyncFail), name: "launch", timeout: 1800, onStatus: headlessSink())
        } catch {
            await launch.cleanupAfterGame()
            throw error
        }
        guard outcome.exit == 0 else {
            await launch.cleanupAfterGame()
            if outcome.exit == PeakPackExit.failed.rawValue, !vanilla, onSyncFail == .stop {
                var f = mods.error(for: outcome, during: "launch")
                f.advice += " You can still play with the mods you already have, or play normal PEAK."
                f.actions = [.playWithInstalledMods, .playNormal, .cancel]
                throw f
            }
            throw mods.error(for: outcome, during: "launch")
        }
        env.update { $0.packRevision = outcome.status?.installedRevision ?? $0.packRevision }
        lastLaunch = vanilla ? "vanilla" : (onSyncFail == .installed ? "modded-installed" : "modded")
        setActivity("PEAK is starting", "The first start can take a minute while shaders are prepared.")
        screen = .playing
        let appeared = await launch.waitForPeakToFinish()
        await launch.cleanupAfterGame()
        guard appeared else {
            throw FriendError(code: "peak-did-not-start", heading: "PEAK didn't start",
                              advice: "Click Try Again. If it happens again, click Copy Diagnostics and send it to \(hostName).",
                              details: "PeakPack reported a launch, but no PEAK.exe appeared.", actions: [.retry, .openLogs])
        }
        log.info("PEAK exited")
        activity = nil
        if quitWhenGameEnds { NSApp.terminate(nil) } else { screen = .home }
    }

    private var lastLaunch: String?

    // MARK: game update

    private func gameUpdateFlow() async throws {
        screen = .setup
        activeStep = .game
        stepStates[.game] = .active
        try await gameDownload(update: true)
        stepStates[.game] = .done
        activeStep = nil
        // New game files: let PeakPack re-check the pack (Doorstop proxy files live in the game folder).
        setActivity("Updating \(hostName)'s mods for the new PEAK", "")
        try await installMods(manifest: nil)
        activity = nil
        screen = .home
    }

    // MARK: repair

    private func repairFlow() async throws {
        screen = .launching
        setActivity("Repairing", "Stopping PEAK's background processes…")
        await prefix.stopWine()
        if env.state.runtimeId != nil {
            activity?.detail = "Checking the game engine's files…"
            let damaged = await Task.detached { [runtime] in runtime.damagedFiles() }.value
            if !damaged.isEmpty {
                log.warn("repair: runtime damaged (\(damaged.prefix(5).joined(separator: ", "))); reinstalling")
                if let id = env.state.runtimeId { runtime.remove(id) }
                env.update { $0.runtimeId = nil }
            }
        }
        if let id = env.state.runtimeId {
            activity?.detail = "Re-applying PEAK's Windows settings…"
            try await prefix.create(runtimeId: id)
        }
        try await setupFlow()
        screen = .launching
        setActivity("Repairing", "Re-checking \(hostName)'s mods…")
        let outcome = try await mods.headless(.sync(adopt: false), name: "repair-sync", timeout: 1800, onStatus: headlessSink())
        guard outcome.exit == 0 else { throw mods.error(for: outcome, during: "repair sync") }
        activity = nil
        notice = "Repair finished. Everything checks out."
        screen = .home
    }

    // MARK: app update

    func checkForAppUpdate(userInitiated: Bool) {
        if !userInitiated, let last = env.state.lastAppUpdateCheck, Date().timeIntervalSince(last) < 6 * 3600 { return }
        Task {
            do {
                let c = try await updater.check(signed: mods.cachedManifest())
                updateCandidate = c
                if userInitiated && c == nil { notice = "You have the newest version (\(AppInfo.version))." }
            } catch {
                log.warn("update check failed: \(error)")
                if userInitiated { notice = "Couldn't check for updates. Check your internet connection." }
            }
        }
    }

    func installAppUpdate() {
        guard task == nil else { return }
        run(.appUpdate)
    }

    private func appUpdateFlow(required: Bool = false) async throws {
        screen = .launching
        setActivity("Updating PEAK (Modded)", required ? "\(hostName)'s mods need a newer version of this app." : "")
        guard updater.canReplaceSelf else {
            throw FriendError(code: "update-location", heading: "Move PEAK (Modded) to Applications first",
                              advice: "The app can only update itself from your Applications folder. Drag it there, open it again, then update.",
                              actions: [.moveToApplications, .cancel])
        }
        var c = updateCandidate
        if c == nil { c = try await updater.check(signed: mods.cachedManifest()) }
        guard let candidate = c else {
            if required {
                throw FriendError(code: "update-unavailable", heading: "A newer PEAK (Modded) is needed",
                                  advice: "\(hostName)'s mods need a newer app, but none could be found yet. Ask \(hostName) for the new download.",
                                  actions: [.checkForUpdates, .cancel])
            }
            notice = "You have the newest version (\(AppInfo.version))."
            screen = .home
            return
        }
        try await updater.install(candidate, progress: progressSink())
        NSApp.terminate(nil)
    }

    func markStarted() -> String? { updater.markStarted() }

    // MARK: location

    private func checkLocation() {
        guard !env.options.isTestRun else { return }
        let path = Bundle.main.bundlePath
        if AppLocation.isTranslocated(path) {
            locationWarning = "Drag PEAK (Modded) into your Applications folder, then open it from there. Otherwise it can't update itself."
        } else if !AppLocation.isInApplications(path, home: NSHomeDirectory()) {
            locationWarning = "PEAK (Modded) works best from your Applications folder."
        }
    }

    func moveToApplications() {
        let src = Bundle.main.bundleURL
        guard !AppLocation.isTranslocated(src.path) else {
            message = (title: "Move the app to Applications", body: "Open Finder, drag PEAK (Modded) from your Downloads into Applications, then open it from Applications.")
            return
        }
        let dest = URL(fileURLWithPath: "/Applications").appendingPathComponent(src.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
            try FileManager.default.copyItem(at: src, to: dest)
            NSWorkspace.shared.openApplication(at: dest, configuration: .init()) { _, _ in
                DispatchQueue.main.async {
                    try? FileManager.default.trashItem(at: src, resultingItemURL: nil)
                    NSApp.terminate(nil)
                }
            }
        } catch {
            problem = FriendError(code: "move-failed", heading: "Couldn't move the app",
                                  advice: "Drag PEAK (Modded) into your Applications folder yourself, then open it from there.",
                                  details: "\(error)", actions: [.cancel])
        }
    }

    // MARK: uninstall / diagnostics

    func uninstall() {
        guard task == nil else { return }
        task = Task {
            screen = .launching
            setActivity("Removing PEAK (Modded)", "Moving files to the Trash…")
            env.frozen = true
            let failed = await maintenance.uninstall()
            activity = nil
            if failed.isEmpty {
                message = (title: "PEAK (Modded) was moved to the Trash",
                           body: "Its game engine, PEAK's Windows files and the mods are in the Trash too. Empty the Trash to free the space. Steam and your Steam games were not touched.")
            } else {
                message = (title: "Some files couldn't be moved to the Trash", body: failed.joined(separator: "\n"))
            }
            task = nil
        }
    }

    func copyDiagnostics() {
        Task {
            let text = await maintenance.diagnostics(lastError: problem, extra: [("Screen", "\(screen)"), ("Step", activeStep?.rawValue ?? "-")])
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notice = "Diagnostics copied. Paste them into a message to \(hostName)."
        }
    }

    func openLogs() { maintenance.openLogs() }

    // MARK: status file (for test gates; no personal data)

    func writeStatus(phaseOverride: String? = nil) {
        guard !env.frozen else { return }
        var s = FrontEndStatus(appVersion: AppInfo.version, phase: phaseOverride ?? phaseName)
        s.step = activeStep?.rawValue ?? (screen == .setup && waiting == .welcome ? "welcome" : nil)
        if problem != nil { s.stepState = "failed" } else if waiting != nil { s.stepState = "waiting-for-user" }
        else if activity != nil { s.stepState = "working" } else { s.stepState = "done" }
        s.message = waiting.map { "waiting: \($0)" } ?? activity.map { "\($0.title): \($0.detail)" }
        s.progress = activity?.progress ?? (game.phase == .downloading ? min(0.99, Double(game.bytes) / Double(max(game.expected, 1))) : nil)
        if let p = problem { s.problem = .init(code: p.code, heading: p.heading, advice: p.advice) }
        s.runtimeId = env.state.runtimeId
        if let g = env.state.game { s.game = .init(version: g.version, manifestId: g.manifestId, files: g.files) }
        s.packRevision = env.state.packRevision
        s.lastLaunch = lastLaunch
        s.write(to: env.paths.statusFile)
    }

    private var phaseName: String {
        if problem != nil { return "error" }
        switch screen {
        case .loading: return "loading"
        case .setup: return setupFinished && activeStep == nil ? "done" : (waiting == .welcome ? "welcome" : "setup")
        case .home: return "ready"
        case .launching: return "launching"
        case .playing: return "playing"
        case .message: return "message"
        }
    }
}
