local _, ns = ...
ns.Data = ns.Data or {}

-- tab : 1 Discipline, 2 Sacré, 3 Ombre ; row = palier, col 1-4.
-- key : identifiant stable, utilisé par les objectifs du guide (check "talent").
-- spellIDs : tous les rangs du talent en Vanilla, comparés à la définition des nœuds C_Traits (à vérifier sur Forever,
-- /coach probe, section « Arbre de talents ») ; tab/row/col : repli pour un client Classic (GetTalentInfo).
-- Positions : guildorder.com (page Forever), rangée/colonne déduites de la page, pas lues en jeu.
ns.Data.TalentPlan = {
	{ from = 10, to = 11, tab = 1, row = 1, col = 2, rank = 2, key = "WANDSPEC", spellIDs = { 14524, 14525, 14526, 14527, 14528 }, name = "Spécialisation Baguette", verify = true }, -- à vérifier : position
	{ from = 12, to = 16, tab = 3, row = 1, col = 3, rank = 5, key = "SPIRITTAP", spellIDs = { 15270, 15335, 15336, 15337, 15338 }, name = "Connexion spirituelle", verify = true },
	{ from = 17, to = 18, tab = 3, row = 2, col = 2, rank = 2, key = "IMPSWP", spellIDs = { 15275, 15317 }, name = "Mot de l'ombre : Douleur amélioré", verify = true },
	{ from = 19, to = 39, tab = 1, row = 2, col = 3, rank = 5, key = "MENTALSTR", spellIDs = { 18551, 18552, 18553, 18554, 18555 }, name = "Force mentale", verify = true },
	{ from = 19, to = 39, tab = 1, row = 3, col = 1, rank = 3, key = "MENTALAGI", spellIDs = { 14520, 14780, 14781, 14782, 14783 }, name = "Agilité mentale", verify = true }, -- à vérifier : la spec écrit « Force mentale (Mental Agility) », ambigu
	{ from = 19, to = 39, tab = 1, row = 2, col = 4, rank = 2, key = "MARTYR", spellIDs = { 14531, 14774 }, name = "Martyre", verify = true },
	{ from = 19, to = 39, tab = 1, row = 3, col = 4, rank = 3, key = "MEDITATION", spellIDs = { 14521, 14776, 14777 }, name = "Méditation", verify = true },
	{ from = 40, to = 40, name = "Respec Ombre : 31 points en Ombre pour la Forme d'Ombre", respec = true, verify = true },
	{ from = 40, to = 40, tab = 3, row = 7, col = 1, rank = 1, key = "SHADOWFORM", spellIDs = { 15473 }, name = "Forme d'Ombre", verify = true },
	{ from = 41, to = 60, tab = 1, row = 1, col = 2, rank = 2, key = "WANDSPEC", spellIDs = { 14524, 14525, 14526, 14527, 14528 }, name = "Spécialisation Baguette", verify = true }, -- à vérifier : spec « à nouveau, puis talents de mana en Discipline »
}
