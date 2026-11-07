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
local REBLAST_MANA = 60  -- Attaque mentale reconseillée au-delà
local FLAY_MANA = 30     -- Fouet mental pour combler au-delà
local BURST_MIN_HP = 25  -- cible presque morte : pas de sort, on achève
local SMITE_UNTIL = 35   -- Châtiment tant que la vie de la cible est au-dessus
local HP_LOW, HP_OK, MANA_LOW = 60, 70, 50
local SMITE_BLIND = 2    -- Châtiments avant le corps à corps quand la vie de la cible est illisible

local AURA = { SHIELD_WEAK = 6788, SHADOWFORM = 15473, BANDAGE = 11196 }
local FIRST_AID = 129

local ICON = { MELEE = "Interface\\Icons\\Ability_MeleeDamage", BANDAGE = "Interface\\Icons\\INV_Misc_Bandage_12",
  DRINK = "Interface\\Icons\\INV_Drink_04", EAT = "Interface\\Icons\\INV_Misc_Food_14" }

local edible = { Humanoid = true, Undead = true } -- repli sur les noms anglais, au cas où le client ne soit pas en français
edible[L.CT_HUMANOID] = true
edible[L.CT_UNDEAD] = true

------------------------------------------------------------------------
-- logique pure
------------------------------------------------------------------------
function Rotation.Compute(ctx)
  local out = { keys = {}, text = "", reason = "" }
  local keys = out.keys
  local function add(k, text, why)
    if #keys >= 3 then return end
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
      if #keys == 0 then out.reason = "vie ou mana illisible : rien à récupérer" end
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
  local tier = lvl < 10 and 1 or (lvl < 40 and 2 or 3)
  local mana, tgtHp = ctx.manaPct, ctx.targetHpPct
  local canCast = not (mana ~= nil and mana < MIN_MANA) and not (tgtHp ~= nil and tgtHp < BURST_MIN_HP)
  local wand = ctx.hasWand == true

  if not ctx.inCombat and ready("PWS") and ctx.weakenedSoul == false and ctx.shieldUp ~= true then
    add("PWS", L.ROT_PWS, "avant d'engager : Bouclier connu, prêt, sans Âme affaiblie")
  end

  if canCast then
    local swp = ctx.hasSWP
    if tier == 1 then
      if known("SWP") and swp == false then add("SWP", L.ROT_SWP, "ouverture : Douleur absente de la cible") end
    elseif tier == 2 then
      if swp == false then
        if ready("MINDBLAST") then add("MINDBLAST", L.ROT_OPEN_MB, "ouverture : Attaque mentale prête")
        elseif known("HOLYFIRE") then add("HOLYFIRE", L.ROT_OPEN_HF, "ouverture : Flammes sacrées") end
        if known("SWP") then add("SWP", L.ROT_SWP, "Douleur absente de la cible") end
      elseif swp == true and mana ~= nil and mana >= REBLAST_MANA and ready("MINDBLAST") then
        add("MINDBLAST", L.ROT_MB, "mana lisible et haut : Attaque mentale reconseillée")
      end
    else
      if swp == false then
        if ready("MINDBLAST") then add("MINDBLAST", L.ROT_OPEN_MB, "ouverture en Forme d'Ombre : Attaque mentale") end
        if known("SWP") then add("SWP", L.ROT_SWP, "Douleur absente de la cible") end
      end
      if ready("SWD") then add("SWD", L.ROT_SWD, "Mot de l'ombre : Mort prêt") end
      if ready("MINDBLAST") then add("MINDBLAST", L.ROT_MB, "Attaque mentale prête") end
      if known("MINDFLAY") and mana ~= nil and mana >= FLAY_MANA then
        add("MINDFLAY", L.ROT_FLAY, "mana lisible : Fouet mental pour combler")
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
  end

  -- sorts à recharge en cours : affichés à la fin, icône grisée
  if tier >= 2 and known("MINDBLAST") and (ctx.cd and ctx.cd("MINDBLAST") or 0) > 0 then add("MINDBLAST", L.ROT_MB, "") end
  if tier == 3 and known("SWD") and (ctx.cd and ctx.cd("SWD") or 0) > 0 then add("SWD", L.ROT_SWD, "") end

  if ctx.targetMelee == true and ready("PSCREAM") then
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
local spellByKey = {}
for _, sp in ipairs(ns.Data.Spells) do spellByKey[sp.key] = sp end

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
    { 49, "MULTIACTIONBAR2BUTTON" }, { 61, "MULTIACTIONBAR1BUTTON" } }
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

-- Raccourci court du sort, ou nil. Sans C_ActionBar.FindSpellActionButtons : scan de GetActionInfo(1..120), jamais en combat.
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
        for _, slot in ipairs(slots) do text = text or bindingText(slot) end
        if text then break end
      end
    end
  else
    if InCombatLockdown() then return nil end
    if not slotByID then
      slotByID = {}
      for slot = 1, 120 do
        local st, kind, id = S.GetAll(GetActionInfo, slot)
        if st == "lisible" and kind == "spell" and type(id) == "number" and not slotByID[id] then slotByID[id] = slot end
      end
    end
    for i = #sp.ranks, 1, -1 do
      text = bindingText(slotByID[sp.ranks[i].id])
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
local smiteIDs = {}
for _, r in ipairs(spellByKey.SMITE.ranks) do smiteIDs[r.id] = true end

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
  ctx.cd = Timers.CooldownRemaining
  local exists = S.Get(UnitExists, "target") == true
  local canAttack = S.Get(UnitCanAttack, "player", "target")
  local dead = exists and S.Get(UnitIsDead, "target") or nil
  ctx.targetDead = dead
  ctx.hasHostileTarget = exists and canAttack ~= false and dead ~= true
  ctx.hasSWP = Timers.HasSWP()
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
  ctx.weakenedSoul = aura(AURA.SHIELD_WEAK)
  ctx.shieldUp = shieldUp()
  ctx.shadowformActive = aura(AURA.SHADOWFORM)
  if not ctx.inCombat and not ctx.hasHostileTarget then
    ctx.recentlyBandaged = aura(AURA.BANDAGE)
    ctx.bandageCount = bandages()
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

local function update() Rotation.Update() end
local function on(e, fn) if not ns.On(e, fn) then ns.Debug("évènement refusé : %s", e) end end

on("PLAYER_TARGET_CHANGED", function() smites = 0 update() end)
on("PLAYER_REGEN_DISABLED", update)
on("PLAYER_REGEN_ENABLED", update)
on("PLAYER_STARTED_MOVING", update)
on("PLAYER_STOPPED_MOVING", update)
ns.Listen("TIMERS", update)
ns.Listen("STATE", update)
ns.OnUnit("UNIT_AURA", "player", update)
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or not smiteIDs[spellID] then return end
  smites = smites + 1
  update()
end)

local function invalidate()
  slotByID, hotCache = nil, {}
  Rotation.Update(true)
end
on("ACTIONBAR_SLOT_CHANGED", invalidate)
on("UPDATE_BINDINGS", invalidate)
