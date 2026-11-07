-- Quête vers laquelle aller : Quests.Best() -> { questID, name, kind, text, detail, go } ou nil. Lecture seule (Règle 0).
-- kind : "turnin" (journal, terminée : à rendre), "progress" (journal, en cours), "pickup" (disponible, connue de Questie).
-- Questie (ns.Q) donne les lieux ; sans Questie : journal seul, sans lieu. Rien n'est enregistré (cache en mémoire).
-- Choix : une quête à rendre dans la zone d'abord ; sinon la plus proche (tranches de BUCKET unités de carte), à tranche égale
-- rendre, puis en cours, puis à prendre ; ce qui est sur une autre carte ou sans lieu passe après, dans cet ordre.
local _, ns = ...
local S, L, Q, State = ns.S, ns.L, ns.Q, ns.State

local Quests = {}
ns.Quests = Quests

local GREY_GAP = 5 -- une quête de niveau <= niveau du joueur - 5 est grise : jamais proposée à prendre
local BUCKET = 10 -- « distance comparable » : tranche de 10 unités de carte (0-100)
local REFRESH = 5 -- secondes entre deux relectures de la position
local UNDEAD = 16 -- bit de requiredRaces des Morts-vivants ; un masque sans ce bit est réservé à une autre race
local RANK = { turnin = 1, progress = 2, pickup = 3 }
local CHUNK = 200 -- quêtes lues par tick pour l'index

-- startedBy / finishedBy = { { npcIDs }, { objectIDs } } : premier PNJ.
local function firstNpc(id, key)
  local t = Q.Quest(id, key)
  local npcs = type(t) == "table" and t[1]
  local npc = type(npcs) == "table" and npcs[1]
  return type(npc) == "number" and npc or nil
end

-- objectives = { { { npcID, nom } }, { objets }, ... } : premier PNJ à tuer, s'il y en a un. shortcut: les objets ne sont pas lus.
local function objectiveNpc(id)
  local o = Q.Quest(id, "objectives")
  local c = type(o) == "table" and type(o[1]) == "table" and o[1][1]
  if type(c) == "table" then c = c[1] end
  return type(c) == "number" and c or nil
end

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

-- Prérequis connus de Questie ; un état illisible (nil) n'écarte jamais la quête.
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

local function less(a, b)
  if a.group ~= b.group then return a.group < b.group end
  local ra, rb = RANK[a.kind], RANK[b.kind]
  if a.group == 0 then
    if a.dist ~= b.dist then return a.dist < b.dist end
  elseif a.group == 1 then
    local ba, bb = math.floor(a.dist / BUCKET), math.floor(b.dist / BUCKET)
    if ba ~= bb then return ba < bb end
    if ra ~= rb then return ra < rb end
    if a.dist ~= b.dist then return a.dist < b.dist end
  elseif ra ~= rb then
    return ra < rb
  end
  return a.order < b.order
end

local function compute()
  local level, mapID = State.level, State.mapID
  if type(level) ~= "number" then return nil end
  local px, py = playerPos(mapID)
  local yards
  if px then
    local st, w, h = S.GetAll(C_Map.GetMapWorldSize, mapID)
    if st == "lisible" and type(w) == "number" and type(h) == "number" then yards = { w, h } end
  end
  local cands, inLog = {}, {}
  -- group 0 : à rendre dans la zone ; 1 : le reste de la zone ; 2 : autre carte ou sans lieu
  local function add(kind, id, name, text, npc, extra)
    local c = { kind = kind, id = id, name = name, text = text, npc = npc, order = #cands + 1, group = 2, dist = 1000, extra = extra }
    local w = npc and Q.Where(npc)
    if w then
      c.w = w
      if mapID and w.uiMapID == mapID then
        c.group = (kind == "turnin") and 0 or 1
        if px then
          c.dist = math.sqrt((w.x - px) ^ 2 + (w.y - py) ^ 2)
          if yards then c.yards = math.sqrt(((w.x - px) * yards[1] / 100) ^ 2 + ((w.y - py) * yards[2] / 100) ^ 2) end
        end
      end
    end
    cands[#cands + 1] = c
    return c
  end
  for _, j in ipairs(journal()) do
    inLog[j.id] = true
    local name = j.title or str(Q.Quest(j.id, "name")) or L.QUEST_ANON
    if j.done then
      add("turnin", j.id, name, L.QUEST_TURNIN:format(name), firstNpc(j.id, "finishedBy") or firstNpc(j.id, "startedBy"))
    else
      local obj = objectiveText(j.id)
      add("progress", j.id, name, obj and L.QUEST_PROGRESS:format(name, obj) or name, objectiveNpc(j.id) or firstNpc(j.id, "startedBy"))
    end
  end
  -- à prendre : la plus proche de la zone qui passe les filtres (index prêt et lieu dans la zone seulement)
  local here = byMap and mapID and byMap[mapID]
  if here then
    local list = {}
    for _, e in ipairs(here) do
      if e.req <= level and e.lvl > level - GREY_GAP and not inLog[e.id] then
        list[#list + 1] = { e = e, d = px and math.sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2) or 0 }
      end
    end
    table.sort(list, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.e.id < b.e.id end)
    for _, it in ipairs(list) do
      local e = it.e
      local name = str(Q.Quest(e.id, "name"))
      if name and State.QuestDone(e.id) ~= true and open(e.id) then
        add("pickup", e.id, name, L.QUEST_PICKUP:format(name), e.npc, e.req)
        break
      end
    end
  end
  table.sort(cands, less)
  local c = cands[1]
  if not c then return nil end
  local parts = {}
  local zone = c.w and ns.Goto and ns.Goto.Zone(c.w)
  if zone then parts[#parts + 1] = zone end
  if c.yards then parts[#parts + 1] = L.QUEST_DIST:format(math.max(10, math.floor(c.yards / 10 + 0.5) * 10)) end
  if c.kind == "pickup" and c.extra and c.extra > 0 then parts[#parts + 1] = L.GUIDE_QLEVEL:format(c.extra) end
  return { questID = c.id, name = c.name, kind = c.kind, text = c.text,
    detail = #parts > 0 and table.concat(parts, " · ") or nil, go = c.w and ("N" .. c.npc) or nil }
end

local best, stamp, dirty = nil, nil, true

-- Résultat en cache : relu si un événement l'a invalidé ou après REFRESH s ; en combat, le dernier résultat.
function Quests.Best()
  if not InCombatLockdown() and (dirty or not stamp or GetTime() - stamp >= REFRESH) then
    local ok, r = pcall(compute)
    if not ok then ns.Debug("Quests : %s", tostring(r)) r = nil end
    best, stamp, dirty = r, GetTime(), false
  end
  return best
end

local function sig(b) return b and (b.questID .. "|" .. b.text .. "|" .. tostring(b.detail)) or "" end

-- Relit et prévient l'interface (GUIDE) si le choix a changé.
function Quests.Refresh()
  if InCombatLockdown() then dirty = true return end
  local old = sig(best)
  dirty = true
  if sig(Quests.Best()) ~= old then ns.Fire("GUIDE") end
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
