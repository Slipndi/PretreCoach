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
    assert(#C.PendingSpells(nil, none) == 0 and #C.PendingSpells(10, function() return nil end) == 0, "level nil / inconnu")
    assert(#C.PendingSpells(10, nil) == 0)
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
    mock.fire("SPELLS_CHANGED")
    assert(#msgs == n, "rien de change : pas de message")
  end)

  check("State : baguette, cache et GET_ITEM_INFO_RECEIVED", function()
    if not GetInventoryItemID then return end
    mock.rangedID, mock.uncached = 11287, true
    mock.fire("PLAYER_EQUIPMENT_CHANGED")
    assert(St.wand.itemID == 11287 and St.wand.reqLevel == nil, "baguette hors cache")
    mock.uncached = false
    mock.fire("GET_ITEM_INFO_RECEIVED", 999)
    assert(St.wand.reqLevel == nil, "autre objet : pas de relecture")
    mock.fire("GET_ITEM_INFO_RECEIVED", 11287)
    assert(St.wand.reqLevel == 5 and St.wand.name == "Baguette 11287")
    mock.rangedID = 12345 -- un arc, pas une baguette
    mock.fire("PLAYER_EQUIPMENT_CHANGED")
    assert(St.wand == false)
  end)

  check("State : PLAYER_LEVEL_UP en combat, rafraichi a la sortie", function()
    local n = #msgs
    mock.setCombat(true)
    mock.fire("PLAYER_LEVEL_UP", 13)
    assert(St.level == 12 and #msgs == n, "rien de lourd en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(St.level == 13 and #msgs == n + 1, "niveau de l'evenement apres le combat")
    mock.fire("PLAYER_REGEN_ENABLED") -- pas sale : rien
    assert(#msgs == n + 1)
  end)

  check("State : repli des metiers par GetSkillLineInfo", function()
    if not GetProfessions then return end
    local gp, gs = GetProfessions, GetSkillLineInfo
    GetProfessions = nil
    GetSkillLineInfo = function() return "Herboristerie", false, 0, 120, 0, 0, 300 end
    mock.fire("SKILL_LINES_CHANGED")
    GetProfessions, GetSkillLineInfo = gp, gs
    assert(St.profs[182].rank == 120 and St.profs[182].max == 300)
  end)

  check("State : QuestDone et Knows", function()
    if C_QuestLog then assert(St.QuestDone(1) == false) else assert(St.QuestDone(1) == nil) end
    assert(St.Knows("NOPE") == nil)
    if not IsPlayerSpell and not IsSpellKnown and not C_SpellBook then
      assert(St.Knows("SWP") == nil, "API absente = inconnu")
      return
    end
    assert(St.Knows("SWP") == 8)
    mock.known = { [594] = true }
    assert(St.Knows("SWP") == 2)
    mock.known = {}
    assert(St.Knows("SWP") == 0)
    mock.known = nil
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
end

suite("presentes")
mock.setAbsent(true)
suite("absentes")
mock.setAbsent(false)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
