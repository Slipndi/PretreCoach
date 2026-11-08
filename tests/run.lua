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

-- Pieces inline (Prof.Money) : o = or, a = argent, c = cuivre
local MI = { o = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t", a = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t", c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t" }

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
    assert(#btns == 16, "16 lignes cliquables")
    local expect = { "guide", "compact", "", "lock", "reset", "probe", "here", "debug", "progress", "heal", "conso", "craft", "mana", "wand", "gold", nil }
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
      assert(t:find("QuestieDB : non installé", 1, true) and t:find("Auctionator : non installé", 1, true))
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
  check("probe : QuestDB et What's Training tiers, presents puis absents", function()
    local ls, wt = LibStub, WT_API
    LibStub = nil WT_API = nil
    local t = probeText()
    assert(t:find("QuestDB : non installé", 1, true) and t:find("What's Training : non installé", 1, true), "absents")
    local lib = { IsReady = function() return true end,
      GetRewards = function(_, id) return id == 6561 and { items = { { 1, 1 } }, choices = { { 2, 1 }, { 3, 1 } } } or nil end }
    LibStub = function(name) return name == "LibQuestDB-1.0" and lib or nil end
    WT_API = { IsReady = function() return true end, GetCatalog = function() return {} end, GetSource = function() end }
    t = probeText()
    assert(t:find("quête test 6561 : 3 objet(s)", 1, true), "QuestDB present")
    assert(t:find("What's Training : chargé, prêt, coût des sorts du prochain niveau", 1, true), "WT present")
    WT_API.IsReady = function() error("boom") end
    assert(probeText():find("What's Training : chargé, pas prêt", 1, true), "WT qui plante")
    LibStub, WT_API = ls, wt
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
    if not absent then assert(t:find("QuestieDB : chargé", 1, true) and t:find("Auctionator : chargé", 1, true)) end
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

  check("Spells : Mort a les IDs Forever (1309595, 1309633), plus le 32379 inexistant", function()
    local ids = {}
    for _, sp in ipairs(N.Data.Spells) do if sp.key == "SWD" then for _, r in ipairs(sp.ranks) do ids[#ids + 1] = r.id end end end
    assert(ids[1] == 1309595 and ids[2] == 1309633 and #ids == 2, "rangs SWD")
  end)

  check("Donnees mortes supprimees : StatAdvice, legacyPoints (jamais affichees)", function()
    assert(N.Data.StatAdvice == nil and N.Data.Professions[171].legacyPoints == nil)
  end)

  check("Spells : Penitence = talent 402174 (IsPlayerSpell), plus l'ID 47540", function()
    if not IsPlayerSpell and not IsSpellKnown and not C_SpellBook then return end
    for _, sp in ipairs(N.Data.Spells) do
      if sp.key == "PENANCE" then assert(sp.talent and #sp.ranks == 1 and sp.ranks[1].id == 402174, "PENANCE") end
    end
    mock.known = { [402174] = true }
    mock.fire("SPELLS_CHANGED")
    assert(N.State.Knows("PENANCE") == 1, "talent pris = connu")
    mock.known = {}
    mock.fire("SPELLS_CHANGED")
    assert(N.State.Knows("PENANCE") == 0, "talent absent = non connu")
    mock.known = nil
    mock.fire("SPELLS_CHANGED")
  end)

  check("State : Knows ignore un rang sans nom (SWD), IsPlayerSpell qui plante", function()
    if not IsPlayerSpell and not IsSpellKnown and not C_SpellBook then return end
    local function has(list, key) for _, p in ipairs(list) do if p.key == key then return true end end end
    mock.known = {}
    mock.unknown = { spell = { [1309595] = true, [1309633] = true } }
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
    assert(st(ev(n, "rank_comp_herb")) == "unknown" and st(ev(n, "rank_comp_alch")) == "unknown")
    n.State.profs = { [182] = { rank = 100, max = 150 }, [171] = { rank = 10, max = 75 } }
    assert(st(ev(n, "rank_comp_herb")) == "done" and st(ev(n, "rank_comp_alch")) == "todo", "un objectif par metier")
    assert(ev(n, "rank_comp_herb").prof == 182 and ev(n, "rank_comp_alch").prof == 171, "prof recopie")
    n.State.profs[171].max = 150
    assert(st(ev(n, "rank_comp_alch")) == "done")
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
    -- point 4 : objectifs autrefois manuels, verifiables
    if C_QuestLog then
      local orig = C_QuestLog.IsQuestFlaggedCompleted
      for id, q in pairs({ rfc_staff = 5730, lord_staff = 914, triage = 6622 }) do
        n.State.level = id == "triage" and 36 or 16
        C_QuestLog.IsQuestFlaggedCompleted = function() return false end
        assert(st(ev(n, id)) == "todo", id .. " a faire")
        C_QuestLog.IsQuestFlaggedCompleted = function(x) return x == q end
        assert(st(ev(n, id)) == "done", id .. " fait")
      end
      C_QuestLog.IsQuestFlaggedCompleted = orig
    end
    n.State.level = 12
    if C_Item and C_Item.GetItemCount or GetItemCount then
      n.State.level = 25
      mock.items = {}
      assert(st(ev(n, "mana_potions")) == "todo")
      mock.items = { [3385] = 2, [3827] = 3 }
      assert(st(ev(n, "mana_potions")) == "done", "5 potions de mana = stock")
      mock.items = { [3385] = 2 }
      assert(st(ev(n, "mana_potions")) == "todo", "stock insuffisant")
      n.State.level = 12
    end
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

  check("Guide : objectif illisible masque, jamais coche a la main (plus de SetManual)", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 12 })
    n.State.talents = nil
    local e = ev(n, "legacy_toa")
    assert(e.unknown and e.manual and not e.done, "talent illisible : inconnu et masque")
    assert(n.Guide.SetManual == nil, "SetManual supprime")
    n.State.talents = { [1] = { rank = 1, max = 1, name = "thrill of adventure" } }
    assert(st(ev(n, "legacy_toa")) == "done", "talent lu par son nom")
    n.State.talents = { [1] = { rank = 0, max = 1, name = "Thrill of Adventure" } }
    assert(st(ev(n, "legacy_toa")) == "todo", "talent non pris")
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
    assert(list[1].id == "wandspec" and list[2].id == "spirittap" and list[3].id == "rank_comp_herb", "priorites d'abord : " .. list[1].id)
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
    assert(#r > 0 and #r < #D2.TalentPlan and r[1].text and r[1].highlight, "talents : seulement le niveau courant")
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
    assert(#r == 1, "seul le metier actif (Herboristerie) est liste")
    local byText = {}
    for _, p in ipairs(r) do byText[p.text] = p end
    assert(byText["Herboristerie"].sub:find("^Herboristerie 10/75") and byText["Alchimie"] == nil)
    r = G.Reference("undead")
    assert(#r == #D2.Undead and r[1].highlight and r[#r].highlight == (20 >= D2.Undead[#D2.Undead].level))
    local anyApi = IsPlayerSpell or IsSpellKnown or (C_SpellBook and C_SpellBook.IsSpellInSpellBook)
    knows({})
    r = G.Reference("spells")
    assert(#r < #D2.Spells, "pas de liste de tous les sorts")
    if anyApi then
      assert(r[1].highlight and r[1].text:find("(rang ", 1, true), "sort a apprendre en premier avec son rang : " .. r[1].text)
    else
      assert(#r == 1 and not r[1].highlight)
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

  -- Fenetre Guide : un ns neuf, niveau 12 (objectif « legacy_toa » illisible, masque).
  local function gw()
    local o = fresh()
    local n = o.n
    n.db.guide.tab, n.db.guide.compact = "now", false
    setState(n, { level = 12 })
    return n, n.UI.GuideWin
  end
  local TABS = { "now", "next", "talents", "spells", "dungeons", "zones", "profs", "undead", "sell", "gold", "route" }

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
    local todo = 0
    for _, e in ipairs(n.Guide.Evaluate()) do if not e.done then todo = todo + 1 end end
    assert(G.used == #n.Guide.Goals() and G.used > 0, "Maintenant : une ligne par categorie")
    G.win.tabs[2].scripts.OnClick(G.win.tabs[2])
    assert(G.used == #n.Guide.Milestones(), "Etapes : une ligne par jalon")
    G.win.tabs[3].scripts.OnClick(G.win.tabs[3])
    assert(G.used == #n.Guide.Reference("talents") and G.rows[1].text.text == n.Guide.Reference("talents")[1].text)
    -- niveau illisible : tout se dessine encore
    setState(n, {})
    for i = 1, #TABS do G.win.tabs[i].scripts.OnClick(G.win.tabs[i]) end
  end)

  check("GuideWindow : aucun objectif manuel ni case a cocher (carte et Maintenant)", function()
    local n, G = gw()
    n.ToggleGuide()
    local ev0 = n.Guide.Evaluate -- ne garde que des objectifs manuels : repli de zone, rien de manuel affiche
    n.Guide.Evaluate = function()
      local o = {}
      for _, e in ipairs(ev0()) do if e.manual then o[#o + 1] = e end end
      assert(#o > 0, "des objectifs manuels existent")
      return o
    end
    n.Fire("GUIDE")
    local goal = n.Guide.Goals()[1]
    assert(goal.e == nil and not goal.text:find("Legacy", 1, true), "XP : repli, pas d'objectif manuel : " .. goal.text)
    for i = 1, G.used do assert(not G.rows[i].entry or not G.rows[i].entry.manual, "Maintenant : rien de manuel") end
    n.SetCompact(true)
    for _, r in ipairs(G.card.rows) do assert(r.box == nil, "carte : plus de case manuelle") end
    assert(not G.card.rows[1].text.text:find("Legacy", 1, true))
    -- un objectif automatique illisible est passe lui aussi : le suivant prend sa place
    n.Guide.Evaluate = ev0
    setState(n, { level = 12, wand = nil })
    local first = n.Guide.Goals()[1]
    assert(not (first.e and (first.e.unknown or first.e.manual)), "XP : ni illisible ni manuel")
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
    assert(G.card.rows[1].text.text:find(n.Guide.Goals()[1].text, 1, true), "texte de l'objectif XP")
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
    assert(G.card.rows[1].text.text ~= nil, "niveau hors plage : texte de repli")
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

  check("Rotation : avant baguette, vie de la cible illisible = Chatiment tant qu'il reste du mana", function()
    local K = { SMITE = 1 }
    for smites = 0, 3 do
      rk({ level = 8, known = K, hasSWP = true, inCombat = true, smitesOnTarget = smites }, "SMITE,MELEE", smites .. " Chatiments")
    end
    local res = rk({ level = 8, known = K, hasSWP = true, inCombat = true, oom = true }, "MELEE", "plus de mana : corps a corps")
    assert(res.text ~= "" and res.reason ~= "")
  end)

  check("Rotation : regle des 5 s, mana illisible : toujours la baguette, jamais d'Attaque mentale par comptage", function()
    local o = { level = 12, hasWand = true, inCombat = true, hasSWP = true, known = { SWP = 1, MINDBLAST = 1 } }
    o.fiveSec = 3
    local r = rk(o, "SHOOT", "5 s en cours : baguette")
    assert(r.text:find("3 s", 1, true), "compte a rebours affiche")
    o.fiveSec = 0
    rk(o, "SHOOT", "5 s ecoulees, mana secret : baguette seule")
    o.manaPct = 80
    rk(o, "MINDBLAST,SHOOT", "mana lisible et haut : Attaque mentale")
    o.manaPct = nil
    o.hasWand = false o.fiveSec = 3 o.known.SMITE = 1
    rk(o, "SMITE,MELEE", "sans baguette, mana secret : pas d'Attaque mentale")
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
    rk(corpse, "DARKSAC,DRINK", "vie secrete : jamais de soin (ni cadavre ni bandage)")
    assert(N.Rotation.Compute(rctx(corpse)).text:find(N.L.ROT_RECOVER, 1, true), "titre Recupere")
    rk(merge(sec, {}), "DARKSAC,DRINK", "mana secret : boire propose sans comptage de sorts ; vie secrete : pas manger")
    rk(merge(sec, { manaCasts = 0, longFight = true }), "DARKSAC,DRINK", "aucun seuil de sorts a mana")
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
      n.db.guide.r6 = true -- rappel R6 deja fait : ce test ne compte que les toasts de R5
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

  check("R6 Thrill of Adventure : lu par nom (vert/rouge), illisible = un seul rappel puis neutre, sans case", function()
    isolated(function()
      local o = fresh()
      local n = o.n
      n.State.level, n.State.talents = 12, nil
      n.Rules.Evaluate()
      n.Rules.Evaluate()
      assert(rule(n, 6).state == "unknown" and not rule(n, 6).reason:find("coche"), "neutre, sans case")
      assert(count(o.rtoasts, "r6") == 1 and n.db.guide.r6 == true, "rappel unique, memorise")
      n.State.talents = { [1] = { rank = 0, max = 1, name = "Thrill of Adventure" } }
      n.Rules.Evaluate()
      assert(rule(n, 6).state == "bad")
      n.State.talents[1].rank = 1
      n.Rules.Evaluate()
      assert(rule(n, 6).state == "ok")
    end, rcleanup)
  end)

  check("R7 Brassenoire : niveaux 23/24/32/33, quete nil, toast Ashenvale unique", function()
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
      n.db.guide.r6 = true -- rappel R6 deja fait : ce test ne compte que les toasts de R8
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
      -- niveau 12 : Brassenoire (24-32) et double spe (40) masquees
      for i = 1, 8 do assert(B.buttons[i].shown == (i ~= 7 and i ~= 8), "niveau 12 : pastille " .. i) end
      n.State.level = 41 B.Render()
      assert(not B.buttons[7].shown and B.buttons[8].shown, "niveau 41 : 7 masquee, 8 visible")
      n.State.level = 28 B.Render()
      for i = 1, 8 do assert(B.buttons[i].shown == (i ~= 8), "niveau 28 : pastille " .. i) end
      n.State.level = nil B.Render()
      for i = 1, 8 do assert(B.buttons[i].shown, "niveau illisible : tout visible " .. i) end
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
    assert(t[1].text:find("^Nouveaux sorts chez ton maître %(" .. #p .. "%) : "), t[1].text)
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
      assert(P and P:IsShown() and P.body.text == "Sort2 (Rang 2) : " .. ("1" .. MI.o .. " 20" .. MI.a), "panneau : 1 service")
      assert(P.pt[1] == "CENTER", "sans ClassTrainerFrame : au centre")
      GetCoinTextureString = nil
      local f = CreateFrame("Frame", "ClassTrainerFrame")
      mock.fire("TRAINER_UPDATE")
      assert(P.body.text == "Sort2 (Rang 2) : 1" .. MI.o .. " 20" .. MI.a, P.body.text)
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
    assert(#t == 1 and t[1].text == "Point de talent : Ombre, rangée 1 : Connexion spirituelle (objectif 5/5)\nPoints non dépensés : 1", t[1] and t[1].text)
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
    assert(#t == 1 and t[1].text:find("31 points en Ombre", 1, true), "rappel du respec")
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
    local hasGap
    for _, row in ipairs(r) do if row.text == t[1].text and not row.highlight then hasGap = true end end
    assert(hasGap, "ligne discrete")
    n.State.talents = nil
    assert(n.Talents.GapLine() == nil, "talents inconnus : pas de ligne de plan")
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
    assert(sub:find("Fabrique : Recette101 (orange, +1 pt)  ·  Coût 1" .. MI.a .. "  ·  Vente HdV 1" .. MI.a .. " 60" .. MI.c .. "  ·  Marge |cff40ff40" .. "60" .. MI.c .. "|r", 1, true), sub)
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
    assert(sub:find("Fabrique : Recette104 (orange, +1 pt)", 1, true) and not sub:find("Coût", 1, true) and not sub:find("Marge", 1, true), sub)
    -- fenetre pas prete : rien de lu
    mock.tsNotReady = true
    n.Prof.Advice[171] = nil
    n.db.prof = nil
    open()
    assert(n.Prof.Get(171) == nil, "fenetre non prete")
    -- format monetaire unique, icones de pieces, zeros omis ; GetCoinTextureString gardee seulement si elle rend des |T
    local g = GetCoinTextureString
    for _, f in ipairs({ g or false, false }) do
      GetCoinTextureString = f or nil
      local m = n.Prof.Money
      assert(m(12000) == "1" .. MI.o .. " 20" .. MI.a and m(10000) == "1" .. MI.o and m(10005) == "1" .. MI.o .. " 5" .. MI.c, "or seul, or + argent, or + cuivre")
      assert(m(5) == "5" .. MI.c and m(0) == "0" .. MI.c and m(100) == "1" .. MI.a and m(mock.SECRET) == "?", "cuivre seul, zero, secret")
    end
    GetCoinTextureString = function(c) return c .. "|TInterface\\X:0|t" end
    assert(n.Prof.Money(7) == "7|TInterface\\X:0|t", "chaine du jeu avec |T conservee")
    local pm = n.Prof.Money
    assert(pm(12005, true) == "1 po 20 pa 5 pc" and pm(3600, true) == "36 pa" and pm(0, true) == "0 pc" and pm(mock.SECRET, true) == "?"
      and not pm(12005, true):find("|T", 1, true), "texte brut po/pa/pc (sonde), meme avec GetCoinTextureString")
    GetCoinTextureString = g
    -- marge : verte si positive, rouge si negative, aucun signe colle aux icones
    local adv2 = { list = { { name = "R", color = "orange", skillUps = 1, cost = 100, value = 50, margin = -50 } } }
    n.Prof.Advice[171] = adv2
    local txt = n.Prof.Text(171)
    assert(txt:find("Marge |cffff4040" .. "50" .. MI.c .. "|r", 1, true) and not txt:match("Marge (.*)"):find("[%+%-]%d"), txt)
    adv2.list[1].margin = 0
    assert(n.Prof.Text(171):find("Marge 0" .. MI.c, 1, true) and not n.Prof.Text(171):find("|cff40ff40", 1, true), "marge nulle : sans couleur")
    n.Prof.Advice[171] = nil
    mock.recipes = nil
  end)

  check("Vente L17a : conseils, tri, totaux, prix ancien, sans Auctionator, combat, API absente, onglet", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 12, profs = { [171] = { rank = 50, max = 75 } } })
    n.db.guide.tab, n.db.guide.compact = "now", false
    local function scan() mock.fire("BAG_UPDATE_DELAYED") mock.flushTimers() end
    if not C_Container then
      scan() -- API absente : aucune erreur, rien de lu
      assert(#n.Sell.Lines == 0 and n.Sell.scanned and #n.Sell.Rows() >= 0)
      return
    end
    local function it(id, q, quality, bound) return { itemID = id, stackCount = q, quality = quality, isBound = bound } end
    -- 100 gris, 101 cher a l'HdV, 102 lie, 103 sans prix, 104 prix ancien, 105 blanc a prix marchand, 106 bien de metier, 1251 bandage
    mock.bagInfo = { it(100, 3, 0), it(101, 2, 1), it(102, 1, 0, true), it(103, 1, 1), it(104, 1, 2), it(105, 1, 1), it(106, 1, 1), it(1251, 1, 1) }
    mock.sellPrice = { [100] = 10, [101] = 100, [102] = 10, [104] = 20, [105] = 40, [106] = 5, [1251] = 30 }
    mock.itemClass = { [106] = 7 }
    mock.ah = { [101] = { 1000, 2 }, [104] = { 300, 10 } }
    local function ids() local t = {} for i, l in ipairs(n.Sell.Lines) do t[i] = l.itemID .. ":" .. l.advice end return table.concat(t, ",") end
    -- combat : aucune lecture, reprise a la fin du combat
    mock.setCombat(true)
    scan()
    assert(not n.Sell.scanned and n.Sell.Scan() == false, "aucune lecture en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED") mock.flushTimers()
    assert(n.Sell.scanned, "lecture apres le combat")
    assert(ids() == "101:ah,104:ah,105:merchant,100:merchant,106:merchant", "tri par gain, lie/sans prix/bandage ecartes : " .. ids())
    assert(n.Sell.Totals.ah == 2300 and n.Sell.Totals.merchant == 75, "totaux")
    assert(n.Sell.Lines[2].old and not n.Sell.Lines[1].old, "prix ancien (10 j) seulement")
    assert(n.Sell.Lines[5].maybe and not n.Sell.Lines[4].maybe, "bien de metier signale, pas ecarte")
    assert(n.db.sell == nil and not findSecret(n.db, "db"), "rien de stocke")
    -- onglet : totaux, puis une ligne par pile avec icone
    n.ToggleGuide()
    local G = n.UI.GuideWin
    for i, key in ipairs(TABS) do if key == "sell" then G.win.tabs[i].scripts.OnClick(G.win.tabs[i]) end end
    assert(n.db.guide.tab == "sell" and G.used == 6, "onglet Vente : totaux + 5 piles")
    assert(G.rows[1].text.text:find("À l'HdV : 23" .. MI.a .. "  ·  Au marchand : 75" .. MI.c, 1, true), G.rows[1].text.text)
    assert(G.rows[2].text.text:find("Hôtel des ventes", 1, true) and G.rows[3].sub.text:find("prix ancien", 1, true))
    assert(G.rows[6].sub.text:find("sert peut-être à ton métier", 1, true))
    -- sans Auctionator : seuls les conseils Marchand, et la note
    local ah = Auctionator
    Auctionator = nil
    scan()
    assert(ids() == "101:merchant,105:merchant,100:merchant,104:merchant,106:merchant", "sans HdV : marchand seul : " .. ids())
    assert(n.Sell.Rows()[1].text:find("Installe Auctionator", 1, true) == nil and n.Sell.Rows()[2].text:find("Installe Auctionator", 1, true), "note apres les totaux")
    Auctionator = ah
    -- au plus 15 piles
    local many = {}
    for i = 1, 20 do many[i] = it(200 + i, 1, 0) end
    mock.bagInfo, mock.sellPrice = many, 3
    scan()
    assert(#n.Sell.Lines == 20 and #n.Sell.Rows() == 16, "15 piles + totaux")
    -- API de sac qui plante : pas d'erreur
    local c = C_Container.GetContainerNumSlots
    C_Container.GetContainerNumSlots = function() error("boom") end
    scan()
    C_Container.GetContainerNumSlots = c
    assert(#n.Sell.Lines == 0)
  end)

  check("Garder ou vendre : vendre, crafter, monter le metier, focus, prix inconnu, bulle, Sell coherent", function()
    local o = fresh()
    local n = o.n
    local function keys(t) local k = {} for x in pairs(t) do k[#k + 1] = tostring(x) end table.sort(k) return table.concat(k, ",") end
    n.db.guide.focus, n.db.show.keeptip = "gold", true -- reglages de depart : le reste ne doit rien ajouter
    local before = keys(n.db) .. "|" .. keys(n.db.show)
    local function prof(rank, max) setState(n, { level = 1, profs = { [171] = { rank = rank, max = max } } }) end
    local function focus(f) n.db.guide.focus = f end
    prof(50, 75)
    mock.items, mock.ah, mock.sellPrice = {}, {}, {}
    local K = n.Keep
    local function text(id, have) local v = K.Verdict(id, have) return v and K.Text(v) or "aucun" end
    local function find(s, sub) return s:find(sub, 1, true) end
    -- marchand seul : Pacifique (2447) vaut 10 c, le metier monte de 50 a 75 : besoin 5 + 10 + 11 = 26, surplus vendu
    mock.sellPrice[2447] = 10
    focus("gold")
    local v = K.Verdict(2447, 40)
    assert(v.keep == 26 and v.rest == 14 and v.target == 75 and v.restKind == "sell", "garder 26, surplus 14")
    assert(text(2447, 40) == "GARDER 26 · Alchimie 50→75  ·  vendre le reste (14) au marchand : 10" .. MI.c .. " l'unité", text(2447, 40))
    assert(K.Verdict(2447, 20).keep == 20 and K.Verdict(2447, 20).rest == 0, "tout garder sous le besoin")
    -- plafond atteint : plus rien a garder, on vend
    prof(75, 75)
    assert(K.Verdict(2447, 40).keep == 0 and find(text(2447, 40), "VENDRE · au marchand : 10" .. MI.c), text(2447, 40))
    prof(50, 75)
    -- prix inconnu : Soleillette (8838) n'est pas utile avant le rang 225
    assert(text(8838, 4) == "PRIX INCONNU · scanne l'HdV", text(8838, 4))
    -- objet sans rapport, ou compte nul
    assert(K.Verdict(100, 5) == nil and K.Verdict(2447, 0) == nil)
    -- potions et bandages : stock de jeu selon le focus
    mock.itemClass, mock.itemSub = { [118] = 0 }, { [118] = 1 }
    mock.sellPrice[118] = 30
    focus("gold")
    assert(K.Verdict(118, 30).keep == 0 and find(text(118, 30), "VENDRE · au marchand"), "or : potions vendues")
    focus("xp")
    assert(find(text(118, 30), "GARDER 20 · à utiliser en jeu  ·  vendre le reste (10) au marchand"), text(118, 30))
    focus("balanced")
    assert(K.Verdict(1251, 12).keep == 5, "bandage : stock equilibre")
    if Auctionator then
      -- HdV : Feuillargent (765) 1000 c ; besoin 5 (50 -> 55) GARDE quel que soit le focus, le rachat est affiche, le reste est vendu
      mock.ah[765] = { 1000, 1 }
      for _, f in ipairs({ "gold", "balanced", "xp" }) do
        focus(f)
        assert(text(765, 8) == "GARDER 5 · Alchimie 50→55 · racheter ≈ " .. n.Prof.Money(5250) .. "  ·  vendre le reste (3) à l'HdV : "
          .. n.Prof.Money(1000) .. " l'unité", f .. " : " .. text(765, 8))
      end
      focus("gold")
      assert(K.Verdict(765, 4).rest == 0 and K.Verdict(765, 4).keep == 4 and K.Verdict(765, 4).kind == "keep", "sous le besoin : tout garde")
      -- vieux prix (> 7 jours) : marchand
      mock.ah[765] = { 1000, 10 }
      mock.sellPrice[765] = 7
      focus("gold")
      assert(K.Verdict(765, 8).sellSrc == "merchant" and K.Verdict(765, 8).sell == 7, "prix ancien ignore")
      mock.ah[765] = { 1000, 1 }
      -- crafter pour vendre : recette connue, produit 5000 c, autres composants Pacifique 100 c (HdV) + fiole 4 x 5 c (marchand)
      mock.ah[2447] = { 100, 1 }
      mock.sellPrice[3371] = 5
      n.Prof.Advice[171] = { list = { { name = "Élixir de défense mineure", color = "orange", value = 5000 } } }
      v = K.Verdict(765, 8)
      assert(v.restKind == "craft" and v.craft == 4880 and v.rest == 3 and v.keep == 5, "crafter : " .. tostring(v.craft))
      assert(find(text(765, 8), "vendre le reste") == nil and find(text(765, 8), "crafter le reste (3) : Élixir de défense mineure, +" .. n.Prof.Money(4880) .. " par unité"), text(765, 8))
      assert(text(765, 4) ~= nil and K.Verdict(765, 8).kind == "keep")
      -- un composant sans prix : pas de craft, on vend
      mock.ah[2447], mock.sellPrice[2447], mock.sellPrice[3371] = nil, nil, nil
      assert(K.Verdict(765, 8).restKind ~= "craft", "composant sans prix : pas de marge inventee")
      mock.ah[2447], mock.sellPrice[2447], mock.sellPrice[3371] = { 100, 1 }, 10, 5
      mock.sellPrice[2449] = 10
      -- Sell ne propose pas la ressource a crafter, ni la part gardee d'une pile ; la ligne Or propose le craft
      if C_Container then
        local function it(id, q) return { itemID = id, stackCount = q, quality = 1 } end
        mock.bagInfo = { it(765, 8), it(2449, 30) }
        mock.items = { [765] = 8, [2449] = 30 }
        n.Sell.Scan()
        local seen = {}
        for _, l in ipairs(n.Sell.Lines) do seen[l.itemID] = l end
        assert(not seen[765], "ressource a crafter : jamais vendue")
        assert(seen[2449] and seen[2449].count == 8, "pile de 30 : 22 gardes, 8 proposes")
        local rows = n.Sell.Rows()
        local all = rows[#rows - 1].text .. rows[#rows].text
        assert(find(all, "GARDER 22 · Alchimie 50→75") and find(all, "crafter le reste (3) : Élixir"), "rangees Garder / Crafter : " .. all)
        local c = n.Gold.Candidates()[1]
        assert(c.kind == "craft" and find(c.text, "Fabrique Élixir de défense mineure avec tes 3 "), c.text)
        mock.items[2449], mock.bagInfo = 20, { it(2449, 20) }
        n.Sell.Scan()
        for _, l in ipairs(n.Sell.Lines) do assert(l.itemID ~= 2449, "pile entierement gardee") end
        mock.bagInfo, mock.items = nil, nil
      end
    end
    -- bulle d'info : une ligne, option, combat ; repli OnTooltipSetItem sans TooltipDataProcessor
    mock.items, mock.ah, n.Prof.Advice[171] = { [2447] = 40 }, {}, nil
    mock.sellPrice[2447] = 10
    focus("gold")
    local function tip(id)
      GameTooltip.lines = nil
      mock.tipItem = "|cffffffff|Hitem:" .. id .. "::::::::12:|h[x]|h|r"
      if mock.tipPost then mock.tipPost(GameTooltip, { id = id }) else GameTooltip.hooks.OnTooltipSetItem(GameTooltip) end
      return GameTooltip.lines and table.concat(GameTooltip.lines, " / ")
    end
    local line = tip(2447)
    if not GetItemCount then assert(line == nil, "compte illisible : aucune ligne") mock.items = nil return end
    assert(line and find(line, "PretreCoach : GARDER 26 · Alchimie 50→75"), tostring(line))
    assert(tip(100) == nil, "objet sans conseil : aucune ligne")
    n.db.show.keeptip = false
    assert(tip(2447) == nil, "option decochee : aucune ligne")
    n.db.show.keeptip = true
    mock.setCombat(true)
    assert(tip(2447) == nil, "rien en combat")
    mock.setCombat(false)
    assert(not findSecret(n.db, "db") and not findSecret(K.All(), "keep"), "rien de secret")
    assert(keys(n.db) .. "|" .. keys(n.db.show) == before, "aucune nouvelle cle dans la base")
    if TooltipDataProcessor then
      local keep = TooltipDataProcessor
      TooltipDataProcessor = nil
      local o2 = fresh()
      mock.tipPost = nil
      setState(o2.n, { level = 1, profs = { [171] = { rank = 50, max = 75 } } })
      o2.n.db.guide.focus = "gold"
      assert(find(tip(2447) or "", "GARDER 26"), "repli OnTooltipSetItem")
      TooltipDataProcessor = keep
    end
    mock.items = nil
  end)

  check("Garder ou vendre v2 : horizon au-dela du plafond, rachat, recette apprise hors plan, bulle formatee", function()
    local o = fresh()
    local n = o.n
    n.db.guide.focus, n.db.show.keeptip = "gold", true
    mock.items, mock.ah, mock.sellPrice = {}, {}, { [2447] = 10, [3371] = 5 }
    local K = n.Keep
    local function find(s, sub) return s:find(sub, 1, true) end
    -- rang 64/75, niveau 12 : le rang Compagnon est ouvert (niveau 10) donc l'horizon (64 + 50) passe le plafond 75
    setState(n, { level = 12, profs = { [171] = { rank = 64, max = 75 } } })
    local v = K.Verdict(2447, 200)
    assert(v.keep > 0 and v.target == 90 and v.after > 0 and v.nextName == "Compagnon", "horizon : " .. tostring(v.target) .. "/" .. tostring(v.after))
    local head = K.Lines(v)
    assert(find(head, "GARDER " .. v.keep .. " · Alchimie 64→90 (dont " .. v.after .. " après le rang Compagnon)"), head)
    -- rang pas encore accessible (niveau 1) : plafond 75 seulement
    setState(n, { level = 1, profs = { [171] = { rank = 64, max = 75 } } })
    assert(K.Verdict(2447, 200).target == 75 and K.Verdict(2447, 200).after == 0, "rang suivant lointain : plafond du rang")
    -- focus or : on garde quand meme ; rachat HdV + 5 % affiche
    setState(n, { level = 12, profs = { [171] = { rank = 64, max = 75 } } })
    if Auctionator then
      mock.ah[2447] = { 100, 1 }
      v = K.Verdict(2447, 5)
      assert(v.kind == "keep" and v.keep == 5 and v.rebuy == 105 * 5, "focus or garde : " .. tostring(v.rebuy))
      assert(find(K.Text(v), "racheter ≈ " .. n.Prof.Money(525)), K.Text(v))
    end
    -- recette apprise hors plan (index lu fenetre ouverte) : Soleillette (8838) n'est pas dans le plan avant 225
    if not C_TradeSkillUI then return end -- API de metier absente : rien a lire
    mock.tsNotReady = nil
    mock.recipes = 1
    mock.recipeInfo = { [101] = { name = "Potion X", relativeDifficulty = 0, numSkillUps = 1 } }
    mock.schematics = { [101] = { reagentSlotSchematics = { { quantityRequired = 3, reagents = { { itemID = 8838 } } } } } }
    mock.sellPrice[8838] = 50
    assert(K.Verdict(8838, 20).restKind == "sell" and K.Verdict(8838, 20).keep == 0, "avant lecture : vendre")
    n.Prof.Read()
    local e = n.db.reagents and n.db.reagents[8838] and n.db.reagents[8838][1]
    assert(e.n == 3 and e.name == "Potion X" and e.color == "orange" and e.line, "index en base")
    v = K.Verdict(8838, 20)
    assert(v.keep == 15 and v.rest == 5 and v.restKind == "sell" and v.kind == "keep", "recette orange : 5 fabrications x 3")
    local h2, d2 = K.Lines(v)
    assert(find(h2, "GARDER 15 · Alchimie, recette Potion X") and find(d2, "vendre le reste (5) au marchand : "), h2 .. " / " .. tostring(d2))
    -- recette devenue verte : l'index est reconstruit, plus rien a garder
    mock.recipeInfo[101].relativeDifficulty = 2
    n.Prof.Read()
    assert(K.Verdict(8838, 20).keep == 0, "recette verte : plus de besoin")
    mock.recipeInfo[101].relativeDifficulty = 0
    n.Prof.Read()
    -- bulle : verdict en tete, detail en seconde ligne
    mock.items = { [8838] = 20 }
    GameTooltip.lines = nil
    mock.tipItem = "|cffffffff|Hitem:8838::::::::12:|h[x]|h|r"
    if mock.tipPost then mock.tipPost(GameTooltip, { id = 8838 }) elseif GameTooltip.hooks and GameTooltip.hooks.OnTooltipSetItem then GameTooltip.hooks.OnTooltipSetItem(GameTooltip) end
    if GetItemCount and GameTooltip.lines then
      assert(#GameTooltip.lines == 2 and find(GameTooltip.lines[1], "PretreCoach : GARDER 15") and find(GameTooltip.lines[2], "vendre le reste (5)"), table.concat(GameTooltip.lines, " / "))
    end
    assert(not findSecret(n.db, "db"), "rien de secret en base")
    mock.recipes, mock.recipeInfo, mock.schematics, mock.items = nil, nil, nil, nil
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

  check("Cadres de soin : creation hors combat, attributs, options, unite absente", function()
    local before = #mock.secure
    local n, restore = boot()
    local H = n.UI.HealFrames
    assert(#H.buttons == 5 and (function() local k = 0 for i = before + 1, #mock.secure do if mock.secure[i].template == "SecureUnitButtonTemplate" then k = k + 1 end end return k end)() == 5 and mock.secureInCombat == 0, "5 boutons securises crees hors combat")
    local lesser, renew, pws = H.SpellName("LESSERHEAL"), H.SpellName("RENEW"), H.SpellName("PWS")
    for _, b in ipairs(H.buttons) do
      assert(b.template == "SecureUnitButtonTemplate" and (b.watched or not RegisterUnitWatch), "gabarit securise et RegisterUnitWatch")
      assert(b.attrs.unit == b.unit and b.attrs.type1 == "spell" and b.attrs.spell1 == lesser, "clic gauche")
      assert(b.attrs.type2 == "spell" and b.attrs.spell2 == renew, "clic droit")
      assert(b.attrs["shift-type1"] == "spell" and b.attrs["shift-spell1"] == pws, "maj + clic gauche")
      assert(b.attrs.macrotext == nil and b.mana, "pas de macro, barre de mana")
    end
    assert(H.buttons[1].unit == "player" and H.buttons[5].unit == "party4")
    -- groupe present : affiche ; option masquer ; unite absente
    H.Render()
    assert(H.frame:IsShown(), "affiche en groupe")
    n.db.show.heal = false; H.Render()
    assert(not H.frame:IsShown(), "option masquer")
    n.db.show.heal = true; mock.hasTarget = false; H.Render()
    assert(H.frame:IsShown(), "seul : le cadre reste visible (bouton du joueur), sans erreur")
    mock.hasTarget = true; H.Render()
    -- combat : la vie secrete va telle quelle aux StatusBar, aucun SetAttribute, changement differe
    local calls = mock.attrCalls
    mock.setCombat(true)
    H.Render()
    local b = H.buttons[2]
    assert(b.bar.value ~= nil and b.mana.value ~= nil, "vie et mana donnees au StatusBar")
    if not mock.noSecrets then
      assert(mock.isSecret(b.bar.value) and mock.isSecret(b.bar.max), "vie secrete donnee au StatusBar")
      assert(mock.isSecret(b.mana.value) and mock.isSecret(b.mana.max), "mana secrete donnee au StatusBar")
    end
    H.Cycle("1", 1)
    assert(mock.attrCalls == calls and mock.attrInCombat == 0, "aucun SetAttribute en combat")
    assert(b.attrs.spell1 == lesser, "attribut inchange en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(b.attrs.spell1 ~= lesser and b.attrs.spell1 == H.SpellName(n.db.heal.spells["1"]) and mock.attrInCombat == 0, "pose a la sortie du combat")
    restore()
  end)

  check("Cadres de soin : nom en couleur de classe (blanc sinon), bouton sur toute la rangee", function()
    local n, restore = boot()
    local H = n.UI.HealFrames
    local b = H.buttons[1]
    H.Refresh(b)
    local c = b.name.textColor
    assert(c and c[1] == 0.9 and c[2] == 0.8 and c[3] == 0.7, "couleur de classe")
    mock.noClass = true
    H.Refresh(b)
    c = b.name.textColor
    mock.noClass = nil
    assert(c[1] == 1 and c[2] == 1 and c[3] == 1, "blanc si classe illisible")
    assert(b.width == 70 + 6 + 200 and b.height == 18, "le bouton couvre nom + barre")
    assert(b.bar.width == 200 and b.mana.height == 3 and b.name.width == 70, "tailles")
    restore()
  end)

  check("Cadres de soin : creation differee si le chargement a lieu en combat", function()
    local keep = mock.attrInCombat
    mock.setCombat(true)
    local n, restore = boot()
    assert(#n.UI.HealFrames.buttons == 0 and mock.secureInCombat == 0, "rien cree en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(#n.UI.HealFrames.buttons == 5 and mock.attrInCombat == keep and mock.secureInCombat == 0, "cree apres le combat")
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
    n.db.guide.done.x, n.db.guide.done.y = true, true
    n.db.training.count = 7
    cmd("reset")
    local p, _, _, x, y = rules:GetPoint()
    assert(p == "TOP" and x == 0 and y == -20, "recentre a la place d'origine")
    assert(next(n.db.frames) == nil and n.db.scale == 1 and n.db.opacity == 0.9, "defauts")
    assert(rules.scale == 1, "echelle appliquee")
    assert(n.db.guide.done.x and n.db.guide.done.y and n.db.training.count == 7, "objectifs et stats intacts")
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
    same(q.trainers.ALCHEMY, 300); same(q.trainers.HERBALISM, 301, 307); same(q.trainers.FIRSTAID, 302, 309); same(q.trainers.COOKING, 303)
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
    assert(n2.db.qindex.fmt == 3)
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

  check("Questie : maitres reconnus par un subName francais (Questie frFR)", function()
    if not LibQuestieDB then return end
    local n = qboot()
    mock.qnpcs[310] = { 16, "Maître des alchimistes", "H", 1497, { [1497] = { { 50, 40 } } } }
    mock.qnpcs[311] = { 16, "Maître herboriste", "AH", 1497, { [1497] = { { 52, 41 } } } }
    n.Q.StartIndex(); drain()
    local idx = n.db.qindex
    local function has(list, id) for _, x in ipairs(list or {}) do if x == id then return true end end end
    assert(idx and has(idx.trainers.ALCHEMY, 310) and has(idx.trainers.HERBALISM, 311), "maitres francais indexes")
    mock.qnpcs[310], mock.qnpcs[311] = nil, nil
  end)

  check("/coach pretre : maitre le plus proche dans le chat et repere pose", function()
    if not LibQuestieDB then return end
    local n = qboot()
    n.Q.StartIndex(); drain()
    local np = #mock.printed
    SlashCmdList.PRETRECOACH("pretre")
    assert(#mock.printed > np and tostring(mock.printed[np + 1]):find(n.L.GO_ROLE_PRIEST, 1, true), tostring(mock.printed[np + 1]))
    assert(mock.waypoint ~= nil, "repere pose")
    SlashCmdList.PRETRECOACH("alchimie")
    assert(tostring(mock.printed[#mock.printed]):find(n.L.GO_ROLE_ALCHEMY, 1, true) or mock.waypoint ~= nil)
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

  check("Guide : quetes cles (tranche, prerequis, fait, sans Questie, donneur en instance)", function()
    local n = fresh().n
    for _, q in ipairs(n.Data.KeyQuests) do
      assert(type(q.id) == "number" and q.from <= q.to and type(q.why) == "string" and q.source:find(":%d+"), "donnee : " .. tostring(q.id))
    end
    for _, q in ipairs(n.Data.KeyQuests) do assert(q.id ~= 5658, "5658 absente de Forever") end
    local seen, top = {}, 0
    for _, q in ipairs(n.Data.KeyQuests) do
      assert(not seen[q.id] and q.source:find("QuestieDB_Forever.toc:%d+"), "doublon ou source : " .. q.id)
      seen[q.id] = true; top = math.max(top, q.to)
    end
    assert(top == 60, "les quetes cles vont jusqu au 60")
    -- quete de test (fictive) : la logique de tranche et de prerequis ne depend pas d'une vraie quete
    local TQ = { id = 99658, from = 10, to = 19, why = "quete test, Toucher de faiblesse", source = "test:1" }
    table.insert(n.Data.KeyQuests, TQ)
    local done, unk = {}, { [8888] = true }
    local orig = C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
    if C_QuestLog then C_QuestLog.IsQuestFlaggedCompleted = function(id) if not unk[id] then return done[id] == true end end end
    local ok, err = pcall(function()
      mock.qquests = { [99658] = { name = "Toucher", startedBy = { { 375 } }, requiredLevel = 10 },
        [6921] = { name = "Ruines", startedBy = { { 308 } }, requiredLevel = 21 } }
      setState(n, { level = 12 })
      assert(st(ev(n, "kq99658")) == "todo" and ev(n, "kq99658").priority == 3, "dans la tranche")
      if LibQuestieDB then
        assert(ev(n, "kq99658").go == "Q99658" and ev(n, "kq99658").text:find("Toucher", 1, true) and ev(n, "kq99658").text:find("faiblesse", 1, true))
      else
        assert(ev(n, "kq99658").go == nil and ev(n, "kq99658").text == TQ.why, "sans Questie : why seul, pas de Ou aller")
      end
      assert(ev(n, "kq906") == nil, "hors tranche")
      assert((ev(n, "kq451") == nil) == (C_QuestLog ~= nil), "prerequis (450) pas fait masque, inconnu propose")
      setState(n, { level = 9 })
      assert(ev(n, "kq99658") == nil, "avant la tranche")
      setState(n, { level = 20 })
      assert(ev(n, "kq99658") == nil, "apres la tranche")
      setState(n, { level = 12 })
      if C_QuestLog then
        done[450] = true
        assert(st(ev(n, "kq451")) == "todo", "prerequis fait")
        done[99658] = true
        assert(st(ev(n, "kq99658")) == "done", "fait : l'onglet Maintenant la retire comme les autres")
        done[99658] = nil
      end
      if LibQuestieDB then
        mock.qquests[99658].requiredLevel = 14
        assert(ev(n, "kq99658") == nil, "niveau requis Questie pas atteint")
        mock.qquests[99658].requiredLevel, mock.qquests[99658].preQuestGroup = 10, { 9999 }
        assert(ev(n, "kq99658") == nil, "prerequis de groupe pas fait")
        mock.qquests[99658].preQuestGroup = { 8888 }
        assert(st(ev(n, "kq99658")) == "todo", "prerequis inconnu : on propose")
        mock.qquests[99658].preQuestGroup, mock.qquests[99658].preQuestSingle = nil, { 9999, 9998 }
        assert(ev(n, "kq99658") == nil, "aucun prerequis alternatif fait")
        done[9998] = true
        assert(st(ev(n, "kq99658")) == "todo", "un prerequis alternatif suffit")
        setState(n, { level = 26 })
        local e = ev(n, "kq6921")
        assert(e and e.go == "Q6921")
        assert(not n.Goto.CanPlace(n.Goto.For(e.go)), "donneur en instance : pas de bouton Repere")
      end
    end)
    if C_QuestLog then C_QuestLog.IsQuestFlaggedCompleted = orig end
    mock.qquests = nil
    for k = #n.Data.KeyQuests, 1, -1 do if n.Data.KeyQuests[k] == TQ then table.remove(n.Data.KeyQuests, k) end end
    assert(ok, err)
    if LibQuestieDB then
      -- sans Questie : les donnees seules
      local lib = LibQuestieDB
      _G.LibQuestieDB = nil
      local ok2, err2 = pcall(function()
        local m = fresh().n
        table.insert(m.Data.KeyQuests, TQ)
        setState(m, { level = 12 })
        assert(not m.Q.Available() and st(ev(m, "kq99658")) == "todo" and ev(m, "kq99658").go == nil)
        assert(ev(m, "kq451") == nil, "prerequis `after` des donnees")
      end)
      _G.LibQuestieDB = lib
      for _, D in ipairs({ n.Data, (fresh().n).Data }) do
        for k = #D.KeyQuests, 1, -1 do if D.KeyQuests[k] == TQ then table.remove(D.KeyQuests, k) end end
      end
      assert(ok2, err2)
    end
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

  -- Rythme et barre vers le 60 : mock.time pilote GetTime, mock.xp / xpMax / level l'etat du joueur
  local toasts
  local function pboot(level, xp, xpMax, secret)
    mock.reset()
    mock.level, mock.xp, mock.xpMax, mock.xpSecret = level, xp, xpMax, secret
    local n = loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    toasts = {}
    n.Toast = function(t) toasts[#toasts + 1] = t return true end
    return n
  end
  local function gain(at, xp)
    mock.time, mock.xp = at, xp
    mock.fire("PLAYER_XP_UPDATE", "player")
  end
  local function levelUp(at, lvl, xp, xpMax)
    mock.time, mock.xp, mock.xpMax = at, xp, xpMax
    mock.fire("PLAYER_XP_UPDATE", "player")
    mock.level = lvl
    mock.fire("PLAYER_LEVEL_UP", lvl)
  end
  local function printed() return table.concat(mock.printed, "\n") end

  check("Pace : gains, XP/h, estimation du niveau (seuils 3 gains et 2 min)", function()
    local n = pboot(10, 0, 1000)
    if not UnitXP then return end
    gain(60, 100); gain(120, 250)
    assert(n.Pace.NextLevel() == nil, "2 gains : pas d'estimation")
    gain(180, 400)
    assert(math.abs(n.Pace.Rate() - 8000) < 0.01, "XP/h " .. tostring(n.Pace.Rate()))
    assert(math.abs(n.Pace.NextLevel() - 270) < 0.01, "estimation en secondes")
    local t = n.Pace.Text()
    assert(t:find("8 000 XP/h", 1, true) and t:find("niveau suivant ~5 min", 1, true), t)
    assert(n.Pace.Fraction() == 0.4)
    mock.time = 180 + 5000 -- le jeu a continue sans gain : plus de temps actif dans la fenetre
    assert(n.Pace.Rate() == nil and n.Pace.NextLevel() == nil)
  end)

  check("Pace : une pause de plus de 5 min est ignoree", function()
    local n = pboot(10, 0, 1000)
    if not UnitXP then return end
    gain(100, 100)
    gain(1100, 200) -- 1000 s sans gain : ni ce temps ni ce gain ne comptent
    assert(math.abs(n.Pace.Rate() - 3600) < 0.01, "XP/h " .. tostring(n.Pace.Rate()))
  end)

  check("Pace : passage de niveau, historique, estimation du 60 et record", function()
    local n = pboot(10, 0, 1000)
    if not UnitXP then return end
    gain(60, 100); gain(120, 250); gain(180, 400)
    levelUp(240, 11, 50, 1200) -- XP_UPDATE avant LEVEL_UP : 600 + 50
    assert(toasts[1] == "Niveau 11 en 4m 00s - bravo !", tostring(toasts[1]))
    assert(#toasts == 1, "premier niveau mesure : pas de record annonce")
    assert(n.db.pace.levels[10].secs == 240 and n.db.pace.record.secs == 240)
    local s, need = n.Pace.Sixty()
    assert(s == nil and need == 2 and n.Pace.Text():find("60 : estimation après 2 niveaux", 1, true), n.Pace.Text())
    levelUp(300, 12, 10, 1400) -- 60 s : record
    assert(toasts[2] == "Niveau 12 en 1m 00s - bravo !" and toasts[3] == "Record : niveau 11 en 1m", table.concat(toasts, "|"))
    -- LEVEL_UP avant XP_UPDATE : le gain doit etre compte une seule fois
    mock.time, mock.level, mock.xp, mock.xpMax = 400, 13, 5, 1600
    mock.fire("PLAYER_LEVEL_UP", 13)
    mock.fire("PLAYER_XP_UPDATE", "player")
    assert(n.db.pace.levels[12].secs == 100 and n.db.pace.record.secs == 60 and #toasts == 4, "pas de nouveau record")
    local sixty = n.Pace.Sixty()
    assert(math.abs(sixty - (240 + 60 + 100) / 3 * (47 - 5 / 1600)) < 0.01, "moyenne des 3 derniers niveaux : " .. tostring(sixty))
    assert(n.Pace.Text():find("60 dans ~2 h", 1, true), n.Pace.Text())
    SlashCmdList.PRETRECOACH("bilan")
    local out = printed()
    assert(out:find("XP gagnée 3 605", 1, true) and out:find("niveaux pris 3", 1, true), out)
    assert(out:find("Record : niveau 11 en 1m", 1, true), out)
    assert(not findSecret(n.db, "db"), "rien de secret dans la base")
  end)

  check("Pace : niveau commence hors addon, jamais d'historique faux", function()
    local n = pboot(10, 400, 1000)
    if not UnitXP then return end
    levelUp(500, 11, 20, 1200)
    assert(n.db.pace.levels[10] == nil and n.db.pace.record == nil and toasts[1] == "Niveau 11 - bravo !", tostring(toasts[1]))
  end)

  check("Pace : gain recu en combat (valeur secrete) rattrape a la fin du combat", function()
    local n = pboot(10, 0, 1000)
    if not UnitXP then return end
    gain(60, 100)
    mock.setCombat(true)
    mock.time = 90
    mock.fire("PLAYER_XP_UPDATE", "player") -- XP secrete : aucune erreur, rien de compte
    mock.setCombat(false)
    mock.xp = 300
    mock.time = 120
    mock.fire("PLAYER_REGEN_ENABLED")
    SlashCmdList.PRETRECOACH("bilan")
    assert(printed():find("XP gagnée 300", 1, true), printed())
  end)

  check("Pace : XP secrete ou absente, tout est inconnu sans erreur", function()
    local n = pboot(10, 5, 100, true)
    gain(60, 5); gain(120, 5); gain(180, 5)
    levelUp(240, 11, 5, 100)
    assert(n.Pace.Rate() == nil and n.Pace.NextLevel() == nil and n.Pace.Fraction() == nil)
    local t = n.Pace.Text()
    assert(t:find("… XP/h", 1, true) and t:find("niveau suivant …", 1, true), t)
    SlashCmdList.PRETRECOACH("bilan")
    assert(printed():find("XP gagnée inconnu", 1, true) and printed():find("inconnu", 1, true), printed())
    assert(n.UI.ProgressBar.value == 11, "niveau seul")
    assert(not findSecret(n.db, "db"), "rien de secret dans la base")
  end)

  check("Barre vers le 60 : remplissage, reperes allumes, option masquer, /coach progress", function()
    local n = pboot(10, 500, 1000)
    local B = n.UI.ProgressBar
    assert(B.value == (UnitXP and 10.5 or 10), tostring(B.value))
    local lit = {}
    for i, m in ipairs(B.markers) do lit[i] = m.lit end
    assert(#lit == 5 and lit[1] and lit[2] and not lit[3] and not lit[4] and not lit[5], "reperes 5 et 10 allumes")
    assert(B.frame.shown, "affichee par defaut")
    local pulsed
    B.markers[3].Pulse = function() pulsed = true end
    levelUp(100, 24, 0, 5000)
    assert(B.markers[3].lit and not B.markers[4].lit and pulsed, "repere 24 s'allume avec une animation")
    n.db.show.progress = false
    B.Render()
    assert(not B.frame.shown, "option masquer")
    SlashCmdList.PRETRECOACH("progress")
    assert(n.db.show.progress == true and B.frame.shown, "la commande reaffiche")
    local before = #mock.printed
    SlashCmdList.PRETRECOACH("bilan")
    assert(#mock.printed > before and printed():find("Bilan : session", 1, true))
  end)

  -- Consommables : { id, sous-classe, nom, niveau d'objet, niveau requis } ; toutes de classe 0 (consommable)
  local CONS_ITEMS = {
    { 4540, 5, "Pain tendre", 5, 1 }, { 4541, 5, "Pain de seigle", 15, 15 }, { 4601, 5, "Pain blanc", 15, 15 },
    { 4599, 5, "Pain de maïs", 25, 25 }, { 159, 5, "Eau fraîche", 5, 1 }, { 1179, 5, "Eau pure", 15, 10 },
    { 118, 1, "Potion de soins mineure", 5, 1 }, { 858, 1, "Potion de soins inférieure", 10, 3 },
    { 2455, 1, "Potion de mana mineure", 5, 5 }, { 500, 1, "Potion de vitesse", 30, 1 },
    { 1251, 7, "Bandage en lin", 1, 1 }, { 2589, 0, "Tissu de lin", 1, 1 },
  }
  -- sacs : { [emplacement] = { id, pile } }
  local function cbag(slots)
    mock.bagInfo = {}
    for slot, s in pairs(slots) do mock.bagInfo[slot] = { itemID = s[1], stackCount = s[2], iconFileID = 9000 + s[1] } end
  end
  local FULL_BAG = { { 4540, 20 }, { 4541, 18 }, { 4601, 5 }, { 4599, 3 }, { 159, 10 }, { 1179, 3 }, { 118, 2 }, { 858, 1 },
    { 2455, 2 }, { 500, 4 }, { 1251, 7 }, { 2589, 40 } }
  local function cboot(level, slots)
    mock.reset()
    mock.level, mock.itemClass, mock.itemSub, mock.itemInfo = level, {}, {}, {}
    for _, it in ipairs(CONS_ITEMS) do
      mock.itemClass[it[1]], mock.itemSub[it[1]], mock.itemInfo[it[1]] = 0, it[2], { it[3], it[4], it[5], 7000 + it[1] }
    end
    cbag(slots or FULL_BAG)
    local n = loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    mock.fire("BAG_UPDATE_DELAYED")
    return n
  end
  local CAT = { food = 1, water = 2, heal = 3, mana = 4, bandage = 5 }

  check("Consommables : classement par categorie, rien d'autre (tissu, potion inconnue)", function()
    if not C_Container then return end
    local C = cboot(20).Cons
    assert(C.Best.food and C.Best.water and C.Best.heal and C.Best.mana and C.Best.bandage, "5 categories trouvees")
    assert(C.Best.food.id ~= 2589 and C.Best.heal.id ~= 500 and C.Best.mana.id ~= 500, "objets hors categorie ignores")
    assert(C.Best.bandage.id == 1251 and C.Best.mana.id == 2455 and C.Best.water.id == 1179, "eau separee de la nourriture")
  end)

  check("Consommables : meilleur choix selon le niveau (requis, niveau d'objet, plus petit tas)", function()
    if not C_Container then return end
    local n = cboot(20)
    assert(n.Cons.Best.food.id == 4601, "a niveau d'objet egal : le plus petit tas")
    assert(n.Cons.Best.heal.id == 858 and n.Cons.Best.water.id == 1179)
    n = cboot(5)
    assert(n.Cons.Best.food.id == 4540 and n.Cons.Best.water.id == 159 and n.Cons.Best.heal.id == 858, "requis > niveau : ecarte")
    n = cboot(2)
    assert(n.Cons.Best.heal.id == 118 and n.Cons.Best.mana == nil, "potion de mana niveau 5 ecartee a 2")
    mock.fire("PLAYER_LEVEL_UP", 15)
    assert(n.Cons.Best.food.id == 4601 and n.Cons.Best.mana.id == 2455, "rescan au niveau gagne")
    cbag({ { 4599, 3 } })
    mock.fire("PLAYER_LEVEL_UP", 24)
    assert(n.Cons.Best.food == nil)
    mock.fire("PLAYER_LEVEL_UP", 25)
    assert(n.Cons.Best.food.id == 4599)
  end)

  check("Consommables : compteurs par categorie (objets utilisables seulement)", function()
    if not C_Container then return end
    local C = cboot(20).Cons
    assert(C.Total.food == 43, tostring(C.Total.food)) -- 20 + 18 + 5 ; les 3 pains de mais (niveau 25) ne comptent pas
    assert(C.Total.water == 13 and C.Total.heal == 3 and C.Total.mana == 2 and C.Total.bandage == 7)
    local C5 = cboot(5).Cons
    assert(C5.Total.food == 20 and C5.Total.water == 10, "niveau 5 : seul le pain tendre est utilisable")
  end)

  check("Barre consommables : attributs poses hors combat, icone, compteur, grise a 0", function()
    if not C_Container then return end
    local n = cboot(20)
    local B = n.UI.ConsumablesBar
    assert(#B.buttons == 5 and B.frame.shown, "5 boutons, barre affichee par defaut")
    local food, bandage = B.buttons[CAT.food], B.buttons[CAT.bandage]
    assert(food.attrs.type1 == "item" and food.attrs.item1 == "item:4601", "attributs de la nourriture")
    assert(B.buttons[CAT.water].attrs.item1 == "item:1179" and B.buttons[CAT.mana].attrs.item1 == "item:2455")
    assert(food.count.text == "43" and food.icon.tex == 9000 + 4601, "icone et compteur")
    assert(not food.icon.desat and not bandage.icon.desat)
    cbag({ { 4540, 20 } })
    mock.fire("BAG_UPDATE_DELAYED")
    assert(bandage.count.text == "" and bandage.icon.desat == true, "grise a 0")
    assert(bandage.attrs.item1 == nil and food.attrs.item1 == "item:4540", "attributs suivent les sacs hors combat")
  end)

  check("Barre consommables : en combat attributs en attente, appliques a la fin du combat", function()
    if not C_Container then return end
    local n = cboot(20)
    local food = n.UI.ConsumablesBar.buttons[CAT.food]
    assert(food.attrs.item1 == "item:4601")
    mock.setCombat(true)
    cbag({ { 4540, 20 }, { 4541, 18 } }) -- le pain blanc a ete mange
    mock.fire("BAG_UPDATE_DELAYED")
    assert(food.attrs.item1 == "item:4601", "attribut inchange en combat")
    assert(food.count.text == "38", "le compteur, lui, suit : " .. tostring(food.count.text))
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(food.attrs.item1 == "item:4541", "applique a la fin du combat")
  end)

  check("Barre consommables : option masquer, /coach conso, rien de secret dans la base", function()
    if not C_Container then return end
    local n = cboot(20)
    local B = n.UI.ConsumablesBar
    assert(n.db.show.cons == true and B.frame.shown)
    n.db.show.cons = false
    B.Render()
    assert(not B.frame.shown, "option masquer")
    mock.fire("BAG_UPDATE_DELAYED")
    assert(not B.frame.shown, "un rescan ne la reaffiche pas")
    SlashCmdList.PRETRECOACH("conso")
    assert(n.db.show.cons == true and B.frame.shown, "la commande reaffiche")
    SlashCmdList.PRETRECOACH("conso")
    assert(n.db.show.cons == false and not B.frame.shown, "et la masque")
    assert(not findSecret(n.db, "db"))
  end)

  check("Guide : Goals, un objectif XP puis un par metier actif", function()
    local n = fresh().n
    setState(n, { level = 12, profs = { [182] = { rank = 60, max = 75 }, [171] = { rank = 10, max = 75 } } })
    local goals = n.Guide.Goals()
    assert(#goals == 4 and goals[1].kind == "xp" and goals[2].line == 182 and goals[3].line == 171 and goals[4].kind == "gold", "XP, Herboristerie, Alchimie, Or")
    assert(not (goals[1].e and goals[1].e.prof), "XP : jamais un objectif de metier")
    for i = 2, 3 do assert(goals[i].kind == "prof" and goals[i].e and goals[i].e.prof == goals[i].line, "objectif du metier") end
    assert(goals[2].label == "Herboristerie" and goals[3].label == "Alchimie")
    for _, g in ipairs(goals) do assert(g.line ~= 129, "pas de Secourisme : metier non appris") end
    n.State.profs[129] = { rank = 1, max = 75 }
    goals = n.Guide.Goals()
    assert(#goals == 5 and goals[4].line == 129 and goals[5].kind == "gold", "Secourisme appris : apres les metiers, Or en dernier")
    n.State.profs = nil
    assert(#n.Guide.Goals() == 2, "metiers illisibles : XP et Or seuls")
  end)

  check("Guide : Goals, repli XP et repli metier (rang chez le maitre, Prof.Text)", function()
    local n = fresh().n
    setState(n, { level = 9, profs = { [182] = { rank = 60, max = 75 }, [171] = { rank = 10, max = 75 } } })
    n.Guide.Evaluate = function() return {} end -- tout est fait -- niveau 9 : Compagnon pas encore disponible
    local goals = n.Guide.Goals()
    assert(goals[1].e == nil and (goals[1].text:find("Monte de niveau", 1, true) or goals[1].text:find("Continue", 1, true)), goals[1].text)
    assert(goals[2].e == nil and goals[2].text:find("Cueille", 1, true), "plan de montee : " .. goals[2].text)
    n.State.level = 12
    n.State.profs[182].rank = 72
    assert(n.Guide.Goals()[2].text:find("rang Compagnon", 1, true), "rang a prendre chez le maitre : " .. n.Guide.Goals()[2].text)
    assert(goals[3].text == n.Prof.StepsText(171) and goals[3].text:find("Réunis", 1, true), "plan alchimie : " .. goals[3].text)
    n.State.profs[182].rank = 10
    assert(n.Guide.Goals()[2].text:find("Cueille", 1, true), "herboristerie : cueillette")
  end)

  check("GuideWindow : carte et onglet Maintenant = les entrees de Goals", function()
    local n, G = gw()
    n.State.profs = { [182] = { rank = 10, max = 75 }, [171] = { rank = 10, max = 75 } }
    local goals = n.Guide.Goals()
    n.SetCompact(true)
    local rows = G.card.rows
    assert(G.card.used == #goals, "une rangee par categorie")
    local want = { "Expérience", "Herboristerie", "Alchimie", "Or" }
    for i, g in ipairs(goals) do
      assert(rows[i].shown and rows[i].label.text == want[i], "libelle " .. i)
      assert(rows[i].text.text:find(g.text, 1, true) and not rows[i].text.text:find("^" .. want[i]), "texte sans prefixe " .. i)
      assert(rows[i].go.shown ~= true or i == 1, "Repere seulement sur XP")
    end
    assert(rows[2].icon.tex == "tex2366", "icone du metier via C_Spell.GetSpellTexture")
    assert(G.card.height and G.card.height > 0, "hauteur de la carte calculee")
    n.State.profs = { [182] = { rank = 10, max = 75 } } -- moins d'entrees : pas de rangee en trop
    n.Fire("GUIDE")
    assert(G.card.used == 3 and rows[3].shown and not rows[4].shown, "rangee en trop masquee")
    n.State.profs = { [182] = { rank = 10, max = 75 }, [171] = { rank = 10, max = 75 } }
    n.Fire("GUIDE")
    local pool = #rows
    n.Fire("GUIDE")
    assert(#rows == pool and rows[3].shown, "pool reutilise")
    n.SetCompact(false)
    n.ToggleGuide()
    G.win.tabs[1].scripts.OnClick(G.win.tabs[1])
    local open = 0
    for _, e in ipairs(n.Guide.Evaluate()) do if not e.done then open = open + 1 end end
    assert(G.used == #goals and G.used < open, "Maintenant : seulement les entrees de Goals")
  end)

  check("Barre de mana : valeur secrete telle quelle, decompte des 5 s, option, /coach mana", function()
    mock.reset()
    local n = loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    local M = n.UI.ManaBar
    assert(M.frame.shown and M.frame.mana.value ~= nil, "affichee, mana donne au StatusBar")
    if not mock.noSecrets then
      assert(mock.isSecret(M.frame.mana.value), "valeur secrete passee telle quelle")
    end
    mock.vitalsReadable = true
    mock.fire("UNIT_POWER_UPDATE", "player")
    assert(M.frame.mana.value == 100, "UNIT_POWER_UPDATE relit le mana")
    mock.mana = 40
    mock.fire("UNIT_MAXPOWER", "player")
    assert(M.frame.mana.value == 40, "UNIT_MAXPOWER relit le mana")
    local F = M.frame
    assert(not F.five.shown and F.text.text == "", "couche des 5 s cachee a 0")
    mock.time = 100
    mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", 585)
    assert(F.five.shown and F.five.width == 1 and F.text.text == "5,0 s" and F.mana.scripts.OnUpdate, "decompte demarre")
    mock.time = 102
    F.mana.scripts.OnUpdate(F.mana, 0.1)
    assert(F.five.shown and F.five.width == 96 and F.text.text == "3,0 s", "suit FiveSecRemaining")
    mock.time = 106
    F.mana.scripts.OnUpdate(F.mana, 0.1)
    assert(not F.five.shown and F.text.text == "" and F.mana.scripts.OnUpdate == nil, "fin : couche cachee, OnUpdate retire")
    n.db.show.mana = false
    M.Render()
    assert(not M.frame.shown, "option masquer")
    SlashCmdList.PRETRECOACH("mana")
    assert(n.db.show.mana == true and M.frame.shown, "/coach mana reaffiche")
    SlashCmdList.PRETRECOACH("mana")
    assert(not M.frame.shown, "/coach mana masque")
  end)

  local function rowTexts(rows) local t = {} for _, r in ipairs(rows) do t[#t + 1] = r.text end return table.concat(t, "\n") end

  check("Talents : toast precis (arbre, rangee, progression, points non depenses)", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 11, unspentTalents = 0, talents = tl{ [15270] = 2 } })
    n.Fire("STATE", { "level" })
    setState(n, { level = 12, unspentTalents = 2, talents = tl{ [15270] = 2 } })
    n.Fire("STATE", { "level", "unspentTalents" })
    local t = pcToasts(o, "^pc:talent:")
    assert(#t == 1 and t[1].text == "Point de talent : Ombre, rangée 1 : Connexion spirituelle (2/5 → 3/5)\nPoints non dépensés : 2", t[1] and t[1].text)
  end)

  check("Talents : illisibles, ni progression ni points inventes", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 11 })
    n.Fire("STATE", { "level" })
    setState(n, { level = 12 })
    n.Fire("STATE", { "level" })
    local t = pcToasts(o, "^pc:talent:")
    assert(#t == 1 and t[1].text == "Point de talent : Ombre, rangée 1 : Connexion spirituelle (objectif 5/5)", t[1] and t[1].text)
    assert(not t[1].text:find("→", 1, true) and not t[1].text:find("dépensés", 1, true))
  end)

  check("Talents : respec 40, etape claire puis Forme d'Ombre", function()
    local o = fresh()
    local n = o.n
    setState(n, { level = 39, unspentTalents = 0, talents = tl{} })
    n.Fire("STATE", { "level" })
    setState(n, { level = 40, unspentTalents = 0, talents = tl{ [15473] = 0 } })
    n.Fire("STATE", { "level" })
    local t = pcToasts(o, "^pc:respec")
    assert(#t == 1 and t[1].text == "Va voir le maître : réinitialise tes talents, puis 31 points en Ombre", t[1] and t[1].text)
    local r = n.Guide.Reference("talents")
    assert(r[1].text == t[1].text and r[1].highlight, "respec en tete de l'onglet")
    assert(r[2].text:find("Ombre, rangée 7 : Forme d'Ombre (0/1 → 1/1)", 1, true), r[2].text)
    n.State.talents = tl{ [15473] = 1 }
    assert(not rowTexts(n.Guide.Reference("talents")):find("réinitialise", 1, true), "Forme d'Ombre prise : plus de respec")
  end)

  check("Talents : onglet, a prendre d'abord, fini masque, futur masque sauf Ensuite", function()
    local n = fresh().n
    setState(n, { level = 19, unspentTalents = 1, talents = tl{ [18551] = 5, [14520] = 1, [14531] = 2, [14521] = 3 } })
    local r = n.Guide.Reference("talents")
    local all = rowTexts(r)
    assert(r[1].text == "Points non dépensés : 1" and not r[1].highlight, r[1].text)
    assert(r[2].highlight and r[2].text == "Discipline, rangée 3 : Agilité mentale (1/3 → 2/3)", r[2].text)
    for _, gone in ipairs{ "Force mentale", "Martyre", "Méditation", "Connexion spirituelle", "Spécialisation Baguette", "Mot de l'ombre" } do
      assert(not all:find(gone, 1, true), gone .. " masque : " .. all)
    end
    assert(r[#r].text == "Ensuite : Forme d'Ombre (Ombre) au niveau 40", r[#r].text)
    n.State.talents = tl{ [18551] = 1 }
    r = n.Guide.Reference("talents")
    assert(r[2].highlight and r[2].text:find("Force mentale (1/5 → 2/5)", 1, true) and r[3].text:find("Agilité mentale", 1, true) and not r[3].highlight)
  end)

  check("Sorts : seulement ce qui est a apprendre, cout, prochains sorts, message vide", function()
    if not hasKnows then return end
    local o = fresh()
    local n = o.n
    local function costAll(level)
      n.db.trainer = {}
      local total = 0
      for _, p in ipairs(n.Calc.PendingSpells(level, n.State.Knows)) do
        for _, sp in ipairs(n.Data.Spells) do
          if sp.key == p.key then
            local c = 100 * p.rankIndex + 50
            total = total + c
            n.db.trainer["Sort" .. sp.ranks[p.rankIndex].id .. "|" .. (p.rankIndex > 1 and "Rang " .. p.rankIndex or "")] = { cost = c, category = "available" }
          end
        end
      end
      return total
    end
    knows(knownUpTo(n, 5))
    setState(n, { level = 10 })
    local pend = n.Calc.PendingSpells(10, n.State.Knows)
    local r = n.Guide.Reference("spells")
    assert(#r == #pend + 2 and #r < #n.Data.Spells, "a apprendre + argent + une ligne prochains : " .. #r)
    assert(r[#pend + 1].text:find("coût inconnu", 1, true), "ligne argent : " .. r[#pend + 1].text)
    for i = 1, #pend do assert(r[i].highlight and not r[i].sub, "cout inconnu : pas de montant") end
    assert(r[#r].text:find("^Prochains sorts : niveau %d+ : ") and not rowTexts(r):find("Coût total", 1, true))
    n.db.trainer = { ["Sort591|Rang 2"] = { cost = 1200, category = "available" } }
    r = n.Guide.Reference("spells")
    local with
    for _, row in ipairs(r) do if row.text == "Sort591 (rang 2)" then with = row end end
    assert(with and with.sub == n.Training.Coin(1200), "cout connu sur la ligne")
    assert(not rowTexts(r):find("Coût total", 1, true), "total seulement si tous connus")
    local total = costAll(10)
    r = n.Guide.Reference("spells")
    assert(r[#pend + 1].text == "Coût total : " .. n.Training.Coin(total) and r[#pend + 2].text:find("Il te manque", 1, true) and r[#r].text:find("^Prochains sorts"), rowTexts(r))
    -- toast de montee de niveau : nombre et cout total
    local o2 = fresh()
    local n2 = o2.n
    knows(knownUpTo(n2, 5))
    setState(n2, { level = 9 })
    n2.Fire("STATE", { "level" })
    n = n2
    local total2 = costAll(10)
    n2.State.level = 10
    n2.Fire("STATE", { "level" })
    local t = pcToasts(o2, "^pc:train:")
    assert(#t == 1 and t[1].text:find("(" .. #pend .. ")", 1, true) and t[1].text:find("Coût total : " .. n2.Training.Coin(total2), 1, true), t[1] and t[1].text)
    -- rien a apprendre
    knows(knownUpTo(n2, 10))
    setState(n2, { level = 10 })
    r = n2.Guide.Reference("spells")
    assert(#r == 1 and r[1].text:find("^Rien à apprendre, prochain passage chez le maître au niveau %d+$"), r[1].text)
    knows(knownUpTo(n2, 60))
    setState(n2, { level = 60 })
    r = n2.Guide.Reference("spells")
    assert(#r == 1 and r[1].text == "Rien à apprendre", r[1].text)
    knows(nil)
  end)

  ------------------------------------------------------------------------
  -- Objectif XP precis : texte et detail calcules en direct (Guide.Goals()[1])
  ------------------------------------------------------------------------
  -- Goals() avec l'entree `id` comme objectif XP (l'ordre des donnees ne compte pas ici).
  local function xpFor(n, id)
    local e = ev(n, id)
    assert(e, "entree absente : " .. id)
    local text, detail = n.Guide.Detail(e)
    return { text = text, detail = detail }
  end

  check("Guide XP : sorts a apprendre, avec et sans cout", function()
    local n = fresh().n
    if not hasKnows then return end
    knows(knownUpTo(n, 5))
    setState(n, { level = 10 })
    n.db.trainer = {}
    local g = xpFor(n, "spells")
    local pend = n.Calc.PendingSpells(10, n.State.Knows)
    assert(g.text:find("^Apprends " .. #pend .. " sorts chez ton maître %(") and not g.text:match("^[^\n]*"):find(" : ", 1, true), g.text)
    assert(g.text:find(n.L.TRAIN_MONEY_UNKNOWN:sub(1, 6), 1, true), "argent sans cout connu : " .. g.text)
    local total = 0
    for i, p in ipairs(pend) do
      for _, sp in ipairs(n.Data.Spells) do
        if sp.key == p.key then
          total = total + 100 * i
          n.db.trainer["Sort" .. sp.ranks[p.rankIndex].id .. "|" .. (p.rankIndex > 1 and "Rang " .. p.rankIndex or "")] = { cost = 100 * i, category = "available" }
        end
      end
    end
    g = xpFor(n, "spells")
    local tail = " : " .. n.Training.Coin(total)
    assert(g.text:match("^[^\n]*"):sub(-#tail) == tail, g.text)
    mock.money = total + 5
    assert(xpFor(n, "spells").text:find("Tu as assez", 1, true), "assez d'argent")
    mock.money = total - 50
    g = xpFor(n, "spells")
    assert(g.text:find("Il te manque " .. n.Training.Coin(50), 1, true), "il manque : " .. g.text)
    mock.moneySecret = true
    assert(not xpFor(n, "spells").text:find("\n", 1, true), "argent illisible : pas de ligne")
    mock.moneySecret, mock.money = nil, nil
    knows(nil)
  end)

  check("Guide XP : talent = Talents.Describe, bandages lisibles ou non, sort a apprendre", function()
    local n = fresh().n
    setState(n, { level = 10 })
    local g = xpFor(n, "wandspec")
    local want
    for _, it in ipairs(n.Talents.Todo(10)) do if it.entry.key == "WANDSPEC" then want = n.Talents.Describe(it) end end
    assert(want and g.text == want, g.text)
    -- bandages : compte lu, puis API illisible
    setState(n, { level = 12 })
    mock.items = { [1251] = 3, [2581] = 1 }
    g = xpFor(n, "bandages")
    assert(not GetItemCount or g.text == "Bandages : 4/10 sur toi : fabrique-en 6 (Secourisme)", g.text)
    local fn, ci = GetItemCount, C_Item
    GetItemCount, C_Item = nil, nil
    g = xpFor(n, "bandages")
    GetItemCount, C_Item = fn, ci
    mock.items = nil
    assert(g.text == "Bandages : aie-en 10 sur toi (Secourisme)" and not g.text:find("0/10", 1, true), g.text)
    -- sort connu chez le maitre : niveau, puis cout
    setState(n, { level = 20 })
    n.db.trainer = {}
    g = xpFor(n, "fearward")
    assert(g.text:find("^Apprends .+ chez ton maître %(niveau %d+%)$"), g.text)
    local name
    for _, sp in ipairs(n.Data.Spells) do if sp.key == "FEARWARD" then name = sp.name end end
    n.db.trainer[name .. "|"] = { cost = 12000, category = "available" }
    g = xpFor(n, "fearward")
    local tail12 = " : " .. n.Training.Coin(12000)
    assert(g.text:sub(-#tail12) == tail12, g.text)
  end)

  check("Guide XP : baguette (nom, source, prix HdV) et baguette superieure", function()
    local n = fresh().n
    setState(n, { level = 8, wand = false })
    mock.ah = { [11287] = { 5000, 1 } }
    local g = xpFor(n, "wand_equip")
    assert(n.Guide.Goals()[1].text == g.text and n.Guide.Goals()[1].detail == g.detail, "Goals() porte le meme texte et detail")
    assert(g.text == "Équipe Baguette magique inférieure (niveau 5)", g.text)
    assert(g.detail:find("Hôtel des ventes", 1, true), g.detail)
    assert(not Auctionator or g.detail:find("environ " .. n.Training.Coin(5000) .. " à l'hôtel des ventes", 1, true), g.detail)
    mock.ah = {}
    assert(not xpFor(n, "wand_equip").detail:find("environ", 1, true), "prix inconnu : omis")
    local ah = Auctionator
    Auctionator = nil
    g = xpFor(n, "wand_equip")
    Auctionator = ah
    assert(g.detail:find("Hôtel des ventes", 1, true) and not g.detail:find("environ", 1, true), "sans Auctionator : la source seule")
    setState(n, { level = 14, wand = { itemID = 11287, reqLevel = 5 } })
    g = xpFor(n, "wand_sup")
    assert(g.text == "Équipe Baguette magique supérieure (niveau 13)", g.text)
    mock.qinit()
  end)

  check("Guide XP : quete avec et sans Questie, pourquoi des objectifs manuels", function()
    local n = fresh().n
    setState(n, { level = 28 })
    local lib = LibQuestieDB
    if lib then
      mock.qquests = { [6561] = { name = "Quete", startedBy = { { 375 } }, requiredLevel = 21 } }
      mock.qnpcs[375][6] = "Maitre Test"
      local g = xpFor(n, "bfd_quest")
      assert(g.text:find("Blackfathom", 1, true), g.text)
      assert(g.detail == "niveau 21 requis · donneur : Maitre Test", g.detail)
    end
    -- Q.Available() garde sa reponse : un ns neuf sans la bibliotheque
    _G.LibQuestieDB = nil
    local n2 = fresh().n
    setState(n2, { level = 28 })
    local g = xpFor(n2, "bfd_quest")
    _G.LibQuestieDB = lib
    mock.qinit()
    assert(g.text:find("Blackfathom", 1, true) and g.detail == nil, "sans Questie : texte seul, rien d'invente")
    setState(n, { level = 45 })
    assert(xpFor(n, "dualspec").detail:find("Ombre", 1, true), "specGroups : pourquoi")
  end)

  check("Guide XP : repli de zone avec duree du prochain niveau", function()
    local n = fresh().n
    local zid
    for id, z in pairs(n.Data.Zones) do if z[2] < 30 then zid = id end end
    setState(n, { level = 30, zone = zid })
    n.Guide.Evaluate = function() return {} end
    n.Pace.NextLevel = function() return 270 end
    local g = n.Guide.Goals()[1]
    assert(g.e == nil and g.text:find("^Monte dans ") and g.detail:find("prochain niveau dans ~5 min", 1, true), g.text .. " / " .. tostring(g.detail))
    n.Pace.NextLevel = function() return nil end
    assert(n.Guide.Goals()[1].detail == nil or not n.Guide.Goals()[1].detail:find("prochain", 1, true), "duree inconnue : omise")
  end)

  check("GuideWindow : le detail s'affiche dans la carte (hauteur incluse) et dans Maintenant", function()
    local n, G = gw()
    setState(n, { level = 8, wand = false })
    local goal = n.Guide.Goals()[1]
    assert(goal.detail, "detail attendu")
    n.SetCompact(true)
    local r = G.card.rows[1]
    assert(r.detail.shown and r.detail.text == goal.detail, "detail sous le texte")
    local with = G.card.height
    local real = n.Guide.Goals
    n.Guide.Goals = function() local t = real() t[1].detail = nil return t end
    n.Fire("GUIDE")
    assert(not r.detail.shown and with > G.card.height, "hauteur : le detail compte")
    n.Guide.Goals = real
    n.SetCompact(false)
    n.db.guide.tab = "now"
    n.ToggleGuide()
    n.Fire("GUIDE")
    assert(G.rows[1].sub.text:find(goal.detail, 1, true), "Maintenant : detail " .. tostring(G.rows[1].sub.text))
  end)

  -- Plan de montee par metier (Prof.Steps) et crafts possibles avec les sacs (Prof.Craftable)
  local function planState(n, profs, level)
    setState(n, { level = level or 40, profs = profs })
    mock.items = nil
    n.Prof.Advice = {}
    n.db.prof = nil
  end
  local function todoText(s) local t = {} for i, a in ipairs(s.todo) do t[i] = a.text end return table.concat(t, "\n") end
  local function kinds(s) local t = {} for i, a in ipairs(s.todo) do t[i] = a.kind end return table.concat(t, ",") end
  local function gatherOf(n, line) for _, a in ipairs(n.Prof.Steps(line).todo) do if a.kind == "gather" then return a end end end

  check("Prof.Steps : etape choisie selon le rang, titre, maitre quand le plafond bloque", function()
    local n = fresh().n
    planState(n, { [171] = { rank = 52, max = 75 } }, 9) -- niveau 9 : Compagnon pas encore disponible
    local s = n.Prof.Steps(171)
    assert(s.title == "Alchimie 52/75 : fais Élixir de défense mineure", s.title)
    assert(not kinds(s):find("rank", 1, true), "plafond loin : pas de maitre")
    n.State.profs[171] = { rank = 3, max = 75 }
    assert(n.Prof.Steps(171).title:find("Élixir arcanique mineur", 1, true), "debut de tranche")
    n.State.level = 40
    n.State.profs[171] = { rank = 72, max = 75 }
    s = n.Prof.Steps(171)
    assert(s.todo[1].kind == "rank" and s.todo[1].text:find("Compagnon", 1, true) and s.todo[1].text:find("Docteur Marsh", 1, true) and s.todo[1].done == false, "maitre d'abord : " .. todoText(s))
    n.State.level = 5 -- niveau trop bas : le rang n'est pas disponible
    assert(n.Prof.Steps(171).todo[1].kind ~= "rank")
    n.State.profs[171] = { rank = 400, max = 300 } -- au-dela du plan : derniere etape
    assert(n.Prof.Steps(171).step.to == 300)
    n.State.profs = nil
    assert(n.Prof.Steps(171) == nil, "metiers illisibles")
    planState(n, { [171] = { rank = 52, max = 75 } })
    assert(n.Prof.Steps(999) == nil and n.Prof.Steps(182) == nil, "metier sans plan ou non appris")
  end)

  check("Prof.Steps : recette a acheter, connue ou non, ligne En direct", function()
    local n = fresh().n
    planState(n, { [171] = { rank = 200, max = 225 } }, 34)
    local s = n.Prof.Steps(171)
    assert(kinds(s):find("^buy"), kinds(s))
    assert(s.todo[1].text:find("Achète « Recette : Potion de protection contre la nature » chez Bronk", 1, true) and s.todo[1].done == nil, s.todo[1].text)
    n.Prof.Advice[171] = { list = { { name = "Potion de protection contre la nature", color = "yellow" } } }
    s = n.Prof.Steps(171)
    assert(s.todo[1].done == true and not kinds(s):find("live", 1, true), "connue : cochee, pas de doublon En direct")
    n.Prof.Advice[171] = { list = { { name = "Potion de mana", color = "orange" } } }
    s = n.Prof.Steps(171)
    assert(todoText(s):find("En direct : tu peux fabriquer Potion de mana (orange)", 1, true), todoText(s))
    assert(s.todo[1].done == nil and kinds(s):find("live$"), "recette non listee : inconnue, En direct en dernier")
    n.Prof.Advice[171] = { list = { { name = "Potion de mana", color = "green" } } }
    assert(not kinds(n.Prof.Steps(171)):find("live", 1, true), "verte : pas de conseil En direct")
  end)

  check("Prof.Steps : recettes a apprendre = ce que le maitre du metier affiche disponible", function()
    local n = fresh().n
    planState(n, { [171] = { rank = 52, max = 75 } }, 9)
    n.db.trainer = { ["Élixir de défense mineure|"] = { category = "available" } } -- sans metier (sort de classe ou ancien releve)
    assert(not n.Prof.Steps(171).learn, "pas de metier connu : rien")
    n.db.trainer = {
      ["Étude des toxines|"] = { category = "available", skill = "Alchimie" },
      ["Laboratoire|"] = { category = "unavailable", skill = "Alchimie" },
      ["Bandage|"] = { category = "available", skill = "Secourisme" },
    }
    local s = n.Prof.Steps(171)
    assert(s.learn and todoText(s):find("Apprends « Étude des toxines » chez le maître", 1, true), todoText(s))
    assert(not todoText(s):find("Laboratoire", 1, true) and not todoText(s):find("Bandage", 1, true))
    n.Prof.Advice[171] = { list = { { name = "Étude des toxines", color = "orange" } } }
    assert(not n.Prof.Steps(171).learn, "deja connue dans la fenetre")
  end)

  check("Prof.Steps : comptes de composants lisibles, absents, secrets", function()
    local n = fresh().n
    planState(n, { [171] = { rank = 10, max = 75 } })
    mock.items = { [765] = 10, [2447] = 3 }
    local g = gatherOf(n, 171)
    if not GetItemCount then
      assert(g.done == nil and not g.text:find("tu en as", 1, true) and g.text:find("45 Feuillargent", 1, true), "API absente : aucun compte invente")
      return
    end
    assert(g.text:find("45 Feuillargent (tu en as 10)", 1, true) and g.text:find("45 Fiole vide (tu en as 0)", 1, true) and g.done == false, g.text)
    assert(g.text:find("achète 45 Fiole vide chez un marchand de fournitures", 1, true), g.text)
    mock.items = { [765] = 10, [2447] = 3, [3371] = 40 }
    assert(gatherOf(n, 171).text:find("achète 5 Fiole vide", 1, true), "il en manque 5")
    mock.items = { [765] = 10, [2447] = 3, [3371] = 45 }
    assert(not gatherOf(n, 171).text:find("achète", 1, true), "assez de fioles : rien a acheter")
    assert(todoText(n.Prof.Steps(171)):find("Fabrique-en ~45 (Élixir de défense mineure) jusqu'à 55", 1, true), todoText(n.Prof.Steps(171)))
    mock.items = { [765] = 99, [2447] = 99, [3371] = 99 }
    assert(gatherOf(n, 171).done == true, "tout est la")
    mock.items = { [765] = mock.SECRET, [2447] = 99, [3371] = 99 }
    g = gatherOf(n, 171)
    assert(g.done == nil and g.text:find("45 Feuillargent", 1, true) and not g.text:find("45 Feuillargent (tu en as", 1, true), "secret : rien de coche, pas de faux compte : " .. g.text)
    local gi = GetItemCount
    GetItemCount = nil -- API absente
    g = gatherOf(n, 171)
    GetItemCount = gi
    assert(g.done == nil and not g.text:find("tu en as", 1, true), "API absente")
    mock.items = nil
  end)

  check("Prof.Steps : herboristerie avec zones (nom lu, repli sur l'ID), secourisme", function()
    local n = fresh().n
    planState(n, { [182] = { rank = 10, max = 75 } })
    mock.mapNames = { [1420] = "Clairières de Tirisfal", [1411] = "Durotar", [1412] = "Mulgore" }
    local s = n.Prof.Steps(182)
    assert(s.title == "Herboristerie 10/75 : cueille Pacifique, Feuillargent, Terrestrine", s.title)
    if not C_Map then
      assert(todoText(s):find("zone 1420 ou zone 1411 ou zone 1412", 1, true), "API absente : repli sur les ID")
      return
    end
    assert(todoText(s):find("Cueille Pacifique, Feuillargent, Terrestrine dans : Clairières de Tirisfal ou Durotar ou Mulgore", 1, true), todoText(s))
    mock.unknown.map = { [1420] = true }
    assert(todoText(n.Prof.Steps(182)):find("zone 1420 ou Durotar", 1, true), "carte inconnue : repli ID")
    mock.unknown.map = nil
    mock.mapNames = nil
    n.State.profs[182] = { rank = 80, max = 150 }
    assert(n.Prof.Steps(182).step.zones[1] == 1421, "tranche 70-115")
    planState(n, { [129] = { rank = 160, max = 225 } })
    s = n.Prof.Steps(129)
    assert(s.title:find("Bandage en soie", 1, true) and todoText(s):find("Manuel : Secourisme expert", 1, true), todoText(s))
    n.State.profs[129] = { rank = 224, max = 225 }
    assert(todoText(n.Prof.Steps(129)):find("Triage", 1, true), "quete Triage pour Artisan : " .. todoText(n.Prof.Steps(129)))
  end)

  check("Goals : texte d'un metier sur 2 lignes max ; Metiers = metiers actifs seulement", function()
    local n = fresh().n
    planState(n, { [182] = { rank = 10, max = 75 }, [171] = { rank = 72, max = 75 }, [129] = { rank = 224, max = 225 } })
    n.Guide.Evaluate = function() return {} end
    for _, g in ipairs(n.Guide.Goals()) do
      if g.kind == "prof" then
        local _, nl = g.text:gsub("\n", "")
        assert(nl <= 1 and not g.text:find("^" .. g.label), g.label .. " : " .. g.text)
      end
    end
    local g2 = n.Guide.Goals()[3]
    assert(g2.line == 171 and g2.text:find("72/75 : encore 3 points possibles, puis maître (Compagnon)\nVa voir le maître pour le rang Compagnon", 1, true), g2.text)
    local r = n.Guide.Reference("profs")
    assert(#r == 3 and r[1].text == "Secourisme" and r[2].text == "Alchimie" and r[3].text == "Herboristerie", "trois metiers actifs")
    assert(r[3].sub:find("^Herboristerie 10/75 : cueille") and r[3].sub:find("• Cueille", 1, true), r[3].sub)
    n.State.profs = { [171] = { rank = 40, max = 75 } }
    mock.items = { [765] = 99, [2447] = 99, [3371] = 99 }
    r = n.Guide.Reference("profs")
    local alch = r[#r]
    assert(alch.text == "Alchimie" and not r[2] or r[1].text == "Avec tes sacs", "section sacs eventuelle en tete")
    assert(alch.text == "Alchimie" and (not GetItemCount or alch.sub:find("|cff40ff40✓|r Réunis", 1, true)), "metiers non appris masques, coche verte")
    for _, row in ipairs(r) do assert(row.text ~= "Herboristerie" and row.text ~= "Secourisme", "metier non appris") end
    n.State.profs = nil
    mock.items = nil
    assert(#n.Guide.Reference("profs") == 3, "metiers illisibles : liste complete, sans checklist")
  end)

  check("Prof.Craftable : craft avec achat marchand, rien, secret, tri par montee de competence", function()
    local o = fresh()
    local n = o.n
    planState(n, { [171] = { rank = 10, max = 75 } })
    assert(#n.Prof.Craftable() == 0, "sacs vides : rien de possible")
    mock.items = { [765] = 4, [2447] = 6 }
    local list = n.Prof.Craftable()
    if not GetItemCount then assert(#list == 0, "comptes illisibles : rien d'affirme") return end
    assert(#list == 2 and list[1].recipe == "Élixir de défense mineure" and list[1].n == 4 and list[1].skillUp and list[1].confirm, "monte la competence d'abord")
    assert(list[2].recipe == "Élixir arcanique mineur" and list[2].n == 6 and not list[2].skillUp, "grise de tranche : apres")
    assert(#list[1].buy == 1 and list[1].buy[1].name == "Fiole vide" and list[1].buy[1].qty == 4 and list[1].buy[1].cost == nil, "fioles a acheter, prix inconnu : nil")
    local text = n.Prof.BagText(list[1])
    assert(text == "Tu peux faire 4 Élixir de défense mineure avec tes Feuillargent et Pacifique : achète 4 Fiole vide chez un marchand de fournitures (recette à confirmer)", text)
    local vial = n.Data.ProfPlan[171].steps[2].comps[3] -- Fiole vide (table partagee)
    vial.price = 4
    assert(n.Prof.Craftable()[1].buy[1].cost == 16 and n.Prof.BagText(n.Prof.Craftable()[1]):find("(≈ 16" .. MI.c .. ")", 1, true), "prix connu")
    vial.price = nil
    mock.items[3371] = 3
    assert(n.Prof.Craftable()[1].buy[1].qty == 1, "fioles deja portees deduites")
    mock.items[3371] = 9
    assert(#n.Prof.Craftable()[1].buy == 0, "rien a acheter")
    -- ligne de la carte et section de l'onglet
    mock.items = { [765] = 4, [2447] = 6 }
    n.Guide.Evaluate = function() return {} end
    assert(n.Guide.Goals()[2].text:find("\nTes sacs : 4× Élixir de défense mineure (achète 4 Fiole vide)", 1, true), n.Guide.Goals()[2].text)
    local r = n.Guide.Reference("profs")
    assert(r[1].text == "Avec tes sacs" and r[1].sub:find("• Tu peux faire 4 Élixir de défense mineure", 1, true), "section en tete de l'onglet")
    -- couleur lue en direct : verte = ne fait plus monter
    n.Prof.Advice[171] = { list = { { name = "Élixir de défense mineure", color = "green" } } }
    list = n.Prof.Craftable()
    assert(not list[1].skillUp and list[1].recipe == "Élixir arcanique mineur" and list[1].n == 6, "tri : le plus grand nombre si rien ne monte")
    assert(not n.Guide.Goals()[2].text:find("Tes sacs", 1, true), "pas de ligne sacs sans montee")
    n.Prof.Advice[171] = nil
    -- icones d'objet : presentes si lisibles, nom seul sinon
    mock.icons = { [765] = 135000, [3371] = 134000 }
    local ic = n.Prof.Craftable()[1]
    assert(n.Prof.BagText(ic):find("avec tes |T135000:14:14|t Feuillargent et Pacifique", 1, true) and n.Prof.BagText(ic):find("achète 4 |T134000:14:14|t Fiole vide", 1, true), n.Prof.BagText(ic))
    assert(todoText(n.Prof.Steps(171)):find("|T135000:14:14|t Feuillargent", 1, true), "icone dans les etapes")
    mock.icons = nil
    assert(not n.Prof.BagText(n.Prof.Craftable()[1]):find("|T", 1, true) and n.Prof.BagText(n.Prof.Craftable()[1]):find("tes Feuillargent et Pacifique", 1, true), "icone illisible : nom seul")
    -- secret : recette ignoree, jamais de faux compte
    mock.items = { [765] = mock.SECRET, [2447] = 6 }
    list = n.Prof.Craftable()
    assert(#list == 1 and list[1].recipe == "Élixir arcanique mineur", "composant secret : recette ignoree")
    mock.items = { [765] = mock.SECRET, [2447] = mock.SECRET }
    assert(#n.Prof.Craftable() == 0, "tout secret : rien")
    -- combat : dernier resultat conserve, pas de relecture ; rescan hors combat
    mock.items = { [765] = 4, [2447] = 6 }
    mock.fire("BAG_UPDATE_DELAYED")
    mock.items = nil
    mock.setCombat(true)
    mock.fire("BAG_UPDATE_DELAYED")
    assert(#n.Prof.Craftable() == 2, "combat : resultat memorise")
    mock.setCombat(false)
    assert(#n.Prof.Craftable() == 0, "hors combat : relu")
  end)

  -- Icone Craft dans la carte du guide : bouton securise qui lance le sort du metier ; l'addon presélectionne la recette, jamais de fabrication
  local function craftBoot(items, withID)
    mock.reset()
    mock.selected, mock.crafted = nil, nil
    local n = loadAddon()
    mock.fire("ADDON_LOADED", ADDON)
    local toasts = {}
    n.Toast = function(text) toasts[#toasts + 1] = text return true end
    setState(n, { level = 40, profs = { [171] = { rank = 10, max = 75 }, [182] = { rank = 10, max = 75 } } })
    n.Prof.Advice = withID and { [171] = { list = { { recipeID = 555, name = "Élixir de défense mineure", color = "orange" } } } } or {}
    n.db.prof = nil
    mock.items = items == nil and { [765] = 4, [2447] = 6 } or items
    n.SetCompact(true)
    mock.fire("BAG_UPDATE_DELAYED")
    return n, toasts
  end

  check("Craft : icone sur la rangee Alchimie avec skill-up, grisee sinon, absente pour Herboristerie", function()
    if not GetItemCount then return end
    local n = craftBoot({}, true)
    local P, card = n.UI.CraftPopup, n.UI.GuideWin.card
    assert(card.profAnchor[171] and card.profAnchor[182], "ancres des rangees metier")
    local b = P.btns[171]
    assert(b and b.shown and b.icon.desat == true and b.icon.alpha == 0.4, "sans skill-up : visible mais grisee")
    assert(b.template == "SecureActionButtonTemplate" and b.attrs.type1 == "spell" and b.attrs.spell1 == "Sort2259", "attributs du sort du metier")
    assert(b.pt[2] == card.profAnchor[171] and b.pt[1] == "TOPRIGHT", "ancree a droite de la rangee")
    assert(P.btns[182] == nil, "rien pour Herboristerie")
    local tip = P.TipLines(b)
    assert(tip[1]:find("Alchimie", 1, true) and tip[#tip] == "Clic : ouvre Alchimie", table.concat(tip, "|"))
    mock.items = { [765] = 4, [2447] = 6 }
    mock.fire("BAG_UPDATE_DELAYED")
    assert(b.shown and b.icon.desat == false and b.icon.alpha == 1, "skill-up : pleine couleur")
    tip = P.TipLines(b)
    assert(tip[1] == "4× Élixir de défense mineure (+compétence)", tostring(tip[1]))
    assert(tip[2]:find("achète 4 Fiole vide", 1, true) and tip[3] == "Clic : ouvre Alchimie sur la recette", table.concat(tip, "|"))
    assert(mock.secureInCombat == 0 and mock.moveInCombat == 0)
    -- carte fermee : bouton cache
    card:Hide()
    assert(not b.shown, "carte cachee : bouton cache")
    card:Show()
    assert(b.shown, "carte reaffichee")
  end)

  check("Craft : en combat rien posé ni déplacé, appliqué à la fin du combat", function()
    if not GetItemCount then return end
    local n = craftBoot({}, true)
    local P, card = n.UI.CraftPopup, n.UI.GuideWin.card
    local b = P.btns[171]
    card:Hide()
    b.attrs, b.applied = {}, nil
    mock.setCombat(true)
    mock.items = { [765] = 4, [2447] = 6 }
    mock.fire("BAG_UPDATE_DELAYED")
    card:Show()
    assert(not b.attrs.spell1 and not b.shown and mock.attrInCombat == 0 and mock.moveInCombat == 0 and mock.secureInCombat == 0, "rien en combat")
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(b.shown and b.attrs.spell1 == "Sort2259" and b.icon.desat == false and mock.attrInCombat == 0, "applique a la fin du combat")
    assert(mock.moveInCombat == 0)
  end)

  check("Craft : le clic memorise la recette, presélection a TRADE_SKILL_SHOW, aucune fabrication", function()
    if not GetItemCount then return end
    local n, toasts = craftBoot(nil, true)
    local b = n.UI.CraftPopup.btns[171]
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected == nil, "sans clic : pas de presélection")
    b.hooks.PreClick(b)
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected and mock.selected[1] == 555 and #mock.selected == 1, "recipeID d'Advice presélectionné")
    mock.fire("TRADE_SKILL_LIST_UPDATE")
    assert(#mock.selected == 1, "une seule presélection par clic")
    assert(mock.crafted == nil and #toasts == 0, "aucune fabrication")
    -- recette introuvable : rien presélectionné, toast discret apres 1 s
    n, toasts = craftBoot(nil, false)
    b = n.UI.CraftPopup.btns[171]
    b.hooks.PreClick(b)
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected == nil and #toasts == 0, "trop tot : on reessaie")
    mock.time = 1.1
    mock.flushTimers()
    assert(mock.selected == nil and mock.crafted == nil, "recette inconnue : rien presélectionné")
    assert(toasts[1] == "Cherche Élixir de défense mineure dans la liste", tostring(toasts[1]))
  end)

  -- Presélection en direct (recette trouvee par nom dans la fenetre ouverte, selection robuste, reessais)
  local function liveBoot(rec)
    local n, toasts = craftBoot(nil, false)
    mock.time = 0
    mock.recipes = 3
    mock.recipeInfo = { [102] = { name = "Élixir DE défense  mineure" }, [103] = rec }
    local b = n.UI.CraftPopup.btns[171]
    b.hooks.PreClick(b)
    return n, toasts, b
  end

  check("Craft : recipeID trouve en direct par nom (casse/espaces), OpenRecipe, une seule fois, rien fabrique", function()
    if not GetItemCount then return end
    local n, toasts = liveBoot({ name = "Autre" })
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected and #mock.selected == 1 and mock.selected[1] == 102, "ID 102 par nom")
    assert(n.UI.CraftPopup.last.method == "a" and n.UI.CraftPopup.last.recipeID == 102, "sonde : methode a")
    mock.fire("TRADE_SKILL_LIST_UPDATE") mock.flushTimers()
    assert(#mock.selected == 1 and mock.crafted == nil and not tostring(toasts[1]):find("non apprise", 1, true) and not tostring(toasts[1]):find("Cherche", 1, true), tostring(toasts[1]))
    -- repli « contient » seulement si pas d'egalite
    n, toasts = liveBoot({ name = "Élixir de défense mineure supérieur" })
    mock.recipeInfo[102] = { name = "Rien" }
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected[1] == 103, "contient")
  end)

  check("Craft : repli sur RecipeList:SelectRecipe quand OpenRecipe est absent", function()
    if not GetItemCount then return end
    local n = liveBoot({ name = "Autre" })
    local open, got = C_TradeSkillUI.OpenRecipe, nil
    C_TradeSkillUI.OpenRecipe = nil
    ProfessionsFrame = { CraftingPage = { RecipeList = { SelectRecipe = function(self, info, flag) got = { info.recipeID, flag } end } } }
    mock.fire("TRADE_SKILL_SHOW")
    C_TradeSkillUI.OpenRecipe, ProfessionsFrame = open, nil
    assert(got and got[1] == 102 and got[2] == true, "SelectRecipe(info, true)")
    assert(n.UI.CraftPopup.last.method == "b" and mock.crafted == nil)
  end)

  check("Craft : reessais par minuterie jusqu'a ce que la liste soit prete", function()
    if not GetItemCount then return end
    local n = liveBoot({ name = "Autre" })
    mock.tsNotReady = true
    mock.fire("TRADE_SKILL_SHOW")
    assert(mock.selected == nil and #mock.timers >= 3, "pas prete : minuteries en attente")
    local pending = mock.timers
    mock.time = 0.3 mock.flushTimers()
    assert(mock.selected == nil, "toujours pas prete")
    mock.tsNotReady = nil
    mock.timers = pending -- les minuteries restantes (0,5 s, ...) se redeclenchent
    mock.time = 0.6 mock.flushTimers()
    assert(mock.selected and #mock.selected == 1 and mock.selected[1] == 102, "prete : presélectionnée")
    mock.time = 1.5 mock.flushTimers()
    assert(#mock.selected == 1 and mock.crafted == nil, "pas de seconde presélection")
  end)

  check("Craft : recette non apprise : toast avec le vendeur du plan, sinon toast actuel", function()
    if not GetItemCount then return end
    local n, toasts, b = liveBoot({ name = "Autre" })
    mock.recipeInfo[102] = { name = "Potion de mana supérieure", learned = false }
    b.entry = { recipe = "Potion de mana supérieure" }
    b.hooks.PreClick(b)
    mock.time = 1.1 mock.flushTimers()
    assert(mock.selected == nil and mock.crafted == nil, "rien presélectionné")
    assert(toasts[1] == "Recette Potion de mana supérieure non apprise : achète-la chez Algernon (Fossoyeuse)", tostring(toasts[1]))
    assert(n.UI.CraftPopup.last.method == "aucune")
  end)

  check("Craft : option masquer et /coach craft", function()
    if not GetItemCount then return end
    local n = craftBoot(nil, true)
    local P = n.UI.CraftPopup
    local b = P.btns[171]
    assert(n.db.show.craft == true and b.shown)
    SlashCmdList.PRETRECOACH("craft")
    assert(n.db.show.craft == false and not b.shown, "commande : masque")
    mock.fire("BAG_UPDATE_DELAYED")
    assert(not b.shown, "un rescan ne la reaffiche pas")
    SlashCmdList.PRETRECOACH("craft")
    assert(n.db.show.craft == true and b.shown, "commande : reaffiche")
    assert(not findSecret(n.db, "db"))
  end)

  -- Rang de metier a prendre : rangee marquee, maitre le plus proche, ramassage masque
  local MASTER = { text = "Maître d'herboristerie, Fossoyeuse (35.0, 50.0)", where = "x", mapID = 1458, x = 35, y = 50 }
  local function rankBoot(rank, level, dest)
    local n, G = gw()
    planState(n, { [182] = { rank = rank, max = 75 } }, level)
    n.Guide.Evaluate = function() return {} end
    n.Goto.For = function(k) if k == "HERBALISM" then return dest end end
    return n, G
  end

  check("Rang bloquant : plafond atteint, titre marque, maitre avec lieu, ramassage masque", function()
    local n = rankBoot(75, 20, MASTER)
    local s = n.Prof.Steps(182)
    assert(s.alert and s.go == "HERBALISM" and s.title == "Herboristerie 75/75 : va prendre Compagnon", s.title)
    assert(s.todo[1].kind == "rank" and s.todo[1].text == "Va voir le maître pour le rang Compagnon : " .. MASTER.text, s.todo[1].text)
    for i = 2, #s.todo do assert(s.todo[i].held, "action grisee : " .. s.todo[i].kind) end
    local g = n.Guide.Goals()[2]
    assert(g.alert and g.go == "HERBALISM" and g.text == "75/75 : va prendre Compagnon\n" .. s.todo[1].text, g.text)
    assert(not g.text:find("Cueille", 1, true), "aucun ramassage dans la carte")
    local sub = n.Guide.Reference("profs")[1].sub
    assert(sub:find("^|cffff9919Herboristerie 75/75 : va prendre Compagnon|r\n") and sub:find("|cff808080• Cueille", 1, true), sub)
  end)

  check("Rang bloquant : rang pas encore disponible (niveau) ou presque au plafond", function()
    local n = rankBoot(75, 5, MASTER)
    local s = n.Prof.Steps(182)
    assert(not s.alert and s.go == "HERBALISM" and s.todo[1].kind == "wait" and s.todo[1].text == "Compagnon au niveau 10 : continue", s.todo[1].text)
    assert(not s.todo[2].held and n.Guide.Goals()[2].go == "HERBALISM" and n.Guide.Goals()[2].text:find("Compagnon au niveau 10", 1, true))
    n.State.level = 20
    n.State.profs[182].rank = 72
    s = n.Prof.Steps(182)
    assert(s.alert and s.title == "Herboristerie 72/75 : encore 3 points possibles, puis maître (Compagnon)", s.title)
    assert(s.todo[1].kind == "rank" and not s.todo[2].held, "presque : le reste n'est pas masque")
    n.State.profs[182].rank = 60
    assert(n.Prof.Steps(182).alert and n.Prof.Steps(182).title == "Herboristerie 60/75 : Compagnon disponible, va le prendre chez le maître", "disponible des 50 : a prendre tout de suite")
    n.State.profs[182].rank = 40
    assert(not n.Prof.Steps(182).alert, "sous 50 : rien a prendre")
    n.State.profs[182] = { rank = 300, max = 300 }
    assert(not n.Prof.Steps(182).alert, "dernier rang : rien a prendre")
  end)

  check("Rang bloquant : Ou aller et Repere sur la rangee metier (carte, Maintenant, Metiers)", function()
    local n, G = rankBoot(75, 20, MASTER)
    n.SetCompact(true)
    local r = G.card.rows[2]
    assert(r.where.shown and r.where.text:find("Où aller : Maître d'herboristerie", 1, true), tostring(r.where.text))
    assert(r.go.shown == true and r.dest == MASTER, "bouton Repere sur la rangee metier")
    n.State.profs[182].rank = 10
    n.Fire("GUIDE")
    assert(r.where.shown and r.go.shown == true and r.dest == MASTER, "plus de rang a prendre : maitre le plus proche toujours propose")
    n.State.profs[182].rank = 75
    n.SetCompact(false)
    n.ToggleGuide()
    G.win.tabs[1].scripts.OnClick(G.win.tabs[1])
    local row = G.rows[2]
    assert(row.sub.text:find("Où aller", 1, true) and row.go.shown == true, "Maintenant")
  end)

  ---------------------------------------------------------------------------------------------------
  -- Or : meilleure action, suivi de session, rangee Or, onglet Or
  ---------------------------------------------------------------------------------------------------
  local function goldNs(profs)
    local n = fresh().n
    setState(n, { level = 12, profs = profs or { [182] = { rank = 60, max = 75 } } })
    mock.ah, mock.bagInfo, mock.sellPrice, mock.money = {}, nil, nil, nil
    return n
  end
  local function bagScan(n) mock.fire("BAG_UPDATE_DELAYED") mock.flushTimers() end
  local function bags(n)
    mock.bagInfo = { { itemID = 101, stackCount = 20, quality = 1 } }
    mock.sellPrice = { [101] = 10 }
    mock.ah = { [101] = { 1000, 2 }, [765] = { 30, 1 } } -- 20 x 1000 pc a l'HdV contre 200 pc au marchand ; Feuillargent 30 pc
    bagScan(n)
  end
  local function adviceWith(n, margin) n.Prof.Advice[171] = { list = { { name = "Potion X", margin = margin } } } end

  check("Or : la vente HdV est choisie quand elle vaut le plus", function()
    if not Auctionator then return end
    if not C_Container then return end
    local n = goldNs({ [182] = { rank = 60, max = 75 }, [171] = { rank = 50, max = 75 } })
    adviceWith(n, 45)
    bags(n)
    local b = n.Gold.Best()
    assert(b.kind == "sell" and b.value == 19800, "vente : " .. tostring(b.kind) .. " " .. tostring(b.value))
    assert(b.text == "Vends 20 Baguette 101 à l'HdV de Fossoyeuse : ≈ " .. n.Prof.Money(20000) .. " (prix de départ conseillé " .. n.Prof.Money(999) .. " l'unité, durée 12 h)", b.text)
    local c = n.Gold.Candidates()
    assert(#c == 3 and c[1].kind == "sell" and c[2].kind == "craft" and c[3].kind == "gather", "tri par cuivre/min : vente, craft, cueillette")
    mock.ah[101] = { 1000, 10 } -- prix trop ancien : la vente n'est plus proposee
    bagScan(n)
    assert(n.Gold.Best().kind ~= "sell", "prix ancien ecarte")
  end)

  check("Or : craft rentable", function()
    if not Auctionator then return end
    local n = goldNs({ [171] = { rank = 50, max = 75 } })
    adviceWith(n, 45)
    local b = n.Gold.Best()
    assert(b.kind == "craft" and b.value == 45 and b.text == "Fabrique 5 Potion X : marge ≈ " .. n.Prof.Money(225) .. " en ≈ 1 min", b.text)
    adviceWith(n, -5)
    assert(n.Gold.Best().kind == "tip", "marge negative : pas de conseil de craft")
  end)

  check("Or : cueillette avec prix, ici puis ailleurs", function()
    if not Auctionator then return end
    local n = goldNs()
    mock.ah = { [765] = { 30, 1 }, [2447] = { 10, 1 }, [2449] = { 5, 1 }, [3820] = { 900, 1 } } -- 3820 : herbe d'un rang trop haut
    n.State.zone, n.State.mapID = 1420, 1420
    local b = n.Gold.Best()
    assert(b.kind == "gather" and b.text == "Cueille 20 Feuillargent ici : ≈ 7 min, ≈ " .. n.Prof.Money(600) .. " à l'HdV", b.text)
    n.State.zone, n.State.mapID = 1424, 1424
    b = n.Gold.Best()
    assert(b.kind == "gather" and b.text:find("^Cueille 20 Feuillargent %(") and b.text:find(n.Prof.Money(600), 1, true) and not b.text:find("ici", 1, true), b.text)
    n.State.profs = { [171] = { rank = 50, max = 75 } }
    assert(n.Gold.Best().kind == "tip", "sans Herboristerie : pas de cueillette")
  end)

  check("Or : rien a vendre ni a crafter, conseil generique", function()
    local n = goldNs()
    local b = n.Gold.Best()
    assert(b.kind == "tip" and b.value == 0 and b.text:find("vends-les à l'hôtel des ventes", 1, true), b.text)
    assert(#n.Gold.Candidates() == 0 and not b.text:find("|T", 1, true), "aucun montant")
  end)

  check("Or : sans Auctionator, aucun montant invente", function()
    local n = goldNs({ [182] = { rank = 60, max = 75 }, [171] = { rank = 50, max = 75 } })
    adviceWith(n, 45)
    if C_Container then bags(n) end
    local ah = Auctionator
    Auctionator = nil
    local b = n.Gold.Best()
    Auctionator = nil
    assert(b.kind == "tip" and #n.Gold.Candidates() == 0, "conseil generique")
    assert(not b.text:find("|T", 1, true) and b.detail:find("Installe Auctionator", 1, true), "ni montant, et la note Auctionator")
    for _, r in ipairs(n.Gold.Rows()) do assert(not r.text:find("≈") or r.text:find("Session"), "pas de montant d'action : " .. r.text) end
    Auctionator = ah
  end)

  check("Or : or de session et or par heure", function()
    local n = goldNs()
    mock.money, mock.time = 10000, 0
    local net, perHour = n.Gold.Session()
    assert(net == 0 and perHour == nil, "debut : rien, pas d'or/heure avant une minute")
    mock.money, mock.time = 22000, 1800
    net, perHour = n.Gold.Session()
    assert(net == 12000 and perHour == 24000, "net et or/heure : " .. tostring(net) .. " " .. tostring(perHour))
    assert(n.Gold.SessionText() == "Session : +" .. n.Prof.Money(12000) .. " (≈ " .. n.Prof.Money(24000) .. "/h)", n.Gold.SessionText())
    mock.money = 4000 -- depenses chez les maitres : le net, simplement
    assert(n.Gold.SessionText() == "Session : -" .. n.Prof.Money(6000) .. " (≈ -" .. n.Prof.Money(12000) .. "/h)", n.Gold.SessionText())
    if not mock.noSecrets then
      mock.moneySecret = true
      assert(n.Gold.Session() == nil and n.Gold.SessionText() == nil, "argent secret : rien")
      mock.moneySecret = nil
    end
    mock.money = nil
  end)

  check("Or : rangee Or apres les metiers, masquable, carte", function()
    local n, G = gw()
    n.State.profs = { [182] = { rank = 10, max = 75 }, [171] = { rank = 10, max = 75 } }
    mock.money, mock.time = 5000, 0
    local goals = n.Guide.Goals()
    local g = goals[#goals]
    assert(#goals == 4 and g.kind == "gold" and g.label == "Or" and goals[3].line == 171, "dernier, apres les metiers")
    assert(g.text == n.Gold.Best().text and g.detail:find("Prochain achat", 1, true), "texte de Best et prochain achat : " .. tostring(g.detail))
    n.SetCompact(true)
    local r = G.card.rows[4]
    assert(G.card.used == 4 and r.label.text == "Or" and r.icon.tex == "Interface\\Icons\\INV_Misc_Coin_01", "carte : icone de piece")
    n.db.show.gold = false
    n.Fire("GUIDE")
    assert(#n.Guide.Goals() == 3 and G.card.used == 3 and not G.card.rows[4].shown, "show.gold = false masque la rangee")
    SlashCmdList.PRETRECOACH("gold")
    assert(n.db.show.gold == true and #n.Guide.Goals() == 4, "/coach gold la reaffiche")
    mock.money = nil
  end)

  check("Or : case des options", function()
    local n, restore = boot()
    local c, db = controls(n), n.db
    assert(c.gold and db.show.gold == true, "case cochee par defaut")
    click(c.gold)
    assert(db.show.gold == false and #n.Guide.Goals() >= 1, "decochee : rangee masquee")
    for _, g in ipairs(n.Guide.Goals()) do assert(g.kind ~= "gold") end
    restore()
  end)

  check("Or : onglet Or, top 5 puis session", function()
    if not Auctionator then return end
    if not C_Container then return end
    local n, G = gw()
    n.State.profs = { [182] = { rank = 60, max = 75 }, [171] = { rank = 50, max = 75 } }
    adviceWith(n, 45)
    mock.money, mock.time = 1000, 0
    bags(n)
    n.ToggleGuide()
    local idx
    for i, k in ipairs({ "now", "next", "talents", "spells", "dungeons", "zones", "profs", "undead", "sell", "gold", "route" }) do if k == "gold" then idx = i end end
    assert(G.win.tabs[idx].label.text == "Devenir riche", "onglet renomme, a cote de Vente")
    G.win.tabs[idx].scripts.OnClick(G.win.tabs[idx])
    -- objectif, reserve, en-tete + 3 pistes, en-tete + 1 ligne de chiffres, session = 9
    assert(n.db.guide.tab == "gold" and G.used == 9, "9 lignes : " .. G.used)
    local rows = n.Gold.Rows()
    assert(rows[4].text:find("Vends 20", 1, true) and rows[5].text:find("Fabrique", 1, true) and rows[6].text:find("Cueille", 1, true), "tri par cuivre/min")
    assert(rows[#rows].text:find("Session :", 1, true), "session en dernier")
    mock.money = nil
  end)

  check("Or : rien de secret, rien d'ecrit dans la base", function()
    local n = goldNs({ [182] = { rank = 60, max = 75 } })
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    before.pace = true -- rythme d'XP de la rangee XP (Guide.Goals), pas de l'or
    mock.money, mock.time = 1000, 0
    mock.ah = { [765] = { 30, 1 } }
    n.Gold.Best() n.Gold.Rows() n.Gold.SessionText() n.Guide.Goals()
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
    for k in pairs(n.db) do assert(not tostring(k):lower():find("gold"), "rien de l'or dans la base") end
    mock.money = nil
  end)

  check("Rang bloquant : Goto absent ou illisible, aucun lieu invente", function()
    local n = rankBoot(75, 20, nil) -- Goto.For ne trouve rien
    local s = n.Prof.Steps(182)
    assert(s.todo[1].text == "Va voir le maître pour le rang Compagnon : Martha Alliestar (Fossoyeuse)", s.todo[1].text)
    n.Goto.For = function() error("illisible") end
    assert(n.Prof.Steps(182).todo[1].text:find("Martha Alliestar", 1, true), "erreur Goto : repli sur les donnees")
    n.Goto.For = function() return { text = "ton maître d'herboristerie (Questie conseillé pour le localiser)" } end
    local t = n.Prof.Steps(182).todo[1].text
    assert(t:find("Martha Alliestar", 1, true) and not t:find("Questie", 1, true), "sans coordonnees : pas de lieu invente")
    local keep = n.Goto
    n.Goto = nil
    local kind = n.Prof.Steps(182).todo[1].kind
    n.Goto = keep -- ce ns reste branche aux evenements : sans Goto, un rendu ulterieur du guide planterait
    assert(kind == "rank", "Goto absent")
  end)

  -- Indicateur de tir de baguette (Wand.lua + barre du RotationPanel)
  local SHOOT, SMITE_ID = 5019, 585
  local function near(a, b) return type(a) == "number" and math.abs(a - b) < 0.01 end
  local function shoot(t) mock.time = t mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", SHOOT) end
  local function failAt(t, id) mock.time = t mock.fire("UNIT_SPELLCAST_FAILED", "player", "c", id or SMITE_ID) end
  -- baguette lancee 4 fois a 1,5 s d'ecart : dernier tir a t = 104,5
  local function wandBoot(fn)
    local keep = PretreCoachDB
    isolated(function()
      local n, P = panel()
      for i = 0, 3 do shoot(100 + i * 1.5) end
      fn(n, P, n.Wand, P.frame.wand)
    end, function() PretreCoachDB = keep end)
  end

  check("Baguette : vitesse = mediane des ecarts (hors 0,8-4 s), repli UnitRangedDamage", function()
    wandBoot(function(n, P, W)
      assert(near(W.Speed(), 1.5), "vitesse " .. tostring(W.Speed()))
      shoot(120) -- ecart de 15,5 s : ignore
      assert(near(W.Speed(), 1.5), "ecart aberrant ignore")
      shoot(120.4) -- 0,4 s : ignore aussi
      assert(near(W.Speed(), 1.5))
    end)
    local keep = PretreCoachDB
    isolated(function()
      local n = panel()
      mock.rangedSpeed = 2.2
      assert(n.Wand.Speed() == 2.2, "repli UnitRangedDamage")
      mock.rangedSpeed = nil
    end, function() PretreCoachDB = keep end)
  end)

  check("Baguette : zone rouge par defaut (0,5 s apres et avant le tir), phase verte ou rouge", function()
    wandBoot(function(n, P, W, wb)
      local z = W.Zones()
      assert(#z == 2 and near(z[1][1], 0) and near(z[1][2], 1 / 3) and near(z[2][1], 2 / 3) and near(z[2][2], 1), "zones par defaut")
      mock.time = 104.5 + 0.2
      local st = W.State()
      assert(st.red and near(W.Wait(), 0.3), "juste apres le tir : rouge, reste 0,3 s")
      mock.time = 104.5 + 0.75
      assert(not W.State().red and W.Wait() == nil, "milieu du cycle : vert")
      mock.time = 104.5 + 1.4
      assert(W.State().red, "juste avant le prochain tir : rouge")
      -- la raison du conseil (ordre inchange)
      local res = N.Rotation.Compute(rctx({ level = 20, hasWand = true, inCombat = true, hasSWP = true, wandWait = 0.3 }))
      assert(keysOf(res) == "SHOOT" and not res.reason:find("attends la fin du tir", 1, true), "baguette seule : rien a ajouter")
      res = N.Rotation.Compute(rctx({ level = 20, hasWand = true, inCombat = true, hasSWP = false, wandWait = 0.3 }))
      assert(res.keys[1] ~= "SHOOT" and res.reason:find("attends la fin du tir (0.3 s)", 1, true), res.reason)
    end)
  end)

  check("Baguette : zone apprise apres 3 echecs (Tir et valeurs secretes ignores)", function()
    wandBoot(function(n, P, W)
      failAt(104.5 + 0.6, SHOOT)
      failAt(104.5 + 0.6, mock.noSecrets and "x" or mock.SECRET)
      assert(W.FailCount() == 0, "Tir et secret ne comptent pas")
      failAt(104.5 + 0.6) failAt(104.5 + 0.75)
      local z = W.Zones()
      assert(W.FailCount() == 2 and #z == 2, "2 echecs : toujours la zone par defaut")
      failAt(104.5 + 0.9)
      z = W.Zones()
      -- regle changee volontairement : deux bords (jamais un intervalle traversant), plafond 0,6 mais pas sous la zone par defaut
      -- (a 1,5 s la zone par defaut fait deja 0,67 : les echecs observes ne l'elargissent pas)
      assert(W.FailCount() == 3 and #z == 2 and near(z[1][2], 1 / 3) and near(z[2][1], 2 / 3), "zone apprise = defaut plafonnee")
      mock.time = 104.5 + 0.1
      assert(W.State().red, "phase 0,07 : juste apres le tir, rouge")
      mock.time = 104.5 + 0.75
      assert(not W.State().red, "phase 0,5 : vert (plus d'intervalle traversant)")
      for i = 1, 25 do mock.fire("UNIT_SPELLCAST_FAILED_QUIET", "player", "c", SMITE_ID) end
      assert(W.FailCount() == 20, "20 phases gardees")
    end)
  end)

  -- baguette a 2 s : zone par defaut 0,25 de chaque cote (total 0,5), plafond 0,6
  local function wandBoot2(fn)
    local keep = PretreCoachDB
    isolated(function()
      local n = panel()
      for i = 0, 3 do shoot(100 + i * 2) end
      fn(n.Wand)
    end, function() PretreCoachDB = keep end)
  end
  local function redWidth(z) local s = 0 for _, x in ipairs(z) do s = s + x[2] - x[1] end return s end

  check("Baguette : echecs a 0,05 / 0,5 / 0,9 : rouge <= 0,6 et deux bords separes", function()
    wandBoot2(function(W)
      failAt(106 + 0.1) failAt(106 + 1) failAt(106 + 1.8)
      local z = W.Zones()
      assert(W.FailCount() == 3 and #z == 2, "3 echecs retenus, 2 bords")
      assert(redWidth(z) <= 0.6 + 1e-6 and redWidth(z) >= 0.5 - 1e-6, "largeur " .. redWidth(z))
      assert(z[1][1] == 0 and z[2][2] == 1 and z[1][2] < z[2][1], "aucun intervalle ne traverse la barre")
      mock.time = 106 + 1 -- phase 0,5 : le milieu reste vert
      assert(not W.State().red, "milieu vert")
    end)
  end)

  check("Baguette : echec ancien oublie, echec loin du tir ignore", function()
    wandBoot2(function(W)
      failAt(106 + 0.1) failAt(106 + 0.2) failAt(106 + 0.3)
      assert(W.FailCount() == 3)
      mock.time = 106 + 61
      assert(W.FailCount() == 0 and #W.Zones(2) == 2 and near(W.Zones(2)[1][2], 0.25), "echecs perimes oublies")
    end)
    local keep = PretreCoachDB
    isolated(function() -- baguette a 3 s : fenetre 1,2 s = 0,4 de phase
      local n = panel()
      for i = 0, 3 do shoot(100 + i * 3) end
      failAt(109 + 1.5) -- phase 0,5 : trop loin d'un tir
      assert(n.Wand.FailCount() == 0, "echec loin du tir ignore")
      failAt(109 + 0.3)
      assert(n.Wand.FailCount() == 1, "echec pres du tir retenu")
    end, function() PretreCoachDB = keep end)
  end)

  check("Baguette : vitesse changee sans lecture : 4 ecarts rejetes coherents deviennent la base", function()
    local keep = PretreCoachDB
    isolated(function()
      local n = panel()
      for _, t in ipairs({ 100, 101.5, 103, 104.5 }) do shoot(t) end
      assert(near(n.Wand.Speed(), 1.5))
      for i = 1, 5 do shoot(104.5 + 2 * i) end
      assert(near(n.Wand.Speed(), 2.0), "vitesse " .. tostring(n.Wand.Speed()))
    end, function() PretreCoachDB = keep end)
  end)

  check("Baguette : ecarts 1,5 / 1,5 / 2,6 / 1,5 : vitesse 1,5 ; vitesse de reference changee > 15 % : reset", function()
    local keep = PretreCoachDB
    isolated(function()
      local n = panel()
      for _, t in ipairs({ 100, 101.5, 103, 105.6, 107.1 }) do shoot(t) end
      assert(near(n.Wand.Speed(), 1.5), "vitesse " .. tostring(n.Wand.Speed()))
    end, function() PretreCoachDB = keep end)
    isolated(function()
      local n = panel()
      mock.rangedSpeed = 1.5 -- reference lisible : 2,6 s rejete des le premier
      for _, t in ipairs({ 100, 102.6, 105.2, 107.8 }) do shoot(t) end
      assert(near(n.Wand.Speed(), 1.5), "ecarts hors +-25 % ignores, repli UnitRangedDamage")
      for i = 1, 3 do shoot(107.8 + 1.5 * i) end
      failAt(112.3) failAt(112.4) failAt(112.5)
      assert(n.Wand.FailCount() == 3 and near(n.Wand.Speed(), 1.5))
      mock.rangedSpeed = 1.8 -- +20 % : tout est vide
      shoot(114.3)
      assert(n.Wand.FailCount() == 0 and near(n.Wand.Speed(), 1.8), "reset : echecs vides, vitesse = nouvelle reference")
      mock.rangedSpeed = nil
    end, function() PretreCoachDB = keep end)
  end)

  check("Baguette : barre visible pendant le tir, cachee apres (2 x vitesse, fin de combat)", function()
    wandBoot(function(n, P, W, wb)
      assert(wb:IsShown() and wb.scripts.OnUpdate, "visible pendant le tir")
      mock.time = 104.5 + 0.2
      wb.scripts.OnUpdate(wb, 0.1)
      assert(wb.red == true and wb.label.text == n.L.WAND_WAIT and near(wb.value, 0.2 / 1.5), "rouge : attends")
      mock.time = 104.5 + 0.75
      wb.scripts.OnUpdate(wb, 0.1)
      assert(wb.red == false and wb.label.text == n.L.WAND_GO and near(wb.value, 0.5), "vert : GO")
      mock.time = 104.5 + 3.5 -- plus de tir depuis plus de 2 x 1,5 s
      wb.scripts.OnUpdate(wb, 0.1)
      assert(not wb:IsShown() and wb.scripts.OnUpdate == nil, "plus de tir : cachee, OnUpdate retire")
      shoot(110)
      assert(wb:IsShown(), "nouveau tir : revient")
      mock.fire("PLAYER_REGEN_ENABLED")
      assert(not wb:IsShown() and wb.scripts.OnUpdate == nil, "fin de combat : cachee")
    end)
  end)

  check("Baguette : option show.wandbar masque la barre", function()
    wandBoot(function(n, P, W, wb)
      assert(wb:IsShown())
      n.db.show.wandbar = false
      P.UpdateWand()
      assert(not wb:IsShown() and wb.scripts.OnUpdate == nil, "option decochee")
      shoot(106)
      assert(not wb:IsShown(), "un tir ne la reaffiche pas")
      SlashCmdList.PRETRECOACH("wand")
      assert(n.db.show.wandbar == true and wb:IsShown(), "/coach wand la reaffiche")
    end)
  end)

  ------------------------------------------------------------------------
  -- Objectif XP choisi parmi les quetes (Quests.Best) ; talents et sorts seulement s'ils sont debloquables
  ------------------------------------------------------------------------
  local function questN(level)
    mock.qlog, mock.qquests, mock.qdone, mock.pos = nil, nil, nil, { 0.5, 0.5 }
    mock.mapID = 1420
    mock.qnpcs[9001] = { 0, "", "H", 85, { [85] = { { 52, 50 } } } } -- tout pres du joueur (50, 50)
    mock.qnpcs[9003] = { 0, "", "H", 85, { [85] = { { 80, 80 } } } } -- loin
    local n = fresh().n
    setState(n, { level = level or 20, mapID = 1420 })
    return n
  end
  local LOUPS = { { text = "3/8 Loups tués", numFulfilled = 3, numRequired = 8, finished = false } }

  -- Signal sur les monstres de quete : index, barres de nom, bulle
  local function mobLog()
    mock.qquests = {
      [501] = { name = "Q501", objectives = { { { 7001, "Loup" } }, {}, { { 8001, "Peau" } } } },
      [502] = { name = "Q502", objectives = { { { 7005, "Rat" } } } },
    }
    mock.qnpcs[7001] = { 0, "", "H", 85, {} }
    mock.qitems = { [8001] = { name = "Peau", npcDrops = { 7002, 7003 } } }
    mock.qlog = {
      { questID = 501, title = "Loups", objectives = {
        { text = "Loup tué : 3/8", numFulfilled = 3, numRequired = 8, finished = false },
        { text = "Peau : 0/4", numFulfilled = 0, numRequired = 4, finished = false } } },
      { questID = 502, title = "Fini", objectives = { { text = "Rat tué : 5/5", numFulfilled = 5, numRequired = 5, finished = true } } },
    }
  end
  local function tipLine(n, guid)
    GameTooltip.lines = nil
    if mock.tipCall then mock.tipCall(GameTooltip, { guid = guid })
    else GameTooltip.hooks.OnTooltipSetUnit(GameTooltip) end
    return GameTooltip.lines and GameTooltip.lines[1]
  end

  check("Monstres de quete : index kill + loot, objectif fini ignore, signal, bulle, option, combat", function()
    if not (C_QuestLog and C_NamePlate and LibQuestieDB) then return end
    local n = questN(20)
    local QM = n.UI.QuestMobs
    assert(n.DEFAULTS.show.questmobs == true)
    mobLog()
    QM.Rebuild()
    local idx = QM.Index()
    assert(idx[7001] and idx[7001][1].kind == "kill" and idx[7001][1].text == "Loup tué : 3/8", "kill")
    assert(idx[7002] and idx[7002][1].kind == "loot" and idx[7002][1].text == "Peau : 0/4" and idx[7003], "loot via npcDrops")
    assert(idx[7005] == nil, "objectif fini ignore")
    -- barres de nom
    local plate = {}
    mock.plates = { nameplate1 = plate, nameplate2 = {} }
    mock.guid = "Creature-0-1-2-3-7001-0000ABCD"
    mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    local ic = QM.Icon("nameplate1")
    assert(ic and ic.shown and ic.pt[1] == "LEFT" and ic.pt[2] == plate and ic.parent == plate, "icone ancree sur la barre")
    mock.fire("NAME_PLATE_UNIT_REMOVED", "nameplate1")
    assert(QM.Icon("nameplate1") == nil and not ic.shown and ic.parent == UIParent, "icone retiree")
    mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate1")
    assert(QM.Icon("nameplate1") == ic, "pool reutilise")
    -- GUID secret, illisible, absent : rien, aucune erreur
    for _, g in ipairs({ mock.SECRET, "n'importe quoi", "Creature-0", "Creature-0-1-2-3-9999-0" }) do
      mock.guid = g
      mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
      assert(QM.Icon("nameplate2") == nil, "pas de signal")
      mock.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
    end
    mock.guid = "Creature-0-1-2-3-7001-0000ABCD"
    mock.noGuid = true
    mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate2")
    mock.noGuid = nil
    assert(QM.Icon("nameplate2") == nil)
    mock.fire("NAME_PLATE_UNIT_REMOVED", "nameplate2")
    -- bulle
    local g = "Creature-0-1-2-3-7001-0000ABCD"
    assert(tipLine(n, g) == "Quête : Loups — Loup tué : 3/8", "ligne de bulle : " .. tostring(tipLine(n, g)))
    assert(tipLine(n, "Creature-0-1-2-3-9999-0") == nil and tipLine(n, mock.SECRET) == nil, "autre PNJ ou secret : rien")
    GameTooltip.NumLines = function() return 1 end
    _G.GameTooltipTextLeft1 = { GetText = function() return "- Loup tué : 3/8" end }
    assert(tipLine(n, g) == nil, "pas de doublon avec la ligne Blizzard")
    GameTooltip.NumLines, _G.GameTooltipTextLeft1 = nil, nil
    -- option
    n.db.show.questmobs = false
    QM.Update()
    assert(not ic.shown and tipLine(n, g) == nil, "option decochee")
    n.db.show.questmobs = true
    QM.Update()
    assert(ic.shown)
    -- combat : l'index ne bouge pas, repris a la sortie
    mock.inCombat = true
    mock.qlog = {}
    QM.Rebuild()
    assert(QM.Index()[7001], "combat : index garde")
    mock.inCombat = false
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(next(QM.Index()) == nil and not ic.shown, "sortie de combat : index refait")
    assert(not findSecret(n.db, "db") and n.db.questmobs == nil)
  end)

  check("Monstres de quete : sans LibQuestieDB, aucun signal", function()
    if not C_QuestLog then return end
    local lib = _G.LibQuestieDB
    _G.LibQuestieDB = nil
    local n = questN()
    mobLog()
    mock.plates = { nameplate1 = {} }
    mock.guid = "Creature-0-1-2-3-7001-0000ABCD"
    n.UI.QuestMobs.Rebuild()
    if C_NamePlate then mock.fire("NAME_PLATE_UNIT_ADDED", "nameplate1") end
    local none = next(n.UI.QuestMobs.Index()) == nil and n.UI.QuestMobs.Icon("nameplate1") == nil
    _G.LibQuestieDB = lib
    assert(none, "sans base : rien")
  end)

  check("Monstres de quete : sans API de quetes ni de barres de nom, aucune erreur", function()
    if C_QuestLog and C_NamePlate then return end
    local n = questN()
    n.UI.QuestMobs.Rebuild()
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(next(n.UI.QuestMobs.Index()) == nil)
  end)

  check("Quetes : une quete terminee a rendre passe avant une quete en cours, meme un peu plus loin", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.qnpcs[9004] = { 0, "", "H", 85, { [85] = { { 52.5, 50 } } } } -- rendu a 2,5 (arret le plus proche : 2)
    mock.qquests = { [201] = { name = "En cours", startedBy = { { 9001 } } }, [202] = { name = "Finie", startedBy = { { 9001 } }, finishedBy = { { 9004 } } } }
    mock.qlog = { { questID = 201, title = "En cours", objectives = LOUPS }, { questID = 202, title = "Finie", complete = true } }
    n.Quests.Refresh()
    local b = n.Quests.Best()
    assert(b and b.kind == "turnin" and b.questID == 202 and b.text == "Rends « Finie »" and b.go == "N9004", b and b.text)
    local g = n.Guide.Goals()[1]
    assert(g.text == b.text and g.go == "N9004" and g.e == nil and g.quest == b, "la rangee XP est la quete : " .. tostring(g.text))
    local d = n.Goto.For(g.go)
    assert(d.mapID == 1420 and d.x == 52.5 and d.y == 50 and d.text:find("Tirisfal", 1, true), d.text)
    assert(n.Goto.Place(d) == true and mock.waypoint.mapID == 1420, "Repere pose")
  end)


  check("Quetes : dans une grotte ou un batiment, la route se calcule sur la carte de la zone", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.mapTypes, mock.mapParents = { [9999] = 5, [9998] = 4 }, { [9999] = 9998, [9998] = 1420 }
    local ok, err = pcall(function()
      assert(n.Quests.ZoneMap(9999) == 1420 and n.Quests.ZoneMap(1420) == 1420 and n.Quests.ZoneMap(nil) == nil, "remonte micro -> instance -> zone")
      mock.qquests = { [202] = { name = "Finie", startedBy = { { 9001 } }, finishedBy = { { 9001 } } } }
      mock.qlog = { { questID = 202, title = "Finie", complete = true } }
      n.State.mapID = 9999
      n.Quests.Refresh()
      local r = n.Quests.Route()
      assert(r[1] and r[1].questID == 202 and r[1].here == true, "le rendu de la zone est ici, pas dans une autre zone")
    end)
    mock.mapTypes, mock.mapParents = nil, nil
    assert(ok, err)
  end)

  check("Quetes : un rendu a l'autre bout de la zone n'ouvre plus la route (seulement s'il est pres)", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.qquests = { [201] = { name = "En cours", startedBy = { { 9001 } } }, [202] = { name = "Finie", startedBy = { { 9001 } }, finishedBy = { { 9003 } } } }
    mock.qlog = { { questID = 201, title = "En cours", objectives = LOUPS }, { questID = 202, title = "Finie", complete = true } }
    n.Quests.Refresh()
    local r = n.Quests.Route()
    assert(r[1].questID == 201 and r[2].kind == "turnin", "rendu a 42 contre 2 : plus proche voisin")
    local o = n.Quests.Order({ { kind = "turnin", questID = 1, x = 53, y = 50 }, { kind = "pickup", questID = 2, x = 52, y = 50 } }, 50, 50)
    assert(o[1].kind == "turnin", "rendu a 3 contre 2 (1,5x) : d'abord")
  end)

  check("Quetes : objectif objet lache ou objet du monde, spawn le plus proche, objectif fini ecarte", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.qnpcs[7002] = { 0, "", "H", 85, { [85] = { { 90, 90 }, { 60, 50 } } } } -- 2 spawns : le plus proche est (60, 50)
    mock.qnpcs[7003] = { 0, "", "H", 85, { [85] = { { 30, 30 } } } }
    mock.qitems = { [8001] = { name = "Peau", npcDrops = { 7002 } }, [8002] = { name = "Griffe", npcDrops = { 7003 } } }
    mock.qobjects = { [6001] = { name = "Caisse", spawns = { [85] = { { 70, 50 } } } } }
    mock.qquests = {
      [201] = { name = "Peaux", startedBy = { { 9003 } }, objectives = { {}, {}, { { 8001, "Peau" } } } },
      [202] = { name = "Caisses", startedBy = { { 9003 } }, objectives = { {}, { { 6001, "Caisse" } } } },
      [203] = { name = "Deux", startedBy = { { 9003 } }, objectives = { {}, {}, { { 8002, "Griffe" }, { 8001, "Peau" } } } },
    }
    local function ob(text, fin) return { text = text, numFulfilled = fin and 1 or 0, numRequired = 1, finished = fin } end
    mock.qlog = { { questID = 201, title = "Peaux", objectives = { ob("Peau : 0/1") } } }
    n.Quests.Refresh()
    local s = n.Quests.Route()[1]
    assert(s.x == 60 and s.y == 50 and s.here and s.npc == 7002 and type(s.go) == "table", "objet lache : spawn le plus proche, pas le donneur (80, 80)")
    mock.qlog = { { questID = 202, title = "Caisses", objectives = { ob("Caisse : 0/1") } } }
    n.Quests.Refresh()
    s = n.Quests.Route()[1]
    assert(s.x == 70 and s.y == 50 and s.npc == nil and s.go.x == 70, "objet du monde")
    mock.qlog = { { questID = 203, title = "Deux", objectives = { ob("Griffe : 0/1"), ob("Peau : 1/1", true) } } }
    n.Quests.Refresh()
    s = n.Quests.Route()[1]
    assert(s.x == 30 and s.y == 30, "la Peau est finie : seule la Griffe compte")
    mock.pos = false
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].x == 30, "position illisible : centre des spawns")
    assert(n.Q.WhereNear(7002, 1420, 85, 85).x == 90 and n.Q.WhereNear(7002, 1420).x == 60 or n.Q.WhereNear(7002, 1420).x == 90, "WhereNear")
    assert(n.Q.WhereNear(7002, 999, 50, 50) == nil, "autre carte : nil")
  end)

  check("Quetes : trop haute pour le joueur (niveau de quete > niveau + 2) : jamais proposee, journal en fin de liste", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN(13)
    n.db.qindex = {}
    local function q(name, lvl) return { name = name, startedBy = { { 9001 } }, requiredLevel = 10, questLevel = lvl } end
    mock.qquests = { [601] = q("Seize", 16), [602] = q("Quinze", 15), [603] = q("Haute", 16), [604] = q("Basse", 13) }
    assert(n.Quests.StartIndex() == true)
    for _ = 1, 5 do mock.flushTimers() end
    mock.qlog = { { questID = 603, title = "Haute", objectives = LOUPS }, { questID = 604, title = "Basse", objectives = LOUPS } }
    n.Quests.Refresh()
    local r, ids = n.Quests.Route(), {}
    for i, s in ipairs(r) do ids[s.questID] = i end
    assert(ids[602] and not ids[601], "a prendre : 15 gardee, 16 ecartee au niveau 13")
    assert(ids[603] == #r and r[#r].tooHigh == 16 and r[#r].text:find("trop haute", 1, true) and ids[604] < ids[603], "journal 16 : en fin de liste")
    assert(n.Quests.Best().questID ~= 603, "jamais l'objectif du jour")
    n.State.level = 14
    n.Quests.Refresh()
    assert(not n.Quests.Route()[#n.Quests.Route()].tooHigh, "niveau 14 : redevient normale")
  end)

  check("Itineraire : plusieurs zones (la plus rentable d'abord, zone grise ou rendu faible ecartes, en-tete Ensuite)", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.areas = { [85] = "Tirisfal", [1497] = "Fossoyeuse", [1637] = "Orgrimmar", [1638] = "Pitons" }
    mock.mapKids = { [946] = { { mapID = 1420, name = "Tirisfal" }, { mapID = 1458, name = "Fossoyeuse" }, { mapID = 1411, name = "Orgrimmar" }, { mapID = 1412, name = "Pitons" } } }
    mock.qnpcs[9301] = { 0, "", "H", 1497, { [1497] = { { 50, 50 } } } }
    mock.qnpcs[9302] = { 0, "", "H", 1497, { [1497] = { { 60, 60 } } } }
    mock.qnpcs[9303] = { 0, "", "H", 1637, { [1637] = { { 40, 40 } } } }
    mock.qnpcs[9304] = { 0, "", "H", 1638, { [1638] = { { 30, 30 } } } }
    local function q(name, npc, lvl, fin) return { name = name, startedBy = { { 9001 } }, finishedBy = fin and { { npc } } or nil,
      objectives = { { { npc, "Loup" } } }, questLevel = lvl } end
    mock.qquests = { [700] = q("Ici", 9001, 20), [701] = q("A1", 9301, 20), [702] = q("A2", 9302, 20), [703] = q("B", 9303, 20),
      [704] = q("Grise", 9304, 10, true) }
    -- B d'abord dans le journal, mais A vaut deux quetes ; C : rendu d'une quete grise, ne justifie pas le trajet
    mock.qlog = { { questID = 703, title = "B", objectives = LOUPS }, { questID = 704, title = "Grise", complete = true },
      { questID = 701, title = "A1", objectives = LOUPS }, { questID = 702, title = "A2", objectives = LOUPS },
      { questID = 700, title = "Ici", objectives = LOUPS } }
    n.Quests.Refresh()
    local r, pos = n.Quests.Route(), {}
    for i, s in ipairs(r) do pos[s.questID] = i end
    assert(r[1].questID == 700, "la zone courante d'abord")
    assert(pos[701] < pos[703] and pos[702] < pos[703] and pos[701] <= 3 and pos[702] <= 3, "zone A (2 quetes) avant B")
    assert(pos[704] == #r, "rendu faible hors zone : en fin de liste, sans zone")
    assert(r[pos[703]].mapID == 1411 and r[pos[703]].zoneHead == true and (r[pos[701]].zoneHead or r[pos[702]].zoneHead), "en-tetes de zone")
    local heads = 0
    for _, row in ipairs(n.Quests.Rows()) do if row.text:find("^Ensuite : ") then heads = heads + 1 end end
    assert(heads == 2, "2 en-tetes (A, B), pas de zone C : " .. heads)
    mock.areas, mock.mapKids = nil, nil
  end)

  check("Quetes : a prendre, les 20 plus proches sont evalues, les 6 plus rentables gardees", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    n.db.qindex = {}
    mock.qquests = {}
    for i = 1, 8 do mock.qnpcs[9100 + i] = { 0, "", "H", 85, { [85] = { { 50 + i, 50 } } } } end
    mock.qnpcs[9200] = { 0, "", "H", 85, { [85] = { { 70, 50 } } } }
    for i = 1, 8 do mock.qquests[400 + i] = { name = "Proche" .. i, startedBy = { { 9100 + i } }, requiredLevel = 16, questLevel = 16 } end
    mock.qquests[499] = { name = "Rentable", startedBy = { { 9200 } }, requiredLevel = 20, questLevel = 22 }
    assert(n.Quests.StartIndex() == true)
    for _ = 1, 5 do mock.flushTimers() end
    n.Quests.Refresh()
    local found
    for _, s in ipairs(n.Quests.Route()) do if s.questID == 499 then found = true end end
    assert(found, "la quete de niveau 22, a 20 unites, n'est pas eliminee par 8 quetes proches")
  end)
  check("Quetes : la quete en cours la plus proche est choisie, texte des objectifs", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    mock.qquests = {
      [201] = { name = "Loin", startedBy = { { 9003 } } },
      [203] = { name = "Pres", startedBy = { { 9003 } }, objectives = { { { 9001, "Loup" } } } },
    }
    mock.qlog = { { questID = 201, title = "Loin", objectives = LOUPS }, { questID = 203, title = "Pres", objectives = LOUPS } }
    n.Quests.Refresh()
    local b = n.Quests.Best()
    assert(b.kind == "progress" and b.questID == 203 and b.text == "Pres : 3/8 Loups tués" and b.go == "N9001", b.text)
    assert(b.detail:find("Tirisfal", 1, true) and b.detail:find("à ~20 m", 1, true), b.detail)
    n.State.mapID = 1458 -- autre carte : plus rien n'est dans la zone, l'ordre du journal reste
    n.Quests.Refresh()
    assert(n.Quests.Best().questID == 201, "autre carte : ordre du journal")
  end)

  check("Quetes : a prendre dans la zone, au bon niveau, ni grise, ni faite, ni reservee", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    n.db.qindex = {} -- l'index des PNJ est pret
    local function q(name, t) t.name, t.startedBy = name, t.startedBy or { { 9001 } } return t end
    mock.qquests = {
      [301] = q("Bonne", { requiredLevel = 15, questLevel = 18 }),
      [302] = q("Grise", { requiredLevel = 5, questLevel = 12 }),
      [303] = q("Trop haute", { requiredLevel = 25, questLevel = 25 }),
      [304] = q("Deja faite", { requiredLevel = 15, questLevel = 18 }),
      [305] = q("Alliance", { requiredLevel = 15, questLevel = 18, requiredRaces = 77 }),
      [307] = q("Prerequis", { requiredLevel = 15, questLevel = 18, preQuestSingle = { 999 } }),
      [308] = q("Ailleurs", { requiredLevel = 15, questLevel = 18, startedBy = { { 375 } } }),
      [309] = q("Horde", { requiredLevel = 15, questLevel = 18, requiredRaces = 178, startedBy = { { 9003 } } }),
    }
    mock.qdone = { [304] = true }
    assert(n.Quests.StartIndex() == true)
    for _ = 1, 5 do mock.flushTimers() end
    n.Quests.Refresh()
    local b = n.Quests.Best()
    assert(b and b.kind == "pickup" and b.questID == 301 and b.text == "Prends « Bonne »" and b.go == "N9001", b and b.text)
    assert(b.detail:find("niveau 15 requis", 1, true) and b.detail:find("Tirisfal", 1, true), b.detail)
    assert(n.Guide.Goals()[1].text == b.text, "rangee XP : " .. tostring(n.Guide.Goals()[1].text))
    mock.qdone[301] = true -- prise : reste la quete Horde, plus loin
    n.Quests.Refresh()
    assert(n.Quests.Best().questID == 309, "Horde plus loin")
    mock.qdone[309] = true
    n.Quests.Refresh()
    assert(n.Quests.Best() == nil, "grises, trop hautes, faites, Alliance, prerequis, autre carte : rien")
    mock.qdone[999] = true -- prerequis fait : la quete arrive
    n.Quests.Refresh()
    assert(n.Quests.Best().questID == 307, "prerequis fait")
  end)

  check("Quetes : sans Questie, le journal seul (sans lieu)", function()
    if not C_QuestLog then return end
    local lib = _G.LibQuestieDB
    _G.LibQuestieDB = nil
    local n = questN()
    mock.qlog = { { questID = 201, title = "En cours", objectives = LOUPS }, { questID = 202, title = "Finie", complete = true } }
    n.Quests.Refresh()
    local b = n.Quests.Best()
    assert(b.kind == "turnin" and b.text == "Rends « Finie »" and b.go == nil and b.detail == "arrêt 1/2", b.text)
    mock.qlog = { { questID = 201, title = "En cours", objectives = LOUPS } }
    n.Quests.Refresh()
    b = n.Quests.Best()
    local g = n.Guide.Goals()[1]
    _G.LibQuestieDB = lib
    assert(b.kind == "progress" and b.text == "En cours : 3/8 Loups tués" and b.go == nil, b.text)
    assert(g.text == b.text and g.go == nil, "pas de Ou aller sans lieu")
  end)

  check("Guide XP : un talent sans point libre n'est pas la rangee XP, avec un point oui", function()
    local n = fresh().n
    mock.qlog = nil
    setState(n, { level = 10, talents = tl{ [14524] = 0 }, unspentTalents = 0 })
    assert(st(ev(n, "wandspec")) == "todo")
    local g = n.Guide.Goals()[1]
    assert(not (g.e and g.e.check == "talent"), "0 point : pas le talent")
    n.State.unspentTalents = 1
    g = n.Guide.Goals()[1]
    assert(g.e and g.e.id == "wandspec" and g.text == xpFor(n, "wandspec").text, "1 point : le talent")
    n.State.unspentTalents = nil
    g = n.Guide.Goals()[1]
    assert(not (g.e and g.e.check == "talent"), "nombre de points illisible : pas le talent")
  end)

  check("Guide XP : un sort pas encore debloquable n'est jamais la rangee XP ; repli de zone sans quete", function()
    local n = fresh().n
    mock.qlog = nil
    setState(n, { level = 30, mapID = 1420, unspentTalents = 0 })
    local locked = { id = "x1", check = "known", arg = "INEXISTANT", done = false, unknown = false, manual = false, text = "Sort verrouille" }
    local talent = { id = "x2", check = "talent", arg = 14524, done = false, unknown = false, manual = false, text = "Talent sans point" }
    n.Guide.Evaluate = function() return { locked, talent } end
    local g = n.Guide.Goals()[1]
    assert(g.e == nil and (g.text:find("^Monte") or g.text:find("^Continue")), "repli de zone : " .. tostring(g.text))
    n.Guide.Evaluate = function() return { locked, talent, { id = "x3", check = "spells", done = false, unknown = false, manual = false, text = "Apprends" } } end
    g = n.Guide.Goals()[1]
    assert(g.e and g.e.id == "x3", "sorts a apprendre chez le maitre : debloquables")
  end)

  check("Quetes : rien de secret ni de stocke, en combat le dernier resultat", function()
    if not (C_QuestLog and C_Map) then return end
    local n = questN()
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    mock.qlog = { { questID = 201, title = mock.SECRET, objectives = { { text = mock.SECRET, finished = false } } }, { questID = 202, title = "Finie", complete = true } }
    n.Quests.Refresh()
    assert(n.Quests.Best().text == "Rends « Finie »")
    mock.qlog = { { questID = 201, title = mock.SECRET, objectives = { { text = mock.SECRET, finished = false } } } }
    n.Quests.Refresh()
    local b = n.Quests.Best()
    assert(b.kind == "progress" and not findSecret(b, "best"), "titre secret : nom de repli")
    mock.inCombat = true
    mock.qlog = nil
    n.Quests.Refresh()
    assert(n.Quests.Best() == b, "en combat : le dernier resultat, sans relecture")
    mock.inCombat = false
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
  end)

  check("Goto : cible { mapID, x, y, text } et cle N<npc>", function()
    local n = fresh().n
    local d = n.Goto.For({ mapID = 1420, x = 10, y = 20, text = "Quelque part" })
    assert(d.mapID == 1420 and d.x == 10 and d.text == "Quelque part (10.0, 20.0)" and d.where == "Quelque part", d.text)
    assert(n.Goto.For({ mapID = 1 }) == nil, "sans texte : rien")
    assert(n.Goto.For("N9999").text:find("Questie", 1, true), "PNJ inconnu : texte neutre")
    mock.qinit()
    mock.pos = nil
  end)

  check("Baguette : rien de secret, rien dans les SavedVariables", function()
    wandBoot(function(n, P, W)
      mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "c", mock.noSecrets and "x" or mock.SECRET)
      mock.fire("UNIT_SPELLCAST_FAILED", "player", "c", mock.noSecrets and "x" or mock.SECRET)
      assert(W.FailCount() == 0 and near(W.Speed(), 1.5), "ids secrets ignores")
      mock.inCombat = true
      mock.rangedSpeed = nil
      assert(not findSecret(PretreCoachDB, "db"), "rien de secret")
      for k in pairs(PretreCoachDB) do assert(not tostring(k):lower():find("wand"), "rien de la baguette dans la base") end
      mock.inCombat = false
    end)
  end)

  ------------------------------------------------------------------------
  -- Itineraire optimise (Quests.Order / Route) et reperes de la carte du monde (UI.QuestPins)
  ------------------------------------------------------------------------
  check("Itineraire : plus proche voisin + 2-opt raccourcit, sans jamais allonger", function()
    local n = fresh().n
    math.randomseed(7)
    local better = 0
    for _ = 1, 60 do
      local stops = {}
      for i = 1, 9 do stops[i] = { kind = "pickup", questID = i, x = math.random(0, 100), y = math.random(0, 100) } end
      local plain = n.Quests.Order(stops, 50, 50, true)
      local opt = n.Quests.Order(stops, 50, 50)
      assert(#opt == 9 and #plain == 9)
      local lp, lo = n.Quests.PathLength(plain, 50, 50), n.Quests.PathLength(opt, 50, 50)
      assert(lo <= lp + 1e-9, "2-opt allonge le chemin")
      if lo < lp - 1e-9 then better = better + 1 end
      assert(opt[1] == plain[1], "premier arret inchange")
    end
    assert(better > 0, "2-opt n'ameliore jamais")
    local many = {}
    for i = 1, 30 do many[i] = { kind = "pickup", questID = i, x = i, y = 0 } end
    assert(#n.Quests.Order(many, 0, 0) == 12, "au plus 12 arrets")
  end)

  check("Itineraire : prendre avant rendre, sans lieu a la fin", function()
    local n = fresh().n
    local o = n.Quests.Order({ { kind = "turnin", questID = 1, x = 51, y = 50 }, { kind = "pickup", questID = 1, x = 90, y = 90 },
      { kind = "progress", questID = 1, x = 52, y = 50 } }, 50, 50)
    assert(o[1].kind == "pickup" and o[2].kind == "progress" and o[3].kind == "turnin", "ordre par quete")
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    n = questN()
    mock.qquests = { [201] = { name = "Ici", startedBy = { { 9001 } }, objectives = { { { 9001, "Loup" } } } } }
    mock.qlog = { { questID = 202, title = "Loin", objectives = LOUPS }, { questID = 201, title = "Ici", objectives = LOUPS } }
    n.Quests.Refresh()
    local r = n.Quests.Route()
    assert(#r == 2 and r[1].questID == 201 and r[1].x and r[2].questID == 202 and r[2].x == nil, "sans lieu a la fin")
    local b = n.Quests.Best()
    assert(b.questID == r[1].questID and b.detail:find("arrêt 1/2", 1, true), b.detail)
  end)

  check("Itineraire : onglet, rien en combat, rien de stocke", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    mock.qquests = { [202] = { name = "Finie", startedBy = { { 9001 } }, finishedBy = { { 9003 } } } }
    mock.qlog = { { questID = 202, title = "Finie", complete = true } }
    n.Quests.Refresh()
    n.ToggleGuide()
    local G = n.UI.GuideWin
    for i, key in ipairs(TABS) do if key == "route" then G.win.tabs[i].scripts.OnClick(G.win.tabs[i]) end end
    assert(n.db.guide.tab == "route" and G.used == #n.Quests.Rows() and G.used == 1, "onglet Itineraire")
    assert(n.Quests.Rows()[1].text:find("1. ", 1, true) and n.Quests.Rows()[1].go == "N9003")
    mock.inCombat = true
    mock.qlog = nil
    n.Quests.Refresh()
    assert(#n.Quests.Route() == 1, "en combat : le dernier itineraire")
    mock.inCombat = false
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k] or k == "guide", "cle ajoutee a la base : " .. tostring(k)) end
  end)

  check("Reperes de carte : types, bonne carte, option, clic, pool borne", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN()
    n.db.qindex = {}
    mock.qquests = {
      [201] = { name = "En cours", startedBy = { { 9003 } }, objectives = { { { 9001, "Loup" } } } },
      [202] = { name = "Finie", startedBy = { { 9001 } }, finishedBy = { { 9003 } } },
      [301] = { name = "Nouvelle", startedBy = { { 9003 } }, requiredLevel = 15, questLevel = 18 },
    }
    mock.qlog = { { questID = 201, title = "En cours", objectives = LOUPS }, { questID = 202, title = "Finie", complete = true } }
    assert(n.Quests.StartIndex() == true)
    for _ = 1, 5 do mock.flushTimers() end
    local P = n.UI.QuestPins
    mock.worldMap = 1420
    WorldMapFrame:Show()
    P.Update()
    assert(type(WorldMapFrame.hooks.OnShow) == "function" and mock.hooked.OnMapChanged, "accroches de la carte")
    local kinds = {}
    for i = 1, P.shown do local p = P.pins[i] assert(p.shown) kinds[p.data.kind] = p end
    assert(P.shown == 3 and kinds.pickup and kinds.turnin and kinds.progress, "un repere par type : " .. P.shown)
    assert(kinds.turnin.data.questID == 202 and kinds.turnin.data.x == 80 and kinds.progress.data.x == 52)
    assert(kinds.turnin.data.n and kinds.turnin.ring.shown, "arret de l'itineraire : anneau numerote")
    -- clic gauche : repere utilisateur
    mock.waypoint = nil
    kinds.turnin.scripts.OnClick(kinds.turnin)
    assert(mock.waypoint and mock.waypoint.mapID == 1420, "le clic pose le repere")
    -- changement de carte : autre carte sans quete, puis retour
    mock.worldMap = 1458
    mock.hooked.OnMapChanged()
    assert(P.shown == 0 and not kinds.turnin.shown, "autre carte : rien")
    mock.worldMap = 1420
    mock.hooked.OnMapChanged()
    assert(P.shown == 3 and P.pins[1].shown)
    -- option
    n.db.show.questpins = false
    P.Update()
    assert(P.shown == 0 and not P.pins[1].shown, "option decochee : rien")
    n.db.show.questpins = true
    WorldMapFrame:Hide()
    WorldMapFrame.hooks.OnHide()
    assert(P.shown == 0, "carte fermee")
    WorldMapFrame:Show()
    WorldMapFrame.hooks.OnShow()
    assert(P.shown == 3)
    -- combat : rien ne bouge
    mock.inCombat = true
    mock.qlog = nil
    P.Update()
    assert(P.shown == 3, "combat : etat garde")
    mock.inCombat = false
    -- pool borne
    local log = {}
    for i = 1, 70 do
      mock.qquests[400 + i] = { name = "Q" .. i, startedBy = { { 9001 } }, finishedBy = { { 9003 } } }
      log[i] = { questID = 400 + i, title = "Q" .. i, complete = true }
    end
    mock.qlog = log
    n.Quests.Refresh()
    P.Update()
    P.Update()
    assert(P.shown == 60 and #P.pins == 60, "pool de 60 : " .. P.shown .. "/" .. #P.pins)
    assert(not findSecret(n.db, "db") and n.db.questpins == nil)
  end)

  check("Reperes de carte : sans LibQuestieDB, aucun repere", function()
    if not C_QuestLog then return end
    local lib = _G.LibQuestieDB
    _G.LibQuestieDB = nil
    local n = questN()
    mock.qlog = { { questID = 202, title = "Finie", complete = true } }
    mock.worldMap = 1420
    WorldMapFrame:Show()
    n.Quests.Refresh()
    n.UI.QuestPins.Update()
    local shown = n.UI.QuestPins.shown
    _G.LibQuestieDB = lib
    assert(shown == 0, "sans base : aucun repere")
  end)

  ------------------------------------------------------------------------
  -- Cueillette : noeuds d'herbes (QuestieDB Item/Object), boucle rentable, reperes de carte
  ------------------------------------------------------------------------
  -- Tirisfal (area 85 -> carte 1420) : 30 Feuillargent en ligne y = 50, 1 Mage royal, 2 Pacifique, 1 Terrestrine, 1 Algue (rang 85).
  local function herbN(rank, line)
    mock.qitems = { [765] = { name = "Feuillargent", objectDrops = { 1617 } }, [785] = { name = "Mage royal", objectDrops = { 1621 } },
      [2447] = { name = "Pacifique", objectDrops = { 1618 } }, [2449] = { name = "Terrestrine", objectDrops = { 1619 } },
      [3820] = { name = "Algue", objectDrops = { 1620 } }, [8831] = { name = "Inconnue" } }
    local pts = { { -1, -1 } }
    for i = 1, line or 30 do pts[#pts + 1] = { i * 3 % 100, 50 + math.floor(i * 3 / 100) } end
    mock.qobjects = { [1617] = { spawns = { [85] = pts, [1497] = { { 5, 5 } } } }, [1618] = { spawns = { [85] = { { 10, 10 }, { 20, 20 } } } },
      [1619] = { spawns = { [85] = { { 80, 80 } } } }, [1621] = { spawns = { [85] = { { 90, 10 } } } }, [1620] = { spawns = { [85] = { { 50, 52 } } } } }
    mock.ah = { [765] = { 30, 1 }, [785] = { 20, 1 }, [2447] = { 10, 1 }, [2449] = { 5, 1 }, [3820] = { 900, 1 } }
    mock.itemInfo = { [765] = { "Feuillargent", 1, 1, 0 }, [785] = { "Mage royal", 1, 1, 0 }, [2447] = { "Pacifique", 1, 1, 0 },
      [2449] = { "Terrestrine", 1, 1, 0 }, [3820] = { "Algue", 1, 1, 0 } }
    mock.pos, mock.mapID, mock.icons = { 0.5, 0.5 }, 1420, { [765] = 1234 }
    local n = fresh().n
    setState(n, { level = 20, mapID = 1420, zone = 1420, profs = { [182] = { rank = rank or 60, max = 75 } } })
    return n
  end
  local function built(n) n.Gather.StartIndex() for _ = 1, 30 do mock.flushTimers() end return n end

  check("Cueillette : herbes de la carte filtrees par rang, couleur, bonus de rang", function()
    if not (LibQuestieDB and C_Map) then return end
    local n = built(herbN(60))
    local h = n.Gather.Herbs(1420)
    local ids = {}
    for i, e in ipairs(h) do ids[i] = e.itemID end
    assert(table.concat(ids, ",") == "765,785,2447,2449", "rang 60, tri par valeur : " .. table.concat(ids, ","))
    assert(h[1].name == "Feuillargent" and h[1].price == 30 and h[1].value == 45 and #h[1].nodes == 30, "instance (-1) ecartee")
    assert(h[4].color == "yellow" and h[4].skillup and h[3].color == "green" and not h[3].skillup, "couleurs Classic")
    assert(n.Gather.Color(20, 1) == "orange" and n.Gather.Color(200, 100) == "grey")
    assert(#n.Gather.Herbs(1458) == 1, "autre carte : son propre noeud")
    n.State.profs[182].rank = 100
    assert(n.Gather.Herbs(1420)[1].itemID == 3820 and n.Gather.Herbs(1420)[1].skillup, "rang 100 : Algue debloquee, orange")
    mock.ah[2447] = nil
    mock.itemInfo[2447] = nil
    mock.sellPrice = { [2447] = 4 }
    for _, e in ipairs(n.Gather.Herbs(1420)) do if e.itemID == 2447 then assert(e.price == 4, "sans prix HdV : prix marchand") end end
    n.State.profs = { [171] = { rank = 50, max = 75 } }
    assert(#n.Gather.Herbs(1420) == 0, "sans Herboristerie : rien")
    mock.sellPrice = nil
  end)

  check("Cueillette : index par paquets, jamais en combat, en memoire seulement", function()
    if not (LibQuestieDB and C_Map and C_Timer) then return end
    local n = herbN(60)
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    mock.inCombat = true
    assert(n.Gather.StartIndex() == true and n.Gather.StartIndex() == false, "un seul index a la fois")
    for _ = 1, 30 do mock.flushTimers() end
    assert(#n.Gather.Herbs(1420) == 0, "en combat : en pause")
    mock.inCombat = false
    mock.fire("PLAYER_REGEN_ENABLED")
    for k in pairs(n.db) do before[k] = true end -- les autres modules ecrivent a la fin du combat (pace...)
    assert(#n.Gather.Herbs(1420) == 0, "un paquet ne suffit pas")
    for _ = 1, 30 do mock.flushTimers() end
    assert(#n.Gather.Herbs(1420) == 4, "repris apres le combat")
    n.Gather.Loop(1420) n.Gather.Pins(1420)
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
  end)

  check("Cueillette : boucle plus proche voisin, bornee, or par heure, candidat Or", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = built(herbN(60))
    local lp = n.Gather.Loop(1420)
    assert(#lp.stops == 15 and lp.stops[1].x == 51 and lp.stops[1].y == 50 and lp.stops[15].n == 15, "15 arrets, le plus proche d'abord")
    for i = 2, #lp.stops do
      local a, b = lp.stops[i - 1], lp.stops[i]
      assert(math.abs(a.x - b.x) == 3, "voisin le plus proche : " .. a.x .. " -> " .. b.x)
    end
    assert(table.concat(lp.names, ", ") == "Feuillargent, Mage royal, Pacifique", "3 herbes au plus : " .. table.concat(lp.names, ", "))
    assert(lp.total == 15 * 45 and lp.perHour == 45 * n.Gather.NODES_PER_HOUR, "or/heure : " .. lp.perHour)
    local b = n.Gold.Best()
    assert(b.kind == "gather" and b.text:find("^Cueille 15 points à .+ %(Feuillargent, Mage royal, Pacifique%) : boucle ≈ 8 min, ≈ ")
      and b.text:find(n.Prof.Money(675), 1, true), b.text)
    local d = n.Goto.For(b.go)
    assert(d.mapID == 1420 and d.x == 51 and d.y == 50 and d.text:find("Feuillargent, premier point", 1, true), "go : premier noeud")
    mock.pos = false -- position illisible : depart au centre
    assert(n.Gather.Loop(1420).stops[1].x == 51)
  end)

  check("Cueillette : onglet Or, une rangee par herbe avec prix et noeuds", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = built(herbN(60))
    local rows, hit = n.Gold.Rows(), {}
    for _, r in ipairs(rows) do hit[r.text] = r end
    local f = hit["Feuillargent : " .. n.Prof.Money(30) .. " · 30 nœuds"]
    local withGo
    for _, r in ipairs(rows) do withGo = withGo or r.go end
    assert(f and f.icon == 1234 and withGo, "rangee Feuillargent, icone ; candidat avec Repere")
    local t = hit["Terrestrine : " .. n.Prof.Money(5) .. " · 1 nœud"]
    assert(t and t.sub == "donne encore des points d'Herboristerie", "bonus de rang signale")
    assert(not hit["Algue : " .. n.Prof.Money(900) .. " · 1 nœud"], "rang trop bas : pas de rangee")
  end)

  check("Cueillette : reperes d'herbes sur la carte (option, borne, clic, bulle)", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = built(herbN(60))
    local P = n.UI.QuestPins
    mock.worldMap = 1420
    WorldMapFrame:Show()
    P.Update()
    assert(P.herbShown == 34, "noeuds de la carte a ton rang : " .. tostring(P.herbShown))
    local first = P.herbs[1]
    assert(first.data.n == 1 and first.ring.shown and first.width == 12 and first.icon.tex == 1234, "boucle en tete, numerotee, petite icone")
    assert(not P.herbs[16].ring.shown, "hors boucle : sans anneau")
    GameTooltip.lines = nil
    first.scripts.OnEnter(first)
    assert(GameTooltip.lines and GameTooltip.lines[1] == "Feuillargent" and GameTooltip.lines[2] == "≈ " .. n.Prof.Money(30) .. " pièce", "bulle : nom + prix")
    mock.waypoint = nil
    first.scripts.OnClick(first)
    assert(mock.waypoint and mock.waypoint.mapID == 1420 and mock.waypoint.x == 0.51, "clic : repere")
    n.db.show.herbpins = false
    P.Update()
    assert(P.herbShown == 0 and not first.shown, "option decochee")
    n.db.show.herbpins = true
    mock.inCombat = true
    P.Update()
    assert(P.herbShown == 0, "combat : rien ne bouge")
    mock.inCombat = false
    -- borne : 120 Feuillargent
    n = built(herbN(60, 120))
    P = n.UI.QuestPins
    mock.worldMap = 1420
    WorldMapFrame:Show()
    P.Update()
    assert(P.herbShown == 80 and #P.herbs == 80, "pool de 80 : " .. tostring(P.herbShown))
    assert(not findSecret(n.db, "db"))
  end)

  check("Cueillette : case des options", function()
    local n, restore = boot()
    local c, db = controls(n), n.db
    assert(c.herbpins and db.show.herbpins == true, "cochee par defaut")
    click(c.herbpins)
    assert(db.show.herbpins == false, "decochee")
    restore()
  end)

  check("Cueillette : sans LibQuestieDB, rien (ni noeud, ni boucle, ni erreur)", function()
    local lib = _G.LibQuestieDB
    _G.LibQuestieDB = nil
    local n = herbN(60)
    local ok = n.Gather.StartIndex() == false and #n.Gather.Herbs(1420) == 0 and n.Gather.Loop(1420) == nil and #n.Gather.Pins(1420) == 0
    local b = n.Gold.Best()
    _G.LibQuestieDB = lib
    assert(ok, "listes vides")
    assert(b.kind ~= "gather" or not b.text:find("Boucle", 1, true), "pas de boucle")
    if lib then
      local keep = lib.Item
      lib.Item = nil
      local n2 = herbN(60)
      assert(n2.Q.Item(765, "name") == nil and n2.Gather.StartIndex() == true, "Item absent : nil sans erreur")
      for _ = 1, 30 do mock.flushTimers() end
      lib.Item = keep
      assert(#n2.Gather.Herbs(1420) == 0)
    end
  end)
  -- Valeur des quetes : or et XP par minute, focus, quete a abandonner ; meilleure recompense (UI.QuestReward)
  ------------------------------------------------------------------------
  check("Valeur : estimation XP par niveau et penalite grise (80, 60, 40, 20, 10 %)", function()
    local n = fresh().n
    local xp, money = n.Quests.Estimate(10, 10)
    assert(xp == 650 and money == 300, xp .. " / " .. money)
    for gap, pct in pairs({ [5] = 1, [6] = 0.8, [7] = 0.6, [8] = 0.4, [9] = 0.2, [10] = 0.1, [15] = 0.1 }) do
      assert(n.Quests.Estimate(10, 10 + gap) == math.floor(650 * pct + 0.5), "ecart " .. gap)
    end
    assert(select(2, n.Quests.Estimate(10, 20)) == 300, "l'argent n'est pas penalise")
  end)

  -- journal de quetes au PNJ 9001 (tout pres), `left` monstres restants chacune
  local function valueLog(ids, left)
    local log = {}
    mock.qquests = mock.qquests or {}
    for i, id in ipairs(ids) do
      mock.qquests[id] = mock.qquests[id] or { name = "Q" .. id, startedBy = { { 9001 } }, objectives = { { { 9001, "Loup" } } } }
      log[i] = { questID = id, title = mock.qquests[id].name,
        objectives = { { text = "Loups", numFulfilled = 0, numRequired = left or 5, finished = false } } }
    end
    mock.qlog = log
  end

  check("Valeur : calibration en memoire par la mediane reel/estime du journal", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetQuestLogRewardXP) then return end
    local n = questN(20)
    mock.qquests = {}
    for _, id in ipairs({ 201, 202, 203 }) do mock.qquests[id] = { name = "Q" .. id, startedBy = { { 9001 } }, questLevel = 20 } end
    valueLog({ 201, 202, 203 })
    mock.qreward = { [201] = { 3300, 2400 }, [202] = { 3300, 2400 }, [203] = { 1650, 1200 } } -- estime : 1650 XP, 12 pa
    n.Quests.Refresh()
    n.Quests.Route()
    local cx, cm = n.Quests.Calib()
    assert(cx == 2 and cm == 2, cx .. " / " .. cm)
    assert(n.Quests.Estimate(20, 20) == 3300, "estimation recalee")
    assert(n.Quests.Best().detail:find("≈ 3300 XP", 1, true), n.Quests.Best().detail)
    mock.qreward[201] = { mock.SECRET, mock.SECRET } -- secret : ignore
    n.Quests.Refresh()
    n.Quests.Route()
    assert(n.Quests.Calib() == 1.5, "mediane de 2 et 1 : " .. n.Quests.Calib())
    mock.qlog = nil
    n.Quests.Refresh()
    n.Quests.Route()
    assert(n.Quests.Calib() == 1, "journal vide : pas de calibration")
    assert(not findSecret(n.db, "db"))
  end)

  check("Valeur : le focus or ou XP choisit les quetes retenues (score par minute)", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetQuestLogRewardXP) then return end
    local n = questN(20)
    mock.qquests, mock.qreward = {}, {}
    local ids = {}
    for i = 1, 13 do ids[i] = 200 + i mock.qreward[200 + i] = { 100, 3000 } end
    mock.qreward[213] = { 6000, 0 } -- beaucoup d'XP, pas d'or
    valueLog(ids)
    local function has(id) for _, s in ipairs(n.Quests.Route()) do if s.questID == id then return s end end end
    n.Quests.Refresh()
    assert(#n.Quests.Route() == 12 and not has(213), "focus or (defaut) : la quete a XP sort des 12 arrets")
    n.db.guide.focus = "xp"
    n.Quests.Refresh()
    local s = has(213)
    assert(s and s.v.xp == 6000 and s.v.gold == 0, "focus XP : elle revient")
    n.db.guide.focus = "balanced"
    n.Quests.Refresh()
    assert(has(213), "equilibre : 6000 XP valent plus que 30 pa")
    n.db.guide.focus = nil
    n.Quests.Refresh()
    local rows = n.Quests.Rows()
    assert(rows[1].sub:find("≈ 100 XP", 1, true) and rows[1].sub:find("/min", 1, true), rows[1].sub)
  end)

  check("Valeur : quete du journal a abandonner (grise, rapporte peu), conseil seulement", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = questN(30)
    mock.qquests = {
      [201] = { name = "Vieille", startedBy = { { 9001 } }, objectives = { { { 9001, "Loup" } } }, questLevel = 20 },
      [202] = { name = "Bonne", startedBy = { { 9001 } }, objectives = { { { 9001, "Loup" } } }, questLevel = 30 },
      [203] = { name = "Finie", startedBy = { { 9001 } }, questLevel = 15 },
    }
    valueLog({ 201, 202 })
    mock.qlog[3] = { questID = 203, title = "Finie", complete = true } -- grise mais a rendre : jamais a abandonner
    n.Quests.Refresh()
    local rows = n.Quests.Rows()
    assert(rows[#rows].text == "À abandonner : Vieille (grise)", rows[#rows].text)
    assert(n.Quests.Route().drop.questID == 201)
    mock.qquests[201].questLevel = 30
    valueLog({ 201, 202 })
    mock.qlog[1].objectives[1].numRequired = 60 -- 60 monstres pour la meme recompense
    n.Quests.Refresh()
    rows = n.Quests.Rows()
    assert(rows[#rows].text == "À abandonner : Vieille (rapporte peu)", rows[#rows].text)
    valueLog({ 201, 202 })
    n.Quests.Refresh()
    assert(n.Quests.Route().drop == nil and not n.Quests.Rows()[#n.Quests.Rows()].text:find("abandonner"), "rien a abandonner")
    assert(#n.Quests.Route() == 2, "l'addon n'abandonne rien")
  end)

  check("Recompense : la recompense au choix qui vaut le plus d'or est marquee", function()
    local n = fresh().n
    local R = n.UI.QuestReward
    mock.choices, mock.questID = { { 1001, 1 }, { 1002, 5 }, { 1003, 1 } }, 555
    mock.ah = { [1001] = { 5000, 1 }, [1002] = { 2000, 1 } } -- 1002 x5 = 1 po
    mock.sellPrice = { [1003] = 7000 }
    local function done() mock.choices, mock.questID, mock.sellPrice, mock.inCombat = nil, nil, nil, false mock.ah = { [2589] = { 120, 3 } } end
    if not GetNumQuestChoices then
      R.Update()
      done()
      assert(R.Best() == nil and R.shown == nil, "API absente : rien")
      return
    end
    R.Update()
    local want = Auctionator and 2 or 3 -- sans Auctionator : prix marchand seul
    assert(R.shown == want, "marquee : " .. tostring(R.shown))
    mock.fire("QUEST_COMPLETE")
    assert(#n.QuestDB.Choices(555) == 3 and n.QuestDB.Choices(555)[2][2] == 5, "choix appris par la base")
    mock.ah = {}
    R.Update()
    assert(R.shown == 3, "sans prix HdV : prix marchand")
    n.db.show.questreward = false
    R.Update()
    assert(R.shown == nil, "option decochee")
    n.db.show.questreward = true
    mock.choices = { { 1003, 1 } }
    R.Update()
    assert(R.shown == nil, "un seul choix : pas de marque")
    mock.choices = { { 1001, 1 }, { 1003, 1 } }
    mock.inCombat = true
    R.Update()
    assert(R.shown == nil, "rien en combat")
    done()
    R.Hide()
    assert(not findSecret(n.db, "db") and n.db.questreward == nil and n.db.seen == nil)
  end)

  check("Valeur : focus dans les options, defauts, rien de secret ni de nouveau dans la base", function() isolated(function()
    local n, restore = boot() -- isole : ADDON_LOADED n'atteint pas les ns des tests precedents
    assert(n.db.guide.focus == "gold" and n.db.show.questreward == true, "defauts")
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    local c = controls(n)
    assert(c.focus and c.questreward, "controles")
    click(c.focus)
    assert(n.db.guide.focus == "balanced")
    click(c.focus)
    click(c.focus)
    assert(n.db.guide.focus == "gold", "cycle or -> equilibre -> XP -> or")
    if C_QuestLog and C_Map and LibQuestieDB then
      mock.pos, mock.mapID = { 0.5, 0.5 }, 1420
      mock.qnpcs[9001] = { 0, "", "H", 85, { [85] = { { 52, 50 } } } }
      n.State.level, n.State.mapID = 20, 1420
      mock.qquests = { [201] = { name = "Q", startedBy = { { 9001 } }, questLevel = 20 } }
      valueLog({ 201 })
      mock.qreward = { [201] = { mock.SECRET, mock.SECRET } }
      n.Quests.Refresh()
      local r = n.Quests.Route()
      assert(r[1] and r[1].v and r[1].v.xp == 1650 and not findSecret(r, "route"), "secret : estimation")
      mock.inCombat = true
      mock.qlog = nil
      n.Quests.Refresh()
      assert(n.Quests.Route() == r, "en combat : le dernier resultat")
      mock.inCombat = false
    end
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
    mock.qinit()
    mock.qreward, mock.pos = nil, nil
    restore()
  end) end)

  ------------------------------------------------------------------------
  -- Base de recompenses apprise (QuestDB)
  ------------------------------------------------------------------------
  check("QuestDB : apprend de la fenetre, du journal et de QUEST_TURNED_IN (prioritaire), jamais un secret", function()
    local n = fresh().n
    local DB = n.QuestDB
    n.State.level = 10
    if GetRewardXP then
      mock.questID, mock.rewardXP, mock.rewardMoney = 700, 650, 300
      mock.rewards, mock.choices = { { 2001, 1 } }, { { 1001, 1 }, { 1002, 5 } }
      mock.fire("QUEST_DETAIL")
      local r = DB.Get(700)
      assert(r and r.xp == 650 and r.money == 300 and r.level == 10 and not r.exact, "QUEST_DETAIL")
      assert(DB.Choices(700)[2][1] == 1002 and DB.Choices(700)[2][2] == 5 and DB.Fixed(700)[1][1] == 2001, "objets")
      mock.rewardXP = 700
      mock.fire("QUEST_COMPLETE")
      assert(DB.Get(700).xp == 700, "QUEST_COMPLETE")
      mock.rewardXP, mock.rewardMoney = mock.SECRET, mock.SECRET
      mock.fire("QUEST_COMPLETE")
      assert(DB.Get(700).xp == 700 and DB.Get(700).money == 300, "secret ignore")
      mock.questID, mock.rewardXP, mock.rewardMoney, mock.rewards, mock.choices = 701, 100, 0, nil, nil
      mock.fire("QUEST_DETAIL")
      assert(DB.Get(701).money == 0 and #DB.Choices(701) == 0, "0 cuivre est une vraie valeur ; aucun choix")
      mock.questID, mock.rewardXP = 702, 50
      mock.inCombat = true
      mock.fire("QUEST_DETAIL")
      mock.inCombat = false
      assert(DB.Get(702) == nil, "rien en combat")
    end
    if C_QuestLog and GetQuestLogRewardXP then
      mock.qlog = { { questID = 800, level = 12 }, { questID = 801, level = 12 }, { questID = 802 } }
      mock.qreward = { [800] = { 500, 40 }, [801] = { 900, 0 }, [802] = { mock.SECRET, mock.SECRET } }
      mock.fire("QUEST_LOG_UPDATE")
      mock.fire("QUEST_LOG_UPDATE")
      assert(DB.Get(800) == nil, "regroupe : pas de lecture avant le delai")
      mock.flushTimers()
      assert(DB.Get(800).xp == 500 and DB.Get(800).money == 40 and DB.Get(800).ql == 12, "journal")
      assert(DB.Get(801).xp == 900 and DB.Get(801).money == nil, "argent 0 du journal : inconnu")
      assert(DB.Get(802) == nil, "journal secret ignore")
      mock.qlog, mock.qreward = nil, nil
    end
    mock.fire("QUEST_TURNED_IN", 700, 640, 310)
    local r = DB.Get(700)
    assert(r.xp == 640 and r.money == 310 and r.exact, "QUEST_TURNED_IN")
    if GetRewardXP then
      mock.questID, mock.rewardXP, mock.rewardMoney = 700, 999, 999
      mock.fire("QUEST_DETAIL")
      assert(DB.Get(700).xp == 640 and DB.Get(700).money == 310, "la valeur exacte n'est pas ecrasee")
    end
    mock.fire("QUEST_TURNED_IN", 700, mock.SECRET, mock.SECRET)
    mock.fire("QUEST_TURNED_IN", 703, mock.SECRET, mock.SECRET)
    assert(DB.Get(700).xp == 640 and DB.Get(703) == nil, "TURNED_IN secret ignore")
    mock.questID, mock.rewardXP, mock.rewardMoney, mock.rewards, mock.choices = nil, nil, nil, nil, nil
    assert(n.db.qrewards.v == 1 and not findSecret(n.db, "db"), "version de format, rien de secret")
    local total, withXP = DB.Stats()
    assert(total >= 1 and withXP >= 1)
  end)

  check("QuestDB : taille bornee, les plus anciennes quetes partent", function()
    local n = fresh().n
    local DB = n.QuestDB
    assert(DB.MAX == 4000)
    DB.MAX = 5
    for i = 1, 12 do DB.Learn(i, { xp = 100 + i }) end
    local total = DB.Stats()
    assert(total <= 5 and total >= 3, "borne : " .. total)
    assert(DB.Get(12) and DB.Get(1) == nil, "la plus recente reste, la plus ancienne part")
    DB.Learn(12, { xp = 1 }) -- une mise a jour ne grossit pas
    assert(DB.Stats() == total)
    n.db.qrewards = { v = 99, q = {} }
    assert(DB.Get(12) == nil and DB.Stats() == 0, "format inconnu : ignore")
    DB.Learn(5, { xp = 7 })
    assert(n.db.qrewards.v == 1 and DB.Get(5).xp == 7, "format inconnu : repart a neuf")
  end)

  check("QuestDB : Quests prend la valeur apprise avant le journal et l'estimation, grise ajustee", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetQuestLogRewardXP) then return end
    local n = questN(20)
    local DB = n.QuestDB
    mock.qquests = { [201] = { name = "Q201", startedBy = { { 9001 } }, questLevel = 20 } }
    valueLog({ 201 })
    mock.qreward = { [201] = { 1000, 50 } } -- le journal dit autre chose
    DB.Learn(201, { xp = 3300, money = 2400, ql = 20 })
    n.Quests.Refresh()
    local v = n.Quests.Route()[1].v
    assert(v.xp == 3300 and v.gold == 2400, "appris : " .. v.xp .. " / " .. v.gold)
    n.State.level = 26 -- ecart 1 : 80 % de l'XP
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.xp == 2640, "XP ajustee au niveau : " .. n.Quests.Route()[1].v.xp)
    n.State.level = 20
    mock.qreward = { [202] = { 1650, 12 } } -- quete 202 jamais apprise : journal
    valueLog({ 202 })
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.xp == 1650, "journal puis estimation")
    mock.qlog, mock.qreward = nil, nil
    -- calibration : les valeurs apprises comptent comme echantillons
    DB.Learn(301, { xp = 3300, money = 2400, ql = 20 })
    DB.Learn(302, { xp = 3300, money = 2400, ql = 20 })
    n.Quests.Refresh()
    n.Quests.Route()
    local cx, cm = n.Quests.Calib()
    assert(cx == 2 and cm == 2, "calibration apprise : " .. cx .. " / " .. cm)
    assert(not findSecret(n.db, "db"))
  end)

  check("QuestDB : les choix appris donnent la meilleure recompense d'une quete jamais vue ce soir", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetNumQuestChoices) then return end
    local n = questN(20)
    mock.qquests = { [201] = { name = "Q201", startedBy = { { 9001 } }, questLevel = 20 } }
    valueLog({ 201 })
    mock.qreward = { [201] = { 1650, 100 } }
    mock.ah, mock.sellPrice = {}, { [1001] = 100, [1002] = 50 }
    mock.questID, mock.choices = 201, { { 1001, 1 }, { 1002, 5 } } -- 100 contre 5 x 50
    mock.fire("QUEST_COMPLETE")
    mock.choices, mock.questID = nil, nil -- fenetre fermee : seule la base se souvient
    n.Quests.Refresh()
    local v = n.Quests.Route()[1].v
    assert(v.gold == 100 + 250, "meilleur choix appris : " .. v.gold)
    mock.ah, mock.sellPrice = { [2589] = { 120, 3 } }, nil
    assert(n.Quests.seen == nil, "Quests.seen supprime")
  end)

  ------------------------------------------------------------------------
  -- Pistes de farm (Farm.lua)
  ------------------------------------------------------------------------
  local function farmN(level)
    mock.qitems = { [2589] = { name = "Lin", npcDrops = { 9101, 9102, 9103, 9104 } }, [7067] = { name = "Terre", npcDrops = { 9105 } },
      [4306] = { name = "Soie" } }
    mock.qnpcs[9101] = { 0, nil, nil, 85, { [85] = { { 20, 20 }, { 22, 24 }, { 25, 21 }, { -1, -1 }, { 80, 80 } } }, "Loup", 10, 12 }
    mock.qnpcs[9102] = { 0, nil, "H", 85, { [85] = { { 50, 50 }, { 51, 50 }, { 52, 50 }, { 53, 50 }, { 54, 50 }, { 55, 50 } } }, "Garde", 10, 10 }
    mock.qnpcs[9103] = { 0, nil, nil, 85, { [85] = { { 50, 50 }, { 51, 50 }, { 52, 50 }, { 53, 50 }, { 54, 50 }, { 55, 50 } } }, "Ogre", 30, 32 }
    mock.qnpcs[9104] = { 0, nil, "A", 85, { [85] = { { 21, 22 } } }, "Sanglier" } -- niveaux inconnus
    mock.qnpcs[9105] = { 0, nil, nil, 85, { [85] = { { 60, 60 } } }, "Elementaire", 11, 11 }
    mock.ah = { [2589] = { 120, 1 } }
    mock.mapID = 1420
    local n = fresh().n
    setState(n, { level = level or 12, mapID = 1420, zone = 1420 })
    return n
  end
  local function farmBuilt(n) n.Farm.StartIndex() for _ = 1, 30 do mock.flushTimers() end return n end

  check("Farm : filtre niveau, faction et instance, case dense, score, prix inconnu", function()
    if not (LibQuestieDB and C_Map) then return end
    local n = farmBuilt(farmN(12))
    local r = n.Farm.Rows(1420)
    assert(#r == 2 and r[1].itemID == 2589 and r[2].itemID == 7067, "Lin d'abord (score), puis Terre sans prix")
    assert(r[1].density == 4 and r[1].score == 480 and r[1].price == 120, "densite x prix : " .. r[1].density .. " / " .. r[1].score)
    assert(#r[1].creatures == 2 and r[1].creatures[1].name == "Loup" and r[1].creatures[1].points == 3, "garde amical et ogre ecartes")
    assert(r[1].levelKnown == false and r[2].levelKnown == true, "niveau inconnu signale")
    assert(r[1].go.mapID == 1420 and r[1].go.x == 22 and r[1].go.y == 21.75, "centre de la case : " .. r[1].go.x .. "," .. r[1].go.y)
    assert(r[1].text:find("Loup", 1, true) and r[1].text:find("niv 10-12", 1, true), r[1].text)
    assert(r[2].price == nil and r[2].score == 0 and r[2].text:find("prix inconnu, scanne l'HdV", 1, true), r[2].text)
    assert(n.Farm.Best(1420).itemID == 2589 and #n.Farm.Rows(1458) == 0, "autre carte : rien")
    n.State.level = 31
    local hi = n.Farm.Rows(1420)
    assert(hi[1].itemID == 2589 and hi[1].creatures[1].name == "Ogre" and hi[1].density == 6, "niveau 31 : l'ogre, pas le loup")
  end)

  check("Farm : index par paquets, jamais en combat, en memoire seulement", function()
    if not (LibQuestieDB and C_Map and C_Timer) then return end
    local n = farmN(12)
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    mock.inCombat = true
    assert(n.Farm.StartIndex() == true and n.Farm.StartIndex() == false, "un seul index a la fois")
    for _ = 1, 30 do mock.flushTimers() end
    assert(#n.Farm.Rows(1420) == 0, "en combat : en pause")
    mock.inCombat = false
    mock.fire("PLAYER_REGEN_ENABLED")
    for k in pairs(n.db) do before[k] = true end
    assert(#n.Farm.Rows(1420) == 0, "un paquet ne suffit pas")
    for _ = 1, 30 do mock.flushTimers() end
    assert(#n.Farm.Rows(1420) == 2, "repris apres le combat")
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
  end)

  check("Farm : sans LibQuestieDB, rien (ni piste, ni erreur)", function()
    local lib = _G.LibQuestieDB
    _G.LibQuestieDB = nil
    local n = farmN(12)
    local ok = n.Farm.StartIndex() == false and #n.Farm.Rows(1420) == 0 and n.Farm.Best(1420) == nil
    _G.LibQuestieDB = lib
    assert(ok, "listes vides")
    if lib then
      local keep = lib.Item
      lib.Item = nil
      local n2 = farmN(12)
      assert(n2.Farm.StartIndex() == true)
      for _ = 1, 30 do mock.flushTimers() end
      lib.Item = keep
      assert(#n2.Farm.Rows(1420) == 0)
    end
  end)

  ------------------------------------------------------------------------
  -- Invariants de coherence du guide (une seule verite entre rangees)
  ------------------------------------------------------------------------
  check("Coherence : or trie au cuivre/min, cueillette en route, une seule destination, rien de garde ni vendu", function()
    if not (C_QuestLog and C_Map and LibQuestieDB) then return end
    local n = built(herbN(60))
    mock.qquests = { [201] = { name = "Q201", startedBy = { { 9001 } }, questLevel = 20 } }
    valueLog({ 201 })
    mock.money = 5000000
    n.Quests.Refresh()
    local c = n.Gold.Candidates()
    for i = 2, #c do assert(c[i - 1].perMin >= c[i].perMin, "(d) tri par cuivre/min") end
    local hasRoute = false
    for _, s in ipairs(n.Quests.Route()) do if s.here and s.x then hasRoute = true end end
    assert(hasRoute, "(e) l'itineraire du scenario a un arret localise sur la carte")
    local function pick(list, f) for _, a in ipairs(list) do if f(a) then return a end end end
    local along = pick(c, function(a) return a.kind == "gather" and a.along end)
    assert(along and along.text:find("en route", 1, true) and not along.go, "(e) cueille en route : " .. tostring(along and along.text))
    assert(not pick(c, function(a) return a.kind == "gather" and a.go end), "(e) pas de boucle concurrente")
    -- cas inverse : une boucle bien plus rentable que l'itineraire de quetes est proposee a la place
    mock.ah[765] = { 1000000, 1 }
    local c2 = n.Gold.Candidates()
    assert(not pick(c2, function(a) return a.along end), "(e) boucle > 1,5 x quete : pas de cueillette en route")
    assert(pick(c2, function(a) return a.kind == "gather" and a.go end), "(e) la boucle est proposee")
    mock.ah[765] = { 30, 1 }
    local primary = 0
    for _, g in ipairs(n.Guide.Goals()) do if g.go and g.primary ~= false then primary = primary + 1 end end
    local far = 0
    for _, g in ipairs(n.Guide.Goals()) do if g.go and g.primary == false then far = far + 1 end end
    assert(primary <= 1 or far == 0, "(c) au plus une destination principale : " .. primary)
    -- (a) rien de garde ET vendu : un objet a crafter n'est jamais propose a la vente
    mock.items, mock.sellPrice = { [765] = 8 }, { [765] = 2 }
    n.Sell.Scan()
    for _, l in ipairs(n.Sell.Lines) do
      local v = n.Keep.Verdict(l.itemID, l.count)
      assert(v.keep == 0 or l.count <= v.rest, "(a) garde et vendu : " .. l.itemID)
    end
    mock.items, mock.sellPrice, mock.money = nil, nil, nil
    assert(not findSecret(n.db, "db"), "(f) rien de secret dans db")
  end)

  check("Coherence : reserve d'argent, achat refuse avec raison, cout inconnu signale sans estimation", function()
    local n = fresh().n
    mock.money = 1000
    local r = n.Budget.Reserve()
    assert(r.money == 1000 and r.spell >= 0 and r.rank == 0, "(f) rang de metier : cout inconnu, jamais invente")
    local ok = n.Budget.Check("comps", 1)
    assert(ok == true or ok == false)
    -- (b) un sort a payer chez le maitre bloque un achat que l'argent seul permettrait
    n.db.trainer = { ["Sort1|"] = { cost = 900, category = "available" } }
    local real = n.Training.Plan
    n.Training.Plan = function() return { pending = { {} }, known = 900, unknown = 1, total = 900 } end
    local ok2, why = n.Budget.Check("recipe", 500)
    assert(ok2 == false and why:find("garde", 1, true) and why:find("sorts", 1, true), "(b) achat refuse avec raison : " .. tostring(why))
    assert(n.Budget.Check("spell", 500) == true, "les sorts passent en premier")
    local rr = n.Budget.Reserve()
    local flagged = false
    for _, u in ipairs(rr.unknown) do if u:find("coût inconnu", 1, true) then flagged = true end end
    assert(flagged, "(f) un sort au cout inconnu est signale")
    n.Training.Plan = real
    mock.money = 5
    local ok3, why3 = n.Budget.Check("comps", 100)
    assert(ok3 == false and why3:find("manque", 1, true), "(b) il te manque : " .. tostring(why3))
    mock.moneySecret = true
    assert(n.Budget.Check("comps", 100) == true, "argent secret : rien a prouver")
    mock.moneySecret, mock.money = nil, nil
    assert(not findSecret(n.db, "db"))
  end)

  ------------------------------------------------------------------------
  -- Or mesure par activite (Earnings.lua)
  local function earnN()
    mock.money, mock.moneySecret, mock.qlog, mock.items, mock.time = 100, nil, nil, nil, 1000
    local n = fresh().n
    mock.fire("PLAYER_MONEY") -- premiere lecture : reference, rien a compter
    mock.fire("BAG_UPDATE_DELAYED")
    return n
  end
  local function gain(d) mock.money = mock.money + d mock.fire("PLAYER_MONEY") end
  local function act(n, a) local s = n.db.earn and n.db.earn.act[a] return s and s.c or 0 end

  check("Earn : chaque variation d'argent va dans l'activite du contexte", function()
    local n = earnN()
    mock.fire("MERCHANT_SHOW") gain(50) gain(-30) mock.fire("MERCHANT_CLOSED")
    assert(act(n, "marchand") == 50 and act(n, "depenses") == 30, "marchand/depenses")
    mock.fire("MAIL_SHOW") gain(7) mock.fire("MAIL_CLOSED")
    mock.fire("AUCTION_HOUSE_SHOW") gain(3) mock.fire("AUCTION_HOUSE_CLOSED")
    assert(act(n, "hdv") == 10, "courrier + HdV : " .. act(n, "hdv"))
    mock.fire("QUEST_TURNED_IN") mock.time = 1001 gain(200)
    assert(act(n, "quetes") == 200, "quete rendue")
    mock.time = 1004 gain(5)
    assert(act(n, "quetes") == 200 and act(n, "autre") == 5, "hors fenetre de 2 s : autre")
    mock.fire("LOOT_OPENED") gain(9) mock.fire("LOOT_CLOSED")
    assert(act(n, "butin") == 9, "butin")
    gain(-4) -- maitre, reparation : une perte est une depense
    assert(act(n, "depenses") == 34, "depenses")
    assert(not findSecret(n.db, "db"))
  end)

  check("Earn : valeur secrete ignoree, rien de secret en db, format inconnu reparti de zero", function()
    local n = earnN()
    mock.moneySecret = true
    mock.fire("PLAYER_MONEY") mock.fire("MERCHANT_SHOW") mock.fire("PLAYER_MONEY")
    mock.moneySecret = nil
    mock.money = 160 mock.fire("PLAYER_MONEY") -- compte depuis la derniere valeur lisible (100)
    assert(act(n, "marchand") == 60, "delta depuis la derniere lecture : " .. act(n, "marchand"))
    assert(not findSecret(n.db, "db"))
    n.db.earn = { v = 0, act = { quetes = { c = 99, s = 99 } } }
    gain(1)
    assert(n.db.earn.v == 1 and act(n, "quetes") == 0, "ancien format : reparti de zero")
    n.db.earn.act.bidon = { c = 1, s = 1 }
    gain(1)
    assert(n.db.earn.act.bidon == nil, "activite inconnue : retiree")
  end)

  check("Earn : temps actif des quetes (journal en cours + mouvement ou combat) et de la cueillette", function()
    local n = earnN()
    n.Earn.Tick()
    mock.time = 1005 n.Earn.Tick()
    assert((n.db.earn.act.quetes or { s = 0 }).s == 0, "sans quete en cours : pas de temps")
    if not C_QuestLog then return end
    mock.qlog = { { questID = 1, title = "Q", level = 5, complete = false } }
    mock.time = 1010 n.Earn.Tick() -- journal relu, mais le joueur est immobile
    mock.time = 1015 n.Earn.Tick()
    assert((n.db.earn.act.quetes or { s = 0 }).s == 0, "immobile hors combat : pas de temps")
    mock.setCombat(true) mock.time = 1020 n.Earn.Tick() mock.setCombat(false)
    assert(n.db.earn.act.quetes.s == 5, "combat : 5 s")
    mock.qlog[1].complete = true
    mock.time = 1025 n.Earn.Tick() mock.setCombat(true) mock.time = 1030 n.Earn.Tick() mock.setCombat(false)
    assert(n.db.earn.act.quetes.s == 5, "quete terminee : plus de temps (journal relu hors combat)")
    mock.time = 1100 n.Earn.Tick() -- pause de 70 s : ne compte pas
    assert(n.db.earn.act.quetes.s == 5)
  end)

  check("Earn : rendement et noeuds par heure mesures, seuil d'echantillon, hors marchand et courrier", function()
    local n = earnN()
    if not GetItemCount then -- passe « absentes » : rien n'est lisible, rien n'est compte, sans erreur
      mock.fire("LOOT_OPENED") mock.fire("BAG_UPDATE_DELAYED") mock.fire("LOOT_CLOSED")
      assert(n.Earn.Yield() == nil and n.db.earn.nodes == 0)
      return
    end
    mock.sellPrice, mock.itemInfo, mock.ah = 4, nil, {}
    local function node(k) -- un noeud : butin, herbes dans les sacs, 30 s de trajet (3 ticks)
      mock.fire("LOOT_OPENED")
      mock.items = { [2447] = (mock.items and mock.items[2447] or 0) + k }
      mock.fire("BAG_UPDATE_DELAYED") mock.fire("BAG_UPDATE_DELAYED")
      mock.fire("LOOT_CLOSED")
      for _ = 1, 3 do mock.time = mock.time + 10 n.Earn.Tick() end
    end
    for i = 1, 14 do node(i % 2 + 1) end
    assert(n.db.earn.nodes == 14 and n.Earn.Yield() == nil and n.Earn.NodesPerHour() == nil, "14 noeuds : pas assez")
    node(2) node(1)
    local e = n.db.earn
    assert(e.nodes == 16 and e.herbs == 24, "noeuds/herbes : " .. e.nodes .. "/" .. e.herbs)
    assert(math.abs(n.Earn.Yield() - 1.5) < 1e-9, "rendement")
    local nph = n.Earn.NodesPerHour()
    assert(nph and nph > 100 and nph < 150, "noeuds/h : " .. tostring(nph))
    if C_Item then assert(e.act.cueillette.c == 24 * 4, "valeur des herbes : " .. e.act.cueillette.c) end
    -- achat chez le marchand, courrier, ou herbe ramassee longtemps apres le butin : ne comptent pas
    mock.fire("MERCHANT_SHOW") mock.items[2447] = mock.items[2447] + 5 mock.fire("BAG_UPDATE_DELAYED") mock.fire("MERCHANT_CLOSED")
    mock.fire("MAIL_SHOW") mock.items[2447] = mock.items[2447] + 5 mock.fire("BAG_UPDATE_DELAYED") mock.fire("MAIL_CLOSED")
    mock.time = mock.time + 60 mock.items[2447] = mock.items[2447] + 5 mock.fire("BAG_UPDATE_DELAYED")
    mock.items[2447] = mock.items[2447] - 8 mock.fire("BAG_UPDATE_DELAYED") -- vente : une baisse ne compte pas
    assert(e.nodes == 16 and e.herbs == 24, "hors butin : inchange")
    -- en combat : differe, sans erreur
    mock.setCombat(true) mock.fire("LOOT_OPENED") mock.items[2447] = mock.items[2447] + 2 mock.fire("BAG_UPDATE_DELAYED")
    assert(e.nodes == 16, "en combat : rien tout de suite")
    mock.setCombat(false) mock.fire("PLAYER_REGEN_ENABLED") mock.fire("LOOT_CLOSED")
    assert(e.nodes == 17 and e.herbs == 26, "repris apres le combat")
    assert(not findSecret(n.db, "db"))
  end)

  check("Earn : Gather utilise la mesure quand elle existe, sinon les constantes", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = built(herbN(60))
    assert(n.Gather.Loop(1420).perHour == 45 * n.Gather.NODES_PER_HOUR, "sans mesure : constantes")
    n.db.earn = { v = 1, act = { cueillette = { c = 0, s = 3600 } }, herbs = 60, nodes = 30 } -- rendement 2, 30 noeuds/h
    assert(n.Earn.Yield() == 2 and n.Earn.NodesPerHour() == 30)
    local lp = n.Gather.Loop(1420)
    assert(n.Gather.Herbs(1420)[1].value == 60 and lp.total == 15 * 60 and lp.perHour == 60 * 30, "mesure : " .. lp.perHour)
  end)

  check("Earn : PerHour, Rows, Text", function()
    local n = earnN()
    assert(n.Earn.PerHour("quetes") == nil and #n.Earn.Rows() == 0 and n.Earn.Text():find("pas encore", 1, true))
    n.db.earn = { v = 1, act = { quetes = { c = 100000, s = 3600 }, cueillette = { c = 50000, s = 1800 }, marchand = { c = 70, s = 0 },
      butin = { c = 5, s = 599 } }, herbs = 0, nodes = 0 }
    assert(n.Earn.PerHour("quetes") == 100000 and n.Earn.PerHour("cueillette") == 100000, "or/h")
    assert(n.Earn.PerHour("butin") == nil and n.Earn.PerHour("marchand") == nil and n.Earn.PerHour("inconnue") == nil, "moins de 10 min : nil")
    local rows = n.Earn.Rows()
    assert(#rows == 4 and rows[1].activity == "quetes" and rows[1].perHour == 100000 and rows[1].total == 100000 and rows[1].secs == 3600
      and rows[2].activity == "cueillette" and rows[4].activity == "butin" and rows[4].perHour == nil, "lignes")
    assert(n.Earn.Text() == "Tes chiffres : quêtes ≈ " .. n.Prof.Money(100000) .. "/h, cueillette ≈ " .. n.Prof.Money(100000) .. "/h", n.Earn.Text())
    n.db.earn.act.cueillette.s = 100
    assert(n.Earn.Text():find("cueillette ≈ …", 1, true), "cueillette pas mesuree")
  end)

  check("Earn : rien ne casse en combat", function()
    local n = earnN()
    mock.setCombat(true)
    mock.fire("PLAYER_MONEY") mock.fire("BAG_UPDATE_DELAYED") mock.fire("LOOT_OPENED") mock.fire("LOOT_CLOSED") n.Earn.Tick()
    gain(10)
    mock.setCombat(false)
    mock.fire("PLAYER_REGEN_ENABLED")
    assert(act(n, "autre") == 10 and not findSecret(n.db, "db"))
  end)

  ------------------------------------------------------------------------
  -- Devenir riche : pistes actionnables, farm, prix conseille, butin en quete, onglet, rangee Or
  ------------------------------------------------------------------------
  check("Riche : prix de depart conseille (HdV moins 1 pc, sinon marchand)", function()
    local n = fresh().n
    assert(n.Gold.Ask(1000, 10) == 999 and n.Gold.Ask(5, nil) == 4, "HdV - 1 pc")
    assert(n.Gold.Ask(11, 10) == nil and n.Gold.Ask(10, 10) == nil, "pas plus haut que le marchand : vends au marchand")
    assert(n.Gold.Ask(nil, 10) == nil and n.Gold.Ask(0, 0) == nil, "prix inconnu : rien")
  end)

  check("Riche : piste de vente actionnable (quantite, lieu, gain, prix, duree)", function()
    if not (Auctionator and C_Container) then return end
    local n = goldNs({ [171] = { rank = 50, max = 75 } })
    bags(n)
    local c = n.Gold.Candidates()[1]
    assert(c.kind == "sell" and c.ask == 999, "prix conseille porte par la piste")
    assert(c.text:find("Vends 20", 1, true) and c.text:find("Fossoyeuse", 1, true) and c.text:find("≈ " .. n.Prof.Money(20000), 1, true)
      and c.text:find("prix de départ conseillé " .. n.Prof.Money(999), 1, true) and c.text:find("12 h", 1, true), c.text)
    mock.ah[101] = { 1000, 2 } mock.bagInfo[1].stackCount = 20
    -- ancien prix marchand haut : l'HdV moins 1 pc ne le depasse pas, la piste dit « marchand »
    n.Sell.Lines = { { advice = "ah", itemID = 101, name = "Baguette 101", count = 20, ah = 11, merchant = 10, amount = 220, gain = 20 } }
    local m = n.Gold.Candidates()[1]
    assert(m.kind == "sell" and m.text:find("au marchand", 1, true) and not m.text:find("HdV de", 1, true), m.text)
  end)

  check("Riche : la vente a un repere vers le commissaire-priseur et sa zone, repli Fossoyeuse", function()
    if not (Auctionator and C_Container) then return end
    local n = goldNs({ [171] = { rank = 50, max = 75 } })
    bags(n)
    local c = n.Gold.Candidates()[1]
    assert(c.go == nil and c.text:find("Fossoyeuse", 1, true), "sans index : repli, pas de repere")
    n.Q.Nearest = function() return 304, { uiMapID = 1420, x = 40, y = 50 } end
    c = n.Gold.Candidates()[1]
    local d = n.Goto.For(c.go)
    assert(c.go.mapID == 1420 and c.go.x == 40 and c.go.y == 50 and d and d.mapID == 1420, "go vers le commissaire-priseur")
    assert(c.text:find(n.Goto.Zone({ uiMapID = 1420 }), 1, true) and not c.text:find("Fossoyeuse", 1, true), c.text)
  end)

  check("Riche : cueille ici a un repere vers le noeud le plus proche, la boucle vers son premier noeud", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = built(herbN(60))
    n.State.zone, n.State.mapID = 1420, 1420
    local b = n.Gold.Best()
    assert(b.kind == "gather" and b.go and b.go.x == 51 and b.go.y == 50, "boucle : premier noeud")
    n.Gather.Loop = function() return nil end
    b = n.Gold.Best()
    assert(b.kind == "gather" and b.text:find("^Cueille 20 Feuillargent ici") and b.go and b.go.mapID == 1420
      and b.go.x == 51 and b.go.y == 50 and n.Goto.For(b.go).text:find("nœud le plus proche", 1, true), "ici : noeud le plus proche")
  end)

  check("Riche : farm integre aux pistes, trie par cuivre/min, sans prix en bas", function()
    if not (LibQuestieDB and C_Map and Auctionator) then return end
    local n = farmBuilt(farmN(12))
    n.State.profs = { [182] = { rank = 60, max = 75 } }
    mock.ah[765] = { 30, 1 }
    local c = n.Gold.Candidates()
    local farms = {}
    for _, a in ipairs(c) do if a.kind == "farm" then farms[#farms + 1] = a end end
    assert(#farms == 2, "Lin et Terre : " .. #farms)
    assert(farms[1].perMin == 120 * 2 * 0.3 and farms[1].go and farms[1].go.mapID == 1420, "perMin estime, lieu")
    assert(farms[1].text:find("Farme les Loup", 1, true) and farms[1].text:find("/h (estimation)", 1, true), farms[1].text)
    assert(farms[2].perMin == 0 and farms[2].text:find("prix inconnu, scanne l'HdV", 1, true) and c[#c] == farms[2], "sans prix : tout en bas")
    for i = 2, #c do assert(c[i - 1].perMin >= c[i].perMin, "tri par cuivre/min") end
    assert(not findSecret(n.db, "db"))
  end)

  check("Riche : butin pendant une quete compte dans quetes, butin hors quete reste butin", function()
    if not C_QuestLog then return end
    local n = earnN()
    mock.qlog = { { questID = 1, title = "Q", level = 5, complete = false } }
    mock.fire("LOOT_OPENED") gain(9) mock.fire("LOOT_CLOSED")
    assert(act(n, "quetes") == 9 and act(n, "butin") == 0, "quete en cours : or des monstres dans quetes")
    mock.qlog[1].complete = true
    mock.time = mock.time + 6 n.Earn.Tick() -- journal relu hors combat
    mock.fire("LOOT_OPENED") gain(4) mock.fire("LOOT_CLOSED")
    assert(act(n, "quetes") == 9 and act(n, "butin") == 4, "hors quete : butin")
    assert(not findSecret(n.db, "db"))
  end)

  local function sections(rows)
    local order = {}
    for _, r in ipairs(rows) do if order[#order] ~= r.section then order[#order + 1] = r.section end end
    return table.concat(order, ",")
  end

  -- Prochain achat : le plan d'achats est pilote par des bouchons (Training.Plan, Calc.ProfessionTodo...) pour fixer l'ordre.
  local function buyN()
    local n = goldNs()
    mock.money, mock.time = 100, 0
    n.State.wand = { itemID = 1, reqLevel = 10, name = "Baguette" } -- baguette correcte : pas d'achat de baguette
    n.Calc.ProfessionTodo = function() return {} end
    n.Training.Plan = function() return { pending = {} } end
    return n
  end

  check("Achats : ordre sorts, rang de metier, recette, baguette, sorts du niveau suivant", function()
    local n = buyN()
    n.Training.Plan = function() return { pending = { { text = "Éclair" } }, known = 500, unknown = 0, nextLevel = 14, nextTotal = 300, nextUnknown = 0 } end
    n.Calc.ProfessionTodo = function() return { { skillLine = 182, rank = { name = "Compagnon", cost = 1000 } } } end
    n.Prof.StepFor = function() return { buy = { recipe = "Potion X", price = 2000 } } end
    n.Prof.KnownRecipe = function() return nil end
    n.State.profs = { [171] = { rank = 50, max = 75 } }
    n.State.wand = false
    local r = n.Earn.Next()
    assert(r.kind == "spell" and r.cost == 500 and r.what:find("Éclair", 1, true), "1. sorts a apprendre")
    n.Training.Plan = function() return { pending = {}, nextLevel = 14, nextTotal = 300, nextUnknown = 0 } end
    r = n.Earn.Next()
    assert(r.kind == "rank" and r.cost == 1000 and r.what == "Compagnon (Herboristerie)", "2. rang de metier : " .. tostring(r.what))
    n.Calc.ProfessionTodo = function() return {} end
    r = n.Earn.Next()
    assert(r.kind == "recipe" and r.cost == 2000 and r.what:find("Potion X", 1, true), "3. recette a acheter")
    n.Prof.KnownRecipe = function() return {} end
    r = n.Earn.Next()
    assert(r.kind == "wand" and r.what:find("aguette", 1, true), "4. baguette : " .. tostring(r.kind))
    n.State.wand = { itemID = 1, reqLevel = 10, name = "Baguette" }
    r = n.Earn.Next()
    assert(r.kind == "next" and r.cost == 300 and r.what:find("14", 1, true), "5. sorts du niveau suivant")
    n.Training.Plan = function() return { pending = {} } end
    assert(n.Earn.Next() == nil and n.Earn.NextShort() == nil and n.Earn.NextText():find("rien à prévoir", 1, true), "rien a acheter")
    mock.money = nil
  end)

  check("Achats : prix inconnu cite sans prix, jamais invente", function()
    local n = buyN()
    n.Training.Plan = function() return { pending = { { text = "Éclair" } }, known = 0, unknown = 1 } end
    mock.money = 5000
    local r = n.Earn.Next()
    local t, sub = n.Earn.NextText()
    assert(r.cost == nil and r.frac == nil and r.ready == nil, "pas de cout, pas de progression")
    assert(t == "Prochain achat : sorts à apprendre : Éclair" and sub == nil, t)
    local s, frac = n.Earn.NextShort()
    assert(not s:find("|T", 1, true) and frac == nil, s)
    n.Training.Plan = function() return { pending = { { text = "A" }, { text = "B" } }, known = 900, unknown = 1 } end
    assert(n.Earn.Next().cost == nil, "cout partiel : pas de total invente")
    mock.money = nil
  end)

  check("Achats : reste a gagner, duree au meilleur rythme, pret, barre de la rangee Or", function()
    local n = buyN()
    n.Training.Plan = function() return { pending = { { text = "Éclair" } }, known = 1000000, unknown = 0 } end
    n.db.earn = { v = 1, act = { quetes = { c = 300000, s = 3600 }, cueillette = { c = 100000, s = 3600 } }, herbs = 0, nodes = 0 }
    mock.money = 400000
    local t, sub = n.Earn.NextText()
    assert(t == "Prochain achat : sorts à apprendre : Éclair (" .. n.Prof.Money(1000000) .. ")", t)
    assert(sub == "Tu as " .. n.Prof.Money(400000) .. ", il te manque " .. n.Prof.Money(600000) .. " · ≈ 2 h à ton rythme", sub)
    local goals = n.Guide.Goals()
    local g = goals[#goals]
    assert(g.kind == "gold" and g.frac == 0.4 and g.detail:find("il te manque", 1, true), "rangee Or : texte court et barre : " .. tostring(g.detail))
    n.db.earn = nil
    assert(select(2, n.Earn.NextText()) == "Tu as " .. n.Prof.Money(400000) .. ", il te manque " .. n.Prof.Money(600000), "sans mesure : pas de duree")
    mock.money = 2000000
    assert(select(2, n.Earn.NextText()) == "✓ prêt, va l'acheter" and n.Earn.NextShort():find("✓ prêt", 1, true), "atteint")
    n.Training.Plan = function() return { pending = {} } end -- achete : on passe au suivant (rien ici)
    assert(n.Earn.Next() == nil)
    mock.money = nil
  end)

  check("Achats : monture du niveau 40 seulement si son prix est lisible", function()
    local n = buyN()
    mock.money = 150000
    local rows = n.Gold.Rows()
    assert(n.Earn.Mount() == nil and n.Earn.MountText() == nil and not rows[2].text:find("Monture", 1, true), "aucun maitre vu : rien")
    n.db.trainer = { ["Apprenti cavalier|"] = { level = 40, category = "unavailable" } } -- prix illisible
    assert(n.Earn.MountText() == nil, "prix illisible : rien")
    n.db.trainer["Apprenti cavalier|"].cost = 200000
    local t, sub = n.Earn.MountText()
    assert(t == "Monture (niveau 40) : Apprenti cavalier (" .. n.Prof.Money(200000) .. ")", t)
    assert(sub == "Au niveau 40 : il te manque " .. n.Prof.Money(50000), sub)
    rows = n.Gold.Rows()
    assert(rows[1].section == "goal" and rows[2].section == "goal" and rows[2].text == t, "montree sous le prochain achat")
    n.db.trainer["Apprenti cavalier|"].category = "used"
    assert(n.Earn.MountText() == nil, "deja apprise : rien")
    mock.money = nil
  end)

  check("Achats : palier de fortune annonce une seule fois, record or/h, argent secret = rien", function()
    local n = buyN()
    local toasts = {}
    n.Toast = function(text) toasts[#toasts + 1] = text return true end
    mock.money = 100
    n.Earn.Track()
    assert(#toasts == 0 and n.db.wealth.tier == 0, "premiere lecture : retenue sans annonce")
    mock.money = 60000 n.Earn.Track() n.Earn.Track()
    assert(#toasts == 1 and toasts[1] == "Fortune : 5 po atteints !", "5 po, une fois : " .. #toasts)
    mock.money = 1000000 n.Earn.Track()
    assert(#toasts == 2 and toasts[2]:find("100 po", 1, true), "palier le plus haut franchi")
    mock.money = 0 n.Earn.Track() mock.money = 1000000 n.Earn.Track()
    assert(#toasts == 2 and n.db.wealth.tier == 6, "jamais reannonce")
    mock.setCombat(true) mock.money = 5000000 n.Earn.Track() mock.setCombat(false)
    assert(#toasts == 2, "pas en combat")
    -- record sur une heure, puis un rythme plus bas ne le baisse pas
    mock.money, mock.time = 10000, 0
    n.Gold.Session()
    mock.time, mock.money = 3600, 40000
    n.Earn.Track()
    local rate = select(2, n.Gold.Session())
    assert(rate and n.db.wealth.record == math.floor(rate) and n.Earn.RecordText() == "Ton record : ≈ " .. n.Prof.Money(math.floor(rate)) .. "/h", tostring(n.db.wealth.record))
    mock.time, mock.money = 7200, 50000
    n.Earn.Track()
    assert(n.db.wealth.record == math.floor(rate), "record non baisse")
    if not mock.noSecrets then
      mock.moneySecret = true
      local n2 = goldNs()
      n2.db.guide.r6 = true -- rappel R6 deja fait
      n2.Toast = function() error("aucune annonce avec un argent secret") end
      n2.Earn.Track() mock.fire("PLAYER_MONEY")
      local r = n2.Earn.Next()
      assert(n2.db.wealth == nil, "rien d'ecrit")
      assert(r == nil or (r.have == nil and r.missing == nil and r.eta == nil and r.frac == nil and r.ready == nil), "rien de calcule")
      assert(not findSecret(n2.db, "db") and not findSecret(n.db, "db"))
      mock.moneySecret = nil
    end
    mock.money = nil
  end)

  check("Riche : onglet Devenir riche, sections dans l'ordre, prochain achat en tete", function()
    local n = goldNs()
    mock.money, mock.time = 1000, 0
    local rows = n.Gold.Rows()
    assert(sections(rows) == "goal,reserve,pistes,chiffres,session", sections(rows))
    assert(rows[1].text:find("Prochain achat : ", 1, true), rows[1].text)
    assert(not rows[1].text:find("/coach objectif", 1, true), "plus d'objectif manuel")
    local none = false
    for _, r in ipairs(rows) do none = none or (r.section == "chiffres" and r.text:lower():find("pas encore assez de mesure", 1, true) ~= nil) end
    assert(none, "chiffres : pas de mesure")
    assert(rows[2].text:find("Réserve", 1, true), rows[2].text)
    n.db.earn = { v = 1, act = { quetes = { c = 300000, s = 3600 }, butin = { c = 5, s = 100 } }, herbs = 0, nodes = 0 }
    local ch = {}
    for _, r in ipairs(n.Gold.Rows()) do if r.section == "chiffres" then ch[#ch + 1] = r.text end end
    assert(ch[2] == "Quêtes : ≈ " .. n.Prof.Money(300000) .. "/h" and ch[3]:find("pas encore assez de mesure", 1, true), "or/h par activite : " .. tostring(ch[2]))
    n.db.wealth = { tier = 0, record = 30000 }
    rows = n.Gold.Rows()
    assert(rows[#rows].section == "session" and rows[#rows].sub == "Ton record : ≈ " .. n.Prof.Money(30000) .. "/h", "record sous la session")
    assert(not findSecret(n.db, "db"))
    n.db.earn, n.db.wealth, mock.money = nil, nil, nil
  end)

  check("Riche : rangee Or de la carte, prochain achat en detail", function()
    local n = gw()
    mock.money, mock.time = 5000, 0
    local g = n.Guide.Goals()
    g = g[#g]
    assert(g.kind == "gold" and (g.detail:find("Prochain achat : ", 1, true) or g.detail:find("Session : +", 1, true)), "detail : " .. tostring(g.detail))
    mock.money = nil
  end)

  check("Riche : rien de nouveau en base, rien de secret", function()
    local n = goldNs()
    local before = {}
    for k in pairs(n.db) do before[k] = true end
    mock.money = 1000
    n.Gold.Rows() n.Guide.Goals() n.Earn.NextShort() n.Earn.MountText()
    assert(not findSecret(n.db, "db"))
    for k in pairs(n.db) do assert(before[k], "cle ajoutee a la base : " .. tostring(k)) end
    mock.money = nil
  end)

  ------------------------------------------------------------------------
  -- Addons tiers optionnels : What's Training (couts des sorts) et QuestDB (recompenses de quetes)
  ------------------------------------------------------------------------
  -- Niveau 14 : Chatiment r3 (598), Cri psychique (8122), Renouveau r2 (6074), Guerison des maladies (528).
  local WT_DISC = { [598] = 900, [592] = 405 } -- GetSource : prix remise (Honore, -10 %)
  local WT_LIST = {
    { id = 598, kind = "trainer", level = 14, cost = 1000 }, { id = 8122, kind = "trainer", level = 14, cost = 2000 },
    { id = 6074, kind = "trainer", level = 14, cost = 700 }, { id = 592, kind = "trainer", level = 12, cost = 450 },
    { id = 99001, kind = "trainer", level = 14, cost = 500 }, -- absent de Data/Spells : compte dans le niveau
    { id = 99002, kind = "trainer", level = 14, cost = 7000, requiredTalentId = 15470 }, -- talent non pris
    { id = 99003, kind = "trainer", level = 14, cost = 800, races = { 2 } }, -- autre race (Orc)
    { id = 99004, kind = "quest", level = 14, cost = 5000 }, { id = 99005, kind = "item", level = 14, cost = 5000 },
    { id = 99006, kind = "weaponMaster", level = 14, cost = 5000 },
  }
  local function installWT(ready)
    WT_API = { IsReady = function() return ready ~= false end,
      GetCatalog = function() local c = {} for i, e in ipairs(WT_LIST) do c[i] = e end return c end,
      GetSource = function(id) return WT_DISC[id] and { kind = "trainer", cost = WT_DISC[id], baseCost = 0, level = 14 } or nil end }
  end
  local function keys(t) local k = {} for x in pairs(t) do k[x] = true end return k end
  local function sameKeys(a, b) for x in pairs(a) do assert(b[x], "cle ajoutee a la base : " .. tostring(x)) end end

  check("WT : cout = maitre > What's Training (remise, puis catalogue) > inconnu ; filtres kind, talent, race", function()
    WT_API = nil
    local n = fresh().n
    setState(n, { level = 12 })
    n.db.trainer = {}
    local before = keys(n.db)
    assert(n.Training.Cost("Sort598", 3, 598) == nil, "sans WT : inconnu")
    installWT()
    assert(n.Training.Cost("Sort598", 3, 598) == 900, "GetSource, remise incluse")
    assert(n.Training.Cost("Sort8122", 1, 8122) == 2000, "pas de GetSource : prix du catalogue")
    n.db.trainer["Sort598|Rang 3"] = { cost = 777, category = "available" }
    assert(n.Training.Cost("Sort598", 3, 598) == 777, "le maitre prime")
    assert(n.Training.Cost("Sort1", 1, 12345) == nil, "sort inconnu de WT")
    assert(n.Training.Cost("Sort99001", 1, 99001) == 500)
    mock.known = {} -- aucun talent pris
    for _, id in ipairs({ 99002, 99003, 99004, 99005, 99006 }) do assert(n.Training.Cost("x", 1, id) == nil, "ignore : " .. id) end
    if IsPlayerSpell then
      mock.known = { [15470] = true }
      assert(n.Training.Cost("x", 1, 99002) == 7000, "talent pris : compte")
      mock.known = nil
    end
    installWT(false)
    assert(n.Training.Cost("Sort8122", 1, 8122) == nil, "WT pas pret")
    WT_API = { IsReady = function() error("boom") end }
    assert(n.Training.Cost("Sort8122", 1, 8122) == nil, "WT qui plante")
    WT_API = nil
    assert(not findSecret(n.db, "db"))
    sameKeys(keys(n.db), before)
  end)

  check("WT : Plan, texte du niveau suivant (assez / il manque), reserve de Budget, Reference", function()
    local n = fresh().n
    setState(n, { level = 12, profs = {} })
    mock.known = {} -- aucun talent pris
    n.db.trainer = { ["Sort6074|Rang 2"] = { cost = 300, category = "available" } }
    installWT()
    local before = keys(n.db)
    local plan = n.Training.Plan(12)
    assert(plan.nextLevel == 14, "prochain palier " .. tostring(plan.nextLevel))
    -- 598 : 900 (remise) + 8122 : 2000 + 6074 : 300 (maitre, pas 700) + 99001 : 500 ; 528 : inconnu
    assert(plan.nextTotal == 3700 and plan.nextUnknown == 1, plan.nextTotal .. " / " .. plan.nextUnknown)
    assert(n.Training.Upcoming(12) == 3700 and n.Training.Upcoming("x") == 0)
    mock.money = 5000
    local t = n.Training.NextText(plan)
    assert(t:find("Sorts du niveau 14 : " .. n.Training.Coin(3700), 1, true) and t:find("tu as assez", 1, true) and t:find("coût inconnu", 1, true), t)
    mock.money = 1000
    t = n.Training.NextText(plan)
    assert(t:find("il te manque " .. n.Training.Coin(2700), 1, true), t)
    mock.moneySecret = true
    assert(n.Training.NextText(plan) == nil, "argent secret")
    mock.moneySecret = nil
    if hasKnows then
      knows(knownUpTo(n, 12))
      local r = n.Budget.Reserve()
      assert(r.spell == 3700 and #r.unknown == 1 and r.unknown[1] == "+ 1 sort(s) au prix inconnu", "reserve : sorts des prochains niveaux " .. r.spell .. " / " .. (r.unknown[1] or "-"))
      knows(knownUpTo(n, 10))
      plan = n.Training.Plan(12)
      local got
      for _, p in ipairs(plan.pending) do if p.text == "Sort592 (rang 2)" then got = p end end
      assert(got and got.cost == 405 and plan.known >= 405, "cout WT d'un sort a apprendre")
      knows(knownUpTo(n, 12))
      local rows = n.Guide.Reference("spells")
      local found
      for _, row in ipairs(rows) do if row.text:find("^Sorts du niveau 14 : ") then found = true end end
      assert(found, rowTexts(rows))
      WT_API = nil
      assert(n.Budget.Reserve().spell == 300, "sans WT : seul le prix du maitre")
      assert(n.Training.NextText(n.Training.Plan(12)) ~= nil, "prix du maitre : texte")
    end
    WT_API = nil
    assert(not findSecret(n.db, "db"))
    sameKeys(keys(n.db), before)
    mock.money, mock.known = nil, nil
  end)

  local EXT = {}
  local function installExt(ready)
    local lib = { IsReady = function() return ready ~= false end,
      GetRewards = function(_, id)
        local r = EXT[id]
        return r and { items = r.items, choices = r.choices, money = r.money, xp = r.xp, questLevel = 20 } or nil
      end,
      GetQuestXP = function(_, id, lvl) return EXT[id] and EXT[id].xp end }
    LibStub = setmetatable({}, { __call = function(_, name) return name == "LibQuestDB-1.0" and lib or nil end })
  end
  local function oneQuest(id, level)
    local n = questN(level or 20)
    mock.qquests = { [id] = { name = "Q" .. id, startedBy = { { 9001 } }, questLevel = 20 } }
    valueLog({ id })
    return n
  end

  check("QuestDB tiers : appris > journal > QuestDB > estimation, source memorisee et affichee", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetQuestLogRewardXP) then return end
    EXT = { [201] = { xp = 2000, money = 700 } }
    installExt()
    local n = oneQuest(201)
    local before = keys(n.db)
    mock.qreward = nil
    n.Quests.Refresh()
    local v = n.Quests.Route()[1].v
    assert(v.xp == 2000 and v.gold == 700 and v.src == "QuestDB", "QuestDB : " .. v.xp .. " / " .. v.gold .. " / " .. tostring(v.src))
    assert(n.Quests.Best().detail:find("≈ 2000 XP (QuestDB)", 1, true), n.Quests.Best().detail)
    mock.qreward = { [201] = { 1650, 12 } }
    n.Quests.Refresh()
    v = n.Quests.Route()[1].v
    assert(v.xp == 1650 and v.gold == 12 and v.src == "journal", "journal : " .. v.xp .. " " .. tostring(v.src))
    n.QuestDB.Learn(201, { xp = 3300, money = 2400, ql = 20 })
    n.Quests.Refresh()
    v = n.Quests.Route()[1].v
    assert(v.xp == 3300 and v.gold == 2400 and v.src == "appris", "appris : " .. v.xp)
    n.QuestDB.Learn(201, { xp = 1234, money = 5, zeroMoney = true, exact = true })
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.xp == 1234, "QUEST_TURNED_IN exact")
    assert(n.Quests.Rows()[1].sub:find("(appris)", 1, true), "source dans l'Itineraire : " .. tostring(n.Quests.Rows()[1].sub))
    -- quete propre a Forever (id >= 65309) sans ligne : estimation, jamais zero
    n = oneQuest(65400)
    mock.qreward = nil
    n.Quests.Refresh()
    v = n.Quests.Route()[1].v
    local ex, em = n.Quests.Estimate(20, 20)
    assert(v.src == "estimé" and v.xp == ex and v.xp > 0 and v.gold == em, "Forever sans ligne : " .. v.xp .. " " .. tostring(v.src))
    assert(n.Quests.Best().detail:find("(estimé)", 1, true))
    assert(not findSecret(n.db, "db"))
    sameKeys(keys(n.db), before)
    mock.qlog, mock.qreward, LibStub = nil, nil, nil
  end)

  check("QuestDB tiers : meilleur choix, repli sur la base apprise, calibration, absent ou pas pret", function()
    if not (C_QuestLog and C_Map and LibQuestieDB and GetQuestLogRewardXP) then return end
    mock.ah, mock.sellPrice = {}, { [1001] = 100, [1002] = 50, [1003] = 10 }
    EXT = { [201] = { xp = 2000, money = 700, choices = { { 1001, 1 }, { 1002, 5 } }, items = { { 1003, 3 } } } }
    installExt()
    local n = oneQuest(201)
    mock.qreward = nil
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.gold == 700 + 30 + 250, "meilleur des choix (5 x 50) + objets : " .. n.Quests.Route()[1].v.gold)
    n.QuestDB.Learn(201, { ql = 20, choices = "1001:1" }) -- la base apprise a des choix : elle prime
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.gold == 700 + 30 + 100, "choix appris : " .. n.Quests.Route()[1].v.gold)
    -- calibration : XP 3300 et 2400 cuivre contre 1650 / 1200 estimes
    EXT = {}
    for _, id in ipairs({ 301, 302, 303 }) do EXT[id] = { xp = 3300, money = 2400 } end
    n = questN(20)
    mock.qquests = {}
    for _, id in ipairs({ 301, 302, 303 }) do mock.qquests[id] = { name = "Q" .. id, startedBy = { { 9001 } }, questLevel = 20 } end
    valueLog({ 301, 302, 303 })
    mock.qreward = nil
    n.Quests.Refresh() n.Quests.Route()
    local cx, cm = n.Quests.Calib()
    assert(cx == 2 and cm == 2, "calibration QuestDB : " .. cx .. " / " .. cm)
    -- pas pret, absent, qui plante : estimation sans erreur
    installExt(false)
    n = oneQuest(201)
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.src == "estimé", "pas pret")
    LibStub = function() error("boom") end
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.src == "estimé", "qui plante")
    LibStub = nil
    n.Quests.Refresh()
    assert(n.Quests.Route()[1].v.src == "estimé" and n.Training.Cost("x", 1, 598) == nil, "absent")
    assert(not findSecret(n.db, "db"))
    mock.qlog, mock.qreward, mock.ah, mock.sellPrice, EXT = nil, nil, nil, nil, {}
  end)
end

suite("presentes")
mock.setAbsent(true)
suite("absentes")
mock.setAbsent(false)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
