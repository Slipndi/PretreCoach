-- Calé sur la sonde du 2026-11-07, build 70862 (client 1.60.1, interface 16001, frFR) : les API Classic absentes de ce
-- client (GetSpellInfo, GetSpellCooldown, IsUsableSpell, GetItemInfo, GetSkillLineInfo, GetTalentInfo, ...) ne sont PAS définies.
-- Fausse API WoW minimale : seulement ce que PretreCoach appelle. Charger avec dofile, rend le module `mock`.
local mock = { errors = {}, printed = {}, events = {}, timers = {}, inCombat = false, hasTarget = true, noSecrets = false,
  unknown = {}, time = 0, guid = "Creature-0", secure = {}, attrCalls = 0, attrInCombat = 0, secureInCombat = 0, moveInCombat = 0 } -- unknown.spell / .item / .map : { [id] = true } = l'API ne repond pas pour cet ID

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
  local f = setmetatable({ scripts = {}, registered = {}, unit = {}, attrs = {} }, frameMT)
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
function FRAME.SetValue(self, v) self.value = v end
function FRAME.SetDesaturated(self, b) self.desat = b end
function FRAME.SetTexture(self, t) self.tex = t end
function FRAME.SetAttribute(self, k, v) self.attrs = self.attrs or {} self.attrs[k] = v end
function FRAME.GetAttribute(self, k) return (self.attrs or {})[k] end
function FRAME.SetColorTexture(self, ...) self.color = { ... } end
function FRAME.SetText(self, t) mock.lastText = t self.text = t end
function FRAME.SetTextColor(self, r, g, b) self.textColor = { r, g, b } end
-- Show/Hide/SetPoint/ClearAllPoints sur un cadre securise en combat : interdit en jeu, compte ici
local function guard(self) if mock.inCombat and self.template and self.template:find("Secure") then mock.moveInCombat = mock.moveInCombat + 1 end end
function FRAME.Show(self) guard(self) local was = self.shown self.shown = true if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
function FRAME.Hide(self) guard(self) local was = self.shown self.shown = false if was and self.scripts.OnHide then self.scripts.OnHide(self) end end
function FRAME.SetShown(self, b) if b then FRAME.Show(self) else FRAME.Hide(self) end end
function FRAME.IsShown(self) return self.shown == true end
function FRAME.SetScale(self, s) self.scale = s end
function FRAME.SetHeight(self, h) self.height = h end
function FRAME.SetWidth(self, w) self.width = w end
function FRAME.SetSize(self, w, h) self.width, self.height = w, h end
function FRAME.SetScript(self, name, fn) self.scripts[name] = fn end
function FRAME.HookScript(self, name, fn) self.hooks = self.hooks or {} self.hooks[name] = fn end
function FRAME.CreateTexture() return newFrame() end
function FRAME.CreateAnimationGroup() return newFrame() end
function FRAME.CreateAnimation() return newFrame() end
function FRAME.SetPoint(self, ...) guard(self) self.pt = { ... } end
function FRAME.ClearAllPoints(self) guard(self) self.pt = nil end
function FRAME.GetPoint(self) if self.pt then return self.pt[1], self.pt[2], self.pt[3], self.pt[4], self.pt[5] end end
function FRAME.CreateFontString() return newFrame() end
function FRAME.GetVerticalScroll() return 0 end
function FRAME.GetVerticalScrollRange() return 0 end
-- gabarit securise : compte les creations en combat (interdit en jeu) ; SetAttribute compte les appels, dont ceux en combat
function CreateFrame(kind, name, _, template)
  local f = newFrame()
  f.kind, f.template = kind, template
  if template and template:find("Secure") then
    mock.secure[#mock.secure + 1] = f
    if mock.inCombat then mock.secureInCombat = mock.secureInCombat + 1 end
  end
  if name then _G[name] = f end
  return f
end
function FRAME.SetAttribute(self, k, v)
  mock.attrCalls = mock.attrCalls + 1
  if mock.inCombat then mock.attrInCombat = mock.attrInCombat + 1 end
  self.attrs[k] = v
end
function FRAME.GetAttribute(self, k) return self.attrs[k] end
function FRAME.SetMinMaxValues(self, a, b) self.min, self.max = a, b end
function FRAME.SetAlpha(self, a) self.alpha = a end
function FRAME.AddLine(self, t) self.lines = self.lines or {} self.lines[#self.lines + 1] = t end -- bulles : GameTooltip.lines
function RegisterUnitWatch(f) f.watched = true end
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
  mock.unknown, mock.tickers, mock.actions, mock.bindings, mock.auras = {}, {}, nil, nil, nil
  mock.dead, mock.canAttack, mock.items, mock.hp, mock.cooldowns, mock.mana = nil, nil, nil, nil, nil, nil
  mock.vitalsReadable, mock.nodes, mock.unspent, mock.usable = nil, nil, nil, nil
  mock.time, mock.guid, mock.noGuid, mock.rangedID, mock.uncached, mock.known = 0, "Creature-0", nil, nil, nil
  mock.rangedSpeed = nil
  mock.level, mock.xp, mock.xpMax, mock.xpSecret = nil, nil, nil, nil
  mock.secure, mock.attrCalls, mock.attrInCombat, mock.secureInCombat, mock.offline, mock.outOfRange = {}, 0, 0, 0, nil, nil
  mock.moveInCombat = 0
  SlashCmdList = {}
  PretreCoachDB = nil
  mock.registered, mock.opened = nil, nil
  mock.waypoint, mock.superTracked, mock.canWaypoint, mock.areas, mock.mapKids, mock.mapNames = nil, nil, nil, nil, nil, nil
  mock.worldMap, mock.hooked, mock.grouped, mock.plates, mock.tipCall = nil, nil, nil, nil, nil
  mock.qreward, mock.choices, mock.questID = nil, nil, nil
  mock.rewards, mock.rewardXP, mock.rewardMoney = nil, nil, nil
  if WorldMapFrame then WorldMapFrame.shown = false end
  if mock.qinit then mock.qinit() end
  mock.recipeInfo, mock.schematics, mock.tsNotReady = nil, nil, nil
  mock.bagInfo, mock.itemClass, mock.itemSub, mock.itemInfo, mock.icons = nil, nil, nil, nil, nil
  mock.tipPost, mock.tipItem = nil, nil
  mock.pos, mock.recipes, mock.bag, mock.addons, mock.sellPrice, mock.sub, mock.ejSelected = nil, nil, nil, nil, nil, nil, nil
end

-- Minuteurs : file qu'on vide a la main.
mock.tickers = {}
C_Timer = { After = function(delay, fn) mock.timers[#mock.timers + 1] = { delay = delay, fn = fn } end,
  NewTicker = function(delay, fn)
    local t = { delay = delay, fn = fn, cancelled = false }
    t.Cancel = function(self) self.cancelled = true end
    mock.tickers[#mock.tickers + 1] = t
    return t
  end }
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
function UnitClass() if mock.noClass then return nil end return "Pretre", "PRIEST", 5 end
RAID_CLASS_COLORS = { PRIEST = { r = 0.9, g = 0.8, b = 0.7 } }
function UnitRace() return "Mort-vivant", "Scourge", 5 end
function UnitLevel() return mock.level or 12 end
-- mock.xp / mock.xpMax = XP du joueur (nil par defaut : illisible) ; mock.xpSecret = valeur secrete
function UnitXP() if mock.xpSecret or secretNow() then return mock.SECRET end return mock.xp end
function UnitXPMax() if mock.xpSecret or secretNow() then return mock.SECRET end return mock.xpMax end
-- Sonde : vie et mana du joueur sont secrets meme hors combat ; mock.vitalsReadable = true les rend lisibles.
-- mock.hp = vie du joueur (100 par defaut)
local function vitalsSecret() return secretNow() or (not mock.vitalsReadable and not mock.noSecrets) end
function UnitHealth(unit)
  if secretNow() or (unit == "player" and vitalsSecret()) then return mock.SECRET end
  return unit == "player" and mock.hp or 100
end
UnitHealthMax = sec(100)
-- mock.mana = mana du joueur en % (100 par defaut)
function UnitPower() return vitalsSecret() and mock.SECRET or mock.mana or 100 end
function UnitPowerMax() return secretNow() and mock.SECRET or 100 end
GetPowerRegen = sec(1)
function UnitExists() return mock.hasTarget end
UnitCreatureType = sec("Humanoïde")
-- mock.dead = la cible est morte ; mock.canAttack = false : cible non attaquable (allie, soi)
function UnitIsDead() if secretNow() then return mock.SECRET end return mock.dead == true end
-- cadres de soin : mock.offline = deconnecte, mock.outOfRange = hors de portee (mock.dead s'applique aussi a UnitIsDeadOrGhost)
function UnitIsDeadOrGhost() if secretNow() then return mock.SECRET end return mock.dead == true end
function UnitIsConnected() if secretNow() then return mock.SECRET end return mock.offline ~= true end
function UnitInRange() if secretNow() then return mock.SECRET end return mock.outOfRange ~= true, true end
function UnitCanAttack()if secretNow() then return mock.SECRET end return mock.canAttack ~= false end
-- mock.guid pilote le GUID de la cible ; mock.noGuid = illisible (nil)
function UnitRangedDamage() if secretNow() then return mock.SECRET end return mock.rangedSpeed end -- vitesse de la baguette (nil = inconnue)
function UnitGUID() if mock.noGuid then return nil end return secretNow() and mock.SECRET or mock.guid end
function CheckInteractDistance() return false end
function GetUnitSpeed() return 0 end
function IsPlayerMoving() return false end
function GetTime() return mock.time end -- pilotable : mock.time
function GetMoney() if mock.moneySecret then return mock.SECRET end return mock.money or 0 end -- pilotable : mock.money (cuivre)
function GetInventoryItemID(_, slot) if slot == 18 then return mock.rangedID end end -- mock.rangedID = baguette equipee
function GetInventoryItemLink() return nil end
function IsPlayerSpell(id) if mock.known then return mock.known[id] or false end return true end -- mock.known = { [id] = true }
function IsSpellKnown(id) return IsPlayerSpell(id) end
function GetProfessions() return 1, 2 end
function GetProfessionInfo(i) return i == 1 and "Herboristerie" or "Alchimie", 0, 100, 300, 0, 0, i == 1 and 182 or 171 end
-- Talents modernes. mock.nodes = { { spellID, rank, max }, ... } ; mock.unspent = nombre (GetNumUnspentTalents)
function GetNumSpecGroups() return 1 end
C_SpecializationInfo = { GetActiveSpecGroup = function() return 1 end, SetActiveSpecGroup = function() end }
C_ClassTalents = { GetActiveConfigID = function() return 3766924 end,
  HasUnspentTalentPoints = function() return (mock.unspent or 0) > 0 end }
function GetNumUnspentTalents() return mock.unspent or 0 end
C_Traits = {
  GetConfigInfo = function() return { treeIDs = { 1 } } end,
  GetTreeNodes = function() local t = {} for i in ipairs(mock.nodes or {}) do t[i] = i end return t end,
  GetNodeInfo = function(_, id) local n = mock.nodes[id] return { activeRank = n[2], maxRanks = n[3], entryIDs = { id }, activeEntry = { entryID = id } } end,
  GetEntryInfo = function(_, id) return { definitionID = id } end,
  GetDefinitionInfo = function(id) return { spellID = mock.nodes[id][1] } end,
}
function GetNumTrainerServices() return 3 end
function GetTrainerServiceInfo(i) return "Sort" .. i, "", "available" end
function GetTrainerServiceLevelReq() return 10 end
function GetTrainerServiceCost() return 100 end
function GetCoinTextureString(c) return "COIN:" .. c end
C_SpellBook = { IsSpellKnown = function() return true end, IsSpellInSpellBook = function() return true end }
-- Journal pilotable : mock.qlog = { { questID, title, isHeader, complete, objectives = { { text, numFulfilled, numRequired, finished } } } } ;
-- mock.qdone = { [questID] = true } : quetes deja faites
C_QuestLog = { IsQuestFlaggedCompleted = function(id) return (mock.qdone or {})[id] == true end, GetTitleForQuestID = function() return "Titre" end,
  GetNumQuestLogEntries = function() return #(mock.qlog or {}), 0 end,
  GetInfo = function(i) local q = (mock.qlog or {})[i] return q and { questID = q.questID, title = q.title, level = q.level, isHeader = q.isHeader == true } or nil end,
  IsComplete = function(id) for _, q in ipairs(mock.qlog or {}) do if q.questID == id then return q.complete == true end end end,
  GetQuestObjectives = function(id) for _, q in ipairs(mock.qlog or {}) do if q.questID == id then return q.objectives or {} end end return {} end }
-- mock.icons sert aussi a GetItemIcon (ancienne API, repli)
function GetItemIcon(id) return (mock.icons or {})[id] end
-- mock.items = { [itemID] = nombre porte }
function GetItemCount(id) return (mock.items or {})[id] or 0 end
-- 11287 = baguette (classe 2, sous-classe 19) ; les autres IDs : un objet quelconque
C_Item = { GetItemInfoInstant = function(id)
  if (mock.unknown.item or {})[id] then return nil end
  return id, "Arme", "Baguette", "", 0, (mock.itemClass or {})[id] or 2, (mock.itemSub or {})[id] or (id == 11287 and 19 or 0)
end,
  -- mock.icons = { [id] = fileID } ; sans entree : icone illisible
  GetItemIconByID = function(id) return (mock.icons or {})[id] end,
  -- mock.itemInfo = { [id] = { nom, niveau d'objet, niveau requis, icone } }
  GetItemInfo = function(id)
    local c = (mock.itemInfo or {})[id]
    if c and not mock.uncached then return c[1], "lien", 1, c[2], c[3], "x", "x", 20, "", c[4] end
    if mock.uncached then return nil end return "Baguette " .. id, "lien", 1, 1, 5, 0, "x", 1, "", 0, type(mock.sellPrice) == "table" and mock.sellPrice[id] or (type(mock.sellPrice) == "number" and mock.sellPrice or nil) end }
-- mock.recipes = nombre de recettes (0 par defaut)
C_TradeSkillUI = { GetProfessionInfoBySkillLineID = function(id) return { professionName = "Metier" .. id } end,
  GetAllRecipeIDs = function() local t = {} for i = 1, mock.recipes or 0 do t[i] = 100 + i end return t end,
  -- mock.recipeInfo = { [id] = champs a modifier } ; mock.schematics = { [id] = schema } ; mock.tsNotReady = fenetre pas prete
  GetRecipeInfo = function(id)
    local t = { recipeID = id, name = "Recette" .. id, relativeDifficulty = 0, numSkillUps = 1, learned = true, craftable = false, numAvailable = 0 }
    for k, v in pairs((mock.recipeInfo or {})[id] or {}) do t[k] = v end
    return t
  end,
  GetRecipeSchematic = function(id, isRecraft) assert(isRecraft == false) return (mock.schematics or {})[id] or {} end,
  -- mock.selected = liste des recettes presélectionnées ; mock.crafted = fabrications (doit rester vide)
  OpenRecipe = function(id) mock.selected = mock.selected or {} mock.selected[#mock.selected + 1] = id end,
  Craft = function(id) mock.crafted = (mock.crafted or 0) + 1 end,
  IsTradeSkillReady = function() return not mock.tsNotReady end,
  GetTradeSkillLine = function() return 171, "Alchimie", 50, 75 end,
  GetBaseProfessionInfo = function() return { professionID = 171, skillLevel = 50, maxSkillLevel = 75 } end }
-- Zone, cible, sacs (mock.bag = { [slot] = itemID } dans le sac 0), addons, journal de donjon
function GetRealZoneText() return "Tirisfal" end
function GetSubZoneText() return mock.sub or "Brill" end
function UnitName() if secretNow() then return mock.SECRET end return "Cible" end
-- mock.bagInfo = { [slot] = infos de GetContainerItemInfo } dans le sac 0 (remplace mock.bag) ; mock.itemClass = { [id] = classID }
C_Container = { GetContainerNumSlots = function(bag) return bag == 0 and (mock.bagInfo and 20 or 4) or 0 end,
  GetContainerItemID = function(bag, slot) return bag == 0 and (mock.bag or { 2589 })[slot] or nil end,
  GetContainerItemInfo = function(bag, slot) if mock.bagInfo then return bag == 0 and mock.bagInfo[slot] or nil end return { itemID = 2589 } end }
-- mock.addons = { Questie = true } ; mock.sellPrice = prix de vente (11e valeur de GetItemInfo)
C_AddOns = { IsAddOnLoaded = function(n) return (mock.addons or {})[n] == true end,
  GetAddOnMetadata = function(n, f) if n == "QuestieDB" and f == "Version" then return mock.qver end end }

-- LibQuestieDB minimal (contrat 4). mock.qnpcs = { [id] = { flags, subName, faction, zoneID, spawns } } en plus de 450 PNJ neutres ;
-- mock.qver = version de l'addon ; mock.qboom = les lectures levent une erreur ; mock.qreads = nombre de lectures de PNJ.
local NPC_KEYS = { npcFlags = 1, subName = 2, friendlyToFaction = 3, zoneID = 4, spawns = 5, name = 6, minLevel = 7, maxLevel = 8 }
local function qDefaults()
  return {
    [375] = { 16, "Priest Trainer", "H", 1497, { [1497] = { { 52.3, 41.2 } } } },
    [376] = { 16, "Priest Trainer", "A", 1519, { [1519] = { { 40, 40 } } } },
    [377] = { 16, "Priest Trainer", "AH", 85, { [85] = { { 30.5, 60.1 } } } },
    [300] = { 16, "Alchemy Trainer", "H", 1497, { [1497] = { { 10, 20 } } } },
    [301] = { 16, "Herbalism Trainer", "H", 1497, { [1497] = { { 11, 21 } } } },
    [302] = { 16, "First Aid Trainer", "H", 1497, { [1497] = { { 12, 22 } } } },
    [303] = { 16, "Cooking Trainer", "H", 1637, { [1637] = { { 13, 23 } } } },
    [304] = { 4096, "Auctioneer", "H", 1497, { [1497] = { { 14, 24 } } } },
    [305] = { 4, "Priest Trainer", "H", 85, { [85] = { { 1, 2 } } } }, -- pas de bit maitre : ignore
    [306] = { 16, "Priest Trainer", nil, 85, { [85] = { { 1, 2 } } } }, -- hostile : ecarte
    [307] = { 16, "Junior Herbalism Trainer", "AH", 85, { [85] = { { 15, 25 } } } },
    [308] = { 16, "Priest Trainer", "H", 1497, { [1497] = { { -1, -1 } } } }, -- instance : pas de point
  }
end
function mock.qinit()
  mock.qnpcs, mock.qver, mock.qboom, mock.qreads, mock.ah, mock.ahBoom = qDefaults(), "1.0.11", nil, 0, { [2589] = { 120, 3 } }, nil
  mock.qquests, mock.qitems, mock.qobjects = nil, nil, nil
  mock.qlog, mock.qdone, mock.mapID = nil, nil, nil
end
mock.qinit()
local function qIds() local t = {} for i = 1, 450 do t[i] = i end return t end
local function qGet(id, key)
  mock.qreads = (mock.qreads or 0) + 1
  if mock.qboom then error("boom") end
  local n = mock.qnpcs[id]
  if not n then return key == "npcFlags" and 0 or nil end
  return n[NPC_KEYS[key]]
end
LibQuestieDB = {
  RequireContract = function(v) if v <= 4 then return true end return false, "trop recent" end,
  Enum = { npcFlags = { TRAINER = 16, AUCTIONEER = 4096 }, zoneIDs = { UNDERCITY = 1497, ORGRIMMAR = 1637, THUNDER_BLUFF = 1638 } },
  Npc = { Get = qGet, GetAllIds = function() return qIds() end },
  -- mock.qitems = { [itemID] = { name, objectDrops } } ; mock.qobjects = { [objectID] = { name, spawns } }
  Item = { Get = function(id, key) if mock.qboom then error("boom") end local i = (mock.qitems or {})[id] return i and i[key] end },
  Object = { Get = function(id, key) if mock.qboom then error("boom") end local o = (mock.qobjects or {})[id] return o and o[key] end },
  -- mock.qquests = { [id] = { name, startedBy, finishedBy, objectives, requiredLevel, questLevel, requiredRaces, preQuestSingle, preQuestGroup } } en plus de 6561
  Quest = { GetAllIds = function() local t = { 6561 } for id in pairs(mock.qquests or {}) do t[#t + 1] = id end table.sort(t) return t end,
    Get = function(id, key) if mock.qboom then error("boom") end
    local q = (mock.qquests or {})[id]
    if q then return q[key] end
    if id == 6561 then return key == "name" and "Quete" or (key == "startedBy" and { { 375 } }) or nil end end },
}
-- mock.ah = { [itemID] = { prix, age } } ; mock.ahBoom = l'API leve une erreur
Auctionator = { API = { v1 = {
  GetAuctionPriceByItemID = function(caller, id) assert(type(caller) == "string") if mock.ahBoom then error("boom") end local e = (mock.ah or {})[id] return e and e[1] end,
  GetAuctionAgeByItemID = function(caller, id) assert(type(caller) == "string") if mock.ahBoom then error("boom") end local e = (mock.ah or {})[id] return e and e[2] end,
} } }
C_EncounterJournal = {}
function EJ_GetNumTiers() return 2 end
function EJ_GetTierInfo(i) return "Palier" .. i end
function EJ_GetCurrentTier() return 1 end
function EJ_GetInstanceByIndex(i, raid) if i <= 12 and not raid then return 900 + i, "Donjon" .. i end end
function EJ_SelectInstance() mock.ejSelected = true end
function EJ_GetEncounterInfoByIndex() end
function EJ_GetLootInfoByIndex() end
C_ActionBar = { FindSpellActionButtons = function() return nil end }
-- mock.registered = categorie enregistree ; mock.opened = id passe a OpenToCategory
Settings = {
  RegisterCanvasLayoutCategory = function(panel, name) return { panel = panel, name = name, GetID = function() return 42 end } end,
  RegisterAddOnCategory = function(c) mock.registered = c end,
  OpenToCategory = function(id) mock.opened = id end,
}
-- mock.cooldowns = { [spellID] = { start, duree } } ; sans entree : pas de recharge
local function cdOf(id) local c = (mock.cooldowns or {})[id] return c and c[1] or 0, c and c[2] or 0 end
C_Spell = {
  GetSpellName = function(id) if (mock.unknown.spell or {})[id] then return nil end return "Sort" .. id end,
  GetSpellCooldown = function(id)
    if secretNow() then return mock.SECRET end
    local s, d = cdOf(id)
    return { startTime = s, duration = d, isEnabled = true }
  end,
  -- mock.usable = false : sort inutilisable
  IsSpellUsable = function() if secretNow() then return mock.SECRET end return mock.usable ~= false, false end,
  IsSpellInRange = sec(true),
  GetSpellPowerCost = function() return { { type = 0, cost = 10 } } end,
}
C_UnitAuras = { GetAuraDataByIndex = function() return secretNow() and mock.SECRET or nil end,
  -- mock.auras = { [spellID] = true } : auras du joueur
  GetPlayerAuraBySpellID = function(id)
    if secretNow() then return mock.SECRET end
    if mock.auras and mock.auras[id] then return { name = "Aura" .. id } end
  end }
-- mock.actions = { [slot] = spellID } ; mock.bindings = { [commande] = touche }
function GetActionInfo(slot) local id = (mock.actions or {})[slot] if id then return "spell", id end end
function GetBindingKey(cmd) return (mock.bindings or {})[cmd] end
function GetBindingText(k) return k end
C_Spell.GetSpellTexture = function(id) return "tex" .. id end
-- mock.pos = { x, y } (fractions) ; mock.pos = false : position nil
local function vec(x, y) return { GetXY = function() return x, y end } end
C_Map = { GetPlayerMapPosition = function(mapID, unit) assert(type(mapID) == "number" and unit == "player", "GetPlayerMapPosition(uiMapID, unit)") if mock.pos == false then return nil end local p = mock.pos or { 0.456, 0.789 } return vec(p[1], p[2]) end,
  CanSetUserWaypointOnMap = function() return mock.canWaypoint ~= false end, GetUserWaypoint = function() return nil end,
  SetUserWaypoint = function(p) mock.waypoint = p end,
  GetBestMapForUnit = function() return mock.mapID or 1 end, GetMapWorldSize = function() return 1000, 500 end,
  GetMapInfo = function(id) if (mock.unknown.map or {})[id] then return nil end return { name = (mock.mapNames or {})[id] or "Tirisfal", parentMapID = id == 1 and 1420 or 0 } end,
  -- mock.areas = { [areaID] = nom } ; mock.mapKids = { [racine] = { { mapID, name }, ... } } (defauts : Tirisfal, Fossoyeuse, Orgrimmar sous 946)
  GetAreaInfo = function(id) return (mock.areas or { [85] = "Tirisfal", [1497] = "Fossoyeuse", [1637] = "Orgrimmar" })[id] end,
  -- une entree peut porter kind (Enum.UIMapType) : elle n'est rendue que pour ce type
  GetMapChildrenInfo = function(root, kind)
    local out = {}
    for _, m in ipairs((mock.mapKids or { [946] = { { mapID = 1420, name = "Tirisfal" }, { mapID = 1458, name = "Fossoyeuse" }, { mapID = 1411, name = "Orgrimmar" } } })[root] or {}) do
      if m.kind == nil or m.kind == kind then out[#out + 1] = m end
    end
    return out
  end }
Enum = { UIMapType = { Cosmic = 0, World = 1, Continent = 2, Zone = 3, City = 10, Dungeon = 4, Micro = 5, Orphan = 6 },
  TradeskillRelativeDifficulty = { Optimal = 0, Medium = 1, Easy = 2, Trivial = 3 }, TooltipDataType = { Item = 0 } }
-- bulles d'objets : mock.tipPost = rappel de TooltipDataProcessor ; mock.tipItem = lien rendu par GameTooltip:GetItem (repli OnTooltipSetItem)
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn) assert(kind == Enum.TooltipDataType.Item) mock.tipPost = fn end }
function GameTooltip.GetItem() return "x", mock.tipItem end

-- Carte du monde minimale : mock.worldMap = uiMapID affiche ; WorldMapFrame:Show() l'ouvre ; mock.hooked = hooksecurefunc ;
-- WorldMapFrame.hooks = HookScript ; mock.grouped = IsInGroup
function FRAME.GetWidth(self) return self.width end
function FRAME.GetHeight(self) return self.height end
WorldMapFrame = newFrame()
WorldMapFrame.GetMapID = function() return mock.worldMap end
WorldMapFrame.ScrollContainer = { Child = newFrame() }
WorldMapFrame.ScrollContainer.Child.width, WorldMapFrame.ScrollContainer.Child.height = 1000, 500
function hooksecurefunc(obj, name, fn)
  assert(type(obj[name]) == "function", "hooksecurefunc : fonction inconnue " .. tostring(name))
  mock.hooked = mock.hooked or {}
  mock.hooked[name] = fn
end
function IsInGroup() return mock.grouped == true end

-- Barres de nom : mock.plates = { [unit] = cadre } ; bulle d'unite : mock.tipCall = rappel de AddTooltipPostCall
C_NamePlate = { GetNamePlateForUnit = function(unit) return (mock.plates or {})[unit] end }
Enum.TooltipDataType.Unit = 2
TooltipDataProcessor = { AddTooltipPostCall = function(kind, fn)
  if kind == Enum.TooltipDataType.Unit then mock.tipCall = fn else assert(kind == Enum.TooltipDataType.Item) mock.tipPost = fn end
end }

-- Recompenses : mock.qreward ={ [questID] = { xp, cuivre } } (valeurs mock.SECRET possibles) ; mock.choices = { { itemID, quantite } }
-- pour la fenetre de quete ouverte (mock.questID) ; QuestInfoRewardsFrame.RewardButtons = boutons Blizzard
function GetQuestLogRewardXP(id) local r = (mock.qreward or {})[id] return r and r[1] end
function GetQuestLogRewardMoney(id) local r = (mock.qreward or {})[id] return r and r[2] end
-- fenetre ouverte : mock.rewardXP, mock.rewardMoney (valeurs mock.SECRET possibles), mock.rewards = objets fixes { { itemID, quantite } }
local function items(kind) return (kind == "choice" and mock.choices or kind == "reward" and mock.rewards) or {} end
function GetRewardXP() return mock.rewardXP end
function GetRewardMoney() return mock.rewardMoney end
function GetNumQuestChoices() return #items("choice") end
function GetNumQuestRewards() return #items("reward") end
function GetQuestItemLink(kind, i) local c = items(kind)[i] return c and ("|cffffffff|Hitem:" .. c[1] .. "::|h[Objet]|h|r") or nil end
function GetQuestItemInfo(kind, i) local c = items(kind)[i] if c then return "Objet", 1, c[2] or 1, 1, true, c[1] end end
function GetQuestID() return mock.questID end
QuestInfoRewardsFrame = { RewardButtons = {} }
for i = 1, 6 do QuestInfoRewardsFrame.RewardButtons[i] = newFrame() end

-- mock.waypoint = dernier repere pose ; mock.superTracked = dernier appel de suivi ; mock.canWaypoint = false : carte refusee
UiMapPoint = { CreateFromCoordinates = function(mapID, x, y) return { mapID = mapID, x = x, y = y } end }
C_SuperTrack = { SetSuperTrackedUserWaypoint = function(v) mock.superTracked = v end }

-- APIs incertaines sur Forever : mock.setAbsent(true) les retire toutes (passe « absente »), false les remet.
local UNCERTAIN = [[
C_Traits C_ClassTalents C_SpecializationInfo GetNumSpecGroups GetNumUnspentTalents
C_SpellBook IsPlayerSpell IsSpellKnown GetProfessions GetProfessionInfo
C_Map C_QuestLog GetUnitSpeed IsPlayerMoving C_Timer Settings GetNumTrainerServices GetTrainerServiceInfo
GetTrainerServiceLevelReq GetTrainerServiceCost GetCoinTextureString GetInventoryItemID GetBindingText C_ActionBar issecretvalue C_TradeSkillUI GetItemCount
UiMapPoint C_SuperTrack WorldMapFrame hooksecurefunc Enum C_Container C_AddOns C_EncounterJournal EJ_GetNumTiers EJ_GetTierInfo EJ_GetCurrentTier EJ_GetInstanceByIndex
EJ_SelectInstance EJ_GetEncounterInfoByIndex EJ_GetLootInfoByIndex LibQuestieDB Auctionator LibStub WT_API GetItemIcon UnitXP UnitXPMax RegisterUnitWatch UnitInRange
GetQuestLogRewardXP GetQuestLogRewardMoney GetNumQuestChoices GetQuestItemLink GetQuestItemInfo GetQuestID QuestInfoRewardsFrame
GetRewardXP GetRewardMoney GetNumQuestRewards C_NamePlate TooltipDataProcessor
]]
local saved = {}
for n in UNCERTAIN:gmatch("%S+") do saved[n] = _G[n] end
function mock.setAbsent(absent)
  for n, v in pairs(saved) do _G[n] = (not absent) and v or nil end
  mock.noSecrets = absent
end

return mock
