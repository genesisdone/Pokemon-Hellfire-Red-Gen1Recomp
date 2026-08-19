# PokeDoom

A DOOM first-person shooter mode for any voxel mod's
3D overworld — real DOOM weapons, monsters, pickups, etc.

Flip **DOOM MODE** on in the settings menu and the overworld becomes a
first-person shooter: pick up a DOOM weapon, gun down roaming demons (or
possessed Pokémon), and fight through Kanto. Flip it off and the base
game plays normally.

## What this is

- An addon that installs alongside the host voxel mod.
- Every sprite, sound, and font comes from a DOOM WAD and a GZDoom
  install you supply yourself — see [Setup](#setup) below.
- Works with DramaticShapeVoxelMod, potato_voxel, and other compatible
  forks of the host mod.

## Features

### Core FPS mode
- First-person camera and view feel (FOV, view bob, weapon sway), riding
  the host mod's own camera.
- All 8 original DOOM weapons: fist, chainsaw, pistol, shotgun, chaingun,
  rocket launcher, plasma rifle, BFG9000 — real fire rates, ammo types,
  weapon-sprite animations, and muzzle flashes read from your WAD.
- A real DOOM status bar HUD: ammo, arms grid, the face widget, health,
  and armor.
- The real DOOM pickup/HUD message font and palette-flash screen tint.
- A player health/armor/damage system, death, and respawn.
- A DOOM-style skin for the pause menu and its Options submenu.
- Controller support: trigger to fire, shoulder buttons to switch
  weapons, full gamepad navigation in the object-placement menu.

### The KILL mechanic
- Overworld NPCs can be aimed at and shot down in first person, with a
  DOOM XDeath gib sequence and permanent removal from your save.
- Toggle whether NPCs can be killed at all, whether that needs
  confirmation, and how graphic it looks.

### DOOM demons
- The 10-monster Doom roster — Zombieman, Shotgun Guy,
  Imp, Demon, Spectre, Cacodemon, Baron of Hell, Lost Soul, Spider
  Mastermind, Cyberdemon — each with real stats, sprites, sounds, and
  attacks.
- Demon AI: chasing/pathing, melee/hitscan/thrown-fireball attacks,
  pain-state stagger, gunfire alerts, and per-monster damage variance.
- Demons roam outdoors, hunt and kill citizens/Pokémon in their way (who
  flee once targeted), and stay out of interiors.
- **ENEMY TYPE** toggle switches the ambient hostile roster between DOOM
  demons and possessed Pokémon NPCs.
- Town invasion events: demons swarm a town, townsfolk flee indoors, and
  you clear every demon out to end it.
- Difficulty and spawn-density options for the ambient roster.

### Items & economy
- DOOM's own 11-item pickup table scattered across every map.
- Battle wins grant a random item; trainer battles can reward a new
  weapon. You start with fist + pistol.
- Everything shows up in the item bag with real DOOM names, and DOOM
  weapons/ammo are sold in Pokémarts.

### Visual/audio parity
- Visible in-flight and impact sprites for rockets, plasma bolts, BFG
  balls, and demon fireballs.
- Blood splatter and bullet-impact puffs on every landed hit.
- Screen palette flashes (damage, pickups).

## Requirements

- The host voxel mod installed and enabled.
- Your own DOOM WAD (`doom.wad`, `doom1.wad`, `doom2.wad`, a Freedoom
  IWAD, etc.).
- Your own GZDoom install, for `game_support.pk3`. Both are required —
  DOOM MODE needs the WAD, and menu text needs the font.

## Installation

1. Copy this mod's folder into your game's `mods/` directory, alongside
   the host voxel mod.
2. Launch the game once so the mod folder is fully set up.

## Setup

1. Find the mod's own `import/` folder (a sibling of its `main.lua` —
   see that folder's own `README.txt` for the exact path on your
   platform).
2. Copy your DOOM WAD file into it.
3. Copy `game_support.pk3`, the whole file, from your GZDoom install
   folder into the same `import/` folder.
4. In-game, open the settings menu and press **IMPORT DOOM WAD** and
   **IMPORT GZDOOM FONT**. DOOM MODE activates once both imports
   succeed.

Your original WAD and pk3 are never modified.

## Usage

- **DOOM MODE** — the master on/off switch.
- **ENEMY TYPE** — DOOM demons or possessed Pokémon as the ambient
  hostile roster.
- **DEMON DIFFICULTY** / **DEMON DENSITY** — tune the ambient roaming
  encounter rate and toughness.
- **TOWN INVASIONS** / **INVASION FREQUENCY** — the scripted
  town-clearing events.
- **PARTY KILLING** / **PARTY KILL CONFIRMATION** / **POKEMON GORE** —
  control whether NPCs/Pokémon can be killed at all, whether that needs
  confirmation, and how graphic it looks.
- **INFINITE AMMO** / **INFINITE HEALTH**, **STARTING LOADOUT**, **VIEW
  BOB**, **SCREEN SHAKE**, and more — the full options list lives in the
  same settings menu, each with its own on-screen description.

## Credits

- **id Software** — DOOM, the source of every gameplay mechanic this mod
  ports. No DOOM assets are distributed with this mod; you supply your
  own.
- GZDoom — the BigUpper menu font, distributed with GZDoom.
- **[wadext](https://github.com/coelckers/wadext)** — the reference WAD
  extractor this mod's own extractor was based on.
