import AppKit
import PeakModdedCore

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0-dev"
    }
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.peakpack.modded" }
    static let displayName = "PEAK (Modded)"
}

struct LaunchOptions {
    var dataDir: URL?
    var logsDir: URL?
    var kitFile: URL?
    var showOptions = false
    var noAutoplay = false
    var printStatus = false
    var printVersion = false
    var afterUpdate = false
    var afterRollback = false
    var skipUpdateCheck = false
    /// Test gates: uninstall moves files here instead of the Trash (the Trash is privacy-protected for scripts).
    var uninstallTo: URL?
    /// CI screenshots: show one sample UI state (DemoScreens) and do nothing else.
    var demoScreen: String?
    /// light | dark: force the appearance (screenshots).
    var appearance: String?
    /// TEST-ONLY (with --data-dir): PeakPack.exe from this URL with this exact SHA-256 instead of the manifest's.
    var testPeakPackURL: String?
    var testPeakPackSHA256: String?

    /// A test run keeps everything in its job dir and never asks to move the app.
    var isTestRun: Bool { dataDir != nil }

    static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        func value() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--data-dir": if let v = value() { o.dataDir = URL(fileURLWithPath: v, isDirectory: true) }
            case "--logs-dir": if let v = value() { o.logsDir = URL(fileURLWithPath: v, isDirectory: true) }
            case "--kit": if let v = value() { o.kitFile = URL(fileURLWithPath: v) }
            case "--uninstall-to": if let v = value() { o.uninstallTo = URL(fileURLWithPath: v, isDirectory: true) }
            case "--demo-screen": o.demoScreen = value()
            case "--appearance": o.appearance = value()
            case "--test-peakpack-url": o.testPeakPackURL = value()
            case "--test-peakpack-sha256": o.testPeakPackSHA256 = value()
            case "--options": o.showOptions = true
            case "--no-autoplay": o.noAutoplay = true
            case "--print-status": o.printStatus = true
            case "--version": o.printVersion = true
            case "--after-update": o.afterUpdate = true
            case "--after-rollback": o.afterRollback = true
            case "--skip-update-check": o.skipUpdateCheck = true
            default: break // macOS may pass -psn_… or -NSDocumentRevisionsDebugMode; ignore unknown
            }
            i += 1
        }
        if let env = ProcessInfo.processInfo.environment["PEAKMODDED_DATA_DIR"], o.dataDir == nil, !env.isEmpty {
            o.dataDir = URL(fileURLWithPath: env, isDirectory: true)
        }
        return o
    }
}

/// Everything a service needs: pins, paths, the state file, the log.
final class AppEnvironment {
    let kit: KitConfig
    let paths: AppPaths
    let store: StateStore
    let options: LaunchOptions
    var state: FrontEndState {
        didSet { if !frozen { try? store.save(state) } }
    }
    /// Set by Uninstall: from then on nothing may recreate the data folder (state, status file).
    var frozen = false

    init(options: LaunchOptions) throws {
        self.options = options
        let kitURL = options.kitFile ?? Bundle.main.url(forResource: "mac-kit", withExtension: "json")
        guard let kitURL else { throw FriendError.internalError("The app is missing its settings file (mac-kit.json). Download it again.") }
        kit = try KitConfig.load(from: kitURL)
        paths = AppPaths(dataRoot: options.dataDir, logs: options.logsDir)
        store = StateStore(url: paths.stateFile)
        state = store.load()
    }

    /// The validated test override, if any (see TestPeakPackOverride). Computed from this run's arguments only.
    lazy var testPeakPack: TestPeakPackOverride? = {
        let (o, why) = TestPeakPackOverride.validate(url: options.testPeakPackURL, sha256: options.testPeakPackSHA256,
                                                     repo: kit.repo, testMode: options.isTestRun)
        if let why { AppLog.shared.warn("--test-peakpack-*: \(why)") }
        if let o { AppLog.shared.warn(o.label) }
        return o
    }()

    func update(_ change: (inout FrontEndState) -> Void) {
        var s = state
        change(&s)
        state = s
    }

    var wineUser: String { paths.wineUser() }

    var installedRuntimeDir: URL? {
        guard let id = state.runtimeId else { return nil }
        let d = paths.runtime(id)
        return FileManager.default.isExecutableFile(atPath: d.appendingPathComponent("bin/wine").path) ? d : nil
    }

    func wine() throws -> WineCommand {
        guard let rt = installedRuntimeDir else {
            throw FriendError(code: "runtime-missing", heading: "The game engine isn't installed",
                              advice: "Click Repair to download it again.", actions: [.repair])
        }
        return WineCommand(runtime: rt, prefix: paths.prefix, logDir: paths.logs.appendingPathComponent("wine", isDirectory: true))
    }
}
