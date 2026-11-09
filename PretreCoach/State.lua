-- État du personnage, lu sans risque (S.Get, repli si l'API est absente). Rafraîchi sur événements ;
-- en combat on marque « sale » et on rafraîchit à la sortie. Les modules écoutent ns.Listen("STATE", fn(msg, changed)).
-- Les demandes sont groupées (un seul ns.After(0.2) en attente) et ne relisent que la partie concernée.
-- Une lecture qui échoue (nil) garde la valeur précédente. State.Refresh() relit tout, mais avec ce délai.
-- QUEST_TURNED_IN ne relit rien : STATE avec changed = { "quests" } (à interroger via State.QuestDone).
-- State.Knows(key) : cache invalidé sur SPELLS_CHANGED (qui émet STATE { "spells" }) / PLAYER_LEVEL_UP ;
-- State.talents = { [spellID] = { rank, max, name } } (C_Traits, seul système de ce client) ; sur un client Classic
-- (GetTalentInfo présent) : { pos = { [tab][row][col] = rang } }. nil = illisible.
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

-- Arbre moderne : un spellID par entrée de nœud (définition). Un nœud illisible est sauté (le talent sera « inconnu »).
local function readTraits()
  local T = C_Traits
  local cfg = S.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  if not (T and type(cfg) == "number") then return nil end
  local cfgInfo = S.Get(T.GetConfigInfo, cfg)
  if type(cfgInfo) ~= "table" or type(cfgInfo.treeIDs) ~= "table" then return nil end
  local out, read = {}, false
  for _, tree in ipairs(cfgInfo.treeIDs) do
    local nodes = S.Get(T.GetTreeNodes, tree)
    for _, nodeID in ipairs(type(nodes) == "table" and nodes or {}) do
      local node = S.Get(T.GetNodeInfo, cfg, nodeID)
      if type(node) == "table" and type(node.activeRank) == "number" and type(node.maxRanks) == "number" then
        read = true
        local ids = type(node.entryIDs) == "table" and node.entryIDs or {}
        local active = type(node.activeEntry) == "table" and node.activeEntry.entryID or nil
        for _, entryID in ipairs(ids) do
          local entry = S.Get(T.GetEntryInfo, cfg, entryID)
          local def = type(entry) == "table" and entry.definitionID and S.Get(T.GetDefinitionInfo, entry.definitionID)
          local spellID = type(def) == "table" and def.spellID
          if type(spellID) == "number" then
            local rank = (#ids == 1 or active == entryID) and node.activeRank or 0
            out[spellID] = { rank = rank, max = node.maxRanks, name = S.Get(C_Spell and C_Spell.GetSpellName, spellID) }
          end
        end
      end
    end
  end
  return read and out or nil
end

local function readClassic()
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
  return { pos = t }
end

local function readTalents() return readTraits() or readClassic() end

-- Nom localisé d'un sort (repli par nom de Calc.TalentGap) ; nil si inconnu.
function State.SpellName(id) return (S.Get(C_Spell and C_Spell.GetSpellName, id)) end

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
    local unspent = S.Get(GetNumUnspentTalents)
    if unspent == nil then -- booléen : 1 ou 0
      local has = S.Get(C_ClassTalents and C_ClassTalents.HasUnspentTalentPoints)
      if has ~= nil then unspent = has and 1 or 0 end
    end
    keep("unspentTalents", unspent)
    keep("specGroups", S.Get(GetNumSpecGroups))
  end
  if w.profs then keep("profs", readProfs()) end
  if w.spells then changed[#changed + 1] = "spells" end
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
from("ACTIVE_TALENT_GROUP_CHANGED", { talents = true })
from("SKILL_LINES_CHANGED", { profs = true })
-- sorts appris : le cache est invalidé et un STATE { "spells" } est émis (groupé par le délai de 0,2 s)
local function spellsChanged()
  invalidateKnows()
  request({ spells = true })
end
on("SPELLS_CHANGED", spellsChanged)
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
-- Rang d'un talent retrouvé par son nom dans l'arbre C_Traits ; nil = arbre ou talent illisible (le nom est localisé).
function State.TalentRankByName(name)
  local t = State.talents
  if type(t) ~= "table" then return nil end
  for _, e in pairs(t) do
    if type(e) == "table" and type(e.name) == "string" and type(e.rank) == "number" and e.name:lower() == name:lower() then return e.rank end
  end
end

function State.QuestDone(id)
  local fn = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted -- repli Classic
  return (S.Get(fn, id))
end

local spellByKey = {}
for _, sp in ipairs(ns.Data.Spells) do spellByKey[sp.key] = sp end

-- Sort connu ? true si UNE des API le dit (sur Forever, IsPlayerSpell rend faux pour un rang superieur appris : le livre
-- de sorts C_SpellBook, comme What's Training, le voit) ; false si au moins une repond non ; nil si aucune ne repond.
local BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player or 0
function State.SpellKnown(id)
  local SB, answered = C_SpellBook, nil
  local tries = { { SB and SB.IsSpellInSpellBook, id, BANK, false }, { SB and SB.IsSpellKnown, id, BANK },
    { IsPlayerSpell, id }, { IsSpellKnown, id }, { IsSpellKnownOrOverridesKnown, id } }
  for _, t in ipairs(tries) do
    if t[1] then
      local v = S.Get(unpack(t, 1, 4))
      if v == true then return true end
      if v == false then answered = false end
    end
  end
  return answered
end

-- Plus haut rang connu du sort (0 si aucun) ; nil si inconnu (API absente, clé inconnue, ou aucun rang n'existe
-- dans le client). Un rang dont l'ID n'a pas de nom (C_Spell.GetSpellName / GetSpellInfo) est ignoré.
local function computeKnows(sp)
  local nameFn = (C_Spell and C_Spell.GetSpellName) or GetSpellInfo
  local answered = false
  local exists = false
  for i = #sp.ranks, 1, -1 do
    local id = sp.ranks[i].id
    local nameState = nameFn and select(2, S.Get(nameFn, id))
    if nameState ~= "nil" then -- si l'API de nom est absente ou en erreur, on ne filtre pas
      exists = true
      local known = State.SpellKnown(id)
      if known == true then return i end
      if known ~= nil then answered = true end
    end
  end
  return exists and answered and 0 or nil
end

function State.Knows(key)
  local sp = spellByKey[key]
  if not sp then return nil end
  local v = knownCache[key]
  if v == nil then
    v = computeKnows(sp)
    knownCache[key] = v == nil and NONE or v
  end
  if v == NONE then return nil end
  return v
end
