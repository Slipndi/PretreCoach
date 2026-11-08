-- « Garder ou vendre » : verdict par ressource de craft (herbes, fioles, tissus : composants de Data/ProfPlan) et par consommable utile.
-- Verdicts : garder pour monter le metier (horizon 50 points, recettes du plan et recettes apprises), garder pour jouer, crafter pour vendre, vendre (HdV recente sinon marchand), prix inconnu.
-- Lecture et conseil seulement : aucun clic, achat, vente ni craft. Rien n'est ecrit dans PretreCoachDB.
local _, ns = ...
local L, S, D, State = ns.L, ns.S, ns.Data, ns.State

local Keep = {}
ns.Keep = Keep

-- Toutes les constantes ici (cuivre sauf mention).
local K = {
  -- shortcut: les marchands n'exposent pas leur prix d'achat ; on le prend a 4x le prix de vente (ratio Classic usuel).
  BUY_RATIO = 4,
  AH_CUT = 0.05, -- commission HdV : racheter coute le prix HdV majore de ce taux
  -- Stock de potions/bandages a garder pour jouer, selon le focus ; le surplus repasse en vente. 0 = pas de stock.
  PLAY = { gold = 0, balanced = 5, xp = 20 },
  BAGS = { 0, 1, 2, 3, 4 },
  MAX_ROWS = 8, -- rangees de l'onglet Vente
  SKILL_MAX = 300,
  HORIZON = 50, -- points de metier regardes devant le rang actuel
  SOON = 5, -- le rang suivant compte s'il s'ouvre dans au plus ce nombre de niveaux
  -- shortcut: fabrications comptees pour une recette apprise orange/jaune (divisees par numSkillUps) ; a regler apres usage reel.
  LEARNED_CRAFTS = 5,
}
Keep.K = K

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end
local function money(c) return ns.Prof.Money(c) end

local function focus()
  local f = ns.db and ns.db.guide and ns.db.guide.focus
  return K.PLAY[f] and f or "gold"
end

local function count(id)
  local n = S.Get((C_Item and C_Item.GetItemCount) or GetItemCount, id)
  return num(n)
end

local function merchant(id)
  local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  local r = { S.GetAll(get, id) }
  local m = r[1] == "lisible" and num(r[12])
  return m and m > 0 and m or nil
end

-- Valeur de vente d'une unite : (prix, "ah" | "merchant") ; HdV recente si elle bat le marchand.
local function sellValue(id)
  local ah, m = ns.Gold.Fresh(id), merchant(id)
  if ah and (not m or ah >= m) then return ah, "ah" end
  if m then return m, "merchant" end
end

-- Prix d'un composant pour un craft : prix du plan, HdV recente, ou achat marchand estime (composants vendus par un marchand).
local function compPrice(c)
  if c.price then return c.price end
  local p = ns.Gold.Fresh(c.id)
  if p then return p end
  local m = c.vendor and merchant(c.id)
  return m and m * K.BUY_RATIO or nil
end

local function knownRecipe(line, name)
  local adv = ns.Prof.Get(line)
  for _, e in ipairs(adv and adv.list or {}) do if e.name == name then return e end end
end

-- Etapes du plan qui utilisent cette ressource, pour les metiers du joueur.
local function uses(id)
  local out, profs = {}, type(State.profs) == "table" and State.profs or {}
  for line, plan in pairs(D.ProfPlan or {}) do
    local p = profs[line]
    for _, st in ipairs(p and plan.steps or {}) do
      for _, c in ipairs(st.recipe and st.comps or {}) do
        if c.id == id then out[#out + 1] = { line = line, p = p, st = st, c = c } end
      end
    end
  end
  table.sort(out, function(a, b) return a.line * 1000 + a.st.from < b.line * 1000 + b.st.from end)
  return out
end

-- Plafond de l'horizon : rang + HORIZON, au-dela du plafond du rang (pmax) seulement si le rang suivant s'ouvre bientot.
-- Rend limite, nom du rang suivant (celui qui s'ouvre apres pmax).
local function horizon(line, rank, pmax)
  local limit, nextName = pmax, nil
  local ranks = D.Professions and D.Professions[line] and D.Professions[line].ranks
  for _, r in ipairs(ranks or {}) do
    if r.max > pmax then
      nextName = r.name
      if (num(State.level) or 0) + K.SOON >= r.minLevel then limit = r.max end
      break
    end
  end
  return math.min(limit, rank + K.HORIZON, K.SKILL_MAX), nextName
end

-- Recettes apprises (index lu fenetre ouverte, ns.db.reagents) qui utilisent cet objet, pour les metiers du joueur.
local function learnedUses(id)
  local out, profs = {}, type(State.profs) == "table" and State.profs or {}
  local list = ns.db and type(ns.db.reagents) == "table" and ns.db.reagents[id]
  for _, e in ipairs(type(list) == "table" and list or {}) do
    if profs[e.line] and (e.color == "orange" or e.color == "yellow") then out[#out + 1] = e end
  end
  return out
end

-- Besoin pour monter : composants des crafts du plan entre le rang et l'horizon (recettes orange/jaune, ou pas encore lues :
-- comme Prof.Craftable), plus les recettes apprises hors plan. Rend { need, line, from, target, after, nextName, learned }.
local function skillNeed(us, lr)
  local r = { need = 0, after = 0 }
  local bestN = 0
  for _, u in ipairs(us) do
    local rank, pmax, st = num(u.p.rank) or 0, math.min(num(u.p.max) or 0, K.SKILL_MAX), u.st
    local limit, nextName = horizon(u.line, rank, pmax)
    local lo, hi = math.max(rank, st.from), math.min(st.to, limit)
    local e = knownRecipe(u.line, st.recipe)
    local useful = not e or e.color == "orange" or e.color == "yellow"
    if pmax > 0 and rank < limit and hi > lo and useful then
      local span = st.to - st.from
      local n = math.ceil(st.crafts * (hi - lo) / span) * u.c.n
      r.need = r.need + n
      r.after = r.after + math.min(n, math.ceil(st.crafts * math.max(0, hi - math.max(lo, pmax)) / span) * u.c.n)
      if n > bestN then bestN, r.line, r.from, r.nextName = n, u.line, rank, nextName end
      r.target = math.max(r.target or 0, hi)
    end
  end
  for _, e in ipairs(lr) do
    local covered = false
    for _, u in ipairs(us) do if u.line == e.line and u.st.recipe == e.name then covered = true end end
    if not covered then
      r.need = r.need + math.ceil(K.LEARNED_CRAFTS / math.max(num(e.ups) or 1, 1)) * (num(e.n) or 1)
      r.learned = r.learned or e.name or "?"
      r.line = r.line or e.line
    end
  end
  return r
end

-- Cout d'une unite a racheter : HdV recente + commission, sinon achat marchand estime (composant vendu par un marchand).
local function rebuyUnit(id, us)
  local ah = ns.Gold.Fresh(id)
  if ah then return math.ceil(ah * (1 + K.AH_CUT)) end
  local m = merchant(id)
  for _, u in ipairs(m and us or {}) do if u.c.vendor then return m * K.BUY_RATIO end end
end

-- Meilleure marge par unite de ressource en fabriquant une recette CONNUE puis en vendant le produit.
-- shortcut: valeur du produit lue a l'ouverture du metier (Prof.Advice, top 5), 1 produit par fabrication.
local function craftValue(us, id)
  local best, name
  for _, u in ipairs(us) do
    local e = knownRecipe(u.line, u.st.recipe)
    if e and e.value and e.value > 0 then
      local others = 0
      for _, c in ipairs(u.st.comps) do
        if c ~= u.c then
          local p = compPrice(c)
          if not p then others = nil break end
          others = others + p * c.n
        end
      end
      local m = others and (e.value - others) / u.c.n
      if m and (not best or m > best) then best, name = m, u.st.recipe end
    end
  end
  return best and math.floor(best), name
end

local bandageSet
local function isPlay(id)
  if not bandageSet then
    bandageSet = {}
    local b = D.Professions and D.Professions[129] and D.Professions[129].bandages
    for _, x in ipairs(b or {}) do if x.itemID then bandageSet[x.itemID] = true end end
  end
  if bandageSet[id] then return true end
  local r = { S.GetAll((C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant, id) }
  return r[1] == "lisible" and num(r[7]) == 0 and num(r[8]) == 1 -- consommable, potion
end

-- Verdict { id, have, keep, why = "skill"|"play", label, from, target, after, nextName, learned, rebuy, rest,
-- restKind = "sell"|"craft"|"unknown", sell, sellSrc, craft, craftName, kind } ; nil si l'objet n'est ni une ressource de
-- craft ni un consommable utile, ou si le compte est illisible. Le besoin pour monter est TOUJOURS garde (le racheter couterait
-- plus que la vente), quel que soit le focus ; seul le surplus est vendu ou crafte.
function Keep.Verdict(id, have)
  have = have or count(id)
  if not (num(id) and have and have > 0) then return nil end
  local us, lr = uses(id), learnedUses(id)
  local play = #us == 0 and #lr == 0 and isPlay(id)
  if #us == 0 and #lr == 0 and not play then return nil end
  local sell, src = sellValue(id)
  local craft, craftName = craftValue(us, id)
  local v = { id = id, have = have, keep = 0, sell = sell, sellSrc = src, craft = craft, craftName = craftName }
  if play then
    v.keep, v.why = math.min(have, K.PLAY[focus()]), "play"
  else
    local r = skillNeed(us, lr)
    if r.need > 0 then
      v.keep, v.why = math.min(have, r.need), "skill"
      v.from, v.target, v.nextName, v.learned = r.from, r.target, r.nextName, r.learned
      v.after = math.min(r.after, v.keep)
      v.label = D.Professions[r.line] and D.Professions[r.line].name or tostring(r.line)
      local u = rebuyUnit(id, us)
      v.rebuy = u and u * v.keep
    end
  end
  v.rest = have - v.keep
  if v.rest > 0 then
    if craft and craft > (sell or 0) then v.restKind = "craft"
    elseif sell then v.restKind = "sell"
    else v.restKind = "unknown" end
  end
  if v.keep == 0 and not v.restKind then return nil end
  v.kind = v.keep > 0 and "keep" or v.restKind
  return v
end

-- Bulle : tete (verdict GARDER / CRAFTER / VENDRE + raison), detail (sort du reste du stock) ou nil.
function Keep.Lines(v)
  local head, detail
  local at = v.sellSrc == "ah" and L.KEEP_AT_AH or L.KEEP_AT_MERCHANT
  if v.keep > 0 then
    if v.why == "play" then head = L.KEEP_H_PLAY:format(v.keep)
    elseif v.target and v.from then
      head = L.KEEP_H_KEEP:format(v.keep, v.label, v.from, v.target)
      if v.after > 0 and v.nextName then head = head .. L.KEEP_H_AFTER:format(v.after, v.nextName) end
    else head = L.KEEP_H_LEARNED:format(v.keep, v.label, v.learned or "?") end
    if v.rebuy then head = head .. L.KEEP_H_REBUY:format(money(v.rebuy)) end
    if v.rest > 0 then
      if v.restKind == "craft" then detail = L.KEEP_D_CRAFT:format(v.rest, v.craftName, money(v.craft))
      elseif v.restKind == "sell" then detail = L.KEEP_D_SELL:format(v.rest, at, money(v.sell))
      else detail = L.KEEP_D_UNKNOWN:format(v.rest) end
    end
  elseif v.restKind == "craft" then head = L.KEEP_H_CRAFT:format(v.craftName, money(v.craft))
  elseif v.restKind == "sell" then head = L.KEEP_H_SELL:format(at, money(v.sell))
  else head = L.KEEP_H_UNKNOWN end
  return head, detail
end

-- Ligne de conseil unique (rangees).
function Keep.Text(v)
  local head, detail = Keep.Lines(v)
  return detail and (head .. "  ·  " .. detail) or head
end

-- Enjeu pour le tri : valeur de ce qui est en jeu (meilleure valeur connue x quantite).
local function stake(v) return math.max(v.sell or 0, v.craft or 0) * v.have end

-- Verdicts de toutes les ressources des sacs, tries par enjeu decroissant ; hors combat seulement (sinon dernier resultat).
local lastAll = {}
function Keep.All()
  if InCombatLockdown() then return lastAll end
  local out, api, seen = {}, C_Container, {}
  if type(api) ~= "table" then lastAll = out return out end
  for _, bag in ipairs(K.BAGS) do
    for slot = 1, num(S.Get(api.GetContainerNumSlots, bag)) or 0 do
      local info = S.Get(api.GetContainerItemInfo, bag, slot)
      local id = type(info) == "table" and num(info.itemID)
      if id and not seen[id] then
        seen[id] = true
        local v = Keep.Verdict(id)
        if v then
          v.icon = info.iconFileID
          local get = (C_Item and C_Item.GetItemInfo) or GetItemInfo
          local r = { S.GetAll(get, id) }
          v.name = r[1] == "lisible" and type(r[2]) == "string" and r[2] or nil
          out[#out + 1] = v
        end
      end
    end
  end
  table.sort(out, function(a, b)
    if stake(a) ~= stake(b) then return stake(a) > stake(b) end
    return a.id < b.id
  end)
  lastAll = out
  return out
end

-- Rangees { icon, text, highlight } pour l'onglet Vente.
function Keep.Rows()
  local ok, all = pcall(Keep.All)
  local rows = {}
  for i = 1, ok and math.min(#all, K.MAX_ROWS) or 0 do
    local v = all[i]
    rows[i] = { icon = v.icon or "Interface\\Icons\\INV_Misc_QuestionMark", highlight = v.keep > 0,
      text = ("%s x%d  ·  %s"):format(v.name or ("objet " .. v.id), v.have, Keep.Text(v)) }
  end
  return rows
end

-- Meilleur craft-pour-vendre des sacs : { text, value } ou nil (value = gain sur la vente directe du reste).
function Keep.BestCraft()
  local ok, all = pcall(Keep.All)
  local best
  for _, v in ipairs(ok and all or {}) do
    if v.restKind == "craft" then
      local gain = (v.craft - (v.sell or 0)) * v.rest
      if not best or gain > best.value then
        best = { value = gain, n = v.rest, text = L.GOLD_KEEP_CRAFT:format(v.craftName, v.rest, v.name or ("objet " .. v.id), money(v.craft)) }
      end
    end
  end
  return best
end

------------------------------------------------------------------------
-- Bulle d'info des objets : une ligne ajoutee (lecture seule), jamais en combat, sous pcall.
------------------------------------------------------------------------
local COLORS = { keep = { 0.4, 1, 0.4 }, sell = { 1, 0.82, 0 }, craft = { 0.4, 0.7, 1 }, unknown = { 0.7, 0.6, 1 } }
local function tipLine(tip, id)
  if tip ~= GameTooltip or InCombatLockdown() then return end
  if not (ns.db and ns.db.show and ns.db.show.keeptip ~= false) then return end
  local ok, v, head, detail = pcall(function() local x = Keep.Verdict(id) if x then return x, Keep.Lines(x) end end)
  if not (ok and v) then return end
  local c = COLORS[v.kind] or COLORS.unknown
  pcall(tip.AddLine, tip, L.KEEP_TAG .. head, c[1], c[2], c[3], true)
  if detail then pcall(tip.AddLine, tip, detail, 0.8, 0.8, 0.8, true) end
  return true
end

local function hook()
  local TDP, E = _G.TooltipDataProcessor, _G.Enum
  if type(TDP) == "table" and TDP.AddTooltipPostCall and type(E) == "table" and type(E.TooltipDataType) == "table" then
    TDP.AddTooltipPostCall(E.TooltipDataType.Item, function(tip, data) tipLine(tip, type(data) == "table" and num(data.id) or nil) end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetItem", function(tip)
      local _, link = tip:GetItem()
      local id = type(link) == "string" and tonumber(link:match("item:(%d+)"))
      if id and tipLine(tip, id) then pcall(tip.Show, tip) end -- relance la mise en page de la bulle
    end)
  end
end
pcall(hook)
