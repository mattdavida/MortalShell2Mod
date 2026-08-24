--[[
  Keybinds on their own tab. Saved via ConfigManager.

  UE4SS cannot unregister a key, so every bindable Key is registered once and
  dispatched against the current dropdown values. Unbound = None. Cheat binds
  fire while the menu is closed. Menu toggle also fires while open. Toggle
  binds flip Cheats → Toggles. Switch Shell binds call the same Switch as the
  Shells tab. Heal / Resolve / Damage come from Combat.

  Menu toggle defaults to F6. A saved keybinds.menuToggle is passed to
  ModMenu.Init on launch. Changing it mid-session arms the new key immediately;
  the launch key still toggles until relaunch (cannot unbind).
]]

local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")

local M = {}

local TAB_ID = "Keybinds"
local NONE = ""
local MENU_TOGGLE_ID = "menuToggle"
local DEFAULT_MENU_KEY = "F6"

-- Mouse keys would steal the menu.
local SKIP = {
    LEFT_MOUSE_BUTTON = true,
    RIGHT_MOUSE_BUTTON = true,
    MIDDLE_MOUSE_BUTTON = true,
    XBUTTON_ONE = true,
    XBUTTON_TWO = true,
}

--- [actionId] = key name or nil
local assigned = {}

--- { { id, label, fire, sectionId, allowEmpty, fireWhileOpen }, ... }
local actions = {}

--- Full bindable list from BuildKeyOptions (includes None).
local allKeyOptions = {}

--- ModMenu key for this launch (cannot unbind). Hidden from other dropdowns.
local launchMenuName = DEFAULT_MENU_KEY

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function NormalizeBind(value)
    if value == nil or value == NONE or value == "None" then
        return nil
    end
    return tostring(value)
end

local function IsBindableName(name)
    return type(name) == "string"
        and type(Key) == "table"
        and type(Key[name]) == "number"
        and not SKIP[name]
end

--- Saved menu toggle, or F6. Call after ConfigManager.Init.
---@return { name: string, code: any }
function M.ResolveMenuKey()
    local name = DEFAULT_MENU_KEY
    local saved = ConfigManager.Get("keybinds")
    if type(saved) == "table" then
        local v = NormalizeBind(saved[MENU_TOGGLE_ID])
        if v ~= nil and IsBindableName(v) then
            name = v
        elseif v ~= nil then
            Log("Menu toggle " .. tostring(v) .. " is not a bindable key — using " .. DEFAULT_MENU_KEY)
        end
    end
    local code = nil
    if type(Key) == "table" then
        code = Key[name]
        if code == nil then
            code = Key[DEFAULT_MENU_KEY]
            name = DEFAULT_MENU_KEY
        end
    end
    return { name = name, code = code }
end

local function Dispatch(keyName)
    local menuOpen = ModMenu.IsOpen()
    for i = 1, #actions do
        local action = actions[i]
        if assigned[action.id] == keyName then
            if (not menuOpen) or action.fireWhileOpen then
                action.fire()
            end
        end
    end
end

local function SortKeyNames(a, b)
    local fa = tonumber(string.match(a, "^F(%d+)$"))
    local fb = tonumber(string.match(b, "^F(%d+)$"))
    if fa ~= nil and fb ~= nil then
        return fa < fb
    end
    if fa ~= nil then
        return true
    end
    if fb ~= nil then
        return false
    end
    return a < b
end

--- Unique Key names from the UE4SS dump (one name per scan code).
local function BuildKeyOptions()
    local byCode = {}
    if type(Key) ~= "table" then
        Log("Key enum missing — keybind list empty")
        return { { label = "None", value = NONE } }, {}, {}
    end

    for name, code in pairs(Key) do
        if type(name) == "string" and type(code) == "number" and not SKIP[name] then
            local existing = byCode[code]
            if existing == nil or name < existing then
                byCode[code] = name
            end
        end
    end

    local names = {}
    local codes = {}
    for code, name in pairs(byCode) do
        names[#names + 1] = name
        codes[name] = code
    end
    table.sort(names, SortKeyNames)

    local options = { { label = "None", value = NONE } }
    for _, name in ipairs(names) do
        options[#options + 1] = { label = name, value = name }
    end
    return options, codes, names
end

---@param exceptId string|nil
---@return table
local function TakenKeys(exceptId)
    local taken = {}
    for i = 1, #actions do
        local id = actions[i].id
        if id ~= exceptId then
            local keyName = assigned[id]
            if keyName ~= nil then
                taken[keyName] = true
            end
        end
    end
    return taken
end

--- Keys already bound to another action (and this session's ModMenu key) are omitted.
---@param action { id: string, allowEmpty?: boolean }
---@return table
local function OptionsFor(action)
    local taken = TakenKeys(action.id)
    if action.id ~= MENU_TOGGLE_ID and launchMenuName ~= nil then
        taken[launchMenuName] = true
    end
    local allowEmpty = action.allowEmpty ~= false
    local own = assigned[action.id]
    local out = {}
    if allowEmpty then
        out[#out + 1] = { label = "None", value = NONE }
    end
    for i = 1, #allKeyOptions do
        local opt = allKeyOptions[i]
        local value = opt.value
        if value ~= NONE and (value == own or not taken[value]) then
            out[#out + 1] = opt
        end
    end
    return out
end

local function RefreshDropdownOptions()
    for i = 1, #actions do
        local action = actions[i]
        local sectionId = action.sectionId
        if sectionId ~= nil then
            local opts = OptionsFor(action)
            if #opts > 0 then
                local selected = assigned[action.id]
                if selected == nil and action.allowEmpty ~= false then
                    selected = NONE
                end
                ModMenu.SetOptions(sectionId, action.id .. "Key", opts, selected)
            end
        end
    end
end

---@param validNames table
---@param launchName string
---@return integer
local function RestoreAssigned(validNames, launchName)
    assigned = {}
    local saved = ConfigManager.Get("keybinds")
    if type(saved) ~= "table" then
        saved = {}
    end
    local n = 0
    local used = {}
    for i = 1, #actions do
        local action = actions[i]
        local keyName = NormalizeBind(saved[action.id])
        if keyName ~= nil and (validNames == nil or validNames[keyName]) then
            if action.id ~= MENU_TOGGLE_ID and keyName == launchName then
                Log(action.label .. " bind ignored this session — " .. keyName .. " is the menu key")
            elseif used[keyName] then
                Log(action.label .. " bind ignored — " .. keyName .. " is already used")
            else
                assigned[action.id] = keyName
                used[keyName] = true
                n = n + 1
            end
        end
    end
    if assigned[MENU_TOGGLE_ID] == nil then
        assigned[MENU_TOGGLE_ID] = launchName
    end
    return n
end

local function PersistAssigned()
    local out = {}
    for i = 1, #actions do
        local id = actions[i].id
        local keyName = assigned[id]
        if keyName ~= nil then
            out[id] = keyName
        end
    end
    ConfigManager.Set("keybinds", out)
end

---@param action { id: string, label: string, allowEmpty?: boolean }
---@param value any
local function OnBind(action, value)
    local prev = assigned[action.id]
    local keyName = NormalizeBind(value)
    if action.allowEmpty == false and keyName == nil then
        keyName = prev or DEFAULT_MENU_KEY
    end
    if keyName ~= nil then
        local taken = TakenKeys(action.id)
        if action.id ~= MENU_TOGGLE_ID then
            taken[launchMenuName] = true
        end
        if taken[keyName] then
            Log(action.label .. " ignored " .. keyName .. " — already bound")
            keyName = prev
            if action.allowEmpty == false and keyName == nil then
                keyName = DEFAULT_MENU_KEY
            end
        end
    end
    if keyName == prev then
        if NormalizeBind(value) ~= keyName then
            RefreshDropdownOptions()
        end
        return
    end
    assigned[action.id] = keyName
    PersistAssigned()
    RefreshDropdownOptions()
    Log(action.label .. " bind -> " .. tostring(keyName or "None"))
end

---@param action { id: string, label: string, allowEmpty?: boolean }
---@return table
local function BindDropdown(action)
    local allowEmpty = action.allowEmpty ~= false
    local opts = OptionsFor(action)
    return {
        type = "dropdown",
        id = action.id .. "Key",
        label = action.label,
        searchable = true,
        allowEmpty = allowEmpty,
        placeholder = allowEmpty and "None" or (assigned[action.id] or DEFAULT_MENU_KEY),
        maxVisible = 80,
        listMaxHeight = 240,
        options = opts,
        default = assigned[action.id] or (allowEmpty and NONE or DEFAULT_MENU_KEY),
        onChange = function(value)
            OnBind(action, value)
        end,
    }
end

---@param groups { id: string, title: string, hint: string, items: table }[]
function M.Register(groups)
    groups = groups or {}
    actions = {}
    for g = 1, #groups do
        local group = groups[g]
        local items = group.items or {}
        for i = 1, #items do
            local action = items[i]
            action.sectionId = group.id
            actions[#actions + 1] = action
        end
    end

    local menuKey = M.ResolveMenuKey()
    launchMenuName = menuKey.name
    local options, codes, names = BuildKeyOptions()
    allKeyOptions = options
    local validNames = {}
    for _, name in ipairs(names) do
        validNames[name] = true
    end
    local restored = RestoreAssigned(validNames, launchMenuName)

    local bound = 0
    for _, name in ipairs(names) do
        local code = codes[name]
        if code ~= nil and name ~= launchMenuName then
            RegisterKeyBind(code, function()
                ExecuteInGameThread(function()
                    Dispatch(name)
                end)
            end)
            bound = bound + 1
        end
    end
    Log(string.format(
        "Keybinds: %d keys armed, %d restored, menu=%s",
        bound,
        restored,
        tostring(launchMenuName)
    ))

    for g = 1, #groups do
        local group = groups[g]
        local items = {
            {
                type = "label",
                label = (group.hint or "Saved to config. Fires while the menu is closed. None = off.")
                    .. " Keys already bound elsewhere are hidden.",
            },
        }
        local groupItems = group.items or {}
        for i = 1, #groupItems do
            items[#items + 1] = BindDropdown(groupItems[i])
        end
        ModMenu.Register({
            id = group.id,
            title = group.title,
            tab = TAB_ID,
            collapsible = true,
            collapsed = group.id ~= "KeybindMenu" and group.id ~= "KeybindToggles",
            items = items,
        })
    end
end

return M
