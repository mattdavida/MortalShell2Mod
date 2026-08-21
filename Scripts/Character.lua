--[[
  Player CharacterData speed multiplier (session) plus Smert Stealth,
  Genessa Spawn Clone, and Lazlo Detonation.

  Reads UEHelpers.GetPlayer().CharacterData — the live SpartaCharacterData
  asset (shell or dark form). Writes Movement, then InitialiseCharacterData
  so the pawn picks it up. Off restores originals. A 1s tick tops off if
  death / pawn restart resets speeds (same idea as Auto Heal / Resolve).

  Smert Stealth: EnableFightStance / RemovePermanentFightStance(Immediate) on
  the live GA_Smert_FightStanceHandler. Weapons stay out.
  Spawn Clone: FindAllOf GA_AstralClones_Action, SpawnCount=9999 on every
  live instance, wait 300ms, then SpawnPrimaryClone (left) +
  SpawnSecondaryClone (right) on each. Off removes both and resets
  SpawnCount to 1 on all. SpawnCount=9999 is a working hack — research
  later. Lazlo Detonation: FindFirstOf GA_Lazlo_Detonation, then
  TriggerLastShockwave on a delay (Shells tab dropdown, Lazlo only).
  Shell picker + these toggles live on the Shells tab. Speed and Auto Heal
  percent save to config. Delay stays session-only.
]]

local UEHelpers = require("UEHelpers.UEHelpers")
local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")
local Shells = require("Shells")

local M = {}

local SECTION_ID = "Character"
local TOGGLES_ID = "Toggles"
local SHELL_TOGGLES_ID = "ShellToggles"

local MOVE_FIELDS = { "WalkSpeed", "JogSpeed", "SprintSpeed" }

local MULT_OPTIONS = {
    { label = "x1.5", value = "1.5" },
    { label = "x2",   value = "2" },
    { label = "x3",   value = "3" },
    { label = "x4",   value = "4" },
    { label = "x5",   value = "5" },
}

local DEFAULT_MULT = "2"

local HEAL_DELAY_OPTIONS = {
    { label = "0.25s", value = "250" },
    { label = "0.5s",  value = "500" },
    { label = "1s",    value = "1000" },
    { label = "2s",    value = "2000" },
    { label = "3s",    value = "3000" },
    { label = "5s",    value = "5000" },
}

local DEFAULT_HEAL_PCT = 100
local DEFAULT_HEAL_DELAY = "1000"

local DETONATION_DELAY_OPTIONS = {
    { label = "0.5s", value = "500" },
    { label = "1s",   value = "1000" },
    { label = "2s",   value = "2000" },
    { label = "3s",   value = "3000" },
    { label = "5s",   value = "5000" },
}
local DEFAULT_DETONATION_DELAY = "3000"

--- [asset key] = { obj, fields... }
local moveSaved = {}

local moveFastOn = false
local fightStanceOn = false
local spawnCloneOn = false
local detonationOn = false
local moveTickHandle = nil

local MOVE_TICK_MS = 1000
local MOVE_EPS = 0.5

local FIGHT_STANCE_MISSING = "Smert must be equipped."
local SPAWN_CLONE_MISSING = "Genessa must be equipped."
local DETONATION_MISSING = "Lazlo must be equipped."
local ASTRAL_CLONES_CLASS = "GA_AstralClones_Action_C"
local DETONATION_CLASS = "GA_Lazlo_Detonation_C"
local detonationTickHandle = nil
-- Working hack: clones only persist with a huge SpawnCount. Reset on disable.
local SPAWN_COUNT_ON = 9999
local SPAWN_COUNT_OFF = 1
local SPAWN_DELAY_MS = 300
local spawnCloneDelayHandle = nil

local function Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

local function IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

---@return APawn|nil
local function GetPlayer()
    local pawn = UEHelpers.GetPlayer()
    if IsValid(pawn) then
        return pawn
    end
    return nil
end

---@param obj UObject
---@return boolean
local function IsDefaultObject(obj)
    local okName, name = pcall(function()
        return obj:GetFullName()
    end)
    if okName and type(name) == "string" and name:find("Default__", 1, true) then
        return true
    end
    return false
end

---@param pawn APawn|nil
---@return UObject|nil
local function FindFightStanceHandler(pawn)
    local found = FindAllOf("GA_Smert_FightStanceHandler_C")
    if type(found) ~= "table" then
        local one = FindFirstOf("GA_Smert_FightStanceHandler_C")
        found = IsValid(one) and { one } or {}
    end
    local pawnName = ""
    if IsValid(pawn) then
        pcall(function()
            pawnName = pawn:GetName() or ""
        end)
    end
    local fallback = nil
    for i = 1, #found do
        local obj = found[i]
        if IsValid(obj) and not IsDefaultObject(obj) then
            local full = ""
            pcall(function()
                full = obj:GetFullName() or ""
            end)
            if pawnName ~= "" and full:find(pawnName, 1, true) then
                return obj
            end
            if fallback == nil then
                fallback = obj
            end
        end
    end
    return fallback
end

---@param on boolean
---@param note string|nil
local function SetFightStanceUi(on, note)
    fightStanceOn = on
    ModMenu.Set(SHELL_TOGGLES_ID, "fightStance", on)
    ModMenu.SetLabel(SHELL_TOGGLES_ID, "fightStanceNote", note or "")
end

local function FightStanceOn()
    local pawn = GetPlayer()
    local handler = FindFightStanceHandler(pawn)
    if not handler then
        SetFightStanceUi(false, FIGHT_STANCE_MISSING)
        Log("Smert Stealth: OFF — handler not found (equip Smert)")
        return
    end
    local ok = pcall(function()
        handler:EnableFightStance()
    end)
    if not ok then
        ok = pcall(function()
            handler:EnableFightStance(true)
        end)
    end
    if not ok then
        SetFightStanceUi(false, "EnableFightStance failed.")
        Log("Smert Stealth: OFF — EnableFightStance failed")
        return
    end
    SetFightStanceUi(true, "")
    Log("Smert Stealth: ON")
end

local function FightStanceOff()
    local pawn = GetPlayer()
    local handler = FindFightStanceHandler(pawn)
    if handler then
        local ok = pcall(function()
            handler:RemovePermanentFightStance(true)
        end)
        if not ok then
            pcall(function()
                handler:RemovePermanentFightStance(true, true, true)
            end)
        end
    end
    SetFightStanceUi(false, "")
    Log("Smert Stealth: OFF")
end

---@return UObject[]
local function FindAstralClonesActions()
    local found = FindAllOf(ASTRAL_CLONES_CLASS)
    if type(found) ~= "table" then
        local one = FindFirstOf(ASTRAL_CLONES_CLASS)
        found = IsValid(one) and { one } or {}
    end
    local out = {}
    for i = 1, #found do
        local obj = found[i]
        if IsValid(obj) and not IsDefaultObject(obj) then
            out[#out + 1] = obj
        end
    end
    return out
end

---@param on boolean
local function SetSpawnCloneUi(on)
    spawnCloneOn = on
    ModMenu.Set(SHELL_TOGGLES_ID, "spawnClone", on)
    ModMenu.SetLabel(SHELL_TOGGLES_ID, "spawnCloneNote", SPAWN_CLONE_MISSING)
end

---@param action UObject
---@param count integer
---@return boolean
local function SetSpawnCount(action, count)
    local ok = pcall(function()
        action.SpawnCount = count
    end)
    return ok
end

---@param actions UObject[]
---@param count integer
---@return integer
local function SetSpawnCountAll(actions, count)
    local n = 0
    for i = 1, #actions do
        local action = actions[i]
        if IsValid(action) and SetSpawnCount(action, count) then
            n = n + 1
        end
    end
    return n
end

local function CancelSpawnCloneDelay()
    if spawnCloneDelayHandle then
        pcall(CancelDelayedAction, spawnCloneDelayHandle)
        spawnCloneDelayHandle = nil
    end
end

local function ActivateClones()
    spawnCloneDelayHandle = nil
    if not spawnCloneOn then
        return
    end
    local actions = FindAstralClonesActions()
    if #actions == 0 then
        SetSpawnCloneUi(false)
        Log("Spawn Clone: OFF — ability not found (equip Genessa)")
        return
    end
    SetSpawnCountAll(actions, SPAWN_COUNT_ON)
    local spawned = 0
    for i = 1, #actions do
        local action = actions[i]
        if IsValid(action) then
            local okPrimary = pcall(function()
                action:SpawnPrimaryClone()
            end)
            local okSecondary = pcall(function()
                action:SpawnSecondaryClone()
            end)
            if okPrimary or okSecondary then
                spawned = spawned + 1
            end
        end
    end
    if spawned == 0 then
        SetSpawnCountAll(actions, SPAWN_COUNT_OFF)
        SetSpawnCloneUi(false)
        Log("Spawn Clone: OFF — SpawnPrimaryClone and SpawnSecondaryClone failed on all")
        return
    end
    Log(string.format("Spawn Clone: spawned on %d/%d instance(s) (SpawnCount=%d)",
        spawned, #actions, SPAWN_COUNT_ON))
end

local function SpawnCloneOn()
    CancelSpawnCloneDelay()
    local actions = FindAstralClonesActions()
    if #actions == 0 then
        SetSpawnCloneUi(false)
        Log("Spawn Clone: OFF — ability not found (equip Genessa)")
        return
    end
    local written = SetSpawnCountAll(actions, SPAWN_COUNT_ON)
    if written == 0 then
        SetSpawnCloneUi(false)
        Log("Spawn Clone: OFF — could not set SpawnCount on any instance")
        return
    end
    SetSpawnCloneUi(true)
    Log(string.format("Spawn Clone: SpawnCount=%d on %d instance(s), spawning in %dms",
        SPAWN_COUNT_ON, written, SPAWN_DELAY_MS))
    spawnCloneDelayHandle = ExecuteInGameThreadWithDelay(SPAWN_DELAY_MS, function()
        ActivateClones()
    end)
end

local function SpawnCloneOff()
    CancelSpawnCloneDelay()
    local actions = FindAstralClonesActions()
    for i = 1, #actions do
        local action = actions[i]
        if IsValid(action) then
            pcall(function()
                action:RemovePrimaryClone()
            end)
            pcall(function()
                action:RemoveSecondaryClone()
            end)
            SetSpawnCount(action, SPAWN_COUNT_OFF)
        end
    end
    SetSpawnCloneUi(false)
    Log(string.format("Spawn Clone: OFF (SpawnCount=%d on %d instance(s))",
        SPAWN_COUNT_OFF, #actions))
end

---@return UObject|nil
local function FindLazloDetonation()
    local obj = FindFirstOf(DETONATION_CLASS)
    if IsValid(obj) and not IsDefaultObject(obj) then
        return obj
    end
    return nil
end

---@param on boolean
local function SetDetonationUi(on)
    detonationOn = on
    ModMenu.Set(SHELL_TOGGLES_ID, "lazloDetonation", on)
    ModMenu.SetLabel(SHELL_TOGGLES_ID, "lazloDetonationNote", DETONATION_MISSING)
end

local function CancelDetonationTick()
    if detonationTickHandle then
        pcall(CancelDelayedAction, detonationTickHandle)
        detonationTickHandle = nil
    end
end

---@param quiet boolean|nil
---@return boolean
local function TriggerShockwave(quiet)
    local action = FindLazloDetonation()
    if not action then
        if not quiet then
            Log("Lazlo Detonation: ability not found (equip Lazlo)")
        end
        return false
    end
    local ok = pcall(function()
        action:TriggerLastShockwave()
    end)
    if not ok then
        if not quiet then
            Log("Lazlo Detonation: TriggerLastShockwave failed")
        end
        return false
    end
    return true
end

local function TickDetonation()
    if not detonationOn then
        return
    end
    TriggerShockwave(true)
end

---@return integer
local function DetonationDelayMs()
    local n = tonumber(ModMenu.Get(SHELL_TOGGLES_ID, "lazloDelay"))
        or tonumber(DEFAULT_DETONATION_DELAY)
        or 3000
    if n < 250 then
        n = 250
    end
    return math.floor(n)
end

local function EnsureDetonationTick()
    if detonationTickHandle or not detonationOn then
        return
    end
    detonationTickHandle = LoopInGameThreadWithDelay(DetonationDelayMs(), TickDetonation)
end

local function RestartDetonationTick()
    CancelDetonationTick()
    if not detonationOn then
        return
    end
    TriggerShockwave(true)
    EnsureDetonationTick()
end

local function DetonationOn()
    CancelDetonationTick()
    local action = FindLazloDetonation()
    if not action then
        SetDetonationUi(false)
        Log("Lazlo Detonation: OFF — ability not found (equip Lazlo)")
        return
    end
    SetDetonationUi(true)
    TriggerShockwave(false)
    EnsureDetonationTick()
    Log("Lazlo Detonation: ON (every " .. tostring(DetonationDelayMs()) .. "ms)")
end

local function DetonationOff()
    CancelDetonationTick()
    SetDetonationUi(false)
    Log("Lazlo Detonation: OFF")
end

---@param pawn APawn
---@return USpartaCharacterData|nil
local function GetCharacterData(pawn)
    local cd = nil
    pcall(function()
        cd = pawn.CharacterData
    end)
    if IsValid(cd) then
        return cd
    end
    pcall(function()
        cd = pawn:GetCharacterData()
    end)
    if IsValid(cd) then
        return cd
    end
    return nil
end

---@param obj UObject
---@return string|nil
local function AssetKey(obj)
    local ok, addr = pcall(function()
        return obj:GetAddress()
    end)
    if ok and addr ~= nil then
        return tostring(addr)
    end
    local okName, name = pcall(function()
        return obj:GetFullName()
    end)
    if okName and type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

---@param struct any
---@param fields string[]
---@return table|nil
local function ReadFields(struct, fields)
    if struct == nil then
        return nil
    end
    local out = {}
    for i = 1, #fields do
        local name = fields[i]
        local n = tonumber(struct[name])
        if n == nil then
            return nil
        end
        out[name] = n
    end
    return out
end

---@param owner UObject
---@param structName string
---@param fields string[]
---@param values table
---@return boolean
local function WriteFields(owner, structName, fields, values)
    local ok = pcall(function()
        local struct = owner[structName]
        for i = 1, #fields do
            local name = fields[i]
            struct[name] = values[name]
        end
        owner[structName] = struct
    end)
    if ok then
        return true
    end
    ok = pcall(function()
        local struct = owner[structName]
        for i = 1, #fields do
            local name = fields[i]
            struct[name] = values[name]
        end
    end)
    return ok
end

---@param pawn APawn
local function PushCharacterData(pawn)
    pcall(function()
        pawn:InitialiseCharacterData()
    end)
end

---@param itemId string
---@return number
local function Multiplier(itemId)
    local n = tonumber(ModMenu.Get(SECTION_ID, itemId)) or tonumber(DEFAULT_MULT) or 2
    if n < 0.1 then
        n = 0.1
    end
    return n
end

---@param saved table
---@param structName string
---@param fields string[]
---@param label string
local function RestoreAll(saved, structName, fields, label)
    local n = 0
    for key, snap in pairs(saved) do
        if snap and IsValid(snap.obj) then
            local values = {}
            for i = 1, #fields do
                values[fields[i]] = snap[fields[i]]
            end
            if WriteFields(snap.obj, structName, fields, values) then
                n = n + 1
            end
        end
        saved[key] = nil
    end
    local pawn = GetPlayer()
    if pawn then
        PushCharacterData(pawn)
    end
    Log(string.format("%s: restored %d CharacterData asset(s)", label, n))
end

---@param current table
---@param snap table
---@param fields string[]
---@param mult number
---@return boolean
local function FieldsBelowTarget(current, snap, fields, mult)
    for i = 1, #fields do
        local name = fields[i]
        local expected = snap[name] * mult
        if current[name] < (expected - MOVE_EPS) then
            return true
        end
    end
    return false
end

---@param saved table
---@param structName string
---@param fields string[]
---@param mult number
---@param label string
---@param opts { onlyIfBelow: boolean|nil, quiet: boolean|nil }|nil
---@return boolean
local function ApplyMult(saved, structName, fields, mult, label, opts)
    opts = opts or {}
    local pawn = GetPlayer()
    if not pawn then
        if not opts.quiet then
            Log(label .. ": no player pawn")
        end
        return false
    end
    local cd = GetCharacterData(pawn)
    if not cd then
        if not opts.quiet then
            Log(label .. ": no CharacterData")
        end
        return false
    end
    local key = AssetKey(cd)
    if key == nil then
        if not opts.quiet then
            Log(label .. ": could not key CharacterData")
        end
        return false
    end
    local struct = nil
    pcall(function()
        struct = cd[structName]
    end)
    local current = ReadFields(struct, fields)
    if current == nil then
        if not opts.quiet then
            Log(label .. ": could not read " .. structName)
        end
        return false
    end
    if saved[key] == nil then
        -- Death / loading can briefly zero Movement; wait for real values.
        if current[fields[1]] <= 0 then
            if not opts.quiet then
                Log(label .. ": Movement not ready")
            end
            return false
        end
        local snap = { obj = cd }
        for i = 1, #fields do
            snap[fields[i]] = current[fields[i]]
        end
        saved[key] = snap
    end
    local snap = saved[key]
    if opts.onlyIfBelow and not FieldsBelowTarget(current, snap, fields, mult) then
        return true
    end
    local scaled = {}
    local parts = {}
    for i = 1, #fields do
        local name = fields[i]
        scaled[name] = snap[name] * mult
        parts[#parts + 1] = string.format("%s=%.1f", name, scaled[name])
    end
    if not WriteFields(cd, structName, fields, scaled) then
        if not opts.quiet then
            Log(label .. ": write failed")
        end
        return false
    end
    PushCharacterData(pawn)
    local prefix = opts.quiet and (label .. ": top-off") or (label .. ":")
    Log(string.format("%s x%.2f on %s (%s)", prefix, mult, key, table.concat(parts, " ")))
    return true
end

local function CancelMoveTick()
    if moveTickHandle then
        pcall(CancelDelayedAction, moveTickHandle)
        moveTickHandle = nil
    end
end

local function TickMoveFast()
    if not moveFastOn then
        return
    end
    ApplyMult(moveSaved, "Movement", MOVE_FIELDS, Multiplier("moveMult"), "Move Fast", {
        onlyIfBelow = true,
        quiet = true,
    })
end

local function EnsureMoveTick()
    if moveTickHandle or not moveFastOn then
        return
    end
    moveTickHandle = LoopInGameThreadWithDelay(MOVE_TICK_MS, TickMoveFast)
end

local function MoveFastOn()
    local mult = Multiplier("moveMult")
    if ApplyMult(moveSaved, "Movement", MOVE_FIELDS, mult, "Move Fast") then
        moveFastOn = true
        EnsureMoveTick()
    else
        moveFastOn = false
        CancelMoveTick()
        ModMenu.Set(TOGGLES_ID, "moveFast", false)
    end
end

local function MoveFastOff()
    moveFastOn = false
    CancelMoveTick()
    RestoreAll(moveSaved, "Movement", MOVE_FIELDS, "Move Fast")
end

function M.Reapply()
    if moveFastOn then
        ApplyMult(moveSaved, "Movement", MOVE_FIELDS, Multiplier("moveMult"), "Move Fast", {
            onlyIfBelow = true,
            quiet = true,
        })
        EnsureMoveTick()
    end
    if fightStanceOn then
        FightStanceOn()
    end
    if spawnCloneOn then
        SpawnCloneOn()
    end
    if detonationOn then
        DetonationOn()
    end
end

function M.SetMoveFast(on)
    if on then
        MoveFastOn()
    else
        MoveFastOff()
    end
end

--- Set the saved intent without applying. ClientRestart / Reapply does the work.
function M.RestoreMoveFast(on)
    moveFastOn = on == true
    if not moveFastOn then
        CancelMoveTick()
    end
end

function M.IsMoveFast()
    return moveFastOn
end

function M.SetFightStance(on)
    if on then
        FightStanceOn()
    else
        FightStanceOff()
    end
end

function M.SetSpawnClone(on)
    if on then
        SpawnCloneOn()
    else
        SpawnCloneOff()
    end
end

function M.SetDetonation(on)
    if on then
        DetonationOn()
    else
        DetonationOff()
    end
end

function M.ToggleFightStance()
    M.SetFightStance(not fightStanceOn)
end

function M.ToggleSpawnClone()
    M.SetSpawnClone(not spawnCloneOn)
end

function M.ToggleDetonation()
    M.SetDetonation(not detonationOn)
end

function M.ToggleMoveFast()
    M.SetMoveFast(not moveFastOn)
    ModMenu.Set(TOGGLES_ID, "moveFast", moveFastOn)
end

---@return number 1-100
function M.HealPercent()
    local n = tonumber(ModMenu.Get(SECTION_ID, "healPct"))
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return DEFAULT_HEAL_PCT
    end
    n = math.floor(n)
    if n < 1 then
        n = 1
    end
    if n > 100 then
        n = 100
    end
    return n
end

---@return integer milliseconds
function M.HealDelayMs()
    local n = tonumber(ModMenu.Get(SECTION_ID, "healDelay")) or tonumber(DEFAULT_HEAL_DELAY) or 1000
    if n < 100 then
        n = 100
    end
    return math.floor(n)
end

--- main.lua assigns this so delay changes restart the heal loop.
function M.NotifyHealDelayChanged()
end

local FLASH_MS = 300
local healPctFlashHandle = nil

local function FlashHealPctButton()
    if healPctFlashHandle then
        pcall(CancelDelayedAction, healPctFlashHandle)
        healPctFlashHandle = nil
    end
    pcall(function()
        ModMenu.SetButtonVariant(SECTION_ID, "healPctSet", "success")
    end)
    healPctFlashHandle = ExecuteInGameThreadWithDelay(FLASH_MS, function()
        healPctFlashHandle = nil
        pcall(function()
            ModMenu.SetButtonVariant(SECTION_ID, "healPctSet", "default")
        end)
    end)
end

---@return string
local function SavedMoveMult()
    local v = tostring(ConfigManager.Get("moveMult") or "")
    for i = 1, #MULT_OPTIONS do
        if MULT_OPTIONS[i].value == v then
            return v
        end
    end
    return DEFAULT_MULT
end

---@return integer
local function SavedHealPct()
    local n = tonumber(ConfigManager.Get("healPct"))
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return DEFAULT_HEAL_PCT
    end
    n = math.floor(n)
    if n < 1 then
        n = 1
    end
    if n > 100 then
        n = 100
    end
    return n
end

local function PersistHealPct()
    ConfigManager.Set("healPct", M.HealPercent())
end

local function ApplyHealPercent()
    local n = M.HealPercent()
    ModMenu.Set(SECTION_ID, "healPct", n)
    PersistHealPct()
    FlashHealPctButton()
    Log("Auto Heal percent: " .. tostring(n))
end

function M.Register()
    ModMenu.Register({
        id = SECTION_ID,
        title = "Character",
        tab = "Cheats",
        collapsible = true,
        collapsed = true,
        items = {
            {
                type = "label",
                label = "Speed multiplier and Auto Heal percent are saved. Delay is session only.",
            },
            {
                type = "dropdown",
                id = "moveMult",
                label = "Speed multiplier",
                options = MULT_OPTIONS,
                default = SavedMoveMult(),
                onChange = function(value)
                    ConfigManager.Set("moveMult", tostring(value or DEFAULT_MULT))
                    if moveFastOn then
                        MoveFastOn()
                    end
                end,
            },
            {
                type = "label",
                label = "Auto Heal amount and tick delay. 100 / 1s matches the old fill-to-full tick.",
            },
            {
                type = "row",
                items = {
                    {
                        type = "number",
                        id = "healPct",
                        label = "Auto Heal percent",
                        default = SavedHealPct(),
                        min = 1,
                        max = 100,
                        integer = true,
                        labelWidth = 150,
                        fieldWidth = 72,
                        onChange = PersistHealPct,
                    },
                    {
                        type = "button",
                        id = "healPctSet",
                        label = "Set",
                        onClick = ApplyHealPercent,
                    },
                },
            },
            {
                type = "dropdown",
                id = "healDelay",
                label = "Auto Heal delay",
                options = HEAL_DELAY_OPTIONS,
                default = DEFAULT_HEAL_DELAY,
                onChange = function()
                    M.NotifyHealDelayChanged()
                end,
            },
        },
    })
end

--- Rebuilds when Lazlo is equipped/unequipped so the delay dropdown can hide.
local shellTogglesLazlo = nil ---@type boolean|nil

function M.RegisterShellToggles()
    local showLazlo = Shells.Is("lazlo")
    if shellTogglesLazlo == showLazlo then
        return
    end
    shellTogglesLazlo = showLazlo

    local items = {
        {
            type = "label",
            label = "Shell-specific. Session only. Equip the matching shell first.",
        },
        {
            type = "checkbox",
            id = "fightStance",
            label = "Smert Stealth",
            default = false,
            onChange = function(on)
                M.SetFightStance(on)
            end,
        },
        {
            type = "label",
            id = "fightStanceNote",
            label = "",
        },
        {
            type = "checkbox",
            id = "spawnClone",
            label = "Spawn Clone",
            default = false,
            onChange = function(on)
                M.SetSpawnClone(on)
            end,
        },
        {
            type = "label",
            id = "spawnCloneNote",
            label = SPAWN_CLONE_MISSING,
        },
        {
            type = "checkbox",
            id = "lazloDetonation",
            label = "Lazlo Detonation",
            default = false,
            onChange = function(on)
                M.SetDetonation(on)
            end,
        },
        {
            type = "label",
            id = "lazloDetonationNote",
            label = DETONATION_MISSING,
        },
    }

    if showLazlo then
        items[#items + 1] = {
            type = "dropdown",
            id = "lazloDelay",
            label = "Shockwave delay",
            options = DETONATION_DELAY_OPTIONS,
            default = DEFAULT_DETONATION_DELAY,
            onChange = function()
                RestartDetonationTick()
            end,
        }
    end

    ModMenu.Register({
        id = SHELL_TOGGLES_ID,
        title = "Shell Toggles",
        tab = "Shells",
        collapsible = true,
        collapsed = false,
        items = items,
    })
end

return M
