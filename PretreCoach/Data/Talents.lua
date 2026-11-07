local _, ns = ...
ns.Data = ns.Data or {}

-- tab : 1 Discipline, 2 Sacré, 3 Ombre ; row = palier, col 1-4.
-- Positions : guildorder.com (page Forever), rangée/colonne déduites de la page, pas lues en jeu.
ns.Data.TalentPlan = {
	{ from = 10, to = 11, tab = 1, row = 1, col = 2, rank = 2, name = "Spécialisation Baguette", verify = true }, -- à vérifier : position
	{ from = 12, to = 16, tab = 3, row = 1, col = 3, rank = 5, name = "Connexion spirituelle", verify = true },
	{ from = 17, to = 18, tab = 3, row = 2, col = 2, rank = 2, name = "Mot de l'ombre : Douleur amélioré", verify = true },
	{ from = 19, to = 39, tab = 1, row = 2, col = 3, rank = 5, name = "Force mentale", verify = true },
	{ from = 19, to = 39, tab = 1, row = 3, col = 1, rank = 3, name = "Agilité mentale", verify = true }, -- à vérifier : la spec écrit « Force mentale (Mental Agility) », ambigu
	{ from = 19, to = 39, tab = 1, row = 2, col = 4, rank = 2, name = "Martyre", verify = true },
	{ from = 19, to = 39, tab = 1, row = 3, col = 4, rank = 3, name = "Méditation", verify = true },
	{ from = 40, to = 40, name = "Respec Ombre : 31 points en Ombre pour la Forme d'Ombre", respec = true, verify = true },
	{ from = 40, to = 40, tab = 3, row = 7, col = 1, rank = 1, name = "Forme d'Ombre", verify = true },
	{ from = 41, to = 60, tab = 1, row = 1, col = 2, rank = 2, name = "Spécialisation Baguette", verify = true }, -- à vérifier : spec « à nouveau, puis talents de mana en Discipline »
}
