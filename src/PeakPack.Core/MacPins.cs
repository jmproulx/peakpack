using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// Publisher side of the optional signed pins (mac/app/proposals/friendinstaller-platforms-mac.md):
///   platforms.mac.runtime  from a mac-build-runtime-* prerelease's SHA256SUMS (+ the asset size from the release),
///   platforms.mac.frontEnd from a mac-build-app-* prerelease's SHA256SUMS,
///   gameDepot              from the host's own steamapps/appmanifest_&lt;appid&gt;.acf (read-only; omitted if unreadable).
/// Any problem with a configured runtime/frontEnd tag throws: the publisher refuses rather than sign a wrong pin.
/// </summary>
public sealed class MacPins(Func<string, CancellationToken, Task<byte[]>> fetch, Action<string> log)
{
    /// <summary>Fetches over HTTPS through a Downloader that, on top of the normal allowlist, may call api.github.com
    /// (publisher only; the friend app's allowlist is unchanged).</summary>
    public static Func<string, CancellationToken, Task<byte[]>> GitHubFetch(Downloader dl) =>
        (url, ct) => dl.GetSmallAsync(url, ct, 4 * 1024 * 1024);

    public static Downloader CreateGitHubDownloader() =>
        new(Path.Combine(Path.GetTempPath(), "peakpack-publisher-pins"), ["api.github.com"]);

    public sealed record ReleaseAsset(string Name, long Size);
    public sealed record ReleaseInfo(string Tag, bool Prerelease, bool Draft, IReadOnlyList<ReleaseAsset> Assets);

    public async Task<ReleaseInfo> GetReleaseAsync(string repo, string tag, CancellationToken ct)
    {
        byte[] bytes;
        try { bytes = await fetch($"https://api.github.com/repos/{repo}/releases/tags/{Uri.EscapeDataString(tag)}", ct); }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException)
        { throw new InvalidDataException($"Couldn't read release {tag} of {repo}: {ex.Message}"); }
        try
        {
            using var doc = JsonDocument.Parse(bytes);
            var r = doc.RootElement;
            var assets = new List<ReleaseAsset>();
            if (r.TryGetProperty("assets", out var arr) && arr.ValueKind == JsonValueKind.Array)
                foreach (var a in arr.EnumerateArray())
                    assets.Add(new ReleaseAsset(a.GetProperty("name").GetString() ?? "", a.TryGetProperty("size", out var s) ? s.GetInt64() : 0));
            return new ReleaseInfo(r.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "",
                r.TryGetProperty("prerelease", out var pr) && pr.GetBoolean(), r.TryGetProperty("draft", out var d) && d.GetBoolean(), assets);
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        { throw new InvalidDataException($"Release {tag} of {repo}: unexpected answer from GitHub ({ex.Message})."); }
    }

    /// <summary>Parses "sha256sum"/"shasum -a 256" output: "&lt;64 hex&gt;  name" or "&lt;64 hex&gt; *name".</summary>
    public static Dictionary<string, string> ParseSha256Sums(string text)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            if (line.Length < 66 || !PackManifest.IsSha256(line[..64]) || line[64] != ' ') continue;
            var name = line[65..].TrimStart(' ');
            if (name.StartsWith('*')) name = name[1..];
            if (name.StartsWith("./", StringComparison.Ordinal)) name = name[2..];
            if (name.Length > 0) map[name] = line[..64].ToLowerInvariant();
        }
        return map;
    }

    async Task<(ReleaseInfo Release, Dictionary<string, string> Sums)> ReadReleaseAsync(string repo, string tag, string prefix, CancellationToken ct)
    {
        if (!tag.StartsWith(prefix, StringComparison.Ordinal))
            throw new InvalidDataException($"'{tag}' isn't a {prefix}* release tag.");
        var rel = await GetReleaseAsync(repo, tag, ct);
        if (rel.Tag != tag) throw new InvalidDataException($"GitHub returned release '{rel.Tag}' for '{tag}'.");
        if (rel.Draft) throw new InvalidDataException($"Release {tag} is a draft.");
        if (!rel.Prerelease) throw new InvalidDataException($"Release {tag} must be a prerelease (mac-build-* releases are never Latest).");
        if (!rel.Assets.Any(a => a.Name == "SHA256SUMS")) throw new InvalidDataException($"Release {tag} has no SHA256SUMS.");
        string text;
        try { text = Encoding.UTF8.GetString(await fetch($"https://github.com/{repo}/releases/download/{tag}/SHA256SUMS", ct)); }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException)
        { throw new InvalidDataException($"Couldn't read SHA256SUMS of {tag}: {ex.Message}"); }
        return (rel, ParseSha256Sums(text));
    }

    /// <summary>publish.json mac.runtime.tag -> a validated platforms.mac.runtime.</summary>
    public async Task<RuntimePin> ResolveRuntimeAsync(string repo, string tag, CancellationToken ct = default)
    {
        var (rel, sums) = await ReadReleaseAsync(repo, tag, RuntimePin.TagPrefix, ct);
        var id = tag[RuntimePin.TagPrefix.Length..];
        if (!RuntimePin.IsValidId(id)) throw new InvalidDataException($"Runtime id '{id}' (from {tag}) must look like pp<N>-cx<version>.");
        var asset = RuntimePin.AssetFor(id);
        if (!sums.TryGetValue(asset, out var sha)) throw new InvalidDataException($"SHA256SUMS of {tag} has no line for {asset}.");
        var ra = rel.Assets.FirstOrDefault(a => a.Name == asset) ?? throw new InvalidDataException($"Release {tag} has no asset {asset}.");
        var pin = new RuntimePin { Id = id, Tag = tag, Asset = asset, Sha256 = sha, Size = ra.Size };
        if (pin.Problems() is { Count: > 0 } p) throw new InvalidDataException(string.Join(" ", p));
        log($"  mac runtime {id}: {asset} sha256 {sha[..12]}… ({ra.Size:N0} bytes) from {tag}");
        return pin;
    }

    /// <summary>publish.json mac.frontEnd.tag -> a validated platforms.mac.frontEnd.</summary>
    public async Task<FrontEndPin> ResolveFrontEndAsync(string repo, string tag, CancellationToken ct = default)
    {
        var (rel, sums) = await ReadReleaseAsync(repo, tag, FrontEndPin.TagPrefix, ct);
        var version = tag[FrontEndPin.TagPrefix.Length..];
        if (!FrontEndPin.IsValidVersion(version)) throw new InvalidDataException($"Front-end version '{version}' (from {tag}) isn't a dotted version.");
        var zip = FrontEndPin.ZipFor(version);
        if (!sums.TryGetValue(zip, out var sha)) throw new InvalidDataException($"SHA256SUMS of {tag} has no line for {zip}.");
        if (!rel.Assets.Any(a => a.Name == zip)) throw new InvalidDataException($"Release {tag} has no asset {zip}.");
        var pin = new FrontEndPin { Version = version, Tag = tag, Zip = zip, Sha256 = sha };
        if (pin.Problems() is { Count: > 0 } p) throw new InvalidDataException(string.Join(" ", p));
        log($"  mac front end {version}: {zip} sha256 {sha[..12]}… from {tag}");
        return pin;
    }

    /// <summary>Compares dotted versions numerically ("0.10.0" &gt; "0.9.1"); the "-suffix" is ignored.</summary>
    public static int CompareVersions(string a, string b)
    {
        static int[] Parts(string v) => v.Split('-')[0].Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray();
        var (x, y) = (Parts(a), Parts(b));
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            int c = (i < x.Length ? x[i] : 0).CompareTo(i < y.Length ? y[i] : 0);
            if (c != 0) return c;
        }
        return 0;
    }

    // ---------------- gameDepot ----------------

    /// <summary>publish.json "gameDepot": "auto" = &lt;gameDir&gt;\..\..\appmanifest_&lt;appId&gt;.acf; otherwise a path to the .acf.</summary>
    public static string? AcfPath(string setting, string? gameDir, int appId)
    {
        if (!setting.Equals("auto", StringComparison.OrdinalIgnoreCase)) return setting;
        if (string.IsNullOrWhiteSpace(gameDir)) return null;
        var steamapps = Directory.GetParent(Path.GetFullPath(gameDir).TrimEnd('\\', '/'))?.Parent?.FullName;
        return steamapps is null ? null : Path.Combine(steamapps, $"appmanifest_{appId}.acf");
    }

    /// <summary>Reads appid, buildid and InstalledDepots/&lt;depot&gt;/manifest from an .acf. Only those fields are used
    /// (nothing else from the file, e.g. LastOwner, ever reaches the manifest). Returns null (with a log line) when the
    /// file is missing or unreadable.</summary>
    public static GameDepot? ReadGameDepot(string? acfPath, int appId, Action<string> log)
    {
        if (acfPath is null || !File.Exists(acfPath)) { log($"  gameDepot: no {acfPath ?? "appmanifest .acf (gameDir isn't set)"}; left out."); return null; }
        try
        {
            var root = Vdf.Parse(File.ReadAllText(acfPath));
            if (root.GetValueOrDefault("AppState") is not Dictionary<string, object> st) throw new InvalidDataException("no AppState");
            string? S(Dictionary<string, object> d, string k) => d.GetValueOrDefault(k) as string;
            if (!int.TryParse(S(st, "appid"), out var acfApp) || acfApp != appId) throw new InvalidDataException($"appid {S(st, "appid")} isn't {appId}");
            var depots = st.GetValueOrDefault("InstalledDepots") as Dictionary<string, object> ?? throw new InvalidDataException("no InstalledDepots");
            // PEAK's game depot is appId+1 (3527291); otherwise the only installed depot.
            var key = depots.ContainsKey((appId + 1).ToString()) ? (appId + 1).ToString() : depots.Count == 1 ? depots.Keys.First() : null;
            if (key is null || depots[key] is not Dictionary<string, object> dep || !int.TryParse(key, out var depotId))
                throw new InvalidDataException("can't tell which installed depot is the game");
            var gd = new GameDepot { AppId = acfApp, DepotId = depotId, ManifestId = S(dep, "manifest") ?? "", BuildId = S(st, "buildid") ?? "" };
            if (gd.Problems() is { Count: > 0 } p) throw new InvalidDataException(string.Join(" ", p));
            if (S(st, "StateFlags") is { } flags && flags != "4")
                log($"  NOTE: Steam says PEAK isn't fully up to date on this PC (StateFlags {flags}); gameDepot records the installed build.");
            log($"  gameDepot: depot {gd.DepotId} manifest {gd.ManifestId}, build {gd.BuildId} (from {acfPath})");
            return gd;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidDataException or FormatException)
        {
            log($"  gameDepot: couldn't read {acfPath} ({ex.Message}); left out.");
            return null;
        }
    }

    /// <summary>Minimal Valve KeyValues (text VDF) reader: quoted keys/values, nested { }, // comments, \" \\ escapes.</summary>
    public static class Vdf
    {
        public static Dictionary<string, object> Parse(string text)
        {
            int i = 0;
            var root = ParseBlock(text, ref i, topLevel: true);
            return root;
        }

        static Dictionary<string, object> ParseBlock(string s, ref int i, bool topLevel)
        {
            var d = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            while (true)
            {
                SkipWs(s, ref i);
                if (i >= s.Length)
                {
                    if (topLevel) return d;
                    throw new InvalidDataException("unexpected end of file");
                }
                if (s[i] == '}')
                {
                    if (topLevel) throw new InvalidDataException("unbalanced }");
                    i++;
                    return d;
                }
                var key = ReadToken(s, ref i);
                SkipWs(s, ref i);
                if (i >= s.Length) throw new InvalidDataException($"no value for '{key}'");
                if (s[i] == '{') { i++; d[key] = ParseBlock(s, ref i, false); }
                else d[key] = ReadToken(s, ref i);
            }
        }

        static void SkipWs(string s, ref int i)
        {
            while (i < s.Length)
            {
                if (char.IsWhiteSpace(s[i])) i++;
                else if (s[i] == '/' && i + 1 < s.Length && s[i + 1] == '/') { while (i < s.Length && s[i] != '\n') i++; }
                else break;
            }
        }

        static string ReadToken(string s, ref int i)
        {
            var sb = new StringBuilder();
            if (s[i] == '"')
            {
                i++;
                while (i < s.Length && s[i] != '"')
                {
                    if (s[i] == '\\' && i + 1 < s.Length) { i++; sb.Append(s[i] switch { 'n' => '\n', 't' => '\t', _ => s[i] }); }
                    else sb.Append(s[i]);
                    i++;
                }
                if (i >= s.Length) throw new InvalidDataException("unterminated string");
                i++;
                return sb.ToString();
            }
            while (i < s.Length && !char.IsWhiteSpace(s[i]) && s[i] is not ('{' or '}' or '"')) sb.Append(s[i++]);
            if (sb.Length == 0) throw new InvalidDataException($"unexpected '{s[i]}'");
            return sb.ToString();
        }
    }
}
