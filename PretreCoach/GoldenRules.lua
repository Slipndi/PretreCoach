-- Règles d'or (spec 4) : ns.Rules.list (8 règles { id, title, explain }), Rules.Status() -> { [1..8] = { state, reason } }
-- avec state = "ok" | "warn" | "bad" | "unknown", Rules.KillStats() -> { total, wand }. Message ns.Fire("RULES") à chaque
-- changement d'état ou de raison. Les règles 1 à 4 sont évaluées en combat ; les règles 5 à 8 seulement hors combat
-- (en combat elles gardent leur dernier état). Rien dans le chat : des toasts (ns.Toast) avec anti-répétition.
local _, ns = ...
local S, L = ns.S, ns.L
local State, Timers, Calc, D = ns.State, ns.Timers, ns.Calc, ns.Data

local Rules = {}
ns.Rules = Rules

Rules.list = {}
for i = 1, 8 do
  Rules.list[i] = { id = i, title = L["RULE_" .. i .. "_TITLE"], explain = L["RULE_" .. i .. "_EXPLAIN"] }
end

-- R2 : au moins 70 % de monstres achevés à la baguette (comparaison en entiers : wand * 10 >= total * 7)
local R3_WARN_SECS = 30     -- R3 : durée de l'état orange après un sort coûteux dans la fenêtre
local EMERGENCY = { LESSERHEAL = true, HEAL = true, GREATERHEAL = true, FLASHHEAL = true, RENEW = true, PWS = true, POH = true }
local ASHENVALE = 1440
local BFD_LEVELS = { from = 24, to = 32 }

local cur = {}
for i = 1, 8 do cur[i] = { state = "unknown", reason = "" } end

local bySpell = {} -- spellID -> entrée de ns.Data.Spells
for _, sp in ipairs(D.Spells) do
  for _, r in ipairs(sp.ranks) do bySpell[r.id] = sp end
end

-- état propre aux règles
local total, wand, deadReadable, counted, nCounted = 0, 0, false, {}, 0 -- R2
local fiveEnd, warnUntil = 0, 0                                         -- R3
local remindedMove = false                                              -- R4
local shownR7 = false                                                   -- R7

local function flags()
  if not ns.db then return {} end
  ns.db.rules = ns.db.rules or {}
  return ns.db.rules
end

local function manual(id)
  local g = ns.db and ns.db.guide
  return g and g.manual and g.manual[id] == true
end

-- Même lecture que Rotation.Context : vitesse, sinon IsPlayerMoving ; faux = mouvement indétectable.
local function movingKnown()
  if type(S.Get(GetUnitSpeed, "player")) == "number" then return true end
  return S.Get(IsPlayerMoving) ~= nil
end

local function evaluate()
  local changed = false
  local function set(i, state, reason)
    local c = cur[i]
    if c.state == state and c.reason == reason then return end
    c.state, c.reason, changed = state, reason, true
    if state == "warn" or state == "bad" then ns.Debug("R%d %s : %s", i, state, reason) end
  end
  local inCombat = InCombatLockdown() and true or false
  local level = State.level
  local now = GetTime()
  local rot = ns.Rotation and ns.Rotation.current

  -- R1 : baguette. Vérifiée aussi en combat, mais le toast attend la sortie de combat.
  local ws, best = Calc.WandStatus(level, State.wand)
  if ws == "aucune" then
    set(1, "bad", L.RULE_R1_NONE)
    if not inCombat and best then ns.Toast(L.RULE_R1_TOAST_NONE:format(best.source), { key = "r1:none" }) end
  elseif ws == "depassee" then
    set(1, "warn", L.RULE_R1_OLD)
    if not inCombat and best then ns.Toast(L.RULE_R1_TOAST_OLD:format(best.name, best.level), { key = "r1:old" }) end
  elseif ws == "ok" then set(1, "ok", L.RULE_R1_OK)
  else set(1, "unknown", L.RULE_R1_UNKNOWN) end

  -- R2 : statistique de session ; le conseil lui-même vient de Rotation.
  local advice = rot and rot.keys and rot.keys[1] == "SHOOT" and L.RULE_R2_ADVICE or nil
  local function with(text) return advice and (text .. " ; " .. advice) or text end
  if total > 0 then
    set(2, wand * 10 >= total * 7 and "ok" or "warn", with(L.RULE_R2_STATS:format(wand, total)))
  else
    set(2, "unknown", with(deadReadable and L.RULE_R2_NONE or L.RULE_R2_UNREADABLE))
  end

  -- R3 : orange pendant R3_WARN_SECS après un sort coûteux lancé dans la fenêtre des 5 s.
  if Timers.FiveSecRemaining() == nil then set(3, "unknown", L.RULE_R3_UNKNOWN)
  elseif now < warnUntil then set(3, "warn", L.RULE_R3_WARN)
  else set(3, "ok", L.RULE_R3_OK) end

  -- R4 : le panneau fait déjà clignoter l'icône ; ici seulement l'état.
  if not movingKnown() then set(4, "unknown", L.RULE_R4_UNKNOWN)
  elseif rot and rot.stop then set(4, "warn", L.RULE_R4_WARN)
  else set(4, "ok", L.RULE_R4_OK) end

  if not inCombat then
    -- R5 : zone, d'après l'en-tête du guide (Calc.ZoneStatus).
    local h = ns.Guide.Header()
    if type(level) ~= "number" or not State.zone then set(5, "unknown", L.RULE_R5_UNKNOWN)
    elseif h.zoneStatus == "bientot" then set(5, "warn", L.RULE_R5_BIENTOT)
    elseif h.zoneStatus == "verte" then
      set(5, "bad", L.RULE_R5_VERTE)
      if h.nextZone then ns.Toast(L.RULE_R5_TOAST:format(h.nextZone), { key = "r5:" .. State.zone, cooldown = 3600 }) end
    else set(5, "ok", L.RULE_R5_OK) end

    -- R6 : aucune API Legacy connue, on suit l'objectif manuel du guide.
    if manual("legacy_toa") then set(6, "ok", L.RULE_R6_OK) else set(6, "unknown", L.RULE_R6_UNKNOWN) end

    -- R7 : Brassenoire.
    if type(level) ~= "number" then set(7, "unknown", L.RULE_R7_UNKNOWN)
    elseif level < BFD_LEVELS.from or level > BFD_LEVELS.to then set(7, "ok", L.RULE_R7_OK)
    else
      local done = State.QuestDone(D.GravestoneQuest)
      if done ~= true and manual("bfd_quest") then done = true end
      if done == true then set(7, "ok", L.RULE_R7_OK)
      elseif done == false then set(7, "warn", L.RULE_R7_WARN)
      else set(7, "unknown", L.RULE_R7_UNKNOWN) end
      if done ~= true and not shownR7 and (State.zone == ASHENVALE or State.mapID == ASHENVALE) then
        shownR7 = true
        ns.Toast(L.RULE_R7_TOAST, { key = "r7" })
      end
    end

    -- R8 : double spécialisation au 40 ; specGroups nil = jugée sur la Forme d'Ombre seule.
    if type(level) ~= "number" then set(8, "unknown", L.RULE_R8_UNKNOWN)
    elseif level < 40 then set(8, "ok", L.RULE_R8_WAIT)
    else
      local sf, sg = State.Knows("SHADOWFORM"), State.specGroups
      local bad
      if sf == 0 then bad = L.RULE_R8_BAD_SHADOW
      elseif type(sg) == "number" and sg < 2 then bad = L.RULE_R8_BAD_SPEC end
      if bad then
        set(8, "bad", bad)
        local f = flags()
        if not f.r8 then f.r8 = true ns.Toast(L.RULE_R8_TOAST, { key = "r8" }) end
      elseif sf then set(8, "ok", L.RULE_R8_OK)
      else set(8, "unknown", L.RULE_R8_UNKNOWN) end
    end
  end

  if changed then ns.Fire("RULES") end
end
Rules.Evaluate = evaluate

function Rules.Status()
  local out = {}
  for i = 1, 8 do out[i] = { state = cur[i].state, reason = cur[i].reason } end
  return out
end

function Rules.KillStats() return { total = total, wand = wand } end

-- R2 : mort de la cible, comptée une seule fois par GUID, seulement si on a lancé un sort dessus récemment.
local function checkKill()
  local guid = S.Get(UnitGUID, "target")
  if not guid then return end
  local dead = S.Get(UnitIsDead, "target")
  if dead == nil then return end
  deadReadable = true
  if dead ~= true or counted[guid] then return end
  local key = Timers.LastCastOn(guid)
  if not key then return end
  if nCounted >= 500 then counted, nCounted = {}, 0 end
  counted[guid], nCounted = true, nCounted + 1
  total = total + 1
  if key == "SHOOT" then wand = wand + 1 end
  evaluate()
end

-- R3 : ordre des écouteurs. Timers.lua et ce fichier écoutent le même UNIT_SPELLCAST_SUCCEEDED ; Timers met fiveEnd à jour
-- et l'ordre d'appel entre deux cadres n'est pas garanti. On ne lit donc jamais FiveSecRemaining() ici : R3 garde sa propre
-- copie de la fin des 5 s (même règle : sort `manaCost`, now + 5), lue avant d'être réécrite dans le même appel.
-- FiveSecRemaining() sert seulement à détecter le mode dégradé (nil), dans evaluate.
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or type(spellID) ~= "number" then return end
  local sp = bySpell[spellID]
  if not (sp and sp.manaCost) then return end
  local now = GetTime()
  local inWindow = fiveEnd > now
  fiveEnd = now + 5
  if inWindow and not EMERGENCY[sp.key] then
    warnUntil = now + R3_WARN_SECS
    ns.Toast(L.RULE_R3_TOAST, { key = "r3", cooldown = 60 })
    ns.After(R3_WARN_SECS, evaluate)
    evaluate()
  end
end)

-- R4 : rappel unique par session, au premier conseil de Tir quand le mouvement n'est pas détectable.
ns.Listen("ROTATION", function(_, res)
  if not remindedMove and res and res.keys and res.keys[1] == "SHOOT" and not movingKnown() then
    remindedMove = true
    ns.Toast(L.RULE_R4_TOAST, { key = "r4" })
  end
  evaluate()
end)

ns.Listen("STATE", evaluate)
ns.Listen("TIMERS", evaluate)
ns.Listen("GUIDE", evaluate)
ns.On("PLAYER_TARGET_CHANGED", checkKill)
ns.OnUnit("UNIT_HEALTH", "target", checkKill)
ns.On("PLAYER_REGEN_ENABLED", function() checkKill() evaluate() end)
ns.On("ADDON_LOADED", function() evaluate() end)
