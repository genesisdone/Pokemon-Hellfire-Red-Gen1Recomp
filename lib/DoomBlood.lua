-- PokeDoom: the blood impact effect -- `P_SpawnBlood` (p_mobj.c:836-859,
-- read fresh). User report (2026-08-07, with a real-DOOM reference
-- screenshot): "in the original doom there is a blood effect when shot...
-- that is not present in the mod." Confirmed real and genuinely missing:
-- none of this project's own hit-resolvers (`lib/DoomKill.lua`'s NPCs,
-- `lib/DoomHordeTarget.lua`'s Horde mobs, `lib/DoomDemons.lua`'s ambient
-- demons) ever spawned anything at the hit point -- a kill/gib eventually
-- showed, but nothing marked a non-lethal or in-flight hit at all.
--
-- Real DOOM's own `MT_BLOOD` (`info.c:226-228`): sprite `BLUD`, three
-- states chaining S_BLOOD1(frame C, 8 tics) -> S_BLOOD2(B, 8 tics) ->
-- S_BLOOD3(A, 8 tics) -> S_NULL (removed) -- `P_SpawnBlood`'s own
-- `damage` argument picks which state to START at, not a separate
-- effect: `damage>12` full spurt (starts at C), `9<=damage<=12` starts
-- at B, `damage<9` starts at A alone -- a brief, fire-and-forget
-- particle (well under a second even at its longest), never a permanent
-- marker the way a gib is. Real DOOM genuinely vanishes it -- S_NULL
-- removes the mobj outright, unlike a gib's own deliberate freeze.
--
-- The actual entity lifecycle (spawn, sync into `ow.entities`, per-tic
-- frame-advance, remove) lives in `lib/DoomEffectEntity.lua` now --
-- factored out 2026-08-19 during a project-wide readability audit, since
-- `lib/DoomPuff.lua` independently implemented the exact same lifecycle,
-- byte-for-byte, differing only in its own real sprite/timing data. This
-- file now owns only what's genuinely specific to blood: `P_SpawnBlood`'s
-- own real damage-threshold starting state.
--
-- CORRECTED 2026-08-07, THREE times, same day -- history kept in full
-- since the earlier rounds' own reasoning turned out to be incomplete,
-- not simply superseded. Round 1: shared ZOMBIEMAN's own calibrated
-- per-pixel ratio (`lib/DoomDemons.lua`'s `NON_DEMON_PREFIXES`),
-- correct in principle -- next report: "blood is no longer in the
-- viewport AT ALL." Round 2: blamed on a genuinely tiny WAD patch
-- rounding toward sub-pixel at that shared ratio; switched to an
-- own-dedicated FIXED height (first 3, then -- after "I still dont see
-- blood" -- 8, matching `lib/DoomItems.lua`'s own already-confirmed-
-- visible `ITEM_WORLD_HEIGHT`). The SAME round that landed height=8
-- ALSO found and fixed a genuinely separate, confirmed bug: this file's
-- own mesh hook never wrapped `SpriteBillboards.shadowQuad`, silently
-- falling through to whichever OTHER file's demon-only recognizer
-- installed first -- a complete, unconditional invisibility bug on its
-- own, independent of any height value. The two fixes shipped together,
-- never isolated, so height=8 was never actually confirmed necessary --
-- Round 3, user report: "the blood effect is too big... even though
-- multiple fixes were implemented," direct evidence it wasn't. Per
-- CLAUDE.md's own standing practice ("prefer reverting to the simplest,
-- most-proven-working pattern over layering another speculative fix"):
-- reverted back to Round 1's own shared-ratio approach -- genuinely the
-- more DOOM-faithful answer (a real blood splat IS supposed to read
-- small next to a demon) -- now that the shadowQuad fix (unrelated to
-- this revert, still in place via `lib/DoomEffectEntity.lua`) is what
-- should actually explain why this either does or doesn't render, not
-- the height.

local V = ...
local DoomEffectEntity = V.require("DoomEffectEntity")

local DoomBlood = {}

-- S_BLOOD1/S_BLOOD2/S_BLOOD3 (info.c:226-228), sprite BLUD, real frame
-- letters (frame field 2/1/0 -> 'C'/'B'/'A'), in real chain order (full
-- spurt down to a single spot).
local blood = DoomEffectEntity.new({
  spritePrefix = "BLUD",
  letters = { "C", "B", "A" },
  ticsPerFrame = 8,
  defMarker = "pokedoomBlood",
  cacheKeyPrefix = "blood-",
})

-- `P_SpawnBlood(x, y, z, damage)` (p_mobj.c:836-859) -- `damage` picks
-- the STARTING index into the real state chain, not a separate branch.
-- Called from every hit-resolver that lands a shot on something
-- shootable (`lib/DoomKill.lua`, `lib/DoomHordeTarget.lua`, `lib/
-- DoomDemons.lua`), regardless of whether that hit also kills.
-- `wy` (added 2026-08-11): optional ABSOLUTE world height for this
-- splat's own real impact point. Nil-safe -- an unmodified call site
-- renders exactly as before.
function DoomBlood.spawn(ow, wx, wz, damage, wy)
  local startIndex = 1
  if damage and damage < 9 then
    startIndex = 3
  elseif damage and damage <= 12 then
    startIndex = 2
  end
  blood.spawn(ow, wx, wz, startIndex, wy)
end

DoomBlood.install = blood.install

return DoomBlood
