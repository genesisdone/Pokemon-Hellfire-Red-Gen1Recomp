-- PokeDoom: a shared factory for short-lived, fire-and-forget billboard
-- effects -- the real entity lifecycle (spawn, sync into `ow.entities`,
-- per-tic frame-advance through a real DOOM state chain, remove on the
-- chain's own end) that `lib/DoomBlood.lua` (`P_SpawnBlood`) and `lib/
-- DoomPuff.lua` (`P_SpawnPuff`) each independently implemented, byte-
-- for-byte identical apart from their own real sprite/timing data.
--
-- Factored out 2026-08-19 during a project-wide readability audit, at
-- direct user request. This is exactly the "parallel implementation"
-- duplication CLAUDE.md's own hard rule warns about (a fix to one
-- lifecycle not automatically reaching its sibling) -- both files
-- already carry their own real history of this happening (the
-- `shadowQuad`-wrapping gap, the vertical-lift gap, both found and
-- fixed in one file, then separately in the other on a second report).
--
-- `DoomEffectEntity.new(config)` returns a fresh, independent effect
-- table with its own private instance list -- blood and puffs are
-- unrelated data, never a shared list, only the LIFECYCLE code is
-- shared. `config` fields:
--   spritePrefix  -- real DOOM sprite lump prefix (e.g. "BLUD", "PUFF")
--   letters       -- real per-state frame letters, in real chain order
--   ticsPerFrame  -- real DOOM tics each frame holds (info.c)
--   defMarker     -- string field name used to recognize this effect's
--                    own fake sprite `def` in the shared mesh-hook wrap
--                    (e.g. "pokedoomBlood") -- must be unique per effect
--   cacheKeyPrefix -- prefix for this effect's own per-frame image cache key

local V = ...
local Host = V.host
local Options = V.require("DoomOptions")
local SpriteBillboards = Host.require("SpriteBillboards")
local DoomGround = V.require("DoomGround")

local DoomEffectEntity = {}

-- Lazy, not a top-level require: `lib/DoomDemons.lua` is a real caller
-- of every effect built here (its own hit resolvers spawn blood/puffs),
-- so a top-level `V.require("DoomDemons")` risks the exact same
-- circular-load hazard `lib/DoomDemons.lua`'s own header comment already
-- documents solving for `lib/DoomWeapons.lua` -- deferred until first
-- actual use, well after every module has finished loading.
local DoomDemons
local function getDoomDemons()
  DoomDemons = DoomDemons or V.require("DoomDemons")
  return DoomDemons
end

local DOOM_TICRATE, FRAME_RATE = 35, 60
local function ticsToFrames(tics)
  return math.max(1, math.floor(tics * FRAME_RATE / DOOM_TICRATE + 0.5))
end

function DoomEffectEntity.new(config)
  local spritePrefix = config.spritePrefix
  local letters = config.letters
  local ticsPerFrame = config.ticsPerFrame
  local defMarker = config.defMarker
  local cacheKeyPrefix = config.cacheKeyPrefix

  local effect = {}
  local instances = {}

  -- ------- the fake entity's own mesh -- delegates to `lib/DoomDemons.
  -- lua`'s own exported `DoomDemons.mesh` (the same real
  -- `buildDemonMesh`/`calibrationRatioFor` machinery every demon and
  -- every other non-demon effect sprite already shares) rather than a
  -- separate dedicated builder -- a real splat/puff is supposed to read
  -- small next to a demon, which sharing ZOMBIEMAN's own already-
  -- calibrated per-pixel ratio (via `spritePrefix` being listed in that
  -- file's own `NON_DEMON_PREFIXES` table) reproduces faithfully.
  --
  -- Both `.mesh` AND `.shadowQuad` are wrapped -- a real, confirmed bug
  -- both `DoomBlood`/`DoomPuff` hit independently before this factoring:
  -- whichever mesh-hook file installs FIRST at `main.lua` load time
  -- permanently pins `shadowQuad` to its own recognizer, so any OTHER
  -- effect's own sprite marker falls through to a frozen `inner` that
  -- never includes its own wrapper, no matter what else is correct.
  local installedMeshHook = false
  local function installMeshHook()
    if installedMeshHook then return end
    installedMeshHook = true
    local recognize = function(inner)
      return function(def, frame)
        if def and def[defMarker] then
          local ok, m = pcall(getDoomDemons().mesh, def.pokedoomCacheKey, def.pokedoomImage, spritePrefix)
          if ok then return m end
          return nil
        end
        return inner(def, frame)
      end
    end
    SpriteBillboards.mesh = recognize(SpriteBillboards.mesh)
    SpriteBillboards.shadowQuad = recognize(SpriteBillboards.shadowQuad)
  end

  -- `inst.wy` (optional, absolute world height): an entity's real
  -- vertical lift is `entity.py - (pose()'s own third return value)`,
  -- added on top of `groundAt(entity.cellX, entity.cellY)` -- confirmed
  -- against the base engine's own real render contract
  -- (`DramaticShapeVoxelMod-dev/lib/VoxelScene.lua`'s `posesOf`). Nil-
  -- safe: an instance with no `wy` renders ground-anchored, same as
  -- before this became configurable.
  local function makeEntity(inst)
    local cornerX, cornerZ = inst.wx - 8, inst.wz - 8
    local entity
    entity = {
      passable = true,
      px = cornerX, py = cornerZ,
      cellX = math.floor(inst.wx / 16), cellY = math.floor(inst.wz / 16),
      -- Same defensive no-op the whole project's own fake entities
      -- already carry -- the classic flat 2D path calls `:draw()`
      -- unconditionally on every `ow.entities` member.
      draw = function() end,
      pose = function()
        local letter = letters[inst.index] or letters[#letters]
        local ok, image = pcall(getDoomDemons().loadSprite, spritePrefix, letter)
        local cacheKey = cacheKeyPrefix .. letter
        local spriteObj = {
          def = {
            [defMarker] = true, pokedoomCacheKey = cacheKey,
            pokedoomImage = (ok and image) or nil, trueColor = true, image = cacheKey,
          },
        }
        function spriteObj:resolveImage() return self.def.pokedoomImage end
        local vy = cornerZ
        if inst.wy and inst.ow then
          local gh = DoomGround.heightAt(inst.ow.map, entity.cellX, entity.cellY)
          vy = entity.py - (inst.wy - gh)
        end
        return spriteObj, cornerX, vy, "down", 0, false
      end,
    }
    return entity
  end

  local function removeEntity(ow, inst)
    inst.inserted = false
    if not (inst.entity and ow and ow.entities) then return end
    for i, e in ipairs(ow.entities) do
      if e == inst.entity then table.remove(ow.entities, i) break end
    end
    inst.entity = nil
  end

  -- Same "re-insert every tick for the currently loaded map, tear down
  -- entirely while PKDOOM MODE is off" shape `lib/DoomKill.lua`'s own
  -- `syncGibEntities` already established -- `inserted`, a real flag
  -- invalidated only on a map change, avoids re-scanning all of
  -- `ow.entities` every tick per active instance just to check "am I
  -- already inserted" (Phase 26's own lag audit).
  local lastMapId = nil
  local function syncEntities(ow)
    local mapId = ow and ow.map and ow.map.id
    if mapId ~= lastMapId then
      for _, inst in ipairs(instances) do inst.inserted = false end
      lastMapId = mapId
    end
    for _, inst in ipairs(instances) do
      if Options.enabled() and ow and ow.entities and inst.mapId == mapId then
        inst.entity = inst.entity or makeEntity(inst)
        if not inst.inserted then
          table.insert(ow.entities, inst.entity)
          inst.inserted = true
        end
      else
        removeEntity(ow, inst)
      end
    end
  end

  -- `inst.index > #letters` is real DOOM's own S_NULL -- past the last
  -- real frame, the mobj is simply gone (unlike a gib's own deliberate
  -- freeze-on-last-frame).
  local function advance(inst)
    if inst.index > #letters then
      inst.tics = -1
    else
      inst.tics = ticsToFrames(ticsPerFrame)
    end
  end

  local function tick(ow)
    for i = #instances, 1, -1 do
      local inst = instances[i]
      if inst.tics >= 0 then
        inst.tics = inst.tics - 1
        if inst.tics <= 0 then
          inst.index = inst.index + 1
          advance(inst)
        end
      end
      if inst.tics < 0 then
        removeEntity(ow, inst)
        table.remove(instances, i)
      end
    end
  end

  -- Spawns a new instance starting at `startIndex` (1-based, into
  -- `letters`) -- the CALLER decides what that index actually means (a
  -- damage threshold for blood, a melee flag for puffs, per each real
  -- DOOM spawn function's own real starting-state rule); this factory
  -- only knows how to animate/render whatever index it's given.
  function effect.spawn(ow, wx, wz, startIndex, wy)
    if not Options.enabled() then return end
    if not (ow and ow.map) then return end
    local inst = { index = startIndex, tics = 0, wx = wx, wz = wz, mapId = ow.map.id, wy = wy, ow = ow }
    advance(inst)
    instances[#instances + 1] = inst
  end

  local installed = false
  function effect.install()
    if installed then return end
    installed = true
    installMeshHook()
    V.mod.hooks:wrap("input.step", function(next, game, dt)
      local ok, ow = pcall(function() return require("src.core.Game").overworld end)
      if ok and ow then
        pcall(syncEntities, ow)
        pcall(tick, ow)
      end
      return next(game, dt)
    end)
  end

  return effect
end

return DoomEffectEntity
