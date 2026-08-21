--[[
  Keybinds on their own tab. Saved via ConfigManager.

  UE4SS cannot unregister a key, so every bindable Key is registered once and
  dispatched against the current dropdown values. Unbound = None. Fires while
  the menu is closed. Toggle binds flip Cheats → Toggles. Switch Shell binds
  call the same Switch as the Shells tab. Heal / Resolve amounts come from Combat.
]]

local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")

local M = {}

local TAB_ID = "Keybinds"
local NONE = ""

-- Mouse keys would steal the menu. F6 is the shell toggle.
local SKIP = {
    LEFT_MOUSE_BUTTON = true,
    RIGHT_MOUSE_BUTTON = true,
    MIDDLE_MOUSE_BUTTON = true,
    XBUTTON_ONE = true,
    XBUTTON_TWO = true,
    F6 = true,
}

--- [actionId] = key name or nil
local assigned = {}

--- { { id, label, fire }, ... }
local actions = {}

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function NormalizeBind(value)
    if value == nil or value == NONE or value == "None" then
        return nil
    end
    return tostring(value)
end

local function Dispatch(keyName)
    if ModMenu.IsOpen() then
        return
    end
    for i = 1, #actions do
        local action = actions[i]
        if assigned[action.id] == keyName then
            action.fire()
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

---@param validNames table
---@return integer
local function RestoreAssigned(validNames)
    assigned = {}
    local saved = ConfigManager.Get("keybinds")
    if type(saved) ~= "table" then
        return 0
    end
    local n = 0
    for i = 1, #actions do
        local action = actions[i]
        local keyName = NormalizeBind(saved[action.id])
        if keyName ~= nil and (validNames == nil or validNames[keyName]) then
            assigned[action.id] = keyName
            n = n + 1
        end
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

---@param action { id: string, label: string }
---@param value any
local function OnBind(action, value)
    local keyName = NormalizeBind(value)
    assigned[action.id] = keyName
    if keyName ~= nil then
        for i = 1, #actions do
            local other = actions[i]
            if other.id ~= action.id and assigned[other.id] == keyName then
                Log(action.label .. " and " .. other.label .. " share " .. keyName)
                break
            end
        end
    end
    PersistAssigned()
    Log(action.label .. " bind -> " .. tostring(keyName or "None"))
end

---@param action { id: string, label: string }
---@param options table
---@return table
local function BindDropdown(action, options)
    return {
        type = "dropdown",
        id = action.id .. "Key",
        label = action.label,
        searchable = true,
        allowEmpty = true,
        placeholder = "None",
        maxVisible = 80,
        listMaxHeight = 240,
        options = options,
        default = assigned[action.id] or NONE,
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
            actions[#actions + 1] = items[i]
        end
    end

    local options, codes, names = BuildKeyOptions()
    local validNames = {}
    for _, name in ipairs(names) do
        validNames[name] = true
    end
    local restored = RestoreAssigned(validNames)

    local bound = 0
    for _, name in ipairs(names) do
        local code = codes[name]
        if code ~= nil then
            RegisterKeyBind(code, function()
                ExecuteInGameThread(function()
                    Dispatch(name)
                end)
            end)
            bound = bound + 1
        end
    end
    Log(string.format("Keybinds: %d keys armed, %d restored (menu closed only)", bound, restored))

    for g = 1, #groups do
        local group = groups[g]
        local items = {
            {
                type = "label",
                label = group.hint or "Saved to config. Fires while the menu is closed. None = off.",
            },
        }
        local groupItems = group.items or {}
        for i = 1, #groupItems do
            items[#items + 1] = BindDropdown(groupItems[i], options)
        end
        ModMenu.Register({
            id = group.id,
            title = group.title,
            tab = TAB_ID,
            collapsible = true,
            collapsed = group.id ~= "KeybindToggles",
            items = items,
        })
    end
end

return M
