-- Cœur de l'addon : sauvegarde par personnage, bus d'événements, commandes /coach.
local ADDON, ns = ...
local L = ns.L

-- Un argument secret fait échouer format : on affiche alors le texte du format seul.
function ns.Print(fmt, ...)
  local text = fmt
  if select("#", ...) > 0 then
    local ok, res = pcall(string.format, fmt, ...)
    if ok then text = res end
  end
  print(L.PREFIX .. " " .. text)
end

function ns.Debug(fmt, ...)
  if ns.db and ns.db.debug then ns.Print("|cff888888[debug]|r " .. fmt, ...) end
end

-- C_Timer est attendu sur Forever ; repli immédiat sinon (la sonde dira s'il existe).
ns.After = (C_Timer and C_Timer.After) or function(_, fn) fn() end

-- Bus d'événements : un seul cadre, plusieurs abonnés par événement.
-- Un abonné qui plante ne bloque pas les autres ; l'erreur part quand même à BugSack.
local frame = CreateFrame("Frame")
local handlers = {}

local function run(fn, event, ...)
  local ok, err = pcall(fn, event, ...)
  if not ok then geterrorhandler()(err) end
end

function ns.On(event, fn)
  local list = handlers[event]
  if not list then
    -- un événement inconnu ou interdit sur Forever fait planter RegisterEvent : on le signale
    local ok, res = pcall(frame.RegisterEvent, frame, event)
    if not ok or res == false then return false end
    list = {}
    handlers[event] = list
  end
  list[#list + 1] = fn
  return true
end

frame:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do run(fn, event, ...) end
end)

-- Événement filtré sur une unité : RegisterUnitEvent (un cadre par couple), sinon repli sur le bus avec filtre.
function ns.OnUnit(event, unit, fn)
  local f = CreateFrame("Frame")
  if pcall(f.RegisterUnitEvent, f, event, unit) then
    f:SetScript("OnEvent", function(_, e, ...) run(fn, e, ...) end)
    return true
  end
  return ns.On(event, function(e, u, ...) if u == unit then return fn(e, u, ...) end end)
end

-- Petit bus interne entre modules : ns.Listen("STATE", fn) ; ns.Fire("STATE", ...) appelle fn("STATE", ...).
local listeners = {}

function ns.Listen(msg, fn)
  listeners[msg] = listeners[msg] or {}
  table.insert(listeners[msg], fn)
end

function ns.Fire(msg, ...)
  for _, fn in ipairs(listeners[msg] or {}) do run(fn, msg, ...) end
end

-- Valeurs par défaut des réglages : complétées sans jamais écraser ce que le joueur a déjà.
ns.DEFAULTS = {
  show = { guide = true, rotation = true, rules = true, toasts = true, minimap = true },
  guide = { manual = {}, done = {}, tab = "now", compact = false },
  training = { every = 1 }, trainer = {},
  locked = false, opacity = 0.9, scale = 1, frames = {}, minimap = { angle = 220 },
}

function ns.FillDefaults(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      ns.FillDefaults(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  PretreCoachDB = PretreCoachDB or {}
  ns.db = PretreCoachDB
  ns.FillDefaults(ns.db, ns.DEFAULTS)
end)

-- Verrou des cadres : ns.db.locked est relu à chaque glissement par UI.Movable.
function ns.SetLocked(on)
  ns.db.locked = on and true or false
  ns.Print(on and L.LOCK_ON or L.LOCK_OFF)
  if ns.RefreshOptions then ns.RefreshOptions() end
end

-- Remet positions, échelle et opacité par défaut ; objectifs, statistiques et données du maître restent intacts.
local resetPending = false
local function doReset()
  resetPending = false
  ns.UI.ResetLayout()
  ns.UI.SetScale(ns.DEFAULTS.scale)
  ns.UI.SetOpacity(ns.DEFAULTS.opacity)
  ns.Print(L.RESET_DONE)
  if ns.RefreshOptions then ns.RefreshOptions() end
end
ns.On("PLAYER_REGEN_ENABLED", function() if resetPending then doReset() end end)

local commands = {
  [""] = function() if ns.ToggleOptions then ns.ToggleOptions() else ns.Print(L.HELP) end end,
  help = function() ns.Print(L.HELP) end,
  lock = function() ns.SetLocked(true) end,
  unlock = function() ns.SetLocked(false) end,
  reset = function()
    if InCombatLockdown() then
      resetPending = true
      ns.Print(L.RESET_DEFERRED)
    else
      doReset()
    end
  end,
  probe = function() ns.Probe() end,
  here = function() ns.Here() end,
  guide = function() if ns.ToggleGuide then ns.ToggleGuide() end end,
  compact = function() if ns.SetCompact then ns.SetCompact() end end,
  debug = function()
    ns.db.debug = not ns.db.debug
    ns.Print(ns.db.debug and L.DEBUG_ON or L.DEBUG_OFF)
  end,
}

-- Point d'entrée unique des commandes (slash et menu de la minicarte) ; faux si la commande est inconnue.
function ns.RunCommand(name)
  local fn = commands[name]
  if not fn then return false end
  fn()
  return true
end

SLASH_PRETRECOACH1 = "/coach"
SlashCmdList.PRETRECOACH = function(msg)
  if not ns.RunCommand((msg or ""):lower():match("^%s*(%S*)")) then ns.Print(L.HELP) end
end
