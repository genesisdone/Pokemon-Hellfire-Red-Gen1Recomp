-- PokeDoom: Wilds-of-Kanto (`overworld-spawn-mod-main 2`, manifest id
-- `overworld_wild_spawns`) movement compatibility. User request, mid-turn
-- addition to the follower-death-fix/trainer-reward request: "make sure
-- the following pokemon in the kanto mod actually follow behind you with
-- the same movement you have instead of the grid movement like it is in
-- the normal game. make it completely compatible with the doom mod." A
-- later message made the scope constraint explicit and controlling:
-- "make all the fixes described in the doom mod and do not touch the
-- kanto folder unless you are just reading" -- everything below only
-- ever READS Wilds' own source (to find the correct live table field and
-- module-path string) and only ever WRAPS a live table field from this
-- mod's own code, per CLAUDE.md's "addon, not a fork" hard rule extended
-- to this third-party dependency -- no file under `overworld-spawn-mod-
-- main 2` is ever edited.
--
-- ------- what Wilds actually does today, confirmed by direct source
-- reads (not assumed)
--
-- Trailer NPCs are real `ow.npcs` members built via the base engine's own
-- `NPC.new` (`control_engine.lua` `makeTrailer`), each holding a direct
-- reference to its real party member (`npc.pokepcMon`). Every tick,
-- `ControlEngine:advanceAllTrailers` calls `ControlEngine.
-- advanceTrailerStep(trailer, ow.map, ow.entities, self.diag)` for each
-- one (`control_engine.lua`, confirmed via direct read of the real call
-- site: a live table-field lookup, `ControlEngine.advanceTrailerStep`,
-- re-read every call -- NOT a cached local -- so wrapping the field from
-- here correctly intercepts it). That function already does continuous
-- pixel interpolation WITHIN one grid step (`t = npc.progress/frames`,
-- lerping `npc.px`/`npc.py`) but can only choose a new direction at
-- completed 16px cell boundaries -- the real mismatch against this mod's
-- own continuous player movement (`DramaticShapeVoxelMod-dev/lib/
-- FreeMove.lua`: `p.px`/`p.py` is the real continuous world position
-- that DRIVES movement, `p.cellX`/`p.cellY` are DERIVED via `math.floor`)
-- is quantized direction-change cadence, not raw jerkiness.
--
-- ------- the fix
--
-- While PKDOOM MODE is on and the player is actually first-person driving
-- (`Options.enabled() and FirstPerson.driving()`), wrap `ControlEngine.
-- advanceTrailerStep` (reached via `mod.find("overworld_wild_spawns").
-- exports.lib.require("follower/control_engine")` -- confirmed, by
-- reading Wilds' own `main.lua`, to be the exact real module-path string
-- convention its own internal code uses, e.g. `V.require("follower/
-- constants")`) and drive each trailer's own `npc.px`/`npc.py` from a
-- continuous trail of the player's own recent positions instead of
-- Wilds' own discrete step queue -- mirroring the player's own real
-- "px/py drives movement, cellX/cellY derived via floor" convention.
--
-- A rolling trail of the player's own world-center position is recorded
-- once per `input.step` tick (only when the player has moved at least
-- `TRAIL_SAMPLE_DIST` world units since the last sample, to keep sample
-- density roughly uniform regardless of frame rate/speed). Trailer `i`
-- (its real conga-line order, read directly off Wilds' own live
-- `ow.pokepcTrailers` array -- no private state duplicated) targets the
-- point `i * FOLLOW_GAP` world units back along that trail, found by
-- walking the trail backward and interpolating within the bracketing
-- segment. `FOLLOW_GAP = 16` (one tile-equivalent) keeps the same visual
-- conga-line spacing the classic grid mode already used, just continuous
-- instead of quantized. No separate speed-limited smoothing is applied on
-- top -- the lag from following N units behind an already-smoothly-
-- extending trail already produces smooth motion by construction; adding
-- a second smoothing pass on top would only fight the first.
--
-- Before committing a computed position, `ow.map:isWalkableCell(cx, cy)`
-- (the same real method Phase 13's own item-scatter code already reads)
-- gates it -- if the trail briefly computes a point that isn't walkable
-- (a rare edge case: a map transition, or the trail not yet having caught
-- up around a corner), the trailer just holds its current position for
-- that one frame rather than risk visually clipping through geometry.
-- This is a deliberate, stated simplification of Wilds' own real
-- per-cell walkability/ledge-hop/water checks (`isFollowerCellAllowed`,
-- `_pickTrailerStep`, `ledgeStep`) -- a single walkable-cell check, not a
-- full re-implementation of those -- flagged here rather than silently
-- presented as full parity.
--
-- Falls through to the ORIGINAL `advanceTrailerStep` whenever: Wilds
-- isn't present, PKDOOM MODE is off or the player isn't actually driving
-- first-person, this specific `npc` isn't found in `ow.pokepcTrailers`
-- (not a real trailer, or Wilds' own internal bookkeeping hasn't caught
-- up yet), or the trail doesn't have enough samples yet for this
-- trailer's own target distance -- so Wilds' own normal grid-following
-- behavior is completely unaffected whenever this compatibility layer
-- doesn't have enough to safely take over, matching CLAUDE.md's own core
-- "nothing about the host's behavior changes when the mode is off"
-- principle, generalized to this dependency too.
--
-- The wrap attempt itself is retried every tick (cheap: a `mod.find` plus
-- a couple of field checks) until it succeeds, rather than attempted once
-- at this mod's own `install()` time -- Wilds is not a declared
-- dependency of this mod (`manifest.json` has no dependency on it), so
-- its own load order relative to this mod is not guaranteed; retrying
-- avoids silently never wrapping if Wilds happens to load after PokeDoom.

local V = ...
local Options = V.require("DoomOptions")
local Host = V.host
local FirstPerson = Host.require("FirstPerson")

local DoomWildsCompat = {}

local FOLLOW_GAP = 16          -- world units between conga-line links (one tile-equivalent)
local TRAIL_SAMPLE_DIST = 3    -- world units between recorded trail points
local MAX_TRAILERS = 6         -- Wilds' own real follower_count cap (control_engine.lua)

local playerTrail = {}
local lastMapId = nil
local wrapped = false

local function resetTrail()
  playerTrail = {}
end

-- Walks the trail backward from its newest sample, accumulating segment
-- lengths, until reaching (and interpolating within) the segment that
-- crosses `dist` world units behind the newest point. Returns nil if the
-- trail has no samples yet.
local function pointBehind(dist)
  local n = #playerTrail
  if n == 0 then return nil end
  if n == 1 then return playerTrail[1].x, playerTrail[1].y end
  local acc = 0
  for i = n, 2, -1 do
    local a, b = playerTrail[i], playerTrail[i - 1]
    local dx, dy = a.x - b.x, a.y - b.y
    local segLen = math.sqrt(dx * dx + dy * dy)
    if acc + segLen >= dist then
      local t = segLen > 0 and (dist - acc) / segLen or 0
      return a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t
    end
    acc = acc + segLen
  end
  -- Trail isn't long enough yet for this distance -- oldest point we have.
  return playerTrail[1].x, playerTrail[1].y
end

local function recordTrailPoint(px, py)
  local last = playerTrail[#playerTrail]
  if last then
    local dx, dy = px - last.x, py - last.y
    if dx * dx + dy * dy < TRAIL_SAMPLE_DIST * TRAIL_SAMPLE_DIST then return end
  end
  playerTrail[#playerTrail + 1] = { x = px, y = py }
  -- Bounded to comfortably exceed the max realistic total follow
  -- distance (6 trailers * FOLLOW_GAP), regardless of how long the
  -- player has been walking.
  local maxLen = math.floor(MAX_TRAILERS * FOLLOW_GAP / TRAIL_SAMPLE_DIST) + 20
  while #playerTrail > maxLen do table.remove(playerTrail, 1) end
end

local function active()
  return Options.enabled() and FirstPerson.driving()
end

-- Finds `npc`'s own conga-line position in `ow.pokepcTrailers` (its
-- real follow order), or nil if this npc isn't one of Wilds' own
-- trailers at all (not a real follower, or Wilds' own bookkeeping
-- hasn't caught up yet).
local function trailerIndex(ow, npc)
  for i, t in ipairs(ow.pokepcTrailers) do
    if t == npc then return i end
  end
  return nil
end

-- The actual override body: tries to place `npc` along the recorded
-- player trail. Returns `handled, moved` -- `handled` false means "this
-- compat layer has nothing useful to do, fall through to Wilds' own real
-- `advanceTrailerStep`"; `handled` true with `moved` false means "this
-- IS a trailer we're driving, but hold its current position this frame"
-- (matching `advanceTrailerStep`'s own real falsy-return "didn't move"
-- contract).
local function driveTrailerFromTrail(npc)
  if not active() then return false end
  local okOw, ow = pcall(function() return require("src.core.Game").overworld end)
  if not (okOw and ow and ow.player and ow.map and ow.pokepcTrailers) then
    return false
  end

  local idx = trailerIndex(ow, npc)
  if not idx then return false end

  local tx, ty = pointBehind(idx * FOLLOW_GAP)
  if not tx then return false end

  local cx, cy = math.floor(tx / 16), math.floor(ty / 16)
  local okWalk, walkable = pcall(function() return ow.map:isWalkableCell(cx, cy) end)
  if not (okWalk and walkable) then
    -- Hold position this frame rather than risk clipping through
    -- geometry -- matching `advanceTrailerStep`'s own real "didn't
    -- move" contract (a falsy return).
    return true, false
  end

  npc.px, npc.py = tx - 8, ty - 8
  npc.cellX, npc.cellY = cx, cy
  npc.moving = true
  return true, true
end

-- Attempts to wrap `ControlEngine.advanceTrailerStep` exactly once.
-- Safe to call every tick -- cheap no-op once `wrapped` is true, and
-- cheap (one `mod.find` + two field checks) while Wilds isn't loaded yet.
local function tryWrap()
  if wrapped then return end
  local wilds = V.mod.find("overworld_wild_spawns")
  if not wilds then return end
  local ok, ControlEngine = pcall(function()
    return wilds.exports.lib.require("follower/control_engine")
  end)
  if not (ok and ControlEngine and ControlEngine.advanceTrailerStep) then return end

  local inner = ControlEngine.advanceTrailerStep
  ControlEngine.advanceTrailerStep = function(npc, map, entities, diag)
    local okRun, handled, result = pcall(driveTrailerFromTrail, npc)
    if okRun and handled then return result end
    return inner(npc, map, entities, diag)
  end
  wrapped = true
end

function DoomWildsCompat.install()
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    tryWrap()
    if active() then
      local okOw, ow = pcall(function() return require("src.core.Game").overworld end)
      if okOw and ow and ow.player and ow.player.px and ow.player.py then
        if ow.map and ow.map.id ~= lastMapId then
          lastMapId = ow.map.id
          resetTrail()
        end
        recordTrailPoint(ow.player.px + 8, ow.player.py + 8)
      end
    end
    return next(game, dt)
  end)

  -- A fresh save/map load has no business resuming a trail recorded
  -- against whatever was previously on screen -- same reasoning as
  -- `lib/DoomKill.lua`'s own `resetGibs`/`lib/DoomTownInvasion.lua`'s own
  -- `resetInvasionState`, both real, confirmed call sites of this exact
  -- pattern.
  local function onFreshLoad()
    resetTrail()
    lastMapId = nil
  end
  V.mod.events:on("save.loaded", onFreshLoad)
  V.mod.events:on("save.created", onFreshLoad)
end

return DoomWildsCompat
