# Cuts branding from a screen recording of a full journey replay. Needs
# ffmpeg (winget install Gyan.FFmpeg).
#
#   ./branding/make-video.ps1 -Source "C:\...\Recording.mp4"
#
# Times are in seconds of the source: the replay runs from 0 to -PlayEnd,
# and -WorldStart to -WorldEnd is a clean shot of the whole world map. Writes
# to branding/video/ (not in git):
#   road-to-sixty-promo.mp4   1920x1080: title card, replay at 3x, the world,
#                             end card
#   road-to-sixty.gif         560 px wide: the replay at 8x, then the world
#   still-*.jpg               full size frames at -Stills

param(
    [Parameter(Mandatory)] [string]$Source,
    [double]$PlayEnd = 89.5,
    [double]$WorldStart = 92.9,
    [double]$WorldEnd = 94.9,
    [double[]]$Stills = @(12, 32, 60, 84, 93.8)
)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$out = Join-Path $here "video"
New-Item -ItemType Directory -Force $out | Out-Null
$header = Join-Path $here "road-to-sixty-header.png"
$logo = Join-Path $here "road-to-sixty-256.png"

# ffmpeg wants fonts as C\:/path inside filters.
function FontPath($name) { "C\:/Windows/Fonts/$name" }
$bold, $regular = (FontPath "palab.ttf"), (FontPath "pala.ttf")
$bg = "0x120d0a"   # dark wood brown, as the header

function Run([string[]]$ffArgs) {
    & ffmpeg -v error -y @ffArgs
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed" }
}

# The window, scaled to 1080 tall and centred on the dark background.
$fit = "scale=-2:1080:flags=lanczos,pad=1920:1080:(ow-iw)/2:0:color=$bg,setsar=1,fps=30"

# Promo: title, replay at 3x, the world, end card. No sound.
$speed = 3
$title = "[1:v]scale=1440:-1,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=$bg,setsar=1,fps=30," +
    "fade=in:st=0:d=0.6,fade=out:st=2.9:d=0.6[title]"
$play = "[0:v]trim=0:$PlayEnd,setpts=(PTS-STARTPTS)/$speed,$fit,fade=in:st=0:d=0.4[play]"
$world = "[0:v]trim=$($WorldStart):$WorldEnd,setpts=PTS-STARTPTS,$fit[world]"
$endCard = "[0:v]trim=$($WorldEnd - 0.04):$WorldEnd,setpts=PTS-STARTPTS,$fit,tpad=stop_mode=clone:stop_duration=4.5," +
    "eq=brightness=-0.32:saturation=0.7[endbg];" +
    "[2:v]scale=220:-1[logo];[endbg][logo]overlay=(W-w)/2:250[endlogo];" +
    "[endlogo]drawtext=fontfile='$bold':text='Road to Sixty':fontsize=96:fontcolor=0xffd36a:" +
    "borderw=3:bordercolor=0x2a1a08:x=(w-tw)/2:y=500," +
    "drawtext=fontfile='$regular':text='Your road from 1 to 60, replayed on the map':fontsize=40:" +
    "fontcolor=0xecdcb4:borderw=2:bordercolor=black:x=(w-tw)/2:y=625," +
    "drawtext=fontfile='$regular':text='Free on CurseForge  |  type /rts in game':fontsize=34:" +
    "fontcolor=0xffd100:borderw=2:bordercolor=black:x=(w-tw)/2:y=715," +
    "fade=in:st=0:d=0.6,fade=out:st=3.9:d=0.6[end]"
$graph = "$title;$play;$world;$endCard;[title][play][world][end]concat=n=4:v=1:a=0[v]"
$promo = Join-Path $out "road-to-sixty-promo.mp4"
Run @("-i", $Source, "-loop", "1", "-t", "3.5", "-i", $header, "-i", $logo,
    "-filter_complex", $graph, "-map", "[v]", "-c:v", "libx264", "-preset", "slow", "-crf", "20",
    "-pix_fmt", "yuv420p", "-movflags", "+faststart", $promo)
Write-Host ("Wrote {0} ({1:N1} MB)" -f $promo, ((Get-Item $promo).Length / 1MB))

# GIF: replay at 8x, then a second of the world, with one shared palette.
$gifSpeed = 8
# 560 px at 10 fps keeps it near 6 MB; 720 px at 12 fps was 13.5 MB.
$gifScale = "scale=560:-2:flags=lanczos,fps=10"
$gifGraph = "[0:v]trim=0:$PlayEnd,setpts=(PTS-STARTPTS)/$gifSpeed,$gifScale[a];" +
    "[0:v]trim=$($WorldStart):$($WorldStart + 1.5),setpts=PTS-STARTPTS,$gifScale[b];" +
    "[a][b]concat=n=2:v=1:a=0,split[x][y];[x]palettegen=max_colors=128:stats_mode=diff[p];" +
    "[y][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle"
$gif = Join-Path $out "road-to-sixty.gif"
Run @("-i", $Source, "-filter_complex", $gifGraph, "-loop", "0", $gif)
Write-Host ("Wrote {0} ({1:N1} MB)" -f $gif, ((Get-Item $gif).Length / 1MB))

# Stills.
foreach ($t in $Stills) {
    $still = Join-Path $out ("still-{0:000.0}.jpg" -f $t)
    Run @("-ss", $t, "-i", $Source, "-frames:v", "1", "-q:v", "2", $still)
}
Write-Host ("Wrote {0} stills" -f $Stills.Count)
