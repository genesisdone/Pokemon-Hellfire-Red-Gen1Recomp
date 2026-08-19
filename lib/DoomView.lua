-- PokeDoom Phase 1: first-person view parity -- FOV and view bob, ported
-- from DOOM-master/linuxdoom-1.10 (read directly at the point of use, per
-- CLAUDE.md's "DOOM facts come from the source" rule -- not reused from
-- this project's earlier, deleted movement-phase derivations). No
-- movement is touched: the host's own FreeMove/camera-driving stay
-- exactly as that mod ships. Only active while PKDOOM MODE is on
-- (lib/DoomOptions.lua).
--
-- Both effects are applied by wrapping the host's FirstPerson.frame
-- (a live table field, the same monkey-patch idiom this whole codebase
-- already uses elsewhere -- see CLAUDE.md), NOT by setting
-- FirstPerson.fovScale: that field exists (FirstPerson.lua:120, written
-- by HordeGun.lua's ADS narrowing) but was VERIFIED to have NO effect on
-- the actual rendered projection in this checkout --
-- FirstPerson.frame's `fov = oFov + (FirstPerson.FOV - oFov) * e` never
-- multiplies by fovScale, and Voxel3D.lua reads that same cam.fov
-- straight into Mat4.perspective with nothing scaling it either. The
-- comment on fovScale ("the fov is folded into the orbit blend below")
-- does not match the current code -- worth knowing since it may also
-- mean Horde's own ADS FOV narrowing isn't visually doing anything, but
-- that's a host file, out of this mod's scope to fix.

local V = ...
local Host = V.host

local FirstPerson = Host.require("FirstPerson")
local Voxel = Host.require("VoxelState")

-- Every one of these is genuinely OPTIONAL -- not guaranteed to exist on
-- every host fork this mod supports (CLAUDE.md's own three-way
-- DramaticShapeVoxelMod-dev/potato_voxel-main/DramaLess-shape
-- compatibility rule) -- `tryRequire` is the one shared "get it if it's
-- there, nil otherwise" helper, factored out 2026-08-19 during a
-- project-wide readability audit (this file used to repeat the same
-- `local okX, X = pcall(Host.require, "X"); if not okX then X = nil end`
-- pair once per module, ~15 times over).
local function tryRequire(name)
  local ok, mod = pcall(Host.require, name)
  return ok and mod or nil
end

local BrickProfile = tryRequire("BrickProfile")
local Structures = tryRequire("Structures")
-- 2026-08-12, round 3: every OTHER real-world-value knob `BrickProfile.
-- apply()` also pins away from its own real desktop default -- see
-- `restoreVoxelLadderIfCollapsed`'s own header comment further down for
-- the full audit of what each one is and its verified real default,
-- read fresh from each file's own source, not guessed.
local HostWater = tryRequire("Water")
local ForestAtmos = tryRequire("ForestAtmos")
local OverworldBattle = tryRequire("OverworldBattle")
local AntiAlias = tryRequire("AntiAlias")
local WorldCurve = tryRequire("WorldCurve")
local VoxelGrid = tryRequire("VoxelGrid")
local HostTiltShift = tryRequire("TiltShift")
local HostChunkMesher = tryRequire("ChunkMesher")
local ShadowMap = tryRequire("ShadowMap")
-- CHANGED 2026-08-19 -- direct user report + confirmed by inspecting the
-- real, current potato_voxel 1.8.2 release directly: Horde Mode (and
-- every `Horde*.lua` file) has been dropped from that host build
-- entirely. `Horde` was never PokeDoom's own feature (`docs/
-- horde-reincorporation.md`) -- this file only ever reused a couple of
-- its live fields as a convenient existing seam, both replaced below
-- with real PokeDoom-owned code once Horde (and the specific host
-- mechanisms those fields used to gate) turned out to be genuinely gone
-- from this host release, not just Horde itself -- `Horde` is no longer
-- required here at all.
local FreeMove = tryRequire("FreeMove")
local Options = V.require("DoomOptions")
local DoomMove = V.require("DoomMove")
local DoomHealth = V.require("DoomHealth")
local DoomHud = V.require("DoomHud")
local DoomWadImport = V.require("DoomWadImport")
local DoomDeathScreen = V.require("DoomDeathScreen")

local DoomView = {}

-- ------- FOV
--
-- DOOM's FIELDOFVIEW = 2048 (r_main.c:48), out of FINEANGLES = 8192 for a
-- full turn (that file's own comment: "FIELDOFVIEW angles covers
-- SCREENWIDTH") => 2048/8192*360 = 90 degrees, against the host's fixed
-- 65-degree FirstPerson.FOV.
local DOOM_FOV_DEG = 2048 / 8192 * 360
DoomView.fovMultiplier = DOOM_FOV_DEG / math.deg(FirstPerson.FOV)

-- ------- view bob (p_user.c P_CalcHeight)
--
--   player->bob = (FixedMul(momx,momx) + FixedMul(momy,momy)) >> 2,
--                 capped at MAXBOB = 0x100000 (p_user.c:49)
--   angle = (FINEANGLES/20 * leveltime) & FINEMASK
--   bob = FixedMul(player->bob/2, finesine[angle])
-- added onto player->viewz, gated on `onground` (mo->z <= mo->floorz) --
-- there is no jump in this mod's scope (see CLAUDE.md), so that gate is
-- always true here and left out.
--
-- momx/momy have no equivalent in this codebase: movement is entirely the
-- host's own FreeMove, an instant-set-per-frame walk with no persisted
-- momentum to read (CLAUDE.md's rescoping removed the momentum code that
-- used to track this). DOOM's own bob amplitude has no smoothing of its
-- own either, though -- it is recomputed fresh from CURRENT momentum
-- every tic with no lag -- so an instant on/off envelope is a faithful
-- match for a movement model that is itself instant on/off, not an
-- approximation invented to paper over a gap.
--
-- **What that envelope is keyed to changed 2026-08-05, twice.**
-- Originally "is the player's world POSITION actually different from
-- last frame" (`me.px ~= lastPx or me.py ~= lastPy`). That is a proxy
-- for DOOM's real trigger, not the thing itself -- DOOM's own
-- `cmd->forwardmove`/`cmd->sidemove` are raw INPUT, not a derived
-- position delta -- and the proxy turned out to be fragile in a way the
-- real signal never would be: ANY position discontinuity between two
-- consecutive `bobOffset` calls (a save reload, a map-boundary
-- coordinate rebase, returning from a battle, a collision-slide
-- correction) reads as "moving" for exactly one frame no matter how it
-- happened, and since the on/off gate was a hard boolean multiplying a
-- fixed-amplitude sine, a rapid FLICKER between "moving"/"not moving"
-- across a couple of frames (not just one big jump) showed up as the
-- camera SNAPPING between 0 and full `BOB_PEAK` repeatedly -- a hard,
-- jarring jitter, not a smooth bob -- confirmed by the user's own report
-- ("sometimes it will jitter really hard instead of bobbing... when it
-- happens, its unplayable").
--
-- Switched then to `FirstPerson.moveVector()` as a binary "moving" gate
-- -- immune to the position-discontinuity bug class, but STILL a hard
-- on/off switch multiplying a FIXED amplitude, which was never actually
-- what real DOOM does: `player->bob` (audited in `lib/DoomMove.lua`'s
-- own header comment) is a CONTINUOUS function of momentum SQUARED, no
-- binary gate anywhere in `P_CalcHeight` at all. That distinction had no
-- real momentum to read from at the time this file was first written
-- (Phase 1 predates Phase 9), so a binary approximation was the honest
-- best option then. It no longer is: Phase 9 gave this mod exactly the
-- real, continuous momentum-magnitude signal DOOM's own formula wants
-- (`DoomMove.bobFraction()`, itself already the 0..1, squared,
-- MAXBOB-capped fraction of that same real formula, built for
-- `lib/DoomWeapons.lua`'s weapon sway). Re-auditing movement fresh at
-- the user's own request surfaced this as a second, related gap: the
-- binary gate meant the camera bobbed at FULL peak amplitude for the
-- entire duration of a slide-to-a-stop (Phase 9's own newly-fixed real
-- behavior) and then cut off in a hard snap the instant momentum hit
-- zero, instead of visibly settling down WITH the slide the way real
-- DOOM's own continuously-decaying `player->bob` actually does. Fixed
-- by reading `bobFraction()` directly instead of a `moveVector()`-based
-- boolean -- which also means this function no longer needs to inspect
-- input/momentum direction at all, only magnitude, matching DOOM's own
-- formula exactly (it has no "gate," only a continuous multiplier that
-- happens to reach 0 on its own once momentum genuinely does).
--
-- MAXBOB (16.0 map units), halved by the /2 in the sine multiply, peaks
-- the swing at 8 map units against VIEWHEIGHT = 41 map units
-- (p_local.h:34) -- proportionally ~19.5% of eye height. There is no
-- principled DOOM-map-unit conversion to this engine's world px (see
-- CLAUDE.md's locked decisions on speed scaling), so that PROPORTION is
-- what's ported, against the host's own FirstPerson.EYE_HEIGHT.
local MAXBOB_UNITS = 0x100000 / 65536 -- 16.0
local VIEWHEIGHT_UNITS = 41
DoomView.BOB_PEAK = FirstPerson.EYE_HEIGHT * (MAXBOB_UNITS / 2 / VIEWHEIGHT_UNITS)

-- FINEANGLES/20, truncated the same way the C integer division truncates
-- it, over FINEANGLES=8192 for one full turn, at DOOM's real
-- TICRATE = 35 (doomdef.h:122) -- converted to radians/frame at this
-- engine's 60Hz the same way this project's (now-deleted) turn-rate code
-- converted DOOM's angleturn, re-derived fresh here rather than trusted
-- from that deleted file.
local FINEANGLES = 8192
local PHASE_PER_TIC = math.floor(FINEANGLES / 20) * (2 * math.pi / FINEANGLES)
local DOOM_TICRATE = 35
DoomView.PHASE_PER_FRAME = PHASE_PER_TIC * (DOOM_TICRATE / 60)

local phase = 0

-- Resets the bob's own phase to a clean start whenever the mode is
-- (re-)engaged (`DoomView.install`'s own enable-edge check) -- cosmetic
-- now rather than load-bearing (the momentum-magnitude-driven multiplier
-- below has no stale-state desync class to guard against at all: `lib/
-- DoomMove.lua`'s own momentum resets on the exact same enable-edge), but
-- there is no reason for the sine to resume mid-swing from wherever it
-- happened to be the last time the mode was on either.
local function resetBob()
  phase = 0
end
DoomView.resetBob = resetBob

-- The vertical bob offset for this frame, in world px. Gated on
-- `DoomMove.bobFraction()` -- real momentum magnitude (squared, capped),
-- not a binary "is there input right now" gate -- see this section's own
-- header comment for the full history of what this used to read and why
-- each switch was made.
--
-- ALSO gated on `FirstPerson.driving()`: `bobFraction()` itself has no
-- idea whether the overworld actually owns the buttons right now (it
-- just reads whatever momentum `lib/DoomMove.lua` last computed, which
-- freezes rather than decays while that file's own per-frame update
-- isn't running -- see `DoomMove.lua`'s own `momX`/`momZ` header
-- comment); without this check, momentum frozen at a nonzero value the
-- instant a menu opens would keep the camera swaying while paused for no
-- reason. `DoomWeapons.lua`'s own `active()` already includes this same
-- check for its every input path (fire, weapon switch, weapon tick).
-- FEATURE 2026-08-10 -- new "VIEW BOB" on/off row (`lib/DoomOptions.lua`)
-- -- some players get motion sick from head bob. `phase` still advances
-- every frame regardless (so turning it back on resumes mid-cycle
-- instead of jumping), only the returned OFFSET is suppressed.
local function bobOffset()
  phase = (phase + DoomView.PHASE_PER_FRAME) % (2 * math.pi)
  if not FirstPerson.driving() then return 0 end
  if not Options.viewBobEnabled() then return 0 end
  return DoomView.BOB_PEAK * DoomMove.bobFraction() * math.sin(phase)
end

-- ------- death camera (P_DeathThink, p_user.c:182-229) -- Phase 15
-- (phases/phase-15-player-death.md), read fresh at the point of use.
--
-- Two real, independent effects, both driven purely by fixed per-tic
-- steps (no formula, matching CLAUDE.md's "avoid math-derived code"
-- rule -- these are already exactly that shape in the real source):
--
--   1. The view falls from VIEWHEIGHT (41 units) to a 6-unit floor
--      height, 1 unit/tic (`if (player->viewheight > 6*FRACUNIT)
--      player->viewheight -= FRACUNIT`).
--   2. If `player->attacker` exists and isn't the player's own self, the
--      view angle steps 5 degrees/tic toward the attacker's bearing,
--      snapping the rest of the way once within 5 degrees (`ANG5 =
--      ANG90/18`).
--
-- NOT ported: the real coupling where `damagecount` only decays on tics
-- where the player is ALREADY facing the attacker (falling back to
-- decaying every tic once no attacker exists) -- `lib/DoomHealth.lua`'s
-- own decay already runs unconditionally every frame (Phase 12), and
-- re-gating it on this file's own turn-completion state would tangle
-- two files together for a one-or-two-frame flash-linger difference
-- nobody would likely notice. A deliberate, documented simplification,
-- not an oversight.
local DEATH_FLOOR_UNITS = 6
local deathViewHeight = nil -- nil while alive; VIEWHEIGHT_UNITS..6 while dead

local function resetDeathCamera()
  deathViewHeight = nil
end
DoomView.resetDeathCamera = resetDeathCamera

-- `stepToward`'s own shortest-direction angle stepper -- the SAME shape
-- `lib/DoomDemons.lua` would want for a "turn toward" behavior, but
-- reimplemented locally rather than shared, since that file's version
-- is grid/cell-facing-based (4-way discrete) and this one needs a
-- continuous yaw radian, a genuinely different representation, not the
-- same function with different units.
local function stepAngleToward(current, target, step)
  local delta = (target - current + math.pi) % (2 * math.pi) - math.pi
  if math.abs(delta) <= step then return target end
  if delta > 0 then return current + step else return current - step end
end

-- Vertical eye-shift, in this engine's own world units, for the current
-- `deathViewHeight` -- proportional to `FirstPerson.EYE_HEIGHT` the same
-- way `DoomView.BOB_PEAK` above already relates a DOOM view-height
-- quantity to this engine's own eye height, since there is no principled
-- DOOM-map-unit conversion (CLAUDE.md).
local function deathEyeShift()
  if not deathViewHeight then return 0 end
  return -(VIEWHEIGHT_UNITS - deathViewHeight) * (FirstPerson.EYE_HEIGHT / VIEWHEIGHT_UNITS)
end

-- ------- screen shake -- this mod's own addition, no DOOM precedent at
-- all (real DOOM's own renderer has no free 3D camera to shake -- it's a
-- fixed-height 2D raycast). User request: a new "SCREEN SHAKE" on/off
-- row (`lib/DoomOptions.lua`). Deliberately vertical-only, added into the
-- SAME `rig.eye[2]`/`rig.focus[2]` additive shift `bobOffset`/
-- `deathEyeShift` above already use -- the one technique this file has
-- already proven safe for nudging the render rig without touching look
-- direction; a horizontal or rotational shake would need new camera math
-- this file has never exercised.
--
-- `DoomView.triggerShake(magnitude, duration)` is the public entry point
-- other files call (`lib/DoomWeapons.lua`'s own explosion splash,
-- `lib/DoomHealth.lua`'s own damage) -- a stronger trigger while one is
-- already running takes over outright rather than stacking/summing, so a
-- rapid string of hits can't compound into an ever-growing, disorienting
-- shake. Decayed once per real `input.step` tick (`install`'s own wrap,
-- below) via a plain counter, not a formula -- the render-side
-- `shakeOffset` below only ever READS the current magnitude/timer.
local shakeTimer, shakeDuration, shakeMagnitude = 0, 0, 0

function DoomView.triggerShake(magnitude, duration)
  if not Options.screenShakeEnabled() then return end
  if magnitude >= shakeMagnitude or shakeTimer <= 0 then
    shakeMagnitude, shakeDuration, shakeTimer = magnitude, duration, duration
  end
end

local function tickShake(dt)
  if shakeTimer > 0 then
    shakeTimer = math.max(0, shakeTimer - dt)
  end
end

local function shakeOffset()
  if shakeTimer <= 0 or shakeDuration <= 0 then return 0 end
  local strength = shakeMagnitude * (shakeTimer / shakeDuration)
  return (math.random() * 2 - 1) * strength
end

-- Player-took-damage shake: reuses `DoomHealth.damageCount()` (real
-- `damagecount`, the same field `lib/DoomHud.lua`'s own palette flash
-- already reads) rather than a new cross-file call FROM `lib/
-- DoomHealth.lua` into this file -- that file is never allowed to
-- require this one back (`DoomView.lua` already requires `DoomHealth`,
-- line 31 above; the reverse would be a genuine circular `V.require`,
-- broken by this project's own cache-on-first-return loader). A real
-- hit rises `damagecount` (capped, refreshed on every new hit) before it
-- starts decaying again -- comparing against last tick's own value is a
-- correct, real "did a hit just land" edge, no separate tracking needed.
local lastDamageCountForShake = 0

local function checkDamageShake()
  if not Options.enabled() then return end
  local cur = DoomHealth.damageCount()
  if cur > lastDamageCountForShake then
    local rise = cur - lastDamageCountForShake
    DoomView.triggerShake(math.min(6, 1 + rise * 0.15), 0.35)
  end
  lastDamageCountForShake = cur
end

-- ------- killfeed: the real GZDoom obituary system (2026-08-07)
--
-- CORRECTED, same day: linuxdoom-1.10 itself has no on-screen kill-
-- notification system at all (confirmed by directly searching
-- `p_inter.c`/`g_game.c` -- `player->message` is pickups/door-keys
-- only, deathmatch tracks a silent `frags[]` counter). Per CLAUDE.md's
-- own hard rule (updated 2026-08-07 at the user's explicit request:
-- "doom source should be taken from gzdoom source when nothing can be
-- found on the subject in the doom source"), this is sourced from
-- `gzdoom-master` instead -- a REAL secondary source, not invented from
-- the user's own reference screenshot's visual style. Read fresh:
-- `Actor::GetObituary` (`wadsrc/static/zscript/actors/actor.zs:777-
-- 787`) picks `HitObituary` specifically when the killing blow's own
-- `MeansOfDeath == 'Melee'`, else falls back to `Obituary` (used for
-- every other cause, including ranged) -- so a monster with a REAL
-- melee attack in real DOOM has two, genuinely different obituary
-- lines; one with only a ranged/charge/hitscan attack has just one.
-- Real strings, `wadsrc/static/language.csv` (`%o` is GZDoom's own
-- player-name placeholder, `PronounMessage`, `p_interaction.cpp` --
-- always "PLAYER" here, this mod has no multiplayer):
--   ZOMBIEMAN:    OB_ZOMBIE    "%o was killed by a zombieman."
--   SHOTGUYGUY:   OB_SHOTGUY   "%o was shot by a sergeant."
--   IMP:          OB_IMPHIT (melee) "%o was slashed by an imp."
--                 OB_IMP (ranged)   "%o was burned by an imp."
--   DEMON:        OB_DEMONHIT  "%o was bit by a demon." (no ranged attack at all)
--   SPECTRE:      OB_SPECTREHIT "%o was eaten by a spectre."
--   CACODEMON:    OB_CACOHIT (melee) "%o got too close to a cacodemon."
--                 OB_CACO (ranged)   "%o was smitten by a cacodemon."
--   BARONOFHELL:  OB_BARONHIT (melee) "%o was ripped open by a Baron of Hell."
--                 OB_BARON (ranged)   "%o was bruised by a Baron of Hell."
--   LOSTSOUL:     OB_SKULL     "%o was spooked by a lost soul." (charge only)
--   SPIDERMASTERMIND: OB_SPIDER "%o stood in awe of the spider demon." (hitscan only)
--   CYBERDEMON:   OB_CYBORG    "%o was splattered by a cyberdemon." (rocket only)
-- Generic fallback (no real per-class string -- this mod's own
-- possessed-citizen mechanic, or a source with no positional identity):
-- OB_DEFAULT, "%o died."
local OBITUARIES = {
  ZOMBIEMAN = { melee = "WAS KILLED BY A ZOMBIEMAN", ranged = "WAS KILLED BY A ZOMBIEMAN" },
  SHOTGUYGUY = { melee = "WAS SHOT BY A SERGEANT", ranged = "WAS SHOT BY A SERGEANT" },
  IMP = { melee = "WAS SLASHED BY AN IMP", ranged = "WAS BURNED BY AN IMP" },
  DEMON = { melee = "WAS BIT BY A DEMON", ranged = "WAS BIT BY A DEMON" },
  SPECTRE = { melee = "WAS EATEN BY A SPECTRE", ranged = "WAS EATEN BY A SPECTRE" },
  CACODEMON = { melee = "GOT TOO CLOSE TO A CACODEMON", ranged = "WAS SMITTEN BY A CACODEMON" },
  BARONOFHELL = { melee = "WAS RIPPED OPEN BY A BARON OF HELL", ranged = "WAS BRUISED BY A BARON OF HELL" },
  LOSTSOUL = { melee = "WAS SPOOKED BY A LOST SOUL", ranged = "WAS SPOOKED BY A LOST SOUL" },
  SPIDERMASTERMIND = { melee = "STOOD IN AWE OF THE SPIDER DEMON", ranged = "STOOD IN AWE OF THE SPIDER DEMON" },
  CYBERDEMON = { melee = "WAS SPLATTERED BY A CYBERDEMON", ranged = "WAS SPLATTERED BY A CYBERDEMON" },
}

-- `attacker` is whatever `lib/DoomHealth.lua`'s own `damage()` stored
-- (Phase 15) -- a live demon mob table (`.name` = its own real roster
-- key, `.lastHitKind` = "melee"/"ranged", set at each real attack call
-- site in `lib/DoomDemons.lua`) for an ambient-demon kill, a possessed
-- citizen NPC (no `.name` roster key, falls through to the generic
-- fallback -- a mod-original mechanic with no real DOOM/GZDoom class to
-- cite), or a plain string ("horde") for a source with no positional
-- identity at all.
local function announceDeath()
  local attacker = DoomHealth.attacker()
  local line
  if type(attacker) == "table" and attacker.name and OBITUARIES[attacker.name] then
    local ob = OBITUARIES[attacker.name]
    line = ob[attacker.lastHitKind] or ob.ranged
  end
  pcall(DoomHud.announceKill, "PLAYER " .. (line or "DIED") .. ".")
end

-- Runs once per real frame from the same `input.step` wrap `bobOffset`'s
-- own phase advance already lives in. Reads the live overworld player's
-- and attacker's own world positions the same `pcall(require(...))`
-- pattern `lib/DoomWeapons.lua`'s own `updateProjectiles` call site
-- already uses -- this file has no other reach into `ow` otherwise.
local FALL_STEP_PER_FRAME = 1 * (35 / 60) -- 1 unit/tic, DOOM-tic to 60Hz
local TURN_STEP_PER_FRAME = math.rad(5) * (35 / 60) -- 5 deg/tic
local function tickDeathCamera()
  if not Options.enabled() then resetDeathCamera() return end
  if not DoomHealth.isDead() then resetDeathCamera() return end
  -- CLAUDE.md hard rule: pausing always means paused, no matter what --
  -- nested INSIDE the "is this system even on" gate above, so opening a
  -- menu mid-death freezes the fall/turn exactly where they are instead
  -- of resetting them (a paused tick must never look like "system off").
  if not FirstPerson.onTop() then return end
  if not deathViewHeight then pcall(announceDeath) end -- the alive->dead edge, exactly once
  deathViewHeight = math.max(DEATH_FLOOR_UNITS,
    (deathViewHeight or VIEWHEIGHT_UNITS) - FALL_STEP_PER_FRAME)

  local attacker = DoomHealth.attacker()
  if type(attacker) ~= "table" or not (attacker.px and attacker.py) then return end
  local ok, ow = pcall(function() return require("src.core.Game").overworld end)
  if not (ok and ow and ow.player and ow.player.px and ow.player.py) then return end
  if attacker == ow.player then return end -- never turn toward self
  local dx, dz = attacker.px - ow.player.px, attacker.py - ow.player.py
  if dx == 0 and dz == 0 then return end
  -- Same `atan2(wx, wz)` convention `FirstPerson.bodyBearing` already
  -- uses for a world-space direction -> yaw conversion (confirmed by
  -- reading that function directly, not guessed), so the result is
  -- already in this engine's own yaw convention with no extra
  -- correction needed.
  local targetYaw = math.atan2(dx, dz)
  FirstPerson.yaw = stepAngleToward(FirstPerson.yaw, targetYaw, TURN_STEP_PER_FRAME)
end

-- ------- respawn (G_DoReborn, g_game.c:922-951) -- Phase 15's own
-- central design question, resolved 2026-08-07: the user picked the
-- DOOM-faithful option outright ("doom faitful reload, and all screens
-- game overs, etc should be ported to the mod from doom 1:1 feature
-- parity"). Read `G_DoReborn` fresh to confirm: single-player DOOM
-- (`if (!netgame) { gameaction = ga_loadlevel; }`, g_game.c:928-931) has
-- no separate game-over screen at all -- USE just reloads the CURRENT
-- level. This mod's overworld maps aren't self-contained DOOM levels
-- with one fixed start point.
--
-- CORRECTED, SAME DAY -- the first implementation restated "reload the
-- level" as "warp back to wherever the player first entered this map"
-- (`trackMapStart`, snapshotting position via `mod.world`'s real
-- `WorldAPI:current()`, then `:warpTo` on respawn). Real, concrete user
-- report: "i dided then respawned inside a house (not in the interior,
-- but the model) and had no way out." Root cause: a raw `warpTo` places
-- the player at an exact coordinate with NONE of the guidance normal
-- footstep-by-footstep movement gets (collision-sliding around
-- obstacles, a door's own real arrival offset) -- landing exactly on a
-- snapshotted "first-seen" cell (most often a doorway/threshold, the
-- single riskiest spot on any map for the voxel mesh's own decorative
-- geometry -- a roof overhang, a wall corner -- to extend past the flat
-- 2D collision grid's own idea of "walkable") can genuinely trap the
-- player inside geometry a normal walk there would have slid around.
-- Not a chance worth re-engineering around (verifying walkability with
-- `Map:isWalkableCell` wouldn't catch a purely visual/voxel-geometry
-- overlap the 2D collision grid never modeled in the first place) --
-- fixed by dropping the reposition entirely. `DoomHealth.reborn()`
-- alone (health/armor/attacker reset, no separate game-over screen)
-- keeps the real, important half of "DOOM-faithful, no permadeath
-- screen" intent; the player simply gets back up exactly where they
-- fell -- a position they already validly stood at under real
-- movement/collision, by definition, never a place that can trap them.
-- FIX 2026-08-11 -- direct user request: a "YOU LOST" essential-NPC
-- kill should never allow a respawn at all (load-a-save/quit only), and
-- an ordinary death should only allow it while a real, persistent
-- 3-life budget (`lib/DoomDeathScreen.lua`'s own `Game.save.
-- pokedoomLives`) still has lives left -- once it's exhausted, that
-- screen ALSO switches to load-a-save/quit. `DoomDeathScreen.
-- canRespawn()` is the single source of truth for which case this
-- death currently is (resolved once, on the alive->dead edge, by that
-- file's own `beginDeathScreen`) -- checked here as an extra gate
-- before honoring the USE press, rather than duplicating any of that
-- decision logic in this file.
local function tryRespawn()
  if not Options.enabled() then return end
  if not DoomHealth.isDead() then return end
  if not FirstPerson.onTop() then return end -- pausing freezes this too
  if not DoomDeathScreen.canRespawn() then return end
  local ok, Game = pcall(require, "src.core.Game")
  local input = ok and Game.input
  if not (input and input.wasPressed and input:wasPressed("a")) then return end
  DoomHealth.reborn()
  resetDeathCamera()
end

-- ------- while dead, the only real action is respawn -- everything else
-- world-interactive stays blocked
--
-- FIXED 2026-08-07 -- user report + screenshot: "when the player is dead
-- they can still interact with everything. the only thing they should be
-- able to do is respawn." Real single-player DOOM's own dead player
-- literally can do nothing but reload (`G_BuildTiccmd`'s own real
-- movement/attack fields all stay zero while `playerstate == PST_DEAD`,
-- confirmed already ported -- see `lib/DoomMove.lua`), but this mod's
-- own world has real interactive surface DOOM never did (NPC dialogue,
-- signs, item pickups via walking over them) that had nothing gating it
-- at all. Traced the actual call path: while PKDOOM MODE drives
-- first-person free-roam, `OverworldState:handleInput` isn't even the
-- function running -- the host's own `FreeMove.install` replaces it with
-- `FreeMove.tick` for as long as `FirstPerson.driving()` holds, and THAT
-- function is what reads the real interact/pause presses
-- (`input:wasPressed("a")` -> `state:interact()`, `"start"` -> pushes the
-- pause menu).
--
-- REBUILT 2026-08-19 -- the original fix wrapped `Horde.suppressWorldInput`
-- (a real seam Horde Mode itself used for the identical shape), but the
-- real, current potato_voxel 1.8.2 release has dropped Horde Mode AND
-- that seam's own call site inside `FreeMove.tick` entirely (confirmed
-- directly against that build's own `lib/FreeMove.lua`: `wasPressed("a")`/
-- `("start")` are read completely unconditionally now, no gate of any
-- kind) -- so even a Horde-free version of the old wrap would have had
-- nothing left to hook. Replaced with PokeDoom's own code: wraps the
-- live `FreeMove.tick` field itself (the same "wrap a live host table
-- field" idiom CLAUDE.md already establishes, one level further in) so
-- that while `Options.enabled()` and `DoomHealth.isDead()`, the two
-- specific button reads that function makes are swallowed for the
-- DURATION OF THAT ONE CALL ONLY -- `Game.input:wasPressed(btn)`
-- (`gen1recomp-dev/src/core/Input.lua:382-384`) just reads a plain
-- `self.pressed[btn]` flag, rebuilt fresh once per fixed step and never
-- consumed by reading it, confirmed by that file's own `Input:step()` --
-- so temporarily shadowing it around one synchronous inner call is safe:
-- nothing else reads it while the shadow is active, and this file's own
-- separate `tryRespawn` poll above (a different call, from a different
-- hook, always AFTER this one restores the real function) still sees the
-- real "a" press untouched. Movement itself is untouched either way
-- (`lib/DoomMove.lua`'s own real death gate already zeroes it
-- separately) -- only the interact/pause reads inside this one call are
-- ever swallowed.
local installedDeathInputLock = false
local function installDeathInputLock()
  if installedDeathInputLock then return end
  if not (FreeMove and FreeMove.tick) then return end
  installedDeathInputLock = true
  local inner = FreeMove.tick
  FreeMove.tick = function(state)
    if Options.enabled() and DoomHealth.isDead() then
      local okGame, Game = pcall(require, "src.core.Game")
      local input = okGame and Game and Game.input
      if input and input.wasPressed then
        local realWasPressed = input.wasPressed
        input.wasPressed = function(self, key)
          if key == "a" or key == "start" then return false end
          return realWasPressed(self, key)
        end
        local ok, err = pcall(inner, state)
        input.wasPressed = realWasPressed
        if not ok then error(err, 0) end
        return
      end
    end
    return inner(state)
  end
end

-- ------- "no way" grunt -- pressing use against a wall/floor with
-- nothing on it
--
-- User request: "make it so if you press e on something a wall or
-- floor or something that doesnt have a trigger on it, it has a grunt
-- sound just like the original doom." Real DOOM: `PTR_UseTraverse`
-- (`p_map.c:1095-1123`), called from `P_UseLines` (`p_user.c:326`, the
-- USE key's own real handler) for every solid LINE within `USERANGE`
-- (64 map units -- short-range, essentially "the wall of whichever
-- cell you're facing") that has no special: `P_LineOpening` finds it
-- fully closed (`openrange <= 0`, a genuine solid wall, not an open
-- doorway) and plays `sfx_noway` (`S_StartSound(usething, sfx_noway)`,
-- lump `DSNOWAY` -- `sounds.c:199`, `"noway"`). Crucially, real DOOM
-- stays SILENT when USE is pressed into open space with no line
-- intercepted at all (nothing within `USERANGE`) -- `P_PathTraverse`
-- simply never calls the callback, so `P_UseLines` returns with no
-- sound. The grunt specifically means "I tried to open a solid
-- obstruction and it does nothing," not a generic "nothing happened"
-- cue.
--
-- The host engine's own `OverworldState:interact()` (`gen1recomp-dev/
-- src/world/OverworldController.lua:1729-1801`) already resolves every
-- USE press to a `kind` -- "npc"/"sign"/"door"/"hidden"/"script"/
-- "bookshelf", or "none" if nothing matched -- and emits it as
-- `world.interacted` (that function's own `interacted()` helper, line
-- 1724) regardless of PKDOOM MODE, matching this project's own
-- established "use the host's real exposed hook" seam rather than
-- reimplementing use-detection. `kind == "none"` alone isn't the right
-- gate, though: it also fires for pressing use into open, walkable
-- ground with nothing there, which real DOOM stays silent for. This
-- grid engine's closest real equivalent to "a solid line within
-- USERANGE" is the SAME walkability check the player's own movement
-- collision already uses for that exact cell (`Map:isWalkableCell`) --
-- a genuinely blocked/non-walkable facing cell is this engine's own
-- version of "a solid wall right in front of you," while a
-- walkable-but-empty cell is "open floor," matching DOOM's own real
-- silent case.
local function installUseNowaySound()
  V.mod.events:on("world.interacted", function(payload)
    if not (Options.enabled() and FirstPerson.onTop()) then return end
    if not (payload and payload.kind == "none") then return end
    local ok, Game = pcall(require, "src.core.Game")
    local ow = ok and Game.overworld
    if not (ow and ow.map) then return end
    local walkOk, walkable = pcall(function()
      return ow.map:isWalkableCell(payload.x, payload.y)
    end)
    if walkOk and walkable then return end -- open floor, nothing there -- real DOOM stays silent
    local sndOk, snd = pcall(DoomWadImport.loadSound, "DSNOWAY")
    if sndOk and snd then DoomWadImport.playClone("DSNOWAY (use on nothing)", snd) end
  end)
end

-- ------- no vertical look, matching the original engine
--
-- linuxdoom-1.10 has no pitch/y-shear mechanic anywhere in its renderer:
-- r_main.c's view setup builds the projection from viewangle (yaw) alone
-- (R_SetupFrame/R_ExecuteSetViewSize), there is no equivalent field on
-- player_t for a vertical look angle, and mouse Y motion in the original
-- input code (g_game.c's G_BuildTiccmd) drives forward/back movement, not
-- looking up/down -- true mouselook is a later SOURCE PORT feature, not
-- part of the original 1993/1994 engine this project is porting from.
-- Forced to 0 every frame while PKDOOM MODE is on, both here (the
-- camera's own render) and by construction for anything else that reads
-- FirstPerson.pitch (DoomWeapons.hitscan's aim direction included, since
-- it is the same shared field, read at fire time -- a camera that looks
-- level but a gun that still aims wherever accumulated mouse Y last left
-- it would be a worse bug than not having this at all).
--
-- FEATURE 2026-08-10 -- user request: "add an option to settings for
-- camera and options will be 'locked, freelook' and freelook should
-- actually let you freelook instead of being locked on the y axis." A
-- new CAMERA options row (`lib/DoomOptions.lua`, `Options.
-- freelookEnabled`) now gates this reset -- an explicit, opt-in
-- DEPARTURE from the real-DOOM parity this function otherwise
-- preserves, not a change to the default. `FirstPerson.lookBy` (this
-- same file's own `install`, below) was never the one suppressing
-- pitch -- it always forwarded `dpitch` through to the host's own real
-- accumulator, already clamped by the host itself
-- (`DramaticShapeVoxelMod-dev/lib/FirstPerson.lua`'s own `lookBy`,
-- `PITCH_UP`/its own down clamp) -- ONLY this per-frame reset ever threw
-- that accumulated value away, so simply skipping the reset while
-- FREELOOK is selected is sufficient; nothing else needs to change.
-- Originally (2026-08-10, first round) scoped to the CAMERA only, with
-- weapon aim deliberately left on auto-aim regardless of this setting,
-- given this project's aim/pitch math's own long, hard-won history
-- (CLAUDE.md's own "20 fix attempts" corollary). REVISED the same day,
-- direct user follow-up request: "for freelook, instead of always
-- shooting whats in front of the player, the bullets follows the
-- viewport/gun direction instead because you can fine aim at enemies
-- theres no need for helping aim, just like gzdoom." `lib/DoomWeapons.
-- lua`'s own `hitscan`/`spawnProjectile` now read live `FirstPerson.
-- pitch` directly (no auto-aim search at all) while `Options.
-- freelookEnabled()` holds, matching real GZDoom's own mouselook
-- behavior -- see that file's own matching comments for the full
-- derivation. LOCKED (the default) keeps the existing, extensively-
-- tuned auto-aim path completely untouched, so this revision only ever
-- changes behavior for players who explicitly opted into FREELOOK.
-- Movement stays unaffected either way: `lib/DoomMove.lua` only ever
-- reads `FirstPerson.yaw` for walk direction, never pitch, matching
-- real DOOM's own horizontal-only movement regardless of look angle.
local function lockPitch()
  if Options.enabled() and not Options.freelookEnabled() then
    FirstPerson.pitch = 0
  end
end

-- ------- always first person, no perspective switching, while the mode is on
--
-- The user asked directly: PKDOOM MODE should always show first person
-- and disallow switching to any other camera. `Voxel.level` is the real
-- rung selector (`VoxelState.lua`'s own `Voxel.FP_LEVEL = 6`,
-- `Voxel.TP_LEVEL = 7`, and the ANGLE rungs below that) -- forced back to
-- `Voxel.FP_LEVEL` every single frame the mode is on, the exact same
-- "just keep re-asserting it, every frame, rather than trying to find
-- and intercept every possible way it could change" pattern `lockPitch`
-- above already uses successfully for pitch. This also directly fixes a
-- real, separately-reported symptom: this mod's own weapon/gib overlays
-- were relying on `FirstPerson.cardBlend() > 0.9` to mean "genuinely in
-- first person, not third" -- true for the ORBIT/HEAD blend, but 3RD
-- person turned out to still count as `Voxel3D.camera == rig` (same
-- underlying rig, just boomed back -- `ThirdPerson.lua`), so `cardBlend`
-- alone doesn't actually exclude it. Locking the rung itself removes the
-- whole class of bug at the root instead of chasing every mode check
-- that reads it.
-- CORRECTED 2026-08-06 -- the user's own screenshots proved the game can
-- get PERMANENTLY stuck in the flat 2D fallback while PKDOOM MODE is on
-- (every interior, and after using the SPAWN ENEMY debug row), not just
-- the brief self-resolving load flicker `drawLoadingCover` already
-- covers below. Root cause: `Voxel.setLevel` (called here) only ever
-- wrote THIS module's own mirror of the level (`Voxel.level`, `.goal`,
-- `.from`, `.t`) -- `VoxelState.lua`'s own header comment says outright
-- "The LEVEL is not ours. The engine's render_pipelines plumbing owns
-- it" -- the real, authoritative store is `Pipelines.level("voxel")`
-- (`src/render/Pipelines.lua`), which the engine's own pipeline tick
-- (`DramaticShapeVoxelMod-dev/main.lua:177-183`, `update(dt, level)`)
-- reads FRESH, EVERY FRAME, and feeds straight back into
-- `Voxel.update(dt, level)` -- which itself calls `Voxel.setLevel(level)`
-- again whenever that differs from `Voxel.level`. So the instant
-- anything else in the game sets `Pipelines.level("voxel")` to something
-- other than `FP_LEVEL` (a building interior appears to do exactly this
-- on entry -- plausibly the host mod's own "don't bother voxelizing a
-- single small room" choice for players who never turn PKDOOM MODE
-- on), this function's own direct write here got silently overwritten
-- back on the very next pipeline tick, every single frame, forever --
-- not a one-frame race, a PERMANENT stuck-flat state, because nothing
-- ever corrected the ENGINE's OWN copy to match.
--
-- A near-identical-LOOKING fix (reading/writing `Pipelines` every frame)
-- was tried and reverted earlier the same day as a wrong diagnosis of a
-- DIFFERENT bug -- a brief, self-resolving flicker on fresh map loads,
-- which really was just async terrain-mesh streaming (see
-- `drawLoadingCover`'s own header comment below) and needed no
-- `Pipelines` involvement at all. This is not that: a view that never
-- resolves in an interior no matter how long the player waits, and a
-- view that changes because of an unrelated menu action, are not a
-- loading window -- they are `Pipelines.level("voxel")` itself sitting
-- on the wrong value with nothing left to correct it. Going through the
-- engine's own real setter (`Pipelines.setLevel`, which `Voxel.setLevel`
-- itself is never a substitute for) fixes the value at its actual
-- source, so the pipeline tick has nothing left to fight.
-- FIX 2026-08-12 (real user report on a fresh, non-dev install: "not
-- pushing me to first person and voxel stuck on potato mode and doesnt
-- let me change it. it doesnt get stuck on potato mode without doom
-- mod"). Root cause, confirmed directly from potato_voxel-main's own
-- source: `lib/BrickProfile.lua` defaults to its TrimUI-handheld
-- lockdown on EVERY device unless the `DS_BRICK=0` environment variable
-- was set on the process BEFORE the game booted -- `dev-launch.ps1`
-- does that for a source/dev run, but nothing does it for a packaged,
-- double-clicked `gen1recomp.exe`. That lockdown collapses
-- `VoxelState.lua`'s own real 8-rung ladder
-- (`ANGLES_DEG={0,35,15,35,50,75,75,75}`, `MAX_LEVEL=7`, with 1ST --
-- `Voxel.FP_LEVEL=6` -- and 3RD -- `Voxel.TP_LEVEL=7` -- as real,
-- separate rungs, `VoxelState.lua:45-66`) down to 5 rungs
-- (`{"OFF","HIGH","MEDIUM","LOW","POTATO"}`, `MAX_LEVEL=4`). `Voxel.
-- setLevel` (`VoxelState.lua:148-164`) clamps any requested level to
-- `[0, Voxel.MAX_LEVEL]` -- and `lockFirstPerson` below has always
-- called `Voxel.setLevel(Voxel.FP_LEVEL)` (6) every frame PKDOOM MODE
-- is on. Under the collapsed ladder that clamps straight down to
-- `Voxel.MAX_LEVEL` (4, POTATO) -- exactly the reported symptom: stuck
-- on POTATO, and never actually reaching first person, because level 6
-- no longer exists on the ladder to reach at all.
--
-- This cannot be fixed by having PokeDoom set DS_BRICK itself: the
-- loader (`gen1recomp-dev/src/mods/Loader.lua:942-965`) runs every
-- mod's ENTIRE main.lua synchronously, in dependency order, before the
-- next mod's runs at all. `potato_voxel-main` is an optional dependency
-- of this mod, so its own main.lua -- including `BrickProfile`'s
-- one-time `os.getenv` read, at that module's own load -- has ALREADY
-- finished, in full, before a single line of this mod's own code ever
-- executes. No addon can run before its own host; this has been
-- verified directly against the loader's source, not assumed.
--
-- Fixed here instead, entirely within this mod, using the exact "wrap a
-- live table field" idiom this whole project already uses everywhere a
-- host module needs correcting from outside (CLAUDE.md): restore
-- `Voxel.ANGLES_DEG`/`ANGLE_LABELS`/`MAX_LEVEL`/`HOTKEY_ORDER` to their
-- real, un-collapsed values -- read directly from potato_voxel-main's
-- own `lib/VoxelState.lua:45-48,94` source, not guessed -- mutating the
-- SAME table objects IN PLACE rather than reassigning them, matching
-- `BrickProfile.lua`'s own explicit warning about this exact hazard
-- ("the pipeline record and the rows hook captured the VOXEL ladder by
-- reference... reassigning the table would leave the pipeline reading
-- the old rungs"). Also flips `BrickProfile.brick` itself back to
-- false, so every OTHER live `BrickProfile.isBrick()` check that
-- fork's own main.lua makes per-frame (the FULL-preset's zoom-fit
-- branch, render scale, shadow policy) reads correctly too from here
-- on -- everything touched is a live field already published on
-- `host.exports.brick` (`potato_voxel-main/main.lua:1354`), never a
-- file edit.
--
-- Gated on `Options.enabled()`, same as every other view change in
-- this file (Locked Decision 3: PKDOOM MODE off means nothing about
-- the host's own behavior changes), and applied ONCE, not every frame
-- -- nothing re-collapses these fields afterward, since
-- `BrickProfile.apply()` only ever runs once, at the host's own boot,
-- long before this mod's code can run at all. A genuine Brick-handheld
-- user who explicitly wants the lockdown still gets it: this only ever
-- restores what an UNSET `DS_BRICK` produced by default, and only
-- while PKDOOM MODE is actually on.
-- FIX 2026-08-12, round 2 -- direct user report with a screenshot: even
-- with the VOXEL ladder restored (above), the border walls/hedges
-- around town rendered as flat, tiled cards instead of real 3D geometry
-- -- "no longer voxel like they normally are." Root cause: `BrickProfile.
-- apply()` (`potato_voxel-main/lib/BrickProfile.lua`) doesn't only touch
-- the camera ladder -- it ALSO overwrites `Structures.ROUND_RING`/
-- `HULL_BILLBOARDS`/`BILLBOARD_CROSS` (real desktop defaults, read fresh
-- from `potato_voxel-main/lib/Structures.lua`: `4`/`false`/`false`) to
-- `12`/`true`/`true`, its own documented handheld-frame-budget
-- optimization that collapses every round-carved hull (trees, the
-- border forest ring) into a single flat south-facing billboard card
-- (plus a 45-degree "cross" card) instead of real geometry -- exactly
-- what a "flat textures instead of voxel" report describes. Same root
-- cause as the VOXEL ladder collapse (BrickProfile defaulting on for
-- every desktop, not just a real Brick handheld), so the same fix
-- shape: restore the real values on the SAME live table Structures
-- already is (`host.exports.lib.require("Structures")`), once, while
-- PKDOOM MODE is on -- never touching potato_voxel-main's own file.
--
-- FIX 2026-08-12, round 3 -- direct user request, after the first two
-- rounds: "look for more bugs based on BrickProfile.apply(). sounds
-- like it could be wide spread." It is -- read that whole function
-- fresh (`potato_voxel-main/lib/BrickProfile.lua:93-213`) end to end,
-- and cross-checked every field it touches against that field's own
-- real, desktop-written default in ITS OWN file (never guessed):
--
--   Water.lua setting        real: {"full","sky","off"}   Brick: {"off"} only
--   ForestAtmos.lua setting  real: {"full","low","off"}    Brick: {"off"} only
--   OverworldBattle.lua      real: {true,"flatB","stadium","stadiumB",false}
--     setting ("3D-BTL")            Brick: {false} only -- this is the staged
--                                    3D battle camera CLAUDE.md's own Phase 8
--                                    KILL-mechanic design explicitly names
--                                    (`BattleCam.lua`/`OverworldBattle.lua`)
--   OverworldBattle.lua      real: {false,true}            Brick: {false} only
--     backSetting ("BACK SPRITES")
--   AntiAlias.lua setting    real: {0,2,4}                 Brick: {0} only
--   WorldCurve.lua setting   real: {0,1,2,3}                Brick: {0} only
--   VoxelGrid.lua setting    real: {false,true}             Brick: {false} only
--   ShadowMap.SIZES          real: {1024,1536,2048}         Brick: {512,768,1024}
--   ShadowMap.BRICK_HIGH_RES real: nil                      Brick: 1536 -- read
--     only when `Voxel.level==1`, which under the REAL 8-rung ladder this
--     file already restores above means "FULL", not Brick's old "HIGH" --
--     left at 1536 this would now wrongly clamp the restored FULL preset's
--     shadow to a fixed size instead of the real adaptive SIZES ladder, a
--     new bug the ladder fix alone would have introduced. Restored to nil.
--   ShadowMap.SPRITE_LAYER   real: true    Brick: true -- SAME value, a real,
--     confirmed non-bug (checked, not assumed) -- left untouched.
--   ChunkMesher URGENT/IDLE/COVERED_SLICE  real: 0.012/0.005/0.030
--     (`ChunkMesher.lua`'s own values, read fresh)     Brick: 0.010/0.004/0.040
--     -- perf-only, no visual/feature loss, restored anyway for consistency.
--
-- Every one of these is restored the same proven way: the live table
-- field, mutated in place where other code holds a reference (matching
-- `pin()`'s own in-place `.values`/`.labels`/cleared-`.index` shape, just
-- reversed), never a file edit.
--
-- One thing this CANNOT fix, confirmed by reading `potato_voxel-main/
-- main.lua` directly: T-SHIFT's own render pipeline is never REGISTERED
-- with the engine at all under Brick (`main.lua:358-382`, `if not
-- BrickProfile.isBrick() then mod.content.render_pipelines:register(
-- "tiltshift", ...) end`) -- a ONE-TIME registry write that already
-- didn't happen, made permanent the instant the host finished loading,
-- long before this mod's own code runs. Restoring `TiltShift.LABELS`
-- (still done below, harmless and correct on its own) cannot conjure a
-- pipeline registration that was never made -- the T-SHIFT blur feature
-- itself stays genuinely unavailable until DS_BRICK=0 is set before the
-- game boots (dev-launch.ps1 already does this) or potato_voxel-main's
-- own default changes; not a gap this mod can close from outside.
-- Confirmed the SAME "one-time decision at host boot, not a live field"
-- shape applies to every SETTINGS-derived OPTIONS ROW too (Water, FOREST
-- FX, 3D-BTL, ANTI-ALIAS, WORLD CURVE, V-GRID, BACK SPRITES): `main.lua`'s
-- own `ui.options.rows` hook returns early with `if BrickProfile.isBrick()
-- then return out end` BEFORE the loop that appends any of those rows --
-- but that early-return reads `BrickProfile.isBrick()` LIVE, on every
-- menu open, not a value frozen at boot (confirmed: it is a plain function
-- call inside the hook body, not a captured local) -- so flipping
-- `BrickProfile.brick = false` below (already done since round 1) is
-- enough on its own to let that loop actually run and the real rows
-- reappear, PROVIDED the settings driving them are already restored to
-- their real ladders first -- which is exactly what this round does.
local brickChecked = false
local function restoreVoxelLadderIfCollapsed()
  if brickChecked then return end
  brickChecked = true
  if not (BrickProfile and BrickProfile.isBrick and BrickProfile.isBrick()) then
    return
  end
  local function replaceInPlace(target, values)
    for i = 1, #target do target[i] = nil end
    for i, v in ipairs(values) do target[i] = v end
  end
  replaceInPlace(Voxel.ANGLES_DEG, { 0, 35, 15, 35, 50, 75, 75, 75 })
  replaceInPlace(Voxel.ANGLE_LABELS,
    { "OFF", "FULL", "15", "35", "50", "75", "1ST (EXPERIMENTAL)", "3RD (EXPERIMENTAL)" })
  Voxel.MAX_LEVEL = #Voxel.ANGLES_DEG - 1
  replaceInPlace(Voxel.HOTKEY_ORDER, { 0, 2, 3, 4, 5, 6, 7 })
  BrickProfile.brick = false
  if Structures then
    Structures.ROUND_RING = 4
    Structures.HULL_BILLBOARDS = false
    Structures.BILLBOARD_CROSS = false
  end
  local function unpin(setting, values, labels)
    if not (setting and setting.setting) then return end
    setting.setting.values = values
    setting.setting.labels = labels
    setting.setting.index = nil
  end
  unpin(HostWater, { "full", "sky", "off" }, { "FULL", "SKY", "OFF" })
  unpin(ForestAtmos, { "full", "low", "off" }, { "FULL", "LOW", "OFF" })
  unpin(OverworldBattle, { true, "flatB", "stadium", "stadiumB", false },
    { "2D-3D A", "2D-3D B", "STADIUM A", "STADIUM B", "OFF" })
  if OverworldBattle and OverworldBattle.backSetting then
    OverworldBattle.backSetting.values = { false, true }
    OverworldBattle.backSetting.labels = { "OFF", "ON" }
    OverworldBattle.backSetting.index = nil
  end
  unpin(AntiAlias, { 0, 2, 4 }, { "OFF", "2X", "4X" })
  unpin(WorldCurve, { 0, 1, 2, 3 }, { "OFF", "1", "2", "3" })
  unpin(VoxelGrid, { false, true }, { "OFF", "ON" })
  if HostTiltShift then
    replaceInPlace(HostTiltShift.LABELS, { "OFF", "1", "2", "3" })
  end
  if HostChunkMesher then
    HostChunkMesher.URGENT_SLICE = 0.012
    HostChunkMesher.IDLE_SLICE = 0.005
    HostChunkMesher.COVERED_SLICE = 0.030
  end
  if ShadowMap then
    replaceInPlace(ShadowMap.SIZES, { 1024, 1536, 2048 })
    ShadowMap.BRICK_HIGH_RES = nil
  end
end

local function lockFirstPerson()
  if not Options.enabled() then return end
  restoreVoxelLadderIfCollapsed()
  local Pipelines = require("src.render.Pipelines")
  if Pipelines.level("voxel") ~= Voxel.FP_LEVEL then
    Pipelines.setLevel("voxel", Voxel.FP_LEVEL)
  end
  if Voxel.level ~= Voxel.FP_LEVEL then
    Voxel.setLevel(Voxel.FP_LEVEL)
  end
end

-- **First fix attempt, 2026-08-06, reverted the same day -- wrong root
-- cause, and the user correctly flagged the extra per-frame `Pipelines`
-- read/write as unwarranted cost for something that turned out not to
-- be the actual mechanism.** That attempt assumed a persistent tug-of-
-- war between `Voxel.level` and a separate `Pipelines.level("voxel")`
-- store. The user's own follow-up report corrected the premise: the
-- flat-2D view only ever showed on game BOOT and on entering a shop/
-- interior, always for "a few seconds," then resolved into first person
-- on its own -- a brief, self-resolving, LOAD-tied window, not a
-- persistent per-frame fight. That description doesn't match a level
-- desync (which would either be wrong forever or flicker every frame,
-- not clear itself after a few seconds) -- it matches the engine's own
-- real async terrain-mesh streaming instead, confirmed by reading
-- `FirstPerson.update` and `VoxelScene.lua` directly:
--   - `VoxelScene.lua:489`: `Voxel.ready = terrain ~= nil`, where
--     `terrain` comes from `ChunkMesher.pair(state.map, ...)` -- the
--     CURRENT map's own terrain mesh, built asynchronously (`main.lua`'s
--     own voxel pipeline registration comment: "Builds are asynchronous
--     (ChunkMesher.pump runs in the pipeline's update): request what
--     this frame wants and draw what is ready... the old synchronous
--     build froze the first frame for seconds").
--   - `FirstPerson.lua:478-484`: the dive-in blend's own target is
--     forced back to 0 (flat) for as long as `blend==0 and not Voxel.
--     ready` -- i.e. the camera literally CANNOT start diving into 3D
--     until the current map's own mesh has finished streaming in,
--     REGARDLESS of which rung `Voxel.level`/`Pipelines.level` say is
--     selected. This is a genuinely separate gate from the rung
--     selector this file already locks -- a real, expected, unavoidable
--     loading window on a fresh map load (boot, or any warp into a new
--     map's own geometry), not a bug in the level-locking logic at all.
--
-- Forcing `Voxel.ready = true` early would be worse, not better --
-- it would show genuinely unfinished/missing terrain instead of a
-- clean brief cover. The real fix (below, `drawLoadingCover`) accepts
-- that this loading window is real and unavoidable, and instead makes
-- sure PKDOOM MODE never shows the raw flat 2D fallback DURING it --
-- painting over it with a plain screen-space cover until the dive-in
-- genuinely completes, the same "PKDOOM MODE should always show first
-- person, never anything else" request this whole section already
-- exists to satisfy.

-- ------- refusing the perspective-cycle key at its own source, not just
-- reasserting after the fact
--
-- `lockFirstPerson` above (an every-frame "put it back" reassertion) is
-- what fixed "doesn't spawn in as first person" -- but the user separately
-- reported still being able to CHANGE perspective with the pad's SELECT
-- button while PKDOOM MODE is on.
--
-- REBUILT 2026-08-19 -- the original fix wrapped `Horde.viewLocked`
-- (Horde Mode's own way of holding the camera at 1ST person for as long
-- as it runs), reused because the host's own `cycleVoxel` checked it
-- directly. On the real, current potato_voxel 1.8.2 release, Horde Mode
-- is gone AND `cycleVoxel` itself has moved and been rebuilt (confirmed
-- directly, not assumed): it now lives inside `lib/InputFeature.lua`'s
-- own `InputFeature.new(ctx)` factory closure, so there's no longer a
-- single shared module-level function to monkey-patch by name the way
-- `Horde.viewLocked` used to be. Traced every real caller of that
-- closure instead of chasing the closure itself: BOTH the keyboard
-- hotkey path (`InputFeature.lua:48`) and the VR stick-click path
-- (`InputFeature.lua:109`) gate through the exact same call --
-- `Pipelines.canToggle("voxel", top, overworld)`
-- (`gen1recomp-dev/src/render/Pipelines.lua:293-298`) -- a real, public,
-- BASE-ENGINE function (not a host-mod one, so this fix no longer
-- depends on any particular host fork's own internal shape at all,
-- unlike the Horde-based version it replaces), that function's own header
-- comment confirming exactly this role: "Whether the player may cycle
-- this mode right now: the free-roam gate, which keeps a hotkey press
-- from switching modes mid-warp or mid-cutscene." Wrapped here to ALSO
-- return false for `id == "voxel"` specifically (the camera-rung
-- pipeline `main.lua:261` registers) whenever `Options.enabled()` holds
-- -- every OTHER registered pipeline (`5`/`7`/`9`'s own VoxelGrid/
-- WorldCurve/Water toggles) passes through untouched, so this only ever
-- blocks the ONE mechanic PKDOOM MODE actually needs locked. Blocks the
-- cycle at its real, current source for every trigger path at once, the
-- same intent the original Horde-based fix had; `lockFirstPerson` stays
-- in place as a second, redundant safety net for any path this doesn't
-- cover.
local function installViewLock()
  local ok, Pipelines = pcall(require, "src.render.Pipelines")
  if not (ok and Pipelines and Pipelines.canToggle) then return end
  local inner = Pipelines.canToggle
  Pipelines.canToggle = function(id, top, overworld)
    if id == "voxel" and Options.enabled() then return false end
    return inner(id, top, overworld)
  end
end

-- ------- the seam
--
-- rig.eye and rig.focus are BOTH shifted by the same amount, not just
-- eye: DOOM's bob translates the whole view vertically at a constant
-- pitch (it changes viewz, not the look angle), so shifting eye alone
-- while focus stays put would tilt the camera every time the bob moved
-- instead of just bouncing it.

local installed = false
local wasEnabled = false

function DoomView.install()
  if installed then return end
  installed = true

  installViewLock()
  installDeathInputLock()
  installUseNowaySound()

  -- `FirstPerson.frame` (wrapped below) turned out to be the WRONG place
  -- for `lockFirstPerson`/the enable-edge check: it's only called from
  -- `VoxelScene.render`, which itself only runs while the voxel 3D pass
  -- is actually rendering (`VoxelScene.lua:942`) -- meaning it's SKIPPED
  -- ENTIRELY whenever `Voxel.level` is OFF or on a non-voxel rung, the
  -- exact state this lock most needs to recover FROM. Confirmed by the
  -- user still being able to leave first person entirely. `input.step`
  -- (`gen1recomp-dev/src/core/Game.lua:187`) is a genuine every-tick game
  -- hook, independent of what's currently rendering -- the same reason
  -- `lib/DoomWeapons.lua`/`lib/DoomKill.lua` already use it for their own
  -- always-on bookkeeping. It fires from `love.update`, strictly before
  -- `love.draw` in LOVE's own frame order, so forcing the rung back here
  -- lands before that same frame ever renders -- no visible flicker, not
  -- just a same-frame race hoped to work out.
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local enabledNow = Options.enabled()
    -- Freshly turning on (including "just reloaded a save with the
    -- option already on", which looks identical to this frame -- there
    -- is no separate save-load hook to key off instead) is exactly when
    -- bobOffset's own stale lastPx/lastPy needs clearing -- see
    -- resetBob's own header comment.
    if enabledNow and not wasEnabled then resetBob() end
    wasEnabled = enabledNow
    pcall(tickDeathCamera)
    pcall(tryRespawn)
    pcall(tickShake, dt)
    pcall(checkDamageShake)
    local results = { next(game, dt) }
    -- CORRECTED 2026-08-06 (second round the same day -- the user's own
    -- "both bugs are still present" after the first `Pipelines.setLevel`
    -- fix): moved from BEFORE `next(game, dt)` to AFTER it. `next` is
    -- this mod's OWN chain toward whatever else has already wrapped
    -- `input.step`, all the way down to the ENGINE's real, base
    -- `input.step` (`gen1recomp-dev/src/core/Game.lua:187`) -- which is
    -- where an interior transition, or a menu closing and re-syncing
    -- `Pipelines.level("voxel")` from `save.options.pipelines.voxel`
    -- (confirmed real: `DramaticShapeVoxelMod-dev/tests/
    -- dramatic_shape_test.lua`'s own "the level is written back to
    -- save.options" / "a restored save restores the mode" tests), most
    -- plausibly actually lives. Reasserting the lock BEFORE `next()` (the
    -- original order) meant any such change made THAT function's own
    -- call was the true last word for the frame, not this lock -- a
    -- STABLE (not flickering) stuck-flat result is exactly what "loses an
    -- every-frame race, every single frame" looks like, matching what
    -- was actually observed. Asserting it AFTER `next()` returns instead
    -- makes this lock the genuine last word before the frame renders,
    -- regardless of what else touches the level anywhere in that whole
    -- chain -- closing the entire class of "something later in the same
    -- frame undoes it" bug, not just the one specific cause already
    -- found.
    pcall(lockFirstPerson)
    return (table.unpack or unpack)(results)
  end)

  local inner = FirstPerson.frame
  function FirstPerson.frame(me, cx, cy, vw, vh)
    lockPitch()
    local rig, sx, sy = inner(me, cx, cy, vw, vh)
    if not (rig and Options.enabled()) then return rig, sx, sy end
    rig.fov = rig.fov * DoomView.fovMultiplier
    if me then
      local shift = bobOffset() + deathEyeShift() + shakeOffset()
      rig.eye[2] = rig.eye[2] + shift
      rig.focus[2] = rig.focus[2] + shift
    end
    return rig, sx, sy
  end

  -- The other half of P_PlayerThink's dead-player branch (p_user.c:258-
  -- 262): real DOOM never calls P_MovePlayer while `playerstate ==
  -- PST_DEAD`, and `cmd->angleturn` is only ever consumed inside that
  -- function -- so mouse/stick look has no effect on a dead player's own
  -- view angle at all; ONLY `tickDeathCamera`'s own scripted 5-degree-
  -- per-tic turn (above) moves it. `lookBy` is this engine's own real
  -- yaw/pitch input entry point (confirmed: `FirstPerson.yaw =
  -- wrapPi(FirstPerson.yaw + dyaw)`), the same live-table-field wrap
  -- idiom this whole codebase already uses.
  local innerLookBy = FirstPerson.lookBy
  FirstPerson.lookBy = function(dyaw, dpitch)
    if Options.enabled() and DoomHealth.isDead() then return end
    return innerLookBy(dyaw, dpitch)
  end
end

-- ------- covering the unavoidable async-load window, instead of
-- fighting it
--
-- See `lockFirstPerson`'s own header comment above for the full
-- diagnosis: while `Voxel.ready` is false (the current map's own
-- terrain mesh is still streaming in, `VoxelScene.lua:462-490`),
-- `FirstPerson.blend` cannot start easing toward 1 at all
-- (`FirstPerson.lua:478-484`) -- a real, expected, brief window on any
-- fresh map load, not something to force past. Painting a plain
-- screen-space cover over the WHOLE frame for as long as blend hasn't
-- reached 1 yet means the player only ever sees black-then-first-
-- person, never the raw flat 2D fallback underneath -- satisfying
-- "PKDOOM MODE should always show first person, never anything else"
-- without touching the async mesh system at all.
--
-- CORRECTED 2026-08-07, THE REAL ROOT CAUSE -- user report: "the bug
-- where gameboy view is still active on first interior load is still
-- in place... this bug has been 'fixed' atleast 5 times... this needs
-- a fix that will actually work." Every previous attempt (this file's
-- own log has the full history) treated this as a RUNG/mode desync --
-- `Voxel.level`, `Pipelines.level("voxel")`, `FirstPerson.driving()`/
-- `engaged()`/`onTop()` -- and kept missing because none of those were
-- ever actually the broken variable. Traced this round via the actual
-- top-level render dispatch, not the mode flags: `OverworldController.
-- lua`'s own per-frame draw (~line 4629-4727) calls the voxel
-- pipeline's `drawWorld` -> `VoxelScene.render`, and -- confirmed
-- directly in that function's own header comment, `VoxelScene.lua:888-
-- 894` -- "With nothing cached at all... return nil: the engine keeps
-- the 2D path for the frame." **The classic flat 2D path is NOT gated
-- behind a mode check at all -- it draws unconditionally, inline,
-- every time the voxel pass returns nil for that frame**
-- (`OverworldController.lua:4712-4727`). So the real question was never
-- "which mode is selected" (always correctly FP_LEVEL under this mod's
-- own lock) -- it's "did `VoxelScene.render` actually have terrain to
-- draw THIS frame," which is `Voxel.ready` (`VoxelScene.lua:489`, a
-- LIVE per-map flag: `Voxel.ready = (ChunkMesher.pair(state.map,...) ~=
-- nil)`, freshly false again the instant a NEW map's terrain isn't
-- built yet).
--
-- This cover's own gate used to be `FirstPerson.blend >= 1`, on the
-- assumption blend tracks "is the dive-in visually complete" faithfully
-- forever. It doesn't. Read `FirstPerson.lua:478-484` fresh: `local
-- target = engagedNow and 1 or 0; if target > FirstPerson.blend and
-- FirstPerson.blend == 0 and not Voxel.ready then target = 0 end` --
-- that "hold at flat while unready" override ONLY EVER FIRES WHEN
-- `blend == 0`, i.e. only on the very FIRST dive-in of the whole play
-- session. Under this mod's own permanent rung-lock (`lockFirstPerson`
-- above), `engaged()` never toggles back off once first entered, so
-- `blend` reaches 1 exactly once and then SITS at 1 forever across
-- EVERY later map transition -- including every door -- regardless of
-- whether that NEW map's own terrain is ready. `blend` is a one-time
-- session flag, not a per-map readiness signal, and this cover was
-- reading it as if it were the latter. That's why every flag-based fix
-- kept missing: `Voxel.level`, `onTop()`, `driving()`, and `blend`
-- itself all read "correct" throughout an interior load; the ACTUAL
-- desynced variable was never checked directly.
--
-- Real, previously-unproven mechanical detail this also explains why
-- it's specifically INTERIORS and specifically the FIRST one of a kind:
-- outdoor maps are proactively meshed via `OverworldState.
-- computeNeighbors`'s neighbor graph while walking, usually already
-- cached by arrival; an interior is only ever reached through a warp,
-- is never in that neighbor list, and its mesh build only starts the
-- instant the door fires -- racing the transition, with a real
-- additional cold `ChunkMesher`/texture-atlas cost paid the first time
-- that specific tileset is ever seen this session.
--
-- Fixed by checking `Voxel.ready` DIRECTLY instead of `blend` -- the
-- real, live, per-map signal `VoxelScene.render` itself keys off, with
-- no one-time-latch behavior to go stale. `onTop()` (not `engaged()`,
-- see the previous round's own reasoning, still valid) is kept as the
-- real "don't black out an actual menu" protection.
local function drawLoadingCover()
  if not Options.enabled() then return end
  if not FirstPerson.onTop() then return end
  if Voxel.ready then return end
  love.graphics.setColor(0, 0, 0, 1)
  love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())
  love.graphics.setColor(1, 1, 1, 1)
end

-- Separate from `DoomView.install()` on purpose: this has to be the
-- OUTERMOST `love.draw` wrap (drawn dead last, on top of literally
-- everything, including this mod's own HUD) to actually cover the
-- screen, and Lua's own "wrap whatever love.draw currently is" idiom
-- means whichever install() call runs LAST becomes outermost. `lib/
-- DoomHud.lua`'s own `love.draw` wrap is otherwise the last one this mod
-- installs (confirmed: only it and `lib/DoomWeapons.lua` touch
-- `love.draw` directly, and `DoomHud.install()` already runs after
-- `DoomWeapons.install()`) -- so `main.lua` calls this function last,
-- after every other `.install()`, to sit above even that.
local installedCover = false
function DoomView.installLoadingCover()
  if installedCover then return end
  installedCover = true
  local inner = love.draw
  love.draw = function(...)
    if inner then inner(...) end
    pcall(drawLoadingCover)
  end
end

return DoomView
