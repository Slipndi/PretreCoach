-- Fausse API WoW minimale : seulement ce que PretreCoach appelle. Charger avec dofile, rend le module `mock`.
local mock = { errors = {}, printed = {}, events = {}, timers = {}, inCombat = false, hasTarget = true }

-- Valeur secrete simulee : toute operation autre que issecretvalue leve une erreur.
local function deny(op) return function() error("attempt to " .. op .. " a secret value", 2) end end
local SECRET_MT = {}
for _, k in ipairs({ "__lt", "__le", "__eq", "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm",
  "__concat", "__len", "__call", "__index", "__newindex", "__tostring" }) do SECRET_MT[k] = deny(k:sub(3)) end
mock.SECRET = setmetatable({}, SECRET_MT)
function mock.isSecret(v) return type(v) == "table" and getmetatable(v) == SECRET_MT end

issecretvalue = mock.isSecret
-- en combat les API de vie, mana, auras, recharges rendent la valeur secrete
local function sec(v) return function() if mock.inCombat then return mock.SECRET end return v end end

-- Cadre : toute methode inconnue est une fonction vide.
local FRAME = {}
local frameMT = { __index = function(_, k) return FRAME[k] or function() end end }
local function newFrame()
  local f = setmetatable({ scripts = {}, registered = {} }, frameMT)
  return f
end
function FRAME.RegisterEvent(self, e)
  if mock.rejectEvents and mock.rejectEvents[e] then error("unknown event " .. e) end
  self.registered[e] = true
  mock.events[e] = self
end
function FRAME.SetScript(self, name, fn) self.scripts[name] = fn end
function FRAME.CreateTexture() return newFrame() end
function FRAME.CreateFontString() return newFrame() end
function FRAME.GetVerticalScroll() return 0 end
function FRAME.GetVerticalScrollRange() return 0 end
function CreateFrame() return newFrame() end
UIParent = newFrame()
ChatFontNormal = {}

-- Envoie un evenement a tous les cadres inscrits (le gestionnaire OnEvent n'a pas de filtre propre).
function mock.fire(event, ...)
  local f = mock.events[event]
  assert(f, "aucun cadre inscrit a " .. event)
  f.scripts.OnEvent(f, event, ...)
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
function UnitPower() return mock.inCombat and mock.SECRET or 50 end
UnitPowerMax = UnitPower
GetPowerRegen = sec(1)
function UnitExists() return mock.hasTarget end
UnitGUID, UnitIsDead, UnitCreatureType = sec("Creature-0"), sec(false), sec("Humanoide")
function CheckInteractDistance() return false end
function GetUnitSpeed() return 0 end
function IsPlayerMoving() return false end
function GetInventoryItemID() return nil end
function IsPlayerSpell() return true end
function IsSpellKnown() return true end
function GetNumTalentTabs() return 3 end
function GetProfessions() return nil end
function GetNumSkillLines() return 0 end
GetSpellCooldown = sec(0)
C_Spell = {
  GetSpellName = function(id) return "Sort" .. id end,
  GetSpellCooldown = function() return mock.inCombat and mock.SECRET or { startTime = 0, duration = 0, isEnabled = true } end,
  IsSpellUsable = sec(true),
  IsSpellInRange = sec(true),
}
C_UnitAuras = { GetAuraDataByIndex = function() return mock.inCombat and mock.SECRET or nil end }
C_Map = { GetBestMapForUnit = function() return 1 end, GetMapInfo = function() return { name = "Tirisfal" } end }

return mock
