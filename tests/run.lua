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

-- State.talents au format C_Traits : tl{ [spellID] = rang } (Connexion spirituelle 15270, Specialisation Baguette 14524)
local function tl(t)
  local o = {}
  for id, r in pairs(t) do o[id] = { rank = r, max = 5, name = "Sort" .. id } end
  return o
end

local function suite(label)
  prefix = label .. " : "
  mock.reset()
  local ns, suiteSlash, suiteCompartment
  check("charge les fichiers du .toc", function()
    assert(#files > 0, "toc vide")
    ns = loadAddon()
    suiteSlash, suiteCompartment = SlashCmdList.PRETRECOACH, PretreCoach_OnCompartmentClick -- les chargements suivants les ecrasent
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
    b.scripts.OnClick(b, "RightButton")
    ns.ToggleGuide = nil
    assert(n == 1 and #mock.printed >= 1)
    ns.ToggleGuide = real
    select(2, ns.UI.MenuRows()):Hide()
  end)
  check("RunCommand : chaque commande comme le slash", function()
    local N = ns
    local realG, realC, realP = N.ToggleGuide, N.SetCompact, N.Probe
    local hit = {}
    N.ToggleGuide = function() hit.guide = true end
    N.SetCompact = function() hit.compact = true end
    N.Probe = function() hit.probe = true end
    for _, c in ipairs({ "guide", "compact", "probe" }) do assert(N.RunCommand(c) and hit[c], c) end
    local d = N.db.debug
    N.RunCommand("debug"); assert(N.db.debug == not d and N.db.debug ~= nil)
    N.RunCommand("debug"); assert(N.db.debug == (d or false))
    -- le slash ne fait que passer par RunCommand (instance neuve : le slash du dernier chargement)
    local seen, realRC = {}, N.RunCommand
    N.RunCommand = function(c) seen[#seen + 1] = c return c ~= "nimporte" end
    suiteSlash("  GUIDE x"); suiteSlash("")
    assert(seen[1] == "guide" and seen[2] == "", "slash -> RunCommand")
    local np = #mock.printed
    suiteSlash("nimporte"); assert(#mock.printed == np + 1, "aide pour commande inconnue")
    N.RunCommand = realRC
    N.RunCommand("lock"); assert(N.db.locked == true)
    N.RunCommand("unlock"); assert(N.db.locked == false)
    assert(N.RunCommand("reset") and N.RunCommand("help") and N.RunCommand(""))
    assert(N.RunCommand("nimporte") == false)
    N.ToggleGuide, N.SetCompact, N.Probe = realG, realC, realP
  end)
  check("Menu minicarte : ouverture, fermeture, entrees, etats", function()
    local N, b = ns, ns.minimapButton
    local calls, real = {}, ns.RunCommand
    ns.RunCommand = function(c) calls[#calls + 1] = c return real(c) end
    b.scripts.OnClick(b, "LeftButton")
    local _, m = ns.UI.MenuRows()
    assert(m and m:IsShown(), "menu ouvert")
    b.scripts.OnClick(b, "LeftButton")
    assert(not m:IsShown(), "nouveau clic = ferme")
    local function row(i) return m.rows and m.rows[i] end
    ns.ToggleMinimapMenu(b)
    local btns = N.UI.MenuRows()
    assert(#btns == 9, "9 lignes cliquables")
    local expect = { "guide", "compact", "", "lock", "reset", "probe", "here", "debug", nil }
    for i, e in ipairs(expect) do
      calls = {}
      if not m:IsShown() then ns.ToggleMinimapMenu(b) end
      btns[i].btn.scripts.OnClick(btns[i].btn)
      assert(calls[1] == e and #calls == (e and 1 or 0), "ligne " .. i .. " -> " .. tostring(calls[1]))
      local keep = btns[i].check ~= nil
      assert(m:IsShown() == keep, "ligne " .. i .. (keep and " reste ouverte" or " ferme"))
    end
    -- libelles et coches suivent l'etat
    ns.db.locked = false; ns.db.guide.compact = false; ns.db.debug = false
    m:Hide(); ns.ToggleMinimapMenu(b)
    assert(btns[4].text.text == ns.L.MENU_LOCK and btns[2].check.shown == false and btns[8].check.shown == false)
    ns.db.locked = true; ns.db.guide.compact = true; ns.db.debug = true
    m:Hide(); ns.ToggleMinimapMenu(b)
    assert(btns[4].text.text == ns.L.MENU_UNLOCK and btns[2].check.shown == true and btns[8].check.shown == true)
    calls = {}; btns[4].btn.scripts.OnClick(btns[4].btn)
    assert(calls[1] == "unlock" and ns.db.locked == false)
    ns.db.guide.compact = false; ns.db.debug = false
    ns.RunCommand = real
    m:Hide()
    if N.UI.GuideWin.win then N.UI.GuideWin.win:Hide() end
    if N.UI.GuideWin.card then N.UI.GuideWin.card:Hide() end
  end)
  check("Menu minicarte : Echap, combat, inactivite, ecran", function()
    local b = ns.minimapButton
    local _, m = ns.UI.MenuRows()
    local found
    for _, n in ipairs(UISpecialFrames) do if n == "PretreCoachMinimapMenu" then found = true end end
    assert(found, "Echap")
    ns.ToggleMinimapMenu(b); select(2, ns.UI.MenuRows()):Hide()
    assert(not m:IsShown())
    ns.ToggleMinimapMenu(b); mock.fire("PLAYER_REGEN_DISABLED")
    assert(not m:IsShown(), "ferme a l'entree en combat")
    mock.setCombat(true); mock.time = mock.time + 10
    ns.ToggleMinimapMenu(b)
    assert(not m:IsShown(), "refuse en combat avec toast")
    assert(mock.lastText == ns.L.MENU_COMBAT)
    mock.setCombat(false)
    -- inactivite : 2 s hors du menu
    ns.ToggleMinimapMenu(b)
    m.scripts.OnUpdate(m, 1.5); assert(m:IsShown())
    m.IsMouseOver = function() return true end
    m.scripts.OnUpdate(m, 1.5); m.scripts.OnUpdate(m, 1.5); assert(m:IsShown(), "souris dessus : reste")
    m.IsMouseOver = nil
    m.scripts.OnUpdate(m, 1.5); assert(m:IsShown())
    m.scripts.OnUpdate(m, 1); assert(not m:IsShown(), "ferme apres 2 s")
    -- replace dans l'ecran : bouton en bas a droite -> vers le haut et la gauche
    UIParent.GetWidth = function() return 1920 end
    UIParent.GetHeight = function() return 1080 end
    b.GetCenter = function() return 1800, 100 end
    ns.ToggleMinimapMenu(b)
    local p, _, rp = m:GetPoint()
    assert(p == "BOTTOMRIGHT" and rp == "TOPRIGHT", "bas droite : " .. tostring(p))
    m:Hide()
    b.GetCenter = function() return 100, 1000 end
    ns.ToggleMinimapMenu(b)
    p, _, rp = m:GetPoint()
    assert(p == "TOPLEFT" and rp == "BOTTOMLEFT", "haut gauche : " .. tostring(p))
    m:Hide()
    b.GetCenter, UIParent.GetWidth, UIParent.GetHeight = nil, nil, nil
  end)
  check("Minimap : clic droit = guide, compartiment", function()
    local b, n, real = ns.minimapButton, 0, ns.ToggleGuide
    ns.ToggleGuide = function() n = n + 1 end
    b.scripts.OnClick(b, "RightButton")
    suiteCompartment("x", "RightButton")
    assert(n == 2)
    ns.ToggleGuide = real
    local _, m = ns.UI.MenuRows()
    suiteCompartment("x", "LeftButton")
    assert(m:IsShown() and m:GetPoint() == "CENTER", "menu au centre sans bouton")
    suiteCompartment("x", "LeftButton", b)
    assert(not m:IsShown(), "second clic ferme")
    b.scripts.OnEnter(b)
  end)
  check("UI.Icon : Pulse, grise, raccourci", function()
    local i = ns.UI.Icon(UIParent, 40)
    i:SetIcon("x"); i:SetHotkey("1"); i:SetGrayed(true); i:Pulse(); mock.flushTimers()
  end)
  check("probe hors combat", function() SlashCmdList.PRETRECOACH("probe") end)
  local function probeText() suiteSlash("probe") return mock.lastText end
  local absent = mock.noSecrets -- passe « absentes »
  check("probe : carte, metiers, sacs, journal, addons (APIs presentes ou absentes)", function()
    local lib, ah = LibQuestieDB, Auctionator -- ce test releve des addons non installes
    LibQuestieDB, Auctionator = nil, nil
    mock.recipes, mock.sellPrice = 5, 7
    mock.fire("TRADE_SKILL_SHOW")
    local t = probeText()
    for _, h in ipairs({ "Carte et repères", "Métiers (fenêtre)", "Sacs", "Journal de donjon", "Addons optionnels" }) do
      assert(t:find("== " .. h .. " ==", 1, true), h)
    end
    assert(t:find("C_Map.SetUserWaypoint:" .. (absent and "NON" or "oui"), 1, true), "presence waypoint")
    assert(t:find("C_Container.GetContainerItemID:" .. (absent and "NON" or "oui"), 1, true), "presence sacs")
    assert(t:find("EJ_GetNumTiers:" .. (absent and "NON" or "oui"), 1, true), "presence EJ")
    assert(not mock.ejSelected, "aucune selection du journal")
    local ts = ns.db.probe.tradeskill
    if absent then
      assert(ts == nil and t:find("0 sacs", 1, true) and t:find("C_AddOns.IsAddOnLoaded absente", 1, true))
    else
      assert(ts.count == 5 and #ts.recipes == 3 and ts.recipes[1].recipeID == 101 and ts.recipes[1].learned == true, "releve metier")
      mock.recipes = 9
      mock.fire("TRADE_SKILL_SHOW")
      assert(ns.db.probe.tradeskill.count == 5, "un seul releve par session")
      assert(t:find("x et y lisibles (45.6, 78.9)", 1, true) and t:find("1 sacs, 1 emplacements", 1, true))
      assert(t:find("(11e valeur de C_Item.GetItemInfo) : 7", 1, true), "prix marchand")
      assert(t:find("instance 10 : Donjon10", 1, true) and not t:find("instance 11", 1, true), "10 instances")
      assert(t:find("2 paliers (courant : 1)", 1, true))
      assert(t:find("Questie : non installé", 1, true) and t:find("Auctionator : non installé", 1, true))
      assert(t:find("LibQuestieDB : non installé", 1, true) and t:find("Auctionator.API.v1.GetAuctionPriceByItemID : non installé", 1, true))
    end
    LibQuestieDB, Auctionator = lib, ah
    mock.fire("TRADE_SKILL_CLOSE")
  end)
  check("probe : position illisible, fenetre de metier non ouverte", function()
    mock.pos = false
    local t = probeText()
    assert(t:find("GetPlayerMapPosition : illisible", 1, true))
    mock.pos = nil
  end)
  check("probe : Questie et Auctionator presents, Auctionator qui plante", function()
    local lib0, ah0 = LibQuestieDB, Auctionator -- a restaurer : les etapes Questie plus bas en ont besoin
    mock.addons = { Questie = true, QuestieDB = true, Auctionator = true }
    _G.LibQuestieDB = { RequireContract = function(n) return n == 4 end,
      Quest = { Get = function(_, k) return ({ name = "Pierre", startedBy = { { 3000 } }, requiredLevel = 5 })[k] end },
      Npc = { Get = function(id, k) return k == "spawns" and { [85] = { { 40.5, 50 } } } or nil end } }
    _G.Auctionator = { API = { v1 = { GetAuctionPriceByItemID = function(c, id) assert(c == "PretreCoach" and id == 2589) return 123 end } } }
    local t = probeText()
    assert(t:find("RequireContract(4) : true", 1, true) and t:find("QuestDB.Get(6561) : name Pierre", 1, true), "questie")
    assert(t:find("requiredLevel 5", 1, true) and t:find("NpcDB.Get(3000, spawns) : {85={", 1, true), "pnj")
    assert(t:find("(2589, étoffe de lin) : 123", 1, true), "prix")
    if not absent then assert(t:find("Questie : chargé", 1, true) and t:find("Auctionator : chargé", 1, true)) end
    _G.Auctionator.API.v1.GetAuctionPriceByItemID = function() error("boom") end
    _G.LibQuestieDB.RequireContract = function() error("boom") end
    t = probeText()
    assert(t:find("(2589, étoffe de lin) : erreur", 1, true) and t:find("RequireContract(4) : erreur", 1, true), "erreurs absorbees")
    _G.LibQuestieDB, _G.Auctionator, mock.addons = lib0, ah0, nil
  end)
  check("/coach here : coordonnees lisibles, puis nil, historique plafonne a 20", function()
    mock.sub = "Brill"
    ns.db.places = nil -- le menu minicarte a deja releve une fois
    suiteSlash("here")
    local t = mock.lastText
    assert(t:find("Tirisfal", 1, true) and t:find("sous-zone : Brill", 1, true) and t:find("Cible : Cible", 1, true), t)
    local p = ns.db.places
    assert(#p == 1 and p[1].sub == "Brill" and p[1].target == nil and p[1].when, "la cible n'est pas sauvegardee")
    if not absent then
      assert(t:find("uiMapID 1", 1, true) and t:find("x 45.6, y 78.9", 1, true), t)
      assert(p[1].mapID == 1 and p[1].x == 45.6 and p[1].y == 78.9)
    end
    mock.pos = false
    suiteSlash("here")
    assert(mock.lastText:find("Position illisible", 1, true), mock.lastText)
    mock.pos = nil
    mock.hasTarget = false
    suiteSlash("here")
    assert(mock.lastText:find("Cible : aucune", 1, true) and ns.db.places[3].target == nil)
    mock.hasTarget = true
    if not absent then
      mock.setCombat(true)
      suiteSlash("here")
      mock.setCombat(false)
      assert(mock.lastText:find("nom illisible", 1, true) and ns.db.places[4].target == nil, "cible secrete")
    end
    for i = 1, 25 do mock.sub = "S" .. i; suiteSlash("here") end
    p = ns.db.places
    assert(#p == 20 and p[20].sub == "S25" and p[1].sub == "S6", "20 derniers releves")
    assert(ns.db.places[1].target ~= mock.SECRET)
    mock.sub = nil
  end)
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
    assert(C.TalentGap(12, nil, plan) == nil, "talents nil = illisible")
    local gap, unk = C.TalentGap(12, {}, plan)
    assert(#gap == 0 and #unk == 1 and unk[1].name == "Connexion spirituelle", "entree introuvable : inconnue, pas manquante")
    gap, unk = C.TalentGap(12, tl{ [15335] = 2 }, plan)
    assert(#gap == 1 and gap[1].have == 2 and gap[1].want == 5 and #unk == 0, "rang insuffisant : manquant")
    assert(#C.TalentGap(12, tl{ [15338] = 5 }, plan) == 0, "plan trouve")
    gap, unk = C.TalentGap(40, {}, plan)
    assert(#gap == 0 and #unk == 1 and unk[1].key == "SHADOWFORM", "respec ignore, Forme d'Ombre attendue")
    assert(#C.TalentGap(nil, {}, plan) == 0)
    -- repli par nom : le noeud porte un autre spellID, meme nom localise que le 1er spellID du plan
    local byName = { [99999] = { rank = 1, max = 5, name = "Connexion" } }
    gap, unk = C.TalentGap(12, byName, plan, function(id) return id == 15270 and "Connexion" or nil end)
    assert(#gap == 1 and gap[1].have == 1 and #unk == 0, "repli par nom")
    -- repli Classic par position
    gap = C.TalentGap(12, { pos = { [3] = { [1] = { [3] = 3 } } } }, plan)
    assert(#gap == 1 and gap[1].have == 3, "repli par position")
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
    mock.nodes = { { 15270, 5, 5 } }
    mock.fire("PLAYER_LOGIN")
    mock.flushTimers()
    assert(St.level == 12, "niveau")
    assert(C_Map and (St.mapID == 1 and St.zone == 1420) or (St.mapID == nil and St.zone == nil), "zone (chaine parentMapID)")
    assert(#msgs == 1 and msgs[1]:find("level", 1, true), "message STATE attendu")
    if C_Traits then
      assert(St.talents[15270].rank == 5 and St.talents[15270].max == 5 and St.talents[15270].name == "Sort15270")
      assert(St.unspentTalents == 0 and St.specGroups == 1 and St.wand == false)
      assert(St.profs[182].rank == 100 and St.profs[171].max == 300, "metiers")
    else
      assert(St.talents == nil and St.unspentTalents == nil and St.specGroups == nil and St.profs == nil and St.wand == nil)
    end
    local n = #msgs
    mock.fire("SPELLS_CHANGED"); mock.fire("SPELLS_CHANGED"); mock.flushTimers()
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
    if not C_Traits then return end
    local gn, sentinel = C_Traits.GetNodeInfo, { [1] = {} }
    C_Traits.GetNodeInfo = function() error("boom") end
    St.talents = nil
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.talents == nil and C.TalentGap(12, St.talents, D.TalentPlan) == nil, "talents inconnus")
    St.talents = sentinel
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.talents == sentinel, "lecture ratee : valeur precedente gardee")
    C_Traits.GetNodeInfo = gn
    mock.fire("ACTIVE_TALENT_GROUP_CHANGED"); mock.flushTimers()
    assert(St.talents ~= sentinel and St.talents[15270].rank == 5)
  end)

  check("State : talents C_Traits (plan trouve, rang insuffisant, entree introuvable), repli Classic", function()
    if not C_Traits then return end
    local function gap(level) return C.TalentGap(level, St.talents, D.TalentPlan, St.SpellName) end
    mock.nodes = { { 15335, 5, 5 } } -- un rang intermediaire du talent : meme talent
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    local g, u = gap(12)
    assert(#g == 0 and #u == 0, "plan trouve")
    mock.nodes = { { 15270, 2, 5 } }
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    g, u = gap(12)
    assert(#g == 1 and g[1].have == 2 and g[1].want == 5 and #u == 0, "rang insuffisant : manquant")
    mock.nodes = { { 1, 1, 1 } }
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    g, u = gap(12)
    assert(#g == 0 and #u == 1, "entree introuvable : inconnue, pas manquante")
    -- client Classic : GetTalentInfo existe, C_Traits non
    local keep = C_Traits
    C_Traits = nil
    GetNumTalentTabs = function() return 3 end
    GetNumTalents = function() return 1 end
    GetTalentInfo = function() return "Talent", 0, 1, 3, 4, 5 end
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    g = gap(12)
    GetNumTalentTabs, GetNumTalents, GetTalentInfo, C_Traits = nil, nil, nil, keep
    assert(#g == 1 and g[1].have == 4, "position Classic")
    mock.nodes = { { 15270, 5, 5 } }
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
  end)

  check("State : unspentTalents par GetNumUnspentTalents, puis HasUnspentTalentPoints, sinon nil", function()
    if not C_ClassTalents then return end
    mock.unspent = 3
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.unspentTalents == 3, "GetNumUnspentTalents")
    local keep = GetNumUnspentTalents
    GetNumUnspentTalents = nil
    mock.unspent = 0
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.unspentTalents == 0, "booleen faux = 0")
    mock.unspent = 2
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.unspentTalents == 1, "booleen vrai = 1, recu " .. tostring(St.unspentTalents))
    local keepC = C_ClassTalents
    C_ClassTalents = nil
    St.unspentTalents = nil
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
    assert(St.unspentTalents == nil, "aucune API : inconnu")
    C_ClassTalents, GetNumUnspentTalents = keepC, keep
    mock.unspent = nil
    mock.fire("PLAYER_TALENT_UPDATE"); mock.flushTimers()
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
    local gp = GetProfessions
    GetProfessions = nil
    GetNumSkillLines = function() return 1 end -- absent de ce client : repli Classic seulement s'il existe
    GetSkillLineInfo = function() return "Herboristerie", false, 0, 120, 0, 0, 300 end
    mock.fire("SKILL_LINES_CHANGED"); mock.flushTimers()
    GetProfessions, GetNumSkillLines, GetSkillLineInfo = gp, nil, nil
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
    mock.fire("SPELLS_CHANGED")
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

  check("Timers : Douleur lancee avec un GUID lisible retrouvee si le GUID devient illisible, sans double compte", function()
    local T = N.Timers
    mock.time, mock.guid = 700, "G"
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 589)
    assert(T.HasSWP() and T.SWPCount() == 1)
    mock.noGuid = true
    assert(T.HasSWP() == true, "GUID devenu illisible : Douleur de la cible actuelle")
    assert(T.SWPCount() == 1, "meme cible comptee une fois")
    mock.noGuid = false
    mock.fire("PLAYER_TARGET_CHANGED")
    mock.time = 800
    assert(T.SWPCount() == 0)
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
      local list = (key and (key:find("^r%d") or key:find("^pc:"))) and out.rtoasts or out.toasts
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
    assert(st(ev(n, "spirittap")) == "unknown", "aucun noeud correspondant : inconnu")
    n.State.talents = tl{ [15270] = 4 }
    assert(st(ev(n, "spirittap")) == "todo")
    n.State.talents[15270].rank = 5
    assert(st(ev(n, "spirittap")) == "done")
    n.State.level, n.State.talents = 41, tl{ [14526] = 2 }
    assert(st(ev(n, "wandspec2")) == "done" and ev(n, "wandspec") == nil, "plan de 41+ : meme talent, un autre rang connu")
    n.State.talents = tl{ [14524] = 0 }
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
    setState(n, { level = 12, talents = tl{ [15270] = 3 } })
    n.Fire("STATE", { "level" })
    assert(#o.toasts == 0 and o.gui == 0, "premiere evaluation : silence")
    n.State.talents[15270].rank = 5
    n.Fire("STATE", { "talents" })
    assert(#o.toasts == 1 and o.gui == 1, "un seul toast, recu " .. #o.toasts)
    assert(o.toasts[1].text == "Connexion spirituelle 5/5 : bien joué" and o.toasts[1].key == "obj:spirittap")
    assert(n.db.guide.done.spirittap == true, "id fait memorise")
    n.Fire("STATE", { "talents" })
    assert(#o.toasts == 1 and o.gui == 1, "pas de doublon")
    n.State.talents[15270].rank = 4; n.Fire("STATE", {})
    n.State.talents[15270].rank = 5; n.Fire("STATE", {})
    assert(#o.toasts == 1, "deja annonce : memorise")
    local o2 = fresh(n.db) -- rechargement : objectif deja fait, aucune annonce
    setState(o2.n, { level = 12, talents = tl{ [15270] = 5 } })
    o2.n.Fire("STATE", {})
    assert(#o2.toasts == 0 and o2.gui == 0)
    local o3 = fresh() -- base neuve mais objectif deja fait au premier passage
    setState(o3.n, { level = 12, talents = tl{ [15270] = 5 } })
    o3.n.Fire("STATE", {})
    assert(#o3.toasts == 0 and o3.n.db.guide.done.spirittap == true)
  end)

  check("Guide : toast de palier avec les 3 priorites, report en combat", function()
    local o = fresh()
    local n = o.n
    knows({})
    setState(n, { level = 39, specGroups = 1, talents = tl{ [14524] = 0 } })
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
    n.State.talents = tl{ [14524] = 2 }
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
    setState(n, { level = 12, talents = tl{ [14524] = 0, [15270] = 0 }, profs = {} })
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
    -- sans Forme d'Ombre apprise (avant le 40 ou sans le talent) le palier reste le 2 : on ne la donne que du 40
    local known, cdv = o.known, o.cd or {}
    if not known then
      known = {}
      for k, v in pairs(FULL) do known[k] = v end
      if (o.level or 12) < 40 then known.SHADOWFORM = nil end
    end
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
    rk(merge(o, { cdNil = true, swpNil = true }), "SHOOT,SWP", "Timers degrade : Douleur en 2e, pas d'Attaque mentale supposee prete")
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
    rk(merge(o, { shadowformActive = false }), "SHADOWFORM,SWP,SHOOT", "Forme d'Ombre absente au 40, mana illisible")
    rk(merge(o, { shadowformActive = false, manaPct = 80 }), "SHADOWFORM,MINDBLAST,SWP", "idem, mana lisible")
    rk(merge(o, { shadowformActive = true, manaPct = 80 }), "MINDBLAST,SWP,SWD", "Forme d'Ombre active")
    rk(merge(o, { shadowformActive = true }), "SWP,SHOOT", "mana illisible : ni Attaque mentale ni Mort")
    rk(merge(o, { manaPct = 80 }), "MINDBLAST,SWP,SWD", "Forme d'Ombre illisible : pas de rappel")
    rk(merge(o, { shadowformActive = false, inCombat = true, manaPct = 80 }), "MINDBLAST,SWP,SWD", "pas de rappel en combat")
    rk(merge(o, { shadowformActive = false, known = { SWP = 1 } }), "SWP,SHOOT", "Forme d'Ombre non apprise : palier 2")
    rk(merge(o, { shadowformActive = false, known = { SWP = 1, MINDBLAST = 1 }, manaPct = 80 }), "MINDBLAST,SWP,SHOOT",
      "Forme d'Ombre non apprise : ouverture du palier 2")
    rk(merge(o, { shadowformActive = true, known = { SWP = 1, SWD = 1 }, manaPct = 80 }), "SWP,SWD,SHOOT",
      "Forme d'Ombre active sans etre apprise (lecture de l'aura) : palier 3")
    rk(merge(o, { level = 39, shadowformActive = false, manaPct = 80 }), "MINDBLAST,SWP,SHOOT", "pas avant 40")
    rk(merge(o, { level = 45, weakenedSoul = false, shadowformActive = true, manaPct = 80 }), "PWS,MINDBLAST,SWP", "Bouclier d'abord")
    local c = merge(o, { level = 45, inCombat = true, hasSWP = true })
    rk(c, "SHOOT", "mana illisible, Douleur posee : baguette")
    rk(merge(c, { manaPct = 80 }), "SWD,MINDBLAST,MINDFLAY", "Mort, Attaque mentale puis Fouet mental")
    rk(merge(c, { manaPct = 29 }), "SHOOT", "mana sous 30 % : ni Mort ni Attaque mentale")
    rk(merge(c, { manaPct = 80, cd = { MINDBLAST = 5, SWD = 5 } }), "MINDFLAY,SHOOT,MINDBLAST", "Fouet mental pour combler")
    rk(merge(c, { cd = { MINDBLAST = 5, SWD = 5 } }), "SHOOT,MINDBLAST,SWD", "mana secret : pas de Fouet mental")
    rk(merge(c, { cdNil = true, manaPct = 80 }), "MINDFLAY,SHOOT", "recharges inconnues")
    rk(merge(c, { cdNil = true, hasWand = false, known = { SWP = 1 } }), "MELEE", "sans baguette, tout inconnu")
    -- mana illisible : Douleur si absente, puis baguette, sinon Fouet mental
    rk(merge(c, { hasSWP = false }), "SWP,SHOOT", "Douleur absente, baguette")
    rk(merge(c, { hasWand = false }), "MINDFLAY,SMITE,MELEE", "sans baguette : Fouet mental")
    rk(merge(c, { hasWand = false, hasSWP = false }), "SWP,MINDFLAY,SMITE", "sans baguette, Douleur absente")
  end)

  check("Rotation : Douleur inconnue en combat, jamais en premier", function()
    local o = { level = 20, hasWand = true, inCombat = true, swpNil = true }
    local res = rk(o, "SHOOT,SWP", "avec baguette")
    assert(res.text == N.L.ROT_SWP_UNKNOWN, "texte dedie")
    rk(merge(o, { level = 8 }), "SHOOT,SWP", "palier 1")
    rk(merge(o, { hasWand = false }), "SMITE,SWP,MELEE", "sans baguette : 2e apres le sort principal")
    rk(merge(o, { hasWand = false, known = { SWP = 1 } }), "MELEE,SWP", "sans baguette ni autre sort")
    res = rk(merge(o, { hasWand = false }), "SMITE,SWP,MELEE")
    assert(res.text == N.L.ROT_SMITE, "le texte reste celui du sort principal")
    rk(merge(o, { inCombat = false }), "SHOOT", "hors combat : rien")
    rk(merge(o, { known = {} }), "SHOOT", "Douleur non apprise")
    rk(merge(o, { manaPct = 10 }), "SHOOT", "mana trop bas")
    rk(merge(o, { level = 45, manaPct = 80, shadowformActive = true }), "SHOOT,SWP,SWD", "palier 3 : baguette, Douleur, Mort")
  end)

  check("Rotation : Flammes sacrees une seule fois par cible", function()
    local o = { level = 20, hasWand = true, inCombat = true, cd = { MINDBLAST = 5 } }
    rk(o, "HOLYFIRE,SWP,SHOOT")
    rk(merge(o, { holyDone = false }), "HOLYFIRE,SWP,SHOOT")
    rk(merge(o, { holyDone = true }), "SWP,SHOOT,MINDBLAST", "deja lancees : Douleur")
  end)

  check("Rotation : groupe de monstres, Douleur sur les autres cibles", function()
    local o = { level = 20, hasWand = true, inCombat = true, hasSWP = false }
    rk(merge(o, { swpCount = 0 }), "MINDBLAST,SWP,SHOOT", "aucune autre Douleur : ouverture normale")
    for _, n in ipairs({ 1, 2, 3 }) do
      local res = rk(merge(o, { swpCount = n }), "SWP,SHOOT", n .. " Douleurs")
      assert(res.text == N.L.ROT_SWP_GROUP)
    end
    rk(merge(o, { swpCount = 4 }), "SHOOT", "au-dela de 4 cibles : baguette")
    rk(merge(o, { swpCount = 2, inCombat = false }), "MINDBLAST,SWP,SHOOT", "hors combat : pas de groupe")
    rk(merge(o, { swpCount = 2, hasSWP = true }), "SHOOT", "Douleur deja sur cette cible")
    rk(merge(o, { swpCount = 2, level = 8 }), "SWP,SHOOT", "palier 1")
    rk(merge(o, { swpCount = 2, known = {} }), "SHOOT", "Douleur non apprise")
    local nc = merge(o, {}) nc.swpCount = nil
    rk(nc, "MINDBLAST,SWP,SHOOT", "compte inconnu : ouverture normale")
  end)

  check("Rotation : Forme d'Ombre active, aucun sort du Sacre ; le Bouclier reste permis", function()
    for _, k in ipairs({ "SMITE", "HOLYFIRE", "LESSERHEAL", "HEAL", "GREATERHEAL", "FLASHHEAL", "RENEW", "POH", "HOLYNOVA",
      "RESURRECTION" }) do
      local found
      for _, sp in ipairs(N.Data.Spells) do if sp.key == k then found = sp.school end end
      assert(found == "holy", k .. " : school = holy")
    end
    local o = { level = 45, known = { SMITE = 1, SHADOWFORM = 1 }, hasWand = false, hasSWP = true, inCombat = true,
      manaPct = 80, targetHpPct = 80 }
    rk(merge(o, { shadowformActive = false }), "SMITE,MELEE", "sans Forme d'Ombre : Chatiment")
    rk(merge(o, { shadowformActive = true }), "MELEE", "Forme d'Ombre active : pas de Chatiment")
    rk(merge(o, { shadowformActive = true, known = { PWS = 1, SHADOWFORM = 1 }, inCombat = false, weakenedSoul = false }),
      "PWS,MELEE", "Bouclier permis")
  end)

  check("Rotation : Tir seulement avec une baguette lue et le niveau 5", function()
    local o = { known = {}, hasWand = true, inCombat = true }
    rk(merge(o, { level = 4 }), "MELEE", "niveau 4")
    rk(merge(o, { level = 5 }), "SHOOT", "niveau 5")
    rk(merge(o, { level = 5, hasWand = false }), "MELEE", "sans baguette")
    local nw = merge(o, { level = 5 }) nw.hasWand = nil
    rk(nw, "MELEE", "baguette inconnue")
  end)

  check("Rotation : hysteresis de l'Attaque mentale (60/50) et du Fouet mental (30/25), memoire passee par ctx", function()
    local o = { level = 20, hasWand = true, inCombat = true, hasSWP = true }
    rk(merge(o, { manaPct = 55, mbHigh = true }), "MINDBLAST,SHOOT", "55 % apres etre monte : toujours conseillee")
    rk(merge(o, { manaPct = 55, mbHigh = false }), "SHOOT", "55 % apres etre descendu : non")
    rk(merge(o, { manaPct = 55 }), "SHOOT", "sans memoire, le seuil haut decide")
    rk(merge(o, { manaPct = 60 }), "MINDBLAST,SHOOT", "60 % sans memoire")
    rk(merge(o, { manaPct = 80, mbHigh = false }), "SHOOT", "la memoire prime (Context la tient a jour)")
    rk(merge(o, { mbHigh = true }), "SHOOT", "mana illisible : jamais")
    local c = merge(o, { level = 45, shadowformActive = true, manaPct = 28 })
    rk(merge(c, { flayHigh = true }), "MINDFLAY,SHOOT", "28 % apres etre monte : Fouet mental")
    rk(merge(c, { flayHigh = false }), "SHOOT", "28 % apres etre descendu : non")
    rk(merge(c, { flayHigh = true, manaPct = 24 }), "MINDFLAY,SHOOT", "la memoire prime ici aussi")
  end)

  check("Rotation : carte Recupere (vie et mana secrets), seuils lisibles prioritaires", function()
    local sec = { hasHostileTarget = false, recover = true }
    sec.hpPct, sec.manaPct = nil, nil
    local corpse = merge(sec, { targetDead = true, targetCreatureType = N.L.CT_HUMANOID, cannibalUsable = true, bandageCount = 2, recentlyBandaged = false })
    rk(corpse, "CANNIBAL,BANDAGE,DARKSAC", "secret + fenetre : cadavre, bandage, Sacrifice sombre (3 conseils max)")
    assert(N.Rotation.Compute(rctx(corpse)).text:find(N.L.ROT_RECOVER, 1, true), "titre Recupere")
    rk(merge(sec, {}), "DARKSAC,DRINK,EAT", "sans cadavre ni bandage")
    local off = merge(sec, { recover = false }) rk(off, "", "fenetre close : baguette seule")
    rk(merge(sec, { inCombat = true }), "", "en combat : rien")
    assert(not N.Rotation.Compute(rctx(merge(sec, { hasHostileTarget = true }))).text:find(N.L.ROT_RECOVER, 1, true), "cible hostile : pas de carte")
    -- seuils lisibles : ils priment, la carte n'apparait pas
    local ok = merge(sec, { hpPct = 100, manaPct = 100 })
    rk(ok, "", "lisible et plein : rien malgre la fenetre")
    local r = N.Rotation.Compute(rctx(merge(ok, { manaPct = 20 })))
    assert(not r.text:find(N.L.ROT_RECOVER, 1, true), "pas de titre si lisible")
    rk(merge(ok, { manaPct = 20 }), "DARKSAC,DRINK", "mana lisible bas : seuils habituels")
  end)

  check("Rotation : Context ouvre la fenetre Recupere 30 s apres le combat", function()
    isolated(function()
      local n = loadAddon()
      mock.hasTarget = false
      mock.time = 100
      assert(n.Rotation.Context().recover == false, "avant tout combat")
      mock.fire("PLAYER_REGEN_DISABLED")
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(n.Rotation.Context().recover == true, "juste apres")
      mock.time = 129
      assert(n.Rotation.Context().recover == true, "29 s")
      mock.time = 131
      assert(n.Rotation.Context().recover == false, "31 s")
      mock.time = 100
      assert(n.Rotation.Context().recover == true, "rouverte (horloge remontee)")
      mock.hasTarget = true
      assert(n.Rotation.Context().recover == false, "cible hostile")
      mock.hasTarget = false
      assert(n.Rotation.Context().recover == false, "cible hostile : fenetre fermee pour de bon")
      mock.fire("PLAYER_REGEN_ENABLED")
      mock.setCombat(true)
      assert(n.Rotation.Context().recover == false, "en combat")
      mock.setCombat(false)
      mock.fire("PLAYER_REGEN_DISABLED")
      assert(n.Rotation.Context().recover == false, "nouveau combat")
      -- vitales lisibles : la fenetre existe mais les seuils priment dans Compute
      mock.fire("PLAYER_REGEN_ENABLED")
      mock.vitalsReadable = true
      local c = n.Rotation.Context()
      assert(c.recover == true and c.hpPct == 100 and c.manaPct == 100)
      assert(#n.Rotation.Compute(c).keys == 0, "lisible et plein : pas de carte")
    end, function() mock.hasTarget, mock.time, mock.vitalsReadable = true, 0, nil mock.setCombat(false) end)
  end)

  check("aucune globale absente du client Forever n'est appelee", function()
    isolated(function()
      local absent = { "GetSpellInfo", "GetSpellCooldown", "IsUsableSpell", "IsSpellInRange", "IsQuestFlaggedCompleted",
        "GetItemInfo", "GetItemInfoInstant",
        "UnitCharacterPoints", "InterfaceOptions_AddCategory" }
      local hits = {}
      for _, name in ipairs(absent) do
        assert(rawget(_G, name) == nil, name .. " ne doit pas exister dans le mock")
        rawset(_G, name, function() hits[#hits + 1] = name end)
      end
      local ok, err = pcall(function()
        local n = loadAddon()
        mock.fire("ADDON_LOADED", ADDON)
        mock.fire("PLAYER_LOGIN")
        for _, e in ipairs({ "SPELLS_CHANGED", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LEVEL_UP",
          "ACTIVE_TALENT_GROUP_CHANGED", "TRAINER_SHOW", "PLAYER_EQUIPMENT_CHANGED" }) do mock.fire(e) end
        n.Rotation.Context()
        SlashCmdList.PRETRECOACH("probe")
      end)
      for _, name in ipairs(absent) do rawset(_G, name, nil) end
      assert(ok, err)
      assert(#hits == 0, "globale absente appelee : " .. table.concat(hits, ","))
    end)
  end)

  check("Rotation : Cri psychique absent du texte si aucun conseil", function()
    local res = N.Rotation.Compute(rctx({ level = 20, hasHostileTarget = false, hpPct = 100, manaPct = 100, targetMelee = true }))
    assert(#res.keys == 0 and not res.text:find(N.L.ROT_PSCREAM, 1, true))
    res = N.Rotation.Compute(rctx({ level = 20, inCombat = true, hasWand = true, hasSWP = true, targetMelee = true }))
    assert(res.keys[2] == "PSCREAM" and res.text:find(N.L.ROT_PSCREAM, 1, true))
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
    mock.vitalsReadable = true
    local c = n.Rotation.Context()
    assert(c.level == 12 and c.inCombat == false and c.hasHostileTarget == true and c.hasWand == true)
    assert(c.knows == n.State.Knows and type(c.cd) == "function")
    assert(c.manaPct == 100 and c.hpPct == 100 and c.targetHpPct == 100 and c.targetMelee == false)
    assert(c.weakenedSoul == true and c.shieldUp == false and c.shadowformActive == false and c.smitesOnTarget == 0)
    mock.hasTarget = false
    c = n.Rotation.Context()
    assert(c.hasHostileTarget == false and c.bandageCount == nil and c.recentlyBandaged == nil, "vie pleine : ni bandages ni aura lus")
    mock.hp = 40
    c = n.Rotation.Context()
    assert(c.hasHostileTarget == false and c.bandageCount == (GetItemCount and 3 or 0), "bandages : rang et anti-venin exclus")
    mock.hp = nil
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
    mock.items, mock.auras, mock.vitalsReadable = nil, nil, nil
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
      mock.flushTimers() -- les evenements sont regroupes sur 0,2 s
      assert(n.Rotation.Hotkey("SWP") == "F5", "cache invalide sur UPDATE_BINDINGS")
      -- sans C_ActionBar : scan de GetActionInfo, hors combat seulement
      C_ActionBar = nil
      mock.actions = { [26] = 594 }
      mock.bindings = { MULTIACTIONBAR3BUTTON2 = "F2", ACTIONBUTTON1 = "1" }
      mock.fire("ACTIONBAR_SLOT_CHANGED")
      mock.flushTimers()
      mock.setCombat(true)
      assert(n.Rotation.Hotkey("SWP") == nil and scans == 0, "pas de scan en combat")
      mock.setCombat(false)
      assert(n.Rotation.Hotkey("SWP") == "F2", "scan hors combat, barre de droite")
      assert(scans == 180, "180 emplacements scannes une fois : " .. scans)
      n.Rotation.Hotkey("SWP") n.Rotation.Hotkey("SMITE")
      assert(scans == 180, "scan reutilise")
      mock.actions = { [1] = 585 }
      mock.fire("ACTIONBAR_SLOT_CHANGED")
      mock.flushTimers()
      assert(n.Rotation.Hotkey("SMITE") == "1" and scans == 360, "cache invalide sur ACTIONBAR_SLOT_CHANGED")
      assert(n.Rotation.Hotkey("SWP") == nil, "sort retire des barres")
      -- plusieurs emplacements : le premier qui a un raccourci ; barres 5 et 6
      mock.actions = { [2] = 594, [30] = 594, [145] = 585, [157] = 589 }
      mock.bindings = { MULTIACTIONBAR3BUTTON6 = "F6", MULTIACTIONBAR5BUTTON1 = "N1", MULTIACTIONBAR6BUTTON1 = "N2" }
      mock.fire("UPDATE_BINDINGS")
      mock.flushTimers()
      assert(n.Rotation.Hotkey("SWP") == "F6", "emplacement 2 sans raccourci, 30 avec")
      assert(n.Rotation.Hotkey("SMITE") == "N1", "barre 5 (145)")
      C_ActionBar = { FindSpellActionButtons = function(id) if id == 10894 then return { 2, 30 } end end }
      mock.fire("UPDATE_BINDINGS")
      mock.flushTimers()
      assert(n.Rotation.Hotkey("SWP") == "F6", "Find : premier emplacement avec raccourci")
      mock.actions = { [157] = 10894 }
      C_ActionBar = nil
      mock.fire("UPDATE_BINDINGS")
      mock.flushTimers()
      assert(n.Rotation.Hotkey("SWP") == "N2", "barre 6 (157)")
    end, function()
      C_ActionBar, GetActionInfo = keepAB, keepGAI
      mock.bindings, mock.actions = nil, nil
      mock.setCombat(false)
    end)
  end)

  -- Compteur d'appels aux auras du joueur et aux bandages (lectures a eviter en combat)
  local function counting(fn)
    local auraCalls, itemCalls = 0, 0
    local keepA, keepI = C_UnitAuras.GetPlayerAuraBySpellID, GetItemCount
    C_UnitAuras.GetPlayerAuraBySpellID = function(...) auraCalls = auraCalls + 1 return keepA(...) end
    if keepI then GetItemCount = function(...) itemCalls = itemCalls + 1 return keepI(...) end end
    local ok, err = pcall(fn, function() return auraCalls, itemCalls end, function() auraCalls, itemCalls = 0, 0 end)
    C_UnitAuras.GetPlayerAuraBySpellID, GetItemCount = keepA, keepI
    mock.setCombat(false)
    mock.hp, mock.mana, mock.hasTarget = nil, nil, true
    if not ok then error(err, 0) end
  end

  check("Rotation : Context ne lit que le necessaire (auras, bandages) selon le combat", function()
    isolated(function()
      local n = loadAddon()
      n.State.level, n.State.profs = 20, { [129] = { rank = 30, max = 75 } }
      counting(function(calls, zero)
        mock.setCombat(true)
        n.Rotation.Context()
        local a, i = calls()
        assert(a == 1 and i == 0, "en combat : seule la Forme d'Ombre (" .. a .. " auras, " .. i .. " objets)")
        zero() mock.setCombat(false)
        n.Rotation.Context()
        a = calls()
        assert(a > 1, "hors combat avec cible hostile : Bouclier et Ame affaiblie lus")
        zero() mock.hasTarget = false
        local c = n.Rotation.Context()
        a, i = calls()
        assert(a == 1 and i == 0 and c.bandageCount == nil, "sans cible, vie pleine : ni bandages ni aura de bandage")
        zero() mock.hp, mock.vitalsReadable = 40, true
        c = n.Rotation.Context()
        a, i = calls()
        assert(a == 2 and c.bandageCount ~= nil and (GetItemCount == nil or i > 0), "vie basse : bandages lus")
        zero() mock.setCombat(true)
        n.Rotation.Context()
        a, i = calls()
        assert(a == 1 and i == 0, "vie basse mais en combat : pas de bandages")
      end)
    end, function() mock.hp, mock.vitalsReadable = nil, nil end)
  end)

  check("Rotation : recharge reelle hors combat quand Timers est degrade, inconnue en combat", function()
    isolated(function()
      local n = loadAddon()
      mock.time = 100
      knows({ [8092] = true })
      local id = n.Rotation.SpellID("MINDBLAST")
      local keepC = C_Spell.GetSpellCooldown
      local ok, err = pcall(function()
        mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "illisible" or mock.SECRET) -- Timers degrade
        local c = n.Rotation.Context()
        assert(n.Timers.CooldownRemaining("MINDBLAST") == nil, "Timers degrade")
        if not id then assert(c.cd("MINDBLAST") == nil, "sort inconnu : recharge inconnue") return end
        assert(c.cd("MINDBLAST") == 0, "pas de recharge : prete")
        mock.cooldowns = { [id] = { 95, 8 } }
        assert(c.cd("MINDBLAST") == 3, "recharge en cours : " .. tostring(c.cd("MINDBLAST")))
        mock.cooldowns = { [id] = { 100, 1.5 } }
        assert(c.cd("MINDBLAST") == 0, "recharge globale seule : prete")
        mock.cooldowns = { [id] = { 0, 0 } }
        assert(c.cd("MINDBLAST") == 0 and c.cd("SWD") == nil, "sort non appris : inconnue")
        C_Spell.GetSpellCooldown = nil -- repli Classic, seulement si la globale existe
        GetSpellCooldown = function() return 95, 8, 1 end
        mock.cooldowns = { [id] = { 95, 8 } }
        assert(c.cd("MINDBLAST") == 3, "ancienne API")
        GetSpellCooldown = nil
        assert(c.cd("MINDBLAST") == nil, "ni C_Spell ni globale : inconnue")
        C_Spell.GetSpellCooldown = keepC
        mock.setCombat(true)
        assert(c.cd("MINDBLAST") == nil, "en combat : jamais suppose pret")
        mock.setCombat(false)
        mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585) -- Timers redevient lisible : sa valeur prime
        assert(c.cd("MINDBLAST") == 0, "Timers lisible : sa valeur")
      end)
      C_Spell.GetSpellCooldown = keepC
      mock.cooldowns = nil
      knows(nil)
      if not ok then error(err, 0) end
    end, function() mock.setCombat(false) end)
  end)

  check("Rotation : le Context tient l'hysteresis de mana", function()
    isolated(function()
      local n = loadAddon()
      mock.vitalsReadable = true
      local function st(mana) mock.mana = mana local c = n.Rotation.Context() return c.mbHigh, c.flayHigh end
      local mb, fl = st(70) assert(mb == true and fl == true)
      mb, fl = st(55) assert(mb == true and fl == true, "55 % : reste haut")
      mb, fl = st(49) assert(mb == false and fl == true, "sous 50 % : Attaque mentale arretee")
      mb = st(55) assert(mb == false, "55 % apres etre descendu")
      mb = st(60) assert(mb == true)
      mb, fl = st(24) assert(mb == false and fl == false, "sous 25 % : Fouet mental arrete")
      _, fl = st(27) assert(fl == false, "27 % : toujours arrete")
      _, fl = st(30) assert(fl == true)
      if not mock.noSecrets then
        mock.setCombat(true)
        mock.vitalsReadable = false
        mb, fl = st(10)
        assert(mb == false and fl == true, "mana secret : etat conserve")
      end
    end, function() mock.mana, mock.vitalsReadable = nil, nil mock.setCombat(false) end)
  end)

  check("Rotation : Flammes sacrees notees par GUID, remises a zero hors combat ; sans GUID, au changement de cible", function()
    isolated(function()
      local n = loadAddon()
      mock.guid = "A"
      assert(n.Rotation.Context().holyDone == false)
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 14914)
      assert(n.Rotation.Context().holyDone == true, "cible A")
      mock.guid = "B"
      assert(n.Rotation.Context().holyDone == false, "cible B")
      mock.guid = "A"
      assert(n.Rotation.Context().holyDone == true, "retour sur A")
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(n.Rotation.Context().holyDone == false, "oublie apres le combat")
      mock.noGuid = true
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 14914)
      assert(n.Rotation.Context().holyDone == true, "GUID illisible : drapeau de la cible actuelle")
      mock.fire("PLAYER_TARGET_CHANGED")
      assert(n.Rotation.Context().holyDone == false, "remis a zero au changement de cible")
    end, function() mock.noGuid, mock.guid = nil, "Creature-0" end)
  end)

  check("Rotation : un changement de cible = une seule mise a jour, dans les deux ordres d'ecouteurs", function()
    isolated(function()
      local n = loadAddon()
      local Ro = n.Rotation
      local updates, orig = 0, Ro.Update
      Ro.Update = function(...) updates = updates + 1 return orig(...) end
      mock.time = 10
      mock.fire("PLAYER_TARGET_CHANGED") -- Timers (TIMERS) puis Rotation
      assert(updates == 1, "une mise a jour (" .. updates .. ")")
      mock.time = 11
      n.Fire("TIMERS")
      assert(updates == 2, "TIMERS seul : une mise a jour (" .. updates .. ")")
      mock.time = 12
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
      assert(updates >= 3, "un lancer de sort (TIMERS) : mise a jour (" .. updates .. ")")
      Ro.Update = orig
    end)
  end)

  check("Raccourcis : evenements regroupes sur 0,2 s, jamais de vidage en combat", function()
    local keepAB = C_ActionBar
    isolated(function()
      local n = loadAddon()
      local rot = 0
      n.Listen("ROTATION", function() rot = rot + 1 end)
      C_ActionBar = { FindSpellActionButtons = function(id) if id == 10894 then return { 3 } end end }
      mock.bindings = { ACTIONBUTTON3 = "F1" }
      assert(n.Rotation.Hotkey("SWP") == "F1")
      mock.bindings = { ACTIONBUTTON3 = "F2" }
      if C_Timer then
        mock.timers = {}
        for _ = 1, 3 do mock.fire("ACTIONBAR_SLOT_CHANGED") end
        mock.fire("UPDATE_BINDINGS")
        assert(#mock.timers == 1, "un seul regroupement en attente (" .. #mock.timers .. ")")
        assert(n.Rotation.Hotkey("SWP") == "F1", "rien avant l'echeance")
        mock.flushTimers()
        assert(n.Rotation.Hotkey("SWP") == "F2", "un rescan a l'echeance")
      else
        mock.fire("UPDATE_BINDINGS")
        assert(n.Rotation.Hotkey("SWP") == "F2", "sans minuteur : immediat")
      end
      -- en combat : le cache n'est pas vide, le rescan attend la sortie de combat
      mock.bindings = { ACTIONBUTTON3 = "F3" }
      mock.setCombat(true)
      mock.fire("UPDATE_BINDINGS")
      mock.flushTimers()
      assert(n.Rotation.Hotkey("SWP") == "F2", "cache conserve en combat")
      mock.setCombat(false)
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(n.Rotation.Hotkey("SWP") == "F3", "rescan a la sortie de combat")
    end, function() C_ActionBar = keepAB mock.bindings = nil mock.setCombat(false) end)
  end)

  check("RotationPanel : un Render force ne fait pas clignoter, un vrai changement oui", function()
    local keep = PretreCoachDB
    isolated(function()
      local n, P = panel()
      local res = { keys = { "SHOOT" }, text = "Arrete", stop = true }
      n.Fire("ROTATION", res)
      assert(P.log.pulse == 1)
      P.Render(res) P.Render(res)
      assert(P.log.pulse == 1, "Render force avec le meme conseil : pas de pulse")
      n.Fire("ROTATION", { keys = { "SHOOT" }, text = "Tir" })
      assert(P.log.pulse == 1, "stop termine : pas de pulse")
      n.Fire("ROTATION", res)
      assert(P.log.pulse == 2, "stop de nouveau : pulse")
    end, function() PretreCoachDB = keep end)
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

  ------------------------------------------------------------------------
  -- L8 : maitre (Training), talents (Talents), metiers (Professions)
  ------------------------------------------------------------------------
  local function pcToasts(o, pat)
    local out = {}
    for _, t in ipairs(o.rtoasts) do if t.key and t.key:find(pat) then out[#out + 1] = t end end
    return out
  end
  local function knownUpTo(n, lvl)
    local ids = {}
    for _, sp in ipairs(n.Data.Spells) do for _, r in ipairs(sp.ranks) do if r.level and r.level <= lvl then ids[r.id] = true end end end
    return ids
  end
  local hasKnows = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)

  check("Training : level up 9->10, toast avec noms et rangs, compteur", function()
    local o = fresh()
    local n = o.n
    knows(knownUpTo(n, 5))
    setState(n, { level = 9 })
    n.Fire("STATE", { "level" })
    assert(#o.rtoasts == 0, "premier STATE : silence")
    n.State.level = 10
    n.Fire("STATE", { "level" })
    local t = pcToasts(o, "^pc:train:")
    if not hasKnows then
      assert(#t == 0 and n.Training.PendingCount() == nil and n.Training.CountText() == "", "API absente : rien")
      return
    end
    local p = n.Calc.PendingSpells(10, n.State.Knows)
    assert(#t == 1 and t[1].key == "pc:train:10" and #p > 0, "un toast")
    assert(t[1].text:find("^Nouveaux sorts chez ton maître : "), t[1].text)
    assert(t[1].text:find("Sort591 (rang 2)", 1, true) and t[1].text:find("Sort594 (rang 2)", 1, true), t[1].text)
    assert((#p > 4) == (t[1].text:find("…", 1, true) ~= nil), "au plus 4 noms puis …")
    assert(n.Training.PendingCount() == #p and n.Training.CountText():find("à apprendre", 1, true))
    n.State.level = 10
    n.Fire("STATE", { "spells" })
    assert(#pcToasts(o, "^pc:train:") == 1, "pas de doublon sans nouveau niveau")
    knows(nil)
  end)

  check("Training : every = 2, pas de toast au niveau impair, compteur juste, affichage", function()
    if not hasKnows then return end
    local o = fresh()
    local n = o.n
    n.db.training = { every = 2 }
    knows(knownUpTo(n, 5))
    setState(n, { level = 8 })
    n.Fire("STATE", { "level" })
    n.State.level = 9
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:train:") == 0, "niveau impair : pas de toast")
    local c = n.Training.PendingCount()
    assert(c and c > 0 and n.Training.CountText():find("^%d+ sorts? à apprendre$"), "compteur juste")
    n.ToggleGuide()
    local G = n.UI.GuideWin
    assert(G.win.count.text == n.Training.CountText(), "compteur dans l'en-tête")
    n.SetCompact(true)
    assert(G.card.count.text == n.Training.CountText(), "compteur sur la carte compacte")
    n.SetCompact(false)
    n.ToggleGuide()
    n.State.level = 10
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:train:") == 1, "niveau pair : toast")
    knows(nil)
  end)

  check("Training : TRAINER_SHOW memorise les services et liste ceux a apprendre", function()
    if not GetNumTrainerServices then return end
    local keep = { GetTrainerServiceInfo, GetTrainerServiceLevelReq, GetTrainerServiceCost, GetCoinTextureString }
    isolated(function()
      local o = fresh()
      local n = o.n
      GetTrainerServiceInfo = function(i) return "Sort" .. i, i == 2 and "Rang 2" or "", i == 2 and "available" or (i == 1 and "used" or "unavailable") end
      GetTrainerServiceLevelReq = function(i) return 10 + i end
      GetTrainerServiceCost = function(i) return i * 6000 end
      mock.fire("TRAINER_SHOW")
      local s = n.db.trainer["Sort2|Rang 2"]
      assert(s and s.level == 12 and s.cost == 12000 and s.category == "available", "service memorise")
      assert(n.db.trainer["Sort1|"].category == "used" and n.db.trainer["Sort3|"].category == "unavailable")
      local P = n.Training.Panel()
      assert(P and P:IsShown() and P.body.text == "Sort2 (Rang 2) : " .. (GetCoinTextureString and "COIN:12000" or "1 po 20 pa"), "panneau : 1 service")
      assert(P.pt[1] == "CENTER", "sans ClassTrainerFrame : au centre")
      GetCoinTextureString = nil
      local f = CreateFrame("Frame", "ClassTrainerFrame")
      mock.fire("TRAINER_UPDATE")
      assert(P.body.text == "Sort2 (Rang 2) : 1 po 20 pa", P.body.text)
      assert(P.pt[2] == f, "ancre a cote du cadre du maitre")
      mock.fire("TRAINER_CLOSED")
      assert(not P:IsShown(), "ferme avec le maitre")
    end, function()
      GetTrainerServiceInfo, GetTrainerServiceLevelReq, GetTrainerServiceCost, GetCoinTextureString = keep[1], keep[2], keep[3], keep[4]
      ClassTrainerFrame = nil
    end)
  end)

  check("Training : API du maitre absente ou qui plante, rien ne s'affiche", function()
    local keep = { GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceLevelReq, GetTrainerServiceCost }
    isolated(function()
      local n = fresh().n
      GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceLevelReq, GetTrainerServiceCost = nil, nil, nil, nil
      mock.fire("TRAINER_SHOW")
      assert(not n.Training.Panel() and next(n.db.trainer or {}) == nil)
      GetNumTrainerServices = function() error("boom") end
      mock.fire("TRAINER_SHOW")
      assert(not n.Training.Panel() and next(n.db.trainer or {}) == nil)
    end, function()
      GetNumTrainerServices, GetTrainerServiceInfo, GetTrainerServiceLevelReq, GetTrainerServiceCost = keep[1], keep[2], keep[3], keep[4]
    end)
  end)

  check("Talents : point de talent au 12, avec et sans UnspentTalentPoints", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 11, unspentTalents = 0 })
    n.Fire("STATE", { "level" })
    setState(n, { level = 12, unspentTalents = 1 })
    n.Fire("STATE", { "level", "unspentTalents" })
    local t = pcToasts(o, "^pc:talent:")
    assert(#t == 1 and t[1].text == "Ton point de talent : Connexion spirituelle (5 points)", t[1] and t[1].text)
    setState(n, { level = 13, unspentTalents = 0 })
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:talent:") == 1, "aucun point : pas de toast")
    setState(n, { level = 14 }) -- API absente : toast au passage de niveau, sans condition
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:talent:") == 2)
    setState(n, { level = 9, unspentTalents = 1 })
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:talent:") == 2, "avant le niveau 10 : rien")
  end)

  check("Talents : respec Ombre au 40", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 39, unspentTalents = 0 })
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:respec") == 0)
    setState(n, { level = 40, unspentTalents = 0 })
    n.Fire("STATE", { "level" })
    local t = pcToasts(o, "^pc:respec")
    assert(#t == 1 and t[1].text:find("Respec Ombre", 1, true), "rappel du respec")
  end)

  check("Talents : plan non suivi, un seul toast par session, ligne dans le guide", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 12, unspentTalents = 0, talents = tl{ [15270] = 0 } })
    n.Fire("STATE", { "talents" })
    n.Fire("STATE", { "talents" })
    setState(n, { level = 13, unspentTalents = 0, talents = tl{ [15270] = 1 } })
    n.Fire("STATE", { "level", "talents" })
    local t = pcToasts(o, "^pc:talentgap")
    assert(#t == 1 and t[1].text == "Plan de talents non suivi : Connexion spirituelle", "un seul toast : " .. #t)
    local r = n.Guide.Reference("talents")
    assert(#r == #n.Data.TalentPlan + 1 and r[1].text == t[1].text and not r[1].highlight, "ligne discrete")
    n.State.talents = nil
    assert(n.Talents.GapLine() == nil and #n.Guide.Reference("talents") == #n.Data.TalentPlan, "talents inconnus : rien")
    local o2 = fresh()
    setState(o2.n, { level = 12, unspentTalents = 0, talents = nil })
    o2.n.Fire("STATE", { "level" })
    assert(#pcToasts(o2, "^pc:talentgap") == 0, "TalentGap nil : rien")
  end)

  check("Professions : rang a prendre, nouveau bandage, metier manquant, une fois", function()
    local o = fresh()
    local n = o.n
    local function profs(herb, aid) return { [182] = { rank = herb, max = 75 }, [171] = { rank = 1, max = 75 }, [129] = { rank = aid, max = 75 } } end
    setState(n, { level = 10, profs = profs(50, 1) })
    n.Fire("STATE", { "profs" })
    local t = pcToasts(o, "^pc:prof:rank:")
    assert(#t == 1 and t[1].text == "Herboristerie 50 : va prendre le rang Compagnon à Brill", t[1] and t[1].text)
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:prof:rank:") == 1, "anti-repetition")
    assert(#pcToasts(o, "^pc:prof:bandage") == 0 and n.db.training.bandage == 1, "premier bandage memorise sans toast")
    setState(n, { level = 10, profs = profs(10, 40) })
    n.Fire("STATE", { "profs" })
    n.Fire("STATE", { "profs" })
    t = pcToasts(o, "^pc:prof:bandage")
    assert(#t == 1 and t[1].text == "Nouveau bandage disponible : Bandage en lin épais" and n.db.training.bandage == 40)
    setState(n, { level = 4, profs = { [182] = { rank = 1, max = 75 } } })
    n.Fire("STATE", { "level" })
    assert(#pcToasts(o, "^pc:prof:missing") == 0, "avant le niveau 5 : rien")
    n.State.level = 12
    n.Fire("STATE", { "level" })
    n.Fire("STATE", { "profs" })
    t = pcToasts(o, "^pc:prof:missing")
    assert(#t == 1 and t[1].text == "Métier à apprendre : Secourisme, Alchimie", "un rappel par session")
    local before = #pcToasts(o, "^pc:prof:")
    setState(n, { level = 12, profs = nil })
    n.Fire("STATE", { "profs" })
    assert(#pcToasts(o, "^pc:prof:") == before, "profs illisibles : rien de plus")
  end)

  check("Professions L16a : recettes lues en direct, tri, cout et marge, combat, toast unique, API absente", function()
    local o = fresh()
    local n = o.n
    n.db.prof = nil
    setState(n, { level = 10, profs = { [171] = { rank = 50, max = 75 }, [129] = { rank = 1, max = 75 } } })
    local function rows() local t = {} for _, r in ipairs(n.Guide.Reference("profs")) do t[r.text] = r end return t end
    assert(rows()["Alchimie"].sub:find("Ouvre la fenêtre du métier pour une liste à jour", 1, true), "jamais ouvert")
    assert(rows()["Secourisme"].sub:find("Bandage à utiliser : Bandage en lin", 1, true), "bandage relie")
    local function open() mock.fire("TRADE_SKILL_SHOW") mock.fire("TRADE_SKILL_LIST_UPDATE") mock.flushTimers() end
    if not C_TradeSkillUI then
      open() -- API absente : aucune erreur, rien de lu
      assert(n.Prof.Get(171) == nil and rows()["Alchimie"].sub:find("Ouvre la fenêtre", 1, true))
      return
    end
    -- 101 orange (manque 2x objet 10), 102 jaune (composant 12 sans prix), 103 verte, 104 orange fabricable, 105 grise, 106 non apprise
    mock.recipes = 6
    mock.recipeInfo = { [102] = { relativeDifficulty = 1, craftable = true }, [103] = { relativeDifficulty = 2 },
      [104] = { numAvailable = 3 }, [105] = { relativeDifficulty = 3 }, [106] = { learned = false } }
    local function sch(item, q, out) return { outputItemID = out, reagentSlotSchematics = { { quantityRequired = q, reagents = { { itemID = item } } } } } end
    mock.schematics = { [101] = sch(10, 2, 900), [102] = sch(12, 1, 902), [104] = sch(11, 1, 901) }
    mock.ah = { [10] = { 50, 1 }, [900] = { 160, 1 }, [11] = { 30, 1 }, [901] = { 40, 1 }, [902] = { 500, 1 } }
    mock.items = { [11] = 5 }
    -- combat : lecture differee jusqu'a la fin du combat
    mock.setCombat(true)
    open()
    assert(n.Prof.Get(171) == nil, "aucune lecture en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED") mock.flushTimers()
    local adv = n.Prof.Advice[171]
    assert(adv and adv.rank == 50 and adv.max == 75 and adv.when, "lecture apres le combat")
    local ids = {}
    for i, e in ipairs(adv.list) do ids[i] = e.recipeID end
    assert(table.concat(ids, ",") == "101,104,102", "tri : oranges (marge 60 > 10), puis jaune ; verte, grise, non apprise ecartees : " .. table.concat(ids, ","))
    local e1, e3 = adv.list[1], adv.list[3]
    assert(e1.cost == 100 and e1.value == 160 and e1.margin == 60 and not e1.craftable and e1.missing[1].n == 2, "cout et marge")
    assert(e3.cost == nil and e3.margin == nil and e3.value == 500 and e3.craftable, "composant sans prix : cout inconnu, jamais invente")
    assert(adv.list[2].craftable, "numAvailable > 0 vaut fabricable")
    assert(n.db.prof[171] == adv and not findSecret(n.db.prof, "prof"), "conserve dans la base, sans secret")
    local t = pcToasts(o, "^pc:prof:craft")
    assert(#t == 1 and t[1].text == "Alchimie : fabrique Recette101 pour monter", "un toast")
    local sub = rows()["Alchimie"].sub
    assert(sub:find("Fabrique : Recette101 (orange, +1 pt) - coût COIN:100 - marge +COIN:60", 1, true), sub)
    assert(sub:find("Il te manque : 2x Baguette 10", 1, true), sub)
    open() -- deuxieme passe identique : ni doublon ni changement
    assert(#pcToasts(o, "^pc:prof:craft") == 1 and n.Prof.Advice[171] ~= adv and n.Prof.Advice[171].list[1].recipeID == 101)
    assert(rows()["Herboristerie"] == nil or not rows()["Herboristerie"].sub:find("Ouvre", 1, true), "herbes : pas de fenetre")
    -- sans Auctionator : ni cout ni marge, l'ordre passe au « fabricable »
    local ah = Auctionator
    Auctionator = nil
    open()
    Auctionator = ah
    adv = n.Prof.Advice[171]
    assert(adv.list[1].recipeID == 104 and adv.list[1].cost == nil and adv.list[1].margin == nil and adv.list[2].recipeID == 101, "sans prix : fabricable d'abord")
    t = pcToasts(o, "^pc:prof:craft")
    assert(#t == 2 and t[2].text == "Alchimie : fabrique Recette104 pour monter", "toast quand la meilleure recette change")
    sub = rows()["Alchimie"].sub
    assert(sub:find("Fabrique : Recette104 (orange, +1 pt)", 1, true) and not sub:find("coût", 1, true) and not sub:find("marge", 1, true), sub)
    -- fenetre pas prete : rien de lu
    mock.tsNotReady = true
    n.Prof.Advice[171] = nil
    n.db.prof = nil
    open()
    assert(n.Prof.Get(171) == nil, "fenetre non prete")
    -- format monetaire maison si GetCoinTextureString est absente
    local g = GetCoinTextureString
    GetCoinTextureString = nil
    assert(n.Prof.Money(12000) == "1 po 20 pa" and n.Prof.Money(0) == "0 pc" and n.Prof.Money(5) == "5 pc")
    GetCoinTextureString = g
    mock.recipes = nil
  end)

  ------------------------------------------------------------------------
  -- L9 : options, commandes, finitions
  ------------------------------------------------------------------------
  local function boot(db)
    local keep = PretreCoachDB
    local n = loadAddon()
    PretreCoachDB = db or {}
    mock.fire("ADDON_LOADED", ADDON)
    return n, function() PretreCoachDB = keep end
  end
  local function click(ctl) ctl.scripts.OnClick(ctl) end
  local function slide(ctl, v) ctl.scripts.OnValueChanged(ctl, v) end
  local cmd = function(s) SlashCmdList.PRETRECOACH(s) end
  -- sans API Settings, les controles n'existent qu'une fois la fenetre maison ouverte
  local function controls(n) if not n.UI.Options.panel then n.ToggleOptions() end return n.UI.Options.controls end

  check("Options : Settings present enregistre la categorie, ToggleOptions l'ouvre", function()
    if not Settings then return end
    mock.registered, mock.opened = nil, nil
    local n, restore = boot()
    assert(mock.registered and mock.registered.name == "Prêtre Coach" and mock.registered.panel == n.UI.Options.panel)
    n.ToggleOptions()
    assert(mock.opened == 42 and not n.UI.Options.win, "OpenToCategory, pas de fenetre")
    restore()
  end)

  check("Options : Settings absent, fenetre maison (Echap, bascule)", function()
    local saved = Settings
    Settings = nil
    local n, restore = boot()
    Settings = saved
    assert(not n.UI.Options.panel)
    n.ToggleOptions()
    local w = n.UI.Options.win
    assert(w and w:IsShown(), "fenetre ouverte")
    local found
    for _, name in ipairs(UISpecialFrames) do if name == "PretreCoachOptionsFrame" then found = true end end
    assert(found, "Echap")
    n.ToggleOptions()
    assert(not w:IsShown())
    restore()
  end)

  check("Options : chaque case affiche/masque et ecrit dans ns.db", function()
    local n, restore = boot()
    local c, db = controls(n), n.db
    local rotation = n.UI.RotationPanel.frame
    n.Rotation.current = { keys = { 1 }, text = "x" }
    n.UI.RotationPanel.Render()
    assert(rotation:IsShown())
    click(c.rotation)
    assert(db.show.rotation == false and not rotation:IsShown(), "cycle masque")
    click(c.rotation)
    assert(db.show.rotation == true and rotation:IsShown(), "cycle revient")
    local rules = n.UI.RulesBar.frame
    assert(rules:IsShown())
    click(c.rules)
    assert(db.show.rules == false and not rules:IsShown(), "regles masquees")
    click(c.rules)
    assert(rules:IsShown())
    click(c.guide)
    local G = n.UI.GuideWin
    assert(db.show.guide == false and not (G.win and G.win:IsShown()) and not (G.card and G.card:IsShown()), "guide masque")
    click(c.guide)
    assert(db.show.guide == true and G.win:IsShown(), "guide revient")
    click(c.toasts)
    assert(db.show.toasts == false and not n.Toast("muet"), "toasts coupes")
    click(c.minimap)
    assert(db.show.minimap == false and not n.minimapButton:IsShown(), "minicarte masquee")
    click(c.minimap)
    assert(n.minimapButton:IsShown())
    click(c.locked); assert(db.locked == true); click(c.locked); assert(db.locked == false)
    click(c.every); assert(db.training.every == 2); click(c.every); assert(db.training.every == 1)
    click(c.debug); assert(db.debug == true); click(c.debug); assert(db.debug == false)
    click(c.compact)
    assert(db.guide.compact == true and G.card:IsShown() and not G.win:IsShown(), "compact applique, guide ouvert")
    click(c.compact)
    assert(db.guide.compact == false and G.win:IsShown())
    restore()
  end)

  check("Options : curseurs taille et opacite appliques", function()
    local n, restore = boot()
    local c, rules = controls(n), n.UI.RulesBar.frame
    slide(c.scale, 0.8)
    assert(n.db.scale == 0.8 and rules.scale == 0.8, "echelle")
    slide(c.scale, 9)
    assert(n.db.scale == 1.6, "borne haute")
    slide(c.opacity, 0.5)
    assert(n.db.opacity == 0.5 and math.abs(rules.bg.color[4] - 0.85 * 0.5) < 1e-9, "opacite")
    restore()
  end)

  check("Echelle et opacite appliquees a tous les cadres au chargement", function()
    local n, restore = boot({ scale = 1.3, opacity = 0.4 })
    assert(n.UI.RulesBar.frame.scale == 1.3 and n.UI.RotationPanel.frame.scale == 1.3, "echelle")
    assert(n.UI.GuideWin.win.scale == 1.3, "fenetre du guide (creee apres)")
    assert(math.abs(n.UI.RulesBar.frame.bg.color[4] - 0.85 * 0.4) < 1e-9, "opacite")
    restore()
  end)

  check("/coach seul ouvre les options, help liste tout", function()
    local n, restore = boot()
    local k, real = 0, n.ToggleOptions
    n.ToggleOptions = function() k = k + 1 end
    cmd("")
    assert(k == 1, "ToggleOptions")
    n.ToggleOptions = real
    mock.printed = {}
    cmd("help")
    local h = mock.printed[1]
    for _, w in ipairs({ "guide", "compact", "lock", "unlock", "reset", "probe", "here", "debug" }) do assert(h:find(w, 1, true), w) end
    restore()
  end)

  check("/coach lock, unlock, reset (positions remises, objectifs intacts)", function()
    local n, restore = boot()
    local rules = n.UI.RulesBar.frame
    cmd("lock"); assert(n.db.locked == true)
    cmd("unlock"); assert(n.db.locked == false)
    rules:ClearAllPoints(); rules:SetPoint("BOTTOM", UIParent, "BOTTOM", 5, 6)
    rules.scripts.OnDragStop(rules)
    n.db.scale, n.db.opacity = 1.4, 0.5
    n.db.guide.manual.x, n.db.guide.done.y = true, true
    n.db.training.count = 7
    cmd("reset")
    local p, _, _, x, y = rules:GetPoint()
    assert(p == "TOP" and x == 0 and y == -20, "recentre a la place d'origine")
    assert(next(n.db.frames) == nil and n.db.scale == 1 and n.db.opacity == 0.9, "defauts")
    assert(rules.scale == 1, "echelle appliquee")
    assert(n.db.guide.manual.x and n.db.guide.done.y and n.db.training.count == 7, "objectifs et stats intacts")
    assert(mock.printed[#mock.printed]:find("remises"), "confirmation")
    restore()
  end)

  check("/coach reset en combat : reporte avec un message", function()
    local n, restore = boot()
    n.db.opacity = 0.5
    mock.setCombat(true)
    mock.printed = {}
    cmd("reset")
    assert(n.db.opacity == 0.5 and #mock.printed == 1 and mock.printed[1]:find("combat"), "rien en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(n.db.opacity == 0.9 and mock.printed[#mock.printed]:find("remises"), "fait apres le combat")
    restore()
  end)

  check("Guide : ouvert seulement s'il l'etait a la deconnexion", function()
    local n, restore = boot() -- premiere connexion : open == nil
    assert(n.UI.GuideWin.win:IsShown() and n.db.guide.open == true, "premiere connexion : ouvert")
    n.UI.GuideWin.win:Hide()
    assert(n.db.guide.open == false)
    local saved = n.db
    restore()
    local n2, restore2 = boot(saved)
    assert(not (n2.UI.GuideWin.win and n2.UI.GuideWin.win:IsShown()) and not (n2.UI.GuideWin.card and n2.UI.GuideWin.card:IsShown()), "reste ferme")
    n2.ToggleGuide()
    local n3, restore3 = boot(saved)
    assert(n3.UI.GuideWin.win:IsShown(), "rouvert car ouvert a la derniere session")
    restore3(); restore2()
    local n4, restore4 = boot({ guide = { compact = true, open = true } })
    assert(n4.UI.GuideWin.card:IsShown(), "la carte suit compact")
    restore4()
  end)

  check("Minimap : show.minimap = false masque le bouton au chargement", function()
    local n, restore = boot({ show = { minimap = false } })
    assert(not n.minimapButton:IsShown())
    restore()
    local n2, restore2 = boot()
    assert(n2.minimapButton:IsShown())
    restore2()
  end)

  check("Un listener STATE qui plante ne bloque pas les autres", function()
    N.Listen("STATE", function() error("boom") end) -- en dernier : il reste inscrit
    local got = 0
    N.Listen("STATE", function() got = got + 1 end)
    N.Fire("STATE", { "x" })
    assert(got == 1 and #mock.errors == 1, "le suivant doit s'executer, l'erreur partir au gestionnaire")
    mock.errors = {}
  end)

  -- L14 : ponts Questie et Auctionator (addon neuf et mock remis a zero a chaque etape)
  local function qboot(db)
    mock.reset()
    local n = loadAddon()
    PretreCoachDB = db or {}
    mock.fire("ADDON_LOADED", ADDON)
    return n
  end
  local function drain() for _ = 1, 20 do if #mock.timers == 0 then return end mock.flushTimers() end error("minuteurs sans fin") end
  local function same(t, ...) local e = { ... } assert(#t == #e, "attendu " .. table.concat(e, ",") .. ", recu " .. table.concat(t, ",")) for i, v in ipairs(e) do assert(t[i] == v) end end

  check("Ponts : Questie et Auctionator absents, rien ne plante", function()
    local lib, ah = LibQuestieDB, Auctionator
    LibQuestieDB, Auctionator = nil, nil
    local ok, err = pcall(function()
      local n = qboot()
      assert(n.Q.Available() == false and n.AH.Available() == false)
      assert(n.Q.Quest(1, "name") == nil and n.Q.Npc(1, "name") == nil and n.Q.Where(375) == nil)
      assert(n.Q.StartIndex() == false and n.Q.Nearest("PRIEST") == nil and n.db.qindex == nil)
      assert(n.AH.Price(2589) == nil and n.AH.Age(2589) == nil)
      mock.fire("PLAYER_LOGIN"); drain()
      assert(n.db.qindex == nil)
    end)
    LibQuestieDB, Auctionator = lib, ah
    assert(ok, err)
  end)

  check("Ponts : contrat refuse = absent", function()
    if not LibQuestieDB then return end
    local keep = LibQuestieDB.RequireContract
    LibQuestieDB.RequireContract = function() return false, "trop vieux" end
    local ok, err = pcall(function() assert(qboot().Q.Available() == false) end)
    LibQuestieDB.RequireContract = keep
    assert(ok, err)
  end)

  check("Ponts : les appels qui plantent sont rattrapes", function()
    if not LibQuestieDB then return end
    local n = qboot()
    mock.qboom, mock.ahBoom = true, true
    assert(n.Q.Available() and n.Q.Npc(375, "name") == nil and n.Q.Quest(6561, "name") == nil and n.Q.Where(375) == nil)
    assert(n.AH.Price(2589) == nil and n.AH.Age(2589) == nil)
    assert(n.Q.StartIndex() == true); drain() -- chaque lecture plante : pas d'erreur, index non sauvegarde, 3 essais au plus
    assert(n.db.qindex == nil and mock.qreads <= 3 * 450 + 10, "echec : rien en cache")
    mock.qboom, mock.ahBoom = nil, nil
  end)

  check("Auctionator : Price et Age", function()
    if not Auctionator then return end
    local n = qboot()
    assert(n.AH.Available() and n.AH.Price(2589) == 120 and n.AH.Age(2589) == 3)
    assert(n.AH.Price(1) == nil and n.AH.Age(1) == nil and n.AH.Price("x") == nil and n.AH.Price(nil) == nil)
    mock.ah = nil
    assert(n.AH.Price(2589) == nil, "base vide : nil sans planter")
  end)

  check("Questie : Where (pourcentage 0-100 tel quel, instance ignoree)", function()
    if not LibQuestieDB then return end
    local n = qboot()
    assert(n.Q.Quest(6561, "name") == "Quete")
    local w = n.Q.Where(375)
    assert(w.areaID == 1497 and w.uiMapID == (C_Map and 1458 or nil) and w.x == 52.3 and w.y == 41.2, "x et y restent en pourcentage")
    assert(n.Q.Where(377).areaID == 85 and n.Q.Where(308) == nil and n.Q.Where(1) == nil and n.Q.Where(999) == nil)
  end)

  check("Questie : index par morceaux, QINDEX, roles et filtre de faction", function()
    if not LibQuestieDB then return end
    local n = qboot()
    local fired = 0
    n.Listen("QINDEX", function() fired = fired + 1 end)
    assert(n.Q.StartIndex() == true and n.Q.StartIndex() == false, "un seul index a la fois")
    if C_Timer then
      mock.flushTimers(); assert(n.db.qindex == nil and fired == 0, "morceau 1 sur 3")
      mock.flushTimers(); assert(n.db.qindex == nil, "morceau 2 sur 3")
    end
    drain()
    local q = n.db.qindex
    assert(fired == 1 and q.ver == "1.0.11")
    same(q.trainers.PRIEST, 308, 375, 377) -- 376 Alliance, 305 sans bit maitre, 306 hostile : ecartes
    same(q.trainers.ALCHEMY, 300); same(q.trainers.HERBALISM, 301, 307); same(q.trainers.FIRSTAID, 302); same(q.trainers.COOKING, 303)
    same(q.auctioneers, 304)
  end)

  check("Questie : l'index se lance au PLAYER_LOGIN apres un delai", function()
    if not LibQuestieDB then return end
    local n = qboot()
    mock.fire("PLAYER_LOGIN"); drain()
    assert(n.db.qindex and n.db.qindex.ver == "1.0.11")
  end)

  check("Questie : pause en combat, reprise apres", function()
    if not LibQuestieDB then return end
    local n = qboot()
    assert(n.Q.StartIndex())
    mock.setCombat(true)
    mock.flushTimers(); mock.flushTimers()
    assert(mock.qreads == 0 and n.db.qindex == nil, "aucune lecture en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED"); drain()
    assert(n.db.qindex and #n.db.qindex.trainers.PRIEST == 3, "termine apres le combat")
  end)

  check("Questie : cache reutilise, reconstruit si la version change", function()
    if not LibQuestieDB then return end
    local n = qboot()
    n.Q.StartIndex(); drain()
    local saved = n.db
    mock.qreads = 0
    local n2 = qboot(saved)
    assert(n2.Q.StartIndex() == false and mock.qreads == 0 and n2.db.qindex.ver == "1.0.11", "cache reutilise")
    local n3 = qboot(saved)
    mock.qver = "1.0.12" -- apres qboot : mock.reset remet la version d'origine
    assert(n3.Q.StartIndex() == true); drain()
    assert(n3.db.qindex.ver == "1.0.12" and mock.qreads > 0, "reconstruit")
  end)

  check("Questie : Nearest prefere la zone du joueur, puis une capitale Horde", function()
    if not LibQuestieDB then return end
    local n = qboot()
    assert(n.Q.Nearest("PRIEST") == nil, "pas d'index : nil")
    n.Q.StartIndex(); drain()
    local id, w = n.Q.Nearest("PRIEST", nil, 85)
    assert(id == 377 and w.areaID == 85, "meme zone")
    assert(n.Q.Nearest("PRIEST") == 375, "sinon Fossoyeuse")
    assert(n.Q.Nearest("COOKING", nil, 85) == 303, "Orgrimmar")
    assert(n.Q.Nearest("HERBALISM", nil, 85) == 307 and n.Q.Nearest("HERBALISM", nil, 999) == 301)
    assert(n.Q.Nearest("AUCTIONEER") == 304 and n.Q.Nearest("INCONNU") == nil)
    n.db.qindex.trainers.ALCHEMY = { 377 }
    assert(n.Q.Nearest("ALCHEMY", nil, 999) == nil, "ni meme zone ni capitale : rien")
  end)

  check("Questie : index vide ou Questie pas pret = pas de cache, reessai plus tard, format versionne", function()
    if not LibQuestieDB then return end
    local n = qboot()
    mock.qboom = true
    assert(n.Q.StartIndex()); mock.flushTimers(); mock.flushTimers(); mock.flushTimers()
    assert(n.db.qindex == nil, "rien de sauvegarde")
    if C_Timer then
      assert(#mock.timers == 1, "reessai programme")
      mock.qboom = nil
      drain()
      assert(n.db.qindex and #n.db.qindex.trainers.PRIEST == 3, "reessai reussi")
    end
    mock.qboom = nil
    drain()
    local saved = n.db
    saved.qindex = saved.qindex or { ver = "1.0.11", trainers = {}, auctioneers = {} }
    saved.qindex.fmt = nil -- ancien format
    local n2 = qboot(saved)
    assert(n2.Q.StartIndex() == true, "format different : reconstruit"); drain()
    assert(n2.db.qindex.fmt == 1)
    local n3 = qboot(n2.db)
    mock.qver = nil -- version illisible : "?" n'est jamais reutilise
    assert(n3.Q.StartIndex() == true); drain()
    assert(n3.db.qindex.ver == "?")
    local n4 = qboot(n3.db)
    mock.qver = nil
    assert(n4.Q.StartIndex() == true, "reconstruit a chaque session")
    drain()
  end)

  check("Questie : Available() reessaie quand LibQuestieDB apparait", function()
    if not LibQuestieDB then return end
    local lib = LibQuestieDB
    _G.LibQuestieDB = nil
    local ok, err = pcall(function()
      local n = qboot()
      assert(n.Q.Available() == false)
      _G.LibQuestieDB = lib
      assert(n.Q.Available() == true, "la bibliotheque est apparue")
    end)
    _G.LibQuestieDB = lib
    assert(ok, err)
  end)

  check("Questie : ligne de spawn sans y numerique rejetee", function()
    if not LibQuestieDB then return end
    local n = qboot()
    mock.qnpcs[999] = { 16, "Priest Trainer", "H", 1497, { [1497] = { { 50, "x" } } } }
    assert(n.Q.Where(999) == nil)
    mock.qnpcs[999] = nil
  end)

  check("Questie : Nearest memorise, vide sur QINDEX; capitales preferees", function()
    if not LibQuestieDB then return end
    local n = qboot()
    n.Q.StartIndex(); drain()
    assert(n.Q.Nearest("PRIEST", nil, 85) == 377)
    local r = mock.qreads
    assert(n.Q.Nearest("PRIEST", nil, 85) == 377 and mock.qreads == r, "deuxieme appel sans lecture")
    n.db.qindex.trainers.PRIEST = { 303, 375 } -- Orgrimmar puis Fossoyeuse
    assert(n.Q.Nearest("PRIEST", nil, 85) == 377, "encore en cache")
    n.Fire("QINDEX")
    assert(n.Q.Nearest("PRIEST", nil, 999) == 375, "pretre : Fossoyeuse d'abord")
    n.db.qindex.auctioneers = { 303, 304 }
    n.Fire("QINDEX")
    assert(n.Q.Nearest("AUCTIONEER") == 304, "hdv : Fossoyeuse d'abord")
    n.db.qindex.trainers.COOKING = { 304, 303 }
    n.Fire("QINDEX")
    assert(n.Q.Nearest("COOKING") == 304, "autre role : premier trouve")
  end)

  -- L15 : « Ou aller » (conversion AreaID -> uiMapID, Goto, repere de carte)
  local function gboot(withIndex)
    local n = qboot()
    mock.mapNames = { [1458] = "Fossoyeuse", [1420] = "Tirisfal" }
    if withIndex then n.Q.StartIndex(); drain() end
    return n
  end

  check("Goto : AreaID -> uiMapID en direct (presente, introuvable, absente)", function()
    local n = gboot()
    if C_Map then
      assert(n.Q.MapFor(1497) == 1458 and n.Q.MapFor(85) == 1420, "noms localises")
      assert(n.Q.MapFor(99999) == nil, "nom introuvable")
      mock.areas = { [5] = "Zone Inconnue" }
      assert(n.Q.MapFor(5) == nil, "nom sans carte")
    else
      assert(n.Q.MapFor(1497) == nil, "API absente : nil, sans erreur")
    end
  end)

  check("Goto : homonymes, City avant Zone, 1414/1415 avant 946, nom pris non ecrase", function()
    local n = gboot()
    if not C_Map then return end
    local T = Enum.UIMapType
    mock.areas = { [7] = "Foo", [8] = "Bar", [9] = "Baz" }
    mock.mapKids = { [1414] = { { mapID = 100, name = "Foo", kind = T.Zone }, { mapID = 300, name = "Baz", kind = T.Zone } },
      [946] = { { mapID = 200, name = "Foo", kind = T.City }, { mapID = 301, name = "Baz", kind = T.Zone }, { mapID = 400, name = "Bar", kind = T.Zone } } }
    assert(n.Q.MapFor(7) == 200, "la ville l'emporte sur la zone")
    assert(n.Q.MapFor(9) == 300, "1414 avant 946")
    assert(n.Q.MapFor(8) == 400)
    mock.areas, mock.mapKids = nil, nil
  end)

  check("GuideWindow : la sous-ligne garde le niveau et ajoute Ou aller", function()
    local n, G = gw()
    n.Guide.Evaluate = function() return { { id = "x", text = "T", sub = "Niv. 5-9", go = "WAND", done = false } } end
    n.ToggleGuide()
    local t = G.rows[1].sub.text
    assert(t:find("Niv. 5-9", 1, true) and t:find("Où aller", 1, true), t)
  end)

  check("Goto : For avec et sans Questie, cible inconnue", function()
    local n = gboot(LibQuestieDB ~= nil)
    for _, t in ipairs({ "WAND", "PRIEST", "ALCHEMY", "HERBALISM", "FIRSTAID", "Q6561", "Q1" }) do
      local d = n.Goto.For(t)
      assert(type(d) == "table" and type(d.text) == "string" and d.text ~= "", t)
      assert(not d.text:find("Trainer") and not d.text:find("Auctioneer") and not d.text:find("Gravestone"), "nom anglais : " .. d.text)
    end
    assert(n.Goto.For("INCONNU") == nil)
    if LibQuestieDB and C_Map then
      local d = n.Goto.For("PRIEST")
      assert(d.mapID == 1458 and d.x == 52.3 and d.y == 41.2 and d.text:find("Fossoyeuse", 1, true), d.text)
      assert(n.Goto.For("WAND").text:find("Hôtel des ventes de Fossoyeuse", 1, true) and n.Goto.For("WAND").mapID == 1458)
      local q = n.Goto.For("Q6561")
      assert(q.mapID == 1458 and q.x == 52.3, "donneur de quete")
      local none = n.Goto.For("Q1")
      assert(none.mapID == nil and none.x == nil, "quete sans donneur : texte seul")
    else
      assert(n.Goto.For("PRIEST").x == nil and n.Goto.For("WAND").text:find("Hôtel des ventes de Fossoyeuse", 1, true), "repli sans coordonnees")
    end
  end)

  check("Goto : Place pose le repere, sinon ecrit dans le chat, sans erreur", function()
    local n = gboot(LibQuestieDB ~= nil)
    local d = { text = "Quelque part", mapID = 1458, x = 52.3, y = 41.2 }
    local np = #mock.printed
    if C_Map and UiMapPoint and C_SuperTrack then
      assert(n.Goto.Place(d) == true and mock.waypoint and mock.waypoint.mapID == 1458 and mock.superTracked == true)
      assert(math.abs(mock.waypoint.x - 0.523) < 1e-9 and #mock.printed == np, "coordonnees en 0-1, pas de message")
      mock.waypoint = nil
      mock.canWaypoint = false
      assert(n.Goto.Place(d) == false and mock.waypoint == nil and #mock.printed == np + 1, "carte refusee : message")
      assert(mock.printed[#mock.printed]:find("Quelque part", 1, true))
    else
      assert(n.Goto.Place(d) == false and #mock.printed == np + 1, "API absente : message")
    end
    assert(n.Goto.Place(nil) == false and n.Goto.Place({ text = "x" }) == false)
    assert(not n.Goto.CanPlace({ text = "x" }) and not n.Goto.CanPlace(nil) and n.Goto.CanPlace(d))
  end)

  check("Goto : guide, regles et QINDEX (bouton masque sans coordonnees)", function()
    local n, G = gw()
    mock.mapNames = { [1458] = "Fossoyeuse", [1420] = "Tirisfal" }
    n.ToggleGuide()
    local c = G.count
    n.Fire("QINDEX")
    assert(G.count == c + 1, "QINDEX rafraichit le guide")
  end)

  check("Goto : detail de la regle 1, bouton masque sans coordonnees", function()
    isolated(function()
      local n = loadAddon()
      n.db = { show = { toasts = false, rules = true }, guide = { manual = {}, done = {} } }
      mock.mapNames = { [1458] = "Fossoyeuse", [1420] = "Tirisfal" }
      mock.fire("ADDON_LOADED", ADDON)
      local R = n.UI.RulesBar
      local b = R.buttons[1]
      n.db.qindex = nil -- la base partagee peut porter l'index d'un test precedent
      b.scripts.OnClick(b)
      assert(R.detail.shown and not R.detail.go.shown, "sans coordonnees : bouton masque")
      assert(R.detail.text.text:find("Où aller", 1, true), "ligne Ou aller")
      b.scripts.OnClick(b) -- referme
      if LibQuestieDB and C_Map then
        n.Q.StartIndex(); drain()
        b.scripts.OnClick(b)
        assert(R.detail.go.shown and R.detail.dest.mapID == 1458, "avec index : bouton visible")
      end
    end, rcleanup)
  end)

  check("Goto : toast R1 cite l'hotel des ventes", function()
    local n = gboot()
    assert(n.Goto.For("WAND").where:find("Hôtel des ventes de Fossoyeuse", 1, true))
  end)

  check("Sonde : GetAreaInfo(85) et uiMapID attendu 1420", function()
    gboot()
    suiteSlash("probe")
    local t = mock.lastText
    assert(t:find("GetAreaInfo(85) : ", 1, true) and t:find("(attendu 1420)", 1, true), "ligne conversion")
    if C_Map then assert(t:find("GetAreaInfo(85) : Tirisfal | uiMapID obtenu : 1420", 1, true), t) end
  end)
end

suite("presentes")
mock.setAbsent(true)
suite("absentes")
mock.setAbsent(false)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
