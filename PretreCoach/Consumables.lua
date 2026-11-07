-- Module Consommables : lecture des sacs (0 a 4), classement par classe/sous-classe, meilleur objet utilisable par categorie.
-- Lecture seule : rien n'est utilise ici (le bouton securise est dans UI/ConsumablesBar.lua). Rien n'est ecrit dans PretreCoachDB.
-- Declencheurs : BAG_UPDATE_DELAYED (deja differe par le jeu), PLAYER_LEVEL_UP, PLAYER_ENTERING_WORLD.
local _, ns = ...
local S = ns.S

local Cons = { Order = { "food", "water", "heal", "mana", "bandage" }, Best = {}, Total = {} }
ns.Cons = Cons

-- A VERIFIER EN JEU (/dump C_Item.GetItemInfoInstant(id)) : classe 0 = Consommable ; sous-classes Classic/Retail :
-- 1 potion, 5 nourriture et boisson, 7 bandage. Nourriture et eau partagent la sous-classe 5 : on les separe par le nom.
local CLASS_CONSUMABLE, SUB_POTION, SUB_FOOD, SUB_BANDAGE = 0, 1, 5, 7
local BAGS = { 0, 1, 2, 3, 4 }
local WATER_WORDS = { "eau", "water", "boisson", "drink", "cidre", "lait", "milk" }
local HEAL_WORDS = { "soins", "heal" }

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

local function has(name, words)
  for _, w in ipairs(words) do if name:find(w, 1, true) then return true end end
  return false
end

local function category(sub, name)
  local n = name:lower()
  if sub == SUB_BANDAGE then return "bandage" end
  if sub == SUB_FOOD then return has(n, WATER_WORDS) and "water" or "food" end
  if sub == SUB_POTION then
    if has(n, HEAL_WORDS) then return "heal" end
    if n:find("mana", 1, true) then return "mana" end
  end
end

-- Infos d'un ID : { cat, name, ilvl, req, icon } ou nil (hors categories, ou pas encore en cache).
local function describe(id)
  local inst = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local r = { S.GetAll(inst, id) }
  if r[1] ~= "lisible" or num(r[7]) ~= CLASS_CONSUMABLE then return nil end
  local icon, sub = r[6], num(r[8])
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local i = { S.GetAll(get, id) }
  if i[1] ~= "lisible" or type(i[2]) ~= "string" then return nil end
  local cat = category(sub, i[2])
  if cat then return { cat = cat, name = i[2], ilvl = num(i[5]) or 0, req = num(i[6]) or 0, icon = i[11] or icon } end
end

local function better(a, b)
  if not b then return true end
  if a.ilvl ~= b.ilvl then return a.ilvl > b.ilvl end
  if a.minStack ~= b.minStack then return a.minStack < b.minStack end -- a egalite : entamer le plus petit tas
  return a.id < b.id
end

local function build(newLevel)
  local api = C_Container
  local out = { best = {}, total = {} }
  if type(api) ~= "table" then return out end
  -- niveau illisible : on ne filtre pas (un objet trop fort ne fait qu'echouer a l'usage)
  local level = newLevel or num(S.Get(UnitLevel, "player")) or 999
  local seen, items = {}, {}
  for _, bag in ipairs(BAGS) do
    local slots = S.Get(api.GetContainerNumSlots, bag)
    for slot = 1, num(slots) or 0 do
      local info = S.Get(api.GetContainerItemInfo, bag, slot)
      local id = type(info) == "table" and num(info.itemID)
      if id then
        if seen[id] == nil then seen[id] = describe(id) or false end
        local d = seen[id]
        if d and d.req <= level then
          local n = num(info.stackCount) or 1
          local it = items[id]
          if not it then
            it = { id = id, cat = d.cat, name = d.name, ilvl = d.ilvl, icon = info.iconFileID or d.icon, count = 0, minStack = n }
            items[id] = it
          end
          it.count, it.minStack = it.count + n, math.min(it.minStack, n)
        end
      end
    end
  end
  for _, it in pairs(items) do
    out.total[it.cat] = (out.total[it.cat] or 0) + it.count
    if better(it, out.best[it.cat]) then out.best[it.cat] = it end
  end
  return out
end

function Cons.Scan(newLevel)
  local ok, res = pcall(build, num(newLevel))
  if ok then Cons.Best, Cons.Total = res.best, res.total end -- API incertaine sur Forever : en cas d'erreur on garde l'etat precedent
  ns.Fire("CONS")
end

ns.On("BAG_UPDATE_DELAYED", function() Cons.Scan() end)
ns.On("PLAYER_ENTERING_WORLD", function() Cons.Scan() end)
-- a PLAYER_LEVEL_UP, UnitLevel peut encore rendre l'ancien niveau : on prend celui de l'evenement
ns.On("PLAYER_LEVEL_UP", function(_, level) Cons.Scan(level) end)
