using System.Net;
using System.Security.Cryptography;

namespace PeakPack.Core;

/// <summary>
/// Downloads files over HTTPS from an allowlist of hosts, verifies SHA-256, and caches by hash.
/// Every byte that ends up in the profile has been hash-checked against the manifest first.
/// </summary>
public sealed class Downloader : IDisposable
{
    /// <summary>Hosts the app will ever download from. Thunderstore (+ its CDN) and GitHub (where
    /// Joshua hosts the manifest, his own DLLs and app updates). Add a host here only deliberately.</summary>
    public static readonly string[] DefaultAllowedHosts =
    [
        // thunderstore.io/package/download/... 302-redirects to ccdn.thunderstore.io/live/repository/packages/...
        "thunderstore.io", "ccdn.thunderstore.io", "gcdn.thunderstore.io", "cdn.thunderstore.io",
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "raw.githubusercontent.com", "gist.githubusercontent.com",
    ];

    readonly HttpClient _http;
    readonly HashSet<string> _allowedHosts;
    readonly string _cacheDir;

    /// <summary>Allow file:// and plain local paths (sandbox testing / publisher). Off for friends by default.</summary>
    public bool AllowLocalFiles { get; init; }

    public Downloader(string cacheDir, IEnumerable<string>? extraAllowedHosts = null)
    {
        _cacheDir = cacheDir;
        Directory.CreateDirectory(cacheDir);
        _allowedHosts = new HashSet<string>(DefaultAllowedHosts.Concat(extraAllowedHosts ?? []), StringComparer.OrdinalIgnoreCase);
        // We follow redirects ourselves so every hop is checked against the allowlist.
        var handler = new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.All };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(5) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("PeakPack/" + typeof(Downloader).Assembly.GetName().Version?.ToString(3));
    }

    public static string Sha256OfFile(string path)
    {
        using var fs = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(fs));
    }

    public static string Sha256OfBytes(ReadOnlySpan<byte> data) => Convert.ToHexStringLower(SHA256.HashData(data));

    /// <summary>Resolve a manifest-relative URL ("files/HeliPilot.dll") against the manifest location.</summary>
    public static string ResolveRelative(string baseLocation, string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var abs) && (abs.Scheme is "https" or "http" or "file"))
            return abs.Scheme == "file" ? abs.LocalPath : url;
        if (Path.IsPathRooted(url)) return url;
        if (Uri.TryCreate(baseLocation, UriKind.Absolute, out var b) && b.Scheme is "https" or "http")
            return new Uri(b, url).ToString();
        // local manifest: relative to its directory
        var dir = Path.GetDirectoryName(Path.GetFullPath(baseLocation)) ?? ".";
        return Path.GetFullPath(Path.Combine(dir, url));
    }

    void CheckUrl(Uri u)
    {
        if (u.Scheme != Uri.UriSchemeHttps)
            throw new SecurityException($"Refusing non-HTTPS download: {u}");
        if (!_allowedHosts.Contains(u.Host))
            throw new SecurityException($"Refusing download from a host that isn't on the allowlist: {u.Host}");
    }

    bool IsLocal(string location, out string localPath)
    {
        localPath = location;
        if (Uri.TryCreate(location, UriKind.Absolute, out var u))
        {
            if (u.Scheme == "file") { localPath = u.LocalPath; return true; }
            return false;
        }
        return true; // plain path
    }

    /// <summary>Fetch small text (the manifest). No hash is known yet; trust comes from HTTPS+allowlist
    /// and, if configured, the manifest signature checked by the caller.</summary>
    public async Task<byte[]> GetSmallAsync(string location, CancellationToken ct = default, int maxBytes = 2 * 1024 * 1024)
    {
        byte[] data;
        if (IsLocal(location, out var lp))
        {
            if (!AllowLocalFiles) throw new SecurityException("Local manifests are only allowed in test mode.");
            data = await File.ReadAllBytesAsync(lp, ct);
        }
        else
        {
            using var resp = await SendFollowingRedirectsAsync(new Uri(location), ct);
            if (resp.Content.Headers.ContentLength > maxBytes) throw new InvalidDataException($"{location} is unexpectedly large.");
            data = await resp.Content.ReadAsByteArrayAsync(ct);
        }
        if (data.Length > maxBytes) throw new InvalidDataException($"{location} is unexpectedly large.");
        return data;
    }

    async Task<HttpResponseMessage> SendFollowingRedirectsAsync(Uri uri, CancellationToken ct)
    {
        for (int hop = 0; hop < 8; hop++)
        {
            CheckUrl(uri);
            var resp = await _http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, ct);
            if ((int)resp.StatusCode is >= 300 and < 400 && resp.Headers.Location is { } loc)
            {
                uri = loc.IsAbsoluteUri ? loc : new Uri(uri, loc);
                resp.Dispose();
                continue;
            }
            if (!resp.IsSuccessStatusCode)
            {
                var code = (int)resp.StatusCode;
                resp.Dispose();
                throw new HttpRequestException($"Download failed ({code}) for {uri}");
            }
            return resp;
        }
        throw new HttpRequestException($"Too many redirects for {uri}");
    }

    public string CachePathFor(string sha256) => Path.Combine(_cacheDir, sha256.ToLowerInvariant() + ".bin");

    /// <summary>
    /// Returns a local path to a file whose SHA-256 equals <paramref name="expectedSha256"/>, downloading it
    /// if not already cached. Throws if the content doesn't match. Pass null to compute (publisher only).
    /// </summary>
    public async Task<(string Path, string Sha256, long Size)> GetVerifiedAsync(
        string location, string? expectedSha256, IProgress<long>? bytesProgress = null, CancellationToken ct = default)
    {
        if (expectedSha256 is not null)
        {
            var cached = CachePathFor(expectedSha256);
            if (File.Exists(cached) && Sha256OfFile(cached) == expectedSha256.ToLowerInvariant())
                return (cached, expectedSha256.ToLowerInvariant(), new FileInfo(cached).Length);
        }

        var tmp = Path.Combine(_cacheDir, Guid.NewGuid().ToString("N") + ".part");
        try
        {
            if (IsLocal(location, out var lp))
            {
                if (!AllowLocalFiles) throw new SecurityException($"Local file sources are only allowed in test/publisher mode: {location}");
                File.Copy(lp, tmp, overwrite: true);
            }
            else
            {
                using var resp = await SendFollowingRedirectsAsync(new Uri(location), ct);
                await using var src = await resp.Content.ReadAsStreamAsync(ct);
                await using var dst = File.Create(tmp);
                var buf = new byte[81920];
                long total = 0; int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    total += n;
                    bytesProgress?.Report(total);
                }
            }

            var actual = Sha256OfFile(tmp);
            if (expectedSha256 is not null && actual != expectedSha256.ToLowerInvariant())
                throw new SecurityException($"Hash mismatch for {location}\n expected {expectedSha256}\n got      {actual}\nThe file was not installed.");
            var final = CachePathFor(actual);
            File.Move(tmp, final, overwrite: true);
            return (final, actual, new FileInfo(final).Length);
        }
        finally
        {
            if (File.Exists(tmp)) File.Delete(tmp);
        }
    }

    public void Dispose() => _http.Dispose();
}

public sealed class SecurityException(string message) : Exception(message);
