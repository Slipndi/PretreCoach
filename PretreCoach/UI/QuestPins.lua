-- Repères de quêtes sur la carte du monde (WorldMapFrame), à la place de ceux de l'addon Questie : affichage seul (Règle 0).
-- « ! » à prendre, « ? » à rendre, un point pour un objectif en cours ; un anneau doré numéroté sur les arrêts de l'itinéraire.
-- Seconde source : nœuds d'herbes de la carte (ns.Gather), plus petits, ceux de la boucle numérotés.
-- Cadres simples (aucun gabarit sécurisé), pools de MAX + HMAX repères réutilisés, rien créé en combat. Clic gauche = repère utilisateur
-- (Goto.Place, clic du joueur seulement). Tout sous pcall. Pas de repères sur la minicarte.
local _, ns = ...
local UI, L = ns.UI, ns.L

local P = { pins = {}, herbs = {} }
UI.QuestPins = P

local MAX, HMAX = 60, 80
local ICON = { -- atlas puis texture de repli (à vérifier en jeu)
  pickup = { "QuestNormal", "Interface\\GossipFrame\\AvailableQuestIcon" },
  turnin = { "QuestTurnin", "Interface\\GossipFrame\\ActiveQuestIcon" },
}
local hooked, mapHook, evFrame, lastMap, acc = false, false, nil, nil, 0

local function setIcon(tex, kind)
  local i = ICON[kind]
  if not i then
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetVertexColor(1, 0.82, 0)
    return
  end
  tex:SetVertexColor(1, 1, 1)
  local ok = pcall(tex.SetAtlas, tex, i[1])
  local a
  if ok then
    local o, v = pcall(tex.GetAtlas, tex)
    a = o and v
  end
  if not a then tex:SetTexture(i[2]) end
end

local function tip(pin)
  pcall(function()
    local d = pin.data
    if not d then return end
    GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
    GameTooltip:AddLine(d.name, 1, 1, 1)
    if d.kind == "herb" then
      if d.price then GameTooltip:AddLine(L.HPIN_PRICE:format(ns.Prof.Money(d.price)), 1, 0.82, 0) end
      if d.skillup then GameTooltip:AddLine(L.GATHER_SKILLUP, 0.4, 1, 0.4) end
      if d.n then GameTooltip:AddLine(L.HPIN_STEP:format(d.n), 0.8, 0.8, 0.85) end
      GameTooltip:Show()
      return
    end
    local line = L["QPIN_" .. d.kind]
    if type(d.level) == "number" and d.level > 0 then line = line .. ", " .. L.QPIN_LEVEL:format(d.level) end
    GameTooltip:AddLine(line, 1, 0.82, 0)
    if d.n then GameTooltip:AddLine(L.QPIN_STEP:format(d.n), 0.8, 0.8, 0.85) end
    GameTooltip:Show()
  end)
end

local function newPin(child, level)
  local b = CreateFrame("Button", nil, child)
  b:SetSize(18, 18)
  pcall(function() b:SetFrameLevel((child:GetFrameLevel() or 1) + level) end)
  b:RegisterForClicks("LeftButtonUp")
  b.ring = b:CreateTexture(nil, "BACKGROUND")
  b.ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  b.ring:SetBlendMode("ADD")
  b.ring:SetVertexColor(1, 0.82, 0)
  b.ring:SetSize(42, 42)
  b.ring:SetPoint("CENTER", b, "CENTER")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetPoint("CENTER", b, "CENTER")
  b.num = b:CreateFontString(nil, "OVERLAY", UI.font.small)
  b.num:SetPoint("BOTTOMLEFT", b, "TOPRIGHT", -6, -6)
  b:SetScript("OnEnter", tip)
  b:SetScript("OnLeave", function() pcall(function() GameTooltip:Hide() end) end)
  b:SetScript("OnClick", function(self)
    local d = self.data
    if d and ns.Goto then ns.Goto.Place(ns.Goto.For({ mapID = d.mapID, x = d.x, y = d.y, text = d.name })) end
  end)
  return b
end

-- Dessine list dans pool (au plus max repères) ; rend le nombre affiché.
local function draw(pool, list, max, child, w, h, level)
  local shown = 0
  for _, d in ipairs(list) do
    if shown >= max then break end
    shown = shown + 1
    local pin = pool[shown]
    if not pin then pin = newPin(child, level) pool[shown] = pin end
    local herb = d.kind == "herb"
    local key = herb and d.itemID or d.kind
    if pin.kind ~= key then
      pin.kind = key
      local s = herb and 12 or ICON[d.kind] and 18 or 8
      pin:SetSize(math.max(s, 12), math.max(s, 12))
      pin.icon:SetSize(s, s)
      pin.ring:SetSize(herb and 28 or 42, herb and 28 or 42)
      if herb then
        pin.icon:SetVertexColor(1, 1, 1)
        pin.icon:SetTexture(ns.Gather.Icon(d.itemID))
      else
        setIcon(pin.icon, d.kind)
      end
    end
    pin.data = d
    pin.ring:SetShown(d.n ~= nil)
    pin.num:SetText(d.n and tostring(d.n) or "")
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", child, "TOPLEFT", d.x / 100 * w, -d.y / 100 * h)
    pin:Show()
  end
  for i = shown + 1, #pool do pool[i]:Hide() pool[i].data = nil end
  return shown
end

local function refresh()
  if InCombatLockdown() then return end -- pas de création de cadre en combat : les repères gardent leur état
  local wm = _G.WorldMapFrame
  local child = wm and wm.ScrollContainer and wm.ScrollContainer.Child
  local show = (ns.db and ns.db.show) or {}
  local quests, herbs, w, h = {}, {}, 0, 0
  if child and wm:IsShown() then
    local mapID = wm:GetMapID()
    w, h = child:GetWidth(), child:GetHeight()
    if type(mapID) == "number" and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      if show.questpins ~= false and ns.Quests then quests = ns.Quests.Pins(mapID) end
      if show.herbpins ~= false and ns.Gather then herbs = ns.Gather.Pins(mapID) end
    end
  end
  P.shown = draw(P.pins, quests, MAX, child, w, h, 50)
  P.herbShown = draw(P.herbs, herbs, HMAX, child, w, h, 40) -- sous les quêtes
end

local function poll(_, elapsed)
  acc = acc + (elapsed or 0)
  if acc < 0.5 then return end
  acc = 0
  local ok, id = pcall(_G.WorldMapFrame.GetMapID, _G.WorldMapFrame)
  if ok and id ~= lastMap then lastMap = id P.Update() end
end

local ensure
function P.Update()
  ensure()
  local ok, err = pcall(refresh)
  if not ok then ns.Debug("Reperes de carte : %s", tostring(err)) end
end

-- Accroche la carte dès qu'elle existe : OnShow, changement de carte (hook ou EventRegistry), sinon sondage à 0,5 s
-- seulement pendant que la carte est ouverte.
ensure = function()
  if hooked then return end
  local wm = _G.WorldMapFrame
  if not wm then return end
  hooked = true
  pcall(function()
    evFrame = CreateFrame("Frame")
    evFrame:RegisterEvent("WORLD_MAP_UPDATE")
    evFrame:SetScript("OnEvent", function() P.Update() end)
  end)
  local ok1 = pcall(function() hooksecurefunc(wm, "OnMapChanged", function() P.Update() end) end)
  local ok2 = pcall(function() EventRegistry.RegisterCallback(EventRegistry, "MapCanvas.MapSet", function() P.Update() end, P) end)
  mapHook = ok1 or ok2
  pcall(function()
    wm:HookScript("OnShow", function()
      if not mapHook and evFrame then acc = 0 evFrame:SetScript("OnUpdate", poll) end
      P.Update()
    end)
    wm:HookScript("OnHide", function()
      if evFrame then evFrame:SetScript("OnUpdate", nil) end
      P.Update()
    end)
  end)
end
P.Ensure = ensure

ns.Listen("QPINS", function() P.Update() end)
ns.On("PLAYER_LOGIN", function() ensure() ns.After(3, ensure) end)
