-- Barre de mana du joueur + fine barre de la regle des 5 s (affichage seul, aucun cadre securise).
-- Le mana du joueur est secret meme hors combat sur Forever : les valeurs brutes vont telles quelles au StatusBar,
-- sans calcul ni comparaison. La barre des 5 s vient de Timers.FiveSecRemaining (nombre lisible).
local ADDON, ns = ...
local UI, L, S, Timers = ns.UI, ns.L, ns.S, ns.Timers
local C = UI.color

local M = {}
UI.ManaBar = M
local WHITE = "Interface\\Buttons\\WHITE8X8"
local frame, active, acc = nil, false, 0

local function newBar(parent, h, anchor, dy)
  local b = CreateFrame("StatusBar", nil, parent)
  b:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, dy)
  b:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, dy)
  b:SetHeight(h)
  pcall(b.SetStatusBarTexture, b, WHITE)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(1, 1, 1, 0.1)
  return b
end

function M.UpdateMana()
  if not frame then return end
  pcall(function() -- valeur secrete possible : donnee telle quelle au widget
    frame.mana:SetMinMaxValues(0, S.Raw(UnitPowerMax, "player", 0))
    frame.mana:SetValue(S.Raw(UnitPower, "player", 0))
  end)
end

-- OnUpdate (0,05 s) seulement pendant le decompte ; ensuite barre pleine verte "regen.", discrete.
function M.UpdateFive()
  if not frame then return end
  local bar = frame.five
  local r = Timers.FiveSecRemaining()
  if type(r) == "number" and r > 0 then
    bar:SetValue(5 - r)
    bar:SetStatusBarColor(C.warn[1], C.warn[2], C.warn[3])
    bar.text:SetText(L.MANA_FIVE:format((("%.1f"):format(r):gsub("%.", ","))))
    bar:SetAlpha(1)
    if not active then
      active, acc = true, 0
      bar:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc >= 0.05 then acc = 0 M.UpdateFive() end
      end)
    end
    return
  end
  if active then active = false bar:SetScript("OnUpdate", nil) end
  bar:SetValue(5)
  bar:SetStatusBarColor(C.good[1], C.good[2], C.good[3])
  bar.text:SetText(type(r) == "number" and L.MANA_REGEN or "")
  bar:SetAlpha(0.45)
end

function M.Render()
  if not frame then return end
  if ns.db and ns.db.show and ns.db.show.mana == false then frame:Hide() return end
  frame:Show()
  M.UpdateMana()
  M.UpdateFive()
end

local function build()
  frame = UI.Panel("PretreCoachManaFrame", UIParent)
  M.frame = frame
  frame:SetSize(170, 40)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -230)
  UI.Movable(frame, "mana")
  local anchor = CreateFrame("Frame", nil, frame)
  anchor:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -6)
  anchor:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
  anchor:SetHeight(1)
  frame.mana = newBar(frame, 16, anchor, 0)
  frame.mana:SetStatusBarColor(0.25, 0.45, 0.95) -- bleu fixe
  frame.mana:SetMinMaxValues(0, 1)
  frame.mana:SetValue(1)
  frame.five = newBar(frame, 12, anchor, -20)
  frame.five:SetMinMaxValues(0, 5)
  frame.five.text = frame.five:CreateFontString(nil, "OVERLAY", UI.font.small)
  frame.five.text:SetPoint("CENTER", frame.five, "CENTER")
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
