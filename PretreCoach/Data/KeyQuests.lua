local _, ns = ...
ns.Data = ns.Data or {}

-- Quêtes clés du prêtre mort-vivant Horde : { id, from, to, why, after?, source }. Peu d'entrées, toutes lues dans QuestieDB Forever
-- (nom, race, niveau requis, prérequis ; données CBOR de QuestieDB_Forever.toc, décodées à la main). Visible dès `from`, jusqu'à la
-- fin du palier qui contient `to` (comme Data/Objectives.lua). `after` = quête à finir avant (preQuestSingle / nextQuestInChain).
-- La quête 6561 (sceptre de Brassenoire) reste l'objectif bfd_quest de Data/Objectives.lua.
-- 5658 retirée (2026-11-08) : présente dans QuestieDB mais absente de Forever, Toucher de faiblesse y est appris sans elle.
-- source : QuestieDB_Forever.toc:<ligne> = rangée X-Quest-<id>-S ; xpDB-classic.lua:<ligne> = XP (src : QuestieDB/support/Forever/QuestXP).
ns.Data.KeyQuests = {
	{ id = 5651, from = 5, to = 9, why = "classe prêtre mort-vivant, première étape des vêtements de prêtre",
		source = "QuestieDB_Forever.toc:15227 (races 16 = mort-vivant, classe 16 = prêtre) ; xpDB-classic.lua:2406" },
	{ id = 5650, from = 5, to = 9, why = "classe prêtre mort-vivant, suite : les vêtements de prêtre", after = 5651,
		source = "QuestieDB_Forever.toc:15223 (races 16, classe 16, nextQuestInChain de 5651) ; xpDB-classic.lua:2405" },
	{ id = 451, from = 10, to = 14, why = "Bois des Pins-Argentés : beaucoup d'XP pour le niveau (2050)", after = 450,
		source = "QuestieDB_Forever.toc:2680 (preQuestSingle 450, niveau requis 9) ; xpDB-classic.lua:424" },
	{ id = 906, from = 17, to = 21, why = "Tarides : beaucoup d'XP pour le niveau (3050)", after = 879,
		source = "QuestieDB_Forever.toc:5329 (preQuestSingle 879, niveau requis 17) ; xpDB-classic.lua:841" },
	{ id = 6921, from = 24, to = 32, why = "Profondeurs de Brassenoire : beaucoup d'XP en donjon (2750)",
		source = "QuestieDB_Forever.toc:16944 (niveau requis 21, donneur dans l'instance) ; xpDB-classic.lua:2662" },
}
