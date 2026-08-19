-- PokeDoom Phase 9: movement port -- DOOM's real momentum-based walking,
-- ported per CLAUDE.md's porting-methodology hard rule (originally
-- written specifically for this phase, since generalized at the user's
-- own request to cover every DOOM-derived mechanic this project ports):
-- the bar is functional 1:1 parity with what DOOM's real source code
-- actually does, researched fresh from `DOOM-master/linuxdoom-1.10` at
-- the point of use -- but which system IMPLEMENTS that behavior is an
-- open choice, judged only on whether it actually reproduces DOOM's real
-- behavior, with no default preference toward the host engine or
-- anything else. See phases/phase-9-movement-port.md for the full audit
-- this design is built on -- read fresh again here at the point of use
-- rather than trusted from that doc, per the project's own hard rule
-- that a past derivation can carry forward a mistake.
--
-- This REVERSES the 2026-08-04 rescoping note at the top of CLAUDE.md
-- ("movement is entirely the host's, untouched") at the user's own later
-- request. Nothing from that deleted movement code is reused here --
-- every constant below is re-derived fresh from source.
--
-- ------- what's ported, and what isn't
--
-- Ported: momentum (accelerate under thrust, coast/decay under
-- friction), the walk/run speed tiers, DOOM's real per-axis
-- (not combined-magnitude) speed clamp, the slide-to-a-stop persisting
-- all the way to zero after input releases (not an instant halt --
-- see the `FirstPerson.moveVector` wrap in `install()` below, added
-- 2026-08-05 after the user reported movement stopping dead the instant
-- a key was released instead of coasting down like real DOOM), and the
-- real per-tic ordering between "move using CURRENT momentum" and
-- "decay momentum for NEXT tic" (see `updateMomentum`'s own header
-- comment, fixed the same round).
--
-- NOT ported: DOOM's own digital `angleturn[]` key-turn constants
-- (`g_game.c:177`). Audited in phases/phase-9-movement-port.md: those
-- constants are for DOOM's DIGITAL key/joystick turning specifically;
-- DOOM's own MOUSE turning is a separate, already-continuous path
-- (`cmd->angleturn -= mousex*0x8`, g_game.c:409) -- much closer in spirit
-- to this engine's existing continuous mouse/stick-driven
-- `FirstPerson.yaw` than the stepped digital constants are. Forcing
-- DOOM's digital key-turn feel onto a mouse-driven camera would be a
-- REGRESSION in feel, not a parity fix, so turning is left exactly as
-- this engine's own FirstPerson.lua already handles it, untouched.
--
-- ------- the seam: FirstPerson.moveWorld, not a fork of FreeMove
--
-- `FreeMove.tick` (`DramaticShapeVoxelMod-dev/lib/FreeMove.lua:239-355`)
-- is a large function: input intent, momentum (until now, none), the
-- collision-aware axis-separated slide (`slideX`/`slideZ`), cell-arrival
-- (`onStepComplete`), and the blocked-push special moves (edge exits,
-- ledge hops, boulder pushes, collision warps) -- all real, all correct,
-- all worth keeping exactly as they are; forking that logic into this
-- file would be exactly the host-duplication CLAUDE.md's hard rule warns
-- against, and would silently drift out of sync with any future fix to
-- the host's own collision handling.
--
-- Confirmed by reading the file directly: `FreeMove.tick`'s own line
-- `local wx, wz = FirstPerson.moveWorld(mx, mz)` is the ONE point where
-- "how hard is the player pushing, in camera space" becomes "which way
-- and how far to try to move, in world space" -- and `FirstPerson.
-- moveWorld` (`FirstPerson.lua:452-455`) is a small, pure rotation with
-- no side effects, confirmed to have exactly ONE real caller in the
-- entire host mod (`FreeMove.lua:280` -- `ThirdPerson.lua`/`VR.lua` only
-- mention it in comments, grepped directly, not assumed). Wrapping it
-- (a live table field, the same monkey-patch idiom this whole codebase
-- already uses) lets this file own WHAT velocity is being asked for --
-- DOOM's own accelerate/friction curve instead of FreeMove's own
-- instant-on/off raw input -- while `slideX`/`slideZ`/warps/ledges/
-- cell-arrival all keep running, completely untouched, on WHATEVER
-- velocity this file hands back. `FreeMove.tick` itself still multiplies
-- the result by its own WALK/BIKE speed constant afterward -- this file
-- pre-divides by that same constant so the multiplication cancels out,
-- rather than mutating `Game.save.onBike` to force it off (DOOM has no
-- bike concept at all, so this mode's own momentum simply replaces
-- whatever speed tier the bike toggle would have picked, without
-- touching the player's own bike preference for when they leave this
-- mode).

local V = ...
local Host = V.host
local FirstPerson = Host.require("FirstPerson")
local FreeMove = Host.require("FreeMove")
local Options = V.require("DoomOptions")
local DoomHealth = V.require("DoomHealth")

local DoomMove = {}

-- ------- constants, derived fresh from DOOM-master/linuxdoom-1.10
--
-- P_Thrust (p_user.c:55-68): `momx += FixedMul(move, finecosine[angle])`
-- where `move = cmd->forwardmove*2048` (forward) or `cmd->sidemove*2048`
-- (strafe, at angle-90) -- FRACUNIT-scale (65536) thrust ADDED to
-- momentum every tic, independently per axis (no diagonal normalization
-- between forward and side).
--
-- G_BuildTiccmd (g_game.c:175-176): `forwardmove[2] = {0x19, 0x32}` =
-- {25, 50} (walk, run); `sidemove[2] = {0x18, 0x28}` = {24, 40}.
--
-- P_XYMovement (p_mobj.c:109-241): `MAXMOVE = 30*FRACUNIT`
-- (`p_local.h:54`) clamps momx/momy INDEPENDENTLY per axis (not the
-- combined vector magnitude -- confirmed by reading the actual clamp,
-- two separate `if` statements, not one against `sqrt(momx^2+momy^2)`).
-- `FRICTION = 0xe800` (`p_mobj.c:112`) multiplies momentum every tic
-- while on the ground (always true here -- no jump in this mod's
-- scope). `STOPSPEED = 0x1000` (`p_mobj.c:111`) is the threshold below
-- which momentum snaps to exactly 0, but ONLY when no input is held
-- (`p_mobj.c:221-227`: both axes below STOPSPEED AND
-- `cmd.forwardmove==0 && cmd.sidemove==0`).
--
-- doomdef.h:122: `TICRATE = 35`.
local FRACUNIT = 65536
local DOOM_TICRATE = 35
local FRAME_RATE = 60

local FORWARDMOVE = { 25, 50 } -- {walk, run}, raw cmd units
local SIDEMOVE = { 24, 40 }
local THRUST_FIXED_PER_CMD = 2048 -- P_Thrust's own multiplier
local MAXMOVE_DOOM_UNITS = 30 -- MAXMOVE / FRACUNIT
local FRICTION_DOOM = 0xe800 / FRACUNIT -- 0.90625, per DOOM TIC
local STOPSPEED_DOOM_UNITS = 0x1000 / FRACUNIT -- 0.0625

-- Friction compounds once per DOOM tic (35/sec); this engine ticks
-- movement once per rendered frame (60/sec, `FreeMove.tick`'s own real
-- cadence). Re-derived to the SAME real-time decay curve rather than
-- reused as a raw per-tic multiplier applied once per frame (which would
-- decay far too slowly at 60Hz vs DOOM's own 35Hz) -- the same "more,
-- smaller frames instead of fewer, bigger tics" conversion this
-- project's other DOOM-tic ports already use (Phase 1's view bob, Phase
-- 2/3's weapon `ticsFor`), just applied to a MULTIPLICATIVE decay
-- instead of an additive tic count: solving `FRICTION^60 ==
-- FRICTION_DOOM^35` for FRICTION gives `FRICTION_DOOM^(35/60)`.
local FRICTION = FRICTION_DOOM ^ (DOOM_TICRATE / FRAME_RATE)

-- No principled DOOM-map-unit-to-world-px conversion exists (CLAUDE.md's
-- "Nature of the port") -- so, matching Phase 1's own bob-peak precedent
-- (a PROPORTION of a host reference, not a literal unit conversion),
-- this anchors PKDOOM's own walk-forward EQUILIBRIUM speed (the steady
-- speed continuous forward thrust settles into once accelerate and
-- friction balance) to a multiple of `FreeMove.WALK`, world-units per
-- 60Hz frame.
--
-- At equilibrium, momentum next frame equals momentum this frame:
-- `eq*FRICTION + thrust == eq`, so `thrust == eq*(1-FRICTION)`. Every
-- other tier (run, strafe walk, strafe run) uses DOOM's own REAL ratios
-- against forwardmove-walk (25) as the reference "1.0", so every real
-- DOOM asymmetry (run is exactly 2x forward thrust; strafe is very
-- slightly SLOWER than forward at walk speed but proportionally MORE so
-- at run speed -- 24/25=0.96 vs 40/50... against the SAME 25 baseline,
-- 40/25=1.6) carries over exactly, scaled by the one chosen anchor.
--
-- **The multiplier itself is an honest judgment call, not a re-derived
-- fact** -- same category as the projectile-speed constants further down
-- this project's own weapon file, "tuned against this mod's own existing
-- motion references, not a formula dressed up to look derived." The
-- original anchor (a bare 1x `FreeMove.WALK`, this mod's ordinary
-- overworld walking pace) read visibly too slow once the user directly
-- compared this port's movement against real DOOM gameplay footage --
-- unsurprising in hindsight, since `FreeMove.WALK` was tuned for a
-- Pokemon-style overworld's own pace, not an early-90s FPS's. Bumped to
-- 2x here (i.e. this mode's own normal walk now moves at the SAME speed
-- the host's own BIKE already does elsewhere in this game -- a real,
-- already-familiar reference point to gauge against, not a number picked
-- from nowhere) as a first retuning attempt -- confirm against the
-- headset and adjust again if it still doesn't read as DOOM-fast enough
-- (or overshoots), the same iterate-after-playtest loop every other
-- judgment call in this project already goes through.
local WALK_EQUILIBRIUM = FreeMove.WALK * 2
local THRUST_SCALE = WALK_EQUILIBRIUM * (1 - FRICTION) / FORWARDMOVE[1]
local FORWARD_THRUST = { THRUST_SCALE * FORWARDMOVE[1], THRUST_SCALE * FORWARDMOVE[2] }
local SIDE_THRUST = { THRUST_SCALE * SIDEMOVE[1], THRUST_SCALE * SIDEMOVE[2] }

-- DOOM's real MAXMOVE sits ~1.8x above its OWN real run-forward
-- equilibrium (`(50*2048/FRACUNIT) / (1-FRICTION_DOOM)`) -- headroom
-- that only matters for diagonal thrust (forward+side combine) or other
-- high-thrust edge cases, since straight walking/running alone never
-- reaches it. Applied here as the SAME proportional headroom above THIS
-- port's own run-forward equilibrium, not DOOM's literal 30.
local DOOM_RUN_THRUST_UNITS = FORWARDMOVE[2] * THRUST_FIXED_PER_CMD / FRACUNIT
local DOOM_RUN_EQUILIBRIUM = DOOM_RUN_THRUST_UNITS / (1 - FRICTION_DOOM)
local MAXMOVE_HEADROOM = MAXMOVE_DOOM_UNITS / DOOM_RUN_EQUILIBRIUM
local RUN_EQUILIBRIUM = WALK_EQUILIBRIUM * (FORWARDMOVE[2] / FORWARDMOVE[1])
local MAXMOVE = RUN_EQUILIBRIUM * MAXMOVE_HEADROOM

-- DOOM's real STOPSPEED is ~0.2% of its own MAXMOVE -- applied as the
-- same proportion of this port's own MAXMOVE, functionally just a
-- "clean up floating-point-style residual creep" threshold either way,
-- not something meant to meaningfully gate anything on its own.
local STOPSPEED = MAXMOVE * (STOPSPEED_DOOM_UNITS / MAXMOVE_DOOM_UNITS)

-- ------- shared bob magnitude, for other files (the weapon sway)
--
-- Real DOOM's `player->bob` (`P_CalcHeight`, p_user.c:49-57) --
-- `(FixedMul(momx,momx)+FixedMul(momy,momy))>>2`, capped at `MAXBOB =
-- 0x100000` (16.0 map units) -- is ONE shared per-player value read by
-- BOTH the view-height code (already ported, Phase 1's `lib/DoomView.
-- lua`) AND `A_WeaponReady`'s own weapon sway (p_pspr.c:329-333).
-- Exposed here as a 0..1 FRACTION of that cap (this mod's own momentum
-- isn't expressed in DOOM's map units, so the raw value has no direct
-- meaning outside this file) so `lib/DoomWeapons.lua` can read "how
-- saturated is the real DOOM bob effect right now" for its own sway,
-- rather than re-deriving momentum math of its own.
--
-- DOOM's real bob reaches its own MAXBOB at momentum magnitude
-- `sqrt(4*16) = 8.0` map-units/tic -- notably BELOW DOOM's own real
-- walk-forward equilibrium (8.33, `DOOM_RUN_EQUILIBRIUM`'s own sibling
-- at the walk tier) -- i.e. real DOOM's weapon sway is very nearly
-- ALWAYS at full amplitude the instant the player is walking at a
-- normal pace, only visibly ramping up in the first instant of
-- accelerating from a stop. Converted to this mod's own scale via the
-- SAME `RUN_EQUILIBRIUM`/`DOOM_RUN_EQUILIBRIUM` ratio already anchoring
-- every other speed constant in this file (walk or run tier gives the
-- identical ratio, since both are proportional to the same anchor).
local DOOM_TO_MOD_SPEED_SCALE = RUN_EQUILIBRIUM / DOOM_RUN_EQUILIBRIUM
local DOOM_MAXBOB_UNITS = 0x100000 / FRACUNIT -- 16.0, matches Phase 1's own MAXBOB_UNITS
local BOB_SATURATION_SPEED = math.sqrt(4 * DOOM_MAXBOB_UNITS) * DOOM_TO_MOD_SPEED_SCALE
-- `DoomMove.bobFraction()` itself is defined further down, right after
-- `momX`/`momZ` (Lua has no hoisting for locals -- it needs to close
-- over those, not the constants above, which is why the FUNCTION isn't
-- here even though the constants it uses are).

-- ------- raw move intent: independent per axis, NOT `moveVector()`'s
-- own normalized output
--
-- `FirstPerson.moveVector()` NORMALIZES its keyboard result
-- (`FirstPerson.lua:440-443`: `mx/mag, mz/mag`) -- a diagonal keyboard
-- press already comes back reduced to ~0.707 per axis, matching a
-- SINGLE direction's own magnitude. Real DOOM's forwardmove/sidemove are
-- NOT normalized against each other: `G_BuildTiccmd` (g_game.c:283-325)
-- adds the FULL forwardmove/sidemove value independently per held key,
-- so pressing forward+strafe together thrusts with BOTH at full
-- strength simultaneously -- diagonal movement is genuinely faster in
-- raw thrust (though FRICTION's own equilibrium and the MAXMOVE clamp
-- still bound how far that actually goes). This exact point was a real,
-- found-and-fixed bug in this project's own now-deleted 2026-08-04
-- movement code (see phases/phase-9-movement-port.md's own checklist) --
-- re-verified against the real source here, not trusted from memory of
-- that earlier fix.
--
-- Stick/touch input is left to `moveVector()`'s own existing analog
-- handling unchanged: an analog deflection has no real DOOM
-- keyboard-boolean equivalent to diverge from in the first place, and
-- `moveVector()`'s own dead-zone/priority logic (stick, then a private
-- touch-drag local this file cannot reach anyway) is exactly the
-- established, correct behavior for those input types. Only when this
-- file's OWN direct read of the arrow-key buttons finds something held
-- does it override with the un-normalized pair -- keyboard is the one
-- case actually needing the fix.
local function rawIntent()
  local ok, Game = pcall(require, "src.core.Game")
  local input = ok and Game.input or nil
  if not (input and input.isDown) then return 0, 0 end
  local mx = (input:isDown("right") and 1 or 0) - (input:isDown("left") and 1 or 0)
  local mz = (input:isDown("up") and 1 or 0) - (input:isDown("down") and 1 or 0)
  if mx ~= 0 or mz ~= 0 then return mx, mz end
  -- `realMoveVector`, NOT the live `FirstPerson.moveVector` field --
  -- once `install()` wraps that field (see its own header comment
  -- below), the live version can report a FAKE residual-momentum
  -- vector while the player is coasting to a stop with no real input
  -- held, specifically so `FreeMove.tick`'s own `moving` check keeps
  -- applying that momentum. If THIS function read the live wrapped
  -- version instead of the real one, that fake vector would loop back
  -- in here as if it were genuine fresh stick/touch input and get
  -- THRUSTED again every frame -- the slide would never actually decay,
  -- coasting forever instead of sliding to a stop. Reading the
  -- unwrapped real function is what makes "no real input" correctly
  -- mean "apply friction only, no thrust" during the slide-out.
  local okV, vx, vz = pcall(realMoveVector)
  if okV then return vx, vz end
  return 0, 0
end

-- ------- run toggle
--
-- DOOM's real default run key is confirmed from source, not assumed:
-- `m_misc.c:253`, `{"key_speed", &key_speed, KEY_RSHIFT}` -- Right
-- Shift. This engine already maps both Shift keys to its own pad SELECT
-- button (`gen1recomp-dev/src/core/Input.lua:20-21`), and SELECT's own
-- other function (cycling the voxel display mode) is already refused
-- outright while PKDOOM MODE is on (`lib/DoomView.lua`'s
-- `installViewLock`) -- so reusing it here for "hold to run" is both
-- genuinely DOOM-authentic (the real default keybind) and not already
-- spoken for while this mode is active.
local function running()
  local ok, Game = pcall(require, "src.core.Game")
  return ok and Game.input and Game.input:isDown("select") or false
end

-- ------- momentum state
local momX, momZ = 0, 0

-- Not gated on `Options.enabled()` here: `momX`/`momZ` only ever change
-- while `updateMomentum` runs, which itself only runs while the mode is
-- on (see `install()` below) -- so this already reads 0 (or whatever
-- momentum was frozen at when the mode last turned off) correctly either
-- way, with no separate check needed. `lib/DoomWeapons.lua`'s own
-- `Actions.weaponReady` -- the only real caller -- is itself only ticked
-- while PKDOOM MODE is on regardless.
function DoomMove.bobFraction()
  if BOB_SATURATION_SPEED <= 0 then return 0 end
  local mag = math.sqrt(momX * momX + momZ * momZ)
  local f = mag / BOB_SATURATION_SPEED
  f = f * f -- bob scales with momentum SQUARED, matching DOOM's own FixedMul(mom,mom), not linearly
  if f > 1 then f = 1 end
  return f
end

-- The REAL, unwrapped rotation, captured by `install()` before
-- `FirstPerson.moveWorld` gets reassigned to this file's own wrapper --
-- `updateMomentum` below needs the actual math, not itself. Calling
-- `FirstPerson.moveWorld` directly from inside `updateMomentum` would
-- call the WRAPPER (a live table field, already reassigned by the time
-- `updateMomentum` ever runs, since it's only ever invoked from inside
-- that same wrapper) -- infinite recursion, caught before ever shipping
-- this file, not found live.
local realMoveWorld = nil

-- The REAL, unwrapped `FirstPerson.moveVector`, captured the same way
-- and for the same reason as `realMoveWorld` above -- `rawIntent`'s own
-- fallback needs the genuine raw signal, not the wrapper `install()`
-- installs further down (which can report a fake residual-momentum
-- vector during a slide-out -- see that wrap's own header comment).
local realMoveVector = nil

-- Reset on the mode's own enable-edge, the same pattern `lib/DoomView.
-- lua`'s `resetBob` already uses for the identical reason: these are
-- plain module-level locals with no idea the mode was off (or the game
-- was closed and reopened) in between. Without this, momentum left over
-- from the moment the mode was last switched off -- frozen, not decaying,
-- since this file's own update only ever runs while the mode is on --
-- would still be sitting there the instant it's switched back on,
-- causing an unwanted "coast" in whatever direction the player was last
-- moving even if they're now standing still with no input held.
local function resetMomentum()
  momX, momZ = 0, 0
end
DoomMove.reset = resetMomentum

-- One momentum update per call -- meant to run exactly once per frame
-- `FreeMove.tick` actually processes movement (i.e., once per wrapped
-- `FirstPerson.moveWorld` call), the same "once per DOOM tic" cadence
-- `P_MovePlayer`+`P_XYMovement` run at together.
--
-- Returns the velocity THIS frame should actually move by -- which is
-- NOT simply "whatever momX/momZ end up as," per a real ordering fact
-- re-confirmed fresh this round: DOOM's own per-tic sequence
-- (`P_Ticker`, p_tick.c:148-152) runs `P_PlayerThink` -- thrust added,
-- `P_MovePlayer`, p_user.c:160-164 -- for EVERY player BEFORE
-- `P_RunThinkers()`, which is what eventually reaches `P_XYMovement`
-- (p_mobj.c:114-241) for each thing's own tic, including the player's.
-- `P_XYMovement` clamps momx/momy to MAXMOVE, MOVES the object using
-- THAT (still pre-friction) value, and only THEN -- after the object has
-- already moved -- multiplies momx/momy by FRICTION, purely to set up
-- NEXT tic's baseline (p_mobj.c:236-240). This function used to return
-- momX/momZ directly (i.e., ALREADY friction-decayed) for the CURRENT
-- frame's own movement -- a real, if subtle, ordering bug: every
-- frame's actual displacement was one FRICTION multiply short of what
-- real DOOM would have moved that same tic, which specifically distorts
-- the slide-to-a-stop's own decay curve (the exact behavior the user
-- asked to audit) rather than steady-state walking (self-correcting at
-- equilibrium, so this rounding-adjacent bug hid there). Fixed by
-- capturing the pre-friction, post-clamp value as `moveX,moveZ` BEFORE
-- applying friction to `momX,momZ` for next frame's own baseline, and
-- returning the former instead of the (mutated) latter.
local function updateMomentum()
  local mx, mz = rawIntent()
  -- P_PlayerThink (p_user.c:258-262) returns straight into P_DeathThink
  -- while `playerstate == PST_DEAD`, WITHOUT ever calling P_MovePlayer --
  -- so a dead player's own `cmd->forwardmove`/`sidemove` never reaches
  -- P_Thrust again. Restated here as "raw intent reads as zero while
  -- dead" rather than skipping this function outright, so EXISTING
  -- momentum still decays to a stop via friction below exactly the way
  -- P_XYMovement's own friction still runs on every mobj regardless of
  -- playerstate -- only the ADDING of new thrust is what death actually
  -- stops. Phase 15 (phases/phase-15-player-death.md).
  if DoomHealth.isDead() then mx, mz = 0, 0 end
  local tier = running() and 2 or 1
  local sideThrust, forwardThrust = mx * SIDE_THRUST[tier], mz * FORWARD_THRUST[tier]
  -- NOTE: FirstPerson.moveWorld(strafe, forward) is the same (mx, mz)
  -- argument order `moveVector()`'s own callers already use -- matches
  -- P_Thrust's own two calls (forward at `angle`, side at `angle-90`),
  -- just expressed as one rotation instead of two.
  local okW, wx, wz = pcall(realMoveWorld, sideThrust, forwardThrust)
  if not okW then return 0, 0 end
  momX = momX + wx
  momZ = momZ + wz
  -- Per-axis clamp, matching P_XYMovement's own two separate `if`
  -- statements exactly -- NOT a combined-magnitude clamp, so diagonal
  -- momentum can exceed MAXMOVE in COMBINED length (up to MAXMOVE*sqrt2)
  -- the same real way DOOM's own diagonal movement can.
  if momX > MAXMOVE then momX = MAXMOVE elseif momX < -MAXMOVE then momX = -MAXMOVE end
  if momZ > MAXMOVE then momZ = MAXMOVE elseif momZ < -MAXMOVE then momZ = -MAXMOVE end
  local moveX, moveZ = momX, momZ
  local noInput = (mx == 0 and mz == 0)
  if math.abs(momX) < STOPSPEED and math.abs(momZ) < STOPSPEED and noInput then
    momX, momZ = 0, 0
  else
    momX, momZ = momX * FRICTION, momZ * FRICTION
  end
  return moveX, moveZ
end

-- ------- install

local installed = false
local wasEnabled = false
local frameCounter = 0

-- Tracks the mode's own enable edge (resets momentum the instant PKDOOM
-- MODE turns on) and advances the frame counter the tight-ledge hold
-- timer (`installTightLedgeHop` below) reads.
local function installEnableEdgeTracking()
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local enabledNow = Options.enabled()
    if enabledNow and not wasEnabled then resetMomentum() end
    wasEnabled = enabledNow
    frameCounter = frameCounter + 1
    return next(game, dt)
  end)
end

local function installMovementWraps()
  realMoveWorld = FirstPerson.moveWorld
  FirstPerson.moveWorld = function(mx, mz)
    if not Options.enabled() then return realMoveWorld(mx, mz) end
    local moveX, moveZ = updateMomentum()
    -- `FreeMove.tick` multiplies this return by its own WALK/BIKE speed
    -- constant right after calling this -- pre-divided here so that
    -- multiplication cancels out and this file's own momentum is what
    -- actually reaches `slideX`/`slideZ`, regardless of the player's
    -- bike toggle (see this file's own header comment for why bike state
    -- is deliberately not read/forced either way).
    local ok, Game = pcall(require, "src.core.Game")
    local speed = (ok and Game.save and Game.save.onBike) and FreeMove.BIKE or FreeMove.WALK
    if not (speed and speed > 0) then speed = 1 end
    return moveX / speed, moveZ / speed
  end

  -- ------- the real fix for "movement stops dead instead of sliding"
  --
  -- The bug, found by tracing `FreeMove.tick` line by line (`Dramatic
  -- ShapeVoxelMod-dev/lib/FreeMove.lua:279-299`): it calls `local mx, mz
  -- = FirstPerson.moveVector()` FIRST, then `FirstPerson.moveWorld(mx,
  -- mz)` (wrapped above), THEN checks `local moving = (mx ~= 0 or mz ~=
  -- 0); if not moving then return end` -- using the RAW moveVector()
  -- result for that gate, not the momentum-derived velocity `moveWorld`
  -- just returned. The instant a movement key is released, raw mx/mz
  -- become (0,0), `moving` goes false, and `FreeMove.tick` returns
  -- BEFORE ever calling `slideX`/`slideZ` -- meaning this file's own
  -- correctly-still-decaying momentum (computed above, every frame,
  -- regardless) never actually reaches the player's position. It just
  -- silently decays in a vacuum for as long as no key is held, and the
  -- player visually stops on a dime the moment input releases -- the
  -- exact "something's missing" the user reported after comparing
  -- against real DOOM, where `P_XYMovement` keeps moving+decaying the
  -- object every tic regardless of whether `cmd->forwardmove`/`sidemove`
  -- are currently held (see `updateMomentum`'s own header comment).
  --
  -- `FreeMove.tick`'s own `moving` gate can't be reached or edited (host
  -- file, CLAUDE.md's hard rule) -- but it's driven entirely by
  -- `FirstPerson.moveVector()`'s return, which IS a live, wrappable
  -- table field, the same idiom already used for `moveWorld`. Wrapping
  -- it to report a unit vector in momentum's own current direction
  -- whenever real input is absent but momentum isn't yet zero keeps
  -- `moving` true for exactly as long as real DOOM's own object would
  -- still be sliding -- STOPSPEED's existing snap-to-zero (already
  -- ported, `updateMomentum` above) is what naturally makes this fake
  -- vector stop appearing the instant DOOM's own real momentum would
  -- have hit zero too, not a separately-invented cutoff.
  --
  -- Safe against the same infinite-recursion class of bug already caught
  -- once for `moveWorld`: this wrapper only reads `momX`/`momZ` (plain
  -- locals) and calls `realMoveVector` (the captured original) -- never
  -- anything that loops back into `updateMomentum`/`moveWorld` itself.
  realMoveVector = FirstPerson.moveVector
  FirstPerson.moveVector = function()
    if not Options.enabled() then return realMoveVector() end
    local mx, mz = realMoveVector()
    if mx == 0 and mz == 0 and (momX ~= 0 or momZ ~= 0) then
      local mag = math.sqrt(momX * momX + momZ * momZ)
      return momX / mag, momZ / mag
    end
    return mx, mz
  end
end

-- ------- Phase 18 Bug 6: tighter ledge-hop tolerance
--
-- Real Gen-1 ledge-hop (`OverworldState:checkLedgeHop`,
-- `OverworldController.lua:1322-1367`) is a discrete, per-cell check
-- against `p.cellX`/`p.cellY` -- not a distance/tolerance value at all
-- on its own. The reported "auto-jumps from way too far away" symptom
-- comes from WHERE that check gets triggered: the host's own
-- `FreeMove.lua` free-roam collision treats the player as a
-- `FreeMove.RADIUS = 5.5` world-px circle (over a third of a 16px
-- cell), and `blockedCell`/`slideX`/`slideZ` (`FreeMove.lua:121-203`)
-- test the cell the LEADING EDGE of that circle would enter -- so the
-- blocked-cell push (and therefore `checkLedgeHop`, called from inside
-- `pushSpecials`, `FreeMove.lua:205-230`) fires the moment the
-- collision circle's edge touches the next cell, well before the
-- player's own actual centre reaches the true boundary. Correct and
-- wanted for a solid wall (stop before visually clipping into it);
-- wrong-feeling for a ledge specifically, since stepping off a ledge is
-- meant to be a deliberate "walk right up to the edge" action.
--
-- `OverworldState` is a real requirable module (confirmed via its own
-- `return OverworldState` at the end of `OverworldController.lua`) and
-- `checkLedgeHop` a live method on it -- a genuine, sanctioned wrap
-- point (CLAUDE.md's own documented "wrap a live table field" idiom),
-- not a host-file edit.
local function installTightLedgeHop()
  local okOS, OverworldState = pcall(require, "src.world.OverworldController")
  local okCol, Collision = pcall(require, "src.world.Collision")
  if okOS and okCol then
    -- **Bug found on the user's own playtest, 2026-08-06: a DISTANCE
    -- tolerance is the wrong tool here, and made ledge hops impossible
    -- outright rather than just tighter.** `slideX`/`slideZ`
    -- (`FreeMove.lua:145-203`) clamp the player's position the instant a
    -- push is refused, to EXACTLY `edge*16 - r - EPS` (or the mirror) --
    -- i.e. the player's own true CENTRE can never get closer than
    -- `FreeMove.RADIUS` (5.5) plus a hair to the real cell boundary,
    -- full stop, no matter how long they keep pressing forward: that
    -- clamp IS the collision boundary. The original fix asked for the
    -- centre to be within 1.5px of the true edge -- a distance smaller
    -- than the achievable minimum, so `checkLedgeHop` failed the
    -- proximity check on literally every call once TIGHT LEDGES was on,
    -- blocking every hop unconditionally ("i cannot jump over walls now
    -- AT ALL"). There is no finer positional signal available here to
    -- read at all: "just brushed it this frame" and "been pressing into
    -- it for ten seconds" clamp to the exact same position, since the
    -- collision system itself refuses to let the player get any closer
    -- either way.
    --
    -- Real fix: measure TIME held against the SAME cell in the SAME
    -- direction instead of distance, which is the only signal that
    -- actually distinguishes "just touched it" from "walked up and is
    -- holding into it" in this collision model. `checkLedgeHop` is
    -- called every frame the player continues pushing into a blocked
    -- cell (confirmed via `pushSpecials`, `FreeMove.lua:205-230`, called
    -- once per frame from `FreeMove.tick` whenever `slideX`/`slideZ`
    -- report a refusal) -- so counting consecutive calls against the
    -- same `(dir, targetCell)` key is a real, per-frame-accurate hold
    -- timer, not an approximation.
    local LEDGE_HOLD_FRAMES = 15 -- ~0.25s at this engine's 60Hz -- a first-pass guess, needs the user's own hands once playable, same as every other feel constant in this file

    local holdKey, holdFrames, holdSeenFrame = nil, 0, -1

    -- `Collision.DELTA[dir]` ({dx,dy}, `Collision.lua:8-9`, exposed) is
    -- the same direction encoding `checkLedgeHop`'s own caller already
    -- uses -- used here only to name the target cell for the hold key,
    -- via `Collision.target` (also exposed), matching exactly what
    -- `checkLedgeHop` itself computes internally for the same purpose.
    local function heldLongEnough(state, dir)
      local p = state.player
      if not (p and p.cellX and p.cellY) then return true end
      local fx, fy = Collision.target(p.cellX, p.cellY, dir)
      local key = dir .. ":" .. fx .. "," .. fy
      -- a gap of more than one real frame since the last call means the
      -- player let go and (maybe) came back -- start the hold over
      -- rather than resume a stale count from a previous approach
      if key == holdKey and frameCounter - holdSeenFrame <= 1 then
        holdFrames = holdFrames + 1
      else
        holdKey, holdFrames = key, 1
      end
      holdSeenFrame = frameCounter
      return holdFrames >= LEDGE_HOLD_FRAMES
    end

    local realCheckLedgeHop = OverworldState.checkLedgeHop
    function OverworldState:checkLedgeHop(dir)
      if Options.enabled() and Options.tightLedgesEnabled()
         and not heldLongEnough(self, dir) then
        return false
      end
      return realCheckLedgeHop(self, dir)
    end
  end
end

function DoomMove.install()
  if installed then return end
  installed = true
  installEnableEdgeTracking()
  installMovementWraps()
  installTightLedgeHop()
end

return DoomMove
