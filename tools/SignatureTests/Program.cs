// Signature verifier tests: the managed P-256 verifier (used under Wine) and the platform verifier (CNG, used on
// Windows) must agree on every vector, and both must accept exactly what PeakPack's signer produces.
//
//   dotnet run --project tools/SignatureTests                 # all checks; exit code = failures
//   dotnet run --project tools/SignatureTests -- --random 2000 # more random keys/messages (default 200)
//
// Vectors: RFC 6979 A.2.5 (P-256, SHA-256) known answers; curve arithmetic sanity (the RFC key's public point from its
// private scalar); edge cases (r/s = 0, n, out of range, high-S, wrong lengths, DER, off-curve/compressed keys);
// random keys + messages signed by .NET with bit-flip, wrong-message and wrong-key variants; the real rev-5
// manifest.json + .sig (fixtures/rev-5, byte-identical to the GitHub release assets) with the real public key from
// src/PeakPack.App/pack.config.json, plus tampered manifests and signatures; ManifestSigner.Verify on the Windows path
// and, in a child process with PEAKPACK_FAKE_PLATFORM=wine-mac, on the managed path.
using System.Diagnostics;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using PeakPack.Core;

internal static class Program
{
    static int _fail, _pass;
    static void Check(bool cond, string name)
    {
        if (cond) { _pass++; Console.WriteLine("  PASS  " + name); }
        else { _fail++; Console.WriteLine("  FAIL  " + name); }
    }

    /// <summary>Platform verdict exactly as ManifestSigner maps it: a CryptographicException (or CNG's
    /// PlatformNotSupportedException for a key it can't import) means "not valid".</summary>
    static bool Platform(byte[] data, byte[] sig, byte[] spki)
    {
        try { return ManifestSigner.VerifyPlatform(data, sig, spki); }
        catch (Exception ex) when (ex is CryptographicException or PlatformNotSupportedException) { return false; }
    }
    static bool Managed(byte[] data, byte[] sig, byte[] spki) => P256Verifier.VerifyData(data, sig, spki, out _);

    /// <summary>Both verifiers must give <paramref name="expected"/>.</summary>
    static void Both(byte[] data, byte[] sig, byte[] spki, bool expected, string name)
    {
        bool p = Platform(data, sig, spki), m = Managed(data, sig, spki);
        Check(p == expected && m == expected, $"{name}: platform {V(p)}, managed {V(m)} (expected {V(expected)})");
    }
    static string V(bool b) => b ? "valid" : "invalid";
    static int _agreeFail, _agreeTotal;
    static void Agree(byte[] data, byte[] sig, byte[] spki, bool expected)
    {
        _agreeTotal++;
        bool p = Platform(data, sig, spki), m = Managed(data, sig, spki);
        if (p != expected || m != expected) { _agreeFail++; if (_agreeFail <= 5) Console.WriteLine($"    disagreement: platform {V(p)} managed {V(m)} expected {V(expected)} sig {Convert.ToHexString(sig)}"); }
    }

    static byte[] H(string hex) => Convert.FromHexString(hex);
    static byte[] Spki(byte[] x, byte[] y) => [.. H("3059301306072a8648ce3d020106082a8648ce3d030107034200"), 0x04, .. x, .. y];
    static byte[] Be32(BigInteger v) { var b = v.ToByteArray(isUnsigned: true, isBigEndian: true); return b.Length == 32 ? b : [.. new byte[32 - b.Length], .. b]; }
    static byte[] Flip(byte[] a, int bit) { var c = (byte[])a.Clone(); c[bit / 8 % c.Length] ^= (byte)(1 << (bit % 8)); return c; }

    static string Root()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "FriendInstaller.sln"))) return d.FullName;
        throw new DirectoryNotFoundException("repo root");
    }

    static bool NcryptLoaded() => Process.GetCurrentProcess().Modules.Cast<ProcessModule>().Any(m => m.ModuleName.Equals("ncrypt.dll", StringComparison.OrdinalIgnoreCase));

    static int Main(string[] args)
    {
        var root = Root();
        var fx = Path.Combine(root, "tools", "SignatureTests", "fixtures", "rev-5");
        var manifest = File.ReadAllBytes(Path.Combine(fx, "manifest.json"));
        var sigText = File.ReadAllText(Path.Combine(fx, "manifest.json.sig"));
        var pubText = JsonDocument.Parse(File.ReadAllText(Path.Combine(root, "src", "PeakPack.App", "pack.config.json"))).RootElement.GetProperty("publicKey").GetString()!;
        var realKey = Convert.FromBase64String(pubText);
        var realSig = Convert.FromBase64String(sigText.Trim());

        if (args.Contains("--child-wine")) return ChildWine(manifest, sigText, pubText);

        Console.WriteLine("== which native path the platform verifier takes (Windows)");
        bool before = NcryptLoaded();
        using (var probe = ECDsa.Create()) Console.WriteLine($"  ECDsa.Create() = {probe.GetType().FullName}");
        bool mOk = Managed(manifest, realSig, realKey);
        bool afterManaged = NcryptLoaded();
        bool pOk = Platform(manifest, realSig, realKey);
        bool afterPlatform = NcryptLoaded();
        Console.WriteLine($"  ncrypt.dll loaded: at start {before}, after managed verify {afterManaged}, after platform verify {afterPlatform}");
        Check(!before && !afterManaged && afterPlatform, "the platform verifier loads ncrypt.dll (CNG key storage: NCryptImportKey/NCryptVerifySignature); the managed one doesn't");
        Check(mOk && pOk, "real rev-5 manifest + signature + Joshua's public key: valid on both");

        Console.WriteLine("== curve arithmetic");
        var G = P256Verifier.G;
        using (var e = ECDsa.Create(ECCurve.NamedCurves.nistP256))
        {
            var c = e.ExportExplicitParameters(false).Curve;
            BigInteger B(byte[]? b) => new(b, isUnsigned: true, isBigEndian: true);
            Check(B(c.Prime) == P256Verifier.P && B(c.A) == P256Verifier.A && B(c.B) == P256Verifier.B && B(c.Order) == P256Verifier.N
                  && B(c.G.X) == G.X && B(c.G.Y) == G.Y, "managed curve constants = CNG's explicit nistP256 parameters");
        }
        Check(P256Verifier.IsOnCurve(G), "G is on the curve");
        Check(P256Verifier.MulAdd(P256Verifier.N, 0, G).Infinity, "n*G = infinity");
        var nm1 = P256Verifier.MulAdd(P256Verifier.N - 1, 0, G);
        Check(nm1.X == G.X && nm1.Y == P256Verifier.P - G.Y, "(n-1)*G = -G");
        Check(P256Verifier.Add(G, G) == P256Verifier.Double(G), "G+G = 2G");
        Check(P256Verifier.Add(G, new P256Verifier.Point(G.X, P256Verifier.P - G.Y)).Infinity, "G + (-G) = infinity");
        var two = P256Verifier.Double(G);
        Check(P256Verifier.Add(two, G) == P256Verifier.MulAdd(3, 0, G) && P256Verifier.IsOnCurve(two), "2G+G = 3G, on the curve");

        Console.WriteLine("== RFC 6979 A.2.5 known answers (P-256, SHA-256)");
        var rx = BigInteger.Parse("0C9AFA9D845BA75166B5C215767B1D6934E50C3DB36E89B127B8A622B120F6721", System.Globalization.NumberStyles.HexNumber);
        var ux = H("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6");
        var uy = H("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299");
        var U = P256Verifier.MulAdd(rx, 0, G);
        Check(Be32(U.X).SequenceEqual(ux) && Be32(U.Y).SequenceEqual(uy), "managed scalar multiply: private key x -> the RFC's public point (Ux, Uy)");
        var rfcKey = Spki(ux, uy);
        var sample = Encoding.ASCII.GetBytes("sample");
        var test = Encoding.ASCII.GetBytes("test");
        var sigSample = H("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716" + "F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8");
        var sigTest = H("F1ABB023518351CD71D881567B1EA663ED3EFCF6C5132B354F28D3B0B7D38367" + "019F4113742A2B14BD25926B49C649155F267E60D3814B4C0CC84250E46F0083");
        Both(sample, sigSample, rfcKey, true, "\"sample\"");
        Both(test, sigTest, rfcKey, true, "\"test\"");
        Both(test, sigSample, rfcKey, false, "\"test\" with the \"sample\" signature");
        Both(sample, sigTest, rfcKey, false, "\"sample\" with the \"test\" signature");

        Console.WriteLine("== edge cases (invalid unless noted)");
        var n = P256Verifier.N;
        byte[] R(byte[] s) => s[..32]; byte[] S(byte[] s) => s[32..];
        Both(sample, [.. R(sigSample), .. Be32(n - new BigInteger(S(sigSample), true, true))], rfcKey, true, "high-S twin (r, n-s): valid on both (plain ECDSA)");
        Both(sample, [.. new byte[32], .. S(sigSample)], rfcKey, false, "r = 0");
        Both(sample, [.. R(sigSample), .. new byte[32]], rfcKey, false, "s = 0");
        Both(sample, [.. Be32(n), .. S(sigSample)], rfcKey, false, "r = n");
        Both(sample, [.. R(sigSample), .. Be32(n)], rfcKey, false, "s = n");
        Both(sample, [.. Be32(n + new BigInteger(R(sigSample), true, true) - n), .. Be32(n + 1)], rfcKey, false, "s = n+1");
        Both(sample, [.. Enumerable.Repeat((byte)0xff, 32), .. S(sigSample)], rfcKey, false, "r = 2^256-1");
        Both(sample, [.. S(sigSample), .. R(sigSample)], rfcKey, false, "r and s swapped");
        Both(sample, sigSample[..63], rfcKey, false, "63-byte signature");
        Both(sample, [.. sigSample, 0], rfcKey, false, "65-byte signature");
        Both(sample, [], rfcKey, false, "empty signature");
        Both(sample, Der(sigSample), rfcKey, false, "the valid signature DER-encoded (PeakPack signs P1363)");
        var yPlus1 = Be32((new BigInteger(uy, true, true) + 1) % P256Verifier.P);
        Both(sample, sigSample, Spki(ux, yPlus1), false, "public key point not on the curve");
        Both(sample, sigSample, [.. H("3039301306072a8648ce3d020106082a8648ce3d030107032200"), 0x03, .. ux], false, "compressed public key");
        Both(sample, sigSample, [.. Spki(ux, uy), 0x00], false, "public key with a trailing byte (both: the key must be exactly the SPKI)");
        Both(sample, sigSample, Spki(new byte[32], new byte[32]), false, "public key (0,0)");
        using (var p384 = ECDsa.Create(ECCurve.NamedCurves.nistP384))
        {
            var s384 = p384.SignData(sample, HashAlgorithmName.SHA256);
            Check(!Managed(sample, s384, p384.ExportSubjectPublicKeyInfo()), "managed refuses a P-384 key (PeakPack's key is P-256; the platform would accept it)");
        }

        int iterations = args.SkipWhile(a => a != "--random").Skip(1).Select(int.Parse).FirstOrDefault(200);
        Console.WriteLine($"== random: {iterations} keys/messages signed by .NET, plus tampered variants");
        var rng = new Random(20261014);
        var sw = Stopwatch.StartNew();
        using var other = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var otherKey = other.ExportSubjectPublicKeyInfo();
        for (int i = 0; i < iterations; i++)
        {
            using var k = ECDsa.Create(ECCurve.NamedCurves.nistP256);
            var key = k.ExportSubjectPublicKeyInfo();
            var msg = new byte[rng.Next(0, 400)]; rng.NextBytes(msg);
            var sig = k.SignData(msg, HashAlgorithmName.SHA256);
            Agree(msg, sig, key, true);
            Agree(msg, Flip(sig, rng.Next(512)), key, false);
            if (msg.Length > 0) Agree(Flip(msg, rng.Next(msg.Length * 8)), sig, key, false);
            Agree([.. msg, 0x0a], sig, key, false);
            Agree(msg, sig, otherKey, false);
        }
        Check(_agreeFail == 0, $"{_agreeTotal} random vectors: both verifiers agree with the expected result ({_agreeFail} disagreements, {sw.Elapsed.TotalSeconds:F1} s)");

        Console.WriteLine("== the real rev-5 manifest, tampered");
        Both(manifest, realSig, realKey, true, "rev-5 manifest.json + .sig");
        Both(Flip(manifest, manifest.Length * 4), realSig, realKey, false, "one bit flipped in the middle of manifest.json");
        Both([.. manifest, 0x0a], realSig, realKey, false, "a newline appended to manifest.json");
        Both(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(manifest).Replace("\n", "\r\n")), realSig, realKey, false, "manifest.json with CRLF line endings");
        Both(Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(manifest).Replace("\"revision\": 5", "\"revision\": 6")), realSig, realKey, false, "revision changed to 6");
        Both(manifest, Flip(realSig, 3), realKey, false, "one bit flipped in r");
        Both(manifest, Flip(realSig, 300), realKey, false, "one bit flipped in s");
        Both(manifest, [.. R(realSig), .. Be32(n - new BigInteger(S(realSig), true, true))], realKey, true, "rev-5 high-S twin (still valid ECDSA on both)");
        Both(manifest, realSig, otherKey, false, "another P-256 key");
        Both(manifest, sigSample, realKey, false, "an unrelated valid signature");

        Console.WriteLine("== ManifestSigner.Verify, Windows path");
        Check(!ManifestSigner.UsesManagedVerifier, "on Windows the platform verifier is used (unchanged for Windows friends)");
        var diag = new List<string>();
        Check(ManifestSigner.Verify(manifest, sigText, pubText, diag.Add) && diag.Count == 0, "rev-5 verifies, nothing logged");
        Check(!ManifestSigner.Verify([.. manifest, 0x20], sigText, pubText, diag.Add), "tampered: invalid");
        Check(!ManifestSigner.Verify(manifest, "not base64!", pubText, diag.Add) && diag.Any(d => d.Contains("not base64")), "bad base64: invalid, logged");
        diag.Clear();
        Check(!ManifestSigner.Verify(manifest, sigText, Convert.ToBase64String(Spki(ux, yPlus1)), diag.Add) && diag.Any(d => d.Contains("CryptographicException") || d.Contains("PlatformNotSupportedException")),
            $"platform exception -> invalid, and its type/message is logged ({diag.FirstOrDefault()})");

        Console.WriteLine("== ManifestSigner.Verify, Wine path (child process, PEAKPACK_FAKE_PLATFORM=wine-mac)");
        var psi = new ProcessStartInfo(Environment.ProcessPath!, "--child-wine") { RedirectStandardOutput = true, UseShellExecute = false };
        psi.Environment["PEAKPACK_FAKE_PLATFORM"] = "wine-mac";
        using (var child = Process.Start(psi)!)
        {
            var output = child.StandardOutput.ReadToEnd();
            child.WaitForExit();
            Console.Write(output);
            Check(child.ExitCode == 0, $"child: all Wine-path checks passed (exit {child.ExitCode})");
        }

        Console.WriteLine(_fail == 0 ? $"ALL {_pass} SIGNATURE CHECKS PASSED" : $"{_fail} SIGNATURE CHECK(S) FAILED ({_pass} passed)");
        return _fail;
    }

    static int ChildWine(byte[] manifest, string sigText, string pubText)
    {
        Check(ManifestSigner.UsesManagedVerifier, "child: under (simulated) Wine the managed verifier is used");
        var sw = Stopwatch.StartNew();
        bool ok = P256Verifier.VerifyData(manifest, Convert.FromBase64String(sigText.Trim()), Convert.FromBase64String(pubText), out _);
        Check(ok && !NcryptLoaded(), $"child: rev-5 valid via the managed verifier without loading ncrypt.dll ({sw.ElapsedMilliseconds} ms)");
        var diag = new List<string>();
        Check(ManifestSigner.Verify(manifest, sigText, pubText, diag.Add), "child: ManifestSigner.Verify(rev-5) = valid");
        Check(diag.Any(d => d.Contains("managed P-256 valid") && d.Contains("platform verifier says: valid")), $"child: debug line records both verdicts ({diag.LastOrDefault()})");
        diag.Clear();
        Check(!ManifestSigner.Verify([.. manifest, 0x0a], sigText, pubText, diag.Add), "child: tampered manifest = invalid");
        Check(diag.Any(d => d.Contains("signature doesn't match")), $"child: and the reason is logged ({diag.FirstOrDefault()})");
        return _fail;
    }

    /// <summary>P1363 r||s -> DER SEQUENCE { INTEGER r, INTEGER s }.</summary>
    static byte[] Der(byte[] p1363)
    {
        var w = new System.Formats.Asn1.AsnWriter(System.Formats.Asn1.AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteInteger(new BigInteger(p1363[..32], true, true));
            w.WriteInteger(new BigInteger(p1363[32..], true, true));
        }
        return w.Encode();
    }
}
