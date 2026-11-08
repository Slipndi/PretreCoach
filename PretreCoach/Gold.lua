-- Objectif « Or » : meilleure action pour gagner de l'or maintenant (vente HdV, craft rentable, cueillette) et suivi de session.
-- Lecture et conseil seulement : aucun achat, aucune vente, aucune enchere. Rien n'est ecrit dans PretreCoachDB.
-- Sans Auctionator, aucun prix n'est lisible : pas de montant, conseil generique (spec, section L17 et Secourisme).
local _, ns = ...
local L, S, D, State = ns.L, ns.S, ns.Data, ns.State

local Gold = {}
ns.Gold = Gold

-- shortcut: valeur d'une cueillette = prix x 20 herbes, juste pour la classer face a une vente ou un craft ; jamais affichee.
local HERB_BATCH = 20
local TOP = 5
-- shortcut: HdV de la Horde en dur (pretre mort-vivant, Fossoyeuse) ; duree de mise en vente conseillee fixe ; a lire de la faction si besoin.
local AH_CITY, AH_HOURS = "Fossoyeuse", 12
-- shortcut: pas de taux de drop dans QuestieDB ni de mesure comparable (Earn.PerHour ne mesure ni le farm ni le butin vendu) :
-- 2 morts par minute et 30 % de chance de lacher la marchandise ; a remplacer par une mesure du farm quand elle existera.
local FARM_KILLS_PER_MIN, FARM_DROP_CHANCE = 2, 0.3

local function money(c) return ns.Prof.Money(c) end
local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

-- Prix HdV lisible et pas trop ancien (meme seuil que Sell), sinon nil.
local function fresh(id)
  local p = ns.AH and ns.AH.Price(id)
  if not p or p <= 0 then return nil end
  local age = ns.AH.Age(id)
  if age and age > ns.Sell.OLD_DAYS then return nil end
  return p
end
Gold.Fresh = fresh

-- Prix de depart conseille a l'HdV (lecture seule, rien n'est mis en vente) : prix Auctionator recent moins 1 pc,
-- seulement s'il reste au-dessus du prix marchand ; sinon nil (vends au marchand).
function Gold.Ask(ah, merchant)
  if not num(ah) or ah <= 0 then return nil end
  if ah - 1 > (num(merchant) or 0) then return ah - 1 end
end

-- Chaque candidat porte perMin = cuivre par minute, la seule valeur de tri (comparable a Quests : meme unite, voir Guide.Goals).
-- shortcut: durees a la louche (Classic), a recaler sur des mesures en jeu.
local AH_TRIP_SECS, LIST_SECS = 120, 30 -- aller a l'HdV si on n'y est pas ; mise en vente
local CRAFT_BATCH, CRAFT_SECS, CRAFT_SETUP = 5, 3, 10 -- fabrications supposees par lot, lancement, preparation (secondes)
local NODE_SECS, NEAR, LOOP_WIN = 20, 3, 1.5 -- detour par noeud cueilli en route ; distance (0-100 de carte) ; boucle seule : x1,5 minimum

local function atAH()
  local f = _G.AuctionHouseFrame
  local ok, shown = pcall(function() return f and f:IsShown() end)
  return ok and shown == true
end

local function craftMins(n) return (n * CRAFT_SECS + CRAFT_SETUP) / 60 end

local function sell(out)
  for _, l in ipairs(ns.Sell.Lines) do -- deja triees par gain decroissant
    if l.advice == "ah" and not l.old then
      local mins = ((atAH() and 0 or AH_TRIP_SECS) + LIST_SECS) / 60
      local name, ask = l.name or ("objet " .. l.itemID), Gold.Ask(l.ah, l.merchant)
      -- commissaire-priseur le plus proche (index Questie) : lieu et repere ; sinon ville en dur
      local okq, _, w = pcall(function() return ns.Q.Nearest("AUCTIONEER", State.mapID) end)
      local zone = okq and w and ns.Goto.Zone(w) or nil
      out[#out + 1] = { kind = "sell", value = l.gain, perMin = l.gain / mins, ask = ask,
        go = zone and { mapID = w.uiMapID, x = w.x, y = w.y, text = L.GO_AH:format(zone) } or nil,
        text = ask and L.GOLD_SELL:format(l.count, name, zone or AH_CITY, money(l.amount), money(ask), AH_HOURS)
          or L.GOLD_SELL_MERCHANT:format(l.count, name, money(l.amount)) }
      return
    end
  end
end

-- Meilleure marge par recette connue (Prof.Advice) ; une marge n'existe que si tous les composants ont un prix.
-- Composants a acheter (pas encore dans les sacs) : payables apres la reserve (Budget), sinon une seule rangee dit pourquoi.
local function craft(out)
  local blocked
  for line in pairs(type(State.profs) == "table" and State.profs or {}) do
    local adv = ns.Prof.Get(line)
    for _, r in ipairs(adv and adv.list or {}) do
      if num(r.margin) and r.margin > 0 then
        local ok, why = true, nil
        if not r.craftable and num(r.cost) and ns.Budget then ok, why = ns.Budget.Check("comps", r.cost) end
        if ok then
          out[#out + 1] = { kind = "craft", value = r.margin, perMin = r.margin * CRAFT_BATCH / craftMins(CRAFT_BATCH),
            text = L.GOLD_CRAFT:format(CRAFT_BATCH, r.name or "?", money(r.margin * CRAFT_BATCH), math.max(1, math.ceil(craftMins(CRAFT_BATCH)))) }
        elseif not blocked or r.margin > blocked.value then
          blocked = { kind = "blocked", value = r.margin, perMin = 0, text = L.GOLD_BLOCKED:format(r.name or "?", money(r.cost), why) }
        end
      end
    end
  end
  if blocked then out[#out + 1] = blocked end
end

-- Herbes cueillables a ton rang : nom -> itemID tire des composants de Data/ProfPlan (les herbes sans ID sont ignorees).
local function herbIDs()
  local ids = {}
  for _, plan in pairs(D.ProfPlan or {}) do
    for _, st in ipairs(plan.steps or {}) do
      for _, c in ipairs(st.comps or {}) do if c.id and not c.vendor then ids[c.name] = c.id end end
    end
  end
  return ids
end

local function zoneLabel(id)
  local z = D.Zones and D.Zones[id]
  return ns.Goto.Zone({ uiMapID = id }) or (z and z[3]) or tostring(id)
end

-- Distance d'un point au segment ab (coordonnees 0-100 de la carte).
local function segDist(p, a, b)
  local dx, dy = b.x - a.x, b.y - a.y
  local len2 = dx * dx + dy * dy
  local t = len2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2)) or 0
  return math.sqrt((p.x - a.x - t * dx) ^ 2 + (p.y - a.y - t * dy) ^ 2)
end

-- Cueillette en route : noeuds a moins de NEAR d'un arret de l'itineraire de quetes (ou du segment entre deux arrets de la carte).
-- nil sans arret localise ici, sans noeud, ou si la boucle seule rapporte nettement plus par minute que l'itineraire (Quests.score).
local function along(lp)
  local route, stops = ns.Quests and ns.Quests.Route() or {}, {}
  for _, s in ipairs(route) do
    if s.here and type(s.x) == "number" and type(s.y) == "number" then stops[#stops + 1] = s end
  end
  if #stops == 0 or not ns.Gather then return nil end
  local qrate = route[1] and route[1].v and num(route[1].v.score)
  if lp and qrate and lp.perHour / 60 > LOOP_WIN * qrate then return nil end
  local n, value, names = 0, 0, {}
  for _, h in ipairs(ns.Gather.Herbs(State.mapID)) do
    local cnt = 0
    for _, p in ipairs(h.nodes) do
      for i, s in ipairs(stops) do
        if segDist(p, s, stops[i + 1] or s) <= NEAR then cnt = cnt + 1 break end
      end
    end
    if cnt > 0 then
      n, value = n + cnt, value + cnt * (h.value or 0)
      if #names < 3 then names[#names + 1] = h.name end
    end
  end
  if n == 0 or value <= 0 then return nil end
  return { kind = "gather", along = true, value = value, perMin = value / (n * NODE_SECS / 60),
    text = L.GOLD_ALONG:format(n, table.concat(names, ", "), math.max(1, math.ceil(n * NODE_SECS / 60)), money(math.floor(value))) }
end

-- Boucle d'herbes de la carte (Gather) ; valeur = ce que rapporte un tour. Sinon : meilleure herbe de Data/ProfPlan.
-- Un itineraire de quetes localise ici prime : on cueille en route au lieu d'une boucle concurrente (along).
local function gather(out)
  local lp = ns.Gather and ns.Gather.Loop(State.mapID)
  local a = along(lp)
  if a then out[#out + 1] = a return end
  if lp then
    local s = lp.stops[1]
    out[#out + 1] = { kind = "gather", value = lp.total, perMin = lp.perHour / 60,
      text = L.GOLD_LOOP:format(#lp.stops, zoneLabel(lp.mapID), table.concat(lp.names, ", "),
        math.max(1, math.floor(lp.total / lp.perHour * 60 + 0.5)), money(math.floor(lp.total))),
      go = { mapID = lp.mapID, x = s.x, y = s.y, text = L.GOLD_LOOP_GO:format(s.herb.name) } }
    return
  end
  local p = type(State.profs) == "table" and State.profs[182]
  local plan = D.ProfPlan and D.ProfPlan[182]
  if not (p and plan) then return end
  local ids, here, far = herbIDs(), nil, nil
  for _, st in ipairs(plan.steps) do
    if st.herbs and st.from <= (num(p.rank) or 0) then
      local onSite = false
      for _, z in ipairs(st.zones or {}) do if z == State.zone or z == State.mapID then onSite = true end end
      for _, name in ipairs(st.herbs) do
        local price = ids[name] and fresh(ids[name])
        if price then
          local c = { name = name, price = price, zone = st.zones and st.zones[1] }
          if onSite then if not here or price > here.price then here = c end
          elseif not far or price > far.price then far = c end
        end
      end
    end
  end
  local c = here or far
  if not c then return end
  local G = ns.Gather
  local perMin = c.price * (G and G.YIELD or 1.5) * (G and G.NODES_PER_HOUR or 120) / 60
  local mins = math.max(1, math.ceil(HERB_BATCH * c.price / perMin))
  local text = here and L.GOLD_GATHER_HERE:format(HERB_BATCH, c.name, mins, money(c.price * HERB_BATCH))
    or L.GOLD_GATHER_AT:format(HERB_BATCH, c.name, c.zone and zoneLabel(c.zone) or "?", mins, money(c.price * HERB_BATCH))
  local go
  local node = here and G and G.Nearest(State.mapID, c.name)
  if node then go = { mapID = State.mapID, x = node.x, y = node.y, text = L.GOLD_NODE_GO:format(c.name) } end
  out[#out + 1] = { kind = "gather", value = c.price * HERB_BATCH, text = text, perMin = perMin, go = go }
end

-- Craft-pour-vendre avec les ressources des sacs (Keep) : gain par rapport a la vente directe.
local function keepCraft(out)
  local b = ns.Keep and ns.Keep.BestCraft()
  if b and b.value > 0 then out[#out + 1] = { kind = "craft", value = b.value, perMin = b.value / craftMins(b.n or 1), text = b.text } end
end

-- Pistes de farm de la carte (Farm.Rows) : gain = prix x morts/min x chance de drop (constantes en tete) ; sans prix : perMin 0, en bas.
local function farm(out)
  for _, r in ipairs(ns.Farm and ns.Farm.Rows(State.mapID) or {}) do
    local perMin = r.price and r.price * FARM_KILLS_PER_MIN * FARM_DROP_CHANCE or 0
    out[#out + 1] = { kind = "farm", value = perMin * 60, perMin = perMin, go = r.go, farm = r,
      text = r.price and (r.text .. L.GOLD_FARM_RATE:format(money(math.floor(perMin * 60)))) or r.text }
  end
end

-- Actions a/b/c rangees par valeur decroissante (au plus TOP) ; vide sans Auctionator.
function Gold.Candidates()
  local out = {}
  if not (ns.AH and ns.AH.Available()) then return out end
  for _, f in ipairs({ sell, craft, gather, keepCraft, farm }) do pcall(f, out) end
  table.sort(out, function(a, b)
    if a.perMin ~= b.perMin then return a.perMin > b.perMin end
    return a.value > b.value
  end)
  for i = #out, TOP + 1, -1 do out[i] = nil end
  return out
end

function Gold.Best()
  local c = Gold.Candidates()[1]
  if c then return c end
  local ah = ns.AH and ns.AH.Available()
  return { kind = "tip", text = L.GOLD_TIP, detail = not ah and L.SELL_NO_AH or nil, value = 0, perMin = 0 }
end

------------------------------------------------------------------------
-- Suivi de session : net (gains moins depenses), jamais ecrit dans la base.
------------------------------------------------------------------------
local start, t0

local function snap()
  local m = num(GetMoney())
  if m and not start then start, t0 = m, GetTime() end
end
ns.On("PLAYER_ENTERING_WORLD", snap)

-- net en cuivre et or/heure (nil tant que moins d'une minute de session) ; nil si l'argent est illisible.
function Gold.Session()
  snap()
  local m = num(GetMoney())
  if not (m and start) then return nil end
  local net, dt = m - start, GetTime() - t0
  return net, dt >= 60 and net * 3600 / dt or nil, dt
end

local function signed(c) return (c < 0 and "-" or "+") .. money(math.abs(c)) end

function Gold.SessionText()
  local net, perHour = Gold.Session()
  if not net then return nil end
  if not perHour then return L.GOLD_SESSION:format(signed(net)) end
  return L.GOLD_SESSION_RATE:format(signed(net), (perHour < 0 and "-" or "") .. money(math.abs(perHour)))
end

-- Lignes de l'onglet « Devenir riche » (section = repere de test) : prochain achat (+ monture), reserve, meilleures pistes (+ herbes de la zone),
-- tes chiffres, session.
function Gold.Rows()
  local rows = {}
  local function add(section, r) r.section, r.highlight = section, r.highlight or false rows[#rows + 1] = r end
  if ns.Earn then
    local t, sub = ns.Earn.NextText()
    add("goal", { text = t, sub = sub })
    local mt, msub = ns.Earn.MountText() -- grand objectif : seulement si le prix est lisible
    if mt then add("goal", { text = mt, sub = msub }) end
  end
  local res = ns.Budget and ns.Budget.Reserve()
  if res then
    local parts = {}
    if res.spell > 0 then parts[#parts + 1] = L.RICH_RES_SPELL:format(money(res.spell)) end
    if res.rank > 0 then parts[#parts + 1] = L.RICH_RES_RANK:format(money(res.rank)) end
    if res.recipe > 0 then parts[#parts + 1] = L.RICH_RES_RECIPE:format(money(res.recipe)) end
    add("reserve", { text = #parts > 0 and L.RICH_RESERVE:format(table.concat(parts, ", ")) or L.RICH_RESERVE_NONE,
      sub = #res.unknown > 0 and table.concat(res.unknown, " · ") or nil })
  end
  add("pistes", { text = L.RICH_PISTES, head = true })
  local c = Gold.Candidates()
  for i, a in ipairs(c) do add("pistes", { text = a.text, highlight = i == 1, go = a.go }) end
  if #c == 0 then
    local b = Gold.Best()
    add("pistes", { text = b.text, sub = b.detail })
  end
  local ok, herbs = pcall(function() return ns.Gather and ns.Gather.Herbs(State.mapID) or {} end)
  for _, h in ipairs(ok and herbs or {}) do
    add("pistes", { icon = ns.Gather.Icon(h.itemID), sub = h.skillup and L.GATHER_SKILLUP or nil,
      text = (#h.nodes == 1 and L.GOLD_HERB_ROW_1 or L.GOLD_HERB_ROW):format(h.name, h.price and money(h.price) or L.GOLD_HERB_NOPRICE, #h.nodes) })
  end
  add("chiffres", { text = L.RICH_CHIFFRES, head = true })
  local er = ns.Earn and ns.Earn.Rows() or {}
  for _, e in ipairs(er) do
    add("chiffres", { text = e.perHour and L.RICH_ROW:format(e.label, money(math.floor(e.perHour))) or L.RICH_ROW_NONE:format(e.label) })
  end
  if #er == 0 then add("chiffres", { text = L.RICH_NOMEASURE }) end
  local s = Gold.SessionText()
  if s then add("session", { text = s, sub = ns.Earn and ns.Earn.RecordText() }) end
  return rows
end
