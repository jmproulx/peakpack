import Foundation
@testable import PeakModdedCore
import XCTest

/// Pins, hashes, the signed manifest: everything the app trusts before it runs anything.
final class TrustTests: XCTestCase {
    func testKitLoadsAndPinsTheReleasedRuntime() throws {
        let kit = Fixture.kit
        XCTAssertEqual(kit.repo, "jmproulx/peakpack")
        XCTAssertEqual(kit.minMacOS, "14.0")
        XCTAssertTrue(kit.runtime.tag.hasPrefix("mac-build-runtime-"))
        XCTAssertEqual(kit.runtime.tag, "mac-build-runtime-\(kit.runtime.id)")
        XCTAssertEqual(kit.runtime.asset, "peakpack-runtime-\(kit.runtime.id)-x86_64.tar.xz")
        XCTAssertTrue(Hashing.isSHA256Hex(kit.runtime.sha256))
        XCTAssertEqual(kit.game.appId, 3527290)
        XCTAssertEqual(kit.game.depotId, 3527291)
        XCTAssertTrue(kit.pack.manifestUrl.hasSuffix("/releases/latest/download/manifest.json"))
    }

    /// The embedded pin must agree with the published release's SHA256SUMS (catches pin typos).
    func testKitPinMatchesPublishedSHA256SUMS() throws {
        let kit = Fixture.kit
        guard kit.runtime.id == "pp1-cx26.3.0" else { throw XCTSkip("fixture is for pp1; update Fixtures/runtime-pp1-SHA256SUMS.txt with the new pin") }
        let sums = ChecksumList(text: Fixture.text("runtime-pp1-SHA256SUMS", "txt"))
        XCTAssertEqual(try Integrity.expectedHash(asset: kit.runtime.asset, pinned: kit.runtime.sha256, sums: sums), kit.runtime.sha256)
    }

    func testAllowList() {
        let kit = Fixture.kit
        XCTAssertTrue(kit.isAllowed(URL(string: "https://github.com/jmproulx/peakpack/releases/download/x/y")!))
        XCTAssertTrue(kit.isAllowed(URL(string: "https://objects.githubusercontent.com/abc")!))
        XCTAssertTrue(kit.isAllowed(URL(string: "https://release-assets.githubusercontent.com/abc")!))
        XCTAssertTrue(kit.isAllowed(URL(string: "https://api.github.com/repos/x/y/releases")!))
        XCTAssertFalse(kit.isAllowed(URL(string: "http://github.com/x")!), "plain http")
        XCTAssertFalse(kit.isAllowed(URL(string: "https://evilgithub.com/x")!), "suffix must be on a label boundary")
        XCTAssertFalse(kit.isAllowed(URL(string: "https://github.com.evil.example/x")!))
        XCTAssertFalse(kit.isAllowed(URL(string: "https://example.org/x")!))
    }

    func testChecksumListParsesBothFormats() {
        let h1 = String(repeating: "a", count: 64), h2 = String(repeating: "B", count: 64)
        let l = ChecksumList(text: "\(h1)  one.tar.xz\r\n\(h2) *two.zip\n# comment\nnot a line\n\(h1.prefix(10))  short\n")
        XCTAssertEqual(l.hash(for: "one.tar.xz"), h1)
        XCTAssertEqual(l.hash(for: "two.zip"), h2.lowercased())
        XCTAssertNil(l.hash(for: "short"))
        XCTAssertEqual(l.entries.count, 2)
    }

    func testIntegrityRejectsPinMismatchAndUnlisted() {
        let a = String(repeating: "1", count: 64), b = String(repeating: "2", count: 64)
        let sums = ChecksumList(text: "\(a)  rt.tar.xz\n")
        XCTAssertThrowsError(try Integrity.expectedHash(asset: "rt.tar.xz", pinned: b, sums: sums)) { e in
            guard case IntegrityError.pinMismatch = e else { return XCTFail("\(e)") }
        }
        XCTAssertThrowsError(try Integrity.expectedHash(asset: "other", pinned: nil, sums: sums)) { e in
            XCTAssertEqual(e as? IntegrityError, .notListed("other"))
        }
        XCTAssertEqual(try Integrity.expectedHash(asset: "rt.tar.xz", pinned: nil, sums: sums), a)
    }

    func testFileHashStreamingMatchesInMemory() throws {
        let d = tempDir()
        var bytes = Data(count: 3 * (1 << 20) + 17)
        for i in 0..<bytes.count { bytes[i] = UInt8(truncatingIfNeeded: i &* 31) }
        let f = d.appendingPathComponent("blob")
        try bytes.write(to: f)
        XCTAssertEqual(try Hashing.sha256Hex(fileAt: f), Hashing.sha256Hex(of: bytes))
        XCTAssertEqual(Hashing.sha256Hex(of: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNoThrow(try Integrity.verify(file: f, name: "blob", expected: Hashing.sha256Hex(of: bytes)))
        XCTAssertThrowsError(try Integrity.verify(file: f, name: "blob", expected: String(repeating: "0", count: 64)))
    }

    // MARK: signed manifest (the real rev-5 release files)

    func testRealRev5ManifestSignatureVerifies() throws {
        let m = Fixture.data("rev5-manifest", "json")
        let sig = Fixture.text("rev5-manifest.json", "sig")
        XCTAssertTrue(ManifestSignature.verify(manifest: m, signatureBase64: sig, publicKeySPKIBase64: Fixture.kit.pack.publicKey))
        let parsed = try ManifestSignature.verifiedManifest(manifest: m, signatureBase64: sig, publicKey: Fixture.kit.pack.publicKey)
        XCTAssertEqual(parsed.revision, 5)
        XCTAssertEqual(parsed.gameAppId, 3527290)
        XCTAssertEqual(parsed.gameVersion, "2.6.b")
        XCTAssertEqual(parsed.platforms?.mac?.extraArgs, ["-force-d3d11"])
        XCTAssertEqual(parsed.app?.version, "0.4.2")
        XCTAssertTrue(parsed.app!.url.hasPrefix("https://github.com/jmproulx/peakpack/releases/download/rev-5/"))
        XCTAssertTrue(Hashing.isSHA256Hex(parsed.app!.sha256))
        XCTAssertNil(parsed.platforms?.mac?.runtime, "rev 5 has no runtime pin yet")
    }

    func testTamperedManifestFails() {
        var m = Fixture.data("rev5-manifest", "json")
        let sig = Fixture.text("rev5-manifest.json", "sig")
        let i = m.firstIndex(of: UInt8(ascii: "5"))!
        m[i] = UInt8(ascii: "6")
        XCTAssertFalse(ManifestSignature.verify(manifest: m, signatureBase64: sig, publicKeySPKIBase64: Fixture.kit.pack.publicKey))
        XCTAssertThrowsError(try ManifestSignature.verifiedManifest(manifest: m, signatureBase64: sig, publicKey: Fixture.kit.pack.publicKey)) {
            XCTAssertEqual($0 as? ManifestError, .badSignature)
        }
    }

    func testWrongKeyOrGarbageFails() {
        let m = Fixture.data("rev5-manifest", "json")
        let sig = Fixture.text("rev5-manifest.json", "sig")
        // A different, valid P-256 SPKI key.
        let other = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE" + String(Fixture.kit.pack.publicKey.suffix(88).reversed())
        XCTAssertFalse(ManifestSignature.verify(manifest: m, signatureBase64: sig, publicKeySPKIBase64: other))
        XCTAssertFalse(ManifestSignature.verify(manifest: m, signatureBase64: "not base64!", publicKeySPKIBase64: Fixture.kit.pack.publicKey))
        XCTAssertFalse(ManifestSignature.verify(manifest: m, signatureBase64: sig, publicKeySPKIBase64: "AAAA"))
    }

    // MARK: runtime pin resolution

    func testSignedRuntimePinOverridesEmbedded() throws {
        let json = """
        {"schema":1,"revision":6,"platforms":{"mac":{"extraArgs":["-force-d3d11"],"minFrontEnd":"0.2.0",
         "runtime":{"id":"pp2-cx26.3.0","tag":"mac-build-runtime-pp2-cx26.3.0","asset":"peakpack-runtime-pp2-cx26.3.0-x86_64.tar.xz",
                    "sha256":"\(String(repeating: "C", count: 64))","size":160000000}}}}
        """
        let m = try PackManifest.decode(Data(json.utf8))
        let eff = RuntimePinResolver.effective(embedded: Fixture.kit.runtime, signedManifest: m)
        XCTAssertEqual(eff.id, "pp2-cx26.3.0")
        XCTAssertEqual(eff.sha256, String(repeating: "c", count: 64))
        XCTAssertEqual(m.platforms?.mac?.minFrontEnd, "0.2.0")
    }

    func testMalformedOrMissingPinKeepsEmbedded() throws {
        let embedded = Fixture.kit.runtime
        XCTAssertEqual(RuntimePinResolver.effective(embedded: embedded, signedManifest: nil), embedded)
        let bad = """
        {"schema":1,"revision":6,"platforms":{"mac":{"runtime":{"id":"../../evil","tag":"rev-6","asset":"x/../y.tar.xz","sha256":"zz"}}}}
        """
        let m = try PackManifest.decode(Data(bad.utf8))
        XCTAssertEqual(RuntimePinResolver.effective(embedded: embedded, signedManifest: m), embedded)
    }
}
