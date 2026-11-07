-- Coach de cycle (spec 5) : l'addon conseille, il ne lance jamais de sort.
-- Rotation.Compute(ctx) est pure (aucun appel à l'API) ; Rotation.Context() lit le jeu via S.Get ; Rotation.Update()
-- recalcule et émet ns.Fire("ROTATION", result) seulement si le résultat change.
-- result = { keys = {k1, k2, k3}, text, reason, stop }. Clés hors sorts : "MELEE", "BANDAGE", "DRINK", "EAT".
local _, ns = ...
local S, L = ns.S, ns.L

local Rotation = {}
ns.Rotation = Rotation

-- Seuils en % (choix de l'addon : la spec dit « bas » / « haut » sans chiffre).
local MIN_MANA = 15      -- sous ce mana lisible : plus de sort à mana, baguette
-- Hystérésis : l'état « au-dessus » est mémorisé dans Rotation.Context (ctx.mbHigh / ctx.flayHigh), Compute reste pure.
local REBLAST_ON, REBLAST_OFF = 60, 50 -- Attaque mentale reconseillée à partir de ON, plus conseillée sous OFF
local FLAY_ON, FLAY_OFF = 30, 25       -- Fouet mental pour combler, idem
local TIER3_MANA = 30        -- palier 3 : Mort et Attaque mentale demandent un mana lisible au moins égal
local GROUP_MAX = 3          -- Douleurs déjà posées au-delà desquelles on reste à la baguette
local BURST_MIN_HP = 25  -- cible presque morte : pas de sort, on achève
local SMITE_UNTIL = 35   -- Châtiment tant que la vie de la cible est au-dessus
local HP_LOW, HP_OK, MANA_LOW = 60, 70, 50
local RECOVER_SECS = 30  -- carte « Récupère » après un combat (vie et mana secrets : pas de seuil)
local SMITE_BLIND = 2    -- Châtiments avant le corps à corps quand la vie de la cible est illisible

local AURA = { SHIELD_WEAK = 6788, SHADOWFORM = 15473, BANDAGE = 11196 }
local FIRST_AID = 129

local ICON = { MELEE = "Interface\\Icons\\Ability_MeleeDamage", BANDAGE = "Interface\\Icons\\INV_Misc_Bandage_12",
  DRINK = "Interface\\Icons\\INV_Drink_04", EAT = "Interface\\Icons\\INV_Misc_Food_14" }

local edible = { Humanoid = true, Undead = true } -- repli sur les noms anglais, au cas où le client ne soit pas en français
edible[L.CT_HUMANOID] = true
edible[L.CT_UNDEAD] = true

local spellByKey = {}
for _, sp in ipairs(ns.Data.Spells) do spellByKey[sp.key] = sp end

------------------------------------------------------------------------
-- logique pure
------------------------------------------------------------------------
function Rotation.Compute(ctx)
  local out = { keys = {}, text = "", reason = "" }
  local keys = out.keys
  local function add(k, text, why)
    if #keys >= 3 then return end
    -- Forme d'Ombre active : les sorts du Sacré sont impossibles, le Bouclier reste permis
    local sp = spellByKey[k]
    if sp and sp.school == "holy" and ctx.shadowformActive == true then return end
    for _, v in ipairs(keys) do if v == k then return end end
    keys[#keys + 1] = k
    if #keys == 1 then out.text, out.reason = text, why end
  end
  local function known(k)
    local r = ctx.knows and ctx.knows(k)
    return type(r) == "number" and r > 0
  end
  -- prêt = appris et recharge connue égale à 0 (recharge inconnue = pas supposé prêt)
  local function ready(k) return known(k) and ctx.cd ~= nil and ctx.cd(k) == 0 end
  -- seuil avec hystérésis : l'état mémorisé prime ; sans mémoire, le seuil haut décide ; mana illisible = faux
  local function above(flag, mana, on)
    if mana == nil then return false end
    if flag == nil then return mana >= on end
    return flag
  end

  local lvl = ctx.level
  if type(lvl) ~= "number" then out.reason = "niveau illisible" return out end

  if lvl >= 40 and not ctx.inCombat and known("SHADOWFORM") and ctx.shadowformActive == false then
    add("SHADOWFORM", L.ROT_SHADOWFORM, "Forme d'Ombre absente au niveau 40+")
  end

  -- sans cible hostile
  if not ctx.hasHostileTarget then
    if ctx.inCombat then
      if #keys == 0 then out.reason = "en combat sans cible hostile" end
      return out
    end
    local hp, mp = ctx.hpPct, ctx.manaPct
    if hp == nil or mp == nil then
      -- vie ou mana secrets : après le combat, la liste de ce qui est possible, sans seuil
      if ctx.recover == true then
        if ctx.targetDead == true and edible[ctx.targetCreatureType] and ctx.cannibalUsable == true and ready("CANNIBAL") then
          add("CANNIBAL", L.ROT_CANNIBAL, "cadavre humanoïde ou mort-vivant")
        end
        if (ctx.bandageCount or 0) > 0 and ctx.recentlyBandaged ~= true then
          add("BANDAGE", L.ROT_BANDAGE, "bandage disponible")
        end
        if ready("DARKSAC") then add("DARKSAC", L.ROT_DARKSAC, "Sacrifice sombre prêt") end
        add("DRINK", L.ROT_DRINK, "boire")
        add("EAT", L.ROT_EAT, "manger")
        out.text = L.ROT_RECOVER .. " : " .. out.text
        out.reason = "récupération après combat (vie ou mana secrets) : " .. out.reason
      elseif #keys == 0 then out.reason = "vie ou mana illisible : rien à récupérer" end
      return out
    end
    local hpLow, mpLow = hp < HP_LOW, mp < MANA_LOW
    if hpLow or mpLow then
      if ctx.targetDead == true and edible[ctx.targetCreatureType] and ctx.cannibalUsable == true and ready("CANNIBAL") then
        add("CANNIBAL", L.ROT_CANNIBAL, "cadavre humanoïde ou mort-vivant, vie ou mana bas")
      end
      if mpLow and hp >= HP_OK and ready("DARKSAC") then
        add("DARKSAC", L.ROT_DARKSAC, "mana bas, vie correcte")
      end
      if hpLow and not mpLow and (ctx.bandageCount or 0) > 0 and ctx.recentlyBandaged == false then
        add("BANDAGE", L.ROT_BANDAGE, "vie basse, mana correct, bandage disponible")
      end
      if mpLow then add("DRINK", L.ROT_DRINK, "mana bas hors combat")
      else add("EAT", L.ROT_EAT, "vie basse hors combat") end
    end
    if #keys == 0 then out.reason = "rien à récupérer" end
    return out
  end

  -- avec cible hostile
  -- palier 3 : Forme d'Ombre apprise ou active (le niveau 40 seul ne suffit pas : sans le talent, on reste au palier 2)
  local tier = lvl < 10 and 1 or ((known("SHADOWFORM") or ctx.shadowformActive == true) and 3 or 2)
  local mana, tgtHp = ctx.manaPct, ctx.targetHpPct
  local canCast = not (mana ~= nil and mana < MIN_MANA) and not (tgtHp ~= nil and tgtHp < BURST_MIN_HP)
  -- Tir : automatique, pas de sort à apprendre (pas de known) ; il faut une baguette lue ET le niveau 5
  local wand = ctx.hasWand == true and lvl >= 5

  if not ctx.inCombat and ready("PWS") and ctx.weakenedSoul == false and ctx.shieldUp ~= true then
    add("PWS", L.ROT_PWS, "avant d'engager : Bouclier connu, prêt, sans Âme affaiblie")
  end

  local swp = ctx.hasSWP
  -- Douleur inconnue (mode dégradé) en combat : jamais conseillée en premier
  local swpUnk = canCast and swp == nil and ctx.inCombat and known("SWP")
  -- groupe de monstres : Douleur déjà sur d'autres cibles et absente de celle-ci
  local group = canCast and ctx.inCombat and swp == false and type(ctx.swpCount) == "number" and ctx.swpCount >= 1
  if swpUnk and wand then
    add("SHOOT", L.ROT_SWP_UNKNOWN, "Douleur inconnue : baguette d'abord, Douleur en 2e")
    add("SWP", L.ROT_SWP, "")
  end

  if group then
    if ctx.swpCount <= GROUP_MAX and known("SWP") then add("SWP", L.ROT_SWP_GROUP, "groupe de monstres : Douleur sur cette cible aussi") end
  elseif canCast then
    if tier == 1 then
      if known("SWP") and swp == false then add("SWP", L.ROT_SWP, "ouverture : Douleur absente de la cible") end
    elseif tier == 2 then
      if swp == false then
        if ready("MINDBLAST") then add("MINDBLAST", L.ROT_OPEN_MB, "ouverture : Attaque mentale prête")
        elseif known("HOLYFIRE") and not ctx.holyDone then add("HOLYFIRE", L.ROT_OPEN_HF, "ouverture : Flammes sacrées") end
        if known("SWP") then add("SWP", L.ROT_SWP, "Douleur absente de la cible") end
      elseif swp == true and above(ctx.mbHigh, mana, REBLAST_ON) and ready("MINDBLAST") then
        add("MINDBLAST", L.ROT_MB, "mana lisible et haut : Attaque mentale reconseillée")
      end
    else
      local mp30 = mana ~= nil and mana >= TIER3_MANA
      if swp == false then
        if mp30 and ready("MINDBLAST") then add("MINDBLAST", L.ROT_OPEN_MB, "ouverture en Forme d'Ombre : Attaque mentale") end
        if known("SWP") then add("SWP", L.ROT_SWP, "Douleur absente de la cible") end
      end
      if mp30 and ready("SWD") then add("SWD", L.ROT_SWD, "Mot de l'ombre : Mort prêt") end
      if mp30 and ready("MINDBLAST") then add("MINDBLAST", L.ROT_MB, "Attaque mentale prête") end
      if known("MINDFLAY") and (above(ctx.flayHigh, mana, FLAY_ON) or (mana == nil and not wand)) then
        add("MINDFLAY", L.ROT_FLAY, mana == nil and "mana illisible, pas de baguette : Fouet mental"
          or "mana lisible : Fouet mental pour combler")
      end
    end
  end

  -- finisseur : baguette, sinon Châtiment puis corps à corps
  if wand then
    add("SHOOT", L.ROT_SHOOT, "baguette équipée : option la plus économe")
  else
    local smite
    if known("SMITE") and not (mana ~= nil and mana < MIN_MANA) then
      if tgtHp == nil then smite = (ctx.smitesOnTarget or 0) < SMITE_BLIND
      else smite = tgtHp > SMITE_UNTIL end
    end
    if smite then
      add("SMITE", L.ROT_SMITE, tgtHp == nil and "pas de baguette, vie de la cible illisible : Châtiment (moins de 2 lancés)"
        or "pas de baguette, cible pas encore basse : Châtiment")
    end
    add("MELEE", L.ROT_MELEE, "pas de baguette : corps à corps")
    -- sans baguette, Douleur inconnue : en 2e, après le sort principal
    if swpUnk then
      local have
      for _, v in ipairs(keys) do if v == "SWP" then have = true end end
      if not have then table.insert(keys, math.min(2, #keys + 1), "SWP") keys[4] = nil end
    end
  end

  -- sorts à recharge en cours : affichés à la fin, icône grisée
  if tier >= 2 and known("MINDBLAST") and (ctx.cd and ctx.cd("MINDBLAST") or 0) > 0 then add("MINDBLAST", L.ROT_MB, "") end
  if tier == 3 and known("SWD") and (ctx.cd and ctx.cd("SWD") or 0) > 0 then add("SWD", L.ROT_SWD, "") end

  if #keys > 0 and ctx.targetMelee == true and ready("PSCREAM") then
    table.insert(keys, math.min(2, #keys + 1), "PSCREAM")
    keys[4] = nil
    out.text = out.text .. " | " .. L.ROT_PSCREAM
    out.reason = out.reason .. " ; monstre au contact : Cri psychique"
  end
  if keys[1] == "SHOOT" and ctx.moving == true then
    out.text, out.stop = L.ROT_STOP, true
    out.reason = out.reason .. " ; en mouvement : s'arrêter pour tirer"
  end
  return out
end

------------------------------------------------------------------------
-- affichage : sorts, textures, raccourcis
------------------------------------------------------------------------
-- ID du plus haut rang connu ; nil si inconnu ou pas un sort.
function Rotation.SpellID(key)
  local sp = spellByKey[key]
  local idx = sp and ns.State.Knows(key)
  if type(idx) == "number" and idx > 0 and sp.ranks[idx] then return sp.ranks[idx].id end
end

function Rotation.Texture(key)
  if ICON[key] then return ICON[key] end
  local sp = spellByKey[key]
  if not sp then return nil end
  local id = Rotation.SpellID(key) or sp.ranks[1].id
  return (S.Get((C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture, id))
end

local slotByID, hotCache = nil, {}

local function slotCommand(slot)
  if slot >= 1 and slot <= 12 then return "ACTIONBUTTON" .. slot end
  local bars = { { 25, "MULTIACTIONBAR3BUTTON" }, { 37, "MULTIACTIONBAR4BUTTON" },
    { 49, "MULTIACTIONBAR2BUTTON" }, { 61, "MULTIACTIONBAR1BUTTON" },
    { 145, "MULTIACTIONBAR5BUTTON" }, { 157, "MULTIACTIONBAR6BUTTON" } }
  for _, b in ipairs(bars) do
    if slot >= b[1] and slot < b[1] + 12 then return b[2] .. (slot - b[1] + 1) end
  end
end

local function bindingText(slot)
  local cmd = type(slot) == "number" and slotCommand(slot)
  local k = cmd and S.Get(GetBindingKey, cmd)
  if type(k) ~= "string" then return nil end
  if GetBindingText then
    local t = S.Get(GetBindingText, k, "KEY_", true)
    if type(t) == "string" then return t end
  end
  return (k:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A"))
end

-- Raccourci court du sort (premier emplacement qui en a un), ou nil. Sans C_ActionBar.FindSpellActionButtons : scan de
-- GetActionInfo(1..180), jamais en combat.
function Rotation.Hotkey(key)
  local c = hotCache[key]
  if c ~= nil then return c or nil end
  local sp = spellByKey[key]
  if not sp then return nil end
  local text
  local find = C_ActionBar and C_ActionBar.FindSpellActionButtons
  if find then
    for i = #sp.ranks, 1, -1 do
      local slots = S.Get(find, sp.ranks[i].id)
      if type(slots) == "table" then
        for _, slot in ipairs(slots) do
          text = bindingText(slot)
          if text then break end
        end
        if text then break end
      end
    end
  else
    if InCombatLockdown() then return nil end
    if not slotByID then
      slotByID = {}
      for slot = 1, 180 do
        local st, kind, id = S.GetAll(GetActionInfo, slot)
        if st == "lisible" and kind == "spell" and type(id) == "number" then
          slotByID[id] = slotByID[id] or {}
          table.insert(slotByID[id], slot)
        end
      end
    end
    for i = #sp.ranks, 1, -1 do
      for _, slot in ipairs(slotByID[sp.ranks[i].id] or {}) do
        text = bindingText(slot)
        if text then break end
      end
      if text then break end
    end
  end
  hotCache[key] = text or false
  return text
end

------------------------------------------------------------------------
-- contexte lu dans le jeu
------------------------------------------------------------------------
local smites = 0
local smiteIDs, holyFireIDs = {}, {}
for _, r in ipairs(spellByKey.SMITE.ranks) do smiteIDs[r.id] = true end
for _, r in ipairs(spellByKey.HOLYFIRE.ranks) do holyFireIDs[r.id] = true end
-- Flammes sacrées : une seule fois par cible (par GUID ; sans GUID lisible, drapeau remis à zéro au changement de cible)
local holyGuids, holyThisTarget = {}, false
-- hystérésis (mémoire de l'état « mana haut ») ; Compute les reçoit par ctx
local mbHigh, flayHigh
local recoverUntil -- GetTime() de la fin de la carte « Récupère » ; nil = pas de carte

local function hyst(flag, mana, on, off)
  if mana == nil then return flag end
  if mana >= on then return true elseif mana < off then return false end
  return flag
end

local function pct(cur, max)
  if type(cur) == "number" and type(max) == "number" and max > 0 then return cur / max * 100 end
end

-- true / false, ou nil si l'aura est illisible (secrète) ou l'API absente.
local function aura(id)
  local st = S.GetAll((C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) or GetPlayerAuraBySpellID, id)
  if st == "lisible" then return true elseif st == "nil" then return false end
end

-- Bouclier posé : n'importe quel rang. nil si une lecture est illisible et aucune n'a trouvé l'aura.
local function shieldUp()
  local unknown
  for _, r in ipairs(spellByKey.PWS.ranks) do
    local a = aura(r.id)
    if a then return true end
    if a == nil then unknown = true end
  end
  if not unknown then return false end
end

-- Recharge restante hors combat quand le suivi de Timers est en mode dégradé (nil) : lecture directe du jeu.
-- Prêt si pas de recharge ou simple recharge globale (<= 1,5 s). En combat : nil, donc jamais supposé prêt.
local function cooldownFallback(key)
  if InCombatLockdown() then return nil end
  local id = Rotation.SpellID(key)
  if not id then return nil end
  local start, dur
  if C_Spell and C_Spell.GetSpellCooldown then
    local st, t = S.GetAll(C_Spell.GetSpellCooldown, id)
    if st ~= "lisible" or type(t) ~= "table" then return nil end
    start, dur = t.startTime, t.duration
  else
    local st, a, b = S.GetAll(GetSpellCooldown, id)
    if st ~= "lisible" then return nil end
    start, dur = a, b
  end
  if S.IsSecret(start) or S.IsSecret(dur) or type(start) ~= "number" or type(dur) ~= "number" then return nil end
  if start == 0 or dur <= 1.5 then return 0 end
  return math.max(0, start + dur - GetTime())
end

local function cooldown(key)
  local r = ns.Timers.CooldownRemaining(key)
  if r ~= nil then return r end
  return cooldownFallback(key)
end

local function bandages()
  local profs = ns.State.profs
  if type(profs) ~= "table" then return nil end
  local p = profs[FIRST_AID]
  local n = 0
  for _, b in ipairs(p and ns.Data.Professions[FIRST_AID].bandages or {}) do
    if b.name:find("^Bandage") and b.skill <= (p.rank or 0) then n = n + (S.Get(GetItemCount, b.itemID) or 0) end
  end
  return n
end

function Rotation.Context()
  local State, Timers = ns.State, ns.Timers
  local ctx = { level = State.level or S.Get(UnitLevel, "player"), inCombat = InCombatLockdown() and true or false }
  ctx.knows = State.Knows
  ctx.cd = cooldown
  local exists = S.Get(UnitExists, "target") == true
  local canAttack = S.Get(UnitCanAttack, "player", "target")
  local dead = exists and S.Get(UnitIsDead, "target") or nil
  ctx.targetDead = dead
  ctx.hasHostileTarget = exists and canAttack ~= false and dead ~= true
  ctx.hasSWP = Timers.HasSWP()
  if ctx.hasHostileTarget and ctx.inCombat and ctx.hasSWP == false then ctx.swpCount = Timers.SWPCount() end
  local w = State.wand
  if type(w) == "table" then ctx.hasWand = true elseif w == false then ctx.hasWand = false end
  ctx.manaPct = pct(S.Get(UnitPower, "player"), S.Get(UnitPowerMax, "player"))
  ctx.hpPct = pct(S.Get(UnitHealth, "player"), S.Get(UnitHealthMax, "player"))
  if exists then
    ctx.targetHpPct = pct(S.Get(UnitHealth, "target"), S.Get(UnitHealthMax, "target"))
    ctx.targetMelee = S.Get(CheckInteractDistance, "target", 3)
  end
  local speed = S.Get(GetUnitSpeed, "player")
  if type(speed) == "number" then ctx.moving = speed > 0
  else ctx.moving = S.Get(IsPlayerMoving) end
  ctx.smitesOnTarget = smites
  ctx.shadowformActive = aura(AURA.SHADOWFORM)
  mbHigh, flayHigh = hyst(mbHigh, ctx.manaPct, REBLAST_ON, REBLAST_OFF), hyst(flayHigh, ctx.manaPct, FLAY_ON, FLAY_OFF)
  ctx.mbHigh, ctx.flayHigh = mbHigh, flayHigh
  local guid = exists and S.Get(UnitGUID, "target") or nil
  if guid then ctx.holyDone = holyGuids[guid] == true else ctx.holyDone = holyThisTarget end
  if not ctx.inCombat then
    -- Bouclier : seulement utile avant d'engager une cible hostile
    if ctx.hasHostileTarget then
      ctx.weakenedSoul = aura(AURA.SHIELD_WEAK)
      ctx.shieldUp = shieldUp()
    end
  end
  if ctx.hasHostileTarget then recoverUntil = nil end
  ctx.recover = not ctx.inCombat and not ctx.hasHostileTarget and recoverUntil ~= nil and GetTime() < recoverUntil
  -- récupération : seulement hors combat, sans cible hostile, avec une vie lisible et basse (ou la carte « Récupère »)
  if not ctx.inCombat and not ctx.hasHostileTarget then
    if ctx.recover or (ctx.hpPct ~= nil and ctx.hpPct < HP_LOW) then
      ctx.recentlyBandaged = aura(AURA.BANDAGE)
      ctx.bandageCount = bandages()
    end
    if dead == true then
      ctx.targetCreatureType = S.Get(UnitCreatureType, "target")
      local id = Rotation.SpellID("CANNIBAL")
      ctx.cannibalUsable = id and S.Get(C_Spell and C_Spell.IsSpellUsable, id) or nil
    end
  end
  return ctx
end

------------------------------------------------------------------------
-- mise à jour
------------------------------------------------------------------------
local lastSig = "|"
local ticking, ticker, tickFrame, acc = false, nil, nil, 0

local function wantTick() return InCombatLockdown() or S.Get(UnitExists, "target") == true end

local function syncTick()
  local want = wantTick()
  if want == ticking then return end
  ticking = want
  local function tick() Rotation.Update() end
  if C_Timer and C_Timer.NewTicker then
    if want then ticker = C_Timer.NewTicker(0.2, tick)
    elseif ticker then ticker:Cancel() ticker = nil end
  else
    tickFrame = tickFrame or CreateFrame("Frame")
    Rotation.tickFrame = tickFrame -- exposé pour les tests
    acc = 0
    tickFrame:SetScript("OnUpdate", want and function(_, dt)
      acc = acc + dt
      if acc >= 0.2 then acc = 0 tick() end
    end or nil)
  end
end

-- force = true : réémet même si rien n'a changé (raccourcis modifiés).
function Rotation.Update(force)
  syncTick()
  local res = Rotation.Compute(Rotation.Context())
  local sig = table.concat(res.keys, ",") .. "|" .. res.text
  Rotation.current = res
  if sig == lastSig and not force then return end
  if sig ~= lastSig then ns.Debug(res.reason) end
  lastSig = sig
  ns.Fire("ROTATION", res)
end

local timersT, tgtT -- GetTime() du dernier TIMERS traité / du dernier changement de cible
local function update() Rotation.Update() end
local function on(e, fn) if not ns.On(e, fn) then ns.Debug("évènement refusé : %s", e) end end

-- Timers.lua émet TIMERS au changement de cible : une seule mise à jour par changement, dans les deux ordres d'écouteurs.
-- shortcut: un TIMERS d'un lancer de sort dans le même cadre qu'un changement de cible est ignoré, le minuteur de 0,2 s rattrape.
on("PLAYER_TARGET_CHANGED", function()
  local now = GetTime()
  local reset = smites ~= 0 or holyThisTarget
  smites, holyThisTarget, tgtT = 0, false, now
  if reset or timersT ~= now then update() end
end)
on("PLAYER_REGEN_DISABLED", function() recoverUntil = nil update() end)
on("PLAYER_REGEN_ENABLED", function()
  holyGuids = {}
  recoverUntil = GetTime() + RECOVER_SECS
  ns.After(RECOVER_SECS + 0.5, update)
  if Rotation.dirty then Rotation.Rescan() else update() end
end)
on("PLAYER_STARTED_MOVING", update)
on("PLAYER_STOPPED_MOVING", update)
ns.Listen("TIMERS", function()
  local now = GetTime()
  if tgtT == now then tgtT = nil return end
  timersT = now
  update()
end)
ns.Listen("STATE", update)
ns.OnUnit("UNIT_AURA", "player", update)
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) then return end
  if holyFireIDs[spellID] then
    local guid = S.Get(UnitGUID, "target")
    if guid then holyGuids[guid] = true else holyThisTarget = true end
    update()
  end
  if not smiteIDs[spellID] then return end
  smites = smites + 1
  update()
end)

-- Raccourcis : une rafale d'évènements = un seul rescan, jamais en combat (marqué sale, refait à la sortie de combat).
function Rotation.Rescan()
  if InCombatLockdown() then Rotation.dirty = true return end
  Rotation.dirty = false
  slotByID, hotCache = nil, {}
  Rotation.Update(true)
end

local pending
local function invalidate()
  Rotation.dirty = true
  if pending then return end
  pending = true
  ns.After(0.2, function() pending = false Rotation.Rescan() end)
end
on("ACTIONBAR_SLOT_CHANGED", invalidate)
on("UPDATE_BINDINGS", invalidate)
