using PeakPack.Core;

namespace PeakPack.App.Host;

/// <summary>"Pin version": keep friends on one tested version of a mod, or always take the latest.</summary>
sealed class PinVersionDialog : HostKit.Dialog
{
    readonly ListView _list;

    /// <summary>Null = always the latest.</summary>
    public Version? Chosen { get; private set; }

    public PinVersionDialog(Ui ui, ThunderstoreIndex.TsPackage pkg, Version? current) : base(ui, "Pin version", 460, 400)
    {
        var root = HostKit.Grid(ui, 1);
        root.Padding = ui.Pad(12, 12, 12, 8);
        root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); // wrap long text to the dialog width
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.Controls.Add(HostKit.Text(ui, $"Which version of {pkg.FriendlyName} should friends get?", bottom: 8), 0, 0);

        _list = HostKit.List(ui, ("Version", 230), ("Downloads", 100), ("", -1));
        _list.Columns[1].TextAlign = HorizontalAlignment.Right;
        var latest = HostKit.Row($"Always the latest (now {pkg.Latest.Version.ToString(3)})", "");
        latest.Tag = null;
        _list.Items.Add(latest);
        foreach (var v in pkg.Versions.OrderByDescending(v => v.Version))
        {
            var it = HostKit.Row(v.Version.ToString(3) + (v.IsActive ? "" : " (withdrawn)"), HostKit.Downloads(v.Downloads));
            it.SubItems[1].ForeColor = Theme.Muted;
            if (!v.IsActive) it.ForeColor = SystemColors.GrayText;
            it.Tag = v.Version;
            _list.Items.Add(it);
        }
        foreach (ListViewItem it in _list.Items)
            if (Equals(it.Tag as Version, current)) { it.Selected = true; it.Focused = true; it.EnsureVisible(); }
        root.Controls.Add(_list, 0, 1);
        root.Controls.Add(HostKit.Text(ui, "Pinning keeps everyone on a version you have tested. \"Latest\" picks up the author's updates each time you publish.", muted: true, top: 8), 0, 2);

        var ok = HostKit.Button(ui, "OK", (_, _) => Accept());
        var cancel = HostKit.Button(ui, "Cancel");
        cancel.DialogResult = DialogResult.Cancel;
        AcceptButton = ok;
        CancelButton = cancel;
        Controls.Add(root);
        Controls.Add(BottomBar(null, ok, cancel));
        _list.DoubleClick += (_, _) => Accept();
        _list.SelectedIndexChanged += (_, _) => ok.Enabled = _list.SelectedItems.Count == 1;
        ok.Enabled = _list.SelectedItems.Count == 1;
    }

    void Accept()
    {
        if (_list.SelectedItems.Count != 1) return;
        Chosen = _list.SelectedItems[0].Tag as Version;
        DialogResult = DialogResult.OK;
        Close();
    }
}
