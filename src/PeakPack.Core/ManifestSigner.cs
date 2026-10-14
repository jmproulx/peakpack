using System.Security.Cryptography;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// Optional manifest signing (ECDSA P-256 / SHA-256, built into .NET - no extra packages).
/// Joshua keeps the private key on his PC; the public key is baked into the friend app.
/// If someone got into the GitHub account or swapped the hosted manifest, friends' apps would refuse
/// it, because file hashes are only as trustworthy as the manifest that lists them.
/// </summary>
public static class ManifestSigner
{
    public static (string PrivatePem, string PublicKeyBase64) GenerateKeyPair()
    {
        using var ec = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        return (ec.ExportPkcs8PrivateKeyPem(), Convert.ToBase64String(ec.ExportSubjectPublicKeyInfo()));
    }

    public static string Sign(byte[] manifestBytes, string privatePem)
    {
        using var ec = ECDsa.Create();
        ec.ImportFromPem(privatePem);
        return Convert.ToBase64String(ec.SignData(manifestBytes, HashAlgorithmName.SHA256));
    }

    /// <summary>Which verifier <see cref="Verify"/> uses: the platform's (CNG) on Windows, the managed P-256 verifier
    /// under Wine (real or simulated), whose ncrypt.dll can't be relied on. Both are equally strict (tools/SignatureTests).</summary>
    public static bool UsesManagedVerifier => Platform.IsWine;

    /// <summary>True only if the signature is valid. <paramref name="diag"/> gets one debug line on failure (why, and
    /// for a crypto exception its type and message), so a failure under Wine is never ambiguous in log.txt.</summary>
    public static bool Verify(byte[] manifestBytes, string signatureBase64, string publicKeyBase64, Action<string>? diag = null)
    {
        byte[] sig, key;
        try
        {
            sig = Convert.FromBase64String(signatureBase64.Trim());
            key = Convert.FromBase64String(publicKeyBase64);
        }
        catch (FormatException ex) { diag?.Invoke("signature check: not base64: " + ex.Message); return false; }

        if (UsesManagedVerifier)
        {
            bool ok = P256Verifier.VerifyData(manifestBytes, sig, key, out var why);
            if (!ok) diag?.Invoke($"signature check (managed P-256, {Platform.Describe}): invalid: {why}");
            // Diagnostics only (never decides): what the platform verifier says here, to keep track of Wine's CNG.
            diag?.Invoke("signature check: managed P-256 " + (ok ? "valid" : "INVALID") + "; platform verifier says: " + PlatformVerdict(manifestBytes, sig, key));
            return ok;
        }
        try { return VerifyPlatform(manifestBytes, sig, key); }
        // CNG reports a key it can't import as PlatformNotSupportedException (wrapping a CryptographicException):
        // that is "not verified" too, never a pass.
        catch (Exception ex) when (ex is CryptographicException or PlatformNotSupportedException)
        {
            diag?.Invoke($"signature check (platform): {ex.GetType().FullName} 0x{ex.HResult:X8}: {ex.Message}" +
                         (ex.InnerException is { } inner ? $" <- {inner.GetType().FullName} 0x{inner.HResult:X8}: {inner.Message}" : ""));
            return false;
        }
    }

    /// <summary>.NET's ECDsa (CNG on Windows): ImportSubjectPublicKeyInfo + VerifyData(SHA-256, IEEE P1363).
    /// Native path on Windows (seen in a stack trace): ECDsaCng.ImportParameters -> CngKey.Import -> NCryptImportKey,
    /// then VerifyData -> SHA-256 via BCrypt + NCryptVerifySignature (ncrypt.dll).</summary>
    public static bool VerifyPlatform(byte[] data, byte[] signature, byte[] spki)
    {
        using var ec = ECDsa.Create();
        ec.ImportSubjectPublicKeyInfo(spki, out int read);
        if (read != spki.Length) return false; // the whole key must be the SPKI, as in the managed verifier
        return ec.VerifyData(data, signature, HashAlgorithmName.SHA256);
    }

    static string PlatformVerdict(byte[] data, byte[] signature, byte[] spki)
    {
        try { return VerifyPlatform(data, signature, spki) ? "valid" : "invalid (VerifyData returned false)"; }
        catch (Exception ex)
        {
            return $"threw {ex.GetType().FullName} 0x{ex.HResult:X8}: {ex.Message}" +
                   (ex.InnerException is { } inner ? $" <- {inner.GetType().FullName} 0x{inner.HResult:X8}: {inner.Message}" : "");
        }
    }
}

/// <summary>
/// Baked into the friend app at build time (embedded resource pack.config.json), so friends never
/// type a URL or pick a setting. Joshua edits it once, builds, and shares the exe.
/// </summary>
public sealed class PackConfig
{
    public string PackName { get; set; } = "Joshua's PEAK mods";
    public string HostName { get; set; } = "Joshua";
    /// <summary>Where the manifest lives. A GitHub "latest release" URL is ideal:
    /// https://github.com/&lt;user&gt;/&lt;repo&gt;/releases/latest/download/manifest.json</summary>
    public string ManifestUrl { get; set; } = "";
    /// <summary>Base64 SubjectPublicKeyInfo. When set, manifest.json.sig must verify.</summary>
    public string? PublicKey { get; set; }
    public string ShortcutName { get; set; } = "PEAK (Modded)";
    /// <summary>Also put a "PeakPack" icon (the app window) on the desktop. Off by default: one icon keeps it obvious;
    /// the app window is in the Start Menu.</summary>
    public bool DesktopAppShortcut { get; set; }

    public static PackConfig Load(Stream? s) =>
        s is null ? new PackConfig() : JsonSerializer.Deserialize<PackConfig>(s, PackManifest.JsonOptions) ?? new PackConfig();
}
