import Foundation
@testable import PeakModdedCore
import XCTest

/// Setup plan, state, PeakPack headless contract, Wine command lines, updates, diagnostics, downloads.
final class FlowTests: XCTestCase {
    func snap(_ change: (inout ProbeSnapshot) -> Void = { _ in }) -> ProbeSnapshot {
        var s = ProbeSnapshot(macOS: DottedVersion("15.1")!, minMacOS: DottedVersion("14.0")!, appleSilicon: true, rosettaInstalled: true,
                              installedRuntimeId: "pp1-cx26.3.0", wantedRuntimeId: "pp1-cx26.3.0", runtimeFilesPresent: true,
                              prefixRuntimeId: "pp1-cx26.3.0", steamInstalled: true, steamRunning: true, steamClientPresent: true,
                              gameComplete: true, peakPackInstalled: true, modsInstalled: true)
        change(&s)
        return s
    }

    func testSetupOrderAndReadiness() {
        XCTAssertNil(SetupPlan.next(snap()))
        XCTAssertTrue(SetupPlan.readyToPlay(snap()))
        XCTAssertEqual(SetupPlan.next(snap { $0.macOS = DottedVersion("13.6")! }), .macOS)
        if case .blocked = SetupPlan.state(of: .macOS, snap { $0.macOS = DottedVersion("12.7")! }) {} else { XCTFail("old macOS must block") }
        XCTAssertEqual(SetupPlan.next(snap { $0.rosettaInstalled = false }), .rosetta)
        XCTAssertNil(SetupPlan.next(snap { $0.rosettaInstalled = false; $0.appleSilicon = false }), "Intel Macs need no Rosetta")
        XCTAssertEqual(SetupPlan.next(snap { $0.runtimeFilesPresent = false; $0.installedRuntimeId = nil; $0.prefixRuntimeId = nil }), .runtime)
        XCTAssertEqual(SetupPlan.next(snap { $0.steamRunning = false; $0.gameComplete = false }), .steam)
        XCTAssertEqual(SetupPlan.next(snap { $0.gameComplete = false; $0.modsInstalled = false }), .game)
        XCTAssertEqual(SetupPlan.next(snap { $0.modsInstalled = false }), .mods)
    }

    func testRuntimeUpdateRunsPrefixStepThenActivates() {
        // An app update pins pp2: the files are unpacked, but the active runtime and the prefix are still pp1.
        let s = snap { $0.wantedRuntimeId = "pp2-cx26.3.0"; $0.runtimeFilesPresent = true }
        XCTAssertEqual(SetupPlan.state(of: .runtime, s), .done)
        XCTAssertEqual(SetupPlan.next(s), .prefix)
        XCTAssertFalse(SetupPlan.readyToPlay(s))
        let notYet = snap { $0.wantedRuntimeId = "pp2-cx26.3.0"; $0.runtimeFilesPresent = false }
        XCTAssertEqual(SetupPlan.next(notYet), .runtime)
    }

    func testSteamClosedIsNotASetupProblemForDailyLaunch() {
        let s = snap { $0.steamRunning = false }
        XCTAssertEqual(SetupPlan.next(s), .steam)
        XCTAssertTrue(SetupPlan.readyToPlay(s), "the launcher opens Steam itself")
        XCTAssertFalse(SetupPlan.readyToPlay(snap { $0.steamInstalled = false }))
    }

    func testVersions() {
        XCTAssertLessThan(DottedVersion("0.1.0")!, DottedVersion("0.1.1")!)
        XCTAssertLessThan(DottedVersion("0.9")!, DottedVersion("0.10")!)
        XCTAssertEqual(DottedVersion("1.0")!, DottedVersion("1.0.0")!)
        XCTAssertLessThan(DottedVersion("1.0.0-beta")!, DottedVersion("1.0.0")!)
        XCTAssertGreaterThanOrEqual(DottedVersion("14.0")!, DottedVersion("14")!)
        XCTAssertNil(DottedVersion("abc"))
        XCTAssertEqual(DottedVersion("v2.3")!.description, "2.3")
    }

    func testStateRoundTripAndAtomicWrite() throws {
        let d = tempDir()
        let store = StateStore(url: d.appendingPathComponent("frontend/state.json"))
        XCTAssertEqual(store.load(), FrontEndState(), "missing file = fresh state")
        var s = FrontEndState()
        s.runtimeId = "pp1-cx26.3.0"
        s.game = GameRecord(version: "2.6.b", revision: "25739797", manifestId: "42", files: 271, bytes: 1_930_336_210,
                            installedAt: Date(timeIntervalSince1970: 1_760_000_000))
        s.setupComplete = true
        try store.save(s)
        try store.save(s) // replace path
        XCTAssertEqual(store.load(), s)
        try Data("{broken".utf8).write(to: store.url)
        XCTAssertEqual(store.load(), FrontEndState())
    }

    func testPaths() {
        let p = AppPaths(home: URL(fileURLWithPath: "/Users/sam"))
        XCTAssertEqual(p.dataRoot.path, "/Users/sam/Library/Application Support/PeakPack")
        XCTAssertEqual(p.logs.path, "/Users/sam/Library/Logs/PEAK Modded")
        XCTAssertEqual(p.gameDir.path, "/Users/sam/Library/Application Support/PeakPack/prefix/drive_c/Games/PEAK")
        XCTAssertEqual(p.peakPackExe(user: "sam").path,
                       "/Users/sam/Library/Application Support/PeakPack/prefix/drive_c/users/sam/AppData/Local/PeakPack/PeakPack.exe")
        XCTAssertEqual(p.peakPackExeWinPath(user: "sam"), #"C:\users\sam\AppData\Local\PeakPack\PeakPack.exe"#)
        XCTAssertEqual(p.steamClientDylib.path, "/Users/sam/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib")
        XCTAssertEqual(p.depotCandidates(appId: 3527290, depotId: 3527291).first?.path,
                       "/Users/sam/Library/Application Support/Steam/steamapps/content/app_3527290/depot_3527291")
        let t = AppPaths(home: URL(fileURLWithPath: "/Users/sam"), dataRoot: URL(fileURLWithPath: "/tmp/job/appdata"))
        XCTAssertEqual(t.logs.path, "/tmp/job/appdata/Logs", "test runs keep logs in the job dir")
    }

    /// The prefix user is "crossover" even when wineboot also made a folder named after the Mac user.
    func testWineUserIsCrossoverInOurPrefix() throws {
        let root = tempDir("wineuser")
        let p = AppPaths(home: URL(fileURLWithPath: "/Users/sam"), dataRoot: root)
        let users = p.driveC.appendingPathComponent("users")
        XCTAssertEqual(p.wineUser(), "crossover", "no prefix yet: the default is crossover")
        for n in ["Public", "crossover", "sam"] {
            try FileManager.default.createDirectory(at: users.appendingPathComponent(n), withIntermediateDirectories: true)
        }
        // Only crossover holds the live files.
        let pp = users.appendingPathComponent("crossover/AppData/Local/PeakPack")
        try FileManager.default.createDirectory(at: pp, withIntermediateDirectories: true)
        try Data("exe".utf8).write(to: pp.appendingPathComponent("PeakPack.exe"))
        let user = p.wineUser()
        XCTAssertEqual(user, "crossover")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.peakPackExe(user: user).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.peakPackExe(user: "sam").path))
        XCTAssertTrue(p.playerLog(user: user).path.hasSuffix("drive_c/users/crossover/AppData/LocalLow/LandCrab/PEAK/Player.log"))
        XCTAssertEqual(p.peakPackExeWinPath(user: user), #"C:\users\crossover\AppData\Local\PeakPack\PeakPack.exe"#)
        // Without a crossover folder (another Wine build) the first real user folder is used, never Public.
        try FileManager.default.removeItem(at: users.appendingPathComponent("crossover"))
        XCTAssertEqual(p.wineUser(), "sam")
    }

    func testHeadlessContract() throws {
        XCTAssertEqual(HeadlessCommand.arguments(.launch(vanilla: false, onSyncFail: .stop), gameWinPath: #"C:\Games\PEAK"#, statusWinPath: #"C:\s.json"#),
                       ["--headless", "--launch", "--on-sync-fail", "stop", "--launch-method", "direct", "--game-dir", #"C:\Games\PEAK"#, "--status-out", #"C:\s.json"#])
        XCTAssertEqual(HeadlessCommand.arguments(.sync(adopt: true), gameWinPath: "G", statusWinPath: "S"),
                       ["--headless", "--sync", "--adopt", "--game-dir", "G", "--status-out", "S"])
        XCTAssertEqual(HeadlessCommand.arguments(.launch(vanilla: true, onSyncFail: .installed), gameWinPath: "G", statusWinPath: "S")[1...3],
                       ["--launch", "--vanilla", "--on-sync-fail"])
        let json = """
        {"state":"failed","step":"sync","message":"Couldn't download HeliPilot","progress":0.4,"platform":"Wine on macOS",
         "appVersion":"0.4.2","installedRevision":4,"latestRevision":5,"changes":["Heli Pilot 0.3.3"],
         "problem":{"heading":"Can't reach Thunderstore","advice":"Check your internet","details":"timeout"},"exitCode":1}
        """
        let d = tempDir()
        let f = d.appendingPathComponent("status.json")
        try Data(json.utf8).write(to: f)
        let s = try XCTUnwrap(HeadlessStatus.read(f))
        XCTAssertFalse(s.isWorking)
        XCTAssertEqual(s.problem?.heading, "Can't reach Thunderstore")
        XCTAssertEqual(s.installedRevision, 4)
        XCTAssertEqual(PeakPackExit.from(3), .foreignLoader)
        XCTAssertNil(PeakPackExit.from(9))
    }

    func testTestPeakPackOverride() {
        let url = "https://github.com/jmproulx/peakpack/releases/download/mac-build-peakpack-0.4.3-test/PeakPack.exe"
        let sha = "b5c3dbe06e277e893a29a4289e08e69d1ae444ec55f98ced16315bd8d8818fcd"
        let (ok, none) = TestPeakPackOverride.validate(url: url, sha256: sha.uppercased(), repo: "jmproulx/peakpack", testMode: true)
        XCTAssertNil(none)
        XCTAssertEqual(ok?.sha256, sha)
        XCTAssertTrue(ok!.label.hasPrefix("TEST PeakPack override: "))
        XCTAssertEqual(TestPeakPackOverride.validate(url: nil, sha256: nil, repo: "jmproulx/peakpack", testMode: false).0, nil)
        XCTAssertEqual(TestPeakPackOverride.validate(url: url, sha256: sha, repo: "jmproulx/peakpack", testMode: false).1, .notTestMode,
                       "never honoured outside test mode")
        XCTAssertEqual(TestPeakPackOverride.validate(url: url, sha256: nil, repo: "jmproulx/peakpack", testMode: true).1, .incomplete)
        XCTAssertEqual(TestPeakPackOverride.validate(url: url, sha256: "abc", repo: "jmproulx/peakpack", testMode: true).1, .badHash)
        for bad in ["http://github.com/jmproulx/peakpack/releases/download/t/PeakPack.exe",
                    "https://github.com/someone/else/releases/download/t/PeakPack.exe",
                    "https://evil.example/jmproulx/peakpack/releases/download/t/PeakPack.exe",
                    "https://github.com/jmproulx/peakpack/releases/download/t/../x/PeakPack.exe",
                    "https://github.com/jmproulx/peakpack/releases/download/t/PeakPack.zip",
                    "https://github.com/jmproulx/peakpack/releases/download/PeakPack.exe",
                    "https://github.com/jmproulx/peakpack/releases/download/t/PeakPack.exe?x=1"] {
            if case .badURL = TestPeakPackOverride.validate(url: bad, sha256: sha, repo: "jmproulx/peakpack", testMode: true).1 {} else {
                XCTFail("must refuse \(bad)")
            }
        }
    }

    func testPeakPackProblemClassification() throws {
        func status(_ heading: String, _ details: String) throws -> HeadlessStatus {
            let j = #"{"state":"failed","problem":{"heading":"\#(heading)","advice":"a","details":"\#(details)"},"exitCode":1}"#
            return try JSONDecoder().decode(HeadlessStatus.self, from: Data(j.utf8))
        }
        XCTAssertEqual(PeakPackProblemKind.classify(try status("A download didn't pass the safety check",
            "The mod list's signature is invalid, so it was NOT installed. Tell the host - the download may have been tampered with.")), .signatureCheck)
        XCTAssertEqual(PeakPackProblemKind.classify(try status("A download didn't pass the safety check", "SHA-256 mismatch for HeliPilot.dll")), .downloadIntegrity)
        XCTAssertEqual(PeakPackProblemKind.classify(try status("Can't reach Thunderstore", "timeout")), .other)
        XCTAssertEqual(PeakPackProblemKind.classify(nil), .other)
    }

    func testWineCommandFollowsTheRuntimeContract() {
        let w = WineCommand(runtime: URL(fileURLWithPath: "/rt/pp1-cx26.3.0"), prefix: URL(fileURLWithPath: "/data/prefix"),
                            logDir: URL(fileURLWithPath: "/logs/wine"))
        let base = ["HOME": "/Users/sam", "DYLD_LIBRARY_PATH": "/evil", "WINEDLLOVERRIDES": "d3d11=b", "PATH": "/opt/homebrew/bin:/usr/bin",
                    "PP_SYNC": "none", "LANG": "en_GB.UTF-8"]
        let spec = w.wine([#"C:\x.exe"#, "--a"], winhttpOverride: true, knobs: .init(hud: true), base: base)
        XCTAssertEqual(spec.executable, "/bin/bash")
        XCTAssertEqual(spec.arguments[0], "-c")
        XCTAssertTrue(spec.arguments[1].contains(#". "$rt/share/peakpack/prefix/pp-env.sh""#))
        XCTAssertTrue(spec.arguments[1].contains(#"exec "$rt/bin/wine" "$@""#))
        XCTAssertTrue(spec.arguments[1].contains(#"WINEDLLOVERRIDES="winhttp=n,b""#))
        XCTAssertFalse(spec.arguments[1].contains("d3d11"), "never a graphics DLL in WINEDLLOVERRIDES (INTERFACES §3.1)")
        XCTAssertEqual(Array(spec.arguments[2...]), ["pp-wine", "/rt/pp1-cx26.3.0", "/data/prefix", "normal", #"C:\x.exe"#, "--a"])
        XCTAssertNil(spec.environment["DYLD_LIBRARY_PATH"])
        XCTAssertNil(spec.environment["WINEDLLOVERRIDES"])
        XCTAssertNil(spec.environment["PP_SYNC"], "stray knobs are not inherited")
        XCTAssertEqual(spec.environment["PP_HUD"], "1")
        XCTAssertEqual(spec.environment["PP_FRONTEND_WINHTTP"], "1")
        XCTAssertEqual(spec.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(spec.environment["HOME"], "/Users/sam")
        XCTAssertNil(w.wine(["x"], base: base).environment["PP_FRONTEND_WINHTTP"])
        let create = w.createPrefix(base: base)
        XCTAssertEqual(create.arguments, ["/rt/pp1-cx26.3.0/share/peakpack/prefix/pp-create-prefix.sh", "/rt/pp1-cx26.3.0", "/data/prefix", "dxmt"])
        XCTAssertEqual(w.killServer(base: base).environment["WINEPREFIX"], "/data/prefix")
    }

    /// The wrapper really runs: a fake runtime whose pp-env.sh and wine are tiny scripts.
    func testWineWrapperExecutesWithFakeRuntime() async throws {
        let rt = tempDir("rt")
        try FileManager.default.createDirectory(at: rt.appendingPathComponent("share/peakpack/prefix"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rt.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try """
        pp_env() { export WINEPREFIX="$2"; export PP_MODE_SEEN="$3"; unset WINEDLLOVERRIDES; }
        """.write(to: rt.appendingPathComponent("share/peakpack/prefix/pp-env.sh"), atomically: true, encoding: .utf8)
        let wine = rt.appendingPathComponent("bin/wine")
        try "#!/bin/bash\necho \"prefix=$WINEPREFIX mode=$PP_MODE_SEEN ovr=${WINEDLLOVERRIDES:-none} args=$*\"\n".write(to: wine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let w = WineCommand(runtime: rt, prefix: URL(fileURLWithPath: "/data/pfx"), logDir: tempDir("logs"))
        let r = try await ProcessRunner.run(w.wine(["a b", "c"], mode: .logs, winhttpOverride: true), timeout: 20)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertEqual(r.output.trimmingCharacters(in: .whitespacesAndNewlines), "prefix=/data/pfx mode=logs ovr=winhttp=n,b args=a b c")
    }

    func testProcessRunnerTimeoutAndLog() async throws {
        let log = tempDir().appendingPathComponent("p.log")
        let r = try await ProcessRunner.run(ProcessSpec(executable: "/bin/sleep", arguments: ["30"], environment: [:]), logTo: log, timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertTrue((try String(contentsOf: log, encoding: .utf8)).contains("=== exit"))
        // A grandchild that keeps stdout open must not block the call (Wine leaves wineserver running).
        let t0 = Date()
        let r2 = try await ProcessRunner.run(ProcessSpec(executable: "/bin/bash", arguments: ["-c", "(sleep 20 &) ; echo started"], environment: [:]), timeout: 15)
        XCTAssertEqual(r2.exitCode, 0)
        XCTAssertTrue(r2.output.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    func testLauncherArgs() {
        let pp1 = SteamLauncherArgs.hold(helperWinDir: #"C:\PeakPackMac"#, logWinPath: #"C:\PeakPackMac\launcher.log"#, holdUntilExit: false)
        XCTAssertEqual(pp1.first, #"C:\PeakPackMac\peakpack_steam_launcher.exe"#)
        XCTAssertTrue(pp1.contains("--no-launch"))
        XCTAssertFalse(pp1.contains("--hold-until-exit"), "pp1's launcher rejects unknown options")
        XCTAssertEqual(pp1[pp1.firstIndex(of: "--forwarder-src")! + 1], #"C:\PeakPackMac\steamclient64.dll"#)
        let pp2 = SteamLauncherArgs.hold(helperWinDir: "C:\\H", logWinPath: "L", holdUntilExit: true)
        XCTAssertEqual(pp2[pp2.firstIndex(of: "--hold-until-exit")! + 1], "PEAK.exe")
    }

    func testRuntimeManifestCapabilities() throws {
        let d = tempDir()
        try Data(#"{"schema":1,"runtime_id":"pp1-cx26.3.0","files":{"a.txt":"\#(Hashing.sha256Hex(of: Data("hi".utf8)))","b.txt":"\#(String(repeating: "0", count: 64))"}}"#.utf8)
            .write(to: d.appendingPathComponent("manifest.json"))
        try Data("hi".utf8).write(to: d.appendingPathComponent("a.txt"))
        try Data("changed".utf8).write(to: d.appendingPathComponent("b.txt"))
        let m = try XCTUnwrap(RuntimeManifest.load(runtimeDir: d))
        XCTAssertFalse(m.supportsHoldUntilExit, "no launcher block = pp1 = no hold mode")
        XCTAssertEqual(m.damagedFiles(in: d), ["b.txt"])
        try Data(#"{"launcher":{"version":"0.3.0","features":["warmup","hold-until-exit"],"warmup":true,"holdUntilExit":true}}"#.utf8)
            .write(to: d.appendingPathComponent("manifest.json"))
        XCTAssertTrue(RuntimeManifest.load(runtimeDir: d)!.supportsHoldUntilExit)
    }

    // MARK: app updates

    func release(_ tag: String, pre: Bool = true, draft: Bool = false, assets: [String]) -> GitHubRelease {
        GitHubRelease(tag_name: tag, prerelease: pre, draft: draft,
                      assets: assets.map { .init(name: $0, browser_download_url: "https://github.com/jmproulx/peakpack/releases/download/\(tag)/\($0)", size: 10) })
    }

    func testAppUpdateFinder() {
        let rs = [
            release("rev-6", pre: false, assets: ["manifest.json", "PeakPack.exe"]),
            release("mac-build-app-0.1.1", assets: ["PEAK-Modded-Mac-0.1.1.zip", "SHA256SUMS"]),
            release("mac-build-app-0.2.0", assets: ["PEAK-Modded-Mac-0.2.0.zip"]), // no SHA256SUMS: skipped
            release("mac-build-app-0.3.0", draft: true, assets: ["PEAK-Modded-Mac-0.3.0.zip", "SHA256SUMS"]),
            release("mac-build-runtime-pp2-cx26.3.0", assets: ["SHA256SUMS"]),
        ]
        let c = AppUpdateFinder.newest(in: rs, tagPrefix: "mac-build-app-", zipPrefix: "PEAK-Modded-Mac-", current: DottedVersion("0.1.0")!)
        XCTAssertEqual(c?.version, DottedVersion("0.1.1"))
        XCTAssertEqual(c?.zipName, "PEAK-Modded-Mac-0.1.1.zip")
        XCTAssertNil(AppUpdateFinder.newest(in: rs, tagPrefix: "mac-build-app-", zipPrefix: "PEAK-Modded-Mac-", current: DottedVersion("0.1.1")!))
        XCTAssertTrue(AppUpdateFinder.isRequired(current: DottedVersion("0.1.0")!, minFrontEnd: "0.2.0"))
        XCTAssertFalse(AppUpdateFinder.isRequired(current: DottedVersion("0.2.0")!, minFrontEnd: "0.2.0"))
        XCTAssertFalse(AppUpdateFinder.isRequired(current: DottedVersion("0.1.0")!, minFrontEnd: nil))
    }

    func testSignedFrontEndPinAndGameDepot() throws {
        let json = """
        {"schema":1,"revision":7,"platforms":{"mac":{"frontEnd":{"version":"0.2.0","tag":"mac-build-app-0.2.0",
         "zip":"PEAK-Modded-Mac-0.2.0.zip","sha256":"\(String(repeating: "A", count: 64))"},
         "gameDepot":{"appId":3527290,"depotId":3527291,"manifestId":"999","buildId":"26000000"}}}}
        """
        let m = try PackManifest.decode(Data(json.utf8))
        let c = try XCTUnwrap(AppUpdateFinder.fromSigned(m.platforms?.mac?.frontEnd, repo: "jmproulx/peakpack", current: DottedVersion("0.1.0")!))
        XCTAssertEqual(c.zipURL.absoluteString, "https://github.com/jmproulx/peakpack/releases/download/mac-build-app-0.2.0/PEAK-Modded-Mac-0.2.0.zip")
        XCTAssertEqual(c.pinnedSha256, String(repeating: "a", count: 64))
        XCTAssertNil(AppUpdateFinder.fromSigned(m.platforms?.mac?.frontEnd, repo: "jmproulx/peakpack", current: DottedVersion("0.2.0")!))
        XCTAssertEqual(m.packDepotManifestId, "999")
        let rec = GameRecord(version: "2.6.b", revision: nil, manifestId: "111", files: 1, bytes: 1)
        if case .updateAvailable = GameUpdatePolicy.decide(installed: rec, steamPublicManifest: nil, packGameVersion: nil, packDepotManifest: "999") {} else { XCTFail() }
        XCTAssertEqual(GameUpdatePolicy.decide(installed: rec, steamPublicManifest: "111", packGameVersion: nil, packDepotManifest: "999"), .upToDate,
                       "Steam says ours is the current public build: Joshua is behind, nothing to download")
    }

    func testReleaseListDecodes() throws {
        let json = #"[{"tag_name":"rev-5","prerelease":false,"draft":false,"assets":[{"name":"PeakPack.exe","browser_download_url":"https://github.com/a","size":5,"extra":1}],"body":"x"}]"#
        XCTAssertEqual(try GitHubRelease.decodeList(Data(json.utf8)).first?.tag_name, "rev-5")
    }

    func testSelfUpdateScriptIsValidBash() async throws {
        let f = tempDir().appendingPathComponent("self-update.sh")
        try SelfUpdateScript.text.write(to: f, atomically: true, encoding: .utf8)
        let r = try await ProcessRunner.run(ProcessSpec(executable: "/bin/bash", arguments: ["-n", f.path], environment: [:]), timeout: 10)
        XCTAssertEqual(r.exitCode, 0, r.output)
        XCTAssertTrue(SelfUpdateScript.text.contains("seq 1 \(SelfUpdateScript.healthTimeoutSeconds)"))
    }

    func testLocation() {
        XCTAssertTrue(AppLocation.isTranslocated("/private/var/folders/x/AppTranslocation/ABC/d/PEAK (Modded).app"))
        XCTAssertTrue(AppLocation.isInApplications("/Applications/PEAK (Modded).app", home: "/Users/sam"))
        XCTAssertTrue(AppLocation.isInApplications("/Users/sam/Applications/PEAK (Modded).app", home: "/Users/sam"))
        XCTAssertFalse(AppLocation.isInApplications("/Users/sam/Downloads/PEAK (Modded).app", home: "/Users/sam"))
    }

    // MARK: diagnostics + status

    func testDiagnosticsRedaction() {
        let text = #"/Users/sam/Library/x C:\users\sam\AppData drive_c/users/sam/AppData SteamID 76561198012345678 build 25739797"#
        let r = Diagnostics.redact(text, userName: "sam")
        XCTAssertFalse(r.contains("/Users/sam"))
        XCTAssertFalse(r.lowercased().contains(#"c:\users\sam"#))
        XCTAssertFalse(r.contains("users/sam/"))
        XCTAssertFalse(r.contains("76561198012345678"))
        XCTAssertTrue(r.contains("[SteamID …5678]"))
        XCTAssertTrue(r.contains("25739797"), "build ids are not SteamIDs")
        let rep = Diagnostics.report(title: "t", facts: [("App", "0.1.0")], error: "boom at /Users/sam/x", logTail: "", userName: "sam")
        XCTAssertTrue(rep.contains("App: 0.1.0"))
        XCTAssertTrue(rep.contains("/Users/<you>/x"))
        let wine = Diagnostics.redact(#"drive_c/users/crossover/AppData C:\users\crossover\AppData"#, userName: "sam")
        XCTAssertEqual(wine, #"drive_c/users/<you>/AppData C:\users\<you>\AppData"#)
    }

    func testSecretsAreRedacted() {
        let jwt = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIwMDAyYWJjZGVmIiwicGZzaWQiOiJ4eXoifQ.c2lnbmF0dXJlLXBhcnQtb2YtdGhlLXRva2Vu"
        let ticket = String(repeating: "14000000a1b2c3d4", count: 16) // 256 hex chars, like a Steam session ticket
        let sha = String(repeating: "ab", count: 32)                  // 64 hex: a SHA-256 stays
        let player = "[EOS] Authenticating with EOS using token \(jwt) and provider steam"
        let r = Diagnostics.redact(player, userName: "sam")
        XCTAssertEqual(r, "[EOS] Authenticating with EOS using token [redacted] and provider steam")
        XCTAssertFalse(Diagnostics.redact("GetAuthSessionTicket ticket: \(ticket)", userName: "sam").contains(ticket.prefix(40)))
        XCTAssertFalse(Diagnostics.redact("warm-up: got \(ticket)", userName: "sam").contains(ticket.prefix(40)),
                       "a bare long hex run goes too")
        XCTAssertFalse(Diagnostics.redact("access_token=\(jwt)&x=1", userName: "sam").contains("eyJ"))
        XCTAssertFalse(Diagnostics.redact("Authorization: Bearer \(jwt)", userName: "sam").contains("eyJ"))
        let keep = "PeakPack.exe sha256 \(sha) manifest 8123456789012345678 build 25739797"
        XCTAssertEqual(Diagnostics.redact(keep, userName: "sam"), keep, "hashes and ids stay readable")
        XCTAssertEqual(Diagnostics.redact("Successfully got user token", userName: "sam"), "Successfully got user token")
    }

    func testSignedFrontEndPinGovernsUpdates() throws {
        let json = #"{"schema":1,"revision":6,"platforms":{"mac":{"frontEnd":{"version":"0.1.6","tag":"mac-build-app-0.1.6","zip":"PEAK-Modded-Mac-0.1.6.zip","sha256":"\#(String(repeating: "b", count: 64))"}}}}"#
        let m = try PackManifest.decode(Data(json.utf8))
        XCTAssertTrue(AppUpdateFinder.signedPinGoverns(m.platforms?.mac?.frontEnd))
        XCTAssertNil(AppUpdateFinder.fromSigned(m.platforms?.mac?.frontEnd, repo: "jmproulx/peakpack", current: DottedVersion("0.1.6")!),
                     "pinned to the running version: no update, and the release list is not consulted")
        XCTAssertFalse(AppUpdateFinder.signedPinGoverns(nil))
    }

    func testSessionFilePickAndCap() throws {
        let d = tempDir("session")
        let old = d.appendingPathComponent("session-20261014-1900.jsonl")
        let new = d.appendingPathComponent("session-20261014-2100.jsonl")
        try Data("{\"t\":1}\n".utf8).write(to: old)
        let lines = (0..<5000).map { #"{"t":\#($0),"fps":58,"note":"x"}"# }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: new)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        try Data("ignore".utf8).write(to: d.appendingPathComponent("other.txt"))
        XCTAssertEqual(Diagnostics.newestFile(in: d, prefix: "session-", suffix: ".jsonl")?.lastPathComponent, new.lastPathComponent)
        let capped = Diagnostics.lastBytes(of: new, maxBytes: 4096)
        XCTAssertLessThanOrEqual(capped.utf8.count, 4096)
        XCTAssertTrue(capped.hasPrefix("{\"t\":"), "starts at a whole line")
        XCTAssertTrue(capped.hasSuffix("\"note\":\"x\"}\n"))
        XCTAssertNil(Diagnostics.newestFile(in: d.appendingPathComponent("missing"), prefix: "session-", suffix: ".jsonl"))
    }

    func testFrontEndStatusFile() throws {
        let f = tempDir().appendingPathComponent("frontend/status.json")
        var s = FrontEndStatus(appVersion: "0.1.0", phase: "setup")
        s.step = "game"
        s.problem = .init(code: "depot-failed", heading: "h", advice: "a")
        s.pid = 4242
        s.write(to: f)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any]
        XCTAssertEqual(obj?["phase"] as? String, "setup")
        XCTAssertEqual((obj?["problem"] as? [String: Any])?["code"] as? String, "depot-failed")
        XCTAssertEqual(obj?["pid"] as? Int, 4242)
    }

    /// After PEAK exits (or SIGTERM) the last status says "exited" with no pid, never a stale "playing".
    func testFinalStatusIsExitedWithoutPid() throws {
        let f = tempDir().appendingPathComponent("frontend/status.json")
        var s = FrontEndStatus(appVersion: "0.1.5", phase: "playing")
        s.stepState = "working"
        s.message = "PEAK is starting: "
        s.progress = 0.5
        s.pid = 4242
        s.lastLaunch = "modded"
        s.sessionStarted = Date(timeIntervalSince1970: 1_760_000_000)
        s.write(to: f)
        let end = Date(timeIntervalSince1970: 1_760_000_600)
        s.finalized(reason: "game-ended", at: end).write(to: f)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as? [String: Any])
        XCTAssertEqual(obj["phase"] as? String, "exited")
        XCTAssertEqual(obj["stepState"] as? String, "done")
        XCTAssertNil(obj["pid"], "no live pid in a final status")
        XCTAssertNil(obj["progress"])
        XCTAssertEqual(obj["exitReason"] as? String, "game-ended")
        XCTAssertNotNil(obj["endedAt"])
        XCTAssertEqual(obj["lastLaunch"] as? String, "modded", "the launch record is kept")
        XCTAssertNotNil(obj["sessionStarted"])
    }

    func testDownloaderRefusesHostsOffTheList() async {
        let kit = Fixture.kit
        let dl = FileDownloader(isAllowed: kit.isAllowed)
        do {
            _ = try await dl.fetchData(URL(string: "https://example.org/x")!)
            XCTFail("must refuse")
        } catch { XCTAssertEqual(error as? DownloadError, .hostNotAllowed("example.org")) }
        do {
            try await dl.download(URL(string: "http://github.com/x")!, to: tempDir().appendingPathComponent("f")) { _ in }
            XCTFail("must refuse plain http")
        } catch { XCTAssertEqual(error as? DownloadError, .hostNotAllowed("github.com")) }
    }
}
