-- /coach probe : relevé de ce que l'API de Forever donne vraiment à un addon.
-- Rien de secret n'est stocké ni affiché : on note seulement « SECRET ».
-- Le relevé hors combat est pris à la commande ; le relevé en combat est pris seul,
-- 2 puis 5 secondes après le début de chaque combat, et mémorisé (SavedVariables).
local _, ns = ...
local S, L = ns.S, ns.L

-- ID de base (rang 1). Sources : WoWForeverRot/Data.lua et IDs Classic. La sonde les valide.
local SPELLS = {
  { 585, "Châtiment" }, { 589, "Mot de l'ombre : Douleur" }, { 17, "Mot de pouvoir : Bouclier" },
  { 8092, "Attaque mentale" }, { 14914, "Flammes sacrées" }, { 15407, "Fouet mental" },
  { 15473, "Forme d'Ombre" }, { 32379, "Mot de l'ombre : Mort" }, { 6346, "Protection contre la peur" },
  { 2944, "Peste dévorante" }, { 14752, "Esprit divin" }, { 2652, "Toucher de faiblesse" },
  { 1277324, "Sacrifice sombre" }, { 20577, "Cannibalisme" }, { 5019, "Tir (baguette)" },
  { 8122, "Cri psychique" }, { 15271, "Connexion spirituelle (buff)" }, { 47540, "Pénitence" },
  { 1243, "Mot de pouvoir : Robustesse" }, { 2050, "Soins inférieurs" }, { 139, "Rénovation" },
}

local APIS = {
  "issecretvalue", "C_Timer.After", "C_Timer.NewTicker",
  "C_Spell.GetSpellInfo", "C_Spell.GetSpellName", "C_Spell.GetSpellTexture", "C_Spell.GetSpellCooldown",
  "C_Spell.IsSpellUsable", "C_Spell.IsSpellInRange", "C_Spell.GetSpellPowerCost",
  "GetSpellInfo", "GetSpellCooldown", "IsUsableSpell", "IsSpellInRange",
  "IsPlayerSpell", "IsSpellKnown", "IsSpellKnownOrOverridesKnown",
  "C_SpellBook.IsSpellInSpellBook", "C_SpellBook.IsSpellKnown", "C_SpellBook.FindSpellBookSlotForSpell",
  "C_Map.GetBestMapForUnit", "C_Map.GetMapInfo",
  "C_QuestLog.IsQuestFlaggedCompleted", "IsQuestFlaggedCompleted",
  "C_UnitAuras.GetAuraDataByIndex", "C_UnitAuras.GetPlayerAuraBySpellID", "C_UnitAuras.GetAuraDataBySpellName",
  "GetInventoryItemID", "GetInventoryItemLink",
  "C_Item.GetItemInfo", "C_Item.GetItemInfoInstant", "GetItemInfo", "GetItemInfoInstant",
  "GetUnitSpeed", "IsPlayerMoving", "C_TradeSkillUI.GetBaseProfessionInfo", "C_TradeSkillUI.GetProfessionInfoBySkillLineID",
  "GetProfessions", "GetProfessionInfo", "GetNumSkillLines", "GetSkillLineInfo",
  "GetNumTalentTabs", "GetTalentTabInfo", "GetTalentInfo", "GetNumTalents",
  "GetUnspentTalentPoints", "UnitCharacterPoints",
  "GetNumTalentGroups", "GetActiveTalentGroup", "GetNumSpecGroups", "GetActiveSpecGroup",
  "C_ClassTalents.GetActiveConfigID", "C_ClassTalents.HasUnspentTalentPoints", "GetNumUnspentTalents",
  "C_Traits.GetConfigInfo", "C_Traits.GetTreeNodes", "C_Traits.GetNodeInfo", "C_Traits.GetEntryInfo", "C_Traits.GetDefinitionInfo",
  "C_SpecializationInfo.GetSpecialization", "C_SpecializationInfo.GetActiveSpecGroup", "LegacySystemFrame_LoadUI", "ToggleLegacySystemUI",
  "GetNumTrainerServices", "GetTrainerServiceInfo", "GetTrainerServiceLevelReq", "GetTrainerServiceCost",
  "Settings.RegisterCanvasLayoutCategory", "Settings.RegisterAddOnCategory", "InterfaceOptions_AddCategory",
  "C_AssistedCombat.GetNextCastSpell",
  "GetActionInfo", "GetBindingKey", "C_ActionBar.FindSpellActionButtons",
  "UnitCreatureType", "CheckInteractDistance", "GetPowerRegen", "InCombatLockdown",
}

local EVENTS = {
  "UNIT_SPELLCAST_SUCCEEDED", "PLAYER_LEVEL_UP", "PLAYER_EQUIPMENT_CHANGED", "ZONE_CHANGED_NEW_AREA",
  "TRAINER_SHOW", "PLAYER_TARGET_CHANGED", "SKILL_LINES_CHANGED", "QUEST_TURNED_IN",
  "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED", "TRAIT_CONFIG_UPDATED",
  "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_STARTED_MOVING", "PLAYER_STOPPED_MOVING",
  "PLAYER_XP_UPDATE", "CHAT_MSG_COMBAT_XP_GAIN", "PLAYER_REGEN_DISABLED", "UNIT_HEALTH",
  "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_CLOSE",
}

------------------------------------------------------------------------
-- lecture sans risque
------------------------------------------------------------------------
local function Resolve(path)
  local v = _G
  for part in path:gmatch("[^%.]+") do
    if type(v) ~= "table" then return nil end
    v = v[part]
  end
  return v
end

-- état d'une table rendue par une API (jamais « table: 0x… »)
local function TableState(v)
  for _, k in ipairs({ "spellId", "name", "startTime", "duration", "isActive" }) do
    if S.IsSecret(v[k]) then return "SECRET (champs)" end
  end
  return "lisible (table" .. (v.spellId and (" spellId=" .. tostring(v.spellId)) or "") .. ")"
end

local function Show(v)
  if S.IsSecret(v) then return "SECRET" end
  if type(v) == "table" then return TableState(v) end
  return tostring(v)
end

-- toutes les valeurs rendues par une API, en texte
local function Dump(path, ...)
  local fn = Resolve(path)
  if type(fn) ~= "function" then return "API absente" end
  local r = { n = 0 }
  local function pack(...) r.n = select("#", ...); for i = 1, r.n do r[i] = select(i, ...) end end
  pack(pcall(fn, ...))
  if not r[1] then return "erreur : " .. tostring(r[2]) end
  local out = {}
  for i = 2, r.n do out[#out + 1] = Show(r[i]) end
  return #out > 0 and table.concat(out, ", ") or "(rien)"
end

-- la première valeur : lisible ou secrète ?
local function Status(path, ...)
  local fn = Resolve(path)
  if type(fn) ~= "function" then return "API absente" end
  local ok, v = pcall(fn, ...)
  if not ok then return "erreur" end
  if S.IsSecret(v) then return "SECRET" end
  if type(v) == "table" then return TableState(v) end
  return "lisible (" .. tostring(v) .. ")"
end

local function SpellName(id)
  local n = S.Get(C_Spell and C_Spell.GetSpellName, id)
  return n or "?"
end

-- Position du joueur en fractions 0..1, ou nil si illisible (API absente, nil ou secrète).
local function PlayerXY(mapID)
  local pos = mapID and S.Get(C_Map and C_Map.GetPlayerMapPosition, "player", mapID)
  if not pos then return nil end
  local ok, x, y = pcall(function()
    if pos.GetXY then return pos:GetXY() end
    return pos.x, pos.y
  end)
  if ok and type(x) == "number" and type(y) == "number" and not S.IsSecret(x) and not S.IsSecret(y) then return x, y end
end

-- « chemin:oui » / « chemin:NON » pour une liste de fonctions
local function Presence(list)
  local t = {}
  for _, p in ipairs(list) do t[#t + 1] = p .. ":" .. (type(Resolve(p)) == "function" and "oui" or "NON") end
  return table.concat(t, " | ")
end

-- table de données d'un addon tiers, en texte court (jamais plus de 4 entrées par niveau)
local function Brief(v, d)
  if type(v) ~= "table" then return tostring(v) end
  d = d or 0
  if d >= 3 then return "{…}" end
  local t, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 4 then t[#t + 1] = "…" break end
    t[#t + 1] = tostring(k) .. "=" .. Brief(x, d + 1)
  end
  return "{" .. table.concat(t, ", ") .. "}"
end

-- Relevé de la fenêtre de métier : nombre de recettes et 3 premières, sans valeur secrète.
local function TakeTradeskill()
  if not ns.db then return end
  local ids = S.Get(Resolve("C_TradeSkillUI.GetAllRecipeIDs"))
  if type(ids) ~= "table" or #ids == 0 then return end
  local rec = { when = date("%Y-%m-%d %H:%M:%S"), count = #ids, recipes = {} }
  for i = 1, math.min(3, #ids) do
    local info = S.Get(Resolve("C_TradeSkillUI.GetRecipeInfo"), ids[i])
    if type(info) == "table" then
      local r = { recipeID = ids[i] }
      for _, k in ipairs({ "name", "difficulty", "relativeDifficulty", "numSkillUps", "learned" }) do
        local v = info[k]
        if not S.IsSecret(v) and type(v) ~= "table" then r[k] = v end
      end
      rec.recipes[#rec.recipes + 1] = r
    end
  end
  ns.db.probe = ns.db.probe or {}
  ns.db.probe.tradeskill = rec
end

------------------------------------------------------------------------
-- relevés
------------------------------------------------------------------------
local function Snapshot()
  local hasTarget = S.Get(UnitExists, "target")
  local prof1 = S.Get(GetProfessions)
  local t = {
    { "Vie joueur", Status("UnitHealth", "player") },
    { "Vie max joueur", Status("UnitHealthMax", "player") },
    { "Mana joueur", Status("UnitPower", "player", 0) },
    { "Mana max", Status("UnitPowerMax", "player", 0) },
    { "Regen mana (GetPowerRegen)", Status("GetPowerRegen") },
    { "Recharge Attaque mentale (C_Spell)", Status("C_Spell.GetSpellCooldown", 8092) },
    { "Recharge globale (61304)", Status("C_Spell.GetSpellCooldown", 61304) },
    { "Buff joueur n°1", Status("C_UnitAuras.GetAuraDataByIndex", "player", 1, "HELPFUL") },
    { "Vitesse joueur", Status("GetUnitSpeed", "player") },
    { "Utilisable Cannibalisme", Status("C_Spell.IsSpellUsable", 20577) },
    { "Métier n°1 (GetProfessionInfo)", prof1 and Status("GetProfessionInfo", prof1) or "aucun métier (GetProfessions)" },
  }
  if hasTarget then
    local more = {
      { "Vie cible", Status("UnitHealth", "target") },
      { "Vie max cible", Status("UnitHealthMax", "target") },
      { "GUID cible", Status("UnitGUID", "target") },
      { "UnitIsDead cible", Status("UnitIsDead", "target") },
      { "Niveau cible", Status("UnitLevel", "target") },
      { "Type de créature cible", Status("UnitCreatureType", "target") },
      { "Débuff cible n°1", Status("C_UnitAuras.GetAuraDataByIndex", "target", 1, "HARMFUL") },
      { "Débuff cible n°1 (les miens)", Status("C_UnitAuras.GetAuraDataByIndex", "target", 1, "HARMFUL|PLAYER") },
      { "Cible au contact (CheckInteractDistance 3)", Status("CheckInteractDistance", "target", 3) },
      { "Portée Tir sur cible", Status("C_Spell.IsSpellInRange", 5019, "target") },
    }
    for _, l in ipairs(more) do t[#t + 1] = l end
  else
    t[#t + 1] = { "Cible", "aucune (cible un monstre pour tester la cible)" }
  end
  return { lines = t, when = date("%Y-%m-%d %H:%M:%S"), target = hasTarget and true or false }
end

-- Tables globales dont le nom contient « legacy » ou « forever » (pas seulement C_*) : membres listés ; C_GameRules en entier.
local function Members(v)
  local m = {}
  for fk, fv in pairs(v) do if type(fk) == "string" then m[#m + 1] = fk .. (type(fv) == "function" and "()" or ":" .. type(fv)) end end
  table.sort(m)
  return "{ " .. table.concat(m, ", ") .. " }"
end

local function Discover()
  local hits, pats = {}, { "legacy", "forever", "camelot", "talent", "trainer", "specgroup", "dualspec" }
  local function match(name)
    local l = name:lower()
    for _, p in ipairs(pats) do if l:find(p, 1, true) then return true end end
  end
  for k, v in pairs(_G) do
    if type(k) == "string" then
      local l = k:lower()
      if type(v) == "function" and match(k) then
        hits[#hits + 1] = k .. "()"
      elseif type(v) == "table" and (l:find("legacy", 1, true) or l:find("forever", 1, true) or k == "C_GameRules") then
        hits[#hits + 1] = k .. " " .. Members(v)
      elseif type(v) == "table" and k:sub(1, 2) == "C_" then
        local fns = {}
        for fk, fv in pairs(v) do
          if type(fk) == "string" and type(fv) == "function" and (match(k) or match(fk)) then fns[#fns + 1] = fk end
        end
        if #fns > 0 then
          table.sort(fns)
          hits[#hits + 1] = k .. " { " .. table.concat(fns, ", ") .. " }"
        end
      end
    end
  end
  table.sort(hits)
  return hits
end

-- Arbre C_Traits : un nœud par ligne (spellID de la définition, nom, rang/max), puis le sort du plan trouvé ou non.
local function TraitsReport(add)
  local T = C_Traits
  local cfg = S.Get(C_ClassTalents and C_ClassTalents.GetActiveConfigID)
  if not (T and type(cfg) == "number") then add("C_Traits ou configID indisponible") return end
  local info = S.Get(T.GetConfigInfo, cfg)
  add("configID %s | treeIDs : %s", tostring(cfg), type(info) == "table" and type(info.treeIDs) == "table" and table.concat(info.treeIDs, ", ") or "?")
  local found = {}
  for _, tree in ipairs(type(info) == "table" and type(info.treeIDs) == "table" and info.treeIDs or {}) do
    local nodes = S.Get(T.GetTreeNodes, tree)
    add("arbre %s : %d nœuds", tostring(tree), type(nodes) == "table" and #nodes or 0)
    for _, nodeID in ipairs(type(nodes) == "table" and nodes or {}) do
      local node = S.Get(T.GetNodeInfo, cfg, nodeID)
      if type(node) == "table" then
        for _, entryID in ipairs(type(node.entryIDs) == "table" and node.entryIDs or {}) do
          local entry = S.Get(T.GetEntryInfo, cfg, entryID)
          local def = type(entry) == "table" and S.Get(T.GetDefinitionInfo, entry.definitionID)
          local spellID = type(def) == "table" and def.spellID
          if type(spellID) == "number" then
            found[spellID] = { rank = node.activeRank, max = node.maxRanks }
            add("  nœud %s : spellID %s | %s | %s/%s", tostring(nodeID), tostring(spellID), SpellName(spellID),
              Show(node.activeRank), Show(node.maxRanks))
          else
            add("  nœud %s : définition illisible", tostring(nodeID))
          end
        end
      end
    end
  end
  add("Plan de talents :")
  for _, e in ipairs(ns.Data.TalentPlan) do
    if e.spellIDs then
      local hit
      for _, id in ipairs(e.spellIDs) do if found[id] then hit = { id = id, n = found[id] } break end end
      add("  %s : %s", e.name, hit and ("trouvé (spellID %d, rang %s/%s)"):format(hit.id, Show(hit.n.rank), Show(hit.n.max)) or "introuvable")
    end
  end
end

local function SlotLine(slot)
  local id, st = S.Get(GetInventoryItemID, "player", slot)
  local head = ("emplacement %d : %s | lien : %s"):format(slot,
    id and ("objet " .. tostring(id)) or (st == "nil" and "vide" or st), Dump("GetInventoryItemLink", "player", slot))
  if not id then return head end
  return head .. (" | instant : %s | infos : %s"):format(Dump("C_Item.GetItemInfoInstant", id), Dump("C_Item.GetItemInfo", id))
end

------------------------------------------------------------------------
-- suivi des événements (compteurs de session + dernier sort lancé)
------------------------------------------------------------------------
local reg, seen, lastCast, trainerDump = {}, {}, "aucun", nil
local UNIT_EVENTS = { UNIT_SPELLCAST_SUCCEEDED = true, UNIT_HEALTH = true }

for _, ev in ipairs(EVENTS) do
  local on = UNIT_EVENTS[ev] and function(e, fn) return ns.OnUnit(e, "player", fn) end or ns.On
  reg[ev] = on(ev, function(e, _, _, spellID)
    seen[e] = (seen[e] or 0) + 1
    if e == "UNIT_SPELLCAST_SUCCEEDED" then
      local secret = S.IsSecret(spellID)
      lastCast = secret and "SECRET" or (tostring(spellID) .. " " .. SpellName(spellID))
      if InCombatLockdown() then
        lastCast = lastCast .. " (en combat)"
        -- la question clé : le spellID reste-t-il lisible en combat ? Mémorisé à part, le hors-combat ne l'écrase pas.
        if ns.db then
          ns.db.probe = ns.db.probe or {}
          ns.db.probe.lastCombatCast = { id = secret and "SECRET" or spellID, name = secret and "?" or SpellName(spellID),
            when = date("%Y-%m-%d %H:%M:%S") }
        end
      end
    elseif e == "TRADE_SKILL_SHOW" or e == "TRADE_SKILL_LIST_UPDATE" then
      TakeTradeskill()
    elseif e == "TRAINER_SHOW" then
      trainerDump = { "services : " .. Dump("GetNumTrainerServices") }
      for i = 1, 3 do
        trainerDump[#trainerDump + 1] = ("  %d : %s | niveau %s | coût %s"):format(i,
          Dump("GetTrainerServiceInfo", i), Dump("GetTrainerServiceLevelReq", i), Dump("GetTrainerServiceCost", i))
      end
      if ns.db then ns.db.probe = ns.db.probe or {}; ns.db.probe.trainer = trainerDump end
    end
  end)
end

-- Un relevé sans cible n'écrase pas un relevé en combat qui avait une cible. Rend true si mémorisé.
local function StoreCombat(snap)
  local old = ns.db.probe.combat
  if snap.target or not (old and old.target) then ns.db.probe.combat = snap return true end
end

ns.On("PLAYER_REGEN_DISABLED", function()
  local function take(announce)
    if not InCombatLockdown() then return end
    ns.db.probe = ns.db.probe or {}
    local snap = Snapshot()
    StoreCombat(snap)
    if announce and snap.target then ns.Print(L.PROBE_COMBAT_SAVED); ns.probeAnnounced = true end
  end
  ns.After(2, function() take(false) end)
  ns.After(5, function() take(not ns.probeAnnounced) end)
end)

------------------------------------------------------------------------
-- fenêtre copiable
------------------------------------------------------------------------
local win
local function ShowText(text)
  if not win then
    win = CreateFrame("Frame", "PretreCoachProbeFrame", UIParent)
    win:SetSize(680, 480)
    win:SetPoint("CENTER")
    win:SetFrameStrata("DIALOG")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    tinsert(UISpecialFrames, "PretreCoachProbeFrame") -- Échap ferme la fenêtre

    local bg = win:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.06, 0.04, 0.10, 0.94)
    local top = win:CreateTexture(nil, "BORDER")
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(2)
    top:SetColorTexture(0.69, 0.52, 1, 1)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText(L.PROBE_TITLE)

    local close = CreateFrame("Button", nil, win)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -6, -4)
    local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    x:SetPoint("CENTER"); x:SetText("×")
    close:SetScript("OnClick", function() win:Hide() end)

    -- ScrollFrame simple, sans modèle : certains modèles Retail manquent sur Forever
    local scroll = CreateFrame("ScrollFrame", nil, win)
    scroll:SetPoint("TOPLEFT", 12, -34)
    scroll:SetPoint("BOTTOMRIGHT", -12, 12)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, d)
      local y = self:GetVerticalScroll() - d * 60
      self:SetVerticalScroll(math.max(0, math.min(y, self:GetVerticalScrollRange())))
    end)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetWidth(650)
    edit:SetScript("OnEscapePressed", function() win:Hide() end)
    scroll:SetScrollChild(edit)
    win.edit = edit
  end
  win.edit:SetText(text)
  win.edit:SetFocus()
  win.edit:HighlightText()
  win:Show()
end

------------------------------------------------------------------------
-- contrôle des ID de Data/ : une ligne par ID qui ne répond pas, un « N/M OK » par catégorie
------------------------------------------------------------------------
local function CheckIds(add, label, ids, fn)
  if type(fn) ~= "function" then add("%s : non vérifiable (API absente)", label) return end
  local ok, n, seen = 0, 0, {}
  for _, e in ipairs(ids) do
    if e[1] and not seen[e[1]] then
      seen[e[1]] = true
      n = n + 1
      if S.Get(fn, e[1]) ~= nil then ok = ok + 1 else add("  %s %s : ne répond pas", tostring(e[1]), tostring(e[2])) end
    end
  end
  add("%s : %d/%d OK", label, ok, n)
end

local function CheckData(add)
  local D = ns.Data
  local spells, items, maps = {}, {}, {}
  for _, s in ipairs(D.Spells or {}) do
    for _, r in ipairs(s.ranks or {}) do spells[#spells + 1] = { r.id, s.key } end
  end
  CheckIds(add, "Sorts", spells, C_Spell and C_Spell.GetSpellName)

  for _, w in ipairs(D.Wands or {}) do items[#items + 1] = { w.itemID, w.name } end
  for _, p in pairs(D.Professions or {}) do
    for _, list in ipairs({ p.bandages or {}, p.recipes or {} }) do
      for _, e in ipairs(list) do items[#items + 1] = { e.itemID, e.name } end
    end
  end
  CheckIds(add, "Objets", items, C_Item and C_Item.GetItemInfoInstant)

  for id, z in pairs(D.Zones or {}) do maps[#maps + 1] = { id, z[3] } end
  for _, d in ipairs(D.Dungeons or {}) do maps[#maps + 1] = { d.zoneMapID, d.name } end
  CheckIds(add, "Cartes", maps, C_Map and C_Map.GetMapInfo)

  CheckIds(add, "Quêtes", { { D.GravestoneQuest, "Blackfathom Villainy" } }, C_QuestLog and C_QuestLog.GetTitleForQuestID)

  local byLine = C_TradeSkillUI and C_TradeSkillUI.GetProfessionInfoBySkillLineID
  CheckIds(add, "Métiers", { { 182, "Herboristerie" }, { 171, "Alchimie" }, { 129, "Secourisme" } },
    byLine and function(id) local i = byLine(id) return i and i.professionName ~= "" and i.professionName or nil end)
end

------------------------------------------------------------------------
-- /coach here : relève un lieu à la main (20 derniers dans ns.db.places)
------------------------------------------------------------------------
local MAX_PLACES = 20

function ns.Here()
  local mapID = S.Get(C_Map and C_Map.GetBestMapForUnit, "player")
  local info = mapID and S.Get(C_Map.GetMapInfo, mapID)
  local x, y = PlayerXY(mapID)
  if x then x, y = math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10 end
  local sub = S.Get(GetSubZoneText)
  local zone = S.Get(GetRealZoneText)
  local hasTarget = S.Get(UnitExists, "target")
  local target = hasTarget and S.Get(UnitName, "target") or nil

  local out = {
    L.HERE_MAP:format(info and Show(info.name) or "?", tostring(mapID)),
    L.HERE_ZONE:format(tostring(zone), (sub and sub ~= "") and sub or "-"),
    x and L.HERE_XY:format(x, y) or L.HERE_XY_NONE,
    hasTarget and (target and L.HERE_TARGET:format(tostring(target)) or L.HERE_TARGET_HIDDEN) or L.HERE_TARGET_NONE,
  }
  if ns.db then
    local places = ns.db.places or {}
    ns.db.places = places
    places[#places + 1] = { when = date("%Y-%m-%d %H:%M:%S"), mapID = mapID, x = x, y = y, sub = sub, target = target }
    while #places > MAX_PLACES do table.remove(places, 1) end
    out[#out + 1] = L.HERE_SAVED:format(#places, MAX_PLACES)
  end
  ShowText(table.concat(out, "\n"))
end

------------------------------------------------------------------------
-- sections étendues de la sonde (lecture seule : existence et lisibilité)
------------------------------------------------------------------------
local function ExtraSections(add, section)
  local function run(name, fn)
    section(name)
    local ok, err = pcall(fn)
    if not ok then add("erreur : %s", tostring(err)) end
  end

  run("Carte et repères", function()
    add(Presence({ "C_Map.SetUserWaypoint", "C_Map.GetUserWaypoint", "C_Map.CanSetUserWaypointOnMap",
      "C_Map.GetPlayerMapPosition", "UiMapPoint.CreateFromCoordinates", "C_SuperTrack.SetSuperTrackedUserWaypoint",
      "C_Map.GetAreaInfo", "C_Map.GetMapChildrenInfo" }))
    -- conversion AreaID -> uiMapID de Ext/Questie.lua : Tirisfal (85) doit donner 1420
    add("GetAreaInfo(85) : %s | uiMapID obtenu : %s (attendu 1420)", tostring(S.Get(C_Map and C_Map.GetAreaInfo, 85)),
      tostring(ns.Q.MapFor(85)))
    local mapID = S.Get(C_Map and C_Map.GetBestMapForUnit, "player")
    add("CanSetUserWaypointOnMap(%s) : %s | GetUserWaypoint : %s", tostring(mapID),
      Dump("C_Map.CanSetUserWaypointOnMap", mapID), Dump("C_Map.GetUserWaypoint"))
    local x, y = PlayerXY(mapID)
    add("GetPlayerMapPosition : %s", x and ("x et y lisibles (%.1f, %.1f)"):format(x * 100, y * 100) or "illisible, nil ou API absente")
  end)

  run("Métiers (fenêtre)", function()
    add(Presence({ "C_TradeSkillUI.GetAllRecipeIDs", "C_TradeSkillUI.GetRecipeInfo", "C_TradeSkillUI.GetRecipeSchematic",
      "C_TradeSkillUI.IsTradeSkillReady", "C_TradeSkillUI.GetTradeSkillLine", "C_TradeSkillUI.GetBaseProfessionInfo" }))
    for _, ev in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_CLOSE" }) do
      add("%s : %s", ev, reg[ev] and "inscrit" or "REFUSÉ")
    end
    local ts = ns.db.probe.tradeskill
    if not ts then add("fenêtre de métier pas encore ouverte : ouvre-la, puis retape /coach probe") return end
    add("relevé de %s : %d recettes", ts.when, ts.count)
    for _, r in ipairs(ts.recipes) do
      add("  %s %s | difficulty %s | relativeDifficulty %s | numSkillUps %s | learned %s", tostring(r.recipeID),
        tostring(r.name), tostring(r.difficulty), tostring(r.relativeDifficulty), tostring(r.numSkillUps), tostring(r.learned))
    end
  end)

  run("Sacs", function()
    add(Presence({ "C_Container.GetContainerNumSlots", "C_Container.GetContainerItemInfo", "C_Container.GetContainerItemID",
      "GetItemCount" }))
    local numSlots, itemID = Resolve("C_Container.GetContainerNumSlots"), Resolve("C_Container.GetContainerItemID")
    local bags, items, first = 0, 0, nil
    for bag = 0, 5 do
      local n = S.Get(numSlots, bag)
      if type(n) == "number" and n > 0 then
        bags = bags + 1
        for slot = 1, n do
          local id = S.Get(itemID, bag, slot)
          if type(id) == "number" then items = items + 1; first = first or id end
        end
      end
    end
    add("%d sacs, %d emplacements occupés", bags, items)
    if first then
      local r = { S.GetAll(Resolve("C_Item.GetItemInfo"), first) }
      add("objet %d : prix marchand (11e valeur de C_Item.GetItemInfo) : %s", first, r[1] == "lisible" and Show(r[12]) or r[1])
    end
  end)

  -- Aucune sélection (EJ_SelectInstance / EJ_SelectTier) : on lit le palier courant, l'interface du journal ne bouge pas.
  run("Journal de donjon", function()
    add(Presence({ "EJ_GetInstanceByIndex", "EJ_SelectInstance", "EJ_GetEncounterInfoByIndex", "EJ_GetLootInfoByIndex",
      "EJ_GetNumTiers" }))
    add("C_EncounterJournal : %s", type(Resolve("C_EncounterJournal")) == "table" and "présent" or "absent")
    local nTiers = S.Get(Resolve("EJ_GetNumTiers"))
    if type(nTiers) ~= "number" then return end
    local names = {}
    for i = 1, nTiers do names[#names + 1] = i .. "=" .. tostring(S.Get(Resolve("EJ_GetTierInfo"), i)) end
    add("%d paliers (courant : %s) : %s", nTiers, tostring(S.Get(Resolve("EJ_GetCurrentTier"))), table.concat(names, ", "))
    for i = 1, 10 do
      local r = { S.GetAll(Resolve("EJ_GetInstanceByIndex"), i, false) }
      if r[1] ~= "lisible" then break end
      add("  instance %d : %s (ID %s)", i, Show(r[3]), Show(r[2]))
    end
  end)

  run("Addons optionnels", function()
    local isLoaded = Resolve("C_AddOns.IsAddOnLoaded")
    for _, name in ipairs({ "Questie", "QuestieDB", "Auctionator" }) do
      local v = S.Get(isLoaded, name)
      add("%s : %s", name, type(isLoaded) ~= "function" and "C_AddOns.IsAddOnLoaded absente"
        or (v == true and "chargé" or "non installé (ou non chargé)"))
    end
    local lib = Resolve("LibQuestieDB")
    if type(lib) ~= "table" then
      add("LibQuestieDB : non installé")
    else
      local ok, res, msg = pcall(lib.RequireContract, 4)
      add("LibQuestieDB : présente | RequireContract(4) : %s", ok and (tostring(res) .. (msg and (" " .. tostring(msg)) or "")) or "erreur")
      local Q, N = lib.Quest, lib.Npc
      if type(Q) == "table" and Q.Get then
        local startedBy = Q.Get(6561, "startedBy")
        add("QuestDB.Get(6561) : name %s | startedBy %s | requiredLevel %s", tostring(Q.Get(6561, "name")),
          Brief(startedBy), tostring(Q.Get(6561, "requiredLevel")))
        local npcs = type(startedBy) == "table" and startedBy[1]
        local npcID = type(npcs) == "table" and npcs[1]
        if npcID and type(N) == "table" and N.Get then add("NpcDB.Get(%s, spawns) : %s", tostring(npcID), Brief(N.Get(npcID, "spawns"))) end
      end
    end
    local price = Resolve("Auctionator.API.v1.GetAuctionPriceByItemID")
    if type(price) ~= "function" then
      add("Auctionator.API.v1.GetAuctionPriceByItemID : %s", Resolve("Auctionator") and "ABSENTE" or "non installé")
    else
      local ok, v = pcall(price, "PretreCoach", 2589)
      add("GetAuctionPriceByItemID(2589, étoffe de lin) : %s", ok and Show(v) or ("erreur : " .. tostring(v)))
    end
  end)
end

------------------------------------------------------------------------
-- rapport
------------------------------------------------------------------------
function ns.Probe()
  local db = ns.db
  db.probe = db.probe or {}
  if InCombatLockdown() then
    StoreCombat(Snapshot())
  else
    db.probe.outside = Snapshot()
  end

  local out = {}
  local function add(fmt, ...) out[#out + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
  local function section(name) add(""); add("== %s ==", name) end

  add("PretreCoach probe %s", date("%Y-%m-%d %H:%M:%S"))
  section("Jeu")
  add("GetBuildInfo : %s", Dump("GetBuildInfo"))
  add("Locale : %s | classe : %s | race : %s | niveau : %s", Dump("GetLocale"), Dump("UnitClass", "player"),
    Dump("UnitRace", "player"), Dump("UnitLevel", "player"))

  section("API (existe ?)")
  local missing = {}
  for _, p in ipairs(APIS) do if type(Resolve(p)) ~= "function" then missing[#missing + 1] = p end end
  add("%d/%d présentes. Absentes : %s", #APIS - #missing, #APIS, #missing > 0 and table.concat(missing, ", ") or "aucune")
  add("INVSLOT_RANGED = %s | INVSLOT_MAINHAND = %s", tostring(INVSLOT_RANGED), tostring(INVSLOT_MAINHAND))

  for _, key in ipairs({ "outside", "combat" }) do
    local snap = db.probe[key]
    section(key == "outside" and "Valeurs hors combat" or "Valeurs en combat")
    if snap then
      add("relevé de %s", snap.when)
      for _, l in ipairs(snap.lines) do add("%s : %s", l[1], l[2]) end
    else
      add(L.PROBE_NEED_COMBAT)
    end
  end

  section("Armes (baguette)")
  for _, slot in ipairs({ 16, 17, 18 }) do add(SlotLine(slot)) end

  section("Déplacement")
  add("GetUnitSpeed : %s | IsPlayerMoving : %s", Dump("GetUnitSpeed", "player"), Dump("IsPlayerMoving"))

  section("Zone")
  local mapID = S.Get(C_Map and C_Map.GetBestMapForUnit, "player")
  local info = mapID and S.Get(C_Map.GetMapInfo, mapID)
  add("uiMapID : %s | nom : %s | GetRealZoneText : %s", tostring(mapID), info and Show(info.name) or "?", Dump("GetRealZoneText"))

  section("Événements (depuis le dernier /reload)")
  for _, ev in ipairs(EVENTS) do
    add("%s : %s, reçu %d fois", ev, reg[ev] and "inscrit" or "REFUSÉ", seen[ev] or 0)
  end
  add("Dernier sort lancé (UNIT_SPELLCAST_SUCCEEDED) : %s", lastCast)
  local lc = db.probe.lastCombatCast
  add("Dernier sort lancé EN COMBAT (spellID lisible ?) : %s", lc and ("%s %s (%s)"):format(tostring(lc.id), tostring(lc.name), tostring(lc.when)) or "aucun")

  section("Talents et double spécialisation")
  add("GetNumSpecGroups : %s | C_SpecializationInfo.GetActiveSpecGroup : %s", Dump("GetNumSpecGroups"), Dump("C_SpecializationInfo.GetActiveSpecGroup"))
  add("GetNumUnspentTalents : %s | C_ClassTalents.HasUnspentTalentPoints : %s", Dump("GetNumUnspentTalents"), Dump("C_ClassTalents.HasUnspentTalentPoints"))
  add("C_ClassTalents.GetActiveConfigID : %s", Dump("C_ClassTalents.GetActiveConfigID"))

  section("Arbre de talents (C_Traits)")
  local okT, errT = pcall(TraitsReport, add)
  if not okT then add("erreur : %s", tostring(errT)) end

  section("API découvertes (legacy / forever / talent / trainer / C_GameRules)")
  local ok, hits = pcall(Discover)
  if ok then for _, h in ipairs(hits) do add(h) end else add("erreur : %s", tostring(hits)) end

  section("Sorts (ID, nom en jeu, connu ?)")
  for _, s in ipairs(SPELLS) do
    add("%d %s -> nom : %s | IsPlayerSpell : %s | IsSpellKnown : %s", s[1], s[2], SpellName(s[1]),
      Dump("IsPlayerSpell", s[1]), Dump("IsSpellKnown", s[1]))
  end
  add("Barres d'action avec Châtiment : %s", Dump("C_ActionBar.FindSpellActionButtons", 585))
  add("Touche ACTIONBUTTON1 : %s", Dump("GetBindingKey", "ACTIONBUTTON1"))

  section("Métiers")
  local PROFS = { [182] = "Herboristerie", [171] = "Alchimie", [129] = "Secourisme" } -- par skillLine
  add("GetProfessions : %s", Dump("GetProfessions"))
  add("GetProfessionInfo rend (nom, icône, niveau, max, nbCapacités, décalage, skillLine, ...) ; skillLine = 7e valeur, à vérifier")
  if GetProfessions then
    local ok, p1, p2, p3, p4, p5 = pcall(GetProfessions)
    local profs = { p1, p2, p3, p4, p5 } -- des trous possibles : on parcourt les 5 index
    for i = 1, 5 do
      local id = profs[i]
      if ok and not S.IsSecret(id) and id then
        local r = { S.GetAll(GetProfessionInfo, id) }
        add("  %s%s", Dump("GetProfessionInfo", id), PROFS[r[8]] and (" <- " .. PROFS[r[8]]) or "")
      end
    end
  end

  section("Quêtes")
  add("Quête %d (Blackfathom Villainy / Gravestone Scepter) terminée : %s", ns.Data.GravestoneQuest,
    Dump("C_QuestLog.IsQuestFlaggedCompleted", ns.Data.GravestoneQuest))

  section("Contrôle des ID de Data/")
  CheckData(add)

  ExtraSections(add, section)

  section("Maître de classe (rempli après une visite)")
  for _, l in ipairs(db.probe.trainer or { "pas encore visité depuis l'installation" }) do add(l) end

  ShowText(table.concat(out, "\n"))
end
