-- État du personnage, lu sans risque (S.Get, repli si l'API est absente). Rafraîchi sur événements ;
-- en combat on marque « sale » et on rafraîchit à la sortie. Les modules écoutent ns.Listen("STATE", fn(msg, changed)).
-- Les demandes sont groupées (un seul ns.After(0.2) en attente) et ne relisent que la partie concernée.
-- Une lecture qui échoue (nil) garde la valeur précédente. State.Refresh() relit tout, mais avec ce délai.
-- QUEST_TURNED_IN ne relit rien : STATE avec changed = { "quests" } (à interroger via State.QuestDone).
-- State.Knows(key) : cache invalidé sur SPELLS_CHANGED / LEARNED_SPELL_IN_TAB / PLAYER_LEVEL_UP (sans message STATE) ;
-- nil (inconnu) si aucun rang du sort n'existe dans le client (pas de nom), sans pouvoir être « à apprendre ».
local _, ns = ...
local S = ns.S

local State = {}
ns.State = State

local PARTS = { "level", "mapID", "zone", "wand", "talents", "unspentTalents", "specGroups", "profs" }
local ALL = { level = true, map = true, wand = true, talents = true, profs = true }
local pendingLevel, dirty, wandWait, scheduled
local want = {}
local wandTries = {} -- itemID -> relances déjà faites sur GET_ITEM_INFO_RECEIVED
local WAND_MAX_TRIES = 3
local knownCache = {}
local NONE = {} -- résultat nil mis en cache

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
    local parent = type(info) == "table" and info.parentMapID or nil
    id = (parent ~= nil and not S.IsSecret(parent)) and parent or nil
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
  wandTries[id] = nil
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
      -- une entrée illisible : on ne rend pas une table partielle (TalentGap signalerait de faux manques)
      if not (st == "lisible" and type(row) == "number" and type(col) == "number" and type(rank) == "number") then return nil end
      t[tab][row] = t[tab][row] or {}
      t[tab][row][col] = rank
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
  local w = want
  want = {}
  local changed = {}
  local function apply(k, v)
    if not deepEq(State[k], v) then
      State[k] = v
      changed[#changed + 1] = k
    end
  end
  local function keep(k, v) if v ~= nil then apply(k, v) end end -- lecture ratée : on garde l'ancienne valeur
  if w.level then
    keep("level", pendingLevel or S.Get(UnitLevel, "player"))
    pendingLevel = nil
  end
  if w.map then
    local mapID, zone = readZone()
    if mapID ~= nil then apply("mapID", mapID) apply("zone", zone) end
  end
  if w.wand then keep("wand", readWand()) end
  if w.talents then
    keep("talents", readTalents())
    keep("unspentTalents", S.Get(GetUnspentTalentPoints))
    keep("specGroups", S.Get(GetNumTalentGroups) or S.Get(GetNumSpecGroups))
  end
  if w.profs then keep("profs", readProfs()) end
  if #changed > 0 then ns.Fire("STATE", changed) end
end

local function flush()
  scheduled = false
  if InCombatLockdown() then dirty = true else refresh() end
end

-- Demande de relecture des parties `parts` ({ wand = true … }) : groupée, un seul ns.After(0.2) en attente.
-- En combat : marque sale, repris à PLAYER_REGEN_ENABLED.
local function request(parts)
  for k in pairs(parts or ALL) do want[k] = true end
  if InCombatLockdown() then dirty = true return end
  if scheduled then return end
  scheduled = true
  ns.After(0.2, flush)
end
State.Refresh = function() request(ALL) end

local function on(e, fn)
  if not ns.On(e, fn) then ns.Debug("évènement refusé : %s", e) end
end

local function invalidateKnows() knownCache = {} end

local function from(e, parts) on(e, function() request(parts) end) end
from("PLAYER_LOGIN", ALL)
from("PLAYER_ENTERING_WORLD", ALL)
from("ZONE_CHANGED_NEW_AREA", { map = true })
from("PLAYER_EQUIPMENT_CHANGED", { wand = true })
from("CHARACTER_POINTS_CHANGED", { talents = true })
from("PLAYER_TALENT_UPDATE", { talents = true })
from("SKILL_LINES_CHANGED", { profs = true })
on("SPELLS_CHANGED", invalidateKnows)
on("LEARNED_SPELL_IN_TAB", invalidateKnows)
on("QUEST_TURNED_IN", function() ns.Fire("STATE", { "quests" }) end)

-- UnitLevel peut être en retard : on prend le niveau de l'événement.
on("PLAYER_LEVEL_UP", function(_, level)
  if type(level) == "number" then pendingLevel = level end
  invalidateKnows()
  request(ALL)
end)
-- Seulement pour la baguette attendue, si le client a réussi, au plus WAND_MAX_TRIES fois par objet.
on("GET_ITEM_INFO_RECEIVED", function(_, itemID, success)
  if not (success and wandWait and itemID == wandWait) then return end
  local n = (wandTries[itemID] or 0) + 1
  if n > WAND_MAX_TRIES then return end
  wandTries[itemID] = n
  request({ wand = true })
end)
on("PLAYER_REGEN_ENABLED", function() if dirty then refresh() end end)

-- true/false, ou nil si inconnu.
function State.QuestDone(id)
  local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
  return (S.Get(fn, id))
end

local spellByKey = {}
for _, sp in ipairs(ns.Data.Spells) do spellByKey[sp.key] = sp end

-- Plus haut rang connu du sort (0 si aucun) ; nil si inconnu (API absente, clé inconnue, ou aucun rang n'existe
-- dans le client). Un rang dont l'ID n'a pas de nom (C_Spell.GetSpellName / GetSpellInfo) est ignoré.
local function computeKnows(sp, fn)
  local nameFn = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
  local answered = false
  local exists = false
  for i = #sp.ranks, 1, -1 do
    local id = sp.ranks[i].id
    local nameState = nameFn and select(2, S.Get(nameFn, id))
    if nameState ~= "nil" then -- si l'API de nom est absente ou en erreur, on ne filtre pas
      exists = true
      local known = S.Get(fn, id)
      if known == true then return i end
      if known ~= nil then answered = true end
    end
  end
  return exists and answered and 0 or nil
end

function State.Knows(key)
  local sp = spellByKey[key]
  local fn = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)
  if not sp or not fn then return nil end
  local v = knownCache[key]
  if v == nil then
    v = computeKnows(sp, fn)
    knownCache[key] = v == nil and NONE or v
  end
  if v == NONE then return nil end
  return v
end
