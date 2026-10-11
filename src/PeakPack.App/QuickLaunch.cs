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
    readonly Label _msg = new() { AutoSize = false, TextAlign = ContentAlignment.MiddleLeft };
    readonly ProgressBar _bar = new() { Style = ProgressBarStyle.Marquee, MarqueeAnimationSpeed = 30 };
    readonly System.Windows.Forms.Timer _showTimer = new() { Interval = 900 };

    public QuickLaunchContext(AppSession s)
    {
        _s = s;
        // Small native progress window (only shown if something takes a moment), sized by hand for the DPI.
        _win = new Form
        {
            Text = s.Config.ShortcutName, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
            StartPosition = FormStartPosition.CenterScreen, AutoScaleMode = AutoScaleMode.None, BackColor = Theme.Face, ShowInTaskbar = true,
        };
        var ui = new Ui(Ui.ScaleFor(s.RawArgs, _win.DeviceDpi));
        _win.ClientSize = ui.Sz(400, 96);
        _win.Font = ui.Body;
        try { _win.Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        var glyph = new PictureBox { Image = Ui.StatusGlyph(StatusKind.Busy, ui.Px(32) * 2), SizeMode = PictureBoxSizeMode.Zoom, Bounds = new Rectangle(ui.Px(18), ui.Px(18), ui.Px(32), ui.Px(32)) };
        _msg.Bounds = new Rectangle(ui.Px(62), ui.Px(14), ui.Px(320), ui.Px(40));
        _bar.Bounds = new Rectangle(ui.Px(62), ui.Px(62), ui.Px(318), ui.Px(8));
        _win.Controls.AddRange([glyph, _msg, _bar]);
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
                var p = SyncRunner.Describe(ex, _s.Config.HostName);
                var withMods = new TaskDialogCommandLinkButton("Play with the mods I have", $"You might not match {_s.Config.HostName}'s game.");
                var normal = new TaskDialogCommandLinkButton("Play normal PEAK", "No mods.");
                var page = new TaskDialogPage
                {
                    Caption = _s.Config.ShortcutName, Heading = "Couldn't update the mods", Text = p.Heading + ". " + p.Advice,
                    Icon = TaskDialogIcon.Warning, Buttons = { withMods, normal, TaskDialogButton.Cancel },
                    Expander = new TaskDialogExpander(p.Details) { CollapsedButtonText = "Details" },
                };
                var choice = TaskDialog.ShowDialog(_win, page);
                if (choice == normal) { Launch(LaunchMode.Vanilla, gameDir); return; }
                if (choice != withMods) { ExitThread(); return; }
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
