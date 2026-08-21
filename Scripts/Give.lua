--[[
  Give a pickup from DT_PickUpItems.

  Category stays Pickup for now (no dropdown until more catalogs exist).
  Labels prefer ItemFragment_Display:ToString (HUD field), then CDO.
  Never call Kismet FText / loc-table APIs (native crash).
  Grant via S_AddItemQuantity.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

local M = {}

local SECTION_ID = "Give"
local CATEGORY_PICKUP = "Pickup"
local DT_PICKUP = "/Game/Sparta/Items/Pickups/Core/DT_PickUpItems.DT_PickUpItems"
local NONE = "__none__"
local UTIL_CDO = "Default__BPFL_Utility_C"
local AMOUNT_ID = "giveAmount"
local DEFAULT_AMOUNT = 1

local NOT_READY = "Pickup table not loaded — open the menu in a world."

--- Catalogs feed the item dropdown. Add rows here to extend category later.
local CATALOGS = {
    {
        id = CATEGORY_PICKUP,
        label = "Pickup",
        path = DT_PICKUP,
    },
}

local state = {
    category = CATEGORY_PICKUP,
    itemId = nil,
    itemsByCategory = {},
    status = NOT_READY,
    named = false,
    frozen = false,
    resolveTried = false,
}

local cachedUtil = nil
local cachedItemLib = nil
local cachedDisplayFragClass = nil
local skipFrag = false

local ITEM_LIB_CDO = "/Script/Sparta.Default__SpartaItemFunctionLibrary"
local DISPLAY_FRAG = "/Script/Sparta.ItemFragment_Display"

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
            if value.ToString then
                return value:ToString()
            end
            return nil
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

local function ResetGiveAmount()
    pcall(function()
        ModMenu.Set(SECTION_ID, AMOUNT_ID, DEFAULT_AMOUNT)
    end)
end

local function PlaceholderOptions()
    return { { label = "(load a world, then reopen)", value = NONE } }
end

local function ItemOptions()
    local list = state.itemsByCategory[state.category or CATEGORY_PICKUP]
    if list == nil or #list == 0 then
        return PlaceholderOptions()
    end
    return list
end

local function GetUtility()
    if IsValid(cachedUtil) then
        return cachedUtil
    end
    cachedUtil = nil
    pcall(function()
        cachedUtil = FindObject(nil, UTIL_CDO)
    end)
    if IsValid(cachedUtil) then
        return cachedUtil
    end
    cachedUtil = nil
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

--- HUD name is on ItemFragment_Display. CDO DisplayName is a different FText.
--- Only :ToString() — no Kismet TextIsEmpty / GetTextId / Conv_TextToString.
local function FragmentDisplayName(itemClass)
    if skipFrag or itemClass == nil then
        return nil
    end
    local lib = GetItemLib()
    local fragClass = GetDisplayFragClass()
    if not IsValid(lib) or not IsValid(fragClass) then
        skipFrag = true
        Log("Give: display fragment class missing — CDO names only")
        return nil
    end
    local frag = nil
    local ok, err = pcall(function()
        frag = lib:FindItemDefinitionFragment(itemClass, fragClass)
    end)
    if not ok then
        skipFrag = true
        Log("Give: skip display fragment — " .. tostring(err))
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

--- Soft ItemClass -> HUD fragment name, else CDO.
local function ResolveDisplayName(softClass, util, world)
    if softClass == nil or not IsValid(util) or not IsValid(world) then
        return nil
    end
    local cls = nil
    local ok = pcall(function()
        cls = util:ResolveSoftItemDefinition(softClass, world)
    end)
    if not ok or not IsValid(cls) then
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
    local dt = StaticFindObject(cat.path)
    if not IsValid(dt) then
        return nil, "not found", 0
    end

    local util = nil
    local world = nil
    if resolveNames then
        util = GetUtility()
        world = GetWorldCtx()
        if IsValid(util) and IsValid(world) then
            state.resolveTried = true
        else
            resolveNames = false
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
            if rowData ~= nil then
                -- DT DisplayName is an empty localized FText — do not convert it.
                if resolveNames then
                    display = ResolveDisplayName(rowData.ItemClass, util, world)
                end
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

local function LoadDb(resolveNames)
    local loaded = 0
    local failed = 0
    local named = 0
    for _, cat in ipairs(CATALOGS) do
        local opts, err, n = LoadCatalog(cat, resolveNames)
        if opts ~= nil and #opts > 0 then
            state.itemsByCategory[cat.id] = opts
            loaded = loaded + 1
            named = named + (n or 0)
        else
            failed = failed + 1
            Log(string.format("Give: %s table failed (%s)", cat.id, tostring(err or "empty")))
        end
    end

    local pickup = state.itemsByCategory[CATEGORY_PICKUP]
    if pickup == nil or #pickup == 0 then
        state.status = NOT_READY
        state.named = false
        return false
    end

    state.named = resolveNames and named > 0
    state.status = string.format("Pickups: %d", #pickup)
    Log(string.format(
        "Give: loaded Pickups: %d named=%d resolve=%s (%d failed)",
        #pickup,
        named,
        tostring(state.named),
        failed
    ))
    return true
end

local function ApplyItemOptions()
    local opts = ItemOptions()
    state.itemId = nil
    pcall(function()
        ModMenu.Set(SECTION_ID, "item", nil)
        ModMenu.SetOptions(SECTION_ID, "item", opts, false)
        ModMenu.SetLabel(SECTION_ID, "status", state.status)
    end)
end

function M.Refresh()
    if state.frozen then
        return
    end

    local pickup = state.itemsByCategory[CATEGORY_PICKUP]
    local hasList = pickup ~= nil and #pickup > 0
    if hasList and state.named then
        state.frozen = true
        Log("Give: catalog cached for session")
        return
    end

    if not LoadDb(not state.named) then
        return
    end

    ApplyItemOptions()
    if state.named or state.resolveTried then
        state.frozen = true
        Log(string.format(
            "Give: catalog cached for session (named=%s)",
            tostring(state.named)
        ))
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

local function GiveSelected()
    local id = state.itemId
    if id == nil or id == "" then
        id = ModMenu.Get(SECTION_ID, "item")
    end
    id = AsString(id)
    if id == nil or id == NONE then
        Log("Give: pick an item first")
        return
    end

    local n = tonumber(ModMenu.Get(SECTION_ID, AMOUNT_ID)) or 0
    n = math.floor(n)
    if n < 1 then
        Log("Give: amount must be >= 1")
        return
    end

    local pc = GetPlayerController()
    if not pc then
        Log("Give: no player controller (load into a world first)")
        return
    end

    local fname = UEHelpers.FindOrAddFName(id)
    local ok, err = pcall(function()
        pc:S_AddItemQuantity(fname, n)
    end)
    if ok then
        Log(string.format("Give: S_AddItemQuantity(%s, %d)", id, n))
    else
        Log("Give failed — " .. tostring(err))
    end
end

function M.Register()
    LoadDb(false)

    ModMenu.Register({
        id = SECTION_ID,
        title = "Give Item",
        tab = "Give",
        collapsible = true,
        collapsed = true,
        items = {
            {
                type = "label",
                id = "status",
                label = state.status,
            },
            {
                type = "dropdown",
                id = "item",
                label = "Item",
                searchable = true,
                placeholder = "Select item...",
                allowEmpty = true,
                maxVisible = 120,
                listMaxHeight = 320,
                options = ItemOptions(),
                default = nil,
                onChange = function(itemId)
                    itemId = AsString(itemId)
                    if itemId == nil or itemId == NONE then
                        state.itemId = nil
                        return
                    end
                    state.itemId = itemId
                    ResetGiveAmount()
                end,
            },
            {
                type = "row",
                items = {
                    {
                        type = "number",
                        id = AMOUNT_ID,
                        label = "Amount",
                        default = DEFAULT_AMOUNT,
                        min = 1,
                        integer = true,
                        labelWidth = 150,
                        fieldWidth = 72,
                    },
                    {
                        type = "button",
                        id = "giveItem",
                        label = "Add",
                        onClick = GiveSelected,
                    },
                },
            },
            {
                type = "fold",
                id = "giveAllFold",
                label = "Give All Items",
                collapsed = true,
                items = {
                    {
                        type = "button",
                        id = "allItems",
                        label = "Give All Items",
                        onClick = function()
                            local pc = GetPlayerController()
                            if not pc then
                                Log("Give: no player controller (load into a world first)")
                                return
                            end
                            local ok, err = pcall(function()
                                pc:S_AddAllItems()
                            end)
                            if ok then
                                Log("Give: S_AddAllItems")
                            else
                                Log("Give S_AddAllItems failed — " .. tostring(err))
                            end
                        end,
                    },
                },
            },
        },
    })
end

return M
