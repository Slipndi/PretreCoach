-- « Où aller » : lieu d'un PNJ utile (via Ext/Questie.lua) et repère de carte posé sur demande du joueur.
-- Goto.For(cible) -> { text, where, mapID, x, y } ou nil si la cible est inconnue ; x et y en pourcentage 0-100.
-- Cible : "WAND", "PRIEST", "ALCHEMY", "HERBALISM", "FIRSTAID" ou "Q<questID>". Le texte ne cite jamais de nom de PNJ anglais :
-- rôle, zone localisée et coordonnées. Sans Questie : un texte neutre, sans coordonnées.
local _, ns = ...
local S, L, Q, State, Calc = ns.S, ns.L, ns.Q, ns.State, ns.Calc

local Goto = {}
ns.Goto = Goto

local ROLES = { PRIEST = true, ALCHEMY = true, HERBALISM = true, FIRSTAID = true }

local function zoneName(w)
  if w.uiMapID then
    local info = S.Get(C_Map and C_Map.GetMapInfo, w.uiMapID)
    if type(info) == "table" and type(info.name) == "string" then return info.name end
  end
  local n = S.Get(C_Map and C_Map.GetAreaInfo, w.areaID)
  return type(n) == "string" and n or nil
end

-- head = lieu sans coordonnées (`where`) ; tail = suite du texte.
local function out(head, w, tail)
  local text = w and (head .. L.GO_XY:format(w.x, w.y)) or head
  return { text = text .. (tail or ""), where = head, mapID = w and w.uiMapID, x = w and w.x, y = w and w.y }
end

-- PNJ du rôle le plus proche, avec sa zone localisée ; nil sans Questie ou sans index.
local function find(role)
  local _, w = Q.Nearest(role, State.mapID)
  local zone = w and zoneName(w)
  if zone then return w, zone end
end

function Goto.For(target)
  if target == "WAND" then
    local _, best = Calc.WandStatus(State.level, State.wand)
    local tail = " : " .. (best and L.GO_WAND_BUY:format(best.level) or L.GO_WAND_ANY)
    -- piste quête : la source de la baguette conseillée (Data/Gear.lua), seulement si elle parle d'une quête
    if best and best.source:find("Quête", 1, true) then tail = tail .. " ; " .. best.source end
    local w, zone = find("AUCTIONEER")
    if w then return out(L.GO_AH:format(zone), w, tail) end
    return out(L.GO_AH_FALLBACK, nil, tail)
  end
  if ROLES[target] then
    local w, zone = find(target)
    if w then return out(L.GO_ROLE:format(L["GO_ROLE_" .. target], zone), w) end
    return out(L["GO_FALLBACK_" .. target])
  end
  local qid = tostring(target):match("^Q(%d+)$")
  if qid then
    local by = Q.Quest(tonumber(qid), "startedBy")
    local npc = type(by) == "table" and type(by[1]) == "table" and by[1][1]
    local w = npc and Q.Where(npc)
    local zone = w and zoneName(w)
    if zone then return out(L.GO_QUEST:format(zone), w) end
    return out(L.GO_QUEST_NONE)
  end
end

-- Le bouton « Repère » n'a de sens qu'avec une carte et des coordonnées.
function Goto.CanPlace(d)
  return type(d) == "table" and d.mapID ~= nil and d.x ~= nil and d.y ~= nil
end

-- Repère de carte (aide visuelle, non protégée) ; sinon le texte dans le chat. À appeler UNIQUEMENT depuis un clic du joueur.
function Goto.Place(dest)
  if type(dest) == "string" then dest = Goto.For(dest) end
  if type(dest) ~= "table" then return false end
  local placed = false
  if Goto.CanPlace(dest) and S.Get(C_Map and C_Map.CanSetUserWaypointOnMap, dest.mapID) == true then
    placed = pcall(function()
      C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(dest.mapID, dest.x / 100, dest.y / 100))
      C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end)
  end
  if not placed then ns.Print(L.GO_WHERE, dest.text) end
  return placed
end
