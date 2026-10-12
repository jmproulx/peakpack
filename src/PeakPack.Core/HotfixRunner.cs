namespace PeakPack.Core;

/// <summary>
/// "Hotfix": publish a new build of ONE of the host's own mods as the next pack revision, then tell the lobby.
/// Shared by the CLI (agents) and the Host window. A dry run unless <see cref="Options.Publish"/>:
///   1. find the mod in publish.json; check the DLL (managed, [BepInPlugin], OnDestroy, embedded PDB);
///      a build that isn't reload-safe is published as restart-only;
///   2. keep the exact bytes under &lt;work&gt;\builds, bump the mod's version, set the changelog line;
///   3. normal pipeline: prepare + gh release rev-N --latest (with the stable PeakPack.exe, so friends' links stay intact);
///   4. after a real release: save publish.json, stamp the host's game (pack-info + companion) and drop a
///      "hot-update" command for the host's companion, which announces revision N to the lobby.
/// </summary>
public sealed class HotfixRunner(Action<string> log)
{
    public sealed record Options(string ConfigPath, string Mod, string? Dll = null, string? Version = null, string? Notes = null,
        bool Rollback = false, bool Publish = false, string? WorkDir = null, string? HostBepInEx = null, string? PreviousPath = null,
        string? Repo = null);

    public sealed record Outcome(int ExitCode, PublishPipeline.Prepared? Prepared, bool Live, string? CommandFile, string Summary);

    public async Task<Outcome> RunAsync(Options o, ThunderstoreIndex index, Downloader dl, CancellationToken ct = default)
    {
        var cfg = PublishConfig.Load(o.ConfigPath);
        var work = o.WorkDir ?? PublishPipeline.DefaultWorkDir;
        var cf = Hotfix.FindMod(cfg, o.Mod) ?? throw new ArgumentException(
            $"'{o.Mod}' isn't one of your own builds in {o.ConfigPath}. Known: " +
            string.Join(", ", cfg.CustomFiles.Where(c => c.Dest.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).Select(c => c.Id)) +
            ". Add it in the Host window (Own builds) first.");
        var title = cf.Title ?? PackDiff.FriendlyFileTitle(cf.Id);

        var dll = o.Rollback
            ? Hotfix.PreviousBuild(work, cf) ?? throw new FileNotFoundException($"No earlier released build of {title} in {Path.Combine(work, "history")}.")
            : o.Dll ?? cf.Source;
        if (!File.Exists(dll)) throw new FileNotFoundException($"Build not found: {dll}");

        var check = Hotfix.Inspect(dll);
        log($"{title}: {dll}");
        log($"  plugin {check.PluginGuid} \"{check.PluginName}\" {check.PluginVersion}; embedded PDB: {check.HasEmbeddedPdb}; OnDestroy: {check.HasOnDestroy}");
        if (!check.IsManaged) throw new InvalidDataException("That file isn't a .NET plugin DLL.");
        bool live = cf.ReloadSafe && check.LiveReloadOk;
        if (cf.ReloadSafe && !check.LiveReloadOk) log("  NOT reload-safe for this build (" + string.Join(" ", check.Problems) + ") -> published as restart-only.");
        else if (!cf.ReloadSafe) log("  Not marked reload-safe in publish.json -> friends get it at their next start.");
        if (live && cfg.Lobby?.TestLobby != true) log("  Test lobby is off -> friends get it at their next start (turn on \"Test lobby\" for live updates).");
        cf.ReloadSafe = live;

        var sha8 = Downloader.Sha256OfFile(dll)[..8];
        var keep = Path.Combine(work, "builds", $"{cf.Id}-{sha8}{Path.GetExtension(dll)}");
        Directory.CreateDirectory(Path.GetDirectoryName(keep)!);
        if (!File.Exists(keep)) File.Copy(dll, keep);
        cf.Source = keep;
        cf.Version = o.Version ?? Hotfix.BumpVersion(cf.Version);
        cfg.Notes = o.Notes ?? (o.Rollback ? $"Rolled back {title} to the previous build." : $"Hotfix: {title} {cf.Version}");
        log($"  version {cf.Version}; notes \"{cfg.Notes}\"");

        var pipe = new PublishPipeline(log);
        var prev = await pipe.LoadPreviousAsync(cfg, work, dl, o.PreviousPath, ct);
        var p = await pipe.PrepareAsync(cfg, work, index, dl, prev, ct);
        log($"Revision {p.Manifest.Revision}: {PackDiff.Summary(p.Changes)}");
        foreach (var c in p.Changes) log("  " + c);
        var repo = o.Repo ?? cfg.GithubRepo ?? throw new ArgumentException("githubRepo isn't set in publish.json");
        var rc = await pipe.ReleaseAsync(p, repo, work, dryRun: !o.Publish, ct);
        bool liveForFriends = live && cfg.Lobby?.TestLobby == true;
        var what = liveForFriends ? "live update for friends who opted in" : "restart notice (\"restart from the PEAK (Modded) icon\")";
        if (rc != 0) return new(rc, p, liveForFriends, null, $"Revision {p.Manifest.Revision} wasn't published.");

        var bep = o.HostBepInEx ?? (cfg.GameDir is { } gd && Directory.Exists(Path.Combine(gd, "BepInEx")) ? Path.Combine(gd, "BepInEx") : null);
        if (!o.Publish)
            return new(0, p, liveForFriends, null,
                $"DRY RUN: would publish revision {p.Manifest.Revision}, save {o.ConfigPath}, stamp {bep ?? "(no host BepInEx folder)"} and tell the lobby ({what}).");

        cfg.Save(o.ConfigPath);
        string? cmd = null;
        if (bep is not null)
        {
            pipe.StampHost(p.Manifest, p.StagingDir, bep);
            cmd = LobbyCommands.Write(bep, LobbyCommands.HotUpdate, p.Manifest.Revision);
            log($"Told your lobby about revision {p.Manifest.Revision} ({what}). Your game must be running and hosting.");
        }
        else log("No host BepInEx folder (set gameDir in publish.json); friends get it at their next start.");
        return new(0, p, liveForFriends, cmd, $"Published revision {p.Manifest.Revision} ({title} {cf.Version}).");
    }
}
