# Construit dist\PretreCoach-<version>.zip (dossier PretreCoach\ a la racine du zip, format WowUp).
# Version lue dans PretreCoach\PretreCoach.toc (## Version). Sortie dans dist\ (ignore par git).
$toc = Join-Path $PSScriptRoot "PretreCoach\PretreCoach.toc"
$line = Select-String -Path $toc -Pattern '^##\s*Version:\s*(\S+)' | Select-Object -First 1
if (-not $line) { Write-Host "## Version introuvable dans $toc"; exit 1 }
$version = $line.Matches[0].Groups[1].Value

$dist = Join-Path $PSScriptRoot "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "PretreCoach-$version.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

# Compress-Archive (PS 5.1) ecrit des "\" dans le zip : on passe par .NET pour des "/".
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Join-Path $PSScriptRoot "PretreCoach"
$z = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    Get-ChildItem $root -Recurse -File | ForEach-Object {
        $rel = "PretreCoach/" + $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $_.FullName, $rel)
    }
} finally { $z.Dispose() }
Write-Host "Cree : $zip"
