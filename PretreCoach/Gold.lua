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

local function sell(out)
  for _, l in ipairs(ns.Sell.Lines) do -- deja triees par gain decroissant
    if l.advice == "ah" and not l.old then
      out[#out + 1] = { kind = "sell", value = l.gain, text = L.GOLD_SELL:format(l.count, l.name or ("objet " .. l.itemID), money(l.amount)) }
      return
    end
  end
end

-- Meilleure marge par recette connue (Prof.Advice) ; une marge n'existe que si tous les composants ont un prix.
local function craft(out)
  for line in pairs(type(State.profs) == "table" and State.profs or {}) do
    local adv = ns.Prof.Get(line)
    for _, r in ipairs(adv and adv.list or {}) do
      if num(r.margin) and r.margin > 0 then
        out[#out + 1] = { kind = "craft", value = r.margin, text = L.GOLD_CRAFT:format(r.name or "?", money(r.margin)) }
      end
    end
  end
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

-- Boucle d'herbes de la carte (Gather) ; valeur = ce que rapporte un tour. Sinon : meilleure herbe de Data/ProfPlan.
local function gather(out)
  local lp = ns.Gather and ns.Gather.Loop(State.mapID)
  if lp then
    local s = lp.stops[1]
    out[#out + 1] = { kind = "gather", value = lp.total,
      text = L.GOLD_LOOP:format(#lp.stops, table.concat(lp.names, ", "), money(math.floor(lp.perHour))),
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
  local text = here and L.GOLD_GATHER_HERE:format(c.name, money(c.price))
    or L.GOLD_GATHER_AT:format(c.name, c.zone and zoneLabel(c.zone) or "?", money(c.price))
  out[#out + 1] = { kind = "gather", value = c.price * HERB_BATCH, text = text }
end

-- Actions a/b/c rangees par valeur decroissante (au plus TOP) ; vide sans Auctionator.
function Gold.Candidates()
  local out = {}
  if not (ns.AH and ns.AH.Available()) then return out end
  for _, f in ipairs({ sell, craft, gather }) do pcall(f, out) end
  table.sort(out, function(a, b) return a.value > b.value end)
  for i = #out, TOP + 1, -1 do out[i] = nil end
  return out
end

function Gold.Best()
  local c = Gold.Candidates()[1]
  if c then return c end
  local ah = ns.AH and ns.AH.Available()
  return { kind = "tip", text = L.GOLD_TIP, detail = not ah and L.SELL_NO_AH or nil, value = 0 }
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
  return net, dt >= 60 and net * 3600 / dt or nil
end

local function signed(c) return (c < 0 and "-" or "+") .. money(math.abs(c)) end

function Gold.SessionText()
  local net, perHour = Gold.Session()
  if not net then return nil end
  if not perHour then return L.GOLD_SESSION:format(signed(net)) end
  return L.GOLD_SESSION_RATE:format(signed(net), (perHour < 0 and "-" or "") .. money(math.abs(perHour)))
end

-- Lignes d'affichage pour l'onglet Or : top 5 des actions, les herbes de la zone, puis la session.
function Gold.Rows()
  local rows, c = {}, Gold.Candidates()
  for i, a in ipairs(c) do rows[i] = { text = a.text, highlight = i == 1, go = a.go } end
  if #c == 0 then
    local b = Gold.Best()
    rows[1] = { text = b.text, sub = b.detail, highlight = false }
  end
  local ok, herbs = pcall(function() return ns.Gather and ns.Gather.Herbs(State.mapID) or {} end)
  for _, h in ipairs(ok and herbs or {}) do
    rows[#rows + 1] = { icon = ns.Gather.Icon(h.itemID), highlight = false, sub = h.skillup and L.GATHER_SKILLUP or nil,
      text = (#h.nodes == 1 and L.GOLD_HERB_ROW_1 or L.GOLD_HERB_ROW):format(h.name, h.price and money(h.price) or L.GOLD_HERB_NOPRICE, #h.nodes) }
  end
  local s = Gold.SessionText()
  if s then rows[#rows + 1] = { text = s, highlight = false } end
  return rows
end
