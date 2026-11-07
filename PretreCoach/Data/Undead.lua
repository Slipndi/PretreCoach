local _, ns = ...
ns.Data = ns.Data or {}

-- Atouts du mort-vivant (onglet de référence) : { key, spellKey?, level, text }.
-- spellKey = clé de ns.Data.Spells quand le sort y figure.
ns.Data.Undead = {
	{ key = "CANNIBAL", spellKey = "CANNIBAL", level = 1, text = "Cannibalisme : mange un cadavre proche entre deux combats pour regagner de la vie sans boire ni manger." },
	{ key = "WOTF", level = 1, text = "Volonté des Réprouvés : te libère de la peur, du charme et du sommeil ; garde-la pour ces moments-là." },
	{ key = "WATER", level = 1, text = "Respiration aquatique : tu tiens bien plus longtemps sous l'eau, traverse les lacs sans crainte." },
	{ key = "SHADOWRES", level = 1, text = "Résistance à l'ombre : passive, un petit plus contre les lanceurs de sorts d'ombre." },
	{ key = "TOUCHWEAK", spellKey = "TOUCHWEAK", level = 10, text = "Toucher de faiblesse : lance-le avant le combat, il punit les monstres qui te frappent au corps à corps." },
	{ key = "DARKSAC", spellKey = "DARKSAC", level = 20, text = "Sacrifice sombre : ne coûte pas de mana mais de la vie ; à utiliser quand ta vie le permet." },
}
