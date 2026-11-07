-- Rappels de métiers (spec 6.6), via Calc.ProfessionTodo, sur STATE { "profs" } ou { "level" } :
-- rang à prendre chez le maître, nouveau bandage (dernier connu dans ns.db.training.bandage), métier manquant dès le niveau 5.
-- Anti-répétition par clé, le temps de la session.
-- shortcut: noms de bandages et de rangs pris dans les données (français), pas relus en jeu.
local _, ns = ...
local L, State, Calc, D = ns.L, ns.State, ns.Calc, ns.Data

local Professions = {}
ns.Professions = Professions

local seen = {}

local function once(key, text)
  if seen[key] then return end
  seen[key] = true
  ns.Toast(text, { key = "pc:prof:" .. key })
end

function Professions.Check()
  local level, profs = State.level, State.profs
  local todo, bandage, missing = Calc.ProfessionTodo(level, profs, D.Professions)
  if not todo then return end
  for _, t in ipairs(todo) do
    once("rank:" .. t.skillLine .. ":" .. t.rank.name,
      L.PROF_RANK:format(D.Professions[t.skillLine].name, profs[t.skillLine].rank or 0, t.rank.name))
  end
  if bandage and ns.db then
    ns.db.training = ns.db.training or {}
    local last = ns.db.training.bandage
    if last and bandage.skill > last then
      ns.Toast(L.PROF_BANDAGE:format(bandage.name), { key = "pc:prof:bandage:" .. bandage.skill })
    end
    if not last or bandage.skill > last then ns.db.training.bandage = bandage.skill end
  end
  if level >= 5 and #missing > 0 then
    local names = {}
    for i, id in ipairs(missing) do names[i] = D.Professions[id].name end
    once("missing", L.PROF_MISSING:format(table.concat(names, ", ")))
  end
end

ns.Listen("STATE", function(_, changed)
  for _, k in ipairs(changed or {}) do
    if k == "profs" or k == "level" then return Professions.Check() end
  end
end)

------------------------------------------------------------------------
-- L16a : recettes lues en direct a l'ouverture de la fenetre de metier (lecture seule : aucune selection ni fabrication).
-- ns.Prof.Advice[skillLineID] = { rank, max, when, list = { { recipeID, name, color, skillUps, craftable, cost, value, margin, missing } } }
-- Noms des champs de GetRecipeInfo a confirmer en jeu (releve dans ns.db.probe.tradeskill) ; lus avec repli.
-- shortcut: quantite produite supposee egale a 1 et premier reactif seul pris en compte ; a affiner apres un releve reel.
------------------------------------------------------------------------
local S = ns.S
local Prof = { Advice = {} }
ns.Prof = Prof

local CRANK = { orange = 1, yellow = 2, green = 3 }
local NAMES = { optimal = "orange", medium = "yellow", easy = "green" }
local BY_NUM = { [0] = "optimal", [1] = "medium", [2] = "easy", [3] = "trivial" }
local TOP = 5

local function field(t, k)
  local v = t[k]
  if S.IsSecret(v) then return nil end
  return v
end
local function num(v) return type(v) == "number" and v or nil end

local function colorOf(info)
  local rd = num(field(info, "relativeDifficulty"))
  if rd then
    local name
    local E = Enum and Enum.TradeskillRelativeDifficulty
    if type(E) == "table" then for k, v in pairs(E) do if v == rd and type(k) == "string" then name = k:lower() end end end
    name = name or BY_NUM[rd]
    if name then return NAMES[name] end
  end
  local d = field(info, "difficulty")
  if type(d) == "string" then return NAMES[d:lower()] end
end

-- Ligne de metier ouverte : skillLineID, rang, max.
local function openLine()
  local T = C_TradeSkillUI
  local info = S.Get(T.GetBaseProfessionInfo)
  if type(info) == "table" and num(field(info, "professionID")) then
    return field(info, "professionID"), num(field(info, "skillLevel")) or 0, num(field(info, "maxSkillLevel")) or 0
  end
  local st, id, _, rank, max = S.GetAll(T.GetTradeSkillLine)
  if st == "lisible" and type(id) == "number" then return id, num(rank) or 0, num(max) or 0 end
end

local function price(itemID) return itemID and ns.AH.Price(itemID) or nil end

-- Cout (nil si un composant n'a pas de prix), valeur du produit, marge et manques d'une recette.
local function enrich(e)
  local sch = S.Get(C_TradeSkillUI.GetRecipeSchematic, e.recipeID, false)
  if type(sch) ~= "table" then return end
  local cost, missing, slots = 0, {}, field(sch, "reagentSlotSchematics")
  for _, s in ipairs(type(slots) == "table" and slots or {}) do
    local r = type(s) == "table" and type(s.reagents) == "table" and s.reagents[1]
    if r then
      local id, q = num(field(r, "itemID")), num(field(s, "quantityRequired"))
      local p = id and q and price(id)
      if p and cost then cost = cost + p * q else cost = nil end -- une fois nil, cost reste nil
      local have = id and S.Get(GetItemCount, id)
      if id and q and type(have) == "number" and have < q then missing[#missing + 1] = { itemID = id, n = q - have } end
    end
  end
  e.cost, e.missing = cost, missing
  e.value = price(num(field(sch, "outputItemID")))
  if e.cost and e.value then e.margin = e.value - e.cost end
end

-- Compare deux valeurs : true/false si differentes, nil si egales (nil toujours en dernier).
local function cmp(x, y, desc)
  if x == y then return nil end
  if x == nil then return false end
  if y == nil then return true end
  if desc then return x > y end
  return x < y
end
local function bool(b) return b and 1 or 0 end
local function first(...)
  for i = 1, select("#", ...) do local r = (select(i, ...)) if r ~= nil then return r end end
  return false
end

local function sortPre(a, b)
  return first(cmp(CRANK[a.color], CRANK[b.color]), cmp(bool(a.craftable), bool(b.craftable), true), cmp(a.recipeID, b.recipeID))
end
local function sortFinal(a, b)
  return first(cmp(CRANK[a.color], CRANK[b.color]), cmp(a.margin, b.margin, true), cmp(a.cost, b.cost),
    cmp(bool(a.craftable), bool(b.craftable), true), cmp(a.recipeID, b.recipeID))
end

local function Get(line) return Prof.Advice[line] or (ns.db and ns.db.prof and ns.db.prof[line]) end
Prof.Get = Get

local toasted = {}

function Prof.Read()
  local T = C_TradeSkillUI
  if not T or InCombatLockdown() or S.Get(T.IsTradeSkillReady) ~= true then return end
  local line, rank, max = openLine()
  local ids = S.Get(T.GetAllRecipeIDs)
  if not line or type(ids) ~= "table" then return end
  local cands, best = {}, 9
  for _, id in ipairs(ids) do
    local info = S.Get(T.GetRecipeInfo, id)
    if type(info) == "table" and field(info, "learned") == true then
      local c, ups = colorOf(info), num(field(info, "numSkillUps"))
      if c and not (ups and ups < 1) then
        best = math.min(best, CRANK[c])
        cands[#cands + 1] = { recipeID = id, name = field(info, "name"), color = c, skillUps = ups or 1,
          craftable = field(info, "craftable") == true or (num(field(info, "numAvailable")) or 0) > 0 }
      end
    end
  end
  local list = {}
  for _, e in ipairs(cands) do if best > 2 or CRANK[e.color] <= 2 then list[#list + 1] = e end end -- vertes : repli seulement
  table.sort(list, sortPre)
  for i = #list, TOP + 1, -1 do list[i] = nil end
  for _, e in ipairs(list) do enrich(e) end
  table.sort(list, sortFinal)
  local old = Get(line)
  local adv = { rank = rank, max = max, list = list, when = date("%Y-%m-%d %H:%M:%S") }
  Prof.Advice[line] = adv
  if ns.db then ns.db.prof = ns.db.prof or {}; ns.db.prof[line] = adv end
  local top, prev = list[1], old and old.list and old.list[1]
  local key = top and (line .. ":" .. top.recipeID)
  -- Secourisme (129) : le conseil bandage existe deja, pas de second toast
  if top and line ~= 129 and not toasted[key] and not (prev and prev.recipeID == top.recipeID) then
    toasted[key] = true
    local data = D.Professions[line]
    ns.Toast(L.PROF_CRAFT:format(data and data.name or tostring(line), top.name or "?"), { key = "pc:prof:craft:" .. key })
  end
end

function Prof.Money(c)
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, c)
    if ok and type(s) == "string" then return s end
  end
  local po, pa, pc, t = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100, {}
  if po > 0 then t[#t + 1] = po .. " po" end
  if pa > 0 then t[#t + 1] = pa .. " pa" end
  if pc > 0 or #t == 0 then t[#t + 1] = pc .. " pc" end
  return table.concat(t, " ")
end

local function itemName(id)
  local ok, n = pcall(function() return C_Item.GetItemInfo(id) end)
  return ok and type(n) == "string" and n or ("objet " .. id)
end

-- Texte du guide pour un metier : conseil lu en direct, sinon invitation a ouvrir la fenetre.
function Prof.Text(line)
  local adv = Get(line)
  local top = adv and adv.list and adv.list[1]
  if not top then
    local _, bandage = Calc.ProfessionTodo(State.level, State.profs, D.Professions)
    return (line == 129 and bandage and (L.PROF_BANDAGE_NOW:format(bandage.name) .. "\n") or "") .. L.PROF_OPEN
  end
  local s = L.PROF_CRAFT_LINE:format(top.name or "?", L["PROF_C_" .. top.color], top.skillUps)
  if top.cost then s = s .. L.PROF_COST:format(Prof.Money(top.cost)) end
  if top.margin then s = s .. L.PROF_MARGIN:format((top.margin >= 0 and "+" or "-") .. Prof.Money(math.abs(top.margin))) end
  if not top.craftable and top.missing and #top.missing > 0 then
    local t = {}
    for i, m in ipairs(top.missing) do t[i] = m.n .. "x " .. itemName(m.itemID) end
    s = s .. "\n" .. L.PROF_LACK:format(table.concat(t, ", "))
  end
  return s
end

-- Lecture 0,3 s apres l'evenement, jamais en combat (reprise a la fin du combat).
local waiting, deferred = false, false
local function schedule()
  if waiting or not C_Timer then return end
  waiting = true
  C_Timer.After(0.3, function()
    waiting = false
    if InCombatLockdown() then deferred = true return end
    Prof.Read()
  end)
end
ns.On("TRADE_SKILL_SHOW", schedule)
ns.On("TRADE_SKILL_LIST_UPDATE", schedule)
ns.On("PLAYER_REGEN_ENABLED", function() if deferred then deferred = false schedule() end end)
