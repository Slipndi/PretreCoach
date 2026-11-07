-- Mini menu du bouton de minicarte : cadres et boutons non sécurisés, chaque ligne appelle ns.RunCommand.
local _, ns = ...
local L, UI = ns.L, ns.UI

local NAME, W, ROW, SEP, PAD, IDLE = "PretreCoachMinimapMenu", 210, 22, 9, 6, 2

local function db() return ns.db or {} end
-- cmd : commande lancée ; check : coche reflétant l'état (la ligne reste alors ouverte) ; label peut être une fonction.
local ENTRIES = {
  { label = L.MENU_GUIDE, cmd = "guide" },
  { label = L.MENU_COMPACT, cmd = "compact", check = function() return db().guide and db().guide.compact end },
  { label = L.MENU_OPTIONS, cmd = "" },
  "sep",
  { label = function() return db().locked and L.MENU_UNLOCK or L.MENU_LOCK end,
    cmd = function() return db().locked and "unlock" or "lock" end },
  { label = L.MENU_RESET, cmd = "reset" },
  "sep",
  { label = L.MENU_PROBE, cmd = "probe" },
  { label = L.MENU_DEBUG, cmd = "debug", check = function() return db().debug end },
  "sep",
  { label = L.MENU_CLOSE },
}

local menu, rows, anchorFrame, idle

local function refresh()
  for _, r in ipairs(rows) do
    local e = r.entry
    r.text:SetText(type(e.label) == "function" and e.label() or e.label)
    if r.check then r.check:SetShown(e.check() and true or false) end
  end
end

local function close() if menu then menu:Hide() end end

local function build()
  menu = UI.Panel(NAME, UIParent)
  rows = {}
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetClampedToScreen(true)
  menu:EnableMouse(true)
  menu:Hide()
  local y = -PAD
  for _, e in ipairs(ENTRIES) do
    if e == "sep" then
      local t = menu:CreateTexture(nil, "ARTWORK")
      local c = UI.color.border
      t:SetColorTexture(c[1], c[2], c[3], 1)
      t:SetPoint("TOPLEFT", menu, "TOPLEFT", PAD, y - SEP / 2)
      t:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -PAD, y - SEP / 2)
      t:SetHeight(1)
      y = y - SEP
    else
      local b = CreateFrame("Button", nil, menu)
      b:SetHeight(ROW)
      b:SetPoint("TOPLEFT", menu, "TOPLEFT", PAD, y)
      b:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -PAD, y)
      local hl = b:CreateTexture(nil, "BACKGROUND")
      hl:SetAllPoints(b)
      local a = UI.color.accent
      hl:SetColorTexture(a[1], a[2], a[3], 0.3)
      hl:Hide()
      b:SetScript("OnEnter", function() hl:Show() end)
      b:SetScript("OnLeave", function() hl:Hide() end)
      local r = { btn = b, entry = e, hl = hl }
      r.text = b:CreateFontString(nil, "OVERLAY")
      pcall(r.text.SetFontObject, r.text, UI.font.text)
      r.text:SetPoint("LEFT", b, "LEFT", 22, 0)
      if e.check then
        r.check = b:CreateTexture(nil, "OVERLAY")
        r.check:SetSize(14, 14)
        r.check:SetPoint("LEFT", b, "LEFT", 4, 0)
        r.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
      end
      b:SetScript("OnClick", function()
        local cmd = type(e.cmd) == "function" and e.cmd() or e.cmd
        if cmd then ns.RunCommand(cmd) end
        if e.check then refresh() else close() end
      end)
      rows[#rows + 1] = r
      y = y - ROW
    end
  end
  menu:SetSize(W, -y + PAD)
  tinsert(UISpecialFrames, NAME)
  menu:SetScript("OnShow", function() idle = 0 refresh() end)
  -- Fermeture après IDLE s hors du menu et de son bouton ; le script ne tourne que menu ouvert.
  menu:SetScript("OnUpdate", function(self, dt)
    local over = false
    for _, f in ipairs({ self, anchorFrame }) do
      local ok, res = pcall(f.IsMouseOver, f)
      if ok and res then over = true end
    end
    idle = over and 0 or idle + (dt or 0)
    if idle >= IDLE then self:Hide() end
  end)
  menu:SetScript("OnHide", function() anchorFrame = nil end)
  ns.On("PLAYER_REGEN_DISABLED", close)
end

-- Ancré au bouton ; s'ouvre vers le haut / la gauche si le bouton est dans la moitié basse / droite de l'écran.
local function place(anchor)
  menu:ClearAllPoints()
  local cx, cy = anchor:GetCenter()
  local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
  local ratio = (anchor:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
  local up = cy and sh and cy * ratio < sh / 2
  local left = cx and sw and cx * ratio > sw / 2
  local v1, v2 = up and "BOTTOM" or "TOP", up and "TOP" or "BOTTOM"
  local h = left and "RIGHT" or "LEFT"
  menu:SetPoint(v1 .. h, anchor, v2 .. h, 0, 0)
end

function ns.ToggleMinimapMenu(anchor)
  if not menu then build() end
  if menu:IsShown() then close() return end
  if InCombatLockdown() then
    ns.Toast(L.MENU_COMBAT, { key = "menu_combat", cooldown = 2 })
    return
  end
  anchorFrame = anchor -- sans bouton (compartiment) : au centre de l'écran
  if anchor then
    place(anchor)
  else
    menu:ClearAllPoints()
    menu:SetPoint("CENTER", UIParent, "CENTER")
  end
  menu:Show()
end

function UI.MenuRows() return rows, menu end -- accessible aux tests
