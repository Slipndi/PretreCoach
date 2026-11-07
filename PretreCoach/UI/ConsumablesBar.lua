-- Barre Consommables : 5 boutons d'objet (nourriture, eau, potion de soins, potion de mana, bandage).
-- Exception de conformite approuvee (voir CLAUDE.md, Regle 0) : seul fichier autorise a utiliser un bouton securise.
-- Le joueur clique lui-meme ; rien ne se declenche seul. Les attributs ne changent JAMAIS en combat :
-- l'objet voulu est calcule a chaque rendu, et applique des que le combat est fini (PLAYER_REGEN_ENABLED).
local ADDON, ns = ...
local UI, L = ns.UI, ns.L

local B = { buttons = {} }
UI.ConsumablesBar = B
local frame
local SIZE, GAP, PAD = 34, 4, 6
-- Icones de repli quand aucun objet n'est choisi (suppositions a verifier en jeu).
local ICONS = {
  food = "Interface\\Icons\\INV_Misc_Food_15", water = "Interface\\Icons\\INV_Drink_10",
  heal = "Interface\\Icons\\INV_Potion_54", mana = "Interface\\Icons\\INV_Potion_76",
  bandage = "Interface\\Icons\\INV_Misc_Bandage_12",
}

local function tooltip(btn)
  pcall(function()
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    if btn.itemID and GameTooltip.SetItemByID then
      GameTooltip:SetItemByID(btn.itemID)
    else
      GameTooltip:AddLine(btn.itemName or L["CONS_" .. btn.cat], 1, 1, 1, true)
    end
    GameTooltip:AddLine(L["CONS_" .. btn.cat] .. " : " .. btn.total, 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
end

function B.Render()
  if not frame then return end
  if ns.db and ns.db.show and ns.db.show.cons == false then
    frame:Hide()
    return
  end
  local fight = InCombatLockdown()
  for i, cat in ipairs(ns.Cons.Order) do
    local b = B.buttons[i]
    local best, total = ns.Cons.Best[cat], ns.Cons.Total[cat] or 0
    b.itemID, b.itemName, b.total = best and best.id, best and best.name, total
    b.icon:SetTexture((best and best.icon) or ICONS[cat])
    if not pcall(b.icon.SetDesaturated, b.icon, total == 0) then
      local v = total == 0 and 0.4 or 1
      b.icon:SetVertexColor(v, v, v)
    end
    b.count:SetText(total > 0 and tostring(total) or "")
    -- attributs : seulement hors combat ; sinon b.applied differe et le prochain rendu (fin de combat) les pose
    if b.applied ~= (b.itemID or false) and not fight then
      b:SetAttribute("type1", "item")
      b:SetAttribute("item1", b.itemID and ("item:" .. b.itemID) or nil)
      b.applied = b.itemID or false
    end
  end
  frame:Show()
end

local function build()
  frame = UI.Panel("PretreCoachConsumablesFrame", UIParent)
  B.frame = frame
  frame:SetSize(2 * PAD + 5 * SIZE + 4 * GAP, 2 * PAD + SIZE)
  frame:SetPoint("CENTER", UIParent, "CENTER", 0, -200)
  UI.Movable(frame, "cons")
  for i, cat in ipairs(ns.Cons.Order) do
    local b = CreateFrame("Button", "PretreCoachConsumable" .. i, frame, "SecureActionButtonTemplate")
    b:SetSize(SIZE, SIZE)
    b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (SIZE + GAP), -PAD)
    b:RegisterForClicks("AnyUp", "AnyDown") -- Retail : le gabarit securise agit sur l'appui ou le relachement selon ActionButtonUseKeyDown
    b.cat, b.total = cat, 0
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints(b)
    b.count = b:CreateFontString(nil, "OVERLAY")
    pcall(b.count.SetFontObject, b.count, UI.font.small)
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -2, 2)
    b:SetScript("OnEnter", tooltip)
    b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    B.buttons[i] = b
  end
end

-- Commande /coach conso et menu de la minicarte.
function ns.ToggleCons()
  local show = ns.db.show
  show.cons = show.cons == false
  B.Render()
  if ns.RefreshOptions then ns.RefreshOptions() end
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  if InCombatLockdown() then return end -- cadres securises : crees hors combat seulement (repris a PLAYER_REGEN_ENABLED)
  build()
  B.Render()
end)
ns.Listen("CONS", function() if frame then B.Render() end end)
ns.On("PLAYER_REGEN_ENABLED", function()
  if not frame then build() end
  B.Render()
end)
