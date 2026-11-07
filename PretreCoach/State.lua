-- État du personnage, lu sans risque (S.Get, repli si l'API est absente). Rafraîchi sur événements ;
-- en combat on marque « sale » et on rafraîchit à la sortie. Les modules écoutent ns.Listen("STATE", fn(msg, changed)).
local _, ns = ...
local S = ns.S

local State = {}
ns.State = State

local PARTS = { "level", "mapID", "zone", "wand", "talents", "unspentTalents", "specGroups", "profs" }
local pendingLevel, dirty, wandWait

local function deepEq(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepEq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- mapID de la carte actuelle, et zone = première clé de ns.Data.Zones en remontant parentMapID.
local function readZone()
  local mapID = S.Get(C_Map and C_Map.GetBestMapForUnit, "player")
  local id, zone = mapID, nil
  for _ = 1, 10 do
    if type(id) ~= "number" or id == 0 then break end
    if ns.Data.Zones[id] then zone = id break end
    local info = S.Get(C_Map.GetMapInfo, id)
    id = type(info) == "table" and info.parentMapID or nil
  end
  return mapID, zone
end

-- table { itemID, reqLevel, name } ; false = pas de baguette ; nil = illisible.
local function readWand()
  wandWait = nil
  local id, st = S.Get(GetInventoryItemID, "player", INVSLOT_RANGED or 18)
  if st ~= "lisible" and st ~= "nil" then return nil end
  if not id then return false end
  local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local s, _, _, _, _, _, class, sub = S.GetAll(instant, id)
  if s ~= "lisible" or class == nil then return nil end
  if class ~= 2 or sub ~= 19 then return false end
  local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local s2, name, _, _, _, minLevel = S.GetAll(info, id)
  if s2 ~= "lisible" then wandWait = id return { itemID = id } end -- pas en cache : GET_ITEM_INFO_RECEIVED
  return { itemID = id, name = name, reqLevel = minLevel }
end

local function readTalents()
  local nTabs = S.Get(GetNumTalentTabs)
  if type(nTabs) ~= "number" then return nil end
  local t = {}
  for tab = 1, nTabs do
    t[tab] = {}
    local n = S.Get(GetNumTalents, tab)
    if type(n) ~= "number" then return nil end
    for i = 1, n do
      local st, _, _, row, col, rank = S.GetAll(GetTalentInfo, tab, i)
      if st == "lisible" and type(row) == "number" and type(col) == "number" and type(rank) == "number" then
        t[tab][row] = t[tab][row] or {}
        t[tab][row][col] = rank
      end
    end
  end
  return t
end

local function readProfs()
  local profs
  local function take(state, ...)
    if state ~= "lisible" then return end
    profs = {}
    for i = 1, select("#", ...) do
      local idx = (select(i, ...))
      if idx then
        local s, _, _, rank, max, _, _, line = S.GetAll(GetProfessionInfo, idx)
        if s == "lisible" and type(line) == "number" and type(rank) == "number" then
          profs[line] = { rank = rank, max = max }
        end
      end
    end
  end
  take(S.GetAll(GetProfessions))
  if profs then return profs end
  local n = S.Get(GetNumSkillLines)
  if type(n) ~= "number" then return nil end
  profs = {}
  local byName = {}
  for line, d in pairs(ns.Data.Professions) do byName[d.name] = line end
  for i = 1, n do
    local s, name, _, _, rank, _, _, max = S.GetAll(GetSkillLineInfo, i)
    local line = s == "lisible" and byName[name]
    if line and type(rank) == "number" and type(max) == "number" then profs[line] = { rank = rank, max = max } end
  end
  return profs
end

local function refresh()
  dirty = false
  local level = pendingLevel or S.Get(UnitLevel, "player") or State.level
  pendingLevel = nil
  local mapID, zone = readZone()
  local new = { level = level, mapID = mapID, zone = zone, wand = readWand(), talents = readTalents(),
    unspentTalents = S.Get(GetUnspentTalentPoints), specGroups = S.Get(GetNumTalentGroups) or S.Get(GetNumSpecGroups),
    profs = readProfs() }
  local changed = {}
  for _, k in ipairs(PARTS) do
    if not deepEq(State[k], new[k]) then
      State[k] = new[k]
      changed[#changed + 1] = k
    end
  end
  if #changed > 0 then ns.Fire("STATE", changed) end
end

-- Hors combat : rafraîchit tout de suite. En combat : marque sale, repris à PLAYER_REGEN_ENABLED.
local function request()
  if InCombatLockdown() then dirty = true else refresh() end
end
State.Refresh = request

for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_EQUIPMENT_CHANGED",
  "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "SKILL_LINES_CHANGED", "QUEST_TURNED_IN", "SPELLS_CHANGED",
  "LEARNED_SPELL_IN_TAB" }) do
  ns.On(e, function() request() end)
end

-- UnitLevel peut être en retard : on prend le niveau de l'événement.
ns.On("PLAYER_LEVEL_UP", function(_, level)
  if type(level) == "number" then pendingLevel = level end
  request()
end)
ns.On("GET_ITEM_INFO_RECEIVED", function(_, itemID)
  if wandWait and itemID == wandWait then request() end
end)
ns.On("PLAYER_REGEN_ENABLED", function() if dirty then refresh() end end)

-- true/false, ou nil si inconnu.
function State.QuestDone(id)
  local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
  return (S.Get(fn, id))
end

local spellByKey = {}
for _, sp in ipairs(ns.Data.Spells) do spellByKey[sp.key] = sp end

-- Plus haut rang connu du sort (0 si aucun) ; nil si inconnu (API absente ou clé inconnue).
function State.Knows(key)
  local sp = spellByKey[key]
  local fn = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)
  if not sp or not fn then return nil end
  local answered = false
  for i = #sp.ranks, 1, -1 do
    local known = S.Get(fn, sp.ranks[i].id)
    if known == true then return i end
    if known ~= nil then answered = true end
  end
  return answered and 0 or nil
end
