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

        // Started by the in-game companion in a test lobby (no window): apply a signed live update of the host's
        // reload-safe mods if the friend opted in, write the result for the companion's notice, exit.
        if (AppSession.Has(args, "--hot-update"))
        {
            var loc = AppSession.Get(args, "--manifest") ?? s.LoadState().ManifestUrl ?? s.ManifestLocation;
            using var dl = s.NewDownloader();
            HotUpdater.ApplyAsync(s.Paths, dl, loc, s.PublicKey, s.Config.ShortcutName).GetAwaiter().GetResult();
            return;
        }
        if (AppSession.Has(args, "--hot-rollback"))
        {
            HotUpdater.RollBack(s.Paths, s.Config.ShortcutName);
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

    static MainForm OffScreen(MainForm f)
    {
        f.StartPosition = FormStartPosition.Manual;
        f.Location = new Point(-4000, -4000);
        f.ShowInTaskbar = false;
        return f;
    }
}
