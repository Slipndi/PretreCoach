-- Reserve d'argent : ce que tu dois garder pour ce qui est DEJA connu (sorts du maitre, rang de metier, recettes) avant
-- qu'un conseil te propose un autre achat. Priorite : sorts, puis rang, puis recettes, puis composants.
-- Seuls les couts CONNUS comptent (Training memorise ceux du maitre ; le prix d'une recette vient de Data/ProfPlan) ;
-- un cout inconnu est signale, jamais estime. Lecture et conseil seulement ; rien n'est ecrit dans PretreCoachDB.
local _, ns = ...
local L, S, D, State, Calc = ns.L, ns.S, ns.Data, ns.State, ns.Calc

local Budget = {}
ns.Budget = Budget

local ORDER = { spell = 1, rank = 2, recipe = 3, comps = 4 }
local LABEL = { spell = "BUDGET_SPELLS", rank = "BUDGET_RANK", recipe = "BUDGET_RECIPE" }
local KINDS = { "spell", "rank", "recipe" }

local function num(v) if type(v) == "number" and not S.IsSecret(v) then return v end end
local function money(c) return ns.Prof.Money(c) end

-- { money (nil si illisible), spell, rank, recipe (sommes des couts connus), unknown = { texte, ... } }
function Budget.Reserve()
  local r = { money = num(S.Get(GetMoney)), spell = 0, rank = 0, recipe = 0, unknown = {} }
  local plan = ns.Training and ns.Training.Plan(State.level)
  if plan and plan.pending and #plan.pending > 0 then
    r.spell = plan.known or 0
    if (plan.unknown or 0) > 0 then r.unknown[#r.unknown + 1] = L.BUDGET_UNKNOWN:format(L.BUDGET_SPELLS) end
  end
  r.spell = r.spell + (ns.Training and ns.Training.Upcoming(State.level) or 0)
  local todo = Calc.ProfessionTodo(State.level, State.profs, D.Professions)
  for _, t in ipairs(todo or {}) do
    if num(t.rank.cost) then r.rank = r.rank + t.rank.cost
    else r.unknown[#r.unknown + 1] = L.BUDGET_UNKNOWN:format(L.BUDGET_RANK) end
  end
  for line, plan2 in pairs(D.ProfPlan or {}) do
    local p = type(State.profs) == "table" and State.profs[line]
    local st = p and ns.Prof.StepFor(plan2, p.rank or 0)
    local b = st and st.buy
    if b and not ns.Prof.KnownRecipe(ns.Prof.Get(line), b.recipe) then
      if num(b.price) then r.recipe = r.recipe + b.price
      else r.unknown[#r.unknown + 1] = L.BUDGET_UNKNOWN:format(L.BUDGET_RECIPE) end
    end
  end
  return r
end

-- Un achat de ce genre au cout connu (cuivre) est-il payable apres la reserve des genres plus prioritaires ?
-- Rend true, ou false et la raison (« garde X pour tes sorts »). Cout ou argent illisible : true (rien a prouver).
function Budget.Check(kind, cost)
  local r = Budget.Reserve()
  if not (r.money and num(cost)) then return true end
  local held, why = 0, {}
  for _, k in ipairs(KINDS) do
    if ORDER[k] < ORDER[kind] and r[k] > 0 then held, why[#why + 1] = held + r[k], L[LABEL[k]] end
  end
  if cost <= r.money - held then return true end
  if held == 0 then return false, L.BUDGET_SHORT:format(money(cost - r.money)) end
  return false, L.BUDGET_KEEP:format(money(held), table.concat(why, " et "))
end
