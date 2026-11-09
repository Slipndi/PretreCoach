-- Coach de soin (cadres de soin) : conseil en texte seulement, a partir de ce que le joueur a lance lui-meme.
-- En combat, vie, mana et recharges sont secrets sur Forever (sonde du 2026-11-09) : aucun conseil ne repose sur la vie,
-- le joueur lit les barres. Suivi : clic sur un cadre (unite + sort du bouton de souris) puis UNIT_SPELLCAST_SUCCEEDED du
-- meme sort dans les 3 s -> Renovation (duree du sort) et Ame affaiblie (15 s apres un Bouclier) sur cette unite.
-- Tank : role TANK (UnitGroupRolesAssigned), sinon le premier guerrier du groupe.
local _, ns = ...
local S, L = ns.S, ns.L

local HC = {}
ns.HealCoach = HC

local WEAK = 15 -- Ame affaiblie (s)
local CLICK_TTL = 3

local keyOf, spellByKey = {}, {}
for _, sp in ipairs(ns.Data.Spells) do
  spellByKey[sp.key] = sp
  for _, r in ipairs(sp.ranks) do keyOf[r.id] = sp.key end
end

local track, pending = {}, nil -- track : id d'unite -> { renew = fin, weak = fin }

local function idOf(u)
  local g = S.Get(UnitGUID, u)
  return type(g) == "string" and g or u -- GUID secret ou absent : le jeton d'unite
end

local function known(k)
  local r = ns.State.Knows(k)
  return type(r) == "number" and r > 0
end

local function spellName(k)
  local H = ns.UI and ns.UI.HealFrames
  return H and H.SpellName(k) or (spellByKey[k] and spellByKey[k].name) or k
end

local function unitName(u)
  local n = S.Get(UnitName, u)
  return type(n) == "string" and n or nil
end

-- Appele par le cadre (PostClick, non securise) : le sort que ce bouton de souris va lancer sur cette unite.
function HC.Clicked(unit, key) pending = { unit = unit, key = key, t = GetTime() } end

function HC.Cast(spellID)
  local key = type(spellID) == "number" and not S.IsSecret(spellID) and keyOf[spellID]
  local p = pending
  if not key or not p or p.key ~= key or GetTime() - p.t > CLICK_TTL then return end
  pending = nil
  local id, now = idOf(p.unit), GetTime()
  local e = track[id] or {}
  track[id] = e
  if key == "RENEW" then e.renew = now + (spellByKey.RENEW.duration or 15)
  elseif key == "PWS" then e.weak = now + WEAK end
end
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID) HC.Cast(spellID) end)
ns.On("PLAYER_ENTERING_WORLD", function() track, pending = {}, nil end)

local function left(t)
  local r = t and (t - GetTime()) or 0
  return r > 0 and math.ceil(r) or 0
end
-- Secondes restantes (0 = rien) : Renovation, Ame affaiblie, d'apres les sorts du joueur seulement.
function HC.Left(unit)
  local e = track[idOf(unit)] or {}
  return left(e.renew), left(e.weak)
end

function HC.Tank(units)
  local guess
  for _, u in ipairs(units) do
    if u ~= "player" then
      if S.Get(UnitGroupRolesAssigned, u) == "TANK" then return u end
      local st, _, class = S.GetAll(UnitClass, u)
      if not guess and st == "lisible" and class == "WARRIOR" then guess = u end
    end
  end
  return guess
end

local function pick(...)
  for i = 1, select("#", ...) do local k = select(i, ...) if known(k) then return k end end
end

-- Clics conseilles selon le groupe et les sorts connus : { ["1"], ["2"], ["shift-1"] } (cles de Data/Spells, nil si rien).
-- Avec un tank : le plus gros soin au clic gauche ; sinon le soin le plus econome. Renovation a droite, Bouclier en urgence.
function HC.Recommended(units)
  local big = HC.Tank(units) and pick("GREATERHEAL", "HEAL", "LESSERHEAL") or pick("HEAL", "LESSERHEAL")
  return { ["1"] = big, ["2"] = pick("RENEW", "LESSERHEAL"), ["shift-1"] = pick("PWS", "FLASHHEAL") }
end

-- Conseil prioritaire (texte) ou nil. ctx = { units = jetons presents, inCombat, spells = reglage des clics }.
function HC.Advice(ctx)
  local slotOf = {}
  for slot, k in pairs(ctx.spells or {}) do slotOf[k] = slotOf[k] or slot end
  local function on(k)
    local s = slotOf[k]
    return s and (" (" .. L.HEALC_SLOT[s] .. ")") or L.HEALC_NOSLOT
  end
  local tank = HC.Tank(ctx.units)
  local tname = tank and (unitName(tank) or L.HEALC_TANK)
  if not ctx.inCombat then
    if known("RESURRECTION") then
      for _, u in ipairs(ctx.units) do
        if u ~= "player" and S.Get(UnitIsDeadOrGhost, u) == true then
          return L.HEALC_DO:format(spellName("RESURRECTION"), unitName(u) or u) .. on("RESURRECTION")
        end
      end
    end
    if tank and known("PWS") and select(2, HC.Left(tank)) == 0 then
      return L.HEALC_PULL:format(spellName("PWS"), tname) .. on("PWS")
    end
    local rec, parts, differs = HC.Recommended(ctx.units), {}, false
    for _, slot in ipairs({ "1", "2", "shift-1" }) do
      if rec[slot] then
        parts[#parts + 1] = L.HEALC_SLOT[slot] .. " " .. spellName(rec[slot])
        if (ctx.spells or {})[slot] ~= rec[slot] then differs = true end
      end
    end
    if differs then return L.HEALC_SETUP:format(table.concat(parts, " · ")) end
    return nil
  end
  if tank and known("RENEW") and (HC.Left(tank)) == 0 then
    return L.HEALC_RENEW:format(spellName("RENEW"), tname) .. on("RENEW")
  end
  local big, urgent = pick("GREATERHEAL", "HEAL", "LESSERHEAL"), pick("FLASHHEAL", "PWS")
  if not big then return nil end
  local s = L.HEALC_BIG:format(spellName(big) .. on(big))
  if urgent then s = s .. L.HEALC_URGENT:format(spellName(urgent) .. on(urgent)) end
  return s
end
