-- Itinéraire des quêtes de la zone : Quests.Route() -> { { kind, questID, name, mapID, x, y, text, ... } } et Quests.Best() = premier arrêt.
-- Lecture seule (Règle 0). kind : "turnin" (journal, terminée : à rendre), "progress" (journal, en cours), "pickup" (disponible, connue de QuestieDB).
-- QuestieDB (ns.Q) donne les lieux ; sans lui : journal seul, sans lieu. Récompenses : base apprise (QuestDB), journal, estimation.
-- Ordre : plus proche voisin depuis le joueur (une quête à rendre d'abord si elle n'est pas bien plus loin que l'arrêt le plus proche), puis 2-opt borné ; une quête à prendre
-- passe toujours avant son objectif puis son rendu. Ce qui est sur une autre carte ou sans lieu passe après (rendre, en cours, prendre).
-- Choix des quêtes retenues (au plus MAX_STOPS arrêts) : score = (or + poids x XP en or) / minutes, voir « Valeur » ci-dessous.
-- Quests.Pins(uiMapID) : repères à dessiner sur la carte du monde (UI/QuestPins.lua).
local _, ns = ...
local S, L, Q, State, QuestDB = ns.S, ns.L, ns.Q, ns.State, ns.QuestDB

local Quests = {}
ns.Quests = Quests

local HARD_GAP = 2 -- une quête de niveau > niveau du joueur + 2 est trop dure : jamais proposée, ni en route (journal : en fin de liste)
local GREY_GAP = 5 -- une quête de niveau <= niveau du joueur - 5 est grise : jamais proposée à prendre
local REFRESH = 5 -- secondes entre deux relectures de la position
local UNDEAD = 16 -- bit de requiredRaces des Morts-vivants ; un masque sans ce bit est réservé à une autre race
local RANK = { turnin = 1, progress = 2, pickup = 3 } -- ordre des arrêts hors zone
local PHASE = { pickup = 1, progress = 2, turnin = 3 } -- ordre imposé pour une même quête
local CHUNK = 200 -- quêtes lues par tick pour l'index
local MAX_STOPS, MAX_PICKUPS, TWO_OPT, MAX_PINS = 12, 6, 200, 60
local POOL = 20 -- quêtes à prendre évaluées (les plus proches) avant de garder les MAX_PICKUPS de meilleur score
local MAX_ZONES, ZONE_PICKS, ZONE_CLOSE = 3, 3, 0.8 -- zones suivantes, quêtes à prendre par zone, « valeur proche » = >= 80 % de la meilleure
local NEAR_TURNIN = 1.5 -- un rendu n'ouvre la route que s'il est à moins de 1,5 x la distance de l'arrêt le plus proche
-- Valeur d'une quête (inspirée de RestedXP/Zygor) : score = (or + poids x XP convertie en or) x chaîne / minutes.
-- shortcut: constantes à la louche (Classic, à pied), à recaler sur des mesures en jeu.
local SPEED = 7 -- yards par seconde à pied
local STOP_SECS = 10 -- par prise ou rendu (dialogue)
local OBJ_SECS = 20 -- par monstre à tuer ou objet à ramasser
local OBJ_DEFAULT = 6 -- objectifs supposés quand le journal ne les donne pas (quête pas encore prise)
local FAR_YD, AWAY_YD = 200, 2000 -- trajet supposé : dans la zone sans distance lisible, sur une autre carte
local FOCUS = { gold = 0.5, balanced = 1, xp = 3 } -- poids de l'XP convertie selon ns.db.guide.focus (défaut "gold")
local CHAIN = 0.25 -- +25 % par quête débloquée (childQuests, nextQuestInChain, breadcrumbForQuestId), au plus +50 %
local GREY_PCT = { 0.8, 0.6, 0.4, 0.2, 0.1 } -- XP d'une quête grise, joueur >= niveau de quête + 6, +7, ... (règle Classic)
local DROP = 0.25 -- quête du journal à abandonner : score < DROP x meilleur score hors rendus
-- Pas de filtre de quêtes de groupe : QuestieDB n'a pas de questTag, et inGroupWith/questFlags ne le disent pas sûrement.

-- startedBy / finishedBy = { { npcIDs }, { objectIDs } } : premier PNJ.
local function firstNpc(id, key)
  local t = Q.Quest(id, key)
  local npcs = type(t) == "table" and t[1]
  local npc = type(npcs) == "table" and npcs[1]
  return type(npc) == "number" and npc or nil
end

local function str(v) return type(v) == "string" and not S.IsSecret(v) and v ~= "" and v or nil end
local function num(v) return type(v) == "number" and not S.IsSecret(v) and v or nil end
local function posLevel(v) v = num(v) return v and v > 0 and v or nil end

-- objectives = { { { npcID, nom } }, { objets }, ... } : jusqu'à 3 PNJ à tuer. shortcut: les objets ne sont pas lus.
local function objectiveNpcs(id)
  local o = Q.Quest(id, "objectives")
  local list = type(o) == "table" and type(o[1]) == "table" and o[1] or {}
  local out = {}
  for _, e in ipairs(list) do
    local n = type(e) == "table" and e[1] or e
    if type(n) == "number" then
      out[#out + 1] = n
      if #out >= 3 then break end
    end
  end
  return out
end

local function objectiveNpc(id) return objectiveNpcs(id)[1] end

-- Lieu d'un objectif non fini, sur la carte mapID : le point le plus proche du joueur (px, py) parmi les monstres à tuer
-- (objectives[1]), les objets du monde (objectives[2]) et les créatures qui lâchent l'objet (objectives[3], Q.Item npcDrops).
-- objs = C_QuestLog.GetQuestObjectives (nil : quête pas prise) ; un objectif fini (texte contenant le nom) est écarté.
-- Rend w, npc (npc nil pour un objet du monde) ; nil si rien sur cette carte.
local MAX_OBJ, MAX_DROPS = 3, 8
local function objectiveSpot(id, mapID, px, py, objs)
  local o = Q.Quest(id, "objectives")
  if type(o) ~= "table" or type(mapID) ~= "number" then return nil end
  local bw, bnpc, bd
  local function open(name)
    for _, ob in ipairs(type(objs) == "table" and objs or {}) do
      local t = type(ob) == "table" and ob.finished == true and str(ob.text)
      if t and name and t:find(name, 1, true) then return false end
    end
    return true
  end
  local function consider(w, npc)
    if not w then return end
    local d = px and ((w.x - px) ^ 2 + (w.y - py) ^ 2) or 0
    if not bd or d < bd then bw, bnpc, bd = w, npc, d end
  end
  local function each(list, f)
    local n = 0
    for _, e in ipairs(type(list) == "table" and list or {}) do
      n = n + 1
      if n > MAX_OBJ then break end
      f(type(e) == "table" and e[1] or e, type(e) == "table" and str(e[2]) or nil)
    end
  end
  each(o[1], function(npc, name)
    if type(npc) == "number" and open(name or str(Q.Npc(npc, "name"))) then consider(Q.WhereNear(npc, mapID, px, py), npc) end
  end)
  each(o[2], function(obj, name)
    if type(obj) == "number" and open(name or str(Q.Object(obj, "name"))) then consider(Q.NearestSpawn(Q.Object(obj, "spawns"), mapID, px, py)) end
  end)
  each(o[3], function(item, name)
    if type(item) ~= "number" or not open(name or str(Q.Item(item, "name"))) then return end
    local drops = Q.Item(item, "npcDrops")
    for k, npc in ipairs(type(drops) == "table" and drops or {}) do
      if k > MAX_DROPS then break end
      if type(npc) == "number" then consider(Q.WhereNear(npc, mapID, px, py), npc) end
    end
  end)
  return bw, bnpc
end

-- Quêtes du journal (hors en-têtes) : { id, title, done, ql }.
local function journal()
  local out = {}
  local n = S.Get(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
  if type(n) ~= "number" then return out end
  for i = 1, n do
    local info = S.Get(C_QuestLog.GetInfo, i)
    if type(info) == "table" and info.isHeader ~= true and type(info.questID) == "number" then
      out[#out + 1] = { id = info.questID, title = str(info.title), done = S.Get(C_QuestLog.IsComplete, info.questID) == true,
        ql = posLevel(info.level) or posLevel(Q.Quest(info.questID, "questLevel")) }
    end
  end
  return out
end

------------------------------------------------------------------------
-- Valeur : XP, or, temps
------------------------------------------------------------------------
-- shortcut: XP et argent d'une quête de niveau L, droites lissées sur des quêtes Classic (~650 XP et 3 pa au niveau 10,
-- ~5600 XP et 1 po au 60), recalées par la médiane réel/estimé des quêtes du journal ; à remplacer si une base les donne.
local function rawXP(ql) return math.max(80, 100 * ql - 350) end
local function rawMoney(ql) return 3 * ql * ql end
local calib = { xp = 1, money = 1 } -- mémoire seulement, jamais dans la base

local function greyPct(ql, level)
  local gap = level - ql - 5
  if gap < 1 then return 1 end
  return GREY_PCT[math.min(gap, #GREY_PCT)]
end

-- XP (pénalité grise comprise) et argent estimés d'une quête de niveau ql pour un joueur de niveau level, calibrés.
function Quests.Estimate(ql, level)
  return math.floor(rawXP(ql) * greyPct(ql, level) * calib.xp + 0.5), math.floor(rawMoney(ql) * calib.money + 0.5)
end
function Quests.Calib() return calib.xp, calib.money end

-- 1 XP vaut, en cuivre, ce qu'une quête du niveau du joueur paie par point d'XP : ~0,5 pc au niveau 10, ~1,9 pc au 60.
local function xpCopper(level) return rawMoney(level) / rawXP(level) end

-- Récompense réelle d'une quête du journal ; nil si l'API manque ou si la valeur est secrète.
local function realReward(id)
  return num(S.Get(GetQuestLogRewardXP, id)), num(S.Get(GetQuestLogRewardMoney, id))
end

-- QuestDB (addon tiers, lib « LibQuestDB-1.0 », optionnel, lecture seule). Donnees CMaNGOS Classic : les quetes propres a
-- Forever (ids >= 65309) n'ont aucune ligne, et un nil ne veut pas dire « sans recompense ».
local function extLib()
  local ok, lib = pcall(function() return LibStub and LibStub("LibQuestDB-1.0", true) end)
  if not (ok and type(lib) == "table") then return nil end
  local ok2, ready = pcall(lib.IsReady, lib)
  return ok2 and ready and lib or nil
end

-- { xp (au niveau actuel, pénalité grise comprise), money (signé), items, choices } ; nil si la quête n'a pas de ligne.
local function extReward(id, level)
  local lib = extLib()
  if not lib then return nil end
  local ok, r = pcall(lib.GetRewards, lib, id)
  if not ok or type(r) ~= "table" then return nil end
  local okx, xp = pcall(lib.GetQuestXP, lib, id, level)
  xp = okx and num(xp) or nil
  return { xp = xp and xp > 0 and xp or nil, money = num(r.money), items = r.items, choices = r.choices }
end

-- Valeur en cuivre d'une liste { { itemID, nombre } } : somme (fixes) ou meilleur élément (choix).
local function extItems(list, best)
  local sum = 0
  for _, it in ipairs(type(list) == "table" and list or {}) do
    local id, n = type(it) == "table" and (it[1] or it.id), type(it) == "table" and (it[2] or it.count) or 1
    local v = (Quests.ItemValue(id) or 0) * (num(n) or 1)
    sum = best and math.max(sum, v) or sum + v
  end
  return sum
end

local function median(t)
  if #t == 0 then return nil end
  table.sort(t)
  local m = math.floor((#t + 1) / 2)
  return #t % 2 == 1 and t[m] or (t[m] + t[m + 1]) / 2
end

-- Échantillons réel/estimé : quêtes apprises (niveau du joueur à la lecture) puis journal (niveau actuel, prioritaire).
-- shortcut: relu à chaque calcul (4000 quêtes au plus, ~ms) ; à mettre en cache si QuestDB grossit.
local function calibrate(list, level)
  local sx, sm = {}, {}
  QuestDB.Each(function(id, xp, l, ql, money)
    if ql then
      if xp and l and xp > 0 then sx[id] = xp / (rawXP(ql) * greyPct(ql, l)) end
      if money and money > 0 then sm[id] = money / rawMoney(ql) end
    end
  end)
  for _, j in ipairs(list) do
    if j.ql then
      local xp, money = realReward(j.id)
      local e = (not xp or not money) and extReward(j.id, level)
      if not xp and sx[j.id] == nil and e then xp = e.xp end
      if not money and sm[j.id] == nil and e then money = e.money end
      if xp and xp > 0 then sx[j.id] = xp / (rawXP(j.ql) * greyPct(j.ql, level)) end
      if money and money > 0 then sm[j.id] = money / rawMoney(j.ql) end
    end
  end
  local rx, rm = {}, {}
  for _, v in pairs(sx) do rx[#rx + 1] = v end
  for _, v in pairs(sm) do rm[#rm + 1] = v end
  local function clamp(v) return v and math.max(0.25, math.min(4, v)) or 1 end
  calib.xp, calib.money = clamp(median(rx)), clamp(median(rm))
end

-- Valeur en cuivre d'un objet (ID ou lien) : prix HdV pas trop ancien (comme Sell/Gold), sinon prix marchand ; nil si illisible.
function Quests.ItemValue(item)
  local id = type(item) == "number" and item or (type(item) == "string" and tonumber(item:match("item:(%d+)")))
  if not id then return nil end
  local p = ns.AH and ns.AH.Price(id)
  local age = p and ns.AH.Age(id)
  if p and p > 0 and not (age and ns.Sell and age > ns.Sell.OLD_DAYS) then return p end
  local r = { S.GetAll((C_Item and C_Item.GetItemInfo) or GetItemInfo, id) }
  return r[1] == "lisible" and num(r[12]) or nil
end

-- Récompense apprise (QuestDB) : XP ramenée à la pénalité grise du niveau actuel, argent, valeur des objets (fixes + meilleur choix).
local function learned(id, ql, level)
  local r = QuestDB.Get(id)
  if not r then return nil end
  local xp, q = r.xp, ql or r.ql
  if xp and q and r.level and r.level ~= level then xp = math.floor(xp * greyPct(q, level) / greyPct(q, r.level) + 0.5) end
  local items, bestChoice = 0, 0
  local fixed, choices = QuestDB.Fixed(id), QuestDB.Choices(id)
  for _, it in ipairs(fixed or {}) do items = items + (Quests.ItemValue(it[1]) or 0) * it[2] end
  for _, it in ipairs(choices or {}) do bestChoice = math.max(bestChoice, (Quests.ItemValue(it[1]) or 0) * it[2]) end
  return xp, r.money, items + bestChoice, fixed ~= nil, choices ~= nil
end

local function focusWeight()
  local g = ns.db and ns.db.guide
  return FOCUS[g and g.focus] or FOCUS.gold
end

local function chainBonus(id)
  local n = 0
  local kids = Q.Quest(id, "childQuests")
  if type(kids) == "table" then n = n + #kids end
  for _, k in ipairs({ "nextQuestInChain", "breadcrumbForQuestId" }) do -- une quête d'accroche mène à une autre
    local v = Q.Quest(id, k)
    if type(v) == "number" and v > 0 then n = n + 1 end
  end
  return 1 + math.min(0.5, CHAIN * n)
end

-- Objectifs restants (monstres + objets) d'une quête du journal ; OBJ_DEFAULT si illisibles.
local function objectivesLeft(id)
  local objs = S.Get(C_QuestLog and C_QuestLog.GetQuestObjectives, id)
  local n, seen = 0, false
  for _, o in ipairs(type(objs) == "table" and objs or {}) do
    local need = type(o) == "table" and num(o.numRequired)
    if need then
      seen = true
      if o.finished ~= true then n = n + math.max(0, need - (num(o.numFulfilled) or 0)) end
    end
  end
  return seen and n or OBJ_DEFAULT
end

-- { xp, gold, rate (cuivre/min), score, grey, far, src } ; nil si rien n'est connu (ni récompense réelle, ni niveau de quête).
-- Priorité : appris (QUEST_TURNED_IN exact, jamais écrasé, puis le reste) > journal > QuestDB tiers > estimation par niveau.
-- src = source de l'XP (sinon de l'argent) : « appris », « journal », « QuestDB », « estimé ».
local function value(id, ql, level, inLog, objs, nStops, travelYd)
  local xp, money, items, haveF, haveC = learned(id, ql, level)
  local sx, sm = xp and "appris", money and "appris"
  if inLog then
    local jx, jm = realReward(id)
    if not xp and jx then xp, sx = jx, "journal" end
    if not money and jm then money, sm = jm, "journal" end
  end
  if not (xp and money and haveF and haveC) then
    local e = extReward(id, level)
    if e then
      if not xp and e.xp then xp, sx = e.xp, "QuestDB" end
      if not money and e.money then money, sm = e.money, "QuestDB" end
      if not haveF then items = (items or 0) + extItems(e.items) end
      if not haveC then items = (items or 0) + extItems(e.choices, true) end
    end
  end
  if ql then
    local ex, em = Quests.Estimate(ql, level)
    if not xp then xp, sx = ex, "estimé" end
    if not money then money, sm = em, "estimé" end
  end
  if not (xp or money) then return nil end
  xp, money = xp or 0, money or 0
  local gold = money + (items or 0)
  local move = travelYd / SPEED
  local mins = math.max(0.5, (move + objs * OBJ_SECS + nStops * STOP_SECS) / 60)
  return { src = sx or sm, xp = xp, gold = gold, rate = gold / mins, grey = ql ~= nil and greyPct(ql, level) < 1, far = move > mins * 30,
    score = (gold + focusWeight() * xp * xpCopper(level)) * chainBonus(id) / mins }
end

-- « ≈ 650 XP · 3 pa (≈ 1 pa/min) »
local function valueText(v)
  if not v then return nil end
  local m = ns.Prof and ns.Prof.Money or tostring
  return L.QUEST_VALUE:format(math.floor(v.xp + 0.5), v.src and (" (" .. v.src .. ")") or "", m(math.floor(v.gold + 0.5)), m(math.floor(v.rate + 0.5)))
end

-- Premier objectif non fini : « 3/8 Loups tués ».
local function objectiveText(id)
  local objs = S.Get(C_QuestLog and C_QuestLog.GetQuestObjectives, id)
  for _, o in ipairs(type(objs) == "table" and objs or {}) do
    if type(o) == "table" and o.finished ~= true then
      local t = str(o.text)
      if t then return t end
      if type(o.numFulfilled) == "number" and type(o.numRequired) == "number" and not S.IsSecret(o.numFulfilled) then
        return ("%d/%d"):format(o.numFulfilled, o.numRequired)
      end
    end
  end
end

-- Position du joueur en unités de carte (0-100) ; nil si illisible.
local function playerPos(mapID)
  if type(mapID) ~= "number" then return nil end
  local p = S.Get(C_Map and C_Map.GetPlayerMapPosition, mapID, "player")
  if type(p) ~= "table" then return nil end
  local ok, x, y = pcall(p.GetXY, p)
  if ok and type(x) == "number" and type(y) == "number" and not S.IsSecret(x) and not S.IsSecret(y) then return x * 100, y * 100 end
end

-- Quêtes à prendre, par carte : { [uiMapID] = { { id, npc, x, y, req, lvl } } }. Mémoire seulement, bâti par tranches.
local byMap, building, resume

function Quests.StartIndex()
  if byMap or building or not Q.Available() or not (ns.db and ns.db.qindex) then return false end
  local ids = Q.QuestIds()
  if not ids then return false end
  building = true
  local idx, wcache, i = {}, {}, 1
  local function scan(id)
    local npc = firstNpc(id, "startedBy")
    if not npc then return end
    local races = Q.Quest(id, "requiredRaces")
    -- shortcut: masque illisible = on garde la quête ; joueur supposé Horde mort-vivant
    if type(races) == "number" and races > 0 and math.floor(races / UNDEAD) % 2 ~= 1 then return end
    if Q.Npc(npc, "friendlyToFaction") == "A" then return end
    local w = wcache[npc]
    if w == nil then w = Q.Where(npc) or false wcache[npc] = w end
    if not (w and w.uiMapID) then return end
    local req = Q.Quest(id, "requiredLevel")
    req = type(req) == "number" and req or 0
    local lvl = Q.Quest(id, "questLevel")
    lvl = type(lvl) == "number" and lvl > 0 and lvl or req
    local t = idx[w.uiMapID] or {}
    idx[w.uiMapID] = t
    t[#t + 1] = { id = id, npc = npc, x = w.x, y = w.y, req = req, lvl = lvl }
  end
  local step
  step = function()
    if InCombatLockdown() then resume = step return end
    local ok, err = pcall(function()
      local last = math.min(i + CHUNK - 1, #ids)
      for k = i, last do if type(ids[k]) == "number" then scan(ids[k]) end end
      i = last + 1
    end)
    if not ok then building = false ns.Debug("Index des quetes : %s", tostring(err)) return end
    if i <= #ids then return ns.After(0, step) end
    byMap, building = idx, false
    Quests.Refresh()
  end
  ns.After(0, step)
  return true
end

-- Prérequis connus de QuestieDB ; un état illisible (nil) n'écarte jamais la quête.
local function open(id)
  local single = Q.Quest(id, "preQuestSingle")
  if type(single) == "table" and #single > 0 then
    local any
    for _, p in ipairs(single) do if State.QuestDone(p) ~= false then any = true end end
    if not any then return false end
  end
  local group = Q.Quest(id, "preQuestGroup")
  for _, p in ipairs(type(group) == "table" and group or {}) do
    if State.QuestDone(p) == false then return false end
  end
  return true
end

-- Quêtes à prendre de la carte : { { id, npc, x, y, req, lvl, name } }, les plus proches d'abord, au plus `limit`.
-- Filtres : niveau atteint, pas grise, pas dans le journal, pas faite, prérequis.
local function pickups(mapID, level, px, py, limit, inLog)
  local out, here = {}, byMap and mapID and byMap[mapID]
  if not here then return out end
  local list = {}
  for _, e in ipairs(here) do
    if e.req <= level and e.lvl > level - GREY_GAP and e.lvl <= level + HARD_GAP and not inLog[e.id] then
      list[#list + 1] = { e = e, d = px and math.sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2) or 0 }
    end
  end
  table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.e.id < b.e.id end)
  for _, it in ipairs(list) do
    if #out >= limit then break end
    local e = it.e
    local name = str(Q.Quest(e.id, "name"))
    if name and State.QuestDone(e.id) ~= true and open(e.id) then
      out[#out + 1] = { id = e.id, npc = e.npc, x = e.x, y = e.y, req = e.req, lvl = e.lvl, name = name }
    end
  end
  return out
end

------------------------------------------------------------------------
-- Ordre : plus proche voisin puis 2-opt
------------------------------------------------------------------------
local function dist(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- Longueur du chemin joueur -> arrêts (unités de carte) ; sans position du joueur, du premier au dernier arrêt.
function Quests.PathLength(order, px, py)
  local len, x, y = 0, px, py
  for _, s in ipairs(order) do
    if x then len = len + dist(x, y, s.x, s.y) end
    x, y = s.x, s.y
  end
  return len
end

-- Une quête à prendre passe avant son objectif, qui passe avant son rendu.
local function valid(order)
  for i, s in ipairs(order) do
    for j = i + 1, #order do
      local t = order[j]
      if t.questID == s.questID and PHASE[t.kind] < PHASE[s.kind] then return false end
    end
  end
  return true
end

-- stops : { { kind, questID, x, y } } tous localisés. Rend un nouvel ordre. Le premier arrêt est le plus proche, une quête (rendue d’abord : NEAR_TURNIN)
-- à rendre d'abord ; la passe 2-opt (au plus MAX_STOPS arrêts, TWO_OPT améliorations) ne le déplace pas. plain : sans 2-opt.
function Quests.Order(stops, px, py, plain)
  local rest, out = {}, {}
  for i, s in ipairs(stops) do if i <= MAX_STOPS then rest[i] = s end end
  local x, y = px, py
  local function ready(s)
    for _, t in ipairs(rest) do
      if t ~= s and t.questID == s.questID and PHASE[t.kind] < PHASE[s.kind] then return false end
    end
    return true
  end
  local function pick(want)
    local bi, bd
    for i, s in ipairs(rest) do
      if (not want or s.kind == want) and ready(s) then
        local d = x and dist(x, y, s.x, s.y) or 0
        if not bd or d < bd then bi, bd = i, d end
      end
    end
    return bi
  end
  while #rest > 0 do
    local bi
    if #out == 0 then
      local t, a = pick("turnin"), pick()
      if t and (not x or dist(x, y, rest[t].x, rest[t].y) <= NEAR_TURNIN * dist(x, y, rest[a].x, rest[a].y)) then bi = t end
    end
    bi = bi or pick() or 1
    local s = table.remove(rest, bi)
    out[#out + 1] = s
    x, y = s.x, s.y
  end
  if plain or #out < 3 then return out end
  local best, iter, improved = Quests.PathLength(out, px, py), 0, true
  while improved and iter < TWO_OPT do
    improved = false
    for i = 2, #out - 1 do
      for j = i + 1, #out do
        local cand = {}
        for k = 1, #out do cand[k] = out[k] end
        local a, b = i, j
        while a < b do cand[a], cand[b] = cand[b], cand[a] a, b = a + 1, b - 1 end
        local len = Quests.PathLength(cand, px, py)
        if len < best - 1e-9 and valid(cand) then
          out, best, improved, iter = cand, len, true, iter + 1
          break
        end
      end
      if improved then break end
    end
  end
  return out
end

-- Carte de la zone ou se trouve le joueur : depuis une grotte, un batiment ou une instance (Dungeon, Micro, Orphan),
-- on remonte au parent, car les lieux QuestieDB sont donnes sur la carte de zone. Type illisible : la carte telle quelle.
local SUBMAP = { [4] = true, [5] = true, [6] = true }
function Quests.ZoneMap(mapID)
  for _ = 1, 5 do
    local info = type(mapID) == "number" and S.Get(C_Map and C_Map.GetMapInfo, mapID)
    local t, parent = type(info) == "table" and info.mapType, type(info) == "table" and info.parentMapID
    if not (SUBMAP[t] and type(parent) == "number" and parent > 0 and not S.IsSecret(parent)) then break end
    mapID = parent
  end
  return mapID
end

local function compute()
  local level, mapID = State.level, Quests.ZoneMap(State.mapID)
  if type(level) ~= "number" then return {} end
  local px, py = playerPos(mapID)
  local yards
  if px then
    local st, w, h = S.GetAll(C_Map.GetMapWorldSize, mapID)
    if st == "lisible" and type(w) == "number" and type(h) == "number" then yards = { w, h } end
  end
  -- w : lieu déjà choisi (objectif) ; « Repère » vise alors ce point, pas le premier spawn du PNJ
  local function stop(kind, id, name, text, npc, extra, w0)
    local s = { kind = kind, questID = id, name = name, text = text, npc = npc, extra = extra }
    local w = w0 or (npc and Q.Where(npc))
    if w then
      s.mapID, s.x, s.y, s.go = w.uiMapID, w.x, w.y, npc and "N" .. npc or nil
      if w0 then
        local base = npc and Q.Where(npc)
        if not (base and base.x == w.x and base.y == w.y) then s.go = { mapID = w.uiMapID, x = w.x, y = w.y, text = name } end
      end
      s.w = w
      s.here = mapID ~= nil and w.uiMapID == mapID
      if s.here and px then
        s.dist = dist(w.x, w.y, px, py)
        if yards then s.yards = math.sqrt(((w.x - px) * yards[1] / 100) ^ 2 + ((w.y - py) * yards[2] / 100) ^ 2) end
      end
    end
    return s
  end
  -- trajet (yards) depuis le joueur puis d'arrêt en arrêt
  local function travel(stops)
    local t, x, y = 0, px, py
    for _, s in ipairs(stops) do
      if not s.here then t = t + AWAY_YD
      elseif yards and x and s.x then
        t = t + math.sqrt(((s.x - x) * yards[1] / 100) ^ 2 + ((s.y - y) * yards[2] / 100) ^ 2)
        x, y = s.x, s.y
      else t = t + FAR_YD end
    end
    return t
  end
  local list = journal()
  calibrate(list, level)
  local inLog, units, tail, drops, high = {}, {}, {}, {}, {}
  for _, j in ipairs(list) do
    inLog[j.id] = true
    local name = j.title or str(Q.Quest(j.id, "name")) or L.QUEST_ANON
    local s
    if j.done then
      s = stop("turnin", j.id, name, L.QUEST_TURNIN:format(name), firstNpc(j.id, "finishedBy") or firstNpc(j.id, "startedBy"))
    else
      local obj = objectiveText(j.id)
      local ow, onpc = objectiveSpot(j.id, mapID, px, py, S.Get(C_QuestLog and C_QuestLog.GetQuestObjectives, j.id))
      s = stop("progress", j.id, name, obj and L.QUEST_PROGRESS:format(name, obj) or name,
        ow and onpc or (not ow and (objectiveNpc(j.id) or firstNpc(j.id, "startedBy")) or nil), nil, ow)
    end
    s.order = #units + #tail + #high + 1
    if not j.done and j.ql and j.ql > level + HARD_GAP then -- trop haute : ni arrêt, ni raison de changer de zone
      s.tooHigh, s.text = j.ql, L.QUEST_HIGH:format(name, j.ql)
      high[#high + 1] = s
    else
      s.v = value(j.id, j.ql, level, true, j.done and 0 or objectivesLeft(j.id), 1, travel({ s }))
      if s.v and not j.done and (s.here or s.v.grey) then drops[#drops + 1] = s end
      if s.here then
        units[#units + 1] = { stops = { s }, v = s.v, order = s.order }
      else
        tail[#tail + 1] = s
      end
    end
  end
  -- à prendre : avec, dans la zone, l'objectif et le rendu s'ils sont connus (même PNJ ou à côté : pickup -> progress -> turnin)
  local picks = {}
  for _, e in ipairs(pickups(mapID, level, px, py, POOL, inLog)) do
    local p = stop("pickup", e.id, e.name, L.QUEST_PICKUP:format(e.name), e.npc, e.req)
    if p.here then
      local u = { stops = { p }, order = 1000 + #units }
      local ow, onpc = objectiveSpot(e.id, mapID, px, py)
      local f = firstNpc(e.id, "finishedBy")
      local po = ow and stop("progress", e.id, e.name, e.name, onpc, nil, ow)
      local pf = f and stop("turnin", e.id, e.name, L.QUEST_TURNIN:format(e.name), f)
      if po and po.here then po.virtual = true u.stops[#u.stops + 1] = po end
      if pf and pf.here then pf.virtual = true u.stops[#u.stops + 1] = pf end
      local qo = Q.Quest(e.id, "objectives")
      -- shortcut: niveau de quête inconnu = celui du joueur
      p.v = value(e.id, e.lvl > 0 and e.lvl or level, level, false, type(qo) == "table" and next(qo) and OBJ_DEFAULT or 0, 2, travel(u.stops))
      u.v = p.v
      picks[#picks + 1] = u
    end
  end
  -- on évalue les POOL plus proches, on garde les MAX_PICKUPS de meilleur score
  table.sort(picks, function(x, y)
    local sx, sy = x.v and x.v.score or 0, y.v and y.v.score or 0
    if sx ~= sy then return sx > sy end
    return x.order < y.order
  end)
  for i = 1, math.min(MAX_PICKUPS, #picks) do units[#units + 1] = picks[i] end
  -- par score/minute ; une quête du journal sans valeur connue garde sa place en tête (ordre du journal)
  local function score(u) return u.v and u.v.score or math.huge end
  table.sort(units, function(a, b) if score(a) ~= score(b) then return score(a) > score(b) end return a.order < b.order end)
  -- à abandonner (conseil seulement) : grise, ou dans la zone et loin derrière la meilleure quête hors rendus
  local ref = 0
  for _, u in ipairs(units) do if u.v and u.stops[1].kind ~= "turnin" then ref = math.max(ref, u.v.score) end end
  local drop
  for _, s in ipairs(drops) do
    if (s.v.grey or s.v.score < DROP * ref) and (not drop or s.v.score < drop.v.score) then drop = s end
  end
  local located, n = {}, 0
  for _, u in ipairs(units) do
    if n + #u.stops <= MAX_STOPS then
      for _, s in ipairs(u.stops) do located[#located + 1] = s end
      n = n + #u.stops
    end
  end
  local route = Quests.Order(located, px, py)
  table.sort(tail, function(a, b)
    if RANK[a.kind] ~= RANK[b.kind] then return RANK[a.kind] < RANK[b.kind] end
    return a.order < b.order
  end)
  -- zones suivantes : une zone n'est retenue que si elle a une quête ou un rendu qui vaut le trajet (ni grise, ni < DROP x meilleur)
  local zones, zlist, placed = {}, {}, {}
  for _, s in ipairs(tail) do
    if s.mapID and s.mapID ~= mapID and not (s.v and (s.v.grey or s.v.score < DROP * ref)) then
      local z = zones[s.mapID]
      if not z then z = { id = s.mapID, stops = {}, value = 0 } zones[s.mapID] = z zlist[#zlist + 1] = z end
      z.stops[#z.stops + 1] = s
      z.value = z.value + (s.v and s.v.score or 1)
    end
  end
  local path = {}
  for i, p in ipairs(ns.Data.ZonePath or {}) do path[p[1]] = path[p[1]] or i end
  local at = mapID
  for _ = 1, MAX_ZONES do
    local top = 0
    for _, z in ipairs(zlist) do top = math.max(top, z.value) end
    local bi, bd -- à valeur proche, la zone voisine sur le parcours conseillé ; sinon l'ordre du journal
    for i, z in ipairs(zlist) do
      if z.value >= top * ZONE_CLOSE then
        local d = path[at] and path[z.id] and math.abs(path[at] - path[z.id]) or math.huge
        if not bd or d < bd then bi, bd = i, d end
      end
    end
    if not bi then break end
    local z = table.remove(zlist, bi)
    at = z.id
    for _, e in ipairs(pickups(z.id, level, nil, nil, ZONE_PICKS, inLog)) do
      z.stops[#z.stops + 1] = stop("pickup", e.id, e.name, L.QUEST_PICKUP:format(e.name), e.npc, e.req)
    end
    local first = z.stops[1]
    local ordered = Quests.Order(z.stops, first.x, first.y)
    ordered[1].zoneHead = true
    for _, s in ipairs(ordered) do route[#route + 1] = s placed[s] = true end
  end
  for _, s in ipairs(tail) do if not placed[s] then route[#route + 1] = s end end
  for _, s in ipairs(high) do route[#route + 1] = s end -- trop hautes : tout à la fin
  for i, s in ipairs(route) do s.n = i end
  if drop then route.drop = { questID = drop.questID, name = drop.name,
    why = drop.v.grey and "grey" or drop.v.far and "far" or "low" } end
  return route
end

local route, stamp, dirty, gen = {}, nil, true, 0

-- Itinéraire en cache : relu si un événement l'a invalidé ou après REFRESH s ; en combat, le dernier résultat.
function Quests.Route()
  if not InCombatLockdown() and (dirty or not stamp or GetTime() - stamp >= REFRESH) then
    local ok, r = pcall(compute)
    if not ok then ns.Debug("Quests : %s", tostring(r)) r = {} end
    route, stamp, dirty, gen = r, GetTime(), false, gen + 1
  end
  return route
end

local best, bestSrc

local function makeBest(r)
  local c = r[1]
  if not c or c.tooHigh then return nil end
  local parts = {}
  if #r > 1 then parts[#parts + 1] = L.QUEST_STEP:format(1, #r) end
  local zone = c.w and ns.Goto and ns.Goto.Zone(c.w)
  if zone then parts[#parts + 1] = zone end
  if c.yards then parts[#parts + 1] = L.QUEST_DIST:format(math.max(10, math.floor(c.yards / 10 + 0.5) * 10)) end
  if c.kind == "pickup" and c.extra and c.extra > 0 then parts[#parts + 1] = L.GUIDE_QLEVEL:format(c.extra) end
  parts[#parts + 1] = valueText(c.v)
  return { questID = c.questID, name = c.name, kind = c.kind, text = c.text,
    detail = #parts > 0 and table.concat(parts, " · ") or nil, go = c.go }
end

-- Quête choisie : premier arrêt de l'itinéraire.
function Quests.Best()
  local r = Quests.Route()
  if r ~= bestSrc then bestSrc, best = r, makeBest(r) end
  return best
end

-- Lignes de l'onglet « Itinéraire » : { text, sub, go, highlight } ; la valeur sur le premier arrêt de chaque quête,
-- puis la quête à abandonner s'il y en a une (conseil : l'addon n'abandonne rien).
local MARK = { pickup = "|cffffd100!|r", turnin = "|cffffd100?|r", progress = "•" }
function Quests.Rows()
  local out, seen, r = {}, {}, Quests.Route()
  for i, s in ipairs(r) do
    local subs = {}
    if s.yards then subs[1] = L.QUEST_DIST:format(math.max(10, math.floor(s.yards / 10 + 0.5) * 10)) end
    if not seen[s.questID] then subs[#subs + 1] = valueText(s.v) end
    seen[s.questID] = true
    local zone = s.zoneHead and i > 1 and s.w and ns.Goto and ns.Goto.Zone(s.w)
    if zone then out[#out + 1] = { text = L.QUEST_NEXT:format(zone), highlight = false } end
    out[#out + 1] = { text = ("%d. %s %s"):format(i, MARK[s.kind], s.text), go = s.go, highlight = i == 1,
      sub = #subs > 0 and table.concat(subs, " · ") or nil }
  end
  if r.drop then out[#out + 1] = { text = L.QUEST_DROP:format(r.drop.name, L["QUEST_DROP_" .. r.drop.why]), highlight = false } end
  return out
end

------------------------------------------------------------------------
-- Repères de la carte du monde
------------------------------------------------------------------------
local pinCache = {}

local function buildPins(mapID)
  local level = State.level
  if type(level) ~= "number" then return {} end
  local list, seen, inLog = {}, {}, {}
  local here = mapID == State.mapID
  local function add(kind, id, name, lvl, npc, x, y, n)
    local key = id .. "|" .. kind .. "|" .. tostring(npc)
    if seen[key] or #list >= MAX_PINS then return end
    seen[key] = true
    list[#list + 1] = { kind = kind, questID = id, name = name, level = lvl, mapID = mapID, x = x, y = y, npc = npc, n = n }
  end
  if here then -- arrêts de l'itinéraire d'abord : ils portent leur numéro
    for _, s in ipairs(Quests.Route()) do
      if s.here and not s.virtual then add(s.kind, s.questID, s.name, tonumber(Q.Quest(s.questID, "questLevel")), s.npc, s.x, s.y, s.n) end
    end
  end
  for _, j in ipairs(journal()) do
    inLog[j.id] = true
    local name = j.title or str(Q.Quest(j.id, "name")) or L.QUEST_ANON
    local lvl = tonumber(Q.Quest(j.id, "questLevel"))
    local npcs = j.done and { firstNpc(j.id, "finishedBy") or firstNpc(j.id, "startedBy") } or objectiveNpcs(j.id)
    for _, npc in ipairs(npcs) do
      local w = Q.Where(npc)
      if w and w.uiMapID == mapID then add(j.done and "turnin" or "progress", j.id, name, lvl, npc, w.x, w.y) end
    end
  end
  local px, py
  if here then px, py = playerPos(mapID) end
  for _, e in ipairs(pickups(mapID, level, px, py, MAX_PINS, inLog)) do add("pickup", e.id, e.name, e.lvl, e.npc, e.x, e.y) end
  return list
end

-- Repères de la carte uiMapID : { { kind, questID, name, level, mapID, x, y, npc, n } }, au plus MAX_PINS. En combat : le cache.
function Quests.Pins(mapID)
  if type(mapID) ~= "number" then return {} end
  if not InCombatLockdown() then Quests.Route() end
  local c = pinCache[mapID]
  if c and (c.gen == gen or InCombatLockdown()) then return c.list end
  if InCombatLockdown() then return {} end
  local ok, list = pcall(buildPins, mapID)
  if not ok then ns.Debug("Quests : %s", tostring(list)) list = {} end
  pinCache[mapID] = { gen = gen, list = list }
  return list
end

local lastSig = ""

local function sigOf(b, r)
  if not b then return "" end
  local ids = {}
  for i, s in ipairs(r) do ids[i] = s.questID .. s.kind end
  return b.questID .. "|" .. b.text .. "|" .. tostring(b.detail) .. "|" .. table.concat(ids, ",") .. "|" .. tostring(r.drop and r.drop.questID)
end

-- Relit et prévient l'interface (GUIDE) si le choix ou l'itinéraire a changé ; QPINS : les repères de carte sont à relire.
function Quests.Refresh()
  if InCombatLockdown() then dirty = true return end
  dirty = true
  local b = Quests.Best()
  local s = sigOf(b, route)
  local changed = s ~= lastSig
  lastSig = s
  if changed then ns.Fire("GUIDE") end
  ns.Fire("QPINS")
end

local pending
local function soon() -- QUEST_LOG_UPDATE arrive en rafale : un seul calcul
  dirty = true
  if pending then return end
  pending = true
  ns.After(0.5, function() pending = false Quests.Refresh() end)
end
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "ZONE_CHANGED_NEW_AREA", "PLAYER_LEVEL_UP" }) do ns.On(e, soon) end

ns.On("PLAYER_REGEN_ENABLED", function()
  local f = resume
  resume = nil
  if f then f() end
  if dirty then soon() end
end)

ns.Listen("QINDEX", function() Quests.StartIndex() end)
ns.On("PLAYER_LOGIN", function()
  ns.After(8, Quests.StartIndex) -- index PNJ déjà en cache d'une session précédente : pas de QINDEX
  if C_Timer and C_Timer.NewTicker then pcall(C_Timer.NewTicker, REFRESH, Quests.Refresh) end -- position
end)
