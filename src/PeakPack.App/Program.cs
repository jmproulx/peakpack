using PeakPack.Core;

namespace PeakPack.App;

static class Program
{
    /// <summary>
    /// PeakPack.exe                 open the window. The FIRST time (the downloaded file): install the app to
    ///                              %LOCALAPPDATA%\PeakPack, create the "PEAK (Modded)" desktop + Start Menu icons,
    ///                              then continue from the installed copy.
    /// PeakPack.exe --launch        what the "PEAK (Modded)" shortcut runs: update + start modded, no questions
    /// PeakPack.exe --uninstall     "Remove PeakPack" (also used by Windows' Installed Apps list)
    /// PeakPack.exe --host          Joshua's Host / Publisher window
    /// Test-only overrides: --game-dir, --data-dir, --manifest, --public-key, --allow-local, --shortcut-dir,
    ///   --launch-method steam|direct|dry, --ui-scale 1.25, --no-self-install,
    ///   --screenshot out.png, --selftest DIR, --selftest-open DIR NAME
    /// </summary>
    [STAThread]
    static void Main(string[] args)
    {
        // Windowless modes run before any WinForms initialisation: less to go wrong under Wine on Mac.
        if (AppSession.Has(args, "--headless") || AppSession.Has(args, "--hot-update") || AppSession.Has(args, "--hot-rollback"))
        {
            Environment.ExitCode = RunWindowless(args);
            return;
        }
        ApplicationConfiguration.Initialize();
        if (AppSession.Has(args, "--host") || AppSession.Has(args, "--host-selftest"))
        {
            // Joshua's Host / Publisher window. Never syncs or touches the game folder by itself.
            Application.Run(new HostForm(args));
            return;
        }
        var s = new AppSession(args);
        SelfUpdate.CleanupOld(s.Paths);

        if (AppSession.Get(args, "--screenshot") is { } shot)
        {
            using var f = OffScreen(new MainForm(s));
            f.Show();
            Application.DoEvents();
            f.SaveScreenshot(shot);
            return;
        }

        if (AppSession.Get(args, "--selftest") is { } testDir)
        {
            // Same first-run install as a real first open, but without restarting (the test drives this process).
            if (FirstRun.ShouldInstall(s)) FirstRun.Install(s);
            var f = OffScreen(new MainForm(s));
            f.Load += async (_, _) => { await Task.Yield(); await f.RunSelfTestAsync(testDir); f.Close(); };
            Application.Run(f);
            return;
        }

        if (AppSession.Get(args, "--selftest-open") is { } openDir)
        {
            var name = args.SkipWhile(a => !a.Equals("--selftest-open", StringComparison.OrdinalIgnoreCase)).Skip(2).FirstOrDefault() ?? "open";
            var f = OffScreen(new MainForm(s));
            f.Load += async (_, _) => { await Task.Yield(); await f.RunOpenSelfTestAsync(openDir, name); f.Close(); };
            Application.Run(f);
            return;
        }

        if (AppSession.Has(args, "--uninstall"))
        {
            var remove = new TaskDialogButton("Remove PeakPack");
            var page = new TaskDialogPage
            {
                Caption = "PeakPack", Heading = "Remove PeakPack and its mods?", Icon = TaskDialogIcon.Warning,
                Text = "Your PEAK folder goes back to exactly how Steam installed it. Your normal PEAK and your saves are not affected.",
                Buttons = { remove, TaskDialogButton.Cancel },
            };
            if (TaskDialog.ShowDialog(page) != remove) return;
            var rep = Setup.Uninstall(s.Paths, s.SetupOptions, s.FindGameDir());
            TaskDialog.ShowDialog(new TaskDialogPage
            {
                Caption = "PeakPack", Heading = "PeakPack has been removed", Icon = TaskDialogIcon.Information,
                Text = "PEAK is back to normal." + (rep.BackupDir is null ? "" : $"\n\nThe mods you had before PeakPack are backed up in {rep.BackupDir}"),
            });
            return;
        }

        if (AppSession.Has(args, "--launch"))
        {
            Application.Run(new QuickLaunchContext(s));
            return;
        }

        if (FirstRun.ShouldInstall(s))
        {
            try
            {
                FirstRun.Install(s);
                FirstRun.StartInstalledCopy(s);
                return;
            }
            catch (Exception ex)
            {
                // Couldn't install (antivirus, disk...): keep going from the downloaded file; the window still works.
                s.Paths.Log("First-run install failed, running from the download: " + ex);
            }
        }

        Application.Run(new MainForm(s));
    }

    /// <summary>--headless (Mac front end, agents), --hot-update and --hot-rollback (started by the in-game companion).</summary>
    static int RunWindowless(string[] args)
    {
        AppSession s;
        try { s = new AppSession(args); }
        catch (Exception ex)
        {
            // Even a broken start reports through the documented status file and exit code.
            if (AppSession.Has(args, "--headless") && AppSession.Get(args, "--status-out") is { } so)
                try
                {
                    File.WriteAllText(so, System.Text.Json.JsonSerializer.Serialize(new { state = "failed", step = "start", message = "PeakPack couldn't start",
                        problem = new { heading = "PeakPack couldn't start", advice = "Reinstall PeakPack.", details = ex.Message }, exitCode = 1 }));
                }
                catch { }
            return 1;
        }
        SelfUpdate.CleanupOld(s.Paths);

        if (AppSession.Has(args, "--hot-update"))
        {
            // One live update at a time per data folder (the companion could ask again while one is running).
            using var mutex = new Mutex(false, "PeakPack-hot-update-" + Downloader.Sha256OfBytes(System.Text.Encoding.UTF8.GetBytes(s.Paths.DataDir.ToLowerInvariant()))[..16]);
            if (!mutex.WaitOne(0)) return 0;
            try
            {
                var loc = AppSession.Get(args, "--manifest") ?? s.LoadState().ManifestUrl ?? s.ManifestLocation;
                using var dl = s.NewDownloader();
                var r = HotUpdater.ApplyAsync(s.Paths, dl, loc, s.PublicKey, s.Config.ShortcutName).GetAwaiter().GetResult();
                return r.Status == HotUpdater.Status.Failed ? 1 : 0;
            }
            finally { mutex.ReleaseMutex(); }
        }
        if (AppSession.Has(args, "--hot-rollback"))
            return HotUpdater.RollBack(s.Paths, s.Config.ShortcutName).Status == HotUpdater.Status.RolledBack ? 0 : 1;

        return Headless.Run(s, args); // see Headless.cs for commands and exit codes
    }

    static MainForm OffScreen(MainForm f)
    {
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(-4000, -4000);
        f.ShowInTaskbar = false;
        return f;
    }
}
