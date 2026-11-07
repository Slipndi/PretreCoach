-- Repli sans luacheck : syntaxe via `luajit -bl`, puis globales ecrites/lues inattendues, puis syntaxe non-5.1.
-- Usage : luajit tests/lint.lua   (arg[-1] = chemin de luajit, reutilise pour les sous-processus)
local root = arg[0]:gsub("\\", "/"):match("^(.*)/tests/[^/]*$") or "."
local bin = arg[-1]
local WRITE_OK = { PretreCoachDB = true, SLASH_PRETRECOACH1 = true, PretreCoach_OnCompartmentClick = true }
local READ_OK = {}
for w in ([[
_G assert date error getmetatable ipairs math next pairs pcall select setmetatable string table tinsert tonumber tostring type unpack
CreateFrame UIParent ChatFontNormal SlashCmdList UISpecialFrames InCombatLockdown geterrorhandler issecretvalue print
C_Timer C_Spell C_UnitAuras C_Map C_Item C_QuestLog C_TradeSkillUI C_SpellBook C_ActionBar C_Traits C_ClassTalents C_SpecializationInfo
GetActionInfo GetBindingKey GetBindingText GetSpellTexture GetPlayerAuraBySpellID
UnitCanAttack UnitHealth UnitHealthMax UnitPower UnitPowerMax GetPowerRegen UnitExists UnitGUID UnitIsDead UnitLevel UnitCreatureType
UnitClass UnitRace CheckInteractDistance GetUnitSpeed IsPlayerMoving GetInventoryItemID GetInventoryItemLink
IsPlayerSpell IsSpellKnown GetSpellInfo GetSpellCooldown GetLocale GetBuildInfo GetRealZoneText GetSubZoneText UnitName
GetNumTalentTabs GetProfessions GetProfessionInfo GetNumSkillLines GetSkillLineInfo
GetNumTrainerServices GetTrainerServiceInfo GetTrainerServiceLevelReq GetTrainerServiceCost GetCoinTextureString
GetTime GetNumTalents GetTalentInfo GetNumTalentGroups GetNumSpecGroups GetNumUnspentTalents
Settings Minimap GameTooltip GetCursorPosition GetItemInfo GetItemCount GetItemInfoInstant IsQuestFlaggedCompleted INVSLOT_MAINHAND INVSLOT_RANGED UiMapPoint C_SuperTrack Enum C_Container
]]):gmatch("%S+") do READ_OK[w] = true end

local bad = 0
local function report(f, msg) bad = bad + 1 print(("%s: %s"):format(f, msg)) end

for line in io.lines(root .. "/PretreCoach/PretreCoach.toc") do
  line = line:gsub("\r", "")
  if line ~= "" and not line:find("^#") then
    local f = "PretreCoach/" .. line:gsub("\\", "/")
    local p = io.popen(('""%s" -bl "%s/%s""'):format(bin, root, f) .. " 2>&1")
    local out = p:read("*a")
    if not p:close() then report(f, "syntaxe : " .. out:gsub("\n.*", "")) else
      local seen = {}
      for op, name in out:gmatch("(G[GS]ET)%s+%d+%s+%d+%s+; \"([^\"]+)\"") do
        local ok = (op == "GSET") and WRITE_OK[name] or (op == "GGET" and (READ_OK[name] or WRITE_OK[name]))
        if not ok and not seen[op .. name] then
          seen[op .. name] = true
          local n = 0
          for l in io.lines(root .. "/" .. f) do
            n = n + 1
            if l:find("%f[%w_]" .. name .. "%f[^%w_]") then report(f .. ":" .. n, (op == "GSET" and "global ecrite " or "global lue inconnue ") .. name) break end
          end
        end
      end
    end
    local n = 0
    for l in io.lines(root .. "/" .. f) do
      n = n + 1
      local code = l:gsub("%-%-.*", ""):gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
      if code:find("%f[%w_]goto%f[^%w_]") or code:find("::[%a_][%w_]*::") then report(f .. ":" .. n, "goto/label : refuse par Lua 5.1") end
    end
  end
end
if bad > 0 then print(bad .. " probleme(s) de lint") os.exit(1) end
print("lint ok")
