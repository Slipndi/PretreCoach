-- Rythme : XP par heure (fenêtre glissante de 20 min de jeu actif), estimations avant le prochain niveau et avant le 60,
-- bilan de session, record du niveau le plus rapide. UnitXP / UnitXPMax peuvent être secrets ou absents sur Forever :
-- tout ce qui en dépend rend nil (affiché « inconnu » / « … »), jamais d'erreur.
-- Persistant (nombres seulement) : ns.db.pace = { levels = { [niveau] = { secs } }, cur = { level, secs, partial }, record = { level, secs } }.
-- Durée d'un niveau = secondes de jeu actif (les pauses de plus de PAUSE s ne comptent pas), cumulées d'une session à l'autre.
local _, ns = ...
local S, L = ns.S, ns.L

local Pace = {}
ns.Pace = Pace

local WINDOW, PAUSE, MIN_GAINS, MIN_ACTIVE, MAX_LEVEL, HISTORY = 1200, 300, 3, 120, 60, 3

local inited, startTime, lastTick, log, level, lastXP, lastMax, cur
local leveled, wrapSeen, doneBase = false, false, 0
local session = { xp = 0, levels = 0 }

local function num(v) return type(v) == "number" and v or nil end

local function readXP()
  return num((S.Get(UnitXP, "player"))), num((S.Get(UnitXPMax, "player")))
end

local function countDone()
  local n = 0
  local g = ns.db and ns.db.guide
  for _, v in pairs(g and g.done or {}) do if v then n = n + 1 end end
  return n
end

-- Niveau courant (relu tant qu'il est inconnu) et durée en cours, reprise de la base si c'est le même niveau.
local function readLevel()
  if not level then level = num((S.Get(UnitLevel, "player"))) end
  ns.db.pace = ns.db.pace or {}
  local p = ns.db.pace
  p.levels = p.levels or {}
  if level and (not p.cur or p.cur.level ~= level) then
    -- niveau commencé hors addon : sa durée serait fausse, il n'entrera ni dans l'historique ni dans le record
    p.cur = { level = level, secs = 0, partial = lastXP == nil or lastXP > 0 }
  end
  cur = p.cur
end

local function ensure()
  if inited or not ns.db then return end
  inited = true
  startTime = GetTime()
  lastTick = startTime
  log = { { t = startTime, gain = 0 } } -- le premier élément sert d'ancre à la fenêtre
  lastXP, lastMax = readXP()
  doneBase = countDone()
  readLevel()
end

local function tick(now)
  local gap = now - lastTick
  if cur and gap > 0 and gap <= PAUSE then cur.secs = cur.secs + gap end
  lastTick = now
end

local function addGain(now, gain)
  log[#log + 1] = { t = now, gain = gain }
  session.xp = session.xp + gain
  while log[2] and log[2].t < now - WINDOW do table.remove(log, 1) end
end

-- XP par heure sur la fenêtre : (xp par heure, nombre de gains, secondes actives) ; nil sans temps actif.
local function rate(now)
  while log[2] and log[2].t < now - WINDOW do table.remove(log, 1) end
  local xp, gains, active = 0, 0, 0
  for i = 2, #log do
    local gap = log[i].t - log[i - 1].t
    if gap <= PAUSE then -- un gain qui clôt une pause ne compte pas : ni son temps ni son XP
      active = active + math.min(gap, log[i].t - math.max(log[i - 1].t, now - WINDOW))
      xp, gains = xp + log[i].gain, gains + 1
    end
  end
  local tail = now - log[#log].t
  if tail <= PAUSE then active = active + tail end
  if active <= 0 or gains == 0 then return nil, gains, active end
  return xp / active * 3600, gains, active
end

local function fmtShort(secs)
  if secs < 60 then return ("%ds"):format(secs) end
  return ("%dm"):format(math.floor(secs / 60))
end
local function fmtMS(secs) return ("%dm %02ds"):format(math.floor(secs / 60), math.floor(secs % 60)) end

local function onXP()
  ensure()
  if not inited then return end
  local now = GetTime()
  tick(now)
  local xp, mx = readXP()
  if xp then
    if lastXP then
      local gain
      if leveled or xp < lastXP then
        if lastMax then gain = lastMax - lastXP + xp end -- fin du niveau précédent + XP du nouveau
        if not leveled then wrapSeen = true end
        leveled = false
      else
        gain = xp - lastXP
      end
      if gain and gain > 0 then addGain(now, gain) end
    end
    lastXP, lastMax = xp, mx or lastMax -- secret : on garde la dernière valeur lue, le gain sera rattrapé à la lecture suivante
  end
  ns.Fire("PACE")
end

local function onLevelUp(_, newLevel)
  ensure()
  if not inited then return end
  newLevel = num(newLevel) or ((level or 0) + 1)
  local now = GetTime()
  tick(now)
  if wrapSeen then wrapSeen = false else leveled = true end
  local p = ns.db.pace
  local secs
  if cur and cur.level == newLevel - 1 and not cur.partial then
    secs = math.floor(cur.secs + 0.5)
    p.levels[cur.level] = { secs = secs }
  end
  if secs then
    ns.Toast(L.PACE_LEVEL:format(newLevel, fmtMS(secs)), { key = "pace_lvl" .. newLevel })
    local rec = p.record
    if not rec then
      p.record = { level = newLevel - 1, secs = secs } -- premier niveau mesuré : pas de fête
    elseif secs < rec.secs then
      p.record = { level = newLevel - 1, secs = secs }
      ns.Toast(L.PACE_RECORD:format(newLevel - 1, fmtShort(secs)), { key = "pace_rec" .. newLevel, duration = 6 })
    end
  else
    ns.Toast(L.PACE_LEVEL_NOTIME:format(newLevel), { key = "pace_lvl" .. newLevel })
  end
  p.cur = { level = newLevel, secs = 0, partial = false }
  cur = p.cur
  level = newLevel
  session.levels = session.levels + 1
  ns.Fire("PACE")
end

-- Secondes restantes avant le prochain niveau, ou nil (XP illisible, moins de 3 gains ou de 2 min de données).
function Pace.NextLevel()
  ensure()
  if not (inited and lastXP and lastMax) then return nil end
  local xph, gains, active = rate(GetTime())
  if not xph or gains < MIN_GAINS or active < MIN_ACTIVE then return nil end
  return (lastMax - lastXP) / xph * 3600
end

-- Fraction du niveau courant, ou nil si l'XP est illisible.
function Pace.Fraction()
  ensure()
  if lastXP and lastMax and lastMax > 0 then return math.min(1, lastXP / lastMax) end
end

function Pace.Level()
  ensure()
  if inited and not level then readLevel() end
  return level
end

-- Secondes avant le 60 d'après la moyenne des 3 derniers niveaux mesurés, ou (nil, niveaux manquants à mesurer).
function Pace.Sixty()
  ensure()
  if not (inited and level) then return nil, HISTORY end
  if level >= MAX_LEVEL then return 0 end
  local keys = {}
  for k, v in pairs(ns.db.pace.levels) do
    if type(k) == "number" and k < level and type(v) == "table" and num(v.secs) then keys[#keys + 1] = k end
  end
  if #keys < HISTORY then return nil, HISTORY - #keys end
  table.sort(keys, function(a, b) return a > b end)
  local sum = 0
  for i = 1, HISTORY do sum = sum + ns.db.pace.levels[keys[i]].secs end
  return sum / HISTORY * (MAX_LEVEL - level - (Pace.Fraction() or 0))
end

function Pace.Rate()
  ensure()
  if not inited then return nil end
  return (rate(GetTime()))
end

local function number(n)
  local s = tostring(math.floor(n + 0.5))
  local k
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1 %2") until k == 0
  return s
end
Pace.Number = number

local function duration(secs)
  if secs < 5400 then return ("%d min"):format(math.max(1, math.floor(secs / 60 + 0.5))) end
  return ("%d h"):format(math.floor(secs / 3600 + 0.5))
end

-- « 1 234 XP/h · niveau suivant ~12 min · 60 dans ~38 h » ; chaque morceau illisible devient « … ».
function Pace.Text()
  local xph = Pace.Rate()
  local nextSecs = Pace.NextLevel()
  local sixty, need = Pace.Sixty()
  local a = xph and L.PACE_XPH:format(number(xph)) or L.PACE_XPH:format("…")
  local b = L.PACE_NEXT:format(nextSecs and ("~" .. duration(nextSecs)) or "…")
  local c
  if sixty then c = L.PACE_SIXTY:format("~" .. duration(sixty))
  elseif need then c = L.PACE_SIXTY_WAIT:format(need)
  else c = L.PACE_SIXTY:format("…") end
  return a .. " · " .. b .. " · " .. c
end

-- /coach bilan : dans le chat local seulement.
function Pace.Report()
  ensure()
  if not inited then ns.Print(L.PACE_NODB) return end
  local now = GetTime()
  tick(now)
  local xph = Pace.Rate()
  ns.Print(L.PACE_REPORT, duration(now - startTime),
    lastXP and number(session.xp) or L.PACE_UNKNOWN, session.levels,
    ns.Rules and ns.Rules.KillStats().total or 0, math.max(0, countDone() - doneBase))
  ns.Print(L.PACE_REPORT2, xph and number(xph) or L.PACE_UNKNOWN,
    Pace.NextLevel() and duration(Pace.NextLevel()) or L.PACE_UNKNOWN)
  local rec = ns.db.pace.record
  if rec then ns.Print(L.PACE_REPORT_REC, rec.level, fmtShort(rec.secs)) end
end

ns.On("PLAYER_LOGIN", function() ensure() end)
ns.On("PLAYER_XP_UPDATE", onXP)
ns.On("PLAYER_REGEN_ENABLED", onXP) -- rattrape un gain reçu en combat (valeur secrète)
ns.On("PLAYER_LEVEL_UP", onLevelUp)
