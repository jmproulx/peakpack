using PeakPack.Core;

// PeakPack command line: Joshua's publisher tool, plus headless versions of every friend-side action
// (used for testing against the sandbox). Friends use the GUI app (PeakPack.exe) instead.

var a = new Args(args);
var cmd = a.Positional.FirstOrDefault()?.ToLowerInvariant();
try
{
    return cmd switch
    {
        "scan" => await Scan(a),
        "publish" => await Publish(a),
        "keygen" => KeyGen(a),
        "prepare" => await Prepare(a, release: false),
        "release" => await Prepare(a, release: true),
        "stamp" => Stamp(a),
        "check" => await Check(a),
        "selfinstall" => SelfInstall(a),
        "hotfix" => await HotfixCmd(a),
        "lobby" => LobbyCmd(a),
        "hot-update" => await HotUpdateCmd(a),
        "hot-rollback" => HotRollbackCmd(a),
        "options" => OptionsCmd(a),
        "inspect" => InspectCmd(a),
        "install" or "sync" => await Install(a),
        "launch" => await Launch(a),
        "status" => Status(a),
        "uninstall" => Uninstall(a),
        "locate" => Locate(),
        _ => Help(),
    };
}
catch (Exception ex)
{
    Console.Error.WriteLine("ERROR: " + ex.Message);
    return 1;
}

static int Help()
{
    Console.WriteLine("""
    PeakPack CLI

    Publisher (Joshua):
      scan    --plugins <BepInEx\plugins dir> [--out publish.json]   identify Thunderstore mods by hash, draft publish.json
      publish --config publish.json --out <dir> [--previous <manifest.json>]
                                                    resolve deps, pin versions + SHA-256, write manifest.json (+ .sig) and assets
      keygen  --out <private-key.pem>                create a signing key; prints the public key for pack.config.json
      prepare --config publish.json [--work D] [--previous manifest.json]
                                                    build the next revision into <work>\staging and list what friends will get
      release --config publish.json [--work D] [--repo owner/name] [--dry-run] [--stamp <host BepInEx dir>]
                                                    prepare + upload as GitHub release rev-N (gh), keep a copy in <work>\current;
                                                    --stamp also updates the host's own companion/pack-info after the release
      stamp   --manifest <dir with manifest.json> --bepinex <BepInEx dir>
                                                    write the companion + pack-info.json into the host's own game
      (work dir default: %LOCALAPPDATA%\PeakPack-publisher)

    Live testing with friends (host):
      hotfix  --mod <name> [--dll <new build>] [--version V] [--notes "..."] [--config publish.json] [--work D]
              [--rollback] [--publish] [--notify <host BepInEx dir>]
                  publish a new build of ONE of your own mods as the next pack revision. DRY RUN unless --publish.
                  After a real publish: updates your game's pack-info and tells your lobby (test lobby: live update
                  for friends who opted in; everyone else: restart from the PEAK (Modded) icon).
                  --rollback republishes the previous build of that mod.
      lobby   snapshot|hot-update [--revision N] [--bepinex <host BepInEx dir>] [--config publish.json]
                  snapshot: ask everyone in your lobby for fresh logs (they land in <BepInEx>\PeakPack-remote-logs\)
                  hot-update: announce revision N to your lobby

    Friend side (normally run by the app / the in-game companion):
      hot-update   [--manifest M] [--data-dir D] [--allow-local] [--public-key K]   apply a live update if allowed
      hot-rollback [--data-dir D]                                                  undo the last live update
      options      [--diagnostics on|off] [--live-updates on|off] [--data-dir D]   friend consent switches
      inspect <dll>...                     plugin GUID/version, embedded PDB, OnDestroy (reload-safe check)

    Friend actions (headless; the GUI does the same):
      install   --manifest <url|path> [--game-dir D] [--data-dir D] [--adopt] [--allow-local] [--public-key K]
                [--keep-extra] [--no-game-folder]   host/dev profile: keep extra plugins / never touch the game folder
      check     [--manifest ...] [--data-dir D]     what an update would change ("Update available: 2 mods changed")
      selfinstall --exe <PeakPack.exe> [--data-dir D] [--shortcut-dir D] [--game-dir D]   first-run install of the app (testing)
      launch    --modded|--vanilla [--sync --manifest ...] [--method steam|direct|dry] [--game-dir D] [--data-dir D] [--no-proxy]
      status    [--game-dir D] [--data-dir D]
      uninstall [--game-dir D] [--data-dir D] [--shortcut-dir D]
      locate    show where Steam and PEAK were found
    """);
    return 0;
}

static string WorkDir(Args a) => a.Get("--work") ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PeakPack-publisher");

static async Task<ThunderstoreIndex> LoadIndex(Args a)
{
    var file = a.Get("--index") ?? Path.Combine(WorkDir(a), "peak-index.json");
    Console.WriteLine($"Loading Thunderstore index ({file})...");
    return await ThunderstoreIndex.LoadAsync(file, TimeSpan.FromHours(a.Has("--refresh") ? 0 : 6));
}

static async Task<int> Scan(Args a)
{
    var plugins = a.Require("--plugins");
    var index = await LoadIndex(a);
    using var dl = new Downloader(Path.Combine(WorkDir(a), "cache"));
    var pub = new Publisher(dl, index, Console.WriteLine);
    var (matched, unmatched) = await pub.ScanAsync(plugins);
    var cfg = new PublishConfig
    {
        Mods = matched.Where(m => index.Find(PackageId.Parse(m).FullName)?.IsHostOnly != true).ToList(),
        HostOnly = matched.Where(m => index.Find(PackageId.Parse(m).FullName)?.IsHostOnly == true).ToList(),
        CustomFiles = unmatched.Select(u => new PublishConfig.CustomFile
        {
            Id = "Custom-" + Path.GetFileNameWithoutExtension(u).Replace(".", "_"),
            Version = "1.0.0",
            Source = u,
            Dest = $"plugins/Custom-{Path.GetFileNameWithoutExtension(u).Replace(".", "_")}/{Path.GetFileName(u)}",
        }).ToList(),
    };
    var outPath = a.Get("--out") ?? "publish.json";
    File.WriteAllText(outPath, System.Text.Json.JsonSerializer.Serialize(cfg, PackManifest.JsonOptions));
    Console.WriteLine($"Wrote {outPath}. Mods tagged \"Host Only\" on Thunderstore were put in hostOnly; review the rest (tags are self-reported by authors).");
    return 0;
}

static async Task<int> Publish(Args a)
{
    var cfg = PublishConfig.Load(a.Require("--config"));
    var outDir = a.Require("--out");
    PackManifest? prev = null;
    var prevPath = a.Get("--previous") ?? Path.Combine(outDir, "manifest.json");
    if (File.Exists(prevPath)) prev = PackManifest.Parse(File.ReadAllText(prevPath));
    var index = await LoadIndex(a);
    using var dl = new Downloader(Path.Combine(WorkDir(a), "cache"));
    var m = await new Publisher(dl, index, Console.WriteLine).PublishAsync(cfg, outDir, prev);
    Console.WriteLine($"\nPublished revision {m.Revision} to {Path.GetFullPath(outDir)}");
    Console.WriteLine($"  loader: {m.Loader.Id}");
    foreach (var p in m.Packages) Console.WriteLine($"  {p.Id,-55} {p.Reason}");
    foreach (var f in m.Files) Console.WriteLine($"  {f.Id,-55} file {f.Path}");
    Console.WriteLine("Changes since previous:");
    foreach (var d in Publisher.Diff(prev, m)) Console.WriteLine("  " + d);
    Console.WriteLine("\nNext: upload everything in the output folder (see tools/publish-release.ps1).");
    return 0;
}

static int KeyGen(Args a)
{
    var outPath = a.Require("--out");
    if (File.Exists(outPath)) throw new IOException($"{outPath} exists; refusing to overwrite a signing key.");
    var (priv, pub) = ManifestSigner.GenerateKeyPair();
    File.WriteAllText(outPath, priv);
    Console.WriteLine($"Private key written to {outPath} (keep it secret, never commit it).");
    Console.WriteLine("Public key (put in pack.config.json \"publicKey\"):");
    Console.WriteLine(pub);
    return 0;
}

static (AppPaths Paths, string? GameDir) Ctx(Args a)
{
    var paths = new AppPaths(a.Get("--data-dir"));
    var state = InstallState.Load(paths);
    var game = a.Get("--game-dir") ?? state.GameDir ?? SteamLocator.FindGameDir();
    return (paths, game);
}

static async Task<int> Install(Args a)
{
    var (paths, game) = Ctx(a);
    if (game is null) throw new DirectoryNotFoundException("Couldn't find PEAK. Pass --game-dir.");
    var manifest = a.Get("--manifest") ?? InstallState.Load(paths).ManifestUrl ?? throw new ArgumentException("--manifest is required the first time");
    using var dl = new Downloader(paths.CacheDir) { AllowLocalFiles = a.Has("--allow-local") };
    var inst = new Installer(paths, dl);
    var lm = await inst.LoadManifestAsync(manifest, a.Get("--public-key"));
    Console.WriteLine($"{lm.Manifest.PackName} - revision {lm.Manifest.Revision}{(lm.Signed ? " (signature OK)" : "")}");
    var opts = new SyncOptions(Strict: !a.Has("--keep-extra"), ManageGameFolder: !a.Has("--no-game-folder"));
    var res = await inst.SyncAsync(lm, game, a.Has("--adopt"), new ConsoleProgress(), default, opts);
    foreach (var w in res.Warnings) Console.WriteLine("  ! " + w);
    foreach (var i in res.Installed) Console.WriteLine("  + " + i);
    foreach (var r in res.Removed) Console.WriteLine("  - " + r);
    Console.WriteLine(res.Changed ? $"Done. Now on revision {res.Revision}." : "Already up to date.");
    return 0;
}

static async Task<int> Launch(Args a)
{
    if (a.Has("--sync")) { var rc = await Install(a); if (rc != 0) return rc; }
    var (paths, game) = Ctx(a);
    if (game is null) throw new DirectoryNotFoundException("Couldn't find PEAK.");
    var mode = a.Has("--vanilla") ? LaunchMode.Vanilla : LaunchMode.Modded;
    var method = (a.Get("--method") ?? "steam") switch { "direct" => Launcher.Method.DirectExe, "dry" => Launcher.Method.DryRun, _ => Launcher.Method.Steam };
    var state = InstallState.Load(paths);
    // --no-proxy: never touch the game folder (real-PC test against a game folder that already has Doorstop).
    if (mode == LaunchMode.Modded && !a.Has("--no-proxy")) GameFolder.ApplyProxy(game, paths, state); // repair if r2modman/Gale overwrote it
    state.Save(paths);
    Console.WriteLine((method == Launcher.Method.DryRun ? "Would run: " : "Ran: ") + Launcher.Launch(mode, paths, state, game, method));
    return 0;
}

static async Task<PublishPipeline.Prepared> PrepareOnly(Args a, PublishConfig cfg, string work)
{
    var index = await LoadIndex(a);
    using var dl = new Downloader(Path.Combine(work, "cache"));
    var pipe = new PublishPipeline(Console.WriteLine);
    var prev = await pipe.LoadPreviousAsync(cfg, work, dl, a.Get("--previous"), default, a.Has("--first-publish"));
    var p = await pipe.PrepareAsync(cfg, work, index, dl, prev);
    Console.WriteLine();
    Console.WriteLine($"Revision {p.Manifest.Revision} staged in {p.StagingDir}");
    Console.WriteLine($"What friends will get ({PackDiff.Summary(p.Changes)}):");
    foreach (var c in p.Changes) Console.WriteLine("  " + c);
    if (p.Changes.Count == 0) Console.WriteLine("  (no mod changes)");
    if (p.Manifest.Platforms?.Mac is { } mac)
        Console.WriteLine($"Mac friends also get: launch args [{string.Join(" ", mac.ExtraArgs)}], {mac.Files.Count} config default(s): " +
                          string.Join(", ", mac.Files.Select(f => Path.GetFileName(f.Path))) + " (only where they have no config yet)");
    if (p.Manifest.App is { } app) Console.WriteLine($"Friend app: {app.Version} (friends on an older PeakPack update themselves)");
    Console.WriteLine("Assets:");
    foreach (var f in p.Assets) Console.WriteLine("  " + f);
    foreach (var pr in p.Problems) Console.WriteLine("NOT READY: " + pr);
    return p;
}

static async Task<int> Prepare(Args a, bool release)
{
    var cfg = PublishConfig.Load(a.Require("--config"));
    if (a.Get("--notes") is { } notes) cfg.Notes = notes;
    var work = a.Get("--work") ?? PublishPipeline.DefaultWorkDir;
    var p = await PrepareOnly(a, cfg, work);
    if (!release) return p.CanRelease ? 0 : 2;
    var repo = a.Get("--repo") ?? cfg.GithubRepo ?? throw new ArgumentException("--repo or githubRepo is required");
    var pipe = new PublishPipeline(Console.WriteLine);
    var rc = await pipe.ReleaseAsync(p, repo, work, a.Has("--dry-run"));
    if (rc == 0 && !a.Has("--dry-run") && a.Get("--stamp") is { } bep) pipe.StampHost(p.Manifest, p.StagingDir, bep);
    return rc;
}

static int Stamp(Args a)
{
    var dir = a.Require("--manifest");
    var m = PackManifest.Parse(File.ReadAllText(Path.Combine(dir, "manifest.json")));
    new PublishPipeline(Console.WriteLine).StampHost(m, dir, a.Require("--bepinex"));
    return 0;
}

static async Task<int> Check(Args a)
{
    var (paths, _) = Ctx(a);
    var manifest = a.Get("--manifest") ?? InstallState.Load(paths).ManifestUrl ?? throw new ArgumentException("--manifest is required");
    using var dl = new Downloader(paths.CacheDir) { AllowLocalFiles = a.Has("--allow-local") };
    var inst = new Installer(paths, dl);
    var lm = await inst.LoadManifestAsync(manifest, a.Get("--public-key"));
    var changes = inst.PendingChanges(lm.Manifest);
    var st = InstallState.Load(paths);
    Console.WriteLine(st.InstalledRevision == 0 ? "Not installed." : changes.Count == 0 && lm.Manifest.Revision == st.InstalledRevision
        ? $"Up to date (revision {st.InstalledRevision})."
        : $"Update available: revision {st.InstalledRevision} -> {lm.Manifest.Revision}, {PackDiff.Summary(changes)}");
    foreach (var c in changes) Console.WriteLine("  " + c.Friendly);
    return 0;
}

static int SelfInstall(Args a)
{
    var paths = new AppPaths(a.Get("--data-dir"));
    var opt = Setup.DefaultOptions(new PackConfig(), paths, a.Get("--shortcut-dir"));
    if (a.Get("--shortcut-dir") is null && !paths.IsDefaultLocation) opt = opt with { DesktopDir = null, StartMenuDir = null };
    var r = Setup.EnsureInstalledCopy(paths, a.Require("--exe"));
    Setup.CreateShortcuts(paths, a.Get("--game-dir"), opt);
    Console.WriteLine($"Installed copy: {r.InstalledExe} (copied: {r.Copied}, kept newer: {r.KeptNewerInstalledCopy})");
    Console.WriteLine($"Mark-of-the-Web on installed copy: {Setup.HasMarkOfTheWeb(r.InstalledExe)}");
    return 0;
}

static string DefaultConfig() => Path.Combine(PublishPipeline.DefaultWorkDir, "publish.json");

static string? HostBepInEx(Args a, PublishConfig? cfg)
{
    if ((a.Get("--notify") ?? a.Get("--bepinex")) is { } d) return d;
    var g = cfg?.GameDir is { } gd ? Path.Combine(gd, "BepInEx") : null;
    return g is not null && Directory.Exists(g) ? g : null;
}

static async Task<int> HotfixCmd(Args a)
{
    var cfgPath = a.Get("--config") ?? DefaultConfig();
    var work = a.Get("--work") ?? PublishPipeline.DefaultWorkDir;
    var index = await LoadIndex(a);
    using var dl = new Downloader(Path.Combine(work, "cache"));
    var cfg = PublishConfig.Load(cfgPath);
    var o = new HotfixRunner.Options(cfgPath, a.Require("--mod"), a.Get("--dll"), a.Get("--version"), a.Get("--notes"),
        a.Has("--rollback"), a.Has("--publish"), work, HostBepInEx(a, cfg), a.Get("--previous"), a.Get("--repo"));
    var r = await new HotfixRunner(Console.WriteLine).RunAsync(o, index, dl);
    Console.WriteLine(r.Summary);
    if (!a.Has("--publish") && r.ExitCode == 0) Console.WriteLine("Add --publish to do it for real.");
    return r.ExitCode;
}

static int LobbyCmd(Args a)
{
    var sub = a.Positional.Skip(1).FirstOrDefault()?.ToLowerInvariant() ?? throw new ArgumentException("lobby snapshot|hot-update");
    PublishConfig? cfg = File.Exists(a.Get("--config") ?? DefaultConfig()) ? PublishConfig.Load(a.Get("--config") ?? DefaultConfig()) : null;
    var bep = HostBepInEx(a, cfg) ?? throw new ArgumentException("Pass --bepinex <your game's BepInEx folder> (or set gameDir in publish.json).");
    var path = sub switch
    {
        "snapshot" => LobbyCommands.Write(bep, LobbyCommands.Snapshot),
        "hot-update" => LobbyCommands.Write(bep, LobbyCommands.HotUpdate, int.Parse(a.Require("--revision"))),
        _ => throw new ArgumentException("lobby snapshot|hot-update"),
    };
    Console.WriteLine($"Queued for your game's companion: {path}");
    if (sub == "snapshot") Console.WriteLine($"Friends' logs arrive in {LobbyCommands.RemoteLogsDir(bep)} within a few seconds (your game must be hosting).");
    return 0;
}

static async Task<int> HotUpdateCmd(Args a)
{
    var paths = new AppPaths(a.Get("--data-dir"));
    var manifest = a.Get("--manifest") ?? InstallState.Load(paths).ManifestUrl ?? throw new ArgumentException("--manifest is required");
    using var dl = new Downloader(paths.CacheDir) { AllowLocalFiles = a.Has("--allow-local") };
    var r = await HotUpdater.ApplyAsync(paths, dl, manifest, a.Get("--public-key"));
    Console.WriteLine($"{r.Status}: {r.Message}");
    return r.Status is HotUpdater.Status.Applied or HotUpdater.Status.UpToDate ? 0 : r.Status == HotUpdater.Status.Failed ? 1 : 3;
}

static int HotRollbackCmd(Args a)
{
    var r = HotUpdater.RollBack(new AppPaths(a.Get("--data-dir")));
    Console.WriteLine($"{r.Status}: {r.Message}");
    return r.Status == HotUpdater.Status.RolledBack ? 0 : 1;
}

static int InspectCmd(Args a)
{
    int bad = 0;
    foreach (var dll in a.Positional.Skip(1).Concat(a.Get("--dll") is { } d ? [d] : Array.Empty<string>()))
    {
        var c = Hotfix.Inspect(dll);
        Console.WriteLine($"{Path.GetFileName(dll)}: plugin {c.PluginGuid} \"{c.PluginName}\" {c.PluginVersion}; embedded PDB {c.HasEmbeddedPdb}; OnDestroy {c.HasOnDestroy}; sha256 {Downloader.Sha256OfFile(dll)[..12]}");
        Console.WriteLine(c.LiveReloadOk ? "  reload-safe: yes" : "  reload-safe: NO (" + string.Join(" ", c.Problems) + ")");
        if (!c.LiveReloadOk) bad++;
    }
    return bad;
}

static int OptionsCmd(Args a)
{
    var paths = new AppPaths(a.Get("--data-dir"));
    var st = InstallState.Load(paths);
    static bool On(string v) => v.Equals("on", StringComparison.OrdinalIgnoreCase) || v == "true" || v == "1";
    if (a.Get("--diagnostics") is { } d) st.ShareDiagnostics = On(d);
    if (a.Get("--live-updates") is { } l) st.AcceptLiveUpdates = On(l);
    st.Save(paths);
    PackInfo.Refresh(paths, "PEAK (Modded)");
    Console.WriteLine($"Share error logs with the host: {(st.ShareDiagnostics ? "on" : "off")}; live updates in test lobbies: {(st.AcceptLiveUpdates ? "on" : "off")}");
    return 0;
}

static int Status(Args a)
{
    var (paths, game) = Ctx(a);
    var state = InstallState.Load(paths);
    Console.WriteLine($"Data folder : {paths.DataDir}");
    Console.WriteLine($"PEAK folder : {game ?? "(not found)"}");
    Console.WriteLine($"Pack        : {state.PackName ?? "(not installed)"} revision {state.InstalledRevision}");
    Console.WriteLine($"Loader      : {state.LoaderId}");
    foreach (var p in state.Packages.Keys.Order()) Console.WriteLine($"  mod  {p}");
    foreach (var f in state.Files.Keys.Order()) Console.WriteLine($"  file {f}");
    if (game is not null)
    {
        var i = GameFolder.Inspect(game, state);
        Console.WriteLine($"Game folder : proxy={(i.HasProxy ? (i.ProxyIsOurs ? "ours" : "FOREIGN") : "none")}, ini enabled={i.IniEnabled?.ToString() ?? "n/a"}, BepInEx folder={(i.HasBepInExFolder ? "present" : "none")}");
        Console.WriteLine($"Steam 'Play' button launches: {(i.SteamLaunchIsModded ? "MODDED" : "normal PEAK (vanilla)")}");
    }
    Console.WriteLine($"Last launch : {state.LastLaunchMode?.ToString() ?? "never"} {state.LastLaunchTime}");
    return 0;
}

static int Uninstall(Args a)
{
    var (paths, game) = Ctx(a);
    var opt = Setup.DefaultOptions(new PackConfig(), paths, a.Get("--shortcut-dir"));
    if (a.Get("--shortcut-dir") is null && !paths.IsDefaultLocation) opt = opt with { DesktopDir = null, StartMenuDir = null };
    var rep = Setup.Uninstall(paths, opt, game);
    foreach (var r in rep.Removed) Console.WriteLine("  removed " + r);
    foreach (var l in rep.LeftBehind) Console.WriteLine("  LEFT (not ours / changed): " + l);
    if (rep.BackupDir is not null) Console.WriteLine($"  Your previous mod loader backup is still at {rep.BackupDir}");
    if (game is not null) Console.WriteLine($"Game folder vanilla: {GameFolder.Inspect(game, new InstallState()).IsVanilla}");
    return 0;
}

static int Locate()
{
    var steam = SteamLocator.FindSteamDir();
    Console.WriteLine($"Steam dir : {steam}");
    Console.WriteLine($"Steam exe : {SteamLocator.FindSteamExe()}");
    if (steam is not null) foreach (var l in SteamLocator.GetLibraryFolders(steam)) Console.WriteLine($"Library   : {l}");
    Console.WriteLine($"PEAK      : {SteamLocator.FindGameDir()}");
    return 0;
}

/// <summary>Reports inline (Progress&lt;T&gt; would post asynchronously and scramble console output).</summary>
sealed class ConsoleProgress : IProgress<SyncProgress>
{
    public void Report(SyncProgress v) => Console.WriteLine($"  [{(v.Fraction ?? 0) * 100,3:0}%] {v.Message}");
}

sealed class Args(string[] raw)
{
    public List<string> Positional { get; } = raw.TakeWhile(r => !r.StartsWith("--")).ToList();
    public bool Has(string k) => raw.Contains(k, StringComparer.OrdinalIgnoreCase);
    public string? Get(string k)
    {
        var i = Array.FindIndex(raw, r => r.Equals(k, StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < raw.Length ? raw[i + 1] : null;
    }
    public string Require(string k) => Get(k) ?? throw new ArgumentException($"{k} is required");
}
