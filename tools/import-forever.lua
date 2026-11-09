-- Import des donnees Forever depuis What's Training (MIT, (c) 2019 Sveng) vers PretreCoach/Data/Forever.lua.
-- Hors jeu, LuaJIT : luajit tools/import-forever.lua "<dossier AddOns>/WhatsTraining" > PretreCoach/Data/Forever.lua
-- A relancer apres une mise a jour de What's Training (puis powershell -File test.ps1 : le test de coherence du plan).
local root = assert(arg[1], "usage : luajit tools/import-forever.lua <dossier WhatsTraining>")

local function load(rel, ns)
  local f = assert(loadfile(root .. "/" .. rel))
  f("WhatsTraining", ns)
end

-- Sorts de prete : spellsByLevel = { [niveau] = { { id, cost, race, requiredIds } } }
local class = {}
load("Classes/Camelot/Priest.lua", { forClass = function() return class end })
local spells = {}
for lvl, list in pairs(class.spellsByLevel) do
  for _, e in ipairs(list) do if type(e.id) == "number" then spells[e.id] = lvl end end
end

-- Recettes des metiers du personnage
local LINES = { [171] = "Alchemy", [129] = "FirstAid" }
local recipes = {}
for line, file in pairs(LINES) do
  local ns = { L = setmetatable({}, { __index = function(_, k) return k end }) } -- textes localises : sans objet ici
  load("Crafting/Recipes/Camelot/" .. file .. ".lua", ns)
  local out = {}
  for _, r in ipairs(ns.Recipes[line] or {}) do
    if r.creates and r.spell then
      local v = {}
      for _, n in ipairs(r.vendors or {}) do
        if n.faction ~= "Alliance" then v[#v + 1] = n.npc end
      end
      out[r.spell] = { skill = r.skill, creates = r.creates, src = r.autoLearned and "auto" or r.source and table.concat(r.source, "+") or r.teach and "item" or "?",
        cost = r.cost, vendors = #v > 0 and v or nil }
    end
  end
  recipes[line] = out
end

-- Ecriture triee (diff stable)
local function keys(t) local k = {} for x in pairs(t) do k[#k + 1] = x end table.sort(k) return k end
local w = {}
local function p(s) w[#w + 1] = s end
p("-- GENERE par tools/import-forever.lua : ne pas modifier a la main.")
p("-- Source : What's Training (WhatsTraining/Classes/Camelot, Crafting/Recipes/Camelot), licence MIT, (c) 2019 Sveng.")
p("-- spells[spellID] = niveau chez le maitre ; recipes[skillLine][recipeID] = { skill, creates, src, cost, vendors (PNJ Horde/neutres) }.")
p("-- src : trainer, vendor, quest, drop (combines par +), auto (appris avec le metier), item (objet de recette, source inconnue), ? (inconnue).")
p("local _, ns = ...")
p("ns.Data = ns.Data or {}")
p("ns.Data.Forever = {")
p("  spells = {")
for _, id in ipairs(keys(spells)) do p(("    [%d] = %d,"):format(id, spells[id])) end
p("  },")
p("  recipes = {")
for _, line in ipairs(keys(recipes)) do
  p(("    [%d] = {"):format(line))
  local t = recipes[line]
  for _, id in ipairs(keys(t)) do
    local r = t[id]
    local vend = r.vendors and (", vendors = { " .. table.concat(r.vendors, ", ") .. " }") or ""
    p(("      [%d] = { skill = %d, creates = %d, src = %q%s%s },"):format(id, r.skill or 0, r.creates, r.src,
      r.cost and (", cost = " .. r.cost) or "", vend))
  end
  p("    },")
end
p("  },")
p("}")
io.write(table.concat(w, "\n"), "\n")
