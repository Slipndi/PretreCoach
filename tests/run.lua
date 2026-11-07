-- Usage : luajit tests/run.lua   (depuis n'importe ou). Sans framework : assert + liste d'etapes.
local root = arg[0]:gsub("\\", "/"):match("^(.*)/tests/[^/]*$") or "."
local print = print -- le mock remplace print
local mock = dofile(root .. "/tests/wowmock.lua")
local failures = {}

local function check(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok and #mock.errors == 0 then print("ok   " .. name) return end
  failures[#failures + 1] = name
  print("FAIL " .. name .. "\n" .. (ok and "" or tostring(err) .. "\n") .. table.concat(mock.errors, "\n"))
  mock.errors = {}
end

-- Chargement dans l'ordre du .toc
local ns = {}
local ADDON = "PretreCoach"
local files = {}
for line in io.lines(root .. "/" .. ADDON .. "/" .. ADDON .. ".toc") do
  line = line:gsub("\r", "")
  if line ~= "" and not line:find("^#") then files[#files + 1] = line:gsub("\\", "/") end
end
check("charge les fichiers du .toc", function()
  assert(#files > 0, "toc vide")
  for _, f in ipairs(files) do
    local chunk = assert(loadfile(root .. "/" .. ADDON .. "/" .. f))
    chunk(ADDON, ns)
  end
end)

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

-- Etapes (a completer pour les lots suivants : guide, regles, cycle)
check("ADDON_LOADED cree PretreCoachDB", function()
  mock.fire("ADDON_LOADED", ADDON)
  assert(type(PretreCoachDB) == "table" and ns.db == PretreCoachDB, "PretreCoachDB absent")
end)
check("probe hors combat", function() SlashCmdList.PRETRECOACH("probe") end)
check("debug et aide", function()
  SlashCmdList.PRETRECOACH("debug"); SlashCmdList.PRETRECOACH("debug"); SlashCmdList.PRETRECOACH("")
end)
check("probe en combat", function()
  mock.setCombat(true)
  mock.fire("PLAYER_REGEN_DISABLED")
  mock.flushTimers()
  SlashCmdList.PRETRECOACH("probe")
  assert(PretreCoachDB.probe.combat, "releve en combat absent")
end)
check("aucune valeur secrete en SavedVariables", function()
  local hit = findSecret(PretreCoachDB, "PretreCoachDB")
  assert(not hit, "valeur secrete stockee a " .. tostring(hit))
end)

if #failures > 0 then print(#failures .. " echec(s) : " .. table.concat(failures, ", ")) os.exit(1) end
print("tous les tests passent")
