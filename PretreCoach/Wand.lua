-- Indicateur de tir de baguette : quand peut-on lancer un sort entre deux tirs ? Données lisibles en combat seulement
-- (spellID, GetTime) ; rien n'est écrit dans PretreCoachDB (vitesse et zone sont réapprises à chaque session).
-- Mesure : UNIT_SPELLCAST_SUCCEEDED avec le spellID de Tir. À vérifier en jeu : chaque tir automatique déclenche-t-il
-- l'événement ? Si seul le premier tir le fait, la vitesse vient de UnitRangedDamage (repli) et l'indicateur s'éteint
-- après 2 x la vitesse sans événement.
-- Fenêtre morte : phase (0 = tir, 1 = tir suivant) des UNIT_SPELLCAST_FAILED d'un sort autre que Tir pendant que la baguette tire.
local _, ns = ...
local S = ns.S

local W = {}
ns.Wand = W

local SHOOT_ID
for _, sp in ipairs(ns.Data.Spells) do
  if sp.key == "SHOOT" then SHOOT_ID = sp.ranks[1].id end
end

local MIN_GAP, MAX_GAP = 0.8, 4 -- écarts entre tirs retenus pour la vitesse
local MAX_GAPS, MAX_FAILS, MIN_FAILS = 9, 20, 3
local PAD = 0.1                 -- marge (s) autour des échecs observés
local DEFAULT_ZONE = 0.5        -- à vérifier en jeu : 0,5 s avant et après un tir
local MAX_RED = 0.6             -- largeur rouge totale max (part de la période) ; jamais sous la zone par défaut
local NEAR_SHOT = 1.2           -- un échec n'est retenu que s'il tombe à moins de 1,2 s (au plus 0,5 de phase) d'un tir
local FAIL_TTL = 60             -- s : un échec plus ancien est oublié
local GAP_TOL, REF_TOL = 0.25, 0.15 -- écart accepté (±25 % de la vitesse de référence) ; changement de vitesse qui vide tout
local MIN_REF_GAPS = 3          -- écarts nécessaires avant de filtrer sur la médiane

local last                      -- GetTime() du dernier tir réussi (nil = la baguette ne tire pas)
local gaps, fails = {}, {}      -- écarts entre tirs ; échecs { phase, GetTime() } (les plus récents en dernier)
local ADOPT_GAPS = 4            -- écarts rejetés cohérents qui remplacent la base
local rej = {}                  -- derniers écarts rejetés d'affilée
local refRD                    -- dernière vitesse lisible de UnitRangedDamage

local function push(list, v, max)
  list[#list + 1] = v
  if #list > max then table.remove(list, 1) end
end

local function median(list)
  if #list == 0 then return nil end
  local c = {}
  for i, v in ipairs(list) do c[i] = v end
  table.sort(c)
  local n = #c
  return n % 2 == 1 and c[(n + 1) / 2] or (c[n / 2] + c[n / 2 + 1]) / 2
end

-- Vitesse (s) : médiane des écarts mesurés, sinon UnitRangedDamage si lisible ; nil si inconnue.
function W.Speed()
  local m = median(gaps)
  if m then return m end
  return W.RangedSpeed()
end

function W.RangedSpeed()
  local v = S.Get(UnitRangedDamage, "player")
  if type(v) == "number" and v >= MIN_GAP and v <= MAX_GAP then return v end
end

-- Oublie les échecs trop anciens.
local function prune()
  local now, keep = GetTime(), {}
  for _, f in ipairs(fails) do if now - f[2] <= FAIL_TTL then keep[#keep + 1] = f end end
  fails = keep
end

-- Zones rouges en phase [0,1] : par défaut la fin et le début du cycle ; après 3 échecs, deux bords (juste après le tir,
-- juste avant le suivant) élargis jusqu'aux échecs observés, sans jamais traverser la barre ni dépasser MAX_RED au total.
-- shortcut: une phase de 0,5 compte comme « après le tir » ; pas de distinction par sort.
function W.Zones(speed)
  speed = speed or W.Speed()
  if not speed then return {} end
  local w = math.min(DEFAULT_ZONE / speed, 0.45)
  prune()
  if #fails >= MIN_FAILS then
    local after, before = w, w
    for _, f in ipairs(fails) do
      local p = f[1]
      if p < 0.5 then after = math.max(after, p + PAD / speed) else before = math.max(before, 1 - p + PAD / speed) end
    end
    local over, budget = after + before - 2 * w, math.max(MAX_RED, 2 * w) - 2 * w
    if over > budget then -- on ne garde de l'élargissement que ce que le plafond permet
      local k = budget / over
      after, before = w + (after - w) * k, w + (before - w) * k
    end
    return { { 0, after }, { 1 - before, 1 } }
  end
  return { { 0, w }, { 1 - w, 1 } }
end

-- Actif : la baguette a tiré il y a moins de 2 x la vitesse (et les sorts sont lisibles).
function W.Active()
  if not last or ns.Timers.degraded then return false end
  local sp = W.Speed()
  return sp ~= nil and GetTime() - last <= 2 * sp
end

-- { phase, speed, zones, red, wait } ou nil si la baguette ne tire pas ; wait = secondes avant la fin de la zone rouge.
function W.State()
  if not W.Active() then return nil end
  local sp = W.Speed()
  local ph = (GetTime() - last) / sp
  if ph >= 1 then ph = ph % 1 end
  local zones = W.Zones(sp)
  local st = { phase = ph, speed = sp, zones = zones, red = false }
  for _, z in ipairs(zones) do
    if ph >= z[1] and ph < z[2] then
      st.red, st.wait = true, math.max(st.wait or 0, (z[2] - ph) * sp)
    end
  end
  return st
end

-- Secondes à attendre avant de pouvoir lancer (nil si libre ou si la baguette ne tire pas).
function W.Wait()
  local st = W.State()
  return st and st.red and st.wait or nil
end

function W.FailCount() prune() return #fails end

ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or spellID ~= SHOOT_ID then return end
  local now = GetTime()
  local rd = W.RangedSpeed()
  local reset = rd and refRD and math.abs(rd - refRD) > REF_TOL * refRD
  if reset then gaps, fails, rej = {}, {}, {} end -- hâte ou nouvelle baguette : tout est à réapprendre
  refRD = rd or refRD
  if last and not reset then
    local g = now - last
    local ref = rd or (#gaps >= MIN_REF_GAPS and median(gaps)) or nil
    if g >= MIN_GAP and g <= MAX_GAP then
      if not ref or math.abs(g - ref) <= GAP_TOL * ref then
        push(gaps, g, MAX_GAPS)
        rej = {}
      elseif not rd then
        -- vitesse changée sans lecture possible : 4 écarts rejetés cohérents entre eux deviennent la nouvelle base
        push(rej, g, ADOPT_GAPS)
        local m = #rej >= ADOPT_GAPS and median(rej)
        local ok = m
        for _, v in ipairs(rej) do if m and math.abs(v - m) > GAP_TOL * m then ok = false end end
        if ok then gaps, fails, rej = rej, {}, {} end
      end
    end
  end
  last = now
  ns.Fire("WAND")
end)

local function failed(_, _, _, spellID)
  if S.IsSecret(spellID) or type(spellID) ~= "number" or spellID == SHOOT_ID then return end
  local st = W.State()
  if not st then return end
  local p = st.phase
  if math.min(p, 1 - p) > math.min(NEAR_SHOT / st.speed, 0.5) then return end -- trop loin d'un tir : pas une collision
  prune()
  push(fails, { p, GetTime() }, MAX_FAILS)
end
ns.OnUnit("UNIT_SPELLCAST_FAILED", "player", failed)
ns.OnUnit("UNIT_SPELLCAST_FAILED_QUIET", "player", failed)

local function stop()
  if last then last = nil ns.Fire("WAND") end
end
ns.On("PLAYER_REGEN_ENABLED", stop)
ns.On("PLAYER_DEAD", stop)
ns.On("PLAYER_ENTERING_WORLD", stop)
