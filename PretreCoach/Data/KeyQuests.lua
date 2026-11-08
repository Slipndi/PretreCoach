local _, ns = ...
ns.Data = ns.Data or {}

-- Quêtes clés du prêtre mort-vivant Horde : { id, from, to, why, after?, source }. Toutes lues dans QuestieDB Forever
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
	{ id = 1048, from = 33, to = 38, why = "Monastère écarlate : beaucoup d'XP en donjon (5150), donneur Varimathras à Fossoyeuse",
		source = "QuestieDB_Forever.toc:6156 (races Horde) ; xpDB-classic.lua:968" },
	{ id = 1445, from = 38, to = 45, why = "Temple englouti : beaucoup d'XP en donjon (5900)", after = 1444,
		source = "QuestieDB_Forever.toc:7710 (preQuestSingle 1444, niveau requis 38) ; xpDB-classic.lua:1222" },
	{ id = 3528, from = 40, to = 45, why = "Temple englouti, Hakkar : énormément d'XP (7900)", after = 4787,
		source = "QuestieDB_Forever.toc:11489 (preQuestSingle 4787, niveau requis 40, donneur Yeh'kinya) ; xpDB-classic.lua:1834" },
	{ id = 7029, from = 41, to = 45, why = "Maraudon : beaucoup d'XP en donjon (5250)",
		source = "QuestieDB_Forever.toc:17078 (races Horde, niveau requis 41, donneur dans l'instance) ; xpDB-classic.lua:2678" },
	{ id = 7064, from = 45, to = 49, why = "Maraudon : beaucoup d'XP en donjon (6100)",
		source = "QuestieDB_Forever.toc:17132 (races Horde, niveau requis 45, donneur dans l'instance) ; xpDB-classic.lua:2688" },
	{ id = 4120, from = 47, to = 49, why = "Féralas : beaucoup d'XP (5100)",
		source = "QuestieDB_Forever.toc:12314 (races Horde, niveau requis 47) ; xpDB-classic.lua:1959" },
	{ id = 8257, from = 50, to = 52, why = "classe prêtre : fin de la chaîne d'Ogtinc (6350 XP)", after = 8256,
		source = "QuestieDB_Forever.toc:19749 (classe 16 = prêtre, preQuestSingle 8256, niveau requis 50) ; xpDB-classic.lua:3016" },
	{ id = 5511, from = 55, to = 59, why = "Scholomance : la clé, beaucoup d'XP (9950)", after = 5804,
		source = "QuestieDB_Forever.toc:14892 (races Horde, preQuestSingle 5804, niveau requis 55) ; xpDB-classic.lua:2353" },
	{ id = 6148, from = 56, to = 59, why = "Plaguelands : l'oracle écarlate Demetria, beaucoup d'XP (8300)", after = 6147,
		source = "QuestieDB_Forever.toc:16120 (races Horde, preQuestSingle 6147, niveau requis 56) ; xpDB-classic.lua:2542" },
	{ id = 4768, from = 57, to = 59, why = "Profondeurs de Rochenoire (Pic Rochenoire) : beaucoup d'XP (8300)",
		source = "QuestieDB_Forever.toc:13339 (races Horde, niveau requis 57) ; xpDB-classic.lua:2118" },
	{ id = 7622, from = 60, to = 60, why = "classe prêtre niveau 60 : 9950 XP",
		source = "QuestieDB_Forever.toc:17738 (classe 16 = prêtre, niveau requis 60) ; xpDB-classic.lua:2777" },
}
