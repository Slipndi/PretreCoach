-- Aides pour les valeurs secrètes de Forever : en combat, le jeu peut rendre la vie, le mana,
-- les auras ou les recharges « secrètes ». On peut les afficher, jamais les comparer.
-- Règle : toute logique passe par S.Get, qui rend nil quand la valeur n'est pas utilisable.
local _, ns = ...

local S = {}
ns.S = S

function S.IsSecret(v)
  return issecretvalue ~= nil and issecretvalue(v) == true
end

-- Appelle fn sans risque. Rend (valeur, état) ; valeur = nil si absente, erreur ou secrète.
-- état : "absente", "erreur", "secret", "nil" ou "lisible".
function S.Get(fn, ...)
  if type(fn) ~= "function" then return nil, "absente" end
  local ok, v = pcall(fn, ...)
  if not ok then return nil, "erreur" end
  if S.IsSecret(v) then return nil, "secret" end
  if v == nil then return nil, "nil" end
  return v, "lisible"
end
