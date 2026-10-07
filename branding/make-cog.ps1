# Draws the gold cog for the journey map's options button and saves it as a
# PNG here and a TGA in the addon (see make-tga.ps1).
#
#   ./branding/make-cog.ps1

Add-Type -AssemblyName System.Drawing

$size = 64
$png = Join-Path $PSScriptRoot "cog-64.png"
$tga = Join-Path (Split-Path $PSScriptRoot -Parent) "RoadToSixty/cog.tga"

# Cog outline: 8 teeth, each a flat-topped trapezoid on a round body.
$teeth, $outer, $inner = 8, 29.0, 22.0
$c = $size / 2
$points = New-Object System.Collections.Generic.List[System.Drawing.PointF]
for ($i = 0; $i -lt $teeth; $i++) {
    $a = 2 * [Math]::PI * $i / $teeth
    $step = 2 * [Math]::PI / $teeth
    # Body arc, then up the tooth's side, across its top, and down again.
    foreach ($pair in @(
            @(-0.50, $inner), @(-0.30, $inner), @(-0.20, $outer),
            @(0.20, $outer), @(0.30, $inner))) {
        $t = $a + $pair[0] * $step
        $points.Add((New-Object System.Drawing.PointF ([float]($c + $pair[1] * [Math]::Cos($t))), ([float]($c + $pair[1] * [Math]::Sin($t)))))
    }
}

$bitmap = New-Object System.Drawing.Bitmap $size, $size
$g = [System.Drawing.Graphics]::FromImage($bitmap)
try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddPolygon($points.ToArray())
    $hole = 9.0
    $path.AddEllipse($c - $hole, $c - $hole, 2 * $hole, 2 * $hole)   # even-odd fill cuts the hole

    # Gold, light at the top left and deep at the bottom right.
    $rect = New-Object System.Drawing.RectangleF 0, 0, $size, $size
    $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect,
        ([System.Drawing.Color]::FromArgb(255, 255, 226, 120)),
        ([System.Drawing.Color]::FromArgb(255, 176, 112, 18)), 45.0
    $g.FillPath($fill, $path)

    # Dark outline, as on the game's icons.
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 40, 24, 4)), 3.0
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.DrawPath($pen, $path)

    # A thin bright rim inside the body for a bevelled look.
    $rim = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(140, 255, 245, 200)), 1.5
    $g.DrawEllipse($rim, $c - 15, $c - 15, 30, 30)
} finally {
    $g.Dispose()
}
$bitmap.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
$bitmap.Dispose()
Write-Host "Wrote $png"

& (Join-Path $PSScriptRoot "make-tga.ps1") -Source $png -Target $tga
