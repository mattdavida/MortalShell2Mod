--[[
  Tarstones — add from in-game DTs, plus bulk level.

  Add: category + searchable stone, grant via AddTarstoneToItemManager
  (toast on) plus AddTarstoneToInventory. UpdateSoftItemStatus on the DT
  soft class so the HUD leaves UNCOLLECTED and files it under Combat /
  Infusions. Never pass a resolved UClass into TSoftClassPtr APIs (AV).
  Labels prefer BuildTarstoneName, then ItemFragment_Display, then CDO.
  Never call Kismet FText / loc-table APIs (native crash).

  Levels — UTarstoneSaveData.Level is 0-based.
  Stored 0 = UI "LEVEL 1" (base). Two diamonds = stored 1, 2 (UI 2, 3).
  Menu shows UI levels 1 / 3. Never write stored < 0 or > 2.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

local M = {}

local SECTION_ID = "Tarstones"
local STATUS_ID = "tarLevelStatus"
local ADD_STATUS_ID = "tarAddStatus"
local STONE_ID = "tarStone"
local CATEGORY_ID = "tarCategory"
local COLLECTED_ID = "tarLevelStone"
local ONE_STATUS_ID = "tarOneLevelStatus"
local INC_ONE_ID = "tarLevelOne"
local DEC_ONE_ID = "tarLevelOneDown"
local NOTE_ID = "tarReequipNote"
local ADD_TOAST_ID = "tarAddToast"
local REEQUIP_NOTE = "Re-equip tarstones to see the new effects."
local TOAST_MS = 3000
local FLASH_MS = 300
local STORED_MIN = 0
local STORED_MAX = 2
local UI_MAX = STORED_MAX + 1
local NONE = "__none__"
local UTIL_CDO = "Default__BPFL_Utility_C"
local TAR_LIB_CDO = "Default__BPFL_Tarstones_C"
local PLAYER_LIB_CDO = "Default__BPFL_Player_C"
local SAVE_LIB_CDO = "Default__BPFL_SaveLoad_C"
local GES_CDO = "Default__GESFunctions"
local REFRESH_EVENT = "GlobalEvent_RefreshTarstoneInventory_C"
local ITEM_LIB_CDO = "/Script/Sparta.Default__SpartaItemFunctionLibrary"
local DISPLAY_FRAG = "/Script/Sparta.ItemFragment_Display"
local NOT_READY = "Tarstone tables not loaded — open the menu in a world."

local CAT_ALL = "All"
local CAT_MELEE = "Melee"
local CAT_SIDEARM = "Sidearm"
local CAT_SUPPORT = "Support"

local CATALOGS = {
    {
        id = CAT_MELEE,
        label = "Melee",
        path = "/Game/Sparta/Core/Tarstones/Melee/DT_Tarstones_Melee.DT_Tarstones_Melee",
        tableField = "MeleeTarstoneTable",
    },
    {
        id = CAT_SIDEARM,
        label = "Sidearm",
        path = "/Game/Sparta/Core/Tarstones/Sidearm/DT_Tarstones_Sidearm.DT_Tarstones_Sidearm",
        tableField = "SidearmTarstoneTable",
    },
    {
        id = CAT_SUPPORT,
        label = "Support",
        path = "/Game/Sparta/Core/Tarstones/Support/DT_Tarstones_Support.DT_Tarstones_Support",
        tableField = "SupportTarstoneTable",
    },
}

local CATEGORY_OPTIONS = {
    { label = "All", value = CAT_ALL },
    { label = "Melee", value = CAT_MELEE },
    { label = "Sidearm", value = CAT_SIDEARM },
    { label = "Support", value = CAT_SUPPORT },
}

local addState = {
    category = CAT_ALL,
    stoneId = nil,
    itemsByCategory = {},
    status = NOT_READY,
    named = false,
    frozen = false,
    resolveTried = false,
}

local levelState = {
    stoneId = NONE,
    options = {},
    byKey = {},
    status = "Selected level: —",
}

local cachedUtil = nil
local cachedTarLib = nil
local cachedPlayerLib = nil
local cachedSaveLib = nil
local cachedItemLib = nil
local cachedGes = nil
local cachedDisplayFragClass = nil
local skipBuildName = false
local skipFrag = false

local function ToUI(stored)
    return stored + 1
end

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

local function AsString(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        if value == "" then
            return nil
        end
        return value
    end
    if type(value) == "userdata" or type(value) == "table" then
        local ok, text = pcall(function()
            return value:ToString()
        end)
        if ok and type(text) == "string" and text ~= "" then
            return text
        end
        return nil
    end
    local text = tostring(value)
    if text ~= nil and text ~= "" and text ~= "nil" then
        return text
    end
    return nil
end

local function FindCdo(name)
    local obj = nil
    pcall(function()
        obj = FindObject(nil, name)
    end)
    if IsValid(obj) then
        return obj
    end
    return nil
end

local function GetUtility()
    if IsValid(cachedUtil) then
        return cachedUtil
    end
    cachedUtil = FindCdo(UTIL_CDO)
    return cachedUtil
end

local function GetTarLib()
    if IsValid(cachedTarLib) then
        return cachedTarLib
    end
    cachedTarLib = FindCdo(TAR_LIB_CDO)
    return cachedTarLib
end

local function GetPlayerLib()
    if IsValid(cachedPlayerLib) then
        return cachedPlayerLib
    end
    cachedPlayerLib = FindCdo(PLAYER_LIB_CDO)
    return cachedPlayerLib
end

local function GetSaveLib()
    if IsValid(cachedSaveLib) then
        return cachedSaveLib
    end
    cachedSaveLib = FindCdo(SAVE_LIB_CDO)
    return cachedSaveLib
end

--- HUD UNCOLLECTED vs Combat/Infusions. DT TSoftClassPtr only — never a UClass.
local function MarkSoftCollected(soft, world)
    if soft == nil then
        return false
    end
    local saveLib = GetSaveLib()
    if not IsValid(saveLib) or not IsValid(world) then
        return false
    end
    local ok, err = pcall(function()
        saveLib:UpdateSoftItemStatus(soft, world)
    end)
    if not ok then
        Log("Tarstones: UpdateSoftItemStatus failed — " .. tostring(err))
        return false
    end
    return true
end

local function GetGes()
    if IsValid(cachedGes) then
        return cachedGes
    end
    cachedGes = FindCdo(GES_CDO)
    if IsValid(cachedGes) then
        return cachedGes
    end
    pcall(function()
        cachedGes = StaticFindObject("/Script/GlobalEventSystem.Default__GESFunctions")
    end)
    if IsValid(cachedGes) then
        return cachedGes
    end
    cachedGes = nil
    return nil
end

local function GetItemLib()
    if IsValid(cachedItemLib) then
        return cachedItemLib
    end
    cachedItemLib = nil
    pcall(function()
        cachedItemLib = StaticFindObject(ITEM_LIB_CDO)
    end)
    if IsValid(cachedItemLib) then
        return cachedItemLib
    end
    cachedItemLib = nil
    return nil
end

local function GetDisplayFragClass()
    if IsValid(cachedDisplayFragClass) then
        return cachedDisplayFragClass
    end
    cachedDisplayFragClass = nil
    pcall(function()
        cachedDisplayFragClass = StaticFindObject(DISPLAY_FRAG)
    end)
    if IsValid(cachedDisplayFragClass) then
        return cachedDisplayFragClass
    end
    cachedDisplayFragClass = nil
    return nil
end

local function GetWorldCtx()
    local world = UEHelpers.GetWorldContextObject()
    if IsValid(world) then
        return world
    end
    world = UEHelpers.GetWorld()
    if IsValid(world) then
        return world
    end
    return nil
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

--- TMap ForEach key/value are always RemoteUnrealParam. Always :get() here.
--- Do not use this on GameplayTag / arbitrary UE structs.
local function MapGet(param)
    if param == nil then
        return nil
    end
    local ok, inner = pcall(function()
        return param:get()
    end)
    if ok and inner ~= nil then
        return inner
    end
    return param
end

local function ReadLevel(value)
    local data = MapGet(value)
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

local function MapEntryCount(map)
    local n = 0
    if map == nil then
        return 0
    end
    pcall(function()
        map:ForEach(function()
            n = n + 1
        end)
    end)
    return n
end

--- Prefer the map that actually has stones. RuntimeData can exist but stay empty
--- after a single AddTarstoneToItemManager grant.
local function GetLevelsMap(comp)
    local rd = GetRuntimeData(comp)
    local rt = nil
    if IsValid(rd) then
        rt = rd.TarstoneLevels
    end
    local cp = nil
    if IsValid(comp) then
        cp = comp.TarstoneLevels
    end
    local rtN = MapEntryCount(rt)
    local cpN = MapEntryCount(cp)
    if rtN > 0 then
        return rt, "RuntimeData"
    end
    if cpN > 0 then
        return cp, "Component"
    end
    if rt ~= nil then
        return rt, "RuntimeData"
    end
    return cp, "Component"
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
            local inst = MapGet(map:Find(class))
            if IsValid(inst) then
                comp:SetTarstoneLevel(inst, payload)
            end
        end)
    end
    trySet(comp.EquippedTarstoneItemInstances)
    trySet(comp.EquippedSupportTarstoneItemInstances)
end

--- Walk both save maps. Newly granted stones often sit only on the
--- component map while RuntimeData still has the older set.
local function ForEachLevelMap(map, comp, fn)
    if map == nil then
        return 0
    end
    local n = 0
    map:ForEach(function(key, value)
        local class = MapGet(key)
        local level, data = ReadLevel(value)
        if class == nil or level == nil then
            return
        end
        n = n + 1
        fn(class, data, value, level, comp)
    end)
    return n
end

--- Walk both maps. fn(class, data, value, level, comp)
local function ForEachLevel(pc, fn)
    local _, pawn = GetPawn(pc)
    local comp = GetComponent(pawn)
    if not IsValid(comp) then
        return 0, nil
    end
    local rd = GetRuntimeData(comp)
    local n = 0
    local source = nil
    if IsValid(rd) and rd.TarstoneLevels ~= nil then
        local c = ForEachLevelMap(rd.TarstoneLevels, comp, fn)
        if c > 0 then
            n = n + c
            source = "RuntimeData"
        end
    end
    if IsValid(comp) and comp.TarstoneLevels ~= nil then
        local c = ForEachLevelMap(comp.TarstoneLevels, comp, fn)
        if c > 0 then
            n = n + c
            if source == nil then
                source = "Component"
            else
                source = "RuntimeData+Component"
            end
        end
    end
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
    end)
    if not ok then
        Log("Set tarstone levels failed — " .. tostring(err))
        return 0
    end
    return changed
end

--- ID_Sidearm_Deadshot_C from GetName, GetFullName, or ToString.
local function NormalizeClassKey(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local last = text:match("([^/%.]+)$")
    if last ~= nil and last ~= "" then
        return last
    end
    return text
end

local function ClassKey(class)
    if class == nil then
        return nil
    end
    class = MapGet(class)
    local name = nil
    pcall(function()
        if class.GetName then
            name = class:GetName()
        end
    end)
    name = NormalizeClassKey(AsString(name))
    if name ~= nil then
        return name
    end
    local full = nil
    pcall(function()
        if class.GetFullName then
            full = class:GetFullName()
        end
    end)
    name = NormalizeClassKey(AsString(full))
    if name ~= nil then
        return name
    end
    return NormalizeClassKey(AsString(class))
end

local function SameClass(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local ka = ClassKey(a)
    local kb = ClassKey(b)
    return ka ~= nil and ka == kb
end

local function ClassesMatch(class, targetClass, targetKey)
    if SameClass(class, targetClass) then
        return true
    end
    local want = NormalizeClassKey(AsString(targetKey)) or ClassKey(targetClass)
    local have = ClassKey(class)
    return want ~= nil and have ~= nil and want == have
end

local function SetOneTo(pc, targetClass, newLevel, targetKey)
    local changed = 0
    local ok, err = pcall(function()
        ForEachLevel(pc, function(class, data, value, _, comp)
            if not ClassesMatch(class, targetClass, targetKey) then
                return
            end
            WriteLevel(value, data, newLevel)
            ApplyToEquipped(comp, class, newLevel, data)
            changed = changed + 1
        end)
    end)
    if not ok then
        Log("Set one tarstone level failed — " .. tostring(err))
        return 0
    end
    return changed
end

local toastHandle = nil
local toastFn = nil
local buttonFlashHandles = {}
local addToastHandle = nil

local function CancelHandle(handles, key)
    local handle = handles[key]
    if handle then
        pcall(CancelDelayedAction, handle)
        handles[key] = nil
    end
end

local function FlashFeedback(itemId, ok, caption)
    local flashKey = SECTION_ID .. ":" .. itemId
    CancelHandle(buttonFlashHandles, flashKey)
    local flashVariant = ok and "success" or "danger"
    pcall(function()
        ModMenu.SetButtonVariant(SECTION_ID, itemId, flashVariant)
    end)
    buttonFlashHandles[flashKey] = ExecuteInGameThreadWithDelay(FLASH_MS, function()
        buttonFlashHandles[flashKey] = nil
        pcall(function()
            ModMenu.SetButtonVariant(SECTION_ID, itemId, "default")
        end)
    end)

    if addToastHandle then
        pcall(CancelDelayedAction, addToastHandle)
        addToastHandle = nil
    end
    local text
    if ok then
        text = "Done — " .. caption
    else
        local pc = UEHelpers.GetPlayerController()
        if IsValid(pc) then
            text = "Failed — " .. caption
        else
            text = "Skipped — load into a world first"
        end
    end
    ModMenu.SetLabel(SECTION_ID, ADD_TOAST_ID, text)
    addToastHandle = ExecuteInGameThreadWithDelay(FLASH_MS, function()
        addToastHandle = nil
        ModMenu.SetLabel(SECTION_ID, ADD_TOAST_ID, "")
    end)
end

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
    if M.RefreshCollected then
        M.RefreshCollected(pc, true)
    end
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
    if M.RefreshCollected then
        M.RefreshCollected(pc, true)
    end
    if n > 0 then
        ShowReequipToast()
    end
end

local function PlaceholderOptions()
    return { { label = "(load a world, then reopen)", value = NONE } }
end

local function CatalogById(id)
    for _, cat in ipairs(CATALOGS) do
        if cat.id == id then
            return cat
        end
    end
    return CATALOGS[1]
end

local function StoneOptions()
    local list = addState.itemsByCategory[addState.category or CAT_ALL]
    if list == nil or #list == 0 then
        return PlaceholderOptions()
    end
    return list
end

local function GetDataTable(cat)
    if cat == nil then
        return nil
    end
    local dt = nil
    pcall(function()
        dt = StaticFindObject(cat.path)
    end)
    if IsValid(dt) then
        return dt
    end
    local _, pawn = GetPawn()
    local comp = GetComponent(pawn)
    if IsValid(comp) and cat.tableField then
        dt = comp[cat.tableField]
        if IsValid(dt) then
            return dt
        end
    end
    return nil
end

--- Soft class -> localized name. BuildTarstoneName first, then fragment, then CDO.
local function FragmentDisplayName(itemClass)
    if skipFrag or itemClass == nil then
        return nil
    end
    local lib = GetItemLib()
    local fragClass = GetDisplayFragClass()
    if not IsValid(lib) or not IsValid(fragClass) then
        skipFrag = true
        Log("Tarstones: display fragment class missing — CDO names only")
        return nil
    end
    local frag = nil
    local ok, err = pcall(function()
        frag = lib:FindItemDefinitionFragment(itemClass, fragClass)
    end)
    if not ok then
        skipFrag = true
        Log("Tarstones: skip display fragment — " .. tostring(err))
        return nil
    end
    if not IsValid(frag) then
        return nil
    end
    return AsString(frag.DisplayName)
end

local function CdoDisplayName(itemClass)
    if itemClass == nil then
        return nil
    end
    local def = itemClass
    pcall(function()
        if itemClass.GetCDO then
            def = itemClass:GetCDO()
        elseif itemClass.GetDefaultObject then
            def = itemClass:GetDefaultObject()
        end
    end)
    if not IsValid(def) then
        return nil
    end
    return AsString(def.DisplayName)
end

local function ResolveSoftClass(softClass, util, world)
    if softClass == nil or not IsValid(util) or not IsValid(world) then
        return nil
    end
    local cls = nil
    local ok = pcall(function()
        cls = util:ResolveSoftItemDefinition(softClass, world)
    end)
    if ok and IsValid(cls) then
        return cls
    end
    return nil
end

local function BuildName(softClass, world)
    if skipBuildName or softClass == nil or not IsValid(world) then
        return nil
    end
    local lib = GetTarLib()
    if not IsValid(lib) then
        skipBuildName = true
        return nil
    end
    local text = nil
    local ok, err = pcall(function()
        text = lib:BuildTarstoneName(softClass, false, world)
    end)
    if not ok then
        skipBuildName = true
        Log("Tarstones: skip BuildTarstoneName — " .. tostring(err))
        return nil
    end
    return AsString(text)
end

local function ResolveDisplayName(softClass, util, world)
    local built = BuildName(softClass, world)
    if built ~= nil then
        return built
    end
    local cls = ResolveSoftClass(softClass, util, world)
    if cls == nil then
        return nil
    end
    local fragName = FragmentDisplayName(cls)
    if fragName ~= nil then
        return fragName
    end
    return CdoDisplayName(cls)
end

local function FormatItemLabel(display, id)
    if display == nil or display == "" or display == id then
        return id
    end
    display = (display:gsub("%s+$", ""):gsub("^%s+", ""))
    return string.format("%s (%s)", display, id)
end

local function LoadCatalog(cat, resolveNames)
    local dt = GetDataTable(cat)
    if not IsValid(dt) then
        return nil, "not found", 0
    end

    local util = nil
    local world = nil
    if resolveNames then
        util = GetUtility()
        world = GetWorldCtx()
        if IsValid(world) then
            addState.resolveTried = true
        else
            resolveNames = false
        end
        if not IsValid(util) then
            util = nil
        end
    end

    local opts = {}
    local named = 0
    local ok, err = pcall(function()
        dt:ForEachRow(function(rowName, rowData)
            local id = AsString(rowName)
            if id == nil then
                return
            end
            local display = nil
            if resolveNames and rowData ~= nil then
                display = ResolveDisplayName(rowData.ItemClass, util, world)
            end
            if display ~= nil then
                named = named + 1
            end
            opts[#opts + 1] = {
                label = FormatItemLabel(display, id),
                value = id,
            }
        end)
    end)
    if not ok then
        return nil, tostring(err), 0
    end

    table.sort(opts, function(a, b)
        return tostring(a.label) < tostring(b.label)
    end)
    return opts, nil, named
end

local function MergeAllCatalogs()
    local merged = {}
    local seen = {}
    for _, cat in ipairs(CATALOGS) do
        local list = addState.itemsByCategory[cat.id]
        if list ~= nil then
            for i = 1, #list do
                local opt = list[i]
                local id = opt and opt.value
                if id ~= nil and seen[id] == nil then
                    seen[id] = true
                    merged[#merged + 1] = {
                        label = opt.label,
                        value = id,
                    }
                end
            end
        end
    end
    table.sort(merged, function(a, b)
        return tostring(a.label) < tostring(b.label)
    end)
    addState.itemsByCategory[CAT_ALL] = merged
end

local function FormatAddStatus()
    local all = addState.itemsByCategory[CAT_ALL]
    local parts = {
        string.format("All %d", all and #all or 0),
    }
    for _, cat in ipairs(CATALOGS) do
        local list = addState.itemsByCategory[cat.id]
        parts[#parts + 1] = string.format("%s %d", cat.label, list and #list or 0)
    end
    return table.concat(parts, " · ")
end

local function LoadDb(resolveNames)
    local loaded = 0
    local failed = 0
    local named = 0
    for _, cat in ipairs(CATALOGS) do
        local opts, err, n = LoadCatalog(cat, resolveNames)
        if opts ~= nil and #opts > 0 then
            addState.itemsByCategory[cat.id] = opts
            loaded = loaded + 1
            named = named + (n or 0)
        else
            failed = failed + 1
            Log(string.format("Tarstones: %s table failed (%s)", cat.id, tostring(err or "empty")))
        end
    end

    if loaded == 0 then
        addState.status = NOT_READY
        addState.named = false
        return false
    end

    MergeAllCatalogs()
    addState.named = resolveNames and named > 0
    addState.status = FormatAddStatus()
    Log(string.format(
        "Tarstones: loaded %d catalogs named=%d resolve=%s (%d failed)",
        loaded,
        named,
        tostring(addState.named),
        failed
    ))
    return true
end

local function ApplyStoneOptions()
    local opts = StoneOptions()
    addState.stoneId = nil
    pcall(function()
        ModMenu.Set(SECTION_ID, STONE_ID, nil)
        ModMenu.SetOptions(SECTION_ID, STONE_ID, opts, false)
        ModMenu.SetLabel(SECTION_ID, ADD_STATUS_ID, addState.status)
    end)
end

local function CatalogReady()
    for _, cat in ipairs(CATALOGS) do
        local list = addState.itemsByCategory[cat.id]
        if list ~= nil and #list > 0 then
            return true
        end
    end
    return false
end

local function CollectedNoneOption()
    return { label = "None", value = NONE }
end

local function CollectedOptions()
    if levelState.options == nil or #levelState.options == 0 then
        return { CollectedNoneOption() }
    end
    return levelState.options
end

local function OneStoneStatusText()
    local id = levelState.stoneId
    if id == nil or id == NONE then
        if next(levelState.byKey) == nil then
            return "Selected level: — (none collected)"
        end
        return "Selected level: —"
    end
    local entry = levelState.byKey[id]
    if entry == nil then
        return "Selected level: —"
    end
    local name = entry.display or id
    return string.format("%s: %d / %d", name, ToUI(entry.stored), UI_MAX)
end

--- HUD / CDO only. Do not call BuildTarstoneName with a UClass — UE4SS
--- crashes in push_softobjectproperty (null FString) on TSoftClassPtr args.
local function CollectedDisplayName(class)
    return FragmentDisplayName(class) or CdoDisplayName(class)
end

local function AddCollectedEntry(class, stored, fallbackKey)
    local key = ClassKey(class) or AsString(fallbackKey)
    if key == nil then
        return false
    end
    stored = tonumber(stored) or STORED_MIN
    local existing = levelState.byKey[key]
    if existing ~= nil then
        if stored > (existing.stored or STORED_MIN) then
            existing.stored = stored
        end
        if existing.class == nil then
            existing.class = class
        end
        return false
    end
    local display = CollectedDisplayName(class)
    levelState.byKey[key] = {
        class = class,
        stored = stored,
        display = display or key,
    }
    return true
end

local function RebuildCollectedOptions()
    local opts = { CollectedNoneOption() }
    for key, entry in pairs(levelState.byKey) do
        local name = entry.display
        if name == nil or name == "" or name == key then
            name = key
        end
        opts[#opts + 1] = {
            label = string.format("%s  %d/%d", name, ToUI(entry.stored or STORED_MIN), UI_MAX),
            value = key,
        }
    end
    table.sort(opts, function(a, b)
        if a.value == NONE then
            return true
        end
        if b.value == NONE then
            return false
        end
        return tostring(a.label) < tostring(b.label)
    end)
    levelState.options = opts
end

local function WalkLevelsMapIntoCollected(map)
    local n = 0
    if map == nil then
        return 0
    end
    pcall(function()
        map:ForEach(function(key, value)
            local class = MapGet(key)
            local level = ReadLevel(value)
            if class == nil or level == nil then
                return
            end
            if AddCollectedEntry(class, level) then
                n = n + 1
            end
        end)
    end)
    return n
end

local function LoadCollected(pc)
    levelState.options = {}
    levelState.byKey = {}

    local _, pawn = GetPawn(pc)
    local comp = GetComponent(pawn)
    local rd = GetRuntimeData(comp)
    local fromRt = 0
    local fromCp = 0
    if IsValid(rd) then
        fromRt = WalkLevelsMapIntoCollected(rd.TarstoneLevels)
    end
    if IsValid(comp) then
        fromCp = WalkLevelsMapIntoCollected(comp.TarstoneLevels)
    end
    -- Do not call GrabCollectedTarstones — it returns TSoftClassPtr and
    -- UE4SS can AV in push_softobjectproperty. Maps + explicit Add are enough.

    RebuildCollectedOptions()
    if levelState.stoneId ~= NONE and (levelState.stoneId == nil or levelState.byKey[levelState.stoneId] == nil) then
        levelState.stoneId = NONE
    end
    levelState.status = OneStoneStatusText()
    Log(string.format(
        "Tarstones: collected %d (RuntimeData +%d Component +%d)",
        math.max(0, #levelState.options - 1),
        fromRt,
        fromCp
    ))
    return #levelState.options
end

local function ApplyCollectedOptions(keepSelection)
    local opts = CollectedOptions()
    local keep = NONE
    if keepSelection and levelState.stoneId ~= nil and levelState.stoneId ~= NONE then
        if levelState.byKey[levelState.stoneId] ~= nil then
            keep = levelState.stoneId
        end
    end
    levelState.stoneId = keep
    levelState.status = OneStoneStatusText()
    local ok, err = pcall(function()
        ModMenu.Set(SECTION_ID, COLLECTED_ID, keep)
        ModMenu.SetOptions(SECTION_ID, COLLECTED_ID, opts, keep)
        ModMenu.SetLabel(SECTION_ID, ONE_STATUS_ID, levelState.status)
    end)
    if not ok then
        Log("Tarstones: collected dropdown update failed — " .. tostring(err))
    end
end

local function RefreshCollected(pc, keepSelection)
    LoadCollected(pc)
    ApplyCollectedOptions(keepSelection)
end

function M.RefreshCollected(pc, keepSelection)
    RefreshCollected(pc, keepSelection)
end

function M.Refresh()
    if not addState.frozen then
        local hasList = CatalogReady()
        if hasList and addState.named then
            addState.frozen = true
            Log("Tarstones: catalog cached for session")
        elseif LoadDb(not addState.named) then
            ApplyStoneOptions()
            if addState.named or addState.resolveTried then
                addState.frozen = true
                Log(string.format(
                    "Tarstones: catalog cached for session (named=%s)",
                    tostring(addState.named)
                ))
            end
        end
    end
    M.RefreshStatus()
    RefreshCollected(nil, true)
end

local function FindRowInCatalog(cat, id)
    local dt = GetDataTable(cat)
    if not IsValid(dt) then
        return nil
    end
    local row = nil
    pcall(function()
        row = dt:FindRow(id)
    end)
    if row == nil then
        return nil
    end
    return row.ItemClass
end

local function FindRowSoftClass(id)
    if addState.category ~= CAT_ALL then
        return FindRowInCatalog(CatalogById(addState.category), id)
    end
    for _, cat in ipairs(CATALOGS) do
        local soft = FindRowInCatalog(cat, id)
        if soft ~= nil then
            return soft
        end
    end
    return nil
end

--- Stream the HUD icon so CommonLazyImage is not empty on first inventory open.
local function PreloadDisplayIcon(itemClass)
    if itemClass == nil then
        return
    end
    local frag = nil
    pcall(function()
        local lib = GetItemLib()
        local fragClass = GetDisplayFragClass()
        if IsValid(lib) and IsValid(fragClass) then
            frag = lib:FindItemDefinitionFragment(itemClass, fragClass)
        end
    end)
    if not IsValid(frag) then
        return
    end
    pcall(function()
        local icon = frag.Icon
        if icon == nil then
            return
        end
        if type(icon.Get) == "function" then
            icon:Get()
        end
        if type(icon.LoadSynchronous) == "function" then
            icon:LoadSynchronous()
        end
    end)
end

--- Same UI ping Add All uses: refresh event + live inventory widgets.
local function NotifyTarstoneUi()
    local ges = GetGes()
    if IsValid(ges) then
        local eventClass = nil
        pcall(function()
            eventClass = FindObject("Class", REFRESH_EVENT)
        end)
        if eventClass == nil then
            pcall(function()
                local inst = FindFirstOf(REFRESH_EVENT)
                if IsValid(inst) and inst.GetClass then
                    eventClass = inst:GetClass()
                end
            end)
        end
        if eventClass ~= nil then
            pcall(function()
                ges:BroadcastEventNoData(eventClass, nil)
            end)
        end
    end

    pcall(function()
        local tabs = FindAllOf("WBP_MGT_Tarstones_Single_C")
        if tabs ~= nil then
            for i = 1, #tabs do
                local tab = tabs[i]
                if IsValid(tab) and tab.RefreshTarstoneInventory then
                    tab:RefreshTarstoneInventory()
                end
            end
        end
    end)

    pcall(function()
        local invs = FindAllOf("WBP_Tarstone_Inventory_C")
        if invs ~= nil then
            for i = 1, #invs do
                local inv = invs[i]
                if IsValid(inv) then
                    if inv.RefreshInventory then
                        inv:RefreshInventory()
                    elseif inv.RebuildCollection then
                        inv:RebuildCollection(true)
                    end
                end
            end
        end
    end)
end

local function AddSelected()
    local id = addState.stoneId
    if id == nil or id == "" then
        id = ModMenu.Get(SECTION_ID, STONE_ID)
    end
    id = AsString(id)
    if id == nil or id == NONE then
        Log("Tarstones: pick a stone first")
        FlashFeedback("tarAddOne", false, "Add")
        return
    end

    local pc, pawn = GetPawn()
    if not IsValid(pc) then
        Log("Tarstones: no player controller (load into a world first)")
        FlashFeedback("tarAddOne", false, "Add")
        return
    end

    local soft = FindRowSoftClass(id)
    if soft == nil then
        Log("Tarstones: row not found — " .. id)
        FlashFeedback("tarAddOne", false, "Add")
        return
    end

    local world = GetWorldCtx()
    local util = GetUtility()
    local cls = ResolveSoftClass(soft, util, world)
    if cls == nil then
        Log("Tarstones: could not resolve class — " .. id)
        FlashFeedback("tarAddOne", false, "Add")
        return
    end

    -- Add All uses the item-manager path (loads fragments/icons + receive event).
    -- Native AddTarstoneToInventory alone leaves CommonLazyImage unloaded.
    local granted = false
    local via = nil
    local playerLib = GetPlayerLib()
    if IsValid(playerLib) and IsValid(world) then
        local ok, err = pcall(function()
            playerLib:AddTarstoneToItemManager(cls, false, world)
        end)
        if ok then
            granted = true
            via = "AddTarstoneToItemManager"
        else
            Log("Tarstones: AddTarstoneToItemManager failed — " .. tostring(err))
        end
    end

    local comp = GetComponent(pawn)
    if IsValid(comp) then
        local ok, err = pcall(function()
            comp:AddTarstoneToInventory(cls, 0, 0)
        end)
        if ok then
            if not granted then
                via = "AddTarstoneToInventory"
            end
            granted = true
        else
            Log("Tarstones: AddTarstoneToInventory failed — " .. tostring(err))
        end
    end

    if granted then
        MarkSoftCollected(soft, world)
        if IsValid(comp) then
            pcall(function()
                comp:CacheAllTarstones()
            end)
        end
        PreloadDisplayIcon(cls)
        NotifyTarstoneUi()
        Log(string.format("Tarstones: added %s via %s", id, via))
        M.RefreshStatus(pc)
        LoadCollected(pc)
        AddCollectedEntry(cls, STORED_MIN, id)
        RebuildCollectedOptions()
        levelState.stoneId = NONE
        ApplyCollectedOptions(false)
        FlashFeedback("tarAddOne", true, id)
    else
        Log("Tarstones: add failed — " .. id)
        FlashFeedback("tarAddOne", false, "Add")
    end
end

--- Same write as Increment/Decrement All: stored level +/- 1, then equipped instance.
--- No ForceIncrement / ForceDecrement BP calls (TSoftClassPtr AV in UE4SS).
local function ChangeSelected(delta, buttonId, caption)
    local id = levelState.stoneId
    if id == nil or id == "" then
        id = ModMenu.Get(SECTION_ID, COLLECTED_ID)
    end
    id = AsString(id)
    if id == nil or id == NONE then
        Log("Tarstones: pick a collected stone first")
        FlashFeedback(buttonId, false, caption)
        return
    end

    local pc = UEHelpers.GetPlayerController()
    if not IsValid(pc) then
        Log("Tarstones: no player controller (load into a world first)")
        FlashFeedback(buttonId, false, caption)
        return
    end

    local entry = levelState.byKey[id]
    if entry == nil or entry.class == nil then
        LoadCollected(pc)
        entry = levelState.byKey[id]
    end
    if entry == nil or entry.class == nil then
        Log("Tarstones: collected stone not found — " .. id)
        ApplyCollectedOptions(false)
        FlashFeedback(buttonId, false, caption)
        return
    end
    levelState.stoneId = id

    if delta > 0 and entry.stored >= STORED_MAX then
        Log(string.format("Tarstones: %s already at max (UI %d)", id, UI_MAX))
        ApplyCollectedOptions(true)
        FlashFeedback(buttonId, false, caption)
        return
    end
    if delta < 0 and entry.stored <= STORED_MIN then
        Log(string.format("Tarstones: %s already at min (UI %d)", id, ToUI(STORED_MIN)))
        ApplyCollectedOptions(true)
        FlashFeedback(buttonId, false, caption)
        return
    end

    local nextLevel = entry.stored + delta
    if nextLevel > STORED_MAX then
        nextLevel = STORED_MAX
    end
    if nextLevel < STORED_MIN then
        nextLevel = STORED_MIN
    end

    local n = SetOneTo(pc, entry.class, nextLevel, id)
    if n < 1 then
        Log("Tarstones: level change failed — " .. id)
        FlashFeedback(buttonId, false, caption)
        return
    end

    Log(string.format(
        "Tarstones: %s stored %d -> %d (UI %d -> %d)",
        id,
        entry.stored,
        nextLevel,
        ToUI(entry.stored),
        ToUI(nextLevel)
    ))
    entry.stored = nextLevel
    RebuildCollectedOptions()
    ApplyCollectedOptions(true)
    M.RefreshStatus(pc)
    ShowReequipToast()
    FlashFeedback(buttonId, true, caption)
end

local function IncrementSelected()
    ChangeSelected(1, INC_ONE_ID, "Increment Level")
end

local function DecrementSelected()
    ChangeSelected(-1, DEC_ONE_ID, "Decrement Level")
end

local function CallAddAll(itemId, caption, name, fn)
    local pc = UEHelpers.GetPlayerController()
    if not IsValid(pc) then
        Log("Tarstones: no player controller (load into a world first)")
        FlashFeedback(itemId, false, caption)
        return
    end
    local ok, err = pcall(function()
        fn(pc)
    end)
    if ok then
        Log("Tarstones: " .. name)
        M.RefreshStatus(pc)
        RefreshCollected(pc, true)
        FlashFeedback(itemId, true, caption)
    else
        Log("Tarstones: " .. name .. " failed — " .. tostring(err))
        FlashFeedback(itemId, false, caption)
    end
end

function M.Register()
    LoadDb(false)

    ModMenu.Register({
        id = SECTION_ID,
        title = "Tarstones",
        tab = "Give",
        collapsible = true,
        collapsed = true,
        items = {
            {
                type = "label",
                id = ADD_STATUS_ID,
                label = addState.status,
            },
            {
                type = "dropdown",
                id = CATEGORY_ID,
                label = "Category",
                options = CATEGORY_OPTIONS,
                default = CAT_ALL,
                onChange = function(catId)
                    catId = AsString(catId)
                    if catId == nil then
                        return
                    end
                    addState.category = catId
                    ApplyStoneOptions()
                end,
            },
            {
                type = "dropdown",
                id = STONE_ID,
                label = "Tarstone",
                searchable = true,
                placeholder = "Select tarstone...",
                allowEmpty = true,
                maxVisible = 120,
                listMaxHeight = 320,
                options = StoneOptions(),
                default = nil,
                onChange = function(stoneId)
                    stoneId = AsString(stoneId)
                    if stoneId == nil or stoneId == NONE then
                        addState.stoneId = nil
                        return
                    end
                    addState.stoneId = stoneId
                end,
            },
            {
                type = "button",
                id = "tarAddOne",
                label = "Add",
                onClick = AddSelected,
            },
            {
                type = "label",
                id = ADD_TOAST_ID,
                label = "",
            },
            {
                type = "dropdown",
                id = COLLECTED_ID,
                label = "Collected",
                searchable = true,
                placeholder = "None",
                allowEmpty = false,
                maxVisible = 120,
                listMaxHeight = 320,
                options = CollectedOptions(),
                default = NONE,
                onChange = function(stoneId)
                    stoneId = AsString(stoneId)
                    if stoneId == nil or stoneId == NONE then
                        levelState.stoneId = NONE
                    else
                        levelState.stoneId = stoneId
                    end
                    levelState.status = OneStoneStatusText()
                    pcall(function()
                        ModMenu.SetLabel(SECTION_ID, ONE_STATUS_ID, levelState.status)
                    end)
                end,
            },
            {
                type = "label",
                id = ONE_STATUS_ID,
                label = levelState.status,
            },
            {
                type = "row",
                items = {
                    {
                        type = "button",
                        id = DEC_ONE_ID,
                        label = "Decrement Level",
                        onClick = DecrementSelected,
                    },
                    {
                        type = "button",
                        id = INC_ONE_ID,
                        label = "Increment Level",
                        onClick = IncrementSelected,
                    },
                },
            },
            {
                type = "label",
                id = NOTE_ID,
                label = "",
            },
            {
                type = "fold",
                id = "tarAddAllFold",
                label = "Add All Tarstones",
                collapsed = true,
                items = {
                    {
                        type = "button",
                        id = "tarMelee",
                        label = "Add All Tarstones (Melee)",
                        confirm = {
                            title = "Add all melee tarstones?",
                            message = "Grants every melee tarstone. This cannot be undone here.",
                            confirmLabel = "Add all",
                        },
                        onClick = function()
                            CallAddAll(
                                "tarMelee",
                                "Add All Tarstones (Melee)",
                                "S_AddAllTarstonesMelee",
                                function(pc)
                                    pc:S_AddAllTarstonesMelee()
                                end
                            )
                        end,
                    },
                    {
                        type = "button",
                        id = "tarSupport",
                        label = "Add All Tarstones (Support)",
                        confirm = {
                            title = "Add all support tarstones?",
                            message = "Grants every support tarstone. This cannot be undone here.",
                            confirmLabel = "Add all",
                        },
                        onClick = function()
                            CallAddAll(
                                "tarSupport",
                                "Add All Tarstones (Support)",
                                "S_AddAllTarstonesSupport",
                                function(pc)
                                    pc:S_AddAllTarstonesSupport()
                                end
                            )
                        end,
                    },
                    {
                        type = "button",
                        id = "tarSidearm",
                        label = "Add All Tarstones (Sidearm)",
                        confirm = {
                            title = "Add all sidearm tarstones?",
                            message = "Grants every sidearm tarstone. This cannot be undone here.",
                            confirmLabel = "Add all",
                        },
                        onClick = function()
                            CallAddAll(
                                "tarSidearm",
                                "Add All Tarstones (Sidearm)",
                                "S_AddAllTarstonesSidearm",
                                function(pc)
                                    pc:S_AddAllTarstonesSidearm()
                                end
                            )
                        end,
                    },
                },
            },
            {
                type = "fold",
                id = "tarLevelAllFold",
                label = "Level All Tarstones",
                collapsed = true,
                items = {
                    {
                        type = "label",
                        id = STATUS_ID,
                        label = "Tarstone level: 1 / 3",
                    },
                    {
                        type = "row",
                        items = {
                            {
                                type = "button",
                                id = "tarLevelDown",
                                label = "Decrement All",
                                onClick = function()
                                    local pc = UEHelpers.GetPlayerController()
                                    if not IsValid(pc) then
                                        Log("Tarstones: no player controller (load into a world first)")
                                        return
                                    end
                                    M.DecrementAll(pc)
                                end,
                            },
                            {
                                type = "button",
                                id = "tarLevel",
                                label = "Increment All",
                                onClick = function()
                                    local pc = UEHelpers.GetPlayerController()
                                    if not IsValid(pc) then
                                        Log("Tarstones: no player controller (load into a world first)")
                                        return
                                    end
                                    M.IncrementAll(pc)
                                end,
                            },
                        },
                    },
                },
            },
        },
    })
end

return M
