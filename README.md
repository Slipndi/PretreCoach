# PretreCoach

Addon pour **World of Warcraft: Forever** (client `_forever_`, Interface 16001) : un guide de leveling interactif pour le prêtre, du niveau 1 au 60. Tout est en français.

## Ce que fait l'addon

- Guide pas à pas avec des objectifs cochés automatiquement selon l'état réel du personnage.
- Surveille les règles d'or du leveling prêtre (baguette, règle des 5 secondes, changement de zone, talents, etc.).
- Coach de cycle : prochain sort conseillé, selon le niveau et les sorts connus.
- Rappels d'entraînement chez le maître, talents, métiers (Herboristerie, Alchimie, Secourisme).
- Dit où aller (rôle, zone, coordonnées) et peut placer un repère sur la carte.

## Règle 0 : conseil seul

L'addon lit et affiche, il n'agit jamais à la place du joueur : aucun lancement de sort, aucun clic, aucun achat ni vente automatique, aucune macro, aucun message envoyé, aucune sortie lisible par une machine. Il est conçu pour respecter les règles de Blizzard (vérifié par `tests/compliance.lua`). Brancher un logiciel externe dessus (AutoHotkey, lecteur de pixels, etc.) reste interdit au joueur. Détails : `Docs/PROMPT_ADDON_PRETRE_COACH.md`, section 0.

## Dépendances optionnelles

- **Questie** (ou sa base seule, `LibQuestieDB`) : positions des maîtres et des PNJ de ville, quêtes de la zone, itinéraire optimisé et repères sur la carte du monde (« ! » à prendre, « ? » à rendre, point d'objectif, anneau numéroté sur l'itinéraire).
- **Auctionator** : prix pour les conseils de métiers et de vente.

Aussi lus s'ils sont présents : **QuestDB** et **What's Training**. Sans eux, l'addon fonctionne seul (conseils plus pauvres).

## Installation

### Voie A : WowUp-CF (PC ou Mac)

1. Dans WowUp, choisir le client **WoW Forever**.
2. « Install from URL », puis coller `https://github.com/Slipndi/PretreCoach`.

Nécessite une release GitHub (zip `PretreCoach-<version>.zip`, dossier `PretreCoach/` à la racine). WowUp propose ensuite les mises à jour tout seul. Zip local : `powershell -File build-release.ps1` (sortie dans `dist/`).

### Voie B : git clone

```
git clone https://github.com/Slipndi/PretreCoach.git
```

- Windows : `powershell -File install.ps1` (option `-WowPath "<dossier WoW>"`).
- Mac / Linux : `./install.sh` (chemin par défaut `/Applications/World of Warcraft`, modifiable en premier argument).

Cela crée un lien vers `_forever_/Interface/AddOns/PretreCoach`. Mise à jour : `git pull`, puis `/reload` en jeu.

## Utilisation

- `/coach` : options. `/coach guide` : fenêtre du guide. `/coach compact` : carte « Prochain objectif ».
- `/coach lock` / `unlock` : verrouiller ou déplacer les fenêtres. `/coach reset` : réinitialiser.
- `/coach probe` : sonde des API du jeu. `/coach here` : position du joueur. `/coach debug` : mode debug.
- Bouton de la minicarte : clic gauche pour le menu, clic droit pour le guide.

## Sauvegardes

Les réglages et caches (`PretreCoachDB`) sont locaux à chaque machine : rien n'est synchronisé entre PC et Mac.

## Tests hors jeu

```
powershell -File test.ps1
```

Lint et tests via LuaJIT (`winget install DEVCOM.LuaJIT`).
