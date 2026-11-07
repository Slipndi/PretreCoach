-- Minuteurs maison, alimentés par les seuls sorts du joueur (UNIT_SPELLCAST_SUCCEEDED) et GetTime().
-- Mode dégradé : un spellID secret ou illisible met Timers.degraded = true (définitif) et rien n'est minuté.
local _, ns = ...
local S = ns.S

local T = { degraded = false }
ns.Timers = T

local LAST_TTL = 30 -- secondes de mémoire du dernier sort lancé sur une cible

local bySpell = {} -- spellID -> entrée de ns.Data.Spells
for _, sp in ipairs(ns.Data.Spells) do
  for _, r in ipairs(sp.ranks) do bySpell[r.id] = sp end
end

local fiveEnd, cdEnd = 0, {}
local swpEnd, swpCurrent = {}, nil -- Douleur : fin par GUID ; repli « cible actuelle » si le GUID est illisible
local lastOn = {}                   -- guid -> { key, t }

local function prune(now)
  for g, e in pairs(swpEnd) do if e <= now then swpEnd[g] = nil end end
  for g, l in pairs(lastOn) do if l.t + LAST_TTL <= now then lastOn[g] = nil end end
  for k, e in pairs(cdEnd) do if e <= now then cdEnd[k] = nil end end
  if swpCurrent and swpCurrent <= now then swpCurrent = nil end
end

ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or type(spellID) ~= "number" then
    if not T.degraded then
      T.degraded = true
      ns.Debug("spellID illisible : minuteurs désactivés (mode dégradé)")
    end
    return
  end
  local sp = bySpell[spellID]
  if not sp then return end
  local now = GetTime()
  if sp.manaCost then fiveEnd = now + 5 end
  if sp.cooldown then cdEnd[sp.key] = now + sp.cooldown end
  local guid = S.Get(UnitGUID, "target")
  if guid then lastOn[guid] = { key = sp.key, t = now } end
  if sp.key == "SWP" and sp.duration then
    if guid then swpEnd[guid] = now + sp.duration else swpCurrent = now + sp.duration end
  end
  prune(now)
  ns.Fire("TIMERS")
end)

ns.On("PLAYER_TARGET_CHANGED", function()
  swpCurrent = nil
  ns.Fire("TIMERS")
end)

-- Secondes restantes avant la fin de la règle des 5 s (0 si finie).
function T.FiveSecRemaining()
  local r = fiveEnd - GetTime()
  return r > 0 and r or 0
end

-- Secondes de recharge restantes du sort `key` (0 si prêt ou non suivi).
function T.CooldownRemaining(key)
  prune(GetTime())
  local e = cdEnd[key]
  return e and e - GetTime() or 0
end

-- Douleur active sur la cible actuelle ?
function T.HasSWP()
  prune(GetTime())
  local guid = S.Get(UnitGUID, "target")
  if guid then return swpEnd[guid] ~= nil end
  return swpCurrent ~= nil
end

-- Nombre de cibles portant une Douleur active.
function T.SWPCount()
  prune(GetTime())
  local n = swpCurrent and 1 or 0
  for _ in pairs(swpEnd) do n = n + 1 end
  return n
end

-- Dernier sort du joueur lancé sur ce GUID : key, GetTime() du lancement (nil si inconnu ou trop ancien).
function T.LastCastOn(guid)
  prune(GetTime())
  local l = guid and lastOn[guid]
  if l then return l.key, l.t end
end
