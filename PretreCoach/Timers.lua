-- Minuteurs maison, alimentés par les seuls sorts du joueur (UNIT_SPELLCAST_SUCCEEDED) et GetTime().
-- Mode dégradé : un spellID secret ou illisible met Timers.degraded = true (TIMERS est alors émis) ; il repasse à
-- false au prochain spellID lisible. Tant qu'il est vrai, FiveSecRemaining, CooldownRemaining, HasSWP et SWPCount
-- rendent nil (= inconnu) : les appelants doivent le gérer. Remise à zéro de swpEnd/lastOn/cdEnd sur PLAYER_DEAD
-- et PLAYER_ENTERING_WORLD.
-- Seuls les sorts `harmful` (Data/Spells.lua) posent lastOn/swpEnd sur la cible, et seulement si UnitCanAttack.
-- LastCastOn(guid) rend key, t, lastNonShootKey (dernier sort hors Tir sur cette cible).
local _, ns = ...
local S = ns.S

local T = { degraded = false, manaCasts = 0 } -- manaCasts : sorts à mana lancés pendant le dernier combat
ns.On("PLAYER_REGEN_DISABLED", function() T.manaCasts = 0 end)
ns.Timers = T

local LAST_TTL = 30 -- secondes de mémoire du dernier sort lancé sur une cible

local bySpell = {} -- spellID -> entrée de ns.Data.Spells
for _, sp in ipairs(ns.Data.Spells) do
  for _, r in ipairs(sp.ranks) do bySpell[r.id] = sp end
end

local fiveEnd, cdEnd = 0, {}
local swpEnd, swpCurrent, swpCurGuid = {}, nil, nil -- Douleur : fin par GUID ; repli « cible actuelle » si le GUID est illisible
local lastOn = {}                   -- guid -> { key, t, nonShoot }

local function prune(now)
  for g, e in pairs(swpEnd) do if e <= now then swpEnd[g] = nil end end
  for g, l in pairs(lastOn) do if l.t + LAST_TTL <= now then lastOn[g] = nil end end
  for k, e in pairs(cdEnd) do if e + 1 <= now then cdEnd[k] = nil end end -- +1 : garde la place d'une marge
  if swpCurrent and swpCurrent <= now then swpCurrent, swpCurGuid = nil, nil end
end

ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or type(spellID) ~= "number" then
    if not T.degraded then
      T.degraded = true
      ns.Debug("spellID illisible : minuteurs désactivés (mode dégradé)")
      ns.Fire("TIMERS")
    end
    return
  end
  local recovered = T.degraded
  T.degraded = false
  local sp = bySpell[spellID]
  if not sp then
    if recovered then ns.Fire("TIMERS") end
    return
  end
  local now = GetTime()
  prune(now)
  if sp.manaCost then
    fiveEnd = now + 5
    if InCombatLockdown() then T.manaCasts = T.manaCasts + 1 end
  end
  if sp.cooldown then cdEnd[sp.key] = now + sp.cooldown end
  local repeatedShoot = false
  -- UnitCanAttack absente : cible traitée comme attaquable (seul « false » l'exclut)
  local canAttack, cst = S.Get(UnitCanAttack, "player", "target")
  if sp.harmful and (canAttack == true or cst == "absente") then
    local guid = S.Get(UnitGUID, "target")
    if guid then
      local prev = lastOn[guid]
      repeatedShoot = sp.key == "SHOOT" and prev ~= nil and prev.key == "SHOOT"
      lastOn[guid] = { key = sp.key, t = now, nonShoot = sp.key ~= "SHOOT" and sp.key or (prev and prev.nonShoot) }
    end
    if sp.key == "SWP" and sp.duration then
      local d = math.min(sp.duration, 18)
      -- swpCurrent aussi quand le GUID est lisible : s'il devient secret en combat, la Douleur de la cible actuelle est retrouvée
      if guid then swpEnd[guid] = now + d end
      swpCurrent, swpCurGuid = now + d, guid
    end
  end
  if not repeatedShoot or recovered then ns.Fire("TIMERS") end
end)

ns.On("PLAYER_TARGET_CHANGED", function()
  swpCurrent, swpCurGuid = nil, nil
  -- cible morte : plus de Douleur à suivre (au mieux, l'état « mort » peut être illisible)
  local guid = S.Get(UnitGUID, "target")
  if guid and S.Get(UnitIsDead, "target") == true then swpEnd[guid] = nil end
  ns.Fire("TIMERS")
end)

local function reset()
  swpEnd, lastOn, cdEnd, swpCurrent, swpCurGuid = {}, {}, {}, nil, nil
  ns.Fire("TIMERS")
end
ns.On("PLAYER_DEAD", reset)
ns.On("PLAYER_ENTERING_WORLD", reset)

-- Secondes restantes avant la fin de la règle des 5 s (0 si finie) ; nil en mode dégradé.
-- margin (optionnelle) : secondes ajoutées pour ne pas annoncer la fin trop tôt (latence du serveur).
function T.FiveSecRemaining(margin)
  if T.degraded then return nil end
  local r = fiveEnd + (margin or 0) - GetTime()
  return r > 0 and r or 0
end

-- Secondes de recharge restantes du sort `key` (0 si prêt ou non suivi) ; nil en mode dégradé.
function T.CooldownRemaining(key, margin)
  if T.degraded then return nil end
  prune(GetTime())
  local e = cdEnd[key]
  local r = e and e + (margin or 0) - GetTime() or 0
  return r > 0 and r or 0
end

-- Douleur active sur la cible actuelle ? nil en mode dégradé ; faux (et oubliée) si la cible est morte.
function T.HasSWP()
  if T.degraded then return nil end
  prune(GetTime())
  local guid = S.Get(UnitGUID, "target")
  if guid then
    if S.Get(UnitIsDead, "target") == true then swpEnd[guid], swpCurrent, swpCurGuid = nil, nil, nil return false end
    return swpEnd[guid] ~= nil
  end
  return swpCurrent ~= nil
end

-- Nombre de cibles portant une Douleur active ; nil en mode dégradé.
function T.SWPCount()
  if T.degraded then return nil end
  prune(GetTime())
  local n = 0
  for _ in pairs(swpEnd) do n = n + 1 end
  if swpCurrent and not (swpCurGuid and swpEnd[swpCurGuid]) then n = n + 1 end -- pas deux fois la même cible
  return n
end

-- Dernier sort du joueur lancé sur ce GUID : key (Tir compris), GetTime() du lancement, key du dernier sort hors Tir
-- (nil si inconnu ou trop ancien).
function T.LastCastOn(guid)
  prune(GetTime())
  local l = guid and lastOn[guid]
  if l then return l.key, l.t, l.nonShoot end
end
