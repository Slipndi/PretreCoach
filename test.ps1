# Lint + tests sans le jeu. Code de sortie non nul en cas d'echec.
$ErrorActionPreference = "Stop"
$lj = (Get-Command luajit -ErrorAction SilentlyContinue).Source
if (-not $lj) { $lj = Join-Path $env:LOCALAPPDATA "Programs\LuaJIT\bin\luajit.exe" }
if (-not (Test-Path $lj)) { Write-Host "luajit introuvable (winget install DEVCOM.LuaJIT)"; exit 2 }
Set-Location $PSScriptRoot
$rc = 0
foreach ($s in "tests\lint.lua", "tests\run.lua") {
    Write-Host "== $s"
    & $lj $s
    if ($LASTEXITCODE -ne 0) { $rc = 1 }
}
if ($rc -ne 0) { Write-Host "ECHEC" } else { Write-Host "OK" }
exit $rc
