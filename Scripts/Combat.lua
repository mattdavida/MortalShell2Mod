--[[
  Cheats → Combat plus Give → Quick Adds.

  Heal / Resolve / Damage to save via ConfigManager. Damage hits the current
  bar (shell if worn) down to a percent — never dumps the shell.
]]

local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")
local Player = require("Player")

local M = {}

local SECTION_COMBAT = "Combat"
local SECTION_ADD = "Add"
local TAB_CHEATS = "Cheats"
local TAB_GIVE = "Give"

local Log = Player.Log
local IsValid = Player.IsValid
local GetPlayerController = Player.GetPlayerController
local GetHealthComponent = Player.GetHealthComponent
local CallOnPlayerController = Player.CallOnPlayerController

local AMOUNT_LABEL_WIDTH = 150
local AMOUNT_FIELD_WIDTH = 72
local DEFAULT_COMBAT_AMOUNT = 100
local DAMAGE_PCT_DEFAULT = "50"
local DAMAGE_PCT_OPTIONS = {
    { label = "50%", value = "50" },
    { label = "40%", value = "40" },
    { label = "35%", value = "35" },
    { label = "25%", value = "25" },
    { label = "10%", value = "10" },
    { label = "1%", value = "1" },
}

--- Damage the current bar (shell if worn, flesh if unshelled). Never empty
--- the shell — S_DealDamage hits shell first, and anything >= current shell
--- HP fires OnShellHealthDepleted.
---@param hc USpartaHealthComponent
---@return number|nil current
---@return number|nil max
---@return string|nil pool
local function ReadDamagePool(hc)
    if not IsValid(hc) then
        return nil, nil, nil
    end
    local shell = nil
    local maxShell = nil
    pcall(function()
        shell = tonumber(hc:GetShellHealth())
    end)
    pcall(function()
        maxShell = tonumber(hc:GetMaxShellHealth())
    end)
    if shell ~= nil and maxShell ~= nil and maxShell > 0 and shell > 0.5 then
        return shell, maxShell, "shell"
    end
    local health = nil
    local maxH = nil
    pcall(function()
        health = tonumber(hc:GetHealth())
    end)
    pcall(function()
        maxH = tonumber(hc:GetCurrentMaxHealth())
    end)
    if maxH == nil or maxH <= 0 then
        pcall(function()
            maxH = tonumber(hc:GetMaxHealth())
        end)
    end
    if health == nil or maxH == nil or maxH <= 0 then
        return nil, nil, nil
    end
    return health, maxH, "flesh"
end

---@param pc APlayerController
---@param pct number
---@return boolean
local function TryDamagePlayer(pc, pct)
    local hc = GetHealthComponent(pc)
    if not IsValid(hc) then
        Log("Damage: no health component")
        return false
    end
    local current, maxH, pool = ReadDamagePool(hc)
    if current == nil or maxH == nil or pool == nil then
        Log("Damage: could not read health")
        return false
    end
    local target = maxH * (pct / 100)
    if target < 1 then
        target = 1
    end
    if current <= target + 0.5 then
        Log(string.format("Damage: %s already %.0f%% or below (%.1f / %.1f)", pool, pct, current, maxH))
        return true
    end
    local amount = current - target
    if pool == "shell" and amount >= current then
        amount = current - 1
    end
    local ok, err = pcall(function()
        pc:S_DealDamage(amount)
    end)
    if not ok then
        Log("Damage: S_DealDamage failed - " .. tostring(err))
        return false
    end
    Log(string.format("Damage: S_DealDamage(%.1f) %s %.1f -> %.0f%% of %.1f", amount, pool, current, pct, maxH))
    return true
end

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

---@return string
local function SavedDamagePct()
    local combat = ConfigManager.Get("combat")
    local v = ""
    if type(combat) == "table" then
        v = tostring(combat.damagePct or combat.breakPct or "")
    end
    for i = 1, #DAMAGE_PCT_OPTIONS do
        if DAMAGE_PCT_OPTIONS[i].value == v then
            return v
        end
    end
    return DAMAGE_PCT_DEFAULT
end

---@param value any
local function SetDamagePct(value)
    local combat = ConfigManager.Get("combat")
    if type(combat) ~= "table" then
        combat = {}
    end
    combat.damagePct = tostring(value or DAMAGE_PCT_DEFAULT)
    combat.breakPct = nil
    ConfigManager.Set("combat", combat)
end

---@return number
local function SelectedDamagePct()
    local v = tostring(ModMenu.Get(SECTION_COMBAT, "damagePct") or "")
    local n = tonumber(v) or tonumber(SavedDamagePct())
    if n == nil or n ~= n or n <= 0 then
        n = tonumber(DAMAGE_PCT_DEFAULT) or 50
    end
    if n > 100 then
        n = 100
    end
    return n
end

---@param sectionId string
---@param amountId string
---@return integer|nil
local function ReadAmount(sectionId, amountId)
    local n = tonumber(ModMenu.Get(sectionId, amountId)) or 0
    n = math.floor(n)
    if n < 1 then
        return nil
    end
    return n
end

--- Row: integer amount field + Add button. Reads ModMenu.Get(sectionId, amountId).
---@param sectionId string
---@param id string
---@param label string
---@param name string
---@param callWithAmount fun(pc: APlayerController, n: integer)
---@param default integer|nil
---@param onAmountChange fun(n: integer)|nil
---@param confirm table|nil
local function AmountRow(sectionId, id, label, name, callWithAmount, default, onAmountChange, confirm)
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
                    local n = ReadAmount(sectionId, amountId)
                    if n == nil then
                        Log("Skipped: " .. name .. " amount must be >= 1")
                        return
                    end
                    local function grant()
                        CallOnPlayerController(string.format("%s(%d)", name, n), function(pc)
                            callWithAmount(pc, n)
                        end)
                    end
                    if type(confirm) == "table" then
                        ModMenu.Confirm({
                            title = confirm.title or string.format("Add %d %s?", n, string.lower(label)),
                            message = confirm.message,
                            confirmLabel = confirm.confirmLabel or "Add",
                            onConfirm = grant,
                        })
                        return
                    end
                    grant()
                end,
            },
        },
    }
end

function M.Revive()
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
end

function M.Heal()
    local n = ReadAmount(SECTION_COMBAT, "healAmount")
    if n == nil then
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
end

function M.Resolve()
    local n = ReadAmount(SECTION_COMBAT, "resolveAmount")
    if n == nil then
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
end

function M.DamagePlayer()
    local pc = GetPlayerController()
    if not pc then
        Log("Skipped Damage bind: no player controller")
        return
    end
    TryDamagePlayer(pc, SelectedDamagePct())
end

local combatRegistered = false
local quickAddsRegistered = false

function M.Register()
    if combatRegistered then
        return
    end
    combatRegistered = true

    ModMenu.Register({
        id = SECTION_COMBAT,
        title = "Combat",
        tab = TAB_CHEATS,
        collapsible = true,
        collapsed = true,
        items = {
            {
                type = "label",
                label = "Amounts and Damage to are saved. Set the number, then press Add.",
            },
            {
                type = "button",
                id = "reviveShell",
                label = "Revive Player",
                variant = "primary",
                onClick = function()
                    CallOnPlayerController("S_ReviveShell", function(pc)
                        pc:S_ReviveShell()
                    end)
                end,
            },
            AmountRow(SECTION_COMBAT, "heal", "Heal", "S_Heal", function(pc, n) pc:S_Heal(n) end, CombatAmount("heal"),
                function(n)
                    SetCombatAmount("heal", n)
                end),
            AmountRow(SECTION_COMBAT, "resolve", "Resolve", "S_GainResolve", function(pc, n) pc:S_GainResolve(n) end,
                CombatAmount("resolve"), function(n)
                    SetCombatAmount("resolve", n)
                end),
            {
                type = "dropdown",
                id = "damagePct",
                label = "Damage to",
                options = DAMAGE_PCT_OPTIONS,
                default = SavedDamagePct(),
                onChange = function(value)
                    SetDamagePct(value)
                end,
            },
            {
                type = "button",
                id = "damagePlayer",
                label = "Damage Player",
                onClick = function()
                    local pc = GetPlayerController()
                    if not pc then
                        Log("Skipped: no player controller (load into a world first)")
                        return
                    end
                    TryDamagePlayer(pc, SelectedDamagePct())
                end,
            },
        },
    })
end

function M.RegisterQuickAdds()
    if quickAddsRegistered then
        return
    end
    quickAddsRegistered = true

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
            AmountRow(SECTION_ADD, "ovums", "Ovums", "S_AddOvums", function(pc, n) pc:S_AddOvums(n) end, 100, nil, {
                confirmLabel = "Add",
            }),
        },
    })
end

return M
