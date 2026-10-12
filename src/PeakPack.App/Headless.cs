using System.Text;
using System.Text.Json;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// Headless mode: what the Mac front end ("PEAK (Modded).app") runs inside our Wine prefix, and handy for agents on
/// Windows too. No window ever opens.
///
///   PeakPack.exe --headless --status [--status-out F]
///   PeakPack.exe --headless --sync   [--adopt] [--status-out F]
///   PeakPack.exe --headless --launch [--vanilla] [--on-sync-fail stop|installed|vanilla] [--status-out F]
///
/// The status file (JSON, rewritten atomically; poll it for progress) and the exit code tell the caller what happened:
///   0 ok · 1 failed (problem.heading/advice say why) · 2 PEAK not found · 3 existing foreign mod loader (rerun with --adopt)
///   4 PEAK already running · 5 not installed yet (run --sync first)
/// </summary>
public static class Headless
{
    public sealed class Status
    {
        public string State { get; set; } = "working";        // working | done | failed
        public string Step { get; set; } = "";                 // check | sync | launch
        public string Message { get; set; } = "";
        public double? Progress { get; set; }
        public string Platform { get; set; } = Core.Platform.Describe;
        public string AppVersion { get; set; } = SelfUpdate.CurrentVersion.ToString(3);
        public int InstalledRevision { get; set; }
        public int? LatestRevision { get; set; }
        public List<string> Changes { get; set; } = new();
        public string? Launched { get; set; }                  // "modded" | "vanilla"
        public string? CommandLine { get; set; }
        public SyncRunner.Problem? Problem { get; set; }
        public int ExitCode { get; set; }
    }

    public static int Run(AppSession s, string[] args)
    {
        var outPath = AppSession.Get(args, "--status-out") ?? Path.Combine(s.Paths.DataDir, "headless-status.json");
        var st = new Status { InstalledRevision = s.LoadState().InstalledRevision };
        void Write()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath))!);
                File.WriteAllText(outPath + ".tmp", JsonSerializer.Serialize(st, PackManifest.JsonOptions), new UTF8Encoding(false));
                File.Move(outPath + ".tmp", outPath, true);
            }
            catch { /* status is best effort */ }
        }
        int Finish(int code, string state)
        {
            st.ExitCode = code; st.State = state; st.Progress = state == "done" ? 1 : st.Progress;
            st.InstalledRevision = s.LoadState().InstalledRevision;
            Write();
            s.Paths.Log($"Headless {st.Step}: {state} ({code}) {st.Message}");
            return code;
        }
        int Fail(Exception ex, int code = 1)
        {
            st.Problem = SyncRunner.Describe(ex, s.Config.HostName);
            st.Message = st.Problem.Heading;
            return Finish(code, "failed");
        }

        try
        {
            var gameDir = s.FindGameDir();
            bool launch = AppSession.Has(args, "--launch"), sync = AppSession.Has(args, "--sync");

            if (!launch && !sync)
            {
                st.Step = "check";
                Write();
                try
                {
                    var c = SyncRunner.CheckAsync(s).GetAwaiter().GetResult();
                    st.LatestRevision = c.Manifest.Revision;
                    st.Changes = c.Changes.Select(x => x.Friendly).ToList();
                    st.Message = !s.IsInstalled ? "Not installed yet" : c.Changes.Count == 0 && !c.IsNewRevision ? "Ready to play" : "Update available: " + PackDiff.Summary(c.Changes);
                }
                catch (Exception ex) { return Fail(ex); }
                return Finish(0, "done");
            }

            if (gameDir is null) { st.Message = "PEAK wasn't found"; st.Problem = new("PEAK wasn't found", "Install PEAK, or pass --game-dir.", ""); return Finish(2, "failed"); }
            if (GameFolder.IsGameRunning(gameDir)) { st.Message = "PEAK is already running"; return Finish(4, "failed"); }

            // Sync (always before a modded launch, exactly like the PEAK (Modded) shortcut).
            bool vanilla = AppSession.Has(args, "--vanilla");
            if (sync || (launch && !vanilla))
            {
                st.Step = "sync";
                Write();
                var progress = new InlineProgress(p => { st.Message = p.Message; st.Progress = p.Fraction; Write(); });
                try
                {
                    var o = SyncRunner.RunAsync(s, gameDir, _ => AppSession.Has(args, "--adopt"), progress, args) // self-update restarts with the same arguments
                        .GetAwaiter().GetResult();
                    st.LatestRevision = o.Manifest.Revision;
                    st.Changes = o.Result.Installed.Concat(o.Result.Removed.Select(r => "-" + r)).ToList();
                    if (o.RestartingForAppUpdate) { st.Message = "PeakPack updated itself and restarted with the same arguments"; return Finish(0, "done"); }
                }
                catch (OperationCanceledException) { st.Message = "Existing mods found"; st.Problem = new("Your PEAK folder already has mods", "Run again with --adopt to move them to a backup folder.", ""); return Finish(3, "failed"); }
                catch (Exception ex) when (launch && !vanilla)
                {
                    var mode = AppSession.Get(args, "--on-sync-fail") ?? "stop";
                    s.Paths.Log("Headless sync failed: " + ex);
                    if (mode == "installed" && s.IsInstalled) { st.Problem = SyncRunner.Describe(ex, s.Config.HostName); st.Message = "Couldn't update; playing with the mods already installed"; }
                    else if (mode == "vanilla") { st.Problem = SyncRunner.Describe(ex, s.Config.HostName); vanilla = true; st.Message = "Couldn't update; playing normal PEAK"; }
                    else return Fail(ex);
                }
                catch (Exception ex) { return Fail(ex); }
            }
            if (!launch) { st.Message = $"Mods are up to date (revision {s.LoadState().InstalledRevision})"; return Finish(0, "done"); }

            st.Step = "launch";
            if (!vanilla && !s.IsInstalled) { st.Message = "Not installed yet"; return Finish(5, "failed"); }
            var state = s.LoadState();
            if (!vanilla) { GameFolder.ApplyProxy(gameDir, s.Paths, state); state.Save(s.Paths); }
            st.CommandLine = Launcher.Launch(vanilla ? LaunchMode.Vanilla : LaunchMode.Modded, s.Paths, state, gameDir, s.LaunchMethod);
            st.Launched = vanilla ? "vanilla" : "modded";
            st.Message = vanilla ? "Starting normal PEAK" : "Starting PEAK with mods";
            return Finish(0, "done");
        }
        catch (Exception ex)
        {
            s.Paths.Log("Headless failed: " + ex);
            return Fail(ex);
        }
    }

    /// <summary>Reports inline (no SynchronizationContext in headless mode).</summary>
    sealed class InlineProgress(Action<SyncProgress> report) : IProgress<SyncProgress>
    {
        public void Report(SyncProgress value) => report(value);
    }
}
