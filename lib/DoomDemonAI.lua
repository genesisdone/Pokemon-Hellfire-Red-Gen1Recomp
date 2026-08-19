-- PokeDoom: real DOOM monster movement/pathing/targeting/attack-decision
-- AI (`A_Chase`/`P_NewChaseDir`/`P_CheckMeleeRange`/`P_CheckMissileRange`
-- and every demon's own attack-selection logic) -- every citation, fix
-- history, and design note below is unchanged from where this code used
-- to live, inline, in `lib/DoomDemons.lua` itself.
--
-- Extracted into its own file 2026-08-19 during a project-wide
-- readability audit, at direct user request ("attempt the split") after
-- confirming the current state plays correctly. `lib/DoomDemons.lua` had
-- grown to 5225 lines and was already sitting at Lua's real, hard
-- 200-local-per-function compile ceiling (see this block's own
-- `pickNewChaseDir` header comment below, and `lib/DoomDemons.lua`'s own
-- remaining header comments, for that history) -- this real DOOM
-- movement/pathing/targeting/attack-decision block was the single
-- largest, most cleanly-delineated section of that file (already under
-- its own `-- === real DOOM movement/pathing AI ===` banner), so moving
-- it to its own file relieves the ceiling pressure at its real source
-- instead of just working around it with more table-field indirection.
--
-- `DoomDemonAI.attach(deps)` is the ONLY export -- called once, from
-- `lib/DoomDemons.lua`, passing in every piece of shared state/helper
-- function this AI logic actually reaches into (the roster/spawn/
-- rendering/hit-resolver code that OWNS that state stays in `lib/
-- DoomDemons.lua`, unmoved). This is a mechanical, behavior-preserving
-- extraction, NOT a rewrite: every function body below is byte-for-byte
-- unchanged from its original home, only the closure's upvalues moved
-- from "captured directly from the enclosing file scope" to "read once
-- from `deps` at the top of `attach`" -- `local X = deps.X` reads
-- identically to a plain module-level local for every real reference
-- below. Returns a small table of the pieces `lib/DoomDemons.lua` itself
-- still needs back (`tickDemon`, the shared `_demonAI` sub-table other
-- code there still calls, plus a handful of constants/helpers a few
-- OTHER functions in that file -- `spawnDemon`, `retargetOntoAttacker`,
-- `spawnPickedDemon` -- also genuinely depend on: `ticsToSeconds`,
-- `playSeeSound`, `REACTIONTIME_TICS`, `BASETHRESHOLD_TICS`, `DIR`).
--
-- Deliberately NOT a top-level `V.require("DoomDemons")` back-reference
-- here -- this file never calls back into `lib/DoomDemons.lua` at all
-- (everything it needs arrives via `deps`), which sidesteps the exact
-- circular-load hazard `lib/DoomEffectEntity.lua`'s own header comment
-- already documents for the reverse direction (`DoomDemons` requiring a
-- file that requires `DoomDemons` back).

local V = ...

local DoomDemonAI = {}

-- `deps` fields, all supplied by `lib/DoomDemons.lua`'s own call site:
--   DoomDemons, DoomLog, DoomHealth, DoomWadImport, DoomBlood, FirstPerson
--     -- modules/tables this AI logic calls into directly
--   demons -- the shared, live ambient-demon list (read-only here, for
--     the concurrent-attacker count in `fireMissileAttack`)
--   blocksSight, walkableCell, entityBlocksCell, npcCenter, targetIsGone,
--   heardNoiseAlert, findTarget, stepCitizenFlee, startAttackAnim,
--   playDemonSound, rollDemonDamage, catchAndKillNpc, groundY,
--   pelletConnects, fireDemonProjectile, startLostSoulCharge,
--   tickLostSoulCharge, demonSpeedPxPerSec, worldPos, stepToward,
--   pickRoamWaypoint -- helper functions this AI logic calls into
--   DEMON_RADIUS, SLIDE_EPS, MELEE_RADIUS, DETECT_RADIUS, DIAG,
--   DOOM_TIC_SECONDS, PLAYER_MELEE_COOLDOWN -- shared constants
function DoomDemonAI.attach(deps)
  local DoomDemons = deps.DoomDemons
  local DoomLog = deps.DoomLog
  local DoomHealth = deps.DoomHealth
  local DoomWadImport = deps.DoomWadImport
  local DoomBlood = deps.DoomBlood
  local FirstPerson = deps.FirstPerson
  local demons = deps.demons
  local blocksSight = deps.blocksSight
  local walkableCell = deps.walkableCell
  local entityBlocksCell = deps.entityBlocksCell
  local npcCenter = deps.npcCenter
  local targetIsGone = deps.targetIsGone
  local heardNoiseAlert = deps.heardNoiseAlert
  local findTarget = deps.findTarget
  local stepCitizenFlee = deps.stepCitizenFlee
  local startAttackAnim = deps.startAttackAnim
  local playDemonSound = deps.playDemonSound
  local rollDemonDamage = deps.rollDemonDamage
  local catchAndKillNpc = deps.catchAndKillNpc
  local groundY = deps.groundY
  local pelletConnects = deps.pelletConnects
  local fireDemonProjectile = deps.fireDemonProjectile
  local startLostSoulCharge = deps.startLostSoulCharge
  local tickLostSoulCharge = deps.tickLostSoulCharge
  local demonSpeedPxPerSec = deps.demonSpeedPxPerSec
  local worldPos = deps.worldPos
  local stepToward = deps.stepToward
  local pickRoamWaypoint = deps.pickRoamWaypoint
  local DEMON_RADIUS = deps.DEMON_RADIUS
  local SLIDE_EPS = deps.SLIDE_EPS
  local MELEE_RADIUS = deps.MELEE_RADIUS
  local DETECT_RADIUS = deps.DETECT_RADIUS
  local DIAG = deps.DIAG
  local DOOM_TIC_SECONDS = deps.DOOM_TIC_SECONDS
  local PLAYER_MELEE_COOLDOWN = deps.PLAYER_MELEE_COOLDOWN

  -- ================== real DOOM movement/pathing AI ==================
  -- (2026-08-07, full audit + port -- user's own explicit request: "enemies
  -- do not shoot as soon as they see you, they move around a bit then
  -- shoot you... audit doom enemy movement per enemy and make sure its
  -- feature 1:1... dont make a new system to avoid doing too much work...
  -- if a new system is the only way to a 1:1 feature parity."; corrected
  -- same day, second round: "the pathing is based on the pokemon grid
  -- system. this was not in the original doom... the doom enemies should
  -- just be able to walk wherever as long as they dont walk past
  -- collision" -- see the "continuous movement + collision" section
  -- above for the real fix. The 8-DIRECTION ALGORITHM below is unchanged
  -- from that first round and stays real DOOM (`P_NewChaseDir` genuinely
  -- only ever picks one of 8 compass directions, never a free angle) --
  -- what changed is HOW each chosen direction is walked: continuously,
  -- via `slideMove` above, never teleported cell-to-cell.)
  --
  -- Confirmed by reading every one of this roster's 10 demons' own real
  -- state chains (info.c): every single one routes its RUN state through
  -- plain `A_Chase` (Lost Soul included -- S_SKULL_RUN1/2 both call
  -- A_Chase, same as everyone else; only its own missile action,
  -- A_SkullAttack, is unique). One shared system, faithfully ported once,
  -- covers all 10 -- only the final attack action (already ported, Phase
  -- 22) differs per monster. Ports:
  --   A_Chase           p_enemy.c:672-776  -- the per-tic state machine
  --   P_NewChaseDir      p_enemy.c:363-489  -- the real 8-directional pathing
  --   P_Move / P_TryWalk p_enemy.c:272-358  -- movement + collision
  --   P_CheckMeleeRange   p_enemy.c:174-192
  --   P_CheckMissileRange p_enemy.c:197-256 -- the real mechanic behind
  --     "moves around before shooting": a fresh `movecount` (0-15 tics,
  --     rerolled on every successful step) blocks even CONSIDERING a
  --     missile attack until it runs out, and `P_CheckMissileRange`'s own
  --     distance-scaled RANDOM CHANCE can still hold fire after that.
  --   A_Look's own real seesound/activesound triggers (p_enemy.c:604-664,
  --     771-775) -- `roster.seeSound`/`.activeSound` have carried real
  --     WAD lump names since Phase 21 but were never actually played.
  --
  -- Every real DOOM-tic quantity (reactiontime, movecount, threshold) is
  -- ported as a real-seconds countdown (tics * 1/35 sec), the same
  -- "state-driven timer, not a raw fixed-tic counter" shape this file's
  -- own `attackCooldown`/`staggerTimer` already use -- CLAUDE.md's own
  -- "avoid math-derived code" rule. `P_CheckSight`'s own real BSP
  -- traversal has no grid equivalent -- restated as a continuous world-px
  -- line march against this file's own real walkability authority
  -- (`walkableCell`), matching CLAUDE.md's "Nature of the port": the
  -- FUNCTIONAL result (blocked by a wall) is what's ported, not DOOM's
  -- own renderer-specific algorithm.
  local DOOM_TICRATE_AI = 35
  local function ticsToSeconds(tics) return tics / DOOM_TICRATE_AI end

  -- dirtype_t (p_enemy.c:51-64), restated for this engine's own world --
  -- Z increases SOUTH here (this file's own already-established `DX/DY`
  -- convention: `down = (0,1)`), the OPPOSITE of DOOM's own Y-increases-
  -- north world space -- every comparison below is re-derived for THIS
  -- convention directly, never copied from the C signs unexamined.
  local DIR = {
    EAST = 1, NORTHEAST = 2, NORTH = 3, NORTHWEST = 4,
    WEST = 5, SOUTHWEST = 6, SOUTH = 7, SOUTHEAST = 8, NODIR = 9,
  }
  -- Unit vectors, not the old system's own plain -1/0/1 grid steps --
  -- diagonals scaled by `DIAG` (see the continuous-movement section
  -- above), matching real DOOM's own `xspeed[]`/`yspeed[]` normalization.
  local DIR_DX = { [1] = 1, [2] = DIAG, [3] = 0, [4] = -DIAG, [5] = -1, [6] = -DIAG, [7] = 0, [8] = DIAG }
  local DIR_DZ = { [1] = 0, [2] = -DIAG, [3] = -1, [4] = -DIAG, [5] = 0, [6] = DIAG, [7] = 1, [8] = DIAG }
  -- The real derived facing string for each direction, matching the OLD
  -- system's own dx/dy-sign-based selection exactly (horizontal
  -- preferred over vertical for any diagonal, the same real precedence
  -- `(dx==1 and "right") or (dx==-1 and "left") or (dy==1 and "down") or
  -- "up"` always produced) -- hardcoded here instead of re-deriving from
  -- the now-fractional `DIAG` values, which a float sign/threshold check
  -- would make fragile for no real benefit.
  local DIR_FACING = {
    [1] = "right", [2] = "right", [3] = "up", [4] = "left",
    [5] = "left", [6] = "left", [7] = "down", [8] = "right",
  }
  -- opposite[] (p_enemy.c:70-74)
  local DIR_OPPOSITE = { [1] = 5, [2] = 6, [3] = 7, [4] = 8, [5] = 1, [6] = 2, [7] = 3, [8] = 4, [9] = 9 }

  -- diags[] (p_enemy.c:76-79): DOOM's own `diags[((deltay<0)<<1)+(deltax>0)]`
  -- (deltay<0 = target SOUTH in ITS coordinate space). Re-derived for
  -- this engine's own opposite Z sign: `deltaz>0` (target's own world Z
  -- minus the demon's) means target is SOUTH here.
  local function diagFor(deltax, deltaz)
    if deltaz > 0 then
      return deltax > 0 and DIR.SOUTHEAST or DIR.SOUTHWEST
    else
      return deltax > 0 and DIR.NORTHEAST or DIR.NORTHWEST
    end
  end

  local MOVECOUNT_MAX_TICS = 15 -- P_TryWalk (p_enemy.c:356): `P_Random()&15`
  local REACTIONTIME_TICS = 8   -- info.c: every one of this roster's 10 demons shares this value
  local BASETHRESHOLD_TICS = 100 -- p_local.h:61 -- see `m.threshold`'s own header note below

  -- `P_CheckSight`'s own real functional requirement (p_enemy.c:188,201:
  -- a demon can't melee/fire at what it can't see through a WALL) --
  -- restated as a continuous world-px line march, sampling every 8px
  -- (half a cell -- fine enough to catch a thin wall without being
  -- expensive over typical `DETECT_RADIUS` distances) along the straight
  -- line between the two real, continuous endpoints. Uses `blocksSight`
  -- (real obstructions only), NOT `walkableCell` (movement-restricted,
  -- also excludes water/warp tiles that don't actually block vision) --
  -- see that function's own header comment for the real bug this fixed.
  local LOS_SAMPLE_PX = 8
  local function hasLineOfSight(ow, fromX, fromZ, toX, toZ)
    local dx, dz = toX - fromX, toZ - fromZ
    local dist = math.sqrt(dx * dx + dz * dz)
    if dist < 1 then return true end
    local steps = math.max(1, math.floor(dist / LOS_SAMPLE_PX))
    for i = 1, steps - 1 do
      local t = i / steps
      local cx = math.floor((fromX + dx * t) / 16)
      local cz = math.floor((fromZ + dz * t) / 16)
      if blocksSight(ow.map, cx, cz) then return false end
    end
    return true
  end

  -- CORRECTED 2026-08-07 -- user report + two screenshots, both showing a
  -- demon (a Spider Mastermind, a Baron of Hell) stuck against a wall it
  -- needed to walk AROUND to reach an opening, unable to commit to the
  -- detour: "even though all he needs to do it go the other way, around
  -- the wall, to the opening and come to me" / "even at the opening he
  -- has trouble getting through." Traced to a real, confirmed gap this
  -- same day's own Round 10 audit had already found and flagged (Finding
  -- 1, `phases/phase-22-demon-behavior-parity.md`) but not yet fixed:
  -- real DOOM monster movement is genuinely ALL-OR-NOTHING per tic --
  -- `P_Move` (p_enemy.c:272-335) computes ONE full destination point
  -- (`actor->x + speed*xspeed[dir]`) and tests it in a single
  -- `P_TryMove`/`P_CheckPosition` call (p_map.c:374-484); if ANYTHING
  -- blocks that exact destination, the move fails COMPLETELY -- the mobj
  -- never moves at all that tic, full stop, no partial credit. Wall-
  -- sliding is a real, but PLAYER-EXCLUSIVE mechanic in DOOM's own source
  -- (`P_XYMovement`'s own `if (mo->player) P_SlideMove(mo)` branch,
  -- p_mobj.c:169-172 -- confirmed no equivalent branch exists for a
  -- non-player mobj, which just zeroes its momentum and stops instead).
  -- This file's own Round 9 rewrite modeled demon movement on the HOST
  -- mod's own PLAYER collision (`FreeMove.lua`'s `slideX`/`slideZ`,
  -- axis-separated, partial credit) -- the right fix for that round's own
  -- reported bug (grid-cell teleportation), but it gave demons the
  -- player's own real movement feel, not a real DOOM MONSTER's. A demon
  -- grazing a wall at a shallow angle could creep along it via partial
  -- axis credit, oscillating right at a corner between "some progress"
  -- and "none" instead of ever cleanly failing and falling through to
  -- `pickNewChaseDir`'s own real full-compass-scan fallback (which DOES
  -- eventually try every remaining direction, including the one that
  -- actually leads around the wall) -- exactly the reported "grazes but
  -- never fully commits to the detour" symptom. Fixed by testing the
  -- FULL per-tic destination as one atomic probe (`canOccupy`, below,
  -- checking every cell the demon's own circular body would occupy
  -- there, both axes together) -- commit fully on success, or don't move
  -- AT ALL this tic on failure, exactly matching real `P_TryMove`'s own
  -- real all-or-nothing shape. `pickNewChaseDir`'s own real retry
  -- cascade (diagonal, axis-preferred, axis-other, old direction, full
  -- compass sweep, turnaround) is unchanged -- it already tries every
  -- real direction in DOOM's own real order; this fix just makes each
  -- individual TRY report a real, clean pass/fail instead of a fuzzy
  -- partial one. `slideX`/`slideZ`/`slideMove` (above) are UNCHANGED and
  -- still used by ROAM's own `stepToward` -- a mod-original system with
  -- no real DOOM movement to be faithful to at all (real monsters with no
  -- target simply stand still), where a smooth any-angle glide remains
  -- the right, deliberate choice.
  local function canOccupy(ow, x, z)
    local r = DEMON_RADIUS
    local x0 = math.floor((x - r + SLIDE_EPS) / 16)
    local x1 = math.floor((x + r - SLIDE_EPS) / 16)
    local z0 = math.floor((z - r + SLIDE_EPS) / 16)
    local z1 = math.floor((z + r - SLIDE_EPS) / 16)
    for cx = x0, x1 do
      for cz = z0, z1 do
        if not walkableCell(ow.map, cx, cz) or entityBlocksCell(ow, cx, cz) then return false end
      end
    end
    return true
  end

  -- P_Move (p_enemy.c:272-335): attempts to move `dist` world px along
  -- `dir` THIS tic as one real all-or-nothing step -- see this section's
  -- own header comment above for the full derivation. No special-line/
  -- door handling exists here (a demon never interacts with a door line
  -- the way DOOM's own `P_Move`'s own `numspechit` branch does), so a
  -- blocked destination is simply a failed move, matching that function's
  -- own real fallback once nothing special was crossed either.
  local function attemptStep(ow, m, dir, dist)
    if not dir or dir == DIR.NODIR then return false end
    local dx, dz = DIR_DX[dir], DIR_DZ[dir]
    local nx, nz = m.px + dx * dist, m.py + dz * dist
    if not canOccupy(ow, nx, nz) then return false end
    m.px, m.py = nx, nz
    m.moveDir = dir
    m.facing = DIR_FACING[dir]
    m.moving = true
    return true
  end

  -- P_TryWalk (p_enemy.c:349-358): `P_Move`, and ONLY on success, a fresh
  -- `movecount = P_Random()&15` -- used exclusively while actively
  -- SEARCHING for a direction (`P_NewChaseDir`, below).
  --
  -- FIX 2026-08-08 -- user report + real diagnostic log (per CLAUDE.md's
  -- own "log before a second fix attempt" rule): demons firing roughly
  -- once every 6-13 real seconds instead of at anything like real DOOM's
  -- own cadence, confirmed by the log itself -- `movecountBlocks=true` on
  -- nearly every sampled check, `stuckReplans` mostly 0 (so NOT the
  -- wall/player-obstacle stall this file's own earlier fix targeted -- a
  -- genuinely different root cause). Found it by re-deriving real DOOM's
  -- own exact `movecount` mechanics fresh: `actor->movecount` is a plain
  -- INTEGER real-tic counter, decremented exactly once per real 35Hz DOOM
  -- tic (`--actor->movecount`, p_enemy.c:764) -- because it's a discrete
  -- integer stepping down by exactly 1 each tic, it ALWAYS passes through
  -- an observable `movecount==0` tic before going negative, and `A_Chase`
  -- own missile-attack check (`if (movecount) goto nomissile`, which reads
  -- movecount BEFORE that tic's own decrement runs) genuinely SEES that
  -- zero tic roughly once per replan cycle (every 0-15 real DOOM tics,
  -- ~0-0.43s) -- a real, fairly frequent opening. This file's own earlier
  -- `m.moveCount` was a CONTINUOUS FLOAT of remaining seconds, decremented
  -- by a fractional `dt` every real 60Hz frame -- a float decrementing by
  -- an arbitrary fraction essentially never lands exactly on `0.0`; it
  -- jumps from some small positive remainder straight to negative WITHIN
  -- the same tic that also immediately rerolls a fresh (near-certainly
  -- positive) value via a successful `pickNewChaseDir`/`tryWalkDir` call
  -- -- so the missile check, which only ever reads whatever value was set
  -- at the END of the PREVIOUS tick, essentially NEVER observed an
  -- expired/open state at all, except the rare ~1/16 case where the fresh
  -- reroll itself happened to land exactly on the integer `0`. Restated
  -- as a real discrete tic counter (an actual integer, decremented by
  -- `tickDemon`'s own real 35Hz accumulator below, the same established
  -- pattern `checkMissileRangeReal`'s own `missileCheckTicAccum` already
  -- uses in this file) so it genuinely spends one real, multi-frame-wide
  -- window at `movecount==0` every replan cycle, matching real DOOM's own
  -- actual observable behavior instead of a float-precision artifact of
  -- this port's own earlier implementation.
  local function tryWalkDir(ow, m, dir, dist)
    if not attemptStep(ow, m, dir, dist) then return false end
    m.moveCount = math.random(0, MOVECOUNT_MAX_TICS)
    return true
  end

  -- FEATURE 2026-08-08 -- user report + screenshot: a demon "was just
  -- looking at me trying to find a way to get me but instead of going
  -- around the wall like he could've done he just kept going back and
  -- forth on the wall... he found his way eventually but it took him
  -- stepping in a spot to know it wont lead to me. he needs to know
  -- before he steps to avoid getting stuck." Re-derived `P_NewChaseDir`
  -- AND its own real caller `A_Chase` (p_enemy.c:363-489, 762-767) fresh
  -- against this file's own existing port before assuming a bug: both
  -- match 1:1, INCLUDING a genuinely authentic real-DOOM quirk that
  -- explains the exact symptom -- `opposite[]`'s own real last entry
  -- (`opposite[DI_NODIR] = DI_NODIR`, p_enemy.c:73, matching this file's
  -- own `DIR_OPPOSITE[9] = 9`) means once EVERY candidate direction fails
  -- in one tic (`m.moveDir` left at `NODIR`), the VERY NEXT call's own
  -- `turnaround` becomes meaningless (nothing real equals `NODIR`), so
  -- the same deterministic geometry gets re-tried in roughly the same
  -- order, with only the algorithm's own random coin-flips (the d1/d2
  -- swap, the sweep direction) able to vary the outcome -- real DOOM
  -- monsters genuinely can and do fumble at odd wall geometry exactly
  -- this way; this is authentic vanilla behavior, faithfully reproduced,
  -- not a porting bug. Since the user explicitly asked for better-than-
  -- vanilla behavior here ("he needs to know before he steps"), this adds
  -- a small, clearly MOD-ORIGINAL improvement on top of the real
  -- algorithm rather than silently deviating from it: `hasFollowThrough`
  -- is a bounded, 2-tic-deep lookahead (NOT real pathfinding -- DOOM's
  -- own monsters have none at all) that rejects a candidate direction
  -- only when stepping there would immediately trap the demon with no
  -- further way to keep moving (every other direction from that new spot
  -- also blocked) -- exactly the "walked into a 1-cell pocket right next
  -- to the wall" case that produces visible back-and-forth. `pickNewChaseDir`
  -- below tries every real candidate WITH this filter first, and only
  -- falls back to the real, unfiltered vanilla behavior if that finds
  -- nothing at all -- so a demon is never worse off than real DOOM's own
  -- algorithm, only smarter when a genuinely better option exists nearby.
  local function hasFollowThrough(ow, m, dir, dist)
    local dx, dz = DIR_DX[dir], DIR_DZ[dir]
    local nx, nz = m.px + dx * dist, m.py + dz * dist
    for d = DIR.EAST, DIR.SOUTHEAST do
      if d ~= DIR_OPPOSITE[dir] then
        local ddx, ddz = DIR_DX[d], DIR_DZ[d]
        if canOccupy(ow, nx + ddx * dist, nz + ddz * dist) then return true end
      end
    end
    return false
  end

  -- Tries `dir` via the real `tryWalkDir` (`P_TryWalk`), but only when it
  -- also has real follow-through (see `hasFollowThrough` above) -- used by
  -- `pickNewChaseDir`'s own fallback sweep stages, below, never by the
  -- diagonal/axis-preferred tries (those stay exactly real-DOOM, since
  -- they're the demon's OWN most-direct route to the target and rejecting
  -- one on a lookahead technicality would just be second-guessing the
  -- real algorithm's own correct first choice).
  local function tryWalkDirSmart(ow, m, dir, dist)
    if dir == DIR.NODIR then return false end
    if not hasFollowThrough(ow, m, dir, dist) then return false end
    return tryWalkDir(ow, m, dir, dist)
  end

  -- P_NewChaseDir (p_enemy.c:363-489) -- the real algorithm behind "moves
  -- around instead of walking straight at you": try the direct diagonal
  -- toward the target first; if blocked (or it would reverse the demon's
  -- own current direction), fall back to the two straight axis
  -- directions, ordered by whichever axis has the larger real distance --
  -- with the SAME real random chance DOOM itself has (`P_Random()>200`,
  -- ~21.5%) to swap that preference instead of always preferring the
  -- bigger delta -- then the demon's OWN previous direction, then a full
  -- random sweep of every remaining direction (forward or backward
  -- through the compass, another real coin flip), and only turns fully
  -- around as an absolute last resort before giving up. Deltas are now
  -- real, continuous world-px distances (`m.px`/`.py` vs. the target's
  -- own real continuous center) rather than cell-index deltas -- more
  -- accurate, and needs no grid lookup on either end at all.
  -- FIXED 2026-08-10 (Phase 30/31 pathing audit) -- real `P_NewChaseDir`
  -- (`p_enemy.c:384-396`) only assigns a real axis preference once the
  -- target's delta EXCEEDS `10*FRACUNIT` on that axis (`if
  -- (deltax>10*FRACUNIT) d[1]=DI_EAST; else if (deltax<-10*FRACUNIT)
  -- d[1]=DI_WEST; else d[1]=DI_NODIR`) -- a genuine dead zone, not a bare
  -- sign check. This file's own `pickNewChaseDir` used a bare `deltax > 0`/
  -- `< 0` split with no dead zone at all until this fix -- only matters
  -- when a demon is very nearly axis-aligned with its target, but it's a
  -- real, citable difference from source. No principled DOOM-map-unit
  -- conversion exists (CLAUDE.md's own "Nature of the port"), so this
  -- value is a judgment call, proportionally anchored to this file's own
  -- `DEMON_RADIUS=6` (half of it) rather than derived fresh. Declared
  -- INSIDE the function rather than as a module-level local -- this file's
  -- own top-level chunk was already right at Lua's real, hard 200-local
  -- ceiling per function scope, and one more module-level local tipped it
  -- into a real "too many local variables (limit is 200) in main
  -- function" compile failure (confirmed live, Mod Manager screenshot).
  -- A function-scoped local has its own separate budget, so this reads
  -- identically but doesn't compete with the module's own count.
  local function pickNewChaseDir(ow, m, dist)
    local CHASE_DIR_DEAD_ZONE = 3
    if not m.target then return end
    local tx, tz = npcCenter(m.target)
    if not tx then return end
    local olddir = m.moveDir or DIR.NODIR
    local turnaround = DIR_OPPOSITE[olddir]

    local deltax, deltaz = tx - m.px, tz - m.py
    local d1 = (deltax > CHASE_DIR_DEAD_ZONE and DIR.EAST)
      or (deltax < -CHASE_DIR_DEAD_ZONE and DIR.WEST) or DIR.NODIR
    local d2 = (deltaz > CHASE_DIR_DEAD_ZONE and DIR.SOUTH)
      or (deltaz < -CHASE_DIR_DEAD_ZONE and DIR.NORTH) or DIR.NODIR

    if d1 ~= DIR.NODIR and d2 ~= DIR.NODIR then
      local diag = diagFor(deltax, deltaz)
      if diag ~= turnaround and tryWalkDir(ow, m, diag, dist) then return end
    end

    if math.random(0, 255) > 200 or math.abs(deltaz) > math.abs(deltax) then
      d1, d2 = d2, d1
    end
    if d1 == turnaround then d1 = DIR.NODIR end
    if d2 == turnaround then d2 = DIR.NODIR end

    if d1 ~= DIR.NODIR and tryWalkDir(ow, m, d1, dist) then return end
    if d2 ~= DIR.NODIR and tryWalkDir(ow, m, d2, dist) then return end

    -- there is no direct path to the target; pick another direction.
    -- `tryWalkDirSmart` first (see its own header comment above) -- only
    -- this and the sweep below get the lookahead filter, matching the
    -- user's own report, which was specifically about the BLIND-GROPING
    -- phase, not the demon's initial direct approach.
    if olddir ~= DIR.NODIR and tryWalkDirSmart(ow, m, olddir, dist) then return end

    -- randomly determine direction of search (p_enemy.c:449-479) --
    -- smart-filtered first pass, so a candidate that would immediately
    -- trap the demon is skipped in favor of one that actually leads
    -- somewhere; a second, UNFILTERED pass (real vanilla DOOM behavior,
    -- unchanged) only runs if literally nothing passed the filter, so this
    -- can never leave a demon MORE stuck than the real algorithm would.
    local forward = math.random(0, 1) == 1
    for _, smart in ipairs({ true, false }) do
      local tryFn = smart and tryWalkDirSmart or tryWalkDir
      if forward then
        for d = DIR.EAST, DIR.SOUTHEAST do
          if d ~= turnaround and tryFn(ow, m, d, dist) then return end
        end
      else
        for d = DIR.SOUTHEAST, DIR.EAST, -1 do
          if d ~= turnaround and tryFn(ow, m, d, dist) then return end
        end
      end
    end

    if turnaround ~= DIR.NODIR and tryWalkDir(ow, m, turnaround, dist) then return end

    m.moveDir = DIR.NODIR -- can not move
    m.moving = false
  end

  -- P_CheckMeleeRange (p_enemy.c:174-192): a real distance reach plus a
  -- real sight requirement. MELEERANGE itself has no principled DOOM-
  -- map-unit conversion (CLAUDE.md) -- this file's own existing
  -- `MELEE_RADIUS` judgment call stands in for that formula's own real
  -- OUTPUT shape (a fixed reach), unchanged; only the SIGHT requirement
  -- is newly real here (previously unchecked entirely).
  local function checkMeleeRangeReal(ow, m, distSq)
    if distSq > MELEE_RADIUS * MELEE_RADIUS then return false end
    local tx, tz = npcCenter(m.target)
    if not tx then return false end
    return hasLineOfSight(ow, m.px, m.py, tx, tz)
  end

  -- P_CheckMissileRange (p_enemy.c:197-256) -- real DOOM's own distance-
  -- scaled hold-fire roll: the closer the target, the more likely a
  -- demon fires on any given check; the farther, the more likely it
  -- holds off, capped at a real maximum hold-fire chance (`dist>200 ->
  -- 200`, i.e. at most 200/256 ~= 78% chance to hold fire on any single
  -- check -- lower, 160/256 ~= 62.5%, for the Cyberdemon specifically).
  -- A monster with NO real melee option fires more eagerly (`!meleestate:
  -- dist -= 128 map units`); Spider Mastermind, Cyberdemon, and Lost Soul
  -- ALSO fire more eagerly (`dist >>= 1`, `p_enemy.c:239-244`). Restated
  -- proportionally against this project's own `DETECT_RADIUS` judgment-
  -- call scale rather than DOOM's literal fixed-point map units -- no
  -- principled conversion exists -- preserving the real SHAPE of the
  -- roll (closer = much likelier to fire), not the literal pixel numbers;
  -- a plain distance-scaled RNG roll is exactly the kind of "simple RNG"
  -- math CLAUDE.md's own rule already carves out as fine to port directly.
  local function missileHoldFireRoll(m, dist)
    local meleeCapable = (m.roster.attackType == nil or m.roster.attackType == "projectile_dual")
    local ratio = math.max(0, dist) / DETECT_RADIUS
    if not meleeCapable then ratio = ratio + 0.4 end
    if m.name == "SPIDERMASTERMIND" or m.name == "CYBERDEMON" or m.name == "LOSTSOUL" then
      ratio = ratio * 0.5
    end
    ratio = math.min(ratio, m.name == "CYBERDEMON" and 0.625 or 0.8)
    return math.random() < ratio -- true = hold fire this check
  end

  -- The real, complete gate (`P_CheckMissileRange`'s own body, in order):
  -- sight required; a fresh pain-hit (`MF_JUSTHIT`, this file's own
  -- `m.justHit`, set alongside `staggerTimer` -- see `demonResolver`/
  -- `demonAoeResolver`) bypasses everything else and fires immediately
  -- ("fight back!"); `reactionTime` blocks ANY attack until it reaches
  -- zero; only then does the real distance-scaled chance apply.
  --
  -- ADDED 2026-08-08 (direct user request: "audit the enemy sound
  -- system... tons of sounds playing way too frequently") -- real DOOM's
  -- own `A_Chase` (which calls `P_CheckMissileRange`, this function's own
  -- real source) runs exactly once per real 35Hz DOOM tic. This engine's
  -- own fixed-step game loop (`gen1recomp-dev/src/core/FixedStep.lua`,
  -- `STEP = 1/60`, confirmed the actual real rate `input.step` -- and
  -- therefore `tickDemon`, and therefore this function -- is called at,
  -- every real call, not merely a display refresh rate) instead calls it
  -- 60 times a real second -- a confirmed, exact 60/35 ≈ 1.71x
  -- over-frequent re-roll of `missileHoldFireRoll`'s own real per-tic
  -- chance, directly inflating how often an attack (and its real, audible
  -- `attackSound`) actually fires, on every single demon in the roster
  -- that has one. Gated on a plain per-demon real-time accumulator
  -- (`m.missileCheckTicAccum`) -- reproducing the real 35Hz check cadence
  -- exactly (dividing 1/60s real calls into real 1/35s DOOM-tic-sized
  -- chunks), a counter rather than a transplanted formula, matching
  -- CLAUDE.md's own "avoid math-derived code" preference. The `justHit`
  -- "fight back!" bypass is gated the SAME way, matching real DOOM's own
  -- actual behavior: nothing in the original source ever reacts faster
  -- than the next real 35Hz tic, "immediate" included.
  -- DIAGNOSTIC 2026-08-08 (CLAUDE.md workflow rule: "a bug that survives
  -- one fix attempt gets logging before a second attempt is made") --
  -- user report: "the demons still just walk around me only shooting
  -- every 10 seconds or so," filed AFTER the `stuckReplans` movecount-
  -- bypass fix above, meaning that fix alone did not resolve the real
  -- symptom -- the movecount gate was only ONE candidate explanation, not
  -- confirmed the actual one. Rather than guess a third theory blind, this
  -- throttled log (`DoomLog.event`, this file's own established pattern)
  -- records WHICH real gate is actually rejecting the shot each time --
  -- `hasLineOfSight` is a real, concrete suspect worth surfacing
  -- specifically: the screenshot accompanying this report shows the
  -- player standing inside dense hedge/bush terrain, and `hasLineOfSight`
  -- (above) samples every 8px along the straight line to the target
  -- against `blocksSight`, which treats ANY non-walkable cell as a sight
  -- blocker -- correct for a real wall, but if this map's own bush/hedge
  -- tiles are marked non-walkable (a real, plausible tileset fact, not
  -- yet confirmed), a demon standing right next to the player could fail
  -- line of sight almost every single check simply from bushes between
  -- them, independent of the movement/movecount system entirely. Logged,
  -- not assumed -- the next real report (or this log itself) should show
  -- definitively which branch is actually firing.
  -- `DOOM_TIC_SECONDS` itself now declared earlier (see `fireDemonProjectile`'s
  -- own header comment above) so `updateDemonProjectiles` can reach it too.
  local MISSILE_GATE_LOG_INTERVAL = 1 -- real seconds between log lines, per demon
  local function checkMissileRangeReal(ow, m, distSq, dt)
    m.missileCheckTicAccum = (m.missileCheckTicAccum or 0) + dt
    if m.missileCheckTicAccum < DOOM_TIC_SECONDS then return false end
    m.missileCheckTicAccum = m.missileCheckTicAccum - DOOM_TIC_SECONDS

    m.missileGateLogAccum = (m.missileGateLogAccum or 0) + DOOM_TIC_SECONDS
    local shouldLog = m.missileGateLogAccum >= MISSILE_GATE_LOG_INTERVAL
    if shouldLog then m.missileGateLogAccum = 0 end

    local tx, tz = npcCenter(m.target)
    if not tx then return false end
    local sight = hasLineOfSight(ow, m.px, m.py, tx, tz)
    if not sight then
      if shouldLog then
        DoomLog.event("AI", "%s (id=%s) missile check: NO LINE OF SIGHT (dist=%.1f)",
          m.name, tostring(m.id), math.sqrt(distSq))
      end
      return false
    end
    if m.justHit then
      m.justHit = false
      return true
    end
    if m.reactionTime and m.reactionTime > 0 then
      if shouldLog then
        DoomLog.event("AI", "%s (id=%s) missile check: reactionTime=%.2f still pending",
          m.name, tostring(m.id), m.reactionTime)
      end
      return false
    end
    local holdFire = missileHoldFireRoll(m, math.sqrt(distSq))
    if shouldLog then
      DoomLog.event("AI", "%s (id=%s) missile check: sight=OK reactionTime=0 holdFireRoll=%s dist=%.1f",
        m.name, tostring(m.id), tostring(holdFire), math.sqrt(distSq))
    end
    if holdFire then return false end
    return true
  end

  -- FOUND 2026-08-08 -- direct user request: "audit the spider
  -- mastermind's behaviour and animations... seems like its using
  -- shotgun sound and is not shooting me with a minigun like it does in
  -- doom." Two separate real things bundled in that one report:
  --
  -- The SOUND is not a bug at all -- re-read `A_SPosAttack` fresh
  -- (`p_enemy.c:821-843`) and confirmed real DOOM's own Spider Mastermind
  -- attack state (`S_SPID_ATK2`/`ATK3`, `info.c:752-753`) calls that
  -- EXACT function -- the same one Shotgun Guy's own attack state calls
  -- -- which itself hardcodes `S_StartSound(actor, sfx_shotgn)` every
  -- single time it fires. There is no separate "minigun"/chaingun sound
  -- or attack function anywhere for this monster in the original
  -- 1993/1994 source at all (`mobjinfo[MT_SPIDER].attacksound` is
  -- literally `sfx_shotgn` too, `info.c:1608`) -- this roster's own
  -- `attackSound = "DSSHOTGN"` (set in a previous round) was already
  -- exactly correct.
  --
  -- The CADENCE is the real gap. `A_SpidRefire` (`p_enemy.c:882-896`),
  -- re-read fresh: `if (P_Random() < 10) return;` -- a ~3.9% chance to
  -- return immediately, changing NOTHING, which lets the state machine's
  -- own natural `nextstate` (back to `S_SPID_ATK2`) continue the burst on
  -- its own. The other ~96.1% of checks fall through to `if (!target ||
  -- target->health<=0 || !P_CheckSight(...)) { switch to seestate }` --
  -- which ONLY breaks the loop if the target is ACTUALLY gone; as long as
  -- the target stays alive and in sight, this branch does nothing either,
  -- and the burst ALSO just continues via the same natural nextstate.
  -- Net real effect: once started, the burst is functionally UNBROKEN
  -- for as long as the target remains alive and visible -- a real,
  -- relentless stream of fire, not "usually continues with occasional
  -- pauses." This mod's own existing `checkMissileRangeReal` (this
  -- monster's own real `P_CheckMissileRange`, ABOVE) was being re-run on
  -- EVERY single shot, including CONTINUATION shots mid-burst -- a
  -- fundamentally different, far more hesitant real mechanic
  -- (`missileHoldFireRoll`'s own distance-scaled chance to simply not
  -- fire again, only halved for this roster's own bosses) that real DOOM
  -- only ever uses to decide whether to START an attack from Chase state
  -- in the first place, never to decide whether an ALREADY-firing burst
  -- continues. `m.spidBursting` (set the instant a shot connects, in the
  -- missile-attack branch below; cleared here and by a pain interrupt,
  -- see `demonResolver`'s own matching comment) tracks which of those two
  -- real states this monster is actually in.
  local function checkSpidRefireReal(ow, m)
    if math.random(0, 255) < 10 then return true end -- P_Random()<10: continue unconditionally, real DOOM quirk included
    local tx, tz = npcCenter(m.target)
    if not tx then return false end
    if targetIsGone(ow, m.target) then return false end
    if ow and ow.player and m.target == ow.player and not DoomHealth.isAlive() then return false end
    return hasLineOfSight(ow, m.px, m.py, tx, tz)
  end

  -- A_Look's own real seesound switch (p_enemy.c:631-661): a monster
  -- whose own real mobjinfo seesound happens to be one of the shared
  -- "posit"/"bgsit" family sounds gets a RANDOM pick across that whole
  -- family instead of always playing its own specific one -- a real,
  -- easy-to-miss DOOM quirk (Shotgun Guy's own real seesound is literally
  -- `sfx_posit2`, yet still randomizes across posit1/2/3, because the
  -- switch matches by VALUE, not by monster identity). `roster.seeSound`
  -- has carried the real WAD lump name since Phase 21 but was never
  -- actually played until now.
  local POSIT_FAMILY = { "DSPOSIT1", "DSPOSIT2", "DSPOSIT3" }
  local BGSIT_FAMILY = { "DSBGSIT1", "DSBGSIT2" }
  local function pickSeeSoundLump(roster)
    local s = roster.seeSound
    if s == "DSPOSIT1" or s == "DSPOSIT2" or s == "DSPOSIT3" then
      return POSIT_FAMILY[math.random(#POSIT_FAMILY)]
    end
    if s == "DSBGSIT1" or s == "DSBGSIT2" then
      return BGSIT_FAMILY[math.random(#BGSIT_FAMILY)]
    end
    return s
  end

  local function playSeeSound(m)
    if not m.roster.seeSound then return end
    local lump = pickSeeSoundLump(m.roster)
    local ok, snd = pcall(DoomWadImport.loadSound, lump)
    if ok and snd then DoomWadImport.playClone(lump .. " (" .. m.name .. " see)", snd) end
  end

  -- Bottom of A_Chase (p_enemy.c:770-775): `P_Random() < 3` is a flat
  -- 3/256 (~1.2%) chance PER TIC while actively chasing.
  --
  -- CORRECTED 2026-08-08 (direct user request: "audit the enemy sound
  -- system... tons of sounds playing way too frequently") -- this used to
  -- be restated as a flat per-CALL roll with a comment claiming "no
  -- frame-rate conversion is needed the way a duration/countdown would."
  -- That reasoning only holds if this function is called once per real
  -- DOOM tic (35Hz) -- it isn't. `tickDemon` (this function's own only
  -- caller) runs once per real `input.step` call, which this engine's own
  -- fixed-step game loop (`gen1recomp-dev/src/core/FixedStep.lua`,
  -- `STEP = 1/60`) fires at a real, fixed 60Hz, confirmed by direct
  -- inspection of that file -- 60 calls a real second, not DOOM's own 35.
  -- Rolling the SAME 3/256 chance 60 times a second instead of 35 inflates
  -- every demon's real per-second activesound trigger rate by a confirmed,
  -- exact 60/35 ≈ 1.71x -- with several demons active/chasing at once
  -- (this mod's own common case), that compounds into exactly the
  -- "constant background noise" the user reported. Fixed with a plain
  -- per-demon real-time accumulator (`m.activeSoundTicAccum`) that only
  -- actually rolls the real 3/256 chance once genuine 1/35s of real time
  -- has elapsed -- a counter, not a transplanted formula, matching
  -- CLAUDE.md's own "avoid math-derived code" preference, and reproducing
  -- DOOM's real per-tic cadence exactly regardless of this engine's own
  -- fixed-step rate.
  local function maybePlayActiveSound(m, dt)
    if not m.roster.activeSound then return end
    m.activeSoundTicAccum = (m.activeSoundTicAccum or 0) + dt
    if m.activeSoundTicAccum < DOOM_TIC_SECONDS then return end
    m.activeSoundTicAccum = m.activeSoundTicAccum - DOOM_TIC_SECONDS
    if math.random(0, 255) >= 3 then return end
    local ok, snd = pcall(DoomWadImport.loadSound, m.roster.activeSound)
    if ok and snd then DoomWadImport.playClone(m.roster.activeSound .. " (" .. m.name .. " active)", snd) end
  end

  -- A_Chase's own real top-of-function target-validity check
  -- (p_enemy.c:704-713): `if (!actor->target ||
  -- !(actor->target->flags&MF_SHOOTABLE))` -- drops a target that is no
  -- longer shootable (killed) and looks for a replacement, or reverts to
  -- idle. `targetIsGone` already covers a citizen's own real removal
  -- (`MF_SHOOTABLE` effectively going false at that same real moment,
  -- p_inter.c's own `P_KillMobj` clearing it) -- the player-death half
  -- (FIXED 2026-08-07, user report: "Enemies continue hunting the
  -- player after the player is dead") was the one real gap:
  -- `targetIsGone` deliberately treats the player as never "gone" (they
  -- can't be removed from a list the way an NPC can), so nothing here
  -- had ever checked whether they'd actually DIED mid-chase.
  --
  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- drops a stale/dead target and, if the demon is still targetless
  -- afterward, tries to acquire a fresh one -- pure `m.target`/`m.state`
  -- bookkeeping, called once at the top of `tickDemon` below.
  --
  -- Grouped as fields on a private `_demonAI` table hung off the already-
  -- existing `DoomDemons` local, not six separate top-level `local
  -- function`s -- this file's own main chunk is already at Lua's real
  -- 200-local ceiling (see `pokedoom_lua_200_local_limit` memory / this
  -- file's own compile-failure history, also cited near `shadowShimmer`
  -- above), so a table FIELD assignment on an EXISTING local is used
  -- instead of a fresh `local` declaration for each one -- the same
  -- established workaround, costing zero additional local slots.
  DoomDemons._demonAI = {}
  function DoomDemons._demonAI.updateDemonTargeting(ow, m)
    local targetDead = m.target and ow and ow.player and m.target == ow.player
                        and not DoomHealth.isAlive()
    local justLostTarget = false
    if m.target and (targetIsGone(ow, m.target) or targetDead) then
      DoomLog.event("DEMON", "%s (id=%s) lost target (%s) -> roam",
        m.name, tostring(m.id), targetDead and "target died" or "target gone")
      m.target.pokedoomBeingHunted = nil
      m.target = nil
      justLostTarget = true
      -- P_SetMobjState(actor, actor->info->spawnstate) -- real DOOM
      -- reverts straight to idle here (this mod's own `else` roam branch,
      -- below) rather than leaving `m.state` at "chase" with no target.
      m.state = "roam"
    end

    if not m.target then
      -- CORRECTED 2026-08-07 -- user report: two demons standing right
      -- near town buildings, one the player's own screenshot confirms had
      -- successfully chased/attacked before ("a cacodemon which in a
      -- previous playtest did kill the player"), now simply not pathing to
      -- anyone. Found a real, confirmed asymmetry against real DOOM while
      -- re-auditing: `findTarget`'s own header comment already notes
      -- `A_Chase`'s inline reacquisition uses `allaround=true` (no facing
      -- cone) while `A_Look`'s own idle scan uses `false` -- but until now
      -- EVERY call here passed the same cone-gated search regardless of
      -- which real situation it actually was. A demon that had already
      -- been actively chasing (a citizen fled out of `DETECT_RADIUS`, or
      -- the player died mid-chase, both real, ordinary ways to lose a
      -- target near the tighter sightlines a town's own building layout
      -- creates) got treated exactly like one that had never noticed
      -- anyone at all -- forced to wait for someone to wander directly
      -- into its current facing before it could ever react again, even
      -- though it was already "awake." `justLostTarget` is true only on
      -- the exact same tic the block above just cleared `m.target` --
      -- the real, same-tic inline retry `A_Chase` itself performs before
      -- ever reverting to `spawnstate` -- passed through as `allaround`
      -- here. Every OTHER call (a demon that's simply been sitting in
      -- `roam` for a while with nothing having just happened) still gets
      -- the real cone, matching `A_Look`'s own real behavior exactly.
      --
      -- `A_Look`'s own real soundtarget check (p_enemy.c:608-623) comes
      -- FIRST, ahead of the sighted/facing-cone search below -- a normal
      -- monster wakes to a nearby gunshot with no line-of-sight needed at
      -- all. See `heardNoiseAlert`/`DoomDemons.noiseAlert` above for the
      -- full derivation. Real DOOM's own soundtarget check lives ONLY in
      -- `A_Look` (the genuine idle/spawnstate action) -- `A_Chase`'s own
      -- same-tic inline retry above (`justLostTarget`, a DIFFERENT real
      -- function, `P_LookForPlayers(actor, true)`) never consults it, so
      -- this only applies to a demon that's been genuinely idle, not one
      -- that just lost a target this exact tick.
      local heardShot = not justLostTarget and ow.player and heardNoiseAlert(ow, m)
      if heardShot then
        m.target = ow.player
      else
        m.target = findTarget(ow, m, justLostTarget)
      end
      if m.target then
        local targetIsPlayerNow = ow and ow.player and m.target == ow.player
        DoomLog.event("DEMON", "%s (id=%s) acquired target (%s, allaround=%s%s) -> chase",
          m.name, tostring(m.id), targetIsPlayerNow and "player" or "npc", tostring(justLostTarget),
          heardShot and ", heard shot" or "")
        m.target.pokedoomBeingHunted = true
        m.state = "chase"
        m.roamWaypoint = nil
        -- A_Look's own real "seeyou:" trigger (p_enemy.c:629-663) --
        -- previously-unused roster sound, now actually played on the real
        -- moment DOOM itself plays it: the instant a target is acquired.
        pcall(playSeeSound, m)
        -- reactiontime resets on a FRESH acquisition -- matches real
        -- DOOM's own `reactiontime = info->reactiontime` at spawn
        -- (p_mobj.c:504) combined with `A_Look` never touching it itself
        -- (a monster that's been standing around idle for a while, per
        -- this mod's own roam system, still has to "react" the same
        -- short beat real DOOM gives it the first time it ever wakes up).
        m.reactionTime = ticsToSeconds(REACTIONTIME_TICS)
        m.threshold = ticsToSeconds(BASETHRESHOLD_TICS)
      end
    end
  end

  -- A_Chase's own top-of-function decrements (p_enemy.c:676-690) --
  -- unconditional, every real tic while a target exists. `threshold`
  -- is tracked faithfully; A_Chase's own "reconsider target if it's
  -- out of sight" block genuinely IS `netgame`-only and has no effect
  -- here, single-player. CORRECTED 2026-08-07: an earlier version of
  -- this comment claimed `P_DamageMobj`'s own retarget-onto-attacker
  -- rule ALSO had "no observable effect... since only the player ever
  -- damages a demon here" -- that conflated two different real
  -- effects of the SAME source block (p_inter.c:904-915, cited fresh
  -- again here) that only share one gate. Real DOOM infighting (one
  -- monster retargeting AWAY from its current target ONTO a different
  -- attacker) genuinely does need a second damage source, correctly
  -- absent here. But the SAME block's OTHER real effect --
  -- `!target->threshold` also covers a monster with NO target at all
  -- (threshold starts at 0) getting damaged and immediately acquiring
  -- WHOEVER hit it as a fresh target -- needs no second source, and
  -- is exactly what makes a passive DOOM monster snap awake and
  -- retaliate the instant it's shot, target-acquisition cone or not.
  -- This mod's own player-vs-demon hit resolvers (`demonResolver`/
  -- `demonAoeResolver`, below) never implemented that half at all --
  -- a demon already mid-roam (heading to an unrelated waypoint,
  -- possibly facing away) that took sustained player fire kept
  -- roaming right through it, only playing a pain sound/stagger,
  -- because nothing ever set `m.target`. User report: "why is this
  -- cacodemon walking away from me still... this has been an ongoing
  -- issue." Fixed at the resolvers themselves (see their own header
  -- comments) -- this file's own `threshold` tracking WAS already
  -- correct and ready for this; the gap was purely in the hit path
  -- never reading/writing it.
  --
  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- the per-tic reactionTime/threshold/attackCooldown decrements plus the
  -- citizen-flee step, called once from `tickDemon` before the melee/
  -- missile/chase decision below reads any of them.
  function DoomDemons._demonAI.updateChaseTimers(ow, m, dt, targetIsPlayer)
    if m.reactionTime and m.reactionTime > 0 then
      m.reactionTime = math.max(0, m.reactionTime - dt)
    end
    if m.threshold and m.threshold > 0 then
      if targetIsGone(ow, m.target) then
        m.threshold = 0
      else
        m.threshold = math.max(0, m.threshold - dt)
      end
    end
    -- `m.attackCooldown`: NOT a real DOOM quantity by itself -- decremented
    -- centrally here, then read/set by whichever attack branch below
    -- fires. Most roster entries never set it above 0 (their own real
    -- pacing comes entirely from `checkMissileRangeReal`'s own
    -- reactiontime/movecount/chance gating, or from `PLAYER_MELEE_COOLDOWN`
    -- for melee) -- SHOTGUYGUY/SPIDERMASTERMIND/CYBERDEMON's own roster
    -- `attackCooldown` (0.4/0.3/1.5) is this project's own explicit,
    -- flagged stand-in for their real sustained/refire-burst behavior
    -- (`A_SpidRefire`/`A_CyberAttack`'s own 3-shot cycle, p_enemy.c:
    -- 882-896) -- see those roster entries' own header comments -- kept
    -- as an EXTRA gate on top of the real one, not a replacement for it.
    if m.attackCooldown and m.attackCooldown > 0 then
      m.attackCooldown = math.max(0, m.attackCooldown - dt)
    end

    -- `stepCitizenFlee` drives an NPC's own movement fields directly --
    -- meaningless (and unsafe to try) on the player, who moves from
    -- real input, not those fields. `m.cx`/`.cy` are DERIVED from the
    -- real, continuous `m.px`/`.py` now (see the continuous-movement
    -- section above) -- kept in sync here purely for this call and for
    -- rendering/lookup code elsewhere that still wants a cell coordinate.
    m.cx, m.cy = math.floor(m.px / 16), math.floor(m.py / 16)
    if not targetIsPlayer then stepCitizenFlee(ow, m.target, m.cx, m.cy) end
  end

  -- check for melee attack (p_enemy.c:724-733) -- checked BEFORE any
  -- missile/hitscan/charge attack, matching real DOOM's own real
  -- priority. `projectile_only` (Cyberdemon) and `charge` (Lost Soul)
  -- have no real `meleestate` at all (confirmed, Phase 22's own
  -- audit) -- `hitscan` demons (Zombieman/Shotgun Guy/Spider
  -- Mastermind) likewise have none in real DOOM.
  --
  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- returns true when a melee attempt was in range this tick (attacked,
  -- or still cooling down against the player) -- `tickDemon` below stops
  -- for this tick either way, matching the original unconditional
  -- `return` this block used to end with inline.
  function DoomDemons._demonAI.handleMeleeAttack(ow, m, targetIsPlayer, distSq)
    local hasMelee = m.roster.attackType ~= "projectile_only"
                  and m.roster.attackType ~= "charge"
                  and m.roster.attackType ~= "hitscan"
    if hasMelee and checkMeleeRangeReal(ow, m, distSq) then
      if targetIsPlayer then
        -- Contact damage, not a kill, and the demon keeps attacking
        -- (unlike a caught citizen, the player isn't removed by one
        -- hit) -- cooldown-gated the same shape Horde's own
        -- `Horde.damage` already uses for its own contact hits.
        if (m.attackCooldown or 0) <= 0 then
          m.attackCooldown = m.roster.attackCooldown or PLAYER_MELEE_COOLDOWN
          startAttackAnim(m)
          playDemonSound(m.roster.meleeSound, m.name .. " melee")
          m.lastHitKind = "melee" -- real melee contact (A_SargAttack/A_TroopAttack/
                                   -- A_HeadAttack/A_BruisAttack's own P_CheckMeleeRange
                                   -- branch) -- picks the real GZDoom HitObituary variant
          pcall(DoomHealth.damage, rollDemonDamage(m.roster), { source = "demon", attacker = m })
        end
      else
        startAttackAnim(m)
        playDemonSound(m.roster.meleeSound, m.name .. " melee")
        local caught = m.target
        m.target = nil
        m.state = "roam"
        catchAndKillNpc(ow, caught)
      end
      return true
    end
    return false
  end

  -- check for missile attack (p_enemy.c:735-750) -- THE real mechanic
  -- behind "moves around a bit before shooting": a fresh `movecount`
  -- (rerolled 0-15 tics on every successful step) blocks even
  -- CONSIDERING a missile/hitscan/charge attack until the demon's
  -- current walk-cycle runs out, and `checkMissileRangeReal`'s own
  -- distance-scaled chance can STILL hold fire after that.
  --
  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- computes whether an attack may START from Chase state this tick --
  -- `tickDemon` below still owns actually FIRING it (the branch is large
  -- enough, and its own diagnostic logging tied closely enough to the
  -- surrounding chase-tick context, that pulling it out too would add
  -- more indirection than clarity).
  function DoomDemons._demonAI.canFireMissileNow(ow, m, distSq, dt)
    local hasMissile = m.roster.attackType == "hitscan"
                     or m.roster.attackType == "projectile_dual"
                     or m.roster.attackType == "projectile_only"
                     or m.roster.attackType == "charge"
    -- 2026-08-08 -- `checkMissileRangeReal` (this monster's own real
    -- `P_CheckMissileRange`) is the right gate for deciding whether to
    -- START attacking from Chase state, but real DOOM never re-runs it
    -- to decide whether an ALREADY-firing Spider Mastermind burst
    -- CONTINUES -- that's `A_SpidRefire`'s own separate, far more
    -- persistent real check (`checkSpidRefireReal`'s own header comment
    -- has the full derivation). `m.spidBursting` (set below the instant
    -- a shot connects) picks which of the two real gates actually
    -- applies this tick -- every other roster entry never sets that
    -- flag, so `checkMissileRangeReal` remains their own only real gate,
    -- completely unchanged.
    -- `STUCK_REPLAN_BYPASS_TICS`: comfortably past real DOOM's own max
    -- legitimate `movecount` window (15 real DOOM tics, ~0.43s) at this
    -- engine's own 60Hz `input.step` rate (~26 ticks) -- see the
    -- `stuckReplans` tracking above for the full derivation. Chosen high
    -- enough that ordinary, short-lived replanning near a corner never
    -- trips it, only a demon that's been genuinely fighting its own
    -- movement AI for a real, noticeable stretch.
    local STUCK_REPLAN_BYPASS_TICS = 45
    local movecountBlocks = (m.moveCount and m.moveCount > 0)
      and (m.stuckReplans or 0) <= STUCK_REPLAN_BYPASS_TICS
    local canFireMissile = false
    if hasMissile and (m.attackCooldown or 0) <= 0 and not movecountBlocks then
      if m.spidBursting then
        canFireMissile = checkSpidRefireReal(ow, m)
        if not canFireMissile then m.spidBursting = false end
      else
        canFireMissile = checkMissileRangeReal(ow, m, distSq, dt)
      end
    elseif hasMissile then
      -- DIAGNOSTIC 2026-08-08 -- see `checkMissileRangeReal`'s own
      -- header comment: this branch is the OTHER real place a shot can
      -- be blocked (never even reaching that function's own checks) --
      -- `attackCooldown` still counting down, or the movecount gate
      -- still active despite the `stuckReplans` bypass. Same throttled
      -- shape/interval as that function's own logging, tracked
      -- separately (`m.outerGateLogAccum`) so the two don't fight over
      -- one shared timer.
      m.outerGateLogAccum = (m.outerGateLogAccum or 0) + dt
      if m.outerGateLogAccum >= MISSILE_GATE_LOG_INTERVAL then
        m.outerGateLogAccum = 0
        DoomLog.event("AI", "%s (id=%s) missile gate BLOCKED OUTER: attackCooldown=%.2f movecountBlocks=%s moveCount=%s stuckReplans=%s",
          m.name, tostring(m.id), m.attackCooldown or 0, tostring(movecountBlocks),
          tostring(m.moveCount), tostring(m.stuckReplans or 0))
      end
    end
    return canFireMissile
  end

  -- Fires this demon's own real missile-range attack (hitscan/charge/
  -- projectile) -- called only once `tickDemon` (below) has already
  -- confirmed `canFireMissileNow`. Extracted 2026-08-19 during a project-
  -- wide readability audit: this used to be an ~120-line block inline in
  -- `tickDemon`'s own `if canFireMissile then ... end`, mixing per-shot
  -- diagnostic logging with the three real attack-type dispatches into one
  -- long branch -- structural cleanup only, no behavior change. Sets
  -- `m.attackCooldown`/`m.justAttacked` itself, matching what the inline
  -- version already did; the caller still handles its own early `return`.
  function DoomDemons._demonAI.fireMissileAttack(ow, m, targetIsPlayer, distSq)
    -- FIXED 2026-08-10 -- user report: "enemies are hitting me a lot
    -- more than in the actual doom game... health going down fully
    -- within 5 seconds... it was the soldier enemies." Root cause:
    -- `checkMissileRangeReal`'s own movecount/reactiontime/hold-fire
    -- gating (above) correctly reproduces `P_CheckMissileRange` --
    -- real DOOM's own "should I even START an attack from the chase
    -- state" check -- but this file never modeled the SEPARATE real
    -- fact that once a monster's attack STATE begins, it's locked
    -- into that state chain (A_FaceTarget -> fire -> return) for a
    -- real, fixed number of tics before `A_Chase` can run again at
    -- all, regardless of movecount. `m.roster.attackCycleTics` (set on
    -- ZOMBIEMAN/SHOTGUYGUY/IMP/CACODEMON/BARONOFHELL, see each entry's
    -- own header comment) is that real per-monster total, read fresh
    -- from each monster's own real ATK1-3 state tics (`info.c`) --
    -- used as the fallback here so every one of them gets a genuine
    -- minimum re-fire gate for the first time. `m.roster.attackCooldown`
    -- (SPIDERMASTERMIND/CYBERDEMON only) is a SEPARATE, already-
    -- justified stand-in for their own real sustained-burst mechanics
    -- (`A_SpidRefire`/`A_CyberAttack`'s 3-shot cycle) and still takes
    -- priority when set.
    m.attackCooldown = m.roster.attackCooldown
      or ((m.roster.attackCycleTics or 0) * DOOM_TIC_SECONDS)
    -- DIAGNOSTIC 2026-08-11 -- user report: "zombieman shooting time is
    -- way too fast... impossible to play without dying almost
    -- instantly." Every number involved has already been re-audited
    -- fresh against real DOOM in this same file (`attackCycleTics=26`
    -- matches the real 10+8+8 ATK1-3 chain; `rollDemonDamage`'s
    -- `(1-5)*3` formula; default difficulty scale is 1.0x) -- this
    -- exact complaint already survived one fix attempt (2026-08-10's
    -- `attackCycleTics` gate, this branch's own header comment above),
    -- and the user's own follow-up couldn't say whether they were
    -- facing one Zombieman or several demons at once -- two situations
    -- that would look and feel identical to the player but need
    -- completely different fixes (a real remaining per-shot cadence
    -- bug vs. plain encounter density with no cover). Per CLAUDE.md's
    -- own "a bug that survives one fix attempt gets logging before a
    -- second attempt" rule: logs this demon's own real re-fire
    -- interval (should never read meaningfully below `attackCooldown`
    -- itself if the gate above is actually working) AND how many OTHER
    -- demons are ALSO actively targeting the player at this exact
    -- moment, so the next report carries real numbers instead of a
    -- third guess.
    if targetIsPlayer then
      local now = love.timer and love.timer.getTime() or 0
      local sinceLastFire = m.lastFireClock and (now - m.lastFireClock) or -1
      m.lastFireClock = now
      local concurrent = 0
      for _, other in ipairs(demons) do
        if other ~= m and other.target == ow.player and other.mapId == ow.map.id and other.state ~= "dying" then
          concurrent = concurrent + 1
        end
      end
      DoomLog.event("AI", "%s (id=%s) FIRING at player: sinceLastFire=%.2fs (this monster's own cooldown=%.2fs) concurrentOtherAttackers=%d dist=%.1f",
        m.name, tostring(m.id), sinceLastFire, m.attackCooldown, concurrent, math.sqrt(distSq))
    end
    if m.name == "SPIDERMASTERMIND" then m.spidBursting = true end
    if m.roster.attackSound then
      local ok, snd = pcall(DoomWadImport.loadSound, m.roster.attackSound)
      if ok and snd then DoomWadImport.playClone(m.roster.attackSound .. " (" .. m.name .. " attack)", snd) end
    end
    startAttackAnim(m)
    if m.roster.attackType == "hitscan" then
      -- FEATURE 2026-08-10 -- see `pelletConnects`'s own header
      -- comment above for the full audit/derivation. Real DOOM fires
      -- `pelletCount` INDEPENDENT pellets per attack (1 for Zombieman,
      -- 3 for Shotgun Guy/Spider Mastermind, `A_PosAttack`/
      -- `A_SPosAttack`) -- each with its own real random spread angle
      -- deciding whether IT connects, not a single guaranteed hit.
      local tx, tz = npcCenter(m.target)
      local dist = math.sqrt(distSq)
      local pellets = m.roster.pelletCount or 1
      if targetIsPlayer then
        for _ = 1, pellets do
          if pelletConnects(dist) then
            -- P_SpawnBlood (p_mobj.c:836-859) is ONLY ever reached via
            -- P_LineAttack's own hitscan traversal (PTR_ShootTraverse,
            -- p_map.c:1003-1008), confirmed only Zombieman/Shotgun Guy/
            -- Spider Mastermind's own real attacks (`A_PosAttack`/
            -- `A_SPosAttack`) route through it -- see this project's
            -- own BUGS.md for the full audit. Spawned at the PLAYER's
            -- own position (`tx, tz`), not the demon's -- once per
            -- CONNECTING pellet, matching real DOOM's own per-hit call.
            local hitDamage = rollDemonDamage(m.roster)
            -- FIX 2026-08-11 -- same real gap as `lib/DoomWeapons.lua`'s
            -- own matching fix this round (`lib/DoomPuff.lua`'s header
            -- comment has the full render-contract derivation) -- this
            -- branch only ever runs `if targetIsPlayer`, so the real
            -- impact height is the player's own eye level.
            local playerGh = groundY(ow, ow.player.cellX, ow.player.cellY)
            pcall(DoomBlood.spawn, ow, tx, tz, hitDamage, playerGh + FirstPerson.EYE_HEIGHT)
            m.lastHitKind = "ranged"
            pcall(DoomHealth.damage, hitDamage, { source = "demon", attacker = m })
          end
        end
      else
        -- NPCs have no partial HP pool in this mod (the established
        -- "every landed hit is a kill" design) -- the first connecting
        -- pellet is already lethal, so there's no reason to keep
        -- rolling the rest once one lands.
        local connected = false
        for _ = 1, pellets do
          if pelletConnects(dist) then connected = true break end
        end
        if connected then
          local caught = m.target
          m.target = nil
          m.state = "roam"
          catchAndKillNpc(ow, caught)
        end
      end
    elseif m.roster.attackType == "charge" then
      -- Lost Soul's own real attack (Phase 22, Round 3) --
      -- `tickDemon`'s own top-of-function `m.charging` check takes
      -- over movement entirely from the very next tick onward.
      startLostSoulCharge(m)
    else -- projectile_dual (Imp/Cacodemon/Baron, too far for melee) / projectile_only (Cyberdemon)
      pcall(fireDemonProjectile, ow, m, m.target)
    end
    m.justAttacked = true
  end

  -- chase towards target (p_enemy.c:763-768): keep moving in the
  -- CURRENT direction (no reroll) unless the walk-cycle expired or
  -- the step failed, in which case `P_NewChaseDir` picks a new one --
  -- `dist` is this real tic's own continuous move budget (real DOOM
  -- speed, scaled to world px/second, times this frame's own `dt`),
  -- not a whole cell the way the old system's own per-step distance
  -- was.
  --
  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- runs once `tickDemon` below has ruled out melee/missile this tick.
  function DoomDemons._demonAI.chaseMoveStep(ow, m, dt)
    local dist = demonSpeedPxPerSec(m) * dt
    -- FIX 2026-08-08 -- see `tryWalkDir`'s own header comment above for
    -- the full derivation: `m.moveCount` is now a real discrete DOOM-tic
    -- integer (matching `actor->movecount`'s own real C type), decremented
    -- by exactly 1 once per real accumulated 1/35s DOOM tic -- NOT by the
    -- raw per-frame `dt` float -- so it genuinely lingers at an observable
    -- `0` for one real window (however many 60Hz frames that spans)
    -- before going negative, instead of a float jumping straight past
    -- zero within a single frame.
    if m.moveCount then
      m.moveCountTicAccum = (m.moveCountTicAccum or 0) + dt
      while m.moveCountTicAccum >= DOOM_TIC_SECONDS do
        m.moveCountTicAccum = m.moveCountTicAccum - DOOM_TIC_SECONDS
        m.moveCount = m.moveCount - 1
      end
    end
    local stepFailed = not attemptStep(ow, m, m.moveDir, dist)
    if not m.moveCount or m.moveCount < 0 or stepFailed then
      -- FEATURE 2026-08-08 -- user report + screenshot: a demon right
      -- next to the player "spin[ning] around" for "5-10 seconds"
      -- before ever firing. Root cause: the player is a real, solid
      -- obstacle to demon movement (`entityBlocksCell`, same as a wall)
      -- -- a demon whose most-direct approach keeps landing ON the
      -- player's own cell fails its per-tic step and calls
      -- `pickNewChaseDir` again, which (per real `P_TryWalk`) rerolls a
      -- fresh `m.moveCount` on every SUCCESSFUL alternate direction it
      -- finds -- and since `canFireMissile` below requires `m.moveCount
      -- <= 0` (the real `A_Chase` movecount gate, p_enemy.c:738-742), a
      -- demon that keeps finding short-lived sidesteps around the
      -- player's own hitbox can keep that gate refreshed far longer than
      -- real DOOM's own genuine 0-15-tic (~0-0.43s) window ever allows,
      -- since real DOOM monsters rarely spend that long continuously
      -- failing to hold a direction next to a target. `m.stuckReplans`
      -- counts consecutive FAILED-step tics (reset the instant a plain
      -- continuing step succeeds, below) -- once it clears a threshold
      -- well past that real natural window, the missile gate stops
      -- honoring `moveCount` so the demon gets a real chance to fight
      -- back instead of being silently muted by its own movement AI.
      m.stuckReplans = (m.stuckReplans or 0) + 1
      pickNewChaseDir(ow, m, dist)
    else
      m.stuckReplans = 0
    end
    maybePlayActiveSound(m, dt)
  end

  -- Extracted as its own helper (structural cleanup, behavior unchanged):
  -- the no-target roam branch, self-contained (needs only ow/m/dt).
  function DoomDemons._demonAI.tickDemonRoam(ow, m, dt)
    m.state = "roam"
    if not m.roamWaypoint then pickRoamWaypoint(ow, m) end
    if m.roamWaypoint then
      -- CORRECTED 2026-08-07 -- user's own explicit request: "the 3d
      -- space should just be treated like a normal 3d space with no
      -- grid and the doom enemies should just be able to walk wherever
      -- as long as they dont walk past collision." `pickRoamWaypoint`
      -- still picks a random WALKABLE CELL as a destination (a
      -- reasonable, simple way to find somewhere reachable to head
      -- toward -- picking a truly arbitrary continuous point risks
      -- aiming into the middle of a solid building), but the demon now
      -- glides straight at that cell's own real world-px center at any
      -- angle, sliding along whatever it grazes via the same continuous
      -- collision the chase system above uses, rather than being
      -- teleported cell-to-cell with a visual interpolation layered on
      -- top.
      local wx, wz = worldPos(m.roamWaypoint[1], m.roamWaypoint[2])
      stepToward(ow, m, wx, wz, demonSpeedPxPerSec(m) * dt)
      local rdx, rdz = wx - m.px, wz - m.py
      if rdx * rdx + rdz * rdz < 16 then -- close enough to the waypoint's own center
        m.roamWaypoint = nil
      end
    end
    m.cx, m.cy = math.floor(m.px / 16), math.floor(m.py / 16)
  end

  local function tickDemon(ow, m, dt)
    if m.state == "dying" then return end

    if m.staggerTimer and m.staggerTimer > 0 then
      m.staggerTimer = m.staggerTimer - dt
      return
    end

    if m.charging then
      tickLostSoulCharge(ow, m)
      return
    end

    DoomDemons._demonAI.updateDemonTargeting(ow, m)

    if m.target then
      local targetIsPlayer = ow and ow.player and m.target == ow.player
      DoomDemons._demonAI.updateChaseTimers(ow, m, dt, targetIsPlayer)

      -- Real DOOM's own `A_Chase` runs its FULL logic every single tic
      -- regardless of movement state -- there is no separate "still
      -- arriving" concept to gate behind at all once movement is
      -- genuinely continuous (this file's own earlier "only decide once
      -- fully arrived at a cell" rule was itself a byproduct of the OLD
      -- teleport-and-glide system, removed along with it).
      local tx, tz = npcCenter(m.target)
      if not tx then return end
      local dx, dz = tx - m.px, tz - m.py
      local distSq = dx * dx + dz * dz

      -- MF_JUSTATTACKED (p_enemy.c:715-722): the tic right after firing
      -- ANY missile-state attack (hitscan/projectile/charge) skips
      -- straight to picking a new direction -- no re-checking whether to
      -- attack again immediately. Real DOOM only skips this on normal/
      -- easy skill (`gameskill != sk_nightmare && !fastparm`) -- this mod
      -- has no difficulty-tier system at all (the same real exclusion
      -- every other difficulty-gated DOOM behavior already gets
      -- elsewhere in this project), so that branch is always taken here.
      if m.justAttacked then
        m.justAttacked = false
        pickNewChaseDir(ow, m, demonSpeedPxPerSec(m) * dt)
        maybePlayActiveSound(m, dt)
        return
      end

      if DoomDemons._demonAI.handleMeleeAttack(ow, m, targetIsPlayer, distSq) then return end

      local canFireMissile = DoomDemons._demonAI.canFireMissileNow(ow, m, distSq, dt)
      if canFireMissile then
        DoomDemons._demonAI.fireMissileAttack(ow, m, targetIsPlayer, distSq)
        return
      end

      DoomDemons._demonAI.chaseMoveStep(ow, m, dt)
    else
      DoomDemons._demonAI.tickDemonRoam(ow, m, dt)
    end
  end

  return {
    tickDemon = tickDemon,
    ticsToSeconds = ticsToSeconds,
    playSeeSound = playSeeSound,
    REACTIONTIME_TICS = REACTIONTIME_TICS,
    BASETHRESHOLD_TICS = BASETHRESHOLD_TICS,
    DIR = DIR,
  }
end

return DoomDemonAI
