local _, ns = ...
ns.Data = ns.Data or {}

-- Plages : Leatrix_Maps.lua (table mapTable, ~l.3858). Les noms sont un repli : l'addon lit le nom localisé.
ns.Data.Zones = {
	[1420] = { 1, 10, "Clairières de Tirisfal" },
	[1421] = { 10, 20, "Forêt des Pins-Argentés" },
	[1413] = { 10, 25, "Les Tarides" },
	[1424] = { 20, 30, "Contreforts de Hautebrande" },
	[1442] = { 15, 27, "Les Serres-Rocheuses" },
	[1440] = { 18, 30, "Ashenvale" },
	[1441] = { 25, 35, "Mille Pointes" },
	[1443] = { 30, 40, "Désolace" },
	[1417] = { 30, 40, "Hautes-terres d'Arathi" },
	[1434] = { 30, 45, "Vallée de Strangleronce" },
	[2548] = { 35, 45, "Riverglades" },
	[1446] = { 40, 50, "Tanaris" },
	[1444] = { 40, 50, "Féralas" },
	[1425] = { 40, 50, "Les Hinterlands" },
	[1418] = { 35, 45, "Terres ingrates" },
	[1449] = { 48, 55, "Cratère d'Un'Goro" },
	[1448] = { 48, 55, "Gangrebois" },
	[1428] = { 50, 58, "Steppes ardentes" },
	[1452] = { 55, 60, "Berceau-de-l'Hiver" },
	[1423] = { 53, 60, "Maleterres de l'Est" },
}

-- Parcours Horde conseillé, ordonné : { uiMapID, min, max } (plages Leatrix).
ns.Data.ZonePath = {
	{ 1420, 1, 10 },
	{ 1421, 10, 20 },
	{ 1424, 20, 30 },
	{ 1417, 30, 40 },
	{ 2548, 35, 45 },
	{ 1446, 40, 50 },
	{ 1449, 48, 55 },
	{ 1423, 53, 60 },
	{ 1452, 55, 60 },
}
