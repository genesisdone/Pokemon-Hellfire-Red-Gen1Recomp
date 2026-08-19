-- PokeDoom: real DOOM exploding barrels (`MT_BARREL`). Direct user
-- request, 2026-08-10: "add random explosive barrels from the original
-- doom to grassy areas, so you can kill demons with them, with all
-- animation, and damage data from original barrels, and any other data
-- you can find to implement. barrels should move slightly when shot
-- just like original barrels from doom source code."
--
-- ------- real DOOM facts, read fresh (`info.c:1888-1912`, `p_enemy.c`,
-- `p_inter.c`)
--
-- `MT_BARREL` mobjinfo: `spawnhealth=20`, `radius=10*FRACUNIT`,
-- `height=42*FRACUNIT`, `damage=0` (a barrel never attacks -- this
-- field is unrelated to its own explosion), `flags=MF_SOLID|
-- MF_SHOOTABLE|MF_NOBLOOD` (no blood spawns on a landed hit -- real
-- DOOM's own `PTR_ShootTraverse`/`PIT_CheckThing` both branch on
-- `MF_NOBLOOD` to spawn a puff instead), `painstate=S_NULL`/
-- `painchance=0` (a barrel NEVER flinches/staggers when shot, unlike a
-- monster -- it just silently absorbs damage until health <= 0).
--
-- Idle animation (`S_BAR1`/`S_BAR2`, `info.c:942-943`): sprite `BAR1`,
-- frames A/B, 6 tics each, looping forever -- a simple 2-frame sway.
--
-- Death/explosion sequence (`S_BEXP`..`S_BEXP5`, `info.c:944-948`):
-- sprite `BEXP`, frame A (5 tics, no action) -> B (5 tics, `A_Scream` --
-- plays `mobjinfo.deathsound`, `sfx_barexp`/DSBAREXP, the SAME real
-- sound the player's own rocket explosion already uses) -> C (5 tics,
-- no action) -> D (10 tics, `A_Explode` -- THIS is where real splash
-- damage actually fires) -> E (10 tics, no action) -> vanishes. 35 tics
-- total (~1 real second), the actual damage landing partway through
-- (after 15 tics), not on the very first frame.
--
-- `A_Explode` (`p_enemy.c:1598-1601`) is `P_RadiusAttack(thingy,
-- thingy->target, 128)` -- the EXACT same call the Cyberdemon's own
-- rocket already uses (see `lib/DoomDemons.lua`'s own
-- `demonProjectileSplash`) -- real 128-DOOM-unit radius, linear
-- falloff, gated on line-of-sight, hitting EVERY real `MF_SHOOTABLE`
-- thing in range (`PIT_RadiusAttack`, `p_map.c:1164-1193`, has no
-- species check at all) with the one real exception: `MT_CYBORG`/
-- `MT_SPIDER` are always immune to splash/concussion damage. Since
-- OTHER barrels are also `MF_SHOOTABLE`, a barrel's own explosion can
-- (and in real DOOM famously does) detonate a NEARBY barrel too -- a
-- genuine, emergent, real chain-reaction, not something separately
-- coded in `p_enemy.c` -- ported here the same way, by including other
-- barrels in this file's own splash sweep.
--
-- "barrels should move slightly when shot" -- confirmed real, and NOT
-- barrel-specific: `P_DamageMobj`'s own generic knockback (`p_inter.c:
-- 806-832`) applies real THRUST to ANY damaged `MF_SHOOTABLE` target
-- with a real inflictor (`thrust = damage*(FRACUNIT>>3)*100/
-- target->info->mass`, then added directly to `target->momx/momy`) --
-- the exact same mechanic that shoves a monster back when shot, which
-- a barrel receives too since it has no exemption from it (`MF_NOCLIP`
-- is the only real skip condition, which barrels don't have). This mod
-- has no generic momentum/friction physics system for arbitrary world
-- objects to hook into (unlike the player's own `lib/DoomMove.lua`) --
-- ported as a small, STATE-DRIVEN decaying positional nudge instead of
-- transplanting DOOM's own fixed-point thrust/friction formulas, per
-- this project's own "avoid math-derived code" preference for the
-- simpler equivalent that still produces the same real, visible result
-- (the barrel visibly shifts a little when hit, then settles).
--
-- ------- what's this mod's own addition, not DOOM's
--
-- Real DOOM never randomly scatters barrels -- every one is hand-placed
-- by a level's own map data (`doomednum = 2035`). "Random barrels in
-- grassy areas" has no DOOM precedent at all (same category as this
-- mod's own currency-per-kill/enemy-drops features) -- how many spawn
-- per map, and reusing `Map:isGrassCell` as the placement filter, are
-- both flagged judgment calls here, not derived facts.

local V = ...
local Host = V.host
local FirstPerson = Host.require("FirstPerson")
local DoomDemons = V.require("DoomDemons")
local DoomWadImport = V.require("DoomWadImport")
local DoomPuff = V.require("DoomPuff")
local DoomHealth = V.require("DoomHealth")
local DoomGround = V.require("DoomGround")
local DoomKill = V.require("DoomKill")
local Options = V.require("DoomOptions")
local DoomLog = V.require("DoomLog")

-- `lib/DoomWeapons.lua` never requires `DoomBarrels` back -- no cycle --
-- but required lazily anyway, matching this project's own established
-- pattern (`lib/DoomWeapons.lua`'s own `getDoomDemons`/`getDoomView`)
-- for any file whose own require graph isn't fully settled yet at the
-- point this file loads.
local DoomWeapons
local function getDoomWeapons()
  DoomWeapons = DoomWeapons or V.require("DoomWeapons")
  return DoomWeapons
end

local DoomBarrels = {}

-- ------- real constants, cited above
local IDLE_LETTERS = { "A", "B" }
local IDLE_TICS = 6
local EXPLODE_STATES = {
  { letter = "A", tics = 5 },
  { letter = "B", tics = 5, scream = true },
  { letter = "C", tics = 5 },
  { letter = "D", tics = 10, explode = true },
  { letter = "E", tics = 10 },
}
local DOOM_TIC_SECONDS = 1 / 35
local BARREL_HP = 20
local BARREL_RADIUS = 10  -- world px, matches real `10*FRACUNIT` reused directly (this project's own established demon-roster convention)
local BARREL_HEIGHT = 42  -- world px, matches real `42*FRACUNIT`
-- Same real 128-DOOM-unit `A_Explode` radius, same proportional
-- conversion `lib/DoomWeapons.lua`'s own `ROCKET_SPLASH_RADIUS` and
-- `lib/DoomDemons.lua`'s own `demonProjectileSplash` already established
-- -- reused rather than a fresh number, since it's the identical real
-- mechanic.
local SPLASH_RADIUS = 32
local SPLASH_MAX_DAMAGE = 128
local HIT_LOG_RADIUS = BARREL_RADIUS

-- Real DOOM's own linear splash falloff (`A_Explode`, p_map.c) -- full
-- `maxDamage` at the blast center, tapering linearly to 0 at `radius`.
-- Factored out 2026-08-19 during a project-wide readability audit: this
-- exact formula was independently written three times in this file
-- (the player's own splash, a chain reaction into another barrel, and
-- `barrelAoeResolver`'s own hit test).
local function splashDamageAt(dist, radius, maxDamage)
  return math.floor(maxDamage * (1 - dist / radius))
end

-- "barrels should move slightly when shot" -- a small, fixed, state-
-- driven nudge (world px, applied once per landed hit, away from the
-- shooter) rather than a transplanted thrust/friction formula. Settles
-- back over `KNOCKBACK_SETTLE` real seconds via simple linear decay.
local KNOCKBACK_PER_HIT = 3
local KNOCKBACK_SETTLE = 0.25

local barrels = {}
local nextBarrelId = 1

local function groundY(ow, cx, cy)
  return DoomGround.heightAt(ow.map, cx, cy)
end

-- ------- scatter placement -- lazy, per-map, on first visit, matching
-- `lib/DoomItems.lua`'s own established `save.doomItems` pattern.
local BARREL_COUNT_MIN, BARREL_COUNT_MAX = 2, 5
local SCATTER_ATTEMPTS = 60 -- bounded search, same shape this project's own other scatter systems already use

-- FIX 2026-08-10 -- user report + screenshot: two barrels scattered
-- right next to each other in a walkway out of Pallet Town, together
-- blocking the only way across -- `passable = false` on a barrel's own
-- entity (matching a real, solid `MF_SOLID` obstacle) meant the naive
-- grass-cell-only random search could and did wall off a real path with
-- no connectivity awareness at all. "Barrels should never block the
-- only path through" is this mod's own explicit requirement (real DOOM
-- never has this problem -- every barrel is hand-placed by a level
-- designer who can already see the whole map).
--
-- Fixed with a real reachability check, not a probability tweak: a
-- candidate cell is only accepted once BLOCKING it (and every other
-- barrel already accepted for this map) is CONFIRMED not to shrink how
-- many cells the player can still reach from their own current
-- position, via an actual bounded BFS flood-fill -- restated from `lib/
-- DoomDemons.lua`'s own real, already-proven `reachableFromPlayer`
-- (same real 4-directional neighbor shape, same `MAX_REACHABLE_CELLS`
-- cap reused rather than a fresh number -- that function isn't exported
-- and doesn't accept a blocked-cell set, so it can't be called directly
-- for this, but the algorithm itself is the same one, not reinvented).
-- The baseline (zero barrels) reachable count is computed ONCE per map;
-- each candidate then only needs to confirm the flood fill still reaches
-- AT LEAST that many cells with the candidate (plus every already-
-- accepted barrel) blocked -- letting the fill exit as soon as it hits
-- that many cells, so the common "this barrel doesn't block anything"
-- case stays cheap.
local MAX_REACHABLE_CELLS = 4000 -- matches lib/DoomDemons.lua's own reachableFromPlayer

-- FIX 2026-08-12 -- direct user report + screenshot: barrels scattered
-- across an entire tree-lined street, leaving no gap a player could
-- walk through without shooting one first -- the same real-world shape
-- the 2026-08-10 reachability fix above was meant to close, resurfacing
-- through a gap that fix doesn't cover. The flood-fill above only checks
-- an AGGREGATE reachable-cell COUNT from the player's own position, not
-- whether any one SPECIFIC corridor stays open -- on a map with enough
-- open area elsewhere (side streets, houses), the fill can satisfy its
-- own target entirely through OTHER routes while several barrels, each
-- individually "safe" by that measure, end up clustered directly across
-- one narrow path together. Real DOOM never has this failure mode at all
-- (every barrel is hand-placed by a level designer who can see the whole
-- map, per this file's own 2026-08-10 note) -- there's no source fact to
-- port here, so this is a state-driven guard against the specific
-- geometry that produces the reported symptom: candidates within
-- `MIN_BARREL_SPACING` tiles of an already-accepted barrel (for the SAME
-- map's own seeding pass) are rejected outright, before the reachability
-- check even runs, so no two barrels from the same scatter can ever end
-- up close enough to jointly wall off a normal-width path the way the
-- screenshot showed. Additive to the existing reachability check, not a
-- replacement for it -- both still have to pass.
local MIN_BARREL_SPACING = 3

local function tooCloseToPlacedBarrel(points, cx, cy)
  for _, p in ipairs(points) do
    if math.abs(p.cx - cx) < MIN_BARREL_SPACING and math.abs(p.cy - cy) < MIN_BARREL_SPACING then
      return true
    end
  end
  return false
end

local function floodReaches(map, startCx, startCy, blocked, target)
  local visited = { [startCx .. "," .. startCy] = true }
  local queue = { { startCx, startCy } }
  local head, count = 1, 1
  local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  while head <= #queue and count < target do
    local cur = queue[head]
    head = head + 1
    for _, d in ipairs(NEIGHBORS) do
      local nx, ny = cur[1] + d[1], cur[2] + d[2]
      local key = nx .. "," .. ny
      if not visited[key] and not (blocked and blocked[key]) then
        -- `inBounds` checked FIRST, matching `lib/DoomDemons.lua`'s own
        -- real, proven `walkableCell` -- `isWalkableCell` isn't
        -- confirmed safe to call on out-of-bounds coordinates on its
        -- own there, so this restates the same defensive order rather
        -- than relying on `pcall` alone to catch it.
        local ok, walkable = pcall(function()
          return map:inBounds(nx, ny) and map:isWalkableCell(nx, ny)
        end)
        if ok and walkable then
          visited[key] = true
          count = count + 1
          if count >= target then break end
          queue[#queue + 1] = { nx, ny }
        end
      end
    end
  end
  return count
end

-- Restated verbatim from `lib/DoomItems.lua`'s own real `isInteriorMap`
-- (there is no simple `map.def.interior` field -- confirmed by reading
-- that file directly rather than guessed): a map counts as interior
-- once its own real `def.index` reaches `Game.data.field.
-- indoorEncounters.firstIndoorMap`, UNLESS its tileset is the one real
-- exclusion (`excludedTileset`) -- both real, already-imported Gen-1
-- data fields this engine tracks for its own indoor-encounter logic,
-- reused here rather than a fresh guess.
local function isInteriorMap(map)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.data.field) then return false end
  local indoor = Game.data.field.indoorEncounters
  if not (indoor and map and map.def) then return false end
  return map.def.index >= indoor.firstIndoorMap
     and map.def.tileset ~= indoor.excludedTileset
end

-- Tries ONE random candidate cell for a barrel placement: must be
-- unblocked, not too close to an already-placed barrel, walkable AND
-- grass, and -- the real safety check -- not cut the player's own
-- reachable area down by more than the one cell the barrel itself now
-- occupies (see `seedBarrelsForMap`'s own "BUG FOUND 2026-08-10" comment
-- below for why "just check floodReaches >= baseline" was wrong).
-- Extracted 2026-08-19 during a project-wide readability audit -- this
-- used to be one ~35-line, 5-deep-nested block inline in the scatter
-- loop; early-return guard clauses read more directly than that nesting
-- did. Mutates `blocked`/`points` in place on success; returns
-- `accepted, expectedReach, cx, cy, reach` (the last three only
-- meaningful when `accepted` is true, for the caller's own log line).
local function tryPlaceBarrelAt(map, blocked, points, expectedReach, px, py)
  -- Real field names, confirmed via `lib/DoomDemons.lua`'s own
  -- `randomWalkablePoint` (not exported, restated here rather than
  -- guessed) -- `map.width`/`map.height` are NOT real fields on this
  -- class.
  local w, h = map.widthCells or 40, map.heightCells or 40
  local cx = math.random(0, math.max(0, w - 1))
  local cy = math.random(0, math.max(0, h - 1))
  local key = cx .. "," .. cy
  if blocked[key] or tooCloseToPlacedBarrel(points, cx, cy) then
    return false, expectedReach
  end
  local walkOk, walkable = pcall(function() return map:isWalkableCell(cx, cy) end)
  local grassOk, grass = pcall(function() return map:isGrassCell(cx, cy) end)
  if not (walkOk and walkable and grassOk and grass) then
    return false, expectedReach
  end
  -- Tentatively block this cell (on top of every barrel already
  -- accepted for this map) and confirm the player's own reachable area
  -- doesn't shrink beyond this cell's own loss -- only THEN is it a
  -- real, confirmed-safe placement.
  blocked[key] = true
  local target = expectedReach - 1
  local reach = floodReaches(map, px, py, blocked, target)
  if reach < target then
    blocked[key] = nil
    return false, expectedReach
  end
  points[#points + 1] = { cx = cx, cy = cy }
  return true, target, cx, cy, reach
end

local function seedBarrelsForMap(ow)
  local map = ow.map
  local mapId = map.id
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save) then return end
  Game.save.doomBarrels = Game.save.doomBarrels or {}
  if Game.save.doomBarrels[mapId] then return end
  if isInteriorMap(map) then
    Game.save.doomBarrels[mapId] = { points = {}, destroyed = {} }
    return
  end

  local px, py = ow.player and ow.player.cellX, ow.player and ow.player.cellY
  local startOk = px and py
  if startOk then
    local walkOk, walkable = pcall(function() return map:isWalkableCell(px, py) end)
    startOk = walkOk and walkable
  end
  if not startOk then
    -- No safe reference point to check connectivity against (the
    -- player's own overworld position isn't ready yet, or isn't
    -- walkable for some reason) -- rather than guess, skip scattering
    -- entirely for now and let the NEXT `input.step` tick (once a real
    -- position is available) try again instead of placing barrels this
    -- mod can't actually verify are safe.
    return
  end

  local baseline = floodReaches(map, px, py, nil, MAX_REACHABLE_CELLS)
  DoomLog.event("BARREL", "seed map=%s baseline reach=%d (player at %d,%d)", tostring(mapId), baseline, px, py)
  local blocked = {}
  local points = {}
  -- BUG FOUND 2026-08-10, after the user reported "i dont see any
  -- barrels in grass at all now" (a full regression from the very fix
  -- meant to stop barrels blocking a path): blocking a CANDIDATE cell
  -- always removes that cell itself from the reachable count too (the
  -- BFS below never visits a blocked cell, including as its own start-
  -- adjacent neighbor), so `reach` could NEVER equal `baseline` even
  -- for a perfectly safe placement -- the old `reach >= baseline` check
  -- silently rejected every single candidate, every time, on every map.
  -- Fixed by tracking a running EXPECTED reachable count that itself
  -- drops by exactly 1 each time a barrel is accepted (that barrel's
  -- own cell is SUPPOSED to stop counting as passable ground -- that's
  -- not a connectivity loss, it's the placement working as intended) --
  -- a new candidate is only rejected when it costs MORE than its own
  -- one cell, i.e. when it actually cuts off some other, unrelated
  -- region.
  local expectedReach = baseline
  local count = math.random(BARREL_COUNT_MIN, BARREL_COUNT_MAX)
  for barrelNum = 1, count do
    local accepted = false
    for _ = 1, SCATTER_ATTEMPTS do
      local ok, newExpectedReach, cx, cy, reach = tryPlaceBarrelAt(map, blocked, points, expectedReach, px, py)
      if ok then
        expectedReach = newExpectedReach
        accepted = true
        DoomLog.event("BARREL", "map=%s barrel %d/%d placed at %d,%d (reach=%d, expected=%d)",
          tostring(mapId), barrelNum, count, cx, cy, reach, expectedReach)
        break
      end
    end
    if not accepted then
      DoomLog.event("BARREL", "map=%s barrel %d/%d: no safe cell found in %d attempts",
        tostring(mapId), barrelNum, count, SCATTER_ATTEMPTS)
    end
  end
  DoomLog.event("BARREL", "map=%s seeding done: %d/%d barrels placed", tostring(mapId), #points, count)
  Game.save.doomBarrels[mapId] = { points = points, destroyed = {} }
end

local function worldPos(cx, cy) return cx * 16, cy * 16 end

local function makeBarrelEntity(b)
  local entity
  entity = {
    passable = false,
    px = b.px, py = b.py, cellX = b.cx, cellY = b.cy,
    draw = function() end,
    pose = function()
      local letter, image
      if b.state == "exploding" then
        local st = EXPLODE_STATES[b.explodeIndex]
        letter = st and st.letter or "E"
      else
        letter = IDLE_LETTERS[b.idleIndex] or "A"
      end
      local sprite = (b.state == "exploding") and "BEXP" or "BAR1"
      local ok, img = pcall(DoomDemons.loadSprite, sprite, letter)
      image = ok and img or nil
      local spriteObj = {
        def = {
          pokedoomDemon = true, pokedoomCacheKey = "barrel-" .. sprite .. letter,
          pokedoomSpritePrefix = sprite,
          pokedoomImage = image, trueColor = true,
          image = "pokedoom-barrel-" .. sprite,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      return spriteObj, entity.px, entity.py, "down", 0, false
    end,
  }
  return entity
end

local function removeBarrelEntity(ow, b)
  b.inserted = false
  if not (b.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == b.entity then table.remove(ow.entities, i) break end
  end
  b.entity = nil
end

-- `pointIndex` (nil for a barrel spawned some other way, none currently
-- exist) names which entry of `Game.save.doomBarrels[mapId].points` this
-- runtime barrel corresponds to -- threaded through so a real kill can
-- mark that SAME index destroyed in the save (see `markBarrelDestroyed`
-- below), the same index-keyed shape `lib/DoomItems.lua`'s own `taken`
-- table already uses for its own picked-up-item persistence.
local function spawnBarrel(ow, cx, cy, pointIndex)
  local px, py = worldPos(cx, cy)
  nextBarrelId = nextBarrelId + 1
  local b = {
    id = nextBarrelId, mapId = ow.map.id,
    cx = cx, cy = cy, px = px, py = py,
    hp = BARREL_HP, state = "idle",
    idleIndex = 1, idleTimer = IDLE_TICS * DOOM_TIC_SECONDS,
    knockX = 0, knockY = 0, knockTimer = 0,
    pointIndex = pointIndex,
  }
  barrels[#barrels + 1] = b
  return b
end

-- BUG FIX 2026-08-12 -- confirmed real, found while auditing this file
-- against `lib/DoomItems.lua`'s own established pattern for the identical
-- category of problem (CLAUDE.md's own "a fix to one implementation of a
-- shared mechanic must be checked against every parallel implementation"
-- hard rule): `DoomItems.lua`'s own `save.doomItems[mapId].taken` table
-- already tracks which scattered points have been consumed, so a picked-
-- up item never reappears -- this file had no equivalent tracking at all.
-- `tickBarrels` below unconditionally drops EVERY barrel for a map (dead
-- or alive) out of the runtime `barrels` list the instant the player
-- leaves that map (`b.mapId ~= ow.map.id`), so the OLD `syncBarrelsForMap`
-- (which only checked "does ANY runtime barrel already exist for this
-- map") saw zero barrels on return and respawned every original scatter
-- point from scratch -- including ones the player had already destroyed.
-- A destroyed barrel would silently come back to life the moment the
-- player walked to a neighboring map and back. Fixed by persisting a
-- `destroyed` set keyed by the same point index `DoomItems.taken` uses,
-- checked here and written by `markBarrelDestroyed` below.
local function syncBarrelsForMap(ow)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save and Game.save.doomBarrels) then return end
  local mapBarrels = Game.save.doomBarrels[ow.map.id]
  if not mapBarrels then return end
  local haveAny = false
  for _, b in ipairs(barrels) do
    if b.mapId == ow.map.id then haveAny = true break end
  end
  if haveAny then return end
  mapBarrels.destroyed = mapBarrels.destroyed or {}
  for i, p in ipairs(mapBarrels.points) do
    if not mapBarrels.destroyed[i] then
      spawnBarrel(ow, p.cx, p.cy, i)
    end
  end
end

-- Companion half of the fix above: marks this barrel's own save point
-- permanently destroyed so `syncBarrelsForMap` skips it on a future visit.
-- A no-op for a barrel with no `pointIndex` (none currently exist, but
-- `spawnBarrel` allows it) or if the map's own save entry is somehow gone.
local function markBarrelDestroyed(ow, b)
  if not b.pointIndex then return end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save and Game.save.doomBarrels) then return end
  local mapBarrels = Game.save.doomBarrels[b.mapId]
  if not mapBarrels then return end
  mapBarrels.destroyed = mapBarrels.destroyed or {}
  mapBarrels.destroyed[b.pointIndex] = true
end

-- ------- splash damage on explosion -- see this file's own header
-- comment for the full real derivation. Restated from `lib/DoomDemons.
-- lua`'s own `demonProjectileSplash` (same real mechanic, same real
-- numbers) rather than shared, per this project's own established
-- "restate small pure-shape pieces per file" precedent -- EXTENDED here
-- to also hit other barrels, for the real chain-reaction.
local function npcCenterFor(entity)
  local px = entity.px or (entity.cellX and entity.cellX * 16)
  local py = entity.py or (entity.cellY and entity.cellY * 16)
  if not (px and py) then return nil end
  return px + 8, py + 8
end

local function losClear(ow, ox, oy, oz, tx, ty, tz)
  local dx, dy, dz = tx - ox, ty - oy, tz - oz
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dist < 1e-6 then return true end
  dx, dy, dz = dx / dist, dy / dist, dz / dist
  local step = 3
  local t = step
  while t < dist do
    local x, y, z = ox + dx * t, oy + dy * t, oz + dz * t
    local cx, cy = math.floor(x / 16), math.floor(z / 16)
    if not ow.map:inBounds(cx, cy) then return false end
    local gh = groundY(ow, cx, cy)
    if y < gh - 0.5 or y < 0 then return false end
    t = t + step
  end
  return true
end

local damageBarrel -- forward-declared: `barrelSplash` (right below)
                    -- calls this for the real chain-reaction against
                    -- other barrels, but `damageBarrel` itself is
                    -- defined further down in the file (Lua has no
                    -- hoisting) -- the standard declare-then-assign
                    -- idiom, same pattern `lib/DoomDemons.lua`'s own
                    -- `demonProjectileSplash` already uses for the
                    -- identical reason.

local function barrelSplash(ow, x, y, z, source)
  if ow.player and DoomHealth.isAlive() then
    local px, pz = ow.player.px, ow.player.py
    if px then
      px, pz = px + 8, pz + 8
      local dx, dz = px - x, pz - z
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist <= SPLASH_RADIUS then
        local damage = splashDamageAt(dist, SPLASH_RADIUS, SPLASH_MAX_DAMAGE)
        local gh = groundY(ow, ow.player.cellX, ow.player.cellY)
        if damage > 0 and losClear(ow, x, y, z, px, gh, pz) then
          pcall(DoomHealth.damage, damage, { source = "barrel", attacker = source })
        end
      end
    end
  end

  -- Demons are reached via the real `DoomWeapons.aoeResolvers` registry
  -- instead (the exact same "radius" event `updateBarrel` below emits
  -- once, right after this function runs) -- not duplicated here.

  if ow.npcs then
    for i = #ow.npcs, 1, -1 do
      local npc = ow.npcs[i]
      if npc ~= ow.player then
        local nx, nz = npcCenterFor(npc)
        if nx then
          local dx, dz = nx - x, nz - z
          local dist = math.sqrt(dx * dx + dz * dz)
          if dist <= SPLASH_RADIUS
             and losClear(ow, x, y, z, nx, groundY(ow, npc.cellX, npc.cellY), nz) then
            npc.pokedoomBeingHunted = nil
            pcall(DoomKill.killNpc, ow, npc)
          end
        end
      end
    end
  end

  -- Real chain reaction: any OTHER live barrel within splash range takes
  -- real falloff damage too, which can itself trigger its own explosion.
  for _, other in ipairs(barrels) do
    if other ~= source and other.mapId == ow.map.id and other.state ~= "exploding" and other.hp > 0 then
      local ox, oz = other.px + 8, other.py + 8
      local dx, dz = ox - x, oz - z
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist <= SPLASH_RADIUS then
        local damage = splashDamageAt(dist, SPLASH_RADIUS, SPLASH_MAX_DAMAGE)
        if damage > 0 and losClear(ow, x, y, z, ox, groundY(ow, other.cx, other.cy), oz) then
          pcall(damageBarrel, ow, other, damage, nil, nil, nil)
        end
      end
    end
  end

  -- Player's own weapon vs ambient demons already has a real, working
  -- AOE resolver registry (`DoomWeapons.registerAoeResolver`) -- this
  -- barrel's own explosion is registered as ONE MORE real AOE EVENT
  -- through that exact same registry (see `install()` below), so it
  -- reaches demons the identical way a rocket/BFG detonation already
  -- does, with no separate demon-specific code needed in this file.
end

-- ------- damage / death
local function startExplosion(ow, b)
  b.state = "exploding"
  b.explodeIndex = 1
  b.explodeTimer = EXPLODE_STATES[1].tics * DOOM_TIC_SECONDS
end

damageBarrel = function(ow, b, damage, shooterX, shooterZ, source)
  if b.hp <= 0 or b.state == "exploding" then return end
  b.hp = b.hp - damage
  -- "barrels should move slightly when shot" -- see this file's own
  -- header comment. Nudges away from the shooter's own position when
  -- known (a direct hit); a splash/chain hit with no single shooter
  -- point just nudges in a random direction, matching real DOOM's own
  -- thrust (which uses the INFLICTOR's position, not the source) as
  -- closely as this simpler model reasonably can.
  local nx, nz = b.px + 8, b.py + 8
  local dx, dz
  if shooterX then
    dx, dz = nx - shooterX, nz - shooterZ
  else
    local a = math.random() * math.pi * 2
    dx, dz = math.cos(a), math.sin(a)
  end
  local dist = math.sqrt(dx * dx + dz * dz)
  if dist > 1e-6 then
    b.knockX = (dx / dist) * KNOCKBACK_PER_HIT
    b.knockY = (dz / dist) * KNOCKBACK_PER_HIT
    b.knockTimer = KNOCKBACK_SETTLE
  end
  if b.hp <= 0 then
    startExplosion(ow, b)
  end
end

-- ------- per-tick update
local function updateBarrel(ow, dt, b)
  if b.mapId ~= ow.map.id then return end

  -- Spreads the total `KNOCKBACK_PER_HIT`-unit nudge proportionally
  -- across `KNOCKBACK_SETTLE` real seconds -- summed over every tick
  -- until `knockTimer` reaches 0, the fractions add up to exactly 1.0,
  -- so the barrel ends up displaced by exactly `knockX`/`knockY` total,
  -- regardless of frame rate.
  --
  -- FIX 2026-08-11 -- user report + screenshot: shooting a barrel next
  -- to a wall sent it flying up on top of that wall. Root cause: this
  -- block moved `b.px/b.py` (and recomputed `b.cx/b.cy` from the new
  -- position) completely unconditionally, with no walkability check at
  -- all -- unlike every other moving entity in this mod (demons,
  -- the player), which all check `Map:isWalkableCell` before accepting
  -- a step. A knockback nudge is small (`KNOCKBACK_PER_HIT`, a few
  -- world px) but perfectly capable of pushing a barrel that started
  -- right next to a wall's own base into the WALL'S OWN CELL. Once
  -- `b.cx/b.cy` pointed at that cell, every real reader of this
  -- barrel's own ground height (`groundY(ow, b.cx, b.cy)`, used for
  -- rendering, splash origin, and hit-test acceptance) returned the
  -- solid geometry's own real height AT that cell -- for a wall, that's
  -- the wall's own TOP surface, not street level -- which is exactly
  -- "the barrel goes up on top of the wall," not a rendering glitch.
  -- Fixed by checking the TENTATIVE new cell's own real walkability
  -- before ever accepting the move: if it's not walkable, the knockback
  -- stops dead right where the barrel already is (the remaining
  -- timer/displacement is simply dropped) instead of crossing into it --
  -- a barrel can never gain the ability to "go up" a wall, pushed or
  -- not, matching the user's own explicit ask.
  if b.knockTimer > 0 then
    local step = math.min(dt, b.knockTimer)
    local frac = step / KNOCKBACK_SETTLE
    local newPx = b.px + b.knockX * frac
    local newPy = b.py + b.knockY * frac
    local newCx, newCy = math.floor(newPx / 16), math.floor(newPy / 16)
    local okW, walkable = pcall(function() return ow.map:isWalkableCell(newCx, newCy) end)
    if okW and walkable then
      b.px, b.py = newPx, newPy
      b.cx, b.cy = newCx, newCy
      b.knockTimer = b.knockTimer - step
    else
      b.knockTimer = 0
    end
  end

  if b.state == "exploding" then
    b.explodeTimer = b.explodeTimer - dt
    if b.explodeTimer <= 0 then
      local st = EXPLODE_STATES[b.explodeIndex]
      if st and st.scream then
        local ok, snd = pcall(DoomWadImport.loadSound, "DSBAREXP")
        if ok and snd then DoomWadImport.playClone("DSBAREXP (barrel)", snd) end
      end
      if st and st.explode then
        local gh = groundY(ow, b.cx, b.cy)
        pcall(barrelSplash, ow, b.px + 8, gh + BARREL_HEIGHT / 2, b.py + 8, b)
        local weapons = getDoomWeapons()
        if weapons and weapons.aoeResolvers then
          for _, resolver in ipairs(weapons.aoeResolvers) do
            pcall(resolver, ow, {
              kind = "radius", x = b.px + 8, y = gh + BARREL_HEIGHT / 2, z = b.py + 8,
              radius = SPLASH_RADIUS, maxDamage = SPLASH_MAX_DAMAGE,
            })
          end
        end
      end
      b.explodeIndex = b.explodeIndex + 1
      local nextState = EXPLODE_STATES[b.explodeIndex]
      if not nextState then
        removeBarrelEntity(ow, b)
        b.dead = true
        markBarrelDestroyed(ow, b)
      else
        b.explodeTimer = nextState.tics * DOOM_TIC_SECONDS
      end
    end
  else
    b.idleTimer = b.idleTimer - dt
    if b.idleTimer <= 0 then
      b.idleTimer = IDLE_TICS * DOOM_TIC_SECONDS
      b.idleIndex = (b.idleIndex % #IDLE_LETTERS) + 1
    end
  end

  if not b.dead then
    local isNewEntity = not b.entity
    b.entity = b.entity or makeBarrelEntity(b)
    b.entity.px, b.entity.py = b.px, b.py
    b.entity.cellX, b.entity.cellY = b.cx, b.cy
    -- DIAGNOSTIC, added 2026-08-10 -- user report + screenshot: one
    -- barrel rendering high up in open sky, clearly detached from any
    -- ground geometry, while every OTHER barrel in the same screenshot
    -- sits correctly at ground level. Checked first, per CLAUDE.md's
    -- own logging-before-a-second-guess rule: `lib/DoomDemons.lua`'s own
    -- 2026-08-06 fix for demons floating (stale `entity.px/py/cellX/
    -- cellY`, never resynced as a demon walked) does NOT apply here --
    -- this file already resyncs those exact 4 fields from `b`'s own
    -- live state unconditionally every tick, two lines above, so that
    -- specific staleness bug is already closed. Since only ONE barrel
    -- (not all of them) floats, this looks specific to that barrel's
    -- own cell rather than the shared render contract -- logs the real
    -- numbers ONCE per barrel (map load) instead of guessing a second
    -- time: `groundY` (what the render pipeline will place it at) is
    -- the value to check first against the cell's own visible height.
    if isNewEntity then
      local gh = groundY(ow, b.cx, b.cy)
      DoomLog.event("BARREL", "map=%s barrel id=%d entity created at cx=%d cy=%d (px=%.1f py=%.1f) groundY=%.2f",
        tostring(ow.map.id), b.id, b.cx, b.cy, b.px, b.py, gh)
    end
    if not b.inserted then
      table.insert(ow.entities, b.entity)
      b.inserted = true
    end
  end
end

local lastEntitiesMapId = nil
local function tickBarrels(ow, dt)
  if ow.map.id ~= lastEntitiesMapId then
    for _, b in ipairs(barrels) do b.inserted = false end
    lastEntitiesMapId = ow.map.id
  end
  for i = #barrels, 1, -1 do
    local b = barrels[i]
    if b.mapId ~= ow.map.id then
      removeBarrelEntity(ow, b)
      table.remove(barrels, i)
    else
      updateBarrel(ow, dt, b)
      if b.dead then table.remove(barrels, i) end
    end
  end
end

-- ------- hit-test resolvers -- same real ray-vs-cylinder shape this
-- project's own established resolvers already use (`lib/DoomKill.lua`'s
-- `overworldNpcResolver`, `lib/DoomDemons.lua`'s `demonResolver`),
-- restated against `barrels` instead of `ow.npcs`/`demons`.
local function nearEntryT(ox, oz, dx, dz, flat, mx, mz, rad, fallbackT)
  local ex, ez = ox - mx, oz - mz
  local halfB = dx * ex + dz * ez
  local c = ex * ex + ez * ez - rad * rad
  local disc = halfB * halfB - flat * c
  if disc < 0 then return fallbackT end
  return (-halfB - math.sqrt(disc)) / flat
end

local function barrelResolver(ow, r, maxT, damage, weaponName)
  if #barrels == 0 then return nil end
  local ox, oy, oz, dx, dy, dz = r[1], r[2], r[3], r[4], r[5], r[6]
  local flat = dx * dx + dz * dz
  if flat < 1e-6 then return nil end
  local best, bestT
  for _, b in ipairs(barrels) do
    if b.mapId == ow.map.id and b.state ~= "exploding" and not b.dead then
      local mx, mz = b.px + 8, b.py + 8
      local t = ((mx - ox) * dx + (mz - oz) * dz) / flat
      if t > 0 and t < maxT and (not bestT or t < bestT) then
        local hx, hz = ox + dx * t - mx, oz + dz * t - mz
        if hx * hx + hz * hz <= HIT_LOG_RADIUS * HIT_LOG_RADIUS then
          local gh = groundY(ow, b.cx, b.cy)
          local y = oy + dy * t
          if y >= gh - 2 and y <= gh + BARREL_HEIGHT then
            best, bestT = b, t
          end
        end
      end
    end
  end
  if not best then return nil end
  local mx, mz = best.px + 8, best.py + 8
  local hitT = nearEntryT(ox, oz, dx, dz, flat, mx, mz, HIT_LOG_RADIUS, bestT)
  -- Real DOOM: `MT_BARREL` carries `MF_NOBLOOD` (`info.c:1910`) -- a
  -- landed hit shows the real bullet-puff effect, not blood
  -- (`PTR_ShootTraverse`'s own `if (in->d.thing->flags & MF_NOBLOOD)
  -- P_SpawnPuff(...) else P_SpawnBlood(...)`, p_map.c:1003-1007) --
  -- `lib/DoomPuff.lua` already ports exactly this real effect.
  -- FIX 2026-08-11 -- same real gap as `lib/DoomWeapons.lua`'s own
  -- matching fix this round: the ray's own real termination height
  -- (`oy + dy*hitT`) was available and simply never passed through.
  pcall(DoomPuff.spawn, ow, ox + dx * hitT, oz + dz * hitT, false, oy + dy * hitT)
  pcall(damageBarrel, ow, best, damage or 1, ox, oz, nil)
  return best, hitT
end

local function barrelAoeResolver(ow, event)
  if #barrels == 0 then return end
  if event.kind == "radius" then
    for _, b in ipairs(barrels) do
      if b.mapId == ow.map.id and b.state ~= "exploding" and not b.dead then
        local mx, mz = b.px + 8, b.py + 8
        local dx, dz = mx - event.x, mz - event.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= event.radius then
          local damage = splashDamageAt(dist, event.radius, event.maxDamage)
          if damage > 0 and losClear(ow, event.x, event.y, event.z, mx, groundY(ow, b.cx, b.cy), mz) then
            pcall(damageBarrel, ow, b, damage, event.x, event.z, nil)
          end
        end
      end
    end
  end
  -- No `spray` branch: real `A_BFGSpray` calls `P_DamageMobj` directly,
  -- never through `P_RadiusAttack` -- but it fans 40 rays against
  -- whatever `demonResolver`-equivalent search each file already runs;
  -- a barrel is a static point target the same shape a `radius` event
  -- already covers, and this mod's own BFG spray implementation
  -- (`lib/DoomDemons.lua`'s own spray branch) targets `demons`
  -- specifically -- extending spray to barrels too is a real, flagged,
  -- deliberately deferred gap, not silently dropped.
end

-- FEATURE 2026-08-11 -- direct user request: "the shooting system
-- should work just like dooms... if you shoot in front of you, and
-- something, like a enemy, pokemon, npc, barrel, or anything else that
-- is shootable, it should land on that thing as long as its lined up
-- horizontally, putting the bullet wherever the entity is vertically
-- automatically." `lib/DoomWeapons.lua`'s own `computeAutoAimPitch`
-- (the real `P_AimLineAttack`-equivalent auto-aim search, LOCKED-camera-
-- mode only, `Options.freelookEnabled()` gated) already searches ambient
-- demons (`DoomDemons.aimTargets`) and every overworld NPC (`ow.npcs`,
-- which already covers "pokemon" and "npc" both, since a Pokémon-as-NPC
-- is just an `ow.npcs` member with a flag) -- but barrels were never
-- added to that search at all, a real, confirmed gap matching CLAUDE.md's
-- own "check every parallel implementation" hard rule (`lib/
-- DoomBarrels.lua` is its own real, parallel hittable-entity system,
-- same as demons/NPCs, just never wired into this ONE shared mechanic).
-- A shot aimed at a barrel sitting above/below the shooter's own level
-- fire line could miss outright, or have its pitch stolen by whatever
-- OTHER demon/NPC happened to be nearest within the cone instead. Same
-- real shape as `DoomDemons.aimTargets` (`{x, z, height, cx, cy}` per
-- candidate) so `computeAutoAimPitch` can treat every hittable-entity
-- system identically with no special-casing.
function DoomBarrels.aimTargets(ow)
  local list = {}
  if not (ow and ow.map) then return list end
  for _, b in ipairs(barrels) do
    if b.mapId == ow.map.id and b.state ~= "exploding" and not b.dead then
      list[#list + 1] = { x = b.px + 8, z = b.py + 8, height = BARREL_HEIGHT, cx = b.cx, cy = b.cy }
    end
  end
  return list
end

-- ------- install
local installed = false
function DoomBarrels.install()
  if installed then return end
  installed = true

  -- CLAUDE.md's own pausing hard rule: any always-on `input.step` tick
  -- that changes world state on its own must check `FirstPerson.onTop()`
  -- so it genuinely freezes while paused (a menu open, a battle, etc.)
  -- instead of continuing to animate/explode/knockback in the background.
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    if ok and ow and ow.map and Options.enabled() and FirstPerson.onTop() then
      pcall(seedBarrelsForMap, ow)
      pcall(syncBarrelsForMap, ow)
      pcall(tickBarrels, ow, dt)
    end
    return next(game, dt)
  end)

  local weapons = getDoomWeapons()
  if weapons then
    weapons.registerTargetResolver(barrelResolver)
    weapons.registerAoeResolver(barrelAoeResolver)
  end

  -- A fresh save/map load has no business resuming stale in-memory
  -- barrel entities against whatever's now actually on screen -- same
  -- real reasoning `lib/DoomKill.lua`'s own `resetGibs` and `lib/
  -- DoomTownInvasion.lua`'s own `resetInvasionState` already use.
  local function reset()
    barrels = {}
    lastEntitiesMapId = nil
  end
  V.mod.events:on("save.loaded", reset)
  V.mod.events:on("save.created", reset)
end

return DoomBarrels
