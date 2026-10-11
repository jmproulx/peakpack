# make-icon.ps1
# Draws the PeakPack app icon with System.Drawing (Windows PowerShell 5.1).
# Every size is rendered natively from the vector geometry at that size
# (a ScaleTransform maps the 256-unit design grid onto the target bitmap),
# not downscaled from the 256px master.
#
# Outputs:
#   src\PeakPack.App\app.ico          multi-image ICO (PNG-compressed entries)
#   tools\icon-preview.png            256px preview
#   tools\icon-sizes.png              all sizes, on white (top) and #202020 (bottom)
#
# Run:
#   powershell -ExecutionPolicy Bypass -File C:\Users\joshu\PeakMods\FriendInstaller\tools\make-icon.ps1

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$IcoPath    = 'C:\Users\joshu\PeakMods\FriendInstaller\src\PeakPack.App\app.ico'
$PreviewPng = 'C:\Users\joshu\PeakMods\FriendInstaller\tools\icon-preview.png'
$SizesPng   = 'C:\Users\joshu\PeakMods\FriendInstaller\tools\icon-sizes.png'

$Sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)

# Palette
$Colors = @{
    Navy      = '#1F2A44'   # badge
    BackPeak  = '#2C3A5A'   # smaller peak behind
    Mountain  = '#3B4A6B'   # main peak body
    Facet     = '#56688F'   # lighter left face
    Snow      = '#FFFFFF'
    Orange    = '#E06A1B'   # pack box
    Strap     = '#B8530F'   # darker band on pack box
}

$Brushes = @{}
foreach ($k in $Colors.Keys) {
    $Brushes[$k] = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Colors[$k]))
}

function New-RoundedRectPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = 2 * $R
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $p.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $p.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Fill a polygon given as flat x,y pairs in design units (0..256)
function Fill-Poly {
    param($Graphics, $Brush, [double[]]$V)
    $n = [int]($V.Count / 2)
    $pts = New-Object 'System.Drawing.PointF[]' $n
    for ($i = 0; $i -lt $n; $i++) {
        $pts[$i] = [System.Drawing.PointF]::new([single]$V[2 * $i], [single]$V[2 * $i + 1])
    }
    $Graphics.FillPolygon($Brush, $pts)
}

function New-PeakPackBitmap {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $k = [single]($Size / 256.0)
        $g.ScaleTransform($k, $k)

        # Sizes <= 24 drop the back peak and the strap for legibility
        $small = ($Size -le 24)

        # 1. Badge: rounded square, corner radius ~18% of 256
        $badge = New-RoundedRectPath 0 0 256 256 46
        $g.FillPath($Brushes.Navy, $badge)
        $badge.Dispose()

        # 2. Smaller back peak (right side)
        if (-not $small) {
            Fill-Poly $g $Brushes.BackPeak @(118, 198, 186, 94, 240, 198)
        }

        # 3. Main peak body, then lighter left face for a two-tone facet
        Fill-Poly $g $Brushes.Mountain @(30, 205, 110, 62, 210, 205)
        Fill-Poly $g $Brushes.Facet    @(30, 205, 110, 62, 118, 205)

        # 4. Snow cap with a jagged lower edge
        Fill-Poly $g $Brushes.Snow @(110, 62, 137, 100, 129, 91, 120, 105, 110, 93, 101, 106, 93, 92)

        # 5. Pack box: rounded crate in the lower-right, with a navy keyline so it separates from the mountain
        $box = New-RoundedRectPath 146 158 86 70 14
        $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($Colors.Navy)), 10
        $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
        $g.DrawPath($pen, $box)
        $pen.Dispose()
        $g.FillPath($Brushes.Orange, $box)
        $box.Dispose()

        # 6. Strap band across the box
        if (-not $small) {
            $g.FillRectangle($Brushes.Strap, [single]146, [single]185, [single]86, [single]14)
        }
    }
    finally {
        $g.Dispose()
    }
    return $bmp
}

# --- Render every ICO size natively and encode each as PNG -----------------
$entries = New-Object System.Collections.Generic.List[object]
foreach ($s in $Sizes) {
    $bmp = New-PeakPackBitmap -Size $s
    $ms = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $entries.Add([pscustomobject]@{ Size = $s; Bytes = $ms.ToArray() })
    }
    finally {
        $ms.Dispose()
        $bmp.Dispose()
    }
}

# --- Write ICO container: ICONDIR + ICONDIRENTRY records + PNG payloads -----
$icoDir = [System.IO.Path]::GetDirectoryName($IcoPath)
if (-not (Test-Path $icoDir)) { New-Item -ItemType Directory -Path $icoDir | Out-Null }

$count = $entries.Count
$fs = [System.IO.File]::Create($IcoPath)
try {
    $bw = New-Object System.IO.BinaryWriter $fs
    # ICONDIR
    $bw.Write([uint16]0)        # reserved
    $bw.Write([uint16]1)        # type: icon
    $bw.Write([uint16]$count)   # image count
    # ICONDIRENTRY x count
    $offset = 6 + 16 * $count
    foreach ($e in $entries) {
        $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }   # 0 means 256
        $bw.Write([byte]$dim)                  # width
        $bw.Write([byte]$dim)                  # height
        $bw.Write([byte]0)                     # colour count (0 = no palette)
        $bw.Write([byte]0)                     # reserved
        $bw.Write([uint16]1)                   # colour planes
        $bw.Write([uint16]32)                  # bits per pixel
        $bw.Write([uint32]$e.Bytes.Length)     # payload size
        $bw.Write([uint32]$offset)             # payload offset
        $offset += $e.Bytes.Length
    }
    # Image payloads
    foreach ($e in $entries) {
        $bw.Write([byte[]]$e.Bytes)
    }
    $bw.Flush()
}
finally {
    $fs.Dispose()
}
Write-Host "Wrote $IcoPath ($count images)"

# --- 256px preview ----------------------------------------------------------
$preview = New-PeakPackBitmap -Size 256
try { $preview.Save($PreviewPng, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $preview.Dispose() }
Write-Host "Wrote $PreviewPng"

# --- Size strip: white row on top, #202020 row below, 1:1 pixels ------------
$gap = 24
$pad = 20
$rowH = 256 + 2 * $pad
$total = 0
foreach ($s in $Sizes) { $total += $s }
$sheetW = $total + $gap * ($Sizes.Count - 1) + 2 * $pad
$sheet = New-Object System.Drawing.Bitmap $sheetW, (2 * $rowH), ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$sg = [System.Drawing.Graphics]::FromImage($sheet)
try {
    $sg.SmoothingMode   = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $sg.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $sg.Clear([System.Drawing.Color]::White)
    $darkBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#202020'))
    $sg.FillRectangle($darkBrush, 0, $rowH, $sheetW, $rowH)
    $darkBrush.Dispose()

    # Row 1 sits on the white clear colour, row 2 on the #202020 fill above
    $rows = @(
        @{ Top = 0 },
        @{ Top = $rowH }
    )
    foreach ($row in $rows) {
        $x = $pad
        foreach ($s in $Sizes) {
            $icon = New-PeakPackBitmap -Size $s
            try {
                # bottom-aligned on a common baseline
                $y = $row.Top + $pad + (256 - $s)
                $sg.DrawImageUnscaled($icon, $x, $y)
            }
            finally { $icon.Dispose() }
            $x += $s + $gap
        }
    }
}
finally {
    $sg.Dispose()
}
try { $sheet.Save($SizesPng, [System.Drawing.Imaging.ImageFormat]::Png) } finally { $sheet.Dispose() }
Write-Host "Wrote $SizesPng"

foreach ($b in $Brushes.Values) { $b.Dispose() }
