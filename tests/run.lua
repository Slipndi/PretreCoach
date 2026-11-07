-- Usage : luajit tests/run.lua   (depuis n'importe ou). Sans framework : assert + liste d'etapes.
-- La suite tourne deux fois : APIs incertaines presentes (forme Classic), puis absentes.
local root = arg[0]:gsub("\\", "/"):match("^(.*)/tests/[^/]*$") or "."
local print = print -- le mock remplace print
local mock = dofile(root .. "/tests/wowmock.lua")
local failures = {}
local prefix = ""

local function check(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok and #mock.errors == 0 then print("ok   " .. prefix .. name) return end
  failures[#failures + 1] = prefix .. name
  print("FAIL " .. prefix .. name .. "\n" .. (ok and "" or tostring(err) .. "\n") .. table.concat(mock.errors, "\n"))
  mock.errors = {}
end

local ADDON = "PretreCoach"
local files = {}
for line in io.lines(root .. "/" .. ADDON .. "/" .. ADDON .. ".toc") do
  line = line:gsub("\r", "")
  if line ~= "" and not line:find("^#") then files[#files + 1] = line:gsub("\\", "/") end
end

-- Charge l'addon dans l'ordre du .toc, avec un ns neuf.
local function loadAddon()
  local ns = {}
  for _, f in ipairs(files) do
    local chunk = assert(loadfile(root .. "/" .. ADDON .. "/" .. f))
    chunk(ADDON, ns)
  end
  return ns
end

-- Parcours recursif : aucune valeur secrete (cle ou valeur) dans les SavedVariables
local function findSecret(t, path, seen)
  seen = seen or {}
  if mock.isSecret(t) then return path end
  if type(t) ~= "table" or seen[t] then return nil end
  seen[t] = true
  for k, v in next, t do
    local hit = findSecret(k, path .. ".<cle>", seen) or findSecret(v, path .. "." .. tostring(k), seen)
    if hit then return hit end
  end
end

-- Garde-fou par lecture du code : la fausse valeur secrete ne leve rien sur `if v then`, donc on interdit
-- tout appel direct aux API sensibles hors Secrets.lua et Probe.lua (les passer en reference a S.Get reste permis).
local SENSITIVE = { "UnitHealth", "UnitHealthMax", "UnitPower", "UnitPowerMax", "UnitIsDead", "UnitGUID",
  "GetSpellCooldown", "GetPowerRegen" }
local function directCall(line)
  local code = line:gsub("%-%-.*", ""):gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
  for _, n in ipairs(SENSITIVE) do
    if code:find("%f[%w_.]" .. n .. "%s*%(") then return n end
  end
  if code:find("%f[%w_]C_UnitAuras%.[%w_]+%s*%(") then return "C_UnitAuras.*" end
  if code:find("%f[%w_]C_Spell%.GetSpellCooldown%s*%(") then return "C_Spell.GetSpellCooldown" end
end

check("garde-fou : pas d'appel direct aux API secretes", function()
  assert(directCall('local h = UnitHealth("player")') and directCall("x = C_UnitAuras.GetAuraDataByIndex(1)")
    and not directCall("S.Get(UnitHealth, 'player') -- UnitHealth()"), "le detecteur ne marche pas")
  for _, f in ipairs(files) do
    if not f:find("Secrets%.lua$") and not f:find("Probe%.lua$") then
      local n = 0
      for l in io.lines(root .. "/" .. ADDON .. "/" .. f) do
        n = n + 1
        local hit = directCall(l)
        assert(not hit, ("%s:%d appelle %s directement : passer par ns.S.Get"):format(f, n, tostring(hit)))
      end
    end
  end
end)

local function suite(label)
  prefix = label .. " : "
  mock.reset()
  local ns
  check("charge les fichiers du .toc", function()
    assert(#files > 0, "toc vide")
    ns = loadAddon()
  end)

  check("ADDON_LOADED cree PretreCoachDB", function()
    mock.fire("ADDON_LOADED", ADDON)
    assert(type(PretreCoachDB) == "table" and ns.db == PretreCoachDB, "PretreCoachDB absent")
  end)
  check("UI : valeurs par defaut sans ecraser l'existant", function()
    assert(ns.db.show.toasts == true and ns.db.opacity == 0.9 and ns.db.minimap.angle == 220 and ns.db.locked == false)
    local keep = ns.db
    PretreCoachDB = { show = { toasts = false }, opacity = 0.5, locked = true, minimap = { angle = 10 } }
    loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    local d = PretreCoachDB
    assert(d.show.toasts == false and d.show.guide == true and d.opacity == 0.5 and d.locked == true
      and d.minimap.angle == 10 and type(d.frames) == "table", "defauts mal appliques")
    PretreCoachDB = keep
    ns.db = keep
  end)
  check("Toast : affiche, puis bloque avant le delai", function()
    mock.time = 1000
    assert(ns.Toast("Baguette equipee"), "premier toast attendu")
    assert(not ns.Toast("Baguette equipee"), "doublon avant le delai")
    assert(ns.Toast("Autre texte"))
    assert(ns.Toast("Meme cle", { key = "k" }) and not ns.Toast("Autre texte pour k", { key = "k" }))
    mock.time = 1301
    assert(ns.Toast("Baguette equipee"), "apres 300 s le texte revient")
    mock.flushTimers(); mock.flushTimers()
    assert(ns.UI.ToastCount() == 0, "les toasts disparaissent")
  end)
  check("Toast : pile limitee a 3", function()
    mock.time = 5000
    local after = ns.After -- sans C_Timer, After s'execute tout de suite : on force la file du mock
    ns.After = function(d, fn) mock.timers[#mock.timers + 1] = { delay = d, fn = fn } end
    for i = 1, 5 do assert(ns.Toast("pile " .. i)) end
    assert(ns.UI.ToastCount() == 3, "attendu 3, recu " .. ns.UI.ToastCount())
    mock.flushTimers(); mock.flushTimers()
    ns.After = after
  end)
  check("Toast : desactives", function()
    ns.db.show.toasts = false
    assert(not ns.Toast("muet") and ns.UI.ToastCount() == 0)
    ns.db.show.toasts = true
  end)
  check("Movable : sauvegarde et restaure", function()
    local f = CreateFrame("Frame")
    ns.UI.Movable(f, "test", true)
    f:SetPoint("TOP", UIParent, "TOP", 12, -34)
    f.scripts.OnDragStop(f)
    local s = ns.db.frames.test
    assert(s and s.point == "TOP" and s.x == 12 and s.y == -34, "position non sauvegardee")
    f:ClearAllPoints(); f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ns.UI.Restore(f)
    local p, _, _, x, y = f:GetPoint()
    assert(p == "TOP" and x == 12 and y == -34, "position non restauree")
    mock.setCombat(true)
    f:ClearAllPoints(); f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    ns.UI.Restore(f)
    assert(f:GetPoint() == "CENTER", "SetPoint doit attendre la fin du combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(f:GetPoint() == "TOP", "restauration reportee apres le combat")
  end)
  check("Minimap : clic sans ToggleGuide, avec ToggleGuide", function()
    local b = ns.minimapButton
    local real = ns.ToggleGuide
    ns.ToggleGuide = nil
    b.scripts.OnClick(b, "LeftButton"); b.scripts.OnClick(b, "RightButton"); b.scripts.OnEnter(b)
    PretreCoach_OnCompartmentClick("x", "LeftButton")
    local n = 0
    ns.ToggleGuide = function() n = n + 1 end
    b.scripts.OnClick(b, "LeftButton")
    ns.ToggleGuide = nil
    assert(n == 1 and #mock.printed >= 1)
    ns.ToggleGuide = real
  end)
  check("UI.Icon : Pulse, grise, raccourci", function()
    local i = ns.UI.Icon(UIParent, 40)
    i:SetIcon("x"); i:SetHotkey("1"); i:SetGrayed(true); i:Pulse(); mock.flushTimers()
  end)
  check("probe hors combat", function() SlashCmdList.PRETRECOACH("probe") end)
  check("debug et aide", function()
    SlashCmdList.PRETRECOACH("debug"); SlashCmdList.PRETRECOACH("debug"); SlashCmdList.PRETRECOACH("")
  end)
  check("Print avec une valeur secrete ne plante pas", function()
    ns.Print("vie %s", mock.SECRET)
    ns.Print("%d%%", "pas un nombre")
    assert(mock.printed[#mock.printed]:find("%%d%%%%", 1), "texte du format seul attendu")
  end)
  check("TRAINER_SHOW", function()
    mock.fire("TRAINER_SHOW")
    assert(PretreCoachDB.probe.trainer, "releve du maitre absent")
  end)
  check("OnUnit : RegisterUnitEvent filtre l'unite", function()
    local n = 0
    assert(ns.OnUnit("UNIT_AURA", "player", function() n = n + 1 end))
    mock.fire("UNIT_AURA", "player"); mock.fire("UNIT_AURA", "target")
    assert(n == 1, "attendu 1 appel, recu " .. n)
  end)
  check("OnUnit : repli sans RegisterUnitEvent", function()
    local n = 0
    mock.noRegisterUnitEvent = true
    local ok = ns.OnUnit("UNIT_POWER_UPDATE", "player", function() n = n + 1 end)
    mock.noRegisterUnitEvent = false
    assert(ok, "inscription refusee")
    mock.fire("UNIT_POWER_UPDATE", "player"); mock.fire("UNIT_POWER_UPDATE", "target")
    assert(n == 1, "attendu 1 appel, recu " .. n)
  end)
  check("probe en combat", function()
    mock.setCombat(true)
    mock.fire("PLAYER_REGEN_DISABLED")
    mock.flushTimers()
    SlashCmdList.PRETRECOACH("probe")
    assert(PretreCoachDB.probe.combat, "releve en combat absent")
    assert(ns.probeAnnounced, "message d'annonce non affiche")
  end)
  check("probe en combat sans cible n'ecrase pas un releve avec cible", function()
    local kept = PretreCoachDB.probe.combat
    assert(kept.target, "releve de depart sans cible")
    mock.hasTarget = false
    SlashCmdList.PRETRECOACH("probe")
    mock.hasTarget = true
    assert(PretreCoachDB.probe.combat == kept, "releve ecrase")
  end)
  check("lastCombatCast : secret puis lisible, hors combat sans effet", function()
    mock.setCombat(true)
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", mock.noSecrets and 585 or mock.SECRET)
    local lc = PretreCoachDB.probe.lastCombatCast
    assert(lc and lc.id == (mock.noSecrets and 585 or "SECRET"), "id secret mal memorise")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 589)
    lc = PretreCoachDB.probe.lastCombatCast
    assert(lc.id == 589, "id lisible non memorise")
    assert(mock.noSecrets or lc.name == "Sort589", "nom attendu : " .. tostring(lc.name))
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "target", "cast", 1)
    mock.setCombat(false)
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast", 17)
    assert(PretreCoachDB.probe.lastCombatCast.id == 589, "le hors-combat a ecrase lastCombatCast")
    SlashCmdList.PRETRECOACH("probe")
    assert(mock.lastText:find("EN COMBAT") and mock.lastText:find("589"), "rapport sans le dernier sort en combat")
  end)
  check("controle des ID de Data/ : section, resumes, ligne pour un ID muet", function()
    mock.unknown = { spell = { [594] = true }, item = { [1251] = true }, map = { [1413] = true } }
    SlashCmdList.PRETRECOACH("probe")
    local t = mock.lastText
    assert(t:find("== Contrôle des ID de Data/ ==", 1, true), "section absente")
    for _, c in ipairs({ "Sorts", "Objets", "Cartes", "Quêtes", "Métiers" }) do
      assert(t:find(c .. " : ", 1, true) and (t:find(c .. " : %d+/%d+ OK") or t:find(c .. " : non vérifiable", 1, true)),
        "resume absent : " .. c)
    end
    assert(t:find("594 SWP : ne répond pas", 1, true), "ligne du sort muet absente")
    assert(t:find("1251 Bandage en lin : ne répond pas", 1, true), "ligne de l'objet muet absente")
    assert(mock.noSecrets or t:find("1413 ", 1, true) and t:find("ne répond pas", 1, true), "ligne de la carte muette absente")
    assert(not t:find("585 SMITE : ne répond pas", 1, true), "un ID qui repond est liste")
    mock.unknown = {}
  end)
  check("coherence des donnees de Data/", function()
    local ns3 = loadAddon() -- chaque fichier du .toc se charge ; Data/ y compris
    local D = ns3.Data
    for _, name in ipairs({ "Zones", "Dungeons", "Spells", "Wands", "Professions", "Milestones" }) do
      assert(type(D[name]) == "table", "Data." .. name .. " absent")
    end
    local keys = {}
    for _, s in ipairs(D.Spells) do
      assert(not keys[s.key], "cle de sort en double : " .. tostring(s.key))
      keys[s.key] = true
      local last
      for _, r in ipairs(s.ranks) do
        if r.level and last then assert(r.level >= last, "rangs non tries : " .. s.key) end
        if r.level then last = r.level end
      end
    end
    for id, z in pairs(D.Zones) do assert(z[1] <= z[2], "plage Zones inversee : " .. id) end
    for _, d in ipairs(D.Dungeons) do assert(d.min <= d.max, "plage Dungeons inversee : " .. d.key) end
  end)
  check("aucune valeur secrete en SavedVariables", function()
    local hit = findSecret(PretreCoachDB, "PretreCoachDB")
    assert(not hit, "valeur secrete stockee a " .. tostring(hit))
  end)
  check("evenement refuse (TRAINER_SHOW) : REFUSE sans planter", function()
    mock.reset()
    mock.rejectEvents = { TRAINER_SHOW = true }
    local ns2 = loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    SlashCmdList.PRETRECOACH("probe")
    assert(ns2.db and mock.lastText:find("TRAINER_SHOW : REFUS"), "REFUSE absent du rapport")
    assert(mock.lastText:find("PLAYER_LEVEL_UP : inscrit"), "les autres evenements doivent rester inscrits")
  end)

  -- L4a : Calc, State, Timers (addon neuf, mock remis a zero)
  mock.reset()
  local N = loadAddon()
  mock.fire("ADDON_LOADED", ADDON)
  local C, D = N.Calc, N.Data

  check("Calc.Tier", function()
    assert(C.Tier(nil) == nil and C.Tier(1) == "1-10" and C.Tier(4) == "1-10" and C.Tier(5) == "1-10")
    assert(C.Tier(10) == "10-20" and C.Tier(40) == "40-50" and C.Tier(59) == "50-60" and C.Tier(60) == "50-60")
  end)

  check("Calc.ZoneStatus", function()
    local z = { 10, 20, "x" }
    assert(C.ZoneStatus(9, z) == "haute" and C.ZoneStatus(10, z) == "adaptee" and C.ZoneStatus(19, z) == "adaptee")
    assert(C.ZoneStatus(20, z) == "bientot" and C.ZoneStatus(21, z) == "verte")
    assert(C.ZoneStatus(nil, z) == "neutre" and C.ZoneStatus(15, nil) == "neutre")
    local st, nxt = C.ZoneStatus(25, D.Zones[1420])
    assert(st == "verte" and nxt[1] == 1424, "etape suivante attendue : 1424")
    st, nxt = C.ZoneStatus(10, D.Zones[1420])
    assert(st == "bientot" and nxt[1] == 1421)
    st, nxt = C.ZoneStatus(60, D.Zones[1452])
    assert(st == "bientot" and nxt == nil, "fin du parcours")
  end)

  check("Calc.WandStatus", function()
    assert(C.WandStatus(4, false) == "ok" and C.WandStatus(5, false) == "aucune" and C.WandStatus(5, {}) == "aucune")
    local st, nxt = C.WandStatus(5, false)
    assert(nxt.level == 5)
    assert(C.WandStatus(20, { itemID = 1, reqLevel = 10 }) == "depassee" and C.WandStatus(19, { itemID = 1, reqLevel = 10 }) == "ok")
    st, nxt = C.WandStatus(20, { itemID = 1, reqLevel = 10 })
    assert(nxt.level == 18, "prochaine baguette : niveau 18")
    -- limites : reqLevel 0, niveaux 10 et 60 ; depassee sans meilleure baguette connue = ok
    st, nxt = C.WandStatus(10, { itemID = 1, reqLevel = 0 })
    assert(st == "depassee" and nxt.level == 5, "reqLevel 0, niveau 10")
    st, nxt = C.WandStatus(60, { itemID = 1, reqLevel = 0 })
    assert(st == "depassee" and nxt.level == 18, "niveau 60 : la meilleure, quel que soit l'ordre")
    st, nxt = C.WandStatus(60, { itemID = 1, reqLevel = 50 })
    assert(st == "ok" and nxt == nil, "rien de mieux a conseiller")
    assert(C.WandStatus(10, { itemID = 1, reqLevel = 1 }) == "ok", "req 1 niveau 10 : pas encore depassee")
    assert(C.WandStatus(20, { itemID = 1 }) == "inconnue" and C.WandStatus(10, nil) == "inconnue" and C.WandStatus(nil, false) == "inconnue")
  end)

  check("Calc.PendingSpells", function()
    local none = function() return 0 end
    local function has(list, key) for _, p in ipairs(list) do if p.key == key then return p end end end
    local p4 = C.PendingSpells(4, none)
    assert(has(p4, "SWP").rankIndex == 1 and has(p4, "SWP").level == 4 and not has(p4, "PWS"), "niveau 4")
    local p60 = C.PendingSpells(60, function(k) return k == "SWP" and 8 or 0 end)
    assert(not has(p60, "SWP") and has(p60, "SMITE").rankIndex == 8, "seul le plus haut rang")
    assert(not has(p60, "MINDFLAY") and not has(p60, "HOLYNOVA") and not has(p60, "PENANCE"), "talents / rang sans niveau exclus")
    local seen = {}
    for _, p in ipairs(p60) do assert(not seen[p.key], "doublon " .. p.key) seen[p.key] = true end
    assert(#C.PendingSpells(nil, none) == 0 and C.PendingSpells(10, function() return nil end) == nil, "level nil / inconnu")
    assert(C.PendingSpells(10, nil) == nil, "API absente = inconnu")
    assert(#C.PendingSpells(10, none) > 0 and #C.PendingSpells(1, function() return 1 end) == 0, "{} : rien a apprendre")
  end)

  check("Calc.TalentGap", function()
    local plan = D.TalentPlan
    assert(C.TalentGap(12, nil, plan) == nil, "talents nil = inconnu")
    local gap = C.TalentGap(12, {}, plan)
    assert(#gap == 1 and gap[1].entry.name == "Connexion spirituelle" and gap[1].have == 0 and gap[1].want == 5)
    assert(#C.TalentGap(12, { [3] = { [1] = { [3] = 5 } } }, plan) == 0)
    assert(#C.TalentGap(40, {}, plan) == 1, "respec ignore, Forme d'Ombre attendue")
    assert(#C.TalentGap(nil, {}, plan) == 0)
  end)

  check("Calc.ProfessionTodo", function()
    local profs = { [182] = { rank = 60, max = 75 }, [129] = { rank = 50, max = 75 } }
    local todo, bandage, missing = C.ProfessionTodo(10, profs, D.Professions)
    assert(#todo == 2 and todo[1].skillLine == 129 and todo[1].rank.name == "Compagnon", "rang Compagnon")
    assert(bandage.name == "Bandage en lin épais", "bandage : " .. tostring(bandage and bandage.name))
    assert(#missing == 1 and missing[1] == 171, "alchimie manquante")
    assert(#C.ProfessionTodo(9, profs, D.Professions) == 0, "niveau trop bas")
    assert(#C.ProfessionTodo(10, { [182] = { rank = 40, max = 75 } }, D.Professions) == 0, "competence trop basse")
    assert(#C.ProfessionTodo(10, { [182] = { rank = 75, max = 150 } }, D.Professions) == 0, "rang deja pris")
    assert(C.ProfessionTodo(10, nil, D.Professions) == nil and C.ProfessionTodo(nil, profs, D.Professions) == nil)
  end)

  local msgs = {}
  N.Listen("STATE", function(_, changed) msgs[#msgs + 1] = table.concat(changed, ",") end)
  local timerMsgs = 0
  N.Listen("TIMERS", function() timerMsgs = timerMsgs + 1 end)
  local St = N.State

  check("State : rafraichi sur PLAYER_LOGIN", function()
    mock.talentList = { [3] = { { 1, 3, 5 } } }
    mock.fire("PLAYER_LOGIN")
    mock.flushTimers()
    assert(St.level == 12, "niveau")
    assert(C_Map and (St.mapID == 1 and St.zone == 1420) or (St.mapID == nil and St.zone == nil), "zone (chaine parentMapID)")
    assert(#msgs == 1 and msgs[1]:find("level", 1, true), "message STATE attendu")
    if GetNumTalentTabs then
      assert(St.talents[3][1][3] == 5 and St.unspentTalents == 0 and St.specGroups == 1 and St.wand == false)
      assert(St.profs[182].rank == 100 and St.profs[171].max == 300, "metiers")
    else
      assert(St.talents == nil and St.unspentTalents == nil and St.specGroups == nil and St.profs == nil and St.wand == nil)
    end
    local n = #msgs
    mock.fire("SPELLS_CHANGED"); mock.fire("LEARNED_SPELL_IN_TAB"); mock.flushTimers()
    -- sans minuteur, ns.After est immediat : un STATE par evenement
    local k = C_Timer and 1 or 2
    assert(#msgs == n + k and msgs[#msgs] == "spells", "STATE { spells } groupe par le delai")
    mock.fire("PLAYER_EQUIPMENT_CHANGED"); mock.flushTimers()
    assert(#msgs == n + k, "rien de change : pas de message")
  end)

  check("State : baguette, cache et GET_ITEM_INFO_RECEIVED", function()
    if not GetInventoryItemID then return end
    mock.rangedID, mock.uncached = 11287, true
    mock.fire("PLAYER_EQUIPMENT_CHANGED"); mock.flushTimers()
    assert(St.wand.itemID == 11287 and St.wand.reqLevel == nil, "baguette hors cache")
    mock.uncached = false
    mock.fire("GET_ITEM_INFO_RECEIVED", 999, true); mock.flushTimers()
    assert(St.wand.reqLevel == nil, "autre objet : pas de relecture")
    mock.fire("GET_ITEM_INFO_RECEIVED", 11287, true); mock.flushTimers()
    assert(St.wand.reqLevel == 5 and St.wand.name == "Baguette 11287")
    mock.rangedID = 12345 -- un arc, pas une baguette
    mock.fire("PLAYER_EQUIPMENT_CHANGED"); mock.flushTimers()
    assert(St.wand == false)
  end)

  check("State : GET_ITEM_INFO_RECEIVED en echec, autre objet, plafond de 3 essais", function()
    if not GetInventoryItemID then return end
    local calls, orig = 0, C_Item.GetItemInfoInstant
    C_Item.GetItemInfoInstant = function(id) calls = calls + 1 return orig(id) end
    mock.rangedID, mock.uncached = 11287, true
    mock.fire("PLAYER_EQUIPMENT_CHANGED"); mock.flushTimers()
    local base = calls
    mock.fire("GET_ITEM_INFO_RECEIVED", 11287, false); mock.flushTimers()
    mock.fire("GET_ITEM_INFO_RECEIVED", 999, true); mock.flushTimers()
    assert(calls == base, "echec ou autre objet : pas de relecture")
    for _ = 1, 6 do mock.fire("GET_ITEM_INFO_RECEIVED", 11287, true); mock.flushTimers() end
    local n = calls - base
    C_Item.GetItemInfoInstant = orig
    mock.uncached, mock.rangedID = false, nil
    mock.fire("PLAYER_EQUIPMENT_CHANGED"); mock.flushTimers()
    assert(n == 3, "plafond de 3 essais, recu " .. n)
  end)

  check("State : rafale de 6 evenements = un seul rafraichissement", function()
    if not C_Timer then return end -- sans minuteur, ns.After s'execute tout de suite
    local n, orig = 0, C_Map.GetBestMapForUnit
    C_Map.GetBestMapForUnit = function(...) n = n + 1 return orig(...) end
    for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "SKILL_LINES_CHANGED",
      "PLAYER_TALENT_UPDATE", "PLAYER_EQUIPMENT_CHANGED" }) do mock.fire(e) end
    assert(n == 0, "rien avant le delai")
    mock.flushTimers()
    C_Map.GetBestMapForUnit = orig
    assert(n == 1, "un seul rafraichissement attendu, recu " .. n)
  end)

  check("State : QUEST_TURNED_IN ne relit rien, annonce quests", function()
    local n = #msgs
    mock.fire("QUEST_TURNED_IN", 1)
    assert(#msgs == n + 1 and msgs[#msgs] == "quests")
  end)

  check("State : talents illisibles = nil (pas de table partielle), ancienne valeur gardee", function()
    if not GetTalentInfo then return end
    local gt, sentinel = GetTalentInfo, { [1] = {} }
    GetTalentInfo = function() error("boom") end
    St.talents = nil
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.talents == nil and C.TalentGap(12, St.talents, D.TalentPlan) == nil, "talents inconnus")
    St.talents = sentinel
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.talents == sentinel, "lecture ratee : valeur precedente gardee")
    GetTalentInfo = gt
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.talents ~= sentinel and St.talents[3][1][3] == 5)
  end)

  check("State : PLAYER_LEVEL_UP en combat, rafraichi a la sortie", function()
    local n = #msgs
    mock.setCombat(true)
    mock.fire("PLAYER_LEVEL_UP", 13)
    assert(St.level == 12 and #msgs == n, "rien de lourd en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    mock.flushTimers()
    assert(St.level == 13 and #msgs == n + 1, "niveau de l'evenement apres le combat")
    mock.fire("PLAYER_REGEN_ENABLED") -- pas sale : rien
    assert(#msgs == n + 1)
  end)

  check("State : repli des metiers par GetSkillLineInfo", function()
    if not GetProfessions then return end
    local gp, gs = GetProfessions, GetSkillLineInfo
    GetProfessions = nil
    GetSkillLineInfo = function() return "Herboristerie", false, 0, 120, 0, 0, 300 end
    mock.fire("SKILL_LINES_CHANGED"); mock.flushTimers()
    GetProfessions, GetSkillLineInfo = gp, gs
    assert(St.profs[182].rank == 120 and St.profs[182].max == 300)
  end)

  check("State : QuestDone et Knows", function()
    if C_QuestLog then assert(St.QuestDone(1) == false) else assert(St.QuestDone(1) == nil) end
    assert(St.Knows("NOPE") == nil)
    if not IsPlayerSpell and not IsSpellKnown and not C_SpellBook then
      assert(St.Knows("SWP") == nil, "API absente = inconnu")
      assert(C.PendingSpells(60, St.Knows) == nil, "tout inconnu : nil")
      return
    end
    assert(St.Knows("SWP") == 8)
    mock.known = { [594] = true }
    assert(St.Knows("SWP") == 8, "cache : pas de relecture avant SPELLS_CHANGED")
    mock.fire("SPELLS_CHANGED")
    assert(St.Knows("SWP") == 2)
    mock.known = {}
    mock.fire("LEARNED_SPELL_IN_TAB")
    assert(St.Knows("SWP") == 0)
    mock.known = { [594] = true }
    mock.fire("PLAYER_LEVEL_UP", 13); mock.flushTimers()
    assert(St.Knows("SWP") == 2, "PLAYER_LEVEL_UP invalide le cache")
    mock.known = nil
    mock.fire("SPELLS_CHANGED")
  end)

  check("State : Knows ignore un rang sans nom (SWD), IsPlayerSpell qui plante", function()
    if not IsPlayerSpell and not IsSpellKnown and not C_SpellBook then return end
    local function has(list, key) for _, p in ipairs(list) do if p.key == key then return true end end end
    mock.known = {}
    mock.unknown = { spell = { [32379] = true } }
    mock.fire("SPELLS_CHANGED")
    assert(St.Knows("SWD") == nil, "ID sans nom = inconnu")
    assert(not has(C.PendingSpells(60, St.Knows), "SWD"), "jamais a apprendre sans pouvoir l'etre")
    mock.unknown = {}
    mock.fire("SPELLS_CHANGED")
    assert(St.Knows("SWD") == 0 and has(C.PendingSpells(60, St.Knows), "SWD"), "ID nomme : a apprendre")
    mock.known = nil
    local ips, isk = IsPlayerSpell, IsSpellKnown
    IsPlayerSpell = function() error("boom") end
    mock.fire("SPELLS_CHANGED")
    assert(St.Knows("SWP") == nil, "API qui plante = inconnu, sans erreur")
    IsPlayerSpell, IsSpellKnown = ips, isk
    mock.fire("SPELLS_CHANGED")
  end)

  check("Timers : regle des 5 s, recharge, Douleur par cible", function()
    local T = N.Timers
    mock.time = 100
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585) -- Chatiment
    assert(T.FiveSecRemaining() == 5 and timerMsgs > 0)
    mock.time = 102
    assert(T.FiveSecRemaining() == 3)
    mock.time = 106
    assert(T.FiveSecRemaining() == 0)

    mock.time = 400
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 8092) -- Attaque mentale, recharge 8
    mock.time = 405
    assert(T.CooldownRemaining("MINDBLAST") == 3 and T.CooldownRemaining("SMITE") == 0)
    mock.time = 409
    assert(T.CooldownRemaining("MINDBLAST") == 0, "recharge expiree")

    mock.time, mock.guid = 200, "A"
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    assert(T.HasSWP() and T.SWPCount() == 1 and T.LastCastOn("A") == "SWP")
    mock.guid, mock.time = "B", 205
    assert(not T.HasSWP(), "autre cible")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    assert(T.SWPCount() == 2 and T.HasSWP())
    mock.time = 219 -- la Douleur de A (fin 218) est finie, celle de B (fin 223) court
    assert(T.SWPCount() == 1 and T.HasSWP() and T.LastCastOn("A") == "SWP")
    mock.guid = "A"
    assert(not T.HasSWP())
    mock.time = 240
    assert(T.SWPCount() == 0 and T.LastCastOn("A") == nil, "tout expire")
  end)

  check("Timers : GUID illisible, repli sur la cible actuelle", function()
    local T = N.Timers
    mock.noGuid, mock.time = true, 300
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    assert(T.HasSWP() and T.SWPCount() == 1)
    mock.fire("PLAYER_TARGET_CHANGED")
    assert(not T.HasSWP() and T.SWPCount() == 0)
    mock.noGuid = false
  end)

  check("Timers : mode degrade puis cast lisible", function()
    local T = N.Timers
    mock.time = 500
    local before = timerMsgs
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "illisible" or mock.SECRET)
    assert(T.degraded and timerMsgs == before + 1, "TIMERS a la bascule")
    assert(T.FiveSecRemaining() == nil and T.CooldownRemaining("SMITE") == nil and T.HasSWP() == nil
      and T.SWPCount() == nil, "inconnu pendant le mode degrade")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
    assert(T.degraded == false and T.FiveSecRemaining() == 5 and T.SWPCount() == 0, "retour a la normale")
  end)

  check("Timers : Tir garde lastNonShoot et ne relance TIMERS qu'au premier", function()
    local T = N.Timers
    mock.time, mock.guid = 600, "S"
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
    local n = timerMsgs
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 5019)
    assert(timerMsgs == n + 1, "premier Tir : TIMERS")
    local k, t, nk = T.LastCastOn("S")
    assert(k == "SHOOT" and t == 600 and nk == "SMITE", "lastNonShoot conserve")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 5019)
    assert(timerMsgs == n + 1, "Tir repete : pas de TIMERS")
    k, t, nk = T.LastCastOn("S")
    assert(k == "SHOOT" and nk == "SMITE")
  end)

  check("Timers : sort sur soi ou cible non attaquable ne touche pas la cible", function()
    local T = N.Timers
    mock.time, mock.guid = 620, "S"
    local k0, t0, nk0 = T.LastCastOn("S")
    mock.time, mock.canAttack = 621, false
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 17) -- Bouclier
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589) -- Douleur sur un allie
    mock.canAttack = nil
    local k, t, nk = T.LastCastOn("S")
    assert(k == k0 and t == t0 and nk == nk0, "lastOn inchange")
    assert(not T.HasSWP() and T.SWPCount() == 0, "pas de Douleur posee")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 17)
    assert(T.LastCastOn("S") == k0, "un Bouclier ne pose rien meme sur cible attaquable")
  end)

  check("Timers : UnitCanAttack absente = cible attaquable", function()
    local T = N.Timers
    local saved = UnitCanAttack
    UnitCanAttack = nil
    mock.time, mock.guid = 640, "NOCA"
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589) -- Douleur
    UnitCanAttack = saved
    assert(T.LastCastOn("NOCA") == "SWP", "sort offensif suivi sans UnitCanAttack")
    mock.time, mock.guid = 641, "NOCA2"
    mock.canAttack = false
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    mock.canAttack = nil
    assert(T.LastCastOn("NOCA2") == nil, "UnitCanAttack present et faux : cible exclue")
  end)

  check("Timers : cible morte, changement de cible, mort du joueur", function()
    local T = N.Timers
    mock.time, mock.guid = 700, "D"
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    assert(T.HasSWP() == true)
    mock.dead = true
    assert(T.HasSWP() == false and T.SWPCount() == 0, "cible morte : Douleur effacee")
    mock.dead = nil
    assert(T.HasSWP() == false, "effacee pour de bon")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    mock.dead = true
    mock.fire("PLAYER_TARGET_CHANGED")
    mock.dead = nil
    assert(T.HasSWP() == false, "changement vers un GUID mort")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 8092)
    assert(T.SWPCount() == 1 and T.CooldownRemaining("MINDBLAST") == 8 and T.LastCastOn("D") == "MINDBLAST")
    mock.fire("PLAYER_DEAD")
    assert(T.SWPCount() == 0 and T.CooldownRemaining("MINDBLAST") == 0 and T.LastCastOn("D") == nil, "remise a zero")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    mock.fire("PLAYER_ENTERING_WORLD")
    assert(T.SWPCount() == 0, "remise a zero a l'entree dans le monde")
  end)

  check("Timers : spellID secret ou illisible = mode degrade", function()
    local T = N.Timers
    assert(T.degraded == false)
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 99999) -- hors donnees : ignore
    assert(T.degraded == false, "un sort hors donnees n'est pas un echec")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "illisible" or mock.SECRET)
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", nil)
    assert(T.degraded == true)
  end)

  check("State et Timers : aucune valeur secrete stockee", function()
    mock.setCombat(true)
    mock.fire("PLAYER_REGEN_DISABLED")
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "illisible" or mock.SECRET)
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(not findSecret(PretreCoachDB, "PretreCoachDB") and not findSecret(St, "State"))
  end)

  -- Guide : un ns neuf par scenario, ses fonctions lisent State a la main (pas d'evenement du jeu).
  local FIELDS = { "level", "mapID", "zone", "wand", "talents", "unspentTalents", "specGroups", "profs" }
  local function fresh(db)
    local n = loadAddon()
    n.db = db or { show = { toasts = true }, guide = { manual = {}, done = {} } }
    local out = { n = n, toasts = {}, gui = 0 }
    -- les toasts des regles d'or (cle "r<n>...") vont dans out.rtoasts : les tests du guide ne comptent que les leurs
    out.rtoasts = {}
    n.Toast = function(text, opts)
      local key = opts and opts.key
      local list = (key and key:find("^r%d")) and out.rtoasts or out.toasts
      list[#list + 1] = { text = text, key = key, cooldown = opts and opts.cooldown }
      return true
    end
    n.Listen("GUIDE", function() out.gui = out.gui + 1 end)
    return out
  end
  local function setState(n, t) for _, k in ipairs(FIELDS) do n.State[k] = t[k] end end
  local function ev(n, id) for _, e in ipairs(n.Guide.Evaluate()) do if e.id == id then return e end end end
  local function st(e) return not e and "absent" or e.unknown and "unknown" or e.done and "done" or "todo" end
  -- change les sorts connus du mock et invalide le cache de Knows (SPELLS_CHANGED atteint tous les ns charges)
  local function knows(ids) mock.known = ids mock.fire("SPELLS_CHANGED") mock.flushTimers() end

  check("Guide : checks prof, profRank, wand, wandItem", function()
    local n = fresh().n
    setState(n, { level = 5 })
    assert(st(ev(n, "learn_prof")) == "unknown" and st(ev(n, "wand_equip")) == "unknown")
    n.State.profs, n.State.wand = {}, false
    assert(st(ev(n, "learn_prof")) == "todo" and st(ev(n, "wand_equip")) == "todo")
    n.State.profs, n.State.wand = { [182] = { rank = 1, max = 75 }, [171] = { rank = 1, max = 75 } }, { itemID = 11287 }
    assert(st(ev(n, "learn_prof")) == "done" and st(ev(n, "wand_equip")) == "done")
    n.State.profs = { [182] = { rank = 1, max = 75 } }
    assert(st(ev(n, "learn_prof")) == "todo", "une seule profession")
    n.State.level, n.State.profs = 12, nil
    assert(st(ev(n, "rank_comp")) == "unknown")
    n.State.profs = { [182] = { rank = 100, max = 150 }, [171] = { rank = 10, max = 75 } }
    assert(st(ev(n, "rank_comp")) == "todo")
    n.State.profs[171].max = 150
    assert(st(ev(n, "rank_comp")) == "done")
    n.State.level, n.State.wand = 14, nil
    assert(st(ev(n, "wand_sup")) == "unknown")
    n.State.wand = false
    assert(st(ev(n, "wand_sup")) == "todo")
    n.State.wand = { itemID = 11287, reqLevel = 5 }
    assert(st(ev(n, "wand_sup")) == "todo", "baguette inferieure")
    n.State.wand = { itemID = 11287 }
    assert(st(ev(n, "wand_sup")) == "unknown", "niveau requis illisible")
    n.State.wand = { itemID = 11288 }
    assert(st(ev(n, "wand_sup")) == "done")
    n.State.wand = { itemID = 7001, reqLevel = 18 }
    assert(st(ev(n, "wand_sup")) == "done", "baguette au moins aussi haute")
  end)

  check("Guide : checks talent, specGroups, herbZone", function()
    local n = fresh().n
    setState(n, { level = 12 })
    assert(st(ev(n, "spirittap")) == "unknown")
    n.State.talents = {}
    assert(st(ev(n, "spirittap")) == "todo")
    n.State.talents = { [3] = { [1] = { [3] = 4 } } }
    assert(st(ev(n, "spirittap")) == "todo")
    n.State.talents[3][1][3] = 5
    assert(st(ev(n, "spirittap")) == "done")
    n.State.level, n.State.talents = 41, { [1] = { [1] = { [2] = 2 } } }
    assert(st(ev(n, "wandspec2")) == "done" and ev(n, "wandspec") == nil, "plan de 41+ : meme position")
    n.State.talents = {}
    assert(st(ev(n, "wandspec2")) == "todo")
    assert(st(ev(n, "dualspec")) == "unknown")
    n.State.specGroups = 1
    assert(st(ev(n, "dualspec")) == "todo")
    n.State.specGroups = 2
    assert(st(ev(n, "dualspec")) == "done")
    n.State.level = 12
    assert(st(ev(n, "herb_zone")) == "unknown")
    n.State.mapID, n.State.zone, n.State.profs = 1, 1421, {}
    assert(st(ev(n, "herb_zone")) == "todo", "herboristerie non apprise")
    n.State.profs = { [182] = { rank = 50, max = 75 } }
    assert(st(ev(n, "herb_zone")) == "todo", "herbes de la zone trop hautes")
    n.State.profs[182].rank = 80
    assert(st(ev(n, "herb_zone")) == "done")
    n.State.zone = nil
    assert(st(ev(n, "herb_zone")) == "done", "zone sans herbes listees")
  end)

  check("Guide : checks spells, known, quest, items", function()
    local n = fresh().n
    setState(n, { level = 32 })
    local anyApi = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)
    local swd, div
    for _, sp in ipairs(n.Data.Spells) do
      if sp.key == "SWD" then swd = sp end
      if sp.key == "DIVSPIRIT" then div = sp end
    end
    if anyApi then
      knows({})
      assert(st(ev(n, "spells")) == "todo" and st(ev(n, "divspirit")) == "todo" and st(ev(n, "swd")) == "todo")
      knows({ [swd.ranks[1].id] = true })
      assert(st(ev(n, "swd")) == "done")
      knows(nil)
      assert(st(ev(n, "spells")) == "done", "tout connu : rien a apprendre")
      knows({ [div.ranks[1].id] = true })
      assert(st(ev(n, "divspirit")) == "done")
      knows(nil)
    else
      assert(st(ev(n, "spells")) == "unknown" and st(ev(n, "swd")) == "unknown")
    end
    -- quete 6561 : visible de 24 a 32
    if C_QuestLog then
      assert(st(ev(n, "bfd_quest")) == "todo")
      local orig = C_QuestLog.IsQuestFlaggedCompleted
      C_QuestLog.IsQuestFlaggedCompleted = function(id) return id == 6561 end
      assert(st(ev(n, "bfd_quest")) == "done")
      C_QuestLog.IsQuestFlaggedCompleted = orig
    else
      assert(st(ev(n, "bfd_quest")) == "unknown")
    end
    n.State.level = 12
    if GetItemCount then
      mock.items = {}
      assert(st(ev(n, "bandages")) == "todo")
      mock.items = { [1251] = 6, [2581] = 4 } -- bandages de Data/Professions.lua
      assert(st(ev(n, "bandages")) == "done")
      mock.items = nil
    else
      assert(st(ev(n, "bandages")) == "unknown")
    end
  end)

  check("Guide : manuel, inconnu cochable et memorise", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 12 })
    local e = ev(n, "legacy_toa")
    assert(e.unknown and e.manual and not e.done, "check manual : inconnu")
    assert(n.Guide.SetManual("legacy_toa", true) and o.gui == 1)
    e = ev(n, "legacy_toa")
    assert(e.done and e.manual and not e.unknown and n.db.guide.manual.legacy_toa == true)
    assert(#o.toasts == 0, "pas de toast pour une case cochee")
    -- un objectif dont l'API ne repond pas se coche aussi
    n.State.level, n.State.profs = 6, nil
    assert(st(ev(n, "learn_prof")) == "unknown")
    assert(n.Guide.SetManual("learn_prof", true) and ev(n, "learn_prof").done)
    -- memorise : un autre chargement avec la meme base
    local again = fresh(n.db).n
    setState(again, { level = 12 })
    assert(ev(again, "legacy_toa").done, "memorise dans ns.db.guide.manual")
    n.State.level = 12
    assert(n.Guide.SetManual("legacy_toa", false) and st(ev(n, "legacy_toa")) == "unknown" and n.db.guide.manual.legacy_toa == nil)
    assert(not n.Guide.SetManual("inconnu", true))
    assert(not findSecret(n.db, "db"))
  end)

  check("Guide : toast unique, rien au premier chargement, rien si deja fait", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 12, talents = { [3] = { [1] = { [3] = 3 } } } })
    n.Fire("STATE", { "level" })
    assert(#o.toasts == 0 and o.gui == 0, "premiere evaluation : silence")
    n.State.talents[3][1][3] = 5
    n.Fire("STATE", { "talents" })
    assert(#o.toasts == 1 and o.gui == 1, "un seul toast, recu " .. #o.toasts)
    assert(o.toasts[1].text == "Connexion spirituelle 5/5 : bien joué" and o.toasts[1].key == "obj:spirittap")
    assert(n.db.guide.done.spirittap == true, "id fait memorise")
    n.Fire("STATE", { "talents" })
    assert(#o.toasts == 1 and o.gui == 1, "pas de doublon")
    n.State.talents[3][1][3] = 4; n.Fire("STATE", {})
    n.State.talents[3][1][3] = 5; n.Fire("STATE", {})
    assert(#o.toasts == 1, "deja annonce : memorise")
    local o2 = fresh(n.db) -- rechargement : objectif deja fait, aucune annonce
    setState(o2.n, { level = 12, talents = { [3] = { [1] = { [3] = 5 } } } })
    o2.n.Fire("STATE", {})
    assert(#o2.toasts == 0 and o2.gui == 0)
    local o3 = fresh() -- base neuve mais objectif deja fait au premier passage
    setState(o3.n, { level = 12, talents = { [3] = { [1] = { [3] = 5 } } } })
    o3.n.Fire("STATE", {})
    assert(#o3.toasts == 0 and o3.n.db.guide.done.spirittap == true)
  end)

  check("Guide : toast de palier avec les 3 priorites, report en combat", function()
    local o = fresh()
    local n = o.n
    knows({})
    setState(n, { level = 39, specGroups = 1, talents = {} })
    n.Fire("STATE", { "level" })
    assert(#o.toasts == 0, "premier chargement : silence")
    n.State.level = 41
    n.Fire("STATE", { "level" })
    assert(#o.toasts == 1 and o.gui == 1, "un toast de palier, recu " .. #o.toasts)
    local t = o.toasts[1]
    assert(t.key == "tier:40-50" and t.text:find("^Nouveau palier : 40%-50"), t.text)
    local lines = 0
    for _ in t.text:gmatch("\n%- ([^\n]+)") do lines = lines + 1 end
    assert(lines == 3, "3 priorites, recu " .. lines .. " : " .. t.text)
    assert(t.text:find("Forme d'Ombre", 1, true) and t.text:find("Double spécialisation", 1, true))
    -- en combat : rien ; a la sortie : l'evaluation
    mock.setCombat(true)
    n.State.talents = { [1] = { [1] = { [2] = 2 } } }
    n.Fire("STATE", { "talents" })
    assert(#o.toasts == 1, "rien en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(#o.toasts == 2 and o.toasts[2].key == "obj:wandspec2", "evalue a la sortie de combat")
    knows(nil)
  end)

  check("Guide : Next, Evaluate (ordre des priorites), Milestones", function()
    local n = fresh().n
    setState(n, { level = nil })
    assert(#n.Guide.Evaluate() == 0 and n.Guide.Next() == nil)
    for _, m in ipairs(n.Guide.Milestones()) do assert(m.state == "futur") end
    setState(n, { level = 12, talents = {}, profs = {} })
    local list = n.Guide.Evaluate()
    assert(list[1].id == "wandspec" and list[2].id == "spirittap" and list[3].id == "rank_comp", "priorites d'abord : " .. list[1].id)
    assert(n.Guide.Next().id == "wandspec")
    local ms = n.Guide.Milestones()
    assert(#ms == #n.Data.Milestones)
    local seen = {}
    for _, m in ipairs(ms) do
      seen[m.state] = true
      if m.to < 12 then assert(m.state == "passe") elseif m.from <= 12 then assert(m.state == "courant") else assert(m.state == "futur") end
    end
    assert(seen.passe and seen.courant and seen.futur)
    setState(n, { level = 60 })
    assert(#n.Guide.Evaluate() > 0)
  end)

  check("Guide : Reference par onglet", function()
    local n = fresh().n
    local G, D2 = n.Guide, n.Data
    setState(n, { level = 20, profs = { [182] = { rank = 10, max = 75 } } })
    assert(#G.Reference("inconnu") == 0)
    local r = G.Reference("talents")
    assert(#r == #D2.TalentPlan and r[1].text and r[1].sub)
    r = G.Reference("zones")
    assert(#r == 20 and r[1].sub == "niveaux 1-10", "zones triees par niveau")
    local hl = 0
    for _, z in ipairs(r) do if z.highlight then hl = hl + 1 end end
    assert(hl > 0, "zones du niveau en evidence")
    r = G.Reference("dungeons")
    local inRange = 0
    for _, d in ipairs(D2.Dungeons) do if d.min <= 20 and 20 <= d.max then inRange = inRange + 1 end end
    assert(#r == inRange + #D2.DungeonTips and r[1].highlight and not r[#r].highlight
      and r[#r].text == D2.DungeonTips[#D2.DungeonTips], "donjons de la tranche puis conseils")
    r = G.Reference("profs")
    assert(#r == 3, "trois metiers")
    local byText = {}
    for _, p in ipairs(r) do byText[p.text] = p end
    assert(byText["Herboristerie"].sub == "10/75" and byText["Alchimie"].sub == "non apprise" and byText["Alchimie"].highlight)
    r = G.Reference("undead")
    assert(#r == #D2.Undead and r[1].highlight and r[#r].highlight == (20 >= D2.Undead[#D2.Undead].level))
    local anyApi = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)
    knows({})
    r = G.Reference("spells")
    assert(#r >= #D2.Spells)
    if anyApi then
      assert(r[1].highlight and r[1].text:find("(rang ", 1, true), "sort a apprendre en premier avec son rang : " .. r[1].text)
    else
      assert(not r[1].highlight)
    end
    knows(nil)
  end)

  check("Guide : Header, zone sans plage", function()
    local n = fresh().n
    setState(n, { level = 12, mapID = 99 })
    local h = n.Guide.Header()
    assert(h.level == 12 and h.progress == 12 / 60 and h.tier == "10-20", "niveau, progression, palier")
    assert(h.zoneStatus == "neutre" and h.nextZone == nil, "zone sans plage")
    assert(h.zoneName == (C_Map and "Tirisfal" or nil), "nom lu sur la carte")
    setState(n, { level = 10, mapID = 1, zone = 1420 })
    h = n.Guide.Header()
    assert(h.zoneStatus == "bientot" and h.zoneName == "Clairières de Tirisfal" and h.nextZone == n.Data.Zones[1421][3])
    setState(n, {})
    h = n.Guide.Header()
    assert(h.level == nil and h.progress == 0 and h.tier == nil and h.zoneStatus == "neutre")
  end)

  -- Fenetre Guide : un ns neuf, niveau 12 (objectif « legacy_toa » inconnu, a cocher a la main).
  local function gw()
    local o = fresh()
    local n = o.n
    n.db.guide.tab, n.db.guide.compact = "now", false
    setState(n, { level = 12 })
    return n, n.UI.GuideWin
  end
  local TABS = { "now", "next", "talents", "spells", "dungeons", "zones", "profs", "undead" }

  check("GuideWindow : ToggleGuide ouvre et ferme, Echap, /coach guide", function()
    local n, G = gw()
    n.ToggleGuide()
    assert(G.win:IsShown() and G.count == 1, "ouverte et dessinee")
    n.ToggleGuide()
    assert(not G.win:IsShown(), "fermee")
    local found
    for _, name in ipairs(UISpecialFrames) do if name == "PretreCoachGuideFrame" then found = true end end
    assert(found, "Echap")
    SlashCmdList.PRETRECOACH("guide")
    assert(G.win:IsShown())
  end)

  check("GuideWindow : chaque onglet se dessine, l'onglet est memorise", function()
    local n, G = gw()
    n.ToggleGuide()
    for i, key in ipairs(TABS) do
      G.win.tabs[i].scripts.OnClick(G.win.tabs[i])
      assert(n.db.guide.tab == key, "onglet memorise : " .. key)
    end
    G.win.tabs[1].scripts.OnClick(G.win.tabs[1])
    assert(G.used == #n.Guide.Evaluate() and G.used > 0, "Maintenant : une ligne par objectif")
    G.win.tabs[2].scripts.OnClick(G.win.tabs[2])
    assert(G.used == #n.Guide.Milestones(), "Etapes : une ligne par jalon")
    G.win.tabs[3].scripts.OnClick(G.win.tabs[3])
    assert(G.used == #n.Guide.Reference("talents") and G.rows[1].text.text == n.Guide.Reference("talents")[1].text)
    -- niveau illisible : tout se dessine encore
    setState(n, {})
    for i = 1, #TABS do G.win.tabs[i].scripts.OnClick(G.win.tabs[i]) end
  end)

  check("GuideWindow : clic sur un objectif inconnu appelle SetManual", function()
    local n, G = gw()
    n.ToggleGuide()
    local calls = {}
    local real = n.Guide.SetManual
    n.Guide.SetManual = function(id, v) calls[#calls + 1] = { id, v } return real(id, v) end
    local row
    for i = 1, G.used do if G.rows[i].entry.id == "legacy_toa" then row = G.rows[i] end end
    assert(row and row.entry.unknown, "ligne inconnue")
    row.box.scripts.OnClick(row.box)
    assert(#calls == 1 and calls[1][1] == "legacy_toa" and calls[1][2] == true, "SetManual(id, true)")
    assert(n.db.guide.manual.legacy_toa == true, "coche memorisee")
    for i = 1, G.used do if G.rows[i].entry.id == "legacy_toa" then row = G.rows[i] end end
    assert(row.entry.done and not row.entry.unknown, "ligne redessinee (GUIDE)")
    row.box.scripts.OnClick(row.box)
    assert(calls[2][2] == false, "decoche a la main")
    row.box.scripts.OnEnter(row.box); row.box.scripts.OnLeave(row.box)
  end)

  check("GuideWindow : GUIDE fenetre fermee, aucun rafraichissement, puis a l'ouverture", function()
    local n, G = gw()
    n.ToggleGuide(); n.ToggleGuide()
    local c = G.count
    n.Fire("GUIDE")
    n.Fire("STATE", { "level" })
    assert(G.count == c, "rien tant que fermee")
    n.ToggleGuide()
    assert(G.count == c + 1, "rafraichie a l'ouverture")
    n.Fire("GUIDE")
    assert(G.count == c + 2, "ouverte : rafraichie sur GUIDE")
  end)

  check("GuideWindow : STATE en combat reporte a PLAYER_REGEN_ENABLED", function()
    local n, G = gw()
    n.ToggleGuide()
    local c = G.count
    mock.setCombat(true)
    n.Fire("STATE", { "level" })
    n.Fire("GUIDE")
    assert(G.count == c, "rien en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(G.count == c + 1, "un seul rafraichissement apres le combat")
  end)

  check("GuideWindow : le pool de lignes ne grossit pas", function()
    local n, G = gw()
    n.ToggleGuide()
    G.win.tabs[3].scripts.OnClick(G.win.tabs[3])
    local size = #G.rows
    for _ = 1, 5 do n.Fire("GUIDE") end
    assert(#G.rows == size, "pool stable")
    G.win.tabs[1].scripts.OnClick(G.win.tabs[1])
    local small = #G.rows
    for _ = 1, 5 do n.Fire("GUIDE") end
    assert(#G.rows == small and small >= size, "pool stable apres retour")
  end)

  check("GuideWindow : mode compact affiche Next(), memorise, /coach compact", function()
    local n, G = gw()
    n.SetCompact(true)
    assert(n.db.guide.compact == true and G.card:IsShown() and not (G.win and G.win:IsShown()))
    assert(G.card.text.text == n.Guide.Next().text or G.card.text.text == "? " .. n.Guide.Next().text, "texte de Next()")
    n.Fire("GUIDE")
    n.ToggleGuide()
    assert(not G.card:IsShown(), "ToggleGuide ferme la carte")
    SlashCmdList.PRETRECOACH("compact")
    assert(n.db.guide.compact == false and G.win:IsShown() and not G.card:IsShown(), "retour a la fenetre")
    SlashCmdList.PRETRECOACH("compact")
    assert(n.db.guide.compact == true and G.card:IsShown())
    G.card:Hide()
    n.State.level = 80
    n.SetCompact(true)
    assert(G.card.text.text ~= nil, "niveau hors plage : texte de repli")
  end)

  check("GuideWindow : show.guide respecte au chargement", function()
    local keep = PretreCoachDB
    for _, case in ipairs({ { false, false }, { true, true }, { false, true } }) do
      local n = loadAddon()
      PretreCoachDB = { show = { guide = case[2] }, guide = { manual = {}, done = {}, compact = case[1] } }
      mock.fire("ADDON_LOADED", ADDON)
      local G = n.UI.GuideWin
      local shown = (G.win and G.win:IsShown()) or (G.card and G.card:IsShown()) or false
      assert(shown == case[2], "show.guide=" .. tostring(case[2]))
      assert(not case[2] or (case[1] and G.card:IsShown()) or (not case[1] and G.win:IsShown()), "bonne vue")
    end
    PretreCoachDB = keep
  end)

  ------------------------------------------------------------------------
  -- Rotation (spec 5)
  ------------------------------------------------------------------------
  -- Les instances chargees par les tests precedents restent inscrites aux evenements du mock : on isole.
  local function isolated(fn, restore)
    local saved = mock.events
    mock.events = {}
    local ok, err = xpcall(fn, debug.traceback)
    mock.events = saved
    if restore then restore() end
    if not ok then error(err, 0) end
  end

  local FULL = { PWS = 1, SWP = 1, SMITE = 1, MINDBLAST = 1, HOLYFIRE = 1, SHADOWFORM = 1, SWD = 1, MINDFLAY = 1,
    PSCREAM = 1, CANNIBAL = 1, DARKSAC = 1 }
  -- hasSWP vaut false par defaut ; swpNil = Douleur inconnue (Timers degrade) ; cdNil = recharges inconnues
  local function rctx(o)
    local known, cdv = o.known or FULL, o.cd or {}
    local c = { level = 12, inCombat = false, hasHostileTarget = true, hasWand = false, hasSWP = false,
      knows = function(k) return known[k] end, cd = function(k) return cdv[k] or 0 end }
    for k, v in pairs(o) do if k ~= "known" and k ~= "cd" and k ~= "cdNil" and k ~= "swpNil" then c[k] = v end end
    if o.cdNil then c.cd = function() return nil end end
    if o.swpNil then c.hasSWP = nil end
    return c
  end
  local function merge(a, b) local c = {} for k, v in pairs(a) do c[k] = v end for k, v in pairs(b) do c[k] = v end return c end
  local function keysOf(res) return table.concat(res.keys, ",") end
  local function rk(o, want, why)
    local res = N.Rotation.Compute(rctx(o))
    assert(keysOf(res) == want, (why or "") .. " : attendu " .. want .. ", recu " .. keysOf(res) .. " (" .. res.reason .. ")")
    return res
  end

  check("Rotation : niveau illisible = aucun conseil", function()
    local res = N.Rotation.Compute({})
    assert(#res.keys == 0 and res.reason ~= "")
  end)

  check("Rotation : paliers 1-10 (Bouclier, Douleur, Chatiment, corps a corps)", function()
    local K = { PWS = 1, SWP = 1, SMITE = 1 }
    rk({ level = 8, known = K, weakenedSoul = false }, "PWS,SWP,SMITE", "avant d'engager")
    rk({ level = 8, known = K, inCombat = true }, "SWP,SMITE,MELEE", "en combat")
    rk({ level = 8, known = K, inCombat = true, hasSWP = true, targetHpPct = 60 }, "SMITE,MELEE", "cible haute")
    rk({ level = 8, known = K, inCombat = true, hasSWP = true, targetHpPct = 30 }, "MELEE", "cible basse")
    rk({ level = 8, known = K, hasSWP = true, weakenedSoul = true }, "SMITE,MELEE", "Ame affaiblie : pas de Bouclier")
    rk({ level = 8, known = K, hasSWP = true, weakenedSoul = false, shieldUp = true }, "SMITE,MELEE", "Bouclier deja pose")
    rk({ level = 8, known = K, hasSWP = true, weakenedSoul = false, cd = { PWS = 3 } }, "SMITE,MELEE", "Bouclier en recharge")
    rk({ level = 8, known = K, hasSWP = true }, "SMITE,MELEE", "Ame affaiblie illisible : pas de Bouclier")
    rk({ level = 8, known = K, hasSWP = true, cdNil = true, weakenedSoul = false }, "SMITE,MELEE", "recharge inconnue")
  end)

  check("Rotation : avant baguette, vie de la cible illisible = Chatiment x2 puis corps a corps", function()
    local K = { SMITE = 1 }
    for smites, want in pairs({ [0] = "SMITE,MELEE", [1] = "SMITE,MELEE", [2] = "MELEE", [3] = "MELEE" }) do
      rk({ level = 8, known = K, hasSWP = true, inCombat = true, smitesOnTarget = smites }, want, smites .. " Chatiments")
    end
    local res = rk({ level = 8, known = K, hasSWP = true, inCombat = true, smitesOnTarget = 2 }, "MELEE")
    assert(res.text ~= "" and res.reason ~= "")
  end)

  check("Rotation : paliers 10-40 avec baguette", function()
    local o = { level = 20, hasWand = true, inCombat = true }
    rk(o, "MINDBLAST,SWP,SHOOT", "ouverture")
    rk(merge(o, { inCombat = false, weakenedSoul = false }), "PWS,MINDBLAST,SWP", "Bouclier puis ouverture")
    rk(merge(o, { known = { SWP = 1, MINDBLAST = 1 }, cd = { MINDBLAST = 5 } }), "SWP,SHOOT,MINDBLAST",
      "Attaque mentale en recharge, a la fin")
    rk(merge(o, { cd = { MINDBLAST = 5 } }), "HOLYFIRE,SWP,SHOOT", "Flammes sacrees quand l'Attaque mentale recharge")
    rk(merge(o, { known = { SWP = 1, HOLYFIRE = 1, MINDBLAST = 0 } }), "HOLYFIRE,SWP,SHOOT", "Attaque mentale non apprise")
    rk(merge(o, { hasSWP = true }), "SHOOT", "mana secret : baguette")
    rk(merge(o, { hasSWP = true, manaPct = 80 }), "MINDBLAST,SHOOT", "mana haut et lisible")
    rk(merge(o, { hasSWP = true, manaPct = 50 }), "SHOOT", "mana moyen")
    rk(merge(o, { manaPct = 10 }), "SHOOT", "mana tres bas : plus de sort")
    rk(merge(o, { targetHpPct = 10 }), "SHOOT", "cible presque morte : on acheve")
    rk(merge(o, { cdNil = true, swpNil = true }), "SHOOT", "Timers degrade : pas d'Attaque mentale supposee prete")
    rk(merge(o, { cdNil = true, hasSWP = true, manaPct = 90 }), "SHOOT", "recharge inconnue, mana haut")
    rk(merge(o, { hasWand = false, hasSWP = true, manaPct = 80 }), "MINDBLAST,SMITE,MELEE", "sans baguette")
    rk(merge(o, { known = {} }), "SHOOT", "rien d'appris : baguette")
    rk(merge(o, { known = {}, hasWand = false }), "MELEE", "rien d'appris, sans baguette")
    rk(merge(o, { known = { MINDBLAST = 0, SWP = 0, SMITE = 0, PSCREAM = 0 }, targetMelee = true }), "SHOOT", "rang 0 = non appris")
    local nw = merge(o, { known = { SWP = 1 }, hasSWP = true }) nw.hasWand = nil
    rk(nw, "MELEE", "baguette inconnue : pas de tir suppose")
  end)

  check("Rotation : un sort non appris n'est jamais conseille", function()
    local spells = {}
    for _, sp in ipairs(N.Data.Spells) do spells[sp.key] = true end
    for _, lvl in ipairs({ 5, 12, 25, 45, 60 }) do
      for _, wand in ipairs({ true, false }) do
        for _, inCombat in ipairs({ true, false }) do
          local res = N.Rotation.Compute(rctx({ level = lvl, known = { SWP = 1 }, hasWand = wand, inCombat = inCombat,
            manaPct = 90, targetMelee = true, shadowformActive = false, weakenedSoul = false }))
          for _, k in ipairs(res.keys) do
            assert(not spells[k] or k == "SWP" or k == "SHOOT", "conseille sans etre appris : " .. k)
          end
        end
      end
    end
  end)

  check("Rotation : Cri psychique au contact, jamais en premier", function()
    local o = { level = 20, hasWand = true, inCombat = true, targetMelee = true }
    local res = rk(o, "MINDBLAST,PSCREAM,SWP")
    assert(res.text:find(N.L.ROT_PSCREAM, 1, true), "avertissement dans le texte")
    rk(merge(o, { hasSWP = true }), "SHOOT,PSCREAM")
    rk(merge(o, { hasSWP = true, targetMelee = false }), "SHOOT")
    local nm = merge(o, { hasSWP = true }) nm.targetMelee = nil
    rk(nm, "SHOOT", "position illisible")
    rk(merge(o, { hasSWP = true, cd = { PSCREAM = 10 } }), "SHOOT", "en recharge")
    rk(merge(o, { hasSWP = true, cdNil = true }), "SHOOT", "recharge inconnue")
  end)

  check("Rotation : baguette et mouvement", function()
    local o = { level = 20, hasWand = true, inCombat = true, hasSWP = true }
    local res = rk(merge(o, { moving = true }), "SHOOT")
    assert(res.stop == true and res.text == N.L.ROT_STOP)
    res = rk(merge(o, { moving = false }), "SHOOT")
    assert(not res.stop and res.text == N.L.ROT_SHOOT)
    assert(not rk(o, "SHOOT").stop, "mouvement inconnu")
  end)

  check("Rotation : paliers 40-60, Forme d'Ombre", function()
    local o = { level = 40, hasWand = true }
    rk(merge(o, { shadowformActive = false }), "SHADOWFORM,MINDBLAST,SWP", "Forme d'Ombre absente au 40")
    rk(merge(o, { shadowformActive = true }), "MINDBLAST,SWP,SWD", "Forme d'Ombre active")
    rk(o, "MINDBLAST,SWP,SWD", "Forme d'Ombre illisible : pas de rappel")
    rk(merge(o, { shadowformActive = false, inCombat = true }), "MINDBLAST,SWP,SWD", "pas de rappel en combat")
    rk(merge(o, { shadowformActive = false, known = { SWP = 1 } }), "SWP,SHOOT", "Forme d'Ombre non apprise")
    rk(merge(o, { level = 39, shadowformActive = false }), "MINDBLAST,SWP,SHOOT", "pas avant 40")
    rk(merge(o, { level = 45, weakenedSoul = false, shadowformActive = true }), "PWS,MINDBLAST,SWP", "Bouclier d'abord")
    local c = merge(o, { level = 45, inCombat = true, hasSWP = true })
    rk(c, "SWD,MINDBLAST,SHOOT", "Mort et Attaque mentale prets")
    rk(merge(c, { manaPct = 80, cd = { MINDBLAST = 5, SWD = 5 } }), "MINDFLAY,SHOOT,MINDBLAST", "Fouet mental pour combler")
    rk(merge(c, { cd = { MINDBLAST = 5, SWD = 5 } }), "SHOOT,MINDBLAST,SWD", "mana secret : pas de Fouet mental")
    rk(merge(c, { cdNil = true, manaPct = 80 }), "MINDFLAY,SHOOT", "recharges inconnues")
    rk(merge(c, { cdNil = true, hasWand = false, known = { SWP = 1 } }), "MELEE", "sans baguette, tout inconnu")
  end)

  check("Rotation : recuperation hors combat sans cible", function()
    local base = { hasHostileTarget = false, hpPct = 100, manaPct = 100 }
    local corpse = merge(base, { hpPct = 50, targetDead = true, targetCreatureType = N.L.CT_HUMANOID, cannibalUsable = true })
    rk(base, "", "tout va bien")
    rk(corpse, "CANNIBAL,EAT", "Cannibalisme")
    rk(merge(corpse, { targetCreatureType = N.L.CT_UNDEAD }), "CANNIBAL,EAT", "mort-vivant")
    rk(merge(corpse, { targetCreatureType = "Bete" }), "EAT", "pas un humanoide")
    rk(merge(corpse, { cannibalUsable = false }), "EAT", "sort inutilisable")
    rk(merge(corpse, { cd = { CANNIBAL = 40 } }), "EAT", "en recharge")
    rk(merge(corpse, { cdNil = true }), "EAT", "recharge inconnue")
    rk(merge(base, { manaPct = 20 }), "DARKSAC,DRINK", "Sacrifice sombre puis boire")
    rk(merge(base, { manaPct = 20, known = { SWP = 1 } }), "DRINK", "Sacrifice sombre non appris")
    rk(merge(base, { manaPct = 20, hpPct = 40 }), "DRINK", "vie trop basse pour le Sacrifice sombre")
    local hurt = merge(base, { hpPct = 40, bandageCount = 2, recentlyBandaged = false })
    rk(hurt, "BANDAGE,EAT", "bandage avant de manger")
    rk(merge(hurt, { recentlyBandaged = true }), "EAT", "bandage recent")
    local nb = merge(hurt, {}) nb.recentlyBandaged = nil
    rk(nb, "EAT", "bandage recent illisible")
    rk(merge(hurt, { bandageCount = 0 }), "EAT", "pas de bandage")
    rk(merge(hurt, { manaPct = 20 }), "DRINK", "mana bas aussi : boire")
    local o = merge(base, {}) o.hpPct = nil
    rk(o, "", "vie illisible")
    o = merge(base, { hpPct = 10 }) o.manaPct = nil
    rk(o, "", "mana illisible")
    rk(merge(base, { inCombat = true, manaPct = 10 }), "", "en combat sans cible")
  end)

  check("Rotation : Context lit le jeu, secret = nil", function()
    local n = loadAddon()
    n.State.level, n.State.wand = 12, { itemID = 11287 }
    n.State.profs = { [129] = { rank = 30, max = 75 } }
    mock.items = { [1251] = 3, [2581] = 4, [6452] = 5 }
    mock.auras = { [6788] = true }
    local c = n.Rotation.Context()
    assert(c.level == 12 and c.inCombat == false and c.hasHostileTarget == true and c.hasWand == true)
    assert(c.knows == n.State.Knows and c.cd == n.Timers.CooldownRemaining)
    assert(c.manaPct == 100 and c.hpPct == 100 and c.targetHpPct == 100 and c.targetMelee == false)
    assert(c.weakenedSoul == true and c.shieldUp == false and c.shadowformActive == false and c.smitesOnTarget == 0)
    mock.hasTarget = false
    c = n.Rotation.Context()
    assert(c.hasHostileTarget == false and c.bandageCount == (GetItemCount and 3 or 0), "bandages : rang et anti-venin exclus")
    mock.hasTarget, mock.dead = true, true
    c = n.Rotation.Context()
    assert(c.hasHostileTarget == false and c.targetDead == true and c.targetCreatureType == N.L.CT_HUMANOID)
    mock.dead, mock.canAttack = nil, false
    assert(n.Rotation.Context().hasHostileTarget == false, "cible amicale")
    mock.canAttack = nil
    n.State.wand = false
    assert(n.Rotation.Context().hasWand == false)
    n.State.wand = nil
    assert(n.Rotation.Context().hasWand == nil)
    mock.setCombat(true)
    c = n.Rotation.Context()
    assert(c.inCombat == true)
    if not mock.noSecrets then
      assert(c.manaPct == nil and c.hpPct == nil and c.targetHpPct == nil, "vie et mana secrets = nil")
      assert(c.weakenedSoul == nil and c.shieldUp == nil and c.shadowformActive == nil, "auras secretes = nil")
      assert(c.hasHostileTarget == true, "cible supposee attaquable")
    end
    mock.setCombat(false)
    mock.items, mock.auras = nil, nil
  end)

  check("Rotation : compteur de Chatiments, remis a zero au changement de cible", function()
    isolated(function()
      local n = loadAddon()
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "x" or mock.SECRET)
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 591)
      assert(n.Rotation.Context().smitesOnTarget == 2)
      mock.fire("PLAYER_TARGET_CHANGED")
      assert(n.Rotation.Context().smitesOnTarget == 0)
    end)
  end)

  check("Rotation : ROTATION n'est emis qu'au changement, raison en debug, minuteur", function()
    isolated(function()
      local n = loadAddon()
      n.db = { debug = true, show = { rotation = true } }
      n.State.level, n.State.wand = 20, { itemID = 11287 }
      local got = {}
      n.Listen("ROTATION", function(_, res) got[#got + 1] = res end)
      local Ro = n.Rotation
      local updates, orig = 0, Ro.Update
      Ro.Update = function(...) updates = updates + 1 return orig(...) end
      local printed0 = #mock.printed
      mock.hasTarget = true
      mock.fire("PLAYER_TARGET_CHANGED")
      assert(#got == 1 and #got[1].keys > 0, "premier calcul emis")
      local dbg = 0
      for i = printed0 + 1, #mock.printed do if mock.printed[i]:find("[debug]", 1, true) then dbg = dbg + 1 end end
      assert(dbg >= 1, "debug : la raison est affichee")
      mock.fire("PLAYER_TARGET_CHANGED")
      mock.fire("PLAYER_REGEN_DISABLED")
      mock.fire("PLAYER_REGEN_ENABLED")
      mock.fire("PLAYER_STARTED_MOVING")
      mock.fire("UNIT_AURA", "player")
      n.Fire("TIMERS")
      n.Fire("STATE", { "level" })
      assert(#got == 1, "inchange : pas de nouvel evenement (" .. #got .. ")")
      local useTicker = C_Timer and C_Timer.NewTicker
      local function alive()
        if useTicker then local t = mock.tickers[#mock.tickers] return t ~= nil and not t.cancelled end
        return Ro.tickFrame ~= nil and Ro.tickFrame.scripts.OnUpdate ~= nil
      end
      assert(alive(), "minuteur actif avec une cible")
      local before = updates
      if useTicker then
        local t = mock.tickers[#mock.tickers]
        assert(t.delay == 0.2)
        t.fn()
      else
        Ro.tickFrame.scripts.OnUpdate(Ro.tickFrame, 0.1)
        assert(updates == before, "pas de recalcul avant 0,2 s")
        Ro.tickFrame.scripts.OnUpdate(Ro.tickFrame, 0.15)
      end
      assert(updates == before + 1, "un recalcul par tic")
      mock.hasTarget = false
      mock.fire("PLAYER_TARGET_CHANGED")
      assert(#got == 2 and #got[2].keys == 0, "plus de cible : resultat vide emis une fois")
      assert(not alive(), "minuteur arrete sans cible ni combat")
      mock.setCombat(true)
      mock.fire("PLAYER_REGEN_DISABLED")
      assert(alive(), "minuteur actif en combat")
      mock.setCombat(false)
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(not alive(), "minuteur arrete apres le combat")
      mock.hasTarget = true
    end, function() mock.setCombat(false) mock.hasTarget = true end)
  end)

  -- Panneau : une instance neuve, ADDON_LOADED, puis les appels de l'interface sont journalises.
  local function panel()
    local n = loadAddon()
    PretreCoachDB = { show = { rotation = true } }
    mock.fire("ADDON_LOADED", ADDON)
    local P = n.UI.RotationPanel
    P.log = { pulse = 0, icons = {}, gray = {} }
    local function wrap(b, i)
      local si, sg, sp = b.SetIcon, b.SetGrayed, b.Pulse
      b.SetIcon = function(s, t) P.log.icons[i] = t si(s, t) end
      b.SetGrayed = function(s, g) P.log.gray[i] = g sg(s, g) end
      b.Pulse = function(s) P.log.pulse = P.log.pulse + 1 sp(s) end
    end
    wrap(P.frame.big, 1) wrap(P.frame.small[1], 2) wrap(P.frame.small[2], 3)
    return n, P
  end

  check("RotationPanel : masque sans conseil ou si show.rotation == false, icones, grisage, pulse", function()
    local keep = PretreCoachDB
    isolated(function()
      local n, P = panel()
      assert(P.frame and not P.frame:IsShown(), "masque au depart")
      mock.time = 400
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 8092) -- Attaque mentale : recharge 8 s
      mock.time = 401
      n.Fire("ROTATION", { keys = {}, text = "" })
      assert(not P.frame:IsShown(), "masque quand keys est vide")
      P.log.pulse = 0
      n.Fire("ROTATION", { keys = { "MINDBLAST", "SHOOT", "SWP" }, text = "Texte" })
      assert(P.frame:IsShown() and P.frame.text.text == "Texte", "affiche")
      assert(P.log.icons[1] and P.log.icons[2] and P.log.icons[3], "trois icones")
      assert(P.log.gray[1] == true and P.log.gray[2] == false and P.log.gray[3] == false, "grise si recharge en cours")
      assert(P.log.pulse == 1)
      n.Fire("ROTATION", { keys = { "MINDBLAST", "SHOOT" }, text = "Texte 2" })
      assert(P.log.pulse == 1, "meme premiere icone : pas de pulse")
      assert(not P.frame.small[2]:IsShown(), "troisieme icone masquee")
      n.Fire("ROTATION", { keys = { "SWP" }, text = "T" })
      assert(P.log.pulse == 2 and not P.frame.small[1]:IsShown(), "premiere icone changee : pulse")
      n.Fire("ROTATION", { keys = {}, text = "" })
      assert(not P.frame:IsShown())
      n.db.show.rotation = false
      n.Fire("ROTATION", { keys = { "SHOOT" }, text = "T" })
      assert(not P.frame:IsShown(), "show.rotation == false")
      n.db.show.rotation = true
      n.Fire("ROTATION", { keys = { "SHOOT" }, text = "T" })
      assert(P.frame:IsShown() and P.log.pulse == 3)
      n.Fire("ROTATION", { keys = { "SHOOT" }, text = "Arrete", stop = true })
      assert(P.log.pulse == 4, "stop : l'icone clignote")
    end, function() PretreCoachDB = keep end)
  end)

  check("RotationPanel : barre des 5 s", function()
    local keep = PretreCoachDB
    isolated(function()
      local _, P = panel()
      local bar = P.frame.bar
      mock.time = 100
      assert(not bar:IsShown(), "masquee au depart")
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
      assert(bar:IsShown() and bar.value == 5 and bar.scripts.OnUpdate, "5 s lancees")
      mock.time = 102
      bar.scripts.OnUpdate(bar, 0.01)
      assert(bar.value == 5, "OnUpdate limite : rien avant 0,05 s")
      bar.scripts.OnUpdate(bar, 0.1)
      assert(bar.value == 3, "valeur " .. tostring(bar.value))
      mock.time = 106
      bar.scripts.OnUpdate(bar, 0.1)
      assert(not bar:IsShown() and bar.scripts.OnUpdate == nil, "fini : masquee, OnUpdate retire")
      mock.time = 110
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
      assert(bar:IsShown())
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "x" or mock.SECRET) -- mode degrade
      assert(not bar:IsShown() and bar.scripts.OnUpdate == nil, "mode degrade : masquee")
    end, function() PretreCoachDB = keep end)
  end)

  check("Rotation : SpellID et Texture", function()
    local n = loadAddon()
    knows({ [589] = true, [594] = true })
    if IsPlayerSpell then
      assert(n.Rotation.SpellID("SWP") == 594 and n.Rotation.SpellID("SMITE") == nil, "plus haut rang connu")
      assert(n.Rotation.Texture("SWP") == "tex594")
    else
      assert(n.Rotation.SpellID("SWP") == nil)
    end
    assert(n.Rotation.SpellID("MELEE") == nil and n.Rotation.Texture("MELEE") ~= nil)
    knows(nil)
  end)

  check("Rotation : Hotkey avec et sans C_ActionBar, scan jamais en combat, cache", function()
    local keepAB, keepGAI = C_ActionBar, GetActionInfo
    isolated(function()
      local n = loadAddon()
      local want = GetBindingText and "SHIFT-3" or "S3"
      local scans = 0
      GetActionInfo = function(...) scans = scans + 1 return keepGAI(...) end
      -- avec C_ActionBar.FindSpellActionButtons
      C_ActionBar = { FindSpellActionButtons = function(id) if id == 10894 then return { 3 } end end }
      mock.bindings = { ACTIONBUTTON3 = "SHIFT-3" }
      assert(n.Rotation.Hotkey("SWP") == want, "raccourci via Find : " .. tostring(n.Rotation.Hotkey("SWP")))
      assert(scans == 0, "pas de scan quand Find existe")
      assert(n.Rotation.Hotkey("MELEE") == nil and n.Rotation.Hotkey("SMITE") == nil, "sort absent des barres")
      mock.bindings = { ACTIONBUTTON3 = "F5" }
      assert(n.Rotation.Hotkey("SWP") == want, "cache")
      mock.fire("UPDATE_BINDINGS")
      assert(n.Rotation.Hotkey("SWP") == "F5", "cache invalide sur UPDATE_BINDINGS")
      -- sans C_ActionBar : scan de GetActionInfo, hors combat seulement
      C_ActionBar = nil
      mock.actions = { [26] = 594 }
      mock.bindings = { MULTIACTIONBAR3BUTTON2 = "F2", ACTIONBUTTON1 = "1" }
      mock.fire("ACTIONBAR_SLOT_CHANGED")
      mock.setCombat(true)
      assert(n.Rotation.Hotkey("SWP") == nil and scans == 0, "pas de scan en combat")
      mock.setCombat(false)
      assert(n.Rotation.Hotkey("SWP") == "F2", "scan hors combat, barre de droite")
      assert(scans == 120, "120 emplacements scannes une fois : " .. scans)
      n.Rotation.Hotkey("SWP") n.Rotation.Hotkey("SMITE")
      assert(scans == 120, "scan reutilise")
      mock.actions = { [1] = 585 }
      mock.fire("ACTIONBAR_SLOT_CHANGED")
      assert(n.Rotation.Hotkey("SMITE") == "1" and scans == 240, "cache invalide sur ACTIONBAR_SLOT_CHANGED")
      assert(n.Rotation.Hotkey("SWP") == nil, "sort retire des barres")
    end, function()
      C_ActionBar, GetActionInfo = keepAB, keepGAI
      mock.bindings, mock.actions = nil, nil
      mock.setCombat(false)
    end)
  end)

  ------------------------------------------------------------------------
  -- L7 : regles d'or (ns.Rules) et bandeau (UI/RulesBar)
  ------------------------------------------------------------------------
  local function rule(n, i) return n.Rules.Status()[i] end
  local function count(list, key) local c = 0 for _, t in ipairs(list) do if t.key == key then c = c + 1 end end return c end
  -- mouvement detectable (ou non) quel que soit le mock
  local function withMoving(known, fn)
    local keepS, keepM = GetUnitSpeed, IsPlayerMoving
    if known then GetUnitSpeed, IsPlayerMoving = function() return 0 end, function() return false end
    else GetUnitSpeed, IsPlayerMoving = nil, nil end
    local ok, err = pcall(fn)
    GetUnitSpeed, IsPlayerMoving = keepS, keepM
    if not ok then error(err, 0) end
  end
  local function rcleanup() mock.guid, mock.dead, mock.inCombat = "Creature-0", nil, false end

  check("Regles : 8 regles avec textes, etat initial inconnu", function()
    isolated(function()
      local n = fresh().n
      assert(#n.Rules.list == 8)
      for i, r in ipairs(n.Rules.list) do
        assert(r.id == i and r.title and r.title ~= "" and r.explain and r.explain ~= "", "regle " .. i)
      end
      for i = 1, 8 do assert(rule(n, i).state == "unknown") end
    end)
  end)

  check("R1 baguette : niveaux 4/5, depassee a -10, illisible, toast, combat, message RULES, debug", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      local fired = 0
      n.Listen("RULES", function() fired = fired + 1 end)
      n.State.level, n.State.wand = 4, false
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "ok" and #o.rtoasts == 0, "niveau 4 sans baguette : rien")
      n.State.level = 5
      n.db.debug = true
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "bad" and count(o.rtoasts, "r1:none") == 1, "niveau 5 : rouge et toast")
      local dbg = false
      for _, line in ipairs(mock.printed) do if line:find("R1 bad", 1, true) then dbg = true end end
      assert(dbg, "debug : R1 bad")
      local f = fired
      n.Rules.Evaluate()
      assert(fired == f, "inchange : pas de nouveau RULES")
      n.State.level, n.State.wand = 20, { itemID = 1, reqLevel = 10 }
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "warn" and count(o.rtoasts, "r1:old") == 1, "req = niveau - 10 : depassee")
      n.State.level = 19
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "ok", "req = niveau - 9 : ok")
      n.State.wand = nil
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "unknown")
      n.State.level, n.State.wand = nil, false
      n.Rules.Evaluate()
      assert(rule(n, 1).state == "unknown", "niveau illisible")
      -- evaluee en combat, mais sans toast
      local c = #o.rtoasts
      mock.setCombat(true)
      n.State.level = 12
      n.Rules.Evaluate()
      mock.setCombat(false)
      assert(rule(n, 1).state == "bad" and #o.rtoasts == c, "R1 en combat : etat oui, toast non")
      n.State.wand = { itemID = 1, reqLevel = 5 }
      n.Fire("STATE", { "wand" })
      assert(rule(n, 1).state == "ok", "STATE relance l'evaluation")
    end, rcleanup)
  end)

  check("R2 achevement : une mort par GUID, 70 %, conseil, mort illisible", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      mock.time = 10
      -- lance un sort sur le monstre `guid`, puis il meurt ; `how` = evenement qui detecte la mort
      local function kill(guid, spellID, how)
        mock.guid, mock.dead = guid, false
        mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", spellID)
        mock.dead = true
        if how == "UNIT_HEALTH" then mock.fire(how, "target") else mock.fire(how) end
      end
      kill("G1", 5019, "UNIT_HEALTH")
      local k = n.Rules.KillStats()
      assert(k.total == 1 and k.wand == 1 and rule(n, 2).state == "ok", "1/1")
      mock.fire("UNIT_HEALTH", "target"); mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("PLAYER_REGEN_ENABLED")
      assert(n.Rules.KillStats().total == 1, "une seule fois par GUID")
      mock.guid, mock.dead = "Inconnu", true -- jamais attaque par nous
      mock.fire("PLAYER_TARGET_CHANGED")
      assert(n.Rules.KillStats().total == 1, "monstre sans sort lance : ignore")
      for i = 2, 7 do kill("S" .. i, 5019, "PLAYER_TARGET_CHANGED") end
      for i = 1, 3 do kill("M" .. i, 585, "PLAYER_REGEN_ENABLED") end
      k = n.Rules.KillStats()
      assert(k.total == 10 and k.wand == 7 and rule(n, 2).state == "ok", "7/10 = 70 % : ok")
      kill("M4", 585, "UNIT_HEALTH")
      assert(rule(n, 2).state == "warn", "7/11 : orange")
      n.Rotation.current = { keys = { "SHOOT" } }
      n.Rules.Evaluate()
      assert(rule(n, 2).reason:find("Connexion spirituelle", 1, true), "le conseil s'affiche")
      assert(not findSecret(n.db, "db"))
    end, rcleanup)
  end)

  check("R2 : mort jamais lisible = inconnu, conseil seul", function()
    isolated(function()
      local keep = UnitIsDead
      UnitIsDead = function() if mock.noSecrets then return nil end return mock.SECRET end
      local ok, err = pcall(function()
        local n = fresh().n
        mock.guid = "G9"
        mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 5019)
        mock.fire("PLAYER_TARGET_CHANGED"); mock.fire("PLAYER_REGEN_ENABLED")
        assert(n.Rules.KillStats().total == 0 and rule(n, 2).state == "unknown")
        assert(rule(n, 2).reason:find("illisible", 1, true), rule(n, 2).reason)
        n.Rotation.current = { keys = { "SHOOT" } }
        n.Rules.Evaluate()
        assert(rule(n, 2).state == "unknown" and rule(n, 2).reason:find("Connexion spirituelle", 1, true), "conseil seul")
      end)
      UnitIsDead = keep
      if not ok then error(err, 0) end
    end, rcleanup)
  end)

  check("R3 5 s : sort couteux dans la fenetre, soin d'urgence, expiration, degrade, ordre des ecouteurs", function()
    for _, reverse in ipairs({ false, true }) do
      isolated(function()
        local o = fresh()
        local n = o.n
        if reverse then -- ordre d'appel inverse entre Timers et GoldenRules : meme resultat
          local l, r = mock.events.UNIT_SPELLCAST_SUCCEEDED, {}
          for i = #l, 1, -1 do r[#r + 1] = l[i] end
          mock.events.UNIT_SPELLCAST_SUCCEEDED = r
        end
        local function cast(id, t) mock.time = t mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", id) end
        cast(585, 100)
        assert(count(o.rtoasts, "r3") == 0 and rule(n, 3).state == "ok", "premier sort : rien")
        cast(585, 102)
        assert(count(o.rtoasts, "r3") == 1 and rule(n, 3).state == "warn", "relance dans les 5 s")
        local t = o.rtoasts[#o.rtoasts]
        assert(t.cooldown == 60 and t.text:find("regen", 1, true), t.text)
        cast(2052, 104) -- soin d'urgence dans la fenetre
        assert(count(o.rtoasts, "r3") == 1, "soin d'urgence : pas de toast")
        cast(585, 111) -- fenetre close
        assert(count(o.rtoasts, "r3") == 1 and rule(n, 3).state == "warn", "hors fenetre : pas de toast, orange tient 30 s")
        mock.time = 133
        mock.flushTimers()
        n.Rules.Evaluate() -- sans C_Timer (passe absentes) ns.After ne reporte rien
        assert(rule(n, 3).state == "ok", "l'orange s'eteint")
        cast(585, 200)
        cast(17, 202) -- Bouclier = urgence
        assert(count(o.rtoasts, "r3") == 1)
        mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "x" or mock.SECRET)
        assert(rule(n, 3).state == "unknown", "mode degrade : inconnu")
      end, rcleanup)
    end
  end)

  check("R4 arrete-toi : stop, combat, rappel unique si mouvement indetectable", function()
    withMoving(true, function()
      isolated(function()
        local o = fresh()
        local n = o.n
        n.Rotation.current = { keys = { "SHOOT" }, stop = true }
        n.Fire("ROTATION", n.Rotation.current)
        assert(rule(n, 4).state == "warn")
        n.Rotation.current = { keys = { "SHOOT" } }
        n.Fire("ROTATION", n.Rotation.current)
        assert(rule(n, 4).state == "ok" and #o.rtoasts == 0, "mouvement lisible : pas de rappel")
        mock.setCombat(true)
        n.Rotation.current = { keys = { "SHOOT" }, stop = true }
        n.Fire("ROTATION", n.Rotation.current)
        mock.setCombat(false)
        assert(rule(n, 4).state == "warn", "evaluee en combat")
      end, rcleanup)
    end)
    withMoving(false, function()
      isolated(function()
        local o = fresh()
        local n = o.n
        n.Fire("ROTATION", { keys = { "SMITE" } })
        assert(#o.rtoasts == 0 and rule(n, 4).state == "unknown", "pas de Tir : pas de rappel")
        n.Fire("ROTATION", { keys = { "SHOOT" } })
        n.Fire("ROTATION", { keys = { "SMITE" } })
        n.Fire("ROTATION", { keys = { "SHOOT" } })
        assert(count(o.rtoasts, "r4") == 1, "rappel unique par session")
      end, rcleanup)
    end)
  end)

  check("R5 zone : adaptee, dernier niveau, verte + toast, inconnu, figee en combat", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      n.State.zone, n.State.level = 1420, 9
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "ok")
      n.State.level = 10
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "warn" and #o.rtoasts == 0, "dernier niveau : orange")
      n.State.level = 11
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "bad" and count(o.rtoasts, "r5:1420") == 1)
      local t = o.rtoasts[#o.rtoasts]
      assert(t.text == "Cette zone devient verte. Direction : Forêt des Pins-Argentés", t.text)
      local c = #o.rtoasts
      mock.setCombat(true)
      n.State.zone, n.State.level = 1421, 15
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "bad" and #o.rtoasts == c, "garde son dernier etat en combat")
      mock.setCombat(false)
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(rule(n, 5).state == "ok", "reevaluee a la sortie du combat")
      n.State.zone = nil
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "unknown", "zone inconnue")
      n.State.zone, n.State.level = 1421, nil
      n.Rules.Evaluate()
      assert(rule(n, 5).state == "unknown", "niveau inconnu")
    end, rcleanup)
  end)

  check("R6 Thrill of Adventure : inconnu, ok si coche dans le guide", function()
    isolated(function()
      local n = fresh().n
      n.Rules.Evaluate()
      assert(rule(n, 6).state == "unknown")
      n.db.guide.manual.legacy_toa = true
      n.Rules.Evaluate()
      assert(rule(n, 6).state == "ok")
    end)
  end)

  check("R7 Brassenoire : niveaux 23/24/32/33, quete nil, manuel, toast Ashenvale unique", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      local keep, done = n.State.QuestDone, false
      n.State.QuestDone = function() return done end
      n.State.zone = 1420
      for _, c in ipairs({ { 23, "ok" }, { 24, "warn" }, { 32, "warn" }, { 33, "ok" } }) do
        n.State.level = c[1]
        n.Rules.Evaluate()
        assert(rule(n, 7).state == c[2], "niveau " .. c[1] .. " : " .. rule(n, 7).state)
      end
      assert(count(o.rtoasts, "r7") == 0, "pas de toast hors Ashenvale")
      n.State.level, n.State.zone = 28, 1440
      n.Rules.Evaluate()
      n.Rules.Evaluate()
      assert(count(o.rtoasts, "r7") == 1, "toast une seule fois par session")
      done = true
      n.Rules.Evaluate()
      assert(rule(n, 7).state == "ok")
      done = nil
      n.Rules.Evaluate()
      assert(rule(n, 7).state == "unknown", "quete illisible")
      n.db.guide.manual.bfd_quest = true
      n.Rules.Evaluate()
      assert(rule(n, 7).state == "ok", "objectif coche a la main")
      n.State.level = nil
      n.Rules.Evaluate()
      assert(rule(n, 7).state == "unknown")
      n.State.QuestDone = keep
    end, rcleanup)
  end)

  check("R8 double spe au 40 : niveaux 39/40, forme d'ombre, specGroups, nil, toast unique, combat", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      local sf
      n.State.Knows = function() return sf end
      n.State.level, n.State.specGroups = 39, 1
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "ok" and #o.rtoasts == 0, "niveau 39")
      n.State.level, sf = 40, 1
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "bad", "une seule spe")
      assert(count(o.rtoasts, "r8") == 1 and o.rtoasts[#o.rtoasts].text == "Respec Ombre et active ta double spé")
      sf, n.State.specGroups = 0, 2
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "bad", "forme d'ombre non apprise")
      assert(count(o.rtoasts, "r8") == 1, "toast une seule fois")
      sf = 1
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "ok")
      n.State.specGroups = nil
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "ok", "specGroups inconnu : juge sur la Forme d'Ombre")
      sf = nil
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "unknown")
      sf, n.State.specGroups = 1, 1
      mock.setCombat(true)
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "unknown", "pas de reevaluation en combat")
      mock.setCombat(false)
      n.Rules.Evaluate()
      assert(rule(n, 8).state == "bad")
    end, rcleanup)
  end)

  check("Regles : toasts non repetes avec le vrai ns.Toast", function()
    isolated(function()
      local n = loadAddon()
      n.db = { show = { toasts = true }, guide = { manual = {}, done = {} } }
      local log, real = {}, n.Toast
      n.Toast = function(t, o) local r = real(t, o) log[#log + 1] = r return r end
      mock.time = 5000
      n.State.level, n.State.wand = 8, false
      n.Rules.Evaluate()
      n.State.level = 9
      n.Rules.Evaluate()
      assert(log[1] == true and log[2] == false, "doublon bloque par l'anti-repetition")
      mock.time = 5301
      n.State.level = 10
      n.Rules.Evaluate()
      assert(log[3] == true, "reapparait apres le delai")
      mock.flushTimers()
    end, rcleanup)
  end)

  check("RulesBar : pastilles, couleurs, combat, infobulle, clic, show.rules", function()
    isolated(function()
      local n = loadAddon()
      n.db = { show = { toasts = false, rules = true }, guide = { manual = {}, done = {} } }
      mock.fire("ADDON_LOADED", ADDON)
      local B = n.UI.RulesBar
      assert(#B.buttons == 8 and B.frame.shown, "8 pastilles")
      n.State.level, n.State.wand = 12, false
      n.Rules.Evaluate()
      local C = n.UI.color
      assert(B.buttons[1].bg.color[1] == C.bad[1] and B.buttons[3].bg.color[1] == C.good[1], "rouge puis vert")
      assert(B.buttons[6].bg.color[1] == 0.45, "gris pour inconnu")
      for i = 1, 8 do assert(B.buttons[i].shown, "hors combat : pastille " .. i) end
      mock.setCombat(true)
      mock.fire("PLAYER_REGEN_DISABLED")
      for i = 1, 4 do assert(B.buttons[i].shown, "combat : pastille " .. i) end
      for i = 5, 8 do assert(not B.buttons[i].shown, "combat : pastille " .. i .. " masquee") end
      mock.setCombat(false)
      mock.fire("PLAYER_REGEN_ENABLED")
      for i = 5, 8 do assert(B.buttons[i].shown) end
      local b = B.buttons[1]
      b.scripts.OnEnter(b)
      b.scripts.OnLeave(b)
      local b2 = B.buttons[2]
      b2.scripts.OnClick(b2)
      assert(B.detail.shown and B.detail.text.text:find(n.Rules.list[2].explain, 1, true), "clic : explication")
      b2.scripts.OnClick(b2)
      assert(not B.detail.shown, "second clic : referme")
      n.db.show.rules = false
      B.Render()
      assert(not B.frame.shown, "show.rules = false")
      n.db.show.rules = true
      n.Fire("RULES")
      n.Rules.Evaluate()
      B.Render()
      assert(B.frame.shown)
    end, rcleanup)
  end)

  check("Un listener STATE qui plante ne bloque pas les autres", function()
    N.Listen("STATE", function() error("boom") end) -- en dernier : il reste inscrit
    local got = 0
    N.Listen("STATE", function() got = got + 1 end)
    N.Fire("STATE", { "x" })
    assert(got == 1 and #mock.errors == 1, "le suivant doit s'executer, l'erreur partir au gestionnaire")
    mock.errors = {}
  end)
end

suite("presentes")
mock.setAbsent(true)
suite("absentes")
mock.setAbsent(false)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
