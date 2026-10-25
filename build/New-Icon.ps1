<#
.SYNOPSIS
    Draws the app icon (Fluent blue gradient tile with white scissors) and saves a multi-size .ico.
    PNG-compressed icon images are used, which Windows Vista and newer support.
#>
param([string]$Out = (Join-Path (Split-Path $PSScriptRoot) 'assets\app.ico'))

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null

function New-IconImage([int]$Size) {
    $bmp = New-Object Drawing.Bitmap($Size, $Size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
    $g.Clear([Drawing.Color]::Transparent)

    $r = [float]($Size * 0.22); $d = $r * 2; $w = [float]($Size - 1)
    $path = New-Object Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90); $path.AddArc($w - $d, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d, $w - $d, $d, $d, 0, 90); $path.AddArc(0, $w - $d, $d, $d, 90, 90); $path.CloseFigure()
    $rect = New-Object Drawing.Rectangle(0, 0, $Size, $Size)
    $brush = New-Object Drawing.Drawing2D.LinearGradientBrush($rect, [Drawing.ColorTranslator]::FromHtml('#2B95F0'), [Drawing.ColorTranslator]::FromHtml('#005A9E'), 45)
    $g.FillPath($brush, $path)

    # Scissors glyph (Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets on Windows 10)
    $fam = if ((New-Object Drawing.Text.InstalledFontCollection).Families.Name -contains 'Segoe Fluent Icons') { 'Segoe Fluent Icons' } else { 'Segoe MDL2 Assets' }
    $font = New-Object Drawing.Font($fam,[float]($Size * 0.50), [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $g.DrawString([string][char]0xE8C6, $font, [Drawing.Brushes]::White, (New-Object Drawing.RectangleF(0, ($Size * 0.03), $Size, $Size)), $fmt)
    $g.Dispose()
    return $bmp
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
$images = foreach ($s in $sizes) {
    $bmp = New-IconImage $s
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $ms.ToArray()
}

# ICO file: ICONDIR + ICONDIRENTRY per image + image data
$fs = [IO.File]::Create($Out)
$bw = New-Object IO.BinaryWriter($fs)
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $images[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256))     # 256 is stored as 0
    $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($img in $images) { $bw.Write($img) }
$bw.Close()

# Also save a 256 px PNG for the README
$png = Join-Path (Split-Path $Out) 'icon-256.png'
[IO.File]::WriteAllBytes($png, $images[-1])
Write-Host "Icon saved: $Out"
