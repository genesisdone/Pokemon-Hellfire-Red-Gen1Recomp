-- PokeDoom Phase 8 (scoped): killing overworld NPCs. The battle KILL
-- command and its own target-swap/HUD transition are NOT part of this
-- file -- per the user's explicit request, this phase currently covers
-- only "walk around in first person and shoot NPCs," Locked Decision 4's
-- first of three KILL contexts. See phases/phase-8-kill-mechanic.md.
--
-- ------- the kill/gib rule, read fresh from p_inter.c
--
-- Real DOOM's P_DamageMobj/P_KillMobj (p_inter.c:764-892): any hit that
-- brings health to 0 kills (P_KillMobj); a kill additionally shows the
-- gorier XDeath ("extreme death") sprite sequence instead of the plain
-- one only when the OVERKILL is big enough that health goes MORE
-- negative than the monster's own spawnhealth (`target->health <
-- -target->info->spawnhealth`, p_inter.c:719-723). This mod has no
-- per-NPC health pool at all -- overworld NPCs are Pokemon trainers/
-- flavor characters, not DOOM monsters with mobjinfo -- and CLAUDE.md's
-- own locked scope just says "the same gib death" for every killed
-- overworld NPC, not "sometimes regular, sometimes extreme." The
-- simplest faithful reading of that spec, rather than inventing a
-- health/pain-state system DOOM's own source gives no equivalent for
-- here, is: every hit is a one-shot kill, and it always gibs.
--
-- ------- the gib animation is REAL DOOM content, not invented
--
-- The Zombieman's (MT_POSSESSED) own XDeath sprite sequence (info.c:
-- 330-338), extracted at runtime from the player's own WAD through the
-- exact same DoomWadImport pipeline every weapon sprite already uses --
-- per CLAUDE.md's asset policy (Locked Decision 5), extracting real DOOM
-- sprites from a player-supplied WAD was always the intended mechanism
-- for every DOOM sprite this mod shows, not a weapons-only exception.
-- Picked over the player's own PLAY death frames as the more natural
-- "generic person" analog for a killed NPC -- POSS is DOOM's own basic
-- humanoid enemy, not a specific likeness, and both sequences are
-- present in this project's reference WAD (confirmed by listing the
-- extracted SPRITES folder directly, not assumed).
--
-- domTics=-1 is DOOM's own real "freeze on this frame forever" sentinel
-- (a corpse just sits there, info.c's own S_POSS_XDIE9 entry) -- kept
-- literally here rather than folded into Phase 5's ticsFor/frames()
-- machinery, since this is a standalone one-shot animation, not a
-- looping weapon psprite chain.
local XDIE_STATES = {
  { domTics = 5, sprite = "POSSM" },                -- S_POSS_XDIE1
  { domTics = 5, sprite = "POSSN", slop = true },    -- S_POSS_XDIE2 (A_XScream: sfx_slop)
  { domTics = 5, sprite = "POSSO" },                 -- S_POSS_XDIE3 (A_Fall: clears solid, silent)
  { domTics = 5, sprite = "POSSP" },                 -- S_POSS_XDIE4
  { domTics = 5, sprite = "POSSQ" },                 -- S_POSS_XDIE5
  { domTics = 5, sprite = "POSSR" },                 -- S_POSS_XDIE6
  { domTics = 5, sprite = "POSSS" },                 -- S_POSS_XDIE7
  { domTics = 5, sprite = "POSST" },                 -- S_POSS_XDIE8
  { domTics = -1, sprite = "POSSU" },                -- S_POSS_XDIE9 (freeze)
}

local V = ...
local Host = V.host
local DoomWeapons = V.require("DoomWeapons")
local DoomWadImport = V.require("DoomWadImport")
local DoomLog = V.require("DoomLog")
local DoomBlood = V.require("DoomBlood")
local DoomHud = V.require("DoomHud")
local DoomFont = V.require("DoomFont")
local DoomDeathScreen = V.require("DoomDeathScreen")
local Options = V.require("DoomOptions")
local DoomGround = V.require("DoomGround")
local DoomSpriteCache = V.require("DoomSpriteCache")
local Voxel3D = Host.require("Voxel3D")
local SpriteBillboards = Host.require("SpriteBillboards")
local FirstPerson = Host.require("FirstPerson")

local DoomKill = {}

-- ------- assets: sprites + sounds, cached like every other DoomWadImport
-- consumer in this mod (Phase 2/3's own pattern) -- reloaded once if the
-- WAD import status changes, same reasoning as DoomWeapons' own cache.
-- FIXED 2026-08-06, same real bug as `lib/DoomDemons.lua`'s own
-- `loadDemonSprite` (see that file's own header comment for the full
-- DOOM-sprite-rotation-rule derivation, confirmed against `wadext-
-- master/wadext.cpp:147`): a `0`-rotation lump only exists for a state
-- that looks the same from every angle, which a directional final-death
-- pose is not guaranteed to be. Falls back to rotation `1` when `0`
-- isn't found.
-- `spriteName` here already includes its own letter (e.g. `XDIE_STATES`'
-- own `"TROOM"`), unlike `DoomSpriteCache.newSpriteLoader`'s own real
-- `(prefix, letter)` split -- passed through with an empty letter so the
-- shared loader's own `prefix .. letter` concatenation still lands on
-- the exact same lump name.
local loadGibSpriteRaw = DoomSpriteCache.newSpriteLoader()
local function loadGibSprite(spriteName)
  return loadGibSpriteRaw(spriteName, "")
end

local function playSound(nameSubstring)
  local ok, snd = pcall(DoomWadImport.loadSound, nameSubstring)
  if ok and snd then DoomWadImport.playClone(nameSubstring, snd) end
end

-- ------- rendering: a real depth-tested entity now, not an overlay
--
-- Went through three real attempts before landing here, each one found
-- wrong by an actual playtest, not guessed right on paper:
--
-- 1. A `love.draw` screen-space overlay (this file's original version).
--    Simple, and it worked for the weapon view model -- but a WORLD
--    object drawn entirely outside the render pipeline paints over
--    EVERYTHING drawn that frame, no exceptions: the gun, world geometry,
--    even the pause menu (confirmed by the user's own screenshots).
-- 2. Moved the draw into `Voxel3D.beginOverlay()`, called from inside a
--    wrap of `VoxelScene.render` -- the same real seam the host's own
--    field FX (heal machine, dust, cut-tree) use. Fixed the pause-menu
--    case for real (this now draws in the same PASS as the rest of the
--    world, so the engine's own later UI compositing correctly covers
--    it). Added a ray/ground-height occlusion check (restated from `lib/
--    DoomWeapons.lua`'s own `terrainRange`) to approximate hiding a gib
--    behind a wall. Still wrong: a screen-space overlay has no real DEPTH
--    -- the occlusion check was binary (fully hidden or fully visible,
--    never partially clipped), and the user confirmed by screenshot a
--    gib still visibly rendering in front of a bookshelf it was only
--    HALFWAY behind.
-- 3. **This version.** The user asked directly for the literal same
--    rendering technique the voxel mod uses for every other entity --
--    real depth-tested geometry, not an approximation. That technique
--    turns out to be reachable without forking the host's own render
--    pipeline (`VoxelScene.render`, `drawCast`, `drawEntity`,
--    `posesOf` -- positioning, camera-ward pull, depth test, lighting,
--    shadow casting, all real, all untouched): `posesOf`
--    (`VoxelScene.lua:506-538`) iterates `state.entities` and calls
--    `e:pose()` on each, feeding the result into the exact same
--    `drawEntity`/`Voxel3D.draw` call every real NPC goes through.
--    Anything satisfying that same minimal shape -- not a "fake NPC,"
--    just enough fields for the render loop to draw it -- gets genuinely
--    depth-tested against the real 3D terrain, automatically, for free.
--
--    The one real gap: `SpriteBillboards.mesh(def, frame)` -- what
--    `drawEntity` calls to build the mesh -- assumes a fixed 16px-tall
--    multi-frame vertical SHEET (`buildCard`, SpriteBillboards.lua:
--    38-53). A DOOM gib sprite is one standalone image at its own native
--    size, not a sheet -- feeding it through unmodified would crop to a
--    meaningless 16x16 corner. Fixed by wrapping ONLY that one small
--    function (a live table field, the same monkey-patch idiom this
--    whole codebase already uses) to build its own correctly-shaped quad
--    for gib defs specifically, via `Voxel3D.newMesh`/`Voxel3D.pushQuad`
--    -- the same low-level, format-safe primitives `buildCard` itself
--    calls (`Voxel3D.FORMAT`: position(3)/texcoord(2)/shade(1) per
--    vertex, confirmed directly from Voxel3D.lua, not guessed) -- and
--    falling through to the real, unmodified `buildCard` for every
--    actual NPC def. Everything downstream of the mesh is 100% the
--    host's own live code.
--
-- Confirmed SAFE to add to `ow.entities`, by reading the engine's own
-- source rather than assuming: `Collision.occupied`
-- (`gen1recomp-dev/src/world/Collision.lua:20-30`) explicitly skips any
-- entity with `.passable = true` -- the same real field the engine's own
-- Pikachu-follower entity uses so the player can walk straight through it
-- (`pikachu_follow.asm`) -- so a gib entity never blocks movement.
-- `OverworldState:npcAtCell` (`OverworldController.lua:1713-1721`) --
-- what `A`/interact actually searches -- reads `self.npcs` ONLY, a
-- SEPARATE array this file never adds a gib to, so a gib is never a talk
-- target either.
local NPC_CARD_WORLD_HEIGHT = 16 -- world units, matches a standing NPC's own real billboard height

-- Calibrated ONCE, from the FIRST XDIE frame's own native pixel height
-- treated as a stand-in for a standing character's real size -- the same
-- fix this file's ORIGINAL screen-space-overlay version needed (see the
-- header comment above): DOOM's own later XDIE frames are naturally
-- WIDER and SHORTER than the earlier ones (gore spreading outward, the
-- body collapsing), not just uniformly smaller. Normalizing EVERY
-- frame's own HEIGHT independently to the same fixed world size (this
-- version's own first attempt, `worldH = NPC_CARD_WORLD_HEIGHT` computed
-- fresh per image) made a later, naturally-shorter-but-wider frame's
-- width balloon far past its true size once forced to that same fixed
-- height -- confirmed by the user's own playtest, the gib visibly
-- growing across the animation. Fixed the same way as before: freeze a
-- `worldUnitsPerNativePixel` ratio ONCE from the first frame, and apply
-- it UNIFORMLY (both axes, same factor) to every later frame's own true
-- native dimensions -- so each frame's real proportions come through,
-- scaled by one consistent physical size, never independently
-- renormalized to a fixed target height per frame.
local worldUnitsPerNativePixel = nil
local function calibrationRatio()
  if worldUnitsPerNativePixel then return worldUnitsPerNativePixel end
  local firstImage = loadGibSprite(XDIE_STATES[1].sprite)
  if not firstImage then return nil end
  local _, ih0 = firstImage:getDimensions()
  if not (ih0 and ih0 > 0) then return nil end
  worldUnitsPerNativePixel = NPC_CARD_WORLD_HEIGHT / ih0
  return worldUnitsPerNativePixel
end

local gibMeshCache = {}
local lastMeshWadState = nil
local function buildGibMesh(image)
  local iw, ih = image:getDimensions()
  if not (iw and ih and iw > 0 and ih > 0) then return nil end
  local ratio = calibrationRatio()
  if not ratio then return nil end
  local worldH = ih * ratio
  local worldW = iw * ratio
  local halfW = worldW / 2
  -- a hair of UV inset, matching buildCard's own -- keeps the sampler off
  -- the sprite's own silhouette edge rather than picking up texture-clamp
  -- bleed from outside it
  local u0, u1 = 0.5 / iw, (iw - 0.5) / iw
  local v0, v1 = 0.5 / ih, (ih - 0.5) / ih
  -- Centered on local X=8, NOT X=0 -- matching `buildCard`'s own
  -- corner-anchored 0..16 quad, whose center sits at local X=8. This
  -- matters because `billboardMatrix` (VoxelScene.lua:287-296) is not a
  -- plain translate: it does `translate(px+8, y, py+8)`, THEN rotates
  -- (the first-person yaw blend and lean), THEN applies `translate(-8, 0,
  -- 0)` to the mesh's own LOCAL space -- i.e. it expects a CORNER-style
  -- quad and shifts it to pivot around its OWN center, in that order.
  -- Read directly, not assumed, after the user reported the gib
  -- intermittently drifting left of the NPC's real position: a quad
  -- centered at local X=0 (this file's first version) gets the SAME -8
  -- local shift applied on top of already being centered, landing its
  -- true center 8 units off the actual rotation pivot -- and since that
  -- extra offset is IN LOCAL SPACE, it rotates along with the camera's
  -- own yaw blend, so the WORLD-space drift direction changes as the
  -- camera turns -- exactly the "sometimes correct, sometimes off"
  -- behavior reported. Centering on local X=8 here (matching buildCard)
  -- means the same "-8" shift lands the center exactly back at the
  -- pivot, for any width, the same way it already does for a real NPC's
  -- fixed 16-wide card. `makeGibEntity` below passes `px = wx - 8` (not
  -- `wx`) for the matching reason: `billboardMatrix`'s own `px + 8`
  -- expects a CORNER value, and this file's stored `wx`/`wz` are already
  -- the death point's real CENTER (`npcCenter`'s own +8,+8), so passing
  -- them unadjusted double-counted that offset in world space too.
  local verts = {
    { 8 - halfW, 0, 0, u0, v1, 1 }, { 8 + halfW, 0, 0, u1, v1, 1 },
    { 8 + halfW, worldH, 0, u1, v0, 1 }, { 8 - halfW, worldH, 0, u0, v0, 1 },
  }
  local indices = {}
  Voxel3D.pushQuad(indices, 0)
  return Voxel3D.newMesh(verts, indices)
end

-- Cached per DOOM sprite name (e.g. "POSSM") -- every gib currently
-- showing that same XDIE frame shares one mesh, the same "cache the
-- built card, draw it many times with different model matrices" pattern
-- `SpriteBillboards.mesh` itself already uses for real NPCs.
local function gibMesh(spriteName, image)
  -- Same cache-busting trigger `loadGibSprite` above already uses --
  -- a WAD re-import mid-session must also throw away the OLD wad's
  -- calibration ratio, not just the mesh cache, or a later frame would
  -- silently size itself against dimensions that no longer describe the
  -- currently-loaded sprites.
  if DoomWadImport.status.state ~= lastMeshWadState then
    lastMeshWadState = DoomWadImport.status.state
    gibMeshCache = {}
    worldUnitsPerNativePixel = nil
  end
  local cached = gibMeshCache[spriteName]
  if cached ~= nil then return cached or nil end
  local okM, m = pcall(buildGibMesh, image)
  m = (okM and m) or false
  gibMeshCache[spriteName] = m
  return m or nil
end

-- The wrap itself MUST NOT throw: `VoxelScene.render` runs inside the
-- render pipeline's own `guardRender` (`src/render/Pipelines.lua`), a
-- pcall around the WHOLE pipeline call -- an uncaught error here would
-- mark the entire voxel pipeline broken and disable 3D rendering for the
-- rest of the session, not just fail this one gib's draw. Wrapped in its
-- own pcall, falling through to the real, original function on anything
-- unexpected, rather than trusting every path through this to be safe.
local installedMeshHook = false
local function installGibMeshHook()
  if installedMeshHook then return end
  installedMeshHook = true
  local inner = SpriteBillboards.mesh
  local function reskin(def, frame)
    if def and def.pokedoomGib then
      local ok, m = pcall(gibMesh, def.pokedoomSpriteName, def.pokedoomImage)
      if ok then return m end
      return nil
    end
    return inner(def, frame)
  end
  SpriteBillboards.mesh = reskin
  -- FIX: `SpriteBillboards.shadowQuad` is a load-time snapshot of the
  -- ORIGINAL `.mesh` (`SpriteBillboards.lua`'s own `shadowQuad = mesh`),
  -- not a live alias -- reassigning `.mesh` above never reaches it. Left
  -- unwrapped, the sun/occlusion pass would call the ORIGINAL function
  -- with this file's own synthetic `pokedoomGib` def, silently fail to
  -- build a card (confirmed via `VoxelScene.lua`'s own `drawShadow`: `if
  -- not mesh then return end`, no crash, just no shadow), and every gib
  -- corpse would render with no shadow/occlusion silhouette -- the exact
  -- same gap `lib/DoomDemons.lua`'s own Phase 21 Round 4 already found
  -- and fixed for demons, and `lib/DoomProps.lua` already avoids for
  -- props. Wrapped the same way here per CLAUDE.md's own "a fix to one
  -- implementation of a shared mechanic must be checked against every
  -- parallel implementation" hard rule.
  SpriteBillboards.shadowQuad = reskin
end

-- ------- multiple gibs, and permanent corpses
--
-- Originally a single `gib` slot, overwritten by the next kill -- a
-- second kill shortly after the first silently discarded whichever gib
-- was still animating, reported directly by the user ("the first gib
-- despawns instantly"). This is now a LIST (`gibs`), one entry per kill,
-- so simultaneous corpses coexist exactly like DOOM's own map, which
-- never limits how many corpses can be lying around at once.
--
-- Also originally auto-despawned after a fixed hold on the frozen last
-- XDIE frame -- the user asked instead for the corpse to "stay on the
-- ground forever ... and just use the last frame of the animation as a
-- permanent sprite, unless respawned," matching DOOM's own real behavior
-- even more closely than the original timeout did: DOOM's own
-- `S_POSS_XDIE9` state (`domTics = -1`) is ALREADY a "freeze forever"
-- sentinel (info.c) -- a real DOOM corpse never despawns on its own
-- either. `tickGibs` below simply stops advancing a gib once it reaches
-- that state, forever, with no separate "done, now hold" bookkeeping.
-- The only thing that clears a gib now is the RESPAWN NPCS options row
-- (`lib/DoomOptions.lua`), via the generic `Options.onRespawnNpcs`
-- callback registry `DoomKill.install` registers into below -- avoids a
-- circular require (`DoomOptions` -> `DoomKill` -> `DoomOptions`, since
-- this file already requires `DoomOptions`), the same "don't call back
-- into a module that's still loading you" hazard `DoomWeapons.
-- registerTargetResolver` was already built to sidestep for a different
-- pair of files.
local gibs = {}

-- ------- the fake entity
--
-- `:pose()` re-reads the CURRENT XDIE state fresh every call (`g.index`),
-- so the entity automatically shows whatever frame the animation is on,
-- including its own frozen last frame forever, with no extra sync step
-- needed when `tickGibs` advances it.
--
-- Never returns a nil sprite, even in the (very unlikely) case neither
-- the current frame's sprite NOR the first XDIE frame is loadable: a nil
-- `sprite` reaching `drawEntity` would index a nil `.def` and throw,
-- which -- same reasoning as `installGibMeshHook`'s own header comment --
-- risks disabling the whole voxel pipeline for the session, a far worse
-- outcome than one gib not drawing correctly for a frame.
--
-- `pose()`'s own `px`/`py` (its 2nd/3rd return, what `posesOf` actually
-- reads as world position -- NOT this entity's own `.px`/`.py` fields,
-- which `posesOf` never looks at) are `wx - 8`/`wz - 8`, not the raw
-- death-point center -- see `buildGibMesh`'s own header comment for why:
-- `billboardMatrix` adds its own `+8` to whatever it's given, expecting a
-- CORNER value the way a real NPC's `npc.px` is one; this file's stored
-- `wx`/`wz` are already the death point's real CENTER (`npcCenter`'s own
-- +8,+8), so passing them unadjusted double-counted that offset.
local function makeGibEntity(g)
  local wx, wz = g.wx, g.wz
  local cornerX, cornerZ = wx - 8, wz - 8
  return {
    passable = true,
    px = cornerX, py = cornerZ,
    cellX = math.floor(wx / 16), cellY = math.floor(wz / 16),
    -- The classic, non-voxel 2D render path (`OverworldController.lua:
    -- 4740-4742`) walks `ow.entities` unconditionally and calls
    -- `e:draw(camX, camY)` on every entry -- a real gap this header
    -- comment's own earlier "PKDOOM MODE's own camera lock keeps the
    -- flat path from ever running while the mode is on" note had
    -- anticipated but never actually guarded against. Confirmed as a
    -- LIVE crash (`attempt to call method 'draw' (a nil value)`) once
    -- `lib/DoomItems.lua`'s own item entities -- present from the very
    -- first frame of any map load, unlike a gib which needs a kill
    -- first -- hit the exact same gap on a fresh boot, before the
    -- camera lock had necessarily forced the voxel rung yet. Added here
    -- too, defensively, since a gib is exposed to the identical risk,
    -- just less often. A safe no-op, not a real 2D draw -- `:pose()`
    -- below is this entity's real rendering path.
    draw = function() end,
    pose = function()
      local state = XDIE_STATES[g.index]
      local spriteName = state and state.sprite or XDIE_STATES[1].sprite
      local image = loadGibSprite(spriteName)
      if not image then
        spriteName = XDIE_STATES[1].sprite
        image = loadGibSprite(spriteName)
      end
      -- FIXED 2026-08-06 -- `if not image then return nil end` used to
      -- sit here, returning ONE value instead of the six `VoxelScene.
      -- lua`'s own `posesOf` (its real line 521/526) unconditionally
      -- destructures (`sprite, vx, vy, ... = e:pose()`), then computes
      -- `e.py - vy` with no nil check -- a bare-nil `pose()` return
      -- crashed the ENTIRE voxel 3D pipeline, not just this one gib,
      -- confirmed by a real crash log from `lib/DoomDemons.lua`'s own
      -- identical bug (see that file's own header comment on this same
      -- date for the full trace -- this file's copy of the same pattern
      -- is fixed the same way here). `image` may still be `nil`; that's
      -- fine, everything downstream already tolerates it via pcall.
      local spriteObj = {
        def = {
          pokedoomGib = true, pokedoomSpriteName = spriteName,
          pokedoomImage = image, trueColor = true, image = "pokedoom-gib",
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      return spriteObj, cornerX, cornerZ, "down", 0, false
    end,
  }
end

local function removeGibEntity(ow, g)
  g.inserted = false
  if not (g.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == g.entity then table.remove(ow.entities, i) break end
  end
  g.entity = nil
end

-- ------- keeping each gib's fake entity in `ow.entities`
--
-- `ow.entities` is rebuilt fresh by the engine on every map (re)load --
-- the same reason `sweepKilled` below has to re-remove killed NPCs every
-- time, not just once -- so a gib's own entity has to be re-inserted the
-- same way, not assumed to persist. Runs every `input.step` tick (cheap
-- at this mod's gib counts): for the CURRENTLY loaded map, makes sure
-- each of ITS gibs' entities are present; a gib on a different map is
-- simply left alone (its entity was already dropped by the engine's own
-- rebuild when the player left that map, and gets re-added the same way
-- if they come back).
--
-- Torn down entirely -- not just left stale -- whenever PKDOOM MODE is
-- off: the classic (non-voxel) 2D render path ALSO walks `ow.entities`
-- and calls `e:draw(camX, camY)` on each one (`OverworldController.lua`'s
-- own flat-path draw loop). PKDOOM MODE's own camera lock (`lib/DoomView.
-- lua`) keeps the flat path from running MOST of the time, but not
-- provably always -- a real, LIVE crash (`attempt to call method 'draw'
-- (a nil value)`) confirmed this gap is reachable on a fresh map load,
-- before the camera lock has necessarily forced the voxel rung yet
-- (found via `lib/DoomItems.lua`'s own item entities, which are present
-- from the very first frame of any map, unlike a gib which needs a kill
-- first and so rarely overlapped this exact window). Fixed at the root
-- with a defensive no-op `:draw()` on `makeGibEntity`'s own returned
-- table (see that function's own comment) rather than trusted to tearing
-- down on OFF alone -- that teardown below is still worth keeping (the
-- same "OFF changes nothing" posture every other part of this mod
-- follows), just no longer the ONLY thing standing between this and a
-- crash.
-- FIX 2026-08-09 -- Phase 26 lag audit: this used to re-scan the WHOLE
-- of `ow.entities` every tick, for every gib, just to check "am I
-- already inserted" -- true essentially 100% of the time after a gib's
-- own first frame, since gibs are PERMANENT (never removed on the same
-- map). With gibs accumulating across a real play session, this was a
-- genuine O(gibs × entities) cost that only got WORSE the longer a
-- session ran -- confirmed as the worst single instance of a pattern
-- independently found in five other files this same audit round
-- (`DoomItems`/`DoomPuff`/`DoomBlood`'s own sync functions, `DoomDemons`'
-- `syncDemons`/`updateDemonProjectiles`, `DoomWeapons`'
-- `updateProjectiles`). Fixed the same way in all six: track membership
-- with a real flag (`g.inserted`) set once at actual insertion, instead
-- of re-deriving it by scanning every tick. The ONE real reason the
-- original scan existed at all -- `ow.entities` gets rebuilt fresh by
-- the engine on a map (re)load, so a stale flag could otherwise miss a
-- genuine reinsertion -- is handled by tracking the map id: any change
-- invalidates every gib's own flag in one pass, the same real "map
-- (re)load invalidates this" signal `lib/DoomItems.lua`'s own
-- `lastMapId` tracking already established as this project's proven
-- pattern for exactly this problem.
local lastGibEntitiesMapId = nil
local function syncGibEntities(ow)
  local mapId = ow and ow.map and ow.map.id
  if mapId ~= lastGibEntitiesMapId then
    for _, g in ipairs(gibs) do g.inserted = false end
    lastGibEntitiesMapId = mapId
  end
  for _, g in ipairs(gibs) do
    if Options.enabled() and ow and ow.entities and g.mapId == mapId then
      g.entity = g.entity or makeGibEntity(g)
      if not g.inserted then
        table.insert(ow.entities, g.entity)
        g.inserted = true
      end
    else
      removeGibEntity(ow, g)
    end
  end
end

-- Advances a single gib entry `g` to its current `XDIE_STATES[g.index]`.
-- Once `g.index` reaches the `domTics = -1` sentinel state, `g.tics`
-- latches at -1 and `tickGibs` below simply stops advancing that entry --
-- there is no "past the last state" case to guard here in practice, since
-- a -1 `tics` value never counts down to trigger another advance.
local function gibAdvance(g)
  local state = XDIE_STATES[g.index]
  if not state then return end
  if state.domTics < 0 then
    g.tics = -1
  else
    local exact = g.ticAccum + state.domTics * 60 / 35
    g.tics = math.floor(exact)
    g.ticAccum = exact - g.tics
  end
  if state.slop then playSound("DSSLOP") end
end

-- wx/wy/wz: the NPC's own real death position (ground height at its
-- cell, captured once by `kill` before the NPC is removed). `mapId`:
-- which map this corpse belongs to (`ow.map.id`) -- see `syncGibEntities`
-- for why. Appends rather than overwrites, so an earlier still-animating
-- (or already frozen/permanent) gib is untouched by a later kill.
local function startGib(wx, wy, wz, mapId)
  local g = { index = 1, tics = 0, ticAccum = 0, wx = wx, wy = wy, wz = wz, mapId = mapId }
  gibAdvance(g)
  table.insert(gibs, g)
end

-- Advances every active gib's animation by one frame. A gib that has
-- already reached the `domTics = -1` freeze state is a no-op here forever
-- after (real DOOM's own corpse never animates again either) -- this is
-- what makes the last frame a PERMANENT sprite rather than something that
-- needs separate "done, now hold" bookkeeping.
local function tickGibs()
  for _, g in ipairs(gibs) do
    if g.tics >= 0 then
      g.tics = g.tics - 1
      if g.tics <= 0 then
        g.index = g.index + 1
        gibAdvance(g)
      end
    end
  end
end

-- ------- world-state: remove the NPC for real, persist the kill
--
-- Mirrors the host's own `save.defeatedTrainers[npc.id] = true` pattern
-- exactly (`gen1recomp-dev/src/world/OverworldController.lua:2914-2921,
-- 2992`) -- same key shape (`npc.id`, already a stable
-- "<mapId>_obj_<index>" string, `NPC.lua:23`), same "a flat table on
-- `Game.save`, checked to keep something gone across sessions" idea,
-- just this mod's own sibling table rather than editing the host's.
-- FIX 2026-08-11 -- user report: an NPC noticed the player (the classic
-- Pokemon "!" trainer-sight bubble), started walking over to talk, and
-- the player's own movement froze to focus attention on them (real,
-- correct base-engine behavior -- `OverworldState:startTrainerApproach`,
-- `gen1recomp-dev/src/world/OverworldController.lua:3211-3238`) -- but
-- killing the NPC before it reached the player left the player stuck,
-- unable to move, forever: "i got stuck waiting for him to talk to me
-- and never hearing him because hes dead." The user's own follow-up
-- asked for a full audit, correctly guessing "this is likely going to
-- be a recurring bug based on how encounters work."
--
-- Root cause, confirmed by reading `OverworldController.lua` directly:
-- `self:update()` (line ~1051) gates the player's OWN movement input
-- (`self:handleInput()`) behind FIVE flags ORed together: `self.runner:
-- isRunning()`, `#self.scriptMoves > 0`, `self.engaging`, `self.emote`,
-- `self.teleportOut`. A trainer sighting sets `self.engaging = true`
-- (`startTrainerApproach`, line 3212) and, while the "!" bubble is up,
-- `self.emote = { npc = npc, ... }` (line 3228) -- once the bubble ends,
-- the walk-up itself is a `self:scriptMove(npc, npc.facing, dist-1,
-- fight)` entry (line 3232), stored in `self.scriptMoves` with a direct
-- `entity = npc` reference (line 4174). `self.engaging` only EVER resets
-- to `false` inside `fight()`'s own completion callback (line 3223),
-- which only fires once the walk-up genuinely finishes and a real battle
-- starts. None of these three mechanisms has any cancellation path for
-- "the NPC I'm tracking no longer exists" -- once this mod's own kill
-- path (`removeNpc`, called from both the player's own weapon hits and
-- `lib/DoomDemons.lua`'s citizen-kill path) pulls the NPC out of
-- `ow.npcs`/`ow.entities`, the base engine simply stops calling
-- `npc:update()` on it every frame (that loop only walks `self.npcs`,
-- `OverworldController.lua:1034-1036`) -- so a queued `scriptMove` whose
-- `mv.entity.moving` field can now never change again NEVER completes
-- (`updateScriptMoves`'s own finish check, line 4199, waits on exactly
-- that field), its `onDone` NEVER fires, `self.engaging`/`self.emote`
-- stay set forever, and `self:handleInput()` -- therefore the player's
-- own movement -- never runs again for the rest of the session. Per
-- CLAUDE.md's own "addon, not a fork" rule, this can't be fixed inside
-- `OverworldController.lua` itself -- fixed here instead, the one place
-- every NPC removal in this whole mod already funnels through, by
-- detecting whether the NPC being removed was the live subject of one of
-- these three mechanisms and unwinding it the same way the engine's own
-- completion path would have, just early.
local function releaseOrphanedEncounterState(ow, npc)
  local okOS, OverworldState = pcall(require, "src.world.OverworldController")
  -- `OverworldState` is only needed here to confirm `ow` really is a live
  -- overworld instance of that class before poking its own fields --
  -- matches this file's own existing precedent (`sweepKilled`'s sibling
  -- functions) of requiring the module without ever calling into it.
  if not (okOS and OverworldState and ow) then return end

  -- The "!" bubble phase: `self.emote.npc` is a direct reference, no
  -- ambiguity possible.
  if ow.emote and ow.emote.npc == npc then
    ow.emote = nil
  end

  -- The walk-up phase: drop any queued scriptMove entries for this NPC
  -- (both the NPC's own walk toward the player, `startTrainerApproach`'s
  -- `dist-1` step, and -- for full generality against any OTHER
  -- scriptMove-driven sequence this same orphaning could hit, e.g. a
  -- story cutscene's own NPC walk -- ANY entry whose `entity` is this
  -- NPC). Removed WITHOUT calling `onDone`: that callback expects the
  -- move to have genuinely completed and the NPC to still be valid,
  -- neither of which is true here -- silently dropping the entry is the
  -- honest equivalent of "this part of the sequence can no longer
  -- happen," not a fabricated success.
  if ow.scriptMoves then
    local wasTrackingThisNpc = false
    for i = #ow.scriptMoves, 1, -1 do
      local mv = ow.scriptMoves[i]
      if mv.entity == npc then
        wasTrackingThisNpc = true
        table.remove(ow.scriptMoves, i)
      end
    end
    -- Only a TRAINER's own approach walk ties `self.engaging` to a
    -- specific NPC this way -- a non-trainer scriptMove (a story NPC
    -- wandering as part of a cutscene) never sets `self.engaging` at
    -- all, so this reset is scoped to exactly the mechanism it's meant
    -- to close, not a blanket "any scriptMove involving any NPC."
    if wasTrackingThisNpc and ow.engaging then
      ow.engaging = false
    end
  end

  -- Belt-and-suspenders: if `self.engaging` is still true and this NPC
  -- is a trainer, release it even if neither of the two live references
  -- above caught it -- e.g. the walk-up already finished and
  -- `self.engaging` is being held by `engageTrainer`'s own pre-battle-
  -- text window (`fight()`, line 3220-3224) with no scriptMove/emote
  -- left pointing at this NPC at all. Gated on `npc.frozen == true`,
  -- NOT just "any trainer" -- `startTrainerApproach` sets `npc.frozen =
  -- true` the instant an engage begins (line 3213) and only clears it in
  -- the same completion callback that clears `self.engaging` itself
  -- (line 3222), so it's the engine's own real, live marker for
  -- "this specific NPC is the one currently engaging the player."
  -- Without this check, killing some OTHER, unrelated idle trainer
  -- elsewhere on the map while a DIFFERENT trainer's approach is still
  -- genuinely in progress (`self.engaging` true, but for that other
  -- trainer) would wrongly release the real, still-legitimate engage --
  -- narrow since `self.engaging` already blocks the player's own
  -- classic movement, but PKDOOM's first-person camera/weapon-fire is a
  -- separate system not gated by it, so shooting an unrelated NPC while
  -- frozen-in-place is genuinely possible.
  if ow.engaging and npc.frozen then
    ow.engaging = false
  end
end

local function removeNpc(ow, npc)
  pcall(releaseOrphanedEncounterState, ow, npc)
  for i, e in ipairs(ow.entities or {}) do
    if e == npc then table.remove(ow.entities, i) break end
  end
  for i, e in ipairs(ow.npcs or {}) do
    if e == npc then table.remove(ow.npcs, i) break end
  end
end

-- Runs every tic regardless of PKDOOM MODE, same as `defeatedTrainers`
-- itself is always honored: a kill is a permanent world-state change,
-- not something that un-happens when the mode is switched off. `ow.npcs`
-- is rebuilt fresh on every map load (OverworldController.lua:386-393),
-- so this sweep is what makes a previously-killed NPC stay gone when the
-- player leaves and comes back -- there is no seam to hook the host's
-- own (private, unexported) `objectVisible` filter directly.
local function sweepKilled(ow)
  local ok, Game = pcall(require, "src.core.Game")
  local killed = ok and Game.save and Game.save.killedNpcs
  if not killed then return end
  for i = #(ow.npcs or {}), 1, -1 do
    local npc = ow.npcs[i]
    if npc and killed[npc.id] then removeNpc(ow, npc) end
  end
end

-- Phase 18 Bug 2: `ow.ghosts` (`OverworldController.lua:512-550`,
-- `rebuildNeighbors`) is a THIRD, separate list of "visual-only NPCs on
-- connected maps" -- built from the same `objectVisible`/`pooledNPC`
-- spawn path a real map entry uses, sharing the SAME pooled instances as
-- `ow.npcs`, but with no filtering on `save.killedNpcs` at all (base-
-- engine code, no awareness of this mod's own sibling table). Rebuilt
-- fresh on every `rebuildNeighbors()` call -- every map transition AND
-- every render-view-size change, not just transitions -- so this has to
-- sweep every tick, the same reason `sweepKilled` above does. Each
-- entry's own shape is `{ npc, map, ox, oy, peers }`
-- (`OverworldController.lua:544-546`) -- confirmed by direct read, not
-- assumed. No gib needs inserting here: real DOOM has no concept of a
-- visible corpse on a map the player isn't standing on either: removing
-- the stale ghost (so the killed NPC simply isn't rendered from a
-- distance) is the correct, non-buggy behavior on its own.
local function sweepKilledGhosts(ow)
  local ok, Game = pcall(require, "src.core.Game")
  local killed = ok and Game.save and Game.save.killedNpcs
  if not (killed and ow and ow.ghosts) then return end
  for i = #ow.ghosts, 1, -1 do
    local ghost = ow.ghosts[i]
    if ghost and ghost.npc and killed[ghost.npc.id] then
      table.remove(ow.ghosts, i)
    end
  end
end

-- Phase 18 Bug 3: RESPAWN NPCS clearing `save.killedNpcs` used to only
-- clear a flag -- nothing re-inserts a respawned NPC into the CURRENTLY
-- loaded map's own `ow.npcs`/`ow.entities` except a real map transition's
-- `setMap` rebuild (`OverworldController.lua:386-393`), so the respawn
-- only ever became visible after leaving and re-entering. Mirrors that
-- same rebuild directly, without waiting for one: `OverworldState.
-- objectVisible`/`.pooledNPC` are both real, explicitly exposed reuse
-- points (`OverworldController.lua:125,144`, "exposed for tests +
-- reuse"), not private locals -- confirmed by direct read before writing
-- this, not assumed. Deliberately ADDS ONLY what's missing rather than
-- wiping and rebuilding `ow.entities` the way `setMap` itself does: a
-- full wipe would also have to know how to re-insert whatever `lib/
-- DoomItems.lua`'s own item entities and this file's own gib entities
-- happen to be doing that same frame, which isn't this function's
-- concern -- both already resync themselves independently every tick.
local function respawnCurrentMap(ow)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save and Game.data) then return end
  if not (ow and ow.map and ow.map.def and ow.map.def.objects) then return end
  local okOS, OverworldState = pcall(require, "src.world.OverworldController")
  if not okOS then return end
  ow.npcPool = ow.npcPool or {}
  ow.npcs = ow.npcs or {}
  ow.entities = ow.entities or {}
  for _, obj in ipairs(ow.map.def.objects) do
    if OverworldState.objectVisible(Game.save, ow.map.id, obj) then
      local npc = OverworldState.pooledNPC(ow.npcPool, Game.data, ow.map.id, obj)
      local present = false
      for _, existing in ipairs(ow.npcs) do
        if existing == npc then present = true break end
      end
      if not present then
        npc.frozen = false -- matches setMap's own real rebuild, OverworldController.lua:390
        table.insert(ow.npcs, npc)
        table.insert(ow.entities, npc)
      end
    end
  end
end

-- Both `kill` below and the raycast resolver further down need an NPC's
-- own world-space center point -- defined here, ahead of both, rather
-- than after (Lua has no hoisting for locals: a `local function` is only
-- visible from its own definition point onward in the enclosing chunk).
local function npcCenter(npc)
  local px = npc.px or (npc.cellX and npc.cellX * 16)
  local py = npc.py or (npc.cellY and npc.cellY * 16)
  if not (px and py) then return nil end
  return px + 8, py + 8
end

-- The Pikachu follower (`npc.pikachuFollower == true`, gen1recomp-dev/
-- src/world/PikachuFollower.lua:141) is a real member of `ow.npcs`, so
-- the generic resolver below finds it with no special-case iteration.
-- Per CLAUDE.md's Locked Decision 4, killing it should route through the
-- SAME permanent-removal-with-confirmation consequence as killing your
-- own active Pokemon in battle (via `PikachuFollower.starterInParty`,
-- tying it to a real party member) -- STILL not implemented here (a
-- separate, pre-existing, documented gap -- unaffected by the Wilds of
-- Kanto fix directly below, which is a genuinely different follower
-- system with its own real party-slot reference already attached to
-- each NPC, `npc.pokepcMon`, unlike the Pikachu case, which has none).
-- This still removes the follower from the world and gibs it like any
-- other NPC (so the player isn't left staring at nothing happening) but
-- logs a clear notice that the party-removal half is not wired in yet
-- -- see phases/phase-8-kill-mechanic.md's own checklist.
--
-- FEATURE 2026-08-10 -- user report: "when you kill a pokemon following
-- the player in the mod source code overworld-spawn-mod-main 2, aka
-- wilds of kanto, it respawns the pokemon and it stays in the same
-- position the player is in, instead of following them. it should stay
-- dead and get removed from the players roster of pokemon... make it so
-- this only happens when the mod wilds of kanto is enabled." Root cause
-- (confirmed by reading that mod's own source directly, never edited --
-- CLAUDE.md's addon-not-a-fork rule applies to every dependency, not
-- just the host voxel mod): Wilds' own `ControlEngine:syncTrailers`
-- (`lib/follower/control_engine.lua`) rebuilds "which party members want
-- a trailer" fresh from `game.save.party` every real tick, and its own
-- `Selection:reconcile` already has a genuine "selected mon fainted or
-- removed -> fall back to the next healthy one" branch -- but this
-- mod's own kill code only ever removed the visible NPC, never touched
-- `save.party` itself, so Wilds still saw a perfectly healthy party
-- member wanting a trailer and unconditionally recreated one the very
-- next tick, landing it wherever `_seedTrailBehind`'s own "no real
-- trail yet" fallback parks a fresh pack: directly on the player's own
-- cell (`control_engine.lua:1440-1454`) -- exactly the reported
-- symptom. Every live Wilds-created trailer NPC already carries a
-- direct reference to its own real party-slot table,
-- `npc.pokepcMon = mon` (`control_engine.lua:832`) -- fixed by actually
-- removing that exact table from `save.party` on kill, the same real
-- permanent-removal shape the base engine's own PC-release flow already
-- uses (`table.remove`, `gen1recomp-dev/src/ui/BoxMenu.lua:130`). Once
-- `save.party` itself reflects the death, Wilds' own already-existing
-- fallback logic simply stops wanting to recreate anything for that
-- slot -- no further changes needed on Wilds' own side, and none of its
-- files were touched to get there.
local function removeFollowerFromParty(npc)
  if not npc.pokepcMon then return end
  -- Explicit presence check (direct user request: "this should only
  -- happen when the mod wilds of kanto is enabled") -- `V.mod.find`,
  -- the same real, sanctioned mod-lookup `main.lua` already uses for
  -- this mod's own host dependency. `npc.pokepcMon` itself can only
  -- ever be set by Wilds in the first place, so this is belt-and-
  -- suspenders clarity, not load-bearing safety.
  if not V.mod.find("overworld_wild_spawns") then return end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save and Game.save.party) then return end
  for i, mon in ipairs(Game.save.party) do
    if mon == npc.pokepcMon then
      table.remove(Game.save.party, i)
      if DoomHud and DoomHud.announceKill then
        local nameOk, name = pcall(function()
          return mon.nickname or Game.data.pokemon[mon.species].name
        end)
        DoomHud.announceKill(
          (nameOk and name or "Your Pokemon") .. " was killed! Removed from your party.")
      end
      return
    end
  end
end

-- Forward-declared (Lua has no hoisting for locals) -- the real body,
-- with its own full derivation, sits further down next to
-- `overworldNpcResolver`, its other real caller. Checked here too, not
-- just at the resolver level, as a defensive backstop against ANY
-- caller of `kill()` -- specifically `lib/DoomDemons.lua`'s own citizen-
-- kill path (`DoomKill.killNpc`, a roaming demon catching an NPC),
-- which never goes through `overworldNpcResolver`/`overworldNpcAoeResolver`
-- at all and would otherwise still be able to kill a story-critical NPC
-- mid-cutscene, the exact same risk this fix exists to close.
local cutsceneLockActive

local function kill(ow, npc)
  if ow and cutsceneLockActive(ow) then return end
  if npc.pikachuFollower then
    print("[PokeDoom] killed the following Pikachu -- permanent party " ..
          "removal is NOT implemented yet (phases/phase-8-kill-mechanic.md)")
  end
  pcall(removeFollowerFromParty, npc)
  local ok, Game = pcall(require, "src.core.Game")
  if ok and Game.save then
    Game.save.killedNpcs = Game.save.killedNpcs or {}
    Game.save.killedNpcs[npc.id] = true
  end
  -- Captured BEFORE removal -- npcCenter/groundAt both need the NPC's
  -- (or its cell's) own live fields, gone once removeNpc runs.
  local wx, wz = npcCenter(npc)
  local wy = DoomGround.heightAt(ow.map, npc.cellX, npc.cellY)
  removeNpc(ow, npc)
  startGib(wx, wy, wz, ow.map and ow.map.id)
end

-- Public entry point for anything else that needs to kill an `ow.npcs`
-- member through this exact same path (persistence, gib, Pikachu-notice)
-- without duplicating it -- added for Phase 21's own ambient demon AI
-- (`lib/DoomDemons.lua`), which needs to kill a citizen NPC a roaming
-- demon catches, the identical real consequence a player's own weapon
-- already triggers.
DoomKill.killNpc = kill

-- ------- the raycast hit-test against ow.npcs
--
-- Restated from the host's own HordeGun.lua `pick` (DramaticShapeVoxel-
-- Mod-dev/lib/HordeGun.lua:281-311) against a DIFFERENT list (`ow.npcs`
-- instead of `HordeMobs.list()`), since that function is a private local
-- there, not an exported seam -- same ray-projection/cylinder-radius/
-- vertical-band math, restated rather than reused, matching this file's
-- own precedent for `terrainRange` in DoomWeapons.lua. `r` is the same
-- `{ox, oy, oz, dx, dy, dz}` array `DoomWeapons.hitscan` builds and every
-- resolver receives.
local HIT_RADIUS = 6 -- world px, matches HordeGun.HIT_RADIUS

-- FIX 2026-08-10 -- user report + screenshot: an impact effect (blood
-- here; the equivalent bug for a projectile's own explosion sprite is
-- `lib/DoomDemons.lua`'s own `demonResolver`, same root cause) could
-- render BEHIND the target instead of on its near-facing surface,
-- worst at close range. Restated from `lib/DoomDemons.lua`'s own
-- `nearEntryT` (see that function's own header comment for the full
-- derivation) rather than shared, matching this file's own established
-- "restate small pure-shape pieces per file" precedent (cited a few
-- lines up, for the identical reason). `t = ((mx-ox)*dx+(mz-oz)*dz)/
-- flat` below is the ray's closest-approach-to-CENTER parameter --
-- correct for picking which NPC is nearest along the ray, but not
-- where the ray actually crosses the target's own hit-cylinder
-- surface. This solves the real ray-vs-circle intersection for the
-- near root instead.
local function nearEntryT(ox, oz, dx, dz, flat, mx, mz, rad, fallbackT)
  local ex, ez = ox - mx, oz - mz
  local halfB = dx * ex + dz * ez
  local c = ex * ex + ez * ez - rad * rad
  local disc = halfB * halfB - flat * c
  if disc < 0 then return fallbackT end
  return (-halfB - math.sqrt(disc)) / flat
end

-- FEATURE 2026-08-10 -- direct user request: "if you kill a trainer, it
-- shows text pop up like normal text does in the game and says 'You're
-- a monster!! ? pokemon gained!' with ? being the amount of pokemon
-- added to your list." Real DOOM has no analog (this mod's own
-- addition, same "no DOOM precedent" category as the currency-per-kill
-- feature, `lib/DoomDemons.lua`). Player-only (called from this
-- resolver's own call site below, NOT from the shared `kill()` an
-- ambient demon also routes through, `lib/DoomDemons.lua`'s citizen
-- kills -- a demon killing a trainer isn't the PLAYER being a monster).
--
-- Confirmed by reading the base engine's own source directly (never
-- edited): a trainer's real team is fully readable from the overworld
-- NPC object itself, no battle required. `npc.def` is the raw map
-- object-event table (`gen1recomp-dev/src/world/NPC.lua:25`) and
-- already carries `trainerClass`/`trainerParty` the instant the NPC
-- spawns -- the SAME two fields `OverworldController.lua:2980`'s own
-- real `BattleState.newTrainer(Game, d.trainerClass, d.trainerParty)`
-- call reads to start a real battle. `Game.data.trainers[trainerClass].
-- parties[partyIndex]` (`data/generated/trainers.lua`) is the same
-- static `{species, level}` array `BattleState.lua:657-668` itself
-- reads -- no battle object needs to exist first.
--
-- `Pokemon.new(data, species, level)` + `BattleState.stampOT(save, mon)`
-- + `Party.add`, falling back to `Boxes.deposit` when the party is full,
-- mirrors `gen1recomp-dev/src/script/Commands.lua`'s own real
-- `give_pokemon` flow exactly (the base engine's own canonical "hand the
-- player a real Pokemon" path, confirmed by reading it directly) rather
-- than inventing a new one. Also sets `Game.save.defeatedTrainers[npc.
-- id] = true` -- not needed to stop a re-challenge (the NPC is already
-- gone from `ow.npcs` entirely once `kill()` runs, which is what both
-- the sight-check and the talk-to-trainer branch actually key off) but
-- confirmed real story scripts (`data/scripts/story3.lua`,
-- `story6.lua`) read this flag directly by id string, outside the
-- normal NPC-interaction path -- cheap insurance against a specific
-- trainer's death silently blocking unrelated quest logic.
local function grantTrainerReward(npc)
  if not (npc.def and npc.def.trainerClass) then return end
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.data and Game.save) then return end
  local trainer = Game.data.trainers and Game.data.trainers[npc.def.trainerClass]
  local partyDef = trainer and trainer.parties and trainer.parties[npc.def.trainerParty or 1]
  if not partyDef then return end

  Game.save.defeatedTrainers = Game.save.defeatedTrainers or {}
  Game.save.defeatedTrainers[npc.id] = true

  local okReq, Pokemon, Party, Boxes, BattleState = pcall(function()
    return require("src.pokemon.Pokemon"), require("src.pokemon.Party"),
           require("src.pokemon.Boxes"), require("src.battle.BattleState")
  end)
  if not okReq then return end

  local gained = 0
  for _, entry in ipairs(partyDef) do
    local monOk, mon = pcall(Pokemon.new, Game.data, entry.species, entry.level)
    if monOk and mon then
      pcall(BattleState.stampOT, Game.save, mon)
      local added = Party.add(Game.save.party, mon)
      if not added then
        added = Boxes.deposit(Game.save, mon) ~= nil
      end
      if added then gained = gained + 1 end
    end
  end

  if gained > 0 and DoomHud and DoomHud.announceKill then
    DoomHud.announceKill(("You're a monster!! %d Pokemon gained!"):format(gained))
  end
end

-- FEATURE 2026-08-10 -- user request: a new "PARTY KILL CONFIRMATION"
-- options row (default ON). Real DOOM has nothing to port for this --
-- CLAUDE.md's own Locked Decision 4 already calls for a confirmation
-- prompt on permanently removing your own Pokémon (written for the
-- still-unimplemented battle KILL command), so this generalizes that
-- design to the one REAL, already-implemented party-kill path today:
-- Wilds-of-Kanto follower kills (`removeFollowerFromParty` below,
-- `npc.pokepcMon`). Scoped to the direct-hit resolver only, not the AOE
-- (rocket splash/BFG spray) path just below -- a splash kill is much
-- more likely to be incidental than deliberate, and this project has no
-- existing "are you sure" modal dialog to reuse in a real-time
-- first-person shooting context, so a full confirmation UI for an AOE
-- hit isn't attempted here; flagged as a real, deliberate scope gap
-- rather than silently dropped.
--
-- The confirmation itself: the FIRST landed direct hit on a follower
-- Pokemon does NOT kill it -- it stamps a live timestamp on the NPC
-- table itself (`pokedoomKillConfirmAt`, same "stash a field directly on
-- the live npc" idiom this whole codebase already uses, e.g. `lib/
-- DoomDemons.lua`'s own `pokedoomBeingHunted`) and shows a warning. A
-- SECOND landed hit on the SAME npc within `PARTY_KILL_CONFIRM_WINDOW`
-- real seconds actually kills it; letting the window lapse resets back
-- to requiring two fresh hits. This is the real, functional equivalent
-- of a confirmation prompt that fits a real-time shooter (no pause, no
-- Y/N dialog needed) rather than an unbuilt, more elaborate modal.
local PARTY_KILL_CONFIRM_WINDOW = 3 -- real seconds

-- FIX 2026-08-10 -- user report (screenshot): this message ran off both
-- edges of the screen even at max resolution. Root cause: `DoomFont.
-- draw` (`lib/DoomFont.lua`) is a real, faithful port of DOOM's own
-- `HUlib_drawTextLine` (`hu_lib.c:99-139`), which SILENTLY CLIPS once a
-- line exceeds `SCREENWIDTH` (320px here) rather than wrapping -- real
-- DOOM's own message widget has no wrap at all, by design, and every
-- real DOOM message is short enough that this never mattered. This
-- mod's own original message (a Pokemon's name + " will be lost
-- forever! Shoot again to confirm.", 47 characters of fixed suffix
-- alone) was simply too long for a single 320px DOOM HUD line, so the
-- tail -- including the actual "shoot again to confirm" instruction --
-- got silently dropped exactly like real DOOM's own clip would drop any
-- other over-long line. Shortened the fixed suffix, AND measured
-- (`DoomFont.measure`, the same real per-glyph-width calculation
-- `DoomFont.draw` itself uses, not a guess) with the name truncated
-- further if even the shortened version still doesn't fit -- the name
-- is far less important to preserve than the actionable instruction, so
-- it's the first thing sacrificed rather than the last.
local PARTY_KILL_CONFIRM_SUFFIX = "! SHOOT AGAIN TO CONFIRM."

local function fitPartyKillMessage(name)
  local msg = name .. PARTY_KILL_CONFIRM_SUFFIX
  if DoomFont.measure(msg) <= 320 then return msg end
  while #name > 0 and DoomFont.measure(name .. PARTY_KILL_CONFIRM_SUFFIX) > 320 do
    name = name:sub(1, #name - 1)
  end
  return name .. PARTY_KILL_CONFIRM_SUFFIX
end

local function partyKillNeedsConfirm(npc)
  return npc.pokepcMon ~= nil and Options.partyKillConfirmationEnabled()
end

-- Returns true if this hit should proceed to a real kill (either
-- confirmation isn't required, or a prior hit within the window already
-- armed it); false means this hit was consumed as the WARNING shot.
local function checkPartyKillConfirm(npc)
  if not partyKillNeedsConfirm(npc) then return true end
  local now = love.timer and love.timer.getTime() or 0
  local pending = npc.pokedoomKillConfirmAt
  if pending and (now - pending) <= PARTY_KILL_CONFIRM_WINDOW then
    npc.pokedoomKillConfirmAt = nil
    return true
  end
  npc.pokedoomKillConfirmAt = now
  if DoomHud and DoomHud.announceKill then
    local nameOk, name = pcall(function()
      local Game = require("src.core.Game")
      return npc.pokepcMon.nickname or Game.data.pokemon[npc.pokepcMon.species].name
    end)
    DoomHud.announceKill(fitPartyKillMessage(nameOk and name or "This Pokemon"))
  end
  return false
end

-- FIXED 2026-08-07 -- user report: "the bullets arent hitting this
-- pokemon npc. it seems better hitting actual demons though." Confirmed
-- the exact same bug class already found and fixed the same day in
-- `lib/DoomDemons.lua`'s own `demonResolver`, just never audited on
-- this SEPARATE resolver: the real auto-aim target for an NPC
-- (`lib/DoomWeapons.lua`'s `computeAutoAimPitch`, its own `consider(
-- npc.px+8, npc.py+8, gh+28)` call) aims at `gh+28` -- roughly an NPC's
-- own center-mass -- but this resolver's own vertical acceptance band
-- only ever ran from `gh-2` up to `gh+17`, 11 world units BELOW the
-- point the shot is actually aimed at. A correctly auto-aimed shot at
-- an NPC's own center would sail just above this window every time,
-- explaining exactly why demons (whose own resolver got the matching
-- fix earlier this same round) now land more reliably than NPCs, which
-- never got it. Widened to `gh+38` (the same real aim point, `28`, plus
-- the same `+10` tolerance `demonResolver`'s own fix uses) -- kept as a
-- restated literal `28` rather than a cross-file shared constant,
-- matching this project's own "restate small pure-shape pieces per
-- file" precedent, but cross-referenced here so the two don't silently
-- drift apart again without at least a paper trail.
-- FIX 2026-08-09 -- Phase 26 lag audit: same unconditional per-shot
-- `DoomLog.event` gap as `lib/DoomDemons.lua`'s own `demonResolver` (see
-- that file's own `logHitEvent` comment for the full derivation) -- a
-- plain module-local real-time throttle, not a per-NPC one (the miss
-- branch has no single NPC to attach a per-instance accumulator to).
local HIT_LOG_INTERVAL = 0.5 -- real seconds
local lastHitLogTime = 0
local function logHitEvent(...)
  local now = love.timer and love.timer.getTime() or 0
  if now - lastHitLogTime < HIT_LOG_INTERVAL then return end
  lastHitLogTime = now
  DoomLog.event(...)
end

-- FEATURE 2026-08-10 -- user request: "add an option for 'pokemon gore'
-- which will have 4 settings 'NPCs, Pokemon, All, None' which will
-- disable killing either pokemon npcs, pokemon, all of them, or not be
-- able to kill anything other than doom demons." Distinguishes a real
-- Pokemon entity from a human trainer/citizen within the SAME `ow.npcs`
-- list this resolver already scans -- confirmed, by reading (never
-- editing) the base engine and the Wilds-of-Kanto mod directly, that
-- every real Pokemon-as-NPC case in this engine sets one of three live
-- fields: `npc.pikachuFollower` (base engine, Yellow's own real Pikachu
-- follower, `src/world/PikachuFollower.lua`); `npc.pokepcMon` together
-- with `npc.pokepcTrailerKind == "mon"` (Wilds' own real party-follower
-- trailers -- `pokepcTrailerKind == "trainer"` is a DIFFERENT, human
-- trainer-companion trailer Wilds also supports, confirmed by reading
-- `control_engine.lua`'s own `compositionDirty`/`makeTrailer` directly,
-- so checking `pokepcMon` alone without the kind check would wrongly
-- treat a trainer companion as a Pokemon); or `npc.wildsAmbientPokemon`
-- (Wilds' own separate peaceful ambient-town-Pokemon feature,
-- `lib/ambient_pokemon.lua`, confirmed real and already inserted into
-- `ow.npcs` with no special handling anywhere in this mod before now).
-- Any `ow.npcs` member matching none of these is a human NPC (a
-- trainer/citizen, or the Wilds trainer-companion case above).
--
-- Scoped to the PLAYER's own weapon resolver only, not the shared
-- `kill()` `lib/DoomDemons.lua`'s ambient citizen-hunting AI also routes
-- through -- same "player-only" boundary this file already draws for
-- `grantTrainerReward` just above, and matches the user's own framing
-- ("not be able to kill anything other than doom demons" describes what
-- YOU can shoot, not whether ambient demon AI keeps functioning).
-- A blocked NPC is filtered OUT of hit-candidate selection entirely
-- (shots pass through it, same as a real DOOM actor with no
-- `MF_SHOOTABLE`) rather than registering a hit that then does nothing
-- -- the closest real analog, and avoids a broken-looking "impact with
-- no consequence."
local function isPokemonNpc(npc)
  return npc.pikachuFollower == true
    or npc.wildsAmbientPokemon == true
    or (npc.pokepcTrailerKind == "mon" and npc.pokepcMon ~= nil)
end

-- FEATURE 2026-08-10 -- direct user request: "add setting to doom
-- settings: Party Killing (so you can disable being able to kill your
-- party at all, so the bullets will just fly through them to whatever
-- target is past them." Distinct from `isPokemonNpc` above: THAT
-- catches every real Pokemon-as-NPC case (including Wilds' own
-- ambient, not-yours town Pokemon, `wildsAmbientPokemon`), where this
-- one is narrower on purpose -- specifically the two real cases that
-- represent an actual `save.party` slot: the Wilds-of-Kanto follower
-- (`pokepcTrailerKind == "mon"` + a real `pokepcMon` reference, the
-- same real check `partyKillNeedsConfirm` below already uses) and
-- Yellow's own real Pikachu follower (`npc.pikachuFollower`,
-- `PikachuFollower.starterInParty`) -- both are literally "your party,"
-- not just "a Pokemon."
local function isPartyNpc(npc)
  return npc.pikachuFollower == true
    or (npc.pokepcTrailerKind == "mon" and npc.pokepcMon ~= nil)
end

-- FIX 2026-08-11 -- direct follow-up to this same day's "killed a
-- trainer mid-approach, stuck forever" fix (`removeNpc`'s own
-- `releaseOrphanedEncounterState`, this file's own header comment for
-- the full derivation): that fix closes the "player froze, NPC died"
-- half of the risk; this closes the OTHER, larger half the same audit
-- flagged but deliberately deferred -- "audit the gen1recomp code and
-- make sure there arent more around to fix," direct user request, then
-- "lets address it" once the gap was reported.
--
-- Story cutscenes (Oak's intro, rival battles, gym leader scripts, the
-- Safari Zone -- `data/scripts/story*.lua`) drive their own NPCs through
-- the base engine's SCRIPT RUNNER (`ow.runner`), not just `scriptMove`/
-- `emote` -- `releaseOrphanedEncounterState` has no visibility into a
-- running script's own internal state (which fields it reads off an
-- NPC, whether it expects to keep driving that NPC later in the SAME
-- script), so killing a story-critical NPC mid-cutscene could still
-- error or hang a script in ways that fix can't reach. Rather than try
-- to identify and protect only the "important" NPC a given script
-- happens to care about (no clean, general signal for that exists),
-- this closes the window itself: while a script is actively running, no
-- NPC on the current map is a valid kill target at all (a shot passes
-- through, the same "not a valid target" mechanism POKEMON GORE/PARTY
-- KILLING already use above, not a broken-looking blocked hit).
--
-- Deliberately checks ONLY `ow.runner:isRunning()`, NOT the other four
-- flags `self:update()`'s own `scripted` condition also ORs together
-- (`#self.scriptMoves > 0`, `self.engaging`, `self.emote`, `self.
-- teleportOut`, `gen1recomp-dev/src/world/OverworldController.lua`
-- ~line 1051) -- confirmed by reading `ScriptRunner:isRunning()`
-- directly (`true` for the entire span a script's own coroutine is
-- suspended waiting on a callback, e.g. a scriptMove's `onDone` mid-
-- cutscene, not just while actively executing a row THIS frame) that
-- every real script-driven scriptMove already keeps `isRunning()` true
-- for its own whole duration too, so this one check alone already
-- covers the story-cutscene risk in full. The plain trainer-sight "!"
-- approach (`startTrainerApproach`) is confirmed NOT routed through
-- `ow.runner` at all (direct `self.engaging`/`self.emote`/`self.
-- scriptMoves` fields only, no coroutine) -- checking those here too
-- would ALSO block killing an approaching trainer before it reaches
-- you, which is existing, intended PKDOOM behavior (this mod's own
-- overworld-NPC-killing feature is explicitly meant to cover any NPC,
-- trainers included) already made SAFE, not risky, by this same day's
-- earlier `releaseOrphanedEncounterState` fix -- narrowing to just
-- `isRunning()` closes the one remaining real gap without taking that
-- gameplay away.
--
-- Forward-declared above `kill()` (this file's own earliest real
-- caller) since Lua has no hoisting for locals -- this is the real
-- assignment.
cutsceneLockActive = function(ow)
  if not ow then return false end
  local ok, running = pcall(function() return ow.runner and ow.runner:isRunning() end)
  return ok and running or false
end

local function npcKillBlocked(npc)
  -- PARTY KILLING off filters the player's own party followers out of
  -- hit-candidate selection entirely -- the exact same "not a valid
  -- target at all" mechanism POKEMON GORE already uses below, so a shot
  -- passes straight through to whatever's behind them, matching the
  -- user's own framing exactly. Checked FIRST/independently of POKEMON
  -- GORE (a party follower is also caught by `isPokemonNpc`, but this
  -- setting exists specifically so a player who's fine with shooting
  -- OTHER Pokemon can still protect their own party without having to
  -- block Pokemon-kills broadly).
  if isPartyNpc(npc) and not Options.partyKillingEnabled() then
    return true
  end
  if isPokemonNpc(npc) then
    return Options.pokemonKillsBlocked()
  end
  return Options.npcKillsBlocked()
end

-- Tests whether the ray (`ox,oy,oz` + `dx,dy,dz` * t) hits `npc`, closer
-- than whatever `bestT` has already been found -- returns the hit `t`,
-- or nil if this NPC isn't a valid/closer/in-range/on-height-band hit.
-- Extracted 2026-08-19 during a project-wide readability audit: this
-- used to be one 5-deep-nested block inline in `overworldNpcResolver`'s
-- own scan loop; early-return guard clauses read more directly than
-- that nesting did, no behavior change.
local function rayHitsNpc(ow, npc, ox, oy, oz, dx, dy, dz, flat, maxT, bestT)
  local mx, mz = npcCenter(npc)
  if not mx or npcKillBlocked(npc) then return nil end
  local t = ((mx - ox) * dx + (mz - oz) * dz) / flat
  if not (t > 0 and t < maxT and (not bestT or t < bestT)) then return nil end
  local hx, hz = ox + dx * t - mx, oz + dz * t - mz
  if hx * hx + hz * hz > HIT_RADIUS * HIT_RADIUS then return nil end
  local gh = DoomGround.heightAt(ow.map, npc.cellX, npc.cellY)
  local y = oy + dy * t
  if y < gh - 2 or y > gh + 38 then return nil end
  return t
end

local function overworldNpcResolver(ow, r, maxT, damage, weaponName)
  if not (ow and ow.npcs and ow.map) then return nil end
  if cutsceneLockActive(ow) then return nil end
  local ox, oy, oz, dx, dy, dz = r[1], r[2], r[3], r[4], r[5], r[6]
  local flat = dx * dx + dz * dz
  if flat < 1e-6 then return nil end
  local best, bestT
  for _, npc in ipairs(ow.npcs) do
    local t = rayHitsNpc(ow, npc, ox, oy, oz, dx, dy, dz, flat, maxT, bestT)
    if t then best, bestT = npc, t end
  end
  if not best then
    logHitEvent("HIT", "overworldNpcResolver: [%s] no NPC hit (%d NPC(s) on this map)",
      tostring(weaponName or "?"), #ow.npcs)
    return nil
  end
  logHitEvent("HIT", "overworldNpcResolver: [%s] hit NPC (name=%s) -> kill",
    tostring(weaponName or "?"), tostring(best.name or best.id))
  -- P_SpawnBlood (p_mobj.c:836-859), called from real DOOM's own hitscan
  -- traversal (PTR_ShootTraverse, p_map.c:1003-1008) on every landed hit
  -- regardless of whether it also kills -- this resolver always kills
  -- (Phase 8's own "every hit that lands is a kill" design) and, unlike
  -- `lib/DoomDemons.lua`'s own resolver, is never told how much damage
  -- the shot actually dealt (irrelevant here since any weapon is
  -- lethal) -- `DoomBlood.spawn`'s own nil-damage default (a full
  -- spurt) is the right call for a hit that's always fatal anyway.
  local bestMx, bestMz = npcCenter(best)
  local hitT = nearEntryT(ox, oz, dx, dz, flat, bestMx, bestMz, HIT_RADIUS, bestT)
  -- FIX 2026-08-11 -- same real gap as `lib/DoomWeapons.lua`'s own
  -- matching fix this round (see `lib/DoomPuff.lua`'s own header
  -- comment for the full render-contract derivation): the ray's own
  -- real termination height was available and never passed through.
  pcall(DoomBlood.spawn, ow, ox + dx * hitT, oz + dz * hitT, nil, oy + dy * hitT)
  -- PARTY KILL CONFIRMATION -- see that feature's own header comment
  -- above `partyKillNeedsConfirm`. A "needs confirmation, not armed yet"
  -- hit still registers (blood already spawned above, the ray still
  -- explodes against this target below) but does NOT kill or grant a
  -- trainer reward this shot.
  if checkPartyKillConfirm(best) then
    -- Trainer reward BEFORE removal -- `best.def` stays reachable on
    -- this Lua table regardless (`kill()` never clears it, only removes
    -- the table from `ow.entities`/`ow.npcs`), but reading it before the
    -- kill resolves keeps the two concerns in the same natural order the
    -- code already reads in (react to what was hit, then kill it).
    pcall(grantTrainerReward, best)
    pcall(DoomDeathScreen.punishEssentialKill, best)
    kill(ow, best)
  end
  -- Second return value, new 2026-08-10: see `lib/DoomDemons.lua`'s own
  -- `demonResolver`, same fix, same reasoning -- `lib/DoomWeapons.lua`'s
  -- `updateProjectiles` uses this to correct a projectile's own
  -- explosion sprite position instead of exploding wherever its raw
  -- per-tick step happened to leave it.
  return best, hitT
end

-- Real line-of-sight between two world points, restated from
-- `lib/DoomHordeTarget.lua`'s own `losClear` (itself restated from
-- `lib/DoomWeapons.lua`'s own private `terrainRange`, not an exported
-- seam) -- this project's own established "restate small pure-shape
-- pieces per file" precedent. DOOM's real `P_CheckSight` has no BSP
-- here to port; "does a straight ray from A to B ever dip below local
-- ground height" is this file's own established stand-in, the same
-- reasoning this file's own `occludedFromCamera` already uses for gib
-- visibility.
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
    local gh = DoomGround.heightAt(ow.map, cx, cy)
    if y < gh - 0.5 or y < 0 then return false end
    t = t + step
  end
  return true
end

-- FIXED 2026-08-08 -- direct user request: "audit doom source code...
-- make sure per weapon damage for every enemy is feature parity with
-- doom." A real, confirmed gap found by that audit: this file never
-- registered ANY `DoomWeapons.registerAoeResolver` at all -- only
-- `overworldNpcResolver` above (a direct-hit resolver). That means a
-- rocket's own real splash damage (`A_Explode`/`P_RadiusAttack`,
-- `p_map.c:1201-1233`) and the BFG's own real 40-ray spray
-- (`A_BFGSpray`, `p_pspr.c:781-811`) -- both of which `lib/DoomWeapons.
-- lua`'s own `explodeProjectile` DOES already emit as real AOE events
-- on every rocket/BFG detonation -- have been doing NOTHING to overworld
-- Pokemon NPCs this entire time: only a DIRECT hit (`overworldNpcResolver`
-- above) has ever killed one. A rocket landing at an NPC's feet without
-- a dead-center direct hit, or a BFG spray ray sweeping straight through
-- one, both currently do nothing at all -- a real, significant weapon-
-- vs-NPC parity gap, not a tuning issue. `lib/DoomDemons.lua`'s own
-- `demonAoeResolver` had the identical gap for BFG spray specifically
-- (fixed the same round, see that file's own matching header comment
-- for the full `A_BFGSpray` derivation) -- this is the NPC-side
-- equivalent, restated against `ow.npcs` instead of `demons`.
--
-- NPCs have no real HP pool of their own (Phase 8's own "every hit
-- that lands is a kill" design, unlike a real DOOM demon) -- so unlike
-- `demonAoeResolver`'s own damage-then-check-hp shape, a connecting
-- radius/spray hit here just kills directly, the same real consequence
-- `overworldNpcResolver` above already applies to a direct hit. Real
-- rocket splash still requires `damage > 0` (real `PIT_RadiusAttack`'s
-- own falloff can reach exactly 0 right at the very edge of the blast
-- radius) before that counts as a landed hit -- BFG spray always rolls
-- a real 15d8 (minimum 15), so any connecting ray is unconditionally
-- lethal, matching `demonAoeResolver`'s own identical shape.
--
-- Both branches below also respect the POKEMON GORE gate
-- (`npcKillBlocked`, defined above `overworldNpcResolver`) -- CLAUDE.md's
-- own "a fix to one implementation of a shared mechanic must be checked
-- against every parallel implementation" rule applied to this file's own
-- second, AOE kill path against the same `ow.npcs` list.
--
-- The real `A_Explode`/`P_RadiusAttack` rocket-splash case.
-- Iterated back-to-front: `kill(ow, npc)` removes the NPC from
-- `ow.npcs` (via `removeNpc`, this file's own established pattern),
-- which would shift indices out from under a forward loop mid-blast.
local function radiusAoeKill(ow, event)
  for i = #ow.npcs, 1, -1 do
    local npc = ow.npcs[i]
    local mx, mz = npcCenter(npc)
    if mx and not npcKillBlocked(npc) then
      local dx, dz = mx - event.x, mz - event.z
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist <= event.radius then
        local damage = math.floor(event.maxDamage * (1 - dist / event.radius))
        if damage > 0 then
          local gh = DoomGround.heightAt(ow.map, npc.cellX, npc.cellY)
          if losClear(ow, event.x, event.y, event.z, mx, gh, mz) then
            -- FIX 2026-08-11 -- same real gap as `overworldNpcResolver`'s
            -- own matching fix this round (`lib/DoomPuff.lua`'s header
            -- comment has the full render-contract derivation) -- this
            -- splash hit has no single ray to pull a termination height
            -- from, so it uses the NPC's own real center-mass height
            -- instead, the same point every other real aim/hit check in
            -- this project already targets on this same NPC.
            pcall(DoomBlood.spawn, ow, mx, mz, damage, gh + NPC_CARD_WORLD_HEIGHT / 2)
            pcall(DoomDeathScreen.punishEssentialKill, npc)
            kill(ow, npc)
          end
        end
      end
    end
  end
end

-- The real `A_BFGSpray` case: 40 independently aimed rays fanned across a
-- real 90-degree arc (`event.arc`/`event.rays`), each ray's own real
-- `P_AimLineAttack` finding the CLOSEST thing directly along THAT
-- ray's specific direction (not a radius sweep) -- restated as the
-- same ray-vs-cylinder closest-hit search `overworldNpcResolver`
-- above already uses for a single ray, run once per fan angle. A
-- kill from an earlier ray this same spray removes that NPC from
-- `ow.npcs`, which the NEXT ray's own fresh `ipairs(ow.npcs)` scan
-- correctly no longer sees -- no separate bookkeeping needed.
-- Finds the closest NPC hit by ONE fan ray from a spray AOE event's own
-- origin, reusing `rayHitsNpc` directly (the fan ray is horizontal only
-- -- `dy=0` matches real `A_BFGSpray`'s own flat-facing
-- `P_AimLineAttack` call, and `320` world px is the ray's own max
-- distance, matching `DoomHordeTarget`'s own identical constant --
-- otherwise the exact same closest-valid-hit test a single hitscan shot
-- already uses). Extracted 2026-08-19 during a project-wide readability
-- audit -- this used to be a second, ~20-line near-duplicate of
-- `rayHitsNpc`'s own inline logic, one level deeper-nested.
local function bestNpcForFanRay(ow, event, dx, dz, flat)
  local maxDist = 320
  local bestT, bestNpc, bestMx, bestMz, bestGh
  for _, npc in ipairs(ow.npcs) do
    local t = rayHitsNpc(ow, npc, event.x, event.y, event.z, dx, 0, dz, flat, maxDist, bestT)
    if t then
      bestT, bestNpc = t, npc
      bestMx, bestMz = npcCenter(npc)
      bestGh = DoomGround.heightAt(ow.map, npc.cellX, npc.cellY)
    end
  end
  return bestNpc, bestMx, bestMz, bestGh
end

local function sprayAoeKill(ow, event)
  for i = 0, event.rays - 1 do
    local angle = event.facing - event.arc / 2 + (event.arc / event.rays) * i
    local dx, dz = math.sin(angle), math.cos(angle)
    local flat = dx * dx + dz * dz
    if flat > 1e-6 then
      local bestNpc, bestMx, bestMz, bestGh = bestNpcForFanRay(ow, event, dx, dz, flat)
      if bestNpc and losClear(ow, event.x, event.y, event.z, bestMx, bestGh, bestMz) then
        -- FIX 2026-08-11 -- same real gap, same fix as the `radius`
        -- branch just above.
        pcall(DoomBlood.spawn, ow, bestMx, bestMz, nil, bestGh + NPC_CARD_WORLD_HEIGHT / 2)
        pcall(DoomDeathScreen.punishEssentialKill, bestNpc)
        kill(ow, bestNpc)
      end
    end
  end
end

local function overworldNpcAoeResolver(ow, event)
  if not (ow and ow.npcs and ow.map) then return end
  if cutsceneLockActive(ow) then return end
  if event.kind == "radius" then
    radiusAoeKill(ow, event)
  elseif event.kind == "spray" then
    sprayAoeKill(ow, event)
  end
end

-- ------- install

-- Clears every permanent gib AND its entity -- shared by RESPAWN NPCS
-- (below) and, as of Phase 18 Bug 5, a fresh save loading/starting.
-- Factored out rather than duplicated: both call sites need the exact
-- same "look up the live overworld, tear down every gib's entity, empty
-- the list" sequence.
local function resetGibs()
  local ok, ow = pcall(function() return require("src.core.Game").overworld end)
  if ok and ow then
    for _, g in ipairs(gibs) do removeGibEntity(ow, g) end
  end
  gibs = {}
end

-- FEATURE 2026-08-10 -- new "NPC RESPAWN TIMER" options row (OFF
-- (default) / 5 MIN / 10 MIN / 30 MIN, `lib/DoomOptions.lua`) -- an
-- automatic version of the manual RESPAWN NPCS row, firing
-- `Options.respawnAllNpcs` on a real countdown instead of only on a
-- button press. Gated on `Options.enabled()` and `FirstPerson.onTop()`
-- (CLAUDE.md's own pausing hard rule: any always-on `input.step` tick
-- that changes world state on its own must check this) so the countdown
-- genuinely freezes while paused rather than silently draining. A
-- setting CHANGE (off<->a duration, or between durations) restarts the
-- countdown fresh from the new duration rather than carrying over a
-- stale remaining value from whatever was running before.
local npcRespawnRemaining = nil
local lastNpcRespawnSeconds = nil

local function tickNpcRespawnTimer(dt)
  if not (Options.enabled() and FirstPerson.onTop()) then return end
  local seconds = Options.npcRespawnSeconds()
  if seconds ~= lastNpcRespawnSeconds then
    lastNpcRespawnSeconds = seconds
    npcRespawnRemaining = seconds
  end
  if not npcRespawnRemaining then return end
  npcRespawnRemaining = npcRespawnRemaining - dt
  if npcRespawnRemaining <= 0 then
    Options.respawnAllNpcs()
    npcRespawnRemaining = seconds
  end
end

local installed = false
function DoomKill.install()
  if installed then return end
  installed = true

  installGibMeshHook()

  DoomWeapons.registerTargetResolver(overworldNpcResolver)
  DoomWeapons.registerAoeResolver(overworldNpcAoeResolver)

  -- Clears every permanent gib on RESPAWN NPCS, alongside that row's own
  -- `save.killedNpcs` reset -- registered as a callback rather than
  -- `lib/DoomOptions.lua` requiring this file directly, since this file
  -- already requires `DoomOptions` (a direct require the other way would
  -- be a circular `DoomOptions -> DoomKill -> DoomOptions` load-order
  -- hazard). Same registry idiom as `DoomWeapons.registerTargetResolver`.
  -- Phase 18 Bug 3: also force-rebuilds the currently loaded map's own
  -- NPC list right here, so a respawn is visible immediately instead of
  -- only after the next real map transition.
  Options.onRespawnNpcs(function()
    resetGibs()
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    if ok and ow then pcall(respawnCurrentMap, ow) end
  end)

  -- Phase 18 Bug 5: `gibs` is a plain module-closure local with no save-
  -- lifecycle awareness of its own -- neither exiting to the title screen
  -- nor loading a different save restarts this mod's Lua state, so a
  -- stale gib from one save could otherwise render under a still-alive
  -- NPC in a completely different save. Real, public events
  -- (`gen1recomp-dev/src/core/Game.lua`'s `restoreSave`/`load`, emitted
  -- via `ModRuntime.emit`) exist for exactly this -- the host mod itself
  -- already resets its own per-save day/night state the identical way
  -- (`DramaticShapeVoxelMod-dev/main.lua:1163-1175`), confirmed by direct
  -- read before copying the pattern, not assumed.
  V.mod.events:on("save.loaded", resetGibs)
  V.mod.events:on("save.created", resetGibs)

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    if ok and ow then
      sweepKilled(ow)
      pcall(sweepKilledGhosts, ow) -- Phase 18 Bug 2
      pcall(syncGibEntities, ow)
    end
    if Options.enabled() then tickGibs() end
    pcall(tickNpcRespawnTimer, dt)
    return next(game, dt)
  end)
end

return DoomKill
