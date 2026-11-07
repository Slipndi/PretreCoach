-- Fenêtre « Guide » et carte compacte « Prochain objectif » : affichage seul de ns.Guide, aucune logique métier.
-- Lignes réutilisées (pool). Mise à jour sur GUIDE et STATE si la fenêtre est visible, reportée après le combat.
local ADDON, ns = ...
local UI, L, Guide = ns.UI, ns.L, ns.Guide
local C = UI.color

local WIN_NAME, CARD_NAME = "PretreCoachGuideFrame", "PretreCoachCompactFrame"
local TABS = { "now", "next", "talents", "spells", "dungeons", "zones", "profs", "undead" }
local BADGE = { -- statut de zone -> couleur
  adaptee = { 0.75, 0.95, 0.8 }, bientot = C.warn, verte = C.bad, haute = C.warn, neutre = { 0.6, 0.6, 0.65 },
}
local WHITE = "Interface\\Buttons\\WHITE8X8"

-- État exposé aux tests : compte des rafraîchissements, pool de lignes, cadres.
local G = { count = 0, rows = {}, used = 0 }
UI.GuideWin = G
local win, card, content, scroll, bar
local rows, lastDone, waiting = G.rows, {}, false

local function gdb() return (ns.db and ns.db.guide) or {} end
local function tab() return gdb().tab or "now" end

local function fontString(parent, font)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetJustifyH("LEFT")
  return fs
end

local function setColor(fs, c, a) fs:SetTextColor(c[1], c[2], c[3], a or 1) end

local function textButton(parent, label, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.1)
  b.label = fontString(b, UI.font.small)
  b.label:SetPoint("CENTER", b, "CENTER")
  b.label:SetText(label)
  return b
end

local function tooltip(owner, text)
  pcall(function()
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
end

------------------------------------------------------------------------
-- lignes (pool)
------------------------------------------------------------------------
local function newRow()
  local r = CreateFrame("Frame", nil, content)
  r.hl = r:CreateTexture(nil, "BACKGROUND")
  r.hl:SetAllPoints(r)
  r.hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.16)
  r.dot = r:CreateTexture(nil, "ARTWORK")
  r.dot:SetSize(8, 8)
  r.dot:SetPoint("TOPLEFT", r, "TOPLEFT", 5, -8)
  r.text = fontString(r, UI.font.text)
  r.sub = fontString(r, UI.font.small)

  local b = CreateFrame("Button", nil, r)
  b:SetSize(16, 16)
  b:SetPoint("TOPLEFT", r, "TOPLEFT", 6, -4)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
  b.check = b:CreateTexture(nil, "ARTWORK")
  b.check:SetAllPoints(b)
  b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
  b.q = fontString(b, UI.font.text)
  b.q:SetPoint("CENTER", b, "CENTER")
  b.q:SetText("?")
  setColor(b.q, C.warn)
  r.box = b
  -- « Repère » : pose un repère de carte vers r.dest (clic du joueur seulement)
  r.go = textButton(r, L.GO_PLACE, 48, 16)
  r.go:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", -4, 4)
  r.go:SetScript("OnClick", function() ns.Goto.Place(r.dest) end)
  r.go:Hide()
  -- petite animation de la coche quand l'objectif passe à fait
  r.pop = b.check:CreateAnimationGroup()
  local a = r.pop:CreateAnimation("Alpha")
  a:SetFromAlpha(0)
  a:SetToAlpha(1)
  a:SetDuration(0.4)
  b:SetScript("OnClick", function()
    local e = r.entry
    if e and e.manual then Guide.SetManual(e.id, not e.done) end
  end)
  b:SetScript("OnEnter", function(self)
    if r.entry and r.entry.unknown then tooltip(self, L.GW_UNKNOWN_TIP) end
  end)
  b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  return r
end

-- Pose la ligne à la hauteur y ; rend sa hauteur. mode : "now" (case), "next" (point de frise), "ref" (surlignage).
local function fill(r, mode, item, y, w)
  local tx = mode == "ref" and 8 or 28
  r.entry = mode == "now" and item or nil
  r:ClearAllPoints()
  r:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
  r:SetWidth(w)
  r.pop:Stop()
  r.box.check:SetAlpha(1)
  r.box:SetShown(mode == "now")
  r.dot:SetShown(mode == "next")
  r.hl:SetShown(mode == "ref" and item.highlight == true)
  r.text:ClearAllPoints()
  r.text:SetPoint("TOPLEFT", r, "TOPLEFT", tx, -4)
  r.text:SetWidth(w - tx - 6)
  r.text:SetText(item.text or "")
  local sub = item.sub
  -- « Où aller » : objectif pas encore fait et doté d'une cible ; le bouton n'existe que s'il y a des coordonnées
  local d = mode == "now" and not item.done and item.go and ns.Goto.For(item.go) or nil
  r.dest = d
  local can = ns.Goto.CanPlace(d)
  if d then sub = (sub and sub ~= "") and (sub .. "  ·  " .. L.GO_WHERE:format(d.text)) or L.GO_WHERE:format(d.text) end
  r.go:SetShown(can)
  r.sub:ClearAllPoints()
  r.sub:SetPoint("TOPLEFT", r.text, "BOTTOMLEFT", 0, -1)
  r.sub:SetWidth(w - tx - 6 - (can and 52 or 0))
  r.sub:SetText(sub or "")
  r.sub:SetShown(sub ~= nil and sub ~= "")

  if mode == "now" then
    local e = item
    r.box.check:SetShown(e.done)
    r.box.q:SetShown(e.unknown)
    r.box:EnableMouse(e.manual == true)
    if e.done then setColor(r.text, C.good, 0.6) else setColor(r.text, C.white) end
    if lastDone[e.id] == false and e.done then r.pop:Play() end
    lastDone[e.id] = e.done
  elseif mode == "next" then
    local c = item.state == "courant" and C.accent or C.white
    r.dot:SetColorTexture(c[1], c[2], c[3], item.state == "passe" and 0.4 or 1)
    setColor(r.text, c, item.state == "passe" and 0.5 or 1)
    setColor(r.sub, C.accent, item.state == "passe" and 0.4 or 0.9)
  else
    setColor(r.text, C.white, item.highlight and 1 or 0.55)
    setColor(r.sub, C.accent, item.highlight and 0.95 or 0.5)
  end
  local h = 8 + (r.text:GetStringHeight() or 14) + ((sub and sub ~= "") and ((r.sub:GetStringHeight() or 12) + 1) or 0)
  h = math.max(h, 24)
  r:SetHeight(h)
  r:Show()
  return h
end

------------------------------------------------------------------------
-- rendu
------------------------------------------------------------------------
local function levelText(h)
  if type(h.level) ~= "number" then return L.GW_LEVEL_UNKNOWN end
  return L.GW_LEVEL:format(h.level) .. (h.tier and ("  ·  " .. L.GW_TIER:format(h.tier)) or "")
end

local function refreshHeader()
  local h = Guide.Header()
  win.lvl:SetText(levelText(h))
  bar:SetValue(h.progress or 0)
  win.zone:SetText(h.zoneName or L.GW_ZONE_UNKNOWN)
  local status = h.zoneStatus or "neutre"
  local text = L["GW_ZONE_" .. status] or ""
  if status == "verte" and h.nextZone then text = text .. "  ·  " .. L.GW_GOTO:format(h.nextZone) end
  win.badge:SetText(text)
  setColor(win.badge, BADGE[status] or BADGE.neutre)
  win.count:SetText(ns.Training.CountText())
end

local function paintTabs()
  for i, b in ipairs(win.tabs) do
    local on = TABS[i] == tab()
    b.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], on and 0.4 or 0.1)
    setColor(b.label, on and C.white or { 0.7, 0.7, 0.75 })
  end
end

local function items()
  local t = tab()
  if t == "now" then
    -- objectifs faits : retirés de la liste (seul ce qui reste à faire s'affiche)
    local todo = {}
    for _, e in ipairs(Guide.Evaluate()) do if not e.done then todo[#todo + 1] = e end end
    return "now", todo, L.GW_NOW_EMPTY
  end
  if t == "next" then return "next", Guide.Milestones(), L.GW_EMPTY end
  return "ref", Guide.Reference(t), L.GW_EMPTY
end

local function refreshWin()
  G.count = G.count + 1
  refreshHeader()
  paintTabs()
  local mode, list, empty = items()
  local w = scroll:GetWidth()
  if not w or w < 50 then w = 360 end
  w = w - 4
  local y, first, last = 4, nil, nil
  for i, item in ipairs(list) do
    local r = rows[i]
    if not r then r = newRow() rows[i] = r end
    if mode == "next" then
      first = first or y + 12
      last = y + 12
    end
    y = y + fill(r, mode, item, y, w) + 2
  end
  for i = #list + 1, #rows do rows[i]:Hide() rows[i].entry = nil end
  G.used = #list
  content.empty:SetText(empty)
  content.empty:SetShown(#list == 0)
  -- frise : fine ligne violette entre le premier et le dernier point
  content.line:SetShown(mode == "next" and first ~= nil and last > first)
  if content.line:IsShown() then
    content.line:ClearAllPoints()
    content.line:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -first)
    content.line:SetSize(2, last - first)
  end
  content:SetSize(w, y + 8)
end

local function refreshCard()
  local e = Guide.Next()
  local text = e and ((e.unknown and "? " or "") .. e.text) or L.GW_NEXT_NONE
  card.text:SetText(text)
  local d = e and not e.done and e.go and ns.Goto.For(e.go) or nil
  card.dest = d
  local can = ns.Goto.CanPlace(d)
  card.where:SetText(d and L.GO_WHERE:format(d.text) or "")
  card.go:SetShown(can)
  local count = ns.Training.CountText()
  card.count:SetText(count)
  card:SetHeight(30 + (card.text:GetStringHeight() or 14) + (d and ((card.where:GetStringHeight() or 12) + 2) or 0)
    + ((count ~= "" or can) and 14 or 0))
end

local function request()
  if card and card:IsShown() then refreshCard() end
  if not (win and win:IsShown()) then return end -- à l'ouverture, OnShow rafraîchit
  if InCombatLockdown() then waiting = true return end
  refreshWin()
end

ns.Listen("GUIDE", request)
ns.Listen("STATE", request)
ns.Listen("QINDEX", request) -- les lieux "Ou aller" dependent de l'index
ns.On("PLAYER_REGEN_ENABLED", function()
  if waiting then
    waiting = false
    request()
  end
end)

------------------------------------------------------------------------
-- construction (à la première ouverture)
------------------------------------------------------------------------
local function setTab(key)
  if ns.db and ns.db.guide then ns.db.guide.tab = key end
  if scroll then scroll:SetVerticalScroll(0) end
  if win and win:IsShown() then refreshWin() end
end

-- Mémorise si le guide (fenêtre ou carte) était ouvert, pour la prochaine connexion.
local function setOpen(v) if ns.db and ns.db.guide then ns.db.guide.open = v end end

local function buildWin()
  win = UI.Panel(WIN_NAME, UIParent)
  G.win = win
  win:SetSize(390, 440)
  win:SetPoint("CENTER")
  win:SetFrameStrata("DIALOG")
  win:Hide()
  UI.Movable(win, "guide", true)
  tinsert(UISpecialFrames, WIN_NAME)

  win.lvl = fontString(win, UI.font.title)
  win.lvl:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -9)
  setColor(win.lvl, C.accent)

  local close = textButton(win, "×", 20, 18)
  close:SetPoint("TOPRIGHT", win, "TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() win:Hide() end)
  local compact = textButton(win, L.GW_COMPACT, 64, 18)
  compact:SetPoint("RIGHT", close, "LEFT", -4, 0)
  compact:SetScript("OnClick", function() ns.SetCompact(true) end)

  local back = win:CreateTexture(nil, "ARTWORK")
  back:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -32)
  back:SetPoint("TOPRIGHT", win, "TOPRIGHT", -10, -32)
  back:SetHeight(8)
  back:SetColorTexture(1, 1, 1, 0.08)
  bar = CreateFrame("StatusBar", nil, win)
  bar:SetPoint("TOPLEFT", back, "TOPLEFT")
  bar:SetPoint("BOTTOMRIGHT", back, "BOTTOMRIGHT")
  bar:SetStatusBarTexture(WHITE)
  bar:SetStatusBarColor(C.accent[1], C.accent[2], C.accent[3])
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(0)

  win.zone = fontString(win, UI.font.text)
  win.zone:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -44)
  win.badge = fontString(win, UI.font.small)
  win.badge:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -60)
  win.count = fontString(win, UI.font.small)
  win.count:SetPoint("TOPRIGHT", win, "TOPRIGHT", -10, -46)
  win.count:SetJustifyH("RIGHT")
  setColor(win.count, C.accent)

  win.tabs = {}
  for i, key in ipairs(TABS) do
    local b = textButton(win, L["GW_TAB_" .. key], 86, 20)
    b:SetPoint("TOPLEFT", win, "TOPLEFT", 10 + ((i - 1) % 4) * 89, -80 - math.floor((i - 1) / 4) * 22)
    b:SetScript("OnClick", function() setTab(key) end)
    win.tabs[i] = b
  end

  -- ScrollFrame simple, sans modèle (certains modèles Retail manquent sur Forever)
  scroll = CreateFrame("ScrollFrame", nil, win)
  scroll:SetPoint("TOPLEFT", win, "TOPLEFT", 10, -128)
  scroll:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -10, 18)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, d)
    local y = self:GetVerticalScroll() - d * 50
    self:SetVerticalScroll(math.max(0, math.min(y, self:GetVerticalScrollRange())))
  end)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(360, 10)
  scroll:SetScrollChild(content)
  content.empty = fontString(content, UI.font.text)
  content.empty:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -8)
  setColor(content.empty, { 0.7, 0.7, 0.75 })
  content.line = content:CreateTexture(nil, "BORDER")
  content.line:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.7)

  win:SetScript("OnShow", function() setOpen(true) refreshWin() end)
  win:SetScript("OnHide", function() setOpen(false) end)
  win:SetScript("OnSizeChanged", function() request() end)
end

local function buildCard()
  card = UI.Panel(CARD_NAME, UIParent)
  G.card = card
  card:SetSize(260, 56)
  card:SetPoint("TOP", UIParent, "TOP", 0, -140)
  card:SetFrameStrata("MEDIUM")
  card:Hide()
  UI.Movable(card, "compact")
  local title = fontString(card, UI.font.small)
  title:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -7)
  title:SetText(L.GW_NEXT_TITLE)
  setColor(title, C.accent)
  card.text = fontString(card, UI.font.text)
  card.text:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -22)
  card.text:SetWidth(240)
  card.where = fontString(card, UI.font.small)
  card.where:SetPoint("TOPLEFT", card.text, "BOTTOMLEFT", 0, -2)
  card.where:SetWidth(240)
  card.go = textButton(card, L.GO_PLACE, 48, 16)
  card.go:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -6, 5)
  card.go:SetScript("OnClick", function() ns.Goto.Place(card.dest) end)
  card.go:Hide()
  card.count = fontString(card, UI.font.small)
  card.count:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 6)
  setColor(card.count, C.accent)
  local close = textButton(card, "×", 18, 16)
  close:SetPoint("TOPRIGHT", card, "TOPRIGHT", -4, -4)
  close:SetScript("OnClick", function() card:Hide() end)
  local expand = textButton(card, "+", 18, 16)
  expand:SetPoint("RIGHT", close, "LEFT", -3, 0)
  expand:SetScript("OnClick", function() ns.SetCompact(false) end)
  expand:SetScript("OnEnter", function(self) tooltip(self, L.GW_EXPAND) end)
  expand:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  card:SetScript("OnShow", function() setOpen(true) refreshCard() end)
  card:SetScript("OnHide", function() setOpen(false) end)
end

------------------------------------------------------------------------
-- commandes
------------------------------------------------------------------------
local function showView()
  if gdb().compact then
    if not card then buildCard() end
    card:Show()
  else
    if not win then buildWin() end
    win:Show()
  end
end

function ns.ToggleGuide()
  local open = (win and win:IsShown()) or (card and card:IsShown())
  if open then
    if win then win:Hide() end
    if card then card:Hide() end
  else
    showView()
  end
end

-- Bascule (ou fixe) le mode compact et affiche la vue correspondante.
function ns.SetCompact(on)
  if on == nil then on = not gdb().compact end
  if ns.db and ns.db.guide then ns.db.guide.compact = on and true or false end
  if win then win:Hide() end
  if card then card:Hide() end
  showView()
end

-- Affiche ou masque le guide (case des options) sans toucher à ns.db.show.
function ns.SetGuideShown(on)
  if on then
    if not ((win and win:IsShown()) or (card and card:IsShown())) then showView() end
  else
    if win then win:Hide() end
    if card then card:Hide() end
  end
end

-- open == nil : première connexion, on ouvre une fois.
ns.On("ADDON_LOADED", function(_, name)
  if name == ADDON and ns.db and ns.db.show and ns.db.show.guide ~= false and gdb().open ~= false then showView() end
end)
