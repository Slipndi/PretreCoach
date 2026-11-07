-- Cadres de groupe pour soigner : le joueur et party1..4, 1 clic = 1 sort choisi par le joueur.
-- EXCEPTION ENCADREE a la Regle 0 (decision du 2026-11-07) : ce fichier est le SEUL a porter des motifs securises
-- (SecureUnitButtonTemplate, SetAttribute, RegisterUnitWatch), comme Clique, HealBot ou Grid. Voir CLAUDE.md.
--  - Les attributs ne sont poses qu'hors combat (sinon differes a PLAYER_REGEN_ENABLED) : type = "spell", spell = nom du
--    sort choisi par le joueur pour ce bouton de souris, unit = l'unite du cadre. Aucune macro, aucun lancement sans clic.
--  - Le sort de chaque bouton est un reglage fixe : il ne change jamais tout seul, ni selon l'etat du jeu.
--  - La vie (possiblement secrete) va telle quelle au StatusBar ; aucun tri, aucune couleur ni comparaison sur elle.
local ADDON, ns = ...
local UI, L, S = ns.UI, ns.L, ns.S

local H = {}
UI.HealFrames = H

local UNITS = { "player", "party1", "party2", "party3", "party4" }
local SLOTS = { "1", "2", "shift-1" } -- bouton de souris : clic gauche, clic droit, maj + clic gauche
local CHOICES = { "LESSERHEAL", "HEAL", "GREATERHEAL", "FLASHHEAL", "RENEW", "PWS", "PWF", "DISPEL", "CUREDISEASE",
  "ABOLISHDISEASE", "FEARWARD", "SHADOWPROT", "RESURRECTION" } -- cles de Data/Spells.lua proposees dans les options
-- Tailles (px) : colonne du nom, barre de vie, barre de mana (prise dans la rangee, sous la vie), espace entre rangees.
local NAME_W, BAR_W, BAR_H, MANA_H, GAP = 70, 200, 18, 3, 4
local PAD, HEAD, NAME_GAP = 8, 8, 6 -- marge dans la bordure doree (haut : HEAD), espace nom/barre ; plus de legende (les clics sont dans l'infobulle)
local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local ROW_W = NAME_W + NAME_GAP + BAR_W

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

-- « Clic gauche : Soins inférieurs », … : ce que fait chaque bouton de souris, d'apres le reglage du joueur.
function H.Bindings()
  local out, spells = {}, spellsDB()
  for _, slot in ipairs(SLOTS) do out[#out + 1] = L.HEAL_SLOT[slot] .. " : " .. (H.SpellName(spells[slot]) or "?") end
  return out
end

-- Legende courte en tete du cadre : G = clic gauche, D = clic droit, Maj = maj + clic gauche.
local function legend()
  if not frame or not frame.legend then return end
  local spells, t = spellsDB(), {}
  for _, slot in ipairs(SLOTS) do t[#t + 1] = L.HEAL_SHORT[slot] .. " " .. (H.SpellName(spells[slot]) or "?") end
  frame.legend:SetText(table.concat(t, "  ·  "))
end

function H.Apply()
  if not built then return end
  legend()
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

-- Couleur de classe (r, g, b) de l'unite ; blanc si la classe est illisible (secrete ou absente).
local function classColor(u)
  local r, g, b = 1, 1, 1
  pcall(function()
    local _, class = UnitClass(u)
    if type(class) ~= "string" or (issecretvalue and issecretvalue(class)) then return end
    local c = C_ClassColor and C_ClassColor.GetClassColor(class) or RAID_CLASS_COLORS[class]
    if c then r, g, b = c.r, c.g, c.b end
  end)
  return r, g, b
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
  b.name:SetTextColor(classColor(u))
  local gone = S.Get(UnitIsConnected, u) == false
  local dead = S.Get(UnitIsDeadOrGhost, u) == true
  if not (b.fbUntil and GetTime() < b.fbUntil) then b.state:SetText(gone and L.HEAL_OFFLINE or (dead and L.HEAL_DEAD or "")) end
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
  -- meme approche que ManaBar : BackdropTemplate sous pcall (repli sans), bordure doree du jeu
  local ok, f = pcall(CreateFrame, "Frame", "PretreCoachHealFrame", UIParent, "BackdropTemplate")
  if not ok or not f then f = CreateFrame("Frame", "PretreCoachHealFrame", UIParent) end
  frame = f
  H.frame = frame
  pcall(function()
    frame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    frame:SetBackdropColor(0.05, 0.04, 0.08, 0.85)
    frame:SetBackdropBorderColor(1, 0.82, 0)
  end)
  frame:SetSize(ROW_W + 2 * PAD, HEAD + PAD + #UNITS * (BAR_H + GAP) - GAP)
  frame:SetPoint("LEFT", UIParent, "LEFT", 20, 0)
  UI.Movable(frame, "heal")
  for i, unit in ipairs(UNITS) do
    local b = CreateFrame("Button", "PretreCoachHeal" .. i, frame, "SecureUnitButtonTemplate")
    b:SetSize(ROW_W, BAR_H) -- le bouton couvre toute la rangee (nom + barre)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(HEAD + (i - 1) * (BAR_H + GAP)))
    b:RegisterForClicks("AnyUp", "AnyDown") -- Retail : le gabarit securise agit sur l'appui ou le relachement selon ActionButtonUseKeyDown
    b.unit = unit
    b.name = b:CreateFontString(nil, "OVERLAY", UI.font.small) -- nom a gauche, hors de la barre
    b.name:SetPoint("LEFT", b, "LEFT")
    b.name:SetWidth(NAME_W)
    b.name:SetJustifyH("LEFT")
    pcall(b.name.SetWordWrap, b.name, false) -- tronque au lieu de passer a la ligne
    b.bar = CreateFrame("StatusBar", nil, b)
    b.bar:SetPoint("TOPRIGHT", b, "TOPRIGHT")
    b.bar:SetSize(BAR_W, BAR_H - MANA_H)
    pcall(b.bar.SetStatusBarTexture, b.bar, BAR)
    b.bar:SetStatusBarColor(0.1, 0.8, 0.1) -- vert fixe
    b.bar:SetMinMaxValues(0, 1)
    b.bar:SetValue(1)
    local bg = b.bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(b.bar)
    bg:SetTexture(BAR)
    bg:SetVertexColor(0.2, 0.2, 0.2, 0.5)
    b.mana = CreateFrame("StatusBar", nil, b) -- fine barre de mana collee sous la vie, dans la rangee
    b.mana:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT")
    b.mana:SetSize(BAR_W, MANA_H)
    pcall(b.mana.SetStatusBarTexture, b.mana, BAR)
    local mc = { 0, 0.44, 0.87 }
    pcall(function() local p = PowerBarColor["MANA"] mc = { p.r, p.g, p.b } end)
    b.mana:SetStatusBarColor(mc[1], mc[2], mc[3])
    b.mana:SetMinMaxValues(0, 1)
    b.mana:SetValue(1)
    b.state = b.bar:CreateFontString(nil, "OVERLAY", UI.font.small) -- etat a droite, dans la barre
    b.state:SetPoint("RIGHT", b.bar, "RIGHT", -4, 0)
    -- scripts non securises : infobulle des clics et memoire du dernier clic (retour visuel), aucun lancement
    b:SetScript("OnEnter", function(self)
      pcall(function()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(UnitName(self.unit) or self.unit)
        for _, line in ipairs(H.Bindings()) do GameTooltip:AddLine(line, 1, 1, 1) end
        GameTooltip:AddLine(L.HEAL_HOWTO, 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
      end)
    end)
    b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    b:SetScript("PostClick", function(self) H.lastClick = { b = self, t = GetTime() } end)
    H.buttons[i], byUnit[unit] = b, b
    applyClicks(b)
    if RegisterUnitWatch then RegisterUnitWatch(b) end
  end
  legend()
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

-- Retour visuel : sort reussi ou rate dans les 3 s qui suivent un clic sur un cadre (spellID lisible meme en combat).
local function feedback(ok, spellID)
  local c = H.lastClick
  if not c or GetTime() - c.t > 3 then return end
  H.lastClick = nil
  local name = type(spellID) == "number" and S.Get(C_Spell and C_Spell.GetSpellName, spellID) or nil
  local text = (ok and "|cff33ff33✓ " or "|cffff4444✗ ") .. (type(name) == "string" and name or "") .. "|r"
  c.b.state:SetText(text)
  c.b.fbUntil = GetTime() + 2 -- Refresh laisse le message 2 s
  H.feedbackText = text
end
ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID) feedback(true, spellID) end)
ns.OnUnit("UNIT_SPELLCAST_FAILED", "player", function(_, _, _, spellID) feedback(false, spellID) end)
for _, e in ipairs({ "UNIT_HEALTH", "UNIT_MAXHEALTH", "UNIT_CONNECTION", "UNIT_NAME_UPDATE", "UNIT_FLAGS" }) do
  ns.On(e, function(_, u)
    local b = built and byUnit[u]
    if b then H.Refresh(b) end
  end)
end
