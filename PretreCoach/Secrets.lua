-- Aides pour les valeurs secrètes de Forever : en combat, le jeu peut rendre la vie, le mana,
-- les auras ou les recharges « secrètes ». On peut les afficher, jamais les comparer.
-- Règle : toute logique passe par S.Get, qui rend nil quand la valeur n'est pas utilisable.
local _, ns = ...

local S = {}
ns.S = S

function S.IsSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) == true
end

-- Appelle fn sans risque. S.GetAll rend (état, v1, v2…) ; état = "absente", "erreur", "secret", "nil" ou "lisible".
-- Si UNE valeur rendue est secrète, l'état est "secret" et aucune valeur n'est rendue.
local function pack(ok, ...)
  if not ok then return "erreur" end
  for i = 1, select("#", ...) do
    if S.IsSecret((select(i, ...))) then return "secret" end
  end
  if (...) == nil then return "nil" end
  return "lisible", ...
end

function S.GetAll(fn, ...)
  if type(fn) ~= "function" then return "absente" end
  return pack(pcall(fn, ...))
end

-- Version à une valeur : (v1, état) ; v1 = nil si absente, erreur, nil ou une valeur rendue est secrète.
function S.Get(fn, ...)
  local state, v = S.GetAll(fn, ...)
  if state == "lisible" then return v, state end
  return nil, state
end
