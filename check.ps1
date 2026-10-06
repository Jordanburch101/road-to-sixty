# Syntax-checks every addon file with LuaJIT, runs Lua Language Server
# diagnostics using .luarc.json (if it is installed), then the offline tests.
# Exits 1 if a syntax check or test fails. Runs on Windows PowerShell and on
# pwsh (Linux, CI).

$addon = Join-Path $PSScriptRoot "ForeverMod"
$failed = $false
$scratch = [System.IO.Path]::GetTempFileName()

foreach ($file in Get-ChildItem $addon -Filter *.lua) {
    $out = luajit -b $file.FullName $scratch 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host $out
        $failed = $true
    }
}
Remove-Item $scratch -ErrorAction SilentlyContinue

if (Get-Command lua-language-server -ErrorAction SilentlyContinue) {
    $report = Join-Path ([System.IO.Path]::GetTempPath()) "forevermod-check.json"
    Remove-Item $report -ErrorAction SilentlyContinue
    lua-language-server --check $PSScriptRoot --checklevel=Warning --check_format=json --check_out_path=$report *> $null
    if (Test-Path $report) {
        $results = Get-Content $report -Raw | ConvertFrom-Json
        foreach ($entry in $results.PSObject.Properties) {
            foreach ($problem in $entry.Value) {
                "{0}:{1}  [{2}] {3}" -f (Split-Path $entry.Name -Leaf), ($problem.range.start.line + 1),
                    $problem.code, ($problem.message -split "`n")[0]
            }
        }
    }
} else {
    Write-Host "lua-language-server not found, skipping diagnostics."
}

Push-Location $PSScriptRoot
foreach ($test in Get-ChildItem (Join-Path $PSScriptRoot "tests") -Filter *_test.lua) {
    luajit "tests/$($test.Name)"
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}
Pop-Location

if ($failed) { exit 1 }
Write-Host "Syntax OK."
exit 0
