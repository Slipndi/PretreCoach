-- Calculs purs : aucun appel à l'API WoW, seulement des arguments (et ns.Data pour les listes conseillées).
local _, ns = ...

local Calc = {}
ns.Calc = Calc

-- Palier : "1-10", "10-20" … "50-60". nil si le niveau est illisible.
function Calc.Tier(level)
  if type(level) ~= "number" then return nil end
  if level < 10 then return "1-10" end
  local lo = math.min(math.floor(level / 10) * 10, 50)
  return lo .. "-" .. (lo + 10)
end

-- zone = ns.Data.Zones[id] ({ min, max, nom }). Rend le statut, et pour "bientot"/"verte" l'étape
-- suivante conseillée de ns.Data.ZonePath ({ uiMapID, min, max }, nil si le parcours est fini).
-- Statuts : "adaptee", "bientot" (dernier niveau de la plage), "verte" (au-delà), "haute" (sous le min), "neutre".
function Calc.ZoneStatus(level, zone)
  if type(level) ~= "number" or type(zone) ~= "table" or type(zone[1]) ~= "number" then return "neutre" end
  local status = "adaptee"
  if level < zone[1] then status = "haute"
  elseif level > zone[2] then status = "verte"
  elseif level == zone[2] then status = "bientot" end
  if status == "bientot" or status == "verte" then
    for _, step in ipairs(ns.Data.ZonePath) do
      if step[3] > level then return status, step end
    end
  end
  return status
end

-- wand = State.wand : table { itemID, reqLevel, name }, false (emplacement vide ou pas une baguette),
-- nil (illisible). Statuts : "aucune", "depassee" (niveau requis <= niveau - 10), "ok", "inconnue".
-- Pour "aucune"/"depassee", rend aussi la prochaine baguette conseillée de ns.Data.Wands (ordre indifférent :
-- la meilleure de niveau <= niveau du joueur et > niveau requis actuel). "depassee" sans meilleure baguette connue : "ok".
function Calc.WandStatus(level, wand)
  if type(level) ~= "number" or wand == nil then return "inconnue" end
  local req = wand and wand.reqLevel
  local status
  if not wand or not wand.itemID then
    status = level >= 5 and "aucune" or "ok"
  elseif type(req) ~= "number" then
    return "inconnue"
  else
    status = req <= level - 10 and "depassee" or "ok"
  end
  if status == "aucune" or status == "depassee" then
    local best
    for _, w in ipairs(ns.Data.Wands) do
      if w.level <= level and w.level > (req or 0) and (not best or w.level > best.level) then best = w end
    end
    if status == "depassee" and not best then return "ok" end
    return status, best
  end
  return status
end

-- knowsFn(key) rend le plus haut rang connu (State.Knows) ; nil = inconnu, le sort n'est alors pas proposé.
-- Rend { key, rankIndex, level } : seul le plus haut rang disponible et non connu de chaque sort, hors talents.
-- Rend nil si l'information est inconnue pour tous les sorts concernés (API absente), {} s'il n'y a rien à apprendre.
function Calc.PendingSpells(level, knowsFn)
  local out = {}
  if type(level) ~= "number" then return out end
  if not knowsFn then return nil end
  local asked, answered = 0, 0
  for _, sp in ipairs(ns.Data.Spells) do
    if not sp.talent and not sp.noTrainer then
      local top
      for i, r in ipairs(sp.ranks) do
        if r.level and r.level <= level then top = i end
      end
      local known = top and knowsFn(sp.key)
      if top then asked = asked + 1 end
      if known then answered = answered + 1 end
      if known and known < top then out[#out + 1] = { key = sp.key, rankIndex = top, level = sp.ranks[top].level } end
    end
  end
  if asked > 0 and answered == 0 then return nil end
  return out
end

-- talents = State.talents : { [spellID] = { rank, max, name } } (C_Traits), ou { pos = { [tab][row][col] = rang } } (Classic) ;
-- nil = illisible. Un talent est trouvé si l'un de ses spellIDs est dans talents, sinon par le nom localisé du 1er spellID
-- (nameOf), sinon par sa position. Rend (manques, inconnus) pour les entrées du plan dont la fenêtre [from, to] contient
-- le niveau : manques = { entry, have, want } au rang non atteint (respecs ignorés) ; inconnus = entrées introuvables.
function Calc.TalentGap(level, talents, plan, nameOf)
  if talents == nil then return nil end
  local out, unknown = {}, {}
  if type(level) ~= "number" then return out, unknown end
  for _, e in ipairs(plan or {}) do
    if e.tab and level >= e.from and level <= e.to then
      local have
      for _, id in ipairs(e.spellIDs or {}) do
        if talents[id] then have = talents[id].rank break end
      end
      if have == nil and e.spellIDs and nameOf then
        local name = nameOf(e.spellIDs[1])
        if name then
          for _, t in pairs(talents) do
            if type(t) == "table" and t.name == name then have = t.rank break end
          end
        end
      end
      if have == nil and talents.pos then
        have = talents.pos[e.tab] and talents.pos[e.tab][e.row] and talents.pos[e.tab][e.row][e.col] or 0
      end
      if have == nil then unknown[#unknown + 1] = e
      elseif have < e.rank then out[#out + 1] = { entry = e, have = have, want = e.rank } end
    end
  end
  return out, unknown
end

-- profs = State.profs, data = ns.Data.Professions. Rend 3 valeurs :
--   todo    : { { skillLine, rank } } rang suivant à prendre (compétence >= minSkill, niveau >= minLevel)
--   bandage : l'entrée de bandage la plus haute utilisable, ou nil
--   missing : skillLines de data que le joueur n'a pas
-- Tout à nil si le niveau ou profs est illisible.
function Calc.ProfessionTodo(level, profs, data)
  if type(level) ~= "number" or type(profs) ~= "table" or type(data) ~= "table" then return nil, nil, nil end
  local todo, missing, bandage, ids = {}, {}, nil, {}
  for id in pairs(data) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local p = profs[id]
    if not p then
      missing[#missing + 1] = id
    else
      local rank, max = p.rank or 0, p.max or 0
      for _, r in ipairs(data[id].ranks or {}) do
        if r.max > max then
          if rank >= r.minSkill and level >= r.minLevel then todo[#todo + 1] = { skillLine = id, rank = r } end
          break
        end
      end
      for _, b in ipairs(data[id].bandages or {}) do
        if b.skill <= rank and (not bandage or b.skill > bandage.skill) then bandage = b end
      end
    end
  end
  return todo, bandage, missing
end
