local _, ns = ...
ns.Data = ns.Data or {}

-- { key, name, min, max, zoneMapID, verify } ; plages : Leatrix_Maps_Icons.lua d'abord, sinon spec 6.4.
-- zoneMapID : carte où se trouve l'entrée (Leatrix), nil si inconnue.
ns.Data.Dungeons = {
	{ key = "rfc", name = "Gouffre de Ragefeu", min = 13, max = 18, zoneMapID = 1454, verify = true }, -- à vérifier : entrée à Orgrimmar (mapID 1454 de Leatrix, instance non lue)
	{ key = "ruins", name = "Ruines de Lordaeron", min = 15, max = 20, zoneMapID = 1420 },
	{ key = "wc", name = "Cavernes des lamentations", min = 17, max = 24, zoneMapID = 1413 },
	{ key = "sfk", name = "Donjon d'Ombrecroc", min = 22, max = 30, zoneMapID = 1421 },
	{ key = "bfd", name = "Profondeurs de Brassenoire", min = 24, max = 32, zoneMapID = 1440 },
	{ key = "dalaran", name = "Cité de Dalaran", min = 28, max = 33, zoneMapID = 1416 },
	{ key = "rfk", name = "Kraal de Tranchebauge", min = 29, max = 38, zoneMapID = 1413 },
	{ key = "sm", name = "Monastère écarlate", min = 34, max = 45, zoneMapID = 1420 },
	{ key = "drowned", name = "Drowned City", min = 35, max = 40, zoneMapID = 1434, verify = true }, -- à vérifier : nom français
	{ key = "rfd", name = "Souilles de Tranchebauge", min = 37, max = 46, zoneMapID = 1413 },
	{ key = "kroldok", name = "Krol'Dok Stronghold", min = 40, max = 45, zoneMapID = 2548, verify = true }, -- à vérifier : nom français
	{ key = "uldaman", name = "Uldaman", min = 41, max = 51, zoneMapID = 1418 },
	{ key = "zf", name = "Zul'Farrak", min = 44, max = 54, zoneMapID = 1446 },
	{ key = "mara", name = "Maraudon", min = 46, max = 55, zoneMapID = 1443 },
	{ key = "alcaz", name = "Alcaz Prison", min = 48, max = 53, zoneMapID = 1445, verify = true }, -- à vérifier : nom français, mapID Marécage d'Âprefange déduit du commentaire Leatrix
	{ key = "atal", name = "Temple englouti", min = 50, max = 60, zoneMapID = 1435 },
	{ key = "blackmaw", name = "Blackmaw Hold", min = 55, max = 60, zoneMapID = 1447, verify = true }, -- à vérifier : nom français
	{ key = "brd", name = "Profondeurs de Rochenoire", min = 50, max = 60, verify = true }, -- à vérifier : plage = spec, absente de Leatrix
	{ key = "dm", name = "Hache-Tripes", min = 56, max = 60, zoneMapID = 1444 },
	{ key = "brs", name = "Pic Rochenoire", min = 50, max = 60, verify = true }, -- à vérifier : plage = spec, absente de Leatrix
	{ key = "shaper", name = "Shaper's Terrace", min = 58, max = 60, zoneMapID = 1449, verify = true }, -- à vérifier : nom français
	{ key = "strat", name = "Stratholme", min = 58, max = 60, zoneMapID = 1423 },
	{ key = "scholo", name = "Scholomance", min = 58, max = 60, zoneMapID = 1422 },
}

ns.Data.DungeonTips = {
	"Bois de l'eau pour garder du mana.",
	"Mot de pouvoir : Bouclier sur le tank avant le pull.",
	"Rénovation sur ceux qui prennent des dégâts en continu.",
	"Mot de l'ombre : Douleur entre deux soins.",
	"Robustesse sur tout le groupe.",
}
