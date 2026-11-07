-- Pont optionnel vers LibQuestieDB (addon QuestieDB) : lecture seule, tout sous pcall, rien n'est embarque (GPL).
-- Sans QuestieDB, Available() rend false et le reste rend nil. Format lu dans QuestieDB/src/meta/npcMeta.lua.
local _, ns = ...
local Q = {}
ns.Q = Q

local CHUNK = 200 -- PNJ lus par tick
-- role -> morceau du subName (anglais, minuscules). Les subName reels : « Priest Trainer », « First Aid Trainer »...
local ROLES = { PRIEST = "priest", ALCHEMY = "alchemy", HERBALISM = "herbalism", FIRSTAID = "first aid", COOKING = "cooking" }

local lib -- nil = pas encore teste, false = absente ou contrat refuse
function Q.Available()
  if lib == nil then
    local l = _G.LibQuestieDB
    local ok, res = pcall(function() return type(l) == "table" and l.RequireContract(4) end)
    lib = (ok and res == true and type(l.Npc) == "table" and type(l.Quest) == "table") and l or false
  end
  return lib ~= false
end

local function read(entity, id, key)
  if not Q.Available() then return nil end
  local ok, v = pcall(lib[entity].Get, id, key)
  if ok then return v end
end
function Q.Quest(id, key) return read("Quest", id, key) end
function Q.Npc(id, key) return read("Npc", id, key) end

-- Premier point d'apparition. Verifie : spawns = { [areaID] = { { x, y }, ... } }, x et y DEJA en pourcentage 0-100
-- (QuestieDB/Types/LibQuestieDB.t.lua:44 ; valeurs reelles ~40-50). (-1, -1) = instance : ignore.
-- shortcut: uiMapID reste nil, la table AreaID -> uiMapID de QuestieDB est du texte Lua qui exige loadstring (interdit, Regle 0).
function Q.Where(npcID)
  local spawns = Q.Npc(npcID, "spawns")
  if type(spawns) ~= "table" then return nil end
  local home = Q.Npc(npcID, "zoneID")
  local area = spawns[home] and home or nil
  if not area then
    for z in pairs(spawns) do if type(z) == "number" and (not area or z < area) then area = z end end
  end
  local rows = area and spawns[area]
  local row = type(rows) == "table" and rows[1]
  if type(row) ~= "table" or type(row[1]) ~= "number" or row[1] < 0 then return nil end
  return { areaID = area, uiMapID = nil, x = row[1], y = row[2] }
end

------------------------------------------------------------------------
-- Index des PNJ utiles (maitres, commissaires-priseurs)
------------------------------------------------------------------------
local function hasBit(flags, bit) return math.floor(flags / bit) % 2 == 1 end

-- Pas d'API de version de donnees : on prend la version de l'addon QuestieDB.
local function dbVersion()
  local get = _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata
  local ok, v = pcall(get or error, "QuestieDB", "Version")
  return ok and tostring(v) or "?"
end

local running, resume

function Q.StartIndex()
  if running or not Q.Available() or not ns.db then return false end
  local ver = dbVersion()
  if type(ns.db.qindex) == "table" and ns.db.qindex.ver == ver then return false end
  local okIds, ids = pcall(lib.Npc.GetAllIds)
  if not okIds or type(ids) ~= "table" then return false end
  local enum = type(lib.Enum) == "table" and lib.Enum.npcFlags or {}
  local TRAINER, AUCTIONEER = enum.TRAINER or 16, enum.AUCTIONEER or 4096
  local idx = { ver = ver, trainers = {}, auctioneers = {} }
  for role in pairs(ROLES) do idx.trainers[role] = {} end

  local function scan(id)
    local f = Q.Npc(id, "npcFlags")
    if type(f) ~= "number" then return end
    local isT, isA = hasBit(f, TRAINER), hasBit(f, AUCTIONEER)
    if not (isT or isA) then return end
    -- shortcut: joueur suppose Horde (pretre mort-vivant) ; "A" seul et nil (hostile) sont ecartes.
    local fac = Q.Npc(id, "friendlyToFaction")
    if fac ~= "H" and fac ~= "AH" then return end
    if isA then idx.auctioneers[#idx.auctioneers + 1] = id end
    local sub = isT and Q.Npc(id, "subName")
    if type(sub) == "string" then
      sub = sub:lower()
      for role, part in pairs(ROLES) do
        if sub:find(part, 1, true) then idx.trainers[role][#idx.trainers[role] + 1] = id end
      end
    end
  end

  local i = 1
  local function step()
    if InCombatLockdown() then resume = step return end -- repris par PLAYER_REGEN_ENABLED
    local last = math.min(i + CHUNK - 1, #ids)
    for k = i, last do scan(ids[k]) end
    i = last + 1
    if i <= #ids then return ns.After(0, step) end
    running = false
    ns.db.qindex = idx
    ns.Fire("QINDEX")
  end
  running = true
  ns.After(0, step)
  return true
end

ns.On("PLAYER_REGEN_ENABLED", function()
  local f = resume
  resume = nil
  if f then f() end
end)

ns.On("PLAYER_LOGIN", function() ns.After(5, Q.StartIndex) end)

-- PNJ du role (PRIEST, ALCHEMY, HERBALISM, FIRSTAID, COOKING ou AUCTIONEER) : meme zone que le joueur, sinon capitale Horde.
-- Le joueur est donne par uiMapID et/ou areaID ; sans conversion de zones, seul l'areaID peut correspondre.
-- shortcut: pas de distance, premier PNJ de l'index qui convient.
function Q.Nearest(role, uiMapID, areaID)
  local idx = ns.db and ns.db.qindex
  local list = type(idx) == "table" and (role == "AUCTIONEER" and idx.auctioneers or idx.trainers[role])
  if not list then return nil end
  local zones = type(lib) == "table" and type(lib.Enum) == "table" and lib.Enum.zoneIDs or {}
  local capitals = {}
  for _, k in ipairs({ "UNDERCITY", "ORGRIMMAR", "THUNDER_BLUFF" }) do capitals[zones[k] or false] = true end
  local capital
  for _, id in ipairs(list) do
    local w = Q.Where(id)
    if w then
      if (areaID and w.areaID == areaID) or (uiMapID and w.uiMapID == uiMapID) then return id, w end
      if not capital and capitals[w.areaID] then capital = { id, w } end
    end
  end
  if capital then return capital[1], capital[2] end
end
