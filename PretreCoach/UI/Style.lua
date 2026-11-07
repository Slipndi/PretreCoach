-- Kit d'interface commun : couleurs, polices, panneau, déplacement, icône à lueur. Aucun BackdropTemplate.
local ADDON, ns = ...
local UI = {}
ns.UI = UI

UI.color = {
  bg = { 0.05, 0.04, 0.08, 0.85 }, border = { 0.35, 0.28, 0.5, 1 },
  accent = { 0.69, 0.52, 1 }, white = { 0.95, 0.95, 1 },
  good = { 0.3, 0.85, 0.4 }, warn = { 1, 0.6, 0.1 }, bad = { 0.9, 0.2, 0.2 },
}
UI.font = { title = "GameFontNormalLarge", text = "GameFontHighlight", small = "GameFontHighlightSmall" }

local panels, movables, pending = {}, {}, {}

-- Les cadres de l'addon ne sont pas sécurisés, mais en combat on reporte quand même SetPoint/SetSize.
local function later(fn)
  if InCombatLockdown() then pending[#pending + 1] = fn else fn() end
end
ns.On("PLAYER_REGEN_ENABLED", function()
  local q = pending
  pending = {}
  for _, fn in ipairs(q) do fn() end
end)

local function opacity() return (ns.db and ns.db.opacity) or 1 end

local function paint(p)
  local c = UI.color.bg
  p.bg:SetColorTexture(c[1], c[2], c[3], c[4] * opacity())
end

-- Cadre stylé : fond SetColorTexture + bordure de 1 px (4 textures).
function UI.Panel(name, parent)
  local p = CreateFrame("Frame", name, parent or UIParent)
  p.bg = p:CreateTexture(nil, "BACKGROUND")
  p.bg:SetAllPoints(p)
  local b = UI.color.border
  p.edges = {}
  for i, e in ipairs({ { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
    { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = p:CreateTexture(nil, "BORDER")
    t:SetColorTexture(b[1], b[2], b[3], b[4])
    t:SetPoint(e[1], p, e[1])
    t:SetPoint(e[2], p, e[2])
    if e[3] then t:SetHeight(1) else t:SetWidth(1) end
    p.edges[i] = t
  end
  paint(p)
  panels[p] = true
  return p
end

local function restore(frame, key)
  local s = ns.db and ns.db.frames and ns.db.frames[key]
  if not s then return end
  later(function()
    frame:ClearAllPoints()
    frame:SetPoint(s.point, UIParent, s.relPoint, s.x, s.y)
    if s.w and s.h then frame:SetSize(s.w, s.h) end
  end)
end

local function save(frame, key, resizable)
  if not ns.db then return end
  local point, _, relPoint, x, y = frame:GetPoint()
  if not point then return end
  local s = { point = point, relPoint = relPoint, x = x, y = y }
  if resizable then s.w, s.h = frame:GetWidth(), frame:GetHeight() end
  ns.db.frames = ns.db.frames or {}
  ns.db.frames[key] = s
end

-- Déplaçable (sauf si ns.db.locked), position (et taille si resizable) sauvegardée dans ns.db.frames[key].
function UI.Movable(frame, key, resizable)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    if not (ns.db and ns.db.locked) and not InCombatLockdown() then self:StartMoving() end
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    save(self, key, resizable)
  end)
  if resizable then
    frame:SetResizable(true)
    if not pcall(frame.SetResizeBounds, frame, 120, 80) then pcall(frame.SetMinResize, frame, 120, 80) end
    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
    local t = grip:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints(grip)
    t:SetColorTexture(UI.color.accent[1], UI.color.accent[2], UI.color.accent[3], 0.5)
    grip:SetScript("OnMouseDown", function()
      if not (ns.db and ns.db.locked) and not InCombatLockdown() then frame:StartSizing("BOTTOMRIGHT") end
    end)
    grip:SetScript("OnMouseUp", function()
      frame:StopMovingOrSizing()
      save(frame, key, true)
    end)
  end
  movables[frame] = key
  restore(frame, key)
end

function UI.Restore(frame, key) restore(frame, key or movables[frame]) end

function UI.SetOpacity(a)
  if ns.db then ns.db.opacity = a end
  for p in pairs(panels) do paint(p) end
end

function UI.SetScale(s)
  if ns.db then ns.db.scale = s end
  for f in pairs(movables) do later(function() f:SetScale(s) end) end
end

-- Les valeurs sauvegardées n'existent qu'après ADDON_LOADED (Core l'a déjà traité).
ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  for f, key in pairs(movables) do restore(f, key); f:SetScale(ns.db.scale or 1) end
  UI.SetOpacity(ns.db.opacity or 1)
end)

-- Bouton-icône : lueur douce animée (Pulse), texte de raccourci, état grisé.
function UI.Icon(parent, size)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(size, size)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints(b)
  b.glow = b:CreateTexture(nil, "OVERLAY")
  b.glow:SetPoint("CENTER", b, "CENTER")
  b.glow:SetSize(size * 1.8, size * 1.8)
  b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  b.glow:SetBlendMode("ADD")
  local a = UI.color.accent
  b.glow:SetVertexColor(a[1], a[2], a[3])
  b.glow:SetAlpha(0)
  b.key = b:CreateFontString(nil, "OVERLAY")
  pcall(b.key.SetFontObject, b.key, UI.font.small)
  b.key:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2, -2)

  local ag = b.glow:CreateAnimationGroup()
  ag:SetLooping("BOUNCE")
  local fade = ag:CreateAnimation("Alpha")
  fade:SetFromAlpha(0.1)
  fade:SetToAlpha(0.9)
  fade:SetDuration(0.5)
  local token = 0

  function b:SetIcon(tex) self.icon:SetTexture(tex) end
  function b:SetHotkey(text) self.key:SetText(text or "") end
  function b:SetGrayed(on)
    if not pcall(self.icon.SetDesaturated, self.icon, on and true or false) then
      local v = on and 0.5 or 1
      self.icon:SetVertexColor(v, v, v)
    end
  end
  function b:Pulse()
    token = token + 1
    local mine = token
    self.glow:SetAlpha(1)
    ag:Play()
    ns.After(2, function() if mine == token then ag:Stop() self.glow:SetAlpha(0) end end)
  end
  return b
end
