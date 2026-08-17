--[[
  Mortal Shell 2 — cheat menu (ModMenu).

  F6 toggles. Calls BP_PlayerController S_* cheats via UEHelpers.GetPlayerController().

  Unlocks also fire Steam achievements.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")

ModMenu.Init({
    title = "Mortal Shell 2",
    instanceId = "MortalShell2Mod",
    key = Key.F6,
    keyHint = "F6",
    dock = "right",
    fontTitle = 16,
    fontSection = 12,
    fontItem = 10,
    fontHint = 8,
    fontDropdown = 9,
})

print("--------------------------------")
print("|  Mortal Shell 2 Mod Loaded   |")
print("|  F6 = Cheat menu             |")
print("|  Unlocks fire Steam achievements")
print("--------------------------------")

local SECTION_TOGGLES = "Toggles"
local SECTION_UNLOCKS = "Unlocks"
local SECTION_ITEMS = "Items"
local SECTION_ADD = "Add"
local SECTION_COMBAT = "Combat"

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

--- UEHelpers.GetPlayerController() does FindAllOf every call. Cache it.
local cachedPC = nil
local cachedPawn = nil
local objectAddressOk = true

local function InvalidatePlayerCache()
    cachedPC = nil
    cachedPawn = nil
end

local function ObjectAddress(obj)
    if not objectAddressOk or obj == nil then
        return nil
    end
    local ok, addr = pcall(function()
        return obj:GetAddress()
    end)
    if not ok then
        objectAddressOk = false
        return nil
    end
    return addr
end

---@return APlayerController|nil
local function GetPlayerController()
    if cachedPC ~= nil and IsValid(cachedPC) then
        return cachedPC
    end
    cachedPC = nil
    cachedPawn = nil
    local pc = UEHelpers.GetPlayerController()
    if IsValid(pc) then
        cachedPC = pc
        return pc
    end
    return nil
end

---@return APawn|nil
local function GetPlayerPawn()
    local pc = GetPlayerController()
    if not pc then
        cachedPawn = nil
        return nil
    end
    local pawn = pc.Pawn
    if IsValid(pawn) then
        cachedPawn = pawn
        return pawn
    end
    cachedPawn = nil
    return nil
end

---@return APawn|nil
local function PeekCachedPawn()
    if cachedPawn ~= nil and IsValid(cachedPawn) then
        return cachedPawn
    end
    return GetPlayerPawn()
end

---@param obj UObject
---@param name string
---@param call fun(obj: UObject)
---@return boolean
local function SafeCall(obj, name, call)
    local ok, err = pcall(call, obj)
    if ok then
        Log("Called " .. name)
        return true
    end
    Log("Failed " .. name .. " — " .. tostring(err))
    return false
end

---@param name string
---@param call fun(pc: APlayerController)
---@return boolean
local function CallOnPlayerController(name, call)
    local pc = GetPlayerController()
    if not pc then
        Log("Skipped: no player controller (load into a world first)")
        return false
    end
    return SafeCall(pc, name, call)
end

--- Auto Heal / Infinite Resolve: cached poll only. Do not hook every attack.
local TICK_MS = 1000
local RESTART_DELAY_MS = 3000
local HEAL_AMOUNT = 9999
local RESOLVE_AMOUNT = 9999

local autoHealOn = false
local infiniteResolveOn = false
local noCooldownOn = false
local tickHandle = nil
local cooldownTickHandle = nil
--- [ability full name] = original cooldown fields (restored on toggle off)
local cooldownSaved = {}

local function CancelTick()
    if tickHandle then
        pcall(CancelDelayedAction, tickHandle)
        tickHandle = nil
    end
end

---@return USpartaHealthComponent|nil
local function GetHealthComponent(pc)
    local pawn = pc.Pawn
    if not IsValid(pawn) then
        return nil
    end
    local hc = pawn.HealthComponent
    if IsValid(hc) then
        return hc
    end
    return nil
end

local function AttrCurrent(data)
    if data == nil then
        return nil
    end
    local n = tonumber(data.CurrentValue)
    if n ~= nil then
        return n
    end
    return tonumber(data.BaseValue)
end

local function NeedsHeal(hc)
    if not IsValid(hc) then
        return true
    end
    local okH, health = pcall(function() return hc:GetHealth() end)
    local okM, maxH = pcall(function() return hc:GetMaxHealth() end)
    if okH and okM and health ~= nil and maxH ~= nil and health < (maxH - 0.5) then
        return true
    end
    local okS, shell = pcall(function() return hc:GetShellHealth() end)
    local okSM, maxShell = pcall(function() return hc:GetMaxShellHealth() end)
    if okS and okSM and shell ~= nil and maxShell ~= nil and maxShell > 0 and shell < (maxShell - 0.5) then
        return true
    end
    if not (okH and okM) then
        return true
    end
    return false
end

local function NeedsResolve(hc)
    if not IsValid(hc) then
        return true
    end
    local set = hc.HealthSet
    if not IsValid(set) then
        return true
    end
    local current = AttrCurrent(set.Resolve)
    local max = AttrCurrent(set.MaxResolve)
    if current ~= nil and max ~= nil then
        return current < (max - 0.5)
    end
    return true
end

local function ApplyAutoHeal(pc)
    if not autoHealOn then
        return
    end
    pc = pc or GetPlayerController()
    if not pc then
        return
    end
    local hc = GetHealthComponent(pc)
    if NeedsHeal(hc) then
        pcall(function()
            pc:S_Heal(HEAL_AMOUNT)
        end)
    end
end

local function ApplyInfiniteResolve(pc)
    if not infiniteResolveOn then
        return
    end
    pc = pc or GetPlayerController()
    if not pc then
        return
    end
    local hc = GetHealthComponent(pc)
    if NeedsResolve(hc) then
        pcall(function()
            pc:S_GainResolve(RESOLVE_AMOUNT)
        end)
    end
end

local function TickToggles()
    if not autoHealOn and not infiniteResolveOn then
        return
    end
    local pc = GetPlayerController()
    if not pc then
        return
    end
    ApplyAutoHeal(pc)
    ApplyInfiniteResolve(pc)
end

local function EnsureTick()
    if tickHandle then
        return
    end
    tickHandle = LoopInGameThreadWithDelay(TICK_MS, TickToggles)
end

local function StopTickIfIdle()
    if autoHealOn or infiniteResolveOn then
        return
    end
    CancelTick()
end

--- Safety net only. Hooks strip cooldown on apply; do not rescan/rewrite every tick.
local COOLDOWN_TICK_MS = 1500
--- ESpartaAbilityGlobalCooldown.Disabled
local COOLDOWN_DISABLED = 0

local function CancelCooldownTick()
    if cooldownTickHandle then
        pcall(CancelDelayedAction, cooldownTickHandle)
        cooldownTickHandle = nil
    end
end

---@param a UObject|nil
---@param b UObject|nil
---@return boolean
local function SameObject(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local addrA = ObjectAddress(a)
    if addrA == nil then
        return false
    end
    return addrA == ObjectAddress(b)
end

---@param param any
---@return any
local function UnwrapParam(param)
    if param == nil then
        return nil
    end
    if type(param) == "userdata" and type(param.get) == "function" then
        local ok, val = pcall(function()
            return param:get()
        end)
        if ok then
            return val
        end
    end
    return param
end

---@param ability UObject
---@return boolean
local function IsDefaultObject(ability)
    if EObjectFlags ~= nil then
        local banned = EObjectFlags.RF_ClassDefaultObject
        if EObjectFlags.RF_ArchetypeObject then
            banned = banned + EObjectFlags.RF_ArchetypeObject
        end
        local ok, has = pcall(function()
            return ability:HasAnyFlags(banned)
        end)
        if ok and has then
            return true
        end
    end
    local okName, name = pcall(function()
        return ability:GetFullName()
    end)
    if okName and type(name) == "string" and name:find("Default__", 1, true) then
        return true
    end
    return false
end

---@param ability UObject
---@param pawn APawn
---@return boolean
local function IsPlayerOwnedAbility(ability, pawn)
    if not IsValid(ability) or not IsValid(pawn) or IsDefaultObject(ability) then
        return false
    end
    local ok, outer = pcall(function()
        return ability:GetOuter()
    end)
    if not ok or not IsValid(outer) then
        return false
    end
    if SameObject(outer, pawn) then
        return true
    end
    -- Instanced abilities are sometimes outered to the ASC, then the pawn.
    local ok2, outer2 = pcall(function()
        return outer:GetOuter()
    end)
    if ok2 and IsValid(outer2) and SameObject(outer2, pawn) then
        return true
    end
    return false
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

---@param pawn APawn
---@return UObject[]
local function CollectPlayerAbilities(pawn)
    local seen = {}
    local list = {}

    local function add(ability)
        if not IsValid(ability) or IsDefaultObject(ability) then
            return
        end
        local ok, name = pcall(function()
            return ability:GetFullName()
        end)
        if not ok or type(name) ~= "string" or seen[name] then
            return
        end
        seen[name] = true
        list[#list + 1] = ability
    end

    -- FindAllOf includes Blueprint subclasses. A second scan of GA_SpartaAbility_C
    -- just walks the UObject heap again.
    local found = FindAllOf("SpartaGameplayAbility")
    if found then
        for _, ability in ipairs(found) do
            if IsPlayerOwnedAbility(ability, pawn) then
                add(ability)
            end
        end
    end

    local asc = pawn.AbilitySystemComponent
    if IsValid(asc) then
        local ok, active = pcall(function()
            return asc:GetActiveAbilities()
        end)
        if ok then
            ForEachArrayItem(active, add)
        end
    end

    return list
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

---@param ability UObject
local function SaveCooldownFields(ability)
    local name = ability:GetFullName()
    if cooldownSaved[name] then
        return
    end
    cooldownSaved[name] = {
        CooldownDuration = ReadField(ability, "CooldownDuration"),
        GlobalCooldownDuration = ReadField(ability, "GlobalCooldownDuration"),
        Cooldown = ReadField(ability, "Cooldown"),
        GlobalCooldown = ReadField(ability, "GlobalCooldown"),
        StoneFormCooldown = ReadField(ability, "StoneFormCooldown"),
        PerfectStoneFormCooldown = ReadField(ability, "PerfectStoneFormCooldown"),
    }
end

---@param ability UObject
local function ZeroCooldownFields(ability)
    WriteField(ability, "CooldownDuration", 0)
    WriteField(ability, "GlobalCooldownDuration", 0)
    WriteField(ability, "Cooldown", COOLDOWN_DISABLED)
    WriteField(ability, "GlobalCooldown", COOLDOWN_DISABLED)
    WriteField(ability, "StoneFormCooldown", 0)
    WriteField(ability, "PerfectStoneFormCooldown", 0)
end

---@param ability UObject
local function RestoreCooldownFields(ability)
    local snap = cooldownSaved[ability:GetFullName()]
    if not snap then
        return
    end
    if snap.CooldownDuration ~= nil then
        WriteField(ability, "CooldownDuration", snap.CooldownDuration)
    end
    if snap.GlobalCooldownDuration ~= nil then
        WriteField(ability, "GlobalCooldownDuration", snap.GlobalCooldownDuration)
    end
    if snap.Cooldown ~= nil then
        WriteField(ability, "Cooldown", snap.Cooldown)
    end
    if snap.GlobalCooldown ~= nil then
        WriteField(ability, "GlobalCooldown", snap.GlobalCooldown)
    end
    if snap.StoneFormCooldown ~= nil then
        WriteField(ability, "StoneFormCooldown", snap.StoneFormCooldown)
    end
    if snap.PerfectStoneFormCooldown ~= nil then
        WriteField(ability, "PerfectStoneFormCooldown", snap.PerfectStoneFormCooldown)
    end
end

---@param ability UObject
---@param pawn APawn
local function ClearAbilityCooldown(ability, pawn)
    pcall(function()
        ability:ClearLocalCooldown(pawn)
    end)
    pcall(function()
        ability:ClearGlobalCooldown(pawn)
    end)
end

---@param restore boolean
---@return integer
local function ApplyNoCooldownToPlayerAbilities(restore)
    local pawn = GetPlayerPawn()
    if not pawn then
        return 0
    end
    local abilities = CollectPlayerAbilities(pawn)
    for _, ability in ipairs(abilities) do
        if restore then
            RestoreCooldownFields(ability)
        else
            SaveCooldownFields(ability)
            ZeroCooldownFields(ability)
            ClearAbilityCooldown(ability, pawn)
        end
    end
    return #abilities
end

local cachedPlayerAbilities = {}
local lastCooldownPawn = nil

local function ApplyCachedAbilityStrip(ability, pawn)
    SaveCooldownFields(ability)
    ZeroCooldownFields(ability)
    ClearAbilityCooldown(ability, pawn)
end

local function StripPlayerAbilities(pawn)
    cachedPlayerAbilities = CollectPlayerAbilities(pawn)
    lastCooldownPawn = pawn
    for _, ability in ipairs(cachedPlayerAbilities) do
        ApplyCachedAbilityStrip(ability, pawn)
    end
    return #cachedPlayerAbilities
end

--- Only rescans when the pawn changes. Apply*Cooldown hooks handle the rest.
local function TickNoCooldown()
    if not noCooldownOn then
        return
    end
    local pawn = GetPlayerPawn()
    if not pawn then
        return
    end
    if lastCooldownPawn ~= nil and SameObject(lastCooldownPawn, pawn) and #cachedPlayerAbilities > 0 then
        return
    end
    StripPlayerAbilities(pawn)
end

local function EnsureCooldownTick()
    if cooldownTickHandle then
        return
    end
    cooldownTickHandle = LoopInGameThreadWithDelay(COOLDOWN_TICK_MS, TickNoCooldown)
end

local function NoCooldownOn()
    noCooldownOn = true
    cachedPlayerAbilities = {}
    lastCooldownPawn = nil
    local pawn = GetPlayerPawn()
    local n = 0
    if pawn then
        n = StripPlayerAbilities(pawn)
    end
    EnsureCooldownTick()
    Log("No Ability Cooldown: ON (" .. tostring(n) .. " abilities)")
end

local function NoCooldownOff()
    noCooldownOn = false
    CancelCooldownTick()
    ApplyNoCooldownToPlayerAbilities(true)
    cooldownSaved = {}
    cachedPlayerAbilities = {}
    lastCooldownPawn = nil
    Log("No Ability Cooldown: OFF")
end

---@param ability UObject|nil
---@param owner UObject|nil
---@return UObject|nil
local function PlayerAbilityToStrip(ability, owner)
    if not IsValid(ability) then
        return nil
    end
    local pawn = PeekCachedPawn()
    if not pawn then
        return nil
    end
    if IsValid(owner) then
        if owner == pawn or SameObject(owner, pawn) then
            return pawn
        end
        return nil
    end
    if IsPlayerOwnedAbility(ability, pawn) then
        return pawn
    end
    return nil
end

local function HookPlayerCooldownApply(path, clearLocal, clearGlobal)
    local function pre(Context, Owner)
        if not noCooldownOn then
            return
        end
        local ability = UnwrapParam(Context)
        local owner = UnwrapParam(Owner)
        if PlayerAbilityToStrip(ability, owner) then
            SaveCooldownFields(ability)
            ZeroCooldownFields(ability)
        end
    end

    local function post(Context, Owner)
        if not noCooldownOn then
            return
        end
        local ability = UnwrapParam(Context)
        local owner = UnwrapParam(Owner)
        local pawn = PlayerAbilityToStrip(ability, owner)
        if not pawn then
            return
        end
        if clearLocal then
            pcall(function()
                ability:ClearLocalCooldown(pawn)
            end)
        end
        if clearGlobal then
            pcall(function()
                ability:ClearGlobalCooldown(pawn)
            end)
        end
    end

    local ok = pcall(function()
        RegisterHook(path, pre, post)
    end)
    if not ok then
        -- Older UE4SS: pre-hook only. Tick still clears leftover cooldown.
        pcall(function()
            RegisterHook(path, pre)
        end)
    end
end

HookPlayerCooldownApply("/Script/Sparta.SpartaGameplayAbility:ApplyLocalCooldown", true, false)
HookPlayerCooldownApply("/Script/Sparta.SpartaGameplayAbility:ApplyGlobalCooldown", false, true)

local function AutoHealOn()
    autoHealOn = true
    GetPlayerPawn()
    ApplyAutoHeal()
    EnsureTick()
    Log("Auto Heal: ON")
end

local function AutoHealOff()
    autoHealOn = false
    StopTickIfIdle()
    Log("Auto Heal: OFF")
end

local function InfiniteResolveOn()
    infiniteResolveOn = true
    GetPlayerPawn()
    ApplyInfiniteResolve()
    EnsureTick()
    Log("Infinite Resolve: ON")
end

local function InfiniteResolveOff()
    infiniteResolveOn = false
    StopTickIfIdle()
    Log("Infinite Resolve: OFF")
end

local function ReapplyTogglesAfterRestart()
    InvalidatePlayerCache()
    CancelTick()
    CancelCooldownTick()
    if not autoHealOn and not infiniteResolveOn and not noCooldownOn then
        return
    end
    ExecuteInGameThreadWithDelay(RESTART_DELAY_MS, function()
        InvalidatePlayerCache()
        if autoHealOn or infiniteResolveOn then
            EnsureTick()
            local pc = GetPlayerController()
            ApplyAutoHeal(pc)
            ApplyInfiniteResolve(pc)
        end
        if noCooldownOn then
            cachedPlayerAbilities = {}
            lastCooldownPawn = nil
            local pawn = GetPlayerPawn()
            if pawn then
                StripPlayerAbilities(pawn)
            end
            EnsureCooldownTick()
        end
        if autoHealOn or infiniteResolveOn or noCooldownOn then
            Log("Toggles re-applied after ClientRestart")
        end
    end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ReapplyTogglesAfterRestart()
end)

ModMenu.Register({
    id = SECTION_TOGGLES,
    title = "Toggles",
    items = {
        {
            type = "checkbox",
            id = "autoHeal",
            label = "Auto Heal",
            default = false,
            onChange = function(on)
                if on then
                    AutoHealOn()
                else
                    AutoHealOff()
                end
            end,
        },
        {
            type = "checkbox",
            id = "infiniteResolve",
            label = "Infinite Resolve",
            default = false,
            onChange = function(on)
                if on then
                    InfiniteResolveOn()
                else
                    InfiniteResolveOff()
                end
            end,
        },
        {
            type = "checkbox",
            id = "noAbilityCooldown",
            label = "No Ability Cooldown",
            default = false,
            onChange = function(on)
                if on then
                    NoCooldownOn()
                else
                    NoCooldownOff()
                end
            end,
        },
    },
})

require("Shells").Register()

---@param id string
---@param label string
---@param name string
---@param call fun(pc: APlayerController)
local function PcButton(id, label, name, call)
    return {
        type = "button",
        id = id,
        label = label,
        onClick = function()
            CallOnPlayerController(name, call)
        end,
    }
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
            Log("Unlocked shell: " .. name)
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

--- Shared column widths so label / field / Add line up across rows.
local AMOUNT_LABEL_WIDTH = 150
local AMOUNT_FIELD_WIDTH = 72

--- Row: integer amount field + Add button. Reads ModMenu.Get(sectionId, amountId).
---@param sectionId string
---@param id string
---@param label string
---@param name string
---@param callWithAmount fun(pc: APlayerController, n: integer)
---@param default integer|nil
local function AmountRow(sectionId, id, label, name, callWithAmount, default)
    local amountId = id .. "Amount"
    return {
        type = "row",
        items = {
            {
                type = "number",
                id = amountId,
                label = label,
                default = default or 100,
                min = 1,
                integer = true,
                labelWidth = AMOUNT_LABEL_WIDTH,
                fieldWidth = AMOUNT_FIELD_WIDTH,
            },
            {
                type = "button",
                id = id,
                label = "Add",
                onClick = function()
                    local n = tonumber(ModMenu.Get(sectionId, amountId)) or 0
                    n = math.floor(n)
                    if n < 1 then
                        Log("Skipped: " .. name .. " amount must be >= 1")
                        return
                    end
                    CallOnPlayerController(string.format("%s(%d)", name, n), function(pc)
                        callWithAmount(pc, n)
                    end)
                end,
            },
        },
    }
end

ModMenu.Register({
    id = SECTION_UNLOCKS,
    title = "Unlocks",
    items = {
        {
            type = "label",
            label = "Steam achievements unlock with these. Load into a world first.",
        },
        { type = "separator" },
        PcButton("clothing", "Unlock All Clothing", "S_UnlockAllClothing", function(pc) pc:S_UnlockAllClothing() end),
        PcButton("gates", "Unlock All Gates", "S_UnlockAllGates", function(pc) pc:S_UnlockAllGates() end),
        PcButton("landing", "Unlock All Landing Areas", "S_UnlockAllLandingAreas",
            function(pc) pc:S_UnlockAllLandingAreas() end),
        PcButton("masks", "Unlock All Masks", "S_UnlockAllMasks", function(pc) pc:S_UnlockAllMasks() end),
        PcButton("seals", "Unlock All Seals", "S_UnlockAllSeals", function(pc) pc:S_UnlockAllSeals() end),
        PcButton("shells", "Unlock All Shells", "UnlockAllShells", UnlockAllShellsThorough),
        PcButton("sidearms", "Unlock All Sidearms", "S_UnlockAllSidearms", function(pc) pc:S_UnlockAllSidearms() end),
        PcButton("weapons", "Unlock All Weapons", "S_UnlockAllWeapons", function(pc) pc:S_UnlockAllWeapons() end),
    },
})

ModMenu.Register({
    id = SECTION_ITEMS,
    title = "Items & Tarstones",
    items = {
        PcButton("allItems", "Add All Items", "S_AddAllItems", function(pc) pc:S_AddAllItems() end),
        { type = "separator" },
        PcButton("tarMelee", "Add All Tarstones (Melee)", "S_AddAllTarstonesMelee",
            function(pc) pc:S_AddAllTarstonesMelee() end),
        PcButton("tarSupport", "Add All Tarstones (Support)", "S_AddAllTarstonesSupport",
            function(pc) pc:S_AddAllTarstonesSupport() end),
        PcButton("tarSidearm", "Add All Tarstones (Sidearm)", "S_AddAllTarstonesSidearm",
            function(pc) pc:S_AddAllTarstonesSidearm() end),
        PcButton("tarLevel", "Increment All Tarstone Levels", "S_TarstoneLevelIncrementall",
            function(pc) pc:S_TarstoneLevelIncrementall() end),
    },
})

ModMenu.Register({
    id = SECTION_ADD,
    title = "Add Amount",
    items = {
        {
            type = "label",
            label = "Set the amount, then press Add.",
        },
        AmountRow(SECTION_ADD, "gold", "Gold", "S_AddGold", function(pc, n) pc:S_AddGold(n) end, 100),
        AmountRow(SECTION_ADD, "gloom", "Gloom", "S_AddGloom", function(pc, n) pc:S_AddGloom(n) end, 100),
        AmountRow(SECTION_ADD, "glimpses", "Glimpses", "S_AddGlimpses", function(pc, n) pc:S_AddGlimpses(n) end, 100),
        AmountRow(SECTION_ADD, "tarcores", "Tarcores", "S_AddTarcores", function(pc, n) pc:S_AddTarcores(n) end, 100),
        AmountRow(SECTION_ADD, "ventrium", "Ventrium", "S_AddVentrium", function(pc, n) pc:S_AddVentrium(n) end, 100),
        AmountRow(SECTION_ADD, "laterite", "Laterite", "S_AddLaterite", function(pc, n) pc:S_AddLaterite(n) end, 100),
        AmountRow(SECTION_ADD, "dorsalite", "Dorsalite", "S_AddDorsalite", function(pc, n) pc:S_AddDorsalite(n) end, 100),
        AmountRow(SECTION_ADD, "thoracium", "Thoracium", "S_AddThoracium", function(pc, n) pc:S_AddThoracium(n) end, 100),
        AmountRow(SECTION_ADD, "ovums", "Ovums", "S_AddOvums", function(pc, n) pc:S_AddOvums(n) end, 100),
    },
})

ModMenu.Register({
    id = SECTION_COMBAT,
    title = "Combat",
    items = {
        AmountRow(SECTION_COMBAT, "heal", "Heal", "S_Heal", function(pc, n) pc:S_Heal(n) end, 100),
        AmountRow(SECTION_COMBAT, "resolve", "Resolve", "S_GainResolve", function(pc, n) pc:S_GainResolve(n) end, 100),
    },
})
