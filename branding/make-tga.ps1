# Converts a PNG to an uncompressed 32-bit TGA with alpha, which WoW can load
# as an addon texture (the addon list icon, ## IconTexture in the toc).
#
#   ./branding/make-tga.ps1                       64 px icon into the addon
#   ./branding/make-tga.ps1 -Source x.png -Target y.tga

param(
    [string]$Source = (Join-Path $PSScriptRoot "road-to-sixty-64.png"),
    [string]$Target = (Join-Path (Split-Path $PSScriptRoot -Parent) "RoadToSixty/icon.tga")
)

Add-Type -AssemblyName System.Drawing
$image = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source))
try {
    $w, $h = $image.Width, $image.Height
    $stream = New-Object System.IO.MemoryStream
    $out = New-Object System.IO.BinaryWriter $stream
    # Header: no ID, no colour map, type 2 (true colour), 32 bits per pixel,
    # descriptor 0x28 = 8 alpha bits, rows stored top to bottom.
    $out.Write([byte[]](0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    $out.Write([uint16]$w)
    $out.Write([uint16]$h)
    $out.Write([byte]32)
    $out.Write([byte]0x28)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $image.GetPixel($x, $y)
            $out.Write([byte[]]($c.B, $c.G, $c.R, $c.A))
        }
    }
    $out.Flush()
    [System.IO.File]::WriteAllBytes($Target, $stream.ToArray())
    Write-Host ("Wrote {0} ({1}x{2})" -f $Target, $w, $h)
} finally {
    $image.Dispose()
}
