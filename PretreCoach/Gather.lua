-- Cueillette rentable (idee de GatherMate) : noeuds d'herbes de la carte lus dans QuestieDB (Item.objectDrops -> Object.spawns),
-- herbes de ton rang, valeur HdV, boucle courte autour du joueur. Lecture et conseil seulement (Regle 0).
-- Index en memoire seulement (rien dans PretreCoachDB), bati par paquets, jamais en combat. Sans QuestieDB : listes vides.
local _, ns = ...
local S, D, Q, State = ns.S, ns.Data, ns.Q, ns.State

local Gather = {}
ns.Gather = Gather

-- shortcut: herbes par noeud supposees (1 a 3 en Classic), a mesurer en jeu sur quelques boucles.
local YIELD = 1.5
-- shortcut: noeuds par heure supposes (un toutes les 30 s, trajet et concurrence compris), a mesurer en jeu.
local NODES_PER_HOUR = 120
local LOOP_MAX, LOOP_HERBS, PIN_MAX = 15, 3, 80
local CHUNK, TRIES = 2, 3 -- herbes indexees par tick ; essais si la base n'est pas prete
Gather.YIELD, Gather.NODES_PER_HOUR, Gather.LOOP_MAX, Gather.PIN_MAX = YIELD, NODES_PER_HOUR, LOOP_MAX, PIN_MAX

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

-- byMap[uiMapID][itemID] = { { x, y }, ... } (0-100)
local byMap, building, resume, tries = nil, false, nil, 0

function Gather.StartIndex()
  if byMap or building or tries >= TRIES or not Q.Available() then return false end
  local ids = {}
  for id in pairs(D.Herbs or {}) do ids[#ids + 1] = id end
  table.sort(ids)
  local idx, found, i = {}, 0, 1
  local function scan(item)
    local objs = Q.Item(item, "objectDrops")
    for _, obj in ipairs(type(objs) == "table" and objs or {}) do
      local spawns = Q.Object(obj, "spawns")
      for area, pts in pairs(type(spawns) == "table" and spawns or {}) do
        local map = type(area) == "number" and type(pts) == "table" and Q.MapFor(area)
        for _, p in ipairs(map and pts or {}) do
          if type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and p[1] >= 0 then -- (-1, -1) : instance
            idx[map] = idx[map] or {}
            local l = idx[map][item] or {}
            idx[map][item] = l
            l[#l + 1] = { x = p[1], y = p[2] }
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
    if not ok then building = false ns.Debug("Index des herbes : %s", tostring(err)) return end
    if i <= #ids then return ns.After(0, step) end
    building = false
    if found == 0 then tries = tries + 1 return end -- base pas prete : nouvel essai au prochain appel
    byMap = idx
    ns.Fire("QPINS")
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
ns.On("PLAYER_LOGIN", function() ns.After(10, Gather.StartIndex) end)

local function playerPos(mapID)
  local p = S.Get(C_Map and C_Map.GetPlayerMapPosition, mapID, "player")
  if type(p) ~= "table" then return nil end
  local ok, x, y = pcall(p.GetXY, p)
  if ok and num(x) and num(y) then return x * 100, y * 100 end
end

local function itemInfo(id) -- nom lu en jeu (sinon QuestieDB), prix marchand
  local r = { S.GetAll((C_Item and C_Item.GetItemInfo) or GetItemInfo, id) }
  local name = r[1] == "lisible" and type(r[2]) == "string" and r[2] or nil
  if not name then
    local n = Q.Item(id, "name")
    name = type(n) == "string" and n or ("objet " .. id)
  end
  return name, r[1] == "lisible" and num(r[12]) or nil
end

function Gather.Icon(id)
  local v = S.Get(C_Item and C_Item.GetItemIconByID, id) or S.Get(GetItemIcon, id)
  return (type(v) == "number" or type(v) == "string") and v or "Interface\\Icons\\INV_Misc_Herb_01"
end

-- Couleur de cueillette Classic : orange sous requis + 25, jaune sous + 50, vert sous + 100, puis gris.
function Gather.Color(rank, req)
  return rank < req + 25 and "orange" or rank < req + 50 and "yellow" or rank < req + 100 and "green" or "grey"
end

-- Herbes de la carte a ton rang : { { itemID, name, req, price, value, nodes, color, skillup } }, les plus rentables d'abord.
function Gather.Herbs(mapID)
  local p = type(State.profs) == "table" and State.profs[182]
  local rank = p and num(p.rank)
  if not (rank and type(mapID) == "number") then return {} end
  if not byMap then Gather.StartIndex() return {} end
  local out = {}
  for item, nodes in pairs(byMap[mapID] or {}) do
    local req = D.Herbs[item]
    if req <= rank then
      local name, merchant = itemInfo(item)
      local price = (ns.Gold and ns.Gold.Fresh(item)) or merchant -- HdV, sinon marchand
      local c = Gather.Color(rank, req)
      out[#out + 1] = { itemID = item, name = name, req = req, price = price, value = price and price * (ns.Earn and ns.Earn.Yield() or YIELD), nodes = nodes,
        color = c, skillup = c == "orange" or c == "yellow" }
    end
  end
  table.sort(out, function(a, b)
    if (a.value or -1) ~= (b.value or -1) then return (a.value or -1) > (b.value or -1) end
    return a.itemID < b.itemID
  end)
  return out
end

-- Boucle : jusqu'a LOOP_MAX noeuds des LOOP_HERBS herbes les plus rentables (avec prix), plus proche voisin depuis le joueur.
-- { mapID, stops = { { x, y, n, herb } }, names, total, perHour } ou nil.
-- shortcut: plus proche voisin seul (pas de 2-opt) et centre de carte si la position est illisible ; suffisant pour 15 points.
function Gather.Loop(mapID)
  local pts, names = {}, {}
  for _, h in ipairs(Gather.Herbs(mapID)) do
    if #names >= LOOP_HERBS or not h.value then break end
    names[#names + 1] = h.name
    for _, p in ipairs(h.nodes) do pts[#pts + 1] = { x = p.x, y = p.y, herb = h } end
  end
  if #pts == 0 then return nil end
  local px, py = playerPos(mapID)
  px, py = px or 50, py or 50
  local stops, total = {}, 0
  while #stops < LOOP_MAX and #pts > 0 do
    local bi, bd
    for k, p in ipairs(pts) do
      local d = (p.x - px) ^ 2 + (p.y - py) ^ 2
      if not bd or d < bd then bi, bd = k, d end
    end
    local s = table.remove(pts, bi)
    stops[#stops + 1] = s
    s.n = #stops
    total = total + s.herb.value
    px, py = s.x, s.y
  end
  return { mapID = mapID, stops = stops, names = names, total = total, perHour = total / #stops * (ns.Earn and ns.Earn.NodesPerHour() or NODES_PER_HOUR) }
end

-- Reperes de la carte : noeuds de la boucle d'abord (numerotes), puis les autres, au plus PIN_MAX.
-- { { kind = "herb", itemID, name, price, mapID, x, y, n, skillup } }
function Gather.Pins(mapID)
  local list, seen = {}, {}
  local function add(h, x, y, n)
    local key = h.itemID .. ":" .. x .. ":" .. y
    if seen[key] or #list >= PIN_MAX then return end
    seen[key] = true
    list[#list + 1] = { kind = "herb", itemID = h.itemID, name = h.name, price = h.price, mapID = mapID, x = x, y = y, n = n, skillup = h.skillup }
  end
  local loop = Gather.Loop(mapID)
  for _, s in ipairs(loop and loop.stops or {}) do add(s.herb, s.x, s.y, s.n) end
  for _, h in ipairs(Gather.Herbs(mapID)) do
    for _, p in ipairs(h.nodes) do add(h, p.x, p.y) end
  end
  return list
end
