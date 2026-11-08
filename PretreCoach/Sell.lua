-- L17a « Quoi vendre » : lecture des sacs (0 a 4), hors combat, et conseil par pile (hotel des ventes ou marchand).
-- Lecture seule : aucune vente, aucun deplacement d'objet. Rien n'est ecrit dans PretreCoachDB.
-- Declencheur : BAG_UPDATE_DELAYED, anti-rebond 1 s ; en combat, reprise a PLAYER_REGEN_ENABLED.
local _, ns = ...
local L, S, D = ns.L, ns.S, ns.Data

local Sell = { Lines = {}, Totals = { ah = 0, merchant = 0 }, scanned = false }
ns.Sell = Sell

local MAX_ROWS = 15
local OLD_DAYS = 7
Sell.OLD_DAYS = OLD_DAYS
-- shortcut: seuil d'HdV fixe (x1,5 du marchand ET 50 pc de plus en tout), a regler apres usage reel.
local RATIO, MIN_GAIN = 1.5, 50
local BAGS = { 0, 1, 2, 3, 4 }
local CLASS_CONSUMABLE, CLASS_TRADE = 0, 7
local PROF_LINES = { 171, 129, 182 } -- Alchimie, Secourisme, Herboristerie

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end

-- Objets que le joueur utilise lui-meme, ID -> vrai : bandages des donnees, composants manquants des recettes lues.
-- shortcut: Prof.Advice ne liste que les composants MANQUANTS du top 5 ; les autres ne sont pas ecartes (voir « maybe »).
local function usedSet()
  local used = {}
  local bandages = D and D.Professions and D.Professions[129] and D.Professions[129].bandages
  for _, b in ipairs(bandages or {}) do if b.itemID then used[b.itemID] = true end end
  local get = ns.Prof and ns.Prof.Get
  for _, line in ipairs(PROF_LINES) do
    local adv = get and get(line)
    for _, r in ipairs(adv and adv.list or {}) do
      for _, m in ipairs(r.missing or {}) do if m.itemID then used[m.itemID] = true end end
    end
  end
  return used
end

local function hasProf()
  local p = ns.State and ns.State.profs
  if type(p) ~= "table" then return false end
  for _, line in ipairs(PROF_LINES) do if p[line] then return true end end
  return false
end

local function itemInfo(id)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local r = { S.GetAll(get, id) }
  if r[1] ~= "lisible" then return nil end
  return r[2], num(r[12]) -- nom, prix marchand (11e valeur)
end

local function classID(id)
  local get = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  local r = { S.GetAll(get, id) }
  if r[1] == "lisible" then return num(r[7]), r[6] end -- classID, icone
end

local function build()
  local used, prof, lines, left = usedSet(), hasProf(), {}, {}
  local api = C_Container
  if type(api) ~= "table" then return lines end
  for _, bag in ipairs(BAGS) do
    local slots = S.Get(api.GetContainerNumSlots, bag)
    for slot = 1, num(slots) or 0 do
      local info = S.Get(api.GetContainerItemInfo, bag, slot)
      local id = type(info) == "table" and num(info.itemID)
      -- ressource a garder (monter le metier, jouer) ou a crafter : retiree de la pile, jamais proposee a la vente
      local q = type(info) == "table" and num(info.stackCount) or 1
      local kv = id and ns.Keep and ns.Keep.Verdict(id)
      if kv then
        left[id] = left[id] or kv.keep
        local k = math.min(left[id], q)
        left[id], q = left[id] - k, q - k
        if kv.restKind == "craft" then q = 0 end
      end
      if id and q > 0 and info.isBound ~= true and not used[id] then
        local name, m = itemInfo(id)
        local merchant = m or 0
        local class, icon = classID(id)
        local ah = ns.AH and ns.AH.Price(id)
        local age = ah and ns.AH.Age(id)
        local mTotal, aTotal = merchant * q, ah and ah * q
        local line = { itemID = id, bag = bag, slot = slot, name = name, count = q, quality = num(info.quality) or 1,
          icon = info.iconFileID or icon, merchant = merchant, ah = ah, age = age,
          old = ah ~= nil and age ~= nil and age > OLD_DAYS,
          maybe = prof and (class == CLASS_TRADE or class == CLASS_CONSUMABLE) }
        if ah and ah >= RATIO * merchant and aTotal - mTotal >= MIN_GAIN then
          line.advice, line.amount, line.gain = "ah", aTotal, aTotal - mTotal
        elseif line.quality == 0 or (not ah and merchant > 0) then
          line.advice, line.amount, line.gain = "merchant", mTotal, mTotal
        end
        if line.advice then lines[#lines + 1] = line end
      end
    end
  end
  table.sort(lines, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    if a.itemID ~= b.itemID then return a.itemID < b.itemID end
    return a.bag * 100 + a.slot < b.bag * 100 + b.slot
  end)
  return lines
end

function Sell.Scan()
  if InCombatLockdown() then return false end
  local ok, lines = pcall(build)
  if not ok then lines = {} end -- API incertaine sur Forever : jamais d'erreur visible
  local t = { ah = 0, merchant = 0 }
  for _, l in ipairs(lines) do
    local k = l.advice
    t[k] = t[k] + l.amount
  end
  Sell.Lines, Sell.Totals, Sell.scanned = lines, t, true
  ns.Fire("SELL")
  return true
end

-- Lignes d'affichage { text, sub, icon, highlight } pour l'onglet Vente : totaux, note Auctionator, 15 piles au plus.
function Sell.Rows()
  local rows = {}
  if not Sell.scanned then return rows end
  local money = ns.Prof and ns.Prof.Money or tostring
  if #Sell.Lines > 0 then
    rows[1] = { text = L.SELL_TOTALS:format(money(Sell.Totals.ah), money(Sell.Totals.merchant)), highlight = true }
  end
  if not (ns.AH and ns.AH.Available()) then rows[#rows + 1] = { text = L.SELL_NO_AH, highlight = false } end
  for i = 1, math.min(#Sell.Lines, MAX_ROWS) do
    local l = Sell.Lines[i]
    local subs = {}
    if l.old then subs[#subs + 1] = L.SELL_OLD end
    if l.maybe then subs[#subs + 1] = L.SELL_MAYBE end
    rows[#rows + 1] = { icon = l.icon or "Interface\\Icons\\INV_Misc_QuestionMark",
      text = ("%s x%d  ·  %s  ·  %s"):format(l.name or ("objet " .. l.itemID), l.count, L["SELL_" .. l.advice], money(l.amount)),
      sub = table.concat(subs, "  ·  "), highlight = l.advice == "ah" }
  end
  -- ressources de craft : garder / vendre / crafter (Keep)
  for _, r in ipairs(ns.Keep and ns.Keep.Rows() or {}) do rows[#rows + 1] = r end
  return rows
end

local pending, deferred = false, false
local function schedule()
  if pending then return end
  if not C_Timer then Sell.Scan() return end
  pending = true
  C_Timer.After(1, function()
    pending = false
    if InCombatLockdown() then deferred = true return end
    Sell.Scan()
  end)
end
ns.On("BAG_UPDATE_DELAYED", schedule)
ns.On("PLAYER_REGEN_ENABLED", function() if deferred then deferred = false schedule() end end)
