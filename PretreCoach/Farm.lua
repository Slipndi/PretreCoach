-- Pistes de farm : marchandises (Data/TradeGoods.lua) lachees par des creatures de la carte, lues dans QuestieDB
-- (Item.npcDrops -> Npc.spawns), creatures de ton niveau et hostiles a la Horde. Lecture et conseil seulement (Regle 0).
-- Index en memoire seulement (rien dans PretreCoachDB), bati par paquets, jamais en combat. Sans QuestieDB : listes vides.
-- shortcut: QuestieDB ne donne pas le taux de drop ; score = prix x densite de creatures (points d'apparition dans une case de 10 x 10),
-- a remplacer par ns.Earn.PerHour quand il existera. Sans niveau dans QuestieDB, la creature n'est pas filtree (levelKnown = false).
local _, ns = ...
local S, L, D, Q, State = ns.S, ns.L, ns.Data, ns.Q, ns.State

local Farm = {}
ns.Farm = Farm

local CHUNK, TRIES, TOP, CELL = 2, 3, 5, 10
local BELOW, ABOVE = 3, 2 -- niveaux de creature acceptes : joueur -3 a +2
Farm.BELOW, Farm.ABOVE = BELOW, ABOVE

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

-- byMap[uiMapID][itemID] = { [npcID] = { name, lo, hi, pts = { { x, y } } } }
local byMap, building, resume, tries = nil, false, nil, 0

function Farm.StartIndex()
  if byMap or building or tries >= TRIES or not Q.Available() then return false end
  local ids = {}
  for _, id in ipairs(D.TradeGoods or {}) do ids[#ids + 1] = id end
  local idx, found, i = {}, 0, 1
  local cache = {} -- npcID -> fiche, ou false (amical a la Horde : ecarte)
  local function npc(id)
    if cache[id] ~= nil then return cache[id] end
    local fac = Q.Npc(id, "friendlyToFaction")
    local spawns = Q.Npc(id, "spawns")
    local r = false
    if fac ~= "H" and fac ~= "AH" and type(spawns) == "table" then -- nil ou "A" : hostile a la Horde
      local name = Q.Npc(id, "name")
      r = { name = type(name) == "string" and name or ("creature " .. id), lo = num(Q.Npc(id, "minLevel")), hi = num(Q.Npc(id, "maxLevel")), spawns = spawns }
    end
    cache[id] = r
    return r
  end
  local function scan(item)
    local drops = Q.Item(item, "npcDrops")
    for _, nid in ipairs(type(drops) == "table" and drops or {}) do
      local n = type(nid) == "number" and npc(nid)
      for area, pts in pairs(n and n.spawns or {}) do
        local map = type(area) == "number" and type(pts) == "table" and Q.MapFor(area)
        for _, p in ipairs(map and pts or {}) do
          if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and p[1] >= 0 then -- (-1, -1) : instance
            idx[map] = idx[map] or {}
            idx[map][item] = idx[map][item] or {}
            local e = idx[map][item][nid]
            if not e then e = { name = n.name, lo = n.lo, hi = n.hi, pts = {} } idx[map][item][nid] = e end
            e.pts[#e.pts + 1] = { p[1], p[2] }
            found = found + 1
          end
        end
      end
    end
  end
  local step
  step = function()
    if InCombatLockdown() then resume = step return end -- repris a PLAYER_REGEN_ENABLED
    local ok, err = pcall(function()
      local last = math.min(i + CHUNK - 1, #ids)
      for k = i, last do scan(ids[k]) end
      i = last + 1
    end)
    if not ok then building = false ns.Debug("Index de farm : %s", tostring(err)) return end
    if i <= #ids then return ns.After(0, step) end
    building = false
    if found == 0 then tries = tries + 1 return end -- base pas prete : nouvel essai au prochain appel
    byMap = idx
    ns.Fire("GUIDE")
  end
  building = true
  ns.After(0, step)
  return true
end

ns.On("PLAYER_REGEN_ENABLED", function()
  local f = resume
  resume = nil
  if f then f() end
end)
ns.On("PLAYER_LOGIN", function() ns.After(12, Farm.StartIndex) end)

local function itemInfo(id) -- nom lu en jeu (sinon QuestieDB), prix marchand
  local r = { S.GetAll((C_Item and C_Item.GetItemInfo) or GetItemInfo, id) }
  local name = r[1] == "lisible" and type(r[2]) == "string" and r[2] or nil
  if not name then
    local n = Q.Item(id, "name")
    name = type(n) == "string" and n or ("objet " .. id)
  end
  return name, r[1] == "lisible" and num(r[12]) or nil
end

-- Creatures de ton niveau dans la case la plus dense : crea, x, y, densite, tous niveaux connus. nil si rien ne convient.
local function lead(npcs, level)
  local cells = {}
  for nid, e in pairs(npcs) do
    if e.lo == nil or e.hi == nil or (e.hi >= level - BELOW and e.lo <= level + ABOVE) then
      for _, p in ipairs(e.pts) do
        local key = math.floor(p[1] / CELL) * 100 + math.floor(p[2] / CELL)
        local c = cells[key] or { n = 0, sx = 0, sy = 0, by = {} }
        cells[key] = c
        c.n, c.sx, c.sy = c.n + 1, c.sx + p[1], c.sy + p[2]
        c.by[nid] = (c.by[nid] or 0) + 1
      end
    end
  end
  local best, bk
  for k, c in pairs(cells) do if not best or c.n > best.n or (c.n == best.n and k < bk) then best, bk = c, k end end
  if not best then return nil end
  local crea, known = {}, true
  for nid, cnt in pairs(best.by) do
    local e = npcs[nid]
    known = known and e.lo ~= nil and e.hi ~= nil
    crea[#crea + 1] = { npcID = nid, name = e.name, level = e.lo and e.hi and { e.lo, e.hi } or nil, points = cnt }
  end
  table.sort(crea, function(a, b) if a.points ~= b.points then return a.points > b.points end return a.npcID < b.npcID end)
  return crea, best.sx / best.n, best.sy / best.n, best.n, known
end

local function describe(r)
  local c = r.creatures[1]
  local who = c.name .. (c.level and L.FARM_LEVEL:format(c.level[1], c.level[2]) or "")
  if r.creatures[2] then who = who .. ", " .. r.creatures[2].name end
  return L.FARM_ROW:format(who, r.go.x, r.go.y, r.name) .. (r.price and L.FARM_PRICE:format(ns.Prof.Money(r.price)) or L.FARM_NOPRICE)
end

-- Pistes de la carte, les plus rentables d'abord (au plus 5) :
-- { itemID, name, price, creatures = { { npcID, name, level = { min, max } | nil, points } }, go = { mapID, x, y, text },
--   density, score, levelKnown, text }
function Farm.Rows(mapID)
  local level = num(State.level)
  if not (level and type(mapID) == "number") then return {} end
  if not byMap then Farm.StartIndex() return {} end
  local out = {}
  for item, npcs in pairs(byMap[mapID] or {}) do
    local crea, x, y, density, known = lead(npcs, level)
    if crea then
      local name, merchant = itemInfo(item)
      local price = (ns.Gold and ns.Gold.Fresh(item)) or merchant -- HdV, sinon marchand
      local r = { itemID = item, name = name, price = price, creatures = crea, density = density, levelKnown = known,
        score = price and price * density or 0, go = { mapID = mapID, x = x, y = y } }
      r.text = describe(r)
      r.go.text = r.text
      out[#out + 1] = r
    end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.itemID < b.itemID
  end)
  for k = #out, TOP + 1, -1 do out[k] = nil end
  return out
end

function Farm.Best(mapID) return Farm.Rows(mapID)[1] end
