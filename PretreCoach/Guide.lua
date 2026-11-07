-- Logique du guide, sans interface : objectifs du palier (Data/Objectives.lua), paliers, onglets de référence.
-- Écoute STATE (hors combat, sinon à PLAYER_REGEN_ENABLED), réévalue, et émet GUIDE quand un objectif passe à fait
-- ou que le palier change. Rien n'est annoncé à la première évaluation ni pour un objectif déjà fait (ns.db.guide.done).
-- État d'un objectif : done=true/false ; unknown=true si l'API ne répond pas (ou check "manual") : la case se coche
-- alors à la main (ns.db.guide.manual[id]). Seuls des booléens sont enregistrés.
local _, ns = ...
local S, State, Calc, D, L = ns.S, ns.State, ns.Calc, ns.Data, ns.L

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
function CHECKS.items(o)
  local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
  local total, answered = 0, false
  for _, id in ipairs(o.arg.ids) do
    local n = S.Get(fn, id)
    if type(n) == "number" then total, answered = total + n, true end
  end
  if not answered then return nil end
  return total >= o.arg.count
end

-- check "manual" : pas d'API connue, toujours inconnu.

local function guideDB() return ns.db and ns.db.guide end

local function evalOne(o)
  local check = CHECKS[o.check]
  local r = check and check(o)
  local e = { id = o.id, text = o.text, priority = o.priority, done = r == true, unknown = false, manual = false }
  if r == nil then
    local g = guideDB()
    e.manual = true
    if g and g.manual[o.id] then e.done = true else e.unknown = true end
  end
  return e
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

local function levels(from, to)
  if from == to then return L.GUIDE_LEVEL:format(from) end
  return L.GUIDE_LEVELS:format(from, to)
end

local function inRange(level, from, to) return type(level) == "number" and level >= from and level <= to end

local REFERENCE = {}

function REFERENCE.talents(level)
  local out = {}
  local note = ns.Talents and ns.Talents.GapLine()
  if note then out[1] = { text = note, highlight = false } end
  for _, e in ipairs(D.TalentPlan) do
    local text = e.rank and L.GUIDE_POINTS:format(e.name, e.rank) or e.name
    out[#out + 1] = { text = text, sub = levels(e.from, e.to), highlight = inRange(level, e.from, e.to) }
  end
  return out
end

-- Sorts à apprendre d'abord (avec le rang), puis les autres sorts avec leur premier niveau.
function REFERENCE.spells(level)
  local out, pending = {}, {}
  for _, p in ipairs(Calc.PendingSpells(level, State.Knows) or {}) do pending[p.key] = true end
  for _, sp in ipairs(D.Spells) do
    if pending[sp.key] then
      local top
      for i, r in ipairs(sp.ranks) do if type(level) == "number" and r.level and r.level <= level then top = i end end
      out[#out + 1] = { text = L.GUIDE_RANK:format(sp.name, top), sub = levels(sp.ranks[top].level, sp.ranks[top].level), highlight = true }
    end
  end
  for _, sp in ipairs(D.Spells) do
    if not pending[sp.key] then
      local first = sp.ranks[1] and sp.ranks[1].level
      out[#out + 1] = { text = sp.name, sub = first and levels(first, first) or "", highlight = false }
    end
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
  for _, id in ipairs(ids) do
    local p = type(State.profs) == "table" and State.profs[id]
    local sub, hi
    if type(State.profs) ~= "table" then
      sub, hi = L.GUIDE_UNKNOWN, false
    elseif not p then
      sub, hi = L.GUIDE_NOT_LEARNED, true
    else
      sub, hi = ("%d/%d"):format(p.rank or 0, p.max or 0), false
      for _, t in ipairs(todo or {}) do if t.skillLine == id then hi = true end end
    end
    out[#out + 1] = { text = D.Professions[id].name, sub = sub, highlight = hi }
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
      if e.priority and not e.done then texts[#texts + 1] = "- " .. e.text end
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

-- Coche (ou décoche) à la main un objectif dont l'état est inconnu. Rend faux si l'id est inconnu ou la base absente.
function Guide.SetManual(id, value)
  local g = guideDB()
  if not g then return false end
  local known
  for _, o in ipairs(D.Objectives) do if o.id == id then known = true end end
  if not known then return false end
  g.manual[id] = value and true or nil
  update(false)
  ns.Fire("GUIDE")
  return true
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
