-- Barre de mana du joueur, style Blizzard, + decompte de la regle des 5 s en surimpression (affichage seul).
-- Le mana du joueur est secret meme hors combat sur Forever : les valeurs brutes vont telles quelles au StatusBar,
-- sans calcul ni comparaison. Le decompte des 5 s vient de Timers.FiveSecRemaining (nombre lisible).
local ADDON, ns = ...
local UI, L, S, Timers = ns.UI, ns.L, ns.S, ns.Timers

local M = {}
UI.ManaBar = M
local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local W, H = 240, 14 -- taille fixe de la barre : la couche des 5 s s'en sert (le mana, lui, est secret)
local frame, active, acc = nil, false, 0

function M.UpdateMana()
  if not frame then return end
  pcall(function() -- valeur secrete possible : donnee telle quelle au widget
    frame.mana:SetMinMaxValues(0, S.Raw(UnitPowerMax, "player", 0))
    frame.mana:SetValue(S.Raw(UnitPower, "player", 0))
  end)
end

-- OnUpdate (0,05 s) seulement pendant le decompte ; a 0 : eclat dore bref, puis couche et texte s'effacent.
function M.UpdateFive()
  if not frame then return end
  local five, mana = frame.five, frame.mana
  local r = Timers.FiveSecRemaining()
  if type(r) == "number" and r > 0 then
    five:SetWidth(math.max(1, W * (5 - r) / 5))
    five:Show()
    frame.text:SetText(L.MANA_FIVE:format((("%.1f"):format(r):gsub("%.", ","))))
    if not active then
      active, acc = true, 0
      mana:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 0.05 then acc = 0 M.UpdateFive() end
      end)
    end
    return
  end
  if active then
    active = false
    mana:SetScript("OnUpdate", nil)
    frame.flash:SetAlpha(0)
    frame.flashAnim:Stop()
    frame.flashAnim:Play()
  end
  five:Hide()
  frame.text:SetText("")
end

function M.Render()
  if not frame then return end
  if ns.db and ns.db.show and ns.db.show.mana == false then frame:Hide() return end
  frame:Show()
  M.UpdateMana()
  M.UpdateFive()
end

local function build()
  local ok, f = pcall(CreateFrame, "Frame", "PretreCoachManaFrame", UIParent, "BackdropTemplate")
  if not ok or not f then f = CreateFrame("Frame", "PretreCoachManaFrame", UIParent) end
  frame = f
  M.frame = frame
  frame:SetSize(W + 8, H + 8)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -230)
  pcall(function()
    frame:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    frame:SetBackdropBorderColor(1, 0.82, 0)
  end)
  UI.Movable(frame, "mana")

  local mana = CreateFrame("StatusBar", nil, frame)
  frame.mana = mana
  mana:SetSize(W, H)
  mana:SetPoint("CENTER", frame, "CENTER")
  pcall(mana.SetStatusBarTexture, mana, BAR)
  local c = { 0, 0.44, 0.87 }
  pcall(function() local p = PowerBarColor["MANA"] c = { p.r, p.g, p.b } end)
  mana:SetStatusBarColor(c[1], c[2], c[3])
  mana:SetMinMaxValues(0, 1)
  mana:SetValue(1)
  local bg = mana:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(mana)
  bg:SetTexture(BAR)
  bg:SetVertexColor(0.2, 0.2, 0.2, 0.5)

  local five = mana:CreateTexture(nil, "OVERLAY") -- couche discrete : grandit de gauche a droite sur 5 s
  frame.five = five
  five:SetPoint("TOPLEFT", mana, "TOPLEFT")
  five:SetPoint("BOTTOMLEFT", mana, "BOTTOMLEFT")
  five:SetColorTexture(1, 1, 1, 0.25)
  five:Hide()
  frame.text = mana:CreateFontString(nil, "OVERLAY", UI.font.small)
  frame.text:SetPoint("RIGHT", mana, "RIGHT", -4, 0)
  frame.flash = mana:CreateTexture(nil, "OVERLAY")
  frame.flash:SetAllPoints(mana)
  frame.flash:SetColorTexture(1, 0.82, 0, 0.6)
  frame.flash:SetAlpha(0)
  frame.flashAnim = frame.flash:CreateAnimationGroup()
  local fade = frame.flashAnim:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0)
  fade:SetDuration(0.6)
end

-- Commande /coach mana et menu de la minicarte.
function ns.ToggleMana()
  ns.db.show.mana = ns.db.show.mana == false
  M.Render()
  if ns.RefreshOptions then ns.RefreshOptions() end
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  build()
  M.Render()
end)
ns.On("PLAYER_ENTERING_WORLD", M.Render)
ns.OnUnit("UNIT_POWER_UPDATE", "player", M.UpdateMana)
ns.OnUnit("UNIT_MAXPOWER", "player", M.UpdateMana)
ns.Listen("TIMERS", M.UpdateFive)
