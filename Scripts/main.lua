--[[
  Mortal Shell 2 — cheat menu (ModMenu).

  Composer: Init, then feature Register() in tab order, then keybinds.
  Menu toggle defaults to F6; Keybinds → Menu can overwrite it (used each launch).
]]

local ModMenu = require("ModMenu.ModMenu")
local ConfigManager = require("ConfigManager.ConfigManager")
local Keybinds = require("Keybinds")

ConfigManager.Init({
    id = "MortalShell2Mod",
    defaults = {
        keybinds = {},
        moveMult = "2",
        healPct = 100,
        combat = {
            heal = 100,
            resolve = 100,
            damagePct = "50",
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

local menuKey = Keybinds.ResolveMenuKey()

ModMenu.Init({
    title = "Mortal Shell 2",
    instanceId = "MortalShell2Mod",
    pointerMode = "touch",
    key = menuKey.code or Key.F6,
    keyHint = menuKey.name,
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
print("|  " .. menuKey.name .. " = Cheat menu")
print("|  Tabs: Cheats / Shells / Give / Unlocks / Keybinds")
print("|  Keybinds: saved, menu closed")
print("|  Unlocks fire Steam achievements")
print("--------------------------------")

local Character = require("Character")
local Toggles = require("Toggles")
local Unlocks = require("Unlocks")
local Combat = require("Combat")
local Tarstones = require("Tarstones")
local Give = require("Give")
local Shells = require("Shells")

Toggles.Register()
Character.Register()

Shells.OnChanged(function()
    Character.RegisterShellToggles()
end)
Shells.Register()

Unlocks.Register()
Tarstones.Register()
Give.Register()
Combat.RegisterQuickAdds()
Combat.Register()

Keybinds.Register({
    {
        id = "KeybindMenu",
        title = "Menu",
        hint =
        "Saved to config. Default F6. A new key works this session; the previous key still toggles until you relaunch.",
        items = {
            {
                id = "menuToggle",
                label = "Toggle Menu",
                allowEmpty = false,
                fireWhileOpen = true,
                fire = function()
                    ModMenu.Toggle()
                end,
            },
        },
    },
    {
        id = "KeybindToggles",
        title = "Toggles",
        hint = "Saved to config. Fires while the menu is closed. Flips Cheats → Toggles. None = off.",
        items = {
            {
                id = "autoHeal",
                label = "Auto Heal",
                fire = function()
                    Toggles.Flip("autoHeal")
                end,
            },
            {
                id = "god",
                label = "God",
                fire = function()
                    Toggles.Flip("god")
                end,
            },
            {
                id = "infiniteResolve",
                label = "Infinite Resolve",
                fire = function()
                    Toggles.Flip("infiniteResolve")
                end,
            },
            {
                id = "noAbilityCooldown",
                label = "No Ability Cooldown",
                fire = function()
                    Toggles.Flip("noAbilityCooldown")
                end,
            },
            {
                id = "alwaysParry",
                label = "Auto Parry on Hit",
                fire = function()
                    Toggles.Flip("alwaysParry")
                end,
            },
            {
                id = "alwaysPerfectBlock",
                label = "Always Perfect Block",
                fire = function()
                    Toggles.Flip("alwaysPerfectBlock")
                end,
            },
            {
                id = "alwaysPerfectHarden",
                label = "Always Perfect Harden",
                fire = function()
                    Toggles.Flip("alwaysPerfectHarden")
                end,
            },
            {
                id = "extraMaxShellPoints",
                label = "Max Shell Points 100",
                fire = function()
                    Toggles.Flip("extraMaxShellPoints")
                end,
            },
            {
                id = "moveFast",
                label = "Move Fast",
                fire = function()
                    Toggles.Flip("moveFast")
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
        hint = "Saved to config. Fires while the menu is closed. Amounts and Damage to use Cheats → Combat. None = off.",
        items = {
            {
                id = "reviveShell",
                label = "Revive Player",
                fire = function()
                    Combat.Revive()
                end,
            },
            {
                id = "heal",
                label = "Heal",
                fire = function()
                    Combat.Heal()
                end,
            },
            {
                id = "resolve",
                label = "Resolve",
                fire = function()
                    Combat.Resolve()
                end,
            },
            {
                id = "damagePlayer",
                label = "Damage Player",
                fire = function()
                    Combat.DamagePlayer()
                end,
            },
        },
    },
})

ModMenu.OnOpen(function()
    Tarstones.Refresh()
    Give.Refresh()
end)
