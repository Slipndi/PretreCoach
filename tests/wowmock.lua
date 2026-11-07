-- Fausse API WoW minimale : seulement ce que PretreCoach appelle. Charger avec dofile, rend le module `mock`.
local mock = { errors = {}, printed = {}, events = {}, timers = {}, inCombat = false, hasTarget = true, noSecrets = false,
  unknown = {}, time = 0, guid = "Creature-0" } -- unknown.spell / .item / .map : { [id] = true } = l'API ne repond pas pour cet ID

-- Valeur secrete simulee : toute operation autre que issecretvalue leve une erreur.
local function deny(op) return function() error("attempt to " .. op .. " a secret value", 2) end end
local SECRET_MT = {}
for _, k in ipairs({ "__lt", "__le", "__eq", "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm",
  "__concat", "__len", "__call", "__index", "__newindex", "__tostring" }) do SECRET_MT[k] = deny(k:sub(3)) end
mock.SECRET = setmetatable({}, SECRET_MT)
function mock.isSecret(v) return type(v) == "table" and getmetatable(v) == SECRET_MT end

issecretvalue = mock.isSecret
-- en combat les API de vie, mana, auras, recharges rendent la valeur secrete
-- (sans issecretvalue, forme Classic, le jeu ne rend jamais de secret : mock.noSecrets)
local function secretNow() return mock.inCombat and not mock.noSecrets end
local function sec(v) return function() if secretNow() then return mock.SECRET end return v end end

-- Cadre : toute methode inconnue est une fonction vide.
-- Les champs Lua en minuscules rendent nil, comme en jeu.
local FRAME = {}
local frameMT = { __index = function(_, k) return FRAME[k] or (tostring(k):find("^%u") and function() end) or nil end }
local function newFrame()
  local f = setmetatable({ scripts = {}, registered = {}, unit = {} }, frameMT)
  return f
end
function FRAME.RegisterEvent(self, e)
  if mock.rejectEvents and mock.rejectEvents[e] then error("unknown event " .. e) end
  self.registered[e] = true
  mock.events[e] = mock.events[e] or {}
  table.insert(mock.events[e], self)
end
function FRAME.RegisterUnitEvent(self, e, unit)
  if mock.noRegisterUnitEvent then error("RegisterUnitEvent indisponible") end
  FRAME.RegisterEvent(self, e)
  self.unit[e] = unit
end
function FRAME.SetText(_, t) mock.lastText = t end
function FRAME.SetScript(self, name, fn) self.scripts[name] = fn end
function FRAME.CreateTexture() return newFrame() end
function FRAME.CreateAnimationGroup() return newFrame() end
function FRAME.CreateAnimation() return newFrame() end
function FRAME.SetPoint(self, ...) self.pt = { ... } end
function FRAME.ClearAllPoints(self) self.pt = nil end
function FRAME.GetPoint(self) if self.pt then return self.pt[1], self.pt[2], self.pt[3], self.pt[4], self.pt[5] end end
function FRAME.CreateFontString() return newFrame() end
function FRAME.GetVerticalScroll() return 0 end
function FRAME.GetVerticalScrollRange() return 0 end
function CreateFrame(_, name) local f = newFrame() if name then _G[name] = f end return f end
UIParent, Minimap, GameTooltip = newFrame(), newFrame(), newFrame()
function GetCursorPosition() return 0, 0 end
ChatFontNormal = {}

-- Envoie un evenement a tous les cadres inscrits ; un cadre inscrit par unite ne recoit que cette unite.
function mock.fire(event, ...)
  local list = mock.events[event]
  assert(list, "aucun cadre inscrit a " .. event)
  for _, f in ipairs(list) do
    if not f.unit[event] or f.unit[event] == (...) then f.scripts.OnEvent(f, event, ...) end
  end
end

-- Remet le mock a zero entre deux chargements de l'addon.
function mock.reset()
  mock.events, mock.timers, mock.errors, mock.printed = {}, {}, {}, {}
  mock.inCombat, mock.hasTarget, mock.rejectEvents, mock.noRegisterUnitEvent, mock.lastText = false, true, nil, false, nil
  mock.unknown = {}
  mock.dead, mock.canAttack = nil, nil
  mock.time, mock.guid, mock.noGuid, mock.rangedID, mock.uncached, mock.known, mock.talentList = 0, "Creature-0", nil, nil, nil, nil, nil
  SlashCmdList = {}
  PretreCoachDB = nil
end

-- Minuteurs : file qu'on vide a la main.
C_Timer = { After = function(delay, fn) mock.timers[#mock.timers + 1] = { delay = delay, fn = fn } end }
function mock.flushTimers()
  local q = mock.timers
  mock.timers = {}
  for _, t in ipairs(q) do t.fn() end
end

function mock.setCombat(b) mock.inCombat = b end
function InCombatLockdown() return mock.inCombat end
function geterrorhandler() return function(err) mock.errors[#mock.errors + 1] = tostring(err) end end
function print(...)
  local t = {}
  for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
  mock.printed[#mock.printed + 1] = table.concat(t, " ")
end

SlashCmdList = {}
UISpecialFrames = {}
tinsert = table.insert
date = os.date
INVSLOT_MAINHAND, INVSLOT_RANGED = 16, 18

-- API de jeu appelees par la sonde
function GetLocale() return "frFR" end
function GetBuildInfo() return "1.15.0", "60001", "Jan 1 2026", 16001 end
function UnitClass() return "Pretre", "PRIEST", 5 end
function UnitRace() return "Mort-vivant", "Scourge" end
function UnitLevel() return 12 end
UnitHealth, UnitHealthMax = sec(100), sec(100)
function UnitPower() return secretNow() and mock.SECRET or 50 end
UnitPowerMax = UnitPower
GetPowerRegen = sec(1)
function UnitExists() return mock.hasTarget end
UnitCreatureType = sec("Humanoide")
-- mock.dead = la cible est morte ; mock.canAttack = false : cible non attaquable (allie, soi)
function UnitIsDead() if secretNow() then return mock.SECRET end return mock.dead == true end
function UnitCanAttack() if secretNow() then return mock.SECRET end return mock.canAttack ~= false end
-- mock.guid pilote le GUID de la cible ; mock.noGuid = illisible (nil)
function UnitGUID() if mock.noGuid then return nil end return secretNow() and mock.SECRET or mock.guid end
function CheckInteractDistance() return false end
function GetUnitSpeed() return 0 end
function IsPlayerMoving() return false end
function GetTime() return mock.time end -- pilotable : mock.time
function GetInventoryItemID(_, slot) if slot == 18 then return mock.rangedID end end -- mock.rangedID = baguette equipee
function GetInventoryItemLink() return nil end
function GetItemInfo(id) if mock.uncached then return nil end return "Baguette " .. id, "lien", 1, 1, 5 end
function IsPlayerSpell(id) if mock.known then return mock.known[id] or false end return true end -- mock.known = { [id] = true }
function IsSpellKnown(id) return IsPlayerSpell(id) end
function GetNumTalentTabs() return 3 end
-- mock.talentList = { [tab] = { { row, col, rang }, ... } } ; sinon un talent par onglet
function GetNumTalents(tab) return mock.talentList and #(mock.talentList[tab] or {}) or 1 end
function GetProfessions() return 1, 2 end
function GetProfessionInfo(i) return i == 1 and "Herboristerie" or "Alchimie", 0, 100, 300, 0, 0, i == 1 and 182 or 171 end
function GetNumSkillLines() return 2 end
function GetSkillLineInfo(i) return "Competence" .. i, false, 0, 50 end
function GetTalentTabInfo(i) return "Onglet" .. i, 0, 0 end
function GetTalentInfo(tab, i)
  local t = mock.talentList and mock.talentList[tab] and mock.talentList[tab][i]
  if t then return "Talent", 0, t[1], t[2], t[3], 5 end
  return "Talent", 0, 1, 1, 0, 5
end
function GetNumTalentGroups() return 1 end
function GetActiveTalentGroup() return 1 end
function GetUnspentTalentPoints() return 0 end
function GetNumTrainerServices() return 3 end
function GetTrainerServiceInfo(i) return "Sort" .. i, "", "available" end
function GetTrainerServiceLevelReq() return 10 end
function GetTrainerServiceCost() return 100 end
C_SpellBook = { IsSpellKnown = function() return true end, IsSpellInSpellBook = function() return true end }
C_QuestLog = { IsQuestFlaggedCompleted = function() return false end, GetTitleForQuestID = function() return "Titre" end }
-- 11287 = baguette (classe 2, sous-classe 19) ; les autres IDs : un objet quelconque
C_Item = { GetItemInfoInstant = function(id)
  if (mock.unknown.item or {})[id] then return nil end
  return id, "Arme", "Baguette", "", 0, 2, id == 11287 and 19 or 0
end }
C_TradeSkillUI = { GetProfessionInfoBySkillLineID = function(id) return { professionName = "Metier" .. id } end }
C_ActionBar = { FindSpellActionButtons = function() return nil end }
Settings = { RegisterCanvasLayoutCategory = function() end, RegisterAddOnCategory = function() end }
GetSpellCooldown = sec(0)
C_Spell = {
  GetSpellName = function(id) if (mock.unknown.spell or {})[id] then return nil end return "Sort" .. id end,
  GetSpellCooldown = function() return secretNow() and mock.SECRET or { startTime = 0, duration = 0, isEnabled = true } end,
  IsSpellUsable = sec(true),
  IsSpellInRange = sec(true),
}
C_UnitAuras = { GetAuraDataByIndex = function() return secretNow() and mock.SECRET or nil end }
C_Map = { GetBestMapForUnit = function() return 1 end, GetMapInfo = function(id) if (mock.unknown.map or {})[id] then return nil end return { name = "Tirisfal", parentMapID = id == 1 and 1420 or 0 } end }

-- APIs incertaines sur Forever : mock.setAbsent(true) les retire toutes (passe « absente »), false les remet.
local UNCERTAIN = [[
GetTalentTabInfo GetTalentInfo GetNumTalentTabs GetNumTalents GetNumTalentGroups GetActiveTalentGroup GetUnspentTalentPoints
C_SpellBook IsPlayerSpell IsSpellKnown GetProfessions GetProfessionInfo GetSkillLineInfo GetNumSkillLines
C_Map C_QuestLog GetUnitSpeed IsPlayerMoving C_Timer Settings GetNumTrainerServices GetTrainerServiceInfo
GetTrainerServiceLevelReq GetTrainerServiceCost GetInventoryItemID C_ActionBar issecretvalue C_TradeSkillUI
]]
local saved = {}
for n in UNCERTAIN:gmatch("%S+") do saved[n] = _G[n] end
function mock.setAbsent(absent)
  for n, v in pairs(saved) do _G[n] = (not absent) and v or nil end
  mock.noSecrets = absent
end

return mock
