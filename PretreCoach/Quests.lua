-- Itinéraire des quêtes de la zone : Quests.Route() -> { { kind, questID, name, mapID, x, y, text, ... } } et Quests.Best() = premier arrêt.
-- Lecture seule (Règle 0). kind : "turnin" (journal, terminée : à rendre), "progress" (journal, en cours), "pickup" (disponible, connue de QuestieDB).
-- QuestieDB (ns.Q) donne les lieux ; sans lui : journal seul, sans lieu. Rien n'est enregistré (cache en mémoire).
-- Ordre : plus proche voisin depuis le joueur (une quête à rendre dans la zone d'abord), puis 2-opt borné ; une quête à prendre
-- passe toujours avant son objectif puis son rendu. Ce qui est sur une autre carte ou sans lieu passe après (rendre, en cours, prendre).
-- Quests.Pins(uiMapID) : repères à dessiner sur la carte du monde (UI/QuestPins.lua).
local _, ns = ...
local S, L, Q, State = ns.S, ns.L, ns.Q, ns.State

local Quests = {}
ns.Quests = Quests

local GREY_GAP = 5 -- une quête de niveau <= niveau du joueur - 5 est grise : jamais proposée à prendre
local REFRESH = 5 -- secondes entre deux relectures de la position
local UNDEAD = 16 -- bit de requiredRaces des Morts-vivants ; un masque sans ce bit est réservé à une autre race
local RANK = { turnin = 1, progress = 2, pickup = 3 } -- ordre des arrêts hors zone
local PHASE = { pickup = 1, progress = 2, turnin = 3 } -- ordre imposé pour une même quête
local CHUNK = 200 -- quêtes lues par tick pour l'index
local MAX_STOPS, MAX_PICKUPS, TWO_OPT, MAX_PINS = 12, 6, 200, 60
-- Étiquettes Blizzard de quêtes de groupe, donjon ou raid (QuestTagType) : écartées à prendre quand le joueur est seul.
-- shortcut: la clé Questie "questTag" n'est pas confirmée en jeu ; absente, rien n'est écarté.
local GROUP_TAGS = { [1] = true, [62] = true, [81] = true, [85] = true, [88] = true, [89] = true }

-- startedBy / finishedBy = { { npcIDs }, { objectIDs } } : premier PNJ.
local function firstNpc(id, key)
  local t = Q.Quest(id, key)
  local npcs = type(t) == "table" and t[1]
  local npc = type(npcs) == "table" and npcs[1]
  return type(npc) == "number" and npc or nil
end

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

local function str(v) return type(v) == "string" and not S.IsSecret(v) and v ~= "" and v or nil end

-- Quêtes du journal (hors en-têtes) : { id, title, done }.
local function journal()
  local out = {}
  local n = S.Get(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
  if type(n) ~= "number" then return out end
  for i = 1, n do
    local info = S.Get(C_QuestLog.GetInfo, i)
    if type(info) == "table" and info.isHeader ~= true and type(info.questID) == "number" then
      out[#out + 1] = { id = info.questID, title = str(info.title), done = S.Get(C_QuestLog.IsComplete, info.questID) == true }
    end
  end
  return out
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

local function grouped()
  local ok, v = pcall(function() return IsInGroup and IsInGroup() end)
  return ok and v == true
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
-- Filtres : niveau atteint, pas grise, pas dans le journal, pas faite, prérequis, pas de groupe/donjon si seul.
local function pickups(mapID, level, px, py, limit, inLog)
  local out, here = {}, byMap and mapID and byMap[mapID]
  if not here then return out end
  local list, solo = {}, not grouped()
  for _, e in ipairs(here) do
    if e.req <= level and e.lvl > level - GREY_GAP and not inLog[e.id] then
      list[#list + 1] = { e = e, d = px and math.sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2) or 0 }
    end
  end
  table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.e.id < b.e.id end)
  for _, it in ipairs(list) do
    if #out >= limit then break end
    local e = it.e
    local name = str(Q.Quest(e.id, "name"))
    local tag = Q.Quest(e.id, "questTag")
    if name and not (solo and GROUP_TAGS[tag]) and State.QuestDone(e.id) ~= true and open(e.id) then
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

-- stops : { { kind, questID, x, y } } tous localisés. Rend un nouvel ordre. Le premier arrêt est le plus proche, une quête
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
    local bi = (#out == 0 and pick("turnin")) or pick() or 1
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

-- Valeur d'une quête : XP de récompense si QuestieDB l'expose ("rewardXP"), sinon niveau de quête proche du joueur.
local function bonus(id, level)
  local xp = Q.Quest(id, "rewardXP")
  if type(xp) == "number" and xp > 0 then return math.min(20, xp / 50) end
  local ql = Q.Quest(id, "questLevel")
  if type(ql) == "number" and ql > 0 then return math.max(0, 10 - math.abs(ql - level)) end
  return 0
end

local function compute()
  local level, mapID = State.level, State.mapID
  if type(level) ~= "number" then return {} end
  local px, py = playerPos(mapID)
  local yards
  if px then
    local st, w, h = S.GetAll(C_Map.GetMapWorldSize, mapID)
    if st == "lisible" and type(w) == "number" and type(h) == "number" then yards = { w, h } end
  end
  local function stop(kind, id, name, text, npc, extra)
    local s = { kind = kind, questID = id, name = name, text = text, npc = npc, extra = extra }
    local w = npc and Q.Where(npc)
    if w then
      s.mapID, s.x, s.y, s.go = w.uiMapID, w.x, w.y, "N" .. npc
      s.w = w
      s.here = mapID ~= nil and w.uiMapID == mapID
      if s.here and px then
        s.dist = dist(w.x, w.y, px, py)
        if yards then s.yards = math.sqrt(((w.x - px) * yards[1] / 100) ^ 2 + ((w.y - py) * yards[2] / 100) ^ 2) end
      end
    end
    return s
  end
  local inLog, units, tail = {}, {}, {}
  for _, j in ipairs(journal()) do
    inLog[j.id] = true
    local name = j.title or str(Q.Quest(j.id, "name")) or L.QUEST_ANON
    local s
    if j.done then
      s = stop("turnin", j.id, name, L.QUEST_TURNIN:format(name), firstNpc(j.id, "finishedBy") or firstNpc(j.id, "startedBy"))
    else
      local obj = objectiveText(j.id)
      s = stop("progress", j.id, name, obj and L.QUEST_PROGRESS:format(name, obj) or name, objectiveNpc(j.id) or firstNpc(j.id, "startedBy"))
    end
    s.order = #units + #tail + 1
    if s.here then
      units[#units + 1] = { stops = { s }, value = (j.done and 100 or 50) + bonus(j.id, level), order = s.order }
    else
      tail[#tail + 1] = s
    end
  end
  -- à prendre : avec, dans la zone, l'objectif et le rendu s'ils sont connus (même PNJ ou à côté : pickup -> progress -> turnin)
  for _, e in ipairs(pickups(mapID, level, px, py, MAX_PICKUPS, inLog)) do
    local p = stop("pickup", e.id, e.name, L.QUEST_PICKUP:format(e.name), e.npc, e.req)
    if p.here then
      local u = { stops = { p }, value = bonus(e.id, level), order = 1000 + #units }
      local o = objectiveNpc(e.id)
      local f = firstNpc(e.id, "finishedBy")
      local po = o and stop("progress", e.id, e.name, e.name, o)
      local pf = f and stop("turnin", e.id, e.name, L.QUEST_TURNIN:format(e.name), f)
      if po and po.here then po.virtual = true u.stops[#u.stops + 1] = po end
      if pf and pf.here then pf.virtual = true u.stops[#u.stops + 1] = pf end
      units[#units + 1] = u
    end
  end
  table.sort(units, function(a, b) if a.value ~= b.value then return a.value > b.value end return a.order < b.order end)
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
  for _, s in ipairs(tail) do route[#route + 1] = s end
  for i, s in ipairs(route) do s.n = i end
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
  if not c then return nil end
  local parts = {}
  if #r > 1 then parts[#parts + 1] = L.QUEST_STEP:format(1, #r) end
  local zone = c.w and ns.Goto and ns.Goto.Zone(c.w)
  if zone then parts[#parts + 1] = zone end
  if c.yards then parts[#parts + 1] = L.QUEST_DIST:format(math.max(10, math.floor(c.yards / 10 + 0.5) * 10)) end
  if c.kind == "pickup" and c.extra and c.extra > 0 then parts[#parts + 1] = L.GUIDE_QLEVEL:format(c.extra) end
  return { questID = c.questID, name = c.name, kind = c.kind, text = c.text,
    detail = #parts > 0 and table.concat(parts, " · ") or nil, go = c.go }
end

-- Quête choisie : premier arrêt de l'itinéraire.
function Quests.Best()
  local r = Quests.Route()
  if r ~= bestSrc then bestSrc, best = r, makeBest(r) end
  return best
end

-- Lignes de l'onglet « Itinéraire » : { text, sub, go, highlight }.
local MARK = { pickup = "|cffffd100!|r", turnin = "|cffffd100?|r", progress = "•" }
function Quests.Rows()
  local out = {}
  for i, s in ipairs(Quests.Route()) do
    out[i] = { text = ("%d. %s %s"):format(i, MARK[s.kind], s.text), go = s.go, highlight = i == 1,
      sub = s.yards and L.QUEST_DIST:format(math.max(10, math.floor(s.yards / 10 + 0.5) * 10)) or nil }
  end
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
  return b.questID .. "|" .. b.text .. "|" .. tostring(b.detail) .. "|" .. table.concat(ids, ",")
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
