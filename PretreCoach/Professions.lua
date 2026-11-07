-- Rappels de métiers (spec 6.6), via Calc.ProfessionTodo, sur STATE { "profs" } ou { "level" } :
-- rang à prendre chez le maître, nouveau bandage (dernier connu dans ns.db.training.bandage), métier manquant dès le niveau 5.
-- Anti-répétition par clé, le temps de la session.
-- shortcut: noms de bandages et de rangs pris dans les données (français), pas relus en jeu.
local _, ns = ...
local L, State, Calc, D = ns.L, ns.State, ns.Calc, ns.Data

local Professions = {}
ns.Professions = Professions

local seen = {}

local function once(key, text)
  if seen[key] then return end
  seen[key] = true
  ns.Toast(text, { key = "pc:prof:" .. key })
end

function Professions.Check()
  local level, profs = State.level, State.profs
  local todo, bandage, missing = Calc.ProfessionTodo(level, profs, D.Professions)
  if not todo then return end
  for _, t in ipairs(todo) do
    once("rank:" .. t.skillLine .. ":" .. t.rank.name,
      L.PROF_RANK:format(D.Professions[t.skillLine].name, profs[t.skillLine].rank or 0, t.rank.name))
  end
  if bandage and ns.db then
    ns.db.training = ns.db.training or {}
    local last = ns.db.training.bandage
    if last and bandage.skill > last then
      ns.Toast(L.PROF_BANDAGE:format(bandage.name), { key = "pc:prof:bandage:" .. bandage.skill })
    end
    if not last or bandage.skill > last then ns.db.training.bandage = bandage.skill end
  end
  if level >= 5 and #missing > 0 then
    local names = {}
    for i, id in ipairs(missing) do names[i] = D.Professions[id].name end
    once("missing", L.PROF_MISSING:format(table.concat(names, ", ")))
  end
end

ns.Listen("STATE", function(_, changed)
  for _, k in ipairs(changed or {}) do
    if k == "profs" or k == "level" then return Professions.Check() end
  end
end)
