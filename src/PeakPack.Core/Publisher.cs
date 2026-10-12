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
    /// <summary>Override for manifest.modsRequiredToJoin; null = auto (any "All Clients" mod or any custom DLL).</summary>
    public bool? ModsRequiredToJoin { get; set; }
    /// <summary>Optional: friend app release to advertise for self-update.</summary>
    public AppSource? App { get; set; }

    // ---- v0.3 ----

    /// <summary>Shown to friends: "Joshua's lobby uses pack rev 7".</summary>
    public string HostName { get; set; } = "Joshua";
    /// <summary>Stable pack id for the lobby check. Default: slug of packName. Don't change it once friends have the pack.</summary>
    public string? PackId { get; set; }
    /// <summary>GitHub repo "owner/name" the release pipeline uploads to. Also used to derive manifestUrl and
    /// assetBaseUrl when those are empty.</summary>
    public string? GithubRepo { get; set; }
    /// <summary>Where friends' apps read the manifest. Used to find the previous revision (what friends really have).
    /// Default with githubRepo: https://github.com/OWNER/REPO/releases/latest/download/manifest.json</summary>
    public string? ManifestUrl { get; set; }
    /// <summary>Friendly names and one-line "why it's in the pack" texts for the friend app, keyed by
    /// "Namespace-Name" (Thunderstore) or a custom file id. Missing entries fall back to Thunderstore's own text.</summary>
    public Dictionary<string, ModText> ModInfo { get; set; } = new(StringComparer.OrdinalIgnoreCase);
    /// <summary>The in-game companion plugin (lobby revision check + live settings). "auto" (default) = the build
    /// in this repo (src/PeakPack.Companion/bin/Release/PeakPack.Companion.dll); a path; or "" to leave it out.</summary>
    public string? Companion { get; set; } = "auto";
    /// <summary>Lobby check policy and the live settings the lobby host's values apply to everyone in that lobby.</summary>
    public LobbySettings? Lobby { get; set; }

    /// <summary>Mac friends (PeakPack inside our Wine prefix): extra game args and Mac config defaults (ifMissing, config/ only).</summary>
    public MacSource? Mac { get; set; }

    public sealed class MacSource
    {
        public List<string> ExtraArgs { get; set; } = new();
        /// <summary>{ id, version, source, dest: "config/&lt;guid&gt;.cfg" }. Always installed "ifMissing".</summary>
        public List<CustomFile> ConfigFiles { get; set; } = new();
        public string? MinFrontEnd { get; set; }
    }

    /// <summary>Fields this version doesn't know (e.g. added by hand or by a newer tool). Kept on load and written
    /// back on Save, so the Host window and the CLI can both edit the same publish.json without losing anything.</summary>
    [System.Text.Json.Serialization.JsonExtensionData]
    public Dictionary<string, JsonElement>? Extra { get; set; }

    public sealed class ModText
    {
        public string? Title { get; set; }
        public string? Description { get; set; }
    }

    public sealed class CustomFile
    {
        public string Id { get; set; } = "";
        public string? Version { get; set; }
        public string Source { get; set; } = "";
        /// <summary>Relative to BepInEx/, e.g. plugins/Joshua-HeliPilot/HeliPilot.dll</summary>
        public string Dest { get; set; } = "";
        public OverwriteMode Overwrite { get; set; } = OverwriteMode.Always;
        public string? Title { get; set; }
        public string? Description { get; set; }
        /// <summary>The mod supports AutoReload (OnDestroy cleans up everything, embedded PDB): new builds may be
        /// applied live in a test lobby. Only for your own mods.</summary>
        public bool ReloadSafe { get; set; }
    }

    /// <summary>Host ids for the manifest: lobby.hostIds if set, else the id the host's own companion recorded in
    /// &lt;gameDir&gt;\BepInEx\PeakPack\host-id.txt the last time he hosted a lobby.</summary>
    public List<string> EffectiveHostIds(Action<string>? log = null)
    {
        if (Lobby?.HostIds is { Count: > 0 } ids) return ids.ToList();
        var file = GameDir is null ? null : Path.Combine(GameDir, "BepInEx", "PeakPack", "host-id.txt");
        if (file is not null && File.Exists(file) && File.ReadAllText(file).Trim() is { Length: > 0 } id)
        {
            log?.Invoke($"  host id from {file}: {id}");
            return [id];
        }
        log?.Invoke("  NOTE: no host id yet (host a lobby once with the companion installed, then publish again). Until then friends share no logs.");
        return [];
    }

    public const string CompanionId = "PeakPack-Companion";
    public const string CompanionDest = "plugins/PeakPack-Companion/PeakPack.Companion.dll";

    public string? EffectiveManifestUrl =>
        !string.IsNullOrWhiteSpace(ManifestUrl) ? ManifestUrl
        : HasRealRepo ? $"https://github.com/{GithubRepo}/releases/latest/download/manifest.json" : null;

    public string? EffectiveAssetBaseUrl =>
        !string.IsNullOrWhiteSpace(AssetBaseUrl) ? AssetBaseUrl
        : HasRealRepo ? $"https://github.com/{GithubRepo}/releases/download/rev-{{revision}}/" : null;

    public bool HasRealRepo => GithubRepo is { Length: > 2 } r && r.Contains('/') && !r.Contains("CHANGE-ME", StringComparison.OrdinalIgnoreCase);

    public string EffectivePackId => string.IsNullOrWhiteSpace(PackId) ? PackManifest.Slug(PackName) : PackManifest.Slug(PackId);

    /// <summary>Resolves "auto" to the companion DLL built in this repo (searching upward from the running exe).</summary>
    public string? ResolveCompanionSource()
    {
        if (Companion is null || Companion.Length == 0) return null;
        if (!Companion.Equals("auto", StringComparison.OrdinalIgnoreCase)) return Companion;
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
        {
            var c = Path.Combine(d.FullName, "src", "PeakPack.Companion", "bin", "Release", "PeakPack.Companion.dll");
            if (File.Exists(c)) return c;
        }
        return null;
    }

    public void Save(string path) =>
        File.WriteAllText(path, JsonSerializer.Serialize(this, PackManifest.JsonOptions), new UTF8Encoding(false));

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
    public const string AutoReloadPackage = "Hamunii-AutoReload";

    public async Task<PackManifest> PublishAsync(PublishConfig cfg, string outDir, PackManifest? previous, CancellationToken ct = default)
    {
        Directory.CreateDirectory(outDir);
        // Test lobby: AutoReload must be in the friends' pack, or live updates have nothing to load them.
        var mods = cfg.Mods.ToList();
        if (cfg.Lobby?.TestLobby == true && cfg.CustomFiles.Any(c => c.ReloadSafe)
            && !mods.Any(x => PackageId.Parse(x).FullName.Equals(AutoReloadPackage, StringComparison.OrdinalIgnoreCase)))
        {
            mods.Add(AutoReloadPackage);
            log($"  test lobby: adding {AutoReloadPackage} (loads live updates of your reload-safe mods)");
        }
        var resolved = Resolver.Resolve(index, mods, cfg.Loader, cfg.LatestDependencies);
        foreach (var w in resolved.Warnings) log("WARNING: " + w);

        var hostOnlyNames = cfg.HostOnly.Select(h => PackageId.Parse(h).FullName).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var m = new PackManifest
        {
            PackName = cfg.PackName,
            Notes = cfg.Notes,
            Revision = (previous?.Revision ?? 0) + 1,
            Published = DateTimeOffset.UtcNow,
            HostOnly = cfg.HostOnly.ToList(),
            HostName = cfg.HostName,
            PackId = cfg.EffectivePackId,
            Lobby = cfg.Lobby is null ? null : new LobbySettings
            {
                MismatchPolicy = cfg.Lobby.MismatchPolicy, LiveSettings = cfg.Lobby.LiveSettings, TestLobby = cfg.Lobby.TestLobby,
                Diagnostics = cfg.Lobby.Diagnostics, HostIds = cfg.EffectiveHostIds(log),
            },
        };
        m.Changelog = (previous?.Changelog ?? []).Take(19).ToList();
        if (!string.IsNullOrWhiteSpace(cfg.Notes)) m.Changelog.Insert(0, new ChangelogEntry { Revision = m.Revision, Date = m.Published, Notes = cfg.Notes.Trim() });
        if (cfg.GameDir is not null && File.Exists(Path.Combine(cfg.GameDir, "version.txt")))
            m.GameVersion = File.ReadLines(Path.Combine(cfg.GameDir, "version.txt")).FirstOrDefault()?.Trim();

        // Thunderstore packages: download once to compute the SHA-256 we pin (Thunderstore's API doesn't publish hashes).
        async Task<PackageEntry> Pin(ThunderstoreIndex.TsVersion v, string reason)
        {
            log($"  hashing {v.FullName} ...");
            var (_, sha, size) = await downloader.GetVerifiedAsync(v.DownloadUrl, null, null, ct);
            var full = PackageId.Parse(v.FullName).FullName;
            var pkg = index.Find(full);
            var cats = pkg?.Categories.Where(c => c is "All Clients" or "Client Side" or "Host Only").ToList();
            cfg.ModInfo.TryGetValue(full, out var info);
            return new PackageEntry
            {
                Id = v.FullName, Url = v.DownloadUrl, Sha256 = sha, Size = size, Reason = reason, Tags = cats is { Count: > 0 } ? cats : null,
                Title = info?.Title ?? (pkg is null ? null : ThunderstoreIndex.Friendly(pkg.Name)),
                Description = info?.Description ?? (string.IsNullOrWhiteSpace(v.Description) ? null : v.Description.Trim()),
            };
        }
        m.Loader = await Pin(resolved.Loader, "loader");
        foreach (var (pkg, reason) in resolved.Packages)
        {
            var full = PackageId.Parse(pkg.FullName).FullName;
            if (hostOnlyNames.Contains(full)) { log($"  skipping host-only {full}"); continue; }
            m.Packages.Add(await Pin(pkg, reason));
        }

        // Joshua's own files: copied into outDir with flat, content-addressed names (GitHub release assets are flat).
        var baseUrl = cfg.EffectiveAssetBaseUrl?.Replace("{revision}", m.Revision.ToString());
        var customFiles = cfg.CustomFiles.ToList();
        if (customFiles.All(c => !c.Id.Equals(PublishConfig.CompanionId, StringComparison.OrdinalIgnoreCase)))
        {
            if (cfg.ResolveCompanionSource() is { } comp && File.Exists(comp))
                customFiles.Add(new PublishConfig.CustomFile
                {
                    Id = PublishConfig.CompanionId, Source = comp, Dest = PublishConfig.CompanionDest,
                    Version = System.Diagnostics.FileVersionInfo.GetVersionInfo(comp) is var fv ? $"{fv.FileMajorPart}.{fv.FileMinorPart}.{fv.FileBuildPart}" : null,
                    Title = "Lobby check",
                    Description = $"Tells you in-game when your mods don't match {cfg.HostName}'s lobby.",
                });
            else if (!string.IsNullOrEmpty(cfg.Companion))
                log($"WARNING: companion plugin not found ({cfg.Companion}); this pack has no in-game lobby check. Build src/PeakPack.Companion (Release) or set \"companion\": \"\".");
        }
        foreach (var cf in customFiles)
        {
            if (!File.Exists(cf.Source)) throw new FileNotFoundException($"Custom file not found: {cf.Source}");
            var sha = Downloader.Sha256OfFile(cf.Source);
            var assetName = $"{cf.Id}-{sha[..8]}-{Path.GetFileName(cf.Source)}";
            File.Copy(cf.Source, Path.Combine(outDir, assetName), true);
            cfg.ModInfo.TryGetValue(cf.Id, out var finfo);
            m.Files.Add(new FileEntry
            {
                Id = cf.Id, Version = cf.Version, Path = cf.Dest, Overwrite = cf.Overwrite,
                Title = cf.Title ?? finfo?.Title, Description = cf.Description ?? finfo?.Description,
                HotReload = cf.ReloadSafe && cf.Dest.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && cf.Id != PublishConfig.CompanionId,
                Url = string.IsNullOrEmpty(baseUrl) ? assetName : baseUrl.TrimEnd('/') + "/" + assetName,
                Sha256 = sha, Size = new FileInfo(cf.Source).Length,
            });
            log($"  custom file {cf.Id} -> {assetName}");
        }

        if (cfg.Mac is { } mac)
        {
            var ms = new MacSettings { ExtraArgs = mac.ExtraArgs.ToList(), MinFrontEnd = mac.MinFrontEnd };
            foreach (var cf in mac.ConfigFiles)
            {
                if (!File.Exists(cf.Source)) throw new FileNotFoundException($"Mac config file not found: {cf.Source}");
                var sha = Downloader.Sha256OfFile(cf.Source);
                var assetName = $"mac-{cf.Id}-{sha[..8]}-{Path.GetFileName(cf.Source)}";
                File.Copy(cf.Source, Path.Combine(outDir, assetName), true);
                ms.Files.Add(new FileEntry
                {
                    Id = cf.Id, Version = cf.Version, Path = cf.Dest, Overwrite = OverwriteMode.IfMissing,
                    Url = string.IsNullOrEmpty(baseUrl) ? assetName : baseUrl.TrimEnd('/') + "/" + assetName,
                    Sha256 = sha, Size = new FileInfo(cf.Source).Length,
                });
                log($"  mac config {cf.Dest} -> {assetName}");
            }
            m.Platforms = new PlatformSettings { Mac = ms };
        }

        if (cfg.App is { } app && File.Exists(app.Source))
        {
            var sha = Downloader.Sha256OfFile(app.Source);
            var name = $"PeakPack-{app.Version}.exe";
            File.Copy(app.Source, Path.Combine(outDir, name), true);
            m.App = new AppRelease { Version = app.Version, Sha256 = sha, Size = new FileInfo(app.Source).Length,
                Url = string.IsNullOrEmpty(baseUrl) ? name : baseUrl.TrimEnd('/') + "/" + name };
        }

        m.ModsRequiredToJoin = cfg.ModsRequiredToJoin
            ?? (m.Packages.Any(p => p.Tags?.Contains("All Clients") == true) || m.Files.Any(f => f.Path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)));
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
