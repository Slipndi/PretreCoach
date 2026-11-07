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

local function label(e) return e.rank and L.GUIDE_POINTS:format(e.name, e.rank) or e.name end

-- Talent à prendre : le premier manquant du plan à ce niveau, sinon le premier introuvable ; talents illisibles : le
-- premier de la fenêtre.
local function nextEntry(level)
  local gap, unknown = Calc.TalentGap(level, State.talents, D.TalentPlan, State.SpellName)
  if gap and gap[1] then return gap[1].entry end
  if gap then return unknown[1] end
  for _, e in ipairs(D.TalentPlan) do
    if e.key and level >= e.from and level <= e.to then return e end
  end
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
      if e.respec and level >= e.from and level <= e.to then ns.Toast(e.name, { key = "pc:respec" }) end
    end
  end
  local unspent = State.unspentTalents
  local want
  if unspent == nil then want = up else want = unspent > 0 and (up or has(changed, "unspentTalents")) end
  if want then
    local e = nextEntry(level)
    if e then ns.Toast(L.TALENT_POINT:format(label(e)), { key = "pc:talent:" .. level .. ":" .. tostring(unspent) }) end
  elseif not gapShown and not (unspent and unspent > 0) then
    local line = Talents.GapLine()
    if line then
      gapShown = true
      ns.Toast(line, { key = "pc:talentgap" })
    end
  end
end)
