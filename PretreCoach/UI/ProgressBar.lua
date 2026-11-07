-- Barre de progression 1 -> 60 : remplissage = niveau + fraction d'XP (niveau seul si l'XP est illisible),
-- repères des grandes étapes (grisés à venir, allumés une fois dépassés), ligne de rythme en dessous.
-- Cadres non sécurisés ; en combat on ne fait que changer le texte et la largeur de la barre.
local ADDON, ns = ...
local UI, L = ns.UI, ns.L
local C = UI.color

local B = { markers = {} }
UI.ProgressBar = B
local frame, fill, text
local W, PAD, BAR_Y, BAR_H, ICON = 300, 10, 26, 6, 14
local BAR_W = W - 2 * PAD

-- Étapes retenues (Data.Milestones n'a ni nom ni liste courte de niveaux clés). Le niveau 20 (monture) est omis :
-- à vérifier sur Forever avant de l'ajouter. Les icônes sont des suppositions à vérifier en jeu.
local MILESTONES = {
  { level = 5, key = "PROGRESS_MS_5", icon = "Interface\\Icons\\INV_Wand_01" },
  { level = 10, key = "PROGRESS_MS_10", icon = "Interface\\Icons\\INV_Misc_Book_09" },
  { level = 24, key = "PROGRESS_MS_24", icon = "Interface\\Icons\\INV_Misc_Key_03" },
  { level = 40, key = "PROGRESS_MS_40", icon = "Interface\\Icons\\Spell_Shadow_Shadowform" },
  { level = 60, key = "PROGRESS_MS_60", icon = "Interface\\Icons\\INV_Crown_01" },
}

local function tooltip(btn)
  pcall(function()
    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
    GameTooltip:AddLine(L[btn.nameKey], 1, 1, 1, true)
    GameTooltip:Show()
  end)
end

function B.Render()
  if not frame then return end
  if ns.db and ns.db.show and ns.db.show.progress == false then
    frame:Hide()
    return
  end
  local level = ns.Pace and ns.Pace.Level()
  local value
  if level then value = math.min(60, level + (ns.Pace.Fraction() or 0)) end
  B.value = value
  fill:SetWidth(math.max(1, math.floor(BAR_W * ((value or 1) - 1) / 59)))
  for _, m in ipairs(B.markers) do
    local lit = level ~= nil and level >= m.level
    local newly = lit and m.lit == false and B.rendered
    m.lit = lit
    m:SetGrayed(not lit)
    m:SetAlpha(lit and 1 or 0.5)
    if newly then m:Pulse() end
  end
  B.rendered = true
  text:SetText(ns.Pace and ns.Pace.Text() or "")
  frame:Show()
end

local function build()
  frame = UI.Panel("PretreCoachProgressFrame", UIParent)
  B.frame = frame
  frame:SetSize(W, 52)
  frame:SetPoint("TOP", UIParent, "TOP", 0, -60)
  UI.Movable(frame, "progress")

  local title = frame:CreateFontString(nil, "OVERLAY", UI.font.small)
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -4)
  title:SetText(L.PROGRESS_TITLE)

  local track = frame:CreateTexture(nil, "ARTWORK")
  track:SetColorTexture(1, 1, 1, 0.12)
  track:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BAR_Y)
  track:SetSize(BAR_W, BAR_H)
  fill = frame:CreateTexture(nil, "OVERLAY")
  fill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.95)
  fill:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -BAR_Y)
  fill:SetSize(1, BAR_H)

  for i, def in ipairs(MILESTONES) do
    local m = UI.Icon(frame, ICON)
    m.level, m.nameKey = def.level, def.key
    m:SetPoint("CENTER", frame, "TOPLEFT", PAD + BAR_W * (def.level - 1) / 59, -(BAR_Y + BAR_H / 2))
    m:SetIcon(def.icon)
    m:SetScript("OnEnter", tooltip)
    m:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
    B.markers[i] = m
  end

  text = frame:CreateFontString(nil, "OVERLAY", UI.font.small)
  text:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(BAR_Y + BAR_H + 10))
  text:SetWidth(BAR_W)
  text:SetJustifyH("LEFT")
end

-- Commande /coach progress et menu de la minicarte.
function ns.ToggleProgress()
  local show = ns.db.show
  show.progress = show.progress == false
  B.Render()
  if ns.RefreshOptions then ns.RefreshOptions() end
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  build()
  B.Render()
end)
ns.Listen("PACE", B.Render)
ns.Listen("STATE", B.Render) -- le niveau lu au chargement peut arriver en retard
ns.On("PLAYER_REGEN_ENABLED", B.Render)
