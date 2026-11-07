-- Bandeau « Règles d'or » : 8 pastilles (état de ns.Rules, message RULES). Affichage seul, aucune logique de règle.
-- En combat, seules les pastilles 1 à 4 restent visibles. Survol : infobulle ; clic : explication de la règle.
local ADDON, ns = ...
local UI, L = ns.UI, ns.L
local C = UI.color

local B = { buttons = {} }
UI.RulesBar = B
local frame, detail, picked
local SIZE, GAP = 22, 4
local GREY = { 0.45, 0.45, 0.5 }
local COLOR = { ok = C.good, warn = C.warn, bad = C.bad, unknown = GREY }

local function status(i)
  local s = ns.Rules.Status()[i]
  return s.state, s.reason
end

local function tooltip(btn)
  local rule = ns.Rules.list[btn.index]
  local state, reason = status(btn.index)
  pcall(function()
    GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
    GameTooltip:AddLine(btn.index .. ". " .. rule.title)
    GameTooltip:AddLine(L["RULE_STATE_" .. state], COLOR[state][1], COLOR[state][2], COLOR[state][3])
    if reason and reason ~= "" then GameTooltip:AddLine(reason, 1, 1, 1, true) end
    GameTooltip:AddLine(L.RULES_CLICK, 0.6, 0.6, 0.65)
    GameTooltip:Show()
  end)
end

-- Clic : petit panneau sous le bandeau ; un second clic sur la même règle le referme.
local function toggleDetail(i)
  if picked == i then
    picked = nil
    detail:Hide()
    return
  end
  picked = i
  local rule = ns.Rules.list[i]
  detail.text:SetText(i .. ". " .. rule.title .. "\n" .. rule.explain)
  detail:Show()
end

function B.Render()
  if not frame then return end
  if ns.db and ns.db.show and ns.db.show.rules == false then
    frame:Hide()
    detail:Hide()
    picked = nil
    return
  end
  local inCombat = InCombatLockdown() and true or false
  for i, btn in ipairs(B.buttons) do
    local c = COLOR[(status(i))]
    btn.bg:SetColorTexture(c[1], c[2], c[3], 0.9)
    if i > 4 and inCombat then btn:Hide() else btn:Show() end
  end
  if inCombat and picked and picked > 4 then picked = nil detail:Hide() end
  frame:Show()
end

local function build()
  frame = UI.Panel("PretreCoachRulesFrame", UIParent)
  B.frame = frame
  frame:SetSize(8 * (SIZE + GAP) + GAP, SIZE + 2 * GAP)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -20)
  UI.Movable(frame, "rules")

  for i = 1, 8 do
    local btn = CreateFrame("Button", nil, frame)
    btn:SetSize(SIZE, SIZE)
    btn:SetPoint("TOPLEFT", frame, "TOPLEFT", GAP + (i - 1) * (SIZE + GAP), -GAP)
    btn.index = i
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints(btn)
    btn.num = btn:CreateFontString(nil, "OVERLAY", UI.font.small)
    btn.num:SetPoint("CENTER", btn, "CENTER")
    btn.num:SetText(tostring(i))
    btn:SetScript("OnEnter", tooltip)
    btn:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    btn:SetScript("OnClick", function() toggleDetail(i) end)
    B.buttons[i] = btn
  end

  detail = UI.Panel("PretreCoachRulesDetail", frame)
  B.detail = detail
  detail:SetSize(220, 70)
  detail:SetPoint("TOP", frame, "BOTTOM", 0, -4)
  detail.text = detail:CreateFontString(nil, "OVERLAY", UI.font.small)
  detail.text:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -8)
  detail.text:SetWidth(204)
  detail.text:SetJustifyH("LEFT")
  detail:Hide()
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  build()
  B.Render()
end)
ns.Listen("RULES", B.Render)
ns.On("PLAYER_REGEN_DISABLED", B.Render)
ns.On("PLAYER_REGEN_ENABLED", B.Render)
