local _, ns = ...
ns.Data = ns.Data or {}

-- Clés = skillLine. Tout est à vérifier sur Forever (valeurs Vanilla de la spec 6.6) ; itemID nil = non prouvé.
local ranks = {
	{ name = "Apprenti", max = 75, minSkill = 1, minLevel = 1 },
	{ name = "Compagnon", max = 150, minSkill = 50, minLevel = 10 },
	{ name = "Expert", max = 225, minSkill = 125, minLevel = 20 },
	{ name = "Artisan", max = 300, minSkill = 200, minLevel = 35 },
}

ns.Data.Professions = {
	[182] = { -- à vérifier : skillLine, noms français des herbes
		name = "Herboristerie",
		ranks = ranks,
		herbs = {
			{ from = 1, to = 70, zones = { 1420 }, names = { "Pacifique", "Feuillargent", "Terrestrine" } },
			{ from = 70, to = 115, zones = { 1421, 1413 }, names = { "Mage royal", "Églantine", "Doulourante" } },
			{ from = 115, to = 170, zones = { 1424, 1442, 1440 }, names = { "Aciérite sauvage", "Tombeline", "Sang-royal", "Vietérule", "Pâlerette" } },
			{ from = 170, to = 230, zones = { 1417, 1434, 1443 }, names = { "Dorépine", "Moustache de Khadgar", "Fleur de feu", "Lotus pourpre", "Larmes d'Arthas" } },
			{ from = 230, to = 300, zones = { 1446, 1444, 1425, 1449, 1448, 1452 }, names = { "Soleillette", "Gromsang", "Sansam doré", "Feuillerêve", "Sauge-argent des montagnes", "Fleur de peste", "Calot de glace" } },
		},
		verify = true,
	},
	[171] = { -- à vérifier : skillLine, compétences requises
		name = "Alchimie",
		ranks = ranks,
		recipes = {
			{ skill = 1, name = "Potion de soins mineure", verify = true },
			{ skill = 25, name = "Potion de mana mineure", verify = true },
			{ skill = 90, name = "Élixir de sagesse", verify = true },
			{ skill = 120, name = "Potion de mana inférieure", verify = true },
			{ skill = 160, name = "Potion de mana", verify = true },
			{ skill = 215, name = "Potion de mana supérieure", verify = true },
			{ skill = 250, name = "Élixir de puissance de l'ombre", verify = true }, -- à vérifier : recette à trouver
			{ skill = 260, name = "Potion de mana excellente", verify = true },
			{ skill = 295, name = "Potion de mana majeure", verify = true }, -- à vérifier : recette à trouver
		},
		verify = true,
	},
	[129] = { -- à vérifier : skillLine, points Legacy (inconnus), Expert via manuel (125), Artisan via quête Triage (225)
		name = "Secourisme",
		ranks = ranks,
		bandages = {
			{ skill = 1, name = "Bandage en lin", itemID = 1251 }, -- itemID lus dans QuestieDB_Forever.toc (X-Item-<id>-S, noms anglais concordants)
			{ skill = 40, name = "Bandage en lin épais", itemID = 2581 },
			{ skill = 80, name = "Bandage en laine", itemID = 3530 },
			{ skill = 115, name = "Bandage en laine épais", itemID = 3531 },
			{ skill = 150, name = "Bandage en soie", itemID = 6450 },
			{ skill = 180, name = "Bandage en soie épais", itemID = 6451 },
			{ skill = 210, name = "Bandage en tisse-mage", itemID = 8544 },
			{ skill = 240, name = "Bandage en tisse-mage épais", itemID = 8545 },
			{ skill = 260, name = "Bandage en étoffe runique", itemID = 14529 },
			{ skill = 290, name = "Bandage en étoffe runique épais", itemID = 14530 },
			{ skill = 80, name = "Anti-venin", itemID = 6452 },
		},
		verify = true,
	},
}
