-- PokeDoom Phase 13: DOOM's real item roster as randomly-generated world
-- pickups, plus the shared reward table `lib/DoomRewards.lua` reuses for
-- battle-win/trainer-weapon rewards -- per the user's explicit 2026-08-05
-- request ("all items in doom, battle rewards..."). The random Kanto-wide
-- SCATTER is this mod's own implementation choice (DOOM has no equivalent
-- to "randomly place items across an open persistent world" -- its own
-- items are hand-placed per finite level); the item ROSTER and what each
-- one does on pickup is real DOOM, re-read fresh from `p_inter.c`/
-- `info.c` per CLAUDE.md's hard rule, not trusted from
-- phases/phase-13-item-pickups.md's own earlier summary. See that doc for
-- the full audit and the locked design decisions (respawn rule, rarity
-- table) this file implements.
--
-- ------- rendering: the exact same real seam `lib/DoomKill.lua` already
-- proved out for gibs
--
-- `ow.entities` is rebuilt fresh by the engine on every map (re)load and
-- confirmed SAFE to add "fake entities" to (`Collision.occupied` skips
-- `.passable=true` entries; `OverworldState:npcAtCell` only reads
-- `ow.npcs`, a separate list, so an item is never a talk target) --
-- anything satisfying the same minimal `:pose()`/`.passable`/`.px,.py`/
-- `.cellX,.cellY` shape `lib/DoomKill.lua`'s own gib entities use gets
-- drawn by the real, unmodified `VoxelScene.render`/`drawEntity`
-- pipeline, genuinely depth-tested against the world terrain, for free.
-- Restated here rather than shared, matching this project's own
-- established "restate small pure-shape pieces per file" precedent.
--
-- ------- world placement: a real, open technical question, answered by
-- direct investigation (not assumed) this round
--
-- No global "list every map in Kanto" registry was found or needed:
-- items are generated LAZILY, the first time the player's own overworld
-- controller loads a given map (`ow.map.id` as the key), using that
-- map's own real walkability data (`Map:isWalkableCell`/`isWaterCell`/
-- `isWarpTileCell`, `gen1recomp-dev/src/world/Map.lua:196-264`, read
-- directly) to pick valid random cells -- this sidesteps the map-
-- enumeration problem entirely rather than guessing at one. Interior vs.
-- outdoor uses the base engine's OWN real classification
-- (`Game.data.field.indoorEncounters`, the exact same check
-- `OverworldController.lua:3477-3484` uses for indoor wild encounters),
-- not an invented heuristic.

local V = ...
local Host = V.host
local DoomWadImport = V.require("DoomWadImport")
local DoomLog = V.require("DoomLog")
local DoomHealth = V.require("DoomHealth")
local DoomWeapons = V.require("DoomWeapons")
local DoomHud = V.require("DoomHud")
local Options = V.require("DoomOptions")
local DoomSpriteCache = V.require("DoomSpriteCache")
-- Lazy, matching this project's own established pattern (`lib/
-- DoomWeapons.lua`'s `getDoomDemons`/`getDoomView`, `lib/DoomBarrels.lua`'s
-- `getDoomWeapons`) -- `DoomDemons` already transitively requires THIS
-- file at module-load time (confirmed via this project's own cycle-check
-- script), so a top-level `V.require("DoomDemons")` here would close a
-- real cycle; called lazily, at USE time, it's safe.
local DoomDemons
local function getDoomDemons()
  DoomDemons = DoomDemons or V.require("DoomDemons")
  return DoomDemons
end
local VoxelScene = Host.require("VoxelScene")
local Voxel3D = Host.require("Voxel3D")
local SpriteBillboards = Host.require("SpriteBillboards")

local DoomItems = {}

-- ------- the shared reward table (phases/phase-13-item-pickups.md's own
-- locked rarity table, 2026-08-05) -- ONE canonical roster, reused by
-- this file's own world scatter AND `lib/DoomRewards.lua`'s battle-win/
-- kill-drop rolls, so there is exactly one place to tune "how rare is X."
-- `MEGA` (megasphere) and the super shotgun stay excluded (Doom II/
-- commercial-only content; this project's reference WAD is confirmed
-- Doom 1, phases/phase-3-weapon-roster.md). `BPAK` (backpack) is
-- deliberately NOT in this table -- see `placeBackpackLandmark` below,
-- a one-per-save world find outside the reward-roll system entirely.
-- `message`/`sound` re-read fresh from `d_englsh.h`/`sounds.h` this
-- round -- real DOOM's own literal pickup text and sound per item.
-- `sound` defaults to `"itemup"` (`sfx_itemup`, `P_TouchSpecialThing`'s
-- own line 358 default) when omitted; only `SOUL` overrides it to
-- `"getpow"` (`sfx_getpow`, the powerup sound -- p_inter.c:492, the one
-- entry in this roster that's powerup-shaped). `MEDI`'s own real message
-- is conditional (`GOTMEDINEED` vs `GOTMEDIKIT`, p_inter.c:480-483,
-- `if (player->health < 25)`) -- handled specially in `messageFor`
-- below rather than a fixed string here.
DoomItems.REWARD_TABLE = {
  { name = "STIM", weight = 10, kind = "body", amount = 10, message = "Picked up a stimpack." },
  { name = "BON1", weight = 10, kind = "healthBonus", message = "Picked up a health bonus." },
  { name = "BON2", weight = 10, kind = "armorBonus", message = "Picked up an armor bonus." },
  { name = "CLIP", weight = 10, kind = "ammo", ammoType = "clip", message = "Picked up a clip." },
  { name = "SHEL", weight = 10, kind = "ammo", ammoType = "shell", message = "Picked up 4 shotgun shells." },
  { name = "ROCK", weight = 10, kind = "ammo", ammoType = "misl", message = "Picked up a rocket." },
  { name = "CELL", weight = 10, kind = "ammo", ammoType = "cell", message = "Picked up an energy cell." },
  { name = "MEDI", weight = 10, kind = "body", amount = 25 }, -- message computed in messageFor
  { name = "ARM1", weight = 10, kind = "armor", armorType = 1, message = "Picked up the armor." },
  { name = "SOUL", weight = 5, kind = "soul", message = "Supercharge!", sound = "getpow" },
  { name = "ARM2", weight = 5, kind = "armor", armorType = 2, message = "Picked up the MegaArmor!" },
}

-- ------- weapon pickups (Phase 6, 2026-08-06) -- real DOOM weapon world
-- pickups, the checklist item Phase 13 explicitly deferred ("weapon
-- pickups deferred to a later round") and Phase 6's own 2026-08-04
-- research already recorded the sprite names for. A SEPARATE table from
-- `REWARD_TABLE` above, not merged into it: a weapon pickup's real
-- effect (`P_GiveWeapon`, already ported as `DoomWeapons.giveWeapon`) is
-- structurally different from a consumable's (grants ownership once,
-- plus 2 ammo clips every time, rather than one fixed effect), and this
-- mod has no DOOM precedent to weigh "how rare should a weapon be" by --
-- flat/equal odds among the 6, not a fabricated-looking derived curve.
-- `sprite` is DOOM's own real pickup-icon lump prefix (verified against
-- the extracted reference WAD in Phase 6's own audit, single-frame `A0`
-- only, distinct from the first-person view-model sprite family Phase
-- 2/3 use -- e.g. `MGUN`, not `CHGG`). `message`/`sound` re-read fresh
-- from `d_englsh.h`/`sounds.h` this round: every weapon's real pickup
-- text, and the real `sfx_wpnup` (`DSWPNUP`) sound every weapon pickup
-- shares (`P_TouchSpecialThing`'s own default overridden specifically
-- for weapon cases, p_inter.c) -- distinct from the default `DSITEMUP`
-- every other pickup in `REWARD_TABLE` above uses.
DoomItems.WEAPON_TABLE = {
  { name = "CHAINGUN", sprite = "MGUN", give = "CHAINGUN", message = "You got the chaingun!", sound = "wpnup" },
  { name = "SHOTGUN", sprite = "SHOT", give = "SHOTGUN", message = "You got the shotgun!", sound = "wpnup" },
  { name = "ROCKETLAUNCHER", sprite = "LAUN", give = "ROCKETLAUNCHER", message = "You got the rocket launcher!", sound = "wpnup" },
  { name = "CHAINSAW", sprite = "CSAW", give = "CHAINSAW", message = "A chainsaw!  Find some meat!", sound = "wpnup" },
  { name = "PLASMARIFLE", sprite = "PLAS", give = "PLASMARIFLE", message = "You got the plasma gun!", sound = "wpnup" },
  { name = "BFG9000", sprite = "BFUG", give = "BFG9000", message = "You got the BFG9000!  Oh, yes.", sound = "wpnup" },
}

local function weaponEntryFor(name)
  for _, e in ipairs(DoomItems.WEAPON_TABLE) do
    if e.name == name then return e end
  end
  return nil
end

-- MEDI's own real conditional (p_inter.c:476-484): the message depends
-- on whether the player was actually hurt at the moment of pickup, read
-- BEFORE `applyEffect` changes it. Every other entry just uses its own
-- fixed `message` field.
function DoomItems.messageFor(entry)
  if entry.name == "MEDI" then
    return DoomHealth.health() < 25
      and "Picked up a medikit that you REALLY need!"
      or "Picked up a medikit."
  end
  return entry.message
end

function DoomItems.soundFor(entry)
  return entry.sound or "itemup"
end

-- Plays a real extracted pickup sound by DOOM's own lump-naming
-- convention ("DS" + uppercase sfx name, e.g. "DSITEMUP" -- the same
-- convention every other sound in this mod already uses,
-- `lib/DoomWeapons.lua`'s own `playWeaponSound`). Silent (not an error)
-- if no WAD is imported yet or this specific lump didn't decode --
-- matching every other DOOM-asset consumer in this mod.
local function playPickupSound(soundName)
  local lump = "DS" .. soundName:upper()
  local ok, snd = pcall(DoomWadImport.loadSound, lump)
  if ok and snd then DoomWadImport.playClone(lump, snd) end
end

-- The shared "a pickup/reward just happened" reaction -- real sound,
-- real on-screen message, and `bonuscount` (feeding both the palette
-- flash and the evil-grin face state, `lib/DoomHud.lua`). One place so
-- `syncItems`' own world-pickup trigger and `lib/DoomRewards.lua`'s
-- battle-win roll can't drift out of sync on what "a pickup" actually
-- does.
--
-- `message` is a CALLER-supplied argument, not computed in here: MEDI's
-- own real message depends on `DoomHealth.health()` as it stood BEFORE
-- `applyEffect` heals it (p_inter.c:480-483's own real `if
-- (player->health < 25)` check) -- every real call site below computes
-- `DoomItems.messageFor(entry)` first, THEN calls `applyEffect`, THEN
-- this function, so the message always reflects the pre-pickup state.
--
-- `showHudMessage` (default true) lets `lib/DoomRewards.lua`'s own
-- battle-context rewards opt OUT of the overworld HUD message
-- specifically -- a real bug the user reported: a battle-win/trainer
-- reward was showing its text BOTH in the battle's own text box
-- (`self:sayNext`, the correct, EXP-parity announcement) AND again as
-- a `lib/DoomHud.lua` overworld message once the player returned from
-- battle, including visibly overlapping the battle screen's own UI
-- during the transition. The sound and `bonuscount` still fire either
-- way -- only the redundant SECOND text announcement is skippable.
function DoomItems.announcePickup(entry, message, showHudMessage)
  if showHudMessage == nil then showHudMessage = true end
  playPickupSound(DoomItems.soundFor(entry))
  if showHudMessage and message and DoomHud.announce then
    DoomHud.announce(message)
  end
  DoomHealth.giveBonus()
end

-- Weighted random pick, `weights` as an optional {name=multiplier}
-- override (Phase 13's own locked design: Pokémon kills use a boosted
-- per-tier weighting, `lib/DoomRewards.lua`'s own concern -- this
-- function just needs to accept an override table, not know why one
-- exists).
function DoomItems.pickItem(weightOverride)
  local total = 0
  for _, entry in ipairs(DoomItems.REWARD_TABLE) do
    total = total + (weightOverride and weightOverride[entry.name] or entry.weight)
  end
  local roll = math.random() * total
  local acc = 0
  for _, entry in ipairs(DoomItems.REWARD_TABLE) do
    acc = acc + (weightOverride and weightOverride[entry.name] or entry.weight)
    if roll <= acc then return entry end
  end
  return DoomItems.REWARD_TABLE[#DoomItems.REWARD_TABLE]
end

-- Applies one item's real DOOM effect (`lib/DoomHealth.lua`'s/
-- `lib/DoomWeapons.lua`'s own `give*` ports, each already cited against
-- its real `P_Give*`/switch-case source at the point they're defined) --
-- shared by this file's own world-pickup trigger and `lib/DoomRewards.
-- lua`'s battle-win roll. `ammoClips` overrides the default 1-clip-load
-- amount (real DOOM's own single-ammo-pickup case, `P_TouchSpecialThing`
-- 533-581) -- the battle-win reward's own 1-12 roll passes a bigger
-- number here rather than this file needing two separate ammo paths.
-- Returns whether anything was actually granted, matching every real
-- `P_Give*`'s own true/false "was this pickup actually needed" contract.
function DoomItems.applyEffect(entry, ammoClips)
  if entry.kind == "body" then
    return DoomHealth.giveBody(entry.amount)
  elseif entry.kind == "healthBonus" then
    return DoomHealth.giveHealthBonus()
  elseif entry.kind == "armorBonus" then
    return DoomHealth.giveArmorBonus()
  elseif entry.kind == "armor" then
    return DoomHealth.giveArmor(entry.armorType)
  elseif entry.kind == "soul" then
    return DoomHealth.giveSoul()
  elseif entry.kind == "ammo" then
    return DoomWeapons.giveAmmo(entry.ammoType, ammoClips or 1)
  end
  return false
end

-- ------- sprites: `loadImage`, not `loadSpriteAsset` -- these are real
-- 3D-world-positioned entities (like gibs), not 2D HUD/psprite-offset-
-- anchored overlays, so no grAb offset math applies (the same reasoning
-- `lib/DoomKill.lua`'s own `loadGibSprite` already established).
-- Pickup icons are ordinarily non-directional in real DOOM (rotation
-- `0`, correct and already working here), but hardened 2026-08-06 with
-- the same fallback `lib/DoomDemons.lua`/`lib/DoomKill.lua` needed for
-- their own genuinely directional sprites (see `DoomDemons.lua`'s own
-- header comment for the full DOOM-sprite-rotation-rule derivation) --
-- cheap insurance against any reward item that turns out not to be.
local loadItemImage = DoomSpriteCache.newSpriteLoader()

-- ------- world-sitting animation, real DOOM content -- re-read fresh
-- from the state chains (`info.c:938-1012`), not every item is static:
-- `ARM1`/`ARM2` pulse a real 2-frame A/B cycle (6-7 tics per frame);
-- `BON1`/`BON2`/`SOUL` all share the identical real 6-frame ping-pong
-- (A-B-C-D-C-B, 6 tics/frame -- `SOUL`'s own frames are additionally
-- `FF_FULLBRIGHT`-flagged in real DOOM, a lighting effect this mod's own
-- renderer has no equivalent hook for, so the glow itself isn't ported,
-- just the frame cycle); `STIM`/`MEDI`/`CLIP`/`SHEL`/`ROCK`/`CELL` are
-- genuinely static single sprites (`tics=-1`), confirmed directly, not
-- assumed uniform. Frame timing converted from DOOM's real 35Hz the same
-- plain-rounded way `lib/DoomHud.lua`'s own face-widget timing already
-- is (cosmetic, not a gameplay-rate stat, so it doesn't need Phase 5's
-- own fractional-accumulator rigor).
local DOOM_TICRATE, FRAME_RATE = 35, 60
local function ticsToFrames(tics)
  return math.max(1, math.floor(tics * FRAME_RATE / DOOM_TICRATE + 0.5))
end
local ANIM = {
  ARM1 = { frames = { "A", "B" }, tics = { 6, 7 } },
  ARM2 = { frames = { "A", "B" }, tics = { 6, 7 } },
  BON1 = { frames = { "A", "B", "C", "D", "C", "B" }, tics = { 6, 6, 6, 6, 6, 6 } },
  BON2 = { frames = { "A", "B", "C", "D", "C", "B" }, tics = { 6, 6, 6, 6, 6, 6 } },
  SOUL = { frames = { "A", "B", "C", "D", "C", "B" }, tics = { 6, 6, 6, 6, 6, 6 } },
}

-- One shared animation clock PER ITEM NAME (not per world instance) --
-- every simultaneous ARM1 pickup in the world shows the same phase,
-- visually indistinguishable from independent per-instance clocks for a
-- looping cycle, at a fraction of the bookkeeping.
local animClocks = {}
local function currentFrame(itemName)
  local anim = ANIM[itemName]
  if not anim then return "A" end
  local clock = animClocks[itemName]
  if not clock then
    clock = { index = 1, hold = ticsToFrames(anim.tics[1]) }
    animClocks[itemName] = clock
  end
  clock.hold = clock.hold - 1
  if clock.hold <= 0 then
    clock.index = clock.index % #anim.frames + 1
    clock.hold = ticsToFrames(anim.tics[clock.index])
  end
  return anim.frames[clock.index]
end

-- FIX 2026-08-08 (user report: "the mod lags HEAVILY when first...
-- picking up a doom item"). Every item sprite/sound is loaded LAZILY, on
-- first actual pickup (`loadItemImage`'s own per-name-and-frame cache
-- above, `DoomWadImport.loadSound`'s own now-fixed per-name cache -- see
-- that file's own header comment) -- a real, synchronous disk-read plus
-- `love.graphics.newImage`/`love.audio.newSource` decode the FIRST time
-- a given name is ever needed, same class of bug as the already-fixed
-- "first pickup/first kill freeze" (that earlier fix only sped up
-- FINDING which file matches a name, never the cost of actually
-- DECODING it once found). Called once via `DoomWadImport.onReady` (see
-- `install()` below), decoding every real `REWARD_TABLE`/`WEAPON_TABLE`
-- sprite frame and pickup sound up front, so the actual first pickup of
-- any given item is a cache hit -- not calling `currentFrame` itself for
-- this, since that would advance its own shared per-item animation
-- clock as a side effect; reading `ANIM[name].frames` directly instead.
-- FIX 2026-08-08, ROUND 2 -- user report: "5 minutes and i knew i wasnt
-- even close to done... you dont have to sit at a terminal for 20
-- minutes for it to not lag." Doing every decode in one synchronous loop
-- (this function's own original shape) just moved dozens of small
-- in-gameplay hitches into a single, much WORSE blocking freeze -- a
-- real regression, not a fix. Rewritten to ENQUEUE each individual
-- image/sound load as its own unit of work
-- (`DoomWadImport.enqueuePrewarm`, see that function's own header
-- comment for the full redesign) instead of doing any of it here
-- directly -- this function itself is now just bookkeeping, effectively
-- instant, and the actual decoding drains in the BACKGROUND across
-- ordinary frame time (`DoomWadImport.pumpPrewarm()`, called from this
-- file's own `install()` `input.step` hook below), never blocking play.
function DoomItems.prewarm()
  for _, entry in ipairs(DoomItems.REWARD_TABLE) do
    local anim = ANIM[entry.name]
    local frames = anim and anim.frames or { "A" }
    for _, frame in ipairs(frames) do
      DoomWadImport.enqueuePrewarm(function() pcall(loadItemImage, entry.name, frame) end)
    end
    local soundLump = "DS" .. DoomItems.soundFor(entry):upper()
    DoomWadImport.enqueuePrewarm(function() pcall(DoomWadImport.loadSound, soundLump) end)
  end
  for _, weapon in ipairs(DoomItems.WEAPON_TABLE) do
    DoomWadImport.enqueuePrewarm(function() pcall(loadItemImage, weapon.sprite, "A") end)
    local soundLump = "DS" .. (weapon.sound or "wpnup"):upper()
    DoomWadImport.enqueuePrewarm(function() pcall(DoomWadImport.loadSound, soundLump) end)
  end
end

-- ------- the fake entity's mesh -- restated from `lib/DoomKill.lua`'s
-- own `buildGibMesh`, same real reasons (`billboardMatrix`'s own
-- corner-anchored `+8`/rotate/`-8` sequence, `SpriteBillboards.mesh`'s
-- own fixed-16px-sheet assumption that a standalone DOOM sprite isn't).
-- Simplified from that file's own per-NPC-calibrated version: item
-- sprites have no natural "person-sized" reference to calibrate against,
-- so every item uniformly targeted HALF a standing NPC's own real card
-- height (`NPC_CARD_WORLD_HEIGHT` in that file, restated as the constant
-- below) -- a reasonable, clearly-flagged visual judgment call (no
-- principled DOOM-pixel-to-world-unit conversion exists, CLAUDE.md's
-- "Nature of the port"), not a per-item native-size calibration; a
-- soulsphere and a stimpack read the same world height here, a known,
-- documented simplification rather than an unstated one.
--
-- REVISED 2026-08-10 -- user report, confirmed against the actual
-- extracted texture: "this entity is still too big (i think its clip,
-- check the texture)" and, on a second item the same round, "the medi
-- box has that problem too but the clip also has that problem -
-- confirmed." The "known simplification" above turned out wrong in
-- practice for exactly the reason CLAUDE.md's own sprite-scale hard
-- rule warns about: capping every item's larger axis to the SAME fixed
-- 8-unit target erases each sprite's own real relative size. Real
-- native WAD pixel dimensions (read fresh, `assets/generated/doom/doom/
-- SPRITES/`): `clipa0.png` is 9x11 -- the SMALLEST real sprite in the
-- whole reward table -- while `media0.png` (28x19), `arm1a0.png`/
-- `arm2a0.png` (31x17), `soula0.png` (25x25) are 2-3x bigger on their
-- long axis. Forcing all of them to an identical 8-unit cap makes the
-- smallest item (a clip) render at HALF a demon's own height
-- (`DEMON_WORLD_HEIGHT=16`) -- roughly hip-height on the player, hence
-- "looks like a trash can." This is the same bug class CLAUDE.md's own
-- hard rule names (a fixed target height re-applied per-sprite,
-- independent of each sprite's own true size) -- these reward items
-- were miscategorized under that rule's "genuinely tiny, use a
-- dedicated fixed height" option (meant for blood/puffs, real WAD size
-- 5x5-5x6px) when they actually belong under its OTHER option: "share
-- an already-calibrated demon's own ratio... right when the sprite's
-- real WAD patch is reasonably large... and preserving its TRUE
-- relative proportions actually matters" -- true here, since a chunky
-- medikit box SHOULD read bigger than a slim ammo clip, exactly the
-- real, true-to-DOOM difference the fixed cap was erasing. Fixed by
-- sharing `lib/DoomDemons.lua`'s own Zombieman-calibrated ratio
-- (`DoomDemons.worldHeightFor`, the SAME function `lib/DoomWeapons.lua`
-- already reuses for projectiles) for every REWARD_TABLE item instead
-- of this fixed constant -- see `buildItemMesh` below. `ITEM_WORLD_
-- HEIGHT` is kept only as the fallback for the rare case a sprite
-- prefix can't be resolved (no image, or the ratio lookup itself
-- fails), not as the normal path anymore.
local ITEM_WORLD_HEIGHT = 8

-- FIX 2026-08-08 (user report: "gun pickups on the ground are too big.
-- likely related to the previous entity size bug when they were too
-- big"). Root cause, confirmed by reading the real extracted sprite
-- dimensions directly: weapon pickup sprites (`SHOT`/`MGUN`/`LAUN`/
-- `CSAW`/`PLAS` -- a gun lying on the ground, viewed from the side) are
-- extremely WIDE relative to their height (real `shota0.png` is
-- 63x12px, aspect 5.25 -- vs a regular item like `clipa0.png`, 9x11px,
-- aspect 0.82, roughly square). The rule above (fix HEIGHT to a
-- constant, preserve aspect ratio) works fine for roughly-square
-- items, but for a 5:1 sprite it blows the WIDTH out to `63*(8/12) =
-- 42` world units -- nearly 3x `lib/DoomDemons.lua`'s own
-- `DEMON_WORLD_HEIGHT=16` (a full standing person), which is exactly
-- the reported "too big." A weapon pickup's own real long axis is its
-- WIDTH, not its height (unlike every other item here, and unlike a
-- demon), so it needs the opposite rule: fix the WIDTH to a sane
-- world-unit target and let height follow the sprite's own real
-- aspect ratio instead -- still no principled DOOM-pixel-to-world-unit
-- conversion exists for this (CLAUDE.md's "Nature of the port"), so
-- `WEAPON_PICKUP_WIDTH=12` is a judgment call, picked to read as
-- "roughly as long as a person is tall, not longer" rather than
-- derived from any source constant.
local WEAPON_PICKUP_WIDTH = 12

-- FIX 2026-08-10 -- user report: "shotgun shells and clips are too big
-- on the ground." Confirmed by reading the actual extracted sprite
-- dimensions directly, not guessed (matching this project's own
-- established audit practice) -- `shela0.png` is 15x7px, aspect ratio
-- 2.14 (WIDER than tall), the exact same shape category as the weapon-
-- pickup sprites already fixed once (`shota0.png`, 5.25 aspect) -- but
-- the OLD rule below only ever fixed HEIGHT and let width follow,
-- exactly the bug that fix was originally written to avoid, just never
-- generalized past weapons: `worldH=8, worldW=15*(8/7)=17.1` world
-- units -- WIDER than a full standing demon (`DEMON_WORLD_HEIGHT=16`).
-- `clipa0.png` itself (9x11, aspect 0.82) measures fine under the old
-- rule and isn't the real bug -- but auditing every OTHER real
-- `REWARD_TABLE` sprite's own actual dimensions the same way (per
-- CLAUDE.md's own "audit every entity... before the user has to find
-- them" directive) found the IDENTICAL latent bug already present on
-- `cella0.png` (17x12, aspect 1.42), `media0.png` (28x19, aspect 1.47),
-- and `arm1a0.png`/`arm2a0.png` (31x17, aspect 1.82 each) -- none yet
-- reported, all real, all the same root cause.
--
-- Fixed by GENERALIZING the weapon-pickup rule instead of special-
-- casing SHEL alone: for ANY item, whichever axis (width or height) is
-- proportionally the LONGER one gets capped at the target size, and the
-- SHORTER axis follows the sprite's own real aspect ratio -- guaranteeing
-- neither axis can ever end up oversized, regardless of a given sprite's
-- own real shape, the same real principle the original weapon-only fix
-- already established. Reuses `ITEM_WORLD_HEIGHT` as that shared cap
-- (not `WEAPON_PICKUP_WIDTH`) for every non-weapon item -- these are all
-- much smaller real-world objects than a full gun, so capping them at
-- the same target already used for a compact item's own height (rather
-- than a full gun's own width target) keeps them proportionally
-- consistent with each other.
local itemMeshCache = {}
local lastMeshWadState = nil
local function buildItemMesh(image, isWeapon, spritePrefix)
  local iw, ih = image:getDimensions()
  if not (iw and ih and iw > 0 and ih > 0) then return nil end
  local worldH, worldW
  if isWeapon then
    worldW = WEAPON_PICKUP_WIDTH
    worldH = ih * (worldW / iw)
  else
    -- Share `lib/DoomDemons.lua`'s own Zombieman-calibrated ratio (see
    -- that file's own `NON_DEMON_PREFIXES` entry for these prefixes,
    -- added the same round) so a real reward item's TRUE relative size
    -- against a person is preserved, instead of forcing every item's
    -- longer axis to the same fixed target regardless of its own real
    -- size (see `ITEM_WORLD_HEIGHT`'s own header comment above for the
    -- full derivation of why that was wrong). `ITEM_WORLD_HEIGHT` stays
    -- as the fallback only for the rare case the ratio lookup itself
    -- fails (no prefix available, or the shared Zombieman reference
    -- sprite couldn't load).
    local DD = getDoomDemons()
    local okH, worldHeight = pcall(DD.worldHeightFor, spritePrefix, image)
    if okH and worldHeight and worldHeight > 0 then
      worldH = worldHeight
      worldW = iw * (worldH / ih)
    elseif iw > ih then
      worldW = ITEM_WORLD_HEIGHT
      worldH = ih * (worldW / iw)
    else
      worldH = ITEM_WORLD_HEIGHT
      worldW = iw * (worldH / ih)
    end
  end
  local halfW = worldW / 2
  local u0, u1 = 0.5 / iw, (iw - 0.5) / iw
  local v0, v1 = 0.5 / ih, (ih - 0.5) / ih
  local verts = {
    { 8 - halfW, 0, 0, u0, v1, 1 }, { 8 + halfW, 0, 0, u1, v1, 1 },
    { 8 + halfW, worldH, 0, u1, v0, 1 }, { 8 - halfW, worldH, 0, u0, v0, 1 },
  }
  local indices = {}
  Voxel3D.pushQuad(indices, 0)
  return Voxel3D.newMesh(verts, indices)
end

local function itemMesh(cacheKey, image, isWeapon, spritePrefix)
  if DoomWadImport.status.state ~= lastMeshWadState then
    lastMeshWadState = DoomWadImport.status.state
    itemMeshCache = {}
  end
  local cached = itemMeshCache[cacheKey]
  if cached ~= nil then return cached or nil end
  local okM, m = pcall(buildItemMesh, image, isWeapon, spritePrefix)
  m = (okM and m) or false
  itemMeshCache[cacheKey] = m
  return m or nil
end

local installedMeshHook = false
local function installItemMeshHook()
  if installedMeshHook then return end
  installedMeshHook = true
  local inner = SpriteBillboards.mesh
  local function reskin(def, frame)
    if def and def.pokedoomItem then
      local ok, m = pcall(itemMesh, def.pokedoomCacheKey, def.pokedoomImage, def.pokedoomWeapon, def.pokedoomSpritePrefix)
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
  -- with this file's own synthetic `pokedoomItem` def, silently fail to
  -- build a card (confirmed via `VoxelScene.lua`'s own `drawShadow`: `if
  -- not mesh then return end`, no crash, just no shadow), and every item
  -- pickup would render with no shadow/occlusion silhouette -- the exact
  -- same gap `lib/DoomDemons.lua`'s own Phase 21 Round 4 already found
  -- and fixed for demons, and `lib/DoomProps.lua` already avoids for
  -- props. Wrapped the same way here per CLAUDE.md's own "a fix to one
  -- implementation of a shared mechanic must be checked against every
  -- parallel implementation" hard rule.
  SpriteBillboards.shadowQuad = reskin
end

-- ------- map helpers
--
-- The real, base-engine classification of "is this map an interior" --
-- the exact same check `OverworldController.lua:3477-3484` uses for its
-- own indoor-wild-encounter roll, reused rather than invented, per
-- CLAUDE.md's porting-methodology hard rule ("verify, don't assume --
-- reuse what already exists").
local function isInteriorMap(map)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.data.field) then return false end
  local indoor = Game.data.field.indoorEncounters
  if not (indoor and map and map.def) then return false end
  return map.def.index >= indoor.firstIndoorMap
     and map.def.tileset ~= indoor.excludedTileset
end

-- A random walkable, dry, non-warp cell -- bounded attempts so a
-- pathologically small/blocked map can't hang this in a loop; simply
-- yields fewer points than requested rather than erroring.
local function randomWalkablePoint(map)
  for _ = 1, 40 do
    local cx = math.random(0, map.widthCells - 1)
    local cy = math.random(0, map.heightCells - 1)
    if map:isWalkableCell(cx, cy) and not map:isWaterCell(cx, cy)
       and not map:isWarpTileCell(cx, cy) then
      return cx, cy
    end
  end
  return nil
end

-- ------- lazy per-map generation
--
-- Density is a judgment call, same category as every other "no DOOM
-- precedent to defer to" number in this project (walk speed, projectile
-- speed): a handful per map, fewer indoors (already smaller, more
-- NPC-dense) -- flagged as adjustable, not re-derived from source.
local OUTDOOR_COUNT = { 3, 6 }
local INDOOR_COUNT = { 1, 2 }

local function seedMap(save, map)
  local mapId = map.id
  save.doomItems = save.doomItems or {}
  if save.doomItems[mapId] then return end
  local interior = isInteriorMap(map)
  local range = interior and INDOOR_COUNT or OUTDOOR_COUNT
  local count = math.random(range[1], range[2])
  local points = {}
  for _ = 1, count do
    local cx, cy = randomWalkablePoint(map)
    if cx then
      points[#points + 1] = { cx = cx, cy = cy, name = DoomItems.pickItem().name }
    end
  end
  -- REMOVED 2026-08-08 -- user's own explicit instruction: "the only 2
  -- ways the player should be able to get weapons is buy them in
  -- pokeshops, or through getting badges" (see `lib/DoomBadgeRewards.
  -- lua`, the new badge-earned weapon grant this replaces this world-
  -- scatter path with). This used to roll a `WEAPON_SPAWN_CHANCE` chance
  -- per outdoor map to seed a real gun pickup among the regular item
  -- points -- removed outright rather than left at 0 chance, so there's
  -- no dead random roll sitting in the normal seeding path. `WEAPON_TABLE`
  -- itself, `weaponEntryFor`, and `syncItems`' own `point.isWeapon`
  -- pickup branch below are all left in place -- still real, still used
  -- by the TEST ITEM debug row (`spawnRow` below), the modder's own
  -- explicit manual test tool, unaffected by this restriction.
  save.doomItems[mapId] = { points = points, taken = {}, interior = interior }
end

-- ------- the backpack: one landmark per save, outside the reward table
--
-- Real DOOM's own `BPAK` is hand-placed by a level designer; this mod
-- has no map registry to pick a truly random Kanto-wide location from
-- (the same reason regular items are seeded lazily per-map rather than
-- up front, see this file's own header comment) -- so the landmark
-- lands on the first outdoor map the player happens to be standing on
-- once the mode is first engaged, a real, honest limitation of the
-- lazy-per-map approach, flagged rather than dressed up as a true
-- world-wide roll.
local function placeBackpackLandmark(save, map)
  if save.doomBackpackPlaced then return end
  if isInteriorMap(map) then return end
  local cx, cy = randomWalkablePoint(map)
  if not cx then return end
  save.doomItems = save.doomItems or {}
  save.doomItems[map.id] = save.doomItems[map.id] or { points = {}, taken = {}, interior = false }
  table.insert(save.doomItems[map.id].points, { cx = cx, cy = cy, name = "BPAK" })
  save.doomBackpackPlaced = true
end

-- ------- monster drops (`lib/DoomDemons.lua`'s own `startDeath`, the
-- port of real DOOM's `P_KillMobj`, p_inter.c:719-757): a hand-coded
-- per-monster-type drop table in real DOOM -- Zombieman/Wolf-SS drop a
-- clip, Shotgun Guy a shotgun, Chaingunner a chaingun (this roster has
-- no Chaingunner, so that branch never applies here); every OTHER
-- monster type drops nothing at all, real DOOM's own actual default (no
-- generic "dropitem" mobjinfo field exists anywhere in this original
-- 1993/1994 source -- that's a later Boom/MBF/source-port addition, not
-- something to invent here). Spawned at the exact point the monster
-- died (`P_SpawnMobj(target->x, target->y, ONFLOORZ, item)`), flagged
-- `MF_DROPPED` (`mo->flags |= MF_DROPPED`) -- ported here as
-- `point.dropped = true`, which changes how much the pickup actually
-- grants on touch (see `syncItems`'s own matching branch below): a
-- dropped clip gives HALF a clip-load (`P_GiveAmmo`'s own real `num =
-- clipammo[ammo]/2` when called with `num=0`, `p_inter.c:534-537`), a
-- dropped weapon gives only 1 ammo clip instead of 2
-- (`DoomWeapons.giveWeapon`'s own matching `dropped` parameter, itself
-- ported from `P_GiveWeapon`'s real `dropped` branch, `p_inter.c:
-- 198-205`).
--
-- Reuses this file's own existing per-map point/entity/pickup machinery
-- entirely unchanged (same `points` list, same proximity-trigger
-- `syncItems` loop below, same mesh/animation code) -- a drop is simply
-- a point inserted OUTSIDE `seedMap`'s own one-time-per-map random
-- roll, at a monster's own real death location instead of a random
-- walkable cell.
function DoomItems.dropItem(ow, cx, cy, itemName, opts)
  if not (ow and ow.map and cx and cy) then return end
  opts = opts or {}
  local ok, Game = pcall(require, "src.core.Game")
  local save = ok and Game.save
  if not save then return end
  save.doomItems = save.doomItems or {}
  local mapId = ow.map.id
  local mapItems = save.doomItems[mapId]
  if not mapItems then
    -- Real DOOM has no equivalent situation -- every level's items are
    -- all hand-placed before play ever starts. This mod's own lazy
    -- per-map scatter (`seedMap`) may genuinely not have run yet if a
    -- demon manages to die before `syncItems` has ticked once on a
    -- freshly-loaded map -- create the map's own points list right
    -- here rather than silently dropping the item, matching
    -- `placeBackpackLandmark`'s own identical "make the table if it
    -- isn't there yet" pattern just above.
    mapItems = { points = {}, taken = {}, interior = isInteriorMap(ow.map) }
    save.doomItems[mapId] = mapItems
  end
  local point = { cx = cx, cy = cy, name = itemName, dropped = true }
  if opts.sprite then point.sprite = opts.sprite end
  if opts.isWeapon then point.isWeapon = true end
  table.insert(mapItems.points, point)
end

-- ------- the fake entity, one per live (not-yet-taken) point
--
-- FIX 2026-08-12 (real crash, confirmed via the `save.writing` diagnostic
-- in main.lua: "src/core/SaveSerializer.lua:41: cannot serialize
-- function", exact path `save.doomItems.<mapId>.points.<i>.entity.draw").
-- `point` here is not a scratch table -- it's the SAME table object that
-- lives inside `save.doomItems[mapId].points` (this file's own real save-
-- persisted data, `seedMap` above). This used to attach the live render
-- entity (a table carrying `draw`/`pose`/`resolveImage` FUNCTION fields)
-- directly onto that object as `point.entity` -- meaning the instant any
-- item on any visited map had ever been rendered once, the save file
-- carried a live function inside it, and the very next save crashed
-- outright. Fixed by keeping the entity in a separate, weak-keyed,
-- never-persisted side table instead of a field on the save object itself
-- -- structurally impossible to leak into a save from here on, rather
-- than something a future call site has to remember to strip first.
-- Weak keys (`__mode = "k"`) let an entry vanish on its own once a point
-- is genuinely gone (taken, or its map's own table dropped), the same
-- lifetime `point.entity = nil` used to enforce by hand.
local entityFor = setmetatable({}, { __mode = "k" })

local function itemWorldPos(cx, cy)
  return cx * 16 + 8, cy * 16 + 8
end

local function makeItemEntity(point)
  local wx, wz = itemWorldPos(point.cx, point.cy)
  local cornerX, cornerZ = wx - 8, wz - 8
  return {
    passable = true,
    px = cornerX, py = cornerZ,
    cellX = point.cx, cellY = point.cy,
    -- The classic, non-voxel 2D render path (`OverworldController.lua:
    -- 4740-4742`) ALSO walks `ow.entities` unconditionally and calls
    -- `e:draw(camX, camY)` on every entry -- a real crash confirmed live
    -- (`attempt to call method 'draw' (a nil value)`) on the very first
    -- frame after a fresh map load, before PKDOOM MODE's own camera lock
    -- (`lib/DoomView.lua`'s `lockFirstPerson`) had necessarily forced the
    -- voxel rung yet. A safe no-op, not a real 2D draw: the voxel pass's
    -- own `:pose()` above is this entity's real rendering path, exactly
    -- like a gib's -- this only exists so the OTHER path doesn't crash
    -- on a table that was never meant to satisfy it.
    draw = function() end,
    pose = function()
      -- `point.sprite` is DOOM's own real pickup-icon lump prefix when
      -- it differs from `point.name` (weapon points, Phase 6, 2026-08-06
      -- -- see `seedMap`'s own comment); every `REWARD_TABLE`-driven
      -- point has no `sprite` field at all, so `point.name` IS already
      -- the real sprite prefix for those, unchanged from before.
      local spriteName = point.sprite or point.name
      local frame = currentFrame(spriteName)
      local image = loadItemImage(spriteName, frame)
      -- FIXED 2026-08-06 -- `if not image then return nil end` used to
      -- sit here, returning ONE value instead of the six `VoxelScene.
      -- lua`'s own `posesOf` (its real line 521/526) unconditionally
      -- destructures (`sprite, vx, vy, ... = e:pose()`), then computes
      -- `e.py - vy` with no nil check -- a bare-nil `pose()` return
      -- crashed the ENTIRE voxel 3D pipeline, not just this one pickup,
      -- confirmed by a real crash log against `lib/DoomDemons.lua`'s own
      -- identical bug (see that file's own header comment on this same
      -- date for the full trace -- this file's copy of the same pattern
      -- is fixed the same way here). `image` may still be `nil`; that's
      -- fine, everything downstream already tolerates it via pcall.
      -- Cache key includes the FRAME letter, not just the sprite name --
      -- animated items (ARM1/ARM2/BON1/BON2/SOUL) cycle through several
      -- DIFFERENTLY-SIZED real sprite images, and `lib/DoomKill.lua`'s
      -- own precedent effectively caches per distinct sprite too (each
      -- gib XDeath frame is its own differently-named lump) -- keying
      -- only by sprite name here would freeze the mesh's own geometry at
      -- whichever frame happened to build it first while the TEXTURE
      -- kept advancing, a real mismatch a static/non-animated item never
      -- would have exposed.
      local spriteObj = {
        def = {
          pokedoomItem = true, pokedoomCacheKey = spriteName .. frame,
          pokedoomImage = image, pokedoomWeapon = point.isWeapon,
          pokedoomSpritePrefix = spriteName,
          trueColor = true, image = "pokedoom-item-" .. spriteName,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      return spriteObj, cornerX, cornerZ, "down", 0, false
    end,
  }
end

local function removeItemEntity(ow, point)
  point.inserted = false
  local entity = entityFor[point]
  if not (entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == entity then table.remove(ow.entities, i) break end
  end
  entityFor[point] = nil
end

-- ------- per-frame sync + proximity pickup trigger
--
-- Same "`ow.entities` is rebuilt fresh on every map (re)load, so re-add
-- every frame for the CURRENT map only" shape `lib/DoomKill.lua`'s own
-- `syncGibEntities` already established -- items on a map the player
-- isn't currently on are simply left alone; the engine already dropped
-- their entities on its own rebuild, and they reappear the same way if
-- the player returns.
--
-- Interior respawn (phases/phase-13-item-pickups.md's own locked
-- design): the FIRST sync after the player's mapId changes TO an
-- interior map clears that map's own `taken` table -- so a Center/Mart/
-- house's items are available again on every fresh entry, while an
-- outdoor map's `taken` table is never cleared, matching real DOOM's own
-- single-player "no respawn" rule (`P_RespawnSpecials`, confirmed
-- deathmatch-only, phases/phase-13-item-pickups.md's own audit).
-- world px -- widened from an original 10 (~2/3 of a cell) after the
-- user reported walking right up to a shell pickup without it
-- triggering. No code bug was found in the actual grant path (`ammo`
-- key names checked end to end, all consistent) -- the likely real
-- explanation is DOOM's own genuine "already at max, pickup does
-- nothing" behavior (`P_GiveAmmo`'s own real `if (player->ammo[ammo] ==
-- player->maxammo[ammo]) return false`, ported faithfully in
-- `DoomWeapons.giveAmmo`) -- a battle-win reward can grant up to 48
-- shells in one roll (12 clips * 4/clip), so hitting the 50-shell cap
-- after a few wins is genuinely plausible, not a bug. Widened anyway as
-- a real, independent proximity improvement -- 16 is a full cell, so
-- standing anywhere in the SAME cell as a pickup now always triggers it,
-- removing any chance the old tighter radius was ALSO a contributing
-- factor.
local PICKUP_RADIUS = 16
local lastMapId = nil

-- Extracted out of `syncItems`' own proximity loop below -- the actual
-- "apply this one item's real effect" dispatch (BPAK landmark / weapon /
-- regular REWARD_TABLE entry) plus its own diagnostic timing, all as one
-- named step rather than inline in the middle of the per-point loop.
local function triggerItemPickup(ow, mapItems, point, i)
  -- DIAGNOSTIC 2026-08-08 -- times the actual pickup-trigger block
  -- itself (`applyEffect`/`giveWeapon`/`announcePickup`, mesh
  -- teardown), so a report of "still lags on first pickup" can show
  -- whether the remaining cost is HERE (some downstream effect
  -- neither prewarm pass covers -- e.g. a `require` paying its own
  -- first-load cost, or `DoomHud`/`DoomFont` building a glyph atlas
  -- on its own first-ever draw) rather than in asset decoding at
  -- all, which the prewarm passes above should have already closed.
  local pickT0 = love.timer and love.timer.getTime() or 0
  local entry
  for _, e in ipairs(DoomItems.REWARD_TABLE) do
    if e.name == point.name then entry = e break end
  end
  local applied
  if point.name == "BPAK" then
    -- Not in REWARD_TABLE (a landmark, not a repeating roll) --
    -- its own real message/sound (p_inter.c:589-599's own
    -- `GOTBACKPACK`, default `sfx_itemup`) handled directly here
    -- rather than a fake table entry built just to satisfy
    -- `announcePickup`'s own signature.
    DoomWeapons.giveBackpack()
    playPickupSound("itemup")
    if DoomHud.announce then
      DoomHud.announce("Picked up a backpack full of ammo!")
    end
    DoomHealth.giveBonus()
    applied = true
  elseif point.isWeapon then
    -- Real P_GiveWeapon (Phase 13's own `DoomWeapons.giveWeapon`):
    -- grants ownership (if new) plus 2 real ammo clips (1 if
    -- `point.dropped` -- a monster drop, see `dropItem`'s own
    -- header comment above and `DoomWeapons.giveWeapon`'s own
    -- matching real `p_inter.c:198-205` citation), returns false
    -- only if the weapon was already owned AND its ammo was
    -- already maxed -- the same "don't consume a pickup you
    -- didn't need" contract every other entry here already
    -- follows.
    local weapon = weaponEntryFor(point.name)
    if weapon then
      applied = DoomWeapons.giveWeapon(weapon.give, point.dropped)
      if applied then
        playPickupSound(weapon.sound or "wpnup")
        if DoomHud.announce then DoomHud.announce(weapon.message) end
        DoomHealth.giveBonus()
      end
    end
  elseif entry then
    -- Real message computed BEFORE applyEffect -- see
    -- `announcePickup`'s own header comment for why (MEDI's real
    -- text depends on health as it stood before the heal).
    local message = DoomItems.messageFor(entry)
    -- `point.dropped` (a monster drop, `dropItem`'s own header
    -- comment above): real DOOM's own dropped clip gives HALF a
    -- clip-load, not the full one a world-placed clip gives
    -- (`P_GiveAmmo`'s own real `num = clipammo[ammo]/2` when
    -- called with `num=0`, `p_inter.c:534-537`) -- `0.5` clips of
    -- `CLIPAMMO.clip = 10` is exactly `5`, matching that real
    -- half-clip amount precisely. Every entry here besides CLIP
    -- has no real `MF_DROPPED` case in vanilla DOOM at all (only
    -- ammo/weapon pickups ever spawn as monster drops), so this
    -- only actually changes behavior for a dropped clip in
    -- practice -- passing it through unconditionally is still
    -- correct, since `applyEffect` only reads `ammoClips` for
    -- `kind == "ammo"` entries to begin with.
    applied = DoomItems.applyEffect(entry, point.dropped and 0.5 or nil)
    if applied then DoomItems.announcePickup(entry, message) end
  end
  if applied then
    mapItems.taken[i] = true
    removeItemEntity(ow, point)
    local pickT1 = love.timer and love.timer.getTime() or 0
    pcall(DoomLog.event, "PREWARM", "DoomItems pickup %s: trigger block took %.3fs",
      tostring(point.name), pickT1 - pickT0)
  end
end

local function syncItems(ow)
  local map = ow and ow.map
  if not (map and ow.entities and ow.player) then return end
  local mapId = map.id
  local ok, Game = pcall(require, "src.core.Game")
  local save = ok and Game.save
  if not save then return end

  -- DIAGNOSTIC 2026-08-08 -- rules out `seedMap`'s own lazy first-visit
  -- per-map generation as the remaining "first pickup" lag source (see
  -- `DoomItems.prewarm`'s own header comment) -- only logs when this
  -- map's own points genuinely didn't exist yet (the real first-visit
  -- case), not on the fast no-op path every other tick takes.
  local seedT0
  local hadMapAlready = save.doomItems and save.doomItems[mapId] ~= nil
  if not hadMapAlready then seedT0 = love.timer and love.timer.getTime() or 0 end
  seedMap(save, map)
  if seedT0 then
    local seedT1 = love.timer and love.timer.getTime() or 0
    pcall(DoomLog.event, "PREWARM", "DoomItems.seedMap: first generation for map %s took %.3fs",
      tostring(mapId), seedT1 - seedT0)
  end
  placeBackpackLandmark(save, map)

  local mapItems = save.doomItems and save.doomItems[mapId]
  if not mapItems then return end

  -- FIX 2026-08-09 -- Phase 26 lag audit: the item-entity insertion
  -- check below used to re-scan the WHOLE of `ow.entities` every tick,
  -- for every not-yet-taken item on the map, just to check "am I
  -- already inserted" -- the same O(points × entities) waste pattern
  -- independently found in five other files this same audit round (see
  -- `lib/DoomKill.lua`'s own `syncGibEntities` for the full derivation
  -- of the fix). `mapChanged` (captured BEFORE `lastMapId` gets
  -- overwritten below, since this file's own existing interior-reset
  -- logic already needed that same "did the map just change" fact)
  -- resets every point's own `inserted` flag exactly when `ow.entities`
  -- could plausibly have been rebuilt out from under it -- a real map
  -- (re)load -- so a stale flag never causes a real item to silently
  -- stop rendering.
  local mapChanged = mapId ~= lastMapId
  if mapChanged and mapItems.interior then
    mapItems.taken = {}
  end
  if mapChanged then
    for _, point in ipairs(mapItems.points) do point.inserted = false end
  end
  lastMapId = mapId

  local px, pz = ow.player.px + 8, ow.player.py + 8
  for i, point in ipairs(mapItems.points) do
    if not mapItems.taken[i] then
      entityFor[point] = entityFor[point] or makeItemEntity(point)
      if not point.inserted then
        table.insert(ow.entities, entityFor[point])
        point.inserted = true
      end

      local wx, wz = itemWorldPos(point.cx, point.cy)
      local dx, dz = wx - px, wz - pz
      if dx * dx + dz * dz <= PICKUP_RADIUS * PICKUP_RADIUS then
        triggerItemPickup(ow, mapItems, point, i)
      end
    elseif entityFor[point] then
      removeItemEntity(ow, point)
    end
  end
end

-- Torn down entirely when PKDOOM MODE is off, matching `lib/DoomKill.
-- lua`'s own exact reasoning: the classic (non-voxel) 2D render path
-- also walks `ow.entities` and calls `:draw()`, a method these fake
-- entities deliberately don't have.
local function teardownItems(ow)
  local ok, Game = pcall(require, "src.core.Game")
  local save = ok and Game.save
  if not (save and save.doomItems and ow) then return end
  for _, mapItems in pairs(save.doomItems) do
    for _, point in ipairs(mapItems.points) do
      if entityFor[point] then removeItemEntity(ow, point) end
    end
  end
end

-- ------- spawn-test menu support (user request, 2026-08-08: "setting
-- to spawn doom drop in front of player").
--
-- COMBINED INTO ONE ROW 2026-08-10, direct user request: "test item and
-- spawn item... should also be [combined]" (the same request applied to
-- TEST ENEMY/SPAWN ENEMY and TEST WEAPON/GIVE WEAPON -- see `lib/
-- DoomDemons.lua`'s own `spawnRow` for the full derivation of why this
-- is actually possible despite the real row-input contract only ever
-- giving a row `.activate` XOR `.step`). Same technique: a `.step`-only
-- row that reads `game.input:wasPressed("a")` itself (confirmed safe to
-- re-read within the same tick, `gen1recomp-dev/src/core/Input.lua:
-- 382-384`) to tell "this call is because A was pressed" apart from
-- "this call is because left/right was pressed."
--
-- `DROP_CHOICES` combines both real drop tables this file already has
-- -- every `REWARD_TABLE` entry (health/armor/ammo) and every
-- `WEAPON_TABLE` entry (a real gun pickup, the sprite family whose own
-- oversized-on-the-ground bug this file just fixed the same round --
-- this debug tool is also how that fix gets visually re-checked) --
-- rather than a single random roll, so a specific pickup can actually
-- be tested on demand.
-- FIX 2026-08-08 (Phase 24 audit, Tier 1 #1) -- this debug row had no
-- gate at all separating "the modder testing their own content" (the
-- row's own original 2026-08-08 request) from "any player of the
-- finished mod," even though a LATER, separate 2026-08-08 request
-- locked "the only 2 ways the player should be able to get weapons is
-- buy them in pokeshops, or through getting badges" as a real game
-- rule -- this row sat in the same Options menu any player sees and
-- could bypass that rule outright. `_G.POKEPORT_DEV_MODE` is the base
-- engine's own real, already-existing developer-mode signal
-- (`gen1recomp-dev/main.lua:250-251`'s `--developer` flag,
-- `conf.lua:8-18`'s `POKEPORT_DEV=1` env var equivalent -- confirmed by
-- reading both directly, not assumed) -- exactly the distinction
-- needed: true during this project's own normal dev-launch workflow
-- (`scripts/dev-launch.ps1`/`.sh` launch with `--developer`), false for
-- a normal player. Only the WEAPON entries are excluded outside dev
-- mode; every `REWARD_TABLE` entry (health/armor/ammo) has no such
-- restriction and stays available either way.
local DROP_CHOICES = {}
for _, e in ipairs(DoomItems.REWARD_TABLE) do
  DROP_CHOICES[#DROP_CHOICES + 1] = { name = e.name, isWeapon = false }
end
if _G.POKEPORT_DEV_MODE then
  for _, e in ipairs(DoomItems.WEAPON_TABLE) do
    DROP_CHOICES[#DROP_CHOICES + 1] = { name = e.name, sprite = e.sprite, isWeapon = true }
  end
end

local dropCursor = 1

local function spawnPickedItem(ow)
  local choice = DROP_CHOICES[dropCursor]
  -- Same real "2 cells ahead of the player's own facing, fall back to
  -- their own cell if that's not walkable" placement `lib/DoomDemons.
  -- lua`'s own TEST ENEMY row already uses.
  local cx = ow.player.cellX + (ow.player.facing == "right" and 2 or ow.player.facing == "left" and -2 or 0)
  local cy = ow.player.cellY + (ow.player.facing == "down" and 2 or ow.player.facing == "up" and -2 or 0)
  local walkOk, walkable = pcall(function() return ow.map:isWalkableCell(cx, cy) end)
  if not (walkOk and walkable) then cx, cy = ow.player.cellX, ow.player.cellY end
  DoomItems.dropItem(ow, cx, cy, choice.name, { sprite = choice.sprite, isWeapon = choice.isWeapon })
end

function DoomItems.spawnRow()
  return {
    id = "pokedoom_spawn_item",
    label = "TEST ITEM",
    value = function()
      return DROP_CHOICES[dropCursor].name
    end,
    step = function(game, dir)
      if game and game.input and game.input.wasPressed and game.input:wasPressed("a") then
        local ok, ow = pcall(function() return require("src.core.Game").overworld end)
        if ok and ow and ow.player and ow.map then pcall(spawnPickedItem, ow) end
        return false
      end
      dropCursor = ((dropCursor - 1 + (dir or 1)) % #DROP_CHOICES) + 1
      return true
    end,
  }
end

local installed = false
function DoomItems.install()
  if installed then return end
  installed = true

  installItemMeshHook()

  -- See `DoomItems.prewarm`'s own header comment above.
  pcall(function() DoomWadImport.onReady(DoomItems.prewarm) end)

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    -- Drains a small, time-budgeted slice of the background prewarm
    -- queue every real tick -- see `DoomWadImport.pumpPrewarm`'s own
    -- header comment. Runs unconditionally (not gated on `Options.
    -- enabled()`) so assets are already warm by the time the player
    -- turns PKDOOM MODE on, not only after.
    pcall(DoomWadImport.pumpPrewarm)
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    if ok and ow then
      if Options.enabled() then
        pcall(syncItems, ow)
      else
        pcall(teardownItems, ow)
      end
    end
    return next(game, dt)
  end)
end

return DoomItems
