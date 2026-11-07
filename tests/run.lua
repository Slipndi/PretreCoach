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
end

suite("presentes")
mock.setAbsent(true)
suite("absentes")
mock.setAbsent(false)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
