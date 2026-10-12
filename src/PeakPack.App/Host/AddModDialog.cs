using PeakPack.Core;

namespace PeakPack.App.Host;

/// <summary>"Add from Thunderstore": search the PEAK community index by name, author or description.</summary>
sealed class AddModDialog : HostKit.Dialog
{
    readonly ThunderstoreIndex _index;
    readonly HashSet<string> _inPack;
    readonly TextBox _query;
    readonly ListView _list;
    readonly Button _add;
    readonly Label _count;
    readonly System.Windows.Forms.Timer _debounce = new() { Interval = 200 };

    public List<ThunderstoreIndex.TsPackage> Selected { get; } = new();

    public AddModDialog(Ui ui, ThunderstoreIndex index, IEnumerable<string> inPack) : base(ui, "Add from Thunderstore", 760, 480)
    {
        _index = index;
        _inPack = new HashSet<string>(inPack, StringComparer.OrdinalIgnoreCase);

        var root = HostKit.Grid(ui, 1);
        root.Padding = ui.Pad(12, 12, 12, 8);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); // wrap long text to the dialog width
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        root.Controls.Add(HostKit.Text(ui, "Search PEAK mods on Thunderstore by name, author or what they do. Helper libraries are added automatically.", bottom: 8), 0, 0);

        var searchRow = HostKit.Grid(ui, 2);
        searchRow.AutoSize = true;
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        searchRow.Controls.Add(HostKit.Field(ui, "&Search:"), 0, 0);
        _query = HostKit.Box(ui);
        _query.Margin = ui.Pad(0, 0, 0, 8);
        _query.PlaceholderText = "e.g. jetpack, emote, more players";
        searchRow.Controls.Add(_query, 1, 0);
        root.Controls.Add(searchRow, 0, 1);

        _list = HostKit.List(ui, ("Mod", 190), ("Author", 120), ("Downloads", 80), ("Who needs it", 110), ("What it does", -1));
        _list.MultiSelect = true;
        _list.Columns[2].TextAlign = HorizontalAlignment.Right;
        root.Controls.Add(_list, 0, 2);

        _count = HostKit.Text(ui, "", muted: true, top: 6);
        root.Controls.Add(_count, 0, 3);

        _add = HostKit.Button(ui, "Add", (_, _) => Accept());
        var cancel = HostKit.Button(ui, "Cancel");
        cancel.DialogResult = DialogResult.Cancel;
        CancelButton = cancel;
        var note = new Label { AutoSize = true, ForeColor = Theme.Muted, Text = "Mods their author tags \"Host Only\" are added as \"Only me\"." };

        Controls.Add(root);
        Controls.Add(BottomBar(note, _add, cancel));

        _query.TextChanged += (_, _) => { _debounce.Stop(); _debounce.Start(); };
        _debounce.Tick += (_, _) => { _debounce.Stop(); Search(); };
        _query.KeyDown += (_, e) =>
        {
            if (e.KeyCode == Keys.Down && _list.Items.Count > 0) { _list.Focus(); _list.Items[0].Selected = true; e.Handled = true; }
            if (e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; _debounce.Stop(); Search(); }
        };
        _list.SelectedIndexChanged += (_, _) => UpdateAdd();
        _list.DoubleClick += (_, _) => Accept();
        Shown += (_, _) => _query.Focus();
        Search();
    }

    public void SetQuery(string q) { _query.Text = q; _debounce.Stop(); Search(); }

    void Search()
    {
        _list.BeginUpdate();
        _list.Items.Clear();
        var results = _index.Search(_query.Text, 80);
        foreach (var p in results)
        {
            bool have = _inPack.Contains(p.FullName);
            var desc = p.Latest.Description.Trim();
            var it = HostKit.Row(p.FriendlyName, p.Owner, HostKit.Downloads(p.TotalDownloads),
                have ? "Already in the pack" : p.IsHostOnly ? "Only me" : "Friends and me", desc);
            it.Tag = p;
            it.ToolTipText = $"{p.FullName} {p.Latest.Version.ToString(3)}\n{desc}";
            if (have) foreach (ListViewItem.ListViewSubItem s in it.SubItems) s.ForeColor = SystemColors.GrayText;
            else { it.SubItems[1].ForeColor = Theme.Muted; it.SubItems[2].ForeColor = Theme.Muted; it.SubItems[4].ForeColor = Theme.Muted; }
            _list.Items.Add(it);
        }
        _list.EndUpdate();
        _count.Text = results.Count == 0 ? "No PEAK mods match that search."
            : _query.Text.Trim().Length == 0 ? $"Most downloaded PEAK mods ({results.Count} shown). Type to search."
            : $"{results.Count} match{(results.Count == 1 ? "" : "es")}" + (results.Count >= 80 ? " (showing the first 80)" : "") + ".";
        UpdateAdd();
    }

    IEnumerable<ThunderstoreIndex.TsPackage> Addable => _list.SelectedItems.Cast<ListViewItem>()
        .Select(i => (ThunderstoreIndex.TsPackage)i.Tag!).Where(p => !_inPack.Contains(p.FullName));

    void UpdateAdd()
    {
        int n = Addable.Count();
        _add.Enabled = n > 0;
        _add.Text = n > 1 ? $"Add {n} mods" : "Add";
        HostKit.FitButton(UiKit, _add);
    }

    void Accept()
    {
        Selected.Clear();
        Selected.AddRange(Addable);
        if (Selected.Count == 0) return;
        DialogResult = DialogResult.OK;
        Close();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _debounce.Dispose();
        base.Dispose(disposing);
    }
}
