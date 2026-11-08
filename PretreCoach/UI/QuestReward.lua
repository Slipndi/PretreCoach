-- Meilleure récompense au choix (façon Pawn) : à la fenêtre de rendu (QUEST_COMPLETE), un liseré doré et une pièce marquent
-- la récompense qui vaut le plus d'or (HdV sinon marchand, x quantité), avec sa valeur. Lecture seule (Règle 0) : cadre simple
-- posé sur le bouton Blizzard, souris ignorée, aucun clic simulé, aucun choix à la place du joueur. Rien en combat ni en base.
-- Les récompenses vues sont apprises par ns.QuestDB (QuestDB.lua), pas ici.
local _, ns = ...
local UI, S = ns.UI, ns.S

local R = {}
UI.QuestReward = R

local function rewardButton(i)
  local ok, b = pcall(function()
    local f = _G.QuestInfoRewardsFrame
    return f and f.RewardButtons and f.RewardButtons[i] or _G["QuestInfoRewardsFrameQuestInfoItem" .. i]
  end)
  return ok and type(b) == "table" and b or nil
end

-- { index, value } de la récompense au choix qui vaut le plus, et le nombre de choix ; nil si aucun prix lisible.
function R.Best()
  local n = S.Get(GetNumQuestChoices)
  if type(n) ~= "number" then return nil, 0 end
  local best
  for i = 1, n do
    local link = S.Get(GetQuestItemLink, "choice", i)
    local v = type(link) == "string" and ns.Quests.ItemValue(link)
    if v then
      local st, _, _, count = S.GetAll(GetQuestItemInfo, "choice", i)
      v = v * (st == "lisible" and type(count) == "number" and count > 0 and count or 1)
      if v > 0 and (not best or v > best.value) then best = { index = i, value = v } end
    end
  end
  return best, n
end

local mark
local function build()
  mark = CreateFrame("Frame")
  mark:EnableMouse(false)
  for _, e in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" }, { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local t = mark:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(1, 0.82, 0, 0.9)
    t:SetPoint(e[1])
    t:SetPoint(e[2])
    if e[1]:sub(1, 3) == e[2]:sub(1, 3) then t:SetHeight(2) else t:SetWidth(2) end
  end
  local icon = mark:CreateTexture(nil, "OVERLAY")
  icon:SetSize(14, 14)
  icon:SetPoint("TOPRIGHT", mark, "TOPRIGHT", -2, -2)
  icon:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  mark.text = mark:CreateFontString(nil, "OVERLAY", UI.font.small)
  mark.text:SetPoint("BOTTOMRIGHT", mark, "BOTTOMRIGHT", -3, 3)
end

function R.Hide()
  if mark then mark:Hide() end
  R.shown = nil
end

-- Relit les choix de la fenêtre ouverte.
function R.Update()
  R.Hide()
  if InCombatLockdown() then return end
  local best, n = R.Best()
  if not best or n < 2 or (ns.db and ns.db.show and ns.db.show.questreward == false) then return end
  local b = rewardButton(best.index)
  if not b then return end
  if not mark then build() end
  if not pcall(function() mark:SetParent(b) mark:ClearAllPoints() mark:SetAllPoints(b) end) then return end
  mark.text:SetText(ns.Prof.Money(math.floor(best.value + 0.5)))
  mark:Show()
  R.shown = best.index
end

-- après les gestionnaires Blizzard, qui remplissent les boutons au même événement
ns.On("QUEST_COMPLETE", function() ns.After(0, R.Update) end)
ns.On("QUEST_FINISHED", R.Hide)
