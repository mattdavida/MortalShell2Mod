# Mortal Shell II Mod

![Mortal Shell II Mod](GithubAssets/mod_hero.png)

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod for **Mortal Shell II** that lets you change any shell from an in-game menu (including Harros after the prologue), plus unlocks, items, currencies, heal / resolve, Auto Heal, Infinite Resolve, and no ability cooldowns.

**Download / install:** [Mortal Shell II Mod on Nexus Mods](https://www.nexusmods.com/mortalshell2/mods/20)

Press **F6** to open the menu.

Unlock buttons also fire Steam achievements. Use them only if you are fine with that.

Tested on **UE4SS latest-experimental** (UE 5.6, Steam).

---

## Features

### Shells — click to wear

| Shell | Notes |
| --- | --- |
| Harros, the Vassal | Prologue shell. Restored even after the Tar Golem fight petrifies him. |
| Tiel, the Acolyte | |
| Eredrim, the Venerable | |
| Proxima, the Broodseer | |
| Gragu, the Insatiable | |
| Smert, the Apostate | |
| Genessa, the Wayward | |
| Lazlo, the Justicar | |
| Sariel, the Endless | |

Change shell anywhere — skips the shrine / pickup gate. The current shell is marked (equipped). The last shell you click is remembered for the session and re-applied after death / pawn restart. Nothing is forced on first spawn.

### Toggles (same menu)

| Control | What it does |
| --- | --- |
| **Auto Heal** | Heals you (and shell health) when below max. Toggle off stops the refill. Persists through death / pawn restart while left ON. |
| **Infinite Resolve** | Refills Resolve when below max. Toggle off stops the refill. Persists through death / pawn restart while left ON. |
| **No Ability Cooldown** | Player abilities have no cooldown. Toggle off restores normal cooldowns. Persists through death / pawn restart while left ON. |

### Unlocks

Steam achievements unlock with these. Load into a world first. There is no “Unlock Everything” on purpose — that spammed achievement notifications.

| Control | What it does |
| --- | --- |
| **Unlock All Clothing** | Unlocks clothing |
| **Unlock All Gates** | Unlocks gates |
| **Unlock All Landing Areas** | Unlocks landing areas |
| **Unlock All Masks** | Unlocks masks |
| **Unlock All Seals** | Unlocks seals |
| **Unlock All Shells** | Unlocks shells |
| **Unlock All Sidearms** | Unlocks sidearms |
| **Unlock All Weapons** | Unlocks weapons |

### Items & Tarstones

| Control | What it does |
| --- | --- |
| **Add All Items** | Adds every item |
| **Add All Tarstones (Melee / Support / Sidearm)** | Adds all tarstones of that type |
| **Increment All Tarstone Levels** | Levels up every tarstone you currently have |

### Add Amount / Combat

Set the number, then press Add (default 100).

| Control | What it does |
| --- | --- |
| **Gold / Gloom / Glimpses / Tarcores / Ventrium / Laterite / Dorsalite / Thoracium / Ovums** | Grants the entered amount of that currency |
| **Heal** | Heals by the entered amount |
| **Resolve** | Gains Resolve by the entered amount |

---

## Requirements

| Dependency | Notes |
| --- | --- |
| [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) | Latest experimental recommended — included in the Nexus full package |
| [ModMenu](https://github.com/mattdavida/ue4ss-ModMenu) | Shared runtime under `ue4ss/Mods/shared/ModMenu/` — included in the download |
| Mortal Shell II (Steam) | Load into a world before using the menu |
| `UE4SS_Signatures/StaticConstructObject.lua` | Required on this game — included in the download |

---

## Installation

Install from the [Nexus release](https://www.nexusmods.com/mortalshell2/mods/20) — full package and already-have-UE4SS steps live there.

---

## Controls

| Key | Action |
| --- | --- |
| **F6** | Toggle the Mortal Shell II menu (dock left/right with the Dock button) |

---

## Notes

- Load into a world first. Buttons do nothing on the title / menu screens (they need a live player controller).
- Unlock buttons fire Steam achievements.
- Auto Heal / Infinite Resolve / No Ability Cooldown re-apply after death / pawn restart (~3 s).
- Shell pick and all toggles last for the current play session. Restart the game (or reload mods) to clear them.
- This game needs the included `StaticConstructObject.lua` signature under `ue4ss\UE4SS_Signatures\` or UE4SS may fail to start.
- This is a cheat / QoL mod — use at your own risk with saves and achievements.
- ModMenu is loaded with `require("ModMenu.ModMenu")` from `shared/`; it is not a separate enabled mod.

---

## Credits

- [RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)
- [ue4ss-ModMenu](https://github.com/mattdavida/ue4ss-ModMenu)

## Links

- Nexus: https://www.nexusmods.com/mortalshell2/mods/20
- ModMenu: https://github.com/mattdavida/ue4ss-ModMenu
