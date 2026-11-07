# Lie le dossier de dev PretreCoach dans les AddOns de WoW Forever (jonction, pas besoin d'admin).
# Ensuite, chaque modif est visible en jeu avec /reload.
param([string]$WowPath = "D:\jeux\World of Warcraft")

$src = Join-Path $PSScriptRoot "PretreCoach"
$dst = Join-Path $WowPath "_forever_\Interface\AddOns\PretreCoach"

if (Test-Path $dst) {
    Write-Host "Already there: $dst"
    exit 0
}
New-Item -ItemType Junction -Path $dst -Target $src | Out-Null
Write-Host "Linked: $dst -> $src"
