-- PokeDoom: town invasion events. User request, 2026-08-08: "demons
-- should not be able to spawn in a town. they should only spawn in
-- grass or other areas. no towns. there should be events randomly
-- through the game that spawns a certain amount of demons in a town
-- youre currently in and you have to kill all of them to save the
-- people in the town, with a enemy counter using the horde enemy
-- counter logic. when the demons spawn, all pokemon NPCs should run
-- inside an interior to avoid getting killed by demons, then come out
-- after all the demons are killed."
--
-- Companion fix, same request, in `lib/DoomDemons.lua`'s own
-- `ambientSpawnTick`: ambient demons no longer spawn on a town map at
-- all (a new `isTownMap` check added there, reusing this file's own
-- real `Map.isFlyTown`-based classification) -- superseding that
-- file's own earlier "demons should... sometimes wonder out to a city"
-- design (2026-08-06) at the user's own current, explicit instruction.
-- This file is the deliberate exception: a scheduled, player-visible
-- EVENT that puts demons in the CURRENT town on purpose, distinct from
-- (and no longer overlapping with) ambient roaming.
--
-- "using a horde enemy counter logic" -- audited what that actually IS
-- first, rather than assuming (this project's own porting-methodology
-- rule: verify, don't assume). `DramaticShapeVoxelMod-dev/lib/
-- HordeHud.lua`'s own real `draw` only ever renders SCORE/WAVE -- no
-- remaining-enemy-count widget exists there at all. The real wave-
-- clear check lives in `HordeMobs.update` as a plain `#s.mobs == 0`
-- test against `Horde.session`, which only exists once a REAL Horde
-- Mode run has actually started (`Horde.begin(G)`). Starting a real
-- Horde session just to borrow its counter would also pull in Horde's
-- own gun/HUD/wave-spawn machinery, which this feature has nothing to
-- do with -- so this file borrows the PATTERN a Horde wave-clear check
-- actually is (a live list of tracked enemies, "cleared once the list
-- is empty") rather than Horde's own session state, and draws its own
-- small counter through this mod's OWN existing `lib/DoomFont.lua`,
-- the same real font every other DOOM-native HUD overlay in this
-- project already uses (see `lib/DoomHordeControl.lua`'s own SCORE/
-- WAVE readout for the closest analogous precedent, whose virtual-
-- canvas transform this file's own `drawCounter` restates).
--
-- Genuinely new mechanics this file adds that have no real DOOM source
-- to cite (this whole event is this mod's own addition, not a ported
-- DOOM feature, same category as Phase 23's own killfeed-on-death
-- addition) -- every number below is a flagged, adjustable judgment
-- call, not a derived fact:
--   - how many demons spawn (`DEMON_COUNT_MIN/MAX`)
--   - how long between invasions (`COOLDOWN_MIN/MAX`) and how likely
--     one starts once eligible (`TRIGGER_CHANCE`, rolled every
--     `CHECK_INTERVAL` seconds while the player stands in a town)
--   - NPC flee target: the nearest entry in the current map's own real
--     `def.warps` list (confirmed, by reading `gen1recomp-dev/src/
--     world/Map.lua` directly, to be the same real per-map warp/door
--     data `Map:warpAtCell` reads from -- on a town map this is
--     overwhelmingly building doors, not cross-map route connections,
--     so "nearest warp" is a reasonable stand-in for "nearest interior
--     entrance" without needing new pathfinding). Movement toward it
--     reuses the exact same real per-cell-step SHAPE `lib/DoomDemons.
--     lua`'s own `stepCitizenFlee` already established (`.moving`/
--     `.targetX`/`.targetY`/`.facing`/`.progress`, the same fields
--     `NPC.lua`'s own normal walk animation reads) -- restated rather
--     than reused directly since the real direction math is inverted
--     (toward a fixed point, not away from a live threat), and it's a
--     short enough function that generalizing it into a shared helper
--     for one caller isn't worth the indirection.
--   - once an NPC reaches its target cell, it's REMOVED from `ow.npcs`
--     (simulating "went inside"), the exact same real remove-from-list
--     shape `lib/DoomKill.lua`'s own `save.killedNpcs` sweep already
--     uses for a different reason -- restored (position, facing, and
--     re-inserted into `ow.npcs`) the instant the invasion ends.
--   - session-only state, not persisted across a save/load -- matching
--     this project's own already-established precedent for Horde Mode
--     itself (`PHASE-PROGRESS.md`'s own backlog: "Save/resume for this
--     mode... may stay session-only"). A save made mid-invasion simply
--     loses it on reload; any hidden NPCs are restored the moment a
--     fresh map load happens anyway (this file's own `endInvasion`
--     runs on `save.loaded`/`save.created` too, see `install` below),
--     so nothing is ever permanently lost, just not resumed.
--   - leaving the invaded town's own map before it's cleared CANCELS
--     the invasion outright (restores any hidden NPCs, discards the
--     remaining demons) rather than trying to keep simulating a map
--     the player can no longer see -- the simplest, safest choice
--     given this mod has no existing precedent for ticking demon AI on
--     an unloaded/inactive map at all.

local V = ...
local Options = V.require("DoomOptions")
local DoomDemons = V.require("DoomDemons")
local DoomFont = V.require("DoomFont")
local DoomVirtualCanvas = V.require("DoomVirtualCanvas")
local Host = V.host
local FirstPerson = Host.require("FirstPerson")
local DayNight = Host.require("DayNight")

local DoomTownInvasion = {}

local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H

-- Town detection lives in `lib/DoomDemons.lua` (`DoomDemons.isTownMap`)
-- rather than here, even though this file is the one that most wants
-- it -- `DoomDemons.lua` needs the SAME check for its own ambient-spawn
-- exclusion (see that file's own `ambientSpawnTick`), and THIS file
-- already requires `DoomDemons` (for `spawnDemon`/`NAMES` below); the
-- reverse (`DoomDemons` requiring this file) would be a real circular
-- require, since `V.require`'s own caching has no cycle-breaking of its
-- own. One shared function, one dependency direction.
local isTownMap = DoomDemons.isTownMap

-- ------- state
local active = false
local mapId = nil
local demonRefs = {} -- { {m = <table from DoomDemons.spawnDemon>}, ... }
local totalCount = 0
local fledNpcs = {} -- { {npc=, homeCx=, homeCy=, homePx=, homePy=, homeFacing=, targetCx=, targetCy=, hidden=false}, ... }

local checkTimer = 0
local CHECK_INTERVAL = 10 -- seconds between eligibility rolls
local COOLDOWN_MIN, COOLDOWN_MAX = 180, 420 -- 3-7 minutes between invasions
local TRIGGER_CHANCE = 0.15
local DEMON_COUNT_MIN, DEMON_COUNT_MAX = 5, 9

-- FEATURE 2026-08-10 -- user request: a new "INVASION FREQUENCY" options
-- row (RARE/NORMAL/FREQUENT, `lib/DoomOptions.lua`). Scales the cooldown
-- range rather than `TRIGGER_CHANCE` -- one knob, not two compounding
-- sources of randomness. Read live every time a fresh cooldown is
-- rolled (`endInvasion`'s own re-roll, and this module's own initial
-- value below), so changing the setting mid-game takes effect on the
-- very next roll without needing a separate "recompute now" call.
local FREQUENCY_SCALE = { rare = 1.8, normal = 1.0, frequent = 0.5 }

local function frequencyScale()
  return FREQUENCY_SCALE[Options.invasionFrequency()] or 1.0
end

local function randomCooldown()
  return (COOLDOWN_MIN + math.random() * (COOLDOWN_MAX - COOLDOWN_MIN)) * frequencyScale()
end
local cooldownRemaining = randomCooldown()

-- ------- starting an invasion
local function nearestWarp(map, cx, cy)
  local warps = map.def and map.def.warps
  if not (warps and #warps > 0) then return nil end
  local best, bestD
  for _, w in ipairs(warps) do
    local dx, dy = w.x - cx, w.y - cy
    local d = dx * dx + dy * dy
    if not bestD or d < bestD then best, bestD = w, d end
  end
  return best
end

-- FIX 2026-08-08 (user report: "the pokemon npcs should actually go
-- INSIDE the interior, not just go behind the door in the 3d world
-- space... if i walk into that interior, i will find that npc that
-- walked inside"). The first version only hid a fleeing NPC on the
-- SAME map -- confirmed real, correct fields for actually relocating
-- one by reading `gen1recomp-dev/src/world/Warp.lua`/`OverworldController.
-- lua` directly: a `map.def.warps` entry carries real `destMap` (the
-- destination map id) and `destWarp` (an index into THAT map's own
-- `warps` list -- not raw x/y), and `WorldAPI:spawnNpc(mapId, objDef)`/
-- `:removeNpc(npcId)` (reached via `V.mod.world`, the base engine's own
-- real mod-facing API, confirmed genuinely cross-map: it appends to/
-- removes from `Game.data.maps[mapId].objects`, the SAME persistent
-- list a map's own NPCs are rebuilt from on `map.entered` regardless of
-- whether that map is the one currently loaded) are the real, public,
-- previously-unused-in-this-project primitives for placing an NPC on a
-- map the player hasn't entered yet, and having it genuinely be there
-- when they do.
local function warpDestination(warp)
  if not (warp and warp.destMap and warp.destWarp) then return nil end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.data.maps) then return nil end
  local destDef = Game.data.maps[warp.destMap]
  if not (destDef and destDef.warps and destDef.warps[warp.destWarp]) then return nil end
  local destWarp = destDef.warps[warp.destWarp]
  return warp.destMap, destWarp.x, destWarp.y
end

local function snapshotNpc(npc)
  return {
    npc = npc,
    homeCx = npc.cellX, homeCy = npc.cellY,
    homePx = npc.px, homePy = npc.py,
    homeFacing = npc.facing,
    hidden = false,
  }
end

-- FEATURE 2026-08-08 -- user request: "invasion mode starting should
-- have some of the same effects as horde mode starting which is: the
-- world turns to night and lavender town music starts playing."
-- Restated from the real, confirmed source of both effects,
-- `DramaticShapeVoxelMod-dev/lib/Horde.lua`'s own `Horde.begin`/
-- `Horde.finish` (read directly): night is `DayNight.setting:
-- setIndex(nightIndex, G)`, where `nightIndex` is found by scanning
-- `DayNight.setting.values` for the literal string `"night"` (a real,
-- existing GLOBAL day/night state -- outdoor-only, `DayNight.lua`
-- itself leaves indoor maps untinted regardless of this setting).
-- Lavender Town's real music (`Horde.SONG = "Music_Lavender"`) plays
-- via `Music.play(data, song, loop, ctx)`, which overwrites the
-- engine's single "currently playing track" slot directly, bypassing
-- the normal per-map music pointer (`state.mapSong`) entirely. Both
-- are GLOBAL, not per-map, state -- exactly why they need an explicit
-- restore on invasion end rather than reverting on their own.
--
-- One real difference from Horde's own version: `Horde.finish`
-- restores the day/night setting explicitly but leaves music to the
-- warp-back-to-the-saved-map it always performs (the engine's own
-- normal map-load path calls `Music.playMap`, restoring the real map
-- theme as a side effect of that warp). This event never warps the
-- player anywhere -- they stay on the same town map throughout -- so
-- there's no warp to piggyback on; `endNightAndMusic` below calls
-- `Music.playMap` itself, but ONLY when a real `ow` (the invaded map
-- still active) is passed in -- if the invasion was cancelled because
-- the player already left that map (`DoomTownInvasion.tick`'s own
-- "left before cleared" branch), the engine's own normal map-load path
-- has already set the correct music for wherever they actually are,
-- and forcibly restoring the OLD town's theme here would incorrectly
-- override it.
local savedDayIndex, savedDayClock = nil, nil

local function startNightAndMusic()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game) then return end
  local okRead, dayIndex = pcall(function() return DayNight.setting:read() end)
  savedDayIndex = okRead and dayIndex or nil
  savedDayClock = DayNight.clock
  local nightIndex = 3
  local okValues, values = pcall(function() return DayNight.setting.values end)
  if okValues and values then
    for i, v in ipairs(values) do
      if v == "night" then nightIndex = i end
    end
  end
  pcall(function() DayNight.setting:setIndex(nightIndex, Game) end)
  pcall(function()
    require("src.core.Music").play(Game.data, "Music_Lavender", true, { reason = "pokedoom_invasion" })
  end)
end

local function endNightAndMusic(ow)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game) then return end
  if savedDayIndex then
    pcall(function() DayNight.setting:setIndex(savedDayIndex, Game) end)
  end
  if savedDayClock then DayNight.clock = savedDayClock end
  savedDayIndex, savedDayClock = nil, nil
  if ow and ow.map then
    pcall(function() require("src.core.Music").playMap(Game.data, ow.map.id) end)
  end
end

-- FIX 2026-08-08 (user report: "i got to 3 demons left then never saw
-- another demon") -- see `DoomDemons.lua`'s own `randomWalkablePointNear`
-- header comment for the full root cause (`spawnDemon`'s own default
-- placement picks a point ANYWHERE on the whole map, which a town-
-- sized map can easily turn into "behind a building the player never
-- walked near"). Every invasion demon now spawns within this many
-- cells of the PLAYER's own position at the moment the invasion
-- starts, converging around them instead of scattering across the
-- whole town -- a judgment call (this whole event has no DOOM
-- precedent), picked to keep every spawn within a short, findable walk
-- rather than literally on top of the player.
local INVASION_SPAWN_RADIUS = 12

local function beginInvasion(ow)
  local map = ow.map
  local count = math.random(DEMON_COUNT_MIN, DEMON_COUNT_MAX)
  local spawned = {}
  local px, py = ow.player and ow.player.cellX, ow.player and ow.player.cellY
  -- FIX 2026-08-09 -- Phase 26 lag audit: the player's own cell never
  -- changes across this loop (it's read once, above), so every one of
  -- the 5-9 `spawnDemonNear` calls below used to independently
  -- recompute an IDENTICAL bounded-but-real up-to-4000-cell reachability
  -- BFS from scratch -- confirmed, by two separate audit passes, as a
  -- genuine synchronous frame-time spike right at the moment an
  -- invasion begins (already a visually busy moment: NPCs starting to
  -- flee, demons starting to spawn). Computed ONCE here and threaded
  -- through every spawn call instead.
  local reachable = px and DoomDemons.reachableFromPlayer(ow)
  for _ = 1, count do
    -- FEATURE 2026-08-08 -- user's own explicit instruction: "the dynamic
    -- difficulty changes should apply to invasions too." `pickDemonName`
    -- (`lib/DoomDemons.lua`'s own header comment has the full derivation)
    -- gates by the player's real badge count -- an invasion on a fresh
    -- save only ever pulls Zombiemen/Shotgun Guys, same as ambient
    -- spawning, instead of the whole 10-demon roster uniformly.
    local name = DoomDemons.pickDemonName()
    local ok, m
    if px then
      ok, m = pcall(DoomDemons.spawnDemonNear, ow, name, px, py, INVASION_SPAWN_RADIUS, reachable)
    else
      ok, m = pcall(DoomDemons.spawnDemon, ow, name)
    end
    if ok and m then spawned[#spawned + 1] = { m = m } end
  end
  if #spawned == 0 then return end -- no walkable spawn point found -- don't start a 0-enemy "invasion"
  demonRefs = spawned
  totalCount = #demonRefs

  local fled = {}
  for _, npc in ipairs(ow.npcs or {}) do
    if not npc.pikachuFollower then
      local warp = nearestWarp(map, npc.cellX, npc.cellY)
      if warp then
        local entry = snapshotNpc(npc)
        entry.targetCx, entry.targetCy = warp.x, warp.y
        -- Resolved once, up front, at the target door -- not needed
        -- until the NPC actually reaches it (`hideNpc` below), but
        -- computed here so a warp that leads nowhere real (no
        -- `destMap`/`destWarp`, e.g. this "door" is actually a route
        -- exit) is known in advance rather than discovered mid-flee.
        local destMapId, destX, destY = warpDestination(warp)
        entry.destMapId, entry.destX, entry.destY = destMapId, destX, destY
        fled[#fled + 1] = entry
      end
    end
  end
  fledNpcs = fled

  active = true
  mapId = map.id
  pcall(startNightAndMusic)
end

-- ------- pre-invasion announcement
--
-- FEATURE 2026-08-10, user request: "make it so invasions have text
-- announcing them, for example when an invasion starts, before the
-- enemies spawn, the screen should flash back and forth between red
-- overlay, and nothing, then it should show 'Demons have invaded!',
-- while the red overlay and nothing are still flashing, then take text
-- and red flashing overlay should go away and it should go into normal
-- invasion gameplay." No DOOM precedent for this at all (this mod's own
-- addition, same category as Phase 23's own killfeed-on-death
-- addition) -- every timing number below is a flagged, adjustable
-- judgment call, not a derived fact.
--
-- "before the enemies spawn" -- `beginInvasion` itself (demon spawns,
-- NPCs fleeing, night+music) is deliberately NOT called until this
-- WHOLE announcement sequence finishes, rather than running underneath
-- it. `announceFlashOn`/`announceFlashTimer` are a plain state-driven
-- toggle (increment, flip past a threshold, reset to 0) rather than a
-- formula, per this project's own "avoid math-derived code" hard rule.
local ANNOUNCE_FLASH_ONLY_DURATION = 1.6 -- red/nothing flashing, no text yet
local ANNOUNCE_TEXT_DURATION = 1.8       -- text shown, flashing continues
local ANNOUNCE_TOTAL_DURATION = ANNOUNCE_FLASH_ONLY_DURATION + ANNOUNCE_TEXT_DURATION
local ANNOUNCE_FLASH_INTERVAL = 0.2      -- red/nothing toggle rate
local ANNOUNCE_TEXT = "DEMONS HAVE INVADED!"

local announcing = false
local announceTimer = 0
local announceOw = nil
local announceFlashOn = true
local announceFlashTimer = 0

local function startAnnouncement(ow)
  announcing = true
  announceTimer = 0
  announceOw = ow
  announceFlashOn = true
  announceFlashTimer = 0
end

local function cancelAnnouncement()
  announcing = false
  announceOw = nil
end

-- Mirrors `DoomTownInvasion.tick`'s own "left before cleared" cancel for
-- an already-active invasion: leaving the map mid-announcement just
-- cancels it outright -- nothing has been spawned or hidden yet, so
-- there's nothing to restore.
local function tickAnnouncement(ow, dt)
  if not (announceOw and ow.map.id == announceOw.map.id) then
    cancelAnnouncement()
    return
  end

  announceFlashTimer = announceFlashTimer + dt
  if announceFlashTimer >= ANNOUNCE_FLASH_INTERVAL then
    announceFlashTimer = announceFlashTimer - ANNOUNCE_FLASH_INTERVAL
    announceFlashOn = not announceFlashOn
  end

  announceTimer = announceTimer + dt
  if announceTimer >= ANNOUNCE_TOTAL_DURATION then
    local startOw = announceOw
    cancelAnnouncement()
    pcall(beginInvasion, startOw)
  end
end

-- ------- fleeing NPCs toward their target warp, then hiding them
--
-- FIX 2026-08-08 -- user report: "the pokemon npcs pathing to doors is
-- a little dumb. sometimes they have trouble finding their way to
-- doors or get stuck in corners. the pokemon npc is stuck going back
-- and forth between 2 cells." Root cause: this function is a pure
-- greedy step -- pick whichever of the 2 axis-aligned directions
-- closes the most distance, walk it if free, otherwise try the other
-- axis -- with NO memory of where it just came from. Near a corner
-- that blocks the preferred axis, the fallback axis can lead to a cell
-- whose OWN preferred axis (recomputed fresh next tick, since it's now
-- closer on one axis than the other) points straight back the way it
-- came, and since that reverse step is just as "free" as any other,
-- nothing stops it from taking it -- a genuine 2-cell loop, forever.
-- `avoidCx`/`avoidCy` (the cell this NPC was AT before its current
-- one, tracked by `tickFleeingNpcs` below) breaks that: a first pass
-- refuses any step that lands back on that cell, and only falls
-- through to a second, unrestricted pass (so a genuine one-way dead
-- end still lets the NPC move rather than freezing outright) if
-- neither direction survives the first.
local function stepNpcToward(ow, npc, targetCx, targetCy, avoidCx, avoidCy)
  if npc.moving then return end
  local dx = targetCx - npc.cellX
  local dy = targetCy - npc.cellY
  if dx == 0 and dy == 0 then return end
  local dirs = {}
  if math.abs(dx) >= math.abs(dy) then
    dirs[1] = { dx >= 0 and 1 or -1, 0 }
    dirs[2] = { 0, dy >= 0 and 1 or -1 }
  else
    dirs[1] = { 0, dy >= 0 and 1 or -1 }
    dirs[2] = { dx >= 0 and 1 or -1, 0 }
  end
  for _, avoidBacktrack in ipairs({ true, false }) do
    for _, d in ipairs(dirs) do
      if d[1] ~= 0 or d[2] ~= 0 then
        local tx, ty = npc.cellX + d[1], npc.cellY + d[2]
        local isBacktrack = avoidCx and tx == avoidCx and ty == avoidCy
        if not (avoidBacktrack and isBacktrack) then
          local ok, walkable = pcall(function() return ow.map:isWalkableCell(tx, ty) end)
          if ok and walkable then
            npc.facing = (d[1] == 1 and "right") or (d[1] == -1 and "left")
                      or (d[2] == 1 and "down") or "up"
            npc.targetX, npc.targetY = tx, ty
            npc.moving = true
            npc.progress = 0
            return
          end
        end
      end
    end
  end
end

-- Removes the NPC from the town map it's fleeing, then -- if this
-- entry's own door resolved to a real destination (see `warpDestination`
-- above) -- actually spawns it on that interior map via `V.mod.world`,
-- so it's really there the moment the player walks in, not just an
-- illusion in the town's own 3D space. `npc.def` is the NPC's own real,
-- original `objDef` (`NPC.lua`'s own `NPC.new`: `self.def = objDef`,
-- confirmed by direct read) -- reused directly for `sprite`/`range`/
-- `name` rather than guessing at what a faithful copy needs. Left
-- stationary inside (no `movement` field set) rather than wandering --
-- once safely sheltered, there's no reason for it to roam the
-- interior. Falls back to the original same-map hide (no interior
-- copy) if the door didn't resolve to a real destination -- a route
-- exit or similar "warp" that isn't actually a building door.
local function hideNpc(ow, entry)
  if entry.hidden then return end
  entry.hidden = true
  for i, n in ipairs(ow.npcs or {}) do
    if n == entry.npc then table.remove(ow.npcs, i) break end
  end
  for i, e in ipairs(ow.entities or {}) do
    if e == entry.npc then table.remove(ow.entities, i) break end
  end
  if entry.destMapId and entry.destX and entry.destY then
    local objDef = {
      sprite = entry.npc.def and entry.npc.def.sprite,
      x = entry.destX, y = entry.destY,
      range = entry.npc.def and entry.npc.def.range,
      name = entry.npc.def and entry.npc.def.name,
    }
    local ok, npcId = pcall(function() return V.mod.world:spawnNpc(entry.destMapId, objDef) end)
    if ok and npcId then entry.spawnedId = npcId end
  end
end

local function restoreNpc(ow, entry)
  if not entry.hidden then return end
  entry.hidden = false
  if entry.spawnedId then
    pcall(function() V.mod.world:removeNpc(entry.spawnedId) end)
    entry.spawnedId = nil
  end
  local npc = entry.npc
  npc.cellX, npc.cellY = entry.homeCx, entry.homeCy
  npc.px, npc.py = entry.homePx, entry.homePy
  npc.facing = entry.homeFacing
  npc.moving = false
  local already = false
  for _, n in ipairs(ow.npcs or {}) do if n == npc then already = true break end end
  if not already then
    table.insert(ow.npcs, npc)
    table.insert(ow.entities, npc)
  end
end

-- `entry.avoidCx/avoidCy` -- the cell this NPC was leaving as of its
-- own last completed step -- is what `stepNpcToward` above uses to
-- refuse an immediate reversal. Only updated when a fresh step
-- decision is actually being made (`not npc.moving`): `npc.cellX/cellY`
-- stay pinned to the OLD cell for the whole walk animation (the same
-- `.moving`/`.progress`-driven convention `stepCitizenFlee` already
-- established elsewhere in this mod), only advancing to the new one
-- once it resolves -- reading them right here, right after the step
-- call, captures exactly "the cell being left" for next tick's own
-- backtrack check.
local function tickFleeingNpcs(ow)
  for _, entry in ipairs(fledNpcs) do
    if not entry.hidden then
      local npc = entry.npc
      if npc.cellX == entry.targetCx and npc.cellY == entry.targetCy and not npc.moving then
        hideNpc(ow, entry)
      elseif not npc.moving then
        pcall(stepNpcToward, ow, npc, entry.targetCx, entry.targetCy, entry.avoidCx, entry.avoidCy)
        entry.avoidCx, entry.avoidCy = npc.cellX, npc.cellY
      end
    end
  end
end

-- `stillOnMap`=false (the "left before cleared" cancel path,
-- `DoomTownInvasion.tick`'s own caller passes `ow=nil` there): the
-- town's own ORIGINAL npcs need no explicit restore at all -- `setMap`
-- rebuilds a map's own `ow.npcs` fresh from its real, PERSISTENT
-- `def.objects` every single entry (confirmed by reading
-- `OverworldController.lua` directly), never reusing a held runtime
-- reference, and this file never touched that persistent data for the
-- ORIGINAL npcs (only the live, in-memory session copy, which simply
-- stops mattering the moment the player leaves). The one thing that
-- DOES need cleanup regardless of whether the player is still there:
-- any INTERIOR copy this file itself created via `V.mod.world:
-- spawnNpc` -- that call appended to `Game.data.maps[destMapId].
-- objects`, real persistent data, which would otherwise linger there
-- forever (a duplicated, orphaned NPC) the next time that building is
-- entered. `removeNpc` works against that same persistent table
-- regardless of which map is currently loaded, so this cleanup runs
-- unconditionally.
local function endInvasion(ow)
  local stillOnMap = ow and ow.map and ow.map.id == mapId
  for _, entry in ipairs(fledNpcs) do
    if stillOnMap then
      pcall(restoreNpc, ow, entry)
    elseif entry.spawnedId then
      pcall(function() V.mod.world:removeNpc(entry.spawnedId) end)
    end
  end
  pcall(endNightAndMusic, stillOnMap and ow or nil)
  active = false
  mapId = nil
  demonRefs = {}
  fledNpcs = {}
  totalCount = 0
  cooldownRemaining = randomCooldown()
end
DoomTownInvasion.endInvasion = endInvasion

-- FIX 2026-08-08 (user report: "the demon counter doesnt go down as i
-- kill them"). Root cause: `m.pokedoomDead` (`lib/DoomDemons.lua`'s
-- `tickDeath`) is ONLY ever set for Lost Soul, the one real demon
-- whose own death animation fully VANISHES (`m.deathVanishes`, DOOM's
-- real `S_SKULL_DIE6` -> `S_NULL`) -- every other demon here freezes
-- forever on its own real last death frame as a permanent corpse (real
-- DOOM's own actual behavior) and NEVER sets that field, so this
-- counter never saw them as dead at all, no matter how many were
-- actually killed. The real, general "no longer a threat" signal is
-- `m.state == "dying"` -- set exactly once, in `startDeath`
-- (`DoomDemons.lua:2988`), the instant a kill happens, and never
-- reverted for the rest of that demon's existence, regardless of
-- whether its corpse later freezes or vanishes.
local function remainingCount()
  local n = 0
  for _, ref in ipairs(demonRefs) do
    if ref.m.state ~= "dying" then n = n + 1 end
  end
  return n
end

-- ------- tick -- called from a gated `input.step` wrap (see `install`
-- below), matching every other always-on demon system's own real
-- pause-respecting shape (`lib/DoomDemons.lua`'s own equivalent).
function DoomTownInvasion.tick(ow, dt)
  if not (ow and ow.map) then return end
  if announcing then
    tickAnnouncement(ow, dt)
    return
  end
  if active then
    if ow.map.id ~= mapId then
      endInvasion(nil) -- left before it was cleared -- see header comment
      return
    end
    tickFleeingNpcs(ow)
    if remainingCount() <= 0 then
      endInvasion(ow)
    end
    return
  end

  if cooldownRemaining > 0 then
    cooldownRemaining = cooldownRemaining - dt
    return
  end

  checkTimer = checkTimer - dt
  if checkTimer > 0 then return end
  checkTimer = CHECK_INTERVAL

  -- FEATURE 2026-08-10 -- new "TOWN INVASIONS" on/off row -- only gates
  -- the AMBIENT/random trigger here, matching this project's own
  -- established precedent for a debug spawn tool vs. its corresponding
  -- feature toggle (`lib/DoomDemons.lua`'s own SPAWN ENEMY row stays
  -- usable with DEMONS off, Phase 21 Round 4) -- the debug START
  -- INVASION row below is deliberately NOT gated by this, so it still
  -- works for testing while the ambient event is turned off.
  if Options.townInvasionsEnabled()
     and isTownMap(ow.map) and math.random() < TRIGGER_CHANCE then
    pcall(startAnnouncement, ow)
  end
end

function DoomTownInvasion.isActive()
  return active
end

-- ------- debug row (user request, 2026-08-08: "add option in settings
-- to start town invasion, for debug purposes") -- a single `.activate`
-- row, not the two-row pick/confirm shape `lib/DoomDemons.lua`'s own
-- SPAWN ENEMY rows use, since there's only one real thing to trigger
-- here (which town, how many demons -- everything `beginInvasion`
-- itself already decides at random, same as the real scheduled event).
-- `value()` doubles as live debug feedback instead of a static "PRESS
-- A": "NOT IN TOWN" when the real event couldn't trigger here either,
-- "ACTIVE" while one's already running (this row no-ops rather than
-- stacking a second invasion on top), "PRESS A" when it would actually
-- do something -- more useful for testing than a fixed label.
function DoomTownInvasion.debugStartRow()
  return {
    id = "pokedoom_debug_start_invasion",
    label = "START INVASION",
    value = function()
      if active then return "ACTIVE" end
      if announcing then return "ANNOUNCING" end
      local ok, ow = pcall(function() return require("src.core.Game").overworld end)
      if ok and ow and ow.map and isTownMap(ow.map) then return "PRESS A" end
      return "NOT IN TOWN"
    end,
    activate = function(game)
      if active or announcing then return end
      local ok, ow = pcall(function() return require("src.core.Game").overworld end)
      if not (ok and ow and ow.map and isTownMap(ow.map)) then return end
      pcall(startAnnouncement, ow)
    end,
  }
end

-- ------- HUD -- see this file's own header comment for why this is a
-- fresh small counter rather than Horde's own SCORE/WAVE readout.
-- Positioned top-CENTER: `lib/DoomHud.lua`'s pickup message/killfeed
-- both live top-LEFT (`HU_MSGX,Y=0,0`), and `lib/DoomHordeControl.lua`'s
-- own SCORE/WAVE lives top-RIGHT -- centered avoids both without
-- needing to coordinate margins with either.
-- Shared with `lib/DoomMenuSkin.lua`'s own identical transform -- see
-- `lib/DoomVirtualCanvas.lua`'s own header for the full derivation.
local virtualScaleAndOffset = DoomVirtualCanvas.centered

local COUNTER_Y = 8

-- FIX 2026-08-08 (user report: "the demons remaining should be
-- attached to in game hud just like every other hud element. as of
-- now if i press pause, its still there, if i quit the game to main
-- menu, its still there"). This only ever checked `active` (whether an
-- invasion is running) -- but that's session state, not "is the
-- overworld actually the thing on screen right now." Every other real
-- HUD element in this mod (`lib/DoomHud.lua`'s own status bar) gates
-- its own visibility on `FirstPerson.driving()` (`Options.enabled()
-- and FirstPerson.driving()`, that file's own real check), not just
-- whatever its own feature toggle is -- `driving()` is `engaged() and
-- onTop()`: `onTop()` alone (already used to GATE the tick above, so
-- an invasion genuinely freezes rather than tearing down while paused)
-- is true even at the title screen with no save loaded at all, since
-- there's no menu covering a first-person camera that was never
-- engaged in the first place; `engaged()` is the piece that actually
-- requires the free-roam first-person camera to be the real active
-- rung, which a pause menu OR the title/main menu both fail.
local function drawCounter()
  if not (active and Options.enabled() and FirstPerson.driving()) then return end
  local text = ("DEMONS REMAINING: %d"):format(remainingCount())
  local w = DoomFont.measure(text)
  local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
  local scale, vox, voy = virtualScaleAndOffset(ww, wh)
  love.graphics.push()
  love.graphics.translate(vox, voy)
  love.graphics.scale(scale, scale)
  DoomFont.draw(text, (VIRTUAL_W - w) / 2, COUNTER_Y)
  love.graphics.pop()
  love.graphics.setColor(1, 1, 1, 1)
end

-- Same `Options.enabled() and FirstPerson.driving()` gate as `drawCounter`
-- above, so the flash/text freeze (and stop drawing) exactly like every
-- other HUD element here while paused/off. The red flash is a real
-- fullscreen overlay (raw `love.graphics.getWidth/Height`), NOT run
-- through the virtual-canvas transform `drawCounter`/the text below use --
-- a screen-space flash reads as "the whole view," where a virtual-canvas
-- one would leave real letterbox bars outside it untouched on non-4:3
-- windows. The text itself DOES use the virtual canvas + `DoomFont`,
-- matching every other DOOM-native text overlay in this mod.
local function drawAnnouncement()
  if not (announcing and Options.enabled() and FirstPerson.driving()) then return end
  local ww, wh = love.graphics.getWidth(), love.graphics.getHeight()
  if announceFlashOn then
    love.graphics.setColor(1, 0, 0, 0.35)
    love.graphics.rectangle("fill", 0, 0, ww, wh)
    love.graphics.setColor(1, 1, 1, 1)
  end
  if announceTimer >= ANNOUNCE_FLASH_ONLY_DURATION then
    local text = ANNOUNCE_TEXT
    local w = DoomFont.measure(text)
    local scale, vox, voy = virtualScaleAndOffset(ww, wh)
    love.graphics.push()
    love.graphics.translate(vox, voy)
    love.graphics.scale(scale, scale)
    DoomFont.draw(text, (VIRTUAL_W - w) / 2, (VIRTUAL_H - 8) / 2)
    love.graphics.pop()
    love.graphics.setColor(1, 1, 1, 1)
  end
end

-- ------- install
local installed = false
function DoomTownInvasion.install()
  if installed then return end
  installed = true

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    if ok and ow and Options.enabled() and Options.demonsEnabled() and FirstPerson.onTop() then
      pcall(DoomTownInvasion.tick, ow, dt)
    end
    return next(game, dt)
  end)

  -- A fresh map/save load has no business resuming a stale invasion
  -- against NPCs that no longer correspond to what's actually on
  -- screen -- same real event, same reasoning `lib/DoomKill.lua`'s own
  -- `resetGibs` already uses `V.mod.events:on("save.loaded"/"save.
  -- created", ...)` for (that file's own real, confirmed call site).
  -- BUG FIX 2026-08-12 -- `endInvasion`'s own header comment above
  -- documents a real leak this reset path shared but never actually
  -- closed: an interior duplicate NPC `hideNpc` spawned via `V.mod.world:
  -- spawnNpc` is real, persistent data (`Game.data.maps[destMapId].
  -- objects`), not session-only state -- a save load/new game mid-
  -- invasion used to just blank `fledNpcs` here without ever calling
  -- `removeNpc` on any already-hidden entry's own `spawnedId`, orphaning
  -- that duplicate NPC in the destination map's own persistent object
  -- list forever (it would show up a second time the next time that
  -- building is entered). `endInvasion` already has this exact cleanup
  -- for its own "left before cleared" path (`stillOnMap == false`) --
  -- restated here for the save-load/new-game path, which never routed
  -- through `endInvasion` at all.
  local function resetInvasionState()
    for _, entry in ipairs(fledNpcs) do
      if entry.spawnedId then
        pcall(function() V.mod.world:removeNpc(entry.spawnedId) end)
      end
    end
    active = false
    announcing = false
    announceOw = nil
    mapId = nil
    demonRefs = {}
    fledNpcs = {}
    totalCount = 0
  end
  V.mod.events:on("save.loaded", resetInvasionState)
  V.mod.events:on("save.created", resetInvasionState)

  local innerDraw = love.draw
  love.draw = function(...)
    if innerDraw then innerDraw(...) end
    if not Options.enabled() then return end
    pcall(drawCounter)
    pcall(drawAnnouncement)
  end
end

return DoomTownInvasion
