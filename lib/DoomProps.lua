-- PokeDoom: real DOOM decorative "thing" objects (`info.c`'s MT_MISC*
-- range, excluding pickups/keys/powerups already ported in `lib/
-- DoomItems.lua` and the exploding barrel already ported in `lib/
-- DoomBarrels.lua`) as MANUALLY-placed map objects. Direct user request,
-- 2026-08-10, following a brainstormed list of DOOM decorative objects:
--
-- "add all objects listed above as objects in the game. do not
-- implement any randomized spawning like barrels
-- add a menu when you press q to spawn an object where the player is
-- standing and save the positions to a new file after added, so they
-- persist over saves and can be added to the coded fully later. have
-- images of all the objects next to them in the menu so i can tell what
-- im spawning"
--
-- Deliberately NOT the barrel's own random-scatter model: every
-- placement here is a single, deliberate player action (press Q, pick a
-- prop from the menu, press A to drop it at the player's own current
-- cell) -- matching the explicit "do not implement any randomized
-- spawning like barrels" instruction.
--
-- REMOVED 2026-08-19, direct user request: "remove the texture editing
-- and any references to it in code because it seems like the way i want
-- it implemented isnt possible." This file used to ALSO let the player
-- retexture an individual placed prop, or reskin a whole map's tileset,
-- with a real DOOM wall/flat texture picked from `lib/DoomTextures.lua`
-- (a real, working feature -- both halves shipped and were confirmed
-- functional -- removed because it didn't match what the user actually
-- wanted from it, not because of a bug). `lib/DoomTextures.lua` itself
-- is deleted -- this file was its only real consumer. The TEXTURES tab,
-- "This Area" whole-tileset target, per-prop `textureOverride`, and the
-- placements file's own optional texture columns are all gone with it;
-- this menu is object placement/selection/delete only again.
--
-- ------- real DOOM data, read fresh from `info.c`'s own MT_MISC*
-- entries this round (never trusted from memory/wiki -- CLAUDE.md's own
-- hard rule)
--
-- Every entry in `PROPS` below cites its real DoomEd number (the map
-- editor's own stable "thing" number -- the only real, citable identity
-- DOOM itself gives these), its real sprite lump prefix, and whether
-- it's really `MF_SOLID` in real DOOM (used for this entity's own
-- `passable` field). `frames`/`tics` are the real per-object animation
-- data from the same source (most are a single static frame; torches/
-- lamps are real 4-frame loops, `GOR1`/`POL6` have real non-uniform
-- per-frame tic counts, kept as an explicit per-frame array rather than
-- forcing them to the common flat-tics shape).
--
-- Every new sprite prefix below is added to `lib/DoomDemons.lua`'s own
-- `NON_DEMON_PREFIXES` table (see that file's own matching edit) so
-- every one of these props shares the SAME already-calibrated
-- Zombieman-ratio scale every other real-object-sized sprite in this
-- project uses -- NEVER an independently-guessed fixed height. This is
-- the exact bug class CLAUDE.md's own sprite-scale hard rule names
-- (a fresh guess per new sprite type instead of reusing the proven
-- shared ratio) -- direct instruction from the user this round: "make
-- sure to remember all the entity size bugs when implementing all these
-- new objects."
--
-- REMOVED 2026-08-19, direct user request after playtesting found real
-- roster entries placing down invisible-but-solid ("many items in the
-- object menu just dont have textures, but can be placed down with
-- collision. either find the textures for these or remove them if they
-- dont have any"): `HDB1-6`, `POB1`, `POB2`, `BRS1`, `TLMP`, `TLP2` are
-- all genuinely real `info.c` MT_MISC* things (not a naming bug in this
-- roster -- confirmed by reading `info.c`'s own `SPR_HDB1`/`SPR_POB1`/
-- `SPR_POB2`/`SPR_BRS1`/`SPR_TLMP`/`SPR_TLP2` state entries directly),
-- but were added to DOOM in the later Ultimate Doom (4-episode) content
-- update -- confirmed absent from the SPECIFIC `doom.wad` this project
-- has actually been testing against (a byte-level lump-directory check
-- found no `HDB1A0`/`TLMPA0`/etc anywhere in it, and that WAD's own real
-- `E#M#` map markers only go up to E3, the older 3-episode registered
-- release, never Episode 4). A player with a genuine Ultimate Doom/
-- Doom II/Final Doom WAD likely DOES have these sprites, but per the
-- user's own explicit instruction this round, removed outright rather
-- than left in with no graceful-degradation handling.
--
-- Two real, honest simplifications, flagged rather than silently
-- assumed:
-- 1. **Hanging gore** (`GOR1-5`) is real DOOM
--    `MF_SPAWNCEILING|MF_NOGRAVITY` -- genuinely ceiling-mounted in the
--    original game. This project's whole fake-entity render pipeline
--    (gibs, items, barrels, demons, these props) is ground-anchored
--    only -- no file anywhere establishes a ceiling-anchor draw path.
--    Placed at GROUND level here instead, a stated visual
--    simplification, not an attempt at literal ceiling placement.
-- 2. **Dead Lost Soul** (`SKUL` frame K) is a real, well-known DOOM
--    quirk: its own death state (`S_SKULL_DIE6`, `info.c`) holds for
--    only 6 tics before transitioning to `S_NULL` (vanishing), unlike
--    every OTHER corpse decoration here (`-1` tics, holds forever) --
--    included anyway, since the user asked for every object on the
--    brainstormed list and this genuinely is a real, if short-lived,
--    placeable DOOM thing; it removes itself a few seconds after being
--    placed, matching real DOOM's own actual behavior exactly.
--
-- `fullbright` is recorded on each entry (DOOM's own real frame-number
-- high bit, `32768`, meaning the sprite always renders at full
-- brightness regardless of sector light) for the record -- this mod's
-- existing render pipeline has no established per-entity brightness
-- override, so it isn't acted on here, only cited for a future round.
--
-- ------- persistence: a real external file, NOT `Game.save`
--
-- Direct user request: "save the positions to a new file after added,
-- so they persist over saves and can be added to the coded fully
-- later." Every other fake-entity system in this project (barrels,
-- items) persists inside `Game.save`, tied to one specific save slot --
-- deliberately NOT reused here, since the user wants placements to
-- survive independently of which save is loaded, in a form they can
-- read and hand-copy into permanent level code later. Written as a
-- plain, human-readable line-based file (`mapId,cx,cy,propId` per
-- line -- trivially both append-only, avoiding any read-modify-write
-- risk, and easy to eyeball/copy by hand), using the exact same
-- dual-attempt strategy `lib/DoomLog.lua` already proved out (a real
-- file inside this mod's own folder first, LOVE's own sandboxed save
-- directory as a fallback) -- restated here rather than shared, since
-- that file's own machinery is single-purpose (one timestamped file per
-- session, write-only) where this needs one STABLE, growing,
-- also-readable-at-startup file.

local V = ...
local Host = V.host
local FirstPerson = Host.require("FirstPerson")
local DoomWadImport = V.require("DoomWadImport")
local Options = V.require("DoomOptions")
local DoomGround = V.require("DoomGround")
local DoomLog = V.require("DoomLog")

-- Lazy -- `DoomDemons` transitively requires several files that (per
-- this project's own established cycle-check discipline) may not have
-- finished loading yet at THIS file's own load time; called at USE time
-- only, matching `lib/DoomBarrels.lua`'s own `getDoomWeapons`/`lib/
-- DoomItems.lua`'s own `getDoomDemons`.
local DoomDemons
local function getDoomDemons()
  DoomDemons = DoomDemons or V.require("DoomDemons")
  return DoomDemons
end

local DoomProps = {}

local DOOM_TIC_SECONDS = 1 / 35

-- ------- the real DOOM prop roster (see this file's own header comment
-- for the full citation/methodology). `frames` is always a list of
-- letters; `tics` is either one flat number (applied to every frame) or
-- a list matching `frames` 1:1 for the two real non-uniform cases.
DoomProps.PROPS = {
  -- ---- obstacles / cover (MF_SOLID)
  { id = "ELEC", name = "Tech Pillar", category = "Obstacle", sprite = "ELEC", doomednum = 48, solid = true, frames = { "A" } },
  { id = "COL1", name = "Tall Green Pillar", category = "Obstacle", sprite = "COL1", doomednum = 30, solid = true, frames = { "A" } },
  { id = "COL2", name = "Short Green Pillar", category = "Obstacle", sprite = "COL2", doomednum = 31, solid = true, frames = { "A" } },
  { id = "COL3", name = "Tall Red Pillar", category = "Obstacle", sprite = "COL3", doomednum = 32, solid = true, frames = { "A" } },
  { id = "COL4", name = "Short Red Pillar", category = "Obstacle", sprite = "COL4", doomednum = 33, solid = true, frames = { "A" } },
  { id = "COL6", name = "Skull Pillar", category = "Obstacle", sprite = "COL6", doomednum = 37, solid = true, frames = { "A" } },
  { id = "SMIT", name = "Stalagmite", category = "Obstacle", sprite = "SMIT", doomednum = 47, solid = true, frames = { "A" } },
  { id = "TRE1", name = "Burnt Tree", category = "Obstacle", sprite = "TRE1", doomednum = 43, solid = true, frames = { "A" } },
  { id = "TRE2", name = "Large Tree", category = "Obstacle", sprite = "TRE2", doomednum = 54, solid = true, frames = { "A" } },
  { id = "FCAN", name = "Burning Barrel", category = "Obstacle", sprite = "FCAN", doomednum = 70, solid = true,
    frames = { "A", "B", "C" }, tics = 4, fullbright = true },

  -- ---- corpses (non-solid unless noted -- real DOOM flags=0 for these)
  { id = "DEADCACO", name = "Dead Cacodemon", category = "Corpse", sprite = "HEAD", doomednum = 22, solid = false, frames = { "L" } },
  { id = "DEADMARINE", name = "Dead Marine", category = "Corpse", sprite = "PLAY", doomednum = 15, solid = false, frames = { "N" } },
  { id = "DEADZOMBIE", name = "Dead Zombieman", category = "Corpse", sprite = "POSS", doomednum = 18, solid = false, frames = { "L" } },
  { id = "DEADDEMON", name = "Dead Demon", category = "Corpse", sprite = "SARG", doomednum = 21, solid = false, frames = { "N" } },
  { id = "DEADSOUL", name = "Dead Lost Soul", category = "Corpse", sprite = "SKUL", doomednum = 23, solid = false,
    frames = { "K" }, vanishTics = 6 }, -- real S_SKULL_DIE6 quirk, see header comment
  { id = "DEADIMP", name = "Dead Imp", category = "Corpse", sprite = "TROO", doomednum = 20, solid = false, frames = { "M" } },
  { id = "DEADSHOTGUY", name = "Dead Shotgun Guy", category = "Corpse", sprite = "SPOS", doomednum = 19, solid = false, frames = { "L" } },
  { id = "BLOODYMESS1", name = "Bloody Mess", category = "Corpse", sprite = "PLAY", doomednum = 10, solid = false, frames = { "W" } },
  { id = "BLOODYMESS2", name = "Bloody Mess 2", category = "Corpse", sprite = "PLAY", doomednum = 12, solid = false, frames = { "W" } },

  -- ---- pole / stick decorations (mixed solidity, matching real flags)
  { id = "POL1", name = "Dead Stick", category = "Pole", sprite = "POL1", doomednum = 25, solid = true, frames = { "A" } },
  { id = "POL2", name = "Heads on a Stick", category = "Pole", sprite = "POL2", doomednum = 28, solid = true, frames = { "A" } },
  { id = "POL3", name = "Head with Candles", category = "Pole", sprite = "POL3", doomednum = 29, solid = true,
    frames = { "A", "B" }, tics = 6, fullbright = true },
  { id = "POL4", name = "Head on a Stick", category = "Pole", sprite = "POL4", doomednum = 27, solid = true, frames = { "A" } },
  { id = "POL5", name = "Pile of Gibs", category = "Pole", sprite = "POL5", doomednum = 24, solid = false, frames = { "A" } },
  { id = "POL6", name = "Twitching Impaled Body", category = "Pole", sprite = "POL6", doomednum = 26, solid = true,
    frames = { "A", "B" }, tics = { 6, 8 } },

  -- ---- hanging gore (real DOOM: ceiling-mounted; placed at ground
  -- level here, see header comment)
  { id = "GOR1", name = "Hanging Victim, Twitching", category = "Hanging", sprite = "GOR1", doomednum = 49, solid = true,
    frames = { "A", "B", "C", "B" }, tics = { 10, 15, 8, 6 } },
  { id = "GOR2", name = "Hanging Pair of Legs", category = "Hanging", sprite = "GOR2", doomednum = 50, solid = true, frames = { "A" } },
  { id = "GOR3", name = "Hanging Victim, 1-Legged", category = "Hanging", sprite = "GOR3", doomednum = 51, solid = true, frames = { "A" } },
  { id = "GOR4", name = "Hanging Leg", category = "Hanging", sprite = "GOR4", doomednum = 52, solid = true, frames = { "A" } },
  { id = "GOR5", name = "Hanging Victim, Guts Removed", category = "Hanging", sprite = "GOR5", doomednum = 53, solid = true, frames = { "A" } },

  -- ---- light sources
  { id = "CAND", name = "Candle", category = "Light", sprite = "CAND", doomednum = 34, solid = false, frames = { "A" }, fullbright = true },
  { id = "CBRA", name = "Candelabra", category = "Light", sprite = "CBRA", doomednum = 35, solid = true, frames = { "A" }, fullbright = true },
  { id = "COLU", name = "Floor Lamp", category = "Light", sprite = "COLU", doomednum = 2028, solid = true, frames = { "A" }, fullbright = true },
  { id = "TBLU", name = "Tall Blue Torch", category = "Light", sprite = "TBLU", doomednum = 44, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
  { id = "TGRN", name = "Tall Green Torch", category = "Light", sprite = "TGRN", doomednum = 45, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
  { id = "TRED", name = "Tall Red Torch", category = "Light", sprite = "TRED", doomednum = 46, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
  { id = "SMBT", name = "Short Blue Torch", category = "Light", sprite = "SMBT", doomednum = 55, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
  { id = "SMGT", name = "Short Green Torch", category = "Light", sprite = "SMGT", doomednum = 56, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
  { id = "SMRT", name = "Short Red Torch", category = "Light", sprite = "SMRT", doomednum = 57, solid = true,
    frames = { "A", "B", "C", "D" }, tics = 4, fullbright = true },
}

local PROPS_BY_ID = {}
for _, p in ipairs(DoomProps.PROPS) do PROPS_BY_ID[p.id] = p end

local function ticsFor(prop, frameIndex)
  if type(prop.tics) == "table" then return prop.tics[frameIndex] or prop.tics[1] or 6 end
  return prop.tics or 0 -- 0/nil real DOOM tics == -1 (static, never advances)
end

local function groundY(ow, cx, cy)
  return DoomGround.heightAt(ow.map, cx, cy)
end

-- ------- persistence: a real, stable, append-only external file
--
-- Mirrors `lib/DoomLog.lua`'s own dual-attempt strategy (a real file in
-- this mod's own folder first, LOVE's sandboxed save directory as a
-- fallback) but for ONE stable, growing file rather than one per
-- session, and readable back at startup (`DoomLog.lua` is write-only).
local PLACEMENTS_FILENAME = "pokedoom-prop-placements.txt"
local placementsDir = "props"

local function realFolderPath()
  local dir = DoomWadImport.absoluteModPath(placementsDir)
  if not dir then return nil end
  local ok = pcall(DoomWadImport.ensureDir, dir)
  if not ok then return nil end
  return dir .. "/" .. PLACEMENTS_FILENAME
end

local function readPlacementsFile()
  local lines = {}
  local realPath = realFolderPath()
  if realPath then
    local fp = io.open(realPath, "r")
    if fp then
      for line in fp:lines() do lines[#lines + 1] = line end
      fp:close()
      return lines, realPath
    end
  end
  local okDir = pcall(love.filesystem.createDirectory, placementsDir)
  local rel = placementsDir .. "/" .. PLACEMENTS_FILENAME
  if okDir then
    local ok, contents = pcall(love.filesystem.read, rel)
    if ok and contents then
      for line in contents:gmatch("[^\r\n]+") do lines[#lines + 1] = line end
    end
  end
  return lines, rel
end

-- Shared write-fallback shape: real-folder attempt first, `love.
-- filesystem` second -- matching `lib/DoomLog.lua`'s own fallback order
-- and its own "report the real failure reason, don't silently swallow
-- it" discipline. Factored out 2026-08-19 during a project-wide
-- readability audit -- `appendPlacementLine`/`writeWholeFile` below used
-- to each independently implement this exact two-tier fallback,
-- differing only in the real `io.open` mode, the LÖVE-side write
-- function, and the content being written.
local function writeToPlacementsFile(mode, loveWriteFn, content)
  local realPath = realFolderPath()
  if realPath then
    local fp = io.open(realPath, mode)
    if fp then
      fp:write(content)
      fp:close()
      return true, realPath
    end
  end
  local okDir = pcall(love.filesystem.createDirectory, placementsDir)
  if okDir then
    local rel = placementsDir .. "/" .. PLACEMENTS_FILENAME
    local ok = pcall(loveWriteFn, rel, content)
    if ok then return true, rel end
  end
  return false, nil
end

-- Appends ONE line -- used ONLY for a brand new placement, where crash-
-- safety (write before the in-memory spawn even happens) matters most.
local function appendPlacementLine(line)
  return writeToPlacementsFile("a", love.filesystem.append, line .. "\n")
end

-- FEATURE 2026-08-10 -- user request: "selecting an object should let
-- you change the object or delete it." Editing/deleting an EXISTING
-- placement can't be a pure append (the OLD line has to stop existing)
-- -- writes the WHOLE current in-memory state fresh instead. Used only
-- on an edit/delete, not on every spawn, so this stays rare relative to
-- the append-only fast path above.
local function serializePlacementLine(mapKey, cx, cy, propId)
  return table.concat({ mapKey, tostring(cx), tostring(cy), propId }, ",")
end

local function writeWholeFile(lines)
  local body = table.concat(lines, "\n") .. (#lines > 0 and "\n" or "")
  return writeToPlacementsFile("w", love.filesystem.write, body)
end

-- In-memory placements, keyed by `tostring(mapId)` -> array of point
-- records `{cx, cy, propId}`. Loaded once from the
-- external file on `install()`. This table is the SOURCE OF TRUTH for
-- `rewritePlacementsFile` below -- every live instance's own entity
-- (`liveProps`, further down) keeps a direct reference to its own
-- record here (`inst.sourcePoint`) so an edit/delete on the live
-- instance mutates the SAME table this rewrite reads, with no separate
-- id-matching step needed.
local placementsByMap = {}
local placementsLoaded = false

local function rewritePlacementsFile()
  local lines = {}
  for mapKey, points in pairs(placementsByMap) do
    for _, pt in ipairs(points) do
      lines[#lines + 1] = serializePlacementLine(mapKey, pt.cx, pt.cy, pt.propId)
    end
  end
  local ok, path = writeWholeFile(lines)
  pcall(DoomLog.event, "PROPS", "rewrote placements file (%d line(s), saved=%s, %s)",
    #lines, tostring(ok), tostring(path))
  return ok
end

local function loadPlacementsOnce()
  if placementsLoaded then return end
  placementsLoaded = true
  local lines, path = readPlacementsFile()
  local loaded = 0
  for _, line in ipairs(lines) do
    -- FIX (caught before shipping, not user-reported): `%a+` (letters
    -- only) would silently fail to match a real number of this file's
    -- own prop ids -- `COL1`-`COL6`, `HDB1`-`HDB6`, `POL1`-`POL6`,
    -- `GOR1`-`GOR5`, `POB1`-`POB2`, `BRS1`, `TLP2`, `DEADCACO`... wait,
    -- `BLOODYMESS1`/`BLOODYMESS2` -- every id with a trailing digit,
    -- roughly a third of the whole roster. `%w+` (alphanumeric) is the
    -- correct pattern.
    local mapId, cx, cy, propId = line:match("^([^,]+),(%-?%d+),(%-?%d+),(%w+)$")
    if mapId and PROPS_BY_ID[propId] then
      local pt = { cx = tonumber(cx), cy = tonumber(cy), propId = propId }
      placementsByMap[mapId] = placementsByMap[mapId] or {}
      table.insert(placementsByMap[mapId], pt)
      loaded = loaded + 1
    end
  end
  pcall(DoomLog.event, "PROPS", "loaded %d placement(s) from %s", loaded, tostring(path))
end

-- ------- entity lifecycle -- the same shape every fake entity in this
-- project already proves out (`ow.entities`, `passable`, `:pose()`
-- returning a corner-anchored world position) -- restated here rather
-- than shared, matching this project's own established "restate small
-- pure-shape pieces per file" precedent.
local liveProps = {}
local nextPropInstanceId = 1

local function worldPos(cx, cy) return cx * 16, cy * 16 end

local function makePropEntity(inst)
  local prop = PROPS_BY_ID[inst.propId]
  local entity
  entity = {
    passable = not prop.solid,
    px = inst.px, py = inst.py, cellX = inst.cx, cellY = inst.cy,
    draw = function() end,
    pose = function()
      local letter = prop.frames[inst.animIndex] or prop.frames[1]
      local ok, image = pcall(getDoomDemons().loadSprite, prop.sprite, letter)
      local spriteObj = {
        def = {
          pokedoomDemon = true, pokedoomCacheKey = "prop-" .. prop.sprite .. letter,
          pokedoomSpritePrefix = prop.sprite,
          pokedoomImage = ok and image or nil, trueColor = true,
          image = "pokedoom-prop-" .. prop.sprite,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      return spriteObj, entity.px, entity.py, "down", 0, false
    end,
  }
  return entity
end

local function removePropEntity(ow, inst)
  inst.inserted = false
  if not (inst.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == inst.entity then table.remove(ow.entities, i) break end
  end
  inst.entity = nil
end

-- `sourcePoint` (optional) is the SAME table stored in `placementsByMap`
-- this instance came from -- kept as a live reference on the instance
-- so `changeInstanceProp`/`deleteInstance` (below) can mutate the
-- persisted record directly, no id-matching needed. Only spawns made
-- directly at the player (`placePropAtPlayer`) create a FRESH point and
-- pass it in; `syncPropsForMap` passes the already-loaded one back in
-- unchanged.
local function spawnPropInstance(ow, cx, cy, propId, sourcePoint)
  local px, py = worldPos(cx, cy)
  nextPropInstanceId = nextPropInstanceId + 1
  local inst = {
    id = nextPropInstanceId, mapId = ow.map.id, propId = propId,
    cx = cx, cy = cy, px = px, py = py,
    animIndex = 1, animTimer = 0, dead = false,
    sourcePoint = sourcePoint,
  }
  liveProps[#liveProps + 1] = inst
  return inst
end

local function syncPropsForMap(ow)
  loadPlacementsOnce()
  local mapKey = tostring(ow.map.id)
  local have = false
  for _, inst in ipairs(liveProps) do
    if inst.mapId == ow.map.id then have = true break end
  end
  if have then return end
  local points = placementsByMap[mapKey]
  if not points then return end
  for _, pt in ipairs(points) do
    spawnPropInstance(ow, pt.cx, pt.cy, pt.propId, pt)
  end
end

-- ------- edit/delete a placed instance -- user request, 2026-08-10:
-- "selecting an object should let you change the object or delete it."
-- All three mutate `inst.sourcePoint` directly (the SAME table
-- `placementsByMap` holds) then do a full rewrite -- see
-- `rewritePlacementsFile`'s own header comment for why a plain append
-- can't express "the old line stops existing."
local function changeInstanceProp(ow, inst, newPropId)
  if not (inst and PROPS_BY_ID[newPropId]) then return end
  inst.propId = newPropId
  inst.animIndex, inst.animTimer, inst.dead = 1, 0, false
  if inst.sourcePoint then
    inst.sourcePoint.propId = newPropId
  end
  removePropEntity(ow, inst)
  rewritePlacementsFile()
end

local function deleteInstance(ow, inst)
  if not inst then return end
  removePropEntity(ow, inst)
  inst.dead = true
  if inst.sourcePoint then
    local mapKey = tostring(inst.mapId)
    local points = placementsByMap[mapKey]
    if points then
      for i, pt in ipairs(points) do
        if pt == inst.sourcePoint then table.remove(points, i) break end
      end
    end
  end
  rewritePlacementsFile()
end

-- Real Lost Soul death (`S_SKULL_DIE6`) genuinely vanishes after 6 real
-- DOOM tics -- see this file's own header comment. Every OTHER prop
-- holds forever (`vanishTics` is nil for all of them), matching real
-- DOOM's own `-1` ("hold this state forever") for every other
-- decoration in this roster.
local function updateProp(ow, dt, inst)
  if inst.mapId ~= ow.map.id or inst.dead then return end
  local prop = PROPS_BY_ID[inst.propId]
  if prop.vanishTics then
    inst.animTimer = (inst.animTimer or 0) + dt
    if inst.animTimer >= prop.vanishTics * DOOM_TIC_SECONDS then
      removePropEntity(ow, inst)
      inst.dead = true
      return
    end
  elseif #prop.frames > 1 then
    inst.animTimer = (inst.animTimer or 0) + dt
    local holdSeconds = ticsFor(prop, inst.animIndex) * DOOM_TIC_SECONDS
    if holdSeconds > 0 and inst.animTimer >= holdSeconds then
      inst.animTimer = 0
      inst.animIndex = (inst.animIndex % #prop.frames) + 1
    end
  end
  if not inst.dead then
    inst.entity = inst.entity or makePropEntity(inst)
    inst.entity.px, inst.entity.py = inst.px, inst.py
    inst.entity.cellX, inst.entity.cellY = inst.cx, inst.cy
    if not inst.inserted then
      table.insert(ow.entities, inst.entity)
      inst.inserted = true
    end
  end
end

local lastPropEntitiesMapId = nil
local function tickProps(ow, dt)
  if ow.map.id ~= lastPropEntitiesMapId then
    for _, inst in ipairs(liveProps) do inst.inserted = false end
    lastPropEntitiesMapId = ow.map.id
    syncPropsForMap(ow)
  end
  for i = #liveProps, 1, -1 do
    local inst = liveProps[i]
    if inst.mapId ~= ow.map.id then
      removePropEntity(ow, inst)
    elseif inst.dead then
      removePropEntity(ow, inst)
      table.remove(liveProps, i)
    else
      updateProp(ow, dt, inst)
    end
  end
end

-- Called by the placement menu (below) on a real click. Writes the
-- placement to the external file FIRST (so a crash right after doesn't
-- lose it), then spawns it immediately on the current map, linked to
-- its own fresh `placementsByMap` record, so the player sees it appear
-- without a reload and it's editable/deletable from that point on.
local function placePropAtPlayer(ow, propId)
  if not (ow and ow.player and ow.map) then return nil end
  local cx, cy = ow.player.cellX, ow.player.cellY
  local mapKey = tostring(ow.map.id)
  local line = serializePlacementLine(mapKey, cx, cy, propId, nil)
  local ok, path = appendPlacementLine(line)
  pcall(DoomLog.event, "PROPS", "placed %s at map=%s cx=%d cy=%d (saved=%s, %s)",
    propId, mapKey, cx, cy, tostring(ok), tostring(path))
  placementsByMap[mapKey] = placementsByMap[mapKey] or {}
  local pt = { cx = cx, cy = cy, propId = propId }
  table.insert(placementsByMap[mapKey], pt)
  return spawnPropInstance(ow, cx, cy, propId, pt)
end

-- ------- the Q-key spawn overlay -- COMPLETE REDESIGN, 2026-08-10,
-- direct user request after the first version (a pushed `Screens`
-- screen, like every other menu in this mod) rendered as a blank white
-- screen and, separately, paused the whole game while open: "it
-- shouldnt use the pokemon menu, it should be a completely new compact
-- menu... does not stop your game, and does not stop any logic in the
-- game or any movement or anything. it should just be an overlay... it
-- should stop mouse movement for camera look though and let the player
-- use the mouse normally... i want it to act as the garrys mod c menu
-- kind of, where you can click on an object... and have it be
-- highlighted, that will be the selection." (The same request also
-- described a texture-retexturing half of this menu, built the same
-- round -- removed 2026-08-19, see this file's own header comment.)
--
-- Drawn via a `love.draw` wrap -- the SAME proven, real mechanism `lib/
-- DoomHud.lua`'s own status bar already uses (never `Screens.push`,
-- which owns the whole game loop while it's on top and is almost
-- certainly what produced the blank-white symptom) -- so the world,
-- every demon, every tick, keeps running untouched underneath.
--
-- Scope decision, stated plainly rather than guessed silently: "click on
-- an object... and have it be highlighted" is read here as clicking a
-- ROW in this overlay's own lists (which is what "highlighted" already
-- means for hover, per the user's own separate sentence about hover
-- color) -- NOT true screen-to-world mouse picking, which would need
-- camera-projection math this project has never built or verified
-- exists. Selecting an ALREADY-PLACED prop out in the world instead
-- reuses this mod's own established forward-ray targeting shape (the
-- same kind of hit-test every weapon/target resolver here already does)
-- -- whatever placed prop is near the center of the screen (the crosshair
-- the player already aims with for everything else in this mod) is the
-- current world target; clicking anywhere OUTSIDE the overlay's own
-- panel selects it. If this isn't what was meant, easy to revise --
-- flagged here rather than silently assumed correct.

local menuOpen = false
-- FIXED 2026-08-10 -- user report: "if i place and object down and then
-- move to a new location, the next object i place should be placed
-- where im standing, not replace my previous object." Root cause: once
-- placing an object set it as `selectedInstance` (so it could be
-- retextured right away with no extra aiming), that selection had no
-- expiry -- the VERY NEXT objects-list click, no matter how much later
-- or how far the player had since walked, still saw a non-dead
-- `selectedInstance` and took the CHANGE branch instead of PLACE. Fixed
-- by tying the selection to the player's own cell at the moment it was
-- made (`selectedAtCx`/`.Cy`) and clearing it the instant the player's
-- CURRENT cell no longer matches (`clearSelectionIfPlayerMoved`, called
-- from the `input.step` tick below) -- standing right next to what you
-- just placed (or aimed at) still lets you change/delete it with no
-- extra step, but walking away is read as "done editing that one,"
-- matching the reported expectation exactly.
local selectedInstance = nil
local selectedAtCx, selectedAtCy = nil, nil
local hoveredWorldInstance = nil
local scrollOffsets = { objects = 0 }
local flashText, flashTimer = nil, 0
local currentRows = {} -- rebuilt every draw() call: clickable screen rects for this frame
local hoverPreview = nil -- {label=, thumb=fn} for whatever the mouse is over right now

-- FEATURE 2026-08-11 -- direct user request: "q menu needs controller
-- support." The whole menu was mouse-only by original design (this
-- file's own opening header comment: "let the player use the mouse
-- normally so they can scroll through the list") -- this adds a real,
-- parallel gamepad navigation path rather than replacing the mouse one.
-- `gamepadListIndex` is a 1-based index into the object list's own
-- full, unscrolled row array (`objectRows()`) -- not a screen position
-- -- so it stays meaningful across scrolling. `lastVisibleRows` mirrors
-- `drawMenu`'s own per-frame `visible` row count (recomputed there from
-- the real window size/selection state), cached here so
-- `moveGamepadFocus` -- called from a gamepad button press, not from
-- inside the draw pass -- can keep the focused row scrolled into view
-- without duplicating that layout math.
local gamepadListIndex = 1
local lastVisibleRows = 8

-- FIX: forward-declared -- `objectRows` is only declared as a local
-- much further down this file (next to `buildObjectRows`, its own
-- natural neighbor). Without this, the call just below would resolve as
-- a GLOBAL (Lua has no hoisting for locals -- a name only becomes a
-- local upvalue from its own `local function` declaration point
-- onward), and since no global of that name is ever assigned, every
-- gamepad d-pad/A press while the Q menu is open (`moveGamepadFocus`/
-- `confirmGamepadFocus`) would throw "attempt to call a nil value" the
-- moment a controller player actually used this feature.
local objectRows

-- Moves the gamepad focus by `direction` (+1/-1), skipping header rows
-- (they have no `.action`), wrapping at either end, and adjusting the
-- scroll offset so the newly-focused row is always visible -- the same
-- real "keep selection in view" contract any list-navigation UI needs,
-- since d-pad navigation alone (no mouse wheel) would otherwise get
-- stuck the moment focus reached the edge of the currently-rendered
-- window.
local function moveGamepadFocus(direction)
  local rows = objectRows()
  if #rows == 0 then return end
  local idx = gamepadListIndex
  for _ = 1, #rows do
    idx = ((idx - 1 + direction) % #rows) + 1
    if rows[idx].kind ~= "header" then
      gamepadListIndex = idx
      break
    end
  end
  local scroll = scrollOffsets.objects or 0
  if gamepadListIndex <= scroll then
    scroll = gamepadListIndex - 1
  elseif gamepadListIndex > scroll + lastVisibleRows then
    scroll = gamepadListIndex - lastVisibleRows
  end
  scrollOffsets.objects = math.max(0, scroll)
end

local function confirmGamepadFocus()
  local rows = objectRows()
  local row = rows[gamepadListIndex]
  if row and row.action then pcall(row.action) end
end

-- ------- row list -- built once (lazy) and cached; `DoomProps.PROPS`
-- is itself already cached, so rebuilding this closure on install is
-- enough, not every frame.
local objectRowsCache = nil

local function currentOverworld()
  local ok, Game = pcall(require, "src.core.Game")
  return ok and Game and Game.overworld or nil
end

-- See `selectedInstance`'s own header comment above for why this pair
-- exists: every place that SETS the selection records the player's
-- current cell alongside it; `clearSelectionIfPlayerMoved` (called every
-- `input.step` tick, below) drops the selection the instant that cell
-- changes.
local function setSelectedInstance(inst, ow)
  selectedInstance = inst
  if inst and ow and ow.player then
    selectedAtCx, selectedAtCy = ow.player.cellX, ow.player.cellY
  else
    selectedAtCx, selectedAtCy = nil, nil
  end
end

local function clearSelectionIfPlayerMoved(ow)
  if not (selectedInstance and ow and ow.player) then return end
  if ow.player.cellX ~= selectedAtCx or ow.player.cellY ~= selectedAtCy then
    selectedInstance, selectedAtCx, selectedAtCy = nil, nil, nil
  end
end

-- Shared by the keyboard Delete/Backspace binding AND the gamepad "B"
-- button below (`DoomProps.install()`) -- previously duplicated inline
-- in two places (that keypressed handler and the `[DELETE]` row's own
-- click action inside `drawMenu`); factored out once a THIRD real call
-- site (gamepad) needed the identical behavior.
local function deleteSelected()
  if not (selectedInstance and not selectedInstance.dead) then return end
  local ow = currentOverworld()
  if ow then deleteInstance(ow, selectedInstance) end
  setSelectedInstance(nil, nil)
  flashText, flashTimer = "Deleted", 1.2
end

local function selectObjectRow(prop)
  local ow = currentOverworld()
  if not ow then return end
  if selectedInstance and not selectedInstance.dead then
    changeInstanceProp(ow, selectedInstance, prop.id)
    flashText, flashTimer = "Changed to " .. prop.name, 1.5
  else
    setSelectedInstance(placePropAtPlayer(ow, prop.id), ow)
    flashText, flashTimer = "Placed " .. prop.name, 1.5
  end
end

local function buildObjectRows()
  local rows, lastCat = {}, nil
  for _, prop in ipairs(DoomProps.PROPS) do
    if prop.category ~= lastCat then
      rows[#rows + 1] = { kind = "header", label = prop.category }
      lastCat = prop.category
    end
    rows[#rows + 1] = {
      kind = "item", label = prop.name,
      thumb = function() return getDoomDemons().loadSprite(prop.sprite, prop.frames[1]) end,
      action = function() selectObjectRow(prop) end,
    }
  end
  return rows
end

function objectRows()
  objectRowsCache = objectRowsCache or buildObjectRows()
  return objectRowsCache
end

-- ------- world targeting -- the crosshair/forward-ray shape, not mouse
-- picking (see this section's own header comment for why). A simple
-- dot-product cone test against the player's own real facing, the same
-- basic shape this project's own hit-resolvers already use elsewhere.
local WORLD_SELECT_MAX_DIST = 64
local WORLD_SELECT_MIN_DOT = math.cos(math.rad(20))

local function findHoveredWorldProp(ow)
  if not (ow and ow.player and ow.player.cellX and ow.player.cellY) then return nil end
  local px, pz = ow.player.cellX * 16 + 8, ow.player.cellY * 16 + 8
  local okYaw, yaw = pcall(function() return FirstPerson.yaw end)
  yaw = (okYaw and type(yaw) == "number" and yaw) or 0
  local fx, fz = math.sin(yaw), math.cos(yaw)
  local best, bestDot = nil, WORLD_SELECT_MIN_DOT
  for _, inst in ipairs(liveProps) do
    if inst.mapId == ow.map.id and not inst.dead then
      local ix, iz = inst.px + 8, inst.py + 8
      local dx, dz = ix - px, iz - pz
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist > 1 and dist <= WORLD_SELECT_MAX_DIST then
        local dot = (fx * dx + fz * dz) / dist
        if dot >= bestDot then bestDot, best = dot, inst end
      end
    end
  end
  return best
end

-- ------- rendering -- raw screen coordinates, deliberately OUTSIDE
-- `lib/DoomHud.lua`'s own 320x200 virtual-canvas transform (the same
-- choice that file's own `drawPaletteFlash` already makes) -- this is a
-- modern utility tool, not an in-fiction HUD element, and mouse
-- coordinates from `love.mouse.getPosition()` are already raw screen
-- space, so no transform math is needed for hit-testing either. "No
-- special styling" per the user's own request -- plain text, a faint
-- panel background only so text stays legible over the game world, one
-- highlight color for whatever the mouse is over.
local PANEL_W = 300
local ROW_H = 20
local HEADER_H = 18
local THUMB = 16
local VISIBLE_ROWS = 16

-- `gamepadFocused`: true when THIS row is `gamepadListIndex`'s own row in
-- the currently active page -- gets the identical highlight/preview
-- treatment mouse hover already gets (see `moveGamepadFocus`'s own
-- header comment), just from a second, independent input source rather
-- than a separate visual language a controller player would have to
-- learn.
local function drawRow(row, x0, y, w, mx, my, gamepadFocused)
  if row.kind == "header" then
    love.graphics.setColor(0.75, 0.7, 0.55, 1)
    love.graphics.print(row.label, x0, y)
    return HEADER_H
  end
  local mouseHovered = mx >= x0 and mx <= x0 + w and my >= y and my <= y + ROW_H
  if mouseHovered or gamepadFocused then
    love.graphics.setColor(1, 0.85, 0.2, 0.32)
    love.graphics.rectangle("fill", x0, y, w, ROW_H)
    hoverPreview = { label = row.label, thumb = row.thumb }
  end
  if mouseHovered then
    currentRows[#currentRows + 1] = { x = x0, y = y, w = w, h = ROW_H, action = row.action }
  end
  local okImg, img = pcall(row.thumb)
  if okImg and img then
    local iw, ih = img:getDimensions()
    local scale = THUMB / math.max(iw, ih)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, x0 + 2, y + (ROW_H - ih * scale) / 2, 0, scale, scale)
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(row.label, x0 + THUMB + 8, y + 3)
  return ROW_H
end

local function drawList(rows, scrollKey, x0, y0, w, visibleRows, mx, my)
  local maxScroll = math.max(0, #rows - visibleRows)
  local scroll = math.max(0, math.min(scrollOffsets[scrollKey] or 0, maxScroll))
  scrollOffsets[scrollKey] = scroll
  local y = y0
  for i = 1, visibleRows do
    local row = rows[scroll + i]
    if not row then break end
    y = y + drawRow(row, x0, y, w, mx, my, (scroll + i) == gamepadListIndex)
  end
  return y
end

-- ------- selection info + change/delete -- user request: "selecting an
-- object should let you change the object or delete it." Changing IS
-- clicking a different row while something's selected (`selectObjectRow`,
-- above) -- no separate button needed for that half; DELETE gets its own
-- explicit click target since there's no "row" for it to reuse.
-- Extracted 2026-08-19 during a project-wide readability audit, along
-- with `drawWorldHoverLabel`/`drawHoverPreviewBox`/`drawMouseCursor`
-- below -- `drawMenu` used to inline all four as one ~100-line function.
local function drawSelectionInfo(x0, panelBottom, mx, my)
  if not (selectedInstance and not selectedInstance.dead) then return end
  local prop = PROPS_BY_ID[selectedInstance.propId]
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Selected: " .. (prop and prop.name or "?"), x0, panelBottom - 34)
  local delX, delY, delW, delH = x0, panelBottom - 18, 70, 16
  local delHover = mx >= delX and mx <= delX + delW and my >= delY and my <= delY + delH
  love.graphics.setColor(delHover and 1 or 0.85, 0.25, 0.25, 1)
  love.graphics.print("[DELETE]", delX, delY)
  currentRows[#currentRows + 1] = {
    x = delX, y = delY, w = delW, h = delH,
    action = deleteSelected,
  }
end

-- What the crosshair is currently aimed at, in the world -- see this
-- section's own header comment above for why this (not mouse picking)
-- is how an EXISTING placed prop gets targeted.
local function drawWorldHoverLabel(ow, h)
  if ow then hoveredWorldInstance = findHoveredWorldProp(ow) end
  if not (hoveredWorldInstance and not hoveredWorldInstance.dead) then return end
  local hprop = PROPS_BY_ID[hoveredWorldInstance.propId]
  love.graphics.setColor(0.6, 1, 0.6, 1)
  love.graphics.print("Aiming at: " .. (hprop and hprop.name or "?") .. " (click to select)", 16, h - 40)
end

-- The big preview -- "the image of the object youre hovering over at
-- the top over it all," verbatim.
local function drawHoverPreviewBox(w)
  if not hoverPreview then return end
  local boxW, boxH = 180, 74
  local bx = (w - boxW) / 2
  love.graphics.setColor(0, 0, 0, 0.8)
  love.graphics.rectangle("fill", bx, 6, boxW, boxH)
  local okImg, img = pcall(hoverPreview.thumb)
  if okImg and img then
    local iw, ih = img:getDimensions()
    local scale = math.min(56 / iw, 56 / ih)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.draw(img, bx + (boxW - iw * scale) / 2, 10, 0, scale, scale)
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print(hoverPreview.label, bx + 4, 6 + boxH - 16)
end

-- FIXED 2026-08-10 -- user report: "i dont see my cursor in game."
-- `love.mouse.setVisible(true)` (`setMenuOpen`, below) is the correct,
-- documented LÖVE call, but relying on the OS/hardware cursor actually
-- reappearing after this engine's own relative-mode mouse-look is a
-- real, known-flaky LÖVE/SDL edge case on some platforms (relative mode
-- owns cursor visibility at the OS level while it's active, and
-- restoring it isn't reliably instant/consistent everywhere) -- not
-- something worth debugging platform-by-platform when a robust
-- workaround costs six lines: draw a real, always-visible cursor
-- ourselves, at `love.mouse.getPosition()`'s own reported coordinates.
-- Position tracking and the OS cursor's own on-screen rendering are
-- separate systems -- `getPosition()` stays accurate regardless of
-- whether the hardware cursor is actually drawing, so this can never be
-- "wrong," only ever a backup/primary indicator layered on top of
-- whatever the OS cursor does or doesn't do. Drawn LAST, over everything
-- else in this overlay.
local function drawMouseCursor(mx, my)
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.line(mx - 6, my, mx + 6, my)
  love.graphics.line(mx, my - 6, mx, my + 6)
  love.graphics.setColor(0, 0, 0, 0.6)
  love.graphics.circle("line", mx, my, 3)
  love.graphics.setColor(1, 1, 1, 1)
end

local function drawMenu()
  currentRows = {}
  hoverPreview = nil
  local w, h = love.graphics.getDimensions()
  local mx, my = love.mouse.getPosition()
  local x0 = w - PANEL_W - 16
  local panelTop, panelBottom = 96, h - 20
  local ow = currentOverworld()

  love.graphics.setColor(0, 0, 0, 0.72)
  love.graphics.rectangle("fill", x0 - 8, panelTop - 8, PANEL_W + 16, panelBottom - panelTop + 16)

  local ty = panelTop

  local hasSelection = selectedInstance and not selectedInstance.dead
  local listBottom = panelBottom - (hasSelection and 40 or 0)
  local visible = math.max(1, math.floor((listBottom - ty) / ROW_H))
  lastVisibleRows = visible -- see `moveGamepadFocus`'s own header comment
  drawList(objectRows(), "objects", x0, ty, PANEL_W, visible, mx, my)

  drawSelectionInfo(x0, panelBottom, mx, my)
  drawWorldHoverLabel(ow, h)
  drawHoverPreviewBox(w)

  if flashTimer > 0 and flashText then
    love.graphics.setColor(0.4, 1, 0.4, 1)
    love.graphics.print(flashText, x0, panelTop - 20)
  end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.print("Q to close", x0, panelBottom + 2)

  drawMouseCursor(mx, my)
end

-- ------- camera-look suppression -- "it should stop mouse movement for
-- camera look though and let the player use the mouse normally." Two
-- real, separate interventions, both wraps of live fields/functions
-- (never an edit to the host mod's own files), matching this whole
-- project's established "wrap a live table field" idiom:
--   1. `FirstPerson.lookBy` (the real function that actually applies a
--      mouse-move delta to camera yaw/pitch, confirmed by reading
--      `FirstPerson.lua` directly) no-ops while the menu is open --
--      camera rotation stops, movement/everything else FirstPerson
--      drives is untouched (deliberately NOT touching
--      `FirstPerson.driving()` itself, which gates far more than just
--      look -- disabling it would risk stopping movement too, which the
--      user explicitly said this must never do).
--   2. `love.mouse.setRelativeMode` is forced to `false` while the menu
--      is open. `FirstPerson`'s own per-frame update re-asserts relative
--      mode (which hides/locks the OS cursor for raw-delta look) EVERY
--      SINGLE FRAME as long as the player is engaged in first-person --
--      a one-time `setRelativeMode(false)` on menu-open would just get
--      overwritten on the very next frame, so this wraps the raw LÖVE
--      call itself to keep winning that fight for as long as the menu
--      stays open, releasing the OS cursor so it moves like a normal
--      pointer.
local lookSuppressInstalled = false
local function installLookSuppression()
  if lookSuppressInstalled then return end
  lookSuppressInstalled = true
  local innerLookBy = FirstPerson.lookBy
  FirstPerson.lookBy = function(dyaw, dpitch)
    if menuOpen then return end
    return innerLookBy(dyaw, dpitch)
  end
  if love.mouse and love.mouse.setRelativeMode then
    local innerSetRelativeMode = love.mouse.setRelativeMode
    love.mouse.setRelativeMode = function(v)
      if menuOpen then v = false end
      return innerSetRelativeMode(v)
    end
  end
end

local function setMenuOpen(open)
  menuOpen = open
  if love.mouse and love.mouse.setVisible then pcall(love.mouse.setVisible, open) end
  if not open then
    currentRows, hoverPreview = {}, nil
  end
end

-- ------- install -- `love.draw` overlay (matching `lib/DoomHud.lua`'s
-- own real, proven pattern -- never `Screens.push`, see this section's
-- own header comment), a `love.keypressed` Q-toggle, mouse click/wheel
-- routing while the menu is open, and the `input.step` tick that keeps
-- every placed prop's own entity live regardless of whether the menu is
-- open -- gated on `FirstPerson.onTop()` per CLAUDE.md's own pausing
-- hard rule, matching every other always-on tick in this project (the
-- prop menu itself is explicitly NOT part of that gate -- the whole
-- point is that it never pauses anything).
local installed = false
function DoomProps.install()
  if installed then return end
  installed = true
  installLookSuppression()

  local function active()
    return Options.enabled() and FirstPerson.driving()
  end

  local innerKeypressed = love.keypressed
  love.keypressed = function(key, scancode, isrepeat)
    if active() and key == "q" and not isrepeat then
      setMenuOpen(not menuOpen)
      return
    end
    if menuOpen and (key == "delete" or key == "backspace") and selectedInstance and not selectedInstance.dead then
      deleteSelected()
      return
    end
    if innerKeypressed then return innerKeypressed(key, scancode, isrepeat) end
  end

  -- FEATURE 2026-08-11 -- direct user request: "q menu needs controller
  -- support." Wraps `Game.gamepadpressed` (the base engine's own real
  -- gamepad-dispatch method -- see `lib/DoomWeapons.lua`'s own matching
  -- gamepad wrap for the full "why Game: methods, not raw love.gamepad*
  -- callbacks" derivation, confirmed against this host's own `First
  -- Person.lua`/`CamControl.lua`). Y opens/closes the menu (mirroring
  -- keyboard Q); while open: d-pad up/down moves the list selection
  -- (`moveGamepadFocus`), A confirms the focused row
  -- (`confirmGamepadFocus`, the same `.action` a mouse click already
  -- fires), B deletes the current selection (mirroring the keyboard
  -- Delete/Backspace binding above). All of these CONSUME the button
  -- (never call through to whatever it otherwise means) only while the
  -- menu is actually open, so a controller player's own normal first-
  -- person controls are completely unaffected the rest of the time --
  -- matching this file's own existing mouse-suppression scoping
  -- (`installLookSuppression`, look stops, movement never does) and
  -- Horde Mode's own established "claim while the mode/menu is active,
  -- fall through otherwise" precedent elsewhere in this codebase.
  local okGame, Game = pcall(require, "src.core.Game")
  if okGame and Game then
    local innerGamepadPressed = Game.gamepadpressed
    function Game:gamepadpressed(joystick, button)
      if active() and button == "y" then
        setMenuOpen(not menuOpen)
        return
      end
      if menuOpen then
        if button == "dpup" then moveGamepadFocus(-1) return
        elseif button == "dpdown" then moveGamepadFocus(1) return
        elseif button == "a" then confirmGamepadFocus() return
        elseif button == "b" then deleteSelected() return
        end
      end
      if innerGamepadPressed then return innerGamepadPressed(self, joystick, button) end
    end
  end

  local innerMousepressed = love.mousepressed
  love.mousepressed = function(x, y, button, istouch, presses)
    if menuOpen and button == 1 then
      local handledRow = nil
      for _, row in ipairs(currentRows) do
        if x >= row.x and x <= row.x + row.w and y >= row.y and y <= row.y + row.h then
          handledRow = row
          break
        end
      end
      if handledRow then
        pcall(handledRow.action)
      elseif hoveredWorldInstance and not hoveredWorldInstance.dead then
        setSelectedInstance(hoveredWorldInstance, currentOverworld())
      end
      return
    end
    if innerMousepressed then return innerMousepressed(x, y, button, istouch, presses) end
  end

  local innerWheelmoved = love.wheelmoved
  love.wheelmoved = function(dx, dy)
    if menuOpen then
      scrollOffsets.objects = (scrollOffsets.objects or 0) - dy
      return
    end
    if innerWheelmoved then return innerWheelmoved(dx, dy) end
  end

  local innerDraw = love.draw
  love.draw = function(...)
    if innerDraw then innerDraw(...) end
    if menuOpen then pcall(drawMenu) end
  end

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if Options.enabled() and FirstPerson.onTop() then
      local ok, ow = pcall(function() return require("src.core.Game").overworld end)
      if ok and ow and ow.map then
        pcall(tickProps, ow, dt)
        pcall(clearSelectionIfPlayerMoved, ow)
      end
    end
    if flashTimer > 0 then flashTimer = math.max(0, flashTimer - dt) end
    return next(game, dt)
  end)
end

return DoomProps
