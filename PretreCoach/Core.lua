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

ns.On("ADDON_LOADED", function(_, name)
  if name ~= ADDON then return end
  PretreCoachDB = PretreCoachDB or {}
  ns.db = PretreCoachDB
end)

local commands = {
  probe = function() ns.Probe() end,
  debug = function()
    ns.db.debug = not ns.db.debug
    ns.Print(ns.db.debug and L.DEBUG_ON or L.DEBUG_OFF)
  end,
}

SLASH_PRETRECOACH1 = "/coach"
SlashCmdList.PRETRECOACH = function(msg)
  local cmd = (msg or ""):lower():match("^%s*(%S*)")
  local fn = commands[cmd]
  if fn then fn() else ns.Print(L.HELP) end
end
