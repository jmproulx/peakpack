using PeakPack.Core;

namespace PeakPack.App.Host;

/// <summary>
/// "Publish hotfix" / "Roll back": one own build as the next pack revision (<see cref="HotfixRunner"/>).
/// Shows the DLL check, runs (test run by default) and keeps the log and the outcome on screen.
/// </summary>
sealed class HotfixDialog : HostKit.Dialog
{
    public delegate Task<HotfixRunner.Outcome> Runner(HotfixRunner.Options options, Action<string> log);

    readonly Runner _run;
    readonly PublishConfig.CustomFile _cf;
    readonly bool _rollback;
    readonly TextBox _dll, _version, _notes, _log;
    readonly Label _check;
    readonly CheckBox _test;
    readonly StatusRow _result;
    readonly Button _go, _close;
    readonly Button? _browse;
    bool _running;

    public bool PublishedForReal { get; private set; }
    public HotfixRunner.Outcome? Outcome { get; private set; }
    public string? Error { get; private set; }

    public HotfixDialog(Ui ui, PublishConfig.CustomFile cf, string title, string? previousBuild, bool forceTestRun, Runner run)
        : base(ui, previousBuild is null ? $"Publish hotfix - {title}" : $"Roll back - {title}", 660, 540)
    {
        _run = run;
        _cf = cf;
        _rollback = previousBuild is not null;

        var root = HostKit.Grid(ui, 1);
        root.Padding = ui.Pad(12, 12, 12, 8);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        root.RowCount = 5;
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(HostKit.Text(ui, _rollback
            ? $"Publishes the build of {title} that friends had before, as the next pack revision. Nothing else in the pack changes."
            : $"Publishes a new build of {title} as the next pack revision. Nothing else in the pack changes. Friends in a test lobby who opted in get it live; everyone else at their next start.", bottom: 10), 0, 0);

        var form = HostKit.Grid(ui, 3);
        form.AutoSize = true;
        form.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        form.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        form.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        int r = 0;
        void Add(string label, Control c, Control? right = null)
        {
            form.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            form.Controls.Add(HostKit.Field(ui, label), 0, r);
            form.Controls.Add(c, 1, r);
            if (right is not null) { right.Margin = ui.Pad(6, 2, 0, 2); form.Controls.Add(right, 2, r); }
            else form.SetColumnSpan(c, 2);
            r++;
        }

        _dll = HostKit.Box(ui, readOnly: _rollback);
        _dll.Text = previousBuild ?? cf.Source;
        if (!_rollback)
        {
            _browse = HostKit.Button(ui, "Browse...", (_, _) => Browse());
            Add("&New build:", _dll, _browse);
        }
        else Add("Previous build:", _dll);

        _check = HostKit.Text(ui, "");
        _check.Margin = ui.Pad(0, 0, 0, 6);
        form.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        form.Controls.Add(_check, 1, r);
        form.SetColumnSpan(_check, 2);
        r++;

        var bumped = Hotfix.BumpVersion(cf.Version);
        _version = HostKit.Box(ui);
        _version.Dock = DockStyle.None;
        _version.Anchor = AnchorStyles.Left;
        _version.Width = ui.Px(110);
        _version.Text = bumped;
        Add("&Version:", _version);

        _notes = HostKit.Box(ui);
        _notes.PlaceholderText = _rollback ? $"Rolled back {title} to the previous build." : $"Hotfix: {title} {bumped}";
        Add("What's ne&w:", _notes);

        _test = new CheckBox { Text = "&Test run only (don't upload)", AutoSize = true, Checked = true, Enabled = !forceTestRun, FlatStyle = FlatStyle.System, Margin = ui.Pad(0, 4, 0, 0), Tag = forceTestRun ? "forced" : null };
        form.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        form.Controls.Add(_test, 1, r);
        form.SetColumnSpan(_test, 2);
        root.Controls.Add(form, 0, 1);

        root.Controls.Add(HostKit.Caption(ui, "Log", top: 12), 0, 2);
        _log = new TextBox
        {
            Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, WordWrap = true,
            Font = ui.Font(8.25f, FontStyle.Regular, "Consolas"), BackColor = Theme.Window, Margin = ui.Pad(0),
        };
        root.Controls.Add(_log, 0, 3);

        _result = new StatusRow(ui, ui.Px(600)) { Margin = ui.Pad(0, 10, 0, 0), Visible = false };
        root.Controls.Add(_result, 0, 4);

        _go = HostKit.Primary(ui, "Run test", async (_, _) => await RunAsync());
        _close = HostKit.Button(ui, "Close", (_, _) => Close());
        CancelButton = _close;
        Controls.Add(root);
        Controls.Add(BottomBar(null, _go, _close));

        _dll.TextChanged += (_, _) => UpdateCheck();
        _version.TextChanged += (_, _) => { if (!_rollback) _notes.PlaceholderText = $"Hotfix: {title} {_version.Text.Trim()}"; };
        _test.CheckedChanged += (_, _) => UpdateGo();
        Resize += (_, _) => FitResult();
        FormClosing += (_, e) => { if (_running) e.Cancel = true; };
        UpdateCheck();
        UpdateGo();
        FitResult();
    }

    void FitResult()
    {
        int w = ClientSize.Width - UiKit.Px(24) - UiKit.Px(44);
        _result.Heading.MaximumSize = _result.Detail.MaximumSize = new Size(Math.Max(UiKit.Px(200), w), 0);
    }

    void Browse()
    {
        using var dlg = new OpenFileDialog { Title = "New build", Filter = "Plugin DLL (*.dll)|*.dll|All files|*.*", CheckFileExists = true };
        if (File.Exists(_dll.Text)) { dlg.InitialDirectory = Path.GetDirectoryName(_dll.Text); dlg.FileName = Path.GetFileName(_dll.Text); }
        if (dlg.ShowDialog(this) == DialogResult.OK) _dll.Text = dlg.FileName;
    }

    void UpdateCheck()
    {
        var path = _dll.Text.Trim();
        var (kind, text) = HostForm.DescribeCheck(File.Exists(path) ? SafeInspect(path) : null, path, _cf.ReloadSafe);
        _check.Text = text;
        _check.ForeColor = HostForm.ColorFor(kind);
        UpdateGo();
    }

    static Hotfix.DllCheck SafeInspect(string path)
    {
        try { return Hotfix.Inspect(path); }
        catch (Exception ex) { return new(false, false, false, null, null, null, [ex.Message]); }
    }

    void UpdateGo()
    {
        _go.Text = _test.Checked ? "Run test" : _rollback ? "Roll back now" : "Publish hotfix";
        _go.Enabled = !_running && !PublishedForReal && File.Exists(_dll.Text.Trim());
    }

    void AppendLog(string line)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { try { BeginInvoke(() => AppendLog(line)); } catch (InvalidOperationException) { } return; }
        _log.AppendText(line + Environment.NewLine);
    }

    public string LogText => _log.Text;

    /// <summary>Runs with the current inputs (the button, or the self-test).</summary>
    public async Task RunAsync()
    {
        if (_running) return;
        _running = true;
        foreach (var c in new Control[] { _dll, _version, _notes, _test, _close }) c.Enabled = false;
        if (_browse is not null) _browse.Enabled = false;
        UpdateGo();
        _log.Clear();
        _result.Visible = false;
        bool publish = !_test.Checked;
        var o = new HotfixRunner.Options(ConfigPath: "", Mod: _cf.Id, Dll: _rollback ? null : _dll.Text.Trim(),
            Version: string.IsNullOrWhiteSpace(_version.Text) ? null : _version.Text.Trim(),
            Notes: string.IsNullOrWhiteSpace(_notes.Text) ? null : _notes.Text.Trim(), Rollback: _rollback, Publish: publish);
        try
        {
            var oc = await _run(o, AppendLog);
            Outcome = oc;
            bool ok = oc.ExitCode == 0;
            PublishedForReal = ok && publish;
            _result.Set(ok ? StatusKind.Good : StatusKind.Bad,
                !ok ? "Not published" : publish ? "Published" : "Test run finished: nothing was uploaded", oc.Summary);
        }
        catch (Exception ex)
        {
            Error = ex.Message;
            AppendLog("ERROR: " + ex.Message);
            _result.Set(StatusKind.Bad, publish ? "The hotfix wasn't published" : "The test run stopped", ex.Message);
        }
        _result.Visible = true;
        FitResult();
        _running = false;
        foreach (var c in new Control[] { _dll, _version, _notes, _close }) c.Enabled = true;
        _test.Enabled = _test.Tag is not "forced" && !PublishedForReal;
        if (_browse is not null) _browse.Enabled = true;
        UpdateGo();
    }

    /// <summary>Self-test: show off-screen without blocking.</summary>
    public void ShowOffscreen()
    {
        StartPosition = FormStartPosition.Manual;
        Location = new Point(-4000, -3000);
        Show();
        Application.DoEvents();
    }
}
