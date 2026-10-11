using PeakPack.Core;

namespace PeakPack.App;

static class Program
{
    /// <summary>
    /// PeakPack.exe                 open the window (first run: Install button)
    /// PeakPack.exe --launch        what the "PEAK (Modded)" shortcut runs: update + start modded, no questions
    /// PeakPack.exe --uninstall     "Remove everything" (also used by Windows' Installed Apps list)
    /// Test-only overrides: --game-dir, --data-dir, --manifest, --public-key, --allow-local,
    ///   --shortcut-dir, --launch-method steam|direct|dry, --screenshot out.png
    /// </summary>
    [STAThread]
    static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        var s = new AppSession(args);
        SelfUpdate.CleanupOld(s.Paths);

        if (AppSession.Get(args, "--screenshot") is { } shot)
        {
            using var f = new MainForm(s) { StartPosition = FormStartPosition.Manual, Location = new Point(-3000, -3000), ShowInTaskbar = false };
            f.Show();
            Application.DoEvents();
            f.SaveScreenshot(shot);
            return;
        }

        if (AppSession.Get(args, "--selftest") is { } testDir)
        {
            var f = new MainForm(s) { StartPosition = FormStartPosition.Manual, Location = new Point(-3000, -3000), ShowInTaskbar = false };
            f.Load += async (_, _) => { await f.RunSelfTestAsync(testDir); f.Close(); };
            Application.Run(f);
            return;
        }

        if (AppSession.Has(args, "--uninstall"))
        {
            if (MessageBox.Show("Remove PeakPack and all of its mods? Your PEAK folder will be put back exactly the way Steam installed it.",
                    "Remove PeakPack", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
            var rep = Setup.Uninstall(s.Paths, s.SetupOptions, s.FindGameDir());
            MessageBox.Show("PeakPack has been removed. PEAK is back to normal." +
                            (rep.BackupDir is null ? "" : $"\n\nYour earlier mods are backed up in {rep.BackupDir}"), "Removed");
            return;
        }

        if (AppSession.Has(args, "--launch"))
        {
            Application.Run(new QuickLaunchContext(s));
            return;
        }

        Application.Run(new MainForm(s));
    }
}
