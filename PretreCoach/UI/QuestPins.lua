-- Repères de quêtes sur la carte du monde (WorldMapFrame), à la place de ceux de l'addon Questie : affichage seul (Règle 0).
-- « ! » à prendre, « ? » à rendre, un point pour un objectif en cours ; un anneau doré numéroté sur les arrêts de l'itinéraire.
-- Cadres simples (aucun gabarit sécurisé), pool de MAX repères réutilisés, rien créé en combat. Clic gauche = repère utilisateur
-- (Goto.Place, clic du joueur seulement). Tout sous pcall. Pas de repères sur la minicarte.
local _, ns = ...
local UI, L = ns.UI, ns.L

local P = { pins = {} }
UI.QuestPins = P

local MAX = 60
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
    local line = L["QPIN_" .. d.kind]
    if type(d.level) == "number" and d.level > 0 then line = line .. ", " .. L.QPIN_LEVEL:format(d.level) end
    GameTooltip:AddLine(line, 1, 0.82, 0)
    if d.n then GameTooltip:AddLine(L.QPIN_STEP:format(d.n), 0.8, 0.8, 0.85) end
    GameTooltip:Show()
  end)
end

local function newPin(child)
  local b = CreateFrame("Button", nil, child)
  b:SetSize(18, 18)
  pcall(function() b:SetFrameLevel((child:GetFrameLevel() or 1) + 50) end)
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

local function refresh()
  if InCombatLockdown() then return end -- pas de création de cadre en combat : les repères gardent leur état
  local wm = _G.WorldMapFrame
  local child = wm and wm.ScrollContainer and wm.ScrollContainer.Child
  local shown = 0
  local on = ((ns.db and ns.db.show) or {}).questpins ~= false
  if on and child and wm:IsShown() and ns.Quests then
    local mapID, w, h = wm:GetMapID(), child:GetWidth(), child:GetHeight()
    if type(mapID) == "number" and type(w) == "number" and type(h) == "number" and w > 0 and h > 0 then
      for _, d in ipairs(ns.Quests.Pins(mapID)) do
        if shown >= MAX then break end
        shown = shown + 1
        local pin = P.pins[shown]
        if not pin then pin = newPin(child) P.pins[shown] = pin end
        if pin.kind ~= d.kind then
          pin.kind = d.kind
          local s = ICON[d.kind] and 18 or 8
          pin.icon:SetSize(s, s)
          setIcon(pin.icon, d.kind)
        end
        pin.data = d
        pin.ring:SetShown(d.n ~= nil)
        pin.num:SetText(d.n and tostring(d.n) or "")
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", child, "TOPLEFT", d.x / 100 * w, -d.y / 100 * h)
        pin:Show()
      end
    end
  end
  P.shown = shown
  for i = shown + 1, #P.pins do P.pins[i]:Hide() P.pins[i].data = nil end
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
