--[[
  Unlocks + Map tab.

  Most buttons call BP_PlayerController S_* cheats. Unlock All Shells also
  grants known tags and marks world pickups. Steam achievements fire with
  these — confirm before bulk unlocks.
]]

local ModMenu = require("ModMenu.ModMenu")
local Player = require("Player")

local M = {}

local SECTION_UNLOCKS = "Unlocks"
local SECTION_MAP = "Map"
local TAB_UNLOCKS = "Unlocks"

local Log = Player.Log
local IsValid = Player.IsValid
local GetPlayerController = Player.GetPlayerController
local CallOnPlayerController = Player.CallOnPlayerController
local ForEachArrayItem = Player.ForEachArrayItem
local ReadField = Player.ReadField
local WriteField = Player.WriteField
local FindCdo = Player.FindCdo

local FLASH_MS = 300
local buttonFlashHandles = {}
local toastHandles = {}

local TOAST_ID = {
    [SECTION_UNLOCKS] = "unlockToast",
    [SECTION_MAP] = "mapToast",
}

local ACHIEVE_CONFIRM = "Steam achievements unlock with this. Load into a world first."

---@param key string
---@param handles table
local function CancelHandle(handles, key)
    local handle = handles[key]
    if handle then
        pcall(CancelDelayedAction, handle)
        handles[key] = nil
    end
end

---@param sectionId string
---@param itemId string
---@param restoreVariant string
---@param ok boolean
---@param caption string
local function FlashUnlockFeedback(sectionId, itemId, restoreVariant, ok, caption)
    local flashKey = sectionId .. ":" .. itemId
    CancelHandle(buttonFlashHandles, flashKey)
    local flashVariant = ok and "success" or "danger"
    pcall(function()
        ModMenu.SetButtonVariant(sectionId, itemId, flashVariant)
    end)
    buttonFlashHandles[flashKey] = ExecuteInGameThreadWithDelay(FLASH_MS, function()
        buttonFlashHandles[flashKey] = nil
        pcall(function()
            ModMenu.SetButtonVariant(sectionId, itemId, restoreVariant)
        end)
    end)

    local toastId = TOAST_ID[sectionId]
    if toastId then
        CancelHandle(toastHandles, sectionId)
        local text
        if ok then
            text = "Done — " .. caption
        elseif GetPlayerController() then
            text = "Failed — " .. caption
        else
            text = "Skipped — load into a world first"
        end
        ModMenu.SetLabel(sectionId, toastId, text)
        toastHandles[sectionId] = ExecuteInGameThreadWithDelay(FLASH_MS, function()
            toastHandles[sectionId] = nil
            ModMenu.SetLabel(sectionId, toastId, "")
        end)
    end
end

local function PcButton(id, label, name, call, variant, sectionId, confirm)
    local restore = variant or "default"
    return {
        type = "button",
        id = id,
        label = label,
        variant = variant,
        confirm = confirm,
        onClick = function()
            local ok = CallOnPlayerController(name, call)
            if sectionId then
                FlashUnlockFeedback(sectionId, id, restore, ok, label)
            end
        end,
    }
end

local function BulkConfirm(label, message)
    return {
        title = label .. "?",
        message = message,
        confirmLabel = label,
    }
end

---@param value any
---@return string|nil
local function ToLuaString(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        return value
    end
    if type(value) == "userdata" then
        local ok, text = pcall(function()
            return value:ToString()
        end)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
    end
    local text = tostring(value)
    if text ~= nil and text ~= "" and text ~= "nil" then
        return text
    end
    return nil
end

---@param tag any
---@return string|nil
local function TagToString(tag)
    if tag == nil then
        return nil
    end
    local direct = ToLuaString(tag)
    if direct and not direct:find("userdata:", 1, true) then
        return direct
    end
    local ok, name = pcall(function()
        return tag.TagName
    end)
    if ok then
        return ToLuaString(name)
    end
    return nil
end

---@param arr any
---@return any[]
local function ArrayItems(arr)
    local list = {}
    ForEachArrayItem(arr, function(item)
        list[#list + 1] = item
    end)
    return list
end

---@return UObject|nil
local function GetEditorSettings()
    local settings = FindCdo("SpartaEditorSettings")
    if settings then
        local ok, inst = pcall(function()
            return settings:Get()
        end)
        if ok and IsValid(inst) then
            return inst
        end
        return settings
    end
    return nil
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

--- S_UnlockAllShells only hits the debug list. Also grant every known shell tag
--- and mark streamed BP_Interactable_Shell_Locked pickups as collected.
---@param pc APlayerController
local function UnlockAllShellsThorough(pc)
    pcall(function()
        pc:S_UnlockAllShells()
    end)

    local unlockedNames = {}
    local function note(name)
        if type(name) == "string" and name ~= "" and not unlockedNames[name] then
            unlockedNames[name] = true
        end
    end

    -- Debug cheat indices (ASG_Character_Player_ShellType is 0..14).
    for i = 0, 14 do
        pcall(function()
            pc:S_UnlockShell(i)
        end)
    end

    local settings = GetEditorSettings()
    if settings then
        local ok, options = pcall(function()
            return settings:GetShellOptions()
        end)
        if ok then
            for _, name in ipairs(ArrayItems(options)) do
                note(ToLuaString(name))
            end
        end
        local okDefault, defaultName = pcall(function()
            return settings:GetEditorDefaultShell()
        end)
        if okDefault then
            note(ToLuaString(defaultName))
        end
    end

    local playerFl = FindCdo("BPFL_Player_C")
    if IsValid(playerFl) then
        local ok, container = pcall(function()
            return playerFl:GetShellsIDsTagContainer(pc)
        end)
        if ok and container ~= nil then
            ForEachArrayItem(container.GameplayTags, function(tag)
                UnlockShellTag(pc, tag)
                note(TagToString(tag))
            end)
        end
    end

    local locked = FindAllOf("BP_Interactable_Shell_Locked_C")
    local marked = 0
    if locked then
        for _, actor in ipairs(locked) do
            if IsValid(actor) then
                WriteField(actor, "ShellUnlocked", true)
                local tag = ReadField(actor, "ShellId")
                UnlockShellTag(pc, tag)
                note(TagToString(tag))
                marked = marked + 1
            end
        end
    end

    local summons = FindAllOf("BP_InteractibleShellSummon_C")
    if summons then
        for _, summon in ipairs(summons) do
            if IsValid(summon) then
                pcall(function()
                    summon:CheckForShellUnlock()
                end)
            end
        end
    end

    local count = 0
    for _ in pairs(unlockedNames) do
        count = count + 1
    end
    Log(string.format("Unlock All Shells: %d tag(s), %d world pickup(s) marked", count, marked))
end

local registered = false

function M.Register()
    if registered then
        return
    end
    registered = true

    ModMenu.Register({
        id = SECTION_UNLOCKS,
        title = "Unlocks",
        tab = TAB_UNLOCKS,
        collapsible = true,
        collapsed = false,
        items = {
            {
                type = "label",
                label = "Steam achievements unlock with these. Load into a world first.",
            },
            { type = "separator" },
            PcButton("clothing", "Unlock All Clothing", "S_UnlockAllClothing", function(pc) pc:S_UnlockAllClothing() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Clothing", ACHIEVE_CONFIRM)),
            PcButton("gates", "Unlock All Gates", "S_UnlockAllGates", function(pc) pc:S_UnlockAllGates() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Gates", ACHIEVE_CONFIRM)),
            PcButton("landing", "Unlock All Landing Areas", "S_UnlockAllLandingAreas",
                function(pc) pc:S_UnlockAllLandingAreas() end, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock All Landing Areas", ACHIEVE_CONFIRM)),
            PcButton("masks", "Unlock All Masks", "S_UnlockAllMasks", function(pc) pc:S_UnlockAllMasks() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Masks", ACHIEVE_CONFIRM)),
            PcButton("seals", "Unlock All Seals", "S_UnlockAllSeals", function(pc) pc:S_UnlockAllSeals() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Seals", ACHIEVE_CONFIRM)),
            PcButton("shells", "Unlock All Shells", "UnlockAllShells", UnlockAllShellsThorough, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock All Shells", ACHIEVE_CONFIRM)),
            PcButton("sidearms", "Unlock All Sidearms", "S_UnlockAllSidearms", function(pc) pc:S_UnlockAllSidearms() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Sidearms", ACHIEVE_CONFIRM)),
            PcButton("weapons", "Unlock All Weapons", "S_UnlockAllWeapons", function(pc) pc:S_UnlockAllWeapons() end, nil,
                SECTION_UNLOCKS, BulkConfirm("Unlock All Weapons", ACHIEVE_CONFIRM)),
            PcButton("shellShades", "Unlock Shell Shades", "S_UnlockShellShades",
                function(pc) pc:S_UnlockShellShades() end, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock Shell Shades", ACHIEVE_CONFIRM)),
            PcButton("red", "Unlock Red Harbinger", "S_UnlockRedHarbinger",
                function(pc) pc:S_UnlockRedHarbinger() end, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock Red Harbinger", ACHIEVE_CONFIRM)),
            PcButton("cosmic", "Unlock Cosmic Harbinger", "S_UnlockCosmicHarbinger",
                function(pc) pc:S_UnlockCosmicHarbinger() end, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock Cosmic Harbinger", ACHIEVE_CONFIRM)),
            PcButton("darkShades", "Unlock Dark Form Shades", "S_UnlockDarkFormShades",
                function(pc) pc:S_UnlockDarkFormShades() end, nil, SECTION_UNLOCKS,
                BulkConfirm("Unlock Dark Form Shades", ACHIEVE_CONFIRM)),
            {
                type = "label",
                id = "unlockToast",
                label = "",
            },
        },
    })

    ModMenu.Register({
        id = SECTION_MAP,
        title = "Map",
        tab = TAB_UNLOCKS,
        collapsible = true,
        collapsed = true,
        items = {
            {
                type = "label",
                label = "Unlock Map fills the map. Reveal All paints every icon and autosaves — cannot undo.",
            },
            PcButton("unlockMap", "Unlock Map", "S_UnlockMap", function(pc) pc:S_UnlockMap() end, "primary", SECTION_MAP,
                BulkConfirm("Unlock Map", "Fills the map. Load into a world first.")),
            PcButton("fastTravel", "Unlock Fast Travel", "S_UnlockFastTravel",
                function(pc) pc:S_UnlockFastTravel() end, nil, SECTION_MAP),
            PcButton("revealAll", "Reveal All Icons", "S_MapReveal_All",
                function(pc) pc:S_MapReveal_All() end, nil, SECTION_MAP,
                BulkConfirm("Reveal All Icons", "Paints every icon and autosaves. This cannot be undone.")),
            {
                type = "label",
                id = "mapToast",
                label = "",
            },
        },
    })
end

return M
