using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PeakPack.App.Host;

/// <summary>
/// Small building blocks for the Host window and its dialogs, on top of the shared <see cref="Ui"/> kit:
/// standard system buttons (uniform width, like Windows' own dialogs), Explorer-themed details ListViews,
/// muted notes, the one orange primary button, and window capture for the self-test.
/// </summary>
static class HostKit
{
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    static extern int SetWindowTheme(IntPtr hWnd, string pszSubAppName, string? pszSubIdList);


    [DllImport("user32.dll")]
    static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    static extern bool PrintWindow(IntPtr hwnd, IntPtr hdcBlt, uint nFlags);

    public const int ButtonHeight = 26;

    /// <summary>Standard push button (FlatStyle.System): native look, sized to fit its text at any scale.</summary>
    public static Button Button(Ui ui, string text, EventHandler? click = null, int minWidth = 88)
    {
        var b = new Button
        {
            Text = text, FlatStyle = FlatStyle.System, UseVisualStyleBackColor = true, AutoSize = false,
            Margin = ui.Pad(0, 0, 6, 0), Font = ui.Body, // explicit: an unparented button still has the unscaled default font
        };
        FitButton(ui, b, minWidth);
        if (click is not null) b.Click += click;
        return b;
    }

    /// <summary>Width = text + padding (at least <paramref name="minWidth"/>), height = the standard button height.</summary>
    public static void FitButton(Ui ui, Button b, int minWidth = 88)
    {
        var w = TextRenderer.MeasureText(b.Text, b.Font ?? ui.Body).Width + ui.Px(24);
        b.Size = new Size(Math.Max(ui.Px(minWidth), w), Math.Max(ui.Px(ButtonHeight), (b.Font ?? ui.Body).Height + ui.Px(10)));
    }

    /// <summary>Gives a column of buttons the same width (the widest text), like the Add/Remove stacks in Windows dialogs.</summary>
    public static void SameWidth(Ui ui, IEnumerable<Button> buttons, params string[] alsoFit)
    {
        var list = buttons.ToList();
        using var f = ui.Body;
        int w = list.Select(b => TextRenderer.MeasureText(b.Text, f).Width)
            .Concat(alsoFit.Select(t => TextRenderer.MeasureText(t, f).Width)).DefaultIfEmpty(0).Max() + ui.Px(24);
        w = Math.Max(w, ui.Px(88));
        foreach (var b in list) b.Width = w;
    }

    /// <summary>The single orange "do it" button (PEAK accent). Everything else stays a system button.</summary>
    public static Button Primary(Ui ui, string text, EventHandler? click = null)
    {
        var b = Button(ui, text, click, 120);
        b.FlatStyle = FlatStyle.Flat;
        b.UseVisualStyleBackColor = false;
        b.Font = ui.Font(9f, FontStyle.Bold);
        b.FlatAppearance.BorderSize = 1;
        void Paint()
        {
            b.BackColor = b.Enabled ? Theme.Accent : SystemColors.Control;
            b.ForeColor = b.Enabled ? Color.White : SystemColors.GrayText;
            b.FlatAppearance.BorderColor = b.Enabled ? Theme.AccentDark : SystemColors.ControlDark;
            b.FlatAppearance.MouseOverBackColor = Theme.AccentDark;
            b.FlatAppearance.MouseDownBackColor = Color.FromArgb(0x9A, 0x44, 0x0B);
        }
        b.EnabledChanged += (_, _) => Paint();
        b.TextChanged += (_, _) => FitButton(ui, b, 120);
        Paint();
        FitButton(ui, b, 120);
        return b;
    }

    /// <summary>Details-view ListView with Explorer's theme (Windows 10 selection/hover look).</summary>
    public static ListView List(Ui ui, params (string Title, int Width)[] columns)
    {
        var lv = new ListView
        {
            View = View.Details, FullRowSelect = true, HideSelection = false, MultiSelect = false,
            HeaderStyle = ColumnHeaderStyle.Nonclickable, Dock = DockStyle.Fill, ShowItemToolTips = true,
            Margin = ui.Pad(0), BorderStyle = BorderStyle.FixedSingle,
        };
        foreach (var (t, w) in columns) lv.Columns.Add(t, w < 0 ? ui.Px(100) : ui.Px(w));
        lv.HandleCreated += (_, _) => SetWindowTheme(lv.Handle, "Explorer", null);
        typeof(Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)?.SetValue(lv, true);
        // The last column takes whatever width is left, so there's never an empty strip or a needless scrollbar.
        void Fit()
        {
            if (lv.Columns.Count == 0 || lv.ClientSize.Width <= 0) return;
            int used = 0;
            for (int i = 0; i < lv.Columns.Count - 1; i++) used += lv.Columns[i].Width;
            // Room for a vertical scrollbar is always kept, so adding rows never brings up a horizontal one.
            bool vscroll = (GetWindowLong(lv.Handle, -16 /* GWL_STYLE */) & 0x00200000 /* WS_VSCROLL */) != 0;
            int width = lv.ClientSize.Width - (vscroll ? 0 : SystemInformation.VerticalScrollBarWidth) - 1;
            lv.Columns[^1].Width = Math.Max(ui.Px(80), width - used);
        }
        lv.Resize += (_, _) => Fit();
        lv.HandleCreated += (_, _) => Fit();
        lv.ColumnWidthChanged += (_, e) => { if (e.ColumnIndex < lv.Columns.Count - 1) Fit(); };
        return lv;
    }

    public static ListViewItem Row(string first, params string[] rest)
    {
        var it = new ListViewItem(first) { UseItemStyleForSubItems = false };
        foreach (var r in rest) it.SubItems.Add(r);
        return it;
    }

    /// <summary>Plain left-aligned label that wraps to its cell width (inside a TableLayoutPanel).</summary>
    public static Label Text(Ui ui, string text, bool muted = false, int top = 0, int bottom = 0) => new()
    {
        Text = text, AutoSize = true, Dock = DockStyle.Fill, ForeColor = muted ? Theme.Muted : Theme.Text,
        Margin = ui.Pad(0, top, 0, bottom), UseMnemonic = false, TextAlign = ContentAlignment.TopLeft,
    };

    /// <summary>Field label in a form grid: vertically centred with its text box.</summary>
    public static Label Field(Ui ui, string text) => new()
    {
        Text = text, AutoSize = true, Anchor = AnchorStyles.Left, Margin = ui.Pad(0, 0, 10, 0), ForeColor = Theme.Text,
    };

    /// <summary>Section caption (semibold body size): what a group of controls is about.</summary>
    public static Label Caption(Ui ui, string text, int top = 0) => new()
    {
        Text = text, AutoSize = true, Dock = DockStyle.Fill, Font = ui.Font(9f, FontStyle.Regular, "Segoe UI Semibold"),
        ForeColor = Theme.Text, Margin = ui.Pad(0, top, 0, 4), UseMnemonic = false,
    };

    public static TableLayoutPanel Grid(Ui ui, int columns)
    {
        var t = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = columns, Margin = ui.Pad(0), Padding = ui.Pad(0), AutoSize = false };
        return t;
    }

    public static FlowLayoutPanel Flow(Ui ui, FlowDirection dir = FlowDirection.LeftToRight) => new()
    {
        FlowDirection = dir, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false,
        Margin = ui.Pad(0), Padding = ui.Pad(0),
    };

    public static TextBox Box(Ui ui, bool readOnly = false) => new()
    {
        Dock = DockStyle.Fill, Margin = ui.Pad(0, 3, 0, 3), ReadOnly = readOnly,
    };

    /// <summary>"just now", "5 min ago", "3 h ago", "yesterday 14:02", "2 Oct 09:15".</summary>
    public static string Ago(DateTime local)
    {
        var d = DateTime.Now - local;
        if (d.TotalSeconds < 60) return "just now";
        if (d.TotalMinutes < 60) return $"{(int)d.TotalMinutes} min ago";
        if (d.TotalHours < 12) return $"{(int)d.TotalHours} h ago";
        if (local.Date == DateTime.Today) return "today " + local.ToString("HH:mm");
        if (local.Date == DateTime.Today.AddDays(-1)) return "yesterday " + local.ToString("HH:mm");
        return local.ToString("d MMM HH:mm");
    }

    public static string Downloads(long n) => n.ToString("N0");

    /// <summary>"C:\Users\...\custom\HeliPilot.dll": keeps the part that tells builds apart (full path in the tooltip).</summary>
    public static string ShortPath(string path)
    {
        var parts = path.Split(['\\', '/'], StringSplitOptions.RemoveEmptyEntries);
        return parts.Length <= 4 ? path : $"{parts[0]}\\{parts[1]}\\...\\{parts[^2]}\\{parts[^1]}";
    }

    /// <summary>Renders a window to a PNG (self-test). PrintWindow captures themed controls faithfully even off-screen;
    /// DrawToBitmap is the fallback.</summary>
    public static void Capture(Control c, string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var bmp = new Bitmap(c.Width, c.Height);
        bool ok = false;
        // Themed buttons animate state changes (e.g. disabled -> enabled) starting from the last state they painted;
        // an off-screen window never paints, so the first print shows the old state. Print once to start the
        // transition, let it finish, then take the real picture.
        using (var scratch = new Bitmap(c.Width, c.Height))
        using (var g0 = Graphics.FromImage(scratch))
        {
            var h0 = g0.GetHdc();
            try { PrintWindow(c.Handle, h0, 0); } finally { g0.ReleaseHdc(h0); }
        }
        var until = DateTime.UtcNow.AddMilliseconds(400);
        while (DateTime.UtcNow < until) { Application.DoEvents(); Thread.Sleep(15); }
        using (var g = Graphics.FromImage(bmp))
        {
            var hdc = g.GetHdc();
            // Flags 0 (WM_PRINT path): PW_RENDERFULLCONTENT comes back blank for off-screen windows.
            try { ok = PrintWindow(c.Handle, hdc, 0); }
            finally { g.ReleaseHdc(hdc); }
        }
        if (!ok) c.DrawToBitmap(bmp, new Rectangle(Point.Empty, c.Size));
        bmp.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }

    public static void OpenFolderOf(string file)
    {
        try
        {
            if (File.Exists(file)) Process.Start("explorer.exe", $"/select,\"{file}\"");
            else if (Directory.Exists(Path.GetDirectoryName(file))) Process.Start("explorer.exe", $"\"{Path.GetDirectoryName(file)}\"");
        }
        catch { }
    }

    /// <summary>Base for the Host dialogs: manual DPI scaling, system face, centred on the owner, Esc closes.</summary>
    public class Dialog : Form
    {
        protected readonly Ui UiKit;

        public Dialog(Ui ui, string title, int width, int height)
        {
            UiKit = ui;
            AutoScaleMode = AutoScaleMode.None;
            Font = ui.Body;
            Text = title;
            BackColor = Theme.Face;
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            MinimizeBox = false;
            MaximizeBox = false;
            FormBorderStyle = FormBorderStyle.Sizable;
            ShowIcon = false;
            ClientSize = ui.Sz(width, height);
            MinimumSize = Size;
            KeyPreview = true;
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            if (keyData == Keys.Escape) { DialogResult = DialogResult.Cancel; Close(); return true; }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        /// <summary>Installer-style bottom bar: etched line, optional note on the left, buttons on the right.</summary>
        protected Control BottomBar(Control? left, params Button[] buttons)
        {
            var bar = new Panel { Dock = DockStyle.Bottom, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Padding = UiKit.Pad(12, 10, 12, 10) };
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, RowCount = 1, Margin = UiKit.Pad(0) };
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            grid.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            if (left is not null) { left.Anchor = AnchorStyles.Left; grid.Controls.Add(left, 0, 0); }
            var flow = Flow(UiKit);
            flow.Anchor = AnchorStyles.Right;
            for (int i = 0; i < buttons.Length; i++) { buttons[i].Margin = UiKit.Pad(i == 0 ? 0 : 6, 0, 0, 0); flow.Controls.Add(buttons[i]); }
            grid.Controls.Add(flow, 1, 0);
            bar.Controls.Add(grid);
            var line = new Label { Dock = DockStyle.Top, Height = 2, AutoSize = false, BorderStyle = BorderStyle.Fixed3D };
            var wrap = new Panel { Dock = DockStyle.Bottom, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink };
            wrap.Controls.Add(bar);
            wrap.Controls.Add(line);
            return wrap;
        }

        /// <summary>Self-test: show without blocking, off-screen, render, close.</summary>
        public void CaptureOffscreen(string path, Action? afterShown = null)
        {
            StartPosition = FormStartPosition.Manual;
            Location = new Point(-4000, -3000);
            Show();
            afterShown?.Invoke();
            for (int i = 0; i < 5; i++) { Application.DoEvents(); Thread.Sleep(20); }
            HostKit.Capture(this, path);
            Close();
        }
    }
}
