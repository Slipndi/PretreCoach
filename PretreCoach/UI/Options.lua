-- Options : entrée dans Paramètres > Addons si l'API existe, sinon fenêtre maison. Contrôles faits main (aucun modèle).
-- Chaque changement est appliqué tout de suite et écrit dans ns.db.
local ADDON, ns = ...
local UI, L = ns.UI, ns.L
local C = UI.color

local O = { controls = {} }
UI.Options = O
local WHITE = "Interface\\Buttons\\WHITE8X8"
local loading = false -- vrai pendant Refresh : SetValue ne doit pas réécrire la base

local function checkbox(parent, label, y, get, set)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(20, 20)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -y)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(b)
  bg:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
  b.check = b:CreateTexture(nil, "ARTWORK")
  b.check:SetAllPoints(b)
  b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  local fs = b:CreateFontString(nil, "OVERLAY", UI.font.text)
  fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
  fs:SetText(label)
  b.refresh = function() b.check:SetShown(get() and true or false) end
  b:SetScript("OnClick", function()
    set(not get())
    b.refresh()
  end)
  return b
end

local function slider(parent, y, lo, hi, labelKey, get, set)
  local fs = parent:CreateFontString(nil, "OVERLAY", UI.font.text)
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -y)
  local s = CreateFrame("Slider", nil, parent)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(220, 16)
  s:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -(y + 22))
  local track = s:CreateTexture(nil, "BACKGROUND")
  track:SetPoint("LEFT", s, "LEFT")
  track:SetPoint("RIGHT", s, "RIGHT")
  track:SetHeight(4)
  track:SetColorTexture(1, 1, 1, 0.15)
  s:SetThumbTexture(WHITE)
  local thumb = s:GetThumbTexture()
  if thumb then
    thumb:SetSize(8, 16)
    thumb:SetVertexColor(C.accent[1], C.accent[2], C.accent[3])
  end
  s:SetMinMaxValues(lo, hi)
  s:SetValueStep(0.05)
  pcall(s.SetObeyStepOnDrag, s, true)
  local function show(v) fs:SetText(L[labelKey]:format(math.floor(v * 100 + 0.5))) end
  s:SetScript("OnValueChanged", function(_, v)
    if loading then return end
    v = math.max(lo, math.min(hi, math.floor(v * 20 + 0.5) / 20))
    show(v)
    set(v)
  end)
  s.refresh = function()
    local v = get()
    loading = true
    s:SetValue(v)
    loading = false
    show(v)
  end
  return s
end

-- Sort d'un bouton de souris des cadres de soin : clic gauche = suivant, clic droit = precedent.
local function cycle(parent, y, slot)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(320, 20)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -y)
  b:RegisterForClicks("AnyUp")
  local fs = b:CreateFontString(nil, "OVERLAY", UI.font.text)
  fs:SetPoint("LEFT", b, "LEFT")
  b.refresh = function()
    fs:SetText(L.HEAL_SLOT[slot] .. " : " .. (UI.HealFrames.SpellName(ns.db.heal and ns.db.heal.spells[slot] or ns.DEFAULTS.heal.spells[slot]) or "?"))
  end
  b:SetScript("OnClick", function(_, btn)
    UI.HealFrames.Cycle(slot, btn == "RightButton" and -1 or 1)
    b.refresh()
  end)
  return b
end

-- Choix des quêtes (ns.db.guide.focus) : chaque clic passe à la valeur suivante.
local FOCI = { "gold", "balanced", "xp" }
local function focusButton(parent, y)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(320, 20)
  b:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -y)
  local fs = b:CreateFontString(nil, "OVERLAY", UI.font.text)
  fs:SetPoint("LEFT", b, "LEFT")
  local function cur() return L["FOCUS_" .. tostring(ns.db.guide.focus)] and ns.db.guide.focus or "gold" end
  b.refresh = function() fs:SetText(L.OPT_FOCUS:format(L["FOCUS_" .. cur()])) end
  b:SetScript("OnClick", function()
    for i, k in ipairs(FOCI) do if k == cur() then ns.db.guide.focus = FOCI[i % #FOCI + 1] break end end
    b.refresh()
    if ns.Quests then ns.Quests.Refresh() end
  end)
  return b
end

local function showSet(key, apply)
  return function() return ns.db.show[key] ~= false end, function(v)
    ns.db.show[key] = v
    if apply then apply(v) end
  end
end

local function build(parent, y)
  local c = O.controls
  local function check(key, label, get, set)
    c[key] = checkbox(parent, label, y, get, set)
    y = y + 24
  end
  check("guide", L.OPT_GUIDE, showSet("guide", function(v) if ns.SetGuideShown then ns.SetGuideShown(v) end end))
  check("rotation", L.OPT_ROTATION, showSet("rotation", function() if UI.RotationPanel then UI.RotationPanel.Render() end end))
  check("rules", L.OPT_RULES, showSet("rules", function() if UI.RulesBar then UI.RulesBar.Render() end end))
  check("toasts", L.OPT_TOASTS, showSet("toasts"))
  check("progress", L.OPT_PROGRESS, showSet("progress", function() if UI.ProgressBar then UI.ProgressBar.Render() end end))
  check("heal", L.OPT_HEAL, showSet("heal", function() if UI.HealFrames then UI.HealFrames.Render() end end))
  check("cons", L.OPT_CONS, showSet("cons", function() if UI.ConsumablesBar then UI.ConsumablesBar.Render() end end))
  check("craft", L.OPT_CRAFT, showSet("craft", function() if UI.CraftPopup then UI.CraftPopup.Sync() end end))
  check("mana", L.OPT_MANA, showSet("mana", function() if UI.ManaBar then UI.ManaBar.Render() end end))
  check("gold", L.OPT_GOLD, showSet("gold", function() ns.Fire("GUIDE") end))
  check("wandbar",L.OPT_WANDBAR, showSet("wandbar", function() if UI.RotationPanel then UI.RotationPanel.UpdateWand() end end))
  check("questpins", L.OPT_QUESTPINS, showSet("questpins", function() if UI.QuestPins then UI.QuestPins.Update() end end))
  check("herbpins", L.OPT_HERBPINS, showSet("herbpins", function() if UI.QuestPins then UI.QuestPins.Update() end end))
  check("questreward", L.OPT_QUESTREWARD, showSet("questreward", function() if UI.QuestReward then UI.QuestReward.Update() end end))
  check("keeptip", L.OPT_KEEPTIP, showSet("keeptip"))
  c.focus = focusButton(parent, y)
  y = y + 24
  check("minimap", L.OPT_MINIMAP, showSet("minimap", function() if ns.RefreshMinimap then ns.RefreshMinimap() end end))
  check("locked", L.OPT_LOCKED, function() return ns.db.locked end, function(v) ns.db.locked = v end)
  check("compact", L.OPT_COMPACT, function() return ns.db.guide.compact end, function(v)
    -- guide ouvert : on change de vue tout de suite, sinon on mémorise seulement
    if ns.db.guide.open and ns.SetCompact then ns.SetCompact(v) else ns.db.guide.compact = v end
  end)
  check("every", L.OPT_EVERY, function() return ns.db.training.every == 2 end,
    function(v) ns.db.training.every = v and 2 or 1 end)
  check("debug", L.OPT_DEBUG, function() return ns.db.debug end, function(v) ns.db.debug = v end)
  c.scale = slider(parent, y + 6, 0.6, 1.6, "OPT_SCALE", function() return ns.db.scale end, UI.SetScale)
  c.opacity = slider(parent, y + 56, 0.3, 1, "OPT_OPACITY", function() return ns.db.opacity end, UI.SetOpacity)
  for i, slot in ipairs({ "1", "2", "shift-1" }) do
    c["heal" .. slot] = cycle(parent, y + 76 + i * 24, slot)
  end
  return y + 176
end

function ns.RefreshOptions()
  if not ns.db then return end
  for _, ctl in pairs(O.controls) do ctl.refresh() end
end

local category
local function title(parent)
  local t = parent:CreateFontString(nil, "OVERLAY", UI.font.title)
  t:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, -14)
  t:SetText(L.OPT_TITLE)
end

-- Fenêtre maison (repli), construite à la première ouverture.
local function window()
  if O.win then return O.win end
  local w = UI.Panel("PretreCoachOptionsFrame", UIParent)
  O.win = w
  w:SetPoint("CENTER")
  w:SetFrameStrata("DIALOG")
  w:Hide()
  UI.Movable(w, "options")
  tinsert(UISpecialFrames, "PretreCoachOptionsFrame")
  title(w)
  w:SetSize(360, build(w, 44) + 8)
  local close = CreateFrame("Button", nil, w)
  close:SetSize(20, 18)
  close:SetPoint("TOPRIGHT", w, "TOPRIGHT", -6, -6)
  local x = close:CreateFontString(nil, "OVERLAY", UI.font.text)
  x:SetPoint("CENTER", close, "CENTER")
  x:SetText("×")
  close:SetScript("OnClick", function() w:Hide() end)
  w:SetScript("OnShow", ns.RefreshOptions)
  return w
end

function ns.ToggleOptions()
  if category then
    local id = category.ID
    if not id and category.GetID then id = category:GetID() end
    if id ~= nil and pcall(Settings.OpenToCategory, id) then return end
  end
  local w = window()
  if w:IsShown() then w:Hide() else w:Show() end
end

-- Paramètres > Addons si l'API existe (sinon ToggleOptions ouvre la fenêtre maison).
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
  local panel = CreateFrame("Frame")
  title(panel)
  build(panel, 44)
  panel:SetScript("OnShow", ns.RefreshOptions)
  category = Settings.RegisterCanvasLayoutCategory(panel, L.MINIMAP_TITLE)
  Settings.RegisterAddOnCategory(category)
  O.panel = panel
end
