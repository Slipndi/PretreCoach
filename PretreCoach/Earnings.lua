-- Or reellement gagne : chaque variation d'argent est rangee dans une activite (marchand, HdV, quetes, butin, depenses),
-- temps actif des activites de terrain (quetes, cueillette), rendement des noeuds d'herbes mesure.
-- Lecture seulement (Regle 0). Persistant (nombres seulement) : ns.db.earn = { v, act = { [activite] = { c = cuivre, s = secondes } }, herbs, nodes }
-- et ns.db.goldGoal (cuivre). Une valeur secrete est ignoree, jamais stockee.
local _, ns = ...
local L, S, D = ns.L, ns.S, ns.Data

local Earn = {}
ns.Earn = Earn

local VERSION, MIN_NODES, MIN_SECS, MIN_NODE_SECS = 1, 15, 600, 300
local QUEST_WIN, LOOT_WIN, HERB_WIN, GAP, CAP = 2, 3, 180, 15, 1e12
local ACTS = { "quetes", "cueillette", "marchand", "hdv", "butin", "depenses", "autre" }
local KNOWN = {}
for _, a in ipairs(ACTS) do KNOWN[a] = true end

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

local function db(create) -- les lectures ne creent rien dans la base
  if not ns.db then return nil end
  local e = ns.db.earn
  if type(e) ~= "table" or e.v ~= VERSION or type(e.act) ~= "table" then
    if not create then return nil end
    e = { v = VERSION, act = {}, herbs = 0, nodes = 0 }
    ns.db.earn = e
  end
  for k in pairs(e.act) do if not KNOWN[k] then e.act[k] = nil end end -- taille bornee : activites connues seulement
  return e
end

local function slot(e, a)
  local s = e.act[a]
  if type(s) ~= "table" then s = { c = 0, s = 0 } e.act[a] = s end
  s.c, s.s = num(s.c) or 0, num(s.s) or 0
  return s
end

local ctx = { merchant = false, mail = false, ah = false, loot = false, questAt = nil, lootSeq = 0, lootEnd = nil, lastHerb = nil }
local lastMoney, lastTick, snap, pending, lastNodeSeq, questOn = nil, nil, nil, false, 0, false

local function inProgress() -- au moins une quete du journal non terminee
  local n = num((S.Get(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)))
  for i = 1, n or 0 do
    local q = S.Get(C_QuestLog.GetInfo, i)
    if type(q) == "table" and q.isHeader ~= true and type(q.questID) == "number" and S.Get(C_QuestLog.IsComplete, q.questID) ~= true then return true end
  end
  return false
end

-- Temps actif : appele par un ticker et par les evenements ; un ecart de plus de GAP s (pause, ecran de chargement) ne compte pas.
local function tick()
  local now = num(GetTime())
  if not now then return end
  local gap = lastTick and now - lastTick or 0
  lastTick = now
  local e = db(true)
  if not e then return end
  if not InCombatLockdown() then questOn = inProgress() end
  if gap <= 0 or gap > GAP then return end
  local moving = InCombatLockdown() or S.Get(IsPlayerMoving) == true
  if questOn and moving then local s = slot(e, "quetes") s.s = math.min(CAP, s.s + gap) end
  if ctx.lastHerb and now - ctx.lastHerb <= HERB_WIN then local s = slot(e, "cueillette") s.s = math.min(CAP, s.s + gap) end
end

local function onMoney()
  local m = num((S.Get(GetMoney)))
  if not m then return end -- secret ou illisible : on garde la derniere valeur lue
  local prev = lastMoney
  lastMoney = m
  local e = db(true)
  if not (prev and e) then return end
  local d, now = m - prev, num(GetTime())
  if d == 0 then return end
  tick()
  local a
  if d < 0 then a = "depenses"
  elseif ctx.merchant then a = "marchand"
  elseif ctx.mail or ctx.ah then a = "hdv"
  elseif ctx.questAt and now and now - ctx.questAt <= QUEST_WIN then a = "quetes"
  elseif ctx.loot and questOn then a = "quetes" -- or ramasse sur les monstres pendant le temps actif de quetes
  elseif ctx.loot then a = "butin" -- hors quete
  else a = "autre" end
  local s = slot(e, a)
  s.c = math.min(CAP, s.c + math.abs(d))
end

local function herbPrice(id)
  local p = ns.Gold and ns.Gold.Fresh and ns.Gold.Fresh(id)
  if p then return p end
  local r = { S.GetAll((C_Item and C_Item.GetItemInfo) or GetItemInfo, id) }  return r[1] == "lisible" and num(r[12]) or 0
end

local function scan()
  local t = {}
  for id in pairs(D.Herbs or {}) do t[id] = num((S.Get(GetItemCount, id))) or 0 end
  return t
end

-- Herbes entrees dans les sacs : comptees seulement pendant (ou juste apres) un butin, hors marchand, courrier et HdV.
local function onBag()
  if InCombatLockdown() then pending = true return end
  pending = false
  local e = db(true)
  if not e then return end
  local now = num(GetTime())
  local cur, old = scan(), snap
  snap = cur
  if not (old and now) then return end
  local gain, value = 0, 0
  for id, c in pairs(cur) do
    if c > (old[id] or 0) then gain = gain + c - old[id] value = value + (c - old[id]) * herbPrice(id) end
  end
  local looting = ctx.loot or (ctx.lootEnd and now - ctx.lootEnd <= LOOT_WIN)
  if gain <= 0 or not looting or ctx.merchant or ctx.mail or ctx.ah then return end
  e.herbs = math.min(CAP, (num(e.herbs) or 0) + gain)
  if ctx.lootSeq ~= lastNodeSeq then lastNodeSeq = ctx.lootSeq e.nodes = math.min(CAP, (num(e.nodes) or 0) + 1) end
  local s = slot(e, "cueillette")
  s.c = math.min(CAP, s.c + value)
  ctx.lastHerb = now
end

Earn.Tick = tick
ns.On("PLAYER_LOGIN", function() lastMoney = num((S.Get(GetMoney))) tick() onBag() if C_Timer and C_Timer.NewTicker then pcall(C_Timer.NewTicker, 5, tick) end end)
ns.On("PLAYER_MONEY", onMoney)
ns.On("BAG_UPDATE_DELAYED", onBag)
ns.On("PLAYER_REGEN_ENABLED", function() if pending then onBag() end end)
ns.On("MERCHANT_SHOW", function() ctx.merchant = true end)
ns.On("MERCHANT_CLOSED", function() ctx.merchant = false end)
ns.On("MAIL_SHOW", function() ctx.mail = true end)
ns.On("MAIL_CLOSED", function() ctx.mail = false end)
ns.On("AUCTION_HOUSE_SHOW", function() ctx.ah = true end)
ns.On("AUCTION_HOUSE_CLOSED", function() ctx.ah = false end)
ns.On("QUEST_TURNED_IN", function() ctx.questAt = num(GetTime()) end)
ns.On("LOOT_OPENED", function() ctx.loot, ctx.lootSeq = true, ctx.lootSeq + 1 end)
ns.On("LOOT_CLOSED", function() ctx.loot, ctx.lootEnd = false, num(GetTime()) end)

-- Rendement moyen (herbes par noeud) mesure, ou nil sous MIN_NODES noeuds.
function Earn.Yield()
  local e = db()
  local n, h = e and num(e.nodes) or 0, e and num(e.herbs) or 0
  if n >= MIN_NODES and h > 0 then return h / n end
end

-- Noeuds par heure mesures (temps de cueillette actif), ou nil sous MIN_NODES noeuds ou MIN_NODE_SECS secondes.
function Earn.NodesPerHour()
  local e = db()
  local n, s = e and num(e.nodes) or 0, e and slot(e, "cueillette").s or 0
  if n >= MIN_NODES and s >= MIN_NODE_SECS then return n / s * 3600 end
end

-- Cuivre par heure d'une activite de terrain (quetes, cueillette), ou nil sous 10 min d'echantillon.
function Earn.PerHour(a)
  local e = db()
  local s = e and KNOWN[a] and slot(e, a)
  if s and s.s >= MIN_SECS then return s.c / s.s * 3600 end
end

-- Pour un futur onglet : { { activity, label, perHour, total, secs } }, quetes et cueillette d'abord.
function Earn.Rows()
  local rows, e = {}, db()
  for _, a in ipairs(ACTS) do
    local s = e and slot(e, a)
    if s and (s.c > 0 or s.s > 0) then rows[#rows + 1] = { activity = a, label = L.EARN_ACT[a], perHour = Earn.PerHour(a), total = s.c, secs = s.s } end
  end
  return rows
end

local function money(c) return ns.Prof.Money(math.floor(c + 0.5)) end
local function duration(secs)
  if secs < 5400 then return ("%d min"):format(math.max(1, math.floor(secs / 60 + 0.5))) end
  return ("%d h"):format(math.floor(secs / 3600 + 0.5))
end

function Earn.Text()
  local q, g = Earn.PerHour("quetes"), Earn.PerHour("cueillette")
  if not (q or g) then return L.EARN_NONE end
  return L.EARN_TEXT:format(q and money(q) or "…", g and money(g) or "…")
end

-- { goal, have, missing, eta } (cuivre, cuivre, cuivre, secondes) ou nil sans objectif ; have/missing nil si l'argent est illisible,
-- eta nil sans mesure (meilleur or/h entre quetes et cueillette).
function Earn.Goal()
  local goal = ns.db and num(ns.db.goldGoal)
  if not (goal and goal > 0) then return nil end
  local have = num((S.Get(GetMoney)))
  local r = { goal = goal, have = have, missing = have and math.max(0, goal - have) or nil }
  local best = math.max(Earn.PerHour("quetes") or 0, Earn.PerHour("cueillette") or 0)
  if r.missing and r.missing == 0 then r.eta = 0 elseif r.missing and best > 0 then r.eta = r.missing / best * 3600 end
  return r
end

-- « Objectif 100 po : 23 % · ≈ 2 h » (sans duree si pas de mesure, « atteint » si fini), ou nil sans objectif.
function Earn.GoalLine()
  local g = Earn.Goal()
  if not g then return nil end
  if not g.have then return L.EARN_GOAL_LINE_NA:format(money(g.goal)) end
  local tail = g.eta == 0 and L.EARN_GOAL_DONE or g.eta and (" · ≈ " .. duration(g.eta)) or ""
  return L.EARN_GOAL_LINE:format(money(g.goal), math.min(100, math.floor(g.have / g.goal * 100)), tail)
end

-- /coach objectif <po> : fixe l'objectif ; sans nombre : l'efface.
function Earn.SetGoal(arg)
  if not ns.db then return end
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "" then ns.db.goldGoal = nil ns.Print(L.EARN_GOAL_CLEAR) return end
  local po = tonumber((arg:gsub(",", ".")))
  if not po or po <= 0 or po > 1e6 then ns.Print(L.EARN_GOAL_BAD) return end
  ns.db.goldGoal = math.floor(po * 10000)
  local g = Earn.Goal()
  local st = g and g.missing and (g.eta and L.EARN_GOAL_ETA:format(money(g.missing), g.eta == 0 and "0 min" or duration(g.eta))
    or L.EARN_GOAL_NOETA:format(money(g.missing))) or ""
  ns.Print(L.EARN_GOAL_SET, money(ns.db.goldGoal), st)
  ns.Fire("GUIDE")
end
