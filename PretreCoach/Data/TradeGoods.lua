local _, ns = ...
ns.Data = ns.Data or {}

-- Marchandises qui se vendent a tout niveau (itemIDs Classic). Noms lus en jeu ; un ID que QuestieDB ne resout pas est ignore.
-- Tissus, elements, puis quelques viandes de Cuisine.
ns.Data.TradeGoods = {
	2589, 2592, 4306, 4338, 14047, -- Lin, Laine, Soie, Tisse-mage, Etoffe runique
	7067, 7068, 7069, 7070, -- Terre, Feu, Air, Eau elementaires
	769, 3173, 2672, 2674, 12037, -- viandes : sanglier, ours, loup, crawler, mysterieuse
}
