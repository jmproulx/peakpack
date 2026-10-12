using System.Drawing.Drawing2D;

namespace PeakPack.App;

/// <summary>
/// Colours. Native Windows first (the installer look Joshua liked): system face colour, Segoe UI, Windows'
/// own status colours. PEAK's touch is the orange accent line under the header and the orange default button.
/// </summary>
public static class Theme
{
    public static readonly Color Accent = Color.FromArgb(0xE0, 0x6A, 0x1B);
    public static readonly Color AccentDark = Color.FromArgb(0xB8, 0x53, 0x0F);
    public static readonly Color Navy = Color.FromArgb(0x1F, 0x2A, 0x44);
    public static readonly Color Text = Color.FromArgb(0x1B, 0x1B, 0x1B);
    public static readonly Color Muted = Color.FromArgb(0x5F, 0x63, 0x68);
    public static readonly Color Face = SystemColors.Control;
    public static readonly Color Window = SystemColors.Window;
    public static readonly Color Line = Color.FromArgb(0xD5, 0xD5, 0xD5);
    // Windows' own status colours (Settings / Windows Security).
    public static readonly Color Good = Color.FromArgb(0x10, 0x7C, 0x10);
    public static readonly Color Warn = Color.FromArgb(0xC2, 0x7C, 0x0E);
    public static readonly Color Bad = Color.FromArgb(0xC4, 0x2B, 0x1C);
    public static readonly Color Info = Color.FromArgb(0x00, 0x5F, 0xB8);
}

public enum StatusKind { Info, Good, Warn, Bad, Busy }

/// <summary>
/// DPI scaling done by hand: every size is given in 96-DPI pixels and multiplied by <see cref="Scale"/>,
/// and fonts are created in pixels. Forms use AutoScaleMode.None so nothing is scaled twice.
/// Scale = DeviceDpi / 96 (PerMonitorV2), or --ui-scale 1.25 / 1.5 for screenshots, which then render
/// exactly like 125% / 150% Windows scaling.
/// </summary>
public sealed class Ui(float scale)
{
    public float Scale { get; } = scale;
    public int Px(int v) => (int)Math.Round(v * Scale);
    public Size Sz(int w, int h) => new(Px(w), Px(h));
    public Padding Pad(int l, int t, int r, int b) => new(Px(l), Px(t), Px(r), Px(b));
    public Padding Pad(int all) => Pad(all, all, all, all);

    /// <summary>Segoe UI at <paramref name="pt"/> points (at 100%).</summary>
    public Font Font(float pt, FontStyle style = FontStyle.Regular, string family = "Segoe UI") =>
        new(family, pt * 96f / 72f * Scale, style, GraphicsUnit.Pixel);
    public Font Body => Font(9f);
    public Font Small => Font(8.25f);
    public Font Strong => Font(9f, FontStyle.Bold);
    public Font Heading => Font(11.5f, FontStyle.Regular, "Segoe UI Semibold");
    public Font Title => Font(12f, FontStyle.Bold);

    public static float ScaleFor(string[] args, int deviceDpi)
    {
        if (AppSession.Get(args, "--ui-scale") is { } s && float.TryParse(s, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var f) && f is >= 0.75f and <= 3f)
            return f;
        return Math.Max(1f, deviceDpi / 96f);
    }

    /// <summary>Flat status glyph like Windows Security's: filled circle with a white check / ! / x / i.</summary>
    public static Bitmap StatusGlyph(StatusKind kind, int size)
    {
        var bmp = new Bitmap(size, size);
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        var color = kind switch { StatusKind.Good => Theme.Good, StatusKind.Warn => Theme.Warn, StatusKind.Bad => Theme.Bad, _ => Theme.Info };
        float s = size;
        using (var b = new SolidBrush(color)) g.FillEllipse(b, 0.5f, 0.5f, s - 1.5f, s - 1.5f);
        using var pen = new Pen(Color.White, Math.Max(1.6f, s * 0.11f)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        using var white = new SolidBrush(Color.White);
        switch (kind)
        {
            case StatusKind.Good:
                g.DrawLines(pen, [new PointF(s * 0.28f, s * 0.52f), new PointF(s * 0.44f, s * 0.67f), new PointF(s * 0.72f, s * 0.36f)]);
                break;
            case StatusKind.Warn:
                g.DrawLine(pen, s * 0.5f, s * 0.26f, s * 0.5f, s * 0.56f);
                g.FillEllipse(white, s * 0.5f - s * 0.07f, s * 0.66f, s * 0.14f, s * 0.14f);
                break;
            case StatusKind.Bad:
                g.DrawLine(pen, s * 0.34f, s * 0.34f, s * 0.66f, s * 0.66f);
                g.DrawLine(pen, s * 0.66f, s * 0.34f, s * 0.34f, s * 0.66f);
                break;
            case StatusKind.Busy:
                using (var p2 = new Pen(Color.White, Math.Max(1.6f, s * 0.11f)) { StartCap = LineCap.Round, EndCap = LineCap.Round })
                    g.DrawArc(p2, s * 0.27f, s * 0.27f, s * 0.46f, s * 0.46f, -90, 270);
                break;
            default:
                g.FillEllipse(white, s * 0.5f - s * 0.07f, s * 0.22f, s * 0.14f, s * 0.14f);
                g.DrawLine(pen, s * 0.5f, s * 0.45f, s * 0.5f, s * 0.74f);
                break;
        }
        return bmp;
    }

    /// <summary>Picture of an icon file (e.g. PEAK.exe's) at a given size, for "your desktop now has this icon".</summary>
    public static Bitmap? IconImage(string path, int size)
    {
        try
        {
            using var ico = Icon.ExtractIcon(path, 0, size) ?? Icon.ExtractAssociatedIcon(path);
            return ico is null ? null : new Bitmap(ico.ToBitmap(), size, size);
        }
        catch { return null; }
    }
}

/// <summary>
/// Classic installer header: white band with a bold title, a one-line subtitle and the app icon on the right,
/// a thin orange (PEAK) line under it.
/// </summary>
public sealed class HeaderBand : Control
{
    readonly Ui _ui;
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public string Subtitle { get; set; } = "";
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Image? Picture { get; set; }

    public HeaderBand(Ui ui)
    {
        _ui = ui;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Dock = DockStyle.Top;
        Height = ui.Px(62);
        BackColor = Theme.Window;
    }

    public void SetText(string title, string subtitle) { Text = title; Subtitle = subtitle; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.ClearTypeGridFit;
        int left = _ui.Px(20), iconSize = _ui.Px(40);
        int right = Width - _ui.Px(16) - (Picture is null ? 0 : iconSize + _ui.Px(12));
        using var title = _ui.Title;
        using var sub = _ui.Body;
        TextRenderer.DrawText(g, Text, title, new Rectangle(left, _ui.Px(11), right - left, _ui.Px(22)), Theme.Text, TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        TextRenderer.DrawText(g, Subtitle, sub, new Rectangle(left + _ui.Px(1), _ui.Px(34), right - left, _ui.Px(20)), Theme.Muted, TextFormatFlags.Left | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        if (Picture is not null)
        {
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.DrawImage(Picture, new Rectangle(Width - _ui.Px(16) - iconSize, (Height - _ui.Px(3) - iconSize) / 2, iconSize, iconSize));
        }
        using var accent = new SolidBrush(Theme.Accent);
        g.FillRectangle(accent, 0, Height - _ui.Px(3), Width, _ui.Px(3));
    }
}

/// <summary>Status line in the style of Windows Update / Windows Security: glyph, bold heading, explanation.</summary>
public sealed class StatusRow : TableLayoutPanel
{
    readonly Ui _ui;
    readonly PictureBox _glyph = new() { SizeMode = PictureBoxSizeMode.Zoom };
    public Label Heading { get; } = new() { AutoSize = true, ForeColor = Theme.Text };
    public Label Detail { get; } = new() { AutoSize = true, ForeColor = Theme.Text };
    public StatusKind Kind { get; private set; }

    public StatusRow(Ui ui, int width)
    {
        _ui = ui;
        AutoSize = true;
        ColumnCount = 2;
        RowCount = 2;
        Margin = ui.Pad(0);
        ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, ui.Px(44)));
        ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        _glyph.Size = ui.Sz(32, 32);
        _glyph.Margin = ui.Pad(0, 2, 12, 0);
        Heading.Font = ui.Heading;
        Heading.Margin = ui.Pad(0, 0, 0, 2);
        Detail.Font = ui.Body;
        Detail.Margin = ui.Pad(0);
        Detail.MaximumSize = new Size(width - ui.Px(44), 0);
        Heading.MaximumSize = Detail.MaximumSize;
        Controls.Add(_glyph, 0, 0);
        SetRowSpan(_glyph, 2);
        Controls.Add(Heading, 1, 0);
        Controls.Add(Detail, 1, 1);
    }

    public void Set(StatusKind kind, string heading, string detail)
    {
        Kind = kind;
        var old = _glyph.Image;
        _glyph.Image = Ui.StatusGlyph(kind, _ui.Px(32) * 2); // drawn at 2x, shown at 1x: crisp edges
        old?.Dispose();
        Heading.Text = heading;
        Detail.Text = detail;
    }
}

/// <summary>
/// A command link in the style of Windows' own (arrow, blue title, note underneath; a light outline on hover),
/// drawn by hand so it scales with the rest of the window and renders identically in screenshots at any scale.
/// (The native BS_COMMANDLINK draws its text at the system DPI, which can't be checked at simulated scales.)
/// Keyboard: Tab focus, Space/Enter click (Button behaviour); accessible as a push button.
/// </summary>
public sealed class CommandLink : Button
{
    static readonly Color Ink = Color.FromArgb(0x1A, 0x5F, 0xB4);
    static readonly Color HoverFill = Color.FromArgb(0xE8, 0xF1, 0xFB);
    static readonly Color HoverLine = Color.FromArgb(0xB9, 0xD4, 0xF1);
    static readonly Color DownFill = Color.FromArgb(0xD5, 0xE6, 0xF8);
    bool _hover, _down;
    string _note = "";

    public CommandLink()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand;
        AccessibleRole = AccessibleRole.PushButton;
    }

    /// <summary>The main choice: shown with a resting outline, like the default command link in Windows dialogs.</summary>
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public bool IsPrimary { get; set { field = value; Invalidate(); } }

    /// <summary>Layout scale (Ui.Scale); fonts come from <see cref="Control.Font"/> (title) and <see cref="NoteFont"/>.</summary>
    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public float LayoutScale { get; set; } = 1f;

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public Font? NoteFont { get; set; }

    [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
    public string Note
    {
        get => _note;
        set { _note = value; AccessibleDescription = value; Invalidate(); }
    }

    int Px(float v) => (int)Math.Round(v * LayoutScale);
    int TextLeft => Px(40);
    const TextFormatFlags Wrap = TextFormatFlags.WordBreak | TextFormatFlags.NoPrefix | TextFormatFlags.TextBoxControl;

    /// <summary>Height needed to show the title and the (wrapped) note at this width.</summary>
    public int PreferredHeightFor(int width)
    {
        int textW = Math.Max(10, width - TextLeft - Px(12));
        var title = TextRenderer.MeasureText(Text, Font, new Size(textW, int.MaxValue), Wrap);
        var note = _note.Length == 0 ? Size.Empty : TextRenderer.MeasureText(_note, NoteFont ?? Font, new Size(textW, int.MaxValue), Wrap);
        return Px(9) + title.Height + (note.Height > 0 ? Px(1) + note.Height : 0) + Px(10);
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
    protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.Clear(Parent?.BackColor ?? Theme.Face);
        var box = new Rectangle(0, 0, Width - 1, Height - 1);
        if (Enabled && (_hover || _down || IsPrimary))
        {
            using var fill = new SolidBrush(_down ? DownFill : _hover ? HoverFill : Color.FromArgb(0xF4, 0xF8, 0xFD));
            using var line = new Pen(HoverLine);
            g.FillRectangle(fill, box);
            g.DrawRectangle(line, box);
        }
        var ink = Enabled ? Ink : Theme.Muted;
        int textW = Width - TextLeft - Px(12);
        var titleSize = TextRenderer.MeasureText(Text, Font, new Size(textW, int.MaxValue), Wrap);

        // Arrow, vertically centred on the first title line.
        g.SmoothingMode = SmoothingMode.AntiAlias;
        float cy = Px(9) + Font.Height / 2f, x0 = Px(13), x1 = Px(29);
        using (var pen = new Pen(ink, Math.Max(1.5f, 1.6f * LayoutScale)) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round })
        {
            g.DrawLine(pen, x0, cy, x1, cy);
            g.DrawLines(pen, [new PointF(x1 - Px(6), cy - Px(6)), new PointF(x1, cy), new PointF(x1 - Px(6), cy + Px(6))]);
        }
        g.SmoothingMode = SmoothingMode.None;

        TextRenderer.DrawText(g, Text, Font, new Rectangle(TextLeft, Px(9), textW, titleSize.Height), ink, Wrap);
        if (_note.Length > 0)
            TextRenderer.DrawText(g, _note, NoteFont ?? Font, new Rectangle(TextLeft, Px(9) + titleSize.Height + Px(1), textW, Height), ink, Wrap);
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(box, -Px(2), -Px(2)));
    }
}

/// <summary>The one primary button of a page (Install, Play now): flat PEAK orange with white text, square corners,
/// standard button size. Everything else stays a normal system button.</summary>
public sealed class AccentButton : Button
{
    bool _hover, _down;

    public AccentButton()
    {
        SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Cursor = Cursors.Hand;
    }

    protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { _hover = _down = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnMouseDown(MouseEventArgs e) { if (e.Button == MouseButtons.Left) { _down = true; Invalidate(); } base.OnMouseDown(e); }
    protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        var back = !Enabled ? Color.FromArgb(0xE8, 0xB8, 0x98) : _down ? Theme.AccentDark : _hover ? Color.FromArgb(0xCC, 0x5E, 0x15) : Theme.Accent;
        using (var b = new SolidBrush(back)) g.FillRectangle(b, ClientRectangle);
        using (var p = new Pen(Theme.AccentDark)) g.DrawRectangle(p, 0, 0, Width - 1, Height - 1);
        TextRenderer.DrawText(g, Text, Font, ClientRectangle, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues)
            ControlPaint.DrawFocusRectangle(g, Rectangle.Inflate(ClientRectangle, -3, -3), Color.White, back);
    }
}
