using System.IO.Compression;
using System.Text;

namespace PeakPack.Core;

public sealed record SyncProgress(string Message, double? Fraction = null, bool IsDownload = false);

/// <param name="Strict">Delete anything in plugins/ and patchers/ the manifest doesn't own ("exactly the host's set").
/// Off = keep extra plugins (a host or dev profile).</param>
/// <param name="ManageGameFolder">Write winhttp.dll + doorstop_config.ini into the game folder and refuse foreign loaders.
/// Off = never touch the game folder (the host's "friend view" profile on a PC that already has its own Doorstop).</param>
/// <param name="ShortcutName">Used in the companion's in-game notices ("restart PEAK from the PEAK (Modded) icon").</param>
public sealed record SyncOptions(bool Strict = true, bool ManageGameFolder = true, string ShortcutName = "PEAK (Modded)");

public sealed class SyncResult
{
    public int Revision { get; init; }
    public List<string> Installed { get; } = new();
    public List<string> Removed { get; } = new();
    public List<string> Warnings { get; } = new();
    public bool Changed => Installed.Count > 0 || Removed.Count > 0;
}

public sealed class ForeignLoaderException(string gameDir) : Exception(
    $"PEAK already has a mod loader installed in its game folder ({gameDir}) that PeakPack didn't put there. " +
    "PeakPack can move it to a backup folder (nothing is deleted) and take over.")
{
    public string GameDir { get; } = gameDir;
}

/// <summary>
/// Makes the profile match the manifest exactly: installs/updates BepInEx and every listed package/file,
/// removes anything no longer listed, verifies hashes, and (re)writes the two game-folder proxy files.
/// Idempotent - running it twice in a row does nothing the second time.
/// </summary>
public sealed class Installer(AppPaths paths, Downloader downloader)
{
    public sealed record LoadedManifest(PackManifest Manifest, string Location, bool Signed);

    /// <summary>Downloads (or reads) the manifest and checks its signature if a public key is configured.</summary>
    public async Task<LoadedManifest> LoadManifestAsync(string location, string? publicKey, CancellationToken ct = default)
    {
        var bytes = await downloader.GetSmallAsync(location, ct);
        bool signed = false;
        if (!string.IsNullOrWhiteSpace(publicKey))
        {
            var sigBytes = await downloader.GetSmallAsync(location + ".sig", ct, 4096);
            if (!ManifestSigner.Verify(bytes, Encoding.ASCII.GetString(sigBytes), publicKey))
                throw new SecurityException("The mod list's signature is invalid, so it was NOT installed. Tell the host - the download may have been tampered with.");
            signed = true;
        }
        var m = PackManifest.Parse(Encoding.UTF8.GetString(bytes));
        return new LoadedManifest(m, location, signed);
    }

    /// <summary>What would change if this manifest were applied (for "Update available: 2 mods changed").</summary>
    public List<PackDiff.Change> PendingChanges(PackManifest m) => PackDiff.Compare(LoadInstalledManifest(paths), m);

    public static PackManifest? LoadInstalledManifest(AppPaths paths)
    {
        try { return File.Exists(paths.InstalledManifestPath) ? PackManifest.Parse(File.ReadAllText(paths.InstalledManifestPath)) : null; }
        catch (Exception ex) { paths.Log("installed-manifest.json unreadable: " + ex.Message); return null; }
    }

    public async Task<SyncResult> SyncAsync(LoadedManifest lm, string gameDir, bool adoptForeignLoader,
        IProgress<SyncProgress>? progress = null, CancellationToken ct = default, SyncOptions? options = null)
    {
        options ??= new SyncOptions();
        var m = lm.Manifest;
        var state = InstallState.Load(paths);
        var result = new SyncResult { Revision = m.Revision };

        if (!GameFolder.LooksLikePeak(gameDir))
            throw new DirectoryNotFoundException($"'{gameDir}' doesn't look like the PEAK folder (no PEAK.exe / PEAK_Data).");
        if (lm.Signed && m.Revision < state.InstalledRevision)
            throw new SecurityException($"The host's mod list (revision {m.Revision}) is older than what you have (revision {state.InstalledRevision}). Refusing to downgrade.");

        // 0. Game folder: refuse to silently clobber someone else's loader.
        var insp = GameFolder.Inspect(gameDir, state);
        if (options.ManageGameFolder && insp.HasForeignLoader)
        {
            if (!adoptForeignLoader) throw new ForeignLoaderException(gameDir);
            state.BackupDir = GameFolder.BackupForeignLoader(gameDir, paths);
            result.Warnings.Add($"Moved the old mod loader out of the PEAK folder to {state.BackupDir}");
        }

        Directory.CreateDirectory(paths.BepInExDir);
        int steps = m.Packages.Count + m.Files.Count + 2, step = 0;
        void Report(string msg, bool dl = false) => progress?.Report(new SyncProgress(msg, (double)step / steps, dl));

        // 1. Loader (BepInEx) into the profile.
        Report("Checking BepInEx...");
        if (!string.Equals(state.LoaderId, m.Loader.Id, StringComparison.OrdinalIgnoreCase) || !File.Exists(paths.PreloaderPath)
            || !File.Exists(Path.Combine(paths.LoaderStoreDir, GameFolder.ProxyDll)))
        {
            var zipPath = await FetchAsync(m.Loader.Url, m.Loader.Sha256, lm.Location, $"Downloading BepInEx ({m.Loader.Id})", Report, ct);
            InstallLoader(zipPath, state);
            state.LoaderId = m.Loader.Id;
            result.Installed.Add(m.Loader.Id);
            state.Save(paths);
        }
        step++;

        // 2. Remove packages that are gone or changed version.
        var desired = m.Packages.ToDictionary(p => PackageId.Parse(p.Id).FullName, p => p, StringComparer.OrdinalIgnoreCase);
        foreach (var installedId in state.Packages.Keys.ToList())
        {
            var full = PackageId.Parse(installedId).FullName;
            if (desired.TryGetValue(full, out var want) && want.Id.Equals(installedId, StringComparison.OrdinalIgnoreCase)
                && state.Packages[installedId].All(f => File.Exists(SafePath.Combine(paths.BepInExDir, f))))
                continue; // present, same version, files intact
            RemovePackage(installedId, state);
            if (!desired.ContainsKey(full)) result.Removed.Add(installedId);
        }
        state.Save(paths);

        // 3. Install missing packages.
        foreach (var p in m.Packages)
        {
            ct.ThrowIfCancellationRequested();
            if (!state.Packages.ContainsKey(p.Id))
            {
                var zip = await FetchAsync(p.Url, p.Sha256, lm.Location, $"Downloading {p.Id}", Report, ct);
                InstallPackage(zip, PackageId.Parse(p.Id), p.Id, state);
                result.Installed.Add(p.Id);
                state.Save(paths);
            }
            step++;
        }

        // 4. Loose files (Joshua's own DLLs / configs).
        var wantedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var f in m.Files)
        {
            ct.ThrowIfCancellationRequested();
            var dest = SafePath.Combine(paths.BepInExDir, f.Path);
            if (f.Overwrite == OverwriteMode.Always) wantedFiles.Add(f.Path);
            bool need = f.Overwrite == OverwriteMode.IfMissing
                ? !File.Exists(dest)
                : !File.Exists(dest) || Downloader.Sha256OfFile(dest) != f.Sha256.ToLowerInvariant();
            if (need)
            {
                var src = await FetchAsync(f.Url, f.Sha256, lm.Location, $"Downloading {f.Id} ({Path.GetFileName(f.Path)})", Report, ct);
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                File.Copy(src, dest, true);
                result.Installed.Add($"{f.Id} {f.Version} ({f.Path})".Replace("  ", " "));
            }
            if (f.Overwrite == OverwriteMode.Always) state.Files[f.Path] = f.Sha256.ToLowerInvariant();
            step++;
        }
        foreach (var old in state.Files.Keys.Where(k => !wantedFiles.Contains(k)).ToList())
        {
            var path = SafePath.Combine(paths.BepInExDir, old);
            if (File.Exists(path)) File.Delete(path);
            DeleteEmptyParents(Path.GetDirectoryName(path)!);
            state.Files.Remove(old);
            result.Removed.Add(old);
        }

        // 5. Strict mode: plugins/ and patchers/ contain exactly what the manifest says - nothing else.
        if (options.Strict) result.Removed.AddRange(RemoveUnmanaged(m, state));

        // 6. Game folder proxy files (enabled=false => Steam launches stay vanilla).
        if (options.ManageGameFolder)
        {
            Report("Preparing the game folder...");
            GameFolder.ApplyProxy(gameDir, paths, state);
        }
        step++;

        // 7. What the in-game companion reads (pack id + revision + lobby settings), and the applied manifest
        //    (so the next check can say exactly what changed).
        PackInfo.From(m, options.ShortcutName).Save(paths.PackInfoPath);
        File.WriteAllText(paths.InstalledManifestPath, m.ToJson());

        state.GameDir = gameDir;
        state.ManifestUrl = lm.Location;
        state.InstalledRevision = m.Revision;
        state.PackName = m.PackName;
        state.ModsRequiredToJoin = m.ModsRequiredToJoin;
        state.PackGameVersion = m.GameVersion;
        state.LastSyncTime = DateTimeOffset.Now;
        state.Save(paths);
        progress?.Report(new SyncProgress(result.Changed ? $"Updated to revision {m.Revision}." : "Mods are up to date.", 1));
        paths.Log($"Sync rev {m.Revision}: +{result.Installed.Count} -{result.Removed.Count} {string.Join(", ", result.Installed.Concat(result.Removed.Select(r => "-" + r)))}");
        return result;
    }

    async Task<string> FetchAsync(string url, string sha, string manifestLocation, string label, Action<string, bool> report, CancellationToken ct)
    {
        var resolved = Downloader.ResolveRelative(manifestLocation, url);
        if (!File.Exists(downloader.CachePathFor(sha))) report(label, true);
        var (path, _, _) = await downloader.GetVerifiedAsync(resolved, sha, null, ct);
        return path;
    }

    void InstallLoader(string zipPath, InstallState state)
    {
        using var zip = ZipFile.OpenRead(zipPath);
        // The pack keeps everything under one folder (BepInExPack_PEAK/); find it via winhttp.dll.
        var proxy = zip.Entries.FirstOrDefault(e => e.Name.Equals(GameFolder.ProxyDll, StringComparison.OrdinalIgnoreCase))
                    ?? throw new InvalidDataException("The BepInEx pack doesn't contain winhttp.dll.");
        var prefix = proxy.FullName[..^proxy.Name.Length];

        // Remove the old loader's core files (but not core/<Package> folders that belong to mods).
        foreach (var f in state.LoaderFiles) TryDelete(SafePath.Combine(paths.BepInExDir, f));
        state.LoaderFiles.Clear();

        var written = new List<string>();
        Directory.CreateDirectory(paths.LoaderStoreDir);
        foreach (var e in zip.Entries)
        {
            if (!e.FullName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) || e.FullName.EndsWith('/')) continue;
            var rel = SafePath.NormalizeRelative(e.FullName[prefix.Length..]);
            if (rel.StartsWith("BepInEx/", StringComparison.OrdinalIgnoreCase))
            {
                var inner = rel["BepInEx/".Length..];
                var dest = SafePath.Combine(paths.BepInExDir, inner);
                if (inner.StartsWith("config/", StringComparison.OrdinalIgnoreCase) && File.Exists(dest)) continue; // keep friend's BepInEx.cfg
                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                e.ExtractToFile(dest, true);
                if (!inner.StartsWith("config/", StringComparison.OrdinalIgnoreCase)) written.Add(inner);
            }
            else if (!rel.Contains('/'))
            {
                // winhttp.dll, doorstop_config.ini, .doorstop_version - kept pristine in the profile;
                // GameFolder.ApplyProxy copies winhttp.dll into the game folder and writes its own ini.
                e.ExtractToFile(Path.Combine(paths.LoaderStoreDir, e.Name), true);
            }
        }
        foreach (var d in new[] { "plugins", "patchers", "config" }) Directory.CreateDirectory(Path.Combine(paths.BepInExDir, d));
        state.LoaderFiles = written; // so a loader upgrade removes stale core files
    }

    void InstallPackage(string zipPath, PackageId id, string fullId, InstallState state)
    {
        using var zip = ZipFile.OpenRead(zipPath);
        var written = new List<string>();
        foreach (var plan in PackageLayout.Plan(zip, id.FullName))
        {
            var dest = SafePath.Combine(paths.BepInExDir, plan.Dest);
            if (plan.IsConfig && File.Exists(dest)) continue; // never overwrite a friend's tweaked config
            Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
            zip.GetEntry(plan.ZipEntry)!.ExtractToFile(dest, true);
            if (!plan.IsConfig) written.Add(plan.Dest);
        }
        state.Packages[fullId] = written;
    }

    void RemovePackage(string installedId, InstallState state)
    {
        var full = PackageId.Parse(installedId).FullName;
        foreach (var dir in PackageLayout.OwnedDirs(full))
        {
            var d = SafePath.Combine(paths.BepInExDir, dir);
            if (Directory.Exists(d)) Directory.Delete(d, true);
        }
        if (state.Packages.Remove(installedId, out var files))
            foreach (var f in files) TryDelete(SafePath.Combine(paths.BepInExDir, f));
        paths.Log($"Removed package {installedId}");
    }

    IEnumerable<string> RemoveUnmanaged(PackManifest m, InstallState state)
    {
        var removed = new List<string>();
        var allowedTop = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var p in m.Packages) allowedTop.Add(PackageId.Parse(p.Id).FullName);
        foreach (var f in m.Files)
        {
            var segs = f.Path.Split('/');
            if (segs.Length >= 2) allowedTop.Add(segs[0] + "/" + segs[1]);
        }
        foreach (var area in new[] { "plugins", "patchers" })
        {
            var dir = Path.Combine(paths.BepInExDir, area);
            if (!Directory.Exists(dir)) continue;
            foreach (var entry in Directory.EnumerateFileSystemEntries(dir))
            {
                var name = Path.GetFileName(entry);
                if (allowedTop.Contains(name) || allowedTop.Contains(area + "/" + name)) continue;
                if (Directory.Exists(entry)) Directory.Delete(entry, true); else File.Delete(entry);
                removed.Add($"{area}/{name} (not in the host's list)");
                paths.Log($"Removed unmanaged {entry}");
            }
        }
        return removed;
    }

    static void TryDelete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch (IOException) { }
    }

    static void DeleteEmptyParents(string dir)
    {
        try
        {
            while (Directory.Exists(dir) && !Directory.EnumerateFileSystemEntries(dir).Any()
                   && !new[] { "plugins", "patchers", "config", "BepInEx" }.Contains(Path.GetFileName(dir), StringComparer.OrdinalIgnoreCase))
            {
                Directory.Delete(dir);
                dir = Path.GetDirectoryName(dir)!;
            }
        }
        catch (IOException) { }
    }
}
