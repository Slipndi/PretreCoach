-- Or reellement gagne : chaque variation d'argent est rangee dans une activite (marchand, HdV, quetes, butin, depenses),
-- temps actif des activites de terrain (quetes, cueillette), rendement des noeuds d'herbes mesure.
-- Lecture seulement (Regle 0). Persistant (nombres seulement) : ns.db.earn = { v, act = { [activite] = { c = cuivre, s = secondes } }, herbs, nodes }
-- et ns.db.wealth { tier, record }. Une valeur secrete est ignoree, jamais stockee.
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

------------------------------------------------------------------------
-- Prochain achat (automatique), monture du niveau 40, paliers de fortune. Lecture seule ; seuls wealth.tier et wealth.record
-- (nombres lisibles) sont ecrits. Cout inconnu : l'achat est cite sans prix, jamais estime.
------------------------------------------------------------------------
local TIERS = { 1, 5, 10, 25, 50, 100, 250, 500, 1000 } -- po
local MOUNT_LEVEL, RECORD_SECS = 40, 600

local function nextItem()
  local st = ns.State
  local plan = ns.Training and ns.Training.Plan(st.level)
  if plan and plan.pending and #plan.pending > 0 then -- 1. sorts a apprendre maintenant
    local names = {}
    for i = 1, math.min(#plan.pending, 2) do names[i] = plan.pending[i].text end
    return { kind = "spell", what = L.EARN_WHAT_SPELLS:format(table.concat(names, ", ") .. (#plan.pending > 2 and ", …" or "")),
      cost = (plan.unknown or 0) == 0 and (plan.known or 0) > 0 and plan.known or nil }
  end
  for _, t in ipairs(ns.Calc.ProfessionTodo(st.level, st.profs, D.Professions) or {}) do -- 2. rang de metier
    local pf = D.Professions[t.skillLine]
    return { kind = "rank", what = L.EARN_WHAT_RANK:format(t.rank.name, pf and pf.name or "?"), cost = num(t.rank.cost) }
  end
  local lines = {}
  for line in pairs(D.ProfPlan or {}) do lines[#lines + 1] = line end
  table.sort(lines)
  for _, line in ipairs(lines) do -- 3. recette a acheter
    local p = type(st.profs) == "table" and st.profs[line]
    local step = p and ns.Prof.StepFor(D.ProfPlan[line], p.rank or 0)
    local b = step and step.buy
    if b and not ns.Prof.KnownRecipe(ns.Prof.Get(line), b.recipe) then
      return { kind = "recipe", what = L.EARN_WHAT_RECIPE:format(b.recipe), cost = num(b.price) }
    end
  end
  local _, best = ns.Calc.WandStatus(st.level, st.wand) -- 4. meilleure baguette
  if best then return { kind = "wand", what = L.EARN_WHAT_WAND:format(best.name), cost = ns.Gold and num(ns.Gold.Fresh(best.itemID)) } end
  if plan and plan.nextLevel and ((plan.nextTotal or 0) > 0 or (plan.nextUnknown or 0) > 0) then -- 5. sorts du prochain niveau
    return { kind = "next", what = L.EARN_WHAT_NEXT:format(plan.nextLevel),
      cost = (plan.nextUnknown or 0) == 0 and plan.nextTotal > 0 and plan.nextTotal or nil }
  end
end

-- Reste a gagner pour `cost` : { cost, have, missing, eta (s), frac, ready } ; argent ou prix inconnu : cost seul.
local function progress(cost)
  local have = num((S.Get(GetMoney)))
  local r = { cost = cost }
  if not (have and cost) then return r end
  r.have, r.missing, r.frac = have, math.max(0, cost - have), math.min(1, have / cost)
  r.ready = r.missing == 0
  local best = math.max(Earn.PerHour("quetes") or 0, Earn.PerHour("cueillette") or 0)
  if r.ready then r.eta = 0 elseif best > 0 then r.eta = r.missing / best * 3600 end
  return r
end

-- { kind, what, cost, have, missing, eta, frac, ready } ou nil s'il n'y a rien a acheter.
function Earn.Next()
  local it = nextItem()
  if not it then return nil end
  for k, v in pairs(progress(it.cost)) do it[k] = v end
  return it
end

local function priced(what, cost) return cost and (what .. " (" .. money(cost) .. ")") or what end

-- « ✓ prêt, va l'acheter » ou « Tu as X, il te manque Y · ≈ 30 min à ton rythme » ; nil si prix ou argent inconnu.
local function detail(r)
  if r.ready then return L.EARN_NEXT_READY end
  if not r.have then return nil end
  return L.RICH_HAVE:format(money(r.have), money(r.missing)) .. (r.eta and L.EARN_NEXT_ETA:format(duration(r.eta)) or "")
end

-- Onglet : (texte, detail).
function Earn.NextText()
  local r = Earn.Next()
  if not r then return L.RICH_NONEXT end
  return L.EARN_NEXT:format(priced(r.what, r.cost)), detail(r)
end

-- Carte : une ligne courte, et la fraction (0-1) pour la barre (nil si prix ou argent inconnu).
function Earn.NextShort()
  local r = Earn.Next()
  if not r then return nil end
  local s = L.EARN_NEXT:format(priced(r.what, r.cost))
  if r.ready then return s .. " · " .. L.EARN_NEXT_READY, 1 end
  return s .. (r.missing and (" · " .. L.EARN_NEXT_MISS:format(money(r.missing))) or ""), r.frac
end

-- Monture : cout de la competence de monte lu chez un maitre deja visite (ns.db.trainer), la moins elevee puis la moins chere.
-- What's Training n'a pas la monte (catalogue de sorts de classe et d'armes seulement) : pas d'autre source. nil si illisible.
function Earn.Mount()
  local best
  for k, v in pairs((ns.db and ns.db.trainer) or {}) do
    local name = k:match("^(.*)|")
    local low = type(name) == "string" and name:lower()
    local cost = type(v) == "table" and num(v.cost)
    if low and cost and cost > 0 and v.category ~= "used" and (low:find("cavalier", 1, true) or low:find("riding", 1, true) or low:find("quitation", 1, true)) then
      local lv = num(v.level) or 999
      if not best or lv < best.lv or (lv == best.lv and cost < best.cost) then best = { name = name, cost = cost, lv = lv } end
    end
  end
  if not best then return nil end
  local r = progress(best.cost)
  r.name = best.name
  return r
end

-- (texte, detail) ou nil si le prix n'est pas lisible.
function Earn.MountText()
  local m = Earn.Mount()
  if not m then return nil end
  local d = m.missing and (m.ready and L.EARN_MOUNT_OK or L.EARN_MOUNT_MISS:format(MOUNT_LEVEL, money(m.missing))) or nil
  return L.EARN_MOUNT:format(MOUNT_LEVEL, m.name, money(m.cost)), d
end

-- Palier de fortune franchi (une annonce par palier et par personnage) et record or/heure de session ; hors combat, argent lisible.
local function track()
  if InCombatLockdown() or not ns.db then return end
  local m = num((S.Get(GetMoney)))
  if not m then return end
  local w = ns.db.wealth
  if type(w) ~= "table" then w = {} ns.db.wealth = w end
  local top = 0
  for i, po in ipairs(TIERS) do if m >= po * 10000 then top = i end end
  local last = num(w.tier)
  if not last then w.tier = top -- premiere lecture : on retient sans annoncer
  elseif top > last then
    w.tier = top
    ns.Toast(L.EARN_TIER:format(TIERS[top]), { key = "pc:wealth:" .. top })
  end
  if ns.Gold then
    local net, rate, dt = ns.Gold.Session()
    if net and rate and rate > 0 and dt and dt >= RECORD_SECS and rate > (num(w.record) or 0) then w.record = math.floor(rate) end
  end
end
Earn.Track = track
ns.On("PLAYER_MONEY", track)
ns.On("PLAYER_LOGIN", function() if ns.db then ns.db.goldGoal = nil end track() end) -- ancien objectif manuel : supprime
ns.On("PLAYER_REGEN_ENABLED", track)

-- « Record : ≈ X/h » ou nil.
function Earn.RecordText()
  local r = ns.db and type(ns.db.wealth) == "table" and num(ns.db.wealth.record)
  return r and r > 0 and L.EARN_RECORD:format(money(r)) or nil
end
