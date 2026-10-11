using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// What the "PEAK (Modded)" desktop shortcut runs (PeakPack.exe --launch): check for updates, sync,
/// start PEAK with mods, exit. No window at all when nothing needs downloading; a small progress window
/// appears only if it takes a moment; a plain-English choice if something fails.
/// </summary>
public sealed class QuickLaunchContext : ApplicationContext
{
    readonly AppSession _s;
    readonly Form _win;
    readonly Label _msg = new() { AutoSize = false, Width = 340, Height = 40, TextAlign = ContentAlignment.MiddleLeft };
    readonly ProgressBar _bar = new() { Width = 340, Height = 10, Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30 };
    readonly System.Windows.Forms.Timer _showTimer = new() { Interval = 900 };

    public QuickLaunchContext(AppSession s)
    {
        _s = s;
        _win = new Form
        {
            Text = s.Config.ShortcutName, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size(380, 100), Font = new Font("Segoe UI", 10f), BackColor = Color.White,
            ShowInTaskbar = true,
        };
        try { _win.Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        _msg.Location = new Point(20, 14);
        _bar.Location = new Point(20, 62);
        _win.Controls.AddRange([_msg, _bar]);
        _msg.Text = "Checking for mod updates...";
        _showTimer.Tick += (_, _) => { _showTimer.Stop(); ShowWindow(); };
        _ = RunAsync();
    }

    void ShowWindow() { if (!_win.Visible) _win.Show(); }

    async Task RunAsync()
    {
        await Task.Yield(); // let the message loop start
        _showTimer.Start();
        string? gameDir = _s.FindGameDir();
        try
        {
            if (gameDir is null || !_s.IsInstalled)
            {
                // Not set up (or PEAK moved): fall back to the full window, which can ask for the folder.
                SwitchToMainWindow();
                return;
            }
            if (GameFolder.IsGameRunning(gameDir))
            {
                ShowWindow();
                MessageBox.Show(_win, "PEAK is already running. Close it first, then use the shortcut again.", _s.Config.ShortcutName, MessageBoxButtons.OK, MessageBoxIcon.Information);
                ExitThread();
                return;
            }

            var progress = new Progress<SyncProgress>(p =>
            {
                _msg.Text = p.Message;
                if (p.IsDownload) ShowWindow();
            });
            try
            {
                var o = await SyncRunner.RunAsync(_s, gameDir, AskAdopt, progress, _s.PassThroughArgs("--launch"));
                if (o.RestartingForAppUpdate) { ExitThread(); return; }
            }
            catch (OperationCanceledException) { ExitThread(); return; }
            catch (Exception ex)
            {
                _s.Paths.Log("Quick launch sync failed: " + ex);
                _showTimer.Stop();
                ShowWindow();
                _bar.Style = ProgressBarStyle.Continuous;
                var choice = MessageBox.Show(_win,
                    SyncRunner.Friendly(ex) + "\n\n" +
                    "Yes = play with the mods you already have (you might not match the host)\n" +
                    "No = play normal PEAK\nCancel = don't start PEAK",
                    "Couldn't update the mods", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Warning);
                if (choice == DialogResult.Cancel) { ExitThread(); return; }
                if (choice == DialogResult.No) { Launch(LaunchMode.Vanilla, gameDir); return; }
            }
            Launch(LaunchMode.Modded, gameDir);
        }
        catch (Exception ex)
        {
            _s.Paths.Log("Quick launch failed: " + ex);
            ShowWindow();
            MessageBox.Show(_win, "Something went wrong starting PEAK with mods:\n\n" + ex.Message +
                                  $"\n\nA log is at {_s.Paths.LogPath} - send it to {_s.Config.HostName}.",
                _s.Config.ShortcutName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            ExitThread();
        }
    }

    bool AskAdopt(string gameDir)
    {
        ShowWindow();
        return MessageBox.Show(_win,
            "Your PEAK folder already has mods installed some other way. PeakPack will move them to a backup folder (nothing is deleted). Continue?",
            "Existing mods found", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
    }

    void Launch(LaunchMode mode, string gameDir)
    {
        var st = _s.LoadState();
        if (mode == LaunchMode.Modded) { GameFolder.ApplyProxy(gameDir, _s.Paths, st); st.Save(_s.Paths); }
        _msg.Text = mode == LaunchMode.Modded ? "Starting PEAK with mods..." : "Starting normal PEAK...";
        var cmd = Launcher.Launch(mode, _s.Paths, st, gameDir, _s.LaunchMethod);
        if (_s.LaunchMethod == Launcher.Method.DryRun) Console.WriteLine(cmd);
        // Linger briefly if visible so the friend sees it worked, then exit.
        var t = new System.Windows.Forms.Timer { Interval = _win.Visible ? 1500 : 1 };
        t.Tick += (_, _) => { t.Stop(); ExitThread(); };
        t.Start();
    }

    void SwitchToMainWindow()
    {
        _showTimer.Stop();
        var main = new MainForm(_s);
        main.FormClosed += (_, _) => ExitThread();
        main.Show();
    }

    protected override void ExitThreadCore()
    {
        _showTimer.Dispose();
        _win.Dispose();
        base.ExitThreadCore();
    }
}
