using System.Text;
using System.Text.Json;

namespace PeakPack.Core;

/// <summary>
/// Live updates of the host's own mods in a test lobby (friend side). Started by the in-game companion as
/// "PeakPack.exe --hot-update" when the lobby host announces a new revision; the companion itself never downloads,
/// verifies or swaps code. Rules, all enforced here:
///   - the friend opted in (InstallState.AcceptLiveUpdates) and the pack is a test lobby (manifest.lobby.testLobby);
///   - the manifest comes from the URL built into the app and its ECDSA signature verifies with the built-in key
///     (an unsigned manifest is never applied, even in test setups without a key);
///   - every file is SHA-256-pinned and downloaded only from the allowlisted hosts;
///   - only files marked hotReload (the host's own reload-safe mods, .dll under plugins/) may change. Any other
///     difference (Thunderstore packages, BepInEx, configs, removed files) means "restart from the PEAK (Modded) icon"
///     and nothing is applied;
///   - the previous build is kept so the friend can undo the update.
/// The new DLL is written in place, which is exactly what Hamunii AutoReload watches for (file changed event), so it
/// hot-loads the new build the same way it does for Joshua's own Deploy builds.
/// </summary>
public static class HotUpdater
{
    public static class Status
    {
        public const string Applied = "applied", RestartNeeded = "restart-needed", NotAllowed = "not-allowed",
            UpToDate = "up-to-date", Failed = "failed", RolledBack = "rolled-back";
    }

    public sealed class Result
    {
        public string Status { get; set; } = HotUpdater.Status.Failed;
        public int Revision { get; set; }
        public int FromRevision { get; set; }
        /// <summary>Friendly titles of the mods that changed ("Scoutmaster Mode").</summary>
        public List<string> Mods { get; set; } = new();
        /// <summary>"pluginGuid|version|plugins/..path.dll" of each new build, read from the DLL. The companion checks that a NEW instance of
        /// each of these plugins is running (AutoReload actually reloaded it) before it says "updated".</summary>
        public List<string> Plugins { get; set; } = new();
        public string Message { get; set; } = "";
        public DateTimeOffset Time { get; set; } = DateTimeOffset.Now;
    }

    sealed class RollbackInfo
    {
        public int FromRevision { get; set; }
        public int ToRevision { get; set; }
        public List<string> Mods { get; set; } = new();
        /// <summary>profile-relative path -> backup file (null = the file didn't exist before).</summary>
        public Dictionary<string, string?> Files { get; set; } = new();
        public Dictionary<string, string> PreviousHashes { get; set; } = new();
    }

    static string LastRollback(AppPaths p) => Path.Combine(p.RollbackDir, "last.json");
    static string PrevManifest(AppPaths p) => Path.Combine(p.RollbackDir, "previous-manifest.json");

    public static bool CanRollBack(AppPaths p) => File.Exists(LastRollback(p));

    /// <summary>The platform settings PeakPack itself acts on (launch args, Mac files), as JSON. The Mac front end's own
    /// pins (runtime, frontEnd) are left out: they change nothing PeakPack installs, so they never force a restart.</summary>
    static string InstallRelevantPlatforms(PackManifest m)
    {
        var mac = m.Platforms?.Mac;
        if (mac is null) return JsonSerializer.Serialize(m.Platforms, PackManifest.JsonOptions);
        var copy = new MacSettings { ExtraArgs = mac.ExtraArgs, Files = mac.Files, MinFrontEnd = mac.MinFrontEnd };
        return JsonSerializer.Serialize(new PlatformSettings { Mac = copy }, PackManifest.JsonOptions);
    }

    /// <summary>Works out what a live update to <paramref name="m"/> would do, without changing anything.</summary>
    public static (string Status, List<FileEntry> Files, string Message) Plan(PackManifest? installed, PackManifest m, InstallState state)
    {
        if (!state.AcceptLiveUpdates) return (Status.NotAllowed, [], "Live updates are off in PeakPack.");
        if (m.Lobby?.TestLobby != true) return (Status.NotAllowed, [], "This pack isn't in test-lobby mode.");
        if (installed is null) return (Status.RestartNeeded, [], "No installed pack to update.");
        if (m.Revision <= state.InstalledRevision) return (Status.UpToDate, [], $"Already on revision {state.InstalledRevision}.");
        if (!string.Equals(installed.Loader.Id, m.Loader.Id, StringComparison.OrdinalIgnoreCase)
            || !installed.Packages.Select(p => p.Id).ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(m.Packages.Select(p => p.Id)))
            return (Status.RestartNeeded, [], "Thunderstore mods or BepInEx changed.");
        if (InstallRelevantPlatforms(installed) != InstallRelevantPlatforms(m))
            return (Status.RestartNeeded, [], "Platform settings changed (e.g. Mac defaults or launch options).");
        var before = installed.Files.ToDictionary(f => f.Path, StringComparer.OrdinalIgnoreCase);
        var after = m.Files.ToDictionary(f => f.Path, StringComparer.OrdinalIgnoreCase);
        if (before.Keys.Any(k => !after.ContainsKey(k))) return (Status.RestartNeeded, [], "A mod was removed (can't be unloaded live).");
        var changed = new List<FileEntry>();
        foreach (var f in m.Files)
        {
            if (before.TryGetValue(f.Path, out var old) && old.Sha256.Equals(f.Sha256, StringComparison.OrdinalIgnoreCase)) continue;
            bool hotOk = f.HotReload && f.Path.StartsWith("plugins/", StringComparison.OrdinalIgnoreCase)
                         && f.Path.EndsWith(".dll", StringComparison.OrdinalIgnoreCase) && f.Id != PublishConfig.CompanionId
                         && (old is null || old.HotReload);
            if (!hotOk) return (Status.RestartNeeded, [], $"{f.Title ?? f.Id} isn't marked reload-safe.");
            changed.Add(f);
        }
        return changed.Count == 0 ? (Status.UpToDate, [], "No mod files changed.") : (Status.Applied, changed, "");
    }

    public static async Task<Result> ApplyAsync(AppPaths paths, Downloader dl, string manifestLocation, string? publicKey,
        string shortcutName = "PEAK (Modded)", CancellationToken ct = default)
    {
        var state = InstallState.Load(paths);
        var r = new Result { FromRevision = state.InstalledRevision, Revision = state.InstalledRevision };
        try
        {
            if (!state.AcceptLiveUpdates) { r.Status = Status.NotAllowed; r.Message = "Live updates are off in PeakPack."; return Done(paths, r); }
            if (string.IsNullOrWhiteSpace(publicKey))
            {
                r.Status = Status.NotAllowed; r.Message = "This PeakPack has no signing key built in, so live updates are disabled.";
                return Done(paths, r);
            }
            var inst = new Installer(paths, dl);
            var lm = await inst.LoadManifestAsync(manifestLocation, publicKey, ct); // throws if the signature is wrong
            if (!lm.Signed) throw new SecurityException("The mod list isn't signed; live updates need a signed mod list.");
            var m = lm.Manifest;
            r.Revision = m.Revision;
            var installed = Installer.LoadInstalledManifest(paths);
            var (status, files, msg) = Plan(installed, m, state);
            r.Status = status; r.Message = msg;
            if (status != Status.Applied) return Done(paths, r);

            // Download + verify everything first; only then touch the plugins folder.
            var fetched = new List<(FileEntry F, string Src, string Dest)>();
            foreach (var f in files)
            {
                var (src, _, _) = await dl.GetVerifiedAsync(Downloader.ResolveRelative(lm.Location, f.Url), f.Sha256, null, ct);
                fetched.Add((f, src, SafePath.Combine(paths.BepInExDir, f.Path)));
            }

            // Keep the previous builds for "undo".
            if (Directory.Exists(paths.RollbackDir)) Directory.Delete(paths.RollbackDir, true);
            Directory.CreateDirectory(paths.RollbackDir);
            var rb = new RollbackInfo { FromRevision = state.InstalledRevision, ToRevision = m.Revision };
            File.WriteAllText(PrevManifest(paths), installed!.ToJson());
            int n = 0;
            foreach (var (f, _, dest) in fetched)
            {
                string? backup = null;
                if (File.Exists(dest))
                {
                    backup = Path.Combine(paths.RollbackDir, $"{n++}-{Path.GetFileName(dest)}");
                    Setup.CopyBytesOnly(dest, backup);
                }
                rb.Files[f.Path] = backup;
                if (state.Files.TryGetValue(f.Path, out var h)) rb.PreviousHashes[f.Path] = h;
            }

            foreach (var (f, src, _) in fetched)
            {
                var title = f.Title ?? PackDiff.FriendlyFileTitle(f.Id);
                if (!r.Mods.Contains(title)) r.Mods.Add(title);
                var info = Hotfix.Inspect(src);
                if (info.PluginGuid is not null) r.Plugins.Add($"{info.PluginGuid}|{info.PluginVersion}|{f.Path}");
            }
            rb.Mods = r.Mods.ToList();
            // The undo record exists BEFORE any DLL is replaced, so a crash mid-way can still be undone.
            File.WriteAllText(LastRollback(paths), JsonSerializer.Serialize(rb, PackManifest.JsonOptions));

            var written = new List<(string Rel, string Dest)>();
            try
            {
                foreach (var (f, src, dest) in fetched)
                {
                    written.Add((f.Path, dest)); // before writing: a half-written (truncated) file must be restored too
                    WriteInPlace(src, dest);
                }
            }
            catch (Exception ex)
            {
                // Put back what was already replaced; nothing else changed (state, manifest, pack-info untouched).
                bool allRestored = true;
                foreach (var (rel, dest) in written)
                {
                    try
                    {
                        if (rb.Files[rel] is { } backup && File.Exists(backup))
                        {
                            // Unchanged (e.g. the write failed because the file is locked): nothing to put back.
                            if (File.Exists(dest) && Downloader.Sha256OfFile(dest) == Downloader.Sha256OfFile(backup)) continue;
                            WriteInPlace(backup, dest);
                        }
                        else if (File.Exists(dest)) File.Delete(dest);
                    }
                    catch (Exception rex) { allRestored = false; paths.Log($"Live update: couldn't restore {rel}: {rex.Message}"); }
                }
                if (!allRestored)
                    throw new IOException($"Couldn't replace a mod file ({ex.Message}) and couldn't put everything back. " +
                                          $"The previous builds are kept in {paths.RollbackDir}; restart PEAK from the icon to repair.", ex);
                try { Directory.Delete(paths.RollbackDir, true); } catch { }
                throw new IOException($"Couldn't replace a mod file ({ex.Message}); the previous builds were put back.", ex);
            }
            foreach (var (f, _, _) in fetched) state.Files[f.Path] = f.Sha256.ToLowerInvariant();

            state.InstalledRevision = m.Revision;
            state.LastSyncTime = DateTimeOffset.Now;
            state.Save(paths);
            File.WriteAllText(paths.InstalledManifestPath, m.ToJson());
            PackInfo.From(m, shortcutName, state, paths).Save(paths.PackInfoPath);
            r.Message = $"Updated {string.Join(", ", r.Mods)} to revision {m.Revision}.";
            paths.Log($"Live update {r.FromRevision} -> {m.Revision}: {string.Join(", ", fetched.Select(x => x.F.Path))}");
            return Done(paths, r);
        }
        catch (Exception ex)
        {
            paths.Log("Live update failed: " + ex);
            r.Status = Status.Failed;
            r.Message = ex.Message;
            return Done(paths, r);
        }
    }

    /// <summary>Puts the previous builds back (AutoReload loads them again) and returns to the previous revision.
    /// The next normal start from the PEAK (Modded) icon updates to the host's latest revision again.</summary>
    public static Result RollBack(AppPaths paths, string shortcutName = "PEAK (Modded)")
    {
        var r = new Result();
        try
        {
            if (!File.Exists(LastRollback(paths))) { r.Status = Status.Failed; r.Message = "There's no live update to undo."; return Done(paths, r); }
            var rb = JsonSerializer.Deserialize<RollbackInfo>(File.ReadAllText(LastRollback(paths)), PackManifest.JsonOptions)!;
            var state = InstallState.Load(paths);
            foreach (var (rel, backup) in rb.Files)
            {
                var dest = SafePath.Combine(paths.BepInExDir, rel);
                if (backup is not null && File.Exists(backup)) WriteInPlace(backup, dest);
                else if (File.Exists(dest)) File.Delete(dest); // it was new in the update (AutoReload can't unload it until restart)
                if (rb.PreviousHashes.TryGetValue(rel, out var h)) state.Files[rel] = h; else state.Files.Remove(rel);
            }
            state.InstalledRevision = rb.FromRevision;
            state.Save(paths);
            if (File.Exists(PrevManifest(paths))) File.Copy(PrevManifest(paths), paths.InstalledManifestPath, true);
            PackInfo.Refresh(paths, shortcutName);
            Directory.Delete(paths.RollbackDir, true);
            r.Status = Status.RolledBack; r.Revision = rb.FromRevision; r.FromRevision = rb.ToRevision; r.Mods = rb.Mods;
            r.Message = $"Went back to the previous build of {string.Join(", ", rb.Mods)} (revision {rb.FromRevision}).";
            paths.Log("Live update undone: " + r.Message);
        }
        catch (Exception ex) { paths.Log("Undo failed: " + ex); r.Status = Status.Failed; r.Message = ex.Message; }
        return Done(paths, r);
    }

    /// <summary>Overwrites the file's content in place (a "changed" event for AutoReload, like Joshua's Deploy copy).
    /// If the file is locked, falls back to rename-old + move-new (a "renamed" event, also watched by AutoReload).</summary>
    static void WriteInPlace(string src, string dest)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
        var old = dest + ".pp-old";
        try { if (File.Exists(old)) File.Delete(old); } catch (IOException) { }
        try { Setup.CopyBytesOnly(src, dest); } // src is the verified cache file; no temp file in the watched folder
        catch (IOException)
        {
            var tmp = $"{dest}.pp-new-{Guid.NewGuid():N}";   // unique, and not a .dll, so AutoReload ignores it
            try
            {
                Setup.CopyBytesOnly(src, tmp);
                if (File.Exists(old)) old = $"{dest}.pp-old-{Guid.NewGuid():N}";
                File.Move(dest, old);
                File.Move(tmp, dest);                        // AutoReload ignores renames; the companion then queues the reload itself
            }
            finally { try { if (File.Exists(tmp)) File.Delete(tmp); } catch { } }
        }
    }

    static Result Done(AppPaths paths, Result r)
    {
        try
        {
            r.Time = DateTimeOffset.Now;
            Directory.CreateDirectory(Path.GetDirectoryName(paths.HotResultPath)!);
            var tmp = paths.HotResultPath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(r, PackManifest.JsonOptions), new UTF8Encoding(false));
            File.Move(tmp, paths.HotResultPath, true);
        }
        catch { /* the companion just won't show a notice */ }
        return r;
    }
}
