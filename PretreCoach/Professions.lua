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
      local have = id and S.Get((C_Item and C_Item.GetItemCount) or GetItemCount, id)
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

-- Index { itemID -> { { line, recipeID, name, color, ups, n } } } des composants des recettes apprises orange/jaune, garde en
-- base (nombres et noms lisibles seulement) pour servir fenetre fermee. Reconstruit par metier a chaque lecture.
function Prof.IndexReagents(line, cands)
  if not ns.db then return end
  local idx = {}
  for id, list in pairs(ns.db.reagents or {}) do
    local keep = {}
    for _, e in ipairs(list) do if e.line ~= line then keep[#keep + 1] = e end end
    if #keep > 0 then idx[id] = keep end
  end
  for _, e in ipairs(cands) do
    local sch = (e.color == "orange" or e.color == "yellow") and S.Get(C_TradeSkillUI.GetRecipeSchematic, e.recipeID, false)
    for _, slot in ipairs(type(sch) == "table" and type(sch.reagentSlotSchematics) == "table" and sch.reagentSlotSchematics or {}) do
      local q = type(slot) == "table" and num(field(slot, "quantityRequired"))
      for _, r in ipairs(q and type(slot.reagents) == "table" and slot.reagents or {}) do
        local id = num(field(r, "itemID"))
        if id then
          idx[id] = idx[id] or {}
          idx[id][#idx[id] + 1] = { line = line, recipeID = e.recipeID, name = type(e.name) == "string" and e.name or nil,
            color = e.color, ups = e.skillUps, n = q }
        end
      end
    end
  end
  if next(idx) or ns.db.reagents then ns.db.reagents = idx end
end

function Prof.Read()
  local T = C_TradeSkillUI
  if not T or InCombatLockdown() or S.Get(T.IsTradeSkillReady) ~= true then return end
  local line, rank, max = openLine()
  local ids = S.Get(T.GetAllRecipeIDs)
  if not line or type(ids) ~= "table" then return end
  local cands, best, known = {}, 9, {}
  for _, id in ipairs(ids) do
    local info = S.Get(T.GetRecipeInfo, id)
    if type(info) == "table" and field(info, "learned") == true then
      local c, ups = colorOf(info), num(field(info, "numSkillUps"))
      local nm = field(info, "name")
      if type(nm) == "string" then known[nm] = c or "gray" end
      known[id] = c or "gray" -- toutes les recettes apprises, pas seulement le top
      if c and not (ups and ups < 1) then
        best = math.min(best, CRANK[c])
        cands[#cands + 1] = { recipeID = id, name = field(info, "name"), color = c, skillUps = ups or 1,
          craftable = field(info, "craftable") == true or (num(field(info, "numAvailable")) or 0) > 0 }
      end
    end
  end
  pcall(Prof.IndexReagents, line, cands)
  local list = {}
  for _, e in ipairs(cands) do if best > 2 or CRANK[e.color] <= 2 then list[#list + 1] = e end end -- vertes : repli seulement
  table.sort(list, sortPre)
  for i = #list, TOP + 1, -1 do list[i] = nil end
  for _, e in ipairs(list) do enrich(e) end
  table.sort(list, sortFinal)
  local old = Get(line)
  local adv = { rank = rank, max = max, list = list, known = known, when = date("%Y-%m-%d %H:%M:%S") }
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

-- Seule fonction d'argent de l'addon : « 1[or] 20[argent] », zéros omis (0 = « 0[cuivre] »). Valeur illisible : « ? ».
local COIN = { "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t", "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t", "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" }
function Prof.Money(c, plain) -- plain : texte po/pa/pc (sonde, copiable hors du jeu)
  if type(c) ~= "number" or S.IsSecret(c) then return "?" end
  if plain then
    c = math.floor(math.abs(c))
    local po, pa, pc, t = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100, {}
    if po > 0 then t[#t + 1] = po .. " po" end
    if pa > 0 then t[#t + 1] = pa .. " pa" end
    if pc > 0 or #t == 0 then t[#t + 1] = pc .. " pc" end
    return table.concat(t, " ")
  end
  if GetCoinTextureString then
    local ok, s = pcall(GetCoinTextureString, c)
    if ok and type(s) == "string" and s:find("|T", 1, true) then return s end
  end
  c = math.floor(math.abs(c))
  local po, pa, pc, t = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100, {}
  if po > 0 then t[#t + 1] = po .. COIN[1] end
  if pa > 0 then t[#t + 1] = pa .. COIN[2] end
  if pc > 0 or #t == 0 then t[#t + 1] = pc .. COIN[3] end
  return table.concat(t, " ")
end

-- Icône d'objet inline devant le nom ; nom seul si l'icône est illisible.
local function ico(id, name)
  if not id then return name end
  local icon
  if C_Item and C_Item.GetItemIconByID then
    local ok, v = pcall(C_Item.GetItemIconByID, id)
    if ok then icon = v end
  end
  if not icon and C_Item and C_Item.GetItemInfoInstant then
    local ok, _, _, _, _, v = pcall(C_Item.GetItemInfoInstant, id)
    if ok then icon = v end
  end
  if type(icon) == "number" and icon > 0 or type(icon) == "string" and icon ~= "" then
    if S.IsSecret(icon) then return name end
    return "|T" .. icon .. ":14:14|t " .. name
  end
  return name
end

-- Marge : verte si positive, rouge si négative, sans signe collé aux icônes.
local function margin(m)
  local col = m > 0 and "|cff40ff40" or m < 0 and "|cffff4040" or nil
  local s = Prof.Money(math.abs(m))
  return col and (col .. s .. "|r") or s
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
  if top.value then s = s .. L.PROF_VALUE:format(Prof.Money(top.value)) end
  if top.margin then s = s .. L.PROF_MARGIN:format(margin(top.margin)) end
  if not top.craftable and top.missing and #top.missing > 0 then
    local t = {}
    for i, m in ipairs(top.missing) do t[i] = m.n .. "x " .. itemName(m.itemID) end
    s = s .. "\n" .. L.PROF_LACK:format(table.concat(t, ", "))
  end
  return s
end

------------------------------------------------------------------------
-- Plan de montee (Data/ProfPlan.lua) : etape du rang actuel en checklist didactique. Texte seulement (Regle 0).
-- done = true / false / nil (nil = illisible ou inconnu : on ne coche rien et on n'invente aucun compte).
------------------------------------------------------------------------
local function count(id)
  if not id then return nil end
  local n = S.Get((C_Item and C_Item.GetItemCount) or GetItemCount, id)
  return type(n) == "number" and n or nil
end

local function zoneName(id)
  local info = S.Get(C_Map and C_Map.GetMapInfo, id)
  local n = type(info) == "table" and field(info, "name")
  return type(n) == "string" and n or ("zone " .. id)
end

local function stepFor(plan, rank)
  rank = math.max(rank, 1)
  for _, x in ipairs(plan.steps) do if rank >= x.from and rank < x.to then return x end end
  return plan.steps[#plan.steps]
end

-- rid (recipeID, optionnel) d'abord : les noms du plan sont traduits de memoire et peuvent differer du client.
local function knownRecipe(adv, name, rid)
  for _, e in ipairs(adv and adv.list or {}) do if (rid and e.recipeID == rid) or e.name == name then return e end end
  local k = adv and type(adv.known) == "table" and adv.known
  local c = k and ((rid and k[rid]) or k[name])
  if c then return { name = name, color = c } end
end
-- Recette sure d'etre inconnue : la fenetre du metier a ete lue (adv.known) et le nom n'y est pas.
local function unknownRecipe(adv, name, rid)
  return adv ~= nil and type(adv.known) == "table" and not knownRecipe(adv, name, rid)
end

local function names(t, sep) return table.concat(t, sep or ", ") end

Prof.StepFor, Prof.KnownRecipe = stepFor, knownRecipe -- pour Budget

-- Achat de ce genre au cout connu payable apres la reserve (Budget) ? Rend true, ou false et la raison ; sous pcall.
local function afford(kind, cost)
  if not (cost and cost > 0 and ns.Budget) then return true end
  local ok, yes, why = pcall(ns.Budget.Check, kind, cost)
  if ok and yes == false then return false, why end
  return true
end

local GOKEY = { [182] = "HERBALISM", [171] = "ALCHEMY", [129] = "FIRSTAID" } -- cibles de Goto.For ; autres metiers : pas de lieu

function Prof.Steps(line)
  local plan = D.ProfPlan and D.ProfPlan[line]
  local p = type(State.profs) == "table" and State.profs[line]
  if not plan or not p then return nil end
  local rank, max = p.rank or 0, p.max or 0
  local step = stepFor(plan, rank)
  local pname = D.Professions[line] and D.Professions[line].name or tostring(line)
  local title
  if step.recipe then title = L.PROF_STEP_TITLE_CRAFT:format(pname, rank, max, step.recipe)
  elseif step.herbs then title = L.PROF_STEP_TITLE_HERB:format(pname, rank, max, names(step.herbs, ", "))
  else title = L.PROF_STEP_TITLE_NOTE:format(pname, rank, max) end
  local todo = {}
  local function add(kind, text, done) todo[#todo + 1] = { kind = kind, text = text, done = done } end
  local adv = Get(line)

  -- Rang suivant a prendre des qu'il est disponible (pris tot, rien n'est perdu au plafond) ; sinon, pres du plafond,
  -- le niveau qu'il faudra.
  local lock, goKey
  for _, t in ipairs(Calc.ProfessionTodo(State.level, State.profs, D.Professions) or {}) do
    if t.skillLine == line then lock = t.rank end
  end
  if lock or rank >= max - 5 then
    if lock then
      goKey = GOKEY[line]
      local ok, d = false, nil
      if goKey and ns.Goto then ok, d = pcall(ns.Goto.For, goKey) end
      local where = ok and type(d) == "table" and d.x and d.text or plan.masters and plan.masters[lock.name]
      add("rank", where and L.PROF_STEP_RANK:format(lock.name, where) or L.PROF_STEP_RANK_ANY:format(lock.name), false)
      if rank >= max then title = L.PROF_STEP_TITLE_RANK:format(pname, rank, max, lock.name)
      elseif rank >= max - 5 then title = L.PROF_STEP_TITLE_SOON:format(pname, rank, max, max - rank, lock.name)
      else title = L.PROF_STEP_TITLE_AVAIL:format(pname, rank, max, lock.name) end
    else
      for _, r in ipairs(D.Professions[line] and D.Professions[line].ranks or {}) do
        if r.max > max then
          if type(State.level) == "number" and State.level < r.minLevel then add("wait", L.PROF_STEP_RANK_LEVEL:format(r.name, r.minLevel)) end
          break
        end
      end
    end
  end
  local held = lock ~= nil and rank >= max -- plafond atteint : rien d'autre a faire avant le maitre
  -- Recettes a apprendre : seulement ce que le maitre de ce metier a affiche « disponible » a la derniere visite (lu en jeu,
  -- jamais deduit du plan, dont les noms ne sont pas verifies) et pas deja connu dans la fenetre du metier.
  local learn, nl = nil, 0
  for k, v in pairs((ns.db and ns.db.trainer) or {}) do
    local rname = k:match("^(.-)|")
    if type(v) == "table" and v.category == "available" and v.skill == pname and rname and not knownRecipe(adv, rname) and nl < 3 then
      local ok, d = false, nil
      if GOKEY[line] and ns.Goto then ok, d = pcall(ns.Goto.For, GOKEY[line]) end
      local where = ok and type(d) == "table" and d.x and d.text
      add("learn", where and L.PROF_STEP_LEARN:format(rname, where) or L.PROF_STEP_LEARN_ANY:format(rname), false)
      learn, nl = true, nl + 1
    end
  end
  if step.buy then
    local b = step.buy
    local known = knownRecipe(adv, b.recipe) and true or nil
    local txt = L.PROF_STEP_BUY:format(b.item or ("Recette : " .. b.recipe), b.where) .. (b.price and (" (" .. Prof.Money(b.price) .. ")") or "")
    local ok, why = true, nil
    if not known then ok, why = afford("recipe", b.price) end
    add("buy", ok and txt or (txt .. " : " .. why), known)
    todo[#todo].blocked = not ok or nil
  end
  if step.extra then add("extra", step.extra) end
  -- Recette du plan (pas achetee chez un marchand, ligne buy ci-dessus) : toujours citee, d'apres le plan et pas d'apres ce que
  -- le joueur a vu ; cochee si la fenetre du metier la montre, a faire si elle n'y est pas, sans coche si la fenetre n'a jamais ete lue.
  if step.recipe and not (step.buy and step.buy.recipe == step.recipe) then
    local known -- true / false / nil (fenetre jamais lue)
    if knownRecipe(adv, step.recipe, step.rid) then known = true elseif unknownRecipe(adv, step.recipe, step.rid) then known = false end
    local dup
    for _, a in ipairs(todo) do if a.kind == "learn" and a.text:find(step.recipe, 1, true) then dup = true end end
    if not dup then
      local ok, d = false, nil
      if known == false and GOKEY[line] and ns.Goto then ok, d = pcall(ns.Goto.For, GOKEY[line]) end
      local where = ok and type(d) == "table" and d.x and d.text
      local text = known == nil and L.PROF_STEP_LEARN_CHECK:format(step.recipe)
        or where and L.PROF_STEP_LEARN:format(step.recipe, where) or L.PROF_STEP_LEARN_ANY:format(step.recipe)
      add("learn", text, known)
      if known == false then learn = true end
    end
  end
  if step.comps then
    local left = math.max(1, math.ceil(step.crafts * (step.to - math.min(math.max(rank, step.from), step.to)) / (step.to - step.from)))
    local parts, vendors, all, spend = {}, {}, true, 0
    for _, c in ipairs(step.comps) do
      local need, have = c.n * left, count(c.id)
      local nm = ico(c.id, c.name)
      parts[#parts + 1] = have and L.PROF_STEP_HAVE:format(need, nm, have) or ("%d %s"):format(need, nm)
      -- a acheter seulement s'il en manque : compte lu = le manque ; compte illisible = sans quantite
      if c.vendor and (have == nil or have < need) then
        vendors[#vendors + 1] = have and ("%d %s"):format(need - have, nm) or nm
        if c.price then spend = spend + c.price * math.max(0, need - (have or 0)) end
      end
      if have == nil then all = nil elseif have < need and all then all = false end
    end
    local text = L.PROF_STEP_GATHER:format(names(parts))
    if #vendors > 0 then text = text .. L.PROF_STEP_VENDOR:format(names(vendors, " et ")) end
    local ok, why = afford("comps", spend)
    if not ok then text = text .. " : " .. why end
    add("gather", text, all)
    add("craft", L.PROF_STEP_CRAFT:format(left, step.recipe, step.to))
  end
  if step.note then add("note", step.note) end
  if step.herbs then
    local z = {}
    for i, id in ipairs(step.zones or {}) do if i <= 3 then z[#z + 1] = zoneName(id) end end
    add("herb", L.PROF_STEP_HERB:format(names(step.herbs, ", "), names(z, " ou ")))
  end
  local top = adv and adv.list and adv.list[1]
  if top and top.name and top.name ~= step.recipe and (top.color == "orange" or top.color == "yellow") then
    add("live", L.PROF_STEP_LIVE:format(top.name, L["PROF_C_" .. top.color]))
  end
  if held then for _, a in ipairs(todo) do if a.kind ~= "rank" then a.held = true end end end
  return { title = title, short = title:sub(#pname + 2), todo = todo, step = step, alert = lock ~= nil, learn = learn, go = GOKEY[line] } -- maitre le plus proche, toujours propose
end

-- Texte court pour la carte : titre + premiere action non faite (2 lignes max), ou le conseil « tes sacs » si une
-- fabrication fait monter la competence et que rien ne bloque (rang ou recette chez le maitre).
function Prof.StepsText(line)
  local s = Prof.Steps(line)
  if not s then return nil end
  local first
  for _, a in ipairs(s.todo) do if a.done ~= true and not a.held then first = a break end end
  if not (first and (first.kind == "rank" or first.kind == "learn")) then -- recette a avoir d'abord, pas un craft des sacs
    for _, e in ipairs(Prof.Craftable()) do
      if e.line == line and e.skillUp then return s.short .. "\n" .. Prof.BagShort(e) end
    end
  end
  return first and (s.short .. "\n" .. first.text) or s.short
end

------------------------------------------------------------------------
-- Crafts possibles avec les composants NON marchands des sacs ; les fioles, fils, etc. (vendor = true) sont a acheter.
-- Entree : { line, recipe, n, with = { noms }, buy = { { name, qty, cost } }, skillUp = true|nil, confirm = true|nil }
-- Composant non marchand illisible (secret, API absente) : recette ignoree, jamais de faux compte.
------------------------------------------------------------------------
local FRESH = 25 -- recettes du plan plus de 25 points sous le rang : ignorees (grises)

local function compute()
  local out = {}
  if type(State.profs) ~= "table" then return out end
  for line, plan in pairs(D.ProfPlan or {}) do
    local p = State.profs[line]
    local adv = p and Get(line)
    for _, st in ipairs(p and plan.steps or {}) do
      if st.recipe and st.comps and (p.rank or 0) >= st.from and st.to > (p.rank or 0) - FRESH and not unknownRecipe(adv, st.recipe, st.rid) then
        local n, with, ok = math.huge, {}, true
        for _, c in ipairs(st.comps) do
          if not c.vendor then
            local have = count(c.id)
            if have == nil then ok = false break end
            n = math.min(n, math.floor(have / c.n))
            with[#with + 1] = ico(c.id, c.name)
          end
        end
        if ok and #with > 0 and n >= 1 then
          local e = { line = line, recipe = st.recipe, n = n, with = with, buy = {} }
          local known = knownRecipe(adv, st.recipe, st.rid)
          if known then e.skillUp = (known.color == "orange" or known.color == "yellow") or nil
          else e.confirm = true e.skillUp = (p.rank or 0) < st.to or nil end
          -- Keep est la source : une ressource qu'il ne garde pas pour monter le metier (il la vend ou la craft ailleurs)
          -- ne fait pas de ce craft un « skill-up » conseille ici
          for _, c in ipairs(e.skillUp and st.comps or {}) do
            local okK, kv = false, nil
            if not c.vendor and ns.Keep then okK, kv = pcall(ns.Keep.Verdict, c.id) end
            if okK and kv and kv.keep == 0 and not (kv.restKind == "craft" and kv.craftName == st.recipe) then e.skillUp = nil end
          end
          for _, c in ipairs(st.comps) do
            if c.vendor then
              local qty = n * c.n
              local have = count(c.id)
              if have then qty = math.max(0, qty - have) end
              if qty > 0 then e.buy[#e.buy + 1] = { name = c.name, id = c.id, qty = qty, cost = c.price and c.price * qty or nil } end
            end
          end
          out[#out + 1] = e
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if (a.skillUp or false) ~= (b.skillUp or false) then return a.skillUp or false end
    if a.n ~= b.n then return a.n > b.n end
    if a.line ~= b.line then return a.line < b.line end
    return a.recipe < b.recipe
  end)
  return out
end

-- Hors combat : recalcul a chaque appel (quelques GetItemCount) et a BAG_UPDATE_DELAYED ; en combat : dernier resultat connu.
local last = {}
function Prof.Craftable()
  if not InCombatLockdown() then last = compute() end
  return last
end

local function buyList(e)
  local t = {}
  for i, b in ipairs(e.buy) do t[i] = ("%d %s"):format(b.qty, ico(b.id, b.name)) .. (b.cost and (" (≈ " .. Prof.Money(b.cost) .. ")") or "") end
  return names(t)
end

-- Achat de composants au cout connu non payable apres la reserve : « : garde X pour tes sorts » (sinon vide).
local function buyWhy(e)
  local total = 0
  for _, b in ipairs(e.buy) do total = total + (b.cost or 0) end
  local ok, why = afford("comps", total)
  return ok and "" or (" : " .. why)
end

function Prof.BagText(e)
  local s = L.PROF_BAG:format(e.n, e.recipe, names(e.with, " et "))
  if #e.buy > 0 then s = s .. L.PROF_BAG_BUY:format(buyList(e)) .. buyWhy(e) end
  return e.confirm and (s .. L.PROF_BAG_CONFIRM) or s
end

function Prof.BagShort(e)
  return L.PROF_BAG_SHORT:format(e.n, e.recipe) .. (#e.buy > 0 and (L.PROF_BAG_SHORT_BUY:format(buyList(e)) .. buyWhy(e)) or "")
end

ns.On("BAG_UPDATE_DELAYED", function() if not InCombatLockdown() then Prof.Craftable() end end)

-- Noms des recettes du plan donnes par le client (C_Spell.GetSpellName(rid)) : ceux du plan, traduits de memoire, ne sont
-- qu'un repli. Une seule fois a la connexion ; un nom illisible garde celui du plan.
function Prof.UseClientNames()
  for _, plan in pairs(D.ProfPlan or {}) do
    for _, st in ipairs(plan.steps or {}) do
      local nm = st.rid and S.Get(C_Spell and C_Spell.GetSpellName, st.rid)
      if type(nm) == "string" and nm ~= "" and nm ~= st.recipe then
        if st.buy and st.buy.recipe == st.recipe then st.buy.recipe = nm end
        st.recipe = nm
      end
    end
  end
end
ns.On("PLAYER_LOGIN", Prof.UseClientNames)

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
