# Mission : créer l'addon « PretreCoach » pour World of Warcraft: Forever

Tu vas créer un addon WoW pour un prêtre mort-vivant qui monte de niveau sur **World of Warcraft: Forever**. C'est un **guide de leveling interactif, branché sur ce qui se passe en jeu**, qui :

1. **Guide le joueur pas à pas** du niveau 1 au 60 : étape en cours, objectifs cochés automatiquement selon l'état réel du personnage, prochaines étapes clés.
2. **Fait respecter les règles d'or** du leveling prêtre : il les surveille en direct et alerte quand l'une n'est pas respectée.
3. **Coache le cycle de dégâts** : prochain sort conseillé en temps réel, avec une logique qui change selon le niveau.
4. **Rappelle quand aller chez le maître** pour les nouveaux sorts et rangs, et où mettre les points de talent.
5. **Est joli** : interface propre, lisible, agréable, en français.

Le joueur est développeur (PHP/Laravel, Python) mais ne connaît pas forcément l'API Lua de WoW. Explique brièvement tes choix et donne des étapes de test claires.

---

## 1. Contexte technique : à lire avant d'écrire une ligne

### 0. Règle essentielle : conformité Blizzard (aucun risque de bannissement)

Le compte du joueur ne doit jamais pouvoir être banni à cause de l'addon. Cette règle passe avant toutes les autres.

**Permis** : l'API Lua officielle de l'interface, pour lire et afficher ; des minuteurs sur ses propres sorts.

**Interdit dans l'addon** (vérifié par `tests/compliance.lua`) :
- lancer ou cibler à la place du joueur (`CastSpell*`, `UseAction`, `TargetUnit`, etc.) ;
- fonctions protégées et cadres sécurisés (`SecureActionButtonTemplate`, `SetAttribute`), sauf l'exception encadrée ci-dessous ;
- toucher aux raccourcis, macros ou barres (`SetBinding*`, `EditMacro`, `CreateMacro`, `PickupSpell`, `PlaceAction`) ;
- envoyer des messages de chat ou d'addon (`SendChatMessage`, `C_ChatInfo.SendAddonMessage`) ;
- `COMBAT_LOG_EVENT_UNFILTERED` et tout contournement des valeurs secrètes ;
- code obscurci (`loadstring`, `RunScript`, `setfenv`) ;
- publicité ou demande de dons ;
- toute sortie destinée à une machine : carrés de couleur ou pixels codant le conseil pour être lus par un programme externe.

**Exception encadrée (2026-11-07)** : le joueur a choisi explicitement des cadres de groupe Blizzard sécurisés (modèle de Clique, HealBot et Grid, autorisé par Blizzard) pour soigner d'un clic. Un seul fichier les porte, `PretreCoach/UI/HealFrames.lua` (liste blanche limitée à ce fichier dans `tests/compliance.lua`) : `SecureUnitButtonTemplate`, `SetAttribute`, `RegisterUnitWatch`. Les attributs (`type1/2` = `spell`, `spell1/2` = nom du sort choisi par le joueur, `unit`) ne sont posés qu'hors combat (`InCombatLockdown()`, sinon différé à `PLAYER_REGEN_ENABLED`) ; les cadres sont créés hors combat. Le sort de chaque bouton de souris est un réglage fixe du joueur. Restent interdits, même dans ce fichier : `macrotext`, `CastSpell*`, `SetBinding*`, `SendChatMessage`, tout lancement sans clic, toute rotation automatique, tout sort choisi par l'addon selon l'état du jeu.
**Exception approuvée par l'utilisateur (2026-11-07, « Étendre l'exception »)** : la barre Consommables (`PretreCoach/UI/ConsumablesBar.lua`, ce fichier seul) utilise `SecureActionButtonTemplate` et `SetAttribute` pour cinq boutons d'objet (`type1="item"`, `item1="item:ID"`). Le joueur clique lui-même ; rien ne se déclenche seul ; les attributs ne changent jamais en combat (mise en attente jusqu'à `PLAYER_REGEN_ENABLED`). `macrotext` et `UseContainerItem` restent interdits partout. La liste blanche par fichier est dans `tests/compliance.lua`.
**Exception approuvée par l'utilisateur (2026-11-07, « Ouvre le métier »)** : l'icône Craft, un petit bouton à droite des rangées Alchimie et Secourisme de la carte du guide au lieu d'une fenêtre (`PretreCoach/UI/CraftPopup.lua`, ce fichier seul ; mêmes règles), utilise `SecureActionButtonTemplate` et `SetAttribute` pour des boutons `type1="spell"`, `spell1="<nom du sort du métier>"` : le clic du joueur lance le sort du métier, ce qui ouvre la fenêtre de métier, comme un clic sur la barre d'actions. L'addon présélectionne ensuite la recette qui fait monter la compétence (`C_TradeSkillUI.OpenRecipe`, navigation d'interface non protégée) ; le joueur clique lui-même sur « Créer ». Les attributs ne changent jamais en combat (mise en attente jusqu'à `PLAYER_REGEN_ENABLED`). `CraftRecipe`, `C_TradeSkillUI.Craft`, `OpenTradeSkill` et `macrotext` restent interdits partout : aucune fabrication automatique.

**Interdit au joueur** : brancher un logiciel externe sur l'addon (AutoHotkey, macro souris ou clavier qui appuie sur la touche conseillée, lecteur de pixels, lecteur de mémoire, « unlockers »). C'est ce qui fait bannir.

**Sources officielles** (relevées le 2026-11-07) :
- EULA Blizzard, section 1.C.ii : interdit les « bots; i.e. any code and/or software, not expressly authorized by Blizzard, that allows the automated control of a Game », les « hacks » et les « cheats » ; section 1.C.vi : logiciels non autorisés qui interceptent ou « mine » des informations. https://www.blizzard.com/en-us/legal/fba4d00f-c7e4-4883-b8b9-1b4500a402ea/blizzard-end-user-license-agreement
- UI Add-On Development Policy (2009) : gratuit, code non obscurci, ni pub ni demande de dons en jeu, aucune nuisance (chat, disque, framerate). https://us.forums.blizzard.com/en/wow/t/24534
- « Combat Philosophy and Addon Disarmament in Midnight » : « Addons should no longer offer a competitive advantage in WoW combat » ; les infos de combat sont des « secret values ». http://worldofwarcraft.blizzard.com/en-us/news/24246290
- WoW Forever : aucune politique propre trouvée.

**Honnêteté** : Blizzard garde le jugement final (« sole determination »). Respecter ces règles réduit le risque au minimum, mais ne donne aucune garantie juridique absolue.

WoW Forever (sorti le 4 novembre 2026) a le contenu de Vanilla (niveau max 60, rangs de sorts, maître de classe), mais tourne sur le **moteur et l'API modernes de WoW Retail (branche 12.x, époque Midnight 12.1.5)**. Ça change tout :

- **Dossier des addons** : `World of Warcraft/_forever_/Interface/AddOns/` (sous Windows, souvent `C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns\`).
- **Numéro d'interface du .toc** : les addons Forever de la bêta utilisaient `## Interface: 16001` (version du jeu 1.60.1). À vérifier en jeu avec `/dump (select(4, GetBuildInfo()))`, puis ajuster le .toc.
- **Restrictions « secret values » (comme sur Midnight)** : en combat, le jeu cache aux addons la vie, le mana, les auras (buffs et débuffs), les temps de recharge, la menace, et parfois d'autres infos. Un addon peut **afficher** une valeur secrète (la passer à `StatusBar:SetValue`, `FontString:SetText`, etc.) mais **ne peut pas la comparer, la calculer ou s'en servir pour décider**. Toute comparaison sur une valeur secrète provoque une erreur.
  - Tester avec `issecretvalue(v)` avant toute logique.
  - Ne jamais faire de `if mana < x` ou de calcul sur une valeur potentiellement secrète sans ce test.
- **Journal de combat interdit** : enregistrer `COMBAT_LOG_EVENT_UNFILTERED` provoque une erreur. N'en dépends pas.
- **Pas d'automatisation** : l'addon conseille, il ne lance jamais de sort à la place du joueur. Pas de fonctions protégées en combat, et vérifie `InCombatLockdown()` avant toute modification de cadre sécurisé.
- **Approche qui marche sur Forever** (utilisée par les addons Forever qui fonctionnent, comme Full Mana Forever ou Lifesworn) : **suivre les propres sorts lancés par le joueur** (événement `UNIT_SPELLCAST_SUCCEEDED` sur l'unité `player`, à vérifier qu'il n'est pas restreint) et tenir ses propres minuteurs : règle des 5 secondes, durée de Mot de l'ombre : Douleur par cible, temps de recharge à partir de durées connues.
- **Hors combat**, la plupart des données sont lisibles : niveau, zone, équipement, grimoire, talents, métiers, quêtes terminées, mana (Forever : voir 10.1, vie et mana sont secrets même hors combat). Le guide interactif s'appuie surtout sur ces moments-là.
- **Régénération du mana continue** : il n'y a pas de « ticks » de 2 secondes. La règle des 5 secondes existe toujours (la regen basée sur l'Esprit s'arrête 5 secondes après un sort qui coûte du mana).
- **La baguette** (sort « Tir » / Shoot) demande d'être immobile 0,5 seconde avant de tirer.
- **API différente de Retail sur certains points** : certains modèles (templates) et fonctions de Retail n'existent pas dans Forever. Avant d'utiliser une API (`C_Spell`, `C_SpellBook`, `C_Map`, `C_QuestLog`, `C_Timer`, `Settings`, `C_AssistedCombat`, fonctions du maître de classe, emplacement d'arme à distance, etc.), vérifie qu'elle existe et prévois une solution de repli.
- **Client en français** : n'identifie rien par son nom anglais. Utilise les identifiants (sorts, objets, quêtes, cartes `uiMapID`) et récupère les noms localisés à l'exécution.
- **Faits relevés en jeu** : une sonde réelle a déjà tranché plusieurs points de cette section (vie et mana secrets, API de talents, globales absentes). Voir la section 10.1, qui prime en cas de conflit.

---

## 2. Phase 0 obligatoire : sonde d'API

Comme on ne connaît pas exactement l'API de Forever, commence par une commande de diagnostic **avant** les fonctionnalités :

- `/coach probe` affiche dans une fenêtre copiable :
  - la version du jeu et le numéro d'interface ;
  - la liste des API utilisées par l'addon, avec « existe / n'existe pas » ;
  - pour la vie, le mana, les auras de la cible, les temps de recharge, le GUID de la cible, `UnitIsDead("target")` : « lisible » ou « secret », **hors combat et en combat** (la commande mémorise un relevé hors combat, puis complète au prochain combat) ;
  - l'objet porté dans l'emplacement d'arme à distance (la baguette) et comment le lire ;
  - si le déplacement du joueur est détectable (`GetUnitSpeed("player")`, `IsPlayerMoving` ou événements de déplacement) ;
  - l'identifiant de carte de la zone actuelle (`C_Map.GetBestMapForUnit("player")`) ;
  - si `UNIT_SPELLCAST_SUCCEEDED`, `PLAYER_LEVEL_UP`, `PLAYER_EQUIPMENT_CHANGED`, `ZONE_CHANGED_NEW_AREA`, `TRAINER_SHOW`, `PLAYER_TARGET_CHANGED`, `SKILL_LINES_CHANGED`, `QUEST_TURNED_IN` et les événements de talents se déclenchent bien ;
  - s'il existe une API pour les talents Legacy et la double spécialisation ;
  - les compétences de métier (Herboristerie, Alchimie, Secourisme) et leur rang, lisibles ou non, et l'API qui les donne (`GetProfessions`/`GetProfessionInfo` ou `GetSkillLineInfo`).
- Demande au joueur de lancer la sonde en jeu et de te coller le résultat. **Adapte ensuite le code à ce qui est réellement disponible.**

---

## 3. Le guide interactif (fenêtre principale)

Une fenêtre « Guide » qui s'ouvre avec `/coach guide` ou un bouton de la minicarte, et qui se met à jour seule.

### 3.1 Contenu

- **En-tête** : niveau actuel, barre de progression vers le 60, palier en cours (1-10, 10-20, etc.), zone actuelle avec un badge de couleur (adaptée, devient verte, trop haute).
- **Onglet « Maintenant »** : la liste des objectifs du palier en cours, **cochés automatiquement** selon l'état réel du personnage. Exemples :
  - « Équipe une baguette » coché dès qu'une baguette est portée ;
  - « Spécialisation Baguette 2/2 » coché quand les points sont placés ;
  - « Apprends tes nouveaux sorts » coché quand plus rien n'est en attente chez le maître ;
  - « Herboristerie au niveau des herbes de la zone » coché selon la compétence du métier ;
  - « Termine la quête du Gravestone Scepter » coché via la quête terminée (ID de quête à vérifier).
- **Onglet « Prochaines étapes »** : les jalons à venir, avec le niveau, sous forme de frise ou de liste élégante (voir les jalons en 3.3).
- **Onglets de référence** : Talents, Sorts à apprendre, Donjons, Zones, Métiers, Atouts du mort-vivant. Chaque onglet met en avant ce qui concerne le niveau actuel (ligne surlignée, le reste atténué).
- **Lien avec le jeu** : se met à jour sur les événements (montée de niveau, changement de zone, équipement, talents, métier, quête rendue, visite chez le maître). Hors combat uniquement pour ce qui est lourd.

### 3.2 Comportement

- Quand un objectif se coche, petite animation et toast discret (« Baguette équipée, bien joué »).
- Quand le palier change, toast « Nouveau palier : 10-20 » avec les 3 priorités du palier.
- La fenêtre se souvient de son onglet, de sa position et de sa taille.
- Option « mode compact » : une simple carte « Prochain objectif » qui reste à l'écran.

### 3.3 Jalons à coder (Data/Milestones.lua)

| Niveau | Jalon |
| --- | --- |
| 4 | Mot de l'ombre : Douleur disponible : ouvre tes combats avec |
| 5 | Baguette magique inférieure (hôtel des ventes ou récompense de quête). Apprends Herboristerie et Alchimie à Brill, et Secourisme (maître à vérifier) |
| 6 | Mot de pouvoir : Bouclier avant chaque combat |
| 10 | Premiers talents : Spécialisation Baguette. Racial : Toucher de faiblesse (Forever : voir 10.1) |
| 10 | Rang Compagnon en Herboristerie et Alchimie (compétence 50) |
| 12-16 | Connexion spirituelle 5/5 |
| 13 | Baguette magique supérieure (hôtel des ventes). Gouffre de Ragefeu (bâton de quête +18 dégâts des sorts) |
| 15 | Ruines de Lordaeron et Cavernes des lamentations (bâton de quête +5 dégâts des sorts) |
| 20 | Racial : Sacrifice sombre. Protection contre la peur et Peste dévorante. Donjon d'Ombrecroc. Rang Expert (compétence 125) |
| 24-32 | Profondeurs de Brassenoire : quête du Gravestone Scepter (baguette qui renforce Mot de l'ombre : Douleur) |
| 30 | Esprit divin. Option Pénitence pour les donjons (Forever : voir 10.1, talent 402174) |
| 32 | Mot de l'ombre : Mort (Forever : voir 10.1, ID 32379 non valide) |
| 35 | Rang Artisan (compétence 200). Secourisme Artisan : quête Triage (Hammerfall, Hautes-terres d'Arathi, à vérifier) |
| 40 | Respec Ombre (31 points) pour la Forme d'Ombre. Double spécialisation : une spé Ombre solo, une spé soin donjons |

---

## 4. Les règles d'or : surveillance en direct

C'est le cœur du coaching. Chaque règle a une détection, un retour visuel, et un repli si l'info est secrète. Un petit bandeau « Règles d'or » montre l'état de chaque règle (vert respectée, orange à surveiller, rouge non respectée), et un clic dessus explique la règle.

| Règle | Détection | Retour au joueur | Si l'info n'est pas lisible |
| --- | --- | --- | --- |
| **1. Baguette d'abord** | Niveau 5 ou plus et pas de baguette dans l'emplacement d'arme à distance. Baguette dont le niveau requis est 10 niveaux ou plus sous celui du joueur | « Équipe une baguette » avec où l'obtenir. « Ta baguette est dépassée, change-la » avec la prochaine baguette conseillée | Vérifier à chaque changement d'équipement et hors combat |
| **2. Achève à la baguette** | Après Mot de l'ombre : Douleur et un sort de burst sur la cible, le conseil passe à la baguette. Si la mort de la cible est détectable, compter les monstres achevés à la baguette (dernier lancement avant la mort = Tir) | Message « Achève à la baguette pour Connexion spirituelle ». Statistique de session : « 8 monstres sur 10 achevés à la baguette » | Garder seulement le conseil, sans statistique |
| **3. Règle des 5 secondes** | Minuteur lancé à chaque sort qui coûte du mana (tes propres lancements) | Barre de 5 secondes sous l'icône. Si le joueur relance un sort coûteux alors que la barre tourne et que ce n'est pas un soin d'urgence, petit rappel « Laisse la regen repartir, passe à la baguette » | Fonctionne sans données secrètes |
| **4. Arrête-toi pour tirer** | Conseil = baguette et joueur en mouvement | Icône de la baguette qui clignote avec « Arrête-toi » | Si le mouvement n'est pas détectable, simple rappel la première fois de la session |
| **5. Change de zone dès qu'elle devient verte** | Niveau du joueur comparé à la plage de la zone actuelle (table des zones par `uiMapID`). Zone verte quand le joueur dépasse la fin de la plage | Badge de zone orange puis rouge, et toast « Cette zone devient verte. Direction : X » avec la zone conseillée | Hors combat, fonctionne sans données secrètes |
| **6. Premier talent Legacy : Thrill of Adventure** | Si l'API des talents Legacy existe : point disponible et Thrill of Adventure pas à 5/5 | Rappel « Mets ton point Legacy dans Thrill of Adventure » | Sinon, rappel unique dans la liste des objectifs |
| **7. Ne saute pas Brassenoire** | Joueur entre 24 et 32 et quête du Gravestone Scepter non terminée | Objectif dans le guide et rappel en entrant en Ashenvale | ID de quête à vérifier ; sinon objectif à cocher à la main |
| **8. Double spécialisation au 40** | Niveau 40 ou plus et Forme d'Ombre non apprise, ou une seule spécialisation | Rappel « Respec Ombre et active ta double spé » | Rappel unique au niveau 40 |

Les règles 1 à 4 s'affichent aussi en combat (via les conseils du cycle). Les règles 5 à 8 ne s'affichent que hors combat.

---

## 5. Coach de cycle

Un panneau avec **une grande icône** (le prochain sort conseillé), **deux petites icônes** (les suivants), et une ligne de texte courte qui explique le conseil (« Pose ton DoT », « Achève à la baguette »). Afficher le raccourci clavier du sort sur l'icône si on le trouve dans les barres d'action.

La logique choisit les règles selon le niveau du joueur et les sorts réellement connus (`IsPlayerSpell` / `IsSpellKnown` ou équivalent ; `GetSpellInfo` est absent, Forever : voir 10.1). Priorités à coder :

**Niveaux 1 à 10, avant la baguette**
1. Avant d'engager : Mot de pouvoir : Bouclier (dès le niveau 6).
2. Ouverture : Mot de l'ombre : Douleur (dès le niveau 4).
3. Châtiment tant que le monstre n'est pas bas.
4. Puis finir au corps à corps.

**Niveaux 10 à 40, avec baguette et Connexion spirituelle (Spirit Tap)**
1. Avant d'engager : Mot de pouvoir : Bouclier.
2. Ouverture : Attaque mentale, ou Flammes sacrées si apprises.
3. Mot de l'ombre : Douleur (si pas déjà posé sur cette cible, d'après ton propre minuteur).
4. Baguette jusqu'à la mort du monstre. Ne reconseiller Attaque mentale que si le mana est haut **et lisible** ; si le mana est secret, rester sur la baguette (Forever : voir 10.1, le mana est secret en permanence, donc toujours la baguette).
5. Groupe de monstres : conseiller de poser Mot de l'ombre : Douleur sur 3 ou 4 cibles (changement de cible détecté), puis baguette.
6. Si un monstre arrive au contact et que la position est lisible : proposer Cri psychique, avec l'avertissement « seulement si l'endroit est dégagé ».

**Niveaux 40 à 60, en Forme d'Ombre**
1. Forme d'Ombre active (rappel si elle n'est pas détectée hors combat).
2. Avant d'engager : Bouclier, puis Attaque mentale.
3. Mot de l'ombre : Douleur.
4. Mot de l'ombre : Mort et Attaque mentale dès qu'ils sont disponibles (temps de recharge suivis par ton propre minuteur depuis le lancement) (Forever : voir 10.1, ID de sort et recharges secrètes).
5. Fouet mental pour combler.

Règles générales :
- Ne jamais conseiller un sort non appris.
- Si une info nécessaire est secrète, choisir l'option la plus économe en mana (la baguette) plutôt que deviner.
- Afficher l'icône en gris quand le sort conseillé est en recharge selon ton minuteur.
- Hors combat, si le mana ou la vie sont bas et lisibles (Forever : voir 10.1, ils ne le sont pas) : proposer Cannibalisme (si un cadavre humanoïde ou mort-vivant est à portée et que le sort est utilisable) ou Sacrifice sombre (vie correcte, mana bas), avant de proposer de boire. Si la vie est basse et le mana correct, proposer un **bandage** avant de manger : il ne coûte pas de mana et ne relance pas la règle des 5 secondes ; débuff « Bandage récent » de 60 s, interrompu par les dégâts.
- En combat : potion de mana conseillée seulement si le mana est lisible (Forever : voir 10.1) ; sinon ne rien conseiller (FullManaForever fait déjà ce travail, ne pas le dupliquer).

---

## 6. Sorts, talents et données de référence

### 6.1 Rappels d'entraînement (Data/Spells.lua)

- Liste des sorts du prêtre avec, pour chaque rang, l'ID du sort, le niveau requis et si possible le coût en or. Construis-la à partir d'une source fiable pour Forever (par exemple warcraft.wiki.gg, catégorie Forever, ou Wowhead) et **marque comme « à vérifier » tout ce qui n'est pas confirmé**. N'invente pas d'ID.
- Nouveautés de Forever : Protection contre la peur et Peste dévorante pour tous les prêtres au niveau 20, Esprit divin au niveau 30, Mot de l'ombre : Mort au niveau 32. Sorts raciaux du mort-vivant : Toucher de faiblesse au niveau 10 (Forever : voir 10.1, non vendu par le maître), Sacrifice sombre (Dark Sacrifice) au niveau 20. Mot de l'ombre : Mort : ID 32379 non valide (Forever : voir 10.1).
- À chaque montée de niveau : si des sorts ou rangs deviennent disponibles et ne sont pas connus, toast « Nouveaux sorts chez ton maître : X (rang 2), Y ».
- Compteur discret dans le panneau : « 3 sorts à apprendre ».
- Quand le joueur ouvre la fenêtre du maître (si l'événement existe) : lire les services proposés pour corriger les données, et surligner ce qu'il reste à apprendre.
- Option : regrouper les visites (« passe au maître tous les 2 niveaux ») pour économiser des allers-retours.

### 6.2 Talents (Data/Talents.lua)

| Niveaux | Talent à prendre |
| --- | --- |
| 10-11 | Spécialisation Baguette 2/2 (Discipline) |
| 12-16 | Connexion spirituelle 5/5 (Ombre) |
| 17-18 | Mot de l'ombre : Douleur amélioré 2/2 (Ombre) |
| 19-39 | Discipline : Force mentale, Martyre, Méditation |
| 40 | Respec chez le maître : 31 points en Ombre pour la Forme d'Ombre |
| 41-60 | Spécialisation Baguette à nouveau, puis talents de mana en Discipline |

À chaque niveau à partir de 10 : toast « Ton point de talent : X ». Si les points placés ne suivent pas le plan, le signaler dans le guide sans insister.

### 6.3 Zones (Data/Zones.lua, à lier aux `uiMapID`)

| Niveaux | Zones |
| --- | --- |
| 1-10 | Clairières de Tirisfal |
| 10-20 | Forêt des Pins-Argentés, les Tarides |
| 20-30 | Contreforts de Hautebrande, Les Serres-Rocheuses, Ashenvale |
| 30-40 | Mille Pointes, Désolace, Hautes-terres d'Arathi, Vallée de Strangleronce |
| 35-45 | Riverglades (nouvelle zone Forever) |
| 40-50 | Tanaris, Feralas, les Hinterlands, Terres ingrates |
| 50-60 | Cratère d'Un'Goro, Gangrebois, Steppes ardentes, Berceau-de-l'Hiver, Maleterres de l'Est |

### 6.4 Donjons (Data/Dungeons.lua)

| Niveaux | Donjons côté Horde |
| --- | --- |
| 13-22 | Gouffre de Ragefeu (13-18), Ruines de Lordaeron (15-22, Tirisfal) |
| 15-30 | Cavernes des lamentations (15-24), Donjon d'Ombrecroc (20-30) |
| 24-35 | Profondeurs de Brassenoire (24-32), Cité de Dalaran (28-35) |
| 29-46 | Kraal de Tranchebauge (29-38), Monastère écarlate (30-46, Tirisfal), Drowned City (35-42), Souilles de Tranchebauge (37-46) |
| 40-55 | Krol'Dok Stronghold (40-47), Uldaman (41-51), Zul'Farrak (44-54), Maraudon (46-55), Alcaz Prison (48-55) |
| 50-60 | Temple englouti, Profondeurs de Rochenoire, Hache-Tripes, Pic Rochenoire, Blackmaw Hold, Shaper's Terrace, Stratholme, Scholomance |

L'onglet Donjons montre en premier ceux de la tranche du joueur, avec les conseils de soin : eau, Bouclier sur le tank avant le pull, Rénovation sur ceux qui prennent des dégâts en continu, Mot de l'ombre : Douleur entre deux soins, Robustesse sur tout le groupe.

### 6.5 Baguettes (Data/Gear.lua)

| Niveau | Baguette | Source |
| --- | --- | --- |
| 5 | Baguette magique inférieure | Hôtel des ventes ou récompense de quête (pas d'Enchantement) |
| 13 | Baguette magique supérieure | Hôtel des ventes, environ 50 % de dégâts en plus |
| 18-25 | Gravestone Scepter | Quête des Profondeurs de Brassenoire |

Caractéristiques : puissance des sorts au début, puis Esprit dès 40 à 50 de puissance des sorts, puis Intelligence et Endurance.

### 6.6 Métiers (Data/Professions.lua)

Tous les ID d'objets, de recettes et de PNJ sont à vérifier sur Forever ; l'addon lit les noms localisés en jeu. Les niveaux de compétence viennent de Vanilla, marqués à vérifier.

**Rangs** (Herboristerie et Alchimie). Maîtres à Brill (Clairières de Tirisfal) et Fossoyeuse.

| Rang | Compétence max | Condition pour le prendre |
| --- | --- | --- |
| Apprenti | 75 | Départ (compétence 1-75) |
| Compagnon | 150 | Compétence 50 et niveau 10 |
| Expert | 225 | Compétence 125 et niveau 20 |
| Artisan | 300 | Compétence 200 et niveau 35 |

**Herboristerie, herbes par tranche** (indicatif, calé sur le parcours de zones de 6.3 ; noms français à vérifier).

| Compétence | Zones | Herbes |
| --- | --- | --- |
| 1-70 | Tirisfal | Pacifique, Feuillargent, Terrestrine |
| 70-115 | Pins-Argentés, Tarides | Mage royal, Églantine, Doulourante |
| 115-170 | Hautebrande, Serres-Rocheuses, Ashenvale | Aciérite sauvage, Tombeline, Sang-royal, Vietérule, Pâlerette |
| 170-230 | Arathi, Strangleronce, Désolace | Dorépine, Moustache de Khadgar, Fleur de feu, Lotus pourpre, Larmes d'Arthas |
| 230-300 | Tanaris, Feralas, Hinterlands, Un'Goro, Gangrebois, Berceau-de-l'Hiver | Soleillette, Gromsang, Sansam doré, Feuillerêve, Sauge-argent des montagnes, Fleur de peste, Calot de glace |

**Alchimie utile au prêtre** (compétence requise, à vérifier).

| Compétence | Recette |
| --- | --- |
| 1 | Potion de soins mineure |
| 25 | Potion de mana mineure |
| 90 | Élixir de sagesse |
| 120 | Potion de mana inférieure |
| 160 | Potion de mana |
| 215 | Potion de mana supérieure |
| 250 | Élixir de puissance de l'ombre (recette à trouver) |
| 260 | Potion de mana excellente |
| 295 | Potion de mana majeure (recette à trouver) |

Herboristerie + Alchimie = autonomie complète en potions de mana pour les donjons.

**Secourisme, bandages** (compétence requise, à vérifier).

| Compétence | Bandage |
| --- | --- |
| 1 / 40 | Lin / lin épais |
| 80 / 115 | Laine / laine épais |
| 150 / 180 | Soie / soie épais |
| 210 / 240 | Tisse-mage / tisse-mage épais |
| 260 / 290 | Étoffe runique / étoffe runique épais |
| 80 | Anti-venin |

Expert à 125 via un manuel (vendeur à vérifier), Artisan à 225 via la quête Triage (niveau 35). Le tissu vient des humanoïdes tués : sans Couture, tout va au Secourisme, le surplus à l'hôtel des ventes.

**Objectifs du guide cochés automatiquement** (compétences lisibles hors combat) :
- métier appris ;
- « Va prendre le rang X » quand la compétence atteint le seuil et le niveau requis ;
- herboristerie suffisante pour les herbes de la zone actuelle ;
- secourisme au niveau du meilleur bandage du palier ;
- potions de mana en stock avant un donjon (compte d'objets hors combat).

**Toasts** : « Herboristerie 50 : va prendre le rang Compagnon à Brill », « Nouveau bandage disponible : X ».

**Points Legacy** : l'Alchimie (métier d'artisanat) donne un point Legacy à 150, 225 et 300 ; à vérifier pour l'Herboristerie et le Secourisme.

---

## 7. Interface : « joli » est un vrai critère

- Style sombre et sobre : fond semi-transparent, fine bordure, accents violet Ombre et blanc prêtre, typographie lisible.
- Grande icône du cycle avec une lueur douce animée (AnimationGroup) quand le conseil change.
- Objectifs cochés avec une petite animation ; jalons présentés comme une frise verticale élégante.
- Notifications en « toast » qui glissent puis disparaissent, jamais de spam dans le chat. Une notification identique ne se répète pas avant un délai.
- Fenêtres déplaçables, verrouillables, taille et opacité réglables. Réglages sauvegardés par personnage (SavedVariables).
- Panneau d'options (via l'API `Settings` si elle existe dans Forever, sinon une fenêtre maison) : afficher ou masquer chaque bloc (guide, cycle, règles d'or, toasts), taille, opacité, verrouillage.
- Tous les textes en français dans `Locales/frFR.lua`.
- Commandes : `/coach` (options), `/coach guide`, `/coach lock`, `/coach unlock`, `/coach reset`, `/coach probe`, `/coach debug`.

---

## 8. Qualité et organisation

Structure conseillée :

```
PretreCoach/
  PretreCoach.toc
  Core.lua            -- événements, état du personnage, minuteurs
  Secrets.lua         -- aides pour gérer les valeurs secrètes sans erreur
  GoldenRules.lua     -- surveillance des règles d'or
  Rotation.lua        -- logique du cycle par palier
  Guide.lua           -- objectifs, paliers, jalons, coches automatiques
  Training.lua        -- rappels d'entraînement
  Talents.lua         -- rappels de talents
  UI/GuideWindow.lua
  UI/RotationPanel.lua
  UI/RulesBar.lua
  UI/Toast.lua
  UI/Options.lua
  Data/Spells.lua
  Data/Talents.lua
  Data/Milestones.lua
  Data/Zones.lua
  Data/Dungeons.lua
  Data/Gear.lua
  Data/Professions.lua
  Locales/frFR.lua
  Media/              -- textures éventuelles
```

- Aucune erreur Lua en combat : protège les accès sensibles avec `pcall` et `issecretvalue`. Recommande au joueur BugSack et BugGrabber pour voir les erreurs.
- Code léger : mises à jour sur événements plutôt que toutes les images, et `C_Timer` ou un `OnUpdate` limité pour les barres.
- Toutes les données de guide dans `Data/` pour pouvoir les corriger sans toucher à la logique.
- Mode debug (`/coach debug`) qui affiche pourquoi tel sort est conseillé et pourquoi telle règle est en orange ou en rouge.

---

## 9. Ordre de travail

1. Crée la structure et le .toc, puis la commande `/coach probe`. Donne-moi les instructions pour copier le dossier dans `_forever_/Interface/AddOns/` (un petit script de copie ou un lien symbolique, pour que je puisse tester en tapant `/reload`).
2. Attends le résultat de la sonde que je te colle, et adapte le plan.
3. Fais la fenêtre du guide interactif avec les objectifs qui se cochent seuls (section 3) et les données de référence (section 6).
4. Ajoute la surveillance des règles d'or (section 4).
5. Ajoute le coach de cycle (section 5) et la barre des 5 secondes.
6. Ajoute les rappels d'entraînement et de talents.
7. Peaufine l'interface (section 7).

À chaque étape, dis-moi quoi tester en jeu et ce que je dois te renvoyer si ça ne marche pas.

---

## 10. Phase 2 : guide de bout en bout (validée le 2026-11-07)

### 10.1 Faits relevés en jeu

Sonde réelle : client 1.60.1 build 70862, Interface 16001, frFR. Ces faits priment sur les suppositions des sections 1 à 9.

- **Vie et mana du joueur : SECRETS, même hors combat.** Les valeurs max sont lisibles.
- **Talents** : ils passent par `C_ClassTalents` / `C_Traits`. Les API Classic (`GetTalentInfo`, etc.) sont absentes. `GetNumUnspentTalents` et `GetNumSpecGroups` existent.
- **Globales absentes** : `GetSpellInfo`, `GetSpellCooldown`, `GetItemInfo`, `GetItemInfoInstant`, `IsQuestFlaggedCompleted`, `GetSkillLineInfo`. Utiliser les API `C_*`.
- **Événement** : `LEARNED_SPELL_IN_TAB` n'existe pas.
- **ID de sorts** : 32379 (Mot de l'ombre : Mort) et 47540 (Pénitence) n'existent pas sous ces ID.
- **Noms du client** qui diffèrent : « Gardien de peur » pour Protection contre la peur, « Sombre sacrifice » pour Sacrifice sombre.
- **Cartes** : `uiMapID` de type Classic (Tirisfal = 1420).
- **Métiers** : la skillLine est la 7e valeur de `GetProfessionInfo` (Alchimie 171, Herboristerie 182, Secourisme 129, Cuisine 185).
- **Sorts** : le spellID est lisible en combat. Pénitence est le talent 402174 (pas un sort à ID fixe).
- **Cartes** : `Enum.UIMapType` n'a pas de `City`. `C_Map.GetPlayerMapPosition(uiMapID, "player")` est lisible.
- **Objets** : le global `GetItemCount` est absent, utiliser `C_Item.GetItemCount`.
- **Journal de donjon** : il n'a aucun palier et `EJ_GetLootInfoByIndex` est absent.
- **Métiers** : `GetRecipeInfo` donne `relativeDifficulty` (0 = optimal) et `numSkillUps`.
- **Toucher de faiblesse** : n'est pas vendu par le maître des prêtres.
- **Recharges** : secrètes en combat ; `C_Spell.IsSpellUsable` reste lisible.
- **Conséquence** : le coach ne décide jamais sur la vie ou le mana. Il affiche une carte « Récupère » après chaque combat.

### 10.2 Principes

- **Zéro supposition** : on privilégie les données LUES EN JEU (API du jeu, Questie et Auctionator en direct) plutôt qu'écrites en dur.
- Tout ce qui est écrit en dur cite sa source et est contrôlé par `/coach probe`.
- **Dépendances optionnelles** : `Questie` (`LibQuestieDB`, API publique, contrat 4) et `Auctionator` (`Auctionator.API.v1`, avec un `callerID` "PretreCoach"). L'addon marche sans elles.
- **Licence** : aucune donnée de Questie n'est embarquée (GPL). On la lit seulement en direct.
- **Pas de doublon** : Questie trace déjà les quêtes et place les PNJ de ville sur la carte, Auctionator met les prix dans les infobulles. Notre addon priorise et dit où aller.
- **Pas de taux de butin inventés** : les tables de butin de Questie ne sont lisibles qu'avec `loadstring`, interdit par la Règle 0.
- **Noms des PNJ** : Questie les donne en anglais. On affiche donc un rôle + une zone localisée + des coordonnées.

### 10.3 Lots

| Lot | Contenu | Données | Repli |
| --- | --- | --- | --- |
| **L13 Sonde étendue** | Sonde de `C_Map.SetUserWaypoint` / `CanSetUserWaypointOnMap`, `C_SuperTrack`, `C_TradeSkillUI`, `C_Container`, prix marchand de `C_Item.GetItemInfo`, `C_EncounterJournal`, présence de LibQuestieDB et d'Auctionator. Plus `/coach here` : position du joueur, copiable | API du jeu, lues par la sonde | Une API absente est notée « n'existe pas » et la fonction qui en dépend est désactivée |
| **L14 Ponts** `Ext/Questie.lua` et `Ext/Auctionator.lua` | Chargement paresseux, `pcall`, conversion AreaID → uiMapID, coordonnées /100. Index local des maîtres et des commissaires-priseurs, construit une fois, hors combat, par petits morceaux | Questie (`LibQuestieDB`) et Auctionator en direct. Index gardé en cache dans les SavedVariables de la machine (rien n'est livré) | Sans Questie ou Auctionator, les ponts restent inactifs et l'addon fonctionne seul |
| **L15 « Où aller »** | Sur chaque objectif et chaque règle : texte (rôle, zone, x y) + bouton « Placer un repère » | Index local du L14, zones de `Data/Zones.lua` | Sans Questie, le texte seul |
| **L16 Métiers en direct** | À l'ouverture de la fenêtre de métier : lecture des recettes et de leur difficulté → « Fabrique X pour monter ». Coût des composants et marge via Auctionator. Route des herbes en liste statique par tranche (section 6.6) | `C_TradeSkillUI`, Auctionator, `Data/Professions.lua` | Sans Auctionator, pas de coût ni de marge. Sans `C_TradeSkillUI`, listes de la section 6.6 |
| **L17 Vente et farm** | **Vente** : scan des sacs hors combat → quoi vendre à l'hôtel des ventes (prix Auctionator contre prix marchand). **Farm** : liste sourcée des boss et objets utiles au prêtre, plus le journal de donjon du jeu | Scans du joueur uniquement (`C_Container`), `Data/` pour le farm, `C_EncounterJournal` si la sonde confirme qu'il existe | Pas de scan, pas de conseil de vente. Sans journal de donjon, la liste de `Data/` seule |
| **L18 Quêtes clés** | Courte liste écrite par ID : quêtes de classe, donjons, récompenses utiles au prêtre | Vérifiée en direct : `Quest.Exists`, prérequis, donneur et coordonnées via Questie, nom localisé via `C_QuestLog` | ID non confirmé : objectif à cocher à la main, marqué « à vérifier » |
| **L19 Diffusion** | Dépôt GitHub public. Installation sur chaque PC ou Mac par WowUp si un essai à blanc prouve qu'il gère `_forever_`. Sauvegardes locales par machine (choix de l'utilisateur) | Dépôt GitHub | Sinon git clone + lien : `install.ps1` (Windows), `install.sh` (Mac). Mise à jour = `git pull` puis `/reload`. Chemin Mac : `/Applications/World of Warcraft/_forever_/Interface/AddOns/` |

### 10.4 Règle 0 rappelée

- **Permis** : repères de carte, lecture des sacs et lecture d'autres addons. Lire et afficher.
- **Interdit** : tout achat, toute vente et toute enchère automatiques, tout lancement de sort, tout clic à la place du joueur.
- Le bouton « Placer un repère » ne pose qu'un repère de carte. Il n'achète, ne vend et ne lance rien.
