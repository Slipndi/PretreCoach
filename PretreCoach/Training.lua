-- Maître de classe (spec 6.1) : toast de montée de niveau, compteur « N sorts à apprendre », et panneau
-- « À apprendre ici » à l'ouverture du maître (ClassTrainerFrame n'est jamais modifié, seulement servi d'ancre).
-- Ce que le maître propose réellement est mémorisé dans ns.db.trainer { [nom .. "|" .. rang] = { level, cost, category } }.
-- Réglage : ns.db.training.every = 1 (défaut) ou 2 : le toast ne part alors qu'aux niveaux pairs ; le compteur reste juste.
local _, ns = ...
local S, L, State, Calc, D = ns.S, ns.L, ns.State, ns.Calc, ns.Data

local Training = {}
ns.Training = Training

local byKey = {}
for _, sp in ipairs(D.Spells) do byKey[sp.key] = sp end

local MAX_NAMES, MAX_LINES = 4, 12

local function cfg()
  if not ns.db then return {} end
  ns.db.training = ns.db.training or {}
  return ns.db.training
end

-- Nombre de sorts ou rangs à apprendre ; nil si Knows est illisible (API absente).
function Training.PendingCount()
  local p = Calc.PendingSpells(State.level, State.Knows)
  return p and #p or nil
end

-- Texte du compteur, vide s'il n'y a rien à apprendre ou si c'est inconnu.
function Training.CountText()
  local n = Training.PendingCount()
  if not n or n == 0 then return "" end
  return (n == 1 and L.TRAIN_COUNT_1 or L.TRAIN_COUNT):format(n)
end

-- Nom localisé du rang (par son ID), sinon le nom des données.
local function spellName(sp, i)
  local name = S.Get((C_Spell and C_Spell.GetSpellName) or GetSpellInfo, sp.ranks[i].id)
  return type(name) == "string" and name or sp.name
end

-- Prix : le formateur unique de l'addon est Prof.Money (icônes de pièces), résolu à l'appel (Professions.lua se charge après).
local function coin(c) return ns.Prof.Money(c) end
Training.Coin = coin

-- Coût mémorisé du rang (chez le maître) ; le rang est comparé par son numéro (« Rang 2 » ou « Rank 2 », rang 1 = vide).
local function knownCost(name, rankIndex)
  for k, v in pairs((ns.db and ns.db.trainer) or {}) do
    local n, rank = k:match("^(.*)|(.*)$")
    if n == name and (tonumber(rank:match("%d+")) or 1) == rankIndex and type(v.cost) == "number" then return v.cost end
  end
end

-- What's Training (addon tiers, optionnel, lecture seule par WT_API) : prix de Forever, remise de faction comprise.
-- Les entrees du catalogue sont gardees en memoire seulement (jamais en base) ; seuls les sorts de maitre comptent.
local AHEAD = 2 -- la reserve de Budget couvre les sorts jusqu'a niveau + AHEAD
local inData = {}
for _, sp in ipairs(D.Spells) do for _, r in ipairs(sp.ranks) do inData[r.id] = true end end

local function wtApi()
  if type(WT_API) ~= "table" then return nil end
  local ok, ready = pcall(WT_API.IsReady)
  return ok and ready and WT_API or nil
end

local function playerRace()
  local st, _, _, id = S.GetAll(UnitRace, "player")
  return st == "lisible" and type(id) == "number" and id or nil
end

local wtAll -- { [spellId] = entree } kind "trainer" seulement
local function catalog(api)
  if wtAll then return wtAll end
  local ok, cat = pcall(api.GetCatalog, "PRIEST", { race = playerRace(), faction = "Horde" })
  if not ok or type(cat) ~= "table" then return {} end
  local all = {}
  for _, e in ipairs(cat) do
    if type(e) == "table" and e.kind == "trainer" and type(e.id) == "number" and type(e.cost) == "number" then all[e.id] = e end
  end
  wtAll = all
  return all
end

-- Talent non pris ou sort reserve a une autre race : ignore.
local function allowed(e)
  if e.requiredTalentId and S.Get(IsPlayerSpell, e.requiredTalentId) ~= true then return false end
  local race = playerRace()
  if type(e.races) == "table" and next(e.races) and race then
    for k, v in pairs(e.races) do if k == race or v == race then return true end end
    return false
  end
  return true
end

local function wtCost(id)
  local api = wtApi()
  if not (api and id) then return nil end
  local e = catalog(api)[id]
  if e and not allowed(e) then return nil end
  local ok, src = pcall(api.GetSource, id)
  if ok and type(src) == "table" and src.kind == "trainer" and type(src.cost) == "number" then return src.cost end
  return e and e.cost or nil
end

-- Cout d'un rang : prix vu chez le maitre, sinon What's Training (si spellId donne), sinon nil.
function Training.Cost(name, rankIndex, spellId) return knownCost(name, rankIndex) or wtCost(spellId) end

-- Sorts de niveau [from, to] : (total des couts connus, nombre de couts inconnus). Les sorts du catalogue absents de
-- Data/Spells sont comptes aussi (leur niveau vient du catalogue).
local function levelCost(from, to)
  local total, unknown = 0, 0
  for _, sp in ipairs(D.Spells) do
    if not sp.talent and not sp.noTrainer then
      for i, r in ipairs(sp.ranks) do
        if r.level and r.level >= from and r.level <= to then
          local c = Training.Cost(spellName(sp, i), i, r.id)
          if c then total = total + c else unknown = unknown + 1 end
        end
      end
    end
  end
  local api = wtApi()
  if api then
    for id, e in pairs(catalog(api)) do
      if not inData[id] and type(e.level) == "number" and e.level >= from and e.level <= to and allowed(e) then
        total = total + (wtCost(id) or e.cost)
      end
    end
  end
  return total, unknown
end

-- Cout connu des sorts des prochains niveaux (reserve de Budget) ; 0 si inconnu.
function Training.Upcoming(level)
  if type(level) ~= "number" then return 0 end
  return (levelCost(level + 1, level + AHEAD))
end

-- Argent du joueur face au cout des sorts a apprendre (plan = Training.Plan) : vert si assez, rouge s'il manque ;
-- cout incomplet : minimum connu ; argent illisible : nil.
function Training.MoneyText(plan)
  local money = S.Get(GetMoney)
  if type(money) ~= "number" or not plan or not plan.pending or #plan.pending == 0 then return nil end
  local need = plan.total or plan.known or 0
  if need == 0 and (plan.unknown or 0) > 0 then return L.TRAIN_MONEY_UNKNOWN:format(coin(money)) end
  local short = need - money
  local s
  if short > 0 then s = "|cffff4444" .. L.TRAIN_MONEY_SHORT:format(coin(short), coin(money)) .. "|r"
  else s = "|cff33ff33" .. L.TRAIN_MONEY_OK:format(coin(money)) .. "|r" end
  if not plan.total and (plan.unknown or 0) > 0 then s = s .. L.TRAIN_MONEY_PARTIAL:format(plan.unknown) end
  return s
end

-- « Sorts du niveau 14 : 3,6 pa, tu as assez » / « ..., il te manque X » ; nil si rien de connu ou argent illisible.
function Training.NextText(plan)
  local money = S.Get(GetMoney)
  if type(money) ~= "number" or not (plan and plan.nextLevel) or (plan.nextTotal or 0) == 0 then return nil end
  local short = plan.nextTotal - money
  local s = short > 0 and L.TRAIN_NEXT_SHORT:format(plan.nextLevel, coin(plan.nextTotal), coin(short))
    or L.TRAIN_NEXT_OK:format(plan.nextLevel, coin(plan.nextTotal))
  if (plan.nextUnknown or 0) > 0 then s = s .. L.TRAIN_MONEY_PARTIAL:format(plan.nextUnknown) end
  return s
end

local function rankText(name, i) return i > 1 and L.GUIDE_RANK:format(name, i) or name end

-- Ce qui est à apprendre maintenant : { pending = { { text, cost } }, total (nil si un coût est inconnu), nextLevel,
-- nextNames }. pending = nil si Knows est illisible. Les sorts noTrainer et talents restent exclus (Calc.PendingSpells).
function Training.Plan(level)
  local out = {}
  local p = Calc.PendingSpells(level, State.Knows)
  if p then
    out.pending = {}
    local total, known, unknown = 0, 0, 0
    for _, e in ipairs(p) do
      local name = spellName(byKey[e.key], e.rankIndex)
      local cost = Training.Cost(name, e.rankIndex, byKey[e.key].ranks[e.rankIndex].id)
      out.pending[#out.pending + 1] = { text = rankText(name, e.rankIndex), cost = cost }
      total = total and cost and total + cost or nil
      if cost then known = known + cost else unknown = unknown + 1 end
    end
    out.total = #out.pending > 0 and total or nil
    out.known, out.unknown = known, unknown
  end
  if type(level) == "number" then
    local best
    for _, sp in ipairs(D.Spells) do
      if not sp.talent and not sp.noTrainer then
        for _, r in ipairs(sp.ranks) do
          if r.level and r.level > level and (not best or r.level < best) then best = r.level end
        end
      end
    end
    if best then
      out.nextLevel, out.nextNames = best, {}
      out.nextTotal, out.nextUnknown = levelCost(best, best)
      for _, sp in ipairs(D.Spells) do
        if not sp.talent and not sp.noTrainer then
          for i, r in ipairs(sp.ranks) do
            if r.level == best then out.nextNames[#out.nextNames + 1] = rankText(spellName(sp, i), i) end
          end
        end
      end
    end
  end
  return out
end

-- Montée de niveau : détectée sur le STATE qui porte le nouveau niveau (le cache de Knows est alors à jour).
local lastLevel
ns.Listen("STATE", function()
  local level = State.level
  if type(level) ~= "number" then return end
  local prev = lastLevel
  lastLevel = level
  if not prev or level <= prev then return end
  local every = tonumber(cfg().every) or 1
  if every > 1 and level % every ~= 0 then return end
  local pending = Calc.PendingSpells(level, State.Knows)
  if not pending or #pending == 0 then return end
  local names = {}
  for i = 1, math.min(#pending, MAX_NAMES) do
    local sp = byKey[pending[i].key]
    local name = spellName(sp, pending[i].rankIndex)
    names[i] = pending[i].rankIndex > 1 and L.GUIDE_RANK:format(name, pending[i].rankIndex) or name
  end
  local text = table.concat(names, ", ") .. (#pending > MAX_NAMES and ", …" or "")
  text = L.TRAIN_NEW:format(#pending, text)
  local total = Training.Plan(level).total
  if total then text = L.TRAIN_NEW_COST:format(text, coin(total)) end
  ns.Toast(text, { key = "pc:train:" .. level })
end)

------------------------------------------------------------------------
-- chez le maître
------------------------------------------------------------------------
local panel

local function hidePanel() if panel then panel:Hide() end end

local function showPanel(lines)
  if not (ns.UI and ns.UI.Panel) then return end
  if not panel then
    panel = ns.UI.Panel("PretreCoachTrainerFrame", UIParent)
    panel:SetWidth(240)
    panel:SetFrameStrata("DIALOG")
    local title = panel:CreateFontString(nil, "OVERLAY", ns.UI.font.small)
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -7)
    title:SetText(L.TRAIN_PANEL)
    title:SetTextColor(ns.UI.color.accent[1], ns.UI.color.accent[2], ns.UI.color.accent[3], 1)
    panel.body = panel:CreateFontString(nil, "OVERLAY", ns.UI.font.text)
    panel.body:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -22)
    panel.body:SetWidth(220)
    panel.body:SetJustifyH("LEFT")
  end
  panel:ClearAllPoints()
  local anchor = _G.ClassTrainerFrame
  if anchor then panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0) else panel:SetPoint("CENTER", UIParent, "CENTER") end
  panel.body:SetText(table.concat(lines, "\n"))
  panel:SetHeight(32 + 14 * #lines)
  panel:Show()
end

-- Lit les services du maître (tout sous pcall via S) ; API absente : rien ne s'affiche.
local function readTrainer()
  local n = S.Get(GetNumTrainerServices)
  if type(n) ~= "number" then return end
  local lines = {}
  for i = 1, n do
    local st, name, rank, cat = S.GetAll(GetTrainerServiceInfo, i)
    if st == "lisible" and type(name) == "string" and type(cat) == "string" and cat ~= "header" then
      rank = type(rank) == "string" and rank or ""
      local level, cost = S.Get(GetTrainerServiceLevelReq, i), S.Get(GetTrainerServiceCost, i)
      if type(level) ~= "number" then level = nil end
      if type(cost) ~= "number" then cost = nil end
      if ns.db then
        ns.db.trainer = ns.db.trainer or {}
        ns.db.trainer[name .. "|" .. rank] = { level = level, cost = cost, category = cat }
      end
      if cat == "available" and #lines < MAX_LINES then
        lines[#lines + 1] = name .. (rank ~= "" and (" (" .. rank .. ")") or "") .. (cost and cost > 0 and (" : " .. coin(cost)) or "")
      end
    end
  end
  if #lines > 0 then showPanel(lines) else hidePanel() end
end

ns.On("TRAINER_SHOW", readTrainer)
ns.On("TRAINER_UPDATE", readTrainer)
ns.On("TRAINER_CLOSED", hidePanel)

-- Pour les tests.
Training.Panel = function() return panel end
