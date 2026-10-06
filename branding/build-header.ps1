# Builds header.html from header.src.html plus the shared art in icon-5.html,
# then renders it to road-to-sixty-header.png with headless Edge.
$dir = $PSScriptRoot
$src = Get-Content "$dir\icon-5.html" -Raw
$start = $src.IndexOf('<svg width="0"')
$end = $src.IndexOf('</svg>', $start) + 6
$page = (Get-Content "$dir\header.src.html" -Raw).Replace('<!--DEFS-->', $src.Substring($start, $end - $start))
Set-Content -Path "$dir\header.html" -Value $page -Encoding utf8

$edge = "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
if (-not (Test-Path $edge)) { $edge = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
$url = "file:///" + ("$dir\header.html").Replace('\', '/')
& $edge --headless=new --disable-gpu --hide-scrollbars --window-size="1200,400" --screenshot="$dir\road-to-sixty-header.png" $url 2>$null | Out-Null
