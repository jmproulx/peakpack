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

    public static bool Verify(byte[] manifestBytes, string signatureBase64, string publicKeyBase64)
    {
        try
        {
            using var ec = ECDsa.Create();
            ec.ImportSubjectPublicKeyInfo(Convert.FromBase64String(publicKeyBase64), out _);
            return ec.VerifyData(manifestBytes, Convert.FromBase64String(signatureBase64.Trim()), HashAlgorithmName.SHA256);
        }
        catch (FormatException) { return false; }
        catch (CryptographicException) { return false; }
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

    public static PackConfig Load(Stream? s) =>
        s is null ? new PackConfig() : JsonSerializer.Deserialize<PackConfig>(s, PackManifest.JsonOptions) ?? new PackConfig();
}
