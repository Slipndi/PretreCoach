local _, ns = ...
ns.Data = ns.Data or {}

-- Objectifs du guide : { id, from, to, text, check, arg, priority }, d'après la spec 3.1, 3.3, 4 (règles 6 à 8), 6.2 et 6.6.
-- Visible dès le niveau `from`, jusqu'à la fin du palier qui contient `to`. priority 1..3 = les 3 priorités du palier.
-- check (voir Guide.lua) : prof (arg = skillLine ou liste), profRank (arg = { line, max }), wand, wandItem (arg = itemID),
-- go (facultatif) : cible de Goto.For (WAND, PRIEST, HERBALISM, FIRSTAID, Q<id>), affichée en « Où aller ».
-- talent (arg = key de TalentPlan), spells, known (arg = key de sort), quest (arg = questID), specGroups (arg = n),
-- why (facultatif, jamais sur un objectif manuel) : le « pourquoi », affiché en détail sous l'objectif (d'après la spec).
-- Les objectifs manuels ne sont plus affichés (ni carte ni Maintenant) : voir Guide.lua, xpPick et firstTodo.
-- prof (facultatif) : skillLine du métier concerné (objectif de métier du guide) ; herbZone (arg = skillLine), items (arg = { count, ids }), manual (case cochée à la main, aucune API connue).
local HERB, ALCH, AID = 182, 171, 129

-- Bandages de Data/Professions.lua (anti-venin exclu) : les seuls objets de Data/ utilisables pour un compte d'objets.
local bandages = {}
for _, b in ipairs(ns.Data.Professions[AID].bandages) do
	if b.name:find("^Bandage") then bandages[#bandages + 1] = b.itemID end
end

ns.Data.Objectives = {
	-- 1-10
	{ id = "wand_equip", from = 5, to = 9, text = "Équipe une baguette", check = "wand", priority = 1, go = "WAND" },
	{ id = "learn_prof", from = 5, to = 9, text = "Apprends Herboristerie et Alchimie", check = "prof", arg = { HERB, ALCH }, priority = 2, go = "HERBALISM" },
	{ id = "learn_firstaid", from = 5, to = 9, text = "Apprends Secourisme", check = "prof", arg = AID, priority = 3, go = "FIRSTAID" },
	{ id = "spells", from = 1, to = 60, text = "Apprends tes nouveaux sorts", check = "spells", go = "PRIEST" },
	{ id = "herb_zone", from = 5, to = 60, text = "Herboristerie au niveau des herbes de la zone", check = "herbZone", arg = HERB, prof = HERB },
	-- 10-20
	{ id = "wandspec", from = 10, to = 11, text = "Spécialisation Baguette 2/2", check = "talent", arg = "WANDSPEC", priority = 1 },
	{ id = "spirittap", from = 12, to = 16, text = "Connexion spirituelle 5/5", check = "talent", arg = "SPIRITTAP", priority = 2 },
	{ id = "rank_comp_herb", from = 10, to = 19, text = "Rang Compagnon en Herboristerie", check = "profRank", arg = { line = HERB, max = 150 }, priority = 3, prof = HERB },
	{ id = "rank_comp_alch", from = 10, to = 19, text = "Rang Compagnon en Alchimie", check = "profRank", arg = { line = ALCH, max = 150 }, priority = 3, prof = ALCH },
	{ id = "legacy_toa", from = 10, to = 29, text = "Premier point Legacy : Thrill of Adventure", check = "manual" },
	{ id = "bandages", from = 10, to = 29, text = "Aie au moins 10 bandages sur toi", check = "items", arg = { count = 10, ids = bandages }, prof = AID },
	{ id = "wand_sup", from = 13, to = 19, text = "Baguette magique supérieure", check = "wandItem", arg = 11288, go = "WAND" },
	{ id = "rfc_staff", from = 13, to = 18, text = "Gouffre de Ragefeu : bâton de quête (+18 dégâts des sorts)", check = "manual" },
	{ id = "lord_staff", from = 15, to = 24, text = "Ruines de Lordaeron et Cavernes des lamentations : bâton de quête (+5 dégâts des sorts)", check = "manual" },
	{ id = "impswp", from = 17, to = 18, text = "Mot de l'ombre : Douleur amélioré 2/2", check = "talent", arg = "IMPSWP" },
	{ id = "mentalstr", from = 19, to = 39, text = "Force mentale 5/5", check = "talent", arg = "MENTALSTR" },
	{ id = "mentalagi", from = 19, to = 39, text = "Agilité mentale 3/3", check = "talent", arg = "MENTALAGI" },
	{ id = "martyr", from = 19, to = 39, text = "Martyre 2/2", check = "talent", arg = "MARTYR" },
	{ id = "meditation", from = 19, to = 39, text = "Méditation 3/3", check = "talent", arg = "MEDITATION" },
	-- 20-30
	{ id = "rank_expert_herb", from = 20, to = 29, text = "Rang Expert en Herboristerie", check = "profRank", arg = { line = HERB, max = 225 }, priority = 1, prof = HERB },
	{ id = "rank_expert_alch", from = 20, to = 29, text = "Rang Expert en Alchimie", check = "profRank", arg = { line = ALCH, max = 225 }, priority = 1, prof = ALCH },
	{ id = "fearward", from = 20, to = 29, text = "Apprends Protection contre la peur", check = "known", arg = "FEARWARD", priority = 2, go = "PRIEST" },
	{ id = "mana_potions", from = 20, to = 39, text = "Potions de mana en stock avant les donjons", check = "manual", prof = ALCH },
	{ id = "bfd_quest", from = 24, to = 32, text = "Quête Blackfathom Villainy (Gravestone Scepter)", check = "quest", arg = ns.Data.GravestoneQuest, priority = 3, go = "Q" .. ns.Data.GravestoneQuest },
	-- 30-40
	{ id = "divspirit", from = 30, to = 39, text = "Apprends Esprit divin", check = "known", arg = "DIVSPIRIT", priority = 2, go = "PRIEST" },
	{ id = "swd", from = 32, to = 39, text = "Apprends Mot de l'ombre : Mort", check = "known", arg = "SWD", go = "PRIEST" },
	{ id = "rank_artisan_herb", from = 35, to = 39, text = "Rang Artisan en Herboristerie", check = "profRank", arg = { line = HERB, max = 300 }, priority = 1, prof = HERB },
	{ id = "rank_artisan_alch", from = 35, to = 39, text = "Rang Artisan en Alchimie", check = "profRank", arg = { line = ALCH, max = 300 }, priority = 1, prof = ALCH },
	{ id = "triage", from = 35, to = 45, text = "Secourisme Artisan : quête Triage", check = "manual", prof = AID },
	-- 40-60
	{ id = "shadowform", from = 40, to = 60, text = "Forme d'Ombre", check = "known", arg = "SHADOWFORM", priority = 1 },
	{ id = "dualspec", from = 40, to = 60, text = "Double spécialisation", check = "specGroups", arg = 2, priority = 2, why = "une spécialisation Ombre en solo, une spécialisation soin pour les donjons" },
	{ id = "wandspec2", from = 41, to = 60, text = "Spécialisation Baguette 2/2 (à reprendre après le respec)", check = "talent", arg = "WANDSPEC", priority = 3 },
}
