local _, ns = ...
ns.Data = ns.Data or {}

-- { level, itemID, name, source, verify }
ns.Data.Wands = {
	{ level = 5, itemID = 11287, name = "Baguette magique inférieure", source = "Hôtel des ventes ou récompense de quête (pas d'Enchantement)", verify = true }, -- à vérifier : ID Vanilla de mémoire, non prouvé sur Forever
	{ level = 13, itemID = 11288, name = "Baguette magique supérieure", source = "Hôtel des ventes, environ 50 % de dégâts en plus", verify = true }, -- à vérifier : ID Vanilla de mémoire, non prouvé sur Forever
	{ level = 18, itemID = 7001, name = "Gravestone Scepter", source = "Quête des Profondeurs de Brassenoire", verify = true }, -- à vérifier : 7001 vient de warcraft.wiki.gg (Vanilla) ; niveau 18-25 selon la spec
}

-- 6561 = « Blackfathom Villainy », version Horde (Questie, questTagInfoCorrections.lua:438) ; la récompense
-- Gravestone Scepter de cette quête vient de warcraft.wiki.gg. À vérifier en jeu sur Forever.
ns.Data.GravestoneQuest = 6561
ns.Data.GravestoneQuestVerify = true

ns.Data.StatAdvice = "Puissance des sorts au début, puis Esprit dès 40 à 50 de puissance des sorts, puis Intelligence et Endurance."
