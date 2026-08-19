-- PokeDoom Phase 11 (scoped): the DOOM status bar background, the
-- ready-ammo number, and the face widget, at the user's own explicit
-- request ("let's just get the background, and face widget working
-- first", then "wire the ammo counter to the hud ammo counter"). Health%
-- /Armor% were added once Phase 12's own `lib/DoomHealth.lua` gave this
-- file real values to read (`DoomHealth.health()`/`armor()`). The arms
-- grid was added by Phase 18 Bug 4 (see `drawArms()` below).
--
-- ------- the face widget: full priority-ladder parity, Phase 25
--
-- DOOM's own real face state machine (`ST_updateFaceWidget`,
-- st_stuff.c:752-922) is a 9-tier priority ladder. As of Phase 25
-- (`phases/phase-25-face-widget-parity.md`, audited fresh against
-- source, not carried forward from this file's own earlier, now-stale
-- claims), every tier is implemented except the two genuinely N/A ones:
--   - priority 9 (dead) -- `DoomHealth.isDead()`.
--   - priority 8 (evil grin) -- `DoomHealth.bonusCount()` + a same-tick
--     `weaponowned[]` flip.
--   - priority 7 (attacked) / priority 6-7 (self-damage) -- built this
--     phase using `DoomHealth.attacker()`/`.damageCount()` (both real,
--     already-tracked Phase 12/15 signals) -- see `attackedFace` below.
--   - priority 5 (rapid-fire rampage) -- `DoomWeapons.isAttacking()`
--     held `RAMPAGEDELAY`.
--   - priority 4 (god/invulnerable) -- built this phase as a stated,
--     honest stand-in: real DOOM's own trigger (`CF_GODMODE`/
--     `pw_invulnerability`) has no live equivalent in this mod yet
--     (Phase 14, `phases/phase-14-god-mode.md`, still "Not started"),
--     so this reads `Options.infiniteHealthEnabled()` instead -- this
--     mod's own existing immunity toggle wearing the real DOOM face,
--     per that phase doc's own explicitly-flagged option (b). Swap to a
--     real `godmode`/`invulnerable` flag once Phase 14 lands.
--   - priority 0 (idle) -- `straightFace()`, random glance.
--   - `STFB<n>` (colored face background) -- confirmed N/A, netgame-only
--     in real DOOM; this mod is single-player.

local V = ...
local Host = V.host
local DoomWadImport = V.require("DoomWadImport")
local DoomWeapons = V.require("DoomWeapons")
local DoomHealth = V.require("DoomHealth")
local DoomFont = V.require("DoomFont")
local DoomDeathScreen = V.require("DoomDeathScreen")
local Options = V.require("DoomOptions")
local DoomSpriteCache = V.require("DoomSpriteCache")
local DoomVirtualCanvas = V.require("DoomVirtualCanvas")
local FirstPerson = Host.require("FirstPerson")
local Voxel = Host.require("VoxelState")

local DoomHud = {}

-- ------- DOOM's own real 320x200 screen space
--
-- `VIRTUAL_W`/`VIRTUAL_H` shared via `lib/DoomVirtualCanvas.lua` (same
-- real constants `lib/DoomMenuSkin.lua`/`lib/DoomTownInvasion.lua` use).
-- This file's own transform is genuinely DIFFERENT from that shared
-- module's `centered` one, though, so it stays defined here rather than
-- also moving there: reported in-game, a window narrower than 320:200
-- (this dev environment's own default test window is roughly 1.4:1)
-- leaves the scale WIDTH-bound, and centering the 200-line canvas
-- top-to-bottom put real floor/ground visible below the status bar
-- instead of the literal bottom of the screen -- wrong for a status bar
-- specifically, whatever else can be said for a centered weapon view
-- model or a billboard gib. Real DOOM's own bar always touches the true
-- bottom edge (native 320x200 has no letterboxing to speak of at all);
-- a source port on a taller-than-4:3 display gets there by pillarboxing
-- (bars left/right, full height kept), never by leaving a gap under the
-- bar -- so `voy` below anchors to the bottom (`h - VIRTUAL_H*scale`,
-- all the slack pushed to the TOP) instead of splitting it evenly. In
-- the height-bound case (a wide-enough window) this is already 0 either
-- way, so nothing changes there.
local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H
local function virtualScaleAndOffset(w, h)
  local scale = math.min(w / VIRTUAL_W, h / VIRTUAL_H)
  return scale, (w - VIRTUAL_W * scale) / 2, h - VIRTUAL_H * scale
end

-- ST_Y = SCREENHEIGHT(200) - ST_HEIGHT(32) = 168 (st_stuff.h:32-34).
-- `ST_refreshBackground` (st_stuff.c:499-512) draws STBAR into a small
-- off-screen buffer at its own (0,0), then `V_CopyRect`s that buffer onto
-- the real screen at (ST_X=0, ST_Y=168) -- so 168 is STBAR's real,
-- effective screen Y, read directly rather than assumed.
local ST_Y = 168

-- ------- assets: cached like every other DoomWadImport consumer in
-- this mod (Phase 2/3's own pattern), by name substring -- `loadSpriteAsset`
-- specifically (not `loadImage`), since every status-bar patch needs its
-- own real grAb offset the same way weapon sprites do (`V_DrawPatch`
-- itself subtracts `leftoffset`/`topoffset` on every draw, confirmed by
-- reading it directly, v_video.c:219-220 -- not just a weapon-specific
-- convention).
local loadHudAsset = DoomSpriteCache.newAssetLoader()

-- Draws a patch at its own real DOOM anchor point, offset by its own
-- real grAb leftoffset/topoffset -- the exact `V_DrawPatch` formula
-- (`x -= leftoffset; y -= topoffset`), not an independently-centered
-- guess (the same lesson Phase 4 already learned for weapon sprites).
-- Silently does nothing if the WAD hasn't been imported yet or this
-- particular lump didn't decode -- matching every other DOOM-asset
-- consumer in this mod, no crash, no placeholder shape for the HUD
-- specifically (a missing status bar just isn't drawn, same as a
-- missing weapon sprite falls back to a placeholder shape rather than
-- erroring).
local function drawPatch(nameSubstring, x, y)
  local asset = loadHudAsset(nameSubstring)
  if not asset then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(asset.image, x - asset.left, y - asset.top)
end

-- ------- the ready-ammo number widget (`STlib_drawNum`, st_lib.c:90-
-- 148; `ST_AMMOX, ST_AMMOY = 44, 171`, `ST_AMMOWIDTH = 3`, st_stuff.c:
-- 139-140 and the real `STlib_initNum(&w_ready, ST_AMMOX, ST_AMMOY,
-- tallnum, ..., ST_AMMOWIDTH)` call, st_stuff.c:1288-1294 -- `x` is the
-- field's own RIGHT edge, confirmed directly from `STlib_drawNum`'s own
-- `x = n->x; while (num && numdigits--) { x -= w; ... }` walk, not
-- assumed).
local ST_AMMOX, ST_AMMOY = 44, 171

-- Right-justified, no leading zeros -- `STlib_drawNum`'s own real draw
-- loop is `while (num && numdigits--)`, so e.g. 5 in a 3-digit field
-- draws only "5", never "005"; 0 is a special case that still draws one
-- "0" digit (st_lib.c:134-135). Steps left by the "0" digit's own real
-- patch width each time (`w = SHORT(n->p[0]->width)`, st_lib.c:99), read
-- dynamically off the loaded asset rather than a guessed pixel constant
-- -- the same "verify, don't assume" lesson Phase 4 already learned for
-- weapon-sprite offsets. DOOM's own negative-number/`STTMINUS` branch
-- (st_lib.c:107-117, 146-147) is not ported: nothing in this mod's own
-- ammo bookkeeping can currently drive a ready-ammo count negative
-- (`checkAmmo` in `lib/DoomWeapons.lua` always gates firing first) and
-- CLAUDE.md's own project rules avoid infrastructure for scenarios that
-- can't happen -- revisit if a future weapon action ever decrements
-- ammo without that gate.
local function drawNumber(value, x, y, numDigits)
  if value == nil then return end
  local zero = loadHudAsset("STTNUM0")
  if not zero then return end
  local w = zero.image:getWidth()
  if value == 0 then
    drawPatch("STTNUM0", x - w, y)
    return
  end
  local cursorX = x
  while value > 0 and numDigits > 0 do
    cursorX = cursorX - w
    drawPatch("STTNUM" .. (value % 10), cursorX, y)
    value = math.floor(value / 10)
    numDigits = numDigits - 1
  end
end

-- ------- health/armor percent widgets (Phase 12) -- `st_percent_t`
-- (`STlib_updatePercent`, st_lib.c:179-188): a `st_number_t` (always
-- width 3, `STlib_initPercent`'s own hardcoded arg, st_lib.c:172) plus a
-- fixed `STTPRCNT` ("%") patch, drawn at the EXACT SAME (x,y) as the
-- number itself (`V_DrawPatch(per->n.x, per->n.y, FG, per->p)`,
-- st_lib.c:185 -- not independently offset; the "%" glyph's own real
-- grAb leftoffset is what naturally sits it just right of the numeral
-- field, the same "trust the real offsets" lesson every other patch in
-- this file already relies on). `ST_HEALTHX, ST_HEALTHY = 90, 171` and
-- `ST_ARMORX, ST_ARMORY = 221, 171` (st_stuff.c:144-145, 162-163,
-- re-confirmed fresh here -- unchanged from Phase 11's own layout
-- table). Real DOOM shows the RAW health/armor number here, NOT
-- clamped to 100 (`DoomHealth.health()`/`armor()`'s own header comment)
-- -- reusing `drawNumber` directly handles that correctly already, since
-- it has no clamp of its own either.
local ST_HEALTHX, ST_HEALTHY = 90, 171
local ST_ARMORX, ST_ARMORY = 221, 171
local function drawPercent(value, x, y)
  drawPatch("STTPRCNT", x, y)
  drawNumber(value, x, y, 3)
end

-- ------- the arms widget (Phase 18 Bug 4) -- `st_stuff.c:148-153`
-- (layout), `:1154-1167` (graphics), `:1308-1324` (`STlib_initMultIcon`,
-- the real on/off data source), all re-read fresh, not assumed from an
-- earlier audit. Background `STARMS` at `(ST_ARMSBGX,ST_ARMSBGY) =
-- (104,168)`; six digit slots in a 3-column, 2-row grid at
-- `(ST_ARMSX+(i%3)*ST_ARMSXSPACE, ST_ARMSY+floor(i/3)*ST_ARMSYSPACE)` for
-- `i=0..5`, `ST_ARMSX,ST_ARMSY=(111,172)`, `ST_ARMSXSPACE,ST_ARMSYSPACE=
-- (12,10)`. Slot `i` shows digit `i+2`, bright (`STYSNUM`, the same
-- short-yellow font this file's own `STTNUM`-adjacent widgets already
-- load lumps from the same way) when its own `weaponowned[]` slot is
-- true, dim (`STGNUM`) when false -- a real binary on/off, no fade.
--
-- The real `weaponowned[]` mapping, cross-checked against DOOM's actual
-- `weapontype_t` enum (`doomdef.h:182-189`: `wp_fist=0, wp_pistol=1,
-- wp_shotgun=2, wp_chaingun=3, wp_missile=4, wp_plasma=5, wp_bfg=6,
-- wp_chainsaw=7`) rather than assumed from the digit order alone --
-- `weaponowned[i+1]` backs slot `i`, so slot 0 ("2") is driven by the
-- PISTOL, not the shotgun, and the chainsaw/fist never appear on this
-- grid at all. `ARMS_SLOTS` below is in that exact order, using this
-- mod's own `lib/DoomWeapons.lua` key names (`player.weaponowned`,
-- `DoomWeapons.lua:297-300`).
local ST_ARMSBGX, ST_ARMSBGY = 104, 168
local ST_ARMSX, ST_ARMSY = 111, 172
local ST_ARMSXSPACE, ST_ARMSYSPACE = 12, 10
local ARMS_SLOTS = {
  "PISTOL", "SHOTGUN", "CHAINGUN", "ROCKETLAUNCHER", "PLASMARIFLE", "BFG9000",
}
local function drawArms()
  drawPatch("STARMS", ST_ARMSBGX, ST_ARMSBGY)
  local owned = DoomWeapons.ownedSnapshot and DoomWeapons.ownedSnapshot() or {}
  for i = 0, 5 do
    local digit = i + 2
    local x = ST_ARMSX + (i % 3) * ST_ARMSXSPACE
    local y = ST_ARMSY + math.floor(i / 3) * ST_ARMSYSPACE
    if owned[ARMS_SLOTS[i + 1]] then
      drawPatch("STYSNUM" .. digit, x, y)
    else
      drawPatch("STGNUM" .. digit, x, y)
    end
  end
end

-- ------- the face widget
--
-- st_stuff.c:120-124's own real tic-based durations, converted to this
-- engine's 60Hz from DOOM's real 35Hz (`doomdef.h TICRATE`) -- a plain
-- rounded frame count, not `lib/DoomWeapons.lua`'s own `ticsFor`
-- fractional accumulator: that precision mattered there because weapon
-- fire RATE is a real gameplay stat (Phase 5's own audit); a face
-- expression's exact frame timing is purely cosmetic, so it doesn't earn
-- that same rigor.
local DOOM_TICRATE = 35
local FRAME_RATE = 60
local function ticsToFrames(tics)
  return math.floor(tics * FRAME_RATE / DOOM_TICRATE + 0.5)
end
local STRAIGHTFACECOUNT = ticsToFrames(DOOM_TICRATE / 2) -- ST_STRAIGHTFACECOUNT
local RAMPAGEDELAY = ticsToFrames(2 * DOOM_TICRATE)      -- ST_RAMPAGEDELAY
local TURNCOUNT = ticsToFrames(1 * DOOM_TICRATE)         -- ST_TURNCOUNT (st_stuff.c:118)
local ST_MUCHPAIN = 20 -- st_stuff.c:126

-- Real pain-tiered face names (st_stuff.c:1178-1194's own naming
-- convention, re-confirmed directly against the actual `sprintf`
-- calls this round: `sprintf(namebuf,"STFST%d%d",i,j)` for the 3
-- "straight ahead" idle glances, `sprintf(namebuf,"STFKILL%d",i)` for
-- the rampage/gritted-teeth face, `i` = `DoomHealth.painTier()`'s own
-- real 0-4 tier). Pinned to tier 0 until Phase 12's own `lib/
-- DoomHealth.lua` existed to compute a real tier from; now reads it
-- live on every face pick instead of a hardcoded "0", per that phase's
-- own checklist. All 5 tiers' worth of face patches were already
-- confirmed present in this dev environment's extracted reference WAD
-- (phases/phase-11-hud.md's own asset audit, 46 face-related files).
-- (The real `sprintf` calls themselves live in `ST_loadGraphics`,
-- st_stuff.c:1124-1194.)
local function straightFace()
  return ("STFST%d%d"):format(DoomHealth.painTier(), math.random(0, 2))
end
local function rampageFace()
  return ("STFKILL%d"):format(DoomHealth.painTier())
end
-- "STFEVL%d" -- the evil grin, `i` = pain tier (st_stuff.c:1191,
-- re-confirmed fresh this round, not assumed from memory).
local function evilGrinFace()
  return ("STFEVL%d"):format(DoomHealth.painTier())
end
-- "STFOUCH%d" / "STFTR%d0" / "STFTL%d0" -- pain reaction, turn-right,
-- turn-left (st_stuff.c:1186-1190, re-confirmed fresh: `sprintf(namebuf,
-- "STFTR%d0",i)`, `"STFTL%d0"`, `"STFOUCH%d"`).
local function ouchFace()
  return ("STFOUCH%d"):format(DoomHealth.painTier())
end
local function turnRightFace()
  return ("STFTR%d0"):format(DoomHealth.painTier())
end
local function turnLeftFace()
  return ("STFTL%d0"):format(DoomHealth.painTier())
end

-- Priority 7's own real angle sub-branch (st_stuff.c:813-851, re-read
-- fresh this round): `badguyangle = R_PointToAngle2(player, attacker)`
-- compared against the player's own facing angle picks head-on
-- (rampage face, reused) vs. turn-right vs. turn-left, within a real
-- ANG45 (45-degree) cone counting as "head-on." DOOM's own unsigned BAM
-- angle-difference dance to get there (that function's own "confusing,
-- aint it?" comment) is arithmetically just a signed angle difference
-- wrapped to (-180,180] -- re-derived directly as that, using the exact
-- same `atan2(dx,dz)` forward-vector convention and wrap idiom `lib/
-- DoomWeapons.lua`'s `computeAutoAimPitch` already established for an
-- analogous angle comparison (its own `AUTOAIM_CONE` check), rather
-- than transplanting BAM fixed-point arithmetic -- this is the real
-- geometric angle DOOM itself computes here, not a tic-rate-derived
-- formula (the case CLAUDE.md's "avoid math-derived code" rule
-- explicitly carves out). Sign convention traced through DOOM's own
-- literal branch logic once (a positive wrapped difference -> turn
-- left, negative -> turn right); this only picks which face graphic
-- shows, so a mirrored left/right would be a harmless one-line swap,
-- not a gameplay bug, if a playtest ever shows it backwards.
local function attackedFace(ow, attacker)
  if type(attacker) == "table" and attacker.px and attacker.py and ow and ow.player then
    local pl = ow.player
    local dx, dz = (attacker.px + 8) - (pl.px + 8), (attacker.py + 8) - (pl.py + 8)
    if dx * dx + dz * dz > 1 then
      local angleTo = math.atan2(dx, dz)
      local diff = (angleTo - FirstPerson.yaw + math.pi) % (2 * math.pi) - math.pi
      if math.abs(diff) < math.rad(45) then
        return rampageFace()
      elseif diff > 0 then
        return turnLeftFace()
      else
        return turnRightFace()
      end
    end
  end
  -- No usable attacker position (e.g. Horde's own string-only "horde"
  -- source, `lib/DoomHordeControl.lua:663`, `{source = "horde"}` with
  -- no `attacker` table) -- real DOOM's own angle math has nothing to
  -- compare against here either; the head-on/rampage face is the
  -- closest real DOOM state that doesn't depend on a direction at all.
  return rampageFace()
end

local faceCount = 0
local faceName = straightFace()
local lastAttackDown = -1
-- `ST_EVILGRINCOUNT = 2*TICRATE` (st_stuff.c:120, re-confirmed).
local EVILGRINCOUNT = ticsToFrames(2 * DOOM_TICRATE)
local evilGrinCount = 0
local oldWeaponsOwned = DoomWeapons.ownedSnapshot and DoomWeapons.ownedSnapshot() or {}
-- `st_oldhealth` (st_stuff.c:378) -- health as of the END of the
-- PREVIOUS tic, updated at the bottom of `updateFace()` below to mirror
-- `ST_Ticker`'s own real call order (st_stuff.c:988-996:
-- `ST_updateWidgets()` -- which calls `ST_updateFaceWidget()` -- runs
-- BEFORE `st_oldhealth = plyr->health` refreshes for the next tic).
local lastHealth = DoomHealth.health()

-- Restates `ST_updateFaceWidget`'s own real, complete priority ladder
-- (st_stuff.c:752-922), every tier now implemented (Phase 25):
-- dead(9) > evil grin(8) > attacked(7) > self-damage(6-7) > rapid-fire
-- rampage(5) > invulnerable(4) > idle(0). Run once per real frame (this
-- file's own `install()` hooks `input.step`) rather than rate-limited
-- to a DOOM-tic cadence -- the DURATIONS above are already scaled to
-- this engine's own 60Hz.
-- ST_updateFaceWidget's real top priority (9, st_stuff.c:761-770):
-- `if (!plyr->health) { priority = 9; st_faceindex = ST_DEADFACE;
-- st_facecount = 1; }` -- checked before EVERYTHING else in the ladder,
-- every single frame, with nothing in real single-player play ever
-- lowering the priority again before the level/state resets (Phase 15,
-- phases/phase-15-player-death.md). Restated here as an early return
-- rather than a `claimed` flag: `st_facecount = 1` in the real source is
-- irrelevant busywork (a decrementing counter that can never actually
-- cause anything else to win priority 9 back), not something worth
-- replicating.
-- ------- one function per priority tier, each returning whether it
-- claimed the frame -- extracted 2026-08-19 during a project-wide
-- readability audit (`updateFace` below used to be one ~130-line
-- function threading a `claimed` flag through 4+ levels of nesting).
-- Each closes over this file's own already-existing module-level state
-- (`faceName`/`faceCount`/`evilGrinCount`/`lastAttackDown`/
-- `oldWeaponsOwned`/`lastHealth`) exactly as the original inline code
-- did -- no new state, no behavior change, just named boundaries around
-- the same real priority ladder (st_stuff.c:752-922).

local function evilGrinHold()
  if evilGrinCount <= 0 then return false end
  evilGrinCount = evilGrinCount - 1
  faceName = evilGrinFace()
  return true
end

-- Runs EVERY frame regardless of whether a higher tier already claimed
-- it -- matches real DOOM's own unconditional weapon-ownership flip
-- check (st_stuff.c), which has to keep its own bookkeeping in sync
-- even on a frame some other tier already won. Callers must call this
-- directly, never through `claimed or weaponPickupGrin()` short-circuit
-- evaluation, which would skip that bookkeeping once `claimed` is true.
local function weaponPickupGrin()
  local newOwned = DoomWeapons.ownedSnapshot and DoomWeapons.ownedSnapshot()
  if not newOwned then return false end
  local flipped = false
  for name, owned in pairs(newOwned) do
    if oldWeaponsOwned[name] ~= owned then flipped = true end
    oldWeaponsOwned[name] = owned
  end
  if not (flipped and DoomHealth.bonusCount() > 0) then return false end
  faceName = evilGrinFace()
  evilGrinCount = EVILGRINCOUNT
  return true
end

-- Priority 7 (attacked) / priority 6-7 (self-damage), st_stuff.c:
-- 798-875 -- a LEVEL-triggered condition, not edge-triggered: real DOOM
-- re-evaluates this every single tic `damagecount` stays nonzero,
-- continuously re-locking `st_facecount` to `ST_TURNCOUNT`
-- (`damagecount` itself, decaying over real time, is what eventually
-- lets this block go quiet and fall through to idle -- not a one-shot
-- hold timer of its own).
local function attackedOrSelfDamage()
  if DoomHealth.damageCount() <= 0 then return false end
  local ok, ow = pcall(function() return require("src.core.Game").overworld end)
  ow = ok and ow or nil
  local attacker = DoomHealth.attacker()
  local healthDelta = DoomHealth.health() - lastHealth
  -- Real DOOM's own priority-7 gate also requires `attacker != plyr->mo`
  -- (not the player's own mobj -- i.e. not self-inflicted). No call site
  -- in this mod's own scope can ever set the player as their own
  -- attacker (every `DoomHealth.damage()` caller passes an external
  -- demon/Horde source, `lib/DoomDemons.lua`/`lib/DoomHordeControl.lua`),
  -- so that comparison would always be vacuously true here -- omitted
  -- rather than checked against a sentinel value nothing in this mod's
  -- scope can ever produce (CLAUDE.md: don't validate scenarios that
  -- can't happen).
  if attacker then
    -- Priority 7 -- a real external attacker.
    if healthDelta > ST_MUCHPAIN then
      -- FIX 2026-08-09 -- Phase 25 audit, re-read `ST_Ticker`'s own real
      -- call order fresh (see `lastHealth`'s own comment above): vanilla
      -- DOOM's own literal OUCH threshold is `plyr->health -
      -- st_oldhealth > ST_MUCHPAIN` -- CURRENT health minus its value
      -- one tic ago -- which is only ever true when health went UP by
      -- more than 20 in one tic, not down. A real, well-known vanilla
      -- DOOM curiosity: despite the face being named "ouch," this branch
      -- actually fires from healing a lot while still hurt
      -- (`damagecount` hasn't decayed to 0 yet), not from taking a lot
      -- of damage. Ported literally rather than "corrected," per
      -- CLAUDE.md's own porting-methodology rule (functional parity
      -- means matching what the source actually does, not what its name
      -- implies it should do) -- and genuinely reachable in this mod: a
      -- big single-call heal (`DoomHealth.giveSoul()`/
      -- `.giveHealthBonus()`) landing while `damagecount` is still
      -- draining down from a recent hit.
      faceName = ouchFace()
    else
      faceName = attackedFace(ow, attacker)
    end
  else
    -- Priority 6/7 -- self-damage, no real attacker (st_stuff.c:
    -- 855-875). Not currently reachable in this mod's own scope --
    -- every real `DoomHealth.damage()` call site passes at least
    -- `opts.source`, so `DoomHealth.attacker()` is never actually nil
    -- while `damagecount() > 0` -- built anyway for parity/future-
    -- proofing (a future environmental-hazard damage source), mirroring
    -- real DOOM's own structure exactly rather than being left out.
    faceName = healthDelta > ST_MUCHPAIN and ouchFace() or rampageFace()
  end
  faceCount = TURNCOUNT
  return true
end

-- Priority 5 -- rapid-fire rampage. `lastAttackDown`'s own bookkeeping
-- (including the `-1` reset when not attacking) only runs while this
-- tier is actually reached -- matches the original's own `if not
-- claimed then ... end` scoping exactly (a higher tier claiming the
-- frame first means this state machine simply doesn't advance that
-- frame, same as before).
local function rampageHold()
  local attacking = DoomWeapons.isAttacking and DoomWeapons.isAttacking()
  if not attacking then
    lastAttackDown = -1
    return false
  end
  if lastAttackDown == -1 then
    lastAttackDown = RAMPAGEDELAY
    return false
  end
  lastAttackDown = lastAttackDown - 1
  if lastAttackDown > 0 then return false end
  faceName = rampageFace()
  faceCount = 1
  lastAttackDown = 1
  return true
end

-- Priority 4 (god/invulnerable), st_stuff.c:897-909 -- real DOOM's own
-- trigger (`CF_GODMODE`/`pw_invulnerability`) has no live equivalent in
-- this mod yet (Phase 14, still "Not started"); stands in with
-- `Options.infiniteHealthEnabled()` per `phases/phase-25-face-widget-
-- parity.md`'s own explicitly-flagged option (b) -- swap to a real
-- cheat/powerup flag once Phase 14 lands. `st_facecount = 1` in the real
-- source (kept re-triggering every tic while the condition holds), same
-- shape as rapid-fire above.
local function godFace()
  if not Options.infiniteHealthEnabled() then return false end
  faceName = "STFGOD0"
  faceCount = 1
  return true
end

local function updateFace()
  if DoomHealth.isDead() then
    faceName = "STFDEAD0"
    faceCount = 1
    return
  end

  local claimed = evilGrinHold()
  local grinFromPickup = weaponPickupGrin() -- see its own header: must run unconditionally
  claimed = claimed or grinFromPickup

  claimed = claimed or attackedOrSelfDamage()
  claimed = claimed or rampageHold()
  claimed = claimed or godFace()

  -- look left/center/right if the facecount has timed out (st_stuff.c:
  -- 912-918) -- DOOM's own real fallback, checked LAST so every higher
  -- priority state gets first refusal at claiming the frame, matching
  -- the real priority order (idle is priority 0, the lowest).
  if not claimed and faceCount <= 0 then
    faceName = straightFace()
    faceCount = STRAIGHTFACECOUNT
  end
  faceCount = faceCount - 1
  lastHealth = DoomHealth.health()
end

-- ------- the pickup/kill message (`player->message`, HU_MSGX/Y = 0,0,
-- HU_MSGTIMEOUT = 4*TICRATE = 4 real seconds, HU_MSGHEIGHT = 1 (in
-- lines!), hu_stuff.h:39-44) -- DOOM's own top-left status text
-- ("Picked up a stimpack.", etc). Phase 16: now drawn with `lib/
-- DoomFont.lua`'s own real `STCFN*` glyph port (`HUlib_drawTextLine`'s
-- real proportional, uppercase-only algorithm), replacing this file's
-- earlier stopgap (the base engine's own GB font) -- see that new
-- file's own header comment for the full derivation. Also now gated on
-- `Options.messagesEnabled()`, real DOOM's own `showMessages` toggle
-- (`HU_Ticker`, hu_stuff.c:518, re-confirmed this round) -- while OFF,
-- neither `announce` nor `announceKill` below even set the pending text,
-- matching real DOOM's own widget never activating at all while the
-- option is off (not just suppressing the DRAW).
--
-- FIX 2026-08-08 -- user report: a pickup message, a death notice, and
-- the per-kill money announcement (all three real call sites: `lib/
-- DoomItems.lua`/`lib/DoomRewards.lua`, `lib/DoomView.lua`'s own death
-- obituary, `lib/DoomDemons.lua`'s own kill-reward) could all land in
-- the same instant and were drawing on top of each other -- an EARLIER
-- version of this file gave death notices their own separate slot
-- specifically so they couldn't "stomp" a simultaneous pickup message,
-- which is exactly backwards from what the user actually wants here:
-- "all of the messages should be in the same killfeed, not any
-- different feed... just do it how the original doom did it and only
-- have 1 message at a time." Confirmed against source: real DOOM's own
-- `HU_MSGHEIGHT` is literally `1` (hu_stuff.h:42, "in lines") -- vanilla
-- DOOM's own message widget genuinely is single-slot, one line, one
-- active message at a time; a second `player->message` write simply
-- replaces whatever was showing. Merged back into ONE real shared slot
-- (`feedText`/`feedTimer`/`feedColor`) -- `announce` and `announceKill`
-- stay two separate public functions (every existing call site keeps
-- calling whichever one already made sense for it) but both now write
-- the SAME slot, just with a different color, so whichever fires most
-- recently is simply what's showing -- never two lines competing for
-- the same pixels.
local HU_MSGX, HU_MSGY = 0, 0
local HU_MSGTIMEOUT = 4 -- seconds
local WHITE_COLOR = { 1, 1, 1, 1 }
-- Real GZDoom prints obituaries at `PRINT_MEDIUM` (`p_interaction.cpp:
-- 314`, literally commented "death messages"), which maps to `CR_GOLD`
-- (`c_console.cpp:172`'s own `PrintColors` table) -- `CR_GOLD`'s own
-- flat/solid color (`textcolors.txt:51-59`) is `#FFCC00`. Not a vanilla
-- DOOM mechanic at all (confirmed: `player->message` is used only for
-- pickups/door-keys in `linuxdoom-1.10`, no on-screen kill text
-- anywhere in that source) -- sourced from `gzdoom-master` instead, the
-- real secondary authority per CLAUDE.md's own hard rule.
local KILLFEED_COLOR = { 1, 0.8, 0, 1 }
local feedText, feedTimer, feedColor = nil, 0, WHITE_COLOR

-- Exposed for `lib/DoomItems.lua`/`lib/DoomRewards.lua`'s own pickup/
-- reward call sites -- the same real signal as `player->message = ...`.
function DoomHud.announce(text)
  if not Options.messagesEnabled() then return end
  feedText = text
  feedTimer = HU_MSGTIMEOUT
  feedColor = WHITE_COLOR
end

-- Exposed for `lib/DoomView.lua`'s own death obituary and `lib/
-- DoomDemons.lua`'s own per-kill money announcement -- same slot as
-- `announce` above (see this section's own header comment), just the
-- real GZDoom gold tint instead of white.
function DoomHud.announceKill(text)
  if not Options.messagesEnabled() then return end
  feedText = text
  feedTimer = HU_MSGTIMEOUT
  feedColor = KILLFEED_COLOR
end

-- Decays the timeout -- called from `install()`'s own `input.step` hook
-- (which receives `dt`; `love.draw` doesn't), the same "decay in the
-- logic tick, draw is a stateless read" split `lib/DoomHealth.lua`'s own
-- damagecount/bonuscount decay already uses.
local function updateMessage(dt)
  if not feedText then return end
  feedTimer = feedTimer - dt
  if feedTimer <= 0 then feedText = nil end
end

-- Real DOOM's own screen has no letterboxing at all -- HU_MSGY=0 is
-- simply the literal top pixel row. This mod's own virtual canvas isn't
-- always that simple: `virtualScaleAndOffset` (this file's own header
-- comment) deliberately BOTTOM-anchors the whole canvas so the status
-- bar touches the real bottom edge on a window narrower than 320:200 --
-- pushing ALL the letterbox slack to the TOP instead of splitting it.
-- That's exactly backwards for something meant to sit at the literal
-- TOP of the real screen: confirmed live by the user's own screenshot,
-- the message floating a real gap below the true top edge on this dev
-- environment's own ~1.4:1 test window. Compensates independently of
-- the status bar's own anchor, rather than re-centering the whole
-- shared canvas and re-breaking that fix: the shared transform is
-- `screenY = voy + virtualY*scale`, so drawing at `virtualY = -voy/
-- scale` lands at literal `screenY = 0` regardless of how much top
-- slack this particular window has. In the height-bound case (a wide
-- enough window) `voy` is already 0, so this is a no-op there.
local function drawMessage()
  if not feedText then return end
  local w, h = love.graphics.getWidth(), love.graphics.getHeight()
  local scale, _, voy = virtualScaleAndOffset(w, h)
  local topY = scale > 0 and (HU_MSGY - voy / scale) or HU_MSGY
  DoomFont.draw(feedText, HU_MSGX, topY, feedColor[1], feedColor[2], feedColor[3], feedColor[4])
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- palette flash (`ST_doPaletteStuff`, st_stuff.c:1000-1051) --
-- DOOM swaps among a handful of precomputed, discrete PLAYPAL palettes
-- (8 red tiers for damage, 4 gold tiers for a pickup bonus, one fixed
-- green for the radiation suit) rather than blending a color; this port
-- draws a single semi-transparent full-screen rect instead. Priority
-- matches real DOOM exactly: damage (red) beats bonus (gold), checked
-- in that order.
--
-- FIXED 2026-08-07 -- user report: "when this demon shoots me theres no
-- damage indicator on my screen." The flash itself was already wired up
-- correctly (`DoomHealth.damage` sets `damagecount` on every real hit,
-- this function already read it, `install()`'s own `love.draw` wrap
-- already called it every frame `visible()` holds) -- confirmed by a
-- fresh re-read, not assumed. The REAL bug was the curve: this function
-- used to scale alpha CONTINUOUSLY and PROPORTIONALLY from zero
-- (`damage/DAMAGE_PEAK * DAMAGE_ALPHA_MAX`), but real DOOM's own
-- `ST_doPaletteStuff` is a STEPPED function, re-read fresh from source
-- (`st_stuff.c:1019-1027`): `palette = (damagecount+7)>>3`, clamped to
-- `NUMREDPALS=8` tiers. Because of the `+7` before the shift, ANY
-- nonzero `damagecount` -- even a single point of damage -- already
-- lands on tier 1 of 8, a real, immediately-visible minimum red flash,
-- not a near-zero sliver; the palette then saturates to the FULLY red
-- tier 8 by `damagecount>=57` (`(57+7)>>3=8`), not only at `damagecount
-- =100`. A typical hitscan/melee hit in this mod (roughly 3-40 damage,
-- see `references/monster-roster.md`) landed well inside DOOM's own
-- "clearly visible" tier range but, under the OLD linear curve, only
-- reached alpha 0.015-0.2 out of a 0.5 max -- functionally invisible on
-- a bright outdoor scene, exactly the reported symptom. Rewritten to
-- the real stepped shape: `redTier(cnt)` reproduces the same `(cnt+7)/8`
-- bucketing (an already-tracked stat being bucketed, not a tic-rate-
-- dependent formula -- the same category `ST_calcPainOffset`'s own real
-- tier system, Phase 12, was already ported directly), then each of the
-- 8 (4, for bonus) tiers maps to a NAMED alpha value in a small table
-- (this project's own "avoid math-derived code" preference for a
-- state-driven lookup over a smooth formula) with a real, visible floor
-- and a strong top tier, instead of one continuous multiply. Colors
-- unchanged from before -- still an approximation, not verified against
-- an actual PLAYPAL lump (no imported WAD in this dev environment) --
-- red-for-damage/gold-for-bonus are well-established, widely-documented
-- real DOOM behavior; the radiation-suit GREEN tint remains NOT
-- implemented (nothing in this mod's own scope sets `powers[pw_ironfeet]`,
-- out of Phase 13's own roster).
--
-- **Deliberately drawn in RAW screen pixels, not the virtual canvas**
-- -- a real bug the user reported: this used to draw a `VIRTUAL_W x
-- VIRTUAL_H` rect from inside the SAME bottom-anchored shared transform
-- `drawMessage` above already had to work around, so on a window
-- narrower than 320:200 the flash's own top edge sat at `voy` (the
-- letterbox gap), not literal screen y=0 -- covering only the same
-- shorter area the message USED to be confined to before that fix,
-- visibly not "the whole screen." A solid color rect has no content
-- that needs the virtual canvas's own scale/font-sizing to look right
-- (unlike the message's real glyphs), so instead of computing another
-- compensating offset, this is called OUTSIDE the shared transform
-- entirely (`install()`'s own `love.draw` wrap, after the matching
-- `pop()`) using LÖVE's own real, raw window dimensions directly --
-- genuinely covers 100% of the real screen on any window shape, the
-- same as real DOOM's own hardware palette swap actually does.
local NUMREDPALS, NUMBONUSPALS = 8, 4 -- st_stuff.c:73-74
-- Tier 1 (any nonzero damagecount) through tier 8 (damagecount>=57) --
-- a real, visible floor instead of starting near-invisible, ramping to
-- a strong, unmistakable near-full-red top tier. Judgment call on the
-- exact alpha VALUES (no PLAYPAL to read real RGB from, per this
-- function's own header note) -- the STEP SHAPE (8 tiers, floor-then-
-- ramp) is the real, sourced part.
local RED_TIER_ALPHA = { 0.12, 0.20, 0.28, 0.36, 0.44, 0.52, 0.60, 0.68 }
local BONUS_TIER_ALPHA = { 0.10, 0.18, 0.26, 0.34 }

-- `(cnt+7)>>3` restated: `cnt` here is this mod's own real-time-decayed
-- float (not DOOM's integer tic-decremented one), so `math.floor` takes
-- the shift's place -- same bucket boundaries for whole-number counts.
local function paletteTier(cnt, numTiers)
  if cnt <= 0 then return 0 end
  local tier = math.floor((cnt + 7) / 8)
  if tier < 1 then tier = 1 end
  if tier > numTiers then tier = numTiers end
  return tier
end

local function drawPaletteFlash()
  local damage = DoomHealth.damageCount()
  local bonus = DoomHealth.bonusCount()
  if damage <= 0 and bonus <= 0 then return end
  local w, h = love.graphics.getWidth(), love.graphics.getHeight()
  if damage > 0 then
    local tier = paletteTier(damage, NUMREDPALS)
    love.graphics.setColor(0.8, 0, 0, RED_TIER_ALPHA[tier])
    love.graphics.rectangle("fill", 0, 0, w, h)
  elseif bonus > 0 then
    local tier = paletteTier(bonus, NUMBONUSPALS)
    love.graphics.setColor(0.85, 0.7, 0.25, BONUS_TIER_ALPHA[tier])
    love.graphics.rectangle("fill", 0, 0, w, h)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- the draw
--
-- `ST_FACESX, ST_FACESY = 143, 168` (st_stuff.c:117-118). Drawn AFTER
-- the STBAR background, matching `ST_drawWidgets`' own real order
-- (called after `ST_refreshBackground`/`ST_doRefresh`) -- and matching
-- why the status bar draws on TOP of the weapon view model in this
-- port too (`DoomHud.install` below runs after `DoomWeapons.install`):
-- real DOOM relies on the status bar to hide whatever a tall weapon
-- sprite overflows past the 200-line screen edge (Phase 5's own
-- `weaponBottomCorrection` notes this exact fact) -- the bar has to be
-- the LAST thing drawn for that to hold, not a cosmetic ordering choice.
--
-- `STFB0`/etc (the face's own colored background patch) is deliberately
-- NOT drawn: real DOOM only draws it `if (netgame)` (st_stuff.c:506-507,
-- read directly) -- single-player DOOM, this mod's own only mode, never
-- shows it at all.
local function drawHud()
  drawPatch("STBAR", 0, ST_Y)
  drawNumber(DoomWeapons.readyAmmo(), ST_AMMOX, ST_AMMOY, 3)
  drawPercent(DoomHealth.health(), ST_HEALTHX, ST_HEALTHY)
  drawPercent(DoomHealth.armor(), ST_ARMORX, ST_ARMORY)
  drawArms()
  drawPatch(faceName, 143, 168)
  drawMessage()
end

-- Same gate `lib/DoomWeapons.lua`'s own `reallyInFirstPerson` uses,
-- restated rather than reached into that file's own private locals --
-- keeps the HUD and the weapon view model visually consistent with each
-- other (both hide together whenever a menu takes the buttons, the
-- existing established behavior for the gun already), not a new,
-- separately-behaving overlay.
--
-- CORRECTED 2026-08-06: checks `Pipelines.level("voxel")` (`src/render/
-- Pipelines.lua`), not `Voxel.level`. Those two can genuinely disagree --
-- `Voxel.level` is only this mod's own local mirror, `Pipelines.level`
-- is the real value the WORLD RENDERER itself reads to decide flat-2D
-- vs. voxel-3D (`VoxelState.lua`'s own header comment: "The LEVEL is not
-- ours. The engine's render_pipelines plumbing owns it") -- which is
-- exactly how the user ended up seeing the real DOOM status bar drawn
-- OVER the flat 2D Game Boy view (screenshot, 2026-08-06): `lib/
-- DoomView.lua`'s old `lockFirstPerson` forced `Voxel.level` to
-- `FP_LEVEL` directly, which satisfied this check, while the world
-- renderer itself was still reading the untouched, un-forced
-- `Pipelines.level("voxel")` and drawing flat. Per the user's own
-- explicit ask ("if it were to SOMEHOW slip out of first person, there
-- should never be a weapon or hud there from doom") -- checking the
-- SAME value the world renderer actually obeys is what makes that
-- guarantee real instead of cosmetic.
local function visible()
  local Pipelines = require("src.render.Pipelines")
  return Options.enabled() and FirstPerson.driving()
     and Voxel.level == Voxel.FP_LEVEL
     and Pipelines.level("voxel") == Voxel.FP_LEVEL
end

local installed = false
function DoomHud.install()
  if installed then return end
  installed = true

  -- BUG FIX 2026-08-12 -- this wrap only ever checked `Options.enabled()`,
  -- missing the `FirstPerson.onTop()` half of CLAUDE.md's own Locked
  -- Decision 6 ("pausing always means paused... any always-on input.step
  -- tick... must check that the overworld genuinely has focus") that
  -- every sibling always-on tick in this mod already has (`lib/
  -- DoomDeathScreen.lua`, `lib/DoomBarrels.lua`, `lib/DoomTownInvasion.
  -- lua`, all gated on `Options.enabled() and FirstPerson.onTop()`).
  -- Concretely: `updateMessage`'s `feedTimer` kept draining real seconds
  -- while a menu was open, so a pickup message could silently expire
  -- during a pause the player never actually saw it during; `updateFace`'s
  -- own timers (`faceCount`, `evilGrinCount`, `lastAttackDown`) drifted
  -- the same way. Neither actually TEARS anything down while off, so
  -- adding the check here freezes them exactly in place, matching every
  -- other gated system.
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if Options.enabled() and FirstPerson.onTop() then
      updateFace()
      updateMessage(dt)
    end
    return next(game, dt)
  end)

  local innerDraw = love.draw
  love.draw = function(...)
    if innerDraw then innerDraw(...) end
    if visible() then
      local w, h = love.graphics.getWidth(), love.graphics.getHeight()
      local scale, vox, voy = virtualScaleAndOffset(w, h)
      love.graphics.push()
      love.graphics.translate(vox, voy)
      love.graphics.scale(scale, scale)
      -- FEATURE 2026-08-10 -- new "HUD" on/off row (`lib/DoomOptions.lua`)
      -- -- only gates the status-bar draw itself, not `visible()` above
      -- (that check is a real safety guarantee against the flat-2D-
      -- fallback leak, unrelated to a cosmetic preference).
      if Options.hudEnabled() then
        pcall(drawHud)
      end
      love.graphics.pop()
      love.graphics.setColor(1, 1, 1, 1)
      -- Outside the virtual-canvas transform on purpose -- see
      -- `drawPaletteFlash`'s own header comment. Real DOOM's palette
      -- swap is the LAST thing applied over everything else on screen
      -- (still true here, drawn after the whole HUD pass above), it
      -- just needs raw screen coordinates to actually cover the whole
      -- real window instead of only the letterboxed canvas area.
      -- FEATURE 2026-08-10 -- new "PALETTE FLASH" on/off row, separate
      -- from HUD above -- some players are sensitive to the red damage/
      -- gold pickup screen tint specifically.
      if Options.paletteFlashEnabled() then
        pcall(drawPaletteFlash)
      end
      -- The "YOU LOST" death screen (`lib/DoomDeathScreen.lua`), drawn
      -- as the VERY LAST layer -- after the palette flash, matching
      -- that function's own "real DOOM's palette swap is the last thing
      -- applied over everything else" precedent, just carried one step
      -- further since this new screen is meant to dominate over even
      -- that. Background first (raw screen coords, same full-bleed
      -- reasoning as `drawPaletteFlash` above), then a SEPARATE
      -- push/scale block for the text so it renders using the shared
      -- 320x200 virtual canvas `DoomFont` is built around, on TOP of
      -- the just-drawn background rect.
      pcall(DoomDeathScreen.drawOverlayBackground)
      love.graphics.push()
      love.graphics.translate(vox, voy)
      love.graphics.scale(scale, scale)
      pcall(DoomDeathScreen.drawOverlayText)
      love.graphics.pop()
      love.graphics.setColor(1, 1, 1, 1)
    end
  end
end

return DoomHud
