-- Panneau du coach de cycle : affichage seul de ns.Rotation (message ROTATION) et de la barre des 5 s (Timers).
-- Jamais de bouton sécurisé : les icônes ne lancent rien.
local ADDON, ns = ...
local UI, Rotation, Timers = ns.UI, ns.Rotation, ns.Timers
local C = UI.color

local P = {}
UI.RotationPanel = P
local frame, lastFirst, lastStop
local barActive, barAcc = false, 0

local function setIcon(btn, key)
  if not key then btn:Hide() return end
  btn:Show()
  btn:SetIcon(Rotation.Texture(key))
  btn:SetHotkey(Rotation.Hotkey(key))
  local cd = Timers.CooldownRemaining(key)
  btn:SetGrayed(type(cd) == "number" and cd > 0)
end

-- Barre des 5 s : visible seulement tant que FiveSecRemaining() > 0 ; l'OnUpdate (toutes les 0,05 s) n'existe que pendant ce temps.
function P.UpdateBar()
  if not frame then return end
  local bar = frame.bar
  local r = Timers.FiveSecRemaining()
  if type(r) ~= "number" or r <= 0 then
    bar:Hide()
    if barActive then barActive = false bar:SetScript("OnUpdate", nil) end
    return
  end
  bar:SetValue(r)
  bar:Show()
  if not barActive then
    barActive, barAcc = true, 0
    bar:SetScript("OnUpdate", function(_, dt)
      barAcc = barAcc + dt
      if barAcc >= 0.05 then barAcc = 0 P.UpdateBar() end
    end)
  end
end

function P.Render(result)
  if not frame then return end
  result = result or Rotation.current
  local keys = result and result.keys or {}
  if #keys == 0 or (ns.db and ns.db.show and ns.db.show.rotation == false) then
    lastFirst, lastStop = nil, nil
    frame:Hide()
    return
  end
  setIcon(frame.big, keys[1])
  setIcon(frame.small[1], keys[2])
  setIcon(frame.small[2], keys[3])
  frame.text:SetText(result.text or "")
  -- pulse seulement si le conseil change vraiment (un Render forcé, ex. raccourci modifié, ne fait pas clignoter)
  if keys[1] ~= lastFirst or (result.stop and not lastStop) then frame.big:Pulse() end
  lastFirst, lastStop = keys[1], result.stop and true or nil
  frame:Show()
  P.UpdateBar()
end

local function build()
  frame = UI.Panel("PretreCoachRotationFrame", UIParent)
  P.frame = frame
  frame:SetSize(176, 104)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -160)
  frame:Hide()
  UI.Movable(frame, "rotation")

  frame.big = UI.Icon(frame, 48)
  frame.big:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -10)
  frame.small = {}
  for i = 1, 2 do
    local b = UI.Icon(frame, 28)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", 68 + (i - 1) * 34, -12)
    frame.small[i] = b
  end

  local bar = CreateFrame("StatusBar", nil, frame)
  frame.bar = bar
  bar:SetSize(156, 6)
  bar:SetPoint("TOPLEFT", frame.big, "BOTTOMLEFT", 0, -4)
  bar:SetMinMaxValues(0, 5)
  pcall(bar.SetStatusBarTexture, bar, "Interface\\Buttons\\WHITE8X8")
  bar:SetStatusBarColor(C.accent[1], C.accent[2], C.accent[3])
  bar.bg = bar:CreateTexture(nil, "BACKGROUND")
  bar.bg:SetAllPoints(bar)
  bar.bg:SetColorTexture(1, 1, 1, 0.1)
  bar:Hide()

  frame.text = frame:CreateFontString(nil, "OVERLAY", UI.font.small)
  frame.text:SetJustifyH("LEFT")
  frame.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -76)
  frame.text:SetWidth(156)
  frame.text:SetTextColor(C.white[1], C.white[2], C.white[3])
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  build()
  P.Render()
end)
ns.Listen("ROTATION", function(_, result) P.Render(result) end)
ns.Listen("TIMERS", P.UpdateBar)
