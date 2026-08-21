--[[
  Tarstone levels — UTarstoneSaveData.Level is 0-based.

  Stored 0 = UI "LEVEL 1" (base). Two diamonds = stored 1, 2 (UI 2, 3).
  Menu shows UI levels 1 / 3. Never write stored < 0 or > 2.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

local M = {}

local SECTION_ID = "Tarstones"
local STATUS_ID = "tarLevelStatus"
local NOTE_ID = "tarReequipNote"
local REEQUIP_NOTE = "Re-equip tarstones to see the new effects."
local TOAST_MS = 3000
local STORED_MIN = 0
local STORED_MAX = 2
local UI_MAX = STORED_MAX + 1

local function ToUI(stored)
    return stored + 1
end

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

local function GetPawn(pc)
    pc = pc or UEHelpers.GetPlayerController()
    if not IsValid(pc) then
        return nil, nil
    end
    local pawn = pc.Pawn
    if not IsValid(pawn) then
        return pc, nil
    end
    return pc, pawn
end

local function GetComponent(pawn)
    if not IsValid(pawn) then
        return nil
    end
    local comp = pawn.TarstoneComponent
    if IsValid(comp) then
        return comp
    end
    return nil
end

---@return UTarstoneSaveData|nil
local function GetRuntimeData(comp)
    if not IsValid(comp) then
        return nil
    end
    local rd = nil
    pcall(function()
        rd = comp:GetRuntimeData()
    end)
    if IsValid(rd) then
        return rd
    end
    rd = comp.RuntimeData
    if IsValid(rd) then
        return rd
    end
    return nil
end

local function ReadLevel(value)
    local data = value:get()
    if data == nil then
        return nil, nil
    end
    return tonumber(data.Level), data
end

local function MapMax(map)
    local maxLv, count = nil, 0
    if map == nil then
        return nil, 0
    end
    map:ForEach(function(_, value)
        local level = ReadLevel(value)
        if level == nil then
            return
        end
        count = count + 1
        if maxLv == nil or level > maxLv then
            maxLv = level
        end
    end)
    return maxLv, count
end

--- Save-object map first (what Live View showed). Component map is fallback.
local function GetLevelsMap(comp)
    local rd = GetRuntimeData(comp)
    if IsValid(rd) and rd.TarstoneLevels ~= nil then
        return rd.TarstoneLevels, "RuntimeData"
    end
    return comp.TarstoneLevels, "Component"
end

local function WriteLevel(value, data, newLevel)
    data.Level = newLevel
    if data.exp ~= nil and newLevel ~= tonumber(data.Level) then
        -- keep exp unless we just changed level
    end
    value:set(data)
end

local function ApplyToEquipped(comp, class, newLevel, data)
    if not IsValid(comp) or class == nil then
        return
    end
    local payload = {
        Level = newLevel,
        exp = (data and data.exp) or 0,
        Durability = (data and data.Durability) or 0,
    }
    local function trySet(map)
        if map == nil then
            return
        end
        pcall(function()
            local wrapped = map:Find(class)
            local inst = wrapped
            if wrapped ~= nil and type(wrapped.get) == "function" then
                inst = wrapped:get()
            end
            if IsValid(inst) then
                comp:SetTarstoneLevel(inst, payload)
            end
        end)
    end
    trySet(comp.EquippedTarstoneItemInstances)
    trySet(comp.EquippedSupportTarstoneItemInstances)
end

--- Walk the save map. fn(class, data, value, level)
local function ForEachLevel(pc, fn)
    local _, pawn = GetPawn(pc)
    local comp = GetComponent(pawn)
    if not IsValid(comp) then
        return 0, nil
    end
    local map, source = GetLevelsMap(comp)
    if map == nil then
        return 0, source
    end
    local n = 0
    map:ForEach(function(key, value)
        local class = key:get()
        local level, data = ReadLevel(value)
        if level == nil then
            return
        end
        n = n + 1
        fn(class, data, value, level, comp)
    end)
    return n, source
end

local function FormatStatus(current, count, source)
    if count == 0 then
        return "Tarstone level: — (none collected)"
    end
    local extra = ""
    if source then
        extra = " [" .. source .. "]"
    end
    return string.format("Tarstone level: %d / %d (%d stones)%s", ToUI(current), UI_MAX, count, extra)
end

function M.RefreshStatus(pc)
    local _, pawn = GetPawn(pc)
    local comp = GetComponent(pawn)
    if not IsValid(comp) then
        ModMenu.SetLabel(SECTION_ID, STATUS_ID, "Tarstone level: — (load a world)")
        return
    end

    local rd = GetRuntimeData(comp)
    local rtMax, rtCount = 0, 0
    local cpMax, cpCount = 0, 0
    pcall(function()
        if IsValid(rd) then
            rtMax, rtCount = MapMax(rd.TarstoneLevels)
        end
        cpMax, cpCount = MapMax(comp.TarstoneLevels)
    end)

    local source = "RuntimeData"
    local current, count = rtMax, rtCount
    if count == 0 then
        current, count = cpMax, cpCount
        source = "Component"
    end
    if count == 0 then
        ModMenu.SetLabel(SECTION_ID, STATUS_ID, FormatStatus(0, 0))
        return
    end
    ModMenu.SetLabel(SECTION_ID, STATUS_ID, FormatStatus(current, count, source))
end

local function SetAllTo(pc, newLevel)
    local changed = 0
    local ok, err = pcall(function()
        ForEachLevel(pc, function(class, data, value, _, comp)
            WriteLevel(value, data, newLevel)
            ApplyToEquipped(comp, class, newLevel, data)
            changed = changed + 1
        end)
        -- Keep component copy in sync if it is a second map.
        local _, pawn = GetPawn(pc)
        local comp = GetComponent(pawn)
        local rd = GetRuntimeData(comp)
        if IsValid(comp) and IsValid(rd) and comp.TarstoneLevels ~= nil and rd.TarstoneLevels ~= nil then
            pcall(function()
                comp.TarstoneLevels:ForEach(function(_, value)
                    local level, data = ReadLevel(value)
                    if level ~= nil and level ~= newLevel then
                        WriteLevel(value, data, newLevel)
                    end
                end)
            end)
        end
    end)
    if not ok then
        Log("Set tarstone levels failed — " .. tostring(err))
        return 0
    end
    return changed
end

local toastHandle = nil
local toastFn = nil

local function ShowReequipToast()
    if toastHandle then
        pcall(CancelDelayedAction, toastHandle)
        toastHandle = nil
    end
    ModMenu.SetLabel(SECTION_ID, NOTE_ID, REEQUIP_NOTE)
    toastFn = function()
        toastHandle = nil
        ModMenu.SetLabel(SECTION_ID, NOTE_ID, "")
    end
    toastHandle = ExecuteInGameThreadWithDelay(TOAST_MS, toastFn)
end

---@param pc APlayerController
function M.IncrementAll(pc)
    local current = nil
    pcall(function()
        ForEachLevel(pc, function(_, _, _, level)
            if current == nil or level > current then
                current = level
            end
        end)
    end)
    if current == nil then
        Log("Increment tarstones: no levels map")
        M.RefreshStatus(pc)
        return
    end
    if current >= STORED_MAX then
        Log(string.format("Tarstones already at max (UI %d / %d, stored %d)", UI_MAX, UI_MAX, STORED_MAX))
        M.RefreshStatus(pc)
        return
    end
    local next = math.min(current + 1, STORED_MAX)
    local n = SetAllTo(pc, next)
    Log(string.format("Tarstones stored %d -> %d (UI %d -> %d, %d stones)", current, next, ToUI(current), ToUI(next), n))
    M.RefreshStatus(pc)
    if n > 0 then
        ShowReequipToast()
    end
end

---@param pc APlayerController
function M.DecrementAll(pc)
    local current = nil
    pcall(function()
        ForEachLevel(pc, function(_, _, _, level)
            if current == nil or level > current then
                current = level
            end
        end)
    end)
    if current == nil then
        Log("Decrement tarstones: no levels map")
        M.RefreshStatus(pc)
        return
    end
    if current <= STORED_MIN then
        Log(string.format("Tarstones already at min (UI %d, stored %d)", ToUI(STORED_MIN), STORED_MIN))
        M.RefreshStatus(pc)
        return
    end
    local next = math.max(current - 1, STORED_MIN)
    local n = SetAllTo(pc, next)
    Log(string.format("Tarstones stored %d -> %d (UI %d -> %d, %d stones)", current, next, ToUI(current), ToUI(next), n))
    M.RefreshStatus(pc)
    if n > 0 then
        ShowReequipToast()
    end
end

return M
