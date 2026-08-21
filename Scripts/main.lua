--[[
  Mortal Shell 2 — cheat menu (ModMenu).

  F6 toggles. Calls BP_PlayerController S_* cheats via UEHelpers.GetPlayerController().

  Unlocks also fire Steam achievements.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")
local Tarstones = require("Tarstones")
local Give = require("Give")
local Character = require("Character")

ConfigManager.Init({
    id = "MortalShell2Mod",
    defaults = {
        keybinds = {},
        moveMult = "2",
        healPct = 100,
        combat = {
            heal = 100,
            resolve = 100,
        },
        toggles = {
            autoHeal = false,
            infiniteResolve = false,
            noAbilityCooldown = false,
            alwaysParry = false,
            alwaysPerfectBlock = false,
            alwaysPerfectHarden = false,
            extraMaxShellPoints = false,
            moveFast = false,
            god = false,
        },
    },
})

ModMenu.Init({
    title = "Mortal Shell 2",
    instanceId = "MortalShell2Mod",
    key = Key.F6,
    keyHint = "F6",
    dock = "right",
    tabs = { "Cheats", "Shells", "Give", "Unlocks", "Keybinds" },
    fontTitle = 16,
    fontSection = 12,
    fontItem = 10,
    fontHint = 8,
    fontDropdown = 9,
})

print("--------------------------------")
print("|  Mortal Shell 2 Mod Loaded   |")
print("|  F6 = Cheat menu             |")
print("|  Tabs: Cheats / Shells / Give / Unlocks / Keybinds")
print("|  Keybinds: saved, menu closed")
print("|  Unlocks fire Steam achievements")
print("--------------------------------")

local SECTION_TOGGLES = "Toggles"
local SECTION_UNLOCKS = "Unlocks"
local SECTION_MAP = "Map"
local SECTION_ITEMS = "Tarstones"
local SECTION_ADD = "Add"
local SECTION_COMBAT = "Combat"

local TAB_CHEATS = "Cheats"
local TAB_GIVE = "Give"
local TAB_UNLOCKS = "Unlocks"

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
local RESOLVE_TICK_MS = 1000
local RESTART_DELAY_MS = 3000
local HEAL_AMOUNT = 9999
local RESOLVE_AMOUNT = 9999

local autoHealOn = false
local godOn = false
local infiniteResolveOn = false
local noCooldownOn = false
local alwaysParryOn = false
local alwaysPerfectBlockOn = false
local alwaysPerfectHardenOn = false
local extraMaxShellPointsOn = false
local healTickHandle = nil
local resolveTickHandle = nil
local cooldownTickHandle = nil
--- [ability full name] = original cooldown fields (restored on toggle off)
local cooldownSaved = {}

local function CancelHealTick()
    if healTickHandle then
        pcall(CancelDelayedAction, healTickHandle)
        healTickHandle = nil
    end
end

local function CancelResolveTick()
    if resolveTickHandle then
        pcall(CancelDelayedAction, resolveTickHandle)
        resolveTickHandle = nil
    end
end

local function CancelTick()
    CancelHealTick()
    CancelResolveTick()
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

--- Deal current shell HP so OnShellHealthDepleted can run (same path as a hit).
---@param pc APlayerController
---@return boolean
local function TryBreakShell(pc)
    local hc = GetHealthComponent(pc)
    if not IsValid(hc) then
        Log("Break Shell: no health component")
        return false
    end
    local okRead, shellHp = pcall(function()
        return hc:GetShellHealth()
    end)
    shellHp = okRead and tonumber(shellHp) or nil
    if shellHp == nil then
        Log("Break Shell: could not read shell health")
        return false
    end
    if shellHp <= 0.5 then
        Log("Break Shell: shell health already empty (" .. tostring(shellHp) .. ")")
        return false
    end
    local amount = shellHp + 1
    local ok, err = pcall(function()
        pc:S_DealDamage(amount)
    end)
    if not ok then
        Log("Break Shell: S_DealDamage failed - " .. tostring(err))
        return false
    end
    Log(string.format("Break Shell: S_DealDamage(%.1f) shell was %.1f", amount, shellHp))
    return true
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

local function HealAmountForTick(hc)
    local pct = Character.HealPercent()
    local maxH = nil
    if IsValid(hc) then
        pcall(function()
            maxH = tonumber(hc:GetMaxHealth())
        end)
        if maxH == nil or maxH <= 0 then
            pcall(function()
                maxH = tonumber(hc:GetMaxShellHealth())
            end)
        end
    end
    if maxH ~= nil and maxH > 0 then
        return math.max(1, maxH * (pct / 100))
    end
    return math.max(1, HEAL_AMOUNT * (pct / 100))
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
        local amount = HealAmountForTick(hc)
        pcall(function()
            pc:S_Heal(amount)
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

local function TickHeal()
    if not autoHealOn then
        return
    end
    ApplyAutoHeal()
end

local function TickResolve()
    if not infiniteResolveOn then
        return
    end
    ApplyInfiniteResolve()
end

local function EnsureHealTick()
    if healTickHandle or not autoHealOn then
        return
    end
    healTickHandle = LoopInGameThreadWithDelay(Character.HealDelayMs(), TickHeal)
end

local function EnsureResolveTick()
    if resolveTickHandle or not infiniteResolveOn then
        return
    end
    resolveTickHandle = LoopInGameThreadWithDelay(RESOLVE_TICK_MS, TickResolve)
end

local function EnsureTick()
    EnsureHealTick()
    EnsureResolveTick()
end

local function RestartHealTick()
    CancelHealTick()
    EnsureHealTick()
end

Character.NotifyHealDelayChanged = RestartHealTick

local function StopTickIfIdle()
    if not autoHealOn then
        CancelHealTick()
    end
    if not infiniteResolveOn then
        CancelResolveTick()
    end
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

---@param pawn APawn|nil
---@return boolean|nil
local function PawnCanBeDamaged(pawn)
    if not IsValid(pawn) then
        return nil
    end
    local ok, v = pcall(function()
        return pawn.bCanBeDamaged
    end)
    if not ok or v == nil then
        return nil
    end
    if v == false or v == 0 then
        return false
    end
    return true
end

---@return UCheatManager|nil
local function GetCheatManager()
    local pc = GetPlayerController()
    if not pc then
        return nil
    end
    local cm = nil
    pcall(function()
        cm = pc.CheatManager
    end)
    if IsValid(cm) then
        return cm
    end
    pcall(function()
        pc:EnableCheats()
    end)
    pcall(function()
        cm = pc.CheatManager
    end)
    if IsValid(cm) then
        return cm
    end
    return nil
end

--- Engine God() toggles CanBeDamaged. Only call when the pawn is not already
--- in the wanted state, then write bCanBeDamaged so polarity cannot drift.
---@param wantOn boolean
---@return boolean
local function ApplyGod(wantOn)
    local cm = GetCheatManager()
    if not IsValid(cm) then
        return false
    end
    local pawn = GetPlayerPawn()
    local canDamage = PawnCanBeDamaged(pawn)
    if canDamage ~= nil then
        local isGod = not canDamage
        if isGod ~= wantOn then
            local ok = pcall(function()
                cm:God()
            end)
            if not ok then
                return false
            end
        end
    else
        local ok = pcall(function()
            cm:God()
        end)
        if not ok then
            return false
        end
    end
    if IsValid(pawn) then
        pcall(function()
            pawn.bCanBeDamaged = not wantOn
        end)
    end
    return true
end

local function GodOn()
    godOn = true
    if ApplyGod(true) then
        Log("God: ON")
    else
        Log("God: ON (waiting for world)")
    end
end

local function GodOff()
    godOn = false
    ApplyGod(false)
    Log("God: OFF")
end

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

local EXTRA_MAX_SHELL_POINTS = 100
--- [tag string] = original StartingMaxShellPoints
local shellPointsSaved = {}

---@return UObject|nil
local function GetProgressionComponent(pc)
    pc = pc or GetPlayerController()
    if not pc then
        return nil
    end
    local names = { "Progression Component", "ProgressionComponent" }
    for i = 1, #names do
        local comp = nil
        pcall(function()
            comp = pc[names[i]]
        end)
        if IsValid(comp) then
            return comp
        end
    end
    local found = FindAllOf("BPC_Player_Progression_C")
    if found then
        for _, obj in ipairs(found) do
            local skip = false
            pcall(function()
                local name = obj:GetFullName()
                if type(name) == "string" and name:find("Default__", 1, true) then
                    skip = true
                end
            end)
            if IsValid(obj) and not skip then
                return obj
            end
        end
    end
    return nil
end

---@param tag any
---@return string|nil
local function ShellPointKey(tag)
    tag = UnwrapParam(tag)
    if tag == nil then
        return nil
    end
    if type(tag) == "string" and tag ~= "" then
        return tag
    end
    local ok, name = pcall(function()
        local n = tag.TagName
        if n ~= nil then
            if type(n) == "string" then
                return n
            end
            if type(n.ToString) == "function" then
                return n:ToString()
            end
        end
        if type(tag.ToString) == "function" then
            return tag:ToString()
        end
        return nil
    end)
    if ok and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

---@param value any
---@return number|nil
local function MapInt(value)
    value = UnwrapParam(value)
    return tonumber(value)
end

---@param map any
---@param key any
---@param valueWrap any
---@param newVal number
---@return boolean
local function WriteMapInt(map, key, valueWrap, newVal)
    if valueWrap ~= nil and type(valueWrap.set) == "function" then
        local ok = pcall(function()
            valueWrap:set(newVal)
        end)
        if ok then
            return true
        end
    end
    local ok = pcall(function()
        map:Add(UnwrapParam(key) or key, newVal)
    end)
    return ok
end

---@param restore boolean
---@return integer
local function ApplyStartingMaxShellPoints(restore)
    local comp = GetProgressionComponent()
    if not IsValid(comp) then
        return 0
    end
    local map = nil
    pcall(function()
        map = comp.StartingMaxShellPoints
    end)
    if map == nil or type(map.ForEach) ~= "function" then
        return 0
    end
    local n = 0
    map:ForEach(function(key, value)
        local id = ShellPointKey(key)
        local current = MapInt(value)
        if id and shellPointsSaved[id] == nil and current ~= nil then
            shellPointsSaved[id] = current
        end
        local target = EXTRA_MAX_SHELL_POINTS
        if restore then
            target = (id and shellPointsSaved[id]) or current
        end
        if target ~= nil and WriteMapInt(map, key, value, target) then
            n = n + 1
        end
    end)
    return n
end

local function ExtraMaxShellPointsOn()
    GetPlayerPawn()
    local n = ApplyStartingMaxShellPoints(false)
    if n == 0 then
        extraMaxShellPointsOn = false
        ModMenu.Set(SECTION_TOGGLES, "extraMaxShellPoints", false)
        Log("Max Shell Points: OFF — progression component not found")
        return
    end
    extraMaxShellPointsOn = true
    Log(string.format("Max Shell Points: ON (%d shells -> %d)", n, EXTRA_MAX_SHELL_POINTS))
end

local function ExtraMaxShellPointsOff()
    extraMaxShellPointsOn = false
    local n = ApplyStartingMaxShellPoints(true)
    Log(string.format("Max Shell Points: OFF (%d shells restored)", n))
end

--- Blueprint abilities are not loaded until a pawn exists.
--- Register on ClientRestart; UnregisterHook first so restarts do not stack.

---@param classPath string
---@return boolean
local function BlueprintClassLoaded(classPath)
    local name = classPath:match("([^./]+)$")
    if type(name) ~= "string" or name == "" then
        return false
    end
    local obj = FindFirstOf(name)
    return IsValid(obj)
end

---@param state { prefix: string, classPath: string, isOn: fun(): boolean, entries: table }
---@param entry { name: string, whenOn: boolean, preId: integer|nil, postId: integer|nil }
local function UnhookBlueprintBool(state, entry)
    if entry.preId == nil and entry.postId == nil then
        return
    end
    local path = state.classPath .. ":" .. entry.name
    local ok, err = pcall(UnregisterHook, path, entry.preId, entry.postId)
    if not ok then
        Log(state.prefix .. ": unhook failed " .. entry.name .. " — " .. tostring(err))
    end
    entry.preId = nil
    entry.postId = nil
end

---@param state { prefix: string, classPath: string, isOn: fun(): boolean, entries: table }
---@param entry { name: string, whenOn: boolean, preId: integer|nil, postId: integer|nil }
---@return boolean
local function HookBlueprintBool(state, entry)
    UnhookBlueprintBool(state, entry)
    local path = state.classPath .. ":" .. entry.name
    local ok, preId, postId = pcall(function()
        return RegisterHook(path, function()
            if not state.isOn() then
                return
            end
            return entry.whenOn
        end)
    end)
    if not ok then
        Log(state.prefix .. ": failed to hook " .. entry.name .. " — " .. tostring(preId))
        entry.preId = nil
        entry.postId = nil
        return false
    end
    entry.preId = preId
    entry.postId = postId
    return true
end

---@param state { prefix: string, classPath: string, isOn: fun(): boolean, entries: table }
---@return boolean
local function EnsureBlueprintBoolHooks(state)
    local n = 0
    for i = 1, #state.entries do
        if HookBlueprintBool(state, state.entries[i]) then
            n = n + 1
        end
    end
    return n == #state.entries
end

local parryHookState = {
    prefix = "Auto Parry on Hit",
    classPath = "/Game/Sparta/Core/Player/Ability/Parry/GA_Parry_Handler.GA_Parry_Handler_C",
    isOn = function()
        return alwaysParryOn
    end,
    entries = {
        { name = "IsInParryWindow",       whenOn = true,  preId = nil, postId = nil },
        { name = "IsUnparryableAttack",   whenOn = false, preId = nil, postId = nil },
        { name = "IsParryingAICharacter", whenOn = true,  preId = nil, postId = nil },
    },
}

local perfectBlockHookState = {
    prefix = "Always Perfect Block",
    classPath = "/Game/Sparta/Core/Characters/Player/Common/Abilities/ActiveBlock/GA_ActiveBlock.GA_ActiveBlock_C",
    isOn = function()
        return alwaysPerfectBlockOn
    end,
    entries = {
        { name = "CanPerfectBlock", whenOn = true, preId = nil, postId = nil },
    },
}

local perfectHardenHookState = {
    prefix = "Always Perfect Harden",
    classPath = "/Game/Sparta/Core/Characters/Player/Common/Abilities/StoneForm/GA_Harden_Original.GA_Harden_Original_C",
    isOn = function()
        return alwaysPerfectHardenOn
    end,
    entries = {
        { name = "IsInPerfectStoneForm", whenOn = true, preId = nil, postId = nil },
    },
}

local PARRY_SEAL_NOTE = "Infinite Seal must be equipped. Equip and try again."
local BLOCK_SEAL_NOTE = "Untarnished Seal must be equipped. Equip and try again."
local HARDEN_SEAL_NOTE = "Vatra's Seal must be equipped. Equip and try again."

---@param on boolean
---@param checkboxId string
---@param noteId string
---@param note string
local function SetSealToggleUi(on, checkboxId, noteId, note)
    ModMenu.Set(SECTION_TOGGLES, checkboxId, on)
    ModMenu.SetLabel(SECTION_TOGGLES, noteId, note or "")
end

---@param state table
---@param setOn fun(on: boolean)
---@param checkboxId string
---@param noteId string
---@param failNote string
---@return boolean
local function TryEnableSealToggle(state, setOn, checkboxId, noteId, failNote)
    if not GetPlayerPawn() or not BlueprintClassLoaded(state.classPath) then
        setOn(false)
        SetSealToggleUi(false, checkboxId, noteId, failNote)
        Log(state.prefix .. ": OFF — ability not loaded")
        return false
    end
    local ok = EnsureBlueprintBoolHooks(state)
    if not ok then
        setOn(false)
        SetSealToggleUi(false, checkboxId, noteId, failNote)
        Log(state.prefix .. ": OFF — ability not loaded")
        return false
    end
    setOn(true)
    SetSealToggleUi(true, checkboxId, noteId, "")
    Log(state.prefix .. ": ON")
    return true
end

local function AlwaysParryOn()
    TryEnableSealToggle(parryHookState, function(on)
        alwaysParryOn = on
    end, "alwaysParry", "alwaysParryNote", PARRY_SEAL_NOTE)
end

local function AlwaysParryOff()
    alwaysParryOn = false
    SetSealToggleUi(false, "alwaysParry", "alwaysParryNote", "")
    Log("Auto Parry on Hit: OFF")
end

local function AlwaysPerfectBlockOn()
    TryEnableSealToggle(perfectBlockHookState, function(on)
        alwaysPerfectBlockOn = on
    end, "alwaysPerfectBlock", "alwaysPerfectBlockNote", BLOCK_SEAL_NOTE)
end

local function AlwaysPerfectBlockOff()
    alwaysPerfectBlockOn = false
    SetSealToggleUi(false, "alwaysPerfectBlock", "alwaysPerfectBlockNote", "")
    Log("Always Perfect Block: OFF")
end

local function AlwaysPerfectHardenOn()
    TryEnableSealToggle(perfectHardenHookState, function(on)
        alwaysPerfectHardenOn = on
    end, "alwaysPerfectHarden", "alwaysPerfectHardenNote", HARDEN_SEAL_NOTE)
end

local function AlwaysPerfectHardenOff()
    alwaysPerfectHardenOn = false
    SetSealToggleUi(false, "alwaysPerfectHarden", "alwaysPerfectHardenNote", "")
    Log("Always Perfect Harden: OFF")
end

---@param id string
---@return boolean
local function ToggleSaved(id)
    local t = ConfigManager.Get("toggles")
    return type(t) == "table" and t[id] == true
end

---@param id string
---@param on boolean
local function SetToggleSaved(id, on)
    local t = ConfigManager.Get("toggles")
    if type(t) ~= "table" then
        t = {}
    end
    t[id] = on and true or false
    ConfigManager.Set("toggles", t)
end

--- Keep saved intent on if the ability is not loaded yet (retry after ClientRestart).
---@param state table
---@param checkboxId string
---@param noteId string
---@param failNote string
local function ReapplySealToggle(state, checkboxId, noteId, failNote)
    if not GetPlayerPawn() then
        return
    end
    if not BlueprintClassLoaded(state.classPath) then
        SetSealToggleUi(true, checkboxId, noteId, failNote)
        Log(state.prefix .. ": waiting — " .. failNote)
        return
    end
    if EnsureBlueprintBoolHooks(state) then
        SetSealToggleUi(true, checkboxId, noteId, "")
        Log(state.prefix .. ": ON")
        return
    end
    SetSealToggleUi(true, checkboxId, noteId, failNote)
    Log(state.prefix .. ": waiting — " .. failNote)
end

local function ReapplyTogglesAfterRestart()
    InvalidatePlayerCache()
    CancelTick()
    CancelCooldownTick()
    ExecuteInGameThreadWithDelay(RESTART_DELAY_MS, function()
        InvalidatePlayerCache()
        if alwaysParryOn then
            ReapplySealToggle(parryHookState, "alwaysParry", "alwaysParryNote", PARRY_SEAL_NOTE)
        end
        if alwaysPerfectBlockOn then
            ReapplySealToggle(perfectBlockHookState, "alwaysPerfectBlock", "alwaysPerfectBlockNote", BLOCK_SEAL_NOTE)
        end
        if alwaysPerfectHardenOn then
            ReapplySealToggle(perfectHardenHookState, "alwaysPerfectHarden", "alwaysPerfectHardenNote", HARDEN_SEAL_NOTE)
        end
        if extraMaxShellPointsOn then
            ApplyStartingMaxShellPoints(false)
        end
        Character.Reapply()
        if godOn then
            ApplyGod(true)
        end
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
        if godOn or autoHealOn or infiniteResolveOn or noCooldownOn
            or alwaysParryOn or alwaysPerfectBlockOn or alwaysPerfectHardenOn
            or extraMaxShellPointsOn then
            Log("Toggles re-applied after ClientRestart")
        end
    end)
end

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ReapplyTogglesAfterRestart()
end)

autoHealOn = ToggleSaved("autoHeal")
godOn = ToggleSaved("god")
infiniteResolveOn = ToggleSaved("infiniteResolve")
noCooldownOn = ToggleSaved("noAbilityCooldown")
alwaysParryOn = ToggleSaved("alwaysParry")
alwaysPerfectBlockOn = ToggleSaved("alwaysPerfectBlock")
alwaysPerfectHardenOn = ToggleSaved("alwaysPerfectHarden")
extraMaxShellPointsOn = ToggleSaved("extraMaxShellPoints")
Character.RestoreMoveFast(ToggleSaved("moveFast"))

ModMenu.Register({
    id = SECTION_TOGGLES,
    title = "Toggles",
    tab = TAB_CHEATS,
    items = {
        {
            type = "label",
            label = "Saved to config. Re-applied when you load into a world.",
        },
        {
            type = "checkbox",
            id = "god",
            label = "God",
            default = godOn,
            onChange = function(on)
                SetToggleSaved("god", on)
                if on then
                    GodOn()
                else
                    GodOff()
                end
            end,
        },
        {
            type = "checkbox",
            id = "autoHeal",
            label = "Auto Heal",
            default = autoHealOn,
            onChange = function(on)
                SetToggleSaved("autoHeal", on)
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
            default = infiniteResolveOn,
            onChange = function(on)
                SetToggleSaved("infiniteResolve", on)
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
            default = noCooldownOn,
            onChange = function(on)
                SetToggleSaved("noAbilityCooldown", on)
                if on then
                    NoCooldownOn()
                else
                    NoCooldownOff()
                end
            end,
        },
        {
            type = "checkbox",
            id = "alwaysParry",
            label = "Auto Parry on Hit",
            default = alwaysParryOn,
            onChange = function(on)
                SetToggleSaved("alwaysParry", on)
                if on then
                    AlwaysParryOn()
                else
                    AlwaysParryOff()
                end
            end,
        },
        {
            type = "label",
            id = "alwaysParryNote",
            label = "",
        },
        {
            type = "checkbox",
            id = "alwaysPerfectBlock",
            label = "Always Perfect Block",
            default = alwaysPerfectBlockOn,
            onChange = function(on)
                SetToggleSaved("alwaysPerfectBlock", on)
                if on then
                    AlwaysPerfectBlockOn()
                else
                    AlwaysPerfectBlockOff()
                end
            end,
        },
        {
            type = "label",
            id = "alwaysPerfectBlockNote",
            label = "",
        },
        {
            type = "checkbox",
            id = "alwaysPerfectHarden",
            label = "Always Perfect Harden",
            default = alwaysPerfectHardenOn,
            onChange = function(on)
                SetToggleSaved("alwaysPerfectHarden", on)
                if on then
                    AlwaysPerfectHardenOn()
                else
                    AlwaysPerfectHardenOff()
                end
            end,
        },
        {
            type = "label",
            id = "alwaysPerfectHardenNote",
            label = "",
        },
        {
            type = "checkbox",
            id = "extraMaxShellPoints",
            label = "Max Shell Points 100",
            default = extraMaxShellPointsOn,
            onChange = function(on)
                SetToggleSaved("extraMaxShellPoints", on)
                if on then
                    ExtraMaxShellPointsOn()
                else
                    ExtraMaxShellPointsOff()
                end
            end,
        },
        {
            type = "checkbox",
            id = "moveFast",
            label = "Move Fast",
            default = Character.IsMoveFast(),
            onChange = function(on)
                SetToggleSaved("moveFast", on)
                Character.SetMoveFast(on)
            end,
        },
    },
})

Character.Register()

local Shells = require("Shells")
Shells.OnChanged(function()
    Character.RegisterShellToggles()
end)
Shells.Register()

local FLASH_MS = 300
local buttonFlashHandles = {}
local toastHandles = {}

local TOAST_ID = {
    [SECTION_UNLOCKS] = "unlockToast",
    [SECTION_MAP] = "mapToast",
    [SECTION_ITEMS] = "tarAddToast",
}

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

local function PcButton(id, label, name, call, variant, sectionId)
    local restore = variant or "default"
    return {
        type = "button",
        id = id,
        label = label,
        variant = variant,
        onClick = function()
            local ok = CallOnPlayerController(name, call)
            if sectionId then
                FlashUnlockFeedback(sectionId, id, restore, ok, label)
            end
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
local DEFAULT_COMBAT_AMOUNT = 100

---@param field string
---@return integer
local function CombatAmount(field)
    local combat = ConfigManager.Get("combat")
    local n = tonumber(type(combat) == "table" and combat[field] or nil)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return DEFAULT_COMBAT_AMOUNT
    end
    n = math.floor(n)
    if n < 1 then
        return DEFAULT_COMBAT_AMOUNT
    end
    return n
end

---@param field string
---@param n integer
local function SetCombatAmount(field, n)
    local combat = ConfigManager.Get("combat")
    if type(combat) ~= "table" then
        combat = {}
    end
    combat[field] = n
    ConfigManager.Set("combat", combat)
end

--- Row: integer amount field + Add button. Reads ModMenu.Get(sectionId, amountId).
---@param sectionId string
---@param id string
---@param label string
---@param name string
---@param callWithAmount fun(pc: APlayerController, n: integer)
---@param default integer|nil
---@param onAmountChange fun(n: integer)|nil
local function AmountRow(sectionId, id, label, name, callWithAmount, default, onAmountChange)
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
                onChange = onAmountChange ~= nil and function(value)
                    local n = tonumber(value)
                    if n == nil or n ~= n then
                        return
                    end
                    n = math.floor(n)
                    if n < 1 then
                        return
                    end
                    onAmountChange(n)
                end or nil,
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
    tab = TAB_UNLOCKS,
    collapsible = true,
    collapsed = false,
    items = {
        {
            type = "label",
            label = "Steam achievements unlock with these. Load into a world first.",
        },
        { type = "separator" },
        PcButton("clothing", "Unlock All Clothing", "S_UnlockAllClothing", function(pc) pc:S_UnlockAllClothing() end, nil, SECTION_UNLOCKS),
        PcButton("gates", "Unlock All Gates", "S_UnlockAllGates", function(pc) pc:S_UnlockAllGates() end, nil, SECTION_UNLOCKS),
        PcButton("landing", "Unlock All Landing Areas", "S_UnlockAllLandingAreas",
            function(pc) pc:S_UnlockAllLandingAreas() end, nil, SECTION_UNLOCKS),
        PcButton("masks", "Unlock All Masks", "S_UnlockAllMasks", function(pc) pc:S_UnlockAllMasks() end, nil, SECTION_UNLOCKS),
        PcButton("seals", "Unlock All Seals", "S_UnlockAllSeals", function(pc) pc:S_UnlockAllSeals() end, nil, SECTION_UNLOCKS),
        PcButton("shells", "Unlock All Shells", "UnlockAllShells", UnlockAllShellsThorough, nil, SECTION_UNLOCKS),
        PcButton("sidearms", "Unlock All Sidearms", "S_UnlockAllSidearms", function(pc) pc:S_UnlockAllSidearms() end, nil, SECTION_UNLOCKS),
        PcButton("weapons", "Unlock All Weapons", "S_UnlockAllWeapons", function(pc) pc:S_UnlockAllWeapons() end, nil, SECTION_UNLOCKS),
        PcButton("shellShades", "Unlock Shell Shades", "S_UnlockShellShades",
            function(pc) pc:S_UnlockShellShades() end, nil, SECTION_UNLOCKS),
        PcButton("red", "Unlock Red Harbinger", "S_UnlockRedHarbinger",
            function(pc) pc:S_UnlockRedHarbinger() end, nil, SECTION_UNLOCKS),
        PcButton("cosmic", "Unlock Cosmic Harbinger", "S_UnlockCosmicHarbinger",
            function(pc) pc:S_UnlockCosmicHarbinger() end, nil, SECTION_UNLOCKS),
        PcButton("darkShades", "Unlock Dark Form Shades", "S_UnlockDarkFormShades",
            function(pc) pc:S_UnlockDarkFormShades() end, nil, SECTION_UNLOCKS),
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
        PcButton("unlockMap", "Unlock Map", "S_UnlockMap", function(pc) pc:S_UnlockMap() end, "primary", SECTION_MAP),
        PcButton("fastTravel", "Unlock Fast Travel", "S_UnlockFastTravel",
            function(pc) pc:S_UnlockFastTravel() end, nil, SECTION_MAP),
        PcButton("revealAll", "Reveal All Icons", "S_MapReveal_All",
            function(pc) pc:S_MapReveal_All() end, "warning", SECTION_MAP),
        {
            type = "label",
            id = "mapToast",
            label = "",
        },
    },
})

ModMenu.Register({
    id = SECTION_ITEMS,
    title = "Tarstones",
    tab = TAB_GIVE,
    collapsible = true,
    collapsed = true,
    items = {
        PcButton("tarMelee", "Add All Tarstones (Melee)", "S_AddAllTarstonesMelee",
            function(pc) pc:S_AddAllTarstonesMelee() end, nil, SECTION_ITEMS),
        PcButton("tarSupport", "Add All Tarstones (Support)", "S_AddAllTarstonesSupport",
            function(pc) pc:S_AddAllTarstonesSupport() end, nil, SECTION_ITEMS),
        PcButton("tarSidearm", "Add All Tarstones (Sidearm)", "S_AddAllTarstonesSidearm",
            function(pc) pc:S_AddAllTarstonesSidearm() end, nil, SECTION_ITEMS),
        {
            type = "label",
            id = "tarAddToast",
            label = "",
        },
        {
            type = "label",
            id = "tarLevelStatus",
            label = "Tarstone level: 1 / 3",
        },
        PcButton("tarLevel", "Increment All Tarstone Levels", "TarstoneLevels+1",
            function(pc) Tarstones.IncrementAll(pc) end),
        PcButton("tarLevelDown", "Decrement All Tarstone Levels", "TarstoneLevels-1",
            function(pc) Tarstones.DecrementAll(pc) end),
        {
            type = "label",
            id = "tarReequipNote",
            label = "",
        },
    },
})

Give.Register()

ModMenu.Register({
    id = SECTION_ADD,
    title = "Quick Adds",
    tab = TAB_GIVE,
    collapsible = true,
    collapsed = true,
    items = {
        {
            type = "label",
            label = "Set the amount, then press Add.",
        },
        AmountRow(SECTION_ADD, "gold", "Gold", "S_AddGold", function(pc, n) pc:S_AddGold(n) end, 100),
        AmountRow(SECTION_ADD, "gloom", "Gloom", "S_AddGloom", function(pc, n) pc:S_AddGloom(n) end, 100),
        AmountRow(SECTION_ADD, "glimpses", "Glimpses", "S_AddGlimpses", function(pc, n) pc:S_AddGlimpses(n) end, 100),
        AmountRow(SECTION_ADD, "shellPoints", "Shell Points", "S_AddShellPoints",
            function(pc, n) pc:S_AddShellPoints(n) end, 100),
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
    tab = TAB_CHEATS,
    collapsible = true,
    collapsed = true,
    items = {
        {
            type = "label",
            label = "Amounts are saved. Set the number, then press Add.",
        },
        AmountRow(SECTION_COMBAT, "heal", "Heal", "S_Heal", function(pc, n) pc:S_Heal(n) end, CombatAmount("heal"), function(n)
            SetCombatAmount("heal", n)
        end),
        AmountRow(SECTION_COMBAT, "resolve", "Resolve", "S_GainResolve", function(pc, n) pc:S_GainResolve(n) end, CombatAmount("resolve"), function(n)
            SetCombatAmount("resolve", n)
        end),
        {
            type = "button",
            id = "breakShell",
            label = "Break Shell",
            onClick = function()
                local pc = GetPlayerController()
                if not pc then
                    Log("Skipped: no player controller (load into a world first)")
                    return
                end
                TryBreakShell(pc)
            end,
        },
        PcButton("reviveShell", "Revive Player", "S_ReviveShell", function(pc) pc:S_ReviveShell() end, "primary"),
    },
})

local function FlipToggle(isOn, onFn, offFn, checkboxId)
    local want = not isOn()
    if checkboxId then
        SetToggleSaved(checkboxId, want)
    end
    if want then
        onFn()
    else
        offFn()
    end
    if checkboxId then
        ModMenu.Set(SECTION_TOGGLES, checkboxId, isOn())
    end
end

require("Keybinds").Register({
    {
        id = "KeybindToggles",
        title = "Toggles",
        hint = "Saved to config. Fires while the menu is closed. Flips Cheats → Toggles. None = off.",
        items = {
            {
                id = "autoHeal",
                label = "Auto Heal",
                fire = function()
                    FlipToggle(function()
                        return autoHealOn
                    end, AutoHealOn, AutoHealOff, "autoHeal")
                end,
            },
            {
                id = "god",
                label = "God",
                fire = function()
                    FlipToggle(function()
                        return godOn
                    end, GodOn, GodOff, "god")
                end,
            },
            {
                id = "infiniteResolve",
                label = "Infinite Resolve",
                fire = function()
                    FlipToggle(function()
                        return infiniteResolveOn
                    end, InfiniteResolveOn, InfiniteResolveOff, "infiniteResolve")
                end,
            },
            {
                id = "noAbilityCooldown",
                label = "No Ability Cooldown",
                fire = function()
                    FlipToggle(function()
                        return noCooldownOn
                    end, NoCooldownOn, NoCooldownOff, "noAbilityCooldown")
                end,
            },
            {
                id = "alwaysParry",
                label = "Auto Parry on Hit",
                fire = function()
                    FlipToggle(function()
                        return alwaysParryOn
                    end, AlwaysParryOn, AlwaysParryOff, "alwaysParry")
                end,
            },
            {
                id = "alwaysPerfectBlock",
                label = "Always Perfect Block",
                fire = function()
                    FlipToggle(function()
                        return alwaysPerfectBlockOn
                    end, AlwaysPerfectBlockOn, AlwaysPerfectBlockOff, "alwaysPerfectBlock")
                end,
            },
            {
                id = "alwaysPerfectHarden",
                label = "Always Perfect Harden",
                fire = function()
                    FlipToggle(function()
                        return alwaysPerfectHardenOn
                    end, AlwaysPerfectHardenOn, AlwaysPerfectHardenOff, "alwaysPerfectHarden")
                end,
            },
            {
                id = "extraMaxShellPoints",
                label = "Max Shell Points 100",
                fire = function()
                    FlipToggle(function()
                        return extraMaxShellPointsOn
                    end, ExtraMaxShellPointsOn, ExtraMaxShellPointsOff, "extraMaxShellPoints")
                end,
            },
            {
                id = "moveFast",
                label = "Move Fast",
                fire = function()
                    local want = not Character.IsMoveFast()
                    SetToggleSaved("moveFast", want)
                    Character.ToggleMoveFast()
                end,
            },
        },
    },
    {
        id = "KeybindShells",
        title = "Shells",
        hint = "Saved to config. Fires while the menu is closed. Flips Shells tab toggles. None = off.",
        items = {
            {
                id = "fightStance",
                label = "Smert Stealth",
                fire = function()
                    Character.ToggleFightStance()
                end,
            },
            {
                id = "spawnClone",
                label = "Spawn Clone",
                fire = function()
                    Character.ToggleSpawnClone()
                end,
            },
            {
                id = "lazloDetonation",
                label = "Lazlo Detonation",
                fire = function()
                    Character.ToggleDetonation()
                end,
            },
        },
    },
    {
        id = "KeybindSwitchShell",
        title = "Switch Shell",
        hint = "Saved to config. Fires while the menu is closed. Same as Shells → Switch Shell. None = off.",
        items = (function()
            local items = {}
            local opts = Shells.Options()
            for i = 1, #opts do
                local id = opts[i].id
                local label = opts[i].label
                items[#items + 1] = {
                    id = "switch_" .. id,
                    label = label,
                    fire = function()
                        Shells.Switch(id)
                    end,
                }
            end
            return items
        end)(),
    },
    {
        id = "KeybindCombat",
        title = "Combat",
        hint = "Saved to config. Fires while the menu is closed. Amounts use Cheats → Combat. None = off.",
        items = {
            {
                id = "heal",
                label = "Heal",
                fire = function()
                    local n = tonumber(ModMenu.Get(SECTION_COMBAT, "healAmount")) or 0
                    n = math.floor(n)
                    if n < 1 then
                        Log("Skipped Heal bind: amount must be >= 1")
                        return
                    end
                    local pc = GetPlayerController()
                    if not pc then
                        Log("Skipped Heal bind: no player controller")
                        return
                    end
                    local ok, err = pcall(function()
                        pc:S_Heal(n)
                    end)
                    if ok then
                        Log("Heal bind S_Heal(" .. tostring(n) .. ")")
                    else
                        Log("Heal bind failed — " .. tostring(err))
                    end
                end,
            },
            {
                id = "resolve",
                label = "Resolve",
                fire = function()
                    local n = tonumber(ModMenu.Get(SECTION_COMBAT, "resolveAmount")) or 0
                    n = math.floor(n)
                    if n < 1 then
                        Log("Skipped Resolve bind: amount must be >= 1")
                        return
                    end
                    local pc = GetPlayerController()
                    if not pc then
                        Log("Skipped Resolve bind: no player controller")
                        return
                    end
                    local ok, err = pcall(function()
                        pc:S_GainResolve(n)
                    end)
                    if ok then
                        Log("Resolve bind S_GainResolve(" .. tostring(n) .. ")")
                    else
                        Log("Resolve bind failed — " .. tostring(err))
                    end
                end,
            },
            {
                id = "reviveShell",
                label = "Revive Player",
                fire = function()
                    local pc = GetPlayerController()
                    if not pc then
                        Log("Skipped Revive bind: no player controller")
                        return
                    end
                    local ok, err = pcall(function()
                        pc:S_ReviveShell()
                    end)
                    if ok then
                        Log("Revive bind S_ReviveShell()")
                    else
                        Log("Revive bind failed — " .. tostring(err))
                    end
                end,
            },
        },
    },
})

ModMenu.OnOpen(function()
    Tarstones.RefreshStatus()
    Give.Refresh()
end)
