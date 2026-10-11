using System.Text.Json;

namespace PeakPack.Core;

/// <summary>Minimal view of the Thunderstore v1 package index (https://thunderstore.io/c/peak/api/v1/package/).
/// Only the publisher uses this; friends never query Thunderstore's API, they just download pinned zips.</summary>
public sealed class ThunderstoreIndex
{
    public const string PeakIndexUrl = "https://thunderstore.io/c/peak/api/v1/package/";

    public sealed record TsVersion(string FullName, Version Version, string DownloadUrl, long FileSize, IReadOnlyList<string> Dependencies, bool IsActive, string Description = "", long Downloads = 0);
    public sealed record TsPackage(string FullName, string Owner, bool IsDeprecated, IReadOnlyList<TsVersion> Versions, IReadOnlyList<string> Categories, int Rating = 0)
    {
        /// <summary>Authors tag PEAK mods "Host Only", "Client Side" or "All Clients" (self-reported).</summary>
        public bool IsHostOnly => Categories.Any(c => c.Equals("Host Only", StringComparison.OrdinalIgnoreCase));
        public TsVersion Latest => Versions.Where(v => v.IsActive).MaxBy(v => v.Version) ?? Versions.MaxBy(v => v.Version)!;
        public string Name => FullName[(FullName.IndexOf('-') + 1)..];
        public long TotalDownloads => Versions.Sum(v => v.Downloads);
        /// <summary>"InfiniteJetpack" -> "Infinite Jetpack", "PEAK_Unlimited" -> "PEAK Unlimited"</summary>
        public string FriendlyName => Friendly(Name);
    }

    readonly Dictionary<string, TsPackage> _byName = new(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyCollection<TsPackage> All => _byName.Values;

    public static ThunderstoreIndex Parse(Stream json)
    {
        var idx = new ThunderstoreIndex();
        using var doc = JsonDocument.Parse(json);
        foreach (var p in doc.RootElement.EnumerateArray())
        {
            var versions = new List<TsVersion>();
            foreach (var v in p.GetProperty("versions").EnumerateArray())
            {
                if (!Version.TryParse(v.GetProperty("version_number").GetString(), out var ver)) continue;
                versions.Add(new TsVersion(
                    v.GetProperty("full_name").GetString()!,
                    ver,
                    v.GetProperty("download_url").GetString()!,
                    v.TryGetProperty("file_size", out var fs) ? fs.GetInt64() : 0,
                    v.GetProperty("dependencies").EnumerateArray().Select(d => d.GetString()!).ToList(),
                    !v.TryGetProperty("is_active", out var a) || a.GetBoolean(),
                    v.TryGetProperty("description", out var desc) ? desc.GetString() ?? "" : "",
                    v.TryGetProperty("downloads", out var dls) && dls.TryGetInt64(out var dn) ? dn : 0));
            }
            var name = p.GetProperty("full_name").GetString()!;
            idx._byName[name] = new TsPackage(name, p.GetProperty("owner").GetString() ?? "",
                p.TryGetProperty("is_deprecated", out var dep) && dep.GetBoolean(), versions,
                p.TryGetProperty("categories", out var cats) ? cats.EnumerateArray().Select(x => x.GetString() ?? "").ToList() : [],
                p.TryGetProperty("rating_score", out var rs) && rs.TryGetInt32(out var r) ? r : 0);
        }
        return idx;
    }

    /// <summary>Loads the index from a cache file if fresh, else downloads it (â‰ˆ9 MB).</summary>
    public static async Task<ThunderstoreIndex> LoadAsync(string cacheFile, TimeSpan maxAge, string url = PeakIndexUrl, CancellationToken ct = default)
    {
        if (!File.Exists(cacheFile) || DateTime.UtcNow - File.GetLastWriteTimeUtc(cacheFile) > maxAge)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(cacheFile))!);
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("PeakPack-Publisher");
            var tmp = cacheFile + ".part";
            await using (var s = await http.GetStreamAsync(url, ct))
            await using (var f = File.Create(tmp))
                await s.CopyToAsync(f, ct);
            File.Move(tmp, cacheFile, true);
        }
        await using var fsr = File.OpenRead(cacheFile);
        return Parse(fsr);
    }

    public TsPackage? Find(string fullName) => _byName.GetValueOrDefault(fullName);

    /// <summary>Host view search: matches name, owner and description; best matches and most downloaded first.
    /// Deprecated packages and modpacks are left out.</summary>
    public IReadOnlyList<TsPackage> Search(string query, int max = 50)
    {
        var q = query.Trim();
        var qn = Norm(q);
        return _byName.Values
            .Where(p => !p.IsDeprecated && !p.Categories.Contains("Modpacks", StringComparer.OrdinalIgnoreCase))
            .Select(p =>
            {
                var name = Norm(p.Name);
                int score = q.Length == 0 ? 1
                    : name == qn ? 100
                    : name.StartsWith(qn) ? 60
                    : name.Contains(qn) ? 40
                    : Norm(p.Owner).Contains(qn) ? 20
                    : p.Latest.Description.Contains(q, StringComparison.OrdinalIgnoreCase) ? 10 : 0;
                return (p, score);
            })
            .Where(x => x.score > 0)
            .OrderByDescending(x => x.score).ThenByDescending(x => x.p.TotalDownloads)
            .Take(max).Select(x => x.p).ToList();

        static string Norm(string s) => new string(s.Where(char.IsAsciiLetterOrDigit).ToArray()).ToLowerInvariant();
    }

    /// <summary>"InfiniteJetpack" -> "Infinite Jetpack"; underscores become spaces; acronyms kept ("PEAKLib_Core" -> "PEAKLib Core").</summary>
    public static string Friendly(string name)
    {
        var sb = new System.Text.StringBuilder();
        for (int i = 0; i < name.Length; i++)
        {
            char c = name[i];
            if (c == '_') { sb.Append(' '); continue; }
            // Split "InfiniteJetpack" but keep "BepInEx" / "PickUp": only before a capital that starts a word of 3+ letters.
            int run = 0;
            while (i + 1 + run < name.Length && char.IsLower(name[i + 1 + run])) run++;
            if (i > 0 && char.IsUpper(c) && char.IsLower(name[i - 1]) && run >= 2) sb.Append(' ');
            sb.Append(c);
        }
        return string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
    }

    public TsVersion Get(PackageId id)
    {
        var pkg = Find(id.FullName) ?? throw new KeyNotFoundException($"Package '{id.FullName}' isn't on Thunderstore (PEAK community).");
        if (id.Version is null) return pkg.Latest;
        return pkg.Versions.FirstOrDefault(v => v.Version == id.Version)
               ?? throw new KeyNotFoundException($"Version {id.Version} of '{id.FullName}' isn't on Thunderstore.");
    }
}

/// <summary>
/// Resolves Joshua's requested mods into a complete, pinned install list (a "lock file").
/// Policy (same spirit as r2modman): every dependency string names a version; if several packages
/// need the same dependency, the highest requested version wins. Explicitly requested versions win
/// over dependency versions. Any BepInExPack* dependency is replaced by the PEAK loader.
/// </summary>
public static class Resolver
{
    public sealed record Resolved(ThunderstoreIndex.TsVersion Loader, IReadOnlyList<(ThunderstoreIndex.TsVersion Pkg, string Reason)> Packages, IReadOnlyList<string> Warnings);

    public static Resolved Resolve(ThunderstoreIndex index, IEnumerable<string> requested, string loader = "BepInEx-BepInExPack_PEAK", bool latestDependencies = false)
    {
        var warnings = new List<string>();
        var loaderVer = index.Get(PackageId.Parse(loader));
        var chosen = new Dictionary<string, (Version Ver, string Reason, bool Pinned)>(StringComparer.OrdinalIgnoreCase);
        var queue = new Queue<string>();

        foreach (var r in requested)
        {
            var id = PackageId.Parse(r);
            if (id.IsLoader) continue;
            var v = index.Get(id);
            var pkg = index.Find(id.FullName)!;
            if (pkg.IsDeprecated) warnings.Add($"{id.FullName} is marked deprecated on Thunderstore.");
            chosen[id.FullName] = (v.Version, "requested", id.Version is not null);
            queue.Enqueue(id.FullName);
        }

        while (queue.Count > 0)
        {
            var name = queue.Dequeue();
            var ver = index.Get(new PackageId(name.Split('-')[0], name.Split('-')[1], chosen[name].Ver));
            foreach (var depStr in ver.Dependencies)
            {
                PackageId dep;
                try { dep = PackageId.Parse(depStr); } catch (FormatException) { warnings.Add($"Skipped odd dependency '{depStr}' of {name}"); continue; }
                if (dep.IsLoader)
                {
                    if (dep.Version is { } lv && dep.FullName.Equals(loaderVer.FullName[..loaderVer.FullName.LastIndexOf('-')], StringComparison.OrdinalIgnoreCase) && lv > loaderVer.Version)
                        warnings.Add($"{name} wants {depStr}, newer than the pinned loader {loaderVer.FullName}.");
                    continue;
                }
                var depPkg = index.Find(dep.FullName);
                if (depPkg is null) { warnings.Add($"{name} depends on {depStr}, which isn't in the PEAK index - skipped."); continue; }
                var want = latestDependencies ? depPkg.Latest.Version : (dep.Version ?? depPkg.Latest.Version);
                if (depPkg.Versions.All(v => v.Version != want)) want = depPkg.Latest.Version;
                if (chosen.TryGetValue(dep.FullName, out var cur))
                {
                    if (cur.Pinned || cur.Ver >= want) continue;
                    chosen[dep.FullName] = (want, cur.Reason, false);
                }
                else chosen[dep.FullName] = (want, "dependency of " + name, false);
                queue.Enqueue(dep.FullName); // re-walk with the (possibly newer) version
            }
        }

        var list = chosen
            .Select(kv => (index.Get(new PackageId(kv.Key.Split('-')[0], kv.Key.Split('-')[1], kv.Value.Ver)), kv.Value.Reason))
            .OrderBy(x => x.Item1.FullName, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new Resolved(loaderVer, list, warnings);
    }
}
