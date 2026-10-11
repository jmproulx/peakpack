using System.Diagnostics;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// The PeakPack window. First run: one "Install" button. After that: big "Play Modded" and
/// "Play normal PEAK" buttons, the mod list, and "Remove everything".
/// </summary>
public sealed class MainForm : Form
{
    static readonly Color Accent = Color.FromArgb(0xE0, 0x6A, 0x1B);   // PEAK-ish orange
    static readonly Color Muted = Color.FromArgb(0x5F, 0x63, 0x68);

    readonly AppSession _s;
    readonly Label _title = new() { AutoSize = true, Font = new Font("Segoe UI Semibold", 16f), Margin = new Padding(0, 0, 0, 2) };
    readonly Label _subtitle = new() { AutoSize = true, ForeColor = Muted, MaximumSize = new Size(520, 0), Margin = new Padding(0, 0, 0, 12) };
    readonly Button _primary = MakeButton("Play Modded", primary: true);
    readonly Button _vanilla = MakeButton("Play normal PEAK", primary: false);
    readonly ProgressBar _bar = new() { Width = 520, Height = 8, Style = ProgressBarStyle.Continuous, Visible = false, Margin = new Padding(0, 10, 0, 0) };
    readonly Label _status = new() { AutoSize = true, MaximumSize = new Size(520, 0), Margin = new Padding(0, 8, 0, 0) };
    readonly Label _modsHeader = new() { AutoSize = true, Text = "Mods in this pack", Font = new Font("Segoe UI Semibold", 10f), Margin = new Padding(0, 16, 0, 4) };
    readonly ListBox _mods = new() { Width = 520, Height = 150, BorderStyle = BorderStyle.FixedSingle, IntegralHeight = false, SelectionMode = SelectionMode.None };
    readonly Label _modeInfo = new() { AutoSize = true, ForeColor = Muted, MaximumSize = new Size(520, 0), Margin = new Padding(0, 8, 0, 0) };
    readonly LinkLabel _checkLink = new() { AutoSize = true, Text = "Check for updates" };
    readonly LinkLabel _folderLink = new() { AutoSize = true, Text = "Open mods folder" };
    readonly LinkLabel _removeLink = new() { AutoSize = true, Text = "Remove everything..." };
    readonly FlowLayoutPanel _root;
    readonly Control[] _order;
    string? _gameDir;
    bool _busy;

    public MainForm(AppSession s)
    {
        _s = s;
        Text = "PeakPack - " + s.Config.PackName;
        Font = new Font("Segoe UI", 10f);
        BackColor = Color.White;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(24, 20, 24, 16);
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }

        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0), WrapContents = false };
        buttons.Controls.AddRange([_primary, _vanilla]);
        var links = new FlowLayoutPanel { AutoSize = true, Margin = new Padding(0, 12, 0, 0), WrapContents = false };
        foreach (var l in new[] { _checkLink, _folderLink, _removeLink }) { l.LinkColor = Muted; l.Margin = new Padding(0, 0, 18, 0); links.Controls.Add(l); }

        _root = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Dock = DockStyle.Fill };
        _order = [_title, _subtitle, buttons, _bar, _status, _modsHeader, _mods, _modeInfo, links];
        foreach (var c in _order) _root.Controls.Add(c);
        Controls.Add(_root);

        _primary.Click += async (_, _) => { if (_s.IsInstalled) await PlayAsync(LaunchMode.Modded); else await InstallAsync(); };
        _vanilla.Click += async (_, _) => await PlayAsync(LaunchMode.Vanilla);
        _checkLink.LinkClicked += async (_, _) => await SyncAsync(showUpToDate: true);
        _folderLink.LinkClicked += (_, _) => { if (Directory.Exists(_s.Paths.BepInExDir)) Process.Start("explorer.exe", _s.Paths.BepInExDir); };
        _removeLink.LinkClicked += (_, _) => RemoveEverything();
        Shown += async (_, _) => await OnShownAsync();
        Refresh_();
    }

    static Button MakeButton(string text, bool primary)
    {
        var b = new Button
        {
            Text = text, AutoSize = false, Size = new Size(primary ? 250 : 200, 52), FlatStyle = FlatStyle.Flat,
            Font = new Font("Segoe UI Semibold", primary ? 12.5f : 11f), Cursor = Cursors.Hand, Margin = new Padding(0, 0, 12, 0),
            BackColor = primary ? Accent : Color.FromArgb(0xF1, 0xF3, 0xF4), ForeColor = primary ? Color.White : Color.FromArgb(0x20, 0x21, 0x24),
        };
        b.FlatAppearance.BorderSize = 0;
        return b;
    }

    /// <summary>Redraws everything from state on disk.</summary>
    void Refresh_()
    {
        var st = _s.LoadState();
        _gameDir ??= _s.FindGameDir();
        _title.Text = _s.Config.PackName;
        bool installed = _s.IsInstalled;

        if (!installed)
        {
            _subtitle.Text = $"This sets up {_s.Config.HostName}'s PEAK mods so you can play together. " +
                             "Your normal PEAK stays exactly as it is: starting PEAK from Steam is still the normal game. " +
                             $"You'll get a \"{_s.Config.ShortcutName}\" shortcut on your desktop for playing with mods.";
            _primary.Text = "Install";
            _vanilla.Visible = false;
            _modsHeader.Visible = _mods.Visible = _modeInfo.Visible = false;
            _checkLink.Visible = _folderLink.Visible = _removeLink.Visible = false;
            _status.Text = _gameDir is null ? "PEAK wasn't found automatically - you'll be asked where it is." : $"PEAK found: {_gameDir}";
            return;
        }

        _subtitle.Text = $"Pack revision {st.InstalledRevision}" + (st.LastSyncTime is { } t ? $" - checked {Ago(t)}" : "");
        _primary.Text = "Play Modded";
        _vanilla.Visible = true;
        _modsHeader.Visible = _mods.Visible = _modeInfo.Visible = true;
        for (int i = 0; i < _order.Length; i++) _root.Controls.SetChildIndex(_order[i], i); // toggling Visible can shuffle FlowLayoutPanel order
        _checkLink.Visible = _folderLink.Visible = _removeLink.Visible = true;

        _mods.Items.Clear();
        foreach (var p in st.Packages.Keys.Order(StringComparer.OrdinalIgnoreCase))
        {
            var id = PackageId.Parse(p);
            _mods.Items.Add($"{id.Name.Replace('_', ' ')}  {id.Version?.ToString(3)}   (by {id.Namespace})");
        }
        foreach (var f in st.Files.Keys.Where(k => k.EndsWith(".dll", StringComparison.OrdinalIgnoreCase)).Order())
            _mods.Items.Add($"{Path.GetFileNameWithoutExtension(f)}   (from {_s.Config.HostName})");

        var last = st.LastLaunchMode is null ? "never launched from here"
            : $"last launched {(st.LastLaunchMode == LaunchMode.Modded ? "WITH mods" : "as normal PEAK")} {Ago(st.LastLaunchTime!.Value)}";
        var steamMode = _gameDir is not null && GameFolder.Inspect(_gameDir, st).SteamLaunchIsModded ? "WITH mods (unexpected - click Check for updates to fix)" : "normal PEAK";
        _modeInfo.Text = $"Starting PEAK from Steam = {steamMode}.  Using the \"{_s.Config.ShortcutName}\" shortcut or Play Modded = with mods.  You {last}.";
    }

    static string Ago(DateTimeOffset t)
    {
        var d = DateTimeOffset.Now - t;
        return d.TotalMinutes < 1 ? "just now" : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago" : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago" : t.LocalDateTime.ToString("d MMM");
    }

    async Task OnShownAsync()
    {
        if (_s.IsInstalled) await SyncAsync(showUpToDate: false); // quietly check for updates on open
    }

    bool EnsureGameDir()
    {
        _gameDir ??= _s.FindGameDir();
        if (_gameDir is not null) return true;
        MessageBox.Show(this, "PeakPack couldn't find PEAK automatically.\n\nPlease pick your PEAK folder - the one that contains PEAK.exe " +
                              "(usually Steam\\steamapps\\common\\PEAK).", "Where is PEAK?", MessageBoxButtons.OK, MessageBoxIcon.Information);
        using var dlg = new FolderBrowserDialog { Description = "Select the PEAK folder (contains PEAK.exe)", UseDescriptionForTitle = true };
        while (dlg.ShowDialog(this) == DialogResult.OK)
        {
            if (GameFolder.LooksLikePeak(dlg.SelectedPath)) { _gameDir = dlg.SelectedPath; return true; }
            MessageBox.Show(this, "That folder doesn't contain PEAK.exe. Try again.", "Not the PEAK folder", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        return false;
    }

    bool AskAdopt(string gameDir) => MessageBox.Show(this,
        "Your PEAK folder already has mods installed some other way (a BepInEx mod loader).\n\n" +
        "PeakPack will move those files into a backup folder (nothing is deleted), so that starting PEAK from Steam " +
        "is really the normal game, and mods only load from the PeakPack shortcut.\n\nContinue?",
        "Existing mods found", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;

    void SetBusy(bool busy, string? msg = null)
    {
        _busy = busy;
        _primary.Enabled = _vanilla.Enabled = !busy;
        _checkLink.Enabled = _removeLink.Enabled = !busy;
        _bar.Visible = busy;
        UseWaitCursor = busy;
        if (msg is not null) _status.Text = msg;
    }

    Progress<SyncProgress> MakeProgress() => new(p =>
    {
        _status.Text = p.Message;
        if (p.Fraction is { } f) _bar.Value = Math.Clamp((int)(f * 100), 0, 100);
    });

    async Task<bool> SyncAsync(bool showUpToDate)
    {
        if (_busy || !EnsureGameDir()) return false;
        SetBusy(true);
        try
        {
            var o = await SyncRunner.RunAsync(_s, _gameDir!, AskAdopt, MakeProgress(), _s.PassThroughArgs());
            if (o.RestartingForAppUpdate) { Close(); return false; }
            SetBusy(false, o.Result.Changed ? $"Updated to revision {o.Result.Revision}: {o.Result.Installed.Count} added/updated, {o.Result.Removed.Count} removed."
                                            : showUpToDate ? "Everything is up to date." : "");
            if (o.Manifest.Notes is { Length: > 0 } n && o.Result.Changed) _status.Text += "\nNote from " + _s.Config.HostName + ": " + n;
            Refresh_();
            return true;
        }
        catch (OperationCanceledException oce) { SetBusy(false, oce.Message); return false; }
        catch (Exception ex)
        {
            _s.Paths.Log("Sync failed: " + ex);
            SetBusy(false, "Update failed: " + SyncRunner.Friendly(ex));
            Refresh_();
            return false;
        }
    }

    async Task InstallAsync()
    {
        if (!EnsureGameDir()) return;
        if (!await SyncAsync(false) || !_s.IsInstalled) return;
        try
        {
            var extra = string.Join(' ', _s.PassThroughArgs().Select(a => a.Contains(' ') ? $"\"{a}\"" : a));
            Setup.InstallApp(_s.Paths, _gameDir!, _s.SetupOptions, extraArgs: extra);
        }
        catch (Exception ex) { _s.Paths.Log("Shortcut creation failed: " + ex); _status.Text = "Mods installed, but the desktop shortcut couldn't be created: " + ex.Message; }
        Refresh_();
        _status.Text = $"All set! Use \"{_s.Config.ShortcutName}\" on your desktop (or the button above) to play with mods. Starting PEAK from Steam is still normal PEAK.";
    }

    async Task PlayAsync(LaunchMode mode)
    {
        if (!EnsureGameDir()) return;
        if (GameFolder.IsGameRunning(_gameDir!))
        {
            _status.Text = "PEAK is already running. Close it first, then press Play again.";
            _s.Paths.Log("Play blocked: PEAK already running");
            return;
        }
        if (mode == LaunchMode.Modded && !await SyncAsync(false))
        {
            var r = MessageBox.Show(this, "Couldn't update the mods (see the message in the window).\n\nPlay with the mods you already have?",
                "Update failed", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r != DialogResult.Yes) return;
        }
        try
        {
            var st = _s.LoadState();
            if (mode == LaunchMode.Modded) { GameFolder.ApplyProxy(_gameDir!, _s.Paths, st); st.Save(_s.Paths); }
            var cmd = Launcher.Launch(mode, _s.Paths, st, _gameDir!, _s.LaunchMethod);
            _status.Text = mode == LaunchMode.Modded ? "Starting PEAK with mods..." : "Starting normal PEAK...";
            if (_s.LaunchMethod == Launcher.Method.DryRun) _status.Text += "\n(dry run) " + cmd;
            Refresh_();
        }
        catch (Exception ex) { _s.Paths.Log("Launch failed: " + ex); _status.Text = "Couldn't start PEAK: " + ex.Message; }
    }

    void RemoveEverything()
    {
        if (MessageBox.Show(this,
                "This removes PeakPack and all of its mods, and puts your PEAK folder back exactly the way Steam installed it.\n\n" +
                "Your normal PEAK and your saves are not affected. Continue?",
                "Remove everything", MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
        if (_gameDir is not null && GameFolder.IsGameRunning(_gameDir)) { MessageBox.Show(this, "Close PEAK first.", "PEAK is running"); return; }
        var rep = Setup.Uninstall(_s.Paths, _s.SetupOptions, _gameDir);
        var msg = "PeakPack has been removed. PEAK is back to normal.";
        if (rep.LeftBehind.Count > 0) msg += "\n\nThese files were changed by something else, so they were left alone:\n" + string.Join("\n", rep.LeftBehind);
        if (rep.BackupDir is not null) msg += $"\n\nThe mods you had before PeakPack are still backed up in:\n{rep.BackupDir}";
        MessageBox.Show(this, msg, "Removed", MessageBoxButtons.OK, MessageBoxIcon.Information);
        Close();
    }

    /// <summary>Dev/test aid (--selftest DIR): drives the real button handlers - Install, then Play Modded,
    /// then Play normal - and saves a screenshot after each step. Only meaningful with sandbox overrides.</summary>
    public async Task RunSelfTestAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        SaveScreenshot(Path.Combine(dir, "1-first-run.png"));
        await InstallAsync();
        SaveScreenshot(Path.Combine(dir, "2-after-install.png"));
        await PlayAsync(LaunchMode.Modded);
        SaveScreenshot(Path.Combine(dir, "3-after-play-modded.png"));
        for (int i = 0; i < 50 && GameFolder.IsGameRunning(_gameDir!); i++) await Task.Delay(200); // fake PEAK.exe exits by itself
        await PlayAsync(LaunchMode.Vanilla);
        SaveScreenshot(Path.Combine(dir, "4-after-play-vanilla.png"));
        File.WriteAllText(Path.Combine(dir, "status.txt"), _status.Text + Environment.NewLine + _modeInfo.Text + Environment.NewLine +
            string.Join(Environment.NewLine, Controls[0].Controls.Cast<Control>().Select(c => $"{c.GetType().Name} '{c.Text.Split('\n')[0]}' top={c.Top} visible={c.Visible}")));
    }

    /// <summary>Debug aid: render the window to a PNG (used to check the layout without a screen).</summary>
    public void SaveScreenshot(string path)
    {
        using var bmp = new Bitmap(Width, Height);
        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
}
