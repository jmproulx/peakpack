using System.IO.Compression;
using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>Joshua's side: publish.json -> manifest.json (+ .sig) + the files to upload.</summary>
public sealed class PublishConfig
{
    public string PackName { get; set; } = "Joshua's PEAK mods";
    public string? Notes { get; set; }
    /// <summary>Loader package, optionally pinned: "BepInEx-BepInExPack_PEAK" or "BepInEx-BepInExPack_PEAK-5.4.75301".</summary>
    public string Loader { get; set; } = "BepInEx-BepInExPack_PEAK";
    /// <summary>Thunderstore mods friends need: "Namespace-Name" (= latest) or "Namespace-Name-1.2.3" (pinned).</summary>
    public List<string> Mods { get; set; } = new();
    /// <summary>Mods only the host needs (e.g. glarmer-PEAK_Unlimited). Listed in the manifest for info, never installed.</summary>
    public List<string> HostOnly { get; set; } = new();
    public bool LatestDependencies { get; set; }
    public List<CustomFile> CustomFiles { get; set; } = new();
    /// <summary>Where uploaded files will live. "{revision}" is replaced. Empty = relative to the manifest URL.
    /// Recommended (immutable per publish): https://github.com/USER/REPO/releases/download/rev-{revision}/</summary>
    public string? AssetBaseUrl { get; set; }
    /// <summary>Optional: PEAK folder, only read to record the game version (version.txt).</summary>
    public string? GameDir { get; set; }
    /// <summary>Optional: path to the PEM private key from `keygen`. Keep it OUT of any repo.</summary>
    public string? SigningKey { get; set; }
    /// <summary>Optional: friend app release to advertise for self-update.</summary>
    public AppSource? App { get; set; }

    public sealed class CustomFile
    {
        public string Id { get; set; } = "";
        public string? Version { get; set; }
        public string Source { get; set; } = "";
        /// <summary>Relative to BepInEx/, e.g. plugins/Joshua-HeliPilot/HeliPilot.dll</summary>
        public string Dest { get; set; } = "";
        public OverwriteMode Overwrite { get; set; } = OverwriteMode.Always;
    }

    public sealed class AppSource
    {
        public string Version { get; set; } = "";
        public string Source { get; set; } = "";
    }

    public static PublishConfig Load(string path) =>
        JsonSerializer.Deserialize<PublishConfig>(File.ReadAllText(path), PackManifest.JsonOptions)
        ?? throw new InvalidDataException("publish.json is empty");
}

public sealed class Publisher(Downloader downloader, ThunderstoreIndex index, Action<string> log)
{
    public async Task<PackManifest> PublishAsync(PublishConfig cfg, string outDir, PackManifest? previous, CancellationToken ct = default)
    {
        Directory.CreateDirectory(outDir);
        var resolved = Resolver.Resolve(index, cfg.Mods, cfg.Loader, cfg.LatestDependencies);
        foreach (var w in resolved.Warnings) log("WARNING: " + w);

        var hostOnlyNames = cfg.HostOnly.Select(h => PackageId.Parse(h).FullName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var m = new PackManifest
        {
            PackName = cfg.PackName,
            Notes = cfg.Notes,
            Revision = (previous?.Revision ?? 0) + 1,
            Published = DateTimeOffset.UtcNow,
            HostOnly = cfg.HostOnly.ToList(),
        };
        if (cfg.GameDir is not null && File.Exists(Path.Combine(cfg.GameDir, "version.txt")))
            m.GameVersion = File.ReadLines(Path.Combine(cfg.GameDir, "version.txt")).FirstOrDefault()?.Trim();

        // Thunderstore packages: download once to compute the SHA-256 we pin (Thunderstore's API doesn't publish hashes).
        async Task<PackageEntry> Pin(ThunderstoreIndex.TsVersion v, string reason)
        {
            log($"  hashing {v.FullName} ...");
            var (_, sha, size) = await downloader.GetVerifiedAsync(v.DownloadUrl, null, null, ct);
            return new PackageEntry { Id = v.FullName, Url = v.DownloadUrl, Sha256 = sha, Size = size, Reason = reason };
        }
        m.Loader = await Pin(resolved.Loader, "loader");
        foreach (var (pkg, reason) in resolved.Packages)
        {
            var full = PackageId.Parse(pkg.FullName).FullName;
            if (hostOnlyNames.Contains(full)) { log($"  skipping host-only {full}"); continue; }
            m.Packages.Add(await Pin(pkg, reason));
        }

        // Joshua's own files: copied into outDir with flat, content-addressed names (GitHub release assets are flat).
        var baseUrl = cfg.AssetBaseUrl?.Replace("{revision}", m.Revision.ToString());
        foreach (var cf in cfg.CustomFiles)
        {
            if (!File.Exists(cf.Source)) throw new FileNotFoundException($"Custom file not found: {cf.Source}");
            var sha = Downloader.Sha256OfFile(cf.Source);
            var assetName = $"{cf.Id}-{sha[..8]}-{Path.GetFileName(cf.Source)}";
            File.Copy(cf.Source, Path.Combine(outDir, assetName), true);
            m.Files.Add(new FileEntry
            {
                Id = cf.Id, Version = cf.Version, Path = cf.Dest, Overwrite = cf.Overwrite,
                Url = string.IsNullOrEmpty(baseUrl) ? assetName : baseUrl.TrimEnd('/') + "/" + assetName,
                Sha256 = sha, Size = new FileInfo(cf.Source).Length,
            });
            log($"  custom file {cf.Id} -> {assetName}");
        }

        if (cfg.App is { } app && File.Exists(app.Source))
        {
            var sha = Downloader.Sha256OfFile(app.Source);
            var name = $"PeakPack-{app.Version}.exe";
            File.Copy(app.Source, Path.Combine(outDir, name), true);
            m.App = new AppRelease { Version = app.Version, Sha256 = sha, Size = new FileInfo(app.Source).Length,
                Url = string.IsNullOrEmpty(baseUrl) ? name : baseUrl.TrimEnd('/') + "/" + name };
        }

        m.Validate();
        var bytes = new UTF8Encoding(false).GetBytes(m.ToJson());
        await File.WriteAllBytesAsync(Path.Combine(outDir, "manifest.json"), bytes, ct);
        if (!string.IsNullOrWhiteSpace(cfg.SigningKey))
        {
            var sig = ManifestSigner.Sign(bytes, await File.ReadAllTextAsync(cfg.SigningKey, ct));
            await File.WriteAllTextAsync(Path.Combine(outDir, "manifest.json.sig"), sig, ct);
            log("  signed manifest.json");
        }
        return m;
    }

    public static IEnumerable<string> Diff(PackManifest? before, PackManifest after)
    {
        var a = (before?.Packages.Select(p => p.Id) ?? []).Concat(before?.Files.Select(f => $"{f.Id}@{f.Sha256[..8]}") ?? []).Append(before?.Loader.Id ?? "").ToHashSet();
        var b = after.Packages.Select(p => p.Id).Concat(after.Files.Select(f => $"{f.Id}@{f.Sha256[..8]}")).Append(after.Loader.Id).ToHashSet();
        foreach (var x in b.Except(a).Order()) yield return "+ " + x;
        foreach (var x in a.Except(b).Where(s => s != "").Order()) yield return "- " + x;
    }

    /// <summary>
    /// Looks at a BepInEx plugins folder and works out which Thunderstore package+version each DLL came from,
    /// by downloading candidate packages and comparing SHA-256 of the DLLs inside. Anything that doesn't match
    /// is reported as a custom file. Read-only for the scanned folder.
    /// </summary>
    public async Task<(List<string> Matched, List<string> Unmatched)> ScanAsync(string pluginsDir, CancellationToken ct = default)
    {
        var matched = new List<string>();
        var unmatched = new List<string>();
        foreach (var dll in Directory.EnumerateFiles(pluginsDir, "*.dll", SearchOption.AllDirectories))
        {
            var sha = Downloader.Sha256OfFile(dll);
            var stem = Norm(Path.GetFileNameWithoutExtension(dll));
            var last = Norm(Path.GetFileNameWithoutExtension(dll).Split('.').Last());
            var candidates = index.All
                .Where(p => { var n = Norm(p.FullName.Split('-')[1]); return n == stem || n == last || (n.Length > 4 && (stem.Contains(n) || n.Contains(last) && last.Length > 4)); })
                .OrderByDescending(p => Norm(p.FullName.Split('-')[1]) == stem || Norm(p.FullName.Split('-')[1]) == last)
                .ThenByDescending(p => p.Versions.Count)
                .Take(6).ToList();
            string? hit = null;
            foreach (var p in candidates)
            {
                foreach (var v in p.Versions.OrderByDescending(v => v.Version).Take(8))
                {
                    var (zipPath, _, _) = await downloader.GetVerifiedAsync(v.DownloadUrl, null, null, ct);
                    using var zip = ZipFile.OpenRead(zipPath);
                    foreach (var e in zip.Entries.Where(e => e.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)))
                    {
                        using var s = e.Open();
                        using var ms = new MemoryStream();
                        await s.CopyToAsync(ms, ct);
                        if (Downloader.Sha256OfBytes(ms.ToArray()) == sha) { hit = v.FullName; break; }
                    }
                    if (hit is not null) break;
                }
                if (hit is not null) break;
            }
            if (hit is not null) { matched.Add(hit); log($"  {Path.GetFileName(dll)} = {hit}"); }
            else { unmatched.Add(dll); log($"  {Path.GetFileName(dll)} = not on Thunderstore (treat as custom file)"); }
        }
        return (matched.Distinct().ToList(), unmatched);

        static string Norm(string s) => new string(s.Where(char.IsAsciiLetterOrDigit).ToArray()).ToLowerInvariant();
    }
}
