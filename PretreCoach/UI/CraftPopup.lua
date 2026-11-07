-- Icone « Craft » dans la carte du guide : un petit bouton a droite de la rangee Alchimie / Secourisme.
-- Exception de conformite approuvee (voir CLAUDE.md, Regle 0) : ce fichier seul lance le SORT DU METIER (type1="spell"),
-- ce qui ouvre la fenetre de metier. L'addon y preselectionne la recette (navigation d'UI) ; le joueur clique lui-meme
-- sur « Creer ». Aucune fabrication automatique : CraftRecipe, C_TradeSkillUI.Craft et macrotext restent interdits.
-- Creation, attributs, SetPoint, Show/Hide : hors combat seulement ; en combat on attend PLAYER_REGEN_ENABLED.
-- Boutons parentes a UIParent (pas a la carte, que le joueur peut fermer en combat) et ancres sur la rangee de la carte :
-- un cadre securise ne change jamais de visibilite par le fait d'un parent non securise.
local ADDON, ns = ...
local UI, L = ns.UI, ns.L

local P = { btns = {} }
UI.CraftPopup = P
local SIZE = 18
-- Sorts de metier (Vanilla) et icones de repli : a verifier en jeu (verify). Herboristerie exclue : rien a fabriquer.
local TRADE = {
  [171] = { spell = 2259, tex = "Interface\\Icons\\Trade_Alchemy" },
  [129] = { spell = 3273, tex = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
}
local ORDER = { 171, 129 }
local want -- { recipeID, name, t, pending } memorise par le clic du joueur

local function spellName(line)
  local id = TRADE[line].spell
  local ok, n = pcall(function() return C_Spell.GetSpellName(id) end)
  if ok and type(n) == "string" and n ~= "" then return n end
  local d = ns.Data.Professions and ns.Data.Professions[line]
  return d and d.name
end

local function recipeIDOf(line, name)
  local adv = ns.Prof.Get(line)
  for _, r in ipairs(adv and adv.list or {}) do
    if r.name == name and type(r.recipeID) == "number" then return r.recipeID end
  end
end

local function buyText(e)
  local t, cost = {}, 0
  for i, b in ipairs(e.buy) do
    t[i] = b.qty .. " " .. b.name
    cost = cost and b.cost and (cost + b.cost) or nil
  end
  return L.CRAFT_BUY:format(table.concat(t, ", ")) .. (cost and (" (≈ " .. ns.Prof.Money(cost) .. ")") or "")
end

-- Lignes de l'infobulle : skill-up possible, sinon 1re action non faite du plan du metier.
local function tipLines(b)
  local name = ns.Data.Professions and ns.Data.Professions[b.line] and ns.Data.Professions[b.line].name or "?"
  local t = {}
  local e = b.entry
  if e then
    t[1] = L.CRAFT_ROW:format(e.n, e.recipe)
    if #e.buy > 0 then t[2] = buyText(e) end
    t[#t + 1] = L.CRAFT_CLICK:format(name)
  else
    local s = ns.Prof.Steps and ns.Prof.Steps(b.line)
    local first
    for _, x in ipairs(s and s.todo or {}) do if x.done ~= true and not first then first = x.text end end
    t[1] = (s and s.title) or name
    if first then t[2] = first end
    t[#t + 1] = L.CRAFT_CLICK_OPEN:format(name)
  end
  return t
end
P.TipLines = tipLines

local function newButton(line)
  local b = CreateFrame("Button", "PretreCoachCraft" .. line, UIParent, "SecureActionButtonTemplate")
  b.line = line
  b:SetSize(SIZE, SIZE)
  b:SetFrameStrata("HIGH")
  b:RegisterForClicks("AnyUp")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetAllPoints(b)
  b.icon:SetTexture(TRADE[line].tex)
  b:SetScript("OnEnter", function(self)
    pcall(function()
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      for i, s in ipairs(tipLines(self)) do
        if i == 1 then GameTooltip:SetText(s, 1, 1, 1, 1, true) else GameTooltip:AddLine(s, 0.8, 0.8, 0.85, true) end
      end
      GameTooltip:Show()
    end)
  end)
  b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  -- non securise : memorise la recette voulue ; le sort du metier part du clic, pas de l'addon
  b:HookScript("PreClick", function()
    want = { recipeID = b.recipeID, name = b.entry and b.entry.recipe, t = GetTime(), pending = 2 }
  end)
  return b
end

-- Aligne les boutons sur la carte. Hors combat seulement : en combat on attend PLAYER_REGEN_ENABLED.
function P.Sync()
  if InCombatLockdown() then return end
  local card = UI.GuideWin and UI.GuideWin.card
  local on = not (ns.db and ns.db.show and ns.db.show.craft == false)
  local up = {}
  if on and card and card:IsShown() then
    for _, e in ipairs(ns.Prof.Craftable()) do
      if e.skillUp and TRADE[e.line] and not up[e.line] then up[e.line] = e end
    end
  end
  for _, line in ipairs(ORDER) do
    local anchor = on and card and card:IsShown() and card.profAnchor and card.profAnchor[line]
    local b = P.btns[line]
    if anchor then
      b = b or newButton(line)
      P.btns[line] = b
      local e = up[line]
      b.entry = e
      b.recipeID = e and recipeIDOf(line, e.recipe) or nil
      if not b.applied then
        local sn = spellName(line)
        if sn then
          b:SetAttribute("type1", "spell")
          b:SetAttribute("spell1", sn)
          b.applied = true
        end
      end
      b:ClearAllPoints()
      b:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, -2)
      b.icon:SetDesaturated(e == nil)
      b.icon:SetAlpha(e and 1 or 0.4)
      b:Show()
    elseif b then
      b:Hide()
    end
  end
end

-- Selection de la recette dans la fenetre de metier : navigation d'UI, ne fabrique rien.
local function preselect()
  if not want then return end
  if GetTime() - want.t > 10 then want = nil return end
  if not want.recipeID then
    ns.Toast(L.CRAFT_FIND:format(want.name or "?"), { key = "pc:craft:find", cooldown = 5 })
    want = nil
    return
  end
  local T = C_TradeSkillUI
  local fn = T and (T.OpenRecipe or T.SetRecipeSelected)
  if fn then pcall(fn, want.recipeID) end
  want.pending = want.pending - 1
  if want.pending <= 0 then want = nil end
end
ns.On("TRADE_SKILL_SHOW", preselect)
ns.On("TRADE_SKILL_LIST_UPDATE", preselect)

function ns.ToggleCraft()
  ns.db.show.craft = ns.db.show.craft == false
  P.Sync()
  if ns.RefreshOptions then ns.RefreshOptions() end
end

ns.Listen("CARDROWS", P.Sync)
ns.On("BAG_UPDATE_DELAYED", P.Sync)
ns.On("PLAYER_REGEN_ENABLED", P.Sync)
ns.On("TRADE_SKILL_LIST_UPDATE", function() if C_Timer then C_Timer.After(0.5, P.Sync) end end)
