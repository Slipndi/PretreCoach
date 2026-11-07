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

local last                      -- GetTime() du dernier tir réussi (nil = la baguette ne tire pas)
local gaps, fails = {}, {}      -- écarts entre tirs ; phases d'échec (les plus récentes en dernier)

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
  local v = S.Get(UnitRangedDamage, "player")
  if type(v) == "number" and v >= MIN_GAP and v <= MAX_GAP then return v end
end

-- Zones rouges en phase [0,1] : par défaut la fin et le début du cycle ; après 3 échecs, l'intervalle observé.
-- shortcut: un seul intervalle min..max (des échecs à la fois près de 0 et de 1 donnent une zone très large) ; à scinder si besoin.
function W.Zones(speed)
  speed = speed or W.Speed()
  if not speed then return {} end
  if #fails >= MIN_FAILS then
    local lo, hi = 1, 0
    for _, p in ipairs(fails) do lo, hi = math.min(lo, p), math.max(hi, p) end
    return { { math.max(0, lo - PAD / speed), math.min(1, hi + PAD / speed) } }
  end
  local w = math.min(DEFAULT_ZONE / speed, 0.45)
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

function W.FailCount() return #fails end

ns.OnUnit("UNIT_SPELLCAST_SUCCEEDED", "player", function(_, _, _, spellID)
  if S.IsSecret(spellID) or spellID ~= SHOOT_ID then return end
  local now = GetTime()
  if last then
    local g = now - last
    if g >= MIN_GAP and g <= MAX_GAP then push(gaps, g, MAX_GAPS) end
  end
  last = now
  ns.Fire("WAND")
end)

local function failed(_, _, _, spellID)
  if S.IsSecret(spellID) or type(spellID) ~= "number" or spellID == SHOOT_ID then return end
  local st = W.State()
  if st then push(fails, st.phase, MAX_FAILS) end -- un échec sans rapport (hors portée...) fausse un peu la zone
end
ns.OnUnit("UNIT_SPELLCAST_FAILED", "player", failed)
ns.OnUnit("UNIT_SPELLCAST_FAILED_QUIET", "player", failed)

local function stop()
  if last then last = nil ns.Fire("WAND") end
end
ns.On("PLAYER_REGEN_ENABLED", stop)
ns.On("PLAYER_DEAD", stop)
ns.On("PLAYER_ENTERING_WORLD", stop)
