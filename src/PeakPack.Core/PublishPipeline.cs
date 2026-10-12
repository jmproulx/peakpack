using System.Diagnostics;
using System.Text;

namespace PeakPack.Core;

/// <summary>
/// Joshua's publish pipeline, shared by the CLI (headless, agent-friendly) and the Host window:
///
///   1. Prepare: work out the previous revision (what friends really have: the live manifest URL, else the
///      last local release), build revision N+1 into &lt;work&gt;\staging, and describe the changes in plain words.
///   2. Release: upload staging as GitHub release "rev-N" (marked latest) with the GitHub CLI, then keep a copy
///      as &lt;work&gt;\current and &lt;work&gt;\history\rev-N. With dryRun, only print the exact gh command.
///   3. Stamp (optional): write the companion + pack-info.json into the host's own BepInEx folder, so the host's
///      game announces revision N in lobbies.
///
/// Every release also carries a stable-named PeakPack.exe, so the link friends get never changes:
///   https://github.com/OWNER/REPO/releases/latest/download/PeakPack.exe
/// </summary>
public sealed class PublishPipeline(Action<string> log)
{
    public sealed record Prepared(PackManifest Manifest, PackManifest? Previous, string StagingDir,
        IReadOnlyList<PackDiff.Change> Changes, IReadOnlyList<string> Assets, IReadOnlyList<string> Problems)
    {
        public bool CanRelease => Problems.Count == 0;
    }

    public static string DefaultWorkDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PeakPack-publisher");

    /// <summary>The revision friends currently have: an explicit file, else the live manifest URL (a 404 means
    /// "first publish"), else the last local release. A network error is an error: guessing could reuse a revision.</summary>
    public async Task<PackManifest?> LoadPreviousAsync(PublishConfig cfg, string workDir, Downloader dl, string? previousPath = null, CancellationToken ct = default)
    {
        if (previousPath is not null) return File.Exists(previousPath) ? PackManifest.Parse(await File.ReadAllTextAsync(previousPath, ct)) : null;
        if (cfg.EffectiveManifestUrl is { } url)
        {
            try
            {
                var bytes = await dl.GetSmallAsync(url, ct);
                var live = PackManifest.Parse(Encoding.UTF8.GetString(bytes));
                log($"Previous revision (live, {url}): {live.Revision}");
                return live;
            }
            catch (HttpRequestException ex) when (ex.Message.Contains("(404)"))
            {
                log($"No live manifest yet at {url} (first publish).");
            }
        }
        var local = Path.Combine(workDir, "current", "manifest.json");
        if (File.Exists(local))
        {
            var m = PackManifest.Parse(await File.ReadAllTextAsync(local, ct));
            log($"Previous revision (local {local}): {m.Revision}");
            return m;
        }
        return null;
    }

    public async Task<Prepared> PrepareAsync(PublishConfig cfg, string workDir, ThunderstoreIndex index, Downloader dl, PackManifest? previous, CancellationToken ct = default)
    {
        var staging = Path.Combine(workDir, "staging");
        if (Directory.Exists(staging)) Directory.Delete(staging, true);
        var m = await new Publisher(dl, index, log).PublishAsync(cfg, staging, previous, ct);

        // Stable-named friend app next to the versioned one (see class comment).
        if (cfg.App is { } app && File.Exists(app.Source))
            File.Copy(app.Source, Path.Combine(staging, "PeakPack.exe"), true);

        var assets = new List<string> { Path.Combine(staging, "manifest.json") };
        if (File.Exists(Path.Combine(staging, "manifest.json.sig"))) assets.Add(Path.Combine(staging, "manifest.json.sig"));
        foreach (var f in m.Files) assets.Add(Path.Combine(staging, f.Url.Split('/')[^1]));
        if (m.App is not null) assets.Add(Path.Combine(staging, m.App.Url.Split('/')[^1]));
        if (File.Exists(Path.Combine(staging, "PeakPack.exe"))) assets.Add(Path.Combine(staging, "PeakPack.exe"));
        assets = assets.Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        var problems = new List<string>();
        if (!cfg.HasRealRepo) problems.Add("githubRepo isn't set (e.g. \"jmproulx/peakpack\").");
        if (string.IsNullOrWhiteSpace(cfg.SigningKey) || !File.Exists(Path.Combine(staging, "manifest.json.sig")))
            problems.Add("The manifest isn't signed: set \"signingKey\" to the .pem from `PeakPack.Cli keygen` (friends' apps require a signature).");
        if (cfg.App is null || !File.Exists(cfg.App.Source))
            problems.Add("\"app\" isn't set: every release must carry PeakPack.exe, or the friends' download link breaks.");
        foreach (var a in assets.Where(a => !File.Exists(a))) problems.Add($"Missing asset {a}");
        var baseUrl = cfg.EffectiveAssetBaseUrl?.Replace("{revision}", m.Revision.ToString());
        foreach (var f in m.Files.Where(f => baseUrl is not null && !f.Url.StartsWith(baseUrl, StringComparison.OrdinalIgnoreCase)))
            problems.Add($"{f.Id} would be downloaded from {f.Url}, not from this release.");

        var changes = PackDiff.Compare(previous, m);
        return new Prepared(m, previous, staging, changes, assets, problems);
    }

    /// <summary>The exact gh invocation (also shown in dry runs and in the Host window).</summary>
    public static List<string> ReleaseArgs(Prepared p, string repo)
    {
        var m = p.Manifest;
        var notes = new StringBuilder();
        notes.AppendLine(string.IsNullOrWhiteSpace(m.Notes) ? $"Pack revision {m.Revision}" : m.Notes.Trim());
        notes.AppendLine();
        foreach (var c in p.Changes.Where(c => !c.IsHelper)) notes.AppendLine("- " + c.Friendly);
        if (p.Changes.Any(c => c.IsHelper)) notes.AppendLine("- Helper libraries updated");
        notes.AppendLine();
        notes.AppendLine($"Friends: just start PEAK from the \"PEAK (Modded)\" icon; it updates automatically. New here? Download PeakPack.exe below.");
        var args = new List<string> { "release", "create", $"rev-{m.Revision}" };
        args.AddRange(p.Assets);
        args.AddRange(["--repo", repo, "--title", $"{m.PackName} - revision {m.Revision}", "--notes", notes.ToString().TrimEnd(), "--latest"]);
        return args;
    }

    public static string? FindGh()
    {
        var local = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "gh", "bin", "gh.exe");
        if (File.Exists(local)) return local;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var c = Path.Combine(dir.Trim(), "gh.exe");
            if (File.Exists(c)) return c;
        }
        var pf = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "GitHub CLI", "gh.exe");
        return File.Exists(pf) ? pf : null;
    }

    public static string Quote(string a) => a.Length > 0 && a.IndexOfAny([' ', '"', '\n', '\'']) < 0 ? a : "\"" + a.Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "") + "\"";

    /// <summary>Uploads the staged revision. dryRun: prints the command and changes nothing.</summary>
    public async Task<int> ReleaseAsync(Prepared p, string repo, string workDir, bool dryRun, CancellationToken ct = default)
    {
        if (!p.CanRelease)
        {
            foreach (var pr in p.Problems) log("NOT READY: " + pr);
            if (!dryRun) return 2;
        }
        var gh = FindGh();
        var args = ReleaseArgs(p, repo);
        log((dryRun ? "DRY RUN, would run: " : "Running: ") + (gh ?? "gh") + " " + string.Join(' ', args.Select(Quote)));
        if (dryRun) return 0;
        if (gh is null) { log("GitHub CLI (gh.exe) not found."); return 3; }

        var psi = new ProcessStartInfo(gh) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var proc = Process.Start(psi)!;
        var stdout = proc.StandardOutput.ReadToEndAsync(ct);
        var stderr = proc.StandardError.ReadToEndAsync(ct);
        await proc.WaitForExitAsync(ct);
        log((await stdout).Trim());
        if (proc.ExitCode != 0) { log("gh failed: " + (await stderr).Trim()); return proc.ExitCode; }

        var current = Path.Combine(workDir, "current");
        var hist = Path.Combine(workDir, "history", $"rev-{p.Manifest.Revision}");
        CopyDir(p.StagingDir, hist);
        if (Directory.Exists(current)) Directory.Delete(current, true);
        CopyDir(p.StagingDir, current);
        log($"Released revision {p.Manifest.Revision}. Friends get it the next time they start PEAK (Modded).");
        return 0;
    }

    /// <summary>Puts the companion and a pack-info.json into a BepInEx folder (the host's own game), so the host's
    /// game announces this revision in lobbies. Touches only BepInEx\plugins\PeakPack-Companion\ and BepInEx\PeakPack\.</summary>
    public enum CompanionStamp { NotInPack, Installed, AlreadyCurrent, LockedByGame }

    /// <summary>Writes pack-info.json FIRST (always: that's what makes the host's lobby announce the new revision; the
    /// running companion re-reads it within 2 s), then installs the companion if it differs. A companion DLL that the
    /// running game loaded at startup is locked by Windows: then it's left as is, reported, and replaced by running
    /// stamp again with PEAK closed. Never throws for a locked DLL.</summary>
    public CompanionStamp StampHost(PackManifest m, string manifestDir, string bepInExDir, string shortcutName = "PEAK (Modded)")
    {
        if (!Directory.Exists(bepInExDir)) throw new DirectoryNotFoundException($"No BepInEx folder at {bepInExDir}");
        PackInfo.From(m, shortcutName).Save(PackInfo.PathIn(bepInExDir));
        log($"pack-info.json -> revision {m.Revision}, host ids [{string.Join(", ", m.Lobby?.HostIds ?? [])}] ({PackInfo.PathIn(bepInExDir)})");

        var comp = m.Files.FirstOrDefault(f => f.Id.Equals(PublishConfig.CompanionId, StringComparison.OrdinalIgnoreCase));
        if (comp is null) { log("Companion: not in this pack; left as is."); return CompanionStamp.NotInPack; }
        var src = Path.Combine(manifestDir, comp.Url.Split('/')[^1]);
        var dst = SafePath.Combine(bepInExDir, comp.Path);
        Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
        if (File.Exists(dst) && Downloader.Sha256OfFile(dst) == comp.Sha256.ToLowerInvariant())
        {
            log($"Companion: already this build ({comp.Version}); not copied.");
            return CompanionStamp.AlreadyCurrent;
        }
        try
        {
            File.Copy(src, dst, true);
            log($"Companion: installed {comp.Version} -> {dst}");
            return CompanionStamp.Installed;
        }
        catch (IOException)
        {
            var have = File.Exists(dst) ? System.Diagnostics.FileVersionInfo.GetVersionInfo(dst).ProductVersion : "?";
            log($"Companion: in use by the running game (installed {have}); left as is. pack-info was updated anyway. " +
                "To replace the DLL, run stamp again with PEAK closed.");
            return CompanionStamp.LockedByGame;
        }
    }

    static void CopyDir(string src, string dst)
    {
        Directory.CreateDirectory(dst);
        foreach (var f in Directory.EnumerateFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
    }
}
