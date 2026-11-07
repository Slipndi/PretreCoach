-- Cadres de groupe pour soigner : le joueur et party1..4, 1 clic = 1 sort choisi par le joueur.
-- EXCEPTION ENCADREE a la Regle 0 (decision du 2026-11-07) : ce fichier est le SEUL a porter des motifs securises
-- (SecureUnitButtonTemplate, SetAttribute, RegisterUnitWatch), comme Clique, HealBot ou Grid. Voir CLAUDE.md.
--  - Les attributs ne sont poses qu'hors combat (sinon differes a PLAYER_REGEN_ENABLED) : type = "spell", spell = nom du
--    sort choisi par le joueur pour ce bouton de souris, unit = l'unite du cadre. Aucune macro, aucun lancement sans clic.
--  - Le sort de chaque bouton est un reglage fixe : il ne change jamais tout seul, ni selon l'etat du jeu.
--  - La vie (possiblement secrete) va telle quelle au StatusBar ; aucun tri, aucune couleur ni comparaison sur elle.
local ADDON, ns = ...
local UI, L, S = ns.UI, ns.L, ns.S
local C = UI.color

local H = {}
UI.HealFrames = H

local UNITS = { "player", "party1", "party2", "party3", "party4" }
local SLOTS = { "1", "2", "shift-1" } -- bouton de souris : clic gauche, clic droit, maj + clic gauche
local CHOICES = { "LESSERHEAL", "HEAL", "GREATERHEAL", "FLASHHEAL", "RENEW", "PWS", "PWF", "DISPEL", "CUREDISEASE",
  "ABOLISHDISEASE", "FEARWARD", "SHADOWPROT", "RESURRECTION" } -- cles de Data/Spells.lua proposees dans les options
local W, HT, GAP, PAD, HEAD, MANA = 130, 28, 2, 4, 12, 4
local WHITE = "Interface\\Buttons\\WHITE8X8"

H.SLOTS = SLOTS
H.buttons = {}
local frame, built, dirty
local byUnit = {}

local function entry(key)
  for _, e in ipairs(ns.Data.Spells) do if e.key == key then return e end end
end

-- Nom du sort donne par le client (sans rang : le jeu prend le plus haut rang connu) ; repli sur le nom des donnees.
function H.SpellName(key)
  local e = entry(key)
  if not e then return nil end
  local id = e.ranks[#e.ranks].id
  local ok, name = pcall(function() return C_Spell.GetSpellName(id) end)
  return (ok and type(name) == "string" and name ~= "") and name or e.name
end

-- Sorts proposes : ceux dont un rang est connu (tous si l'API manque), plus le choix courant.
function H.Choices(current)
  local out = {}
  for _, key in ipairs(CHOICES) do
    local e = entry(key)
    if e then
      local known = key == current or not IsPlayerSpell
      for _, r in ipairs(e.ranks) do
        if known then break end
        local ok, k = pcall(IsPlayerSpell, r.id)
        known = ok and k == true
      end
      if known then out[#out + 1] = key end
    end
  end
  return out
end

-- Sort choisi par bouton de souris (reglage du joueur, defauts si la base n'en a pas).
local function spellsDB()
  return ns.db.heal and ns.db.heal.spells or ns.DEFAULTS.heal.spells
end

-- Pose les attributs de clic d'un bouton. Appelee seulement hors combat (voir H.Apply).
local function applyClicks(b)
  local spells = spellsDB()
  b:SetAttribute("unit", b.unit)
  for _, slot in ipairs(SLOTS) do
    local prefix, num = slot:match("^(.-)(%d+)$")
    local name = H.SpellName(spells[slot])
    b:SetAttribute(prefix .. "type" .. num, name and "spell" or nil)
    b:SetAttribute(prefix .. "spell" .. num, name)
  end
end

function H.Apply()
  if not built then return end
  if InCombatLockdown() then dirty = true return end
  dirty = false
  for _, b in ipairs(H.buttons) do applyClicks(b) end
end

-- Change le sort d'un bouton de souris (dir = 1 suivant, -1 precedent) ; les attributs suivent hors combat.
function H.Cycle(slot, dir)
  ns.db.heal = ns.db.heal or { spells = {} }
  ns.db.heal.spells = ns.db.heal.spells or {}
  local spells = ns.db.heal.spells
  spells[slot] = spells[slot] or ns.DEFAULTS.heal.spells[slot]
  local list = H.Choices(spells[slot])
  local at = 1
  for i, k in ipairs(list) do if k == spells[slot] then at = i end end
  spells[slot] = list[(at - 1 + (dir or 1)) % #list + 1] or spells[slot]
  H.Apply()
  return spells[slot]
end

-- Affichage seul : peut tourner en combat, ne touche jamais aux attributs ni a la visibilite du bouton securise.
function H.Refresh(b)
  local u = b.unit
  if S.Get(UnitExists, u) ~= true then return end
  -- vie secrete possible : donnee telle quelle au StatusBar, sans comparaison ni calcul
  pcall(function()
    b.bar:SetMinMaxValues(0, S.Raw(UnitHealthMax, u))
    b.bar:SetValue(S.Raw(UnitHealth, u))
  end)
  pcall(function() -- mana (type 0) : meme principe, valeur brute donnee telle quelle
    b.mana:SetMinMaxValues(0, S.Raw(UnitPowerMax, u, 0))
    b.mana:SetValue(S.Raw(UnitPower, u, 0))
  end)
  pcall(b.name.SetText, b.name, UnitName(u))
  local gone = S.Get(UnitIsConnected, u) == false
  local dead = S.Get(UnitIsDeadOrGhost, u) == true
  b.state:SetText(gone and L.HEAL_OFFLINE or (dead and L.HEAL_DEAD or ""))
  b:SetAlpha(S.Get(UnitInRange, u) == false and 0.45 or 1) -- portee illisible : le cadre reste opaque
end

function H.Render()
  if not built then return end
  if not InCombatLockdown() then -- masquage hors combat seulement (le cadre contient des boutons securises)
    frame:SetShown((ns.db.show or {}).heal ~= false) -- visible aussi seul : le bouton du joueur reste la
    if not RegisterUnitWatch then
      for _, b in ipairs(H.buttons) do b:SetShown(S.Get(UnitExists, b.unit) == true) end
    end
  end
  for _, b in ipairs(H.buttons) do H.Refresh(b) end
end

-- Creation hors combat uniquement : sinon reprise a PLAYER_REGEN_ENABLED.
function H.Build()
  if built or not ns.db or InCombatLockdown() then return end
  built = true
  frame = UI.Panel("PretreCoachHealFrame", UIParent)
  H.frame = frame
  frame:SetSize(W + 2 * PAD, HEAD + PAD + #UNITS * (HT + GAP))
  frame:SetPoint("LEFT", UIParent, "LEFT", 20, 0)
  UI.Movable(frame, "heal")
  for i, unit in ipairs(UNITS) do
    local b = CreateFrame("Button", "PretreCoachHeal" .. i, frame, "SecureUnitButtonTemplate")
    b:SetSize(W, HT)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(HEAD + (i - 1) * (HT + GAP)))
    b:RegisterForClicks("AnyUp")
    b.unit = unit
    b.bar = CreateFrame("StatusBar", nil, b)
    b.bar:SetPoint("TOPLEFT", b, "TOPLEFT")
    b.bar:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, MANA + 1)
    b.mana = CreateFrame("StatusBar", nil, b) -- fine barre de mana sous la vie, bleu fixe
    b.mana:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT")
    b.mana:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT")
    b.mana:SetHeight(MANA)
    pcall(b.mana.SetStatusBarTexture, b.mana, WHITE)
    b.mana:SetStatusBarColor(0.25, 0.45, 0.95)
    b.mana:SetMinMaxValues(0, 1)
    b.mana:SetValue(1)
    pcall(b.bar.SetStatusBarTexture, b.bar, WHITE)
    b.bar:SetStatusBarColor(C.good[1], C.good[2], C.good[3]) -- vert fixe
    b.bar:SetMinMaxValues(0, 1)
    b.bar:SetValue(1)
    b.name = b.bar:CreateFontString(nil, "OVERLAY", UI.font.small)
    b.name:SetPoint("LEFT", b, "LEFT", 4, 0)
    b.state = b.bar:CreateFontString(nil, "OVERLAY", UI.font.small)
    b.state:SetPoint("RIGHT", b, "RIGHT", -4, 0)
    H.buttons[i], byUnit[unit] = b, b
    applyClicks(b)
    if RegisterUnitWatch then RegisterUnitWatch(b) end
  end
  -- portee : relue deux fois par seconde tant que les cadres sont visibles
  local t = 0
  frame:SetScript("OnUpdate", function(_, dt)
    t = t + (dt or 0)
    if t < 0.5 then return end
    t = 0
    for _, b in ipairs(H.buttons) do H.Refresh(b) end
  end)
  H.Render()
end

ns.On("ADDON_LOADED", function(_, name)
  if name == ADDON then H.Build() end
end)
ns.On("PLAYER_REGEN_ENABLED", function()
  if not built then H.Build() return end
  if dirty then H.Apply() end
  H.Render()
end)
ns.On("GROUP_ROSTER_UPDATE", H.Render)
for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_CONNECTION", "UNIT_NAME_UPDATE", "UNIT_FLAGS" }) do
  ns.On(e, function(_, u)
    local b = built and byUnit[u]
    if b then H.Refresh(b) end
  end)
end
