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
  ns.Toast(L.TRAIN_NEW:format(text), { key = "pc:train:" .. level })
end)

------------------------------------------------------------------------
-- chez le maître
------------------------------------------------------------------------
-- Prix en or/argent/cuivre : GetCoinTextureString si présent, sinon « 1 po 20 pa ».
local function coin(c)
  local s = S.Get(GetCoinTextureString, c)
  if type(s) == "string" then return s end
  local parts = {}
  if c >= 10000 then parts[#parts + 1] = math.floor(c / 10000) .. " po" end
  if c % 10000 >= 100 then parts[#parts + 1] = math.floor(c % 10000 / 100) .. " pa" end
  if c % 100 > 0 or #parts == 0 then parts[#parts + 1] = (c % 100) .. " pc" end
  return table.concat(parts, " ")
end

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
