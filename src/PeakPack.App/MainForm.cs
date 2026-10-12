using System.Diagnostics;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// The PeakPack window, laid out like a classic Windows installer: header band, a status line in the style of
/// Windows Update ("Ready to play", "Update available: 2 mods changed", "Not installed yet", "Something went
/// wrong"), the main actions as native command links, what's in the pack and why, and a bottom button bar.
/// Pages: Welcome (first run) -> Done ("your desktop now has a PEAK (Modded) icon") -> Main (every later open).
/// </summary>
public sealed class MainForm : Form
{
    enum Page { Welcome, Done, Main }

    const int ContentWidth = 540;
    readonly AppSession _s;
    Ui _ui;
    Page _page;
    string? _gameDir;
    bool _busy;
    PackManifest? _latest;                   // manifest fetched from the host (welcome preview / update check)
    List<PackDiff.Change>? _pending;         // what an update would change
    SyncRunner.Problem? _problem;
    string? _note;                           // extra line under the status (e.g. "Updated to revision 8")

    // Controls (rebuilt when the DPI changes)
    HeaderBand _header = null!;
    StatusRow _status = null!;
    ProgressBar _bar = null!;
    FlowLayoutPanel _actions = null!;
    CommandLink _playModded = null!, _playVanilla = null!;
    Label _welcomeText = null!, _modsHeader = null!, _whatsNew = null!, _modeInfo = null!;
    TableLayoutPanel _doneRow = null!;
    ListView _mods = null!;
    LinkLabel _checkLink = null!, _folderLink = null!, _removeLink = null!, _copyLink = null!;
    Button _okButton = null!, _cancelButton = null!;
    TableLayoutPanel _body = null!;
    Panel _footer = null!;

    public MainForm(AppSession s)
    {
        _s = s;
        _ui = new Ui(Ui.ScaleFor(s.RawArgs, DeviceDpi));
        Text = "PeakPack";
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Theme.Face;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        _page = s.IsInstalled ? Page.Main : Page.Welcome;
        BuildLayout();
        Render();
        Shown += async (_, _) => await OnShownAsync();
        DpiChanged += (_, e) =>
        {
            if (AppSession.Get(_s.RawArgs, "--ui-scale") is not null) return;
            _ui = new Ui(Math.Max(1f, e.DeviceDpiNew / 96f));
            BuildLayout();
            Render();
        };
    }

    // ------------------------------------------------------------------ layout

    void BuildLayout()
    {
        SuspendLayout();
        foreach (Control c in Controls.Cast<Control>().ToList()) { Controls.Remove(c); c.Dispose(); }
        int w = _ui.Px(ContentWidth);
        Font = _ui.Body;

        _header = new HeaderBand(_ui) { Picture = LoadHeaderPicture() };

        _status = new StatusRow(_ui, w) { Margin = _ui.Pad(0, 0, 0, 10) };
        _bar = new ProgressBar { Size = new Size(w, _ui.Px(6)), Margin = _ui.Pad(0, 0, 0, 10), Style = ProgressBarStyle.Continuous, Visible = false };

        _playModded = new CommandLink { Size = new Size(w, _ui.Px(58)), Margin = _ui.Pad(0, 0, 0, 2), Font = _ui.Font(11f), NoteFont = _ui.Body, LayoutScale = _ui.Scale };
        _playVanilla = new CommandLink { Size = new Size(w, _ui.Px(58)), Margin = _ui.Pad(0), Font = _ui.Font(11f), NoteFont = _ui.Body, LayoutScale = _ui.Scale };
        _playModded.Click += async (_, _) => await PlayAsync(LaunchMode.Modded);
        _playVanilla.Click += async (_, _) => await PlayAsync(LaunchMode.Vanilla);

        _welcomeText = new Label { AutoSize = true, MaximumSize = new Size(w, 0), Margin = _ui.Pad(0) };

        _doneRow = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, RowCount = 2, Margin = _ui.Pad(0, 2, 0, 0) };
        _doneRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, _ui.Px(64)));
        _doneRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var icon = new PictureBox { Size = _ui.Sz(48, 48), SizeMode = PictureBoxSizeMode.Zoom, Margin = _ui.Pad(4, 0, 12, 0), Name = "icon" };
        var iconName = new Label { AutoSize = true, Font = _ui.Strong, Margin = _ui.Pad(0, 4, 0, 2), Name = "name" };
        var iconText = new Label { AutoSize = true, MaximumSize = new Size(w - _ui.Px(64), 0), Margin = _ui.Pad(0), Name = "text" };
        _doneRow.Controls.Add(icon, 0, 0);
        _doneRow.SetRowSpan(icon, 2);
        _doneRow.Controls.Add(iconName, 1, 0);
        _doneRow.Controls.Add(iconText, 1, 1);

        _actions = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoSize = true, Margin = _ui.Pad(0, 0, 0, 12) };
        _actions.Controls.AddRange([_playModded, _playVanilla, _welcomeText, _doneRow]);

        _modsHeader = new Label { AutoSize = true, Font = _ui.Strong, Margin = _ui.Pad(0, 0, 0, 4) };
        _mods = new ListView
        {
            View = View.Details, FullRowSelect = true, HeaderStyle = ColumnHeaderStyle.Nonclickable, ShowItemToolTips = true,
            Size = new Size(w, _ui.Px(150)), Margin = _ui.Pad(0, 0, 0, 6), MultiSelect = false, ShowGroups = true, Font = _ui.Body,
        };
        _mods.Columns.Add("Mod", _ui.Px(160));
        _mods.Columns.Add("What it does", w - _ui.Px(160) - SystemInformation.VerticalScrollBarWidth - _ui.Px(6));

        _whatsNew = new Label { AutoSize = true, MaximumSize = new Size(w, 0), Margin = _ui.Pad(0, 0, 0, 4) };
        _modeInfo = new Label { AutoSize = true, MaximumSize = new Size(w, 0), ForeColor = Theme.Muted, Margin = _ui.Pad(0) };

        _body = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 1, AutoSize = false, Padding = _ui.Pad(20, 16, 20, 10), BackColor = Theme.Face,
        };
        foreach (var c in new Control[] { _status, _bar, _actions, _modsHeader, _mods, _whatsNew, _modeInfo })
        {
            _body.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            _body.Controls.Add(c);
        }

        // Bottom bar: links on the left, standard buttons on the right (installer style).
        _footer = new Panel { Dock = DockStyle.Bottom, Height = _ui.Px(50), BackColor = Theme.Face };
        _footer.Paint += (_, e) => { using var p = new Pen(Theme.Line); e.Graphics.DrawLine(p, 0, 0, _footer.Width, 0); };
        _checkLink = MakeLink("Check for updates", async () => await UpdateNowAsync());
        _folderLink = MakeLink("Open mods folder", () => { if (Directory.Exists(_s.Paths.BepInExDir)) Process.Start("explorer.exe", _s.Paths.BepInExDir); return Task.CompletedTask; });
        _removeLink = MakeLink("Remove PeakPack...", () => { RemoveEverything(); return Task.CompletedTask; });
        _copyLink = MakeLink("Copy details", () => { CopyDetails(); return Task.CompletedTask; });
        var links = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Location = new Point(_ui.Px(20), _ui.Px(17)), BackColor = Theme.Face };
        links.Controls.AddRange([_checkLink, _folderLink, _removeLink, _copyLink]);
        _okButton = new Button { FlatStyle = FlatStyle.System, Size = _ui.Sz(96, 28), Font = _ui.Body };
        _cancelButton = new Button { FlatStyle = FlatStyle.System, Size = _ui.Sz(96, 28), Font = _ui.Body };
        _okButton.Click += async (_, _) => await OnOkAsync();
        _cancelButton.Click += (_, _) => Close();
        _footer.Controls.AddRange([links, _okButton, _cancelButton]);
        _footer.Resize += (_, _) => PlaceFooterButtons();

        Controls.Add(_body);
        Controls.Add(_footer);
        Controls.Add(_header);
        ResumeLayout(true);
    }

    LinkLabel MakeLink(string text, Func<Task> onClick)
    {
        var l = new LinkLabel { Text = text, AutoSize = true, Margin = _ui.Pad(0, 0, 16, 0), LinkBehavior = LinkBehavior.HoverUnderline, Font = _ui.Body };
        l.LinkClicked += async (_, _) => { if (!_busy) await onClick(); };
        return l;
    }

    void PlaceFooterButtons()
    {
        int right = _footer.Width - _ui.Px(20), y = (_footer.Height - _okButton.Height) / 2;
        if (_cancelButton.Visible) { _cancelButton.Location = new Point(right - _cancelButton.Width, y); right = _cancelButton.Left - _ui.Px(8); }
        _okButton.Location = new Point(right - _okButton.Width, y);
    }

    Image? LoadHeaderPicture()
    {
        try
        {
            using var st = typeof(MainForm).Assembly.GetManifestResourceStream("PeakPack.App.app-256.png");
            return st is null ? null : new Bitmap(st);
        }
        catch { return null; }
    }

    void SizeToContent()
    {
        var pref = _body.GetPreferredSize(new Size(_ui.Px(ContentWidth) + _body.Padding.Horizontal, 0));
        int h = _header.Height + pref.Height + _footer.Height;
        // Small screens / high scaling: shrink the mod list rather than run off the screen.
        int avail = Screen.FromPoint(Cursor.Position).WorkingArea.Height - (Height - ClientSize.Height) - _ui.Px(8);
        if (h > avail && _mods.Visible)
        {
            _mods.Height = Math.Max(_ui.Px(70), _mods.Height - (h - avail));
            pref = _body.GetPreferredSize(new Size(_ui.Px(ContentWidth) + _body.Padding.Horizontal, 0));
            h = _header.Height + pref.Height + _footer.Height;
        }
        ClientSize = new Size(_ui.Px(ContentWidth) + _body.Padding.Horizontal, h);
        PlaceFooterButtons();
    }

    // ------------------------------------------------------------------ rendering

    string Host => _s.Config.HostName;
    string Shortcut => _s.Config.ShortcutName;

    void Render()
    {
        SuspendLayout();
        var st = _s.LoadState();
        _gameDir ??= _s.FindGameDir();
        _header.SetText(_s.Config.PackName, _page switch
        {
            Page.Welcome => $"Set up {Host}'s mods for PEAK",
            Page.Done => "Setup complete",
            _ => $"Pack revision {st.InstalledRevision}" + (st.LastLaunchMode is { } lm && st.LastLaunchTime is { } lt
                ? $"   ·   last played {(lm == LaunchMode.Modded ? "with mods" : "normal PEAK")} {Ago(lt)}" : ""),
        });

        _playModded.Visible = _playVanilla.Visible = _page == Page.Main;
        _welcomeText.Visible = _page == Page.Welcome;
        _doneRow.Visible = _page == Page.Done;
        _copyLink.Visible = _problem is not null;
        _checkLink.Visible = _folderLink.Visible = _removeLink.Visible = _page == Page.Main; // keep the Welcome/Done bars uncluttered
        // Hiding controls in a FlowLayoutPanel can reorder them; pin the order.
        Control[] order = [_playModded, _playVanilla, _welcomeText, _doneRow];
        for (int i = 0; i < order.Length; i++) _actions.Controls.SetChildIndex(order[i], i);

        switch (_page)
        {
            case Page.Welcome: RenderWelcome(); break;
            case Page.Done: RenderDone(); break;
            default: RenderMain(st); break;
        }
        if (_problem is { } p) _status.Set(StatusKind.Bad, p.Heading, p.Advice + (_page == Page.Main ? $" You can still play with the mods you have (revision {st.InstalledRevision})." : ""));
        FillModList(st);
        ResumeLayout(true);
        SizeToContent();
    }

    void RenderWelcome()
    {
        var m = _latest;
        int mods = m is null ? 0 : m.Packages.Count(p => !p.IsHelper) + m.Files.Where(f => f.Id != PublishConfig.CompanionId).Select(f => f.Id).Distinct().Count();
        long bytes = m is null ? 0 : m.Loader.Size + m.Packages.Sum(p => p.Size) + m.Files.Sum(f => f.Size);
        if (!_busy && _problem is null)
            _status.Set(StatusKind.Info, "Not installed yet",
                m is null ? "Click Install to set up the mods." : $"Click Install to download {mods} mod{(mods == 1 ? "" : "s")} ({FormatSize(bytes)}). It takes about a minute.");
        _welcomeText.Text =
            "When you click Install, PeakPack will:\n" +
            $"  •  download the mods from Thunderstore (the PEAK mod site) and {Host}'s own mods\n" +
            $"  •  put a \"{Shortcut}\" icon on your desktop for playing with {Host}\n" +
            "  •  leave your normal PEAK alone: Steam's Play button still starts the game without mods" +
            (_gameDir is null ? "\n\nPEAK wasn't found automatically, so you'll be asked where it is." : "");
        _okButton.Text = "Install";
        _cancelButton.Text = "Cancel";
        _okButton.Visible = _cancelButton.Visible = true;
        _okButton.Enabled = !_busy;
        AcceptButton = _okButton;
        _modsHeader.Text = "What's in this pack";
        _whatsNew.Visible = false;
        _modeInfo.Text = "";
        _modeInfo.Visible = false;
    }

    void RenderDone()
    {
        if (_problem is null)
            _status.Set(StatusKind.Good, "All set", $"Your desktop now has a \"{Shortcut}\" icon.");
        var icon = (PictureBox)_doneRow.Controls["icon"]!;
        icon.Image ??= _gameDir is null ? LoadHeaderPicture() : Ui.IconImage(Path.Combine(_gameDir, "PEAK.exe"), _ui.Px(48));
        _doneRow.Controls["name"]!.Text = Shortcut;
        _doneRow.Controls["text"]!.Text = $"Double-click it whenever you play with {Host}. It updates the mods first, then starts PEAK with them. " +
                                         "Starting PEAK from Steam is still the normal game.";
        _okButton.Text = "Play now";
        _cancelButton.Text = "Close";
        _okButton.Visible = _cancelButton.Visible = true;
        _okButton.Enabled = !_busy;
        AcceptButton = _okButton;
        _modsHeader.Text = "What's in this pack";
        _whatsNew.Visible = false;
        _modeInfo.Visible = false;
    }

    void RenderMain(InstallState st)
    {
        bool updating = _pending is { Count: > 0 } || (_latest is not null && _latest.Revision != st.InstalledRevision);
        _playModded.Text = updating ? "Update and play with mods" : "Play with mods";
        _playModded.Note = $"Starts PEAK with {Host}'s mods{(updating ? " after updating them" : "")}. Same as the \"{Shortcut}\" icon on your desktop.";
        _playVanilla.Text = "Play normal PEAK";
        _playVanilla.Note = "No mods. Same as pressing Play in Steam.";
        _playModded.Height = _playModded.PreferredHeightFor(_playModded.Width);
        _playVanilla.Height = _playVanilla.PreferredHeightFor(_playVanilla.Width);
        _playModded.Enabled = _playVanilla.Enabled = !_busy;
        _checkLink.Text = updating ? "Update now" : "Check for updates";
        _okButton.Text = "Close";
        _okButton.Visible = true;
        _cancelButton.Visible = false;
        _okButton.Enabled = true;
        AcceptButton = null;
        CancelButton = _okButton;

        if (!_busy && _problem is null)
        {
            var insp = _gameDir is null ? null : GameFolder.Inspect(_gameDir, st);
            var gv = _gameDir is null ? null : GameFolder.GameVersion(_gameDir);
            if (_gameDir is not null && GameFolder.IsGameRunning(_gameDir))
                _status.Set(StatusKind.Info, "PEAK is running", "Close PEAK to update the mods or to switch between modded and normal PEAK.");
            else if (updating)
                _status.Set(StatusKind.Warn, "Update available: " + (_pending is { Count: > 0 } ? PackDiff.Summary(_pending) : "new pack revision"),
                    (_pending is { Count: > 0 } ? string.Join(" · ", _pending.Where(c => !c.IsHelper).Select(c => c.Friendly).DefaultIfEmpty("Helper libraries updated").Take(4)) + ". " : "") +
                    "Play with mods updates automatically, or click Update now.");
            else if (insp is { SteamLaunchIsModded: true })
                _status.Set(StatusKind.Warn, "Steam would start PEAK with mods", "Something changed your PEAK folder. Click Check for updates to put it back.");
            else if (gv is not null && st.PackGameVersion is { } pv && gv != pv)
                _status.Set(StatusKind.Warn, "PEAK has updated since this pack was made",
                    $"PEAK is now {gv}; the pack was made for {pv}. If modded PEAK misbehaves, play normal PEAK until {Host} updates the pack.");
            else
                _status.Set(StatusKind.Good, "Ready to play",
                    $"You have {Host}'s mods, pack revision {st.InstalledRevision}" + (st.LastSyncTime is { } t ? $", checked {Ago(t)}." : ".") + (_note is null ? "" : " " + _note));
        }

        var shown = _latest ?? Installer.LoadInstalledManifest(_s.Paths);
        var latestNote = shown?.Changelog.FirstOrDefault(c => c.Revision == shown.Revision)?.Notes ?? (shown?.Revision == st.InstalledRevision ? shown?.Notes : null);
        _whatsNew.Text = latestNote is { Length: > 0 } ? $"What's new in revision {shown!.Revision}: {latestNote}" : "";
        _whatsNew.Visible = _whatsNew.Text.Length > 0;
        _modsHeader.Text = "What's in this pack";
        _modeInfo.Visible = true;
        _modeInfo.Text = $"Mods only load when you use Play with mods or the \"{Shortcut}\" icon. Starting PEAK from Steam is always normal PEAK." +
                         (st.ModsRequiredToJoin ? $" To join {Host}'s games, play with mods." : "");
    }

    void FillModList(InstallState st)
    {
        var m = _page == Page.Welcome ? _latest : Installer.LoadInstalledManifest(_s.Paths) ?? _latest;
        _mods.BeginUpdate();
        _mods.Items.Clear();
        _mods.Groups.Clear();
        var gMods = new ListViewGroup("Mods");
        var gOwn = new ListViewGroup($"Made by {Host}");
        var gHelp = new ListViewGroup("Helpers (needed by the mods above)") { CollapsedState = ListViewGroupCollapsedState.Collapsed };
        _mods.Groups.AddRange([gMods, gOwn, gHelp]);
        if (m is not null)
        {
            foreach (var p in m.Packages.OrderBy(p => p.IsHelper).ThenBy(p => p.Title ?? p.Id, StringComparer.OrdinalIgnoreCase))
            {
                var id = PackageId.Parse(p.Id);
                var it = new ListViewItem([p.Title ?? ThunderstoreIndex.Friendly(id.Name), OneLine(p.Description) ?? ""], p.IsHelper ? gHelp : gMods)
                {
                    ToolTipText = $"{id.FullName} {id.Version?.ToString(3)} from Thunderstore" + (p.Description is { } d ? "\n" + d : ""),
                };
                if (p.IsHelper) it.ForeColor = Theme.Muted;
                _mods.Items.Add(it);
            }
            foreach (var g in m.Files.GroupBy(f => f.Id))
            {
                var f = g.First();
                bool companion = f.Id == PublishConfig.CompanionId;
                var it = new ListViewItem([f.Title ?? PackDiff.FriendlyFileTitle(f.Id), OneLine(f.Description) ?? (companion ? "" : $"{Host}'s own mod")], companion ? gHelp : gOwn)
                {
                    ToolTipText = $"{f.Id} {f.Version}",
                };
                if (companion) it.ForeColor = Theme.Muted;
                _mods.Items.Add(it);
            }
        }
        else
        {
            foreach (var p in st.Packages.Keys.Order(StringComparer.OrdinalIgnoreCase))
                _mods.Items.Add(new ListViewItem([ThunderstoreIndex.Friendly(PackageId.Parse(p).Name), ""], gMods));
        }
        gHelp.Header = $"Helpers ({gHelp.Items.Count}, needed by the mods above)";
        _mods.EndUpdate();
        _modsHeader.Visible = _mods.Visible = _mods.Items.Count > 0;
    }

    static string? OneLine(string? s)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        s = s.Replace('\n', ' ').Replace('\r', ' ').Trim();
        return s.Length > 110 ? s[..107].TrimEnd() + "..." : s;
    }

    static string FormatSize(long bytes) => bytes < 1024 * 1024 ? $"{Math.Max(1, bytes / 1024)} KB" : $"{bytes / 1024d / 1024d:0.#} MB";

    static string Ago(DateTimeOffset t)
    {
        var d = DateTimeOffset.Now - t;
        return d.TotalMinutes < 1 ? "just now" : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min ago" : d.TotalDays < 1 ? $"{(int)d.TotalHours} h ago" : t.LocalDateTime.ToString("d MMM");
    }

    // ------------------------------------------------------------------ actions

    async Task OnShownAsync() => await CheckAsync();

    /// <summary>Fetch the host's manifest and work out what an update would change. Changes nothing on disk.</summary>
    async Task CheckAsync()
    {
        if (_busy) return;
        SetBusy(true, _page == Page.Welcome ? "Getting the mod list..." : "Checking for updates...");
        try
        {
            var c = await SyncRunner.CheckAsync(_s);
            _latest = c.Manifest;
            _pending = _page == Page.Main ? c.Changes : null;
            _problem = null;
        }
        catch (Exception ex)
        {
            _s.Paths.Log("Check failed: " + ex);
            _problem = SyncRunner.Describe(ex, Host);
        }
        SetBusy(false);
    }

    async Task OnOkAsync()
    {
        if (_page == Page.Welcome) await InstallAsync();
        else if (_page == Page.Done) { _page = Page.Main; Render(); await PlayAsync(LaunchMode.Modded); }
        else Close();
    }

    void SetBusy(bool busy, string? heading = null)
    {
        _busy = busy;
        UseWaitCursor = busy;
        _bar.Visible = busy;
        if (busy) { _bar.Value = 0; _problem = null; _note = null; _status.Set(StatusKind.Busy, heading ?? "Working...", ""); }
        Render();
    }

    Progress<SyncProgress> MakeProgress(string heading) => new(p =>
    {
        _status.Set(StatusKind.Busy, heading, p.Message);
        if (p.Fraction is { } f) _bar.Value = Math.Clamp((int)(f * 100), 0, 100);
    });

    bool EnsureGameDir()
    {
        _gameDir ??= _s.FindGameDir();
        if (_gameDir is not null) return true;
        TaskDialog.ShowDialog(this, new TaskDialogPage
        {
            Caption = "PeakPack", Heading = "Where is PEAK?", Icon = TaskDialogIcon.Information,
            Text = "PeakPack couldn't find PEAK automatically. Please pick your PEAK folder: the one that contains PEAK.exe (usually Steam\\steamapps\\common\\PEAK).",
        });
        using var dlg = new FolderBrowserDialog { Description = "Select the PEAK folder (contains PEAK.exe)", UseDescriptionForTitle = true };
        while (dlg.ShowDialog(this) == DialogResult.OK)
        {
            if (GameFolder.LooksLikePeak(dlg.SelectedPath)) { _gameDir = dlg.SelectedPath; return true; }
            MessageBox.Show(this, "That folder doesn't contain PEAK.exe. Try again.", "Not the PEAK folder", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        return false;
    }

    bool AskAdopt(string gameDir)
    {
        if (AppSession.Has(_s.RawArgs, "--selftest")) return true;
        var yes = new TaskDialogButton("Move them and continue");
        var page = new TaskDialogPage
        {
            Caption = "PeakPack", Heading = "Your PEAK folder already has mods", Icon = TaskDialogIcon.Warning,
            Text = "They were installed some other way (a BepInEx mod loader). PeakPack will move them into a backup folder (nothing is deleted), " +
                   "so that Steam's Play button starts normal PEAK and mods only load from PeakPack.",
            Buttons = { yes, TaskDialogButton.Cancel },
        };
        return TaskDialog.ShowDialog(this, page) == yes;
    }

    /// <summary>Applies the host's pack. Returns false (with _problem set) on failure.</summary>
    async Task<bool> SyncAsync(string heading)
    {
        if (!EnsureGameDir()) return false;
        SetBusy(true, heading);
        try
        {
            var o = await SyncRunner.RunAsync(_s, _gameDir!, AskAdopt, MakeProgress(heading), _s.PassThroughArgs());
            if (o.RestartingForAppUpdate) { Close(); return false; }
            _latest = o.Manifest;
            _pending = null;
            _problem = null;
            _note = o.Result.Changed && _page == Page.Main ? $"Just updated: {o.Result.Installed.Count} added or updated, {o.Result.Removed.Count} removed." : null;
            SetBusy(false);
            return true;
        }
        catch (OperationCanceledException) { SetBusy(false); return false; }
        catch (Exception ex)
        {
            _s.Paths.Log("Sync failed: " + ex);
            _problem = SyncRunner.Describe(ex, Host);
            SetBusy(false);
            return false;
        }
    }

    async Task InstallAsync()
    {
        if (!await SyncAsync("Installing...") || !_s.IsInstalled) return;
        try { FirstRun.RefreshShortcuts(_s, _gameDir!); }
        catch (Exception ex) { _s.Paths.Log("Shortcut refresh failed: " + ex); }
        _page = Page.Done;
        Render();
    }

    async Task UpdateNowAsync()
    {
        if (_gameDir is not null && GameFolder.IsGameRunning(_gameDir)) { Render(); return; }
        await SyncAsync("Updating...");
    }

    async Task PlayAsync(LaunchMode mode)
    {
        if (_busy || !EnsureGameDir()) return;
        if (GameFolder.IsGameRunning(_gameDir!))
        {
            _status.Set(StatusKind.Info, "PEAK is already running", "Close it first, then press Play again.");
            _s.Paths.Log("Play blocked: PEAK already running");
            return;
        }
        if (mode == LaunchMode.Modded && !await SyncAsync("Checking for updates..."))
        {
            if (_problem is null) return; // cancelled
            var withMods = new TaskDialogButton("Play with the mods I have") { };
            var page = new TaskDialogPage
            {
                Caption = "PeakPack", Heading = _problem.Heading, Icon = TaskDialogIcon.Warning,
                Text = _problem.Advice + $"\n\nYou can still play with the mods you already have, but you might not match {Host}.",
                Buttons = { withMods, TaskDialogButton.Cancel },
            };
            if (!AppSession.Has(_s.RawArgs, "--selftest") && TaskDialog.ShowDialog(this, page) != withMods) return;
        }
        try
        {
            var st = _s.LoadState();
            if (mode == LaunchMode.Modded) { GameFolder.ApplyProxy(_gameDir!, _s.Paths, st); st.Save(_s.Paths); }
            var cmd = Launcher.Launch(mode, _s.Paths, st, _gameDir!, _s.LaunchMethod);
            _problem = null;
            Render();
            _status.Set(StatusKind.Good, mode == LaunchMode.Modded ? "Starting PEAK with mods" : "Starting normal PEAK",
                mode == LaunchMode.Modded ? "Steam is starting PEAK. Have fun." : "Steam is starting PEAK without mods." +
                (_s.LaunchMethod == Launcher.Method.DryRun ? "\n(dry run) " + cmd : ""));
        }
        catch (Exception ex)
        {
            _s.Paths.Log("Launch failed: " + ex);
            _problem = SyncRunner.Describe(ex, Host);
            Render();
        }
    }

    void RemoveEverything()
    {
        var remove = new TaskDialogButton("Remove PeakPack");
        var page = new TaskDialogPage
        {
            Caption = "PeakPack", Heading = "Remove PeakPack and its mods?", Icon = TaskDialogIcon.Warning,
            Text = "Your PEAK folder goes back to exactly how Steam installed it, and the PeakPack icons are removed. Your normal PEAK and your saves are not affected.",
            Buttons = { remove, TaskDialogButton.Cancel },
        };
        if (TaskDialog.ShowDialog(this, page) != remove) return;
        if (_gameDir is not null && GameFolder.IsGameRunning(_gameDir)) { MessageBox.Show(this, "Close PEAK first.", "PEAK is running"); return; }
        var rep = Setup.Uninstall(_s.Paths, _s.SetupOptions, _gameDir);
        var msg = "PEAK is back to normal.";
        if (rep.LeftBehind.Count > 0) msg += "\n\nThese files were changed by something else, so they were left alone:\n" + string.Join("\n", rep.LeftBehind);
        if (rep.BackupDir is not null) msg += $"\n\nThe mods you had before PeakPack are still backed up in:\n{rep.BackupDir}";
        TaskDialog.ShowDialog(this, new TaskDialogPage { Caption = "PeakPack", Heading = "PeakPack has been removed", Text = msg, Icon = TaskDialogIcon.Information });
        Close();
    }

    void CopyDetails()
    {
        var log = File.Exists(_s.Paths.LogPath) ? string.Join(Environment.NewLine, File.ReadLines(_s.Paths.LogPath).TakeLast(40)) : "";
        var text = $"PeakPack {SelfUpdate.CurrentVersion}, revision {_s.LoadState().InstalledRevision}\n{_problem?.Heading}\n{_problem?.Details}\n\n{log}";
        try { Clipboard.SetText(text); _copyLink.Text = "Copied"; } catch { }
    }

    // ------------------------------------------------------------------ test aids

    /// <summary>--selftest DIR: drives the real handlers (welcome, Install, Done, Play with mods, Play normal) and
    /// saves a screenshot after each step. Only meaningful with sandbox overrides.</summary>
    public async Task RunSelfTestAsync(string dir)
    {
        Directory.CreateDirectory(dir);
        await CheckAsync();
        SaveScreenshot(Path.Combine(dir, "1-welcome.png"));
        await InstallAsync();
        SaveScreenshot(Path.Combine(dir, "2-done.png"));
        _page = Page.Main;
        await CheckAsync();
        SaveScreenshot(Path.Combine(dir, "3-ready.png"));
        WriteStatus(Path.Combine(dir, "3-ready.txt"));
        await PlayAsync(LaunchMode.Modded);
        SaveScreenshot(Path.Combine(dir, "4-after-play-modded.png"));
        for (int i = 0; i < 50 && GameFolder.IsGameRunning(_gameDir!); i++) await Task.Delay(200); // fake PEAK.exe exits by itself
        await PlayAsync(LaunchMode.Vanilla);
        WriteStatus(Path.Combine(dir, "status.txt"));
    }

    /// <summary>--selftest-open DIR NAME: open as on a later day, run the update check, screenshot (update available / error states).</summary>
    public async Task RunOpenSelfTestAsync(string dir, string name)
    {
        Directory.CreateDirectory(dir);
        await CheckAsync();
        SaveScreenshot(Path.Combine(dir, name + ".png"));
        WriteStatus(Path.Combine(dir, name + ".txt"));
    }

    void WriteStatus(string path) => File.WriteAllText(path,
        $"page={_page}\nstatus={_status.Kind}: {_status.Heading.Text}\n{_status.Detail.Text}\nwhatsNew={_whatsNew.Text}\nmode={_modeInfo.Text}\nmods={string.Join(" | ", _mods.Items.Cast<ListViewItem>().Select(i => i.Text))}\n" +
        $"size={ClientSize.Width}x{ClientSize.Height}\n" +
        string.Join("\n", _body.Controls.Cast<Control>().Where(c => c.Visible).Select(c => $"{c.GetType().Name} bounds={c.Bounds}")));

    /// <summary>Render the window to a PNG (layout checks without a screen).</summary>
    public void SaveScreenshot(string path)
    {
        using var bmp = new Bitmap(Width, Height);
        DrawToBitmap(bmp, new Rectangle(0, 0, Width, Height));
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
}
