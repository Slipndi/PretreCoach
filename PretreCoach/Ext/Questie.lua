-- Pont optionnel vers LibQuestieDB (addon QuestieDB) : lecture seule, tout sous pcall, rien n'est embarque (GPL).
-- Sans QuestieDB, Available() rend false et le reste rend nil. Format lu dans QuestieDB/src/meta/npcMeta.lua.
local _, ns = ...
local S = ns.S
local Q = {}
ns.Q = Q

local CHUNK = 200 -- PNJ lus par tick
-- role -> morceau du subName (anglais, minuscules). Les subName reels : « Priest Trainer », « First Aid Trainer »...
local ROLES = { PRIEST = "priest", ALCHEMY = "alchemy", HERBALISM = "herbalism", FIRSTAID = "first aid", COOKING = "cooking" }

local lib, tried -- lib : nil = pas encore teste, false = absente ou contrat refuse ; tried : table testee en dernier
function Q.Available()
  if lib == nil or (lib == false and _G.LibQuestieDB ~= tried) then -- un echec se reteste quand la bibliotheque change
    local l = _G.LibQuestieDB
    tried = l
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

-- AreaID -> uiMapID sans donnee embarquee : nom localise (C_Map.GetAreaInfo) puis table nom -> uiMapID construite en direct
-- depuis les cartes Zone/City sous Cosmic (946), Kalimdor (1414) et Royaumes de l'Est (1415). Cache en memoire seulement.
-- Homonymes : les cartes City passent avant les Zone, puis 1414/1415 avant 946 ; un nom pris n'est pas ecrase.
-- shortcut: nil si l'API manque ou si le nom ne correspond a aucune carte.
local byName, areaMap = nil, {}
local function mapIndex()
  if byName then return byName end
  local idx, T = {}, (Enum and Enum.UIMapType) or {}
  for _, kind in ipairs({ T.City, T.Zone }) do
    for _, root in ipairs({ 1414, 1415, 946 }) do
      local kids = S.Get(C_Map and C_Map.GetMapChildrenInfo, root, kind, true)
      for _, m in ipairs(type(kids) == "table" and kids or {}) do
        if type(m) == "table" and type(m.name) == "string" and type(m.mapID) == "number" and not idx[m.name] then idx[m.name] = m.mapID end
      end
    end
  end
  if next(idx) then byName = idx end -- vide (API pas prete) : on reessaiera
  return idx
end

function Q.MapFor(areaID)
  local c = areaMap[areaID]
  if c ~= nil then return c or nil end
  local idx = mapIndex()
  if not byName then return nil end
  local name = S.Get(C_Map and C_Map.GetAreaInfo, areaID)
  local id = type(name) == "string" and idx[name] or false
  areaMap[areaID] = id
  return id or nil
end

-- Premier point d'apparition. Verifie : spawns = { [areaID] = { { x, y }, ... } }, x et y DEJA en pourcentage 0-100
-- (QuestieDB/Types/LibQuestieDB.t.lua:44 ; valeurs reelles ~40-50). (-1, -1) = instance : ignore.
-- shortcut: uiMapID vient de Q.MapFor (nom de zone localise) et reste nil si la conversion echoue ; la table AreaID -> uiMapID
-- de QuestieDB est du texte Lua qui exige loadstring (interdit, Regle 0), donc non utilisee.
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
  if type(row) ~= "table" or type(row[1]) ~= "number" or type(row[2]) ~= "number" or row[1] < 0 then return nil end
  return { areaID = area, uiMapID = Q.MapFor(area), x = row[1], y = row[2] }
end

------------------------------------------------------------------------
-- Index des PNJ utiles (maitres, commissaires-priseurs)
------------------------------------------------------------------------
local function hasBit(flags, bit) return math.floor(flags / bit) % 2 == 1 end

-- Pas d'API de version de donnees : on prend la version de l'addon QuestieDB.
local function dbVersion()
  local get = _G.C_AddOns and _G.C_AddOns.GetAddOnMetadata
  local ok, v = pcall(get or error, "QuestieDB", "Version")
  return ok and v ~= nil and tostring(v) or "?" -- "?" : jamais reutilise comme cache
end

local FORMAT = 1 -- a incrementer quand la forme de qindex change
local TRIES, RETRY = 3, 30
local tries, nearCache = 0, {}
ns.Listen("QINDEX", function() nearCache = {} end)

local running, resume

function Q.StartIndex()
  if running or not Q.Available() or not ns.db then return false end
  local ver = dbVersion()
  local c = ns.db.qindex
  if type(c) == "table" and ver ~= "?" and c.ver == ver and c.fmt == FORMAT then return false end
  local okIds, ids = pcall(lib.Npc.GetAllIds)
  if not okIds or type(ids) ~= "table" then return false end
  local enum = type(lib.Enum) == "table" and lib.Enum.npcFlags or {}
  local TRAINER, AUCTIONEER = enum.TRAINER or 16, enum.AUCTIONEER or 4096
  local idx = { ver = ver, fmt = FORMAT, trainers = {}, auctioneers = {} }
  for role in pairs(ROLES) do idx.trainers[role] = {} end

  local nils = 0
  local function scan(id)
    local f = Q.Npc(id, "npcFlags")
    if type(f) ~= "number" then nils = nils + 1 return end
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
  local function trainerCount() local c = 0 for _, l in pairs(idx.trainers) do c = c + #l end return c end
  local function finish()
    running = false
    if nils > #ids * 0.9 or trainerCount() == 0 or #idx.auctioneers == 0 then -- Questie pas pret : on ne sauvegarde pas
      tries = tries + 1
      if tries < TRIES then ns.After(RETRY, Q.StartIndex) end
      return
    end
    ns.db.qindex = idx
    ns.Fire("QINDEX")
  end
  local step
  local function work()
    local last = math.min(i + CHUNK - 1, #ids)
    for k = i, last do scan(ids[k]) end
    i = last + 1
    if i <= #ids then return ns.After(0, step) end
    finish()
  end
  step = function()
    if InCombatLockdown() then resume = step return end -- repris par PLAYER_REGEN_ENABLED
    local ok, err = pcall(work)
    if not ok then running = false ns.Debug("Questie index : %s", tostring(err)) end
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
-- Hors zone, AUCTIONEER et PRIEST preferent Fossoyeuse, puis Orgrimmar, puis les Pitons-du-Tonnerre ; les autres roles : premier.
-- shortcut: pas de distance, premier PNJ de l'index qui convient. Memorise par (role, uiMapID, areaID), vide sur QINDEX.
function Q.Nearest(role, uiMapID, areaID)
  Q.Available()
  local idx = ns.db and ns.db.qindex
  local list = type(idx) == "table" and (role == "AUCTIONEER" and idx.auctioneers or idx.trainers[role])
  if not list then return nil end
  local key = role .. ":" .. tostring(uiMapID) .. ":" .. tostring(areaID)
  local hit = nearCache[key]
  if hit ~= nil then if hit then return hit[1], hit[2] end return nil end
  local zones = type(lib) == "table" and type(lib.Enum) == "table" and lib.Enum.zoneIDs or {}
  local capitals = {}
  for r, k in ipairs({ "UNDERCITY", "ORGRIMMAR", "THUNDER_BLUFF" }) do capitals[zones[k] or false] = r end
  local prefer = role == "AUCTIONEER" or role == "PRIEST"
  local capital, rank
  for _, id in ipairs(list) do
    local w = Q.Where(id)
    if w then
      if (areaID and w.areaID == areaID) or (uiMapID and w.uiMapID == uiMapID) then
        nearCache[key] = { id, w }
        return id, w
      end
      local r = capitals[w.areaID]
      if r and (not capital or (prefer and r < rank)) then capital, rank = { id, w }, r end
    end
  end
  nearCache[key] = capital or false
  if capital then return capital[1], capital[2] end
end
