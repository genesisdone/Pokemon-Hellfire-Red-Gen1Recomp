-- PokeDoom Phase 2: the weapon framework, generalized from DOOM's own
-- state-machine architecture -- read fresh from DOOM-master/
-- linuxdoom-1.10 at every constant below, per CLAUDE.md's "DOOM facts
-- come from the source" rule. The pistol is rebuilt here as the proof
-- case (info.c states S_PISTOL/S_PISTOLUP/S_PISTOLDOWN/S_PISTOL1-4/
-- S_PISTOLFLASH; p_pspr.c's P_SetPsprite/P_MovePsprites engine and
-- A_WeaponReady/A_Lower/A_Raise/A_FirePistol/A_ReFire/A_Light0/A_Light1;
-- d_items.c's weaponinfo_t entry for wp_pistol). Phase 3 adds the other
-- 8 weapons as more entries in WEAPONS/STATES, not a new engine.
--
-- DOOM has NO manual reload -- ammo just decrements until P_CheckAmmo
-- auto-switches weapons. The magazine-and-reload feel in the host mod's
-- own HordeGun.lua is that module's own arcade embellishment for its
-- wave-survival mode, not authentic DOOM behavior, so it is deliberately
-- NOT ported here.
--
-- Rendering: the weapon view model is a plain 2D screen-space sprite,
-- drawn through the base engine's generic `render.hud` hook
-- (Game.lua:516-518, always available to any mod) -- NOT a real 3D voxel
-- object the way the host's own HordeGun is. This isn't a compromise:
-- DOOM's own weapon sprite is ALSO a flat screen-space overlay with no
-- depth test against the world (how a 2.5D engine draws it), so this is
-- the more faithful choice. It also sidesteps a real constraint found
-- while researching this: HordeGun.draw() is hardcoded into the host's
-- VoxelScene.lua at a specific line, with no exposed seam for a third-
-- party mod to add its own depth-composited 3D draw call there, and a
-- render_pipelines worldPresent/present stage only ever receives the
-- already-flattened 2D canvas -- too late for that kind of drawing.
--
-- Target resolution is deliberately a registry with NOTHING registered
-- yet: Phase 6 owns the rules for what a shot is allowed to kill (battle
-- opponents, overworld NPCs, the following Pokemon) and under what
-- consequences. This phase only builds the seam those rules plug into,
-- per CLAUDE.md's design constraint that it serve both contexts from the
-- start.

local V = ...
local Host = V.host

local FirstPerson = Host.require("FirstPerson")
local Voxel = Host.require("VoxelState")
local Options = V.require("DoomOptions")
local DoomWadImport = V.require("DoomWadImport")
local DoomLog = V.require("DoomLog")
local DoomMove = V.require("DoomMove")
local DoomHealth = V.require("DoomHealth")
local DoomPuff = V.require("DoomPuff")
local DoomGround = V.require("DoomGround")
local DoomVirtualCanvas = V.require("DoomVirtualCanvas")

-- `lib/DoomDemons.lua` already requires THIS file (`DoomWeapons`) at its
-- own top level, to register its target/AOE resolvers -- a top-level
-- `V.require("DoomDemons")` here would be a genuine circular require
-- (whichever of the two loads second would get the other's still-
-- mid-construction module table). Deferred to first actual USE instead
-- (well after both modules have finished loading, since nothing fires a
-- weapon during module load) -- the same safe, standard way to break a
-- require cycle in Lua.
local DoomDemons
local function getDoomDemons()
  DoomDemons = DoomDemons or V.require("DoomDemons")
  return DoomDemons
end

-- Same lazy-require idiom, same real cycle-avoidance reason (`lib/
-- DoomBarrels.lua` already lazily requires THIS file via its own
-- `getDoomWeapons()`, so a top-level require here would close a real
-- cycle) -- added for `computeAutoAimPitch`'s own new barrel candidate
-- search below.
local DoomBarrels
local function getDoomBarrels()
  DoomBarrels = DoomBarrels or V.require("DoomBarrels")
  return DoomBarrels
end

-- FIX 2026-08-10 -- user report: launching via Play-Windows.bat failed
-- outright, "mods/PokeDoom-dev/main.lua:60: stack overflow" (infinite
-- recursion inside `V.require`). Root cause: this file's own top-level
-- `V.require("DoomView")` (added the same round as the SCREEN SHAKE
-- feature below) closed a genuine 3-way require cycle -- `lib/
-- DoomView.lua` requires `lib/DoomHud.lua`, which requires THIS file
-- (`DoomWeapons`), which was requiring `DoomView` right back, all at
-- module-LOAD time. Whichever of the three loads first (`DoomView`,
-- per `main.lua`'s own require order) never finishes constructing
-- before the cycle demands it again, so `V.require`'s own "already
-- cached" check never fires and each file's whole chunk re-runs forever.
-- Same real fix as `DoomDemons` just above (a proven, already-working
-- pattern in this exact file): deferred to first actual USE instead of
-- module-load time, since nothing triggers a rocket/BFG explosion while
-- modules are still loading.
local DoomView
local function getDoomView()
  DoomView = DoomView or V.require("DoomView")
  return DoomView
end

local DoomWeapons = {}

-- ------- DOOM tic/frame conversion
--
-- DOOM's TICRATE is 35 (doomdef.h:122). Converted to this engine's 60Hz
-- the same way this project's other DOOM-tic conversions are: more,
-- smaller frames instead of fewer, bigger tics -- but each STATES/
-- FLASH_STATES entry below now stores the RAW `domTics` count straight
-- off `info.c`, not a pre-rounded frame count. Rounding every state
-- independently (this function's own previous version, `math.floor(
-- domTics*60/35+0.5)` applied once per entry at table-load time) drifted
-- up to 2 frames (~33ms) from the exact conversion over a full weapon
-- cycle for some weapons (fist, shotgun, rocket launcher, BFG9000 --
-- measured in phases/phase-5-fire-rate.md's own audit table), since
-- 60/35 isn't a whole number and each state's own fractional remainder
-- was simply discarded instead of carried into the next state's rounding.
-- ticsFor below fixes that with a running fractional accumulator (the
-- same error-diffusion idea a sample-rate converter or a Bresenham line
-- uses): each call adds this exact state's own exact frame-equivalent to
-- whatever fractional remainder is still owed from the last call, floors
-- that for the actual integer frame count to display, and keeps the new
-- remainder for next time -- so the cumulative displayed frame count for
-- ANY prefix of a psprite's whole history stays within under 1 frame of
-- the mathematically exact DOOM-tic-to-60Hz conversion, not just at one
-- chosen endpoint. The accumulator lives on `player.psp`/`player.flash`
-- themselves (see their own `ticAccum` field below) and is never reset --
-- DOOM's own tic clock never resets either (leveltime runs continuously
-- for the whole level, weapon switches included), so there's no natural
-- "chain boundary" to reset on that wouldn't itself be an approximation.
local DOOM_TICRATE = 35
local FRAME_RATE = 60
local function ticsFor(psp, domTics)
  local exact = psp.ticAccum + domTics * FRAME_RATE / DOOM_TICRATE
  local displayFrames = math.floor(exact)
  psp.ticAccum = exact - displayFrames
  return displayFrames
end

-- ------- the weapon state tables (info.c)
--
-- state_t is {sprite, frame, tics, action, nextstate, misc1, misc2}
-- (info.h:1147). `sprite` restored here as of Phase 4 (phases/phase-4-
-- weapon-animations.md) -- a lump-name string like "PISGA" -- decoded
-- from info.c's own numeric frame field the same way DOOM's renderer
-- decodes it (p_pspr.h:50-51: FF_FULLBRIGHT=0x8000, FF_FRAMEMASK=0x7fff;
-- masked frame number -> letter, 0=A/1=B/2=C/...), confirmed directly
-- rather than assumed, every weapon audited fresh in that phase doc.
-- Every weapon sprite uses rotation digit 0 uniformly (a first-person
-- view model has no rotation to show, confirmed empirically too -- every
-- extracted sprite this project has found ends in 0), so `sprite` here
-- is the lump name MINUS that trailing rotation digit;
-- DoomWadImport.findAsset's substring match doesn't need it disambiguated
-- further. misc1/misc2 (a one-time sprite offset override) are unused by
-- every weapon's states, so still left out. `domTics` is each state's own
-- raw `info.c` tic count (Phase 5, phases/phase-5-fire-rate.md) -- see
-- ticsFor above for how it becomes an actual display-frame count.
--
-- The weapon psprite chain (ps_weapon):
local STATES = {
  PISTOL     = { domTics = 1, action = "weaponReady", next = "PISTOL",     sprite = "PISGA" },
  PISTOLDOWN = { domTics = 1, action = "lower",       next = "PISTOLDOWN", sprite = "PISGA" },
  PISTOLUP   = { domTics = 1, action = "raise",       next = "PISTOLUP",   sprite = "PISGA" },
  PISTOL1    = { domTics = 4, action = nil,           next = "PISTOL2",    sprite = "PISGA" },
  PISTOL2    = { domTics = 6, action = "firePistol",  next = "PISTOL3",    sprite = "PISGB" },
  PISTOL3    = { domTics = 4, action = nil,           next = "PISTOL4",    sprite = "PISGC" },
  PISTOL4    = { domTics = 5, action = "refire",      next = "PISTOL",     sprite = "PISGB" },

  -- Fist (info.c:138-145)
  PUNCH     = { domTics = 1, action = "weaponReady", next = "PUNCH",  sprite = "PUNGA" },
  PUNCHDOWN = { domTics = 1, action = "lower",       next = "PUNCHDOWN", sprite = "PUNGA" },
  PUNCHUP   = { domTics = 1, action = "raise",       next = "PUNCHUP",   sprite = "PUNGA" },
  PUNCH1    = { domTics = 4, action = nil,           next = "PUNCH2", sprite = "PUNGB" },
  PUNCH2    = { domTics = 4, action = "punch",       next = "PUNCH3", sprite = "PUNGC" },
  PUNCH3    = { domTics = 5, action = nil,           next = "PUNCH4", sprite = "PUNGD" },
  PUNCH4    = { domTics = 4, action = nil,           next = "PUNCH5", sprite = "PUNGC" },
  PUNCH5    = { domTics = 5, action = "refire",      next = "PUNCH",  sprite = "PUNGB" },

  -- Chainsaw (info.c:203-209) -- SAW/SAWB alternate as the idle "chug"
  SAW     = { domTics = 4, action = "weaponReady", next = "SAWB", sprite = "SAWGC" },
  SAWB    = { domTics = 4, action = "weaponReady", next = "SAW",  sprite = "SAWGD" },
  SAWDOWN = { domTics = 1, action = "lower",       next = "SAWDOWN", sprite = "SAWGC" },
  SAWUP   = { domTics = 1, action = "raise",       next = "SAWUP",   sprite = "SAWGC" },
  SAW1    = { domTics = 4, action = "saw",         next = "SAW2", sprite = "SAWGA" },
  SAW2    = { domTics = 4, action = "saw",         next = "SAW3", sprite = "SAWGB" },
  SAW3    = { domTics = 0, action = "refire",      next = "SAW",  sprite = "SAWGB" },

  -- Shotgun (info.c:154-165)
  SGUN  = { domTics = 1, action = "weaponReady", next = "SGUN", sprite = "SHTGA" },
  SGUNDOWN = { domTics = 1, action = "lower",     next = "SGUNDOWN", sprite = "SHTGA" },
  SGUNUP   = { domTics = 1, action = "raise",     next = "SGUNUP",   sprite = "SHTGA" },
  SGUN1 = { domTics = 3, action = nil,           next = "SGUN2", sprite = "SHTGA" },
  SGUN2 = { domTics = 7, action = "fireShotgun", next = "SGUN3", sprite = "SHTGA" },
  SGUN3 = { domTics = 5, action = nil,           next = "SGUN4", sprite = "SHTGB" },
  SGUN4 = { domTics = 5, action = nil,           next = "SGUN5", sprite = "SHTGC" },
  SGUN5 = { domTics = 4, action = nil,           next = "SGUN6", sprite = "SHTGD" },
  SGUN6 = { domTics = 5, action = nil,           next = "SGUN7", sprite = "SHTGC" },
  SGUN7 = { domTics = 5, action = nil,           next = "SGUN8", sprite = "SHTGB" },
  SGUN8 = { domTics = 3, action = nil,           next = "SGUN9", sprite = "SHTGA" },
  SGUN9 = { domTics = 7, action = "refire",      next = "SGUN",  sprite = "SHTGA" },

  -- Chaingun (info.c:185-190)
  CHAIN     = { domTics = 1, action = "weaponReady", next = "CHAIN",     sprite = "CHGGA" },
  CHAINDOWN = { domTics = 1, action = "lower",       next = "CHAINDOWN", sprite = "CHGGA" },
  CHAINUP   = { domTics = 1, action = "raise",       next = "CHAINUP",   sprite = "CHGGA" },
  CHAIN1    = { domTics = 4, action = "fireCGun",    next = "CHAIN2", sprite = "CHGGA" },
  CHAIN2    = { domTics = 4, action = "fireCGun",    next = "CHAIN3", sprite = "CHGGB" },
  CHAIN3    = { domTics = 0, action = "refire",      next = "CHAIN",  sprite = "CHGGB" },

  -- Rocket launcher (info.c:193-198)
  MISSILE     = { domTics = 1,  action = "weaponReady", next = "MISSILE",     sprite = "MISGA" },
  MISSILEDOWN = { domTics = 1,  action = "lower",       next = "MISSILEDOWN", sprite = "MISGA" },
  MISSILEUP   = { domTics = 1,  action = "raise",       next = "MISSILEUP",   sprite = "MISGA" },
  MISSILE1    = { domTics = 8,  action = "gunFlash",    next = "MISSILE2", sprite = "MISGB" },
  MISSILE2    = { domTics = 12, action = "fireMissile", next = "MISSILE3", sprite = "MISGB" },
  MISSILE3    = { domTics = 0,  action = "refire",      next = "MISSILE",  sprite = "MISGB" },

  -- Plasma rifle (info.c:210-214)
  PLASMA     = { domTics = 1,  action = "weaponReady", next = "PLASMA",     sprite = "PLSGA" },
  PLASMADOWN = { domTics = 1,  action = "lower",       next = "PLASMADOWN", sprite = "PLSGA" },
  PLASMAUP   = { domTics = 1,  action = "raise",       next = "PLASMAUP",   sprite = "PLSGA" },
  PLASMA1    = { domTics = 3,  action = "firePlasma",  next = "PLASMA2", sprite = "PLSGA" },
  PLASMA2    = { domTics = 20, action = "refire",      next = "PLASMA",  sprite = "PLSGB" },

  -- BFG9000 (info.c:217-223)
  BFG     = { domTics = 1,  action = "weaponReady", next = "BFG",     sprite = "BFGGA" },
  BFGDOWN = { domTics = 1,  action = "lower",       next = "BFGDOWN", sprite = "BFGGA" },
  BFGUP   = { domTics = 1,  action = "raise",       next = "BFGUP",   sprite = "BFGGA" },
  BFG1    = { domTics = 20, action = "bfgSound",    next = "BFG2", sprite = "BFGGA" },
  BFG2    = { domTics = 10, action = "gunFlash",    next = "BFG3", sprite = "BFGGB" },
  BFG3    = { domTics = 10, action = "fireBFG",     next = "BFG4", sprite = "BFGGB" },
  BFG4    = { domTics = 20, action = "refire",      next = "BFG",  sprite = "BFGGB" },
}
-- The FLASH psprite chain (ps_flash) -- a second, independent state
-- machine DOOM runs alongside the weapon one, purely to time the muzzle
-- flash. P_MovePsprites syncs its sx/sy to the weapon psprite's own every
-- tic (p_pspr.c:875-876) -- this port's own draw code (drawSprite) draws
-- the flash at the SAME position it already draws the weapon, matching
-- that sync without needing separate offsets. LIGHTDONE has no `sprite`
-- -- it's the state that ENDS the flash (A_Light0, S_NULL-equivalent),
-- never itself drawn (setFlashPsprite sets player.flash.state = nil the
-- instant it's reached, since its `next` is nil -- see that function).
local FLASH_STATES = {
  PISTOLFLASH = { domTics = 7, action = "light1", next = "LIGHTDONE", sprite = "PISFA" },
  LIGHTDONE   = { domTics = 0,         action = "light0", next = nil },

  SGUNFLASH1 = { domTics = 4, action = "light1", next = "SGUNFLASH2", sprite = "SHTFA" },
  SGUNFLASH2 = { domTics = 3, action = "light2", next = "LIGHTDONE",  sprite = "SHTFB" },

  -- A_FireCGun picks CHAINFLASH1/2 by which of the two fire frames is
  -- current (p_pspr.c:745-749's `psp->state - &states[S_CHAIN1]` offset)
  -- -- see Actions.fireCGun.
  CHAINFLASH1 = { domTics = 5, action = "light1", next = "LIGHTDONE", sprite = "CHGFA" },
  CHAINFLASH2 = { domTics = 5, action = "light2", next = "LIGHTDONE", sprite = "CHGFB" },

  MISSILEFLASH1 = { domTics = 3, action = "light1", next = "MISSILEFLASH2", sprite = "MISFA" },
  MISSILEFLASH2 = { domTics = 4, action = nil,      next = "MISSILEFLASH3", sprite = "MISFB" },
  MISSILEFLASH3 = { domTics = 4, action = "light2", next = "MISSILEFLASH4", sprite = "MISFC" },
  MISSILEFLASH4 = { domTics = 4, action = "light2", next = "LIGHTDONE",     sprite = "MISFD" },

  PLASMAFLASH1 = { domTics = 4, action = "light1", next = "LIGHTDONE", sprite = "PLSFA" },
  PLASMAFLASH2 = { domTics = 4, action = "light1", next = "LIGHTDONE", sprite = "PLSFB" },

  BFGFLASH1 = { domTics = 11, action = "light1", next = "BFGFLASH2", sprite = "BFGFA" },
  BFGFLASH2 = { domTics = 6,  action = "light2", next = "LIGHTDONE", sprite = "BFGFB" },
}

-- ------- the weaponinfo table (d_items.c) -- one entry per weapon,
-- pointing at that weapon's own STATES/FLASH_STATES chains above.
local WEAPONS = {
  FIST = {
    ammoType = nil, -- am_noammo
    upstate = "PUNCHUP", downstate = "PUNCHDOWN",
    readystate = "PUNCH", atkstate = "PUNCH1", flashstate = nil,
  },
  PISTOL = {
    ammoType = "clip", ammoPerShot = 1,
    upstate = "PISTOLUP", downstate = "PISTOLDOWN",
    readystate = "PISTOL", atkstate = "PISTOL1", flashstate = "PISTOLFLASH",
  },
  SHOTGUN = {
    ammoType = "shell", ammoPerShot = 1,
    upstate = "SGUNUP", downstate = "SGUNDOWN",
    readystate = "SGUN", atkstate = "SGUN1", flashstate = "SGUNFLASH1",
  },
  CHAINGUN = {
    ammoType = "clip", ammoPerShot = 1,
    upstate = "CHAINUP", downstate = "CHAINDOWN",
    readystate = "CHAIN", atkstate = "CHAIN1", flashstate = "CHAINFLASH1",
  },
  ROCKETLAUNCHER = {
    ammoType = "misl", ammoPerShot = 1,
    upstate = "MISSILEUP", downstate = "MISSILEDOWN",
    readystate = "MISSILE", atkstate = "MISSILE1", flashstate = "MISSILEFLASH1",
  },
  PLASMARIFLE = {
    ammoType = "cell", ammoPerShot = 1,
    upstate = "PLASMAUP", downstate = "PLASMADOWN",
    readystate = "PLASMA", atkstate = "PLASMA1", flashstate = "PLASMAFLASH1",
  },
  BFG9000 = {
    ammoType = "cell", ammoPerShot = 40, -- BFGCELLS (p_pspr.c:52)
    upstate = "BFGUP", downstate = "BFGDOWN",
    readystate = "BFG", atkstate = "BFG1", flashstate = "BFGFLASH1",
  },
  CHAINSAW = {
    ammoType = nil, -- am_noammo
    upstate = "SAWUP", downstate = "SAWDOWN",
    readystate = "SAW", atkstate = "SAW1", flashstate = nil,
  },
}
-- number-key order. DOOM's own weapon slots pair fist/chainsaw on one key
-- and shotgun/super-shotgun on another (whichever is owned); this port
-- has no such slot-sharing logic, so each weapon gets its own dedicated
-- key regardless -- but `selectWeapon` below now DOES gate on
-- `player.weaponowned`, matching real DOOM (Phase 13, replacing the
-- earlier "every weapon simply available" simplification).
local WEAPON_KEYS = {
  ["1"] = "FIST", ["2"] = "PISTOL", ["3"] = "SHOTGUN", ["4"] = "CHAINGUN",
  ["5"] = "ROCKETLAUNCHER", ["6"] = "PLASMARIFLE", ["7"] = "BFG9000",
  ["8"] = "CHAINSAW",
}

-- Real DOOM max ammo capacities without a backpack (p_inter.c:58:
-- `maxammo[NUMAMMO] = {200, 50, 300, 50}`, ordered am_clip/am_shell/
-- am_cell/am_misl per doomdef.h:203-207) -- what IDFA/the "give all
-- ammo" cheat actually fills a player's ammo up to (st_stuff.c:573,587).
-- `clipammo[NUMAMMO] = {10, 4, 20, 1}` (p_inter.c:59) -- P_GiveAmmo's own
-- real per-clip-load amount for each type ("a weapon is found with two
-- clip loads, a big item has five," that file's own comment). Real
-- DOOM's `maxammo` is a PER-PLAYER, mutable `player_t` field (a backpack
-- pickup doubles it once, permanently) -- ported here the same way, as
-- `player.maxAmmo` below, not a fixed module constant.
local MAX_AMMO_DEFAULT = { clip = 200, shell = 50, cell = 300, misl = 50 }
local CLIPAMMO = { clip = 10, shell = 4, cell = 20, misl = 1 }

-- ------- player weapon state (player_t's relevant fields: psprites,
-- readyweapon, pendingweapon, ammo, refire, attackdown -- p_pspr.h /
-- d_player.h)
local player = {
  readyweapon = "PISTOL",
  pendingweapon = nil,
  -- Real `G_PlayerReborn` starting values (g_game.c:800-833), no longer
  -- the earlier "every weapon/ammo type starts full" simplification --
  -- that departure existed only because no pickup system existed yet to
  -- earn the rest (Phase 2's own header comment); Phase 13 replaces it
  -- with the genuine mechanism, so the genuine starting state belongs
  -- here now too: `weaponowned[wp_fist]=true; weaponowned[wp_pistol]=
  -- true; ammo[am_clip]=50` -- fist and pistol owned, nothing else.
  -- `readyweapon`/`pendingweapon` stay `wp_pistol` (g_game.c:825),
  -- matching this file's own existing PISTOL default.
  -- CHANGED 2026-08-19, direct user request ("the pistol you spawn with
  -- when you start a new game to have 20 bullets in it already") --
  -- starting `clip` ammo is now 20, a deliberate departure from real
  -- DOOM's own 50 (this mod's own addition, not a porting correction --
  -- see `loadWeaponSave`'s matching fresh-save branch below, which needs
  -- the exact same value for a save that reaches the game through
  -- `save.created` instead of this module-load default).
  weaponowned = {
    FIST = true, PISTOL = true, SHOTGUN = false, CHAINGUN = false,
    ROCKETLAUNCHER = false, PLASMARIFLE = false, BFG9000 = false,
    CHAINSAW = false,
  },
  maxAmmo = { clip = MAX_AMMO_DEFAULT.clip, shell = MAX_AMMO_DEFAULT.shell,
              misl = MAX_AMMO_DEFAULT.misl, cell = MAX_AMMO_DEFAULT.cell },
  backpack = false, -- P_GiveAmmo's own `player->backpack` guard against doubling maxAmmo twice
  ammo = { clip = 20, shell = 0, misl = 0, cell = 0 },
  refire = 0,
  attackdown = false,
  attackHeld = false, -- this port's BT_ATTACK: set by the mouse wrap below
  swayPhase = 0,
  -- swayX/swayY: real DOOM psp->sx/sy DELTAS (i.e. the OSCILLATING part
  -- only, added onto the SPRITE_SX_BASE/WEAPON_TOP_DOOM baselines
  -- elsewhere in this file, not the absolute psp->sx/sy values
  -- themselves) -- written ONLY by Actions.weaponReady, matching real
  -- DOOM where A_WeaponReady is the ONLY place that ever writes psp->sx/
  -- sy, so they correctly stay frozen at whatever they last were through
  -- an entire fire/recoil sequence (which never calls A_WeaponReady) --
  -- see that function's own header comment.
  swayX = 0,
  swayY = 0,
  -- sy: 0 raised (WEAPONTOP) .. 1 lowered (WEAPONBOTTOM). ticAccum: the
  -- running fractional-frame remainder ticsFor's error-diffusion rounding
  -- carries between states (Phase 5, phases/phase-5-fire-rate.md) -- never
  -- reset, see ticsFor's own header comment for why.
  psp = { state = nil, tics = 0, sy = 1, ticAccum = 0 },
  flash = { state = nil, tics = 0, ticAccum = 0 },
}

-- ------- save persistence (weaponowned/ammo/maxAmmo/backpack/readyweapon)
--
-- User report (2026-08-07): "if i get a weapon then quit and continue on
-- a save before i got that weapon, i will still have that weapon, until
-- i swap away from it. i need the weapons the player have be attached to
-- the save so this doesnt happen." Root cause: `player` above is a plain
-- module-closure local with NO save-lifecycle awareness at all -- unlike
-- `save.killedNpcs`/`save.defeatedTrainers`, loading a DIFFERENT (or
-- earlier) save never touched it, so whatever weapons/ammo this Lua
-- session happened to already have stayed exactly as they were,
-- completely detached from which save is actually loaded. The exact
-- same class of bug `lib/DoomKill.lua`'s own gibs and `lib/
-- DoomHordeControl.lua`'s own Horde-death corpses already had (Phase 18
-- Bug 5 / 2026-08-07) -- fixed the same real way: a dedicated
-- save-namespaced table, loaded fresh on `save.loaded`/`save.created`.
-- `Game.save.pokedoomWeapons` (top-level, mirroring `save.killedNpcs`'s
-- own shape) rather than nested under `save.options.pokedoom` -- this is
-- player PROGRESS, not a settings toggle.
local weaponViewDirty = false

-- FIX 2026-08-19 -- REAL ROOT CAUSE of "new game starts with 0 ammo
-- instead of the real 20-round starting clip": `save.created` and
-- `save.loaded` were wired to this exact same function, trusting
-- whatever `Game.save.pokedoomWeapons` already held either way. That's
-- correct for `save.loaded` (continuing a real, previously-written save
-- genuinely should restore whatever it last had) but wrong for
-- `save.created` -- a brand-new game's own `Game.save` table is a mod-
-- UNAWARE base-engine object; the base engine resets every field IT
-- knows about, but `pokedoomWeapons` is this mod's own added extension
-- field, which nothing in the base engine's own new-game logic has any
-- reason to know to clear. If a PRIOR session (or an earlier save this
-- process already loaded once) had already written a real, low/empty
-- ammo count into memory, starting a genuinely new game never got a
-- chance to reset it -- the stale value was still sitting there,
-- indistinguishable from a real prior save's own legitimate progress
-- purely by `if saved then` alone. `forceFresh` makes `save.created`
-- skip that trust entirely and always apply the real starting values
-- (the exact same shape `player` above already starts life with),
-- overwriting whatever `Game.save.pokedoomWeapons` currently holds
-- rather than reading it.
-- DIAGNOSTIC 2026-08-19 -- direct user report, SURVIVED the `forceFresh`
-- fix above (confirmed redeployed, still 0 ammo on a genuine new game) --
-- per CLAUDE.md's own "a bug that survives one fix attempt gets logging
-- before a second attempt" rule, logging every real decision point in
-- this function now instead of guessing a third theory blind. `readyAmmo()`
-- (the HUD's own real source) reads `player.ammo` directly, never
-- `Game.save.pokedoomWeapons` -- so if the HUD still shows 0 after this
-- runs, `player.ammo.clip` itself was never actually set to 20 here, no
-- matter what the save mirror holds.
local function loadWeaponSave(gameArg, forceFresh)
  local Game = gameArg or require("src.core.Game")
  if not (Game and Game.save) then
    pcall(DoomLog.event, "WEAPONSAVE", "loadWeaponSave: no Game/Game.save (Game=%s, Game.save=%s), bailing out",
      tostring(Game ~= nil), tostring(Game and Game.save ~= nil))
    return
  end
  local rawSaved = Game.save.pokedoomWeapons
  local saved = not forceFresh and rawSaved
  pcall(DoomLog.event, "WEAPONSAVE",
    "loadWeaponSave: forceFresh=%s rawSaved=%s rawSaved.ammo.clip=%s -> taking %s branch",
    tostring(forceFresh), tostring(rawSaved ~= nil),
    tostring(rawSaved and rawSaved.ammo and rawSaved.ammo.clip),
    saved and "RESTORE" or "FRESH")
  if saved then
    for name in pairs(player.weaponowned) do
      player.weaponowned[name] = (saved.owned and saved.owned[name]) or false
    end
    for ammoType in pairs(player.ammo) do
      player.ammo[ammoType] = (saved.ammo and saved.ammo[ammoType]) or 0
      player.maxAmmo[ammoType] = (saved.maxAmmo and saved.maxAmmo[ammoType])
        or MAX_AMMO_DEFAULT[ammoType]
    end
    player.backpack = saved.backpack or false
    -- Defensive: if the restored readyweapon somehow isn't one this save
    -- actually owns (a manually edited save, or a save from a build with
    -- a different weapon roster), fall back to the pistol -- always
    -- owned, never a crash-shaped surprise.
    player.readyweapon = (saved.readyweapon and player.weaponowned[saved.readyweapon])
      and saved.readyweapon or "PISTOL"
  else
    -- No saved record yet -- a genuinely fresh save, or one written
    -- before this feature existed. Real `G_PlayerReborn` starting values
    -- (g_game.c:800-833), the exact same shape `player` above already
    -- starts life with -- reset explicitly here (not just left alone)
    -- since this function also runs on a SAVE SWITCH, where the
    -- in-memory `player` may currently hold a DIFFERENT save's progress.
    player.maxAmmo = { clip = MAX_AMMO_DEFAULT.clip, shell = MAX_AMMO_DEFAULT.shell,
                        misl = MAX_AMMO_DEFAULT.misl, cell = MAX_AMMO_DEFAULT.cell }
    -- FEATURE 2026-08-10 -- new "STARTING LOADOUT" options row
    -- (PISTOL ONLY (default, the real `G_PlayerReborn` values above) /
    -- ALL WEAPONS -- every weapon owned, full ammo of each type, for
    -- players who'd rather skip the pickup grind). No DOOM precedent for
    -- the ALL WEAPONS side (real DOOM's own closest equivalent is the
    -- IDKFA cheat, not a menu default) -- this mod's own addition.
    if Options.startingLoadout() == "all" then
      player.weaponowned = {
        FIST = true, PISTOL = true, SHOTGUN = true, CHAINGUN = true,
        ROCKETLAUNCHER = true, PLASMARIFLE = true, BFG9000 = true,
        CHAINSAW = true,
      }
      player.ammo = { clip = player.maxAmmo.clip, shell = player.maxAmmo.shell,
                       misl = player.maxAmmo.misl, cell = player.maxAmmo.cell }
    else
      player.weaponowned = {
        FIST = true, PISTOL = true, SHOTGUN = false, CHAINGUN = false,
        ROCKETLAUNCHER = false, PLASMARIFLE = false, BFG9000 = false,
        CHAINSAW = false,
      }
      -- 20, not real DOOM's own 50 -- see `player`'s own matching
      -- 2026-08-19 comment above for the full derivation.
      player.ammo = { clip = 20, shell = 0, misl = 0, cell = 0 }
    end
    player.backpack = false
    player.readyweapon = "PISTOL"
  end
  player.pendingweapon = nil
  pcall(DoomLog.event, "WEAPONSAVE",
    "loadWeaponSave: DONE -- player.ammo.clip=%s player.weaponowned.PISTOL=%s player.readyweapon=%s",
    tostring(player.ammo.clip), tostring(player.weaponowned.PISTOL), tostring(player.readyweapon))
  -- Forces the view model to actually catch up to whatever was just
  -- restored, in case PKDOOM MODE is already active across this load --
  -- `DoomWeapons.install()`'s own `started` enable-edge only ever fires
  -- once per session otherwise.
  weaponViewDirty = true
end

local function saveWeaponState(gameArg)
  local Game = gameArg or require("src.core.Game")
  if not (Game and Game.save) then return end
  Game.save.pokedoomWeapons = Game.save.pokedoomWeapons or {}
  local saved = Game.save.pokedoomWeapons
  saved.owned = saved.owned or {}
  for name, owned in pairs(player.weaponowned) do saved.owned[name] = owned end
  saved.ammo = saved.ammo or {}
  for ammoType, amount in pairs(player.ammo) do saved.ammo[ammoType] = amount end
  saved.maxAmmo = saved.maxAmmo or {}
  for ammoType, amount in pairs(player.maxAmmo) do saved.maxAmmo[ammoType] = amount end
  saved.backpack = player.backpack
  saved.readyweapon = player.readyweapon
end

-- Reads the real health pipeline as of Phase 12 (`lib/DoomHealth.lua`,
-- `P_DamageMobj`'s player branch) -- this used to be a hardcoded `true`
-- with a comment noting "no health/death system in this mod's scope
-- yet"; that system now exists, so this is the one place CLAUDE.md
-- already flagged as needing exactly this change. `> 0` matches DOOM's
-- own real `player->playerstate != PST_DEAD` gate (itself driven by
-- `!plyr->health`, confirmed in Phase 15's own audit of `P_KillMobj`).
function DoomWeapons.playerAlive()
  return DoomHealth.isAlive()
end

-- `player.attackdown` -- DOOM's own real field name and semantics
-- exactly (p_pspr.h's `player_t.attackdown`, set true the moment a shot
-- actually fires from the ready state, `Actions.weaponReady`/`fireWeapon`
-- above -- NOT the same as the raw `attackHeld` mouse-button signal,
-- which the fresh-press-required weapons deliberately don't fire on
-- every frame of). Exposed for `lib/DoomHud.lua`'s own face widget,
-- which needs the exact same signal `ST_updateFaceWidget`'s real rapid-
-- fire rampage check reads (`st_stuff.c:880`: `if (plyr->attackdown)`).
function DoomWeapons.isAttacking()
  return player.attackdown
end

-- `w_ready`'s own real value (`ST_updateWidgets`, st_stuff.c:924-935):
-- the ready weapon's ammo count, or -- when `weaponinfo[...].ammo ==
-- am_noammo` (fist/chainsaw) -- DOOM's own real 1994 "n/a" sentinel that
-- forces a blank readout (`STlib_drawNum`, st_lib.c:128-129). Ported here
-- as a real `nil` rather than carrying the magic number itself through:
-- the sentinel is DOOM's own C implementation trick for its digit-
-- drawing routine, not the functional behavior a re-implementation owes
-- (CLAUDE.md's "Nature of the port") -- `lib/DoomHud.lua`'s own
-- `drawNumber` just treats nil as "draw nothing," the same net effect.
function DoomWeapons.readyAmmo()
  local ammoType = WEAPONS[player.readyweapon].ammoType
  if not ammoType then return nil end
  return player.ammo[ammoType] or 0
end

-- ------- forward declarations (Lua has no hoisting for these mutual
-- references: actions call setPsprite/checkAmmo/fireWeapon and vice
-- versa, the same mutual recursion P_SetPsprite/A_WeaponReady/
-- P_FireWeapon/P_CheckAmmo have in DOOM's own C)
local setPsprite, setFlashPsprite, checkAmmo, fireWeapon
local Actions = {}

-- P_SetPsprite (p_pspr.c:58-102): sets state+tics, runs the state's
-- action if any, and chains straight through to nextstate without
-- waiting a frame for as long as tics comes back 0 -- the do-while(!tics)
-- loop that lets a state like LIGHTDONE (tics=0) act as a same-tic
-- redirector rather than a frame that's actually shown.
setPsprite = function(stateName)
  repeat
    if not stateName then
      player.psp.state = nil
      return
    end
    local state = STATES[stateName]
    player.psp.state = stateName
    player.psp.tics = ticsFor(player.psp, state.domTics)
    if state.action then
      Actions[state.action]()
      if not player.psp.state then return end
    end
    stateName = STATES[player.psp.state].next
  until player.psp.tics ~= 0
end

setFlashPsprite = function(stateName)
  repeat
    if not stateName then
      player.flash.state = nil
      return
    end
    local state = FLASH_STATES[stateName]
    player.flash.state = stateName
    player.flash.tics = ticsFor(player.flash, state.domTics)
    if state.action then
      Actions[state.action]()
      if not player.flash.state then return end
    end
    stateName = FLASH_STATES[player.flash.state].next
  until player.flash.tics ~= 0
end

-- P_BringUpWeapon (p_pspr.c:138-154)
local function bringUpWeapon()
  if not player.pendingweapon then player.pendingweapon = player.readyweapon end
  local w = WEAPONS[player.pendingweapon]
  player.pendingweapon = nil
  player.psp.sy = 1
  setPsprite(w.upstate)
end

-- FIX 2026-08-19 -- REAL ROOT CAUSE of "switched to fist with 0 ammo in
-- my pistol and couldn't switch back... couldn't use my fists either":
-- this function's own header comment (below) already documented the
-- exact missing piece -- running out of ammo used to just lower and
-- immediately re-raise the SAME weapon (`bringUpWeapon`'s own real
-- `pendingweapon` fallback re-using `readyweapon` when nothing else set
-- it), a same-weapon stutter forever instead of a real switch, for as
-- long as the player kept holding fire on an empty gun. Manually
-- selecting a DIFFERENT weapon (the fist) mid-stutter should still have
-- worked on paper (`selectWeapon` just sets `pendingweapon`, read at the
-- top of the NEXT `Actions.weaponReady` call once the stutter's own
-- lower/raise cycle happens to land back on the READY state) -- but every
-- resumed `weaponReady` tick immediately saw `attackHeld` still true and
-- re-fired before ever reaching that check, so a held trigger on an
-- empty weapon could starve a manual switch out indefinitely, reading
-- exactly like "stuck, can't switch, can't fire anything." Implements
-- the real chain now (P_CheckAmmo, p_pspr.c:161-240): plasma > super
-- shotgun > chaingun > shotgun > pistol > chainsaw > missile > bfg >
-- fist (no super shotgun -- not in this project's roster, Locked
-- Decision 2) -- see `pickAmmoSwitch` below for the real per-weapon
-- ammo/ownership checks.
local AMMO_PREFERENCE_CHAIN = {
  "PLASMARIFLE", "CHAINGUN", "SHOTGUN", "PISTOL", "CHAINSAW",
  "ROCKETLAUNCHER", "BFG9000",
}

-- Real DOOM's own pistol check skips the ownership test entirely
-- (`player->ammo[am_clip] > 0` alone, p_pspr.c:198-199) -- vanilla
-- single-player DOOM can never actually lose the pistol, so it never
-- needed one. This port's own shop-sell feature (`DoomWeapons.
-- takeWeapon`) means ownership genuinely CAN change here, so every
-- entry -- pistol included -- checks `player.weaponowned` for real
-- correctness in this port's own context; not a deviation from the real
-- chain's own order, just closing a gap that assumption doesn't survive
-- once weapons are sellable. FIST is the unconditional final fallback,
-- matching DOOM's own real `else newweapon = wp_fist` -- always owned,
-- never needs ammo.
local function pickAmmoSwitch()
  for _, name in ipairs(AMMO_PREFERENCE_CHAIN) do
    if player.weaponowned[name] then
      local cw = WEAPONS[name]
      local need = cw.ammoPerShot or 1
      if not cw.ammoType or (player.ammo[cw.ammoType] or 0) >= need then
        return name
      end
    end
  end
  return "FIST"
end

-- P_CheckAmmo (p_pspr.c:161-240).
checkAmmo = function()
  local w = WEAPONS[player.readyweapon]
  local need = w.ammoPerShot or 1
  -- INFINITE AMMO setting (user request, 2026-08-07): bypasses the real
  -- ammo gate entirely -- the single real choke point every weapon's
  -- fire action already goes through (`fireWeapon`, right below), so
  -- gating here alone means empty/negative ammo can never stop a shot.
  -- The per-shot decrement sites below are ALSO individually gated (not
  -- just left to run and go negative) so the HUD ammo count stays sane
  -- if the player turns this back off mid-game.
  if Options.infiniteAmmoEnabled() then return true end
  if not w.ammoType or (player.ammo[w.ammoType] or 0) >= need then
    return true
  end
  -- Only picks a new target if nothing has already claimed
  -- `pendingweapon` -- a player's own manual weapon-select press (still
  -- possible mid-stutter, see this function's own header comment) must
  -- never be clobbered by this auto-pick running again on a later tic.
  if not player.pendingweapon then
    local newWeapon = pickAmmoSwitch()
    if newWeapon ~= player.readyweapon then
      player.pendingweapon = newWeapon
    end
  end
  setPsprite(w.downstate)
  return false
end

-- P_FireWeapon (p_pspr.c:246-257), minus P_SetMobjState (no player mobj
-- animation states exist in this mod's scope). P_NoiseAlert -- monster-
-- alerting -- WAS also skipped here at the time this comment was
-- written ("no monster AI exist in this mod's scope"); that constraint
-- no longer holds (Phase 21/22's own real demon AI), so it's ported for
-- real now: see `lib/DoomDemons.lua`'s own `DoomDemons.noiseAlert`/
-- `heardNoiseAlert` for the full derivation. `pcall`-wrapped like every
-- other cross-module call site in this file (`getDoomDemons()`'s own
-- established lazy-require pattern) -- a demon-AI hiccup must never be
-- able to break the player's own ability to fire a weapon.
fireWeapon = function()
  if not checkAmmo() then return end
  setPsprite(WEAPONS[player.readyweapon].atkstate)
  local ok, ow = pcall(function() return require("src.core.Game").overworld end)
  if ok and ow then
    -- BUG FIX 2026-08-12 -- this used to be `pcall(getDoomDemons().noiseAlert,
    -- ow)`: `getDoomDemons()` and the `.noiseAlert` field lookup both happen
    -- while evaluating pcall's OWN arguments, i.e. BEFORE pcall's protection
    -- actually starts -- if the lazy require ever throws, or resolves to a
    -- module table that doesn't (yet) carry `.noiseAlert`, the error is not
    -- caught here at all, contrary to this function's own header comment
    -- above. Matches the nil-checked `local DD = getDoomX(); if DD and
    -- DD.method then pcall(DD.method, ...) end` shape already used at every
    -- OTHER lazy cross-module call site in this file (`computeAutoAimPitch`'s
    -- own DD/DB lookups below).
    local DD = getDoomDemons()
    if DD and DD.noiseAlert then
      pcall(DD.noiseAlert, ow)
    end
  end
end

-- A_WeaponReady (p_pspr.c:281-334), minus the S_PLAY_ATK/chainsaw-idle
-- bits (no player mobj animation state exists here). The fire condition
-- (p_pspr.c:315-319) is `BT_ATTACK held AND (attackdown was false OR this
-- weapon is neither the rocket launcher nor the BFG)` -- for every OTHER
-- weapon the OR's second half is always true, so attackdown doesn't gate
-- firing from the ready state at all; only the rocket launcher/BFG
-- require a fresh press-edge. `attackdown` is never reset on a weapon
-- switch (`P_BringUpWeapon`, p_pspr.c:138-154, doesn't touch it), so in
-- real DOOM holding fire through a weapon switch auto-fires anything
-- except those two immediately. Phase 5's audit
-- (phases/phase-5-fire-rate.md) found this port previously applied the
-- missile/BFG-only restriction to all 9 weapons uniformly -- fixed here.
local NEEDS_FRESH_PRESS = { ROCKETLAUNCHER = true, BFG9000 = true }

-- A_WeaponReady's own weapon-sway peak (p_pspr.c:329-333):
--   angle = (128*leveltime)&FINEMASK
--   psp->sx = FRACUNIT + FixedMul(player->bob, finecosine[angle])
--   angle &= FINEANGLES/2-1
--   psp->sy = WEAPONTOP + FixedMul(player->bob, finesine[angle])
-- `player->bob` (`P_CalcHeight`, p_user.c:49-57 -- the SAME shared value
-- Phase 1's own view bob is derived from) caps at `MAXBOB = 0x100000` =
-- 16.0 map units -- unlike the view bob's OWN formula (which halves it,
-- `FixedMul(player->bob/2, ...)`, Phase 1's own MAXBOB_UNITS/2
-- derivation), the WEAPON sway uses the FULL, un-halved value, a
-- genuinely LARGER peak swing than the view bob's own.
--
-- Unlike world movement (no principled DOOM-map-unit-to-world-px
-- conversion exists, CLAUDE.md), this value does NOT need proportional
-- rescaling: `psp->sx`/`psp->sy` live in the SAME virtual 320x200
-- psprite-space this file's own `drawSprite`/`spritePosition` already
-- faithfully ports at 1:1 scale (`SPRITE_SX_BASE = 1` IS literally
-- DOOM's own `FRACUNIT` baseline at this canvas's native resolution,
-- confirmed against real extracted sprite offsets in that section's own
-- header comment) -- so DOOM's real 16.0-unit peak carries over as a
-- literal 16 VIRTUAL pixels, not a guessed or rescaled placeholder (this
-- file's own previous version used a flat, always-on 2px sway with no
-- real derivation behind it -- replaced here).
local WEAPON_BOB_PEAK = 16.0

function Actions.weaponReady()
  if player.pendingweapon or not DoomWeapons.playerAlive() then
    setPsprite(WEAPONS[player.readyweapon].downstate)
    return
  end
  if player.attackHeld then
    if not player.attackdown or not NEEDS_FRESH_PRESS[player.readyweapon] then
      player.attackdown = true
      fireWeapon()
      return
    end
  else
    player.attackdown = false
  end
  -- the weapon's own bob/sway cycle -- A_WeaponReady's OWN rate
  -- (128 fine-angle-units per DOOM tic), a different cycle from
  -- P_CalcHeight's view bob (FINEANGLES/20 per tic, ported in Phase 1's
  -- lib/DoomView.lua) -- read fresh from source here, not reused from
  -- that derivation, since they are genuinely two different constants.
  --
  -- No `*(35/60)` conversion belongs here, unlike most other DOOM-tic
  -- constants ported in this file: THIS function doesn't run once per
  -- real 60Hz frame at all -- it's the READY state's own `action`,
  -- called by `setPsprite` exactly once per DOOM-tic-equivalent (the
  -- READY states' own `domTics = 1`, converted to ~1.71 real frames per
  -- call by `ticsFor`'s own accumulator, i.e. ~35 calls/sec -- already
  -- DOOM's real cadence). Multiplying by an ADDITIONAL 35/60 here was a
  -- genuine bug (found after the user compared this port's sway speed
  -- directly against real DOOM gameplay footage and reported it visibly
  -- slower): the sway advanced at only (35/60) of its real angular rate,
  -- ~58% too slow, since the call frequency was already correct and
  -- didn't need re-deriving a second time. Advancing by the raw per-tic
  -- amount every call reproduces DOOM's real angular rate exactly (35
  -- calls/sec * perTic radians/call == DOOM's own 35 tics/sec * perTic
  -- radians/tic).
  local FINEANGLES = 8192
  local perTic = 128 * (2 * math.pi / FINEANGLES)
  player.swayPhase = (player.swayPhase + perTic) % (2 * math.pi)
  -- `player->bob`'s own real magnitude, as a 0..1 fraction of its cap
  -- (`DoomMove.bobFraction()` -- Phase 9 gives this mod real momentum to
  -- compute DOOM's real formula from, where before there was none to
  -- read at all). Zero while standing still, matching DOOM's own real
  -- behavior exactly (this file's previous version swayed constantly
  -- regardless of movement, which was never actually faithful).
  local bob = DoomMove.bobFraction() * WEAPON_BOB_PEAK
  player.swayX = bob * math.cos(player.swayPhase)
  -- `angle & (FINEANGLES/2-1)` in DOOM's own BAM units is `angle mod
  -- FINEANGLES/2` -- FINEANGLES/2 corresponds to pi radians here, so the
  -- SAME masking is `swayPhase % pi`. Halving the angle's own period
  -- this way (not halving the AMPLITUDE) is what gives DOOM's weapon its
  -- real, recognizable figure-eight sway -- sy completes two full bounce
  -- cycles for every one sx side-to-side swing, and since sine over
  -- 0..pi never goes negative, the weapon only ever bounces DOWN from
  -- its raised resting position, never up past it, matching the classic
  -- DOOM bob exactly rather than a generic side-to-side wobble.
  player.swayY = bob * math.sin(player.swayPhase % math.pi)
end

-- A_ReFire (p_pspr.c:343-362)
function Actions.refire()
  if player.attackHeld and not player.pendingweapon and DoomWeapons.playerAlive() then
    player.refire = player.refire + 1
    fireWeapon()
  else
    player.refire = 0
    checkAmmo()
  end
end

-- A_Lower (p_pspr.c:384-416). LOWERSPEED is FRACUNIT*6 (p_pspr.c:44) map
-- units per tic, over a WEAPONBOTTOM(128)-WEAPONTOP(32) = 96-unit travel
-- (p_pspr.c:47-48) -- there's no principled DOOM-map-unit conversion
-- (CLAUDE.md), so this is ported as a NORMALIZED 0..1 fraction of that
-- same travel, moving 6/96 of it per DOOM tic.
--
-- FIX 2026-08-08 (Phase 24 audit, Tier 1 #6) -- this used to carry an
-- additional `*(35/60)` factor, the EXACT bug `Actions.weaponReady`'s
-- own header comment (above) already documents finding and fixing for
-- the sway constant, on this file's own sibling `*DOWN`/`*UP` states
-- (`PISTOLDOWN = { domTics = 1, action = "lower", next = "PISTOLDOWN" }`
-- -- the identical self-looping `domTics = 1` shape as the READY states
-- that comment is about). Since `Actions.lower`/`.raise` are ALSO only
-- ever called once per DOOM-tic-equivalent (~35 calls/sec, already
-- DOOM's real cadence, via the same `ticsFor`-driven `setPsprite`
-- accumulator), the extra `*(35/60)` was a second, uncorrected instance
-- of the identical double-conversion bug: raise/lower traversed its full
-- 0..1 range in ~0.784 real seconds instead of DOOM's real `96/6` units
-- at 35 tics/sec = ~0.457s -- a confirmed 1.71x-too-slow weapon
-- raise/lower on every weapon switch. `phases/phase-5-fire-rate.md`'s
-- own earlier "not a bug" verdict on this constant only ever ruled out
-- a global 2x error; it never independently re-measured raise/lower
-- speed the way the sway bug was, so it never caught this. Removed the
-- extra factor -- the call cadence already supplies it, same as sway.
local LOWER_STEP = 6 / 96
local RAISE_STEP = LOWER_STEP

function Actions.lower()
  player.psp.sy = math.min(1, player.psp.sy + LOWER_STEP)
  if player.psp.sy < 1 then return end
  -- The real dead-player branch this comment used to flag as unported
  -- ("no death system yet") -- now real, Phase 15
  -- (phases/phase-15-player-death.md): `if (player->playerstate ==
  -- PST_DEAD) { psp->sy = WEAPONBOTTOM; return; }` (p_pspr.c:398-402) --
  -- once dead, the weapon stays fully lowered forever; `P_BringUpWeapon`
  -- is never called again. Without this branch, a dead player's weapon
  -- would cycle forever: `Actions.weaponReady` already sends it down
  -- while `not DoomWeapons.playerAlive()`, but this function used to
  -- always raise it right back up the instant it finished lowering,
  -- which would have shown as a nonstop up/down weapon animation the
  -- moment real death first became possible.
  if not DoomWeapons.playerAlive() then return end
  player.readyweapon = player.pendingweapon or player.readyweapon
  player.pendingweapon = nil
  bringUpWeapon()
end

-- A_Raise (p_pspr.c:422-441)
function Actions.raise()
  player.psp.sy = math.max(0, player.psp.sy - RAISE_STEP)
  if player.psp.sy > 0 then return end
  setPsprite(WEAPONS[player.readyweapon].readystate)
end

-- A_Light1 / A_Light0 / A_Light2 (p_pspr.c:761-774): DOOM sets
-- player->extralight, a sector-brightness boost for the muzzle-flash
-- frame. This mod has no equivalent lighting hook, so what actually
-- matters for this port -- the muzzle flash being VISIBLE while a
-- ps_flash state is active, and not once LIGHTDONE ends it -- is already
-- exactly what player.flash.state tracks; these three only exist so the
-- state tables' `action` fields have something to call, matching DOOM's
-- own shape. A_Light2 specifically is real, missing content, not an
-- afterthought: several Phase 3 flash chains (shotgun/super shotgun/
-- chaingun/missile/BFG's *FLASH2 states) reference it, and its absence
-- was a confirmed crash caught by the user's own playtest ("attempt to
-- call a nil value" on Actions.light2) -- Phase 2 only ever needed
-- light1/light0 since the pistol's own flash chain has just one stage.
function Actions.light1() end
function Actions.light0() end
function Actions.light2() end

-- ------- the shot: P_BulletSlope + P_GunShot + A_FirePistol
-- (p_pspr.c:598-662)
--
-- P_GunShot's spread: `angle += (P_Random()-P_Random())<<18` when not
-- `accurate`. P_Random is 0..255, so the extreme case is 255<<18 =
-- 66,846,720 BAM units out of a 32-bit (2^32) full turn = 5.6 degrees --
-- triangularly distributed (a difference of two uniforms), same shape
-- `math.random()-math.random()` produces, so that expression scaled by
-- this same 5.6-degree extreme is a faithful reproduction, not a guess.
-- A_FirePistol calls it with `accurate = !player->refire` -- the FIRST
-- shot of a volley is always dead-on; only auto-fire from holding the
-- trigger through A_ReFire adds spread.
local MAX_SPREAD = math.rad(5.6)

DoomWeapons.RANGE = 220 -- world px -- matches the host's own HordeGun.RANGE

-- Real DOOM's own MELEERANGE, ported to this engine's own reference
-- points rather than a proportional conversion of `DoomWeapons.RANGE`
-- (see the "------- melee (fist, chainsaw)" section further down this
-- file for the full derivation/bug history) -- declared HERE, not next
-- to `Actions.punch`/`Actions.saw` where it's actually used, so
-- `hitscan()` (below) can compare a shot's own `opts.range` against it
-- directly instead of needing a separate `opts.melee` boolean flag
-- (FIX 2026-08-19, project-wide readability audit: the two used to be
-- redundant -- every real melee call site set both fields to the same
-- effect).
local MELEE_RANGE = 24

-- The terrain occlusion test, restated against the same "a wall is a
-- cell whose ground stands taller than the ray is here" rule the host's
-- own HordeGun.lua uses for its (private, unexported) local `occlusion`
-- function -- not reused directly since it isn't exposed, restated
-- against the same public VoxelScene.groundAt seam that function itself
-- calls.
local function terrainRange(map, r, maxRange)
  local step = 3
  local t = step
  while t <= maxRange do
    local x = r[1] + r[4] * t
    local y = r[2] + r[5] * t
    local z = r[3] + r[6] * t
    local cx, cy = math.floor(x / 16), math.floor(z / 16)
    if not map:inBounds(cx, cy) then return t end
    local gh = DoomGround.heightAt(map, cx, cy)
    if y < gh - 0.5 or y < 0 then return t end
    t = t + step
  end
  return maxRange
end

-- ------- target resolution -- the generic seam Phase 6 fills in
--
-- Phase 8 populated this with `overworldNpcResolver` (lib/DoomKill.lua);
-- Phase 6's own re-audit (2026-08-06) found it damage-blind (a resolver
-- only ever got `(ow, r, maxT)`, no damage number) -- fine for overworld
-- NPCs' own real one-shot-kill design, wrong for anything that tracks
-- real HP. Extended the SAME call the same day, once the user answered
-- Phase 6's own open coexistence question directly ("yes pkdoom's doom
-- weapons should damage horde modes mobs"): every resolver now also
-- receives the real damage this specific hit/shot rolled, as a 4th
-- argument -- backward compatible, since `overworldNpcResolver`'s own
-- 3-argument signature simply never reads it. Each resolver is tried in
-- order against the same ray/max-range the terrain occlusion already
-- computed; the first one that answers wins.
DoomWeapons.targetResolvers = {}

function DoomWeapons.registerTargetResolver(fn)
  table.insert(DoomWeapons.targetResolvers, fn)
end

-- ------- area-of-effect resolution -- rocket splash / BFG spray, the
-- other half of the same 2026-08-06 gap: DoomWeapons.hitscan/updateProjectiles
-- above only ever resolve a SINGLE straight ray against a SINGLE best
-- target, which fits a direct hit but not a splash/spray that can reach
-- several targets from one shot. A resolver here gets one `event` table
-- describing the real explosion (`kind = "radius"` for the rocket's real
-- P_RadiusAttack, `kind = "spray"` for the BFG's real A_BFGSpray) and
-- owns finding/damaging every target itself -- the caller (explodeProjectile,
-- below) only ever knows the explosion's own real physical parameters,
-- never what kinds of things exist in the world to apply them to.
DoomWeapons.aoeResolvers = {}

function DoomWeapons.registerAoeResolver(fn)
  table.insert(DoomWeapons.aoeResolvers, fn)
end

-- FIXED 2026-08-07 -- user report: "the projectiles the player shoots
-- do not fire from the barrel of the gun and therefore miss many of the
-- shots it takes that would make it in the original doom." Real DOOM's
-- own `P_SpawnPlayerMissile` (p_mobj.c:934-987) auto-aims the VERTICAL
-- slope of every shot via `P_AimLineAttack` -- essential since vanilla
-- DOOM has no mouselook at all, so a level-only shot could never
-- otherwise hit anything whose center isn't exactly at the shooter's
-- own fixed eye height. `FirstPerson.pitch` is deliberately forced to 0
-- at all times while PKDOOM MODE is on (`lib/DoomView.lua`'s own
-- `lockPitch`, matching DOOM's real fixed-forward view) -- meaning
-- every shot here travelled perfectly level with NO auto-aim to
-- compensate, unlike real DOOM. Against this mod's own open,
-- terrain-varied world (unlike DOOM's own typically level combat
-- floors), a shot whose height stayed fixed at the SHOOTER's own local
-- ground+eye height routinely sailed over or under a target standing on
-- different terrain, or a floating Cacodemon -- exactly the real,
-- confirmed cause of "shots that would hit in real DOOM are missing
-- here," not really a "wrong barrel position" so much as "no vertical
-- aim assist at all."
--
-- Adapted (CLAUDE.md's "Nature of the port" -- functional result, not a
-- code transplant) rather than literally ported: DOOM's own real
-- `P_AimLineAttack` walks its BSP and a traced LINE against actual
-- thing/line geometry, three tries at 0°/+5.625°/-5.625° (net) off the
-- player's own real angle -- this engine has no BSP trace to reuse, so
-- this instead scans every live demon (`DoomDemons.aimTargets`) and
-- citizen NPC (`ow.npcs`) within a real angular cone of the shooter's
-- CURRENT yaw and weapon range, picks the CLOSEST one, and returns the
-- pitch needed to hit its own real vertical center -- or nil if nothing
-- qualifies, the same real "just aim dead level" fallback
-- `P_SpawnPlayerMissile` itself uses once its own three tries all come
-- up empty.
--
-- CORRECTED 2026-08-07 -- this was widened to 20 degrees on the theory
-- that this engine's own forgiving cylinder hit-test needed a wider
-- search than DOOM's own thin traced line to find "real, reasonable
-- targets" a true DOOM-width search would have caught. That reasoning
-- traded away the actual real-DOOM behavior it was supposed to adapt:
-- the direct, repeated, and user-tested complaint ("i tested in doom
-- original in freelook and no freelook. the projectiles go where the
-- player is aiming... THE PROJECTILES SHOULD GO WHERE THE PLAYER IS
-- AIMING, WHICH IT ISNT DOING") is exactly what a 20-degree search
-- produces: a demon standing up to 20 degrees off the crosshair can
-- still steal the shot's vertical aim, which reads as "not going where
-- I'm looking" even though the shot did hit something. Real DOOM's own
-- search never reaches anywhere near that wide -- its outermost try is
-- 5.625 degrees off the player's true angle, full stop (`P_AimLineAttack`
-- callers, p_pspr.c:601-619/p_mobj.c:934-963, `1<<26` of a 32-bit angle
-- unit). Narrowed to match; a real target dead ahead is still found via
-- the same "closest within cone" scan, just no longer one visibly off
-- to the side.
local AUTOAIM_CONE = math.rad(6)

-- FIXED 2026-08-07 -- user report: "the bullets should be going right
-- in front of the player normally when aiming straight like this, but
-- its going up and down for some reason, like it cant figure out where
-- to go so goes both ways. and bullets are still missing demons but
-- now i cant even see the puff... which means its just shooting
-- somewhere i cant see." A real, serious gap in `consider()` (below):
-- it only ever tested ANGLE (the cone) and flat DISTANCE, never whether
-- anything actually stands between the shooter and the candidate --
-- unlike real DOOM's own `P_AimLineAttack`, which is fundamentally a
-- LINE TRACE through the map's own geometry, so it can never even see a
-- target on the other side of a wall in the first place. This function's
-- own angular-cone approximation had no equivalent: a demon behind a
-- wall, around a corner, or in an adjacent room -- fully within the
-- 20-degree cone and weapon range, invisible to the PLAYER but not to
-- this search -- could still win as the CLOSEST candidate and have the
-- shot's own pitch computed toward it, aiming into the wall that's
-- actually in the way. Worse, as that hidden demon (or a different one)
-- moved -- ambient roaming, chasing something else -- which candidate
-- was closest could flip from shot to shot, swinging the computed pitch
-- between two completely different, both-invisible targets: exactly the
-- reported "goes up and down... like it cant figure out where to go."
-- Fixed by reusing `terrainRange` (this file's own real terrain/wall
-- occlusion test, the SAME one the actual fired shot already runs
-- against) as a genuine line-of-sight gate on every candidate BEFORE
-- distance is allowed to make it the pick -- a candidate whose own
-- straight line back to the shooter is blocked by terrain before
-- reaching it is no longer considered at all, matching real DOOM's own
-- line-trace behavior instead of a pure angle/distance guess.
local function hasClearAim(map, originX, originY, originZ, tx, tz, ty, dist)
  local dx, dy, dz = tx - originX, ty - originY, tz - originZ
  local len = math.sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1 then return true end
  local r = { originX, originY, originZ, dx / len, dy / len, dz / len }
  -- A small tolerance below the true distance -- `terrainRange` steps in
  -- 3-unit increments and reports the step it stopped at, not an exact
  -- boundary; requiring it to reach at least `len` minus one step is
  -- enough to distinguish "reached the target" from "stopped short at a
  -- real wall well before it."
  return terrainRange(map, r, len) >= len - 3.5
end

-- FIX 2026-08-09 -- Phase 26 lag audit: same unconditional per-shot
-- `DoomLog.event` gap as `lib/DoomDemons.lua`'s own `demonResolver` (see
-- that file's own `logHitEvent` comment for the full derivation) --
-- called from both `hitscan` (once per pellet, so a shotgun blast is 7
-- calls per trigger pull) and `spawnProjectile`, and the chaingun/
-- plasma rifle fire this repeatedly under automatic fire. Same plain
-- module-local real-time throttle.
local AIM_LOG_INTERVAL = 0.5 -- real seconds
local lastAimLogTime = 0
local function logAimEvent(...)
  local now = love.timer and love.timer.getTime() or 0
  if now - lastAimLogTime < AIM_LOG_INTERVAL then return end
  lastAimLogTime = now
  DoomLog.event(...)
end

-- Gathers ambient-demon candidates (`lib/DoomDemons.lua`'s own real
-- `aimTargets`) into the given `consider` callback. Split out of
-- `computeAutoAimPitch` below, one helper per candidate source, purely so
-- that function reads as "gather from every source, then compute" instead of
-- one long body mixing all three -- no behavior change.
local function considerDemonAimTargets(consider, ow)
  local DD = getDoomDemons()
  if DD and DD.aimTargets then
    local ok, targets = pcall(DD.aimTargets, ow)
    if ok and targets then
      for _, t in ipairs(targets) do
        local gh = DoomGround.heightAt(ow.map, t.cx, t.cy)
        consider(t.x, t.z, gh + (t.height or 56) / 2)
      end
    end
  end
end

-- FEATURE 2026-08-11 -- see `DoomBarrels.aimTargets`'s own header
-- comment for the full derivation: barrels were never part of this
-- search at all until now, a real gap against every other hittable-
-- entity type this function already covers.
local function considerBarrelAimTargets(consider, ow)
  local DB = getDoomBarrels()
  if DB and DB.aimTargets then
    local ok, targets = pcall(DB.aimTargets, ow)
    if ok and targets then
      for _, t in ipairs(targets) do
        local gh = DoomGround.heightAt(ow.map, t.cx, t.cy)
        consider(t.x, t.z, gh + (t.height or 42) / 2)
      end
    end
  end
end

local function considerNpcAimTargets(consider, ow)
  for _, npc in ipairs(ow.npcs or {}) do
    if npc.px and npc.py and npc.cellX and npc.cellY then
      local gh = DoomGround.heightAt(ow.map, npc.cellX, npc.cellY)
      -- FOUND 2026-08-08 -- THE actual root cause of "shots fly above
      -- every NPC/enemy," found after ~20 fix attempts targeting
      -- trajectory (origin height, aim clamp, projectile render anchor)
      -- produced zero visible change -- confirmed by the user's own
      -- direct report that the symptom is IDENTICAL for regular
      -- overworld NPCs, which never touch any of `lib/DoomDemons.lua`'s
      -- own code at all, ruling out every demon-specific fix as the
      -- explanation and pointing at something shared instead.
      --
      -- This aim point used to be a flat `gh + 28`, presented as "half of
      -- this project's own... 56 reference" -- but that 56 was never
      -- actually this NPC's own real rendered height; it was borrowed
      -- from nowhere verified. The real number already exists, one file
      -- over: `lib/DoomKill.lua`'s own `NPC_CARD_WORLD_HEIGHT = 16`,
      -- calibrated directly from "a standing NPC's own real billboard
      -- height" (that constant's own comment) -- i.e. a live NPC's card
      -- renders from `gh+0` (feet) to `gh+16` (top of head), full stop.
      -- `gh + 28` was never the center of that card -- it's 12 world
      -- units ABOVE the very TOP of the sprite, aiming at empty air a
      -- Baron-of-Hell's-height above a Pokémon-sized NPC's own head,
      -- on every single shot, regardless of how correct the trajectory
      -- math computing the PATH to that point became. This is why the
      -- projectile-anchor fix (2026-08-08, earlier this round) changed
      -- nothing visible: it corrected the bolt's own render position by
      -- a couple world units, but the AIM TARGET itself was still tens
      -- of units too high before that fix ever ran. Real center-mass for
      -- a 16-unit-tall card is `gh + 8`, not `gh + 28`.
      consider(npc.px + 8, npc.py + 8, gh + 8)
    end
  end
end

local function computeAutoAimPitch(ow, originX, originY, originZ, yaw, range)
  if not (ow and ow.map) then return nil end
  local best, bestDist

  local function consider(tx, tz, centerY)
    local dx, dz = tx - originX, tz - originZ
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 1 or dist > range then return end
    -- `atan2(dx, dz)` is the real inverse of this file's own
    -- `sin(yaw)*cp, cos(yaw)*cp` forward-vector convention (matching
    -- `FirstPerson.lookDir`'s own identical formula) -- self-consistent
    -- with the direction every shot already fires along.
    local angleTo = math.atan2(dx, dz)
    local diff = (angleTo - yaw + math.pi) % (2 * math.pi) - math.pi
    if math.abs(diff) > AUTOAIM_CONE then return end
    if bestDist and dist >= bestDist then return end
    if not hasClearAim(ow.map, originX, originY, originZ, tx, tz, centerY, dist) then return end
    bestDist, best = dist, { dist = dist, y = centerY }
  end

  considerDemonAimTargets(consider, ow)
  considerBarrelAimTargets(consider, ow)
  considerNpcAimTargets(consider, ow)

  -- EXTENDED 2026-08-07 -- part of the user's own broader "add as many
  -- logs as would help diagnose issues" request. This exact function
  -- was the site of two separate, real, hard-to-spot bugs found THIS
  -- session (the pitch sign inversion just below, and the missing
  -- line-of-sight gate in `consider()` above) -- both were only found
  -- by reading this function's own math by hand after a vague symptom
  -- report ("sometimes misses," "goes up and down"). A permanent record
  -- of what this function actually picked, and why, turns that same
  -- class of report into a direct read instead of a fresh investigation
  -- each time.
  if not best then
    logAimEvent("AIM", "[%s] no target found (cone=%.0f deg, range=%.0f) -- falling back to camera pitch",
      player.readyweapon, math.deg(AUTOAIM_CONE), range)
    return nil
  end
  -- FIXED 2026-08-07 -- user report: "doesnt seem like the bullets are
  -- actually hitting enemies when theyre in line of sight sometimes."
  -- This engine's own real pitch convention (confirmed fresh against
  -- the host's own `FirstPerson.lua`: `PITCH_UP = -50deg`, `PITCH_DOWN =
  -- +70deg`, and its own `lookDir()`'s matching `dy = -sin(pitch)`) is
  -- NEGATIVE pitch = look UP, POSITIVE = look DOWN. This function used
  -- to return `atan2(best.y - originY, best.dist)` -- POSITIVE whenever
  -- the target's own aim point is ABOVE the shooter's eye (the ordinary
  -- case for most demons, whose center-mass typically sits above a
  -- crouched first-person eye height, more so for taller ones) -- which
  -- is exactly backwards: a positive pitch aims DOWN, so a shot at a
  -- target standing above eye level was aimed BELOW it instead, a clean
  -- whiff despite correct targeting/facing/line-of-sight. A target
  -- below eye level got the opposite error (aimed above instead of
  -- below). Near-eye-level targets had little enough vertical error to
  -- still land by luck/hit-radius tolerance -- exactly the "sometimes"
  -- shape of the report, not an always-miss. This sign error was never
  -- exercised before this session's own auto-aim work landed: pitch
  -- previously stayed hard-locked at 0 the whole time PKDOOM MODE is
  -- on (no vertical aim assist existed at all), so `sin(pitch)`'s own
  -- sign never mattered until a real, nonzero, computed pitch value
  -- started being used. Negated to match the confirmed real convention.
  --
  -- FIXED 2026-08-07 -- user report: "projectiles still arent coming
  -- out of the barrel correctly," with a screenshot showing two plasma
  -- bolts hanging uselessly high in the sky, nowhere near the target.
  -- The log for that exact fight (`[AIM] target at dist=24.0
  -- targetY=55.0 originY=13.0 -> pitch=-60.2 deg`, fired point-blank at
  -- a Cyberdemon, `targetY=55` being that roster's own real aim-point)
  -- confirmed it: this raw `atan2` result was NEVER clamped to a
  -- physically real look angle. Round 1 of this fix clamped to this
  -- engine's own real CAMERA look-range (`FirstPerson.PITCH_UP=-50deg`/
  -- `.PITCH_DOWN=70deg`) -- a real, working improvement (confirmed by
  -- the user's own follow-up log: every clamped shot near a Cyberdemon
  -- landed as a hit), but the user's NEXT report, with a fresh
  -- screenshot of the exact same symptom (two plasma bolts floating
  -- high above a demon group), showed it wasn't enough: at close range
  -- against a tall target, even a -50-degree shot still travels mostly
  -- UP (`sin(50deg)=0.766` vertical vs `cos(50deg)=0.643` forward) for
  -- its whole real flight distance before ever converging on the
  -- target's own hit-band, which reads as "flying into the sky" even
  -- though the hit-test technically succeeds eventually. Root cause:
  -- the camera's own look-range was never actually the right reference
  -- value in the first place -- it bounds what a PLAYER'S OWN CAMERA
  -- can physically show, not what real DOOM's own auto-aim was ever
  -- willing to search. Re-checked `P_AimLineAttack` (p_map.c:1020-1054)
  -- fresh: it hard-codes its own real vertical search window to
  -- `topslope = 100*FRACUNIT/160`, `bottomslope = -100*FRACUNIT/160`
  -- (that function's own comment: "can't shoot outside view angles") --
  -- a SLOPE, not a look-angle, `atan(100/160)` ~= 32.005 degrees, well
  -- inside (not equal to) the camera's own -50/+70 range. `PTR_AimTraverse`
  -- (p_map.c:870-886) confirms this window is a hard reject/clamp on
  -- the search itself, not a post-hoc display cap: a candidate target
  -- outside it is never even considered a hit ("shot over/under the
  -- thing," lines 874-880), and any candidate that IS hit still has its
  -- own returned `aimslope` clamped into this exact window (lines
  -- 883-886) -- i.e. real DOOM itself NEVER fires a shot steeper than
  -- ~32 degrees off level, regardless of how close or tall the target
  -- is; a real player standing directly under a Cyberdemon in actual
  -- DOOM would see their own shot cap out at this same shallow angle
  -- and simply undershoot the target's real center, not swing the
  -- barrel up to track it. Replaced the borrowed camera-range clamp
  -- with this real, narrower, DOOM-sourced one.
  local AIMSLOPE_LIMIT = math.atan(100 / 160) -- P_AimLineAttack's own real topslope/bottomslope, p_map.c:1039-1040
  -- REMOVED 2026-08-08 -- the tighter `VISUAL_AIMSLOPE_LIMIT=10deg` added
  -- 2026-08-07 (see git history / BUGS.md for its own full derivation)
  -- was a compensating patch for a problem that has SINCE been found and
  -- fixed at its actual root: `doSpawnProjectile` was feeding this
  -- function an origin height (`MUZZLE_HEIGHT=5`, a purely visual
  -- barrel-alignment constant) instead of the real eye-height
  -- (`FirstPerson.EYE_HEIGHT=13`) that `hitscan` always correctly used.
  -- That made every target look ~8-23 world units higher than it really
  -- was relative to the shooter, inflating the needed pitch on every
  -- shot -- the 10-degree clamp only hid the symptom by chopping the
  -- (already-wrong) angle down.
  --
  -- Fresh log evidence AFTER that origin-height fix, from a real fight
  -- against a Baron of Hell at close range (`targetY=32.0 originY=13.0`,
  -- `dist=30.4`): `pitch=-10.0 deg (clamped)` on every single shot,
  -- each one exploding with `reason=wall` well short of the target
  -- (`traveled=21.0` of a possible ~34 units to reach it) -- the ORIGIN
  -- HEIGHT is now correct, but the 10-degree clamp is now the thing
  -- forcing every close-range, elevated shot to undershoot into
  -- nearby geometry instead of ever reaching a real, correctly-computed
  -- target angle. This reads visually as "the shot doesn't reach the
  -- enemy" / "stops short in the air" -- the same family of symptom as
  -- the original "shooting above everything" report, just from the
  -- opposite direction (the clamp cutting a now-correct angle down,
  -- rather than an inflated angle needing to be cut down).
  --
  -- With the real root cause fixed, the extra clamp no longer protects
  -- against anything -- restored to trusting the real DOOM constant
  -- above (~32 degrees, `P_AimLineAttack`'s own real search window) as
  -- the only bound, matching what `hitscan` (pistol/shotgun/chaingun)
  -- has used successfully the whole time.
  local pitch = -math.atan2(best.y - originY, best.dist)
  local clamped = false
  if pitch < -AIMSLOPE_LIMIT then pitch, clamped = -AIMSLOPE_LIMIT, true end
  if pitch > AIMSLOPE_LIMIT then pitch, clamped = AIMSLOPE_LIMIT, true end
  logAimEvent("AIM", "[%s] target at dist=%.1f targetY=%.1f originY=%.1f -> pitch=%.1f deg%s",
    player.readyweapon, best.dist, best.y, originY, math.deg(pitch), clamped and " (clamped)" or "")
  return pitch
end

-- Fires one shot along the current view direction. Returns whatever a
-- registered resolver returned (nil if none did, including "no resolvers
-- registered yet" -- Phase 2's own state, honestly).
-- opts: { yawSpread, pitchSpread (radians, default 0), damage (default
-- 0) }. Generalized from the pistol-only version so shotgun/super-
-- shotgun/chaingun can each supply their own real DOOM spread/damage
-- rather than the one fixed pistol constant.
function DoomWeapons.hitscan(opts)
  opts = opts or {}
  local Game = require("src.core.Game")
  local ow = Game.overworld
  if not (ow and ow.player and ow.map) then return nil end
  local yaw = FirstPerson.yaw
  if opts.yawSpread and opts.yawSpread > 0 then
    yaw = yaw + (math.random() - math.random()) * opts.yawSpread
  end
  local pl = ow.player
  local gh = DoomGround.heightAt(ow.map, pl.cellX, pl.cellY)
  local originX, originY, originZ = pl.px + 8, gh + FirstPerson.EYE_HEIGHT, pl.py + 8
  -- Real auto-aim (see this function's own header comment above) --
  -- searched along the shooter's TRUE current yaw (not this specific
  -- pellet's own spread angle, matching real DOOM's own
  -- `P_AimLineAttack(player->mo, angle, ...)` using the player's real
  -- facing, not a per-pellet spread).
  --
  -- FIXED 2026-08-07 -- this used to fall back to `FirstPerson.pitch`
  -- when no target qualified, on the theory that this mod's own
  -- `lockPitch()` (`lib/DoomView.lua`) keeps that field at 0 the whole
  -- time PKDOOM MODE is on, so it should be a harmless no-op. Re-reading
  -- `P_BulletSlope`/`P_SpawnPlayerMissile` fresh (p_pspr.c:601-619,
  -- p_mobj.c:934-963) shows real DOOM's own fallback is NOT "whatever
  -- the shooter's current look angle happens to be" -- it's an explicit,
  -- unconditional `slope = 0` the instant all 3 search tries fail,
  -- independent of anything else. Reading a shared, mutable field here
  -- instead of that hard constant is also a real, if currently
  -- dormant, hazard: it silently depends on `lockPitch()` having
  -- already run THIS frame before the shot fires, which frame-ordering
  -- doesn't actually guarantee on every possible tick (mode just
  -- enabled, just unpaused, etc.). Ported the real, unconditional
  -- fallback directly instead of relying on a separate system to keep
  -- an indirect one correct.
  -- FEATURE 2026-08-10 -- direct user request: "for freelook, instead
  -- of always shooting whats in front of the player, the bullets
  -- follows the viewport/gun direction instead because you can fine
  -- aim at enemies theres no need for helping aim, just like gzdoom."
  -- Real DOOM's own auto-aim (`P_BulletSlope`/`P_AimLineAttack`) exists
  -- ONLY because vanilla DOOM has no vertical look at all -- confirmed
  -- real GZDoom behavior (a later source port WITH real mouselook,
  -- gzdoom-master, the project's own real secondary DOOM-fact
  -- authority): once a player can actually aim the camera vertically,
  -- autoaim becomes optional assist, not a hard requirement, and firing
  -- straight along the real look direction is the expected default for
  -- anyone with precise manual aim. `Options.freelookEnabled()` is
  -- exactly that real signal in this mod -- while it's on, this shot
  -- fires along the camera's own LIVE `FirstPerson.pitch` (already the
  -- same real sign convention this whole pitch pipeline already uses,
  -- confirmed by `computeAutoAimPitch`'s own matching convention) with
  -- NO auto-aim search at all, matching GZDoom's real behavior exactly.
  -- LOCKED (freelook off) keeps this mod's own existing auto-aim
  -- behavior completely unchanged -- this project's aim/trajectory math
  -- has its own long, hard-won debugging history (CLAUDE.md's own "20
  -- fix attempts" corollary), so the existing path is left untouched
  -- rather than risking it for the case that doesn't need it.
  local pitch
  if Options.freelookEnabled() then
    pitch = FirstPerson.pitch
  else
    pitch = computeAutoAimPitch(ow, originX, originY, originZ, FirstPerson.yaw,
                                 opts.range or DoomWeapons.RANGE) or 0
  end
  if opts.pitchSpread and opts.pitchSpread > 0 then
    pitch = pitch + (math.random() - math.random()) * opts.pitchSpread
  end
  local cp = math.cos(pitch)
  local r = {
    originX, originY, originZ,
    math.sin(yaw) * cp, -math.sin(pitch), math.cos(yaw) * cp,
  }
  local maxT = terrainRange(ow.map, r, opts.range or DoomWeapons.RANGE)
  local hit
  -- Each resolver pcall'd individually (2026-08-06 robustness fix, see
  -- this file's own install() comment) -- one bad resolver degrades to
  -- "found nothing" instead of stopping the others, or the caller, cold.
  for _, resolver in ipairs(DoomWeapons.targetResolvers) do
    local ok, got = pcall(resolver, ow, r, maxT, opts.damage or 0, player.readyweapon)
    if ok and got then hit = got break end
  end
  -- FEATURE 2026-08-07 -- user request: "bullet impacts should render
  -- just as they do in doom with the paticle effects and textures on
  -- the wall afterwards." Real `PTR_ShootTraverse` (p_map.c:948-971,
  -- the `hitline:` case) spawns a real bullet puff (`P_SpawnPuff`)
  -- whenever a shot is stopped by a WALL rather than a shootable
  -- target -- confirmed genuinely missing from this mod entirely.
  -- `maxT < requested range` is this project's own real signal for
  -- "terrain stopped it" (`terrainRange`'s own real contract, above --
  -- it only ever returns short of the full requested range when
  -- bounds/floor/ceiling actually blocked the ray, never as a
  -- coincidence of running out of distance) -- backed off a couple of
  -- world px toward the shooter first, matching real DOOM's own
  -- identical "position a bit closer... so the puff doesn't skip the
  -- flash" real reasoning, just not the same literal 4-DOOM-unit figure
  -- (no principled conversion exists, same as every other undreived
  -- distance in this project). `opts.range == MELEE_RANGE` (true only
  -- for `Actions.punch`/`Actions.saw`'s own real calls) mirrors real
  -- DOOM's own `attackrange == MELEERANGE` check -- see `lib/
  -- DoomPuff.lua`'s own header comment for why that changes the real
  -- starting frame.
  if not hit and maxT < (opts.range or DoomWeapons.RANGE) then
    local backoff = math.max(0, maxT - 2)
    -- FIX 2026-08-11 -- user report: a shot that hit nothing landed its
    -- own puff at "ground level or ceiling level... not the same
    -- vertical level as the player." Root cause: `wy` (the ray's own
    -- REAL termination height, `r[2] + r[5]*backoff` -- already
    -- computed as part of this same ray) was never extracted here at
    -- all, only its X/Z -- see `lib/DoomPuff.lua`'s own `makePuffEntity`
    -- header comment for the full render-contract derivation this
    -- closes. Now threaded through so the puff renders at the shot's
    -- own true 3D impact point, not wherever `groundAt` happens to
    -- resolve for that cell.
    local wx, wy, wz = r[1] + r[4] * backoff, r[2] + r[5] * backoff, r[3] + r[6] * backoff
    pcall(DoomPuff.spawn, ow, wx, wz, opts.range == MELEE_RANGE, wy)
  end
  return hit
end

-- damage = 5*(P_Random()%3+1) -- shared by pistol, shotgun (once per
-- pellet), chaingun, and super shotgun -- P_GunShot/P_LineAttack all use
-- the same roll.
local function hitscanDamage()
  return 5 * math.random(1, 3)
end

-- ------- per-weapon asset cache (sprite + sound)
--
-- Generalized from Phase 2's pistol-only version, now that Phase 3 has
-- 8 weapons' worth of lump names to look up instead of one. Re-checked
-- only when DoomWadImport's own status actually changes (not every
-- frame/shot), same reasoning as the original.
local assetCache = {}
local lastAssetWadState = nil

local function weaponAsset(cacheKey, nameSubstring, loader)
  if DoomWadImport.status.state ~= lastAssetWadState then
    lastAssetWadState = DoomWadImport.status.state
    assetCache = {}
  end
  local hit = assetCache[cacheKey]
  if hit ~= nil then return hit or nil end
  local value = false
  if lastAssetWadState == "ready" then
    local ok, got = pcall(loader, nameSubstring)
    if ok and got then value = got end
  end
  assetCache[cacheKey] = value
  return value or nil
end

-- Returns { image, left, top } -- left/top are the sprite's REAL DOOM
-- offsets (DoomWadImport.loadSpriteAsset, which reads wadext's own `grAb`
-- PNG chunk -- the WAD's real spriteoffset/spritetopoffset per lump,
-- confirmed present by direct inspection of an actual extracted PNG, not
-- assumed lost as Phase 4's original notes wrongly guessed).
local function weaponSpriteAsset(nameSubstring)
  return weaponAsset("sprite:" .. nameSubstring, nameSubstring, DoomWadImport.loadSpriteAsset)
end

local function weaponSound(nameSubstring)
  return weaponAsset("sound:" .. nameSubstring, nameSubstring, DoomWadImport.loadSound)
end

-- Plays the real extracted sound if the WAD import found one, else the
-- given fallback (nil is fine -- silence rather than force a fallback
-- that doesn't fit every weapon).
local function playWeaponSound(nameSubstring, fallbackFn)
  local snd = weaponSound(nameSubstring)
  if snd then
    DoomWadImport.playClone(nameSubstring, snd) -- clone: a held trigger can overlap two shots
  elseif fallbackFn then
    pcall(fallbackFn)
  end
end

function Actions.firePistol()
  if not Options.infiniteAmmoEnabled() then
    player.ammo.clip = (player.ammo.clip or 0) - 1
  end
  setFlashPsprite("PISTOLFLASH")
  DoomWeapons.hitscan({
    yawSpread = player.refire > 0 and MAX_SPREAD or 0,
    damage = hitscanDamage(),
  })
  playWeaponSound("DSPISTOL", function() Host.require("HordeSfx").shot() end)
end

-- ------- melee (fist, chainsaw)
--
-- BUG, found and fixed 2026-08-06 (user report: "the chainsaw and fists
-- do not work"): this used to be `DoomWeapons.RANGE / 32`, applying real
-- DOOM's own MELEERANGE/MISSILERANGE ratio (`p_local.h:57-58`: 64*FRACUNIT
-- / (32*64*FRACUNIT) = 1/32) to `DoomWeapons.RANGE` -- but that constant
-- was never itself a proportional DOOM-map-unit conversion in the first
-- place; its own comment says plainly it "matches the host's own
-- HordeGun.RANGE," an independently-tuned value borrowed from a
-- DIFFERENT system's own feel. Applying a real DOOM RATIO on top of an
-- UNRELATED anchor compounds two different reference frames that don't
-- actually correspond to the same real-world scale, and the result --
-- 220/32 = 6.875 world px -- is barely more than point-blank once the
-- player's own collision radius (`FreeMove.RADIUS = 5.5`) and a target's
-- own `HIT_RADIUS` (6-10px) are accounted for, meaning a punch or
-- chainsaw swing almost never actually connects even standing right next
-- to something.
--
-- Fixed by anchoring MELEE_RANGE the way this project's OTHER "no
-- principled unit conversion" values already are (CLAUDE.md's own
-- "Nature of the port"): against this engine's own real reference
-- points instead of a borrowed, unrelated constant -- a target's own
-- `HIT_RADIUS` (`lib/DoomKill.lua`'s NPC resolver: 6px; `lib/
-- DoomHordeTarget.lua`'s Horde-mob resolver: 6px; `lib/DoomDemons.
-- lua`'s demon resolver: 10px) plus a full 16px cell, so melee reliably
-- connects against anything standing in an adjacent cell -- comparable
-- to real DOOM's own MELEERANGE genuinely exceeding a typical demon's
-- radius by 2-3x, not barely reaching its own edge. (`MELEE_RANGE`
-- itself is declared up near `DoomWeapons.RANGE` now, not here -- see
-- that declaration's own header for why.)

-- A_Punch: (P_Random()%10+1)<<1 = 2,4,...,20. A_Saw: 2*(P_Random()%10+1)
-- -- the same formula restated, so both weapons share this roll
-- (p_pspr.c:476, :510).
local function meleeDamage()
  return math.random(1, 10) * 2
end

function Actions.punch()
  DoomWeapons.hitscan({
    yawSpread = MAX_SPREAD, damage = meleeDamage(), range = MELEE_RANGE,
  })
  playWeaponSound("DSPUNCH")
end

-- A_Saw plays sfx_sawful on a miss, sfx_sawhit on a connect (p_pspr.c
-- :518-524) -- real, already working against overworld NPCs (Phase 8's
-- own resolver, `lib/DoomKill.lua`), correctly picking DSSAWHIT/DSSAWFUL
-- below off whatever `hit` actually comes back. Stale comment removed
-- here (Phase 6's own re-audit, 2026-08-06) -- this used to say the
-- registry was still empty and every swing played the miss sound; it
-- hasn't been true since Phase 8 landed.
function Actions.saw()
  local hit = DoomWeapons.hitscan({
    yawSpread = MAX_SPREAD, damage = meleeDamage(), range = MELEE_RANGE,
  })
  playWeaponSound(hit and "DSSAWHIT" or "DSSAWFUL")
end

-- ------- shotguns and chaingun
--
-- A_GunFlash (p_pspr.c:449-455), minus the player-mobj animation line:
-- sets the flash psprite to the current weapon's own flashstate. Used
-- directly by the rocket launcher/BFG states below (their own STATES
-- entries reference it by name), not just here.
function Actions.gunFlash()
  local flash = WEAPONS[player.readyweapon].flashstate
  if flash then setFlashPsprite(flash) end
end

-- A_FireShotgun (p_pspr.c:668-688): 7 pellets, EACH always spread
-- (P_GunShot's own `false` "accurate" argument -- a shotgun blast is
-- never dead-on, unlike the pistol/chaingun's first-shot accuracy).
function Actions.fireShotgun()
  if not Options.infiniteAmmoEnabled() then
    player.ammo.shell = (player.ammo.shell or 0) - 1
  end
  setFlashPsprite("SGUNFLASH1")
  for _ = 1, 7 do
    DoomWeapons.hitscan({ yawSpread = MAX_SPREAD, damage = hitscanDamage() })
  end
  playWeaponSound("DSSHOTGN")
end

-- A_FireShotgun2 (p_pspr.c:696-726): 20 pellets, each a direct
-- P_LineAttack rather than P_GunShot, with a WIDER horizontal spread
-- A_FireCGun (p_pspr.c:733-754): same P_GunShot/accuracy rule as the
-- pistol (dead-on unless refiring), same damage roll, same DSPISTOL
-- sound (the chaingun has no sound lump of its own -- see phase-3's
-- doc). The one real distinct behavior: which flash state it picks
-- alternates with which of the two fire frames (CHAIN1/CHAIN2) is
-- current (`flashstate + (psp->state - &states[S_CHAIN1])` in the
-- original) -- tracked here by which STATE name called this action,
-- since player.psp.state IS that name at the moment the action runs.
function Actions.fireCGun()
  if not Options.infiniteAmmoEnabled() then
    if (player.ammo.clip or 0) <= 0 then return end
    player.ammo.clip = player.ammo.clip - 1
  end
  setFlashPsprite(player.psp.state == "CHAIN2" and "CHAINFLASH2" or "CHAINFLASH1")
  DoomWeapons.hitscan({
    yawSpread = player.refire > 0 and MAX_SPREAD or 0,
    damage = hitscanDamage(),
  })
  playWeaponSound("DSPISTOL")
end

-- ------- projectiles (rocket launcher, plasma rifle, BFG)
--
-- Unlike every weapon above, these don't fire an instant ray -- DOOM
-- spawns a MOVING object (P_SpawnPlayerMissile) that travels at a fixed
-- speed and explodes on whatever stops it first. mobjinfo's own speed
-- values (info.c, MT_ROCKET/MT_PLASMA/MT_BFG): 20/25/25 map-units per
-- DOOM tic. There is no principled way to carry DOOM map units into this
-- engine's world px (CLAUDE.md's locked decisions already say so for
-- movement speed and view bob) -- the speeds below are a judgment call
-- tuned against this mod's OWN existing motion references (Free Movement
-- mode's WALK_TOP/RUN_TOP, since removed from scope but still the last
-- reference point this project derived -- see git history), not a
-- formula dressed up to look derived. Bumped up from run speed enough
-- that a rocket clearly outruns the player, matching how obviously fast
-- DOOM's own rockets read.
--
-- FIXED 2026-08-06 -- the "KNOWN GAP" this comment used to describe
-- (Phase 2, then Phase 5's own "polish" backlog item) is closed. The
-- diagnosis it made was correct for what existed AT THE TIME -- there
-- really is no seam for a third-party mod to inject a depth-composited
-- object into `VoxelScene.lua`'s own internal `drawScene` pass -- but a
-- LATER, different technique this project itself went on to discover
-- and use successfully (`lib/DoomKill.lua`'s gibs, Phase 8; `lib/
-- DoomItems.lua`'s world pickups, Phase 13; `lib/DoomDemons.lua`'s
-- demons, Phase 21) never needs that seam at all: a synthetic entity
-- with its own `pose()`/`draw()`, pushed into `ow.entities`, already
-- rides the EXISTING real 3D voxel pass (`posesOf` -> `drawEntity` ->
-- `SpriteBillboards.mesh`) that every real NPC/entity already goes
-- through -- no reach into `VoxelScene.drawScene` needed at all. This
-- comment was simply never revisited once that technique existed. Per
-- the user's own explicit request (2026-08-06, Phase 23's own visual-
-- effects audit): "the proejctiles that come out of player weapons...
-- should be feature parity 1:1" -- applied below the exact same way.
DoomWeapons.projectiles = {}

-- Real DOOM's own visible sprite per projectile, read fresh from
-- `info.c`'s state tables (`S_ROCKET`/`S_EXPLODE1-3` lines 250,263-265;
-- `S_PLASBALL`/`S_PLASBALL2`/`S_PLASEXP`-`5` lines 243-249;
-- `S_BFGSHOT`/`S_BFGSHOT2`/`S_BFGLAND`-`6` lines 251-258), audited fresh
-- in `phases/phase-23-visual-effects-parity.md`. All three sprite
-- families are `FF_FULLBRIGHT` (frame values >=32768 in the real state
-- table) -- always full brightness regardless of ambient light, ported
-- via the same `trueColor=true` synthetic-def idiom every other fake
-- entity in this project already uses (a real DOOM fullbright frame has
-- no ambient-light dependency to begin with, so this isn't a
-- simplification, it's the literal real behavior).
--
-- `flightLetters`/`flightTics`: the real in-flight animation -- Rocket
-- is a SINGLE static frame (real DOOM has no rocket spin animation at
-- all, confirmed by its own 1-frame self-looping state), Plasma/BFG
-- both ping-pong 2 frames. `explodeLetters`/`explodeTics`: the real
-- impact sequence, uniform tics per frame here (this project's own
-- established simplification for animation clocks, `lib/DoomDemons.lua`'s
-- own precedent, rather than porting DOOM's own actual per-frame tic
-- counts which differ frame to frame in the real state table).
--
-- STATED SIMPLIFICATION: BFG's own real impact ALSO spawns 40 small
-- `SPR_BFE2`-sprite puffs, one at each of `A_BFGSpray`'s own 40 ray
-- endpoints (`p_pspr.c`, already ported for damage in
-- `explodeProjectile` below) -- not ported visually here; only the
-- single main "splat" animation at the impact point (`SPR_BFE1`, real
-- DOOM's own `S_BFGLAND` chain) is. Spawning 40 additional short-lived
-- visual entities per BFG shot was judged excessive for this mod's own
-- scope; flagged here rather than silently dropped.
local PROJECTILE_VISUAL = {
  ROCKET = {
    prefix = "MISL", flightLetters = { "A" }, flightTics = 4,
    explodeLetters = { "B", "C", "D" }, explodeTics = 6,
  },
  PLASMA = {
    prefix = "PLSS", flightLetters = { "A", "B" }, flightTics = 6,
    explodePrefix = "PLSE", explodeLetters = { "A", "B", "C", "D", "E" }, explodeTics = 4,
  },
  BFG = {
    prefix = "BFS1", flightLetters = { "A", "B" }, flightTics = 4,
    explodePrefix = "BFE1", explodeLetters = { "A", "B", "C", "D", "E", "F" }, explodeTics = 8,
  },
}

-- `baseDamage` is each projectile's own real `mobjinfo.damage` field
-- (info.c: MT_ROCKET=20, MT_PLASMA=5, MT_BFG=100) -- real DOOM's own
-- direct-hit-on-a-thing formula, `PIT_CheckThing` (p_map.c:277):
-- `damage = ((P_Random()%8)+1) * tmthing->info->damage` -- a flat 1-8
-- dice roll times this base, computed at the point of a direct hit below
-- (Phase 6's own re-audit, 2026-08-06 -- this number was never actually
-- computed before; a direct projectile hit reached a resolver with no
-- damage value at all, harmless while the only resolver was the
-- overworld NPC one-shot-kill, a real gap once Horde mobs track HP).
local PROJECTILE = {
  ROCKET = { speed = 6.0, splash = true,   deathSound = "DSBAREXP", baseDamage = 20 },
  PLASMA = { speed = 7.5, splash = false,  deathSound = "DSFIRXPL", baseDamage = 5 },
  BFG    = { speed = 7.5, splash = "spray", deathSound = "DSRXPLOD", baseDamage = 100 },
}

local function missileHitDamage(kind)
  return math.random(1, 8) * (PROJECTILE[kind].baseDamage or 0)
end

-- The visible entity a flying/exploding projectile rides -- same real
-- shape `lib/DoomDemons.lua`'s own `makeDemonEntity` already uses
-- (`passable`, a no-op `:draw()` for the classic 2D path, a real
-- `:pose()` for the voxel path). `proj.px`/`.py`/`.cellX`/`.cellY` are
-- kept LIVE, re-synced every tick from the outside (`updateProjectiles`
-- below) -- NOT frozen at construction the way an earlier version of
-- `lib/DoomDemons.lua`'s own entity once was, a real bug (fixed
-- 2026-08-06, see that file's own header comment on it) that sent a
-- moving entity floating into the sky once its OWN stale `.py`/`.cellX`/
-- `.cellY` drifted far enough from its CURRENT position -- avoided here
-- from the start by applying that same fix's lesson up front.
--
-- Vertical placement is the one genuinely new wrinkle a flying
-- projectile has that a ground-walking demon/gib/item never did: the
-- render pipeline's own real `lift` value (`VoxelScene.lua`'s `posesOf`,
-- `lift = e.py - vy`) is normally a SMALL ledge-hop/surf-bob arc on top
-- of the ground height it separately looks up via `e.cellX`/`e.cellY` --
-- here it's repurposed to carry the projectile's own full real height
-- ABOVE the ground at its current cell (`proj.y - gh`), computed fresh
-- each `pose()` call the same way `posesOf` itself would, so the two
-- agree.
--
-- FOUND 2026-08-07 -- THE actual root cause of the "left/right of the
-- barrel, flips with facing direction" report, after the yaw-lag fix
-- above did NOT resolve it (confirmed by the user's own fresh
-- screenshots showing the same symptom). Traced by comparing this
-- function directly against `lib/DoomDemons.lua`'s own PROVEN-correct
-- `makeDemonEntity` (real demons render in the exact right place, every
-- session) rather than re-guessing at spawn math a further time.
--
-- `DramaticShapeVoxelMod-dev/lib/VoxelScene.lua`'s own `posesOf`
-- (:519-527) takes an entity's X position from `pose()`'s own 2nd return
-- value, and its Z position from the entity's raw `.py` FIELD directly
-- (`py = e.py`, NOT from `pose()`'s return at all) -- both then get a
-- SINGLE `+8` added uniformly by `billboardMatrix`
-- (`VoxelScene.lua:289`: `Mat4.translate(px + 8, y, py + 8)`), which only
-- produces the right on-screen center if what's fed in was a raw CORNER
-- coordinate (`cellX*16`-style, unshifted) -- confirmed by
-- `makeDemonEntity` itself (`lib/DoomDemons.lua:877`: `px = m.px, py =
-- m.py`, its OWN raw corner-based fields, `pose()` returning them
-- completely unmodified) and by real player/NPC position fields sharing
-- that exact same corner convention project-wide (confirmed earlier this
-- session).
--
-- THIS function instead set `entity.px`/`.py` to `proj.x`/`proj.z`
-- directly -- but `proj.x`/`proj.z` are ALREADY center-adjusted at spawn
-- (`pl.px + 8, pl.py + 8`, deliberately matching the CAMERA's own real
-- eye-position formula so the projectile's real GAMEPLAY position lines
-- up with the shooter's actual eye) -- so the render pipeline's own
-- uniform `+8` was landing on a value that already HAD one, double-
-- applying it: the visible mesh rendered a full (+8, +8) world px off
-- from the projectile's real logical position in BOTH X and Z. A fixed
-- WORLD-SPACE diagonal offset like that is invisible to hit detection
-- (which reads `proj.x`/`.y`/`.z` directly, never the render-only
-- `entity.px`/`.py`) -- consistent with shots still occasionally
-- connecting despite reading as visually wrong -- and, critically, a
-- FIXED world offset viewed from a ROTATING camera renders dead-on from
-- exactly the one facing where that offset happens to point straight
-- ahead, and swings increasingly to one side (mirrored on either side of
-- that direction) as the camera turns away from it -- exactly, and
-- fully, the reported symptom. Fixed by storing/resyncing
-- `entity.px`/`.py` as the real corner value (`proj.x - 8`, `proj.z - 8`)
-- instead, matching `makeDemonEntity`'s own proven contract exactly, so
-- the pipeline's single `+8` is the only one ever applied. `cellX`/
-- `cellY` are UNCHANGED (still floored from the true `proj.x`/`proj.z`,
-- not the corner-shifted display value) -- cell lookups should reflect
-- the projectile's real position, not its render-only offset. The
-- height/`lift` math (`vy` below) needs no change at all: `lift = e.py -
-- vy` is self-canceling for ANY value of `e.py` (confirmed algebraically
-- this session), so it was never affected by this bug either way.
-- DIAGNOSTIC, added 2026-08-07 per CLAUDE.md's own new rule ("a bug
-- that survives one fix attempt gets logging before a second attempt is
-- made"). Every position/direction/mesh-centering formula in the actual
-- spawn/render chain has now been independently re-verified correct
-- against source (including full object-identity tracing: `ow.player`
-- IS `state.player` IS what the camera's own `me.px` reads, no copy, no
-- interpolation) -- the one remaining, NOT yet checked possibility is
-- that the projectile's own raw WAD sprite image has real, non-zero
-- transparent padding on one side (a genuine per-sprite asset property,
-- not a formula bug), which `buildDemonMesh`'s shared billboard builder
-- would currently render centered on the PIXEL BOUNDING BOX rather than
-- DOOM's own real per-sprite anchor point (`leftoffset`/`topoffset`,
-- confirmed extracted and preserved by wadext, but currently only READ
-- for the 2D weapon HUD -- `DoomWadImport.loadSpriteAsset` -- never for
-- this shared 3D mesh builder, which uses the offset-less `loadImage`
-- instead). Logs the real numbers ONCE per unique sprite frame so the
-- next report carries hard data instead of another screenshot guess: if
-- `leftoffset` is small relative to the image's own width, this isn't
-- it; if it's a large fraction of the width, it very likely is.
local loggedSpriteOffsets = {}
local function logSpriteOffsetOnce(prefix, letter)
  local key = prefix .. letter
  if loggedSpriteOffsets[key] then return end
  loggedSpriteOffsets[key] = true
  local ok, asset = pcall(DoomWadImport.loadSpriteAsset, prefix .. letter)
  if ok and asset and asset.image then
    local iw, ih = asset.image:getDimensions()
    DoomLog.event("PROJ", "sprite %s%s: image width=%d height=%d, real WAD leftoffset=%d topoffset=%d",
      prefix, letter, iw, ih, asset.left, asset.top)
  end
end

-- ADDED 2026-08-08 -- diagnostic for the vertical-anchor fix, per
-- CLAUDE.md's own logging rule; prints the exact real-world-unit
-- half-height each unique projectile sprite frame is now being shifted
-- down by, so a future report can directly confirm this fix is actually
-- in the build being tested rather than guessing from visual impression
-- alone.
local loggedWorldHeights = {}
local function logWorldHeightOnce(prefix, letter, worldH)
  local key = prefix .. letter
  if loggedWorldHeights[key] then return end
  loggedWorldHeights[key] = true
  DoomLog.event("PROJ", "sprite %s%s: real worldH=%.2f, vertical-center shift=%.2f world px",
    prefix, letter, worldH or -1, (worldH or 0) / 2)
end

local function makeProjectileEntity(proj)
  local entity
  entity = {
    passable = true,
    px = proj.x - 8, py = proj.z - 8,
    cellX = math.floor(proj.x / 16), cellY = math.floor(proj.z / 16),
    draw = function() end,
    pose = function()
      local visual = PROJECTILE_VISUAL[proj.kind]
      local exploding = proj.exploding
      local letters = exploding and visual.explodeLetters or visual.flightLetters
      local prefix = exploding and (visual.explodePrefix or visual.prefix) or visual.prefix
      local letter = letters[proj.animIndex] or letters[1]
      -- BUG FIX 2026-08-12 -- `DD.loadSprite` used to be indexed straight
      -- into `pcall`'s own argument list with no nil-check on `DD` first
      -- (`pcall(DD.loadSprite, ...)`, `DD` possibly nil straight off
      -- `getDoomDemons()`) -- that field lookup happens while evaluating
      -- pcall's arguments, i.e. BEFORE pcall's protection starts, so a nil
      -- `DD` would throw uncaught out of this per-frame render callback.
      -- Guarded the same nil-checked way every OTHER lazy cross-module call
      -- site in this file already does.
      local DD = getDoomDemons()
      local image
      if DD and DD.loadSprite then
        local okImg, got = pcall(DD.loadSprite, prefix, letter)
        if okImg then image = got end
      end
      pcall(logSpriteOffsetOnce, prefix, letter)
      local spriteObj = {
        def = {
          pokedoomProjectile = true, pokedoomCacheKey = prefix .. letter,
          pokedoomImage = image, trueColor = true, image = "pokedoom-proj-" .. prefix,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      local gh = DoomGround.heightAt(proj.ow.map, entity.cellX, entity.cellY)
      -- FOUND 2026-08-08 -- the actual structural cause of "projectiles
      -- land above enemies," reported as present on every shot regardless
      -- of aim/pitch (confirmed: ~20 fix attempts, all targeting the
      -- TRAJECTORY, produced zero visible change) -- because this bug
      -- lives entirely in RENDERING, a system none of those fixes ever
      -- touched. `buildDemonMesh` (`lib/DoomDemons.lua`) builds every
      -- billboard quad from LOCAL y=0 (bottom edge) to y=worldH (top
      -- edge) -- correct for a walking demon/NPC, whose own real logical
      -- position IS its feet -- and this function's own `lift` math (see
      -- this function's own header comment; `y = gh + lift` in
      -- `VoxelScene.lua`'s `drawEntity`, confirmed by reading that
      -- function directly) places that LOCAL y=0 exactly at the
      -- projectile's own real logical height (`proj.y`). For a demon
      -- that's correct. For a FLYING projectile, `proj.y` is meant to
      -- read as the bolt's own CENTER, not its lowest visible pixel --
      -- so every projectile has been rendering with its entire sprite
      -- (up to its own real `worldH`, several world units for the larger
      -- explode frames) stacked ABOVE its true position, a constant,
      -- aim-independent bias -- exactly what the user's own screenshots
      -- kept showing no matter how the trajectory math changed. Shifts
      -- the render anchor down by half the sprite's own real world
      -- height so its vertical CENTER, not its bottom edge, lands on
      -- `proj.y`. `DoomDemons.worldHeightFor` (new export, same round)
      -- reuses the exact ratio math `buildDemonMesh` itself uses, so
      -- this always agrees with whatever the mesh actually built.
      local halfWorldH = 0
      if image then
        local okH, worldH = pcall(DD.worldHeightFor, prefix, image)
        if okH and worldH then
          halfWorldH = worldH / 2
          pcall(logWorldHeightOnce, prefix, letter, worldH)
        end
      end
      local vy = entity.py - (proj.y - gh - halfWorldH)
      return spriteObj, entity.px, vy, "down", 0, false
    end,
  }
  return entity
end

local function removeProjectileEntity(ow, proj)
  proj.inserted = false
  if not (proj.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == proj.entity then table.remove(ow.entities, i) break end
  end
  proj.entity = nil
end

-- `SpriteBillboards.mesh` wrap, the same idiom `lib/DoomDemons.lua`'s
-- own `installDemonMeshHook` already uses for its own fake entities --
-- a SEPARATE wrap with this file's own marker (`pokedoomProjectile`),
-- not a reuse of the demon one's `pokedoomDemon` flag (a projectile
-- isn't a demon; sharing that flag would work mechanically but reads
-- wrong) -- reuses `DoomDemons.mesh`'s own real cache/build logic
-- directly instead, since that function is generic (builds a billboard
-- card sized to whatever image it's given) despite its name.
local installedProjectileMeshHook = false
local function installProjectileMeshHook()
  if installedProjectileMeshHook then return end
  installedProjectileMeshHook = true
  local SpriteBillboards = Host.require("SpriteBillboards")
  local inner = SpriteBillboards.mesh
  SpriteBillboards.mesh = function(def, frame)
    if def and def.pokedoomProjectile then
      -- BUG FIX 2026-08-12 -- same nil-guard gap as `makeProjectileEntity`'s
      -- own `pose()` above: `DD.mesh` used to be indexed straight into
      -- `pcall`'s argument list with no check that `DD` (`getDoomDemons()`)
      -- is actually non-nil first, which would throw uncaught out of this
      -- render-pipeline hook -- a much worse failure mode than a single bad
      -- resolver, since this wrap runs for every rendered frame, not just a
      -- weapon fire.
      local DD = getDoomDemons()
      if not (DD and DD.mesh) then return nil end
      local ok, mesh = pcall(DD.mesh, def.pokedoomCacheKey, def.pokedoomImage)
      if ok then return mesh end
      return nil
    end
    return inner(def, frame)
  end
end

-- FIXED 2026-08-07 -- user report, repeated across several rounds of
-- prior fixes that all turned out correct but insufficient ("still not
-- coming out the barrel... need to be down more... sometimes it comes
-- from different directions like to the left and up instead of just
-- up"). Two real, separate problems, both traced to this function's own
-- spawn point sharing the EXACT SAME world position as the camera's own
-- eye (`pl.px+8, gh+FirstPerson.EYE_HEIGHT, pl.py+8` -- literally
-- `FirstPerson.lua`'s own real eye position, `FirstPerson.EYE_HEIGHT=
-- 13`, confirmed by reading that file directly):
--
-- 1. HEIGHT: real DOOM's own `P_SpawnPlayerMissile` (p_mobj.c:969-971)
--    spawns a missile at `source->z + 4*8*FRACUNIT` = 32 map units above
--    the shooter's own FEET -- measurably LOWER than that same player's
--    real `VIEWHEIGHT` (p_local.h:34: `41*FRACUNIT`, also measured from
--    the feet) -- DOOM's own missile launch point is genuinely below eye
--    level, closer to chest/gun height, never AT the eye the way this
--    port's own previous formula placed it.
--
--    CORRECTED 2026-08-07 -- the previous round scaled this project's
--    own `FirstPerson.EYE_HEIGHT` by the real 32/41 DOOM ratio
--    (`MISSILE_SPAWN_RATIO`), presenting it as a re-derived DOOM fact.
--    That number is real, but it answers a DIFFERENT question than the
--    one this line actually needs: 32 map units is DOOM's own HIT-
--    DETECTION height for its flat, fixed-point 320x200 raycaster --
--    CLAUDE.md's own "Nature of the port" section is explicit that this
--    kind of figure has no principled mapping onto THIS engine's
--    real-time 3D screen position, and re-deriving it harder doesn't
--    change that. The user's own direct comparison (a real DOOM
--    screenshot vs. this mod's own, "coming out EXACTLY out of the
--    barrel, not slightly above it like it is now") confirmed the old
--    ratio (~10.1 world units, 78% of `EYE_HEIGHT`) still renders
--    visibly above the drawn 2D weapon viewmodel's own barrel tip.
--    `MUZZLE_HEIGHT` below is therefore a plain, explicitly-tunable
--    world-unit constant, not a DOOM-ratio derivation -- lowered from
--    the old ~10.1 result; if it still doesn't visually line up, this is
--    the one value to nudge, not something to re-derive from source
--    again.
-- 2. DIRECTION JITTER: not a DOOM fact at all -- there is no DOOM source
--    describing THIS engine's own perspective-projected billboard
--    renderer -- but a real, genuine consequence of (1): a sprite
--    rendered at (or extremely near) the viewing camera's own exact
--    position is a degenerate case for ANY perspective projection
--    (screen position is dominated by floating-point noise as depth
--    approaches 0), which independently explains the reported
--    left/up/detached jitter even on frames where the aim math itself
--    (confirmed correct by prior rounds' own log evidence) was dead
--    accurate. Fixed the same way a real gun's own muzzle legitimately
--    isn't AT the eye either: nudge the spawn point a small, fixed
--    distance forward along the shot's own real fire direction before
--    the projectile's very first rendered frame -- matching this file's
--    own established "no principled unit conversion -- pick a small,
--    reference-anchored constant" precedent (`MELEE_RANGE`'s own header
--    comment, anchored to this project's own `HIT_RADIUS`-scale
--    references).
local MUZZLE_HEIGHT = 5 -- world px above ground -- a visual tuning judgment call, see header comment above; NOT a re-derived DOOM ratio
local MUZZLE_FORWARD_OFFSET = 6 -- world px -- pushes the spawn point off the camera's own exact eye position (see header comment above)

-- ADDED then REMOVED (a world-position nudge), then REPLACED with a real
-- angular one, all 2026-08-07. First added as a blind compensating
-- world-position offset at the user's own request after an exhaustive
-- audit (origin X/Z, yaw-to-direction trig, render lift/height formula,
-- shared billboard mesh vertex centering, weapon viewmodel screen
-- position -- ALL independently re-verified correct against source)
-- found no coded bug. Bisecting that position offset against repeated
-- screenshots produced a genuinely contradictory result (a smaller push
-- read as landing further right than a bigger one had) -- the real
-- tell that a WORLD-POSITION offset was the wrong kind of fix: its
-- apparent screen-space size shrinks as the projectile flies farther
-- away (`atan(offset/distance)`), so it could only ever look right at
-- one specific test distance, explaining the inconsistent results
-- directly. A first theory (real DOOM's own walk-bob sway, `player.
-- swayX`, correctly never reaching the missile spawn point) was floated
-- and reverted when the user confirmed the mismatch is present even
-- standing still, with a clean, unobstructed screenshot ruling out
-- window-overlap as a measurement artifact too.
--
-- REAL root cause, found from the plasma rifle's own actual WAD asset
-- data (this file's own `[PROJ] sprite ...` diagnostic log, added per
-- CLAUDE.md's own "log before a second fix attempt" rule): the visible
-- weapon HUD sprite is NOT drawn centered on the camera's true optical
-- axis at all -- it's positioned by `spritePosition` (this file, below)
-- using DOOM's own real per-sprite `leftoffset`, which is whatever the
-- original id Software artist happened to draw it at, not necessarily
-- centered on the sprite's own bounding box. Confirmed with real
-- numbers: `PLSGA` (the plasma rifle's own ready-frame weapon sprite)
-- is `dims=83x61, leftoffset=-123`. Real DOOM's positioning formula
-- (`spritePosition`, this file) draws it from virtual-x `1-(-123)=124`
-- to `124+83=207` -- CENTER 165.5, while true screen center (`VIRTUAL_W
-- /2`) is 160. The plasma rifle's own real gun art sits 5.5 virtual
-- pixels RIGHT of the camera's true axis, baked into the real WAD
-- sprite itself -- not a bug in this port, and not fixable by changing
-- the projectile's spawn math, since that math is independently
-- confirmed correct (the projectile fires exactly along the camera's
-- TRUE axis, which is exactly why it visually diverges from the
-- gun's own off-axis art). A world-position nudge answers the wrong
-- question (matching a screen point) with the wrong tool (a 3D
-- position, whose apparent screen offset changes with distance); this
-- is instead a real angular correction, converted from that WAD-
-- verified 5.5-virtual-pixel screen offset through the camera's own
-- real FOV (`FirstPerson.FOV = math.rad(65)`, vertical; converted to
-- an approximate horizontal FOV via the virtual canvas's own 320:200
-- aspect ratio: `2*atan(tan(65deg/2)*1.6)` ~= 91 degrees), giving
-- `(5.5/320) * 91deg` ~= 1.56 degrees -- applied to the fire DIRECTION
-- (yaw), not the origin position, so the correction stays visually
-- correct at every range instead of only one tested distance. Per
-- CLAUDE.md's new logging rule: this magnitude is a principled
-- estimate from real asset data, not a guess, but the exact FOV
-- conversion (vertical-to-horizontal via an assumed 1.6 aspect) is the
-- one unverified link in this chain -- confirm visually and report back
-- rather than assuming this is exactly right on the first try.
local MUZZLE_YAW_OFFSET = math.rad(1.56) -- see header comment above for the full derivation

-- FIXED 2026-08-07 -- user report, with fresh session logs, precisely
-- describing a NEW symptom the two fixes above didn't touch: "the
-- projectiles do come out of the barrel ONLY WHEN THE PLAYER IS LOOKING
-- IN A CERTAIN DIRECTION. if the player looks to the right of that, the
-- projectiles will start spawning to the left of the barrel, if the
-- player looks to the left of that, the projectiles will spawn to the
-- right of the barrel" -- a real ordering hazard, not a math error.
--
-- This engine's own real per-frame order (confirmed by reading
-- `gen1recomp-dev/src/core/Game.lua`'s `Game:update` fresh): the
-- `"input.step"` hook this mod fires weapon actions from
-- (`Game.lua:187`, inside `Game:step`, itself driven by
-- `FixedStep:update` early in `Game:update`) runs BEFORE
-- `Pipelines.update(dt)` -> `FirstPerson.update(dt)` (`Game.lua:261`),
-- which is the call that actually applies THIS frame's already-
-- accumulated mouse-look delta to `FirstPerson.yaw`
-- (`DramaticShapeVoxelMod-dev/lib/FirstPerson.lua:256-260,462,530-535`).
-- So a shot fired from `input.step` reads last frame's yaw -- one tick
-- stale relative to what the camera (and this file's own weapon sprite,
-- drawn later still) actually shows THIS frame. While turning, that
-- staleness is a real angular error whose sign flips with turn
-- direction, exactly the reported symptom. It's invisible on instant-
-- resolution hitscan shots (`DoomWeapons.hitscan`, pistol/shotgun/
-- chaingun) because those never persist a WORLD-SPACE render position
-- across frames to reveal the drift -- confirmed by checking the host's
-- own `HordeGun.lua`, which reads the exact same possibly-stale
-- `FirstPerson.yaw` (`HordeGun.lua:247-252`) for its own hitscan and
-- never shows this bug for the identical reason (`occlusion`/`pick` both
-- resolve synchronously, `HordeGun.lua:260-311`). A slow, animated
-- PROJECTILE (rocket/plasma/BFG) is exactly the case that DOES persist
-- across frames, so it's the only place this ever became visible.
--
-- Fixed by deferring the actual spawn (not the fire INPUT, which still
-- triggers instantly off `input.step` for responsiveness) to this file's
-- own existing `love.draw` wrap (`install()`, below) -- LÖVE's real
-- per-frame draw callback, which only ever runs AFTER `love.update` (and
-- therefore `Pipelines.update`/`FirstPerson.update`) has already
-- finished for that same frame, so the yaw it reads here is guaranteed
-- current, not stale. This mod already proved `love.draw` is the one
-- hook in this engine guaranteed to run dead last each frame (see that
-- wrap's own header comment, "nothing in the engine or any other mod
-- runs after it") -- reusing that same proven timing guarantee here
-- rather than inventing a new one.
local pendingProjectileSpawns = {}

local function doSpawnProjectile(kind)
  local Game = require("src.core.Game")
  local ow = Game.overworld
  if not (ow and ow.player and ow.map) then return end
  local yaw = FirstPerson.yaw
  local pl = ow.player
  local gh = DoomGround.heightAt(ow.map, pl.cellX, pl.cellY)
  local originX, originY, originZ =
    pl.px + 8, gh + MUZZLE_HEIGHT, pl.py + 8
  -- Real auto-aim -- see `DoomWeapons.hitscan`'s own matching header
  -- comment for the full derivation (`P_SpawnPlayerMissile`,
  -- p_mobj.c:934-963). FIXED 2026-08-07: falls back to a hard `0`
  -- (real DOOM's own unconditional flat-slope fallback), not
  -- `FirstPerson.pitch` -- see the matching fix/comment in
  -- `DoomWeapons.hitscan` above for the full reasoning.
  --
  -- FIXED 2026-08-08 -- user report, sharpened over several rounds:
  -- "instead of being on the same x axis as the player, it goes up
  -- above everything... for every enemy... every npc." Every prior
  -- attempt (tightening `VISUAL_AIMSLOPE_LIMIT`, tuning
  -- `MAX_PROJECTILE_CLIMB`) tuned the CLAMP on the computed pitch and
  -- produced zero measurable change -- the log this round's fix is
  -- based on (`[AIM] target at dist=98.3 targetY=28.0 originY=5.0 ->
  -- pitch=-10.0 deg (clamped)`) proves why: `originY` fed into the aim
  -- search here was `gh + MUZZLE_HEIGHT` (5), while `computeAutoAimPitch`
  -- targets `gh + height/2` (28 for a regular 56-tall demon/NPC) -- a
  -- CONSTANT ~23-unit vertical gap between shooter and target reference
  -- height, present on literally every aimed shot regardless of
  -- distance, which pins the computed pitch at max-steep for any target
  -- within ordinary engagement range. No clamp value could ever fix an
  -- input that's already wrong before the clamp runs.
  --
  -- `DoomWeapons.hitscan` (above) never had this bug: it aims from
  -- `gh + FirstPerson.EYE_HEIGHT` (13) AND fires its own ray from that
  -- exact same origin -- one height, used consistently for both the
  -- search and the actual shot.
  --
  -- FIXED 2026-08-08 -- user report (with screenshot): NPCs now visibly
  -- take zero hits from the plasma rifle -- every shot's own impact mark
  -- lands on the ground right at/below their feet, never on them, while
  -- demons still mostly get hit ("sometimes it can go below demons feet
  -- too in the same way but it actually hits the demons most of the
  -- times"). This is a SEPARATE bug from the one just fixed above this
  -- same round (the auto-aim TARGET height, `computeAutoAimPitch`'s own
  -- `consider(..., gh+8)` calls) -- that fix was correct and is why
  -- demons now register hits at all; this is a second, independent bug
  -- in how the resulting angle gets used.
  --
  -- The line below used to search for a target from `gh +
  -- FirstPerson.EYE_HEIGHT` (13) -- matching `hitscan`'s own convention,
  -- per the (now-reverted) comment this replaces -- but then spawned and
  -- flew the actual projectile from a DIFFERENT, lower origin,
  -- `gh + MUZZLE_HEIGHT` (5, purely a visual/HUD-alignment tuning value,
  -- see that constant's own header comment). That 8-unit gap
  -- (EYE_HEIGHT - MUZZLE_HEIGHT) is invisible to `computeAutoAimPitch`,
  -- which only ever computes an ANGLE (`atan2(targetY - originY, dist)`)
  -- -- a straight line's own slope. Reusing that same angle from a
  -- DIFFERENT, lower starting height doesn't preserve where the line
  -- ends up: for a dead-straight shot (no gravity), height at any
  -- horizontal distance D is `spawnY + D * slope`, and `slope` here was
  -- solved for `eyeY + dist*slope = targetY`, i.e. `dist*slope = targetY
  -- - eyeY`. Substituting the ACTUAL spawn height instead of `eyeY`:
  -- `spawnY + dist*slope = (eyeY - 8) + (targetY - eyeY) = targetY - 8`
  -- -- exactly 8 world units short of the real target height, at the
  -- real target's own distance, on literally every single shot,
  -- independent of range. With this round's own new, correct aim target
  -- (`gh+8`, half of `NPC_CARD_WORLD_HEIGHT`/`DEMON_WORLD_HEIGHT`), that
  -- 8-unit shortfall lands the real trajectory at `gh+8-8 = gh+0` --
  -- GROUND LEVEL -- by the time it's covered ~62.5% of the distance to
  -- the target (`spawnY + d*slope = gh` solves to `d = 0.625*dist`), the
  -- shot has already crashed into the floor and exploded there
  -- (`reason=wall`) well short of ever reaching the target's own
  -- position -- exactly the "explodes on the ground below their feet"
  -- symptom, and why it happens on EVERY shot rather than intermittently
  -- (this is deterministic geometry, not chance). Demons still land hits
  -- most of the time only because `demonResolver`'s own hit-test uses a
  -- wider horizontal radius (10 vs NPCs' 6, `lib/DoomKill.lua`'s
  -- `HIT_RADIUS`) and a taller vertical band, giving the still-descending
  -- shot more per-tick chances to register a hit before it finishes
  -- crashing into the floor -- not because the trajectory itself is
  -- actually correct for demons either (matching the user's own report
  -- that it undershoots demons too, just less fatally).
  --
  -- Fixed by searching for the aim angle from the SAME height the
  -- projectile actually launches from (`gh + MUZZLE_HEIGHT`), so the
  -- solved slope is the one that truly carries THIS shot's own real
  -- starting point through the real target height at the real target
  -- distance -- no separate, unaccounted-for origin-height gap.
  -- FEATURE 2026-08-10 -- same real user request/derivation as
  -- `hitscan`'s own matching change just above: while FREELOOK is on,
  -- a projectile launches along the camera's own real live pitch, no
  -- auto-aim search at all, matching real GZDoom's own mouselook
  -- behavior. LOCKED keeps this file's own existing, extensively-tuned
  -- auto-aim trajectory completely unchanged.
  local pitch
  if Options.freelookEnabled() then
    pitch = FirstPerson.pitch
  else
    pitch = computeAutoAimPitch(ow, pl.px + 8, gh + MUZZLE_HEIGHT, pl.py + 8,
                                 yaw, DoomWeapons.RANGE) or 0
  end
  local cp = math.cos(pitch)
  -- Muzzle-yaw nudge (see MUZZLE_YAW_OFFSET's own header comment above)
  -- -- applied to the fire DIRECTION only, AFTER auto-aim's own search
  -- (which must still center on the true camera axis, where the player
  -- is actually looking/targeting, not the visually-offset gun art).
  --
  -- CORRECTED 2026-08-07, same round -- user tested `yaw +
  -- MUZZLE_YAW_OFFSET` and reported the bolt still landing left, no
  -- change. Rather than re-guess the rotation direction abstractly
  -- again (the same mistake that cost a round on the earlier, now-
  -- removed `MUZZLE_RIGHT_OFFSET` position vector), cross-checked
  -- against the one thing that round's bisection DID empirically prove:
  -- the real "screen right" world vector is `(-cos(yaw), sin(yaw))`,
  -- the negation of the first (wrong) guess. Rotating this file's own
  -- forward vector `(sin(yaw), cos(yaw))` a small angle `d` TOWARD that
  -- proven vector works out algebraically to `(sin(yaw-d), cos(yaw-d))`
  -- -- i.e. the correction is `yaw - MUZZLE_YAW_OFFSET`, not `+`. Flipped
  -- accordingly.
  local fireYaw = yaw - MUZZLE_YAW_OFFSET
  -- Muzzle-forward nudge (see header comment above) -- applied AFTER
  -- pitch is computed (auto-aim itself should still search from the
  -- real, un-offset muzzle origin above, not an already-nudged one) but
  -- BEFORE the projectile's own physics/visual spawn point is fixed, so
  -- every frame this projectile ever renders starts already clear of the
  -- camera's own exact position.
  local fdx, fdy, fdz = math.sin(fireYaw) * cp, -math.sin(pitch), math.cos(fireYaw) * cp
  originX = originX + fdx * MUZZLE_FORWARD_OFFSET
  originY = originY + fdy * MUZZLE_FORWARD_OFFSET
  originZ = originZ + fdz * MUZZLE_FORWARD_OFFSET
  local spec = PROJECTILE[kind]
  -- Added 2026-08-07 -- prior rounds' fixes (auto-aim clamp, entity
  -- position resync) were both confirmed correct by log evidence, yet
  -- the user's own screenshot still showed the same "floating detached
  -- in the sky" symptom -- rather than guess a third time, logging the
  -- actual real spawn/travel numbers so the NEXT report carries hard
  -- data (where it started, which direction, how far it actually got
  -- before impact/despawn) instead of another screenshot-only guess.
  DoomLog.event("PROJ", "spawn %s [weapon=%s]: origin=(%.1f,%.1f,%.1f) dir=(%.2f,%.2f,%.2f) pitch=%.1fdeg yaw=%.1fdeg fireYaw=%.1fdeg",
    kind, player.readyweapon, originX, originY, originZ, fdx, fdy, fdz, math.deg(pitch), math.deg(yaw), math.deg(fireYaw))
  table.insert(DoomWeapons.projectiles, {
    kind = kind, speed = spec.speed, traveled = 0,
    x = originX, y = originY, z = originZ,
    dx = fdx, dy = fdy, dz = fdz,
    ow = ow, animIndex = 1, animTimer = PROJECTILE_VISUAL[kind].flightTics,
  })
end

-- Called from `input.step` (unchanged -- ammo/state-machine timing still
-- needs to be instant) -- just queues the kind. `doSpawnProjectile` above
-- does the actual yaw-dependent work, deferred to `love.draw` by
-- `flushPendingProjectileSpawns` below (see the header comment above
-- `pendingProjectileSpawns` for why).
local function spawnProjectile(kind)
  table.insert(pendingProjectileSpawns, kind)
end

local function flushPendingProjectileSpawns()
  if #pendingProjectileSpawns == 0 then return end
  for _, kind in ipairs(pendingProjectileSpawns) do
    doSpawnProjectile(kind)
  end
  pendingProjectileSpawns = {}
end

-- On impact: DOOM's real P_RadiusAttack (`p_map.c:1201-1233`, NOT
-- `p_inter.c`) is a 128-map-unit blast whose damage falls off LINEARLY
-- with distance and is gated on real line of sight to the blast
-- (`P_CheckSight`) -- ported below as `ROCKET_SPLASH_RADIUS`/
-- `ROCKET_SPLASH_MAX_DAMAGE`, proportionally scaled to this engine's own
-- 16px cells the same "no principled literal-unit conversion" way every
-- other DOOM-map-unit figure in this project already is (CLAUDE.md's
-- "Nature of the port"): DOOM's 128 units / 64 units-per-cell = 2 cells,
-- so 2 * 16px = 32 world px here; the DAMAGE number itself needs no such
-- conversion and stays DOOM's real 128. A_BFGSpray (p_pspr.c:781-811)
-- fans 40 independently aimed rays across a 90-degree arc, each rolling
-- its own real 15d8 damage (15 dice, 1-8 each) only if that specific ray
-- connects.
--
-- Both are real math, applied here via `DoomWeapons.aoeResolvers`
-- (extended into existence 2026-08-06, once the user answered Phase 6's
-- own open question directly: PKDOOM MODE's weapons should damage
-- Horde Mode's own spawned mobs) -- this function only ever describes
-- the explosion's own real physical shape; each registered resolver
-- owns finding and damaging whatever actually exists in the world to
-- receive it. UPDATED 2026-08-08 (per-weapon-damage audit, user
-- request): `lib/DoomHordeTarget.lua`'s own `hordeAoeResolver` was, for
-- a long time, the ONLY one of the three registered AOE resolvers that
-- actually handled BOTH `kind`s -- `lib/DoomDemons.lua`'s own
-- `demonAoeResolver` silently ignored every `spray` event outright (so
-- the BFG did nothing to ambient demons at all), and `lib/DoomKill.lua`
-- registered no AOE resolver whatsoever (so NEITHER rocket splash NOR
-- BFG spray ever did anything to overworld NPCs -- only a direct hit
-- ever killed one). Both fixed the same round; every registered
-- resolver now handles both real `kind`s.
local ROCKET_SPLASH_RADIUS = 32     -- 128 DOOM map units, proportional (see above)
local ROCKET_SPLASH_MAX_DAMAGE = 128 -- DOOM's own real number, no conversion needed

-- CORRECTED 2026-08-07, same day -- a user-provided session log (no
-- coded fix ships without hard data, per CLAUDE.md's own new rule)
-- showed the first version of this cap (150) never once fired
-- (`reason=climb` never appeared anywhere in the log), while several
-- misses still explode-via-wall/range at Y=45-62 above local ground --
-- clearly still reading as "in the sky" in the user's own screenshot,
-- just never reaching 150 before something else (a wall, `RANGE`)
-- caught them first. Real error in the original derivation: it anchored
-- on `CYBERDEMON`'s own FULL `height=110`, but `computeAutoAimPitch`
-- never aims at a target's full height at all -- it aims at
-- `gh + height/2` (`consider()`'s own real formula, above), i.e.
-- center-mass, confirmed by this exact log's own numbers (`targetY=28`
-- for the 56-tall regular roster, `CACODEMON`'s own real aim point
-- likewise at half its own height). The tallest real center-mass aim
-- point in this roster is therefore `CYBERDEMON`'s `110/2 = 55`, not
-- 110 -- a correctly-aimed shot never legitimately needs to climb much
-- past that on its way to a real hit (which resolves in tens of world
-- px of travel per this same log, long before accumulating much height
-- at all -- only a MISS ever flies far enough to matter here). Tightened
-- accordingly, with real margin above 55 but nowhere near the original
-- 150.
local MAX_PROJECTILE_CLIMB = 60 -- world px above local ground

-- BUG FIX 2026-08-12 -- both call sites below used to be
-- `pcall(getDoomView().triggerShake, ...)`: the `getDoomView()` lazy-require
-- call and the `.triggerShake` field lookup both happen while evaluating
-- pcall's OWN arguments, before pcall's protection actually starts, so a nil
-- `DoomView` would throw uncaught. Small shared helper so the nil-check
-- (matching this file's own established `local DD = getDoomX(); if DD and
-- DD.method then pcall(...) end` shape) only needs writing once.
local function triggerScreenShake(intensity, duration)
  local DV = getDoomView()
  if DV and DV.triggerShake then
    pcall(DV.triggerShake, intensity, duration)
  end
end

local function explodeProjectile(proj, ow)
  local spec = PROJECTILE[proj.kind]
  playWeaponSound(spec.deathSound)
  if spec.splash == "spray" and ow then
    local facing = math.atan2(proj.dx, proj.dz)
    for _, resolver in ipairs(DoomWeapons.aoeResolvers) do
      pcall(resolver, ow, {
        kind = "spray", x = proj.x, y = proj.y, z = proj.z,
        facing = facing, arc = math.rad(90), rays = 40,
        diceCount = 15, diceSides = 8,
      })
    end
    -- FEATURE 2026-08-10 -- new "SCREEN SHAKE" on/off row -- the BFG's
    -- own real spray is the biggest single weapon effect in this mod, so
    -- the strongest shake of the two splash types here.
    triggerScreenShake(7, 0.5)
  elseif spec.splash == true and ow then
    for _, resolver in ipairs(DoomWeapons.aoeResolvers) do
      pcall(resolver, ow, {
        kind = "radius", x = proj.x, y = proj.y, z = proj.z,
        radius = ROCKET_SPLASH_RADIUS, maxDamage = ROCKET_SPLASH_MAX_DAMAGE,
      })
    end
    triggerScreenShake(5, 0.4)
  end
end

-- Advances a projectile's own `animIndex` through the given letter list
-- on the given tics-per-frame, looping (Plasma/BFG ping-pong; Rocket's
-- own single-letter flight list just stays put).
local function advanceProjectileAnim(p, letters, tics)
  p.animTimer = (p.animTimer or 0) - 1
  if p.animTimer <= 0 then
    p.animTimer = tics
    p.animIndex = (p.animIndex or 0) % #letters + 1
  end
end

-- FIX 2026-08-09 -- Phase 26 lag audit: the insertion check below used
-- to re-scan all of `ow.entities` every tick per in-flight projectile
-- just to check "am I already inserted" -- a projectile's own entity
-- identity never changes after creation, so this was pure O(projectiles
-- × entities) waste after the first tick, the same pattern independently
-- found and fixed five other places this round (see `lib/DoomKill.lua`'s
-- own `syncGibEntities` for the full derivation). Real `inserted` flag
-- instead, invalidated on a map change for the same defense-in-depth
-- reason every sibling fix carries it, even though this file's own
-- projectiles are short-lived enough that the failure mode may never be
-- reachable in practice.
-- Advances one already-`exploding` projectile's impact animation by one
-- frame, removing it (and its render entity) once that animation finishes.
-- Split out of `updateProjectiles`'s own per-projectile loop below purely to
-- keep that loop body to one real branch per iteration -- no behavior change.
local function advanceExplodingProjectile(ow, projectiles, i, p, visual)
  -- Playing out the real impact animation (`explodeProjectile`
  -- already fired the sound/splash-damage the instant impact
  -- happened, below -- this is purely the visual tail end).
  p.animTimer = (p.animTimer or 0) - 1
  if p.animTimer <= 0 then
    p.animIndex = (p.animIndex or 1) + 1
    if p.animIndex > #visual.explodeLetters then
      removeProjectileEntity(ow, p)
      table.remove(projectiles, i)
    else
      p.animTimer = visual.explodeTics
    end
  end
end

-- Advances one in-flight (not yet `exploding`) projectile by one tick: moves
-- it along its own travel segment, syncs its render entity, then checks
-- terrain/range/target-resolver collision and starts the explosion sequence
-- if any of those triggered this tick. Split out of `updateProjectiles`'s
-- own per-projectile loop below -- this branch alone was the large majority
-- of that loop's real code -- no behavior change.
local function stepFlyingProjectile(ow, p, visual)
  local step = p.speed
  local prevX, prevY, prevZ = p.x, p.y, p.z
  -- AUDITED 2026-08-07 -- direct user request ("audit doom code, and
  -- implement these changes") pointing at two symptoms: projectiles
  -- flying to implausible places instead of stopping at whatever
  -- they hit, and no distinct impact-explosion entity when one hits
  -- a wall. Tracing this function's OWN real logic (not a fresh
  -- symptom guess) found the actual root cause: this loop only ever
  -- checked map bounds, ground height, `DoomWeapons.RANGE`'s own
  -- timeout, and registered ENTITY targets -- there was no wall/
  -- terrain collision check anywhere, at all. A shot that missed a
  -- target near a building, fence, or wall simply passed straight
  -- through solid geometry and kept flying at whatever pitch it
  -- launched with until it timed out at `RANGE` (220 world px) --
  -- which, for a real, correctly-DOOM-clamped auto-aim shot (see
  -- `computeAutoAimPitch`'s own real `atan(100/160)` ~=32 degree
  -- limit, p_map.c:1039-1040), still climbs `220*sin(32deg)` ~= 116
  -- world units above its own spawn point before giving up -- read
  -- exactly as "shooting up at a steep angle into the sky," even
  -- though the actual fired angle never exceeded real DOOM's own
  -- real limit. Real DOOM's own equivalent (`P_XYMovement`'s missile
  -- branch, p_mobj.c:213-217/316/345: a missile blocked by a solid
  -- line calls `P_ExplodeMissile` immediately, the same function
  -- floor/ceiling contact also calls) has no such gap -- it explodes
  -- the instant it's actually blocked, not after however far its own
  -- vertical component happens to carry it. Fixed by reusing
  -- `terrainRange` (this file's own existing wall-occlusion raycast,
  -- already proven by `hasClearAim`'s line-of-sight gate above) for
  -- JUST this frame's own travel segment, exactly like the target-
  -- resolver check just below already does for entity hits -- a
  -- fast projectile can't tunnel through a wall between two frames
  -- any more than it could already tunnel through a target.
  local hitDist = terrainRange(ow.map, { prevX, prevY, prevZ, p.dx, p.dy, p.dz }, step)
  local hitWall = hitDist < step - 0.01
  local travelDist = hitWall and hitDist or step
  p.x, p.y, p.z = prevX + p.dx * travelDist, prevY + p.dy * travelDist, prevZ + p.dz * travelDist
  p.traveled = p.traveled + travelDist
  -- Entity created/synced/inserted UNCONDITIONALLY here, before the
  -- explosion check below -- an instant point-blank impact (exploding
  -- on this very first tick) still needs a real entity in `ow.
  -- entities` for the explosion animation branch above to find and
  -- animate next tick, not just a projectile that survives at least
  -- one full flight frame first.
  advanceProjectileAnim(p, visual.flightLetters, visual.flightTics)
  p.entity = p.entity or makeProjectileEntity(p)
  -- `-8` on both: see `makeProjectileEntity`'s own header comment --
  -- `entity.px`/`.py` must stay the real CORNER value (matching
  -- `makeDemonEntity`'s own proven contract), not the center-adjusted
  -- `p.x`/`p.z` gameplay position, or the render pipeline's own
  -- uniform `+8` double-applies it.
  p.entity.px, p.entity.py = p.x - 8, p.z - 8
  p.entity.cellX, p.entity.cellY = math.floor(p.x / 16), math.floor(p.z / 16)
  if not p.inserted then
    table.insert(ow.entities, p.entity)
    p.inserted = true
  end
  -- FIXED 2026-08-07 -- user report, with fresh [PROJ] log evidence:
  -- "still not on the barrel... except it does come out of the barrel
  -- when facing this certain direction" -- a DIFFERENT symptom from
  -- the barrel-offset fix just above, confirmed by the log itself: a
  -- shot auto-aimed at a real nearby target (e.g. `pitch=-16.3deg`
  -- for a target only 61 units away) that then MISSES (blocked LOS,
  -- moved out of the hit cylinder, etc.) used to keep flying at that
  -- same steep slope all the way to this timeout -- climbing tens of
  -- world units into open sky before finally giving up. The real
  -- root cause of that (this loop having no wall-collision check at
  -- all) is fixed above; `RANGE` remains as the real DOOM
  -- `MISSILERANGE` equivalent -- a last-resort cap for a shot that
  -- genuinely never hits anything solid (fired out over open water,
  -- say), not the thing doing the day-to-day stopping anymore.
  local exploded = hitWall or p.traveled > DoomWeapons.RANGE
  local explodeReason = hitWall and "wall" or nil
  if not exploded then
    local cx, cy = math.floor(p.x / 16), math.floor(p.z / 16)
    if not ow.map:inBounds(cx, cy) then
      exploded, explodeReason = true, "oob"
    else
      local gh = DoomGround.heightAt(ow.map, cx, cy)
      if p.y < gh - 0.5 or p.y < 0 then
        exploded, explodeReason = true, "wall"
      -- AUDITED 2026-08-07 -- direct evidence from a user-provided
      -- session log: a steep, correctly-computed auto-aim shot
      -- (`pitch=-21.8deg`, matching a real nearby target) that
      -- MISSED (target moved/died between pitch computation and
      -- the per-segment hit check, or similar) climbed all the way
      -- to `RANGE`'s own timeout with nothing to stop it. The
      -- wall-collision fix above only helps when something IS in
      -- the way; it does nothing for a miss over open terrain. Real
      -- DOOM's own equivalent limit is a level's own low ceiling
      -- (this mod's outdoor maps have none) -- the faithful stand-in
      -- is a real HEIGHT cap, not a distance one. See
      -- `MAX_PROJECTILE_CLIMB`'s own header comment above for the
      -- full derivation (and its own correction, from a SECOND
      -- user-provided log, once the first magnitude -- anchored on
      -- the tallest demon's FULL height instead of its real
      -- center-mass AIM POINT -- proved too loose to ever fire).
      elseif p.y - gh > MAX_PROJECTILE_CLIMB then
        exploded, explodeReason = true, "climb"
      end
    end
  elseif not hitWall then
    explodeReason = "range"
  end
  -- target-resolver check, same registry every hitscan weapon feeds --
  -- a short ray for just this frame's travel segment, so a fast-moving
  -- projectile can't tunnel through a target between two frames. Real
  -- direct-hit damage (`missileHitDamage`, PIT_CheckThing's own
  -- `(1-8) * mobjinfo.damage` roll) computed once per segment check,
  -- not per resolver -- every weapon's shot deserves the same roll
  -- regardless of which resolver ends up claiming the hit.
  if not exploded and #DoomWeapons.targetResolvers > 0 then
    local segStart = {
      p.x - p.dx * step, p.y - p.dy * step, p.z - p.dz * step,
      p.dx, p.dy, p.dz,
    }
    local dmg = missileHitDamage(p.kind)
    for _, resolver in ipairs(DoomWeapons.targetResolvers) do
      local ok, got, hitT = pcall(resolver, ow, segStart, step, dmg, p.kind)
      if ok and got then
        exploded, explodeReason = true, "entity"
        -- FIX 2026-08-10 -- user report + screenshot: the explosion
        -- sprite rendered BEHIND the target it hit, worst at close
        -- range against a wide-radius demon (a Cyberdemon, real
        -- radius 40). Root cause: `p.x/p.y/p.z` at this point is
        -- wherever the projectile's own full per-tick `step` landed
        -- it (set above, before this hit check even ran), NOT where
        -- it actually crossed the target's hit-cylinder surface --
        -- at close range a single tic's own travel distance can
        -- already carry the projectile well past a wide target's
        -- near-facing surface. Resolvers now optionally return a
        -- second value -- the real ray-vs-circle near-surface entry
        -- point (`lib/DoomDemons.lua`'s own `demonResolver`/`lib/
        -- DoomKill.lua`'s own `overworldNpcResolver`, both updated
        -- the same round for the identical blood-placement bug) --
        -- used here to snap the projectile back to that true impact
        -- point before it explodes, instead of leaving it wherever
        -- its own raw movement happened to stop.
        if hitT then
          p.x = segStart[1] + segStart[4] * hitT
          p.y = segStart[2] + segStart[5] * hitT
          p.z = segStart[3] + segStart[6] * hitT
        end
        break
      end
    end
  end
  if exploded then
    DoomLog.event("PROJ", "explode %s at (%.1f,%.1f,%.1f), traveled=%.1f, reason=%s",
      p.kind, p.x, p.y, p.z, p.traveled, explodeReason or "?")
    explodeProjectile(p, ow)
    p.exploding = true
    p.explodeReason = explodeReason
    p.animIndex = 1
    p.animTimer = visual.explodeTics
  end
end

local lastPlayerProjectileEntitiesMapId = nil
local function updateProjectiles(ow)
  local projectiles = DoomWeapons.projectiles
  if ow.map.id ~= lastPlayerProjectileEntitiesMapId then
    for _, p in ipairs(projectiles) do p.inserted = false end
    lastPlayerProjectileEntitiesMapId = ow.map.id
  end
  for i = #projectiles, 1, -1 do
    local p = projectiles[i]
    local visual = PROJECTILE_VISUAL[p.kind]
    if p.exploding then
      advanceExplodingProjectile(ow, projectiles, i, p, visual)
    else
      stepFlyingProjectile(ow, p, visual)
    end
  end
end

-- A_FireMissile / A_FirePlasma (p_pspr.c:550-589): neither explicitly
-- plays a sound in the original -- MT_ROCKET/MT_PLASMA's own "seesound"
-- (rlaunc/plasma) fires automatically the moment P_SpawnMobj creates
-- them, which is what spawnProjectile's caller below reproduces the
-- EFFECT of (a launch sound on firing), even though the real call site
-- is implicit rather than inside these two action functions.
function Actions.fireMissile()
  if not Options.infiniteAmmoEnabled() then
    player.ammo.misl = (player.ammo.misl or 0) - 1
  end
  spawnProjectile("ROCKET")
  playWeaponSound("DSRLAUNC")
end

function Actions.firePlasma()
  if not Options.infiniteAmmoEnabled() then
    player.ammo.cell = (player.ammo.cell or 0) - 1
  end
  setFlashPsprite(math.random() < 0.5 and "PLASMAFLASH1" or "PLASMAFLASH2")
  spawnProjectile("PLASMA")
  playWeaponSound("DSPLASMA")
end

-- A_BFGsound (p_pspr.c:817-823): the charge-up hum while BFG1 holds
function Actions.bfgSound()
  playWeaponSound("DSBFG")
end

-- A_FireBFG (p_pspr.c:563-570): MT_BFG's own seesound is 0 (silent spawn
-- -- the charge-up hum above is the only sound DOOM actually plays here),
-- so no playWeaponSound call belongs in this one.
function Actions.fireBFG()
  if not Options.infiniteAmmoEnabled() then
    player.ammo.cell = (player.ammo.cell or 0) - 40
  end
  spawnProjectile("BFG")
end

-- ------- per-frame tick (P_MovePsprites, p_pspr.c:851-877)

local function movePsprites()
  if player.psp.state then
    player.psp.tics = player.psp.tics - 1
    if player.psp.tics == 0 then
      setPsprite(STATES[player.psp.state].next)
    end
  end
  if player.flash.state then
    player.flash.tics = player.flash.tics - 1
    if player.flash.tics == 0 then
      setFlashPsprite(FLASH_STATES[player.flash.state].next)
    end
  end
end

-- ------- weapon switching (number keys -- d_items.c's weapon slots)
--
-- Now gated on `player.weaponowned` (Phase 13) -- real DOOM never lets
-- you switch to a weapon you don't have in the first place (there is no
-- separate "reject" branch to port; the vanilla status bar/weapon-key
-- handling simply never offers an unowned slot), so refusing here is
-- this port's own equivalent of that absence, not an invented rule.
local function selectWeapon(name)
  if not (name and WEAPONS[name]) or name == player.readyweapon then return end
  if not player.weaponowned[name] then return end
  if player.pendingweapon == name then return end
  player.pendingweapon = name
end

-- FEATURE 2026-08-11 -- direct user request: "switching weapons... needs
-- controller support." A controller has no number row to mirror `WEAPON_
-- KEYS`' own 1-8 direct-select scheme, so this is a genuinely NEW input
-- mode, not a DOOM-ported one -- real DOOM itself has no gamepad weapon-
-- cycle concept at all (vanilla 1.10 predates analog-stick controller
-- support entirely). Cycling to the next/previous OWNED weapon via the
-- shoulder buttons is this mod's own judgment call, matching the
-- near-universal console-FPS/console-DOOM-port convention (real
-- examples: the PSX/DOOM64/Xbox ports all cycle weapons on the shoulder
-- buttons) -- a UX choice, not a derivable DOOM fact, same category as
-- every other controller-mapping decision in this file.
local WEAPON_ORDER = {
  WEAPON_KEYS["1"], WEAPON_KEYS["2"], WEAPON_KEYS["3"], WEAPON_KEYS["4"],
  WEAPON_KEYS["5"], WEAPON_KEYS["6"], WEAPON_KEYS["7"], WEAPON_KEYS["8"],
}
local function cycleWeapon(direction)
  local currentIndex
  for i, name in ipairs(WEAPON_ORDER) do
    if name == player.readyweapon then currentIndex = i break end
  end
  if not currentIndex then return end
  local n = #WEAPON_ORDER
  for step = 1, n - 1 do
    local idx = ((currentIndex - 1 + step * direction) % n) + 1
    local name = WEAPON_ORDER[idx]
    if player.weaponowned[name] then
      selectWeapon(name)
      return
    end
  end
end

-- ------- P_GiveAmmo (p_inter.c:73-160), minus the trainer/nightmare
-- double-ammo skill branch (this mod has no difficulty-tier system, same
-- exclusion already made for Phase 12's damage pipeline) and the
-- "auto-switch to a newly-affordable weapon when ammo was at 0" tail
-- (a real DOOM behavior, deliberately not ported -- a minor QoL nicety,
-- not central to functional parity, and this mod's own `checkAmmo`
-- already handles running dry a different way). `clips` mirrors DOOM's
-- own real `num` parameter exactly: "the number of clip loads, not the
-- individual count" (that file's own doc comment) -- `clips * CLIPAMMO
-- [type]` rounds are actually granted, capped at `player.maxAmmo[type]`.
-- Returns whether anything was actually added (false if already at max,
-- matching DOOM's own "don't consume a pickup you didn't need").
function DoomWeapons.giveAmmo(ammoType, clips)
  if not (ammoType and CLIPAMMO[ammoType]) then return false end
  if player.ammo[ammoType] >= player.maxAmmo[ammoType] then return false end
  local num = (clips or 1) * CLIPAMMO[ammoType]
  player.ammo[ammoType] = math.min(player.ammo[ammoType] + num, player.maxAmmo[ammoType])
  return true
end

-- FEATURE 2026-08-08 -- user request: "you should be able to buy doom
-- items randomly through pokeshops." Real DOOM has no concept of
-- buying individual rounds one at a time (ammo is always found in
-- whole "clip loads," `giveAmmo`'s own real `clips` parameter above),
-- but a Pokémart purchase is naturally per-UNIT (the player picks a
-- quantity of the exact item being sold, `src/ui/ShopMenu.lua`'s own
-- real buy flow) -- this mod's own addition, no DOOM precedent to
-- port, exactly like the currency-per-kill feature added the same
-- round. Adds RAW ammo units directly rather than reusing `giveAmmo`'s
-- own `clips`-multiplied formula (which would over-grant by a factor
-- of `CLIPAMMO[type]` for a purchase of the same raw quantity).
function DoomWeapons.giveAmmoUnits(ammoType, amount)
  if not (ammoType and CLIPAMMO[ammoType] and amount and amount > 0) then return false end
  if player.ammo[ammoType] >= player.maxAmmo[ammoType] then return false end
  player.ammo[ammoType] = math.min(player.ammo[ammoType] + amount, player.maxAmmo[ammoType])
  return true
end

-- ------- backpack (SPR_BPAK case, p_inter.c:589-599): doubles every
-- `maxAmmo` entry ONCE (guarded by `player.backpack`, matching real
-- DOOM's own identical guard against doubling twice), then grants 1
-- clip-load of every ammo type regardless of the double having already
-- happened on an earlier pickup.
function DoomWeapons.giveBackpack()
  if not player.backpack then
    for ammoType in pairs(player.maxAmmo) do
      player.maxAmmo[ammoType] = player.maxAmmo[ammoType] * 2
    end
    player.backpack = true
  end
  for ammoType in pairs(CLIPAMMO) do
    DoomWeapons.giveAmmo(ammoType, 1)
  end
end

-- ------- P_GiveWeapon (p_inter.c:167-220), single-player branch.
--
-- UPDATED 2026-08-08 -- `lib/DoomKill.lua`'s own new monster item-drop
-- system (real DOOM's `P_KillMobj`, p_inter.c:719-757) now actually
-- reaches the `dropped` case this function's own header comment used to
-- say was unreachable: `P_GiveWeapon`'s own real signature takes a
-- `dropped` bool (`p_inter.c:171`, "The weapon name may have a
-- MF_DROPPED flag ored in") and grants only 1 ammo clip for a dropped
-- weapon vs. 2 for one found placed in the world (`p_inter.c:198-205`)
-- -- ported directly, a plain integer branch, not the kind of tic-rate/
-- fixed-point formula CLAUDE.md's "avoid math-derived code" rule warns
-- about. Grants ammo either way (a pickup for an already-owned weapon
-- still tops up its ammo, matching real DOOM), but only marks the
-- weapon owned and auto-switches to it (`pendingweapon`) the first time
-- -- ported exactly, including that real asymmetry.
function DoomWeapons.giveWeapon(name, dropped)
  local w = WEAPONS[name]
  if not w then return false end
  local gaveAmmo = w.ammoType and DoomWeapons.giveAmmo(w.ammoType, dropped and 1 or 2) or false
  local gaveWeapon = false
  if not player.weaponowned[name] then
    gaveWeapon = true
    player.weaponowned[name] = true
    -- FEATURE 2026-08-10 -- new "WEAPON SWITCH ON PICKUP" on/off row
    -- (`lib/DoomOptions.lua`, default ON -- preserves the real DOOM
    -- `P_GiveWeapon` auto-switch above exactly, for anyone who never
    -- touches the row). OFF still marks the weapon owned (selectable via
    -- the number key/next-weapon cycle) but doesn't interrupt whatever's
    -- currently readied.
    if Options.weaponSwitchOnPickupEnabled() then
      player.pendingweapon = name
    end
  end
  return gaveWeapon or gaveAmmo
end

-- ------- selling from the bag (2026-08-07) -- user request: "the doom
-- items should be able to be sold in shops for currency... add value to
-- them." `lib/DoomInventory.lua`'s own bag rows already mirror this
-- file's real `weaponowned`/`ammo` state 1:1 (Phase 13); the base
-- engine's own `ShopMenu.lua` sell flow (`src/ui/ShopMenu.lua:87-140`)
-- has no idea this mod's inventory rows aren't its own real items, and
-- just calls `Bag.remove` directly on `save.inventory` -- these two
-- functions are what `lib/DoomInventory.lua`'s own per-frame reconcile
-- calls to turn that bag-side removal into a REAL change here, the one
-- place both sides of the mirror meet (without them, the very next
-- resync would silently restore the "sold" copy right back, since this
-- file's own state is what that sync reads FROM, unaware anything sold
-- at all). Real DOOM itself has no economy/currency of any kind, so
-- there is no source-derived "correct" way to remove a weapon/ammo
-- count -- these simply undo `giveAmmo`/`giveWeapon`'s own real effects.
--
-- No `takeFist`: the fist is real DOOM's own permanent, un-loseable
-- baseline capability (`weaponowned[wp_fist]` starts, and stays, true --
-- g_game.c:826), not a genuine pickup -- `lib/DoomInventory.lua`'s own
-- registration marks it a real Gen1 key item instead (unsellable,
-- exactly like an HM), so this is never called for it in practice.
function DoomWeapons.takeAmmo(ammoType, amount)
  if not (ammoType and player.ammo[ammoType] and amount and amount > 0) then return end
  player.ammo[ammoType] = math.max(0, player.ammo[ammoType] - amount)
end

-- Revokes ownership; if the sold weapon was ready or about to become
-- ready, falls back to the fist -- the same real "what do you fight
-- with now" question real DOOM never has to answer (you can never sell
-- your only weapon there), answered here the only way this mod's own
-- economy addition can: the one weapon that's never sellable.
function DoomWeapons.takeWeapon(name)
  if not (name and WEAPONS[name] and player.weaponowned[name]) then return end
  player.weaponowned[name] = false
  if player.readyweapon == name or player.pendingweapon == name then
    selectWeapon("FIST")
  end
end

-- Every weapon name not yet in `player.weaponowned`, in WEAPON_KEYS'
-- own stable key order (not pairs()'s unspecified iteration order) --
-- for `giveRandomUnownedWeapon` below and anything else that wants a
-- deterministic-order list of what's still missing.
-- Every real DOOM weapon name, in the same stable `WEAPON_KEYS` order
-- (1-8), deduplicated -- shared by `unownedWeapons`/`weaponNames` below,
-- which differ only in whether an already-owned weapon is filtered out.
-- Factored out 2026-08-19 during a project-wide readability audit (both
-- used to independently rebuild this same list).
local function orderedWeaponNames(includeName)
  local names, seen = {}, {}
  for _, key in ipairs({ "1", "2", "3", "4", "5", "6", "7", "8" }) do
    local name = WEAPON_KEYS[key]
    if name and not seen[name] then
      seen[name] = true
      if not includeName or includeName(name) then names[#names + 1] = name end
    end
  end
  return names
end

function DoomWeapons.unownedWeapons()
  return orderedWeaponNames(function(name) return not player.weaponowned[name] end)
end

-- Every real DOOM weapon, in the same stable `WEAPON_KEYS` order (1-8),
-- owned or not -- for the GIVE WEAPON debug row below (unlike
-- `unownedWeapons` above, which exists for the "hand me whatever's
-- still missing" cheat and deliberately excludes already-owned ones).
function DoomWeapons.weaponNames()
  return orderedWeaponNames()
end

-- User request (2026-08-06): "a button in settings that you can select
-- a weapon, and when pressing a or enter, it gives the player that
-- weapon."
--
-- COMBINED INTO ONE ROW 2026-08-10, direct user request: "test weapon
-- and give weapon should [also] be combined into one button" (the same
-- request already applied to TEST ENEMY/SPAWN ENEMY -- see `lib/
-- DoomDemons.lua`'s own `spawnRow` for the full derivation of WHY this
-- is actually possible despite the real row-input contract only ever
-- giving a row `.activate` XOR `.step`). Same technique: a `.step`-only
-- row that reads `game.input:wasPressed("a")` itself (confirmed safe to
-- re-read within the same tick -- `Input:wasPressed`,
-- `gen1recomp-dev/src/core/Input.lua:382-384`, is a pure read of a
-- table only ever rebuilt once per fixed step) to tell "this call is
-- because A was pressed" apart from "this call is because left/right
-- was pressed," rather than trusting the ambiguous `dir` parameter the
-- real dispatcher passes identically (`dir=1`) for either.
local giveWeaponCursor = 1

function DoomWeapons.giveWeaponRow()
  return {
    id = "pokedoom_give_weapon",
    label = "TEST WEAPON",
    value = function()
      local names = DoomWeapons.weaponNames()
      return names[giveWeaponCursor] or names[1]
    end,
    step = function(game, dir)
      local names = DoomWeapons.weaponNames()
      if game and game.input and game.input.wasPressed and game.input:wasPressed("a") then
        local name = names[giveWeaponCursor] or names[1]
        if name then pcall(DoomWeapons.giveWeapon, name) end
        return false
      end
      giveWeaponCursor = ((giveWeaponCursor - 1 + (dir or 1)) % #names) + 1
      return true
    end,
  }
end

-- Picks one random not-yet-owned weapon and grants it via `giveWeapon`
-- above -- the real mechanism behind Phase 13's trainer-battle weapon
-- reward (`lib/DoomRewards.lua`). Returns the picked name, or nil if
-- every weapon is already owned (no error, no fallback reward here --
-- the caller decides what "nothing left to give" should mean for its
-- own context).
function DoomWeapons.giveRandomUnownedWeapon()
  local pool = DoomWeapons.unownedWeapons()
  if #pool == 0 then return nil end
  local name = pool[math.random(1, #pool)]
  DoomWeapons.giveWeapon(name)
  return name
end

-- A plain-value snapshot of `player.weaponowned`, for `lib/DoomHud.lua`'s
-- own evil-grin face state (`ST_updateFaceWidget`'s real trigger, re-
-- confirmed in phases/phase-13-item-pickups.md's own audit: `bonuscount`
-- nonzero AND at least one `weaponowned[]` slot flipped on the SAME
-- tick) -- exposed as a copy, not the live table, so a caller can safely
-- hold onto one frame's snapshot and diff it against a later one without
-- it silently updating out from under them.
function DoomWeapons.ownedSnapshot()
  local snap = {}
  for name, owned in pairs(player.weaponowned) do snap[name] = owned end
  return snap
end

-- Raw `player.ammo[type]` reader -- for `lib/DoomInventory.lua`'s own
-- real-Gen1-bag sync (Phase 13), which needs per-type counts
-- independent of whichever weapon is currently readied
-- (`DoomWeapons.readyAmmo()`'s own scope).
function DoomWeapons.ammoCount(ammoType)
  return player.ammo[ammoType] or 0
end

-- ------- dev command: give yourself a weapon without picking it up
--
-- The dev console's own verbs (src/dev/Console.lua's VERBS table) are a
-- private local in that file -- no seam exists for a mod to register a
-- new one. That same file's exec() falls through unmatched input to
-- plain Lua evaluation with game/data/mods/_G in scope ("expression
-- first... statements fall through"), which is the sanctioned way to
-- reach a mod from the console -- a clearly-namespaced GLOBAL function,
-- not a fork of that file. Bypasses the real pickup system entirely
-- (deliberately -- this is a raw testing tool, not a real game action,
-- same posture as `lib/DoomHealth.lua`'s own `pokedoom_hurt`) and works
-- for any weapon already in the WEAPONS table above -- console usage:
-- `pokedoom_give("SHOTGUN")`. Now also grants real ownership (Phase 13),
-- not just ammo, since `selectWeapon` refuses an unowned weapon as of
-- this same round -- without this the command would top up ammo for a
-- weapon the player still couldn't actually switch to.
function DoomWeapons.give(weaponName)
  local name = tostring(weaponName or ""):upper()
  local w = WEAPONS[name]
  if not w then
    local known = {}
    for k in pairs(WEAPONS) do known[#known + 1] = k end
    table.sort(known)
    print(("[PokeDoom] no such weapon: %s (have: %s)")
      :format(name, table.concat(known, ", ")))
    return false
  end
  player.weaponowned[name] = true
  if w.ammoType then
    player.ammo[w.ammoType] = math.max(player.ammo[w.ammoType] or 0, player.maxAmmo[w.ammoType])
  end
  selectWeapon(name)
  print(("[PokeDoom] switching to %s"):format(name))
  return true
end

-- exposed both ways: as a global for the console's Lua-fallback
-- evaluation, and via mod.exports (the same sanctioned inter-mod seam
-- DramaticShapeVoxelMod-dev itself uses to publish to this mod -- see
-- CLAUDE.md) for anything that would rather reach it without touching
-- _G. install() sets the mod.exports side, since only main.lua holds
-- the mod handle this file's own V table doesn't carry.
_G.pokedoom_give = DoomWeapons.give

-- ------- the view model
--
-- Uses each weapon's real ready-frame sprite once the player has
-- imported a DOOM WAD (lib/DoomWadImport.lua) -- DOOM's own published
-- sprite-naming convention (4-letter sprite name + frame letter +
-- rotation digit), found by substring since wadext's numeric output
-- prefix depends on the specific WAD's lump order. Falls back to a plain
-- placeholder shape when no WAD has been imported yet, or the current
-- weapon's sprite didn't decode, so this mod is fully playable before
-- that. Verified against the pre-extracted reference folder (filenames
-- only, see phases/phase-3-weapon-roster.md) rather than assumed.
--
-- Position: psp.sy (0 raised .. 1 lowered) slides it off the bottom of
-- the screen for the raise/lower animation; player.swayX/swayY trace a
-- real figure-eight while ready and moving, scaled by DOOM's own real
-- momentum-based `player->bob` (via `DoomMove.bobFraction()`, Phase 9 --
-- zero while standing still, matching real DOOM, see Actions.
-- weaponReady's own header comment for the full derivation). There is
-- deliberately no firing "kick" (an up-and-back snap-then-decay on every
-- shot) -- an earlier version of this file had one, restated from the
-- host's own HordeGun recoil, but real DOOM's weapon sprite has no such
-- reaction to firing at all. Confirmed by grepping every real write site
-- of `psp->sx`/`sy` in p_pspr.c: `A_WeaponReady`'s own sway (line 331/
-- 333), `P_SetPsprite`'s one-time per-state `misc1`/`misc2` override
-- (line 85-86, unused by every weapon this mod ports, per STATES' own
-- header comment), and `A_Lower`/`A_Raise` snapping `sy` to WEAPONBOTTOM/
-- WEAPONTOP at the end of their travel (already ported as this mod's own
-- `Actions.lower`/`raise`) -- none of them a firing-triggered kick. A
-- firing state's own psprite position is simply whatever it was last
-- left at, held still through the entire fire/recoil sequence -- the
-- ready-state sway is the only ONGOING motion DOOM's weapon sprite ever
-- has. The removed kick was exactly the kind of invented, uncited
-- embellishment CLAUDE.md's porting-methodology hard rule rules out
-- (same category as the host's own magazine/reload feel, already
-- excluded above) -- caught and removed at the user's own request after
-- comparing against real DOOM gameplay footage.

-- Phase 4: the fixed per-weapon WEAPON_SPRITE table is gone -- every
-- STATES/FLASH_STATES entry now carries its own real `sprite` lump name
-- (info.c-accurate, see that table's own header comment), so the weapon
-- sprite is looked up by CURRENT STATE, the same way DOOM's own
-- R_DrawPlayerSprite reads `psp->state->sprite`/`frame` every tic instead
-- of a per-weapon constant. weaponSpriteAsset()/weaponAsset() already
-- cache by the lump-name STRING itself (`"sprite:" .. nameSubstring`,
-- Phase 2/3), so no cache changes were needed here -- switching frames
-- just feeds a different string into the same cache.
local nameSubstring0 = function(sprite) return sprite .. "0" end -- rotation digit 0, see STATES' header comment

-- TEMPORARY debug print: sound loads through this exact same findAsset/
-- io.open/newFileData chain and is confirmed working, so if a sprite
-- doesn't show, this pins down whether the PNG failed to DECODE
-- (love.graphics.newImage) vs. decoded fine but never actually got drawn
-- (a positioning/scale bug in drawSprite instead). Prints once per
-- distinct sprite name, not every frame.
local spriteDebugPrinted = {}
-- Returns image, left, top (left/top default 0,0 when there's no sprite
-- at all, so callers can always destructure 3 values without a nil check).
local function loadNamedSprite(name)
  if not name then return nil, 0, 0 end
  local asset = weaponSpriteAsset(nameSubstring0(name))
  if not spriteDebugPrinted[name] then
    spriteDebugPrinted[name] = true
    if asset then
      local ok, iw, ih = pcall(function() return asset.image:getDimensions() end)
      print(("[PokeDoom] sprite %s: loaded ok, dims=%s, offset=%d,%d"):format(
        name, ok and (iw .. "x" .. ih) or "getDimensions failed",
        asset.left, asset.top))
    else
      print(("[PokeDoom] sprite %s: weaponSpriteAsset() returned nil (findAsset miss or newImage decode failure)"):format(name))
    end
  end
  if not asset then return nil, 0, 0 end
  return asset.image, asset.left, asset.top
end

-- FIX 2026-08-08 (user report: "the mod lags HEAVILY when first shooting
-- a gun"). Every weapon sprite/sound is loaded LAZILY, on first actual
-- use (`weaponAsset`'s own per-name cache above) -- a real, synchronous
-- disk-read + `love.graphics.newImage`/`love.audio.newSource` decode the
-- FIRST time a given name is ever needed, same class of bug as the
-- already-fixed "first pickup/first kill freeze" (that fix only sped up
-- FINDING which file matches a name; it never touched the cost of
-- actually DECODING it once found). Firing a weapon for the very first
-- time needs several never-before-loaded sprite names in a row (ready
-- frame, muzzle flash, several fire-animation frames) plus its fire
-- sound, all in the same instant -- exactly the reported hitch. Called
-- once via `DoomWadImport.onReady` (see `install()` below), decoding
-- every real STATES/FLASH_STATES sprite name and every real per-weapon
-- fire sound up front, so the actual first shot is a cache hit.
-- FIX 2026-08-08, ROUND 2 -- user report: "5 minutes and i knew i wasnt
-- even close to done... you dont have to sit at a terminal for 20
-- minutes for it to not lag." Doing every decode in one synchronous loop
-- (this function's own original shape) just moved dozens of small
-- in-gameplay hitches into a single, much WORSE blocking freeze -- a
-- real regression, not a fix. Rewritten to ENQUEUE each individual
-- sprite/sound load as its own unit of work
-- (`DoomWadImport.enqueuePrewarm`, see that function's own header
-- comment for the full redesign) instead of doing any of it here
-- directly -- this function itself is now just bookkeeping, effectively
-- instant, and the actual decoding drains in the BACKGROUND across
-- ordinary frame time, never blocking play.
function DoomWeapons.prewarm()
  local spriteNames = {}
  for _, s in pairs(STATES) do
    if s.sprite then spriteNames[s.sprite] = true end
  end
  for _, s in pairs(FLASH_STATES) do
    if s.sprite then spriteNames[s.sprite] = true end
  end
  for name in pairs(spriteNames) do
    DoomWadImport.enqueuePrewarm(function() pcall(loadNamedSprite, name) end)
  end
  -- Real per-weapon fire sound lumps -- see this file's own real call
  -- sites (`playWeaponSound("DS...")`) for where each of these is
  -- actually played from.
  local soundNames = {
    "DSPISTOL", "DSPUNCH", "DSSAWHIT", "DSSAWFUL",
    "DSSHOTGN", "DSRLAUNC", "DSPLASMA", "DSBFG",
  }
  for _, name in ipairs(soundNames) do
    DoomWadImport.enqueuePrewarm(function() pcall(weaponSound, name) end)
  end
end

-- player.psp.state is nil only in the brief window before the first
-- active frame's bringUpWeapon() call (see install()'s `started` guard);
-- both lookups tolerate that and fall through to the placeholder.
local function currentWeaponSpriteName()
  local st = player.psp.state and STATES[player.psp.state]
  return st and st.sprite
end

local function currentFlashSpriteName()
  local st = player.flash.state and FLASH_STATES[player.flash.state]
  return st and st.sprite
end

local function currentWeaponSprite()
  return loadNamedSprite(currentWeaponSpriteName())
end

local function currentFlashSprite()
  return loadNamedSprite(currentFlashSpriteName())
end

-- ------- DOOM's real screen space, not arbitrary window percentages
--
-- DOOM draws everything -- including the weapon sprite, at its own
-- NATIVE pixel size -- into a fixed 320x200 buffer (SCREENWIDTH/
-- SCREENHEIGHT, doomdef.h:110-112), then scales that WHOLE buffer up to
-- fit the real display. The previous version of this function instead
-- scaled the SPRITE ITSELF up by an arbitrary window-relative percentage
-- (h*0.55/spriteHeight -- a ~7x blow-up at a typical window size), which
-- is exactly why it rendered oversized, blocky, and wrongly positioned
-- (confirmed by the user's own screenshot). Drawing into a virtual
-- 320x200 canvas and scaling THAT uniformly, the way DOOM's own renderer
-- actually works, is the fix -- not a guess.
local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H

-- WEAPONTOP/WEAPONBOTTOM (p_pspr.c:47-48) are the real psp.sy range this
-- mod's own player.psp.sy (0 raised .. 1 lowered) already tracks, just
-- normalized.
local WEAPON_TOP_DOOM, WEAPON_BOTTOM_DOOM = 32, 128

-- A_WeaponReady's own psp->sx baseline (p_pspr.c:331: `psp->sx = FRACUNIT
-- + FixedMul(player->bob, finecosine[angle])`) -- FRACUNIT is 1 pixel at
-- the psprite's own 1:1 scale (pspritescale = FRACUNIT*viewwidth/
-- SCREENWIDTH = FRACUNIT at fullscreen viewwidth=320, r_main.c:722, and
-- centerx = viewwidth/2 = 160, r_main.c:697). psp->sx sits near this tiny
-- constant, NOT screen-centered -- what makes the sprite actually land
-- near screen-center is each lump's own (large, negative) spriteoffset
-- being subtracted from it (see SPRITE_SX_BASE's use in
-- spritePosition below). Verified against a real extracted asset, not
-- assumed: PISGA0's own grAb chunk is leftoffset=-126, so
-- 1-(-126)=127, and a 57px-wide sprite drawn from x=127 spans to x=184,
-- centered almost exactly on screen-center 160.
local SPRITE_SX_BASE = 1

-- Shared with `lib/DoomMenuSkin.lua`/`lib/DoomTownInvasion.lua`'s own
-- identical transform -- see `lib/DoomVirtualCanvas.lua`'s own header.
local virtualScaleAndOffset = DoomVirtualCanvas.centered

-- swayX/swayY are already in VIRTUAL pixels (a handful of pixels, DOOM's
-- own weapon sway is subtle -- not a fraction of screen width). spriteName
-- (e.g. "PISGB") is the CURRENT state's own sprite lump name whether or
-- not a real asset loaded for it -- used here only for its trailing frame
-- letter, so a WAD-less playthrough still shows the gun's silhouette
-- squash/grow across ready/fire/recovery instead of one static box
-- (Phase 4 checklist). No fake flash shape is drawn here: this mod has no
-- real muzzle-flash asset to approximate in the placeholder case either
-- (no offsets to place it correctly with, unlike the real-sprite path
-- below), and the whole point of removing the old circle was to stop
-- standing in for an effect this phase now owns for real.
local function drawPlaceholder(swayX, swayY, spriteName)
  local frameOffset = 0
  if spriteName then
    frameOffset = spriteName:byte(-1) - string.byte("A")
  end
  local squash = (frameOffset % 4)
  local gunW, gunH = 46 - squash, 50 - squash * 2
  local gx = VIRTUAL_W / 2 - gunW / 2 + swayX
  local gy = VIRTUAL_H - gunH + swayY
  love.graphics.setColor(0.16, 0.16, 0.19, 1)
  love.graphics.rectangle("fill", gx, gy, gunW, gunH, gunW * 0.15)
  love.graphics.setColor(0.05, 0.05, 0.06, 1)
  love.graphics.rectangle("fill", gx + gunW * 0.35, gy - gunH * 0.25,
                          gunW * 0.3, gunH * 0.3)
end

-- The exact port of R_DrawPSprite's own positioning (r_things.c:676-695),
-- simplified for this mod's fullscreen 320x200 canvas (viewwidth=
-- SCREENWIDTH=320 => pspritescale=FRACUNIT, centerx=160 -- see
-- SPRITE_SX_BASE's own header comment for the derivation):
--   x1 (left edge)         = psp->sx - spriteoffset[lump]
--   sprtopscreen (top edge) = psp->sy - spritetopoffset[lump]
-- `left`/`top` here are that lump's own real grAb-chunk offsets
-- (DoomWadImport.loadSpriteAsset) -- NOT independently re-centered per
-- sprite. This is what makes the flash land in the RIGHT place relative
-- to the gun: P_MovePsprites (p_pspr.c:875-876) syncs the flash psprite's
-- sx/sy to the weapon psprite's own every tic, so both this mod's weapon
-- and flash calls share the exact same sxPixels/syPixels anchor point,
-- each shifted by only ITS OWN offset -- exactly like the real engine,
-- confirmed against real extracted data (PISGA0 leftoffset=-126,
-- topoffset=-106 puts the pistol's own bottom edge flush with the
-- 200px screen foot when raised, i.e. sy=32: 32-(-106)+62(height)=200;
-- PISFA0 leftoffset=-140, topoffset=-66 puts the flash's bottom at
-- y=136 for the SAME sy=32 -- well above the gun body, not down at the
-- hands, matching real DOOM screenshots).
local function spritePosition(left, top, sxPixels, syPixels)
  return sxPixels - left, syPixels - top
end

-- Real DOOM relies on a hard clip at the 200-line screen buffer's own
-- edge (SCREENHEIGHT, doomdef.h:110) to hide however much of a weapon
-- sprite falls behind the status bar (ST_HEIGHT=32, st_stuff.h:32) --
-- confirmed by computing every weapon's own real screen-space bottom
-- edge (WEAPON_TOP_DOOM - topoffset + spriteHeight) from its actual grAb
-- offsets: PISTOL/SHOTGUN/PLASMARIFLE/FIST/CHAINSAW all land EXACTLY at
-- y=200 (nothing hidden), but CHAINGUN/ROCKETLAUNCHER/BFG9000 land at
-- y=232 -- 32px PAST the buffer, silently clipped in real DOOM (never
-- drawn there at all) since a status bar covers that band regardless.
-- This mod has no status bar to hide that overflow, and LOVE has no
-- implicit clip on a plain transform-and-draw call, so those three
-- weapons drew their FULL, unclipped height while every other weapon
-- stopped exactly at the canvas edge -- an inconsistent hem the user
-- reported as "some guns don't push to the bottom" (screenshots showed
-- the taller ones floating above the true window bottom relative to the
-- others, since the outer virtualScaleAndOffset letterbox margin sits in
-- exactly that gap when the real window isn't 320:200).
--
-- Fix: shift a weapon's WHOLE draw (its own sprite AND its flash, by the
-- identical amount, so their real relative alignment from Phase 4 is
-- untouched) so THAT sprite's own natural bottom edge always lands
-- exactly on VIRTUAL_H.
--
-- **Originally calibrated once per WEAPON, from its ready-frame sprite
-- only, and reused unchanged for every other state's sprite too** -- this
-- came back from a playtest still showing a gap under some guns (the
-- user's own screenshot). Root cause: different STATES entries for the
-- SAME weapon point at DIFFERENT lumps (e.g. the chaingun's CHAIN1/CHAIN2
-- are "CHGGA"/"CHGGB") whose own real grAb top offsets and pixel heights
-- are not guaranteed identical -- a correction derived only from the
-- READY frame's own lump was systematically wrong for any OTHER frame
-- whose natural bottom genuinely differs from the ready frame's, leaving
-- exactly this kind of persistent gap (or, for the reverse case, a
-- persistent overflow) rather than a normal frame-to-frame recoil wobble.
-- Fixed by calibrating per SPRITE LUMP NAME instead of per weapon,
-- against whichever lump is actually being drawn THIS frame -- every
-- displayed frame's own true bottom edge lands flush at VIRTUAL_H now,
-- regardless of which state it belongs to, cached the same cheap way
-- (`weaponSpriteAsset`'s own cache already keys by lump name, so this
-- just mirrors that granularity instead of collapsing it back to one
-- constant per weapon).
local bottomCorrection = {}
local function spriteBottomCorrection(spriteName, image, top)
  if not spriteName then return 0 end
  local cached = bottomCorrection[spriteName]
  if cached ~= nil then return cached end
  if not image then return 0 end -- WAD not loaded yet -- retry next call
  local naturalBottom = (WEAPON_TOP_DOOM - top) + image:getHeight()
  local correction = VIRTUAL_H - naturalBottom
  bottomCorrection[spriteName] = correction
  return correction
end

local function drawSprite(spriteName, sprite, left, top, sy01, swayX, swayY, flashSprite, flashLeft, flashTop)
  local sxPixels = SPRITE_SX_BASE + swayX
  local syPixels = WEAPON_TOP_DOOM + sy01 * (WEAPON_BOTTOM_DOOM - WEAPON_TOP_DOOM)
                    + swayY + spriteBottomCorrection(spriteName, sprite, top)
  local dx, dy = spritePosition(left, top, sxPixels, syPixels)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(sprite, dx, dy)
  -- ps_flash overlay (Phase 4): drawn from the SAME sxPixels/syPixels
  -- anchor, offset by the flash lump's own real left/top -- see this
  -- function's header comment.
  if flashSprite then
    local fx, fy = spritePosition(flashLeft, flashTop, sxPixels, syPixels)
    love.graphics.draw(flashSprite, fx, fy)
  end
end

-- Two different callers feed this: render.hud's viewport (width/height/
-- gameX/gameY-shaped) and render.compose's ctx (ww/wh/ox/oy/vpw/vph-
-- shaped) -- normalized to plain (w, h, ox, oy) numbers here rather than
-- have the drawing logic know about either table shape. See install()
-- for why both exist: render.hud's own viewport (Renderer:endFrame's
-- return value) turned out to be nil on every single frame in this
-- game's specific configuration (voxel/VR-capable renderer -- traced to
-- Renderer.lua's own early-return branch when another mod's
-- render.compose hook takes over the composite, most likely the voxel
-- mod's VR system), confirmed by the user's own playtest log, not
-- guessed. render.compose fires earlier, with a ctx that's unconditionally
-- built, so it doesn't depend on whichever branch endFrame happens to
-- take.
local function drawViewModel(w, h, ox, oy)
  if not (w and h) then return end
  ox, oy = ox or 0, oy or 0
  local scale, vox, voy = virtualScaleAndOffset(w, h)

  -- A_WeaponReady's own bob/sway (`player.swayX`/`swayY`, computed once
  -- per tic-cadence call to Actions.weaponReady, matching DOOM's own
  -- "psp->sx/sy only ever written by A_WeaponReady" behavior -- see that
  -- function's own header comment) -- just read here, not recomputed:
  -- DOOM's real renderer doesn't interpolate psp->sx/sy between tics
  -- either, so holding whatever value was last written between draw
  -- calls is the faithful behavior, not an approximation.
  local swayX, swayY = player.swayX, player.swayY

  love.graphics.push()
  love.graphics.translate(ox + vox, oy + voy)
  love.graphics.scale(scale, scale)

  local sprite, left, top = currentWeaponSprite()
  if sprite then
    local flashSprite, flashLeft, flashTop = currentFlashSprite()
    drawSprite(currentWeaponSpriteName(), sprite, left, top, player.psp.sy,
               swayX, swayY, flashSprite, flashLeft, flashTop)
  else
    drawPlaceholder(swayX, swayY, currentWeaponSpriteName())
  end

  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- install: input capture + the per-frame tick
--
-- Fire is claimed on the mouse the same way the host's own Horde mode
-- claims it (FirstPerson.lua's hordeMouse, wrapped ahead of the mouse-
-- captured A/B remap) -- this wrap runs AFTER the host's own main.lua
-- (our hard dependency guarantees that), which is what makes it outer
-- and gives this mod's fire input first refusal while PKDOOM MODE is on.
local installed = false

function DoomWeapons.install()
  if installed then return end
  installed = true

  installProjectileMeshHook()

  -- See `DoomWeapons.prewarm`'s own header comment above.
  pcall(function() DoomWadImport.onReady(DoomWeapons.prewarm) end)

  -- Loads whatever this save already has right away (covers the mod
  -- booting into an already-loaded save), then keeps it in sync with
  -- every future save switch -- same real event names `lib/DoomKill.
  -- lua`'s own gib reset already uses.
  -- DIAGNOSTIC 2026-08-19 -- see `loadWeaponSave`'s own header comment:
  -- every call site here now logs its own pcall ok/err too, so a silently
  -- swallowed error inside `loadWeaponSave` (which would explain "nothing
  -- happens, ammo stays 0" with zero other symptoms) is distinguishable
  -- from the event simply never firing at all.
  do
    local ok, err = pcall(loadWeaponSave)
    pcall(DoomLog.event, "WEAPONSAVE", "install(): initial loadWeaponSave() pcall ok=%s err=%s", tostring(ok), tostring(not ok and err or nil))
  end
  V.mod.events:on("save.loaded", function()
    local ok, err = pcall(loadWeaponSave)
    pcall(DoomLog.event, "WEAPONSAVE", "save.loaded fired -- loadWeaponSave() pcall ok=%s err=%s", tostring(ok), tostring(not ok and err or nil))
  end)
  V.mod.events:on("save.created", function()
    local ok, err = pcall(loadWeaponSave, nil, true)
    pcall(DoomLog.event, "WEAPONSAVE", "save.created fired -- loadWeaponSave(forceFresh) pcall ok=%s err=%s", tostring(ok), tostring(not ok and err or nil))
  end)

  local function active()
    return Options.enabled() and FirstPerson.driving()
  end

  local innerPressed = love.mousepressed
  love.mousepressed = function(x, y, button, istouch, presses)
    if active() and not istouch and button == 1 then
      player.attackHeld = true
      return
    end
    if innerPressed then return innerPressed(x, y, button, istouch, presses) end
  end

  local innerReleased = love.mousereleased
  love.mousereleased = function(x, y, button, istouch, presses)
    if button == 1 and player.attackHeld then
      player.attackHeld = false
      return
    end
    if innerReleased then return innerReleased(x, y, button, istouch, presses) end
  end

  local innerKeypressed = love.keypressed
  love.keypressed = function(key, scancode, isrepeat)
    if active() and WEAPON_KEYS[key] then
      selectWeapon(WEAPON_KEYS[key])
      return
    end
    if innerKeypressed then return innerKeypressed(key, scancode, isrepeat) end
  end

  -- FEATURE 2026-08-11 -- direct user request: full controller support
  -- for firing and weapon switching, confirmed genuinely missing (the
  -- host mod's own Horde Mode -- this weapon rig's own ancestor -- was
  -- checked first, hoping to just mirror it, but its own fire is
  -- mouse/touch-only too; no existing gamepad-fire pattern anywhere in
  -- this codebase to copy).
  --
  -- Wraps `Game.gamepadpressed`/`.gamepadreleased`/`.gamepadaxis`
  -- (methods on the base engine's own `Game` singleton), NOT raw
  -- `love.gamepad*` callbacks -- confirmed via `DramaticShapeVoxelMod-
  -- dev/lib/FirstPerson.lua`'s own real right-stick-look wrap and `lib/
  -- CamControl.lua`'s own real stick-click-zoom wrap, both of which
  -- specifically intercept `Game.gamepadaxis`/`Game.gamepadpressed`
  -- rather than `love.gamepadaxis`/`love.gamepadpressed` directly --
  -- this engine dispatches gamepad input by calling those `Game:`
  -- methods internally, not by re-checking the raw LÖVE callback slot
  -- the way mouse/keyboard events do, so wrapping the raw `love.*` name
  -- would silently never fire.
  --
  -- Right trigger = fire (`Game.lua`'s own `Game:gamepadpressed`
  -- comment confirms LÖVE reports an analog trigger AS a `gamepadpressed`
  -- button once it crosses the press threshold -- and, by the same
  -- mechanism, `gamepadreleased` once it drops back below -- so this
  -- reads it exactly like a real button, no manual axis/deadzone math
  -- needed, matching this project's own "avoid math-derived code"
  -- preference for the simpler equivalent). Left/right shoulder =
  -- previous/next weapon (`cycleWeapon`, above).
  --
  -- REAL, CONFIRMED CONFLICT, deliberately accepted: `Game:gamepadpressed`
  -- itself already binds right trigger/shoulder and left trigger/shoulder
  -- to cycling GAME SPEED (`self:_cycleSpeed(1/-1)`, `Game.lua` line
  -- ~691-704), unconditionally, before its own further dispatch. Claimed
  -- here BEFORE calling through to that inner behavior (this wrap's own
  -- body runs first, exactly like Horde Mode's own real "claimed before
  -- the A/B mapping below, so a press during the mode never also lands
  -- as something else" precedent, `FirstPerson.lua`) -- while PKDOOM
  -- MODE is actively driving, right trigger/shoulder buttons mean
  -- fire/weapon-switch, not game-speed, matching the same real tradeoff
  -- Horde Mode's own input claim already accepts elsewhere in this
  -- engine. Left trigger is deliberately NOT claimed (this mod has no
  -- secondary-fire concept to spend it on) -- still reaches the base
  -- game-speed-down behavior even while PKDOOM MODE is on.
  local okGame, Game = pcall(require, "src.core.Game")
  if okGame and Game then
    local innerGamepadPressed = Game.gamepadpressed
    function Game:gamepadpressed(joystick, button)
      if active() then
        if button == "righttrigger" then
          player.attackHeld = true
          return
        elseif button == "rightshoulder" then
          cycleWeapon(1)
          return
        elseif button == "leftshoulder" then
          cycleWeapon(-1)
          return
        end
      end
      if innerGamepadPressed then return innerGamepadPressed(self, joystick, button) end
    end

    local innerGamepadReleased = Game.gamepadreleased
    function Game:gamepadreleased(joystick, button)
      if button == "righttrigger" and player.attackHeld then
        player.attackHeld = false
        return
      end
      if innerGamepadReleased then return innerGamepadReleased(self, joystick, button) end
    end
  end

  -- the state machine starts life lowered-then-raising, same as
  -- P_SetupPsprites (p_pspr.c:831-842) calling P_BringUpWeapon at level
  -- start -- deferred to the first frame it's actually needed rather
  -- than run at install time, since FirstPerson isn't necessarily
  -- driving yet when the mod loads
  local started = false

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if active() then
      if not started or weaponViewDirty then
        started = true
        weaponViewDirty = false
        bringUpWeapon()
      end
      -- Keeps `Game.save.pokedoomWeapons` current every real tick, the
      -- same "just keep re-asserting it" shape this project already uses
      -- elsewhere (`lib/DoomView.lua`'s own `lockFirstPerson`/
      -- `lockPitch`) -- cheaper and far less error-prone than trying to
      -- remember a save call at every single give/switch site.
      pcall(saveWeaponState)
      -- BUG FIX, 2026-08-06 (user report: death left the game stuck --
      -- couldn't pause, world froze, but the player could still walk).
      -- `movePsprites()` runs every weapon fire, which runs every
      -- registered target-resolver (`DoomWeapons.targetResolvers`/
      -- `aoeResolvers` -- now three real ones: overworld NPCs, Horde
      -- mobs, ambient demons). NONE of these calls were ever pcall-
      -- protected -- a real, pre-existing gap since Phase 2, harmless
      -- while there was only one simple resolver, a real risk now that
      -- there are three, each touching more external state (a Horde
      -- session mid-teardown, a demon mid-death). An uncaught error here
      -- propagates out of this ENTIRE wrap, past `next(game, dt)` at the
      -- bottom -- which means the rest of the hook chain (every
      -- previously-installed wrap, ultimately the base engine's own
      -- tick) never runs for that frame either. Wrapped defensively so
      -- one bad resolver call degrades gracefully (skips a tick) instead
      -- of silently freezing the whole game's own logic.
      pcall(movePsprites)
      if #DoomWeapons.projectiles > 0 then
        local ok, ow = pcall(function() return require("src.core.Game").overworld end)
        if ok and ow then pcall(updateProjectiles, ow) end
      end
    elseif started and not active() then
      player.attackHeld = false
    end
    return next(game, dt)
  end)

  -- the view model, drawn in love.draw itself -- not any of gen1recomp's
  -- own render.hud/render.compose hooks.
  --
  -- Both were tried first, in order, and both failed for the same
  -- underlying reason: hooking into the GAME's own composite pipeline
  -- means trusting its internal state at the exact moment our hook
  -- fires, and either the data was wrong (render.hud's viewport argument
  -- -- Renderer:endFrame's return value -- confirmed nil on every frame
  -- in this game's actual configuration) or the timing was wrong
  -- (render.compose's sprite load succeeded with zero errors -- confirmed
  -- by the user's own playtest log -- yet still never became visible,
  -- meaning something drawn AFTER it in the same frame, inside
  -- Renderer:endFrame or later in Game.lua's own draw sequence, was
  -- painting over it).
  --
  -- love.draw sidesteps needing to reason about any of that: it is the
  -- literal last thing LOVE calls before presenting the frame to the
  -- screen, full stop -- nothing in the engine or any other mod runs
  -- after it. Wrapping it is the SAME established pattern this codebase
  -- already uses for love.mousepressed/love.keypressed (see this file's
  -- install() above, and the host mod's own FirstPerson.lua), just
  -- applied to drawing instead of input. Uses love.graphics.getWidth/
  -- Height directly -- LOVE's own always-correct window size, not
  -- gen1recomp's own viewport/ctx shapes -- so positioning is relative to
  -- the whole window rather than the inner letterboxed GB frame
  -- specifically; a minor cosmetic gap (not pixel-perfect against the
  -- letterbox) worth revisiting in Polish once "is it visible at all" is
  -- answered.
  -- `active()`'s own FirstPerson.driving() only confirms INPUT authority
  -- (FirstPerson is reading the player's buttons right now, per that
  -- function's own comment: "engaged, with the overworld on top of the
  -- stack") -- it does NOT confirm the first-person rig is the camera
  -- actually being RENDERED this frame. Those can differ (a blend/
  -- transition, or another camera type briefly holding the render while
  -- input authority hasn't handed off yet), which is exactly why the
  -- weapon view model was reported showing up outside first-person mode.
  -- `Voxel.level == Voxel.FP_LEVEL` (`VoxelState.lua`) is the real,
  -- authoritative rung selector -- what `lib/DoomView.lua`'s own
  -- `lockFirstPerson` now forces back to FP_LEVEL every frame while the
  -- mode is on, so this should never actually read false anymore, but
  -- checking it directly here (rather than the softer `FirstPerson.
  -- cardBlend() > 0.9` heuristic this used at first) is still the more
  -- precise gate: `cardBlend` turned out to also read >0.9 while 3RD
  -- person is showing (the "same underlying rig, just boomed back"
  -- ThirdPerson.lua uses, still `Voxel3D.camera == rig`), which is
  -- exactly why the weapon/gib were reported visible in third person
  -- despite that check. Gating the DRAW specifically (not `active()`
  -- itself, which still correctly governs input/firing) on this tighter
  -- condition is the fix.
  -- CORRECTED 2026-08-06: also checks `Pipelines.level("voxel")`, not
  -- just `Voxel.level` -- see `lib/DoomHud.lua`'s own `visible()` for the
  -- full diagnosis of why the two can disagree (they're separate stores;
  -- `Pipelines.level` is the one the world renderer itself actually
  -- reads) and why that gap is exactly how the user ended up seeing the
  -- real weapon view model floating over a flat 2D Game Boy screen.
  local function reallyInFirstPerson()
    local Pipelines = require("src.render.Pipelines")
    return active() and Voxel.level == Voxel.FP_LEVEL
       and Pipelines.level("voxel") == Voxel.FP_LEVEL
  end

  local drawErrorPrinted = false
  local innerDraw = love.draw
  love.draw = function(...)
    -- Flushed here, BEFORE the world itself draws (`innerDraw`), so a
    -- projectile queued this frame renders at its correct, fresh-yaw
    -- position starting on its very first visible frame instead of one
    -- frame late. See `pendingProjectileSpawns`'s own header comment.
    pcall(flushPendingProjectileSpawns)
    if innerDraw then innerDraw(...) end
    -- FEATURE 2026-08-10 -- new "SHOW WEAPON" on/off row
    -- (`lib/DoomOptions.lua`) -- only hides the view model draw itself;
    -- `reallyInFirstPerson()`'s own gate stays the real safety guarantee
    -- against a flat-2D-fallback leak, and firing/input logic (`active()`
    -- above) is completely unaffected -- turning the gun invisible
    -- shouldn't also disable it.
    if reallyInFirstPerson() and Options.showWeaponEnabled() then
      local ok, err = pcall(drawViewModel, love.graphics.getWidth(),
                            love.graphics.getHeight(), 0, 0)
      if not ok and not drawErrorPrinted then
        drawErrorPrinted = true
        print("[PokeDoom] drawViewModel error: " .. tostring(err))
      end
    end
  end
end

return DoomWeapons
