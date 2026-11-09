local _, ns = ...
ns.Data = ns.Data or {}

-- Plan de montee 1-300 par metier, etapes par tranche { from, to }. TOUT est a verifier (verify = true).
-- Sources (guides WoW Forever beta, lus en anglais ; noms francais retraduits de memoire du client Vanilla FR) :
--   https://www.wow-professions.com/forever/alchemy-leveling-guide
--   https://www.wow-professions.com/forever/first-aid-leveling-guide
--   https://www.wow-professions.com/forever/herbalism-leveling-guide
-- Cote Horde (pretre mort-vivant). Aucun prix de recette ni de fiole donne par les sources : price = nil (jamais invente).
-- rid = recipeID du sort de fabrication (compare avant le nom) : 2331, 2334, 3276 lus en jeu (2026-11-09), les autres = IDs Classic a verifier.
-- comps = par fabrication { name, id (itemID), n, vendor = vendu par un marchand simple, price = prix unitaire en cuivre ou nil }.
-- crafts = nombre approximatif de fabrications sur toute la tranche. zones = uiMapID. masters[nomDeRang] = ou aller.
local function s(from, to, t) t.from, t.to, t.verify = from, to, true return t end
local VIDE = { name = "Fiole vide", id = 3371, n = 1, vendor = true }
local PLOMB = { name = "Fiole de plomb", id = 3372, n = 1, vendor = true }
local CRISTAL = { name = "Fiole de cristal", id = 8925, n = 1, vendor = true }
local SPICE = { name = "Épices apaisantes", id = 3713, n = 1, vendor = true }
local function herb(name, id, n) return { name = name, id = id, n = n or 1 } end
local function cloth(name, id, n) return { name = name, id = id, n = n } end

ns.Data.ProfPlan = {
	[171] = { -- Alchimie
		masters = {
			Compagnon = "Docteur Marsh (Fossoyeuse) ou Yelmak (Orgrimmar)",
			Expert = "Docteur Herbert Halsey (Fossoyeuse), 50 pa",
			Artisan = "Rogvar (Stonard, Marais des Chagrins)",
		},
		steps = {
			s(1, 10, { recipe = "Élixir arcanique mineur", crafts = 9, comps = { herb("Pacifique", 2447), VIDE } }),
			s(10, 55, { recipe = "Élixir de défense mineure", rid = 7183, crafts = 45, comps = { herb("Feuillargent", 765), herb("Pacifique", 2447), VIDE } }),
			s(55, 65, { recipe = "Potion de mana mineure", rid = 2331, crafts = 10, comps = { herb("Mage royal", 785), herb("Pacifique", 2447), VIDE } }),
			s(65, 90, { recipe = "Elixir de Robustesse mineure", rid = 2334, crafts = 27, comps = { herb("Terrestrine", 2449, 2), herb("Pacifique", 2447), VIDE } }),
			s(90, 120, { recipe = "Élixir de sagesse", rid = 3171, crafts = 30, comps = { herb("Mage royal", 785), herb("Églantine", 2450, 2), VIDE } }),
			s(120, 165, { recipe = "Potion de mana inférieure", rid = 3173, crafts = 52, comps = { herb("Mage royal", 785), herb("Strangleronce", 3820), VIDE } }),
			s(165, 195, { recipe = "Potion de mana", rid = 3452, crafts = 36, comps = { herb("Strangleronce", 3820), herb("Sang-royal", 3356), PLOMB } }),
			s(195, 230, { recipe = "Potion de protection contre la nature", rid = 7259, crafts = 48, comps = { herb("Vietérule", 3357), herb("Strangleronce", 3820), PLOMB },
				buy = { recipe = "Potion de protection contre la nature", where = "Bronk (Féralas), Glyx Brewright (Vallée de Strangleronce) ou Alchimiste Pestlezugg (Tanaris)" } }),
			s(230, 265, { recipe = "Breuvage de détection des morts-vivants", rid = 11460, crafts = 45, comps = { herb("Larmes d'Arthas", 8836), CRISTAL } }),
			s(265, 290, { recipe = "Potion de mana supérieure", rid = 11448, crafts = 30, comps = { herb("Soleillette", 8838, 2), herb("Aveuglette", 8839, 2), CRISTAL },
				buy = { recipe = "Potion de mana supérieure", where = "Algernon (Fossoyeuse)" } }),
			s(290, 300, { crafts = 20, note = "Choisis une recette orange ou jaune dans ta fenêtre d'alchimie (recettes vendues ou en vente à l'hôtel des ventes)" }),
		},
	},
	[182] = { -- Herboristerie
		masters = {
			Compagnon = "Martha Alliestar (Fossoyeuse)",
			Expert = "Martha Alliestar (Fossoyeuse)",
			Artisan = "Martha Alliestar (Fossoyeuse) : prends-le avant de partir pour Tanaris",
		},
		steps = {
			s(1, 70, { herbs = { "Pacifique", "Feuillargent", "Terrestrine" }, zones = { 1420, 1411, 1412 } }),
			s(70, 115, { herbs = { "Mage royal", "Églantine", "Strangleronce" }, zones = { 1421, 1432, 1439 } }),
			s(115, 150, { herbs = { "Doulourante", "Aciérite sauvage", "Strangleronce", "Sang-royal" }, zones = { 1424, 1442 } }),
			s(150, 170, { herbs = { "Vietérule", "Sang-royal", "Aciérite sauvage" }, zones = { 1424, 1442 } }),
			s(170, 205, { herbs = { "Sang-royal", "Vietérule", "Pâlerette", "Dorépine", "Moustache de Khadgar" }, zones = { 1434, 1417 } }),
			s(205, 230, { herbs = { "Lotus pourpre", "Fleur de feu" }, zones = { 1446, 1427 } }),
			s(230, 270, { herbs = { "Soleillette", "Lotus pourpre", "Champignon fantôme", "Sansam doré" }, zones = { 1425 } }),
			s(270, 300, { herbs = { "Soleillette", "Gromsang", "Sansam doré", "Feuillerêve", "Sauge-argent des montagnes", "Fleur de peste" }, zones = { 1448 } }),
		},
	},
	[129] = { -- Secourisme
		masters = {
			Compagnon = "Mary Edras (Fossoyeuse)",
			Expert = "achète le manuel « Secourisme expert » chez Balai Lok'Wein (Marécage d'Âprefange)",
			Artisan = "quête Triage : Docteur Gregory Victor (Hammerfall, Hautes-terres d'Arathi)",
		},
		steps = {
			s(1, 40, { recipe = "Bandage en lin", rid = 3275, crafts = 50, comps = { cloth("Toile de lin", 2589, 1) } }),
			s(40, 80, { recipe = "Bandage épais en lin", rid = 3276, crafts = 52, comps = { cloth("Toile de lin", 2589, 2) } }),
			s(80, 115, { recipe = "Bandage en laine", rid = 3277, crafts = 50, comps = { cloth("Étoffe de laine", 2592, 1) } }),
			s(115, 150, { recipe = "Bandage en laine épais", rid = 3278, crafts = 50, comps = { cloth("Étoffe de laine", 2592, 2) } }),
			s(150, 180, { recipe = "Bandage en soie", rid = 7928, crafts = 42, comps = { cloth("Étoffe de soie", 4306, 1) },
				buy = { recipe = "Secourisme expert", item = "Manuel : Secourisme expert", where = "Balai Lok'Wein (Marécage d'Âprefange)" } }),
			s(180, 210, { recipe = "Bandage en soie épais", rid = 7929, crafts = 46, comps = { cloth("Étoffe de soie", 4306, 2) },
				buy = { recipe = "Bandage en soie épais", item = "Manuel : Bandage en soie épais", where = "Balai Lok'Wein (Marécage d'Âprefange)" } }),
			s(210, 225, { recipe = "Bandage en tisse-mage", rid = 10840, crafts = 17, comps = { cloth("Tisse-mage", 4338, 1) },
				buy = { recipe = "Bandage en tisse-mage", item = "Manuel : Bandage en tisse-mage", where = "Balai Lok'Wein (Marécage d'Âprefange)" } }),
			s(225, 240, { recipe = "Potion de soins supérieure", rid = 7181, crafts = 16, comps = { herb("Soleillette", 8838), SPICE, CRISTAL },
				extra = "Quête Triage (secourisme 225, niveau 35) : Docteur Gregory Victor, Hammerfall (Hautes-terres d'Arathi), soigne 15 blessés en commençant par les plus graves" }),
			s(240, 260, { recipe = "Bandage en tisse-mage épais", rid = 10841, crafts = 30, comps = { cloth("Tisse-mage", 4338, 2) } }),
			s(260, 275, { recipe = "Bandage en étoffe runique", rid = 18629, crafts = 20, comps = { cloth("Étoffe runique", 14047, 1) } }),
			s(275, 300, { recipe = "Potion de soins majeure", rid = 17556, crafts = 30, comps = { herb("Sansam doré", 13464), { name = "Épices apaisantes", id = 3713, n = 3, vendor = true }, CRISTAL } }),
		},
	},
}
