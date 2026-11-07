-- Talents (spec 6.2) : dès le niveau 10, toast « Ton point de talent : X » d'après Data.TalentPlan, rappel du respec Ombre
-- au 40, et une ligne discrète (guide, onglet Talents) si le plan n'est pas suivi ; un seul toast à ce sujet par session.
-- Réagit au STATE (niveau, points non dépensés, talents), donc après la mise à jour de State.
local _, ns = ...
local L, State, Calc, D = ns.L, ns.State, ns.Calc, ns.Data

local Talents = {}
ns.Talents = Talents

local MIN_LEVEL = 10
local lastLevel, gapShown

local function has(changed, ...)
  for _, k in ipairs(changed or {}) do
    for i = 1, select("#", ...) do if k == select(i, ...) then return true end end
  end
  return false
end

-- Ligne « plan non suivi » (texte), nil si le plan est suivi ou si les talents sont illisibles.
function Talents.GapLine()
  local gap = Calc.TalentGap(State.level, State.talents, D.TalentPlan, State.SpellName)
  if not gap or #gap == 0 then return nil end
  return L.TALENT_GAP:format(gap[1].entry.name)
end

-- Talents à faire à ce niveau : { entry, have, want } ; have = nil si les talents sont illisibles ou le talent introuvable
-- (aucune progression inventée). Respecs exclus (entrées sans arbre).
function Talents.Todo(level)
  local out = {}
  if type(level) ~= "number" then return out end
  local gap, unknown = Calc.TalentGap(level, State.talents, D.TalentPlan, State.SpellName)
  if gap then
    for _, g in ipairs(gap) do out[#out + 1] = g end
    for _, e in ipairs(unknown) do out[#out + 1] = { entry = e, want = e.rank } end
  else
    for _, e in ipairs(D.TalentPlan) do
      if e.tab and level >= e.from and level <= e.to then out[#out + 1] = { entry = e, want = e.rank } end
    end
  end
  return out
end

-- « Ombre, rangée 1 : Connexion spirituelle (2/5 → 3/5) » ; sans lecture : « (objectif 5/5) ».
function Talents.Describe(it)
  local e = it.entry
  local tab = L["TALENT_TAB_" .. e.tab]
  if it.have then return L.TALENT_LINE:format(tab, e.row, e.name, it.have, it.want, it.have + 1, it.want) end
  return L.TALENT_LINE_BLIND:format(tab, e.row, e.name, it.want, it.want)
end

-- Entrée de respec dont la fenêtre contient le niveau.
function Talents.Respec(level)
  if type(level) ~= "number" then return nil end
  for _, e in ipairs(D.TalentPlan) do
    if e.respec and level >= e.from and level <= e.to then return e end
  end
end

-- Prochain talent du plan au-delà du niveau (le plus proche), nil s'il n'y en a plus.
function Talents.Upcoming(level)
  if type(level) ~= "number" then return nil end
  local best
  for _, e in ipairs(D.TalentPlan) do
    if e.tab and e.from > level and (not best or e.from < best.from) then best = e end
  end
  return best
end

ns.Listen("STATE", function(_, changed)
  if not has(changed, "level", "unspentTalents", "talents") then return end
  local level = State.level
  if type(level) ~= "number" then return end
  local up = lastLevel ~= nil and level > lastLevel
  lastLevel = level
  if level < MIN_LEVEL then return end
  if up then
    for _, e in ipairs(D.TalentPlan) do
      if e.respec and level >= e.from and level <= e.to then ns.Toast(L.TALENT_RESPEC, { key = "pc:respec" }) end
    end
  end
  local unspent = State.unspentTalents
  local want
  if unspent == nil then want = up else want = unspent > 0 and (up or has(changed, "unspentTalents")) end
  if want then
    local it = Talents.Todo(level)[1]
    if it then
      local text = L.TALENT_POINT:format(Talents.Describe(it))
      if unspent and unspent > 0 then text = text .. "\n" .. L.TALENT_UNSPENT:format(unspent) end
      ns.Toast(text, { key = "pc:talent:" .. level .. ":" .. tostring(unspent) })
    end
  elseif not gapShown and not (unspent and unspent > 0) then
    local line = Talents.GapLine()
    if line then
      gapShown = true
      ns.Toast(line, { key = "pc:talentgap" })
    end
  end
end)
