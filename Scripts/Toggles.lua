--[[
  Cheats → Toggles runtime.

  God, Auto Heal, Infinite Resolve, No Ability Cooldown, seal hooks
  (parry / perfect block / perfect harden), Max Shell Points 100.
  Saved via ConfigManager. Re-applied on PlayerController:ClientRestart.
  Move Fast lives in Character.lua; this module only saves the checkbox.
]]

local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")
local Character = require("Character")
local Player = require("Player")

local M = {}

local SECTION_TOGGLES = "Toggles"
local TAB_CHEATS = "Cheats"

local Log = Player.Log
local IsValid = Player.IsValid
local GetPlayerController = Player.GetPlayerController
local GetPlayerPawn = Player.GetPlayerPawn
local PeekCachedPawn = Player.PeekCachedPawn
local InvalidatePlayerCache = Player.Invalidate
local ObjectAddress = Player.ObjectAddress
local SameObject = Player.SameObject
local UnwrapParam = Player.UnwrapParam
local IsDefaultObject = Player.IsDefaultObject
local ForEachArrayItem = Player.ForEachArrayItem
local ReadField = Player.ReadField
local WriteField = Player.WriteField
local GetHealthComponent = Player.GetHealthComponent

local registered = false
local cooldownHooksInstalled = false

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


---@param obj UObject
---@param target UObject
---@return boolean
local function OuterChainHas(obj, target)
    if not IsValid(obj) or not IsValid(target) then
        return false
    end
    local targetAddr = ObjectAddress(target)
    local cur = obj
    for _ = 1, 8 do
        if not IsValid(cur) then
            return false
        end
        if cur == target then
            return true
        end
        local addr = ObjectAddress(cur)
        if targetAddr ~= nil and addr ~= nil and addr == targetAddr then
            return true
        end
        local ok, outer = pcall(function()
            if type(cur.GetOuter) == "function" then
                return cur:GetOuter()
            end
            return cur.Outer
        end)
        if not ok or outer == nil then
            return false
        end
        cur = outer
    end
    return false
end

---@param classPath string
---@return UObject|nil
local function FindLiveAbility(classPath)
    local name = classPath:match("([^./]+)$")
    if type(name) ~= "string" or name == "" then
        return nil
    end
    local pawn = GetPlayerPawn()
    local list = nil
    pcall(function()
        list = FindAllOf(name)
    end)
    local fallback = nil
    if type(list) == "table" then
        for i = 1, #list do
            local obj = list[i]
            if IsValid(obj) and not IsDefaultObject(obj) then
                if pawn ~= nil and OuterChainHas(obj, pawn) then
                    return obj
                end
                if fallback == nil then
                    fallback = obj
                end
            end
        end
        return fallback
    end
    local obj = FindFirstOf(name)
    if IsValid(obj) and not IsDefaultObject(obj) then
        return obj
    end
    return nil
end

---@param classPath string
---@return boolean
local function BlueprintClassLoaded(classPath)
    return FindLiveAbility(classPath) ~= nil
end

---@param state { prefix: string, classPath: string, isOn: fun(): boolean, entries: table }
---@param entry { name: string, whenOn: boolean, preId: integer|nil, postId: integer|nil }
local function UnhookBlueprintBool(state, entry)
    if entry.preId == nil and entry.postId == nil then
        return
    end
    -- ClientRestart often destroys the UFunction first; skip unregister then.
    if BlueprintClassLoaded(state.classPath) then
        local path = state.classPath .. ":" .. entry.name
        local ok, err = pcall(UnregisterHook, path, entry.preId, entry.postId)
        if not ok then
            local msg = tostring(err)
            if not string.find(msg, "no UFunction", 1, true) then
                Log(state.prefix .. ": unhook failed " .. entry.name .. " — " .. msg)
            end
        end
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

---@param state { entries: table }
---@return boolean
local function SealHooksReady(state)
    if state == nil or type(state.entries) ~= "table" or #state.entries == 0 then
        return false
    end
    for i = 1, #state.entries do
        if state.entries[i].preId == nil then
            return false
        end
    end
    return true
end

---@param state { prefix: string, classPath: string, isOn: fun(): boolean, entries: table }
local function InvalidateBlueprintHooks(state)
    for i = 1, #state.entries do
        state.entries[i].preId = nil
        state.entries[i].postId = nil
    end
    state.waitingLogged = nil
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

--- Keep saved intent on if the ability is not loaded yet (retry until live).
---@param state table
---@param checkboxId string
---@param noteId string
---@param failNote string
---@return boolean
local function ReapplySealToggle(state, checkboxId, noteId, failNote)
    if SealHooksReady(state) then
        SetSealToggleUi(true, checkboxId, noteId, "")
        return true
    end
    if not GetPlayerPawn() then
        return false
    end
    if not BlueprintClassLoaded(state.classPath) then
        SetSealToggleUi(true, checkboxId, noteId, "Waiting for ability…")
        if not state.waitingLogged then
            state.waitingLogged = true
            Log(state.prefix .. ": waiting — ability not loaded yet")
        end
        return false
    end
    if EnsureBlueprintBoolHooks(state) then
        state.waitingLogged = nil
        SetSealToggleUi(true, checkboxId, noteId, "")
        Log(state.prefix .. ": ON")
        return true
    end
    SetSealToggleUi(true, checkboxId, noteId, failNote)
    if not state.waitingLogged then
        state.waitingLogged = true
        Log(state.prefix .. ": waiting — hook failed")
    end
    return false
end

local SEAL_RETRY_MS = 1000
local sealRetryHandle = nil
local restartReapplyHandle = nil

local function CancelSealRetry()
    if sealRetryHandle then
        pcall(CancelDelayedAction, sealRetryHandle)
        sealRetryHandle = nil
    end
end

local function SealToggleNeedsRetry()
    if alwaysParryOn and not SealHooksReady(parryHookState) then
        return true
    end
    if alwaysPerfectBlockOn and not SealHooksReady(perfectBlockHookState) then
        return true
    end
    if alwaysPerfectHardenOn and not SealHooksReady(perfectHardenHookState) then
        return true
    end
    return false
end

local function TickSealRetries()
    if not GetPlayerPawn() then
        return
    end
    if alwaysParryOn and not SealHooksReady(parryHookState) then
        ReapplySealToggle(parryHookState, "alwaysParry", "alwaysParryNote", PARRY_SEAL_NOTE)
    end
    if alwaysPerfectBlockOn and not SealHooksReady(perfectBlockHookState) then
        ReapplySealToggle(perfectBlockHookState, "alwaysPerfectBlock", "alwaysPerfectBlockNote", BLOCK_SEAL_NOTE)
    end
    if alwaysPerfectHardenOn and not SealHooksReady(perfectHardenHookState) then
        ReapplySealToggle(perfectHardenHookState, "alwaysPerfectHarden", "alwaysPerfectHardenNote", HARDEN_SEAL_NOTE)
    end
    if not SealToggleNeedsRetry() then
        CancelSealRetry()
    end
end

local function EnsureSealRetryTick()
    if not SealToggleNeedsRetry() then
        CancelSealRetry()
        return
    end
    if sealRetryHandle then
        return
    end
    sealRetryHandle = LoopInGameThreadWithDelay(SEAL_RETRY_MS, TickSealRetries)
end

local function ReapplyTogglesAfterRestart()
    InvalidatePlayerCache()
    CancelTick()
    CancelCooldownTick()
    InvalidateBlueprintHooks(parryHookState)
    InvalidateBlueprintHooks(perfectBlockHookState)
    InvalidateBlueprintHooks(perfectHardenHookState)
    if restartReapplyHandle then
        pcall(CancelDelayedAction, restartReapplyHandle)
        restartReapplyHandle = nil
    end
    EnsureSealRetryTick()
    restartReapplyHandle = ExecuteInGameThreadWithDelay(RESTART_DELAY_MS, function()
        restartReapplyHandle = nil
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
        EnsureSealRetryTick()
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


local ON = {
    autoHeal = AutoHealOn,
    god = GodOn,
    infiniteResolve = InfiniteResolveOn,
    noAbilityCooldown = NoCooldownOn,
    alwaysParry = AlwaysParryOn,
    alwaysPerfectBlock = AlwaysPerfectBlockOn,
    alwaysPerfectHarden = AlwaysPerfectHardenOn,
    extraMaxShellPoints = ExtraMaxShellPointsOn,
}

local OFF = {
    autoHeal = AutoHealOff,
    god = GodOff,
    infiniteResolve = InfiniteResolveOff,
    noAbilityCooldown = NoCooldownOff,
    alwaysParry = AlwaysParryOff,
    alwaysPerfectBlock = AlwaysPerfectBlockOff,
    alwaysPerfectHarden = AlwaysPerfectHardenOff,
    extraMaxShellPoints = ExtraMaxShellPointsOff,
}

function M.IsOn(id)
    if id == "autoHeal" then return autoHealOn end
    if id == "god" then return godOn end
    if id == "infiniteResolve" then return infiniteResolveOn end
    if id == "noAbilityCooldown" then return noCooldownOn end
    if id == "alwaysParry" then return alwaysParryOn end
    if id == "alwaysPerfectBlock" then return alwaysPerfectBlockOn end
    if id == "alwaysPerfectHarden" then return alwaysPerfectHardenOn end
    if id == "extraMaxShellPoints" then return extraMaxShellPointsOn end
    if id == "moveFast" then return Character.IsMoveFast() end
    return false
end

function M.SetSaved(id, on)
    SetToggleSaved(id, on)
end

--- Flip a Cheats → Toggles checkbox (keybind path). Syncs config + UI.
function M.Flip(id)
    if id == "moveFast" then
        local want = not Character.IsMoveFast()
        SetToggleSaved("moveFast", want)
        Character.ToggleMoveFast()
        return
    end
    local onFn = ON[id]
    local offFn = OFF[id]
    if onFn == nil or offFn == nil then
        Log("Toggles.Flip: unknown id " .. tostring(id))
        return
    end
    local want = not M.IsOn(id)
    SetToggleSaved(id, want)
    if want then
        onFn()
    else
        offFn()
    end
    ModMenu.Set(SECTION_TOGGLES, id, M.IsOn(id))
end

function M.Register()
    if registered then
        return
    end
    registered = true

    Character.NotifyHealDelayChanged = RestartHealTick

    if not cooldownHooksInstalled then
        cooldownHooksInstalled = true
        HookPlayerCooldownApply("/Script/Sparta.SpartaGameplayAbility:ApplyLocalCooldown", true, false)
        HookPlayerCooldownApply("/Script/Sparta.SpartaGameplayAbility:ApplyGlobalCooldown", false, true)
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


end

return M
