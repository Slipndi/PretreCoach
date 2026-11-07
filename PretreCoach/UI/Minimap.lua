-- Bouton de minicarte maison (sans bibliothèque) + entrée du menu des addons (.toc AddonCompartmentFunc).
local ADDON, ns = ...
local L = ns.L

local RADIUS, ICON = 80, "Interface\\Icons\\Spell_Shadow_ShadowWordPain"

local function onClick(button)
  if button == "RightButton" then
    if ns.ToggleOptions then ns.ToggleOptions() end
  elseif ns.ToggleGuide then
    ns.ToggleGuide()
  else
    ns.Print(L.HELP)
  end
end

-- Appelée par le client (champ ## AddonCompartmentFunc) : (addonName, buttonName, menuButtonFrame).
function PretreCoach_OnCompartmentClick(_, button) onClick(button) end

local btn = CreateFrame("Button", "PretreCoachMinimapButton", Minimap)
btn:SetSize(31, 31)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:RegisterForDrag("LeftButton")
local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetSize(20, 20)
icon:SetPoint("CENTER", btn, "CENTER")
icon:SetTexture(ICON)
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
local ring = btn:CreateTexture(nil, "OVERLAY")
ring:SetSize(53, 53)
ring:SetPoint("TOPLEFT", btn, "TOPLEFT")
ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local function angle() return (ns.db and ns.db.minimap and ns.db.minimap.angle) or 220 end

local function reposition(a)
  local r = math.rad(a)
  btn:ClearAllPoints()
  btn:SetPoint("CENTER", Minimap, "CENTER", math.cos(r) * RADIUS, math.sin(r) * RADIUS)
end

btn:SetScript("OnClick", function(_, button) onClick(button) end)
btn:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    if not (mx and cx) then return end
    local s = Minimap:GetEffectiveScale()
    local a = math.deg(math.atan2(cy / s - my, cx / s - mx))
    if ns.db and ns.db.minimap then ns.db.minimap.angle = a end
    reposition(a)
  end)
end)
btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
btn:SetScript("OnEnter", function(self)
  pcall(function()
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(L.MINIMAP_TITLE)
    GameTooltip:AddLine(L.MINIMAP_LEFT, 1, 1, 1)
    GameTooltip:AddLine(L.MINIMAP_RIGHT, 1, 1, 1)
    GameTooltip:AddLine(L.MINIMAP_DRAG, 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
end)
btn:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)

function ns.RefreshMinimap()
  btn:SetShown(not (ns.db and ns.db.show and ns.db.show.minimap == false))
end

reposition(angle())
ns.On("ADDON_LOADED", function(_, name)
  if name == ADDON then reposition(angle()) ns.RefreshMinimap() end
end)
ns.minimapButton = btn
