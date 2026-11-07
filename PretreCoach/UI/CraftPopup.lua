-- Fenetre « Craft » : jusqu'a 3 recettes qui font monter Alchimie/Secourisme avec les sacs, un bouton par recette.
-- Exception de conformite approuvee (voir CLAUDE.md, Regle 0) : ce fichier seul lance le SORT DU METIER (type1="spell"),
-- ce qui ouvre la fenetre de metier. L'addon y preselectionne la recette (navigation d'UI) ; le joueur clique lui-meme
-- sur « Creer ». Aucune fabrication automatique : CraftRecipe, C_TradeSkillUI.Craft et macrotext restent interdits.
-- Attributs poses hors combat seulement ; en combat le rendu est suspendu et reprend a PLAYER_REGEN_ENABLED.
local ADDON, ns = ...
local UI, L = ns.UI, ns.L

local P = { rows = {} }
UI.CraftPopup = P
local frame
local SIZE, PAD, ROW_H, MAX = 34, 6, 42, 3
local W = 300
-- Sorts de metier (Vanilla) et icones de repli : a verifier en jeu (verify). Herboristerie exclue : rien a fabriquer.
local TRADE = {
  [171] = { spell = 2259, tex = "Interface\\Icons\\Trade_Alchemy" },
  [129] = { spell = 3273, tex = "Interface\\Icons\\Spell_Holy_SealOfSacrifice" },
}
local want -- { recipeID, name, t, pending } memorise par le clic du joueur
local dismissed = false

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

function P.Render()
  if not frame or InCombatLockdown() then return end
  local entries = {}
  if not (ns.db and ns.db.show and ns.db.show.craft == false) and not dismissed then
    for _, e in ipairs(ns.Prof.Craftable()) do
      if e.skillUp and TRADE[e.line] and #entries < MAX then entries[#entries + 1] = e end
    end
  end
  if #entries == 0 then frame:Hide() return end
  for i, r in ipairs(P.rows) do
    local e = entries[i]
    if e then
      r.line, r.recipe = e.line, e.recipe
      r.recipeID = recipeIDOf(e.line, e.recipe)
      r.icon:SetTexture(TRADE[e.line].tex)
      r.text:SetText(L.CRAFT_ROW:format(e.n, e.recipe))
      r.buy:SetText(#e.buy > 0 and buyText(e) or "")
      if r.applied ~= e.line then
        r.btn:SetAttribute("type1", "spell")
        r.btn:SetAttribute("spell1", spellName(e.line))
        r.applied = e.line
      end
    end
    r.frame:SetShown(e ~= nil)
  end
  frame:SetHeight(2 * PAD + #entries * ROW_H)
  frame:Show()
end

local function build()
  frame = UI.Panel("PretreCoachCraftFrame", UIParent)
  P.frame = frame
  frame:SetSize(W, 2 * PAD + ROW_H)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -130)
  UI.Movable(frame, "craft")
  frame:Hide()
  for i = 1, MAX do
    local r = { frame = CreateFrame("Frame", nil, frame) }
    r.frame:SetSize(W - 2 * PAD - 16, ROW_H)
    r.frame:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD - (i - 1) * ROW_H)
    local b = CreateFrame("Button", "PretreCoachCraft" .. i, r.frame, "SecureActionButtonTemplate")
    r.btn = b
    b:SetSize(SIZE, SIZE)
    b:SetPoint("TOPLEFT", r.frame, "TOPLEFT", 0, 0)
    b:RegisterForClicks("AnyUp")
    r.icon = b:CreateTexture(nil, "ARTWORK")
    r.icon:SetAllPoints(b)
    r.text = r.frame:CreateFontString(nil, "OVERLAY")
    pcall(r.text.SetFontObject, r.text, UI.font.text)
    r.text:SetPoint("TOPLEFT", b, "TOPRIGHT", 6, -2)
    r.buy = r.frame:CreateFontString(nil, "OVERLAY")
    pcall(r.buy.SetFontObject, r.buy, UI.font.small)
    r.buy:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -2)
    -- non securise : memorise la recette voulue ; le sort du metier part du clic, pas de l'addon
    b:HookScript("PreClick", function()
      want = { recipeID = r.recipeID, name = r.recipe, t = GetTime(), pending = 2 }
    end)
    P.rows[i] = r
  end
  local x = CreateFrame("Button", nil, frame)
  x:SetSize(14, 14)
  x:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)
  x.label = x:CreateFontString(nil, "OVERLAY")
  pcall(x.label.SetFontObject, x.label, UI.font.small)
  x.label:SetAllPoints(x)
  x.label:SetText("x")
  x:SetScript("OnClick", function()
    if InCombatLockdown() then return end
    dismissed = true
    frame:Hide()
  end)
  P.close = x
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
  dismissed = false
  P.Render()
  if ns.RefreshOptions then ns.RefreshOptions() end
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  if InCombatLockdown() then return end -- cadres securises : crees hors combat seulement (repris a PLAYER_REGEN_ENABLED)
  build()
  P.Render()
end)
ns.On("BAG_UPDATE_DELAYED", function()
  dismissed = false
  P.Render()
end)
ns.On("PLAYER_REGEN_ENABLED", function()
  if not frame then build() end
  P.Render()
end)
