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
  return y + 100
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
