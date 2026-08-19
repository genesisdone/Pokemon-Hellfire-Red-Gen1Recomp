-- PokeDoom: a standalone addon that turns the Dramatic Shape Voxel Mod's
-- existing 1ST-person camera into a DOOM-style FPS mode -- view parity,
-- weapons, a KILL mechanic in battle and the overworld, and (Phase 9,
-- reversing an earlier 2026-08-04 rescoping -- see CLAUDE.md's own
-- rescoping note) DOOM's real momentum-based movement. See CLAUDE.md for
-- the full phase plan.
--
-- Hard rule (CLAUDE.md): this mod never edits DramaticShapeVoxelMod-dev or
-- gen1recomp-dev. Everything below reaches the host mod only through
-- mod.find + the exports table it deliberately publishes at that mod's
-- main.lua:1188 ("mod.exports.lib = V ... exposed so a companion mod can
-- ... without reaching into this mod's file layout"), and reaches the
-- base engine only through its own public modules/hooks.

local mod = ...

-- CHANGED 2026-08-11, direct user request: "it should be compatible with
-- potato voxel, dramatic shape, and dramaless shape on any version." The
-- 2026-08-08 swap (see the old version of this comment, kept in git
-- history) hardcoded a SINGLE id ("potato_voxel") with a hard error if
-- that exact id wasn't found -- which is exactly what broke PokeDoom
-- outright on a real Steam Deck test running an older/differently-
-- forked build of the host mod: `mod.find` only ever matches an EXACT
-- id string, so a real, working, compatible host installed under any
-- OTHER name (the original `DRAMATIC_SHAPE`, or a third fork) was
-- invisible to this check, and PokeDoom refused to run at all --
-- matching the reported symptom exactly ("basically nothing at all
-- works... no first person, nothing spawns").
--
-- Every one of these forks publishes the SAME real `mod.exports.lib = V`
-- shape (the sanctioned extension seam CLAUDE.md's own "addon, not a
-- fork" section documents) -- a rename/fork doesn't change that contract,
-- only the manifest `id` string. Tries each known real id in turn and
-- uses whichever one is actually installed, with NO version floor (the
-- user's own explicit "on any version") -- matches `manifest.json`'s own
-- `optional_dependencies` list below, which is authoritative for what
-- ids are considered compatible; add a new fork's id to BOTH places
-- together, the same lesson the 2026-08-08 swap already taught (a
-- manifest-only or runtime-only update, without its matching half, is a
-- real, confirmed way for this exact check to silently drift out of
-- sync again).
-- FIX 2026-08-19 -- REAL ROOT CAUSE of "dramaless shape does not work
-- with pokedoom... doom mod refused to even enable saying the user
-- doesnt have a compatible voxel mod": `mod.find(id)` is a plain string
-- match, and the real, actual DramaLess Shape mod's own real manifest.
-- json declares its id as `"DRAMALESS_SHAPE"` (confirmed directly by
-- reading that mod's own real manifest.json, not assumed) -- this list's
-- own third entry was lowercase (`"dramaless_shape"`), so it never
-- matched a real DramaLess Shape install at all, regardless of version,
-- the exact same silent-drift failure shape the 2026-08-08 swap already
-- caused once (see this section's own header comment above). Both this
-- array and `manifest.json`'s own matching `optional_dependencies` entry
-- are corrected together.
local HOST_IDS = { "potato_voxel", "DRAMATIC_SHAPE", "DRAMALESS_SHAPE" }
local host
for _, id in ipairs(HOST_IDS) do
  host = mod.find(id)
  if host then break end
end
if not host then
  error("PokeDoom requires one of: " .. table.concat(HOST_IDS, ", ") ..
        " (a compatible Dramatic Shape Voxel Mod fork) to be installed " ..
        "and enabled -- see CLAUDE.md", 0)
end

-- ------- our own sibling-module loader
--
-- Same shape as the host mod's own (see that mod's main.lua): a mod
-- folder may live inside a mounted .love archive, which plain require
-- cannot reliably reach, so lib/ modules load through V.require instead
-- of package.path. V.host carries the host's published lib namespace, so
-- our modules call V.host.require("FreeMove") etc. rather than V.require
-- for anything that belongs to the host mod.

local V = { mod = mod, path = mod.path, host = host.exports.lib }

local function chunkFor(rel)
  local source = mod:read(rel)
  if not source then
    error(("POKEDOOM: %s is missing -- reinstall the mod"):format(rel), 0)
  end
  local chunk, err = load(source, "@" .. mod.path .. "/" .. rel)
  if not chunk then
    error(("POKEDOOM: %s did not compile: %s"):format(rel, tostring(err)), 0)
  end
  return chunk
end

local modules = {}
function V.require(name)
  local hit = modules[name]
  if hit ~= nil then return hit end
  local value = chunkFor("lib/" .. name .. ".lua")(V)
  modules[name] = value
  return value
end

local Options = V.require("DoomOptions")
local DoomWadImport = V.require("DoomWadImport")
local DoomGZDoomImport = V.require("DoomGZDoomImport")
local DoomLog = V.require("DoomLog")

-- Real, verified fixes for host-mod (potato_voxel-main) bugs found
-- while developing this mod -- see `lib/DoomHostFixes.lua`'s own header
-- for the full CachePrebuild/MeshCache bug history (moved there
-- 2026-08-19 during a project-wide readability audit, so this file's own
-- module-wiring sequence below isn't buried under it). Called here, at
-- the SAME early point in load order the original inline code ran at,
-- since the MeshCache/CachePrebuild fixes need to apply before anything
-- else touches those host modules -- `lib/DoomDiagnostics.lua`'s own
-- periodic watch (installed later, see below) fetches the same resolved
-- state itself, via that same real `.install()`'s own idempotency guard.
V.require("DoomHostFixes").install()

local DoomView = V.require("DoomView")
local DoomWeapons = V.require("DoomWeapons")
local DoomKill = V.require("DoomKill")
local DoomMove = V.require("DoomMove")
local DoomHud = V.require("DoomHud")
local DoomHealth = V.require("DoomHealth")
local DoomItems = V.require("DoomItems")
local DoomRewards = V.require("DoomRewards")
local DoomInventory = V.require("DoomInventory")
local DoomDemons = V.require("DoomDemons")
local DoomTownInvasion = V.require("DoomTownInvasion")
local DoomBlood = V.require("DoomBlood")
local DoomPuff = V.require("DoomPuff")
local DoomMenuSkin = V.require("DoomMenuSkin")
local DoomBadgeRewards = V.require("DoomBadgeRewards")
local DoomWildsCompat = V.require("DoomWildsCompat")
local DoomBarrels = V.require("DoomBarrels")
local DoomSettingsMenu = V.require("DoomSettingsMenu")
local DoomProps = V.require("DoomProps")
local DoomDeathScreen = V.require("DoomDeathScreen")

-- DIAGNOSTIC 2026-08-11 (Steam Deck "doom menu shows no text" /
-- "nothing spawns" bug): logs the real, resolved asset-root paths once,
-- via `DoomLog.event` -- a bare `print()` from inside `DoomWadImport.
-- lua` itself was tried first and confirmed NOT to reach this log file
-- (only `DoomLog.write` does; see that file's own `DoomLog.write`).
--
-- FIX 2026-08-11 -- the FIRST version of this diagnostic ran here, at
-- raw top-level module-load time (during the synchronous require chain,
-- before the game loop/window exists at all) -- and never showed up in
-- the user's next log either, with no error visible anywhere. This
-- file's own `checkExistingExtraction` hit this EXACT class of bug
-- before (see that function's own header comment): code run this early
-- can misbehave in ways that never surface as a normal Lua error. Moved
-- into the existing, CONFIRMED-working `input.step` diagnostic wrap
-- (`lib/DoomDiagnostics.lua`, same place "DOOM MODE toggled" already
-- logs successfully every session), firing once on the first real tick
-- instead -- and reporting its own pcall failure explicitly (`err`)
-- instead of swallowing it silently, so if this STILL doesn't show up,
-- the log itself says why rather than just going quiet again.

-- DIAGNOSTIC 2026-08-11 (crash log from a real save: "src/core/
-- SaveSerializer.lua:41: cannot serialize function" -- some value
-- somewhere under Game.save is a Lua function, which that encoder
-- can't turn into save bytes). `SaveSerializer.lua`'s own `serialize`
-- (read directly, base engine, not edited) recurses through EVERY key
-- of the whole save table with NO path tracking at all -- the error
-- message alone can't say which of PokeDoom's own several `Game.save.*`
-- tables (or which base-engine one) actually holds the bad value. Doing
-- our OWN walk, with a path, is far faster than grepping every call
-- site in this mod for one that might store a whole live table
-- (containing a function field) instead of plain data.
--
-- `Game.lua:1013-1014`'s own real `writeSave` fires `save.writing` with
-- `{ save = self.save, ... }` AFTER the overworld's own `captureSave`
-- has run (so this sees the exact same table `SaveData.save` is about
-- to hand to the serializer) and BEFORE that serializer call happens --
-- the correct, sanctioned point to observe this from an addon (`mod.
-- events:on`, not a host-file edit). Cycle-safe (`visited`, keyed by
-- table identity) since save data can plausibly self-reference.
local function findFunctionPath(t, path, visited, depth)
  if depth > 60 or type(t) ~= "table" or visited[t] then return nil end
  visited[t] = true
  for k, v in pairs(t) do
    local newPath = path .. "." .. tostring(k)
    if type(v) == "function" then
      return newPath
    elseif type(v) == "table" then
      local found = findFunctionPath(v, newPath, visited, depth + 1)
      if found then return found end
    end
  end
  return nil
end

-- FIX 2026-08-12 -- this diagnostic has been firing (and, per the crash
-- log's own repeated timestamps, the actual crash keeps happening) but
-- its own answer has never once shown up in any session log. Root
-- cause: `DoomLog.write`'s buffered flush (`FLUSH_INTERVAL_LINES=20`/
-- `FLUSH_INTERVAL_SECONDS=1`, added for the hot weapon-fire logging
-- path) means a line sits in memory, not on disk, until one of those
-- thresholds is crossed -- and `save.writing` fires immediately BEFORE
-- the serializer call that then throws, with no time for either
-- threshold to pass in between. `DoomLog.lua`'s own `DoomLog.flush()`
-- was written for exactly this ("a genuinely important moment... should
-- reach for this instead of re-adding a per-write flush") but was never
-- actually wired to a real call site until now.
V.mod.events:on("save.writing", function(payload)
  local ok, result = pcall(findFunctionPath, payload and payload.save, "save", {}, 0)
  if ok and result then
    pcall(DoomLog.event, "DIAG",
      "save.writing: FOUND function value at %s -- this is what crashes the save", result)
  elseif ok then
    pcall(DoomLog.event, "DIAG", "save.writing: walked the whole save table, no function value found")
  else
    pcall(DoomLog.event, "DIAG", "save.writing scan itself failed: %s", tostring(result))
  end
  pcall(DoomLog.flush)
end)

-- ------- "Doom Settings" submenu -- user request, 2026-08-10: "put all
-- these settings + the original settings added for the mod in their own
-- settings category that you can go inside of called 'Doom Settings'."
-- Registers this mod's own nested settings screen (lib/
-- DoomSettingsMenu.lua) under a real id so `src.ui.Screens.push` can find
-- it -- the base engine's own public `mod.content.screens` registry
-- (`src/mods/Schemas.lua`'s own documented `register(id, { new = fn })`
-- shape), the exact same seam the MODS row's own `ManagerState` screen
-- and this mod's own future submenus would use. Every real PokeDoom
-- settings row now lives inside that screen instead of the flat splice
-- this hook used to append directly -- see the hook below.
mod.content.screens:register("PokeDoomSettings", {
  new = function(game) return DoomSettingsMenu.new(game) end,
})

-- ------- options menu rows
--
-- Row shape and the ui.options.rows hook are the base engine's own
-- (src/ui/OptionRows.lua, src/ui/OptionsMenu.lua) -- calling next() first
-- and appending after it is the documented convention so every other
-- mod's rows (including the host's own VOXEL/T-SHIFT rows) survive ours.
--
-- REMOVED 2026-08-10 -- HORDE MODE's own settings-menu row
-- (`DoomHorde.row()`) removed along with the rest of this mod's own
-- Horde-tie-in (see phases/phase-27-horde-unification.md's own final
-- log entry and docs/horde-reincorporation.md for the full removal
-- writeup and reasoning). The host's own pre-existing Konami-code
-- trigger for Horde Mode is completely untouched -- this only removes
-- the ADDITIONAL settings-menu entry point this mod added on top of it.
--
-- RESTRUCTURED 2026-08-10 -- every real PokeDoom settings row (both
-- `Options.rows()`'s own ~24 rows and CHOOSE DOOM WAD) used to be
-- spliced directly into this flat top-level list. Now just ONE
-- navigation row opens the nested "Doom Settings" screen instead (see
-- `lib/DoomSettingsMenu.lua`'s own header comment for the full design).
--
-- MOVED 2026-08-10 (same day, follow-up request): the debug/testing
-- rows (TEST ENEMY, TEST ITEM, TEST WEAPON, START INVASION) that used
-- to be spliced here too have all moved INTO `lib/DoomSettingsMenu.lua`
-- itself (see that file's own `buildRows` for the full reasoning) -- so
-- the only thing this hook adds now is the single DOOM SETTINGS row.
--
-- REORDERED 2026-08-10, direct user request: "put doom settings and
-- controls at the top of options above everything else." CONTROLS is a
-- real VANILLA row (`gen1recomp-dev/src/ui/OptionsMenu.lua`'s own
-- `buildRows`, `id = "controls"`) already present somewhere in `out` by
-- the time this hook runs -- pulled out of wherever it already was and
-- reinserted at the front, right after our own new row, rather than
-- removed/duplicated. Every other row (vanilla or another mod's own)
-- keeps its original relative order behind these two.
mod.hooks:wrap("ui.options.rows", function(next, game, rows)
  local out = next(game, rows)
  if type(out) ~= "table" then return out end

  local doomSettingsRow = {
    id = "pokedoom_settings_menu",
    label = "DOOM SETTINGS",
    activate = function(g)
      require("src.ui.Screens").push(g, "PokeDoomSettings")
    end,
  }

  local controlsRow, rest = nil, {}
  for _, row in ipairs(out) do
    if row.id == "controls" and not controlsRow then
      controlsRow = row
    else
      rest[#rest + 1] = row
    end
  end

  local reordered = { doomSettingsRow }
  if controlsRow then reordered[#reordered + 1] = controlsRow end
  for _, row in ipairs(rest) do reordered[#reordered + 1] = row end
  return reordered
end)

-- ------- session log file -- installed FIRST, before every other
-- module, so anything below that wants to log has somewhere real to
-- write to from its own very first tick. See lib/DoomLog.lua's own
-- header comment for the full user request this answers.
DoomLog.install()

-- ------- Phase 1: first-person view parity
--
-- Wraps FirstPerson.frame (see lib/DoomView.lua for why, not
-- FirstPerson.fovScale) -- installed at load time same as every wrap in
-- this codebase, after the host's own main.lua has already run (our hard
-- dependency guarantees that), which is what makes this wrap the
-- outermost layer over that function.
DoomView.install()

-- FIX 2026-08-08 -- see lib/DoomWadImport.lua's own header comment on
-- `checkExistingExtraction`: this used to run unconditionally at module
-- load (during mod boot, before the game window exists), a real blocking
-- shell-out that was delaying the whole GAME from starting, not just
-- item prewarm. Installed early, before any other file that might touch
-- `DoomWadImport.status`, so the deferred check runs on the very first
-- real tick regardless of install order elsewhere.
DoomWadImport.install()

-- Same real reasoning as `DoomWadImport.install()` right above --
-- `lib/DoomGZDoomImport.lua`'s own `checkExistingExtraction` needs the
-- same first-tick deferral, for the same reason.
DoomGZDoomImport.install()

-- Watches both of the imports installed just above -- locks DOOM MODE
-- off until both are ready, then auto-activates it once, the first time
-- they both are (see `lib/DoomOptions.lua`'s own `Options.install`
-- header comment for the full derivation).
Options.install()

-- ------- Phase 2: weapon framework
--
-- Claims left-click (fire), number keys (weapon select), input.step (the
-- state-machine tick), and render.hud (the view model) -- see
-- lib/DoomWeapons.lua for why each of those seams was picked.
DoomWeapons.install()

-- ------- dev command: give yourself a weapon (console: pokedoom_give)
--
-- Published through mod.exports too, the same sanctioned inter-mod seam
-- DramaticShapeVoxelMod-dev itself uses to publish to this mod (see
-- CLAUDE.md) -- lib/DoomWeapons.lua already set the _G side; this is the
-- non-global way to reach it (e.g. `mod.find("POKEDOOM").exports.give`).
mod.exports = mod.exports or {}
mod.exports.give = DoomWeapons.give

-- ------- dev command: hurt yourself without a real damage source
-- (console: pokedoom_hurt) -- same dual _G/mod.exports pattern as
-- pokedoom_give above; lib/DoomHealth.lua already set the _G side. See
-- that file's own header comment and phases/phase-12-health-armor-
-- damage.md's own open question for why this is currently the ONLY way
-- to exercise the real damage pipeline -- nothing in this mod's own
-- scope damages the player on its own yet.
mod.exports.hurt = DoomHealth.hurt

-- Phase 13: real damagecount/bonuscount decay (P_PlayerThink's own
-- `if (damagecount) damagecount--`/`bonuscount--`, p_user.c:355-359) --
-- see lib/DoomHealth.lua's own install() comment. Feeds lib/DoomHud.
-- lua's new palette-flash and evil-grin face state.
DoomHealth.install()

-- ------- Phase 11 (scoped): the status bar background, ready-ammo,
-- health/armor, and face widget
--
-- Installed AFTER DoomWeapons above so its own `love.draw` wrap -- and
-- therefore the status bar -- draws ON TOP of the weapon view model, not
-- under it: real DOOM relies on the status bar being the LAST thing
-- drawn to hide whatever a tall weapon sprite overflows past the
-- 200-line screen edge (see lib/DoomHud.lua's own install() comment).
-- The arms grid and Phase 11's own "still blocked" face states (evil
-- grin, ouch, turning) are not part of this yet -- pending Phase 13/14.
DoomHud.install()

-- ------- Phase 20 (scoped: pause menu + Options submenu only): the
-- pause menu (StartMenu) and its Options submenu (OptionsMenu),
-- redrawn in real DOOM's own menu visual style. Installed AFTER
-- DoomHud, same real reason as that file's own install-order comment
-- just above -- this wraps `love.draw` too, and needs to layer ON TOP
-- of the status bar, matching a real DOOM menu drawing over its own
-- HUD. See lib/DoomMenuSkin.lua for the full derivation.
DoomMenuSkin.install()

-- ------- Phase 8 (scoped): killing overworld NPCs
--
-- Registers a target resolver with DoomWeapons.hitscan (the seam Phase 2
-- built for exactly this, which only needs DoomWeapons' TABLE to exist,
-- not its install() to have already run) and its own input.step hook for
-- the kill-persistence sweep and gib-entity sync. A gib itself renders as
-- a real, minimal entry in `ow.entities` -- drawn by the completely
-- unmodified `VoxelScene.render`/`drawCast`/`drawEntity` pipeline, not a
-- screen-space overlay -- see lib/DoomKill.lua's own install() comment
-- for the full reasoning.
DoomKill.install()

-- The "YOU LOST" death screen (`lib/DoomDeathScreen.lua`) -- after
-- DoomKill (whose own player-caused kill sites can force a death via
-- this file's `punishEssentialKill`) and DoomHud (whose own `love.draw`
-- wrap calls this file's `drawOverlayBackground`/`drawOverlayText`), so
-- both real call sites it's wired into already exist by the time this
-- runs.
DoomDeathScreen.install()

-- ------- Phase 9: movement port
--
-- Wraps `FirstPerson.moveWorld` (a small, pure rotation with exactly one
-- real caller in the whole host mod, `FreeMove.tick`) so DOOM's own real
-- accelerate/friction momentum decides what velocity FreeMove's own
-- unmodified collision-aware slide actually applies -- see
-- lib/DoomMove.lua for the full derivation and reasoning.
DoomMove.install()

-- ------- Phase 13: DOOM's item roster as randomly-generated world
-- pickups, battle-win item rewards, and the trainer-battle weapon
-- reward -- see lib/DoomItems.lua and lib/DoomRewards.lua for the full
-- derivation. DoomItems wraps `SpriteBillboards.mesh` the same live-
-- table-field way lib/DoomKill.lua's own gib rendering already does;
-- install order between the two doesn't matter -- each wrap chains
-- through whichever it finds already installed, the same composable
-- pattern this whole codebase already uses for love.draw. DoomRewards
-- subscribes to the base engine's own real `battle.ended` event
-- (`mod.events:on`, not `mod.hooks:wrap` -- a different, but equally
-- public, mod-facing seam -- see that file's own header comment).
DoomItems.install()
DoomRewards.install()

-- Real DOOM weapons/ammo mirrored into the game's own ITEMS bag
-- (PAUSE -> ITEMS) -- see lib/DoomInventory.lua for the full derivation,
-- including the `mod.content.items:register(...)` seam this relies on.
DoomInventory.install()

-- REMOVED 2026-08-10 -- Phase 6/21's own HORDE MODE settings row and
-- PKDOOM-weapons-vs-Horde-mobs target/AOE resolver (`DoomHorde.install()`,
-- `DoomHordeTarget.install()`) both removed along with the rest of this
-- mod's own Horde-tie-in -- see docs/horde-reincorporation.md.

-- Phase 21: the real DOOM demon roster, as ambient roaming world
-- entities (regular mode, ammo/citizen-hunting, outdoor-only) and a
-- SPAWN ENEMY options row for manual testing -- see lib/DoomDemons.lua
-- for the full derivation, including the deliberate simplifications
-- (a looping animation clock instead of DOOM's own exact per-tic state
-- machine, a direct-step roam/chase instead of DOOM's own BSP-blockmap
-- `A_Chase`) and the real DOOM data (sprite/frame/tic tables, mobjinfo
-- stats) those simplifications are still built from.
DoomDemons.install()

-- Real DOOM exploding barrels (`MT_BARREL`), scattered on grass --
-- direct user request, 2026-08-10: "add random explosive barrels from
-- the original doom to grassy areas... barrels should move slightly
-- when shot just like original barrels from doom source code." Installed
-- right after DoomDemons -- this file reuses that one's own real sprite-
-- loading/mesh-building pipeline (`DoomDemons.loadSprite`, and the
-- SAME already-installed `SpriteBillboards.mesh`/`.shadowQuad` hook,
-- via the shared `pokedoomDemon` marker) rather than duplicating any of
-- it -- see lib/DoomBarrels.lua for the full derivation.
DoomBarrels.install()

-- Real DOOM decorative "thing" objects (pillars, torches, corpses,
-- hanging gore, pools, lights), manually placed via a Q-key menu --
-- direct user request, 2026-08-10. Installed right after DoomBarrels for
-- the same reason: reuses DoomDemons' own sprite-loading/mesh pipeline
-- via the shared `pokedoomDemon` marker rather than duplicating it. See
-- lib/DoomProps.lua for the full derivation.
DoomProps.install()

-- Badge-gated progression -- user request, 2026-08-08: demon difficulty
-- gated by real Kanto gym badge count (see lib/DoomDemons.lua's own
-- `DEMON_UNLOCK_ORDER`/`pickDemonName`, which this depends on), plus a
-- new weapon and an "enemy unlocked" announcement on every real badge
-- win -- see lib/DoomBadgeRewards.lua for the full derivation. Installed
-- after DoomDemons (reads its DEMON_UNLOCK_ORDER/demonDisplayName) and
-- DoomWeapons/DoomHud (both already required above); no draw-order
-- dependency of its own.
DoomBadgeRewards.install()

-- REMOVED 2026-08-10 -- Phase 21/6's own Horde-mob reskin/health-sync/
-- HUD-suppression (`DoomHordeControl.install()`) removed -- direct user
-- request after repeated, compounding Horde-specific bugs (a death-
-- animation bug, a wave-progress stall, a first-person pause-key gap)
-- traced to Horde's own PokeDoom-side integration having grown into a
-- genuinely separate codebase from the ambient demon system it should
-- have been calling into from the start. See
-- docs/horde-reincorporation.md for the full writeup -- what was built,
-- why it was removed, and how to build it correctly next time.

-- Town invasion events -- user request, 2026-08-08: ambient demons no
-- longer spawn in towns at all (that fix lives in lib/DoomDemons.lua's
-- own `ambientSpawnTick`); this is the deliberate replacement -- a
-- scheduled event that spawns demons in whatever town the player is
-- currently in, sends every town NPC fleeing into the nearest interior
-- until they're all dead, and draws its own real "DEMONS REMAINING"
-- counter. See lib/DoomTownInvasion.lua for the full derivation,
-- including why this borrows Horde Mode's own wave-clear PATTERN
-- rather than an actual running Horde session -- this borrowing is
-- read-only (the host's own `Horde.SONG` constant, and a pattern, not
-- a dependency), so it's entirely unaffected by this mod's own Horde
-- integration being removed above.
DoomTownInvasion.install()

-- The real blood impact effect (P_SpawnBlood) on every landed hitscan
-- hit -- see lib/DoomBlood.lua for the full derivation. No draw-order
-- dependency on anything above (reuses lib/DoomDemons.lua's own already-
-- installed SpriteBillboards.mesh hook, checked lazily per frame, not at
-- install time), so its own position here isn't load-bearing.
DoomBlood.install()

-- The real bullet-impact puff effect (P_SpawnPuff) whenever a hitscan
-- shot hits a wall instead of a shootable target -- see lib/DoomPuff.lua
-- for the full derivation. Same no-draw-order-dependency reasoning as
-- DoomBlood.install() just above.
DoomPuff.install()

-- Wilds-of-Kanto (third-party mod, `overworld_wild_spawns`) follower
-- movement compatibility -- makes the party Pokemon trailing the player
-- in that mod move with this mod's own continuous PKDOOM MODE movement
-- instead of Wilds' own classic grid-stepping, while PKDOOM MODE is
-- actually driving. Read-only against Wilds' own source; only ever wraps
-- a live table field, per CLAUDE.md's "addon, not a fork" rule extended
-- to this dependency -- see lib/DoomWildsCompat.lua for the full
-- derivation. No draw-order dependency on anything else here.
DoomWildsCompat.install()

-- Covers the real, unavoidable async terrain-mesh-loading window (map
-- boot, any warp into new geometry) so PKDOOM MODE never shows the raw
-- flat 2D fallback, even briefly -- see lib/DoomView.lua's own
-- `installLoadingCover` for the full diagnosis. Deliberately called LAST,
-- after every other `.install()` above: this has to be the OUTERMOST
-- `love.draw` wrap (drawn on top of literally everything, including this
-- mod's own HUD) to actually cover the screen, and whichever wrap is
-- installed last becomes outermost.
DoomView.installLoadingCover()

-- Real, session-log-backed runtime diagnostics (gate-state toggle
-- logging, the WAD-root/host-fix resolution log, the onTop()/
-- CachePrebuild watches) -- see lib/DoomDiagnostics.lua for the full
-- history of what each one was added to investigate. Installed LAST,
-- after every real feature module above, since none of this mod's own
-- actual gameplay depends on it existing -- it only ever OBSERVES the
-- other systems' own live state.
V.require("DoomDiagnostics").install()

-- Phase 6/7 onward will require() their own lib/ modules and install()
-- themselves here the same way.
