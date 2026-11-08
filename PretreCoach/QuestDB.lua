-- Base de récompenses de quêtes apprise en jeu (aucune base en ligne ne donne XP, or et objets de Forever) : ns.QuestDB.
-- Lecture seule (Règle 0) : on note les valeurs que le jeu donne (fenêtres de quête, journal, QUEST_TURNED_IN), jamais d'action.
-- Stockage (ns.db.qrewards, clé de format v = 1) : { v, n = nb de quêtes, seq = compteur de récence, q = { [questID] = e } }
-- avec e = { x = XP, m = cuivre, l = niveau du joueur à la lecture de x, q = niveau de quête, f = "itemID:nb;..." fixes,
-- c = "itemID:nb;..." au choix, t = récence, e = 1 si valeurs exactes reçues à QUEST_TURNED_IN (jamais écrasées ensuite) }.
-- Une valeur secrète est ignorée, jamais stockée. Rien en combat.
local _, ns = ...
local S, Q = ns.S, ns.Q

local QuestDB = {}
ns.QuestDB = QuestDB

local VERSION, MAX_ITEMS = 1, 10
QuestDB.MAX = 4000 -- quêtes gardées ; au-delà, les plus anciennes partent (par dixième)

local function num(v) return type(v) == "number" and not S.IsSecret(v) and v or nil end

-- shortcut: un format de version différente est remplacé sans migration ; à migrer si la base devient précieuse.
local function store(create)
  local r = ns.db and ns.db.qrewards
  if type(r) == "table" and r.v == VERSION and type(r.q) == "table" then return r end
  if not create or not ns.db then return nil end
  r = { v = VERSION, n = 0, seq = 0, q = {} }
  ns.db.qrewards = r
  return r
end

local function playerLevel()
  return num(ns.State and ns.State.level) or num(S.Get(UnitLevel, "player")) or 0
end

local function evict(r)
  local ids = {}
  for id in pairs(r.q) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b) return r.q[a].t < r.q[b].t end)
  for i = 1, math.min(#ids, r.n - QuestDB.MAX + math.max(1, math.floor(QuestDB.MAX / 10))) do
    r.q[ids[i]] = nil
    r.n = r.n - 1
  end
end

-- f = { xp, money, zeroMoney (0 cuivre est une vraie valeur), fixed, choices, ql, exact } ; chaque champ déjà lu sans secret.
local function learn(id, f)
  id = num(id)
  if not id or id <= 0 then return end
  local r = store(true)
  if not r then return end
  local e = r.q[id]
  if not e then
    e = {}
    r.q[id] = e
    r.n = r.n + 1
  end
  r.seq = r.seq + 1
  e.t = r.seq
  local open = f.exact or not e.e
  if open and f.xp and f.xp > 0 then
    e.x, e.l = f.xp, playerLevel()
    if f.exact then e.e = 1 end
  end
  if open and f.money and (f.money > 0 or f.zeroMoney) then e.m = f.money end
  if f.fixed then e.f = f.fixed end
  if f.choices then e.c = f.choices end
  if f.ql then e.q = f.ql end
  if r.n > QuestDB.MAX then evict(r) end
end
QuestDB.Learn = learn

-- "itemID:nb;itemID:nb" des récompenses "reward" ou "choice" de la fenêtre ouverte ; "" = aucune ; nil = illisible.
local function items(kind)
  local n = S.Get(kind == "choice" and GetNumQuestChoices or GetNumQuestRewards)
  if not num(n) then return nil end
  local out = {}
  for i = 1, math.min(n, MAX_ITEMS) do
    local link = S.Get(GetQuestItemLink, kind, i)
    local id = type(link) == "string" and not S.IsSecret(link) and tonumber(link:match("item:(%d+)"))
    if not id then return nil end -- objet pas encore chargé : on ne note pas une liste tronquée
    local st, _, _, count = S.GetAll(GetQuestItemInfo, kind, i)
    out[#out + 1] = id .. ":" .. (st == "lisible" and type(count) == "number" and count > 0 and count or 1)
  end
  return table.concat(out, ";")
end

local function levelOf(id)
  local ql = Q and Q.Quest and Q.Quest(id, "questLevel")
  return type(ql) == "number" and ql > 0 and ql or nil
end

-- Fenêtre de quête ouverte (QUEST_DETAIL, QUEST_COMPLETE).
local function window()
  if InCombatLockdown() then return end
  local id = num(S.Get(GetQuestID))
  if not id or id <= 0 then return end
  local money = num(S.Get(GetRewardMoney))
  learn(id, { xp = num(S.Get(GetRewardXP)), money = money, zeroMoney = money ~= nil,
    fixed = items("reward"), choices = items("choice"), ql = levelOf(id) })
end

-- Journal : XP et argent de chaque quête (le jeu les recalcule selon le niveau du joueur).
local function log()
  if InCombatLockdown() then return end
  local n = S.Get(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
  if not num(n) then return end
  for i = 1, n do
    local info = S.Get(C_QuestLog.GetInfo, i)
    local id = type(info) == "table" and info.isHeader ~= true and num(info.questID)
    if id then
      local xp, money = num(S.Get(GetQuestLogRewardXP, id)), num(S.Get(GetQuestLogRewardMoney, id))
      local ql = num(info.level)
      if xp or money then learn(id, { xp = xp, money = money, ql = ql and ql > 0 and ql or levelOf(id) }) end
    end
  end
end

local pending
ns.On("QUEST_LOG_UPDATE", function() -- en rafale : une lecture
  if pending then return end
  pending = true
  ns.After(1, function() pending = false pcall(log) end)
end)
ns.On("QUEST_DETAIL", function() pcall(window) end)
ns.On("QUEST_COMPLETE", function() pcall(window) end)
-- valeurs exactes reçues, prioritaires
ns.On("QUEST_TURNED_IN", function(_, id, xp, money)
  xp, money = num(xp), num(money)
  if xp or money then learn(id, { xp = xp, money = money, zeroMoney = money ~= nil, exact = true }) end
end)

-- { xp, money, level, ql, exact } d'une quête apprise (champs nil = pas notés) ; nil si inconnue.
function QuestDB.Get(id)
  local r = store(false)
  local e = r and r.q[id]
  if not e then return nil end
  return { xp = e.x, money = e.m, level = e.l, ql = e.q, exact = e.e == 1 }
end

local function decode(s)
  local out = {}
  for item, count in (s or ""):gmatch("(%d+):(%d+)") do out[#out + 1] = { tonumber(item), tonumber(count) } end
  return out
end
-- Objets au choix / fixes appris : { { itemID, nombre } } ; nil si pas encore vus.
function QuestDB.Choices(id) local r = store(false) local e = r and r.q[id] return e and e.c and decode(e.c) or nil end
function QuestDB.Fixed(id) local r = store(false) local e = r and r.q[id] return e and e.f and decode(e.f) or nil end

-- fn(id, xp, level, ql, money) pour chaque quête apprise.
function QuestDB.Each(fn)
  local r = store(false)
  for id, e in pairs(r and r.q or {}) do fn(id, e.x, e.l, e.q, e.m) end
end

-- Nombre de quêtes apprises, dont avec XP.
function QuestDB.Stats()
  local r = store(false)
  local withXP = 0
  for _, e in pairs(r and r.q or {}) do if e.x then withXP = withXP + 1 end end
  return r and r.n or 0, withXP
end
