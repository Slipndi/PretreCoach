-- Signal sur les monstres de quête (comme l'addon Questie) : petite icône dorée au-dessus de la barre de nom (épée = à tuer, sac = peut
-- lâcher un objet de quête) et ligne « Quête : ... » dans la bulle d'info. Affichage seul (Règle 0) : cadres simples non sécurisés,
-- ancrés (SetPoint) sur la barre de nom sans toucher aux cadres Blizzard. Index npcID -> quêtes recalculé hors combat, depuis le journal
-- + QuestieDB (objectifs créatures, objets via npcDrops). GUID secret : pas de signal. Rien dans PretreCoachDB hors show.questmobs.
-- shortcut: objectif du journal retrouvé par le nom (nom QuestieDB dans le texte), sinon premier objectif non fini ; à affiner si besoin.
local _, ns = ...
local UI, L, S = ns.UI, ns.L, ns.S

local QM = {}
UI.QuestMobs = QM

local ICON = { kill = "Interface\\Icons\\INV_Sword_04", loot = "Interface\\Icons\\INV_Misc_Bag_10" } -- à vérifier en jeu
local MAXDROP = 30 -- créatures retenues par objet de quête

local index, dirty, pending = {}, false, false -- index[npcID] = { { id, title, kind, text } }
local plates, used, pool = {}, {}, {} -- plates[unit] = true ; used[unit] = icône ; pool = icônes libres

local function on() return not (ns.db and ns.db.show and ns.db.show.questmobs == false) end
local function str(v) return type(v) == "string" and not S.IsSecret(v) and v ~= "" and v or nil end
local function npcOf(guid)
  guid = str(guid)
  return guid and tonumber(guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)")) or nil
end

local function add(idx, npc, e)
  if type(npc) ~= "number" or not e then return end
  local l = idx[npc] or {}
  idx[npc] = l
  for _, o in ipairs(l) do if o.id == e.id and o.kind == e.kind then return end end
  l[#l + 1] = e
end

-- Objectif du journal de la quête : (texte, fini) ; name = nom à retrouver dans le texte.
local function progress(objs, name)
  local first
  for _, o in ipairs(objs) do
    if type(o) == "table" then
      local t = str(o.text)
      local txt = t or (type(o.numFulfilled) == "number" and type(o.numRequired) == "number" and not S.IsSecret(o.numFulfilled)
        and not S.IsSecret(o.numRequired) and ("%d/%d"):format(o.numFulfilled, o.numRequired)) or nil
      if name and t and t:find(name, 1, true) then return txt, o.finished == true end
      if not first and o.finished ~= true and txt then first = txt end
    end
  end
  return first, first == nil -- aucun objectif non fini : la quête n'a plus rien à signaler
end

local function build()
  local idx = {}
  local Q = ns.Q
  if not (Q and Q.Available()) then return idx end
  local n = S.Get(C_QuestLog and C_QuestLog.GetNumQuestLogEntries)
  if type(n) ~= "number" then return idx end
  for i = 1, n do
    local info = S.Get(C_QuestLog.GetInfo, i)
    local id = type(info) == "table" and info.isHeader ~= true and info.questID
    if type(id) == "number" and not S.IsSecret(id) and S.Get(C_QuestLog.IsComplete, id) ~= true then
      local objs = S.Get(C_QuestLog.GetQuestObjectives, id)
      local o = Q.Quest(id, "objectives")
      if type(objs) == "table" and type(o) == "table" then
        local title = str(info.title) or str(Q.Quest(id, "name")) or "?"
        local function entry(kind, name)
          local text, done = progress(objs, name)
          if text and not done then return { id = id, title = title, kind = kind, text = text } end
        end
        for _, c in ipairs(type(o[1]) == "table" and o[1] or {}) do
          local npc = type(c) == "table" and c[1] or c
          local name = type(c) == "table" and str(c[2]) or str(Q.Npc(npc, "name"))
          add(idx, npc, entry("kill", name))
        end
        for _, it in ipairs(type(o[3]) == "table" and o[3] or {}) do
          local item = type(it) == "table" and it[1] or it
          local drops = Q.Item(item, "npcDrops")
          local name = type(it) == "table" and str(it[2]) or str(Q.Item(item, "name"))
          for k, npc in ipairs(type(drops) == "table" and drops or {}) do
            if k > MAXDROP then break end
            add(idx, npc, entry("loot", name))
          end
        end
      end
    end
  end
  return idx
end

------------------------------------------------------------------------
-- Barres de nom
------------------------------------------------------------------------
local function release(unit)
  local ic = used[unit]
  if not ic then return end
  used[unit] = nil
  pcall(ic.Hide, ic)
  pool[#pool + 1] = ic
end

local function newIcon()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(18, 18)
  f.ring = f:CreateTexture(nil, "BACKGROUND")
  f.ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
  f.ring:SetBlendMode("ADD")
  f.ring:SetVertexColor(1, 0.82, 0)
  f.ring:SetSize(40, 40)
  f.ring:SetPoint("CENTER", f, "CENTER")
  f.tex = f:CreateTexture(nil, "ARTWORK")
  f.tex:SetSize(14, 14)
  f.tex:SetPoint("CENTER", f, "CENTER")
  return f
end

local function sync(unit)
  local list = on() and index[npcOf(S.Get(UnitGUID, unit)) or 0]
  local ok, plate = pcall(function() return C_NamePlate.GetNamePlateForUnit(unit) end)
  if not (list and ok and plate and not S.IsSecret(plate)) then return release(unit) end
  local kind = "loot"
  for _, e in ipairs(list) do if e.kind == "kill" then kind = "kill" end end
  local ic = used[unit]
  if not ic then
    ic = table.remove(pool)
    if not ic then
      local made, f = pcall(newIcon)
      if not made then return end
      ic = f
    end
    used[unit] = ic
  end
  -- ancrage refusé (combat) : on cache, la sortie du combat réessaie
  local set = pcall(function()
    ic:ClearAllPoints()
    ic:SetPoint("BOTTOM", plate, "TOP", 0, 2)
  end)
  if not set then return release(unit) end
  ic.tex:SetTexture(ICON[kind])
  ic:Show()
end

local function syncAll() for unit in pairs(plates) do pcall(sync, unit) end end

local function rebuild()
  if InCombatLockdown() then dirty = true return end -- on garde le dernier index
  dirty = false
  local ok, idx = pcall(build)
  if ok then index = idx else ns.Debug("Monstres de quete : %s", tostring(idx)) end
  syncAll()
end

local function soon()
  if pending then return end
  pending = true
  ns.After(0.5, function() pending = false rebuild() end)
end

ns.On("NAME_PLATE_UNIT_ADDED", function(_, unit)
  if type(unit) ~= "string" then return end
  plates[unit] = true
  pcall(sync, unit)
end)
ns.On("NAME_PLATE_UNIT_REMOVED", function(_, unit)
  if type(unit) ~= "string" then return end
  plates[unit] = nil
  release(unit)
end)
for _, e in ipairs({ "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "QUEST_TURNED_IN" }) do ns.On(e, soon) end
ns.On("PLAYER_LOGIN", function() ns.After(3, rebuild) end)
ns.On("PLAYER_REGEN_ENABLED", function()
  if dirty then rebuild() else syncAll() end
end)

function QM.Rebuild() rebuild() end
function QM.Update() syncAll() end
function QM.Index() return index end
function QM.Icon(unit) return used[unit] end

------------------------------------------------------------------------
-- Bulle d'info
------------------------------------------------------------------------
local function tipHas(tt, text)
  local n = S.Get(function() return tt:NumLines() end)
  for i = 1, type(n) == "number" and n or 0 do
    local fs = _G[(tt:GetName() or "GameTooltip") .. "TextLeft" .. i]
    local t = fs and S.Get(fs.GetText, fs)
    if str(t) and t:find(text, 1, true) then return true end
  end
  return false
end

local function tipLines(tt, guid)
  if not on() then return end
  local list = index[npcOf(guid) or 0]
  if not list then return end
  for _, e in ipairs(list) do
    if not tipHas(tt, e.text) then tt:AddLine(L.QMOB_LINE:format(e.title, e.text), 1, 0.82, 0) end
  end
  tt:Show()
end

local function hookTip()
  local TDP = _G.TooltipDataProcessor
  local unitType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
  if TDP and TDP.AddTooltipPostCall and unitType then
    TDP.AddTooltipPostCall(unitType, function(tt, data)
      pcall(function() tipLines(tt, type(data) == "table" and data.guid or nil) end)
    end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tt)
      pcall(function()
        local _, unit = tt:GetUnit()
        tipLines(tt, unit and S.Get(UnitGUID, unit))
      end)
    end)
  end
end
pcall(hookTip)
