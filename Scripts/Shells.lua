--[[
  Shell picker and current-shell helpers.

  Catalog comes from SpartaGameSettings (Shells + GetShellNames), not a
  hardcoded English name list. Labels use ItemFragment_Display.
  Switch uses the ShellNames FString (S_SwitchToShell / GetShellItemDefinition).
  Equipped state uses GetCurrentShellID class/tag, not HUD FText.

  Skip ID_Shell_LoadFromSave. Harros still clears the petrified flag.
  Smert / Genessa / Lazlo toggles live in Character.lua. Lazlo is
  ID_Shell_Necrophage — Is("lazlo") keys off GetShellNames, not the class.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

local M = {}

local SECTION_ID = "Shells"
local SETTINGS_CDO = "/Script/Sparta.Default__SpartaGameSettings"
local ITEM_LIB_CDO = "/Script/Sparta.Default__SpartaItemFunctionLibrary"
local DISPLAY_FRAG = "/Script/Sparta.ItemFragment_Display"
local DARK_FORM_ID = "darkForm"
local DARK_FORM_LABEL = "Dark Form"

--- Last-resort switch keys (same strings as GetShellNames). Not UI titles.
local FALLBACK_SHELLS = {
    { id = "tiel",    name = "Tiel",    label = "Tiel" },
    { id = "lazlo",   name = "Lazlo",   label = "Lazlo" },
    { id = "genessa", name = "Genessa", label = "Genessa" },
    { id = "smert",   name = "Smert",   label = "Smert" },
    { id = "harros",  name = "Harros",  label = "Harros", restore = true },
    { id = "eredrim", name = "Eredrim", label = "Eredrim" },
    { id = "sariel",  name = "Sariel",  label = "Sariel" },
    { id = "gragu",   name = "Gragu",   label = "Gragu" },
    { id = "proxima", name = "Proxima", label = "Proxima" },
    { id = "solomon", name = "Solomon", label = "Solomon" },
}

--- Filled by LoadCatalog. Each: id, name, label, path, restore.
local SHELLS = {}

--- Stable catalog id of the equipped shell (lazlo, harros, ...).
local currentId = nil
--- Last shell the player picked in this menu. Switch key (GetShellNames).
local wantedName = nil
local reapplyHandle = nil
local registeredCount = -1
local skipFrag = false
local cachedItemLib = nil
local cachedDisplayFragClass = nil
---@type fun(current: string|nil)[]
local changedFns = {}

local function NotifyChanged()
    for i = 1, #changedFns do
        pcall(changedFns[i], currentId)
    end
end

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

--- TArray wrappers only. Do not probe `.get` on UE structs — GameplayTag
--- __index treats Get as a property and errors (pcall does not catch it).
local function IsUnrealParam(value)
    if value == nil then
        return false
    end
    local t = type(value)
    if t == "RemoteUnrealParam" or t == "LocalUnrealParam" then
        return true
    end
    local text = nil
    pcall(function()
        text = tostring(value)
    end)
    return type(text) == "string" and text:find("^RemoteUnrealParam", 1) ~= nil
end

---@param param any
---@return any
local function UnwrapParam(param)
    local value = param
    for _ = 1, 3 do
        if value == nil or not IsUnrealParam(value) then
            return value
        end
        local ok, inner = pcall(function()
            return value:get()
        end)
        if not ok or inner == nil or inner == value then
            return value
        end
        value = inner
    end
    return value
end

---@param value any
---@return string|nil
local function ToLuaString(value)
    value = UnwrapParam(value)
    if value == nil then
        return nil
    end
    if type(value) == "string" then
        if value:find("^table:", 1)
            or value:find("^RemoteUnrealParam", 1)
            or value == ""
            or value == "None"
            or value == "nil"
        then
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
    if type(value) == "boolean" then
        return nil
    end
    local text = tostring(value)
    if text ~= nil and text ~= "" and text ~= "nil" and not text:find("^table:", 1) then
        return text
    end
    return nil
end

---@param tag any
---@return string|nil
local function TagToString(tag)
    return ToLuaString(tag)
end

---@param arr any
---@param fn fun(item: any, index: integer)
local function ForEachArrayItem(arr, fn)
    if arr == nil then
        return
    end
    local n = 0
    pcall(function()
        n = #arr
    end)
    if n == 0 then
        pcall(function()
            n = arr:GetArrayNum()
        end)
    end
    if n > 0 then
        for i = 1, n do
            local ok, item = pcall(function()
                return arr[i]
            end)
            if ok then
                fn(UnwrapParam(item), i)
            end
        end
        return
    end
    pcall(function()
        arr:ForEach(function(index, elem)
            fn(UnwrapParam(elem), index)
        end)
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

--- HUD name is on ItemFragment_Display. Only :ToString() — no Kismet loc APIs.
local function FragmentDisplayName(itemClass)
    if skipFrag or itemClass == nil then
        return nil
    end
    local lib = GetItemLib()
    local fragClass = GetDisplayFragClass()
    if not IsValid(lib) or not IsValid(fragClass) then
        return nil
    end
    local frag = nil
    local ok, err = pcall(function()
        frag = lib:FindItemDefinitionFragment(itemClass, fragClass)
    end)
    if not ok then
        skipFrag = true
        Log("Shells: skip display fragment — " .. tostring(err))
        return nil
    end
    if not IsValid(frag) then
        return nil
    end
    return ToLuaString(frag.DisplayName)
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
    return ToLuaString(def.DisplayName)
end

local function ClassDisplayName(itemClass)
    local name = FragmentDisplayName(itemClass)
    if name ~= nil then
        return name
    end
    return CdoDisplayName(itemClass)
end

---@return UObject|nil
local function GetGameSettings()
    local settings = nil
    pcall(function()
        settings = StaticFindObject(SETTINGS_CDO)
    end)
    if not IsValid(settings) then
        settings = FindFirstOf("SpartaGameSettings")
    end
    if not IsValid(settings) then
        return nil
    end
    pcall(function()
        local inst = settings:Get()
        if IsValid(inst) then
            settings = inst
        end
    end)
    return settings
end

---@param value any
---@return string|nil
local function SoftPath(value)
    if value == nil then
        return nil
    end
    if type(value) == "userdata" or type(value) == "table" then
        if type(value.get) == "function" then
            local ok, inner = pcall(function()
                return value:get()
            end)
            if ok and inner ~= nil and inner ~= value then
                local nested = SoftPath(inner)
                if nested ~= nil then
                    return nested
                end
            end
        end
        for _, field in ipairs({ "AssetPathName", "AssetPath", "ObjectPath", "SoftObjectPath" }) do
            local ok, fieldVal = pcall(function()
                return value[field]
            end)
            if ok and fieldVal ~= nil then
                local nested = SoftPath(fieldVal)
                if nested ~= nil then
                    return nested
                end
            end
        end
    end
    local text = ToLuaString(value)
    if text == nil then
        return nil
    end
    local path = text:match("(/Game/[^%s,\"']+)") or text:match("(/Script/[^%s,\"']+)")
    if path ~= nil then
        return (path:gsub("[%.]+$", ""))
    end
    if text:find("^/Game/", 1) or text:find("^/Script/", 1) then
        return text
    end
    return nil
end

local function ObjectName(obj)
    if obj == nil then
        return nil
    end
    local name = nil
    pcall(function()
        if obj.GetName then
            name = obj:GetName()
        end
    end)
    name = ToLuaString(name)
    if name ~= nil then
        return name
    end
    local full = nil
    pcall(function()
        if obj.GetFullName then
            full = obj:GetFullName()
        end
    end)
    return ToLuaString(full)
end

local function FindClass(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local obj = nil
    pcall(function()
        obj = StaticFindObject(path)
    end)
    if IsValid(obj) then
        return obj
    end
    return nil
end

local function ShouldSkip(name, path)
    local blob = AlnumLower((name or "") .. (path or ""))
    return blob:find("loadfromsave", 1, true) ~= nil
end

local function IsHarros(name, path)
    local blob = AlnumLower((name or "") .. (path or ""))
    return blob:find("harros", 1, true) ~= nil
end

local function MakeId(name, path)
    if type(name) == "string" and name ~= "" then
        local id = AlnumLower(name)
        if id ~= "" then
            return id
        end
    end
    if type(path) == "string" then
        local base = path:match("([^/%.]+)_C$") or path:match("([^/%.]+)$")
        if base ~= nil then
            base = base:gsub("^ID_Shell_", "")
            local id = AlnumLower(base)
            if id ~= "" then
                return id
            end
        end
    end
    return nil
end

---@param path string|nil
---@return string[]
local function PathTokens(path)
    local tokens = {}
    if type(path) ~= "string" or path == "" then
        return tokens
    end
    local base = path:match("([^/%.]+)$") or path
    tokens[#tokens + 1] = base
    local noC = base:gsub("_C$", "")
    if noC ~= base then
        tokens[#tokens + 1] = noC
    end
    local short = noC:gsub("^ID_Shell_", "")
    if short ~= noC then
        tokens[#tokens + 1] = short
    end
    return tokens
end

---@param shell table
---@return string[]
local function ShellTokens(shell)
    local tokens = { shell.name, shell.id }
    if shell.label ~= nil and shell.label ~= shell.name then
        tokens[#tokens + 1] = shell.label
    end
    local extras = PathTokens(shell.path)
    for i = 1, #extras do
        tokens[#tokens + 1] = extras[i]
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
        if type(token) == "string" and token ~= "" then
            local needle = string.lower(token)
            if last == needle or c:find(needle, 1, true) then
                return true
            end
            local compactNeedle = AlnumLower(token)
            if compactNeedle ~= "" and compact:find(compactNeedle, 1, true) then
                return true
            end
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

local function ShellById(id)
    if type(id) ~= "string" or id == "" then
        return nil
    end
    for i = 1, #SHELLS do
        if SHELLS[i].id == id then
            return SHELLS[i]
        end
    end
    return nil
end

local function CollectStrings(arr)
    local list = {}
    ForEachArrayItem(arr, function(item)
        local text = ToLuaString(item)
        if text ~= nil then
            list[#list + 1] = text
        else
            list[#list + 1] = ""
        end
    end)
    return list
end

local function CollectPaths(arr)
    local list = {}
    ForEachArrayItem(arr, function(item)
        list[#list + 1] = SoftPath(item) or ""
    end)
    return list
end

local function ResolveLabel(name, path, settings)
    local item = nil
    if settings ~= nil and type(name) == "string" and name ~= "" then
        pcall(function()
            item = settings:GetShellItemDefinition(name)
        end)
    end
    if not IsValid(item) then
        item = FindClass(path)
    end
    if IsValid(item) then
        local display = ClassDisplayName(item)
        if display ~= nil then
            return display
        end
    end
    return name
end

local function UseFallback(reason)
    if #SHELLS > 0 then
        return
    end
    local copy = {}
    for i = 1, #FALLBACK_SHELLS do
        local src = FALLBACK_SHELLS[i]
        copy[i] = {
            id = src.id,
            name = src.name,
            label = src.label,
            restore = src.restore,
        }
    end
    SHELLS = copy
    Log("Shells: " .. reason)
end

local function LoadCatalog()
    local settings = GetGameSettings()
    if settings == nil then
        UseFallback("settings missing — using switch-key fallback")
        return
    end

    local names = {}
    pcall(function()
        names = CollectStrings(settings:GetShellNames())
    end)
    if #names == 0 then
        names = CollectStrings(ReadField(settings, "ShellNames"))
    end
    local paths = CollectPaths(ReadField(settings, "Shells"))

    local n = math.max(#names, #paths)
    if n == 0 then
        UseFallback("catalog empty — using switch-key fallback")
        return
    end

    local list = {}
    local skipped = 0
    for i = 1, n do
        local name = names[i]
        if name == "" then
            name = nil
        end
        local path = paths[i]
        if path == "" then
            path = nil
        end
        if ShouldSkip(name, path) then
            skipped = skipped + 1
        else
            local id = MakeId(name, path)
            if id ~= nil then
                local label = ResolveLabel(name, path, settings) or name or id
                list[#list + 1] = {
                    id = id,
                    name = name or id,
                    label = label,
                    path = path,
                    restore = IsHarros(name, path),
                }
            end
        end
    end

    if #list == 0 then
        UseFallback("no playable shells — using switch-key fallback")
        return
    end

    SHELLS = list
    Log(string.format("Shells: catalog %d (skipped %d LoadFromSave)", #SHELLS, skipped))
end

local function ButtonLabel(shell)
    local label = shell.label or shell.name or shell.id
    if currentId ~= nil and currentId == shell.id then
        return label .. "  (equipped)"
    end
    return label
end

local function RefreshShellLabels()
    for i = 1, #SHELLS do
        local shell = SHELLS[i]
        pcall(function()
            ModMenu.SetButtonLabel(SECTION_ID, ShellButtonId(shell), ButtonLabel(shell))
        end)
    end
end

local function AddCandidate(candidates, value)
    if type(value) == "userdata" or type(value) == "table" then
        local name = ObjectName(value)
        if name ~= nil then
            candidates[#candidates + 1] = name
        end
    end
    local text = TagToString(value) or ToLuaString(value)
    if text and text ~= "" then
        candidates[#candidates + 1] = text
    end
end

---@param pc APlayerController
---@return table|nil, string[]
local function DetectCurrentShell(pc)
    local candidates = {}
    local function add(value)
        AddCandidate(candidates, value)
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

    local playerFl = FindCdo("BPFL_Player_C")
    if IsValid(playerFl) then
        local ok, a, b, c, d, e = pcall(function()
            return playerFl:GetCurrentShellID(pc)
        end)
        if ok then
            add(a)
            add(b)
            add(c)
            add(d)
            add(e)
        end
    end

    pcall(function()
        add(pc:GetCurrentShell())
    end)

    local ui = FindCdo("BPFL_UI_C")
    if IsValid(ui) then
        local ok, name = pcall(function()
            return ui:GetEquippedShellName(pc)
        end)
        if ok then
            add(name)
        end
    end

    for i = 1, #SHELLS do
        for c = 1, #candidates do
            if MatchesShell(SHELLS[i], candidates[c]) then
                return SHELLS[i], candidates
            end
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

    local game = GetGameSettings()
    if IsValid(game) then
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
    currentId = shell.id
    local detected = DetectCurrentShell(pc)
    if detected ~= nil then
        currentId = detected.id
    end
    RefreshShellLabels()
    Log("Equipped " .. (shell.label or shell.name))
    NotifyChanged()
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
    Log("Re-applied " .. (shell.label or shell.name) .. " after restart")
end

---@param id string
---@return boolean
function M.Is(id)
    if type(id) ~= "string" or id == "" then
        return false
    end
    return currentId == id
end

---@param fn fun(current: string|nil)
function M.OnChanged(fn)
    if type(fn) == "function" then
        changedFns[#changedFns + 1] = fn
    end
end

local function RefreshFromWorld()
    local pc = GetPlayerController()
    if not pc then
        return
    end
    local detected = DetectCurrentShell(pc)
    if detected then
        currentId = detected.id
        RefreshShellLabels()
        NotifyChanged()
    end
end

---@param pc APlayerController
---@return boolean
local function ActivateDarkForm(pc)
    local success = { true }
    local ok, err = pcall(function()
        pc:ActivateDarkForm(false, true, success)
    end)
    if ok then
        Log("Dark Form: ActivateDarkForm(false, true) success=" .. tostring(success[1]))
        wantedName = nil
        currentId = DARK_FORM_ID
        RefreshShellLabels()
        NotifyChanged()
        ExecuteInGameThreadWithDelay(300, RefreshFromWorld)
        return true
    end
    Log("Dark Form: ActivateDarkForm failed — " .. tostring(err))
    return false
end

--- Playable shells plus Dark Form, same order as Switch Shell.
---@return { id: string, label: string }[]
function M.Options()
    if #SHELLS == 0 then
        LoadCatalog()
    end
    local list = {}
    for i = 1, #SHELLS do
        list[#list + 1] = { id = SHELLS[i].id, label = SHELLS[i].label }
    end
    list[#list + 1] = { id = DARK_FORM_ID, label = DARK_FORM_LABEL }
    return list
end

---@param id string
---@return boolean
function M.Switch(id)
    local pc = GetPlayerController()
    if not pc then
        Log("Skipped: no player controller (load into a world first)")
        return false
    end
    if id == DARK_FORM_ID then
        return ActivateDarkForm(pc)
    end
    if #SHELLS == 0 then
        LoadCatalog()
    end
    local shell = ShellById(id)
    if shell ~= nil then
        EquipShell(pc, shell)
        return true
    end
    Log("Switch: unknown shell " .. tostring(id))
    return false
end

local function BuildItems()
    local items = {
        { type = "label", label = "S_SwitchToShell — skips the shrine gate." },
    }
    if #SHELLS == 0 then
        items[#items + 1] = {
            type = "label",
            label = "Shell list not loaded — open the menu in a world.",
        }
    end
    for i = 1, #SHELLS do
        local shell = SHELLS[i]
        items[#items + 1] = {
            type = "button",
            id = ShellButtonId(shell),
            label = ButtonLabel(shell),
            onClick = function()
                M.Switch(shell.id)
            end,
        }
    end
    items[#items + 1] = { type = "separator" }
    items[#items + 1] = {
        type = "button",
        id = DARK_FORM_ID,
        label = DARK_FORM_LABEL,
        onClick = function()
            M.Switch(DARK_FORM_ID)
        end,
    }
    return items
end

local function RegisterSection()
    ModMenu.Register({
        id = SECTION_ID,
        title = "Switch Shell",
        tab = "Shells",
        collapsible = true,
        collapsed = false,
        items = BuildItems(),
    })
    registeredCount = #SHELLS
end

function M.Register()
    LoadCatalog()

    local pc = GetPlayerController()
    if pc then
        local detected = DetectCurrentShell(pc)
        if detected then
            currentId = detected.id
            Log("Current shell: " .. (detected.label or detected.name))
        end
    end

    RegisterSection()
    NotifyChanged()

    ModMenu.OnOpen(function()
        local before = #SHELLS
        LoadCatalog()
        if #SHELLS ~= registeredCount then
            RegisterSection()
        else
            RefreshShellLabels()
        end
        if before == 0 and #SHELLS > 0 then
            Log(string.format("Shells: loaded %d after menu open", #SHELLS))
        end
        RefreshFromWorld()
    end)

    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
        if wantedName == nil then
            return
        end
        if reapplyHandle then
            pcall(CancelDelayedAction, reapplyHandle)
            reapplyHandle = nil
        end
        reapplyHandle = ExecuteInGameThreadWithDelay(3000, function()
            reapplyHandle = nil
            ReapplyWantedShell()
        end)
    end)
end

return M
