using System.Numerics;
using System.Security.Cryptography;

namespace PeakPack.Core;

/// <summary>
/// Fully managed ECDSA P-256 / SHA-256 signature VERIFICATION (no signing, no private keys), used only under Wine.
/// Why: on Windows, .NET's ECDsa.Create() is CNG. Importing the key (NCryptImportKey) and verifying
/// (NCryptVerifySignature) go through ncrypt.dll, which Wine implements only partly. Under Wine 11 on macOS the
/// signature of a correct manifest failed to verify. This verifier needs nothing native except SHA-256 (the same
/// SHA256.HashData every file download already depends on).
///
/// Exactly as strict as the platform verifier for PeakPack's signatures (both are checked against the same vectors
/// in tools/SignatureTests):
///   key: SubjectPublicKeyInfo, id-ecPublicKey + prime256v1, uncompressed point; the point must lie on the curve
///        (stricter than the platform on encoding: the exact 91-byte DER, nothing before or after it);
///   signature: IEEE P1363 r||s, exactly 64 bytes (what .NET's SignData writes; DER is refused, as on Windows);
///   1 &lt;= r, s &lt; n; e = SHA-256(data); R = (e/s)G + (r/s)Q; valid iff R is not infinity and R.x mod n == r.
/// Timing doesn't matter: only public data is involved.
/// </summary>
public static class P256Verifier
{
    static BigInteger Hex(string h) => BigInteger.Parse("0" + h, System.Globalization.NumberStyles.HexNumber);

    // SEC 2 / FIPS 186-4 curve P-256 (secp256r1, prime256v1).
    public static readonly BigInteger P = Hex("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
    public static readonly BigInteger A = P - 3;
    public static readonly BigInteger B = Hex("5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b");
    public static readonly BigInteger N = Hex("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
    public static readonly Point G = new(Hex("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"),
                                         Hex("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"));

    /// <summary>DER prefix of a P-256 SubjectPublicKeyInfo: SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 },
    /// BIT STRING (0 unused bits) 04 || X || Y }.</summary>
    static readonly byte[] SpkiPrefix = Convert.FromHexString("3059301306072a8648ce3d020106082a8648ce3d030107034200");
    public const int SpkiLength = 91;

    public readonly record struct Point(BigInteger X, BigInteger Y, bool Infinity = false)
    {
        public static readonly Point AtInfinity = new(BigInteger.Zero, BigInteger.Zero, true);
    }

    static BigInteger Mod(BigInteger v, BigInteger m) { var r = v % m; return r.Sign < 0 ? r + m : r; }
    static BigInteger Inv(BigInteger v, BigInteger m) => BigInteger.ModPow(Mod(v, m), m - 2, m); // m prime, v != 0
    static BigInteger U(ReadOnlySpan<byte> bigEndian) => new(bigEndian, isUnsigned: true, isBigEndian: true);

    public static bool IsOnCurve(Point q) =>
        !q.Infinity && q.X.Sign >= 0 && q.X < P && q.Y.Sign >= 0 && q.Y < P
        && Mod(q.Y * q.Y, P) == Mod(q.X * q.X * q.X + A * q.X + B, P);

    public static Point Double(Point a)
    {
        if (a.Infinity || a.Y.IsZero) return Point.AtInfinity;
        var l = Mod((3 * a.X * a.X + A) * Inv(2 * a.Y, P), P);
        var x = Mod(l * l - 2 * a.X, P);
        return new Point(x, Mod(l * (a.X - x) - a.Y, P));
    }

    public static Point Add(Point a, Point b)
    {
        if (a.Infinity) return b;
        if (b.Infinity) return a;
        if (a.X == b.X) return Mod(a.Y + b.Y, P).IsZero ? Point.AtInfinity : Double(a);
        var l = Mod((b.Y - a.Y) * Inv(b.X - a.X, P), P);
        var x = Mod(l * l - a.X - b.X, P);
        return new Point(x, Mod(l * (a.X - x) - a.Y, P));
    }

    /// <summary>u1*G + u2*Q (Shamir's trick).</summary>
    public static Point MulAdd(BigInteger u1, BigInteger u2, Point q)
    {
        var gq = Add(G, q);
        var r = Point.AtInfinity;
        int bits = (int)Math.Max(u1.GetBitLength(), u2.GetBitLength());
        for (int i = bits - 1; i >= 0; i--)
        {
            r = Double(r);
            bool b1 = !(u1 >> i).IsEven, b2 = !(u2 >> i).IsEven;
            if (b1 && b2) r = Add(r, gq);
            else if (b1) r = Add(r, G);
            else if (b2) r = Add(r, q);
        }
        return r;
    }

    /// <summary>The public point from a P-256 SubjectPublicKeyInfo, or null (with the reason) if it isn't one.</summary>
    public static Point? ParseSpki(ReadOnlySpan<byte> spki, out string? why)
    {
        why = null;
        if (spki.Length != SpkiLength || !spki[..SpkiPrefix.Length].SequenceEqual(SpkiPrefix) || spki[SpkiPrefix.Length] != 0x04)
        { why = "public key isn't a P-256 SubjectPublicKeyInfo with an uncompressed point"; return null; }
        var q = new Point(U(spki.Slice(27, 32)), U(spki.Slice(59, 32)));
        if (!IsOnCurve(q)) { why = "public key point isn't on P-256"; return null; }
        return q;
    }

    /// <summary>Verifies a P1363 (r||s) signature over a SHA-256 digest.</summary>
    public static bool VerifyHash(ReadOnlySpan<byte> sha256, ReadOnlySpan<byte> signature, Point q, out string? why)
    {
        why = null;
        if (sha256.Length != 32) { why = "digest isn't 32 bytes"; return false; }
        if (signature.Length != 64) { why = $"signature is {signature.Length} bytes, not 64 (r||s)"; return false; }
        var r = U(signature[..32]);
        var s = U(signature[32..]);
        if (r.IsZero || r >= N || s.IsZero || s >= N) { why = "r or s out of range"; return false; }
        var e = U(sha256); // 256-bit digest, 256-bit order: no truncation
        var w = Inv(s, N);
        var pt = MulAdd(Mod(e * w, N), Mod(r * w, N), q);
        if (pt.Infinity) { why = "R is the point at infinity"; return false; }
        if (Mod(pt.X, N) != r) { why = "signature doesn't match"; return false; }
        return true;
    }

    /// <summary>Same contract as the platform path: SHA-256 of the data, P1363 signature, SPKI public key.</summary>
    public static bool VerifyData(ReadOnlySpan<byte> data, ReadOnlySpan<byte> signature, ReadOnlySpan<byte> spki, out string? why)
    {
        if (ParseSpki(spki, out why) is not { } q) return false;
        return VerifyHash(SHA256.HashData(data), signature, q, out why);
    }
}
