import Foundation
@testable import PeakModdedCore
import XCTest

/// Steam console log parsing, the depot checks, game-update decisions and the appinfo.vdf reader.
final class SteamTests: XCTestCase {
    let parser = SteamConsoleParser(appId: 3527290, depotId: 3527291)

    func testCommandText() {
        XCTAssertEqual(parser.command, "download_depot 3527290 3527291")
    }

    func testCompletionWithManifestAndPath() {
        let log = """
        [2026-10-13 12:00:01] download_depot 3527290 3527291
        [2026-10-13 12:00:02] Downloading depot 3527291 (1930 MB) ...
        [2026-10-13 12:09:40] Depot download complete : "/Users/sam/Library/Application Support/Steam/steamapps/content/app_3527290/depot_3527291" (manifest 8123456789012345678)
        """
        let ev = parser.events(in: log)
        XCTAssertEqual(ev.first, .commandSeen)
        XCTAssertEqual(ev.last, .completed(DepotCompletion(
            path: "/Users/sam/Library/Application Support/Steam/steamapps/content/app_3527290/depot_3527291",
            manifestId: "8123456789012345678")))
    }

    func testCompletionOfAnotherDepotIsIgnored() {
        let ev = parser.events(in: #"Depot download complete : "/x/steamapps/content/app_440/depot_441" (manifest 1)"#)
        XCTAssertTrue(ev.isEmpty)
    }

    func testCompletionWithoutManifestAndCRLF() {
        let ev = parser.events(in: "noise\r\nDepot download complete : \"/a/app_3527290/depot_3527291\"\r\n")
        XCTAssertEqual(ev, [.completed(DepotCompletion(path: "/a/app_3527290/depot_3527291", manifestId: nil))])
    }

    func testFailureLines() {
        let ev = parser.events(in: "[2026-10-13 12:00:02] download_depot: failed, no license for app 3527290\n")
        XCTAssertEqual(ev, [.failed("download_depot: failed, no license for app 3527290")])
        XCTAssertTrue(parser.events(in: "Some other line about error in shader cache\n").isEmpty, "unrelated errors are ignored")
    }

    func testLogTailOnlyNewCompleteLines() throws {
        let d = tempDir()
        let f = d.appendingPathComponent("console_log.txt")
        try "old line\n".write(to: f, atomically: true, encoding: .utf8)
        let t = LogTail(url: f)
        t.startAtEnd()
        XCTAssertEqual(t.readNew(), "")
        let h = try FileHandle(forWritingTo: f)
        try h.seekToEnd()
        try h.write(contentsOf: Data("new one\npartial".utf8))
        XCTAssertEqual(t.readNew(), "new one\n")
        try h.write(contentsOf: Data(" done\n".utf8))
        try h.close()
        XCTAssertEqual(t.readNew(), "partial done\n")
        // Rotation/truncation restarts from 0.
        try "fresh\n".write(to: f, atomically: false, encoding: .utf8)
        XCTAssertEqual(t.readNew(), "fresh\n")
    }

    // MARK: depot folder

    func makeDepot(_ dir: URL, files: [String], version: String? = "2.6.b\n25739797\n") throws {
        for f in files {
            let u = dir.appendingPathComponent(f)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1000).write(to: u)
        }
        if let version { try version.write(to: dir.appendingPathComponent("version.txt"), atomically: true, encoding: .utf8) }
    }

    func testDepotInspection() throws {
        let kit = Fixture.kit
        let d = tempDir()
        try makeDepot(d, files: Array(kit.game.requiredFiles.dropLast()))
        var i = DepotInspector.inspect(d, requiredFiles: kit.game.requiredFiles)
        XCTAssertFalse(i.isComplete)
        XCTAssertEqual(i.missing, [kit.game.requiredFiles.last!])
        try makeDepot(d, files: kit.game.requiredFiles)
        i = DepotInspector.inspect(d, requiredFiles: kit.game.requiredFiles)
        XCTAssertTrue(i.isComplete)
        XCTAssertEqual(i.version, "2.6.b")
        XCTAssertEqual(i.revision, "25739797")
        XCTAssertEqual(i.files, kit.game.requiredFiles.count + 1)
        XCTAssertFalse(DepotInspector.sizeLooksRight(i, expectedBytes: kit.game.expectedBytes), "a few KB is not PEAK")
        XCTAssertTrue(DepotInspector.sizeLooksRight(DepotInspection(missing: [], version: nil, revision: nil, files: 271, bytes: 1_930_336_210),
                                                    expectedBytes: kit.game.expectedBytes))
    }

    // MARK: game update decision

    func testUpdatePolicy() {
        let rec = GameRecord(version: "2.6.b", revision: nil, manifestId: "111", files: 271, bytes: 1)
        XCTAssertEqual(GameUpdatePolicy.decide(installed: nil, steamPublicManifest: "1", packGameVersion: nil), .notInstalled)
        XCTAssertEqual(GameUpdatePolicy.decide(installed: rec, steamPublicManifest: "111", packGameVersion: "2.7.a"), .upToDate,
                       "Steam's manifest id wins over the pack's version")
        if case .updateAvailable = GameUpdatePolicy.decide(installed: rec, steamPublicManifest: "222", packGameVersion: nil) {} else { XCTFail() }
        if case .updateAvailable = GameUpdatePolicy.decide(installed: rec, steamPublicManifest: nil, packGameVersion: "2.6.c") {} else { XCTFail() }
        XCTAssertEqual(GameUpdatePolicy.decide(installed: rec, steamPublicManifest: nil, packGameVersion: "2.6.a"), .upToDate,
                       "an older pack is not a reason to re-download")
        var noId = rec; noId.manifestId = nil; noId.version = nil
        XCTAssertEqual(GameUpdatePolicy.decide(installed: noId, steamPublicManifest: "1", packGameVersion: "2.6.b"), .unknown)
    }

    func testGameVersionCompare() {
        XCTAssertEqual(GameVersion.compare("2.6.b", "2.6.c"), -1)
        XCTAssertEqual(GameVersion.compare("2.7.a", "2.6.z"), 1)
        XCTAssertEqual(GameVersion.compare("2.6.b", "2.6.b"), 0)
        XCTAssertEqual(GameVersion.compare("1.10", "1.9"), 1)
        XCTAssertEqual(GameVersion.compare("2.6", "2.6.a"), -1)
        XCTAssertEqual(GameVersion.compare("2.6b", "2.6.b"), 0)
    }

    // MARK: appinfo.vdf

    func peakEntry(newLayout: Bool) -> [(String, AppInfoBuilder.Node)] {
        let manifests: AppInfoBuilder.Node = newLayout
            ? .map([("public", .map([("gid", .str("8123456789012345678")), ("size", .str("1930336210"))]))])
            : .map([("public", .str("8123456789012345678"))])
        return [("appinfo", .map([
            ("appid", .int(3527290)),
            ("common", .map([("name", .str("PEAK")), ("oslist", .str("windows"))])),
            ("depots", .map([
                ("3527291", .map([("config", .map([("oslist", .str("windows"))])), ("manifests", manifests)])),
                ("branches", .map([("public", .map([("buildid", .str("25739797")), ("timeupdated", .str("1760000000"))]))])),
            ])),
        ]))]
    }

    func testAppInfoV41StringTable() throws {
        var b = AppInfoBuilder(.v41)
        let data = b.file(apps: [(440, [("appinfo", .map([("appid", .int(440))]))]), (3527290, peakEntry(newLayout: true))])
        let node = try AppInfoVDF.node(for: 3527290, in: data)
        let info = AppInfoVDF.buildInfo(from: node, depotId: 3527291)
        XCTAssertEqual(info, SteamBuildInfo(publicBuildId: "25739797", depotPublicManifest: "8123456789012345678"))
        XCTAssertEqual(node["appinfo"]?["common"]?["name"]?.text, "PEAK")
    }

    func testAppInfoV40InlineKeysOldManifestLayout() throws {
        var b = AppInfoBuilder(.v40)
        let data = b.file(apps: [(3527290, peakEntry(newLayout: false))])
        let info = AppInfoVDF.buildInfo(from: try AppInfoVDF.node(for: 3527290, in: data), depotId: 3527291)
        XCTAssertEqual(info.depotPublicManifest, "8123456789012345678")
        XCTAssertEqual(info.publicBuildId, "25739797")
    }

    func testAppInfoV39() throws {
        var b = AppInfoBuilder(.v39)
        let data = b.file(apps: [(3527290, peakEntry(newLayout: true))])
        XCTAssertEqual(AppInfoVDF.buildInfo(from: try AppInfoVDF.node(for: 3527290, in: data), depotId: 3527291).publicBuildId, "25739797")
    }

    func testAppInfoErrors() {
        var b = AppInfoBuilder(.v41)
        let data = b.file(apps: [(440, [("appinfo", .map([("appid", .int(440))]))])])
        XCTAssertThrowsError(try AppInfoVDF.node(for: 3527290, in: data)) { XCTAssertEqual($0 as? AppInfoError, .appNotFound) }
        XCTAssertThrowsError(try AppInfoVDF.node(for: 1, in: Data([1, 2, 3, 4, 5, 6, 7, 8]))) { e in
            guard case AppInfoError.badMagic = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try AppInfoVDF.node(for: 1, in: data.prefix(12)))
        XCTAssertNil(AppInfoVDF.buildInfo(fileAt: URL(fileURLWithPath: "/nonexistent/appinfo.vdf"), appId: 3527290, depotId: 3527291))
    }
}
