--[[
  Shell picker — same layout as OutfitCheatMod:
  one button per shell, current one tagged " (equipped)".
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

local M = {}

local SECTION_ID = "Shells"

--- Official nine shells. Harros is prologue-only and needs the petrified flag cleared.
local SHELLS = {
    { id = "harros",  label = "Harros, the Vassal",     name = "Harros",  restore = true },
    { id = "tiel",    label = "Tiel, the Acolyte",      name = "Tiel" },
    { id = "eredrim", label = "Eredrim, the Venerable", name = "Eredrim" },
    { id = "proxima", label = "Proxima, the Broodseer", name = "Proxima",
      aliases = { "Broodseer", "Broodseeker", "BroodSeeker" } },
    { id = "gragu",   label = "Gragu, the Insatiable",  name = "Gragu" },
    { id = "smert",   label = "Smert, the Apostate",    name = "Smert" },
    { id = "genessa", label = "Genessa, the Wayward",   name = "Genessa" },
    { id = "lazlo",   label = "Lazlo, the Justicar",    name = "Lazlo" },
    { id = "sariel",  label = "Sariel, the Endless",    name = "Sariel" },
}

local currentName = nil
--- Last shell the player picked in this menu. Nil until they click.
local wantedName = nil
local reapplyHandle = nil

local function IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function ShellButtonId(shell)
    return "shell_" .. shell.id
end

---@param className string
---@return UObject|nil
local function FindCdo(className)
    local obj = FindFirstOf(className)
    if IsValid(obj) then
        return obj
    end
    return nil
end

---@param obj UObject
---@param field string
---@return any
local function ReadField(obj, field)
    local ok, val = pcall(function()
        return obj[field]
    end)
    if ok then
        return val
    end
    return nil
end

---@param obj UObject
---@param field string
---@param value any
local function WriteField(obj, field, value)
    pcall(function()
        obj[field] = value
    end)
end

---@param value any
---@return string|nil
local function ToLuaString(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        if value:find("^table:", 1) or value == "" or value == "None" or value == "nil" then
            return nil
        end
        return value
    end
    if type(value) == "userdata" or type(value) == "table" then
        local ok, text = pcall(function()
            if type(value.ToString) == "function" then
                return value:ToString()
            end
            return nil
        end)
        if ok and type(text) == "string" and text ~= "" and not text:find("^table:", 1) then
            return text
        end
        local okTag, tagName = pcall(function()
            local n = value.TagName
            if n == nil then
                return nil
            end
            if type(n) == "string" then
                return n
            end
            if type(n.ToString) == "function" then
                return n:ToString()
            end
            return tostring(n)
        end)
        if okTag and type(tagName) == "string" and tagName ~= "" and not tagName:find("^table:", 1) then
            return tagName
        end
    end
    return nil
end

---@param tag any
---@return string|nil
local function TagToString(tag)
    return ToLuaString(tag)
end

---@param arr any
---@param fn fun(item: any)
local function ForEachArrayItem(arr, fn)
    if arr == nil then
        return
    end
    local n = 0
    pcall(function()
        n = #arr
    end)
    if n > 0 then
        for i = 1, n do
            local ok, item = pcall(function()
                return arr[i]
            end)
            if ok then
                fn(item)
            end
        end
        return
    end
    pcall(function()
        for _, item in ipairs(arr) do
            fn(item)
        end
    end)
end

local function IsDefaultObject(obj)
    local okName, name = pcall(function()
        return obj:GetFullName()
    end)
    if okName and type(name) == "string" and name:find("Default__", 1, true) then
        return true
    end
    return false
end

---@param className string
---@param fn fun(obj: UObject)
local function ForEachLoaded(className, fn)
    local found = FindAllOf(className)
    if found then
        for _, obj in ipairs(found) do
            if IsValid(obj) and not IsDefaultObject(obj) then
                fn(obj)
            end
        end
        return
    end
    local obj = FindFirstOf(className)
    if IsValid(obj) and not IsDefaultObject(obj) then
        fn(obj)
    end
end

---@return APlayerController|nil
local function GetPlayerController()
    local pc = UEHelpers.GetPlayerController()
    if IsValid(pc) then
        return pc
    end
    return nil
end

---@param text string
---@return string
local function AlnumLower(text)
    return (string.lower(text):gsub("[^%w]+", ""))
end

---@param shell table
---@return string[]
local function ShellTokens(shell)
    local tokens = { shell.name, shell.id }
    if shell.aliases then
        for i = 1, #shell.aliases do
            tokens[#tokens + 1] = shell.aliases[i]
        end
    end
    return tokens
end

---@param shell table
---@param current string|nil
---@return boolean
local function MatchesShell(shell, current)
    if type(current) ~= "string" or current == "" then
        return false
    end
    local c = string.lower(current)
    local last = c:match("([^%.]+)$") or c
    last = last:match("([^,%s]+)") or last
    local compact = AlnumLower(current)
    for _, token in ipairs(ShellTokens(shell)) do
        local needle = string.lower(token)
        if needle ~= "" and (last == needle or c:find(needle, 1, true)) then
            return true
        end
        local compactNeedle = AlnumLower(token)
        if compactNeedle ~= "" and compact:find(compactNeedle, 1, true) then
            return true
        end
    end
    return false
end

local function ShellByName(name)
    for i = 1, #SHELLS do
        if MatchesShell(SHELLS[i], name) then
            return SHELLS[i]
        end
    end
    return nil
end

local function RefreshShellLabels()
    for i = 1, #SHELLS do
        local shell = SHELLS[i]
        local label = shell.label
        if MatchesShell(shell, currentName) then
            label = label .. "  (equipped)"
        end
        ModMenu.SetButtonLabel(SECTION_ID, ShellButtonId(shell), label)
    end
end

---@param pc APlayerController
---@return string|nil, string[]
local function DetectCurrentShell(pc)
    local candidates = {}
    local function add(value)
        local text = TagToString(value) or ToLuaString(value)
        if text and text ~= "" then
            candidates[#candidates + 1] = text
        end
    end

    local pawn = pc.Pawn
    if IsValid(pawn) then
        local ok, id = pcall(function()
            return pawn:GetCharacterID()
        end)
        if ok then
            add(id)
        end
        add(ReadField(pawn, "CharacterId"))
        add(ReadField(pawn, "ShellIDTag"))
        pcall(function()
            add(pawn:GetClass():GetName())
        end)
        pcall(function()
            add(pawn:GetName())
        end)
    end

    local ui = FindCdo("BPFL_UI_C")
    if IsValid(ui) then
        local ok, name = pcall(function()
            return ui:GetEquippedShellName(pc)
        end)
        if ok then
            add(name)
        end
    end

    for i = 1, #candidates do
        if ShellByName(candidates[i]) then
            return candidates[i], candidates
        end
    end
    return nil, candidates
end

---@param pc APlayerController
---@param tag any
local function UnlockShellTag(pc, tag)
    if tag == nil then
        return
    end
    local eq = FindCdo("BPFL_Player_Equipment_C")
    if IsValid(eq) then
        pcall(function()
            eq:UnlockShell(tag, true, pc)
        end)
    end
    local save = pc.PlayerSaveGameObject
    if IsValid(save) then
        pcall(function()
            save:AddUnlockedEquipment(tag, true)
        end)
    end
end

---@param pc APlayerController
---@param shell table
local function UnlockMatchingTags(pc, shell)
    local playerFl = FindCdo("BPFL_Player_C")
    if not IsValid(playerFl) then
        return
    end
    local ok, container = pcall(function()
        return playerFl:GetShellsIDsTagContainer(pc)
    end)
    if not ok or container == nil then
        return
    end
    ForEachArrayItem(container.GameplayTags, function(tag)
        if MatchesShell(shell, TagToString(tag)) then
            UnlockShellTag(pc, tag)
            local eq = FindCdo("BPFL_Player_Equipment_C")
            if IsValid(eq) then
                pcall(function()
                    eq:ChangeShell(tag, true, pc)
                end)
            end
        end
    end)
end

---@param save UObject
---@return boolean
local function ClearHarrosPetrifiedFlag(save)
    if not IsValid(save) then
        return false
    end
    local before = ReadField(save, "Harros")
    if before == nil then
        return false
    end
    WriteField(save, "Harros", false)
    return true
end

---@param pc APlayerController
local function UnpetrifyHarros(pc)
    local cleared = 0
    ForEachLoaded("BPSO_PetrifiedCultistManager_C", function(save)
        if ClearHarrosPetrifiedFlag(save) then
            cleared = cleared + 1
        end
    end)
    ForEachLoaded("BP_LS_PetrifiedCultistManager_C", function(actor)
        local saveComp = ReadField(actor, "SpartaSave")
        if IsValid(saveComp) then
            local ok, data = pcall(function()
                return saveComp:GetRuntimeData()
            end)
            if not ok or not IsValid(data) then
                data = ReadField(saveComp, "RuntimeData")
            end
            if ClearHarrosPetrifiedFlag(data) then
                cleared = cleared + 1
            end
        end
        pcall(function()
            actor:SwitchCultistDatalayers()
        end)
    end)
    if cleared == 0 then
        local cdo = FindFirstOf("BPSO_PetrifiedCultistManager_C")
        local class = nil
        if IsValid(cdo) then
            pcall(function()
                class = cdo:GetClass()
            end)
        end
        local sub = FindFirstOf("SpartaSaveSubSystem")
        if IsValid(sub) and class ~= nil then
            pcall(function()
                local inst = sub:GetInstance(pc)
                if IsValid(inst) then
                    sub = inst
                end
            end)
            local ok, obj = pcall(function()
                return sub:GetSaveObjectByClassFromSlotIndex(sub:GetActiveSaveProfileSlotIndex(), class)
            end)
            if ok and ClearHarrosPetrifiedFlag(obj) then
                cleared = cleared + 1
            end
        end
    end
end

---@param pc APlayerController
---@param shell table
local function EquipShell(pc, shell)
    if shell.restore then
        UnpetrifyHarros(pc)
        local save = pc.PlayerSaveGameObject
        if IsValid(save) then
            pcall(function()
                save:UnlockDefaultPrologueEquip()
            end)
        end
    end

    UnlockMatchingTags(pc, shell)

    local game = FindCdo("SpartaGameSettings")
    if IsValid(game) then
        pcall(function()
            local inst = game:Get()
            if IsValid(inst) then
                game = inst
            end
        end)
        local ok, item = pcall(function()
            return game:GetShellItemDefinition(shell.name)
        end)
        if ok and item ~= nil then
            local save = pc.PlayerSaveGameObject
            if IsValid(save) then
                pcall(function()
                    save:SetActiveShell(item)
                end)
            end
            pcall(function()
                pc:SetShellItem(item)
            end)
            pcall(function()
                pc:ActivateShellFromItem(item)
            end)
        end
    end

    pcall(function()
        pc:S_SwitchToShell(shell.name)
    end)

    wantedName = shell.name
    -- Trust the click for the label. Proxima's id is not always "Proxima".
    currentName = shell.name
    local detected = DetectCurrentShell(pc)
    if detected and MatchesShell(shell, detected) then
        currentName = detected
    end
    RefreshShellLabels()
    Log("Equipped " .. shell.label)
end

local function ReapplyWantedShell()
    if wantedName == nil then
        return
    end
    local pc = GetPlayerController()
    if not pc then
        return
    end
    if type(pc.S_SwitchToShell) == "TrivialObject" then
        return
    end
    local shell = ShellByName(wantedName)
    if not shell then
        return
    end
    EquipShell(pc, shell)
    Log("Re-applied " .. shell.label .. " after restart")
end

function M.Register()
    local pc = GetPlayerController()
    if pc then
        currentName = DetectCurrentShell(pc)
        if currentName then
            Log("Current shell: " .. currentName)
        end
    end

    local items = {
        { type = "label", label = "S_SwitchToShell — skips the shrine gate." },
    }

    for i = 1, #SHELLS do
        local shell = SHELLS[i]
        local label = shell.label
        if MatchesShell(shell, currentName) then
            label = label .. "  (equipped)"
        end
        items[#items + 1] = {
            type = "button",
            id = ShellButtonId(shell),
            label = label,
            onClick = function()
                local controller = GetPlayerController()
                if not controller then
                    Log("Skipped: no player controller (load into a world first)")
                    return
                end
                EquipShell(controller, shell)
            end,
        }
    end

    ModMenu.Register({
        id = SECTION_ID,
        title = "Shells",
        items = items,
    })

    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        if wantedName == nil then
            return
        end
        if reapplyHandle then
            pcall(CancelDelayedAction, reapplyHandle)
            reapplyHandle = nil
        end
        reapplyHandle = ExecuteInGameThreadWithDelay(300, function()
            reapplyHandle = nil
            ReapplyWantedShell()
        end)
    end)
end

return M
