# Sets "## Interface" in the toc to match your installed WoW client, after a
# patch. Reads the client version (such as 1.60.1.70235) from .build.info in
# the WoW folder; the interface number is major * 10000 + minor * 100 + patch,
# so 1.60.1 is 16001. The CurseForge upload works out its game version from
# this same toc line, so this is the only thing to update after a patch.
#
#   ./scripts/sync-version.ps1                         beta client
#   ./scripts/sync-version.ps1 -Product wow_classic    another client
#   ./scripts/sync-version.ps1 -List                   show installed clients

param(
    [string]$Product = "wow_classic_beta",
    [string]$WowPath = (Join-Path ${env:ProgramFiles(x86)} "World of Warcraft"),
    [switch]$List
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$toc = Join-Path $root "RoadToSixty/RoadToSixty.toc"

$info = Join-Path $WowPath ".build.info"
if (-not (Test-Path $info)) {
    Write-Host "No .build.info in $WowPath. Pass -WowPath." -ForegroundColor Red
    exit 1
}

# .build.info is a table: a header of "Name!TYPE:size" columns separated by
# "|", then one row per installed client.
$lines = Get-Content $info
$columns = $lines[0].Split('|') | ForEach-Object { $_.Split('!')[0] }
$clients = foreach ($line in $lines | Select-Object -Skip 1) {
    if (-not $line) { continue }
    $values = $line.Split('|')
    $row = @{}
    for ($i = 0; $i -lt $columns.Count; $i++) { $row[$columns[$i]] = $values[$i] }
    [pscustomobject]@{ Product = $row["Product"]; Version = $row["Version"] }
}

if ($List) {
    $clients | Format-Table -AutoSize
    exit 0
}

$client = $clients | Where-Object Product -eq $Product | Select-Object -First 1
if (-not $client) {
    Write-Host "No client '$Product' installed. Installed: $(($clients.Product) -join ', ')" -ForegroundColor Red
    exit 1
}
$parts = $client.Version.Split('.')
$interface = [int]$parts[0] * 10000 + [int]$parts[1] * 100 + [int]$parts[2]
$gameVersion = "{0}.{1}.{2}" -f $parts[0], $parts[1], $parts[2]

$text = [System.IO.File]::ReadAllText($toc)
$match = [regex]::Match($text, '(?m)^## Interface:\s*(\d+)')
if (-not $match.Success) {
    Write-Host "No '## Interface:' line in $toc" -ForegroundColor Red
    exit 1
}
$current = [int]$match.Groups[1].Value
if ($current -eq $interface) {
    Write-Host "Toc already matches $Product $($client.Version) (interface $interface)."
    exit 0
}

$text = $text.Substring(0, $match.Groups[1].Index) + $interface + $text.Substring($match.Groups[1].Index + $match.Groups[1].Length)
[System.IO.File]::WriteAllText($toc, $text)
Write-Host "Interface $current -> $interface ($Product $($client.Version), CurseForge game version $gameVersion)."
Write-Host "Commit it, then tag a release: git tag v<version>; git push origin v<version>"
