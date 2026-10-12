using PeakPack.Core;

namespace PeakPack.App.Host;

/// <summary>
/// "Import from my game": identifies the DLLs in the host's BepInEx\plugins folder by SHA-256
/// (<see cref="Publisher.ScanAsync"/>). Read-only for the game folder. Thunderstore matches can be added
/// to the mod list; unknown DLLs can be added as own builds.
/// </summary>
sealed class ImportDialog : HostKit.Dialog
{
    readonly ThunderstoreIndex _index;
    readonly string _pluginsDir;
    readonly string _cacheDir;
    readonly HashSet<string> _inPack;
    readonly HashSet<string> _customSources;
    readonly ListView _list;
    readonly Label _state;
    readonly ProgressBar _bar;
    readonly Button _add;
    readonly ListViewGroup _gMatched = new("On Thunderstore");
    readonly ListViewGroup _gUnknown = new("Not on Thunderstore: tick your own builds");
    readonly CancellationTokenSource _cts = new();
    bool _scanning;

    public sealed record ModPick(string Entry, bool HostOnly);
    public List<ModPick> Mods { get; } = new();
    public List<string> Dlls { get; } = new();

    public ImportDialog(Ui ui, ThunderstoreIndex index, string pluginsDir, string cacheDir, IEnumerable<string> inPack, IEnumerable<string> customSources)
        : base(ui, "Import from my game", 760, 460)
    {
        _index = index;
        _pluginsDir = pluginsDir;
        _cacheDir = cacheDir;
        _inPack = new HashSet<string>(inPack, StringComparer.OrdinalIgnoreCase);
        _customSources = new HashSet<string>(customSources.Select(s => Path.GetFullPath(s)), StringComparer.OrdinalIgnoreCase);

        var root = HostKit.Grid(ui, 1);
        root.Padding = ui.Pad(12, 12, 12, 8);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); // wrap long text to the dialog width
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.Controls.Add(HostKit.Text(ui, $"Mods found in {pluginsDir}. Each DLL is matched to its Thunderstore release by its exact contents. Nothing in your game folder is changed.", bottom: 8), 0, 0);

        var stateRow = HostKit.Grid(ui, 2);
        stateRow.AutoSize = true;
        stateRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        stateRow.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, ui.Px(160)));
        _state = new Label { AutoSize = true, Anchor = AnchorStyles.Left, ForeColor = Theme.Muted, Margin = ui.Pad(0, 0, 8, 8), AutoEllipsis = true };
        _bar = new ProgressBar { Style = ProgressBarStyle.Marquee, Dock = DockStyle.Fill, Height = ui.Px(14), Margin = ui.Pad(0, 2, 0, 8), MarqueeAnimationSpeed = 30 };
        stateRow.Controls.Add(_state, 0, 0);
        stateRow.Controls.Add(_bar, 1, 0);
        root.Controls.Add(stateRow, 0, 1);

        _list = HostKit.List(ui, ("Mod or file", 210), ("Thunderstore id / file", 230), ("Who needs it", 110), ("Note", -1));
        _list.CheckBoxes = true;
        _list.Groups.Add(_gMatched);
        _list.Groups.Add(_gUnknown);
        root.Controls.Add(_list, 0, 2);

        _add = HostKit.Button(ui, "Add selected", (_, _) => Accept());
        _add.Enabled = false;
        var cancel = HostKit.Button(ui, "Cancel", (_, _) => { _cts.Cancel(); DialogResult = DialogResult.Cancel; Close(); });
        CancelButton = cancel;
        Controls.Add(root);
        Controls.Add(BottomBar(null, _add, cancel));
        _list.ItemChecked += (_, _) => { if (!_scanning) UpdateAdd(); };
        FormClosing += (_, _) => _cts.Cancel();
    }

    /// <summary>Starts the scan when the dialog opens.</summary>
    public void ScanOnShown() => Shown += async (_, _) => await ScanAsync();

    async Task ScanAsync()
    {
        _scanning = true;
        _state.Text = "Looking at your plugins (downloads candidate releases once to compare them)...";
        try
        {
            using var dl = new Downloader(_cacheDir);
            var pub = new Publisher(dl, _index, line => { try { if (IsHandleCreated && !IsDisposed) BeginInvoke(() => _state.Text = line.Trim()); } catch (InvalidOperationException) { } });
            var (matched, unmatched) = await Task.Run(() => pub.ScanAsync(_pluginsDir, _cts.Token));
            ShowResults(matched, unmatched);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            _bar.Visible = false;
            _state.ForeColor = Theme.Bad;
            _state.Text = "Couldn't finish the scan: " + ex.Message;
        }
        finally { _scanning = false; }
    }

    /// <summary>Fills the list from scan results (also used directly by the self-test).</summary>
    public void ShowResults(IReadOnlyList<string> matched, IReadOnlyList<string> unmatched)
    {
        _scanning = true;
        _list.BeginUpdate();
        _list.Items.Clear();
        foreach (var m in matched.OrderBy(m => m, StringComparer.OrdinalIgnoreCase))
        {
            var id = PackageId.Parse(m);
            var pkg = _index.Find(id.FullName);
            bool have = _inPack.Contains(id.FullName);
            bool hostOnly = pkg?.IsHostOnly == true;
            bool isLatest = pkg is not null && id.Version == pkg.Latest.Version;
            var entry = isLatest || id.Version is null ? id.FullName : id.ToString();
            var note = have ? "Already in the pack"
                : isLatest ? $"You have {id.Version?.ToString(3)} (the latest)"
                : $"You have {id.Version?.ToString(3)}; it will be pinned to that version";
            var it = HostKit.Row(pkg?.FriendlyName ?? ThunderstoreIndex.Friendly(id.Name), id.ToString(), hostOnly ? "Only me" : "Friends and me", note);
            it.Group = _gMatched;
            it.Tag = new ModPick(entry, hostOnly);
            it.Checked = !have;
            it.SubItems[1].ForeColor = Theme.Muted;
            it.SubItems[3].ForeColor = Theme.Muted;
            if (have) foreach (ListViewItem.ListViewSubItem s in it.SubItems) s.ForeColor = SystemColors.GrayText;
            _list.Items.Add(it);
        }
        foreach (var dll in unmatched.OrderBy(Path.GetFileName, StringComparer.OrdinalIgnoreCase))
        {
            // The lobby-check companion is added by PeakPack itself.
            if (dll.Contains(Path.DirectorySeparatorChar + "PeakPack-Companion" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;
            bool have = _customSources.Contains(Path.GetFullPath(dll));
            var rel = Path.GetRelativePath(_pluginsDir, dll);
            if (rel.StartsWith("..", StringComparison.Ordinal)) rel = dll;
            var it = HostKit.Row(ThunderstoreIndex.Friendly(Path.GetFileNameWithoutExtension(dll).Split('.').Last()), rel, "Friends and me",
                have ? "Already in Own builds" : $"Changed {HostKit.Ago(File.GetLastWriteTime(dll))}");
            it.Group = _gUnknown;
            it.Tag = dll;
            it.Checked = false;
            it.SubItems[1].ForeColor = Theme.Muted;
            it.SubItems[3].ForeColor = Theme.Muted;
            if (have) foreach (ListViewItem.ListViewSubItem s in it.SubItems) s.ForeColor = SystemColors.GrayText;
            _list.Items.Add(it);
        }
        _list.EndUpdate();
        _bar.Visible = false;
        int m2 = _list.Items.Cast<ListViewItem>().Count(i => i.Group == _gMatched), u = _list.Items.Count - m2;
        _state.Text = $"{m2} mod{(m2 == 1 ? "" : "s")} matched on Thunderstore, {u} other DLL{(u == 1 ? "" : "s")}.";
        _scanning = false;
        UpdateAdd();
    }

    void UpdateAdd() => _add.Enabled = _list.CheckedItems.Count > 0;

    void Accept()
    {
        foreach (ListViewItem it in _list.CheckedItems)
        {
            if (it.Tag is ModPick mp && !_inPack.Contains(PackageId.Parse(mp.Entry).FullName)) Mods.Add(mp);
            else if (it.Tag is string dll && !_customSources.Contains(Path.GetFullPath(dll))) Dlls.Add(dll);
        }
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _cts.Dispose();
        base.Dispose(disposing);
    }
}
