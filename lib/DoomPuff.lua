-- PokeDoom: the bullet-impact puff -- `P_SpawnPuff` (p_mobj.c:807-831,
-- read fresh), called from `PTR_ShootTraverse`'s own real wall-hit
-- branch (p_map.c:948-971, `hitline:`) whenever a hitscan shot is
-- stopped by TERRAIN rather than a shootable target. User request
-- (2026-08-07): "bullet impacts should render just as they do in doom
-- with the paticle effects and textures on the wall afterwards" --
-- confirmed real and genuinely missing: this project ported blood
-- (`P_SpawnBlood`, `lib/DoomBlood.lua`) but never `P_SpawnPuff`, so a
-- shot that missed every target and hit a wall showed nothing at all.
--
-- Real DOOM's own `MT_PUFF` (`info.c:2070-`): sprite `PUFF`, a REAL
-- 4-state chain S_PUFF1(A)->S_PUFF2(B)->S_PUFF3(C)->S_PUFF4(D)->S_NULL
-- (removed), 4 tics/frame -- confirmed fresh, not assumed uniform with
-- blood's own 3-frame chain. A real, deliberate DOOM detail carried
-- over: `P_SpawnPuff` starts a MELEE-caused puff (fist/chainsaw hitting
-- a wall instead of a monster) at S_PUFF3 instead of S_PUFF1 --
-- "don't make punches spark on the wall" (that function's own real
-- comment) -- a melee wall-hit shows only the C->D tail, not the full
-- spark. `DoomPuff.spawn`'s own `melee` parameter ports this exactly.
--
-- The actual entity lifecycle (spawn, sync into `ow.entities`, per-tic
-- frame-advance, remove) lives in `lib/DoomEffectEntity.lua` now --
-- factored out 2026-08-19 during a project-wide readability audit, since
-- this file used to independently implement the exact same lifecycle
-- `lib/DoomBlood.lua` already had, byte-for-byte, differing only in its
-- own real sprite/timing data. This file now owns only what's genuinely
-- specific to a puff: `P_SpawnPuff`'s own real melee-vs-full-spark
-- starting state.
--
-- CORRECTED 2026-08-07 (same round as `lib/DoomBlood.lua`'s own
-- identical revert -- read that file's own header comment for the full
-- history): this file originally used its OWN dedicated fixed
-- `PUFF_WORLD_HEIGHT` (8, copied directly from blood's own THEN-current
-- value), reasoning at the time that reusing an "already-confirmed-
-- visible" number was safer than deriving a fresh one. That reasoning
-- skipped a step -- blood's own height-8 fix had never actually been
-- isolated from a SEPARATE, real `shadowQuad`-wrapping bug fixed in the
-- exact same round, so "confirmed visible at 8" was never really
-- confirmed to require 8 specifically. User report, this round: "the
-- puff effect is too big just as the blood effect is too big." Fixed
-- the same way blood was: delegate to `lib/DoomDemons.lua`'s own
-- exported `DoomDemons.mesh`, passing spritePrefix `"PUFF"` (now back in
-- that file's own `NON_DEMON_PREFIXES` table, sharing ZOMBIEMAN's
-- already-calibrated per-pixel ratio) instead of an independently
-- fixed height -- the real, WAD-faithful small size, matching how every
-- other non-demon effect sprite in this project is already built.

local V = ...
local DoomEffectEntity = V.require("DoomEffectEntity")

local DoomPuff = {}

-- S_PUFF1..4 (info.c:229-232), sprite PUFF, real frame letters A-D.
local puff = DoomEffectEntity.new({
  spritePrefix = "PUFF",
  letters = { "A", "B", "C", "D" },
  ticsPerFrame = 4,
  defMarker = "pokedoomPuff",
  cacheKeyPrefix = "puff-",
})

-- `P_SpawnPuff(x, y, z)` (p_mobj.c:811-831) -- `melee` (true for a
-- fist/chainsaw wall-hit) starts the real chain at S_PUFF3 instead of
-- S_PUFF1, matching that function's own real `attackrange == MELEERANGE`
-- check. Called only from a hitscan's own wall-impact case (`lib/
-- DoomWeapons.lua`'s `hitscan`) -- a shot that hit a shootable target
-- spawns blood instead (`lib/DoomBlood.lua`), matching real DOOM's own
-- exact `PTR_ShootTraverse` branch (p_map.c:1003-1008).
-- `wy` (added 2026-08-11): optional ABSOLUTE world height for this
-- puff's own real impact point. Nil-safe -- an unmodified call site
-- renders exactly as before.
function DoomPuff.spawn(ow, wx, wz, melee, wy)
  puff.spawn(ow, wx, wz, melee and 3 or 1, wy)
end

DoomPuff.install = puff.install

return DoomPuff
