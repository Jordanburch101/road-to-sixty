# Builds the release zip of the addon, without developer tools.
#
#   ./scripts/package.ps1                  version from git (tag, or describe)
#   ./scripts/package.ps1 -Version 1.0.0   explicit version
#
# Steps:
#   1. Copies ForeverJourney/ to build/ForeverJourney/.
#   2. Strips developer-only parts, marked as in the BigWigs packager:
#        toc:  lines between "#@debug@" and "#@end-debug@"
#        Lua:  lines between "--@debug@" and "--@end-debug@"
#      and deletes any .lua file the stripped toc no longer lists.
#   3. Puts the version in place of @project-version@ in the toc.
#   4. Checks the build: every listed file exists, no debug markers are left,
#      and, with LuaJIT installed, every Lua file compiles and the build
#      loads in toc order (tests/release_load.lua).
#   5. Zips build/ForeverJourney/ to dist/ForeverJourney-<version>.zip, with the
#      ForeverJourney folder at the top as WoW expects.
# Exits 1 if any check fails.

param(
    [string]$Version
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$addonName = "ForeverJourney"
$source = Join-Path $root $addonName
$buildRoot = Join-Path $root "build"
$build = Join-Path $buildRoot $addonName
$dist = Join-Path $root "dist"

function Fail($message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

# Version: argument, else the tag CI is building, else git describe, else "dev".
if (-not $Version) {
    if ($env:GITHUB_REF_TYPE -eq "tag") {
        $Version = $env:GITHUB_REF_NAME
    } else {
        # Windows PowerShell turns git's stderr into an error under "Stop".
        $ErrorActionPreference = "Continue"
        $Version = (git -C $root describe --tags --always --dirty 2>$null)
        $ErrorActionPreference = "Stop"
        if ($LASTEXITCODE -ne 0 -or -not $Version) { $Version = "dev" }
    }
}
$Version = $Version -replace '^v', ''
Write-Host "Packaging $addonName $Version"

# 1. Fresh copy.
if (Test-Path $buildRoot) { Remove-Item $buildRoot -Recurse -Force }
New-Item -ItemType Directory -Path $build -Force | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $build -Recurse

# Removes the lines from a start marker to an end marker, both included.
# Fails on a marker without its partner, so a typo cannot ship dev code.
function Remove-Blocks([string[]]$lines, [string]$start, [string]$end, [string]$file) {
    $kept = New-Object System.Collections.Generic.List[string]
    $inside = $false
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed -eq $start) {
            if ($inside) { Fail "$file has a nested $start" }
            $inside = $true
        } elseif ($trimmed -eq $end) {
            if (-not $inside) { Fail "$file has $end without $start" }
            $inside = $false
        } elseif (-not $inside) {
            $kept.Add($line)
        }
    }
    if ($inside) { Fail "$file has $start without $end" }
    return ,$kept.ToArray()
}

function Write-Lines([string]$path, [string[]]$lines) {
    # UTF-8 without BOM and LF endings, the same on every platform.
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
}

# 2 and 3. Strip the toc and set the version.
$tocPath = Join-Path $build "$addonName.toc"
$toc = Remove-Blocks (Get-Content $tocPath) "#@debug@" "#@end-debug@" "$addonName.toc"
$toc = $toc | ForEach-Object { $_.Replace("@project-version@", $Version) }
Write-Lines $tocPath $toc

$listed = @($toc | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() })
foreach ($file in Get-ChildItem $build -Filter *.lua -Recurse) {
    $relative = $file.FullName.Substring($build.Length + 1).Replace('\', '/')
    if ($listed -notcontains $relative) {
        Write-Host "  dropped $relative (developer only)"
        Remove-Item $file.FullName
        continue
    }
    $lines = Get-Content $file.FullName
    $stripped = Remove-Blocks $lines "--@debug@" "--@end-debug@" $relative
    if ($stripped.Count -ne $lines.Count) {
        Write-Host ("  stripped {0} debug lines from {1}" -f ($lines.Count - $stripped.Count), $relative)
    }
    Write-Lines $file.FullName $stripped
}

# 4. Check the build.
foreach ($entry in $listed) {
    if (-not (Test-Path (Join-Path $build $entry))) { Fail "toc lists $entry, which is missing" }
}
$leftovers = Get-ChildItem $build -Recurse -File | Select-String -Pattern "@debug@|@end-debug@|@project-version@" -SimpleMatch:$false
if ($leftovers) { Fail ("markers left in the build:`n" + ($leftovers -join "`n")) }

$luajit = Get-Command luajit -ErrorAction SilentlyContinue
if ($luajit) {
    $scratch = [System.IO.Path]::GetTempFileName()
    foreach ($file in Get-ChildItem $build -Filter *.lua -Recurse) {
        $out = & luajit -b $file.FullName $scratch 2>&1
        if ($LASTEXITCODE -ne 0) { Fail "$($file.Name) does not compile: $out" }
    }
    Remove-Item $scratch -ErrorAction SilentlyContinue
    # Load every file in toc order against a stand-in game API.
    & luajit (Join-Path $root "tests/release_load.lua") $build
    if ($LASTEXITCODE -ne 0) { Fail "the release build does not load" }
} else {
    Write-Host "  luajit not found, skipping the compile and load checks" -ForegroundColor Yellow
}

# 5. Zip with forward slashes in entry names (Compress-Archive on Windows
# PowerShell 5.1 writes backslashes, which some extractors mishandle).
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipPath = Join-Path $dist "$addonName-$Version.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in Get-ChildItem $build -Recurse -File) {
        $name = "$addonName/" + $file.FullName.Substring($build.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $name,
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    }
} finally {
    $zip.Dispose()
}

$count = (Get-ChildItem $build -Recurse -File).Count
Write-Host ("Built {0} ({1} files, {2:N0} KB)" -f $zipPath, $count, ((Get-Item $zipPath).Length / 1KB))
if ($env:GITHUB_OUTPUT) {
    Add-Content -Path $env:GITHUB_OUTPUT -Value "zip=$zipPath"
    Add-Content -Path $env:GITHUB_OUTPUT -Value "version=$Version"
}
