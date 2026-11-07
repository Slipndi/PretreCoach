#!/bin/sh
# Lie le dossier PretreCoach/ du clone dans les AddOns de WoW Forever (Mac/Linux).
# Usage : ./install.sh [chemin de World of Warcraft]  (defaut : /Applications/World of Warcraft)
# Ensuite, chaque modif est visible en jeu avec /reload.
set -eu

WOW_PATH="${1:-/Applications/World of Warcraft}"
SRC="$(cd "$(dirname "$0")" && pwd)/PretreCoach"
ADDONS="$WOW_PATH/_forever_/Interface/AddOns"
DST="$ADDONS/PretreCoach"

if [ -e "$DST" ] || [ -L "$DST" ]; then
    echo "Already there: $DST"
    exit 0
fi
if [ ! -d "$ADDONS" ]; then
    echo "AddOns folder not found: $ADDONS (check the path: $WOW_PATH)"
    exit 1
fi
ln -s "$SRC" "$DST"
echo "Linked: $DST -> $SRC"
