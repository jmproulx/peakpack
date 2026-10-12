using System.Diagnostics;
using System.Text;
using System.Text.Json;
using PeakPack.App.Host;
using PeakPack.Core;

namespace PeakPack.App;

/// <summary>
/// Joshua's Host / Publisher window (PeakPack.exe --host [--host-config publish.json] [--work dir]).
/// A friendly front-end over the same publish.json and <see cref="PublishPipeline"/> the CLI uses: edit the
/// mod list, own builds and lobby settings, check what friends will get, publish revision N, and test the
/// friends' exact pack from a separate profile ("Play as a friend") without touching his own mods.
/// Never syncs into or writes the game folder, except the opt-in lobby-check stamp after a real publish.
/// </summary>
public sealed partial class HostForm : Form
{
    readonly string[] _args;
    readonly string? _selfTestDir;
    readonly bool _scaleFixed;
    readonly string _workDir;
    readonly string? _previousOverride;
    Ui _ui;

    string _configPath;
    PublishConfig _cfg = new();
    bool _dirty;
    bool _populating;
    string? _loadError;

    ThunderstoreIndex? _index;
    PublishPipeline.Prepared? _prepared;
    bool _preparedStale;
    readonly List<string> _prepareWarnings = new();
    (bool Dry, int Revision, string Command)? _released;
    (string Heading, string Detail)? _error;
    string? _friendResult;
    string? _confirmText;

    int _busyDepth;
    string _busyHeading = "", _busyDetail = "";
    readonly StringBuilder _logText = new();

    readonly System.Windows.Forms.Timer _clock = new() { Interval = 30_000 };

    // ---- controls (rebuilt when the DPI changes) ----
    HeaderBand _header = null!;
    StatusRow _status = null!;
    TabControl _tabs = null!;
    Label _pathLabel = null!;
    Button _openBtn = null!, _saveBtn = null!, _closeBtn = null!;

    ListView _mods = null!;
    Button _modAdd = null!, _modImport = null!, _modRemove = null!, _modWho = null!, _modPin = null!;
    TextBox _modTitle = null!, _modDesc = null!;

    ListView _builds = null!;
    Button _buildAdd = null!, _buildSource = null!, _buildRemove = null!, _buildShow = null!;
    TextBox _buildTitle = null!, _buildVersion = null!, _buildDesc = null!;

    RadioButton _warn = null!, _block = null!;
    ListView _live = null!;
    TextBox _livePlugin = null!, _liveSection = null!, _liveKey = null!;
    Button _liveAdd = null!, _liveRemove = null!;

    TextBox _notes = null!;
    Button _check = null!, _friend = null!, _publish = null!;
    Label _friendHint = null!, _changesCaption = null!;
    ListView _changes = null!;
    StatusRow _problems = null!;
    CheckBox _testRun = null!, _stamp = null!;
    TextBox _log = null!;

    TextBox _packName = null!, _hostName = null!, _repo = null!, _loader = null!, _key = null!, _gameDir = null!, _appSource = null!, _appVersion = null!;
    Label _manifestUrl = null!;

    static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    static string DefaultConfigPath => Path.Combine(LocalAppData, "PeakPack-publisher", "publish.json");
    string SettingsPath => Path.Combine(_workDir, "host-settings.json");
    string IndexFile => Path.Combine(_workDir, "peak-index.json");
    string CacheDir => Path.Combine(_workDir, "cache");
    bool SelfTest => _selfTestDir is not null;

    public HostForm(string[] args)
    {
        _args = args;
        _selfTestDir = AppSession.Get(args, "--host-selftest");
        _scaleFixed = AppSession.Get(args, "--ui-scale") is not null;
        _workDir = Path.GetFullPath(AppSession.Get(args, "--work") ?? PublishPipeline.DefaultWorkDir);
        _previousOverride = AppSession.Get(args, "--previous");
        _ui = new Ui(Ui.ScaleFor(args, DeviceDpi));

        AutoScaleMode = AutoScaleMode.None;
        KeyPreview = true;
        try { Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!); } catch { }
        if (SelfTest)
        {
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-3000, -3000);
            ShowInTaskbar = false;
        }
        else StartPosition = FormStartPosition.CenterScreen;

        _configPath = AppSession.Get(args, "--host-config") ?? ReadLastConfigPath() ?? DefaultConfigPath;
        _configPath = Path.GetFullPath(_configPath);
        LoadConfig(_configPath);

        BuildUi(first: true);
        Populate();

        Resize += (_, _) => FitWrapping();
        _clock.Tick += (_, _) => RefreshBuildTimes();
        _clock.Start();
        Shown += async (_, _) => await OnShownAsync();
        DpiChanged += (_, e) => { if (!_scaleFixed && _busyDepth == 0) Rebuild(e.DeviceDpiNew / 96f); };
        FormClosing += OnClosing;
    }

    // ================= config =================

    string? ReadLastConfigPath()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(SettingsPath));
            return doc.RootElement.TryGetProperty("lastConfig", out var p) && p.GetString() is { Length: > 0 } s && File.Exists(s) ? s : null;
        }
        catch { return null; }
    }

    void RememberConfigPath()
    {
        try
        {
            Directory.CreateDirectory(_workDir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new Dictionary<string, string> { ["lastConfig"] = _configPath }, PackManifest.JsonOptions));
        }
        catch { /* only a convenience */ }
    }

    void LoadConfig(string path)
    {
        _loadError = null;
        _prepared = null;
        _released = null;
        _error = null;
        if (File.Exists(path))
        {
            try
            {
                _cfg = PublishConfig.Load(path);
                _dirty = false;
            }
            catch (Exception ex)
            {
                _loadError = $"{path} couldn't be read: {ex.Message}";
                _cfg = NewDefaultConfig();
                _dirty = false;
            }
        }
        else
        {
            _cfg = NewDefaultConfig();
            _dirty = true; // a new file: not saved yet
        }
        // The friend app's version always comes from the exe itself.
        if (_cfg.App is { } app && File.Exists(app.Source) && ExeVersion(app.Source) is { } v && v != app.Version)
        {
            app.Version = v;
            _dirty = true;
        }
        _configPath = path;
        RememberConfigPath();
    }

    static PublishConfig NewDefaultConfig()
    {
        var exe = Path.Combine(RepoRoot(), "publish-out", "PeakPack.exe");
        return new PublishConfig
        {
            PackName = "Joshua's PEAK mods",
            HostName = "Joshua",
            GithubRepo = "jmproulx/peakpack",
            Loader = "BepInEx-BepInExPack_PEAK",
            Companion = "auto",
            SigningKey = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PeakPack-keys", "peakpack-signing.pem"),
            GameDir = SteamLocator.FindGameDir(),
            App = new PublishConfig.AppSource { Source = exe, Version = ExeVersion(exe) ?? "" },
        };
    }

    /// <summary>The FriendInstaller repo (folder with FriendInstaller.sln) above the running exe.</summary>
    static string RepoRoot()
    {
        for (var d = new DirectoryInfo(AppContext.BaseDirectory); d is not null; d = d.Parent)
            if (File.Exists(Path.Combine(d.FullName, "FriendInstaller.sln"))) return d.FullName;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "PeakMods", "FriendInstaller");
    }

    /// <summary>"0.3.0" from the exe's product version (without the +commit suffix), else its file version.</summary>
    static string? ExeVersion(string exe)
    {
        try
        {
            if (!File.Exists(exe)) return null;
            var fv = FileVersionInfo.GetVersionInfo(exe);
            var v = (fv.ProductVersion ?? fv.FileVersion)?.Split('+')[0].Trim();
            if (string.IsNullOrEmpty(v)) return null;
            return Version.TryParse(v, out var parsed) && parsed.Build >= 0 ? parsed.ToString(3) : v;
        }
        catch { return null; }
    }

    /// <summary>Snapshot for background work, so edits can't race the pipeline.</summary>
    PublishConfig CloneConfig() =>
        JsonSerializer.Deserialize<PublishConfig>(JsonSerializer.Serialize(_cfg, PackManifest.JsonOptions), PackManifest.JsonOptions)!;

    bool SaveConfig()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_configPath)!);
            _cfg.Save(_configPath);
            _dirty = false;
            _loadError = null;
            RememberConfigPath();
            UpdateStatus();
            return true;
        }
        catch (Exception ex)
        {
            ShowError("Couldn't save publish.json", ex.Message);
            return false;
        }
    }

    /// <summary>Any edit: remember it's unsaved and that the last check no longer matches.</summary>
    void Changed()
    {
        if (_populating) return;
        _dirty = true;
        if (_prepared is not null) _preparedStale = true;
        _released = null;
        _error = null;
        UpdateStatus();
    }

    // ================= layout =================

    void Rebuild(float scale)
    {
        int tab = _tabs.SelectedIndex;
        SuspendLayout();
        var old = Controls.Cast<Control>().ToList();
        Controls.Clear();
        foreach (var c in old) c.Dispose();
        _ui = new Ui(Math.Max(1f, scale));
        BuildUi(first: false);
        Populate();
        _tabs.SelectedIndex = tab;
        ResumeLayout(true);
    }

    void BuildUi(bool first)
    {
        SuspendLayout();
        Font = _ui.Body;
        BackColor = Theme.Face;
        if (first)
        {
            ClientSize = _ui.Sz(900, 660);
            MinimumSize = SizeFromClientSize(_ui.Sz(760, 560));
            // Fit the screen it opens on (e.g. 1080p at 150 % leaves ~1000 px of height above the taskbar).
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            if (Width > area.Width || Height > area.Height)
                Size = new Size(Math.Min(Width, area.Width), Math.Min(Height, area.Height));
        }

        _header = new HeaderBand(_ui) { Picture = Ui.IconImage(Environment.ProcessPath!, _ui.Px(40)) };

        _status = new StatusRow(_ui, _ui.Px(820));
        _status.Dock = DockStyle.Top;
        var statusHost = new Panel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(20, 12, 20, 10) };
        statusHost.Controls.Add(_status);

        _tabs = new TabControl { Dock = DockStyle.Fill, Padding = new Point(_ui.Px(12), _ui.Px(4)) };
        _tabs.TabPages.AddRange([BuildModsTab(), BuildBuildsTab(), BuildLobbyTab(), BuildPublishTab(), BuildSettingsTab()]);
        var tabsHost = new Panel { Dock = DockStyle.Fill, Padding = _ui.Pad(12, 0, 12, 0) };
        tabsHost.Controls.Add(_tabs);

        Controls.Add(tabsHost);
        Controls.Add(BuildBottomBar());
        Controls.Add(statusHost);
        Controls.Add(_header);

        _tabs.SelectedIndexChanged += (_, _) => { if (_tabs.SelectedTab?.Text == "Own builds") RefreshBuildTimes(); };
        ResumeLayout(true);
        FitWrapping();
    }

    /// <summary>Labels with MaximumSize need their width updated when the window is resized.</summary>
    void FitWrapping()
    {
        if (_status is null) return;
        int w = ClientSize.Width - _ui.Px(40) - _ui.Px(44);
        _status.Heading.MaximumSize = _status.Detail.MaximumSize = new Size(Math.Max(_ui.Px(200), w), 0);
        if (_problems is not null)
        {
            int pw = _tabs.DisplayRectangle.Width - _ui.Px(24) - _ui.Px(44);
            _problems.Heading.MaximumSize = _problems.Detail.MaximumSize = new Size(Math.Max(_ui.Px(200), pw), 0);
        }
    }

    Control BuildBottomBar()
    {
        _pathLabel = new Label { AutoSize = false, Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = Theme.Muted, TextAlign = ContentAlignment.MiddleLeft, Margin = _ui.Pad(0, 0, 12, 0), UseMnemonic = false };
        _openBtn = HostKit.Button(_ui, "&Open...", (_, _) => OpenOther());
        _saveBtn = HostKit.Button(_ui, "&Save", (_, _) => SaveConfig());
        _closeBtn = HostKit.Button(_ui, "Close", (_, _) => Close());
        var flow = HostKit.Flow(_ui);
        foreach (var b in new[] { _openBtn, _saveBtn, _closeBtn }) { b.Margin = _ui.Pad(6, 0, 0, 0); flow.Controls.Add(b); }
        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 1, AutoSize = true, Margin = _ui.Pad(0) };
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.Controls.Add(_pathLabel, 0, 0);
        grid.Controls.Add(flow, 1, 0);
        var bar = new Panel { Dock = DockStyle.Top, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(12, 10, 12, 10) };
        bar.Controls.Add(grid);
        var wrap = new Panel { Dock = DockStyle.Bottom, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(0, 10, 0, 0) };
        wrap.Controls.Add(bar);
        wrap.Controls.Add(new Label { Dock = DockStyle.Top, Height = 2, AutoSize = false, BorderStyle = BorderStyle.Fixed3D });
        return wrap;
    }

    TabPage Page(string title, Control content)
    {
        var p = new TabPage(title) { BackColor = Theme.Window, UseVisualStyleBackColor = false, Padding = _ui.Pad(14, 12, 14, 12) };
        p.Controls.Add(content);
        return p;
    }

    static void Rows(TableLayoutPanel t, params SizeType[] rows)
    {
        t.RowCount = rows.Length;
        foreach (var r in rows) t.RowStyles.Add(r == SizeType.Percent ? new RowStyle(SizeType.Percent, 100) : new RowStyle(r));
    }

    // ---- Mods ----
    TabPage BuildModsTab()
    {
        var t = HostKit.Grid(_ui, 1);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Rows(t, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize, SizeType.AutoSize);

        var intro = HostKit.Text(_ui, "Thunderstore mods in the pack. \"Friends and me\" mods are installed for everyone; \"Only me\" mods (host-side tools) are listed but never installed for friends. Helper libraries are added automatically.", muted: true, bottom: 10);
        t.Controls.Add(intro, 0, 0);

        _mods = HostKit.List(_ui, ("Mod", 150), ("Thunderstore id", 185), ("Version", 100), ("Who needs it", 100), ("What it does", -1));
        t.Controls.Add(_mods, 0, 1);

        _modAdd = HostKit.Button(_ui, "&Add from Thunderstore...", async (_, _) => await AddFromThunderstoreAsync());
        _modImport = HostKit.Button(_ui, "&Import from my game...", async (_, _) => await ImportFromGameAsync());
        _modRemove = HostKit.Button(_ui, "&Remove", (_, _) => RemoveMod());
        _modWho = HostKit.Button(_ui, "Only &me", (_, _) => ToggleWho());
        _modPin = HostKit.Button(_ui, "&Pin version...", async (_, _) => await PinVersionAsync());
        HostKit.SameWidth(_ui, [_modWho], "Friends need it");
        t.Controls.Add(ButtonRow([_modAdd, _modImport], [_modPin, _modWho, _modRemove]), 0, 2);

        var edit = HostKit.Grid(_ui, 2);
        edit.AutoSize = true;
        edit.Margin = _ui.Pad(0, 10, 0, 0);
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _modTitle = HostKit.Box(_ui);
        _modDesc = HostKit.Box(_ui);
        edit.Controls.Add(HostKit.Field(_ui, "&Name friends see:"), 0, 0);
        edit.Controls.Add(_modTitle, 1, 0);
        edit.Controls.Add(HostKit.Field(_ui, "What it &does:"), 0, 1);
        edit.Controls.Add(_modDesc, 1, 1);
        t.Controls.Add(edit, 0, 3);

        _mods.SelectedIndexChanged += (_, _) => OnModSelected();
        _mods.DoubleClick += (_, _) => _modDesc.Focus();
        _mods.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveMod(); };
        _modTitle.TextChanged += (_, _) => EditModText();
        _modDesc.TextChanged += (_, _) => EditModText();
        return Page("Mods", t);
    }

    /// <summary>Button row under a list: "add" buttons on the left, buttons acting on the selection on the right.</summary>
    TableLayoutPanel ButtonRow(Button[] left, Button[] right)
    {
        var row = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, RowCount = 1, Margin = _ui.Pad(0, 8, 0, 0) };
        row.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        row.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var l = HostKit.Flow(_ui);
        var r = HostKit.Flow(_ui);
        r.Anchor = AnchorStyles.Right;
        for (int i = 0; i < left.Length; i++) { left[i].Margin = _ui.Pad(0, 0, 6, 0); l.Controls.Add(left[i]); }
        for (int i = 0; i < right.Length; i++) { right[i].Margin = _ui.Pad(6, 0, 0, 0); r.Controls.Add(right[i]); }
        row.Controls.Add(l, 0, 0);
        row.Controls.Add(r, 1, 0);
        return row;
    }

    // ---- Own builds ----
    TabPage BuildBuildsTab()
    {
        var t = HostKit.Grid(_ui, 1);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Rows(t, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize, SizeType.AutoSize);

        var intro = HostKit.Text(_ui, "Your own DLLs and configs, shipped exactly as they are on disk when you publish. \"Built\" shows when each file last changed.", muted: true, bottom: 10);
        t.Controls.Add(intro, 0, 0);

        _builds = HostKit.List(_ui, ("Title", 200), ("Id", 130), ("Version", 60), ("Built", 90), ("Source file", 210), ("Goes to (in BepInEx)", -1));
        t.Controls.Add(_builds, 0, 1);

        _buildAdd = HostKit.Button(_ui, "&Add DLL...", (_, _) => AddDll());
        _buildSource = HostKit.Button(_ui, "&Change source...", (_, _) => ChangeSource());
        _buildRemove = HostKit.Button(_ui, "&Remove", (_, _) => RemoveBuild());
        _buildShow = HostKit.Button(_ui, "Show in &folder", (_, _) => { if (SelectedBuild() is { } cf) HostKit.OpenFolderOf(cf.Source); });
        t.Controls.Add(ButtonRow([_buildAdd], [_buildShow, _buildSource, _buildRemove]), 0, 2);

        var edit = HostKit.Grid(_ui, 4);
        edit.AutoSize = true;
        edit.Margin = _ui.Pad(0, 10, 0, 0);
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        edit.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, _ui.Px(110)));
        _buildTitle = HostKit.Box(_ui);
        _buildVersion = HostKit.Box(_ui);
        _buildDesc = HostKit.Box(_ui);
        edit.Controls.Add(HostKit.Field(_ui, "&Name friends see:"), 0, 0);
        edit.Controls.Add(_buildTitle, 1, 0);
        var vl = HostKit.Field(_ui, "&Version:");
        vl.Margin = _ui.Pad(16, 0, 10, 0);
        edit.Controls.Add(vl, 2, 0);
        edit.Controls.Add(_buildVersion, 3, 0);
        edit.Controls.Add(HostKit.Field(_ui, "What it &does:"), 0, 1);
        edit.Controls.Add(_buildDesc, 1, 1);
        edit.SetColumnSpan(_buildDesc, 3);
        t.Controls.Add(edit, 0, 3);

        _builds.SelectedIndexChanged += (_, _) => OnBuildSelected();
        _builds.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveBuild(); };
        _buildTitle.TextChanged += (_, _) => EditBuild();
        _buildVersion.TextChanged += (_, _) => EditBuild();
        _buildDesc.TextChanged += (_, _) => EditBuild();
        return Page("Own builds", t);
    }

    // ---- Lobby ----
    TabPage BuildLobbyTab()
    {
        var t = HostKit.Grid(_ui, 1);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Rows(t, SizeType.AutoSize, SizeType.Percent);

        var policy = new GroupBox { Text = "When a friend's pack doesn't match your lobby", Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(12, 6, 12, 10), Margin = _ui.Pad(0, 0, 0, 12), FlatStyle = FlatStyle.System };
        var pg = HostKit.Grid(_ui, 1);
        pg.AutoSize = true;
        Rows(pg, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize, SizeType.AutoSize);
        pg.Controls.Add(HostKit.Text(_ui, "The lobby check (PeakPack's companion plugin) compares everyone's pack revision with yours when they join.", muted: true, bottom: 6), 0, 0);
        _warn = new RadioButton { Text = "&Warn them, and let them stay", AutoSize = true, Margin = _ui.Pad(0, 2, 0, 2), FlatStyle = FlatStyle.System };
        _block = new RadioButton { Text = "&Block: warn them, then leave the lobby after a few seconds (only players on an older revision)", AutoSize = true, Margin = _ui.Pad(0, 2, 0, 2), FlatStyle = FlatStyle.System };
        pg.Controls.Add(_warn, 0, 1);
        pg.Controls.Add(_block, 0, 2);
        policy.Controls.Add(pg);
        t.Controls.Add(policy, 0, 0);

        var live = new GroupBox { Text = "Live settings", Dock = DockStyle.Fill, Padding = _ui.Pad(12, 6, 12, 12), Margin = _ui.Pad(0), FlatStyle = FlatStyle.System };
        var lg = HostKit.Grid(_ui, 2);
        lg.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        lg.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        Rows(lg, SizeType.AutoSize, SizeType.Percent, SizeType.AutoSize);
        var note = HostKit.Text(_ui, "While friends are in your lobby, your values for these BepInEx config entries are used by everyone (for example a jetpack's boost strength). Only entries listed here are ever accepted from the network.", muted: true, bottom: 8);
        lg.Controls.Add(note, 0, 0);
        lg.SetColumnSpan(note, 2);
        _live = HostKit.List(_ui, ("Plugin GUID", 260), ("Section", 150), ("Key", -1));
        lg.Controls.Add(_live, 0, 1);
        _liveRemove = HostKit.Button(_ui, "&Remove", (_, _) => RemoveLiveSetting());
        _liveAdd = HostKit.Button(_ui, "A&dd", (_, _) => AddLiveSetting());
        HostKit.SameWidth(_ui, [_liveRemove, _liveAdd]);
        var rs = HostKit.Flow(_ui, FlowDirection.TopDown);
        rs.Margin = _ui.Pad(10, 0, 0, 0);
        _liveRemove.Margin = _ui.Pad(0);
        rs.Controls.Add(_liveRemove);
        lg.Controls.Add(rs, 1, 1);

        var add = HostKit.Grid(_ui, 6);
        add.AutoSize = true;
        add.Margin = _ui.Pad(0, 10, 0, 0);
        add.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        add.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 46));
        add.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        add.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 27));
        add.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        add.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 27));
        _livePlugin = HostKit.Box(_ui);
        _livePlugin.PlaceholderText = "com.joshua.jetpackboost";
        _liveSection = HostKit.Box(_ui);
        _liveSection.PlaceholderText = "General";
        _liveKey = HostKit.Box(_ui);
        _liveKey.PlaceholderText = "BoostStrength";
        add.Controls.Add(HostKit.Field(_ui, "Plugin:"), 0, 0);
        add.Controls.Add(_livePlugin, 1, 0);
        var sl = HostKit.Field(_ui, "Section:"); sl.Margin = _ui.Pad(12, 0, 8, 0);
        add.Controls.Add(sl, 2, 0);
        add.Controls.Add(_liveSection, 3, 0);
        var kl = HostKit.Field(_ui, "Key:"); kl.Margin = _ui.Pad(12, 0, 8, 0);
        add.Controls.Add(kl, 4, 0);
        add.Controls.Add(_liveKey, 5, 0);
        lg.Controls.Add(add, 0, 2);
        _liveAdd.Anchor = AnchorStyles.Left | AnchorStyles.Bottom;
        _liveAdd.Margin = _ui.Pad(10, 0, 0, 3);
        lg.Controls.Add(_liveAdd, 1, 2);
        live.Controls.Add(lg);
        t.Controls.Add(live, 0, 1);

        _warn.CheckedChanged += (_, _) => SetPolicy();
        _block.CheckedChanged += (_, _) => SetPolicy();
        _live.SelectedIndexChanged += (_, _) => UpdateButtons();
        _live.KeyDown += (_, e) => { if (e.KeyCode == Keys.Delete) RemoveLiveSetting(); };
        foreach (var b in new[] { _livePlugin, _liveSection, _liveKey })
        {
            b.TextChanged += (_, _) => UpdateButtons();
            b.KeyDown += (_, e) => { if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; AddLiveSetting(); } };
        }
        return Page("Lobby", t);
    }

    // ---- Publish ----
    TabPage BuildPublishTab()
    {
        var t = HostKit.Grid(_ui, 1);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        t.RowCount = 8;
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // what's new
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // actions
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // caption
        t.RowStyles.Add(new RowStyle(SizeType.Percent, 60));     // changes
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // problems
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // log caption
        t.RowStyles.Add(new RowStyle(SizeType.Percent, 40));     // log
        t.RowStyles.Add(new RowStyle(SizeType.AutoSize));        // options + publish

        var notesRow = HostKit.Grid(_ui, 2);
        notesRow.AutoSize = true;
        notesRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        notesRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _notes = HostKit.Box(_ui);
        _notes.PlaceholderText = "One line for friends, e.g. \"HeliPilot: smoother landings\"";
        notesRow.Controls.Add(HostKit.Field(_ui, "&What's new:"), 0, 0);
        notesRow.Controls.Add(_notes, 1, 0);
        t.Controls.Add(notesRow, 0, 0);

        var actions = HostKit.Grid(_ui, 3);
        actions.AutoSize = true;
        actions.Margin = _ui.Pad(0, 8, 0, 0);
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        actions.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        _check = HostKit.Button(_ui, "&Check what friends will get", async (_, _) => await CheckAsync());
        _friend = HostKit.Button(_ui, "Play as a &friend", async (_, _) => await PlayAsFriendAsync());
        _check.Margin = _ui.Pad(0, 0, 6, 0);
        _friend.Margin = _ui.Pad(0, 0, 12, 0);
        _friendHint = new Label { AutoSize = true, Dock = DockStyle.Fill, ForeColor = Theme.Muted, TextAlign = ContentAlignment.MiddleLeft, Margin = _ui.Pad(0), UseMnemonic = false };
        actions.Controls.Add(_check, 0, 0);
        actions.Controls.Add(_friend, 1, 0);
        actions.Controls.Add(_friendHint, 2, 0);
        t.Controls.Add(actions, 0, 1);

        _changesCaption = HostKit.Caption(_ui, "What friends will get", top: 14);
        t.Controls.Add(_changesCaption, 0, 2);
        _changes = HostKit.List(_ui, ("Change", 420), ("Version", -1));
        _changes.HeaderStyle = ColumnHeaderStyle.None;
        t.Controls.Add(_changes, 0, 3);

        _problems = new StatusRow(_ui, _ui.Px(700)) { Margin = _ui.Pad(0, 10, 0, 0), Visible = false };
        t.Controls.Add(_problems, 0, 4);

        t.Controls.Add(HostKit.Caption(_ui, "Log", top: 12), 0, 5);
        _log = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, WordWrap = true,
            Font = _ui.Font(8.25f, FontStyle.Regular, "Consolas"), BackColor = Theme.Window, Margin = _ui.Pad(0),
        };
        t.Controls.Add(_log, 0, 6);

        var bottom = HostKit.Grid(_ui, 2);
        bottom.AutoSize = true;
        bottom.Margin = _ui.Pad(0, 10, 0, 0);
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        bottom.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var opts = HostKit.Flow(_ui, FlowDirection.TopDown);
        _testRun = new CheckBox { Text = "&Test run only (don't upload)", AutoSize = true, Margin = _ui.Pad(0, 0, 0, 2), FlatStyle = FlatStyle.System };
        _stamp = new CheckBox { Text = "&Update my own game's lobby check after publishing", AutoSize = true, Margin = _ui.Pad(0), FlatStyle = FlatStyle.System };
        opts.Controls.Add(_testRun);
        opts.Controls.Add(_stamp);
        bottom.Controls.Add(opts, 0, 0);
        _publish = HostKit.Primary(_ui, "Publish", async (_, _) => await PublishAsync());
        _publish.Anchor = AnchorStyles.Right | AnchorStyles.Bottom;
        _publish.Margin = _ui.Pad(0);
        bottom.Controls.Add(_publish, 1, 0);
        t.Controls.Add(bottom, 0, 7);

        _notes.TextChanged += (_, _) => { if (_populating) return; _cfg.Notes = NullIfEmpty(_notes.Text); Changed(); };
        _testRun.CheckedChanged += (_, _) => { if (_populating) return; _publishTestRun = _testRun.Checked; UpdateButtons(); };
        _stamp.CheckedChanged += (_, _) => { if (_populating) return; _stampHost = _stamp.Checked; };
        return Page("Publish", t);
    }

    bool _publishTestRun;
    bool? _stampHost;

    // ---- Settings ----
    TabPage BuildSettingsTab()
    {
        var t = HostKit.Grid(_ui, 1);
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Rows(t, SizeType.AutoSize, SizeType.AutoSize);
        t.Dock = DockStyle.Top;
        t.AutoSize = true;

        GroupBox Group(string title, out TableLayoutPanel g)
        {
            var box = new GroupBox { Text = title, Dock = DockStyle.Fill, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = _ui.Pad(12, 8, 12, 10), Margin = _ui.Pad(0, 0, 0, 12), FlatStyle = FlatStyle.System };
            g = HostKit.Grid(_ui, 3);
            g.AutoSize = true;
            g.Dock = DockStyle.Top; // Fill would hand spare height to the last row and push its label off-centre
            g.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, _ui.Px(150)));
            g.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            box.Controls.Add(g);
            return box;
        }
        void Row(TableLayoutPanel g, string label, Control box, Control? right = null, string? hint = null)
        {
            int r = g.RowCount++;
            g.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            g.Controls.Add(HostKit.Field(_ui, label), 0, r);
            g.Controls.Add(box, 1, r);
            if (right is not null) { right.Margin = _ui.Pad(6, 2, 0, 2); g.Controls.Add(right, 2, r); }
            else g.SetColumnSpan(box, 2);
            if (hint is not null)
            {
                int h = g.RowCount++;
                g.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                var l = HostKit.Text(_ui, hint, muted: true, bottom: 4);
                l.Margin = _ui.Pad(0, 0, 0, 6);
                g.Controls.Add(l, 1, h);
                g.SetColumnSpan(l, 2);
            }
        }

        var pack = Group("Pack", out var pg);
        pg.RowCount = 0;
        _packName = HostKit.Box(_ui);
        _hostName = HostKit.Box(_ui);
        _repo = HostKit.Box(_ui);
        _repo.PlaceholderText = "owner/name";
        _loader = HostKit.Box(_ui);
        _manifestUrl = HostKit.Text(_ui, "", muted: true);
        Row(pg, "Pack &name:", _packName);
        Row(pg, "Your &name:", _hostName, hint: "Shown to friends, e.g. \"Joshua's lobby uses pack revision 7\".");
        Row(pg, "GitHub &repository:", _repo);
        int mr = pg.RowCount++;
        pg.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        _manifestUrl.Margin = _ui.Pad(0, 0, 0, 6);
        pg.Controls.Add(_manifestUrl, 1, mr);
        pg.SetColumnSpan(_manifestUrl, 2);
        Row(pg, "Mod &loader:", _loader);
        t.Controls.Add(pack, 0, 0);

        var files = Group("Files on this PC", out var fg);
        fg.RowCount = 0;
        _key = HostKit.Box(_ui);
        _gameDir = HostKit.Box(_ui);
        _appSource = HostKit.Box(_ui);
        _appVersion = HostKit.Box(_ui, readOnly: true);
        _appVersion.Dock = DockStyle.None;
        _appVersion.Width = _ui.Px(110);
        _appVersion.Anchor = AnchorStyles.Left;
        var browseKey = HostKit.Button(_ui, "Browse...", (_, _) => BrowseFile(_key, "Signing key (*.pem)|*.pem|All files|*.*"));
        var browseGame = HostKit.Button(_ui, "Browse...", (_, _) => BrowseGame());
        var browseApp = HostKit.Button(_ui, "Browse...", (_, _) => { BrowseFile(_appSource, "PeakPack.exe|PeakPack.exe|Programs (*.exe)|*.exe"); RefreshAppVersion(); });
        var refreshApp = HostKit.Button(_ui, "R&efresh", (_, _) => RefreshAppVersion());
        HostKit.SameWidth(_ui, [browseKey, browseGame, browseApp, refreshApp]);
        Row(fg, "&Signing key:", _key, browseKey, "From \"PeakPack.Cli keygen\". Friends' apps only accept packs signed with it. Never put it in a repo.");
        Row(fg, "&PEAK folder:", _gameDir, browseGame, "Your own game. Only read, except the optional lobby-check update after publishing.");
        Row(fg, "Friend &app:", _appSource, browseApp);
        var versionRow = HostKit.Flow(_ui);
        versionRow.Anchor = AnchorStyles.Left;
        _appVersion.Margin = _ui.Pad(0, 3, 10, 3);
        versionRow.Controls.Add(_appVersion);
        versionRow.Controls.Add(new Label { AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Theme.Muted, Margin = _ui.Pad(0, 6, 0, 0),
            Text = "Read from the file; every release carries this exe." });
        Row(fg, "App version:", versionRow, refreshApp);
        t.Controls.Add(files, 0, 1);

        _packName.TextChanged += (_, _) => { if (_populating) return; _cfg.PackName = _packName.Text.Trim(); Changed(); UpdateHeader(); };
        _hostName.TextChanged += (_, _) => { if (_populating) return; _cfg.HostName = _hostName.Text.Trim(); Changed(); };
        _repo.TextChanged += (_, _) => { if (_populating) return; _cfg.GithubRepo = NullIfEmpty(_repo.Text); Changed(); UpdateManifestUrl(); };
        _loader.TextChanged += (_, _) => { if (_populating) return; _cfg.Loader = NullIfEmpty(_loader.Text) ?? "BepInEx-BepInExPack_PEAK"; Changed(); };
        _key.TextChanged += (_, _) => { if (_populating) return; _cfg.SigningKey = NullIfEmpty(_key.Text); Changed(); };
        _gameDir.TextChanged += (_, _) => { if (_populating) return; _cfg.GameDir = NullIfEmpty(_gameDir.Text); Changed(); UpdateButtons(); };
        _appSource.TextChanged += (_, _) =>
        {
            if (_populating) return;
            var s = NullIfEmpty(_appSource.Text);
            if (s is null) _cfg.App = null;
            else { _cfg.App ??= new PublishConfig.AppSource(); _cfg.App.Source = s; }
            Changed();
        };
        _appSource.Leave += (_, _) => RefreshAppVersion();
        var page = Page("Settings", t);
        page.AutoScroll = true; // nothing is ever clipped, whatever the scale
        return page;
    }

    static string? NullIfEmpty(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    // ================= populate =================

    void Populate()
    {
        _populating = true;
        try
        {
            _notes.Text = _cfg.Notes ?? "";
            _packName.Text = _cfg.PackName;
            _hostName.Text = _cfg.HostName;
            _repo.Text = _cfg.GithubRepo ?? "";
            _loader.Text = _cfg.Loader;
            _key.Text = _cfg.SigningKey ?? "";
            _gameDir.Text = _cfg.GameDir ?? "";
            _appSource.Text = _cfg.App?.Source ?? "";
            _appVersion.Text = _cfg.App?.Version ?? "";
            _warn.Checked = (_cfg.Lobby?.MismatchPolicy ?? MismatchPolicy.Warn) == MismatchPolicy.Warn;
            _block.Checked = !_warn.Checked;
            _testRun.Checked = SelfTest || _publishTestRun;
            _testRun.Enabled = !SelfTest;
            _stamp.Checked = _stampHost ?? HostBepInExDir is not null;
            _log.Text = _logText.ToString();
            _log.SelectionStart = _log.TextLength;
            _log.ScrollToCaret();
        }
        finally { _populating = false; }
        RefreshMods();
        RefreshBuilds();
        RefreshLive();
        RefreshChanges();
        UpdateManifestUrl();
        UpdateHeader();
        UpdateStatus();
    }

    string? HostBepInExDir => _cfg.GameDir is { } g && Directory.Exists(Path.Combine(g, "BepInEx")) ? Path.Combine(g, "BepInEx") : null;

    void UpdateHeader()
    {
        _header.SetText("Publish for friends", $"Build the next revision of {(_cfg.PackName.Length > 0 ? _cfg.PackName : "your pack")} and send it to everyone.");
        Text = $"PeakPack Host - {_cfg.PackName}{(_dirty ? " *" : "")}";
        _pathLabel.Text = _configPath + (_dirty ? "  (unsaved changes)" : "");
    }

    void UpdateManifestUrl() =>
        _manifestUrl.Text = _cfg.EffectiveManifestUrl is { } u ? "Friends' apps read the pack from " + u : "Set the repository (owner/name) that releases are uploaded to.";

    // ---- Mods list ----
    sealed record ModRow(string Entry, bool HostOnly)
    {
        public PackageId? Id { get; } = TryParse(Entry);
        static PackageId? TryParse(string e) { try { return PackageId.Parse(e); } catch (FormatException) { return null; } }
        public string Key => Id?.FullName ?? Entry;
    }

    void RefreshMods()
    {
        var selected = SelectedMod()?.Key;
        _mods.BeginUpdate();
        _mods.Items.Clear();
        foreach (var e in _cfg.Mods) _mods.Items.Add(ModItem(new ModRow(e, false)));
        foreach (var e in _cfg.HostOnly) _mods.Items.Add(ModItem(new ModRow(e, true)));
        foreach (ListViewItem it in _mods.Items)
            if (((ModRow)it.Tag!).Key.Equals(selected, StringComparison.OrdinalIgnoreCase)) { it.Selected = true; it.Focused = true; it.EnsureVisible(); }
        _mods.EndUpdate();
        OnModSelected();
    }

    ListViewItem ModItem(ModRow row)
    {
        var id = row.Id;
        var pkg = id is null ? null : _index?.Find(id.Value.FullName);
        _cfg.ModInfo.TryGetValue(row.Key, out var info);
        var title = NullIfEmpty(info?.Title) ?? pkg?.FriendlyName ?? (id is null ? row.Entry : ThunderstoreIndex.Friendly(id.Value.Name));
        string version; bool badVersion = false;
        if (id?.Version is { } v)
        {
            badVersion = pkg is not null && pkg.Versions.All(x => x.Version != v);
            version = v.ToString(3) + (badVersion ? " (missing)" : " (pinned)");
        }
        else version = pkg is null ? "latest" : $"latest ({pkg.Latest.Version.ToString(3)})";

        string desc; Color descColor;
        if (NullIfEmpty(info?.Description) is { } d) { desc = d; descColor = Theme.Text; }
        else if (id is null) { desc = "Not a Thunderstore id (Namespace-Name or Namespace-Name-1.2.3)"; descColor = Theme.Bad; }
        else if (pkg is not null) { desc = pkg.Latest.Description.Trim(); descColor = Theme.Muted; }
        else if (_index is not null) { desc = "Not found on Thunderstore"; descColor = Theme.Bad; }
        else { desc = ""; descColor = Theme.Muted; }

        var it = HostKit.Row(title, row.Key, version, row.HostOnly ? "Only me" : "Friends and me", desc);
        it.Tag = row;
        it.SubItems[1].ForeColor = Theme.Muted;
        it.SubItems[2].ForeColor = badVersion ? Theme.Bad : Theme.Muted;
        it.SubItems[4].ForeColor = descColor;
        it.ToolTipText = desc.Length > 0 ? $"{row.Entry}\n{desc}" : row.Entry;
        return it;
    }

    ModRow? SelectedMod() => _mods?.SelectedItems.Count == 1 ? (ModRow)_mods.SelectedItems[0].Tag! : null;

    void OnModSelected()
    {
        var row = SelectedMod();
        _populating = true;
        try
        {
            if (row is null)
            {
                _modTitle.Text = _modDesc.Text = "";
                _modTitle.PlaceholderText = _modDesc.PlaceholderText = "Select a mod above";
            }
            else
            {
                var pkg = row.Id is { } id ? _index?.Find(id.FullName) : null;
                _cfg.ModInfo.TryGetValue(row.Key, out var info);
                _modTitle.Text = info?.Title ?? "";
                _modDesc.Text = info?.Description ?? "";
                _modTitle.PlaceholderText = pkg?.FriendlyName ?? (row.Id is { } i2 ? ThunderstoreIndex.Friendly(i2.Name) : "");
                _modDesc.PlaceholderText = pkg is not null ? pkg.Latest.Description.Trim() + "  (Thunderstore's text)" : "One line: why it's in the pack";
            }
        }
        finally { _populating = false; }
        UpdateButtons();
    }

    void EditModText()
    {
        if (_populating || SelectedMod() is not { } row) return;
        var t = _cfg.ModInfo.GetValueOrDefault(row.Key) ?? new PublishConfig.ModText();
        t.Title = NullIfEmpty(_modTitle.Text);
        t.Description = NullIfEmpty(_modDesc.Text);
        if (t.Title is null && t.Description is null) _cfg.ModInfo.Remove(row.Key);
        else _cfg.ModInfo[row.Key] = t;
        // Update the row in place (rebuilding the list would steal focus from the text box).
        var it = _mods.SelectedItems[0];
        var fresh = ModItem(row);
        for (int i = 0; i < it.SubItems.Count; i++) { it.SubItems[i].Text = fresh.SubItems[i].Text; it.SubItems[i].ForeColor = fresh.SubItems[i].ForeColor; }
        Changed();
    }

    // ---- Own builds list ----
    sealed record BuildRow(PublishConfig.CustomFile? File, bool Companion);

    void RefreshBuilds()
    {
        var selected = SelectedBuild();
        _builds.BeginUpdate();
        _builds.Items.Clear();
        foreach (var cf in _cfg.CustomFiles)
        {
            var exists = File.Exists(cf.Source);
            var it = HostKit.Row(cf.Title ?? _cfg.ModInfo.GetValueOrDefault(cf.Id)?.Title ?? ThunderstoreIndex.Friendly(cf.Id.Contains('-') ? cf.Id[(cf.Id.IndexOf('-') + 1)..] : cf.Id),
                cf.Id, cf.Version ?? "", exists ? HostKit.Ago(File.GetLastWriteTime(cf.Source)) : "file missing", HostKit.ShortPath(cf.Source), cf.Dest);
            it.Tag = new BuildRow(cf, false);
            it.SubItems[1].ForeColor = Theme.Muted;
            it.SubItems[3].ForeColor = exists ? Theme.Text : Theme.Bad;
            it.SubItems[4].ForeColor = exists ? Theme.Muted : Theme.Bad;
            it.SubItems[5].ForeColor = Theme.Muted;
            it.ToolTipText = exists ? $"{cf.Source}\nLast changed {File.GetLastWriteTime(cf.Source):g}" : $"Not found: {cf.Source}";
            if (ReferenceEquals(cf, selected)) { it.Selected = true; it.Focused = true; }
            _builds.Items.Add(it);
        }

        // The lobby check is added automatically (companion "auto"); shown read-only so it's clear whether it ships.
        if (_cfg.CustomFiles.All(c => !c.Id.Equals(PublishConfig.CompanionId, StringComparison.OrdinalIgnoreCase)))
        {
            string version = "", built, source;
            bool ok = false;
            if (string.IsNullOrEmpty(_cfg.Companion)) { built = "left out"; source = "companion is turned off in publish.json (\"companion\": \"\")"; }
            else if (_cfg.ResolveCompanionSource() is { } comp && File.Exists(comp))
            {
                ok = true;
                version = ExeVersion(comp) ?? "";
                built = HostKit.Ago(File.GetLastWriteTime(comp));
                source = HostKit.ShortPath(comp);
            }
            else { built = "not found"; source = "Build src/PeakPack.Companion (Release) - without it friends get no in-game lobby check"; }
            var it = HostKit.Row("Lobby check (PeakPack companion)", PublishConfig.CompanionId, version, built, source, PublishConfig.CompanionDest);
            it.Tag = new BuildRow(null, true);
            foreach (ListViewItem.ListViewSubItem s in it.SubItems) s.ForeColor = SystemColors.GrayText;
            if (!ok) { it.SubItems[3].ForeColor = Theme.Bad; it.SubItems[4].ForeColor = Theme.Bad; }
            it.ToolTipText = "Added automatically to every revision (read-only here).";
            _builds.Items.Add(it);
        }
        _builds.EndUpdate();
        OnBuildSelected();
    }

    void RefreshBuildTimes()
    {
        if (_builds is null || _builds.IsDisposed) return;
        foreach (ListViewItem it in _builds.Items)
            if (it.Tag is BuildRow { File: { } cf } && File.Exists(cf.Source))
                it.SubItems[3].Text = HostKit.Ago(File.GetLastWriteTime(cf.Source));
    }

    PublishConfig.CustomFile? SelectedBuild() => _builds?.SelectedItems.Count == 1 && _builds.SelectedItems[0].Tag is BuildRow { File: { } f } ? f : null;

    void OnBuildSelected()
    {
        var cf = SelectedBuild();
        _populating = true;
        try
        {
            _buildTitle.Text = cf?.Title ?? "";
            _buildVersion.Text = cf?.Version ?? "";
            _buildDesc.Text = cf?.Description ?? "";
            _buildTitle.PlaceholderText = cf is null ? "Select a file above" : ThunderstoreIndex.Friendly(cf.Id.Contains('-') ? cf.Id[(cf.Id.IndexOf('-') + 1)..] : cf.Id);
            _buildDesc.PlaceholderText = cf is null ? "" : "One line: what it does";
        }
        finally { _populating = false; }
        UpdateButtons();
    }

    void EditBuild()
    {
        if (_populating || SelectedBuild() is not { } cf) return;
        cf.Title = NullIfEmpty(_buildTitle.Text);
        cf.Version = NullIfEmpty(_buildVersion.Text);
        cf.Description = NullIfEmpty(_buildDesc.Text);
        var it = _builds.SelectedItems[0];
        it.SubItems[0].Text = cf.Title ?? _buildTitle.PlaceholderText;
        it.SubItems[2].Text = cf.Version ?? "";
        Changed();
    }

    // ---- Lobby ----
    void RefreshLive()
    {
        _live.BeginUpdate();
        _live.Items.Clear();
        foreach (var ls in _cfg.Lobby?.LiveSettings ?? [])
        {
            var it = HostKit.Row(ls.Plugin, ls.Section, ls.Key);
            it.Tag = ls;
            _live.Items.Add(it);
        }
        _live.EndUpdate();
        UpdateButtons();
    }

    void SetPolicy()
    {
        if (_populating) return;
        var want = _block.Checked ? MismatchPolicy.Block : MismatchPolicy.Warn;
        if ((_cfg.Lobby?.MismatchPolicy ?? MismatchPolicy.Warn) == want) return;
        (_cfg.Lobby ??= new LobbySettings()).MismatchPolicy = want;
        Changed();
    }

    void AddLiveSetting()
    {
        var (p, s, k) = (_livePlugin.Text.Trim(), _liveSection.Text.Trim(), _liveKey.Text.Trim());
        if (p.Length == 0 || s.Length == 0 || k.Length == 0) return;
        if ((p + s + k).IndexOfAny(['|', '\r', '\n']) >= 0) { ShowError("That setting can't be used", "Plugin, section and key can't contain the | character."); return; }
        var lobby = _cfg.Lobby ??= new LobbySettings();
        if (!lobby.LiveSettings.Any(x => x.Plugin.Equals(p, StringComparison.OrdinalIgnoreCase) && x.Section.Equals(s, StringComparison.OrdinalIgnoreCase) && x.Key.Equals(k, StringComparison.OrdinalIgnoreCase)))
            lobby.LiveSettings.Add(new LiveSetting { Plugin = p, Section = s, Key = k });
        _liveKey.Text = "";
        _liveKey.Focus();
        RefreshLive();
        Changed();
    }

    void RemoveLiveSetting()
    {
        if (_live.SelectedItems.Count != 1 || _cfg.Lobby is null) return;
        _cfg.Lobby.LiveSettings.Remove((LiveSetting)_live.SelectedItems[0].Tag!);
        RefreshLive();
        Changed();
    }

    // ================= status =================

    void UpdateStatus()
    {
        if (_status is null || _status.IsDisposed) return;
        var (kind, heading, detail) = ComputeStatus();
        _status.Set(kind, heading, detail);
        UpdateHeader();
        UpdateButtons();
    }

    (StatusKind, string, string) ComputeStatus()
    {
        if (_busyDepth > 0) return (StatusKind.Busy, _busyHeading, _busyDetail);
        if (_error is { } e) return (StatusKind.Bad, e.Heading, e.Detail);
        if (_loadError is not null) return (StatusKind.Bad, "publish.json couldn't be read", _loadError + " Showing a new pack instead; saving will replace that file.");
        if (_released is { Dry: false } r) return (StatusKind.Good, $"Published revision {r.Revision}", "Friends get it the next time they start PEAK (Modded). \"What's new\" was cleared for the next revision.");
        if (_released is { Dry: true } d && _prepared is not null && !_preparedStale)
            return (StatusKind.Good, $"Test run finished for revision {d.Revision}", "Nothing was uploaded. The exact gh command is in the log on the Publish tab. Untick \"Test run only\" to publish for real.");

        if (string.IsNullOrWhiteSpace(_cfg.SigningKey) || !File.Exists(_cfg.SigningKey))
            return (StatusKind.Warn, "Not signed: set your signing key", "Friends' apps only accept a signed pack. Pick your .pem key on the Settings tab.");
        if (!_cfg.HasRealRepo)
            return (StatusKind.Warn, "No GitHub repository set", "Set the repository (owner/name) releases are uploaded to on the Settings tab.");
        if (_cfg.App is null || !File.Exists(_cfg.App.Source))
            return (StatusKind.Warn, "Friend app not found", "Every release must carry PeakPack.exe, or the friends' download link breaks. Set it on the Settings tab.");
        var missing = _cfg.CustomFiles.Where(c => !File.Exists(c.Source)).ToList();
        if (missing.Count > 0)
            return (StatusKind.Warn, $"{missing.Count} own build{(missing.Count == 1 ? " is" : "s are")} missing", $"{Path.GetFileName(missing[0].Source)} isn't at {Path.GetDirectoryName(missing[0].Source)}. Fix it on the Own builds tab.");

        if (_prepared is { } p && !_preparedStale)
        {
            int n = p.Manifest.Revision;
            if (!p.CanRelease) return (StatusKind.Bad, $"Revision {n} can't be published yet", p.Problems[0]);
            var summary = p.Previous is null ? "first publish" : PackDiff.Summary(p.Changes);
            return (StatusKind.Good, $"Ready to publish revision {n}: {summary}",
                _dirty ? "Includes your unsaved changes; publishing saves publish.json first." : "Look over the list on the Publish tab, then press \"Publish revision " + n + "\".");
        }
        if (_prepared is not null && _preparedStale)
            return (StatusKind.Info, "Changed since the last check", "Press \"Check what friends will get\" on the Publish tab to see the new revision.");
        if (_dirty)
            return (StatusKind.Info, "Unsaved changes", "Save (Ctrl+S) so the CLI and your agent see the same pack. Publishing also saves.");
        return (StatusKind.Info, "Ready when you are", "On the Publish tab, press \"Check what friends will get\" to build the next revision and see exactly what changes.");
    }

    void UpdateButtons()
    {
        if (_check is null || _check.IsDisposed) return;
        bool idle = _busyDepth == 0;
        var mod = SelectedMod();
        _modAdd.Enabled = _modImport.Enabled = idle;
        _modRemove.Enabled = _modWho.Enabled = idle && mod is not null;
        _modPin.Enabled = idle && mod?.Id is not null;
        _modTitle.Enabled = _modDesc.Enabled = mod is not null;
        var whoText = mod is { HostOnly: true } ? "Friends need it" : "Only &me";
        if (_modWho.Text != whoText) _modWho.Text = whoText;

        var cf = SelectedBuild();
        _buildAdd.Enabled = idle;
        _buildSource.Enabled = _buildRemove.Enabled = idle && cf is not null;
        _buildShow.Enabled = cf is not null && File.Exists(cf.Source);
        _buildTitle.Enabled = _buildVersion.Enabled = _buildDesc.Enabled = cf is not null;

        _liveRemove.Enabled = _live.SelectedItems.Count == 1;
        _liveAdd.Enabled = _livePlugin.Text.Trim().Length > 0 && _liveSection.Text.Trim().Length > 0 && _liveKey.Text.Trim().Length > 0;

        _check.Enabled = idle;
        var (canFriend, why) = FriendViewAvailability();
        _friend.Enabled = idle && canFriend;
        _friendHint.Text = why;

        bool fresh = _prepared is not null && !_preparedStale;
        bool alreadyReleased = _released is { Dry: false };
        _publish.Text = fresh ? $"Publish revision {_prepared!.Manifest.Revision}" : "Publish";
        _publish.Enabled = idle && fresh && !alreadyReleased && (_prepared!.CanRelease || _testRun.Checked) && _cfg.HasRealRepo;
        _stamp.Enabled = HostBepInExDir is not null && !_testRun.Checked;

        _openBtn.Enabled = _saveBtn.Enabled = idle;
        _tabs.Cursor = idle ? Cursors.Default : Cursors.AppStarting;
    }

    (bool, string) FriendViewAvailability()
    {
        var g = _cfg.GameDir;
        if (!GameFolder.LooksLikePeak(g)) return (false, "Set your PEAK folder on the Settings tab to test the friends' pack.");
        if (!SelfTest && !File.Exists(Path.Combine(g!, GameFolder.ProxyDll)))
            return (false, "Needs BepInEx's winhttp.dll in your PEAK folder (your own modded setup) to start a separate test copy.");
        bool fresh = _prepared is not null && !_preparedStale;
        if (!fresh && !File.Exists(Path.Combine(_workDir, "current", "manifest.json")))
            return (false, "Check what friends will get first; then you can play exactly that.");
        return (true, fresh ? $"Starts PEAK with exactly revision {_prepared!.Manifest.Revision}'s mods, from a separate copy." : "Starts PEAK with the last published pack, from a separate copy.");
    }

    // ================= busy / log / errors =================

    void BeginBusy(string heading, string detail = "")
    {
        _busyDepth++;
        _busyHeading = heading;
        _busyDetail = detail;
        _error = null;
        UseWaitCursor = false;
        UpdateStatus();
    }

    void BusyDetail(string detail)
    {
        if (_busyDepth == 0) return;
        _busyDetail = detail;
        _status.Set(StatusKind.Busy, _busyHeading, detail);
    }

    void EndBusy()
    {
        _busyDepth = Math.Max(0, _busyDepth - 1);
        UpdateStatus();
    }

    /// <summary>Thread-safe log line (the pipeline logs from worker threads).</summary>
    void Log(string line)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { try { BeginInvoke(() => Log(line)); } catch (InvalidOperationException) { } return; }
        _logText.AppendLine(line);
        if (_log is not null && !_log.IsDisposed) _log.AppendText(line + Environment.NewLine);
        var t = line.Trim();
        if (t.StartsWith("WARNING:", StringComparison.Ordinal)) _prepareWarnings.Add(t["WARNING:".Length..].Trim());
        if (_busyDepth > 0 && t.Length > 0) BusyDetail(t.Length > 140 ? t[..140] + "..." : t);
    }

    void ShowError(string heading, string detail)
    {
        _error = (heading, detail);
        Log("ERROR: " + heading + ": " + detail);
        UpdateStatus();
        if (!SelfTest && Visible)
            TaskDialog.ShowDialog(this, new TaskDialogPage { Caption = "PeakPack Host", Heading = heading, Text = detail, Icon = TaskDialogIcon.Error, Buttons = { TaskDialogButton.OK } });
    }

    static string Friendly(Exception ex) => ex switch
    {
        HttpRequestException => "Couldn't reach the internet (GitHub or Thunderstore). " + ex.Message,
        TaskCanceledException => "A download timed out. Try again.",
        KeyNotFoundException => ex.Message + " Check the Mods tab.",
        UnauthorizedAccessException or IOException => ex.Message,
        _ => ex.Message,
    };

    // ================= window =================

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == (Keys.Control | Keys.S)) { if (_busyDepth == 0) SaveConfig(); return true; }
        if (keyData == (Keys.Control | Keys.O)) { if (_busyDepth == 0) OpenOther(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    void OnClosing(object? sender, FormClosingEventArgs e)
    {
        if (SelfTest) return;
        if (_busyDepth > 0)
        {
            var r = TaskDialog.ShowDialog(this, new TaskDialogPage
            {
                Caption = "PeakPack Host", Heading = "Still working", Icon = TaskDialogIcon.Warning,
                Text = "PeakPack is in the middle of something (" + _busyHeading.ToLowerInvariant() + "). Close anyway?",
                Buttons = { TaskDialogButton.Yes, TaskDialogButton.No },
            });
            if (r != TaskDialogButton.Yes) { e.Cancel = true; return; }
        }
        if (!AskSaveChanges()) e.Cancel = true;
    }

    /// <summary>False = the user cancelled.</summary>
    bool AskSaveChanges()
    {
        if (!_dirty) return true;
        var save = new TaskDialogButton("&Save");
        var discard = new TaskDialogButton("&Don't save");
        var r = TaskDialog.ShowDialog(this, new TaskDialogPage
        {
            Caption = "PeakPack Host", Heading = "Save changes to publish.json?", Text = _configPath,
            Buttons = { save, discard, TaskDialogButton.Cancel }, DefaultButton = save,
        });
        if (r == save) return SaveConfig();
        return r == discard;
    }

    void OpenOther()
    {
        if (!AskSaveChanges()) return;
        using var dlg = new OpenFileDialog
        {
            Title = "Open publish.json", Filter = "Publish settings (*.json)|*.json|All files|*.*",
            InitialDirectory = Path.GetDirectoryName(_configPath), FileName = Path.GetFileName(_configPath),
        };
        if (dlg.ShowDialog(this) != DialogResult.OK) return;
        LoadConfig(dlg.FileName);
        _preparedStale = false;
        Populate();
    }

    void BrowseFile(TextBox target, string filter)
    {
        using var dlg = new OpenFileDialog { Filter = filter, CheckFileExists = true };
        if (File.Exists(target.Text)) { dlg.InitialDirectory = Path.GetDirectoryName(target.Text); dlg.FileName = Path.GetFileName(target.Text); }
        if (dlg.ShowDialog(this) == DialogResult.OK) target.Text = dlg.FileName;
    }

    void BrowseGame()
    {
        using var dlg = new FolderBrowserDialog { Description = "Select your PEAK folder (contains PEAK.exe)", UseDescriptionForTitle = true, SelectedPath = _gameDir.Text };
        while (dlg.ShowDialog(this) == DialogResult.OK)
        {
            if (GameFolder.LooksLikePeak(dlg.SelectedPath)) { _gameDir.Text = dlg.SelectedPath; return; }
            TaskDialog.ShowDialog(this, new TaskDialogPage { Caption = "PeakPack Host", Heading = "That isn't the PEAK folder", Text = "Pick the folder that contains PEAK.exe (usually steamapps\\common\\PEAK).", Icon = TaskDialogIcon.Warning });
        }
    }

    void RefreshAppVersion()
    {
        if (_cfg.App is not { } app) { _appVersion.Text = ""; return; }
        var v = ExeVersion(app.Source);
        if (v is null) { _appVersion.Text = "not found"; return; }
        _appVersion.Text = v;
        if (app.Version != v) { app.Version = v; Changed(); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _clock.Dispose();
        base.Dispose(disposing);
    }
}
