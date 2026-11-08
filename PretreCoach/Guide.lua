-- Logique du guide, sans interface : objectifs du palier (Data/Objectives.lua), paliers, onglets de référence.
-- Écoute STATE (hors combat, sinon à PLAYER_REGEN_ENABLED), réévalue, et émet GUIDE quand un objectif passe à fait
-- ou que le palier change. Rien n'est annoncé à la première évaluation ni pour un objectif déjà fait (ns.db.guide.done).
-- État d'un objectif : done=true/false ; unknown=true (et manual=true : masqué) si l'API ne répond pas.
local _, ns = ...
local S, State, Calc, D, L, Q = ns.S, ns.State, ns.Calc, ns.Data, ns.L, ns.Q

local Guide = {}
ns.Guide = Guide

-- Dernier niveau inclus pour un objectif dont `to` est dans le palier de Calc.Tier : 9, 19, 29 … et 60.
local function tierEnd(to)
  if to < 10 then return 9 end
  local hi = math.min(math.floor(to / 10) * 10, 50) + 10
  return hi == 60 and 60 or hi - 1
end

local function list(arg) return type(arg) == "table" and arg or { arg } end

-- Chaque check rend true / false / nil (inconnu).
local CHECKS = {}

function CHECKS.prof(o)
  local p = State.profs
  if type(p) ~= "table" then return nil end
  for _, line in ipairs(list(o.arg)) do if not p[line] then return false end end
  return true
end

function CHECKS.profRank(o)
  local p = State.profs
  if type(p) ~= "table" then return nil end
  for _, line in ipairs(list(o.arg.line)) do
    if not (p[line] and (p[line].max or 0) >= o.arg.max) then return false end
  end
  return true
end

function CHECKS.wand()
  local w = State.wand
  if w == nil then return nil end
  return w ~= false
end

-- Baguette voulue, ou une baguette au moins aussi haute (niveau requis).
function CHECKS.wandItem(o)
  local w = State.wand
  if w == nil then return nil end
  if not w then return false end
  if w.itemID == o.arg then return true end
  local need
  for _, x in ipairs(D.Wands) do if x.itemID == o.arg then need = x.level end end
  if not need or type(w.reqLevel) ~= "number" then return nil end
  return w.reqLevel >= need
end

-- L'entrée du plan portant cette key, celle dont `from` est le plus proche sans dépasser celui de l'objectif.
function CHECKS.talent(o)
  local t = State.talents
  if type(t) ~= "table" then return nil end
  local e
  for _, x in ipairs(D.TalentPlan) do
    if x.key == o.arg and x.from <= o.from and (not e or x.from > e.from) then e = x end
  end
  if not e then return nil end
  local gap, unknown = Calc.TalentGap(e.from, t, { e }, State.SpellName)
  if #unknown > 0 then return nil end
  return #gap == 0
end

function CHECKS.talentName(o)
  local r = State.TalentRankByName(o.arg)
  if r == nil then return nil end
  return r > 0
end

function CHECKS.spells()
  local p = Calc.PendingSpells(State.level, State.Knows)
  if p == nil then return nil end
  return #p == 0
end

function CHECKS.known(o)
  local k = State.Knows(o.arg)
  if k == nil then return nil end
  return k > 0
end

function CHECKS.quest(o) return State.QuestDone(o.arg) end

function CHECKS.specGroups(o)
  local g = State.specGroups
  if type(g) ~= "number" then return nil end
  return g >= o.arg
end

-- Rang de la profession >= première compétence des herbes de la zone ; zone sans herbes listées : rien à faire.
function CHECKS.herbZone(o)
  local p = State.profs
  if type(p) ~= "table" or State.mapID == nil then return nil end
  if not p[o.arg] then return false end
  for _, h in ipairs(D.Professions[o.arg].herbs or {}) do
    for _, z in ipairs(h.zones) do
      if z == State.zone then return (p[o.arg].rank or 0) >= h.from end
    end
  end
  return true
end

-- arg = { count, ids } : total des objets portés ; inconnu si aucun compte n'est lisible.
local function itemTotal(arg)
  local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
  local total, answered = 0, false
  for _, id in ipairs(arg.ids) do
    local n = S.Get(fn, id)
    if type(n) == "number" then total, answered = total + n, true end
  end
  if answered then return total end
end

function CHECKS.items(o)
  local total = itemTotal(o.arg)
  if not total then return nil end
  return total >= o.arg.count
end

local function guideDB() return ns.db and ns.db.guide end

local function evalOne(o)
  local check = CHECKS[o.check]
  local r = check and check(o)
  local e = { id = o.id, text = o.text, priority = o.priority, go = o.go, prof = o.prof, check = o.check, arg = o.arg, why = o.why, from = o.from, done = r == true, unknown = false, manual = false }
  if r == nil then
    e.manual, e.unknown = true, true -- illisible : masqué du guide (jamais de case à cocher)
  end
  return e
end

-- Quête clé (Data/KeyQuests.lua) proposable : niveau requis atteint et prérequis faits. Sans Questie, seul `after` compte ;
-- une réponse inconnue (nil) n'écarte jamais la quête.
local function questDone(id) -- sans C_QuestLog : inconnu (pas de repli Classic, absent de Forever)
  if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then return State.QuestDone(id) end
end

local function keyQuestOpen(q)
  local req = Q.Quest(q.id, "requiredLevel")
  if type(req) == "number" and State.level < req then return false end
  if q.after and questDone(q.after) == false then return false end
  local single = Q.Quest(q.id, "preQuestSingle")
  if type(single) == "table" and #single > 0 then
    local any
    for _, p in ipairs(single) do if questDone(p) ~= false then any = true end end
    if not any then return false end
  end
  local group = Q.Quest(q.id, "preQuestGroup")
  for _, p in ipairs(type(group) == "table" and group or {}) do
    if questDone(p) == false then return false end
  end
  return true
end

-- Objectifs du palier courant, rangés par priorité (1 à 3, puis le reste dans l'ordre des données).
function Guide.Evaluate()
  local level = State.level
  local out = {}
  if type(level) ~= "number" then return out end
  for i, o in ipairs(D.Objectives) do
    if level >= o.from and level <= tierEnd(o.to) then
      local e = evalOne(o)
      e.order = i
      out[#out + 1] = e
    end
  end
  for i, q in ipairs(D.KeyQuests) do
    if level >= q.from and level <= tierEnd(q.to) then
      -- shortcut: QuestDone illisible (API absente) = pas fait, la quête ne disparaît alors jamais ; à revoir si Forever perd l'API.
      local done = questDone(q.id) == true
      if done or keyQuestOpen(q) then
        local name = Q.Quest(q.id, "name")
        out[#out + 1] = {
          id = "kq" .. q.id, text = type(name) == "string" and L.GUIDE_KEYQUEST:format(name, q.why) or q.why, priority = 3,
          check = "quest", arg = q.id, go = Q.Available() and ("Q" .. q.id) or nil, done = done, unknown = false, manual = false, order = #D.Objectives + i,
        }
      end
    end
  end
  table.sort(out, function(a, b)
    local pa, pb = a.priority or 4, b.priority or 4
    if pa ~= pb then return pa < pb end
    return a.order < b.order
  end)
  return out
end

-- Premier objectif à faire (fait = false) ; à défaut, le premier inconnu ; nil s'il ne reste rien.
function Guide.Next()
  local list = Guide.Evaluate()
  for _, e in ipairs(list) do if not e.done and not e.unknown then return e end end
  for _, e in ipairs(list) do if e.unknown then return e end end
end

-- Paliers de Data/Milestones.lua : state = "passe" | "courant" | "futur" (tout futur si le niveau est illisible).
function Guide.Milestones()
  local level = State.level
  local out = {}
  for _, m in ipairs(D.Milestones) do
    local state = "futur"
    if type(level) == "number" then
      if m[2] < level then state = "passe" elseif m[1] <= level then state = "courant" end
    end
    out[#out + 1] = { from = m[1], to = m[2], text = m[3], state = state }
  end
  return out
end

-- En-tête : niveau, progression vers le 60, palier, zone (statut Calc.ZoneStatus) et prochaine zone conseillée.
function Guide.Header()
  local level = State.level
  local zone = State.zone and D.Zones[State.zone]
  local status, step = Calc.ZoneStatus(level, zone)
  local name = zone and zone[3]
  if not name and State.mapID and C_Map then
    local info = S.Get(C_Map.GetMapInfo, State.mapID)
    if type(info) == "table" and type(info.name) == "string" then name = info.name end
  end
  local nextZone = step and D.Zones[step[1]] and D.Zones[step[1]][3]
  return {
    level = level,
    progress = type(level) == "number" and math.min(level / 60, 1) or 0,
    tier = Calc.Tier(level),
    zoneName = name, zoneStatus = status, nextZone = nextZone,
  }
end

-- Premier objectif à faire (non fait, non inconnu d'abord, puis inconnu) parmi ceux qui passent `keep`.
local function firstTodo(list, keep)
  -- jamais d'objectif à cocher à la main (check "manual") dans les rangées de la carte
  for _, e in ipairs(list) do if keep(e) and not e.manual and not e.done and not e.unknown then return e end end
  for _, e in ipairs(list) do if keep(e) and not e.manual and e.unknown then return e end end
end

-- Texte et détail du repli : « Monte dans <zone> », « ta zone est verte pour toi : prochain niveau dans ~X min ».
local function xpFallback()
  local h = Guide.Header()
  local green = h.zoneStatus == "verte" and h.nextZone
  local zone = green or h.zoneName
  local text = zone and L.GUIDE_XP_ZONE:format(zone) or L.GUIDE_XP_KEEP
  local parts = { green and L.GUIDE_XP_GREEN or nil }
  local secs = ns.Pace and ns.Pace.NextLevel()
  if type(secs) == "number" and not S.IsSecret(secs) then
    local t = secs < 5400 and ("%d min"):format(math.max(1, math.floor(secs / 60 + 0.5))) or ("%d h"):format(math.floor(secs / 3600 + 0.5))
    parts[#parts + 1] = L.GUIDE_XP_NEXT:format(t)
  end
  return text, #parts > 0 and table.concat(parts, " : ") or nil
end

-- Texte précis et détail d'une entrée XP, calculés en direct : DETAIL[check](e) rend text, detail (nil = on garde e.text).
-- Une valeur illisible ou secrète n'est jamais affichée : la partie inconnue est omise.
local DETAIL = {}
local function coin(c) return ns.Training.Coin(c) end

function DETAIL.spells()
  local plan = ns.Training.Plan(State.level)
  local p = plan.pending
  if not p or #p == 0 then return end
  local names = {}
  for i = 1, math.min(#p, 4) do names[i] = p[i].text end
  local list = table.concat(names, ", ") .. (#p > 4 and ", …" or "")
  local text = #p == 1 and L.GUIDE_SPELLS_1:format(list) or L.GUIDE_SPELLS:format(#p, list)
  if plan.total then text = text .. " : " .. coin(plan.total) end
  local money = ns.Training.MoneyText(plan)
  return money and (text .. "\n" .. money) or text
end

function DETAIL.talent(e)
  for _, it in ipairs(ns.Talents.Todo(State.level)) do
    if it.entry.key == e.arg then return ns.Talents.Describe(it) end
  end
end

function DETAIL.wand(e)
  local w
  if e.check == "wandItem" then
    for _, x in ipairs(D.Wands) do if x.itemID == e.arg then w = x end end
  else
    local _, best = Calc.WandStatus(State.level, State.wand)
    w = best
  end
  if not w then return end
  local detail = w.source
  local price = ns.AH and ns.AH.Price(w.itemID)
  if type(price) == "number" and price > 0 then detail = detail .. " ; " .. L.GUIDE_AH_PRICE:format(coin(price)) end
  return L.GUIDE_WAND:format(w.name, w.level), detail
end
DETAIL.wandItem = DETAIL.wand

function DETAIL.items(e)
  local n = itemTotal(e.arg)
  if n then return L.GUIDE_ITEMS:format(n, e.arg.count, math.max(e.arg.count - n, 0)) end
  return L.GUIDE_ITEMS_BLIND:format(e.arg.count)
end

function DETAIL.known(e)
  for _, sp in ipairs(D.Spells) do
    if sp.key == e.arg and type(sp.ranks[1].level) == "number" then
      local text = L.GUIDE_KNOWN:format(sp.name, sp.ranks[1].level)
      local cost = ns.Training.Cost(sp.name, 1, sp.ranks[1].id)
      return cost and (text .. " : " .. coin(cost)) or text
    end
  end
end

-- Quête : niveau requis et donneur, tels que Questie les connaît (rien sans Questie).
function DETAIL.quest(e)
  local parts = {}
  local req = Q.Quest(e.arg, "requiredLevel")
  if type(req) == "number" and req > 0 then parts[#parts + 1] = L.GUIDE_QLEVEL:format(req) end
  local by = Q.Quest(e.arg, "startedBy")
  local npc = type(by) == "table" and type(by[1]) == "table" and by[1][1]
  local name = npc and Q.Npc(npc, "name")
  if type(name) == "string" then parts[#parts + 1] = L.GUIDE_QNPC:format(name) end
  return nil, #parts > 0 and table.concat(parts, " · ") or nil
end

local function xpText(e)
  if not e then return xpFallback() end
  local fn = DETAIL[e.check]
  local text, detail
  if fn then text, detail = fn(e) end
  return text or e.text, detail or e.why
end
Guide.Detail = xpText -- aussi pour une entrée métier (ex. bandages) : text, detail

local function unspent()
  local u = State.unspentTalents
  return type(u) == "number" and not S.IsSecret(u) and u or 0
end

-- Sort à apprendre chez le maître dès maintenant : premier rang au niveau du joueur (un talent exige un point libre).
local function knownReady(e)
  for _, sp in ipairs(D.Spells) do
    if sp.key == e.arg then
      local lv = sp.ranks[1].level
      return type(lv) == "number" and type(State.level) == "number" and lv <= State.level and (not sp.talent or unspent() > 0)
    end
  end
  return false
end

-- Baguette à équiper : dans les sacs, ou avec un prix connu à l'hôtel des ventes.
local function wandReady(e)
  local w
  if e.check == "wandItem" then
    for _, x in ipairs(D.Wands) do if x.itemID == e.arg then w = x end end
  else
    local _, best = Calc.WandStatus(State.level, State.wand)
    w = best
  end
  if not w then return false end
  local n = itemTotal({ count = 1, ids = { w.itemID } })
  if n and n >= 1 then return true end
  local price = ns.AH and ns.AH.Price(w.itemID)
  return type(price) == "number" and price > 0
end

-- Débloquable MAINTENANT (rangée XP, avant les quêtes). Les talents, sorts et sorts connus ne sont JAMAIS dans la rangée
-- tant qu'ils ne sont pas débloquables (GATED) ; les autres objectifs automatiques passent après les quêtes.
local READY = { talent = function() return unspent() > 0 end, spells = function() return true end, known = knownReady,
  wand = wandReady, wandItem = wandReady }
local GATED = { talent = true, spells = true, known = true }

-- XP : premier objectif automatique à faire ; un objectif illisible (nil) ou manuel est passé.
-- leftover = faux : seulement le débloquable maintenant ; vrai : le reste hors GATED.
local function xpPick(list, leftover)
  for _, e in ipairs(list) do
    if not e.prof and not e.manual and not e.unknown and not e.done then
      if leftover then
        if not GATED[e.check] then return e end
      elseif READY[e.check] and READY[e.check](e) then
        return e
      end
    end
  end
end

local FAR_GO = 10 -- deux reperes a plus de 10 (sur 100) l'un de l'autre, ou sur deux cartes : destinations concurrentes
local PROF_ORDER = { 182, 171, 129 } -- Herboristerie, Alchimie, Secourisme, puis les autres métiers connus

-- Objectifs affichés : XP d'abord, puis un par métier actif. Entrée : { kind, line, label, e, text }.
function Guide.Goals()
  local list = Guide.Evaluate()
  local out = {}
  -- 1. débloquable maintenant ; 2. la quête choisie par Quests ; 3. le reste des objectifs ; 4. repli de zone (xpText(nil))
  local xp, quest = xpPick(list, false), nil
  local text, detail, go
  if not xp then
    quest = ns.Quests and ns.Quests.Best()
    if quest then text, detail, go = quest.text, quest.detail, quest.go else xp = xpPick(list, true) end
  end
  if not text then text, detail = xpText(xp) end
  out[1] = { kind = "xp", label = L.GUIDE_XP, e = xp, text = text, detail = detail, go = go, quest = quest }
  local profs = State.profs
  -- Or : derniere rangee, masquable (show.gold)
  -- Une seule destination principale : si l'XP et l'Or visent deux lieux eloignes, celui qui rapporte le plus par minute
  -- (Quests.score contre Gold.perMin, meme unite) garde le Repere ; l'autre garde son texte et son `go`, avec primary = false.
  local function onePrimary(gold)
    local xpGo = out[1].go or (out[1].e and not out[1].e.done and out[1].e.go)
    local a, b = xpGo and ns.Goto.For(xpGo), gold.go and ns.Goto.For(gold.go)
    if not (ns.Goto.CanPlace(a) and ns.Goto.CanPlace(b)) then return end
    if a.mapID == b.mapID and math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) <= FAR_GO then return end
    local r = out[1].quest and ns.Quests.Route()[1]
    local xpRate = r and r.v and r.v.score
    if type(xpRate) == "number" and (gold.best.perMin or 0) > xpRate then out[1].primary = false else gold.primary = false end
  end
  local function withGold()
    if ns.Gold and not (ns.db and ns.db.show and ns.db.show.gold == false) then
      local b = ns.Gold.Best()
      local nx, frac
      if ns.Earn then nx, frac = ns.Earn.NextShort() end
      local g = { kind = "gold", label = L.GOLD_LABEL, text = b.text, detail = nx or ns.Gold.SessionText() or b.detail, frac = frac, go = b.go, best = b }
      out[#out + 1] = g
      pcall(onePrimary, g)
    end
    return out
  end
  if type(profs) ~= "table" then return withGold() end
  local lines, seen = {}, {}
  for _, id in ipairs(PROF_ORDER) do lines[#lines + 1] = id seen[id] = true end
  local rest = {}
  for id in pairs(D.Professions) do if not seen[id] then rest[#rest + 1] = id end end
  table.sort(rest)
  for _, id in ipairs(rest) do lines[#lines + 1] = id end
  local todo = Calc.ProfessionTodo(State.level, profs, D.Professions)
  for _, line in ipairs(lines) do
    if profs[line] and D.Professions[line] then
      local g = { kind = "prof", line = line, label = D.Professions[line].name }
      g.e = firstTodo(list, function(e) return e.prof == line end)
      g.text = ns.Prof and ns.Prof.StepsText(line)
      if g.text then -- plan de montee : titre + premiere action non faite
      elseif g.e then
        g.text = g.e.text
      else
        for _, t in ipairs(todo or {}) do
          if t.skillLine == line then g.text = L.PROF_RANK:format(g.label, profs[line].rank or 0, t.rank.name) end
        end
        if not g.text and D.Professions[line].herbs then g.text = L.GUIDE_HERB_GATHER
        elseif not g.text and ns.Prof then g.text = ns.Prof.Text(line) end
      end
      local st = ns.Prof and ns.Prof.Steps(line)
      if st then g.alert, g.go = (st.alert or st.learn) or nil, st.go end -- « Où aller » = maitre le plus proche, toujours ; rangee marquee si rang a prendre
      if g.text then out[#out + 1] = g end
    end
  end
  return withGold()
end

local function levels(from, to)
  if from == to then return L.GUIDE_LEVEL:format(from) end
  return L.GUIDE_LEVELS:format(from, to)
end

local function inRange(level, from, to) return type(level) == "number" and level >= from and level <= to end

local REFERENCE = {}

function REFERENCE.talents(level)
  local out, T = {}, ns.Talents
  local unspent = State.unspentTalents
  if type(unspent) == "number" and unspent > 0 then out[#out + 1] = { text = L.TALENT_UNSPENT:format(unspent), highlight = false } end
  local respec = T.Respec(level)
  local todo = T.Todo(level)
  -- Respec : étape à part tant que le talent final du palier n'est pas pris (ou si les talents sont illisibles).
  if respec and #todo > 0 then out[#out + 1] = { text = L.TALENT_RESPEC, highlight = true } end
  for i, it in ipairs(todo) do out[#out + 1] = { text = T.Describe(it), highlight = i == 1 } end
  local note = T.GapLine()
  if note then out[#out + 1] = { text = note, highlight = false } end
  local nxt = T.Upcoming(level)
  if nxt then out[#out + 1] = { text = L.TALENT_NEXT:format(nxt.name, L["TALENT_TAB_" .. nxt.tab], nxt.from), highlight = false } end
  if #out == 0 then out[1] = { text = L.TALENT_NONE, highlight = false } end
  return out
end

-- Seulement ce qui est à apprendre maintenant (avec le coût connu), puis le prochain niveau qui apporte un sort.
function REFERENCE.spells(level)
  local out, plan = {}, ns.Training.Plan(level)
  if not plan.pending then return { { text = L.GUIDE_UNKNOWN, highlight = false } } end
  for _, p in ipairs(plan.pending) do
    out[#out + 1] = { text = p.text, sub = p.cost and ns.Training.Coin(p.cost) or nil, highlight = true }
  end
  if plan.total and #plan.pending > 1 then out[#out + 1] = { text = L.TRAIN_TOTAL:format(ns.Training.Coin(plan.total)), highlight = false } end
  local money = ns.Training.MoneyText(plan)
  if money then out[#out + 1] = { text = money, highlight = false } end
  if #out == 0 then
    out[1] = { text = plan.nextLevel and L.TRAIN_NOTHING:format(plan.nextLevel) or L.TRAIN_NOTHING_END, highlight = false }
    local nx = ns.Training.NextText(plan)
    if nx then out[2] = { text = nx, highlight = false } end
  elseif plan.nextLevel then
    out[#out + 1] = { text = L.TRAIN_NEXT:format(plan.nextLevel, table.concat(plan.nextNames, ", ")), highlight = false }
    local nx = ns.Training.NextText(plan)
    if nx then out[#out + 1] = { text = nx, highlight = false } end
  end
  return out
end

-- Donjons de la tranche, puis les conseils de groupe.
function REFERENCE.dungeons(level)
  local out = {}
  for _, d in ipairs(D.Dungeons) do
    if inRange(level, d.min, d.max) then out[#out + 1] = { text = d.name, sub = levels(d.min, d.max), highlight = true } end
  end
  for _, tip in ipairs(D.DungeonTips) do out[#out + 1] = { text = tip, highlight = false } end
  return out
end

function REFERENCE.zones(level)
  local ids = {}
  for id in pairs(D.Zones) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local za, zb = D.Zones[a], D.Zones[b]
    if za[1] ~= zb[1] then return za[1] < zb[1] end
    return a < b
  end)
  local out = {}
  for _, id in ipairs(ids) do
    local z = D.Zones[id]
    out[#out + 1] = { text = z[3], sub = levels(z[1], z[2]), highlight = inRange(level, z[1], z[2]) }
  end
  return out
end

function REFERENCE.profs(level)
  local todo = Calc.ProfessionTodo(level, State.profs, D.Professions)
  local ids = {}
  for id in pairs(D.Professions) do ids[#ids + 1] = id end
  table.sort(ids)
  local out = {}
  -- « Avec tes sacs » en tete : crafts possibles avec les composants non marchands portes
  local bag = {}
  for i, e in ipairs(ns.Prof and ns.Prof.Craftable() or {}) do if i <= 5 then bag[#bag + 1] = "• " .. ns.Prof.BagText(e) end end
  if #bag > 0 then out[1] = { text = L.PROF_BAG_HEAD, sub = table.concat(bag, "\n"), highlight = true } end
  for _, id in ipairs(ids) do
    local p = type(State.profs) == "table" and State.profs[id]
    local sub, hi, alert, go
    if type(State.profs) ~= "table" then
      sub, hi = L.GUIDE_UNKNOWN, false
    elseif p then
      sub, hi = ("%d/%d"):format(p.rank or 0, p.max or 0), false
      local s = ns.Prof and ns.Prof.Steps(id)
      if s then
        -- checklist de l'etape courante : coche verte = fait, point = a faire, gris = en attente du rang
        local t = { s.alert and ("|cffff9919" .. s.title .. "|r") or s.title }
        for _, a in ipairs(s.todo) do
          local line = (a.done == true and "|cff40ff40✓|r " or "• ") .. a.text
          t[#t + 1] = a.held and ("|cff808080" .. line .. "|r") or line
        end
        sub = table.concat(t, "\n")
        alert, go = (s.alert or s.learn) or nil, s.go
      end
      -- conseil lu en direct (cout, marge) ; Herboristerie n'a pas de fenetre de recettes
      if ns.Prof and not D.Professions[id].herbs then sub = sub .. "\n" .. ns.Prof.Text(id) end
      for _, t in ipairs(todo or {}) do if t.skillLine == id then hi = true end end
    end
    -- metier non appris : pas de ligne (seuls les metiers actifs sont listes)
    if p or type(State.profs) ~= "table" then out[#out + 1] = { text = D.Professions[id].name, sub = sub, highlight = hi, alert = alert, go = go } end
  end
  return out
end

function REFERENCE.undead(level)
  local out = {}
  for _, u in ipairs(D.Undead) do
    out[#out + 1] = { text = u.text, sub = levels(u.level, u.level), highlight = type(level) == "number" and level >= u.level }
  end
  return out
end

-- tab : "talents" | "spells" | "dungeons" | "zones" | "profs" | "undead". Rend { { text, sub, highlight } }.
function Guide.Reference(tab)
  local fn = REFERENCE[tab]
  return fn and fn(State.level) or {}
end

-- Suivi de session : `was[id]` = fait / pas fait au dernier passage (absent si inconnu ou pas affiché).
local was, started, lastTier = {}, false, nil

-- announce = faux : on met le suivi à jour sans toast ni message (case cochée à la main).
local function update(announce)
  if type(State.level) ~= "number" then return end
  local g = guideDB()
  local entries = Guide.Evaluate()
  local tier = Calc.Tier(State.level)
  local changed = false
  if started and announce and tier ~= lastTier then
    changed = true
    local texts = {}
    for _, e in ipairs(entries) do
      if e.priority and not e.done and not tostring(e.id):find("^kq") then texts[#texts + 1] = "- " .. e.text end
    end
    if #texts > 0 then
      ns.Toast(L.GUIDE_TIER:format(tier) .. "\n" .. table.concat(texts, "\n"), { key = "tier:" .. tier })
    end
  end
  local now = {}
  for _, e in ipairs(entries) do
    if not e.unknown then now[e.id] = e.done end
    if e.done and not e.manual then
      if started and announce and was[e.id] == false and not (g and g.done[e.id]) then
        changed = true
        ns.Toast(L.GUIDE_DONE:format(e.text), { key = "obj:" .. e.id })
      end
      if g then g.done[e.id] = true end
    end
  end
  was, lastTier, started = now, tier, true
  if changed then ns.Fire("GUIDE") end
end

local waiting = false
ns.Listen("STATE", function()
  if InCombatLockdown() then waiting = true return end
  update(true)
end)
ns.On("PLAYER_REGEN_ENABLED", function()
  if waiting then
    waiting = false
    update(true)
  end
end)
