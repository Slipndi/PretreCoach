-- Conformite Blizzard : echoue si l'addon appelle ou cite une API interdite (voir Docs/PROMPT_ADDON_PRETRE_COACH.md, section 0).
-- Usage : luajit tests/compliance.lua (depuis la racine du depot).

local FORBIDDEN = {
  "CastSpell", "CastSpellByName", "CastSpellByID", "UseAction", "UseItemByName", "UseContainerItem",
  "C_Container.UseContainerItem", "RunMacro", "RunMacroText", "TargetUnit", "AssistUnit", "FocusUnit",
  "ClearTarget", "TargetNearestEnemy", "StartAttack", "StopAttack", "SpellStopCasting", "JumpOrAscendStart",
  "MoveForwardStart", "TurnLeftStart", "ToggleAutoRun", "InteractUnit", "FollowUnit",
  "SecureActionButtonTemplate", "SecureUnitButtonTemplate", "SecureGroupHeaderTemplate", "RegisterUnitWatch", "macrotext",
  "SecureHandler", "SetAttribute", "SetBinding", "SetBindingClick",
  "SetBindingSpell", "SetOverrideBinding", "SetOverrideBindingClick", "SaveBindings", "EditMacro",
  "CreateMacro", "DeleteMacro", "PickupSpell", "PickupAction", "PlaceAction", "SendChatMessage",
  "SendAddonMessage", "C_ChatInfo", "COMBAT_LOG_EVENT_UNFILTERED", "CombatLogGetCurrentEventInfo",
  "loadstring", "RunScript", "setfenv", "getfenv", "SetCVar",
  -- actions a la place du joueur : metiers, hotel des ventes, marchands, sacs
  "CraftRecipe", "C_TradeSkillUI.Craft", "OpenTradeSkill", "PostAuction", "PlaceAuctionBid", "C_AuctionHouse.PostItem",
  "C_AuctionHouse.PostCommodity", "C_AuctionHouse.PlaceBid", "C_AuctionHouse.StartCommoditiesPurchase",
  "C_AuctionHouse.ConfirmCommoditiesPurchase", "BuyMerchantItem", "PickupContainerItem", "C_Container.PickupContainerItem",
}
local PREFIX_OK = { SecureHandler = true } -- SecureHandlerBaseTemplate etc. : pas de borne droite

-- Liste blanche precise : fichier -> motif -> vrai. Aujourd'hui vide : Probe.lua ne contient aucun motif interdit.
-- Ajouter ici ["PretreCoach/Probe.lua"] = { ["SendAddonMessage"] = true } seulement si la sonde doit citer un nom.
-- Exception encadree (2026-11-07) : cadres de groupe cliquables, motifs securises dans CE fichier seulement.
-- macrotext, CastSpell*, SetBinding*, etc. restent interdits meme la.
local HEAL = "PretreCoach/UI/HealFrames.lua"
local ALLOW = { [HEAL] = { SecureUnitButtonTemplate = true, SecureActionButtonTemplate = true,
  SecureGroupHeaderTemplate = true, SetAttribute = true, RegisterUnitWatch = true } }

-- Retire les commentaires Lua en gardant les chaines et les numeros de ligne.
local function strip(src)
  local out, i, n = {}, 1, #src
  while i <= n do
    local c = src:sub(i, i)
    if c == "-" and src:sub(i, i + 1) == "--" then
      local eq = src:match("^%-%-%[(=*)%[", i)
      local e = eq and select(2, src:find("]" .. eq .. "]", i, true)) or (src:find("\n", i, true) or n + 1) - 1
      local chunk = src:sub(i, e):gsub("[^\n]", "")
      out[#out + 1] = chunk
      i = e + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2 elseif d == c or d == "\n" then break else j = j + 1 end
      end
      out[#out + 1] = src:sub(i, j); i = j + 1
    else
      out[#out + 1] = c; i = i + 1
    end
  end
  return table.concat(out)
end

local function find_hits(name, src)
  local hits = {}
  local n = 0
  for line in (strip(src) .. "\n"):gmatch("(.-)\n") do
    n = n + 1
    for _, pat in ipairs(FORBIDDEN) do
      if not (ALLOW[name] and ALLOW[name][pat]) then
        local lua = "%f[%w_]" .. pat:gsub("%p", "%%%0") .. (PREFIX_OK[pat] and "" or "%f[^%w_]")
        if line:find(lua) then hits[#hits + 1] = ("%s:%d: %s"):format(name, n, pat) end
      end
    end
  end
  return hits
end

-- Auto-test : un faux fichier doit declencher la detection (et un commentaire ne doit pas).
local fake = find_hits("fake.lua", 'local x = 1\nCastSpellByName("Heal")\n-- SetCVar ignore\nSendChatMessage("hi")\n')
assert(#fake == 2 and fake[1]:find("fake.lua:2: CastSpellByName", 1, true)
  and fake[2]:find("fake.lua:4: SendChatMessage", 1, true), "auto-test compliance en echec")
for _, api in ipairs({ "CraftRecipe", "C_TradeSkillUI.Craft", "OpenTradeSkill", "PostAuction", "PlaceAuctionBid", "C_AuctionHouse.PostItem",
  "C_AuctionHouse.PostCommodity", "C_AuctionHouse.PlaceBid", "C_AuctionHouse.StartCommoditiesPurchase",
  "C_AuctionHouse.ConfirmCommoditiesPurchase", "BuyMerchantItem", "UseContainerItem", "C_Container.UseContainerItem",
  "PickupContainerItem", "C_Container.PickupContainerItem" }) do
  local h = find_hits("fake.lua", "x = 1\n" .. api .. "(1)\n")
  assert(#h >= 1 and h[1]:find("fake.lua:2: ", 1, true), "auto-test : motif non detecte : " .. api)
end
assert(#find_hits("fake.lua", "PostAuctionX(1)\nMyCraftRecipe(1)\n") == 0, "auto-test : bornes de mot")
-- Exception : motifs securises permis dans HealFrames.lua seulement ; macrotext et CastSpell* refuses partout.
local secure = 'f = CreateFrame("Button", "x", UIParent, "SecureUnitButtonTemplate")\nf:SetAttribute("type1", "spell")\nRegisterUnitWatch(f)\n'
assert(#find_hits(HEAL, secure) == 0, "auto-test : motifs securises refuses dans HealFrames.lua")
assert(#find_hits("PretreCoach/UI/Autre.lua", secure) == 3, "auto-test : motif securise accepte hors HealFrames.lua")
assert(#find_hits(HEAL, 'f:SetAttribute("macrotext", "/cast X")\n') == 1, "auto-test : macrotext accepte dans HealFrames.lua")
assert(#find_hits(HEAL, 'CastSpellByName("X")\nSetBindingClick("1", "x")\n') == 2, "auto-test : CastSpell/SetBinding acceptes dans HealFrames.lua")
print("auto-test : detection OK")

local sep = package.config:sub(1, 1)
local cmd = sep == "\\" and 'dir /s /b "PretreCoach\\*.lua"' or "find PretreCoach -name '*.lua'"
local p = assert(io.popen(cmd))
local all, count = {}, 0
for path in p:lines() do
  path = path:gsub("\r", ""):gsub("\\", "/")
  local rel = path:match("(PretreCoach/.*)$")
  if rel and not rel:find("^PretreCoach/Data/") then
    local f = assert(io.open(rel, "rb"))
    local src = f:read("*a"); f:close()
    count = count + 1
    for _, h in ipairs(find_hits(rel, src)) do all[#all + 1] = h end
  end
end
p:close()
assert(count > 0, "aucun fichier lu (lancer depuis la racine du depot)")

if #all > 0 then
  print("ECHEC conformite Blizzard : API interdite trouvee")
  for _, h in ipairs(all) do print("  " .. h) end
  os.exit(1)
end
print(("conformite OK : %d fichiers, aucune API interdite"):format(count))
