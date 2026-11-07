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
  b.bg:SetColorTexture(0.03, 0.04, 0.08, 0.6)
  return b
end

-- Degrade vertical sur la texture de la barre (API moderne CreateColor, sinon ancienne forme) ; repli : couleur unie.
local function gradient(bar, top, bottom)
  local tex = bar:GetStatusBarTexture()
  local ok = tex and pcall(function()
    if CreateColor then
      tex:SetGradient("VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], 1), CreateColor(top[1], top[2], top[3], 1))
    else
      tex:SetGradient("VERTICAL", bottom[1], bottom[2], bottom[3], top[1], top[2], top[3])
    end
  end)
  if not ok then bar:SetStatusBarColor(bottom[1], bottom[2], bottom[3]) end
end

function M.UpdateMana()
  if not frame then return end
  pcall(function() -- valeur secrete possible : donnee telle quelle au widget
    frame.mana:SetMinMaxValues(0, S.Raw(UnitPowerMax, "player", 0))
    frame.mana:SetValue(S.Raw(UnitPower, "player", 0))
  end)
end

-- OnUpdate (0,05 s) seulement pendant le decompte ; a 0 : flash vert bref, puis la fine barre s'efface.
function M.UpdateFive()
  if not frame then return end
  local bar = frame.five
  local r = Timers.FiveSecRemaining()
  if type(r) == "number" and r > 0 then
    bar:SetValue(5 - r)
    bar:SetStatusBarColor(1, 0.75, 0.2) -- orange dore
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
  if active then
    active = false
    bar:SetScript("OnUpdate", nil)
    bar.flash:SetAlpha(0)
    bar.flashAnim:Stop()
    bar.flashAnim:Play()
  end
  bar:SetValue(5)
  bar:SetStatusBarColor(C.good[1], C.good[2], C.good[3])
  bar.text:SetText("")
  bar:SetAlpha(0)
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
  frame:SetSize(260, 16)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -230)
  UI.Movable(frame, "mana")
  local anchor = CreateFrame("Frame", nil, frame)
  anchor:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
  anchor:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
  anchor:SetHeight(1)
  local mana = newBar(frame, 8, anchor, 0)
  frame.mana = mana
  mana:SetMinMaxValues(0, 1)
  mana:SetValue(1)
  mana:SetStatusBarColor(0.2, 0.45, 0.95) -- repli si le degrade echoue
  gradient(mana, { 0.45, 0.72, 1 }, { 0.08, 0.22, 0.75 }) -- bleu clair en haut, bleu profond en bas
  local shine = mana:CreateTexture(nil, "OVERLAY") -- reflet sur la moitie haute
  shine:SetPoint("TOPLEFT", mana, "TOPLEFT")
  shine:SetPoint("TOPRIGHT", mana, "TOPRIGHT")
  shine:SetHeight(4)
  shine:SetColorTexture(1, 1, 1, 0.12)

  local five = newBar(frame, 3, anchor, -9) -- collee sous la mana (8 px + 1 px de jour)
  frame.five = five
  five:SetMinMaxValues(0, 5)
  five:SetAlpha(0)
  five.text = five:CreateFontString(nil, "OVERLAY", UI.font.small)
  five.text:SetPoint("TOPRIGHT", five, "BOTTOMRIGHT", 0, -1)
  five.flash = five:CreateTexture(nil, "OVERLAY")
  five.flash:SetAllPoints(five)
  five.flash:SetColorTexture(C.good[1], C.good[2], C.good[3], 1)
  five.flash:SetAlpha(0)
  five.flashAnim = five.flash:CreateAnimationGroup()
  local fade = five.flashAnim:CreateAnimation("Alpha")
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
