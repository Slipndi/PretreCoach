-- Pont optionnel vers Auctionator.API.v1 : lecture seule, sous pcall, callerID "PretreCoach".
local _, ns = ...
local AH = {}
ns.AH = AH

local function v1()
  local a = _G.Auctionator
  local api = type(a) == "table" and type(a.API) == "table" and a.API.v1
  return type(api) == "table" and api or nil
end

local function call(name, itemID)
  local api = v1()
  local fn = api and api[name]
  if type(fn) ~= "function" or type(itemID) ~= "number" then return nil end
  local ok, v = pcall(fn, "PretreCoach", itemID)
  if ok and type(v) == "number" then return v end
end

function AH.Available() local api = v1() return api ~= nil and type(api.GetAuctionPriceByItemID) == "function" end
function AH.Price(itemID) return call("GetAuctionPriceByItemID", itemID) end -- cuivre, nil si inconnu
function AH.Age(itemID) return call("GetAuctionAgeByItemID", itemID) end -- jours (nil au-dela de 21 : voir GetAuctionAge.lua)
