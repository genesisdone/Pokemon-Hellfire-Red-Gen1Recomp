-- PokeDoom: options -- the master switch. Movement is no longer this
-- mod's concern (see CLAUDE.md's rescoping) -- it rides the host mod's
-- existing 1ST/3RD camera and its own FreeMove, completely unmodified.
-- What this switch will gate, as later phases land: first-person view
-- parity (FOV/view bob), the weapon HUD and firing, and the battle/
-- overworld KILL mechanic.
--
-- Row shape and the ui.options.rows hook are the base engine's own
-- (src/ui/OptionRows.lua: { id, label, value = fn(game)->string,
-- step = fn(game, dir)->changed }; src/ui/OptionsMenu.lua feeds rows
-- through the hook). Persisted the same way the engine's own option rows
-- are -- directly under game.save.options, under our own key -- so
-- SaveData.mergeOptions's "unknown keys survive" guarantee
-- (gen1recomp-dev/src/core/SaveData.lua) carries it across saves written
-- by older builds of this mod or without it installed at all.
--
-- Default OFF: installing this addon must not change how the host mod's
-- existing 1ST/3RD rungs behave until the player opts in.

local V = ...
local Options = {}

-- FEATURE 2026-08-19, direct user request: "make sure doom mode cannot
-- be enabled until both pk3 and wad are added. once both are, doom mode
-- should automatically activate." Neither import file requires this one
-- back (`lib/DoomWadImport.lua`'s own header comment on its
-- `V.require("DoomWadImport")` circular-load note is about `lib/
-- DoomLog.lua`, not this file; `lib/DoomGZDoomImport.lua` only requires
-- `DoomWadImport`), so a plain top-level require here is safe.
local DoomWadImport = V.require("DoomWadImport")
local DoomGZDoomImport = V.require("DoomGZDoomImport")

-- True once BOTH real asset imports this mod depends on report "ready":
-- Locked Decision 5's own DOOM WAD (weapon/demon/item sprites and
-- sounds) and the separate GZDoom pk3 import (`lib/DoomGZDoomImport.lua`,
-- the pause menu's own real BigUpper font). Gates the DOOM MODE row's
-- own `step` below, and drives `Options.install()`'s own auto-activate
-- watcher further down this file.
local function assetsReady()
  return DoomWadImport.status.state == "ready" and DoomGZDoomImport.status.state == "ready"
end
Options.assetsReady = assetsReady

-- Lazy, pcall-guarded -- `lib/DoomLog.lua` itself requires THIS file
-- (for `Options.loggingEnabled`), so a top-level require here would be
-- a real circular load. Used only by the LOGGING row's own `value()`
-- below, to surface `DoomLog.status()`'s real failure reason (if any)
-- directly in the settings row's own displayed text -- added 2026-08-11
-- after the LOGGING toggle itself failed silently with no file, no
-- console, and no way to diagnose it without exactly this.
local DoomLog
local function getDoomLog()
  if DoomLog then return DoomLog end
  local ok, mod = pcall(V.require, "DoomLog")
  if ok then DoomLog = mod end
  return DoomLog
end

-- `messages`: real DOOM's own `showMessages` option (`m_menu.c`'s
-- options screen), found by Phase 16's own fresh audit of `hu_stuff.c`
-- (`HU_Ticker`, hu_stuff.c:518: pickup text is gated behind this,
-- entirely separate from `message_dontfuckwithme`'s own netgame-chat-
-- only override). Real DOOM's own default is ON (`m_menu.c`'s
-- `showMessages = 1` at declaration) -- matched here.
--
-- `tightLedges`: Phase 18 Bug 6 -- not a real DOOM option (DOOM has no
-- ledge-hop mechanic at all; this is a real Gen-1 mechanic this mod's
-- own free-roam movement inherits through the host's `FreeMove.lua`).
-- Requested by the user as "a setting thats toggled on by default", so
-- default true here, same posture as `messages` above (a quality-of-
-- life fix defaulting to the FIXED behavior, not the old behavior) --
-- see `lib/DoomMove.lua`'s own `checkLedgeHop` wrap for what this gates.
-- `demons`: Phase 21 -- ambient DOOM demons roaming the outdoor
-- overworld, hunting citizens/the following Pokémon. Real DOOM has no
-- equivalent (its demons wait in a fixed level until they see the
-- player, not an open, persistent world) -- this mod's own, explicitly
-- requested departure ("it shouldnt just be demons looking for
-- citizens 24/7, it should be the demon roaming indefinitely"), so it
-- gets its own toggle rather than riding PKDOOM MODE's own switch
-- silently. CHANGED 2026-08-19, direct user request ("enemies: on" as a
-- new default) -- default is now ON, no longer matching PKDOOM MODE's
-- own OFF-by-default posture. Reasonable on its own terms too: DOOM MODE
-- itself is now locked behind both real asset imports being ready
-- (`Options.assetsReady`, added the same day) before it can ever turn
-- on at all, so by the time this row's value is ever actually reachable
-- in play, the player has already deliberately set the mode up -- ON is
-- the more useful default at that point, not a surprise sprung on
-- someone who hasn't opted in yet.
-- `infiniteAmmo`/`infiniteHealth`: user-requested dev-style conveniences
-- (2026-08-07), not real DOOM options (real DOOM's own equivalents are
-- the `IDFA`/`IDDQD` CHEAT CODES, not menu toggles -- see
-- `phases/phase-14-god-mode.md` for the god-mode/`IDDQD` phase this
-- would eventually fold into once that phase's own `player.cheats`
-- flag exists; `lib/DoomHealth.lua`'s `DoomHealth.damage()` already
-- has the exact `opts.godmode` seam that phase left open, reused here
-- rather than duplicating a second immunity check). Default OFF, same
-- posture as every other significant behavior-changing toggle in this
-- project.
-- `pokemonGore`: user request (2026-08-10): "add an option for 'pokemon
-- gore'... 4 settings 'NPCs, Pokemon, All, None' which will disable
-- killing... pokemon npcs, pokemon, all of them, or not be able to kill
-- anything other than doom demons." CORRECTED same day, per the user's
-- own precise follow-up clarification (the first implementation had the
-- polarity backwards): each value names what's ALLOWED to be killed, not
-- what's blocked. "None" = neither NPCs nor Pokemon are killable. "NPCs"
-- = you can ONLY kill NPCs (Pokemon protected). "Pokemon" = you can ONLY
-- kill Pokemon (NPCs protected, the symmetric mirror of "NPCs", not
-- separately restated by the user but implied). "All" = both are
-- killable -- nothing blocked. See `lib/DoomKill.lua`'s own
-- `isPokemonNpc`/gating at its real kill choke points for what "NPCs"
-- vs. "Pokemon" actually means here -- ambient DOOM demons are a
-- completely separate kill system (`lib/DoomDemons.lua`) and are never
-- gated by this option at all, matching the user's own "anything other
-- than doom demons" phrasing.
--
-- CHANGED 2026-08-12, direct user request ("make pokemon gore default
-- to npcs"): default is now "npcs" (Pokemon protected by default, human
-- NPCs killable) rather than "all" -- only affects a save that has
-- never touched this row (`Options.get`'s own nil-check backfill,
-- above); an existing save with an explicit stored value is unaffected.
-- `camera`: user request (2026-08-10): "add an option to settings for
-- camera and options will be 'locked, freelook' and freelook should
-- actually let you freelook instead of being locked on the y axis."
-- "locked" (default) preserves this mod's own original, deliberate
-- design (`lib/DoomView.lua`'s own `lockPitch` header comment: real
-- linuxdoom-1.10 has no pitch/mouselook mechanic at all -- forcing
-- `FirstPerson.pitch = 0` every frame is what ported that real absence).
-- "freelook" is an explicit, opt-in DEPARTURE from that parity, not a
-- bug fix -- lets vertical look actually move, same as any later source
-- port's own mouselook.
-- The 13-row batch below, added 2026-08-10, all at the user's own
-- explicit request (the full list, verbatim: DEMON DIFFICULTY, DEMON
-- DENSITY, TOWN INVASIONS, INVASION FREQUENCY, VIEW BOB, SCREEN SHAKE,
-- HUD, PALETTE FLASH, SHOW WEAPON, STARTING LOADOUT, WEAPON SWITCH ON
-- PICKUP, PARTY KILL CONFIRMATION, NPC RESPAWN TIMER). Every default
-- below preserves this mod's own existing behavior exactly for anyone
-- who never opens a settings row -- same posture every prior row in
-- this file already uses -- with explicit exceptions the user asked for
-- directly: `partyKillConfirmation` originally defaulted to true (ON),
-- not the "preserve prior behavior" default a new safety feature would
-- otherwise get by this file's own convention -- CHANGED 2026-08-19,
-- see that field's own comment below, along with `demons`/`partyKilling`,
-- for the current defaults and why.
local DEFAULTS = {
  enabled = false, messages = true, tightLedges = true, demons = true,
  enemyType = "demons", enemyDrops = "money", pokemonGore = "npcs",
  camera = "locked",
  demonDifficulty = "normal", demonDensity = "normal",
  townInvasions = true, invasionFrequency = "normal",
  viewBob = true, screenShake = true, hud = true, paletteFlash = true,
  showWeapon = true, startingLoadout = "pistol", weaponSwitchOnPickup = true,
  -- `partyKillConfirmation`: originally defaulted to true (ON, a
  -- deliberate exception to this block's own "preserve prior behavior"
  -- convention -- see the header comment above). CHANGED 2026-08-19,
  -- direct user request ("party kill confirmation: off") -- now OFF by
  -- default, matching every other row's "preserve prior behavior"
  -- posture again.
  partyKillConfirmation = false, npcRespawnTimer = "off",
  -- FEATURE 2026-08-10 -- direct user request: "add setting to doom
  -- settings: Party Killing (so you can disable being able to kill
  -- your party at all, so the bullets will just fly through them to
  -- whatever target is past them." Originally defaulted ON, preserving
  -- this mod's own existing behavior exactly. CHANGED 2026-08-19, direct
  -- user request ("party killing: off") -- now OFF by default, so a
  -- player who never opens this row keeps their own party protected
  -- from stray fire. See `lib/DoomKill.lua`'s own `isPartyNpc`/
  -- `npcKillBlocked` for what this actually gates: specifically the
  -- player's own real party-member followers (Wilds-of-Kanto's
  -- `pokepcMon`, Yellow's own Pikachu follower), distinct from POKEMON
  -- GORE's own broader "any Pokemon-as-NPC" gate above, which also
  -- covers ambient/wild Pokemon that aren't the player's own party.
  partyKilling = false,
  infiniteAmmo = false, infiniteHealth = false,
  -- FEATURE 2026-08-11 -- direct user request: "add option in settings
  -- to turn logging on (off by default)." `lib/DoomLog.lua`'s own
  -- persistent per-session log file (this project's single biggest real
  -- debugging tool across a long multi-platform bug hunt) has been
  -- unconditional up to now -- always creates and writes a real file on
  -- disk from the moment anything first logs. Default OFF per the
  -- user's own explicit instruction; a modder chasing a bug turns this
  -- on first, same as every other DOOM SETTINGS toggle in this list.
  logging = false,
}

-- FIX 2026-08-10 -- user report: the mod failed to load with "mods/
-- PokeDoom-dev/lib/DoomOptions.lua:105: attempt to index field 'save'
-- (a nil value)." `Options.get` always assumed `Game.save` already
-- exists, which held for every real gameplay call site (an overworld/
-- battle genuinely can't exist without a loaded save) -- but the newly
-- much-larger DOOM SETTINGS row list (13 new rows this same round) made
-- it far more likely something exercises a row's own `value()` function
-- -- and therefore `Options.get` -- with no save loaded at all: the Mod
-- Manager's own real "game.data is nil under the stub games the UI
-- harnesses drive" case (`gen1recomp-dev/src/ui/OptionsMenu.lua`'s own
-- comment, confirmed by reading it directly), most plausibly sanity-
-- checking every registered row while enabling/validating this mod.
-- Returns a plain, non-persisted copy of `DEFAULTS` in that case rather
-- than crash -- correct behavior anyway for "what would this setting
-- read as with no real game context," and every actual gameplay path
-- still gets the real, save-backed, persisted table exactly as before.
local function defaultsCopy()
  local copy = {}
  for k, v in pairs(DEFAULTS) do copy[k] = v end
  return copy
end

-- Every key besides `enabled` (already covered by the constructor above --
-- see the comment on the block this is called from) that a save written by
-- an older build of this mod might be missing entirely.
local BACKFILL_KEYS = {
  "messages", "tightLedges", "demons", "enemyType", "enemyDrops",
  "pokemonGore", "camera", "demonDifficulty", "demonDensity",
  "townInvasions", "invasionFrequency", "viewBob", "screenShake", "hud",
  "paletteFlash", "showWeapon", "startingLoadout", "weaponSwitchOnPickup",
  "partyKillConfirmation", "npcRespawnTimer", "partyKilling",
  "infiniteAmmo", "infiniteHealth", "logging",
}

-- one-line helper: fills in any of the keys above still nil on `opts`
local function backfillMissingKeys(opts)
  for _, key in ipairs(BACKFILL_KEYS) do
    if opts[key] == nil then opts[key] = DEFAULTS[key] end
  end
end

function Options.get(gameArg)
  local Game = gameArg or require("src.core.Game")
  if not Game.save then return defaultsCopy() end
  Game.save.options.pokedoom = Game.save.options.pokedoom or {
    enabled = DEFAULTS.enabled,
    messages = DEFAULTS.messages,
    tightLedges = DEFAULTS.tightLedges,
  }
  -- `messages`/`tightLedges` didn't exist before Phase 16/18 -- a save
  -- written by an earlier build of this mod has `enabled` but not
  -- these keys at all, which Lua's own `and`/`or` would otherwise read
  -- as "off" (nil is falsy) instead of the real default -- explicit
  -- nil-check backfill, not just relying on the table constructor above
  -- (which only runs the FIRST time `save.options.pokedoom` is ever
  -- created).
  local opts = Game.save.options.pokedoom
  backfillMissingKeys(opts)
  return opts
end

function Options.enabled(gameArg)
  return Options.get(gameArg).enabled and true or false
end

function Options.messagesEnabled(gameArg)
  return Options.get(gameArg).messages and true or false
end

function Options.tightLedgesEnabled(gameArg)
  return Options.get(gameArg).tightLedges and true or false
end

function Options.loggingEnabled(gameArg)
  return Options.get(gameArg).logging and true or false
end

function Options.demonsEnabled(gameArg)
  return Options.get(gameArg).demons and true or false
end

-- User request (2026-08-06): "a toggle to switch from pokemon npcs as
-- enemies or demons as enemies" for regular mode's own ambient hostile
-- system. "demons" (default): the existing real-DOOM-demon behavior
-- (ambient roaming demons). "pokemon": ambient hostiles are existing
-- citizen NPCs turned hostile in place instead of DOOM demons (`lib/
-- DoomDemons.lua`'s own "possessed citizen" system).
--
-- REMOVED 2026-08-10 -- this option also used to control Horde Mode's
-- own separate DOOM-demon reskin ("both," per the user's own 2026-08-06
-- answer) before that whole tie-in was removed -- see
-- docs/horde-reincorporation.md. Single-purpose again now.
function Options.enemyType(gameArg)
  return Options.get(gameArg).enemyType or DEFAULTS.enemyType
end

-- User request (2026-08-10): "add new setting 'enemy drops' where you
-- can choose money, ammo... or money and ammo." Real values: "money"
-- (default), "ammo", "both" -- see `lib/DoomDemons.lua`'s own
-- `grantKillReward` for what this actually gates.
function Options.enemyDrops(gameArg)
  return Options.get(gameArg).enemyDrops or DEFAULTS.enemyDrops
end

-- Raw stored value: "npcs" / "pokemon" / "all" / "none". Consumers
-- outside this file should generally prefer the two boolean accessors
-- below rather than comparing this string directly -- kept exported
-- anyway to display the current setting (see the row's own `value` fn).
function Options.pokemonGore(gameArg)
  return Options.get(gameArg).pokemonGore or DEFAULTS.pokemonGore
end

-- Truth table (corrected 2026-08-10, per the user's own precise
-- clarification -- see `DEFAULTS.pokemonGore`'s comment above for the
-- full derivation): each stored value names what's ALLOWED, so a
-- category is BLOCKED whenever the OTHER category is the one exclusively
-- allowed, or neither is allowed.
--   none    -> npcs blocked, pokemon blocked
--   npcs    -> npcs killable, pokemon blocked
--   pokemon -> npcs blocked, pokemon killable
--   all     -> npcs killable, pokemon killable
function Options.npcKillsBlocked(gameArg)
  local v = Options.pokemonGore(gameArg)
  return v == "none" or v == "pokemon"
end

function Options.pokemonKillsBlocked(gameArg)
  local v = Options.pokemonGore(gameArg)
  return v == "none" or v == "npcs"
end

function Options.camera(gameArg)
  return Options.get(gameArg).camera or DEFAULTS.camera
end

function Options.freelookEnabled(gameArg)
  return Options.camera(gameArg) == "freelook"
end

-- Raw value: "easy" / "normal" / "hard" / "nightmare". Gates
-- `lib/DoomDemons.lua`'s own `DIFFICULTY_SCALE`/`difficultyScale`.
function Options.demonDifficulty(gameArg)
  return Options.get(gameArg).demonDifficulty or DEFAULTS.demonDifficulty
end

-- Raw value: "low" / "normal" / "high". Gates `lib/DoomDemons.lua`'s own
-- `DENSITY_SCALE`/`currentMaxAmbientDemons`.
function Options.demonDensity(gameArg)
  return Options.get(gameArg).demonDensity or DEFAULTS.demonDensity
end

function Options.townInvasionsEnabled(gameArg)
  return Options.get(gameArg).townInvasions and true or false
end

-- Raw value: "rare" / "normal" / "frequent". Gates `lib/
-- DoomTownInvasion.lua`'s own `FREQUENCY_SCALE`/`frequencyScale`.
function Options.invasionFrequency(gameArg)
  return Options.get(gameArg).invasionFrequency or DEFAULTS.invasionFrequency
end

function Options.viewBobEnabled(gameArg)
  return Options.get(gameArg).viewBob and true or false
end

function Options.screenShakeEnabled(gameArg)
  return Options.get(gameArg).screenShake and true or false
end

function Options.hudEnabled(gameArg)
  return Options.get(gameArg).hud and true or false
end

function Options.paletteFlashEnabled(gameArg)
  return Options.get(gameArg).paletteFlash and true or false
end

function Options.showWeaponEnabled(gameArg)
  return Options.get(gameArg).showWeapon and true or false
end

-- Raw value: "pistol" / "all". Gates `lib/DoomWeapons.lua`'s own
-- `loadWeaponSave`'s fresh-save branch.
function Options.startingLoadout(gameArg)
  return Options.get(gameArg).startingLoadout or DEFAULTS.startingLoadout
end

function Options.weaponSwitchOnPickupEnabled(gameArg)
  return Options.get(gameArg).weaponSwitchOnPickup and true or false
end

function Options.partyKillConfirmationEnabled(gameArg)
  return Options.get(gameArg).partyKillConfirmation and true or false
end

-- OFF means the player's own real party-member followers are never
-- even valid hit-targets at all -- see `lib/DoomKill.lua`'s own
-- `isPartyNpc`/`npcKillBlocked` for the actual gate.
function Options.partyKillingEnabled(gameArg)
  return Options.get(gameArg).partyKilling and true or false
end

-- Raw value: "off" / "5min" / "10min" / "30min". Gates `lib/DoomKill.lua`'s
-- own automatic respawn-timer tick. `Options.npcRespawnSeconds` below
-- converts to the real countdown duration that tick actually uses.
function Options.npcRespawnTimer(gameArg)
  return Options.get(gameArg).npcRespawnTimer or DEFAULTS.npcRespawnTimer
end

local NPC_RESPAWN_SECONDS = { ["5min"] = 300, ["10min"] = 600, ["30min"] = 1800 }

-- nil means "off" -- the timer tick should not be running at all.
function Options.npcRespawnSeconds(gameArg)
  return NPC_RESPAWN_SECONDS[Options.npcRespawnTimer(gameArg)]
end

function Options.infiniteAmmoEnabled(gameArg)
  return Options.get(gameArg).infiniteAmmo and true or false
end

function Options.infiniteHealthEnabled(gameArg)
  return Options.get(gameArg).infiniteHealth and true or false
end

-- Generic "something else wants to know when RESPAWN NPCS fires" registry
-- -- `lib/DoomKill.lua` uses this to also clear its own in-memory
-- permanent-gib list, without this file requiring `DoomKill` back (which
-- would be a circular `DoomOptions -> DoomKill -> DoomOptions` load, since
-- `DoomKill` already requires this file). Same registry idiom as
-- `DoomWeapons.registerTargetResolver`.
local respawnCallbacks = {}
function Options.onRespawnNpcs(fn)
  table.insert(respawnCallbacks, fn)
end

-- How many overworld NPCs are currently marked permanently killed
-- (`Game.save.killedNpcs`, `lib/DoomKill.lua`'s own persistence table,
-- same key shape as the host's own `save.defeatedTrainers`).
local function killedCount(game)
  local Game = game or require("src.core.Game")
  local killed = Game.save and Game.save.killedNpcs
  if not killed then return 0 end
  local n = 0
  for _ in pairs(killed) do n = n + 1 end
  return n
end

-- Advances `opts[key]` to the next value in `order` (wrapping past the
-- end back to the start) -- factored out 2026-08-19 during a project-
-- wide readability audit: six separate rows below (enemy drops, gore,
-- demon difficulty/density, invasion frequency, NPC respawn timer) each
-- independently reimplemented this exact "find current index, step to
-- the next one" loop, differing only in which key/order list they used.
local function cycleValue(opts, key, order)
  local idx = 1
  for i, v in ipairs(order) do
    if v == opts[key] then idx = i break end
  end
  opts[key] = order[(idx % #order) + 1]
end

-- Extracted 2026-08-10 so the new "NPC RESPAWN TIMER" automatic tick
-- (`lib/DoomKill.lua`'s own `install`) can fire the exact same real
-- respawn sequence the manual RESPAWN NPCS row below already does,
-- rather than a second, driftable copy of it.
function Options.respawnAllNpcs(gameArg)
  local Game = gameArg or require("src.core.Game")
  if Game.save then Game.save.killedNpcs = {} end
  for _, fn in ipairs(respawnCallbacks) do pcall(fn) end
end

function Options.rows()
  return {
    {
      id = "pokedoom_enabled",
      -- RENAMED 2026-08-10, direct user request ("rename pkdoom mode to
      -- doom mode") -- display label only; `id`/internal `opts.enabled`
      -- field name kept as-is (not user-visible, no reason to touch).
      label = "DOOM MODE",
      -- LOCKED 2026-08-19, direct user request: "make sure doom mode
      -- cannot be enabled until both pk3 and wad are added." Everything
      -- this mode actually draws -- weapon/demon sprites and sounds
      -- (the WAD), the pause menu's own real BigUpper font (the pk3) --
      -- is genuinely missing or broken without both, so this locks the
      -- switch itself rather than silently letting a player turn on a
      -- half-working mode and only discover the gap later. Turning it
      -- back OFF is never blocked -- only the OFF-to-ON transition
      -- needs both assets ready. See `Options.install()` below for the
      -- matching "auto-activate once both are ready" half of this
      -- request.
      value = function(game)
        local opts = Options.get(game)
        if not opts.enabled and not assetsReady() then return "LOCKED" end
        return opts.enabled and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        if not opts.enabled and not assetsReady() then return false end
        opts.enabled = not opts.enabled
        return true
      end,
    },
    -- Real DOOM's own `showMessages` toggle (Phase 16) -- gates the
    -- pickup/reward text `lib/DoomHud.lua`/`lib/DoomFont.lua` draw,
    -- exactly like real DOOM's own options screen does, no more and no
    -- less: it does NOT gate the sound, the palette flash, or
    -- `bonuscount` (confirmed from `HU_Ticker`'s own real scope, which
    -- only ever touches the message widget itself).
    {
      id = "pokedoom_messages",
      label = "MESSAGES",
      value = function(game)
        return Options.messagesEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.messages = not opts.messages
        return true
      end,
    },
    -- Clears the persisted "this NPC is dead" flags AND every registered
    -- callback's own state (`lib/DoomKill.lua`'s permanent gib list, via
    -- `Options.onRespawnNpcs`, since gibs otherwise now stay forever --
    -- this is their only clear point). Phase 18 Bug 3: `DoomKill.lua`'s
    -- own respawn callback now ALSO force-rebuilds the currently loaded
    -- map's own `ow.npcs`/`ow.entities` the moment this fires (mirroring
    -- `setMap`'s own real spawn sweep), so respawned NPCs reappear
    -- instantly -- no longer needs a real map transition (leave and come
    -- back, or reload) to take visual effect, which used to be true and
    -- is documented as fixed in phases/phase-18-bug-fixes.md.
    {
      id = "pokedoom_respawn_npcs",
      label = "RESPAWN NPCS",
      value = function(game)
        local n = killedCount(game)
        return n > 0 and (tostring(n) .. " KILLED") or "NONE KILLED"
      end,
      step = function(game, dir)
        Options.respawnAllNpcs(game)
        return true
      end,
    },
    -- Phase 18 Bug 6: real Gen-1 ledge-hop behavior (inherited through
    -- the host's own free-roam collision) was triggering well before the
    -- player visually reached a ledge's edge, making some gaps feel
    -- impossible to walk through without an unwanted auto-hop. Gates
    -- `lib/DoomMove.lua`'s own `OverworldState.checkLedgeHop` wrap, which
    -- adds a real proximity check before allowing the hop.
    {
      id = "pokedoom_tight_ledges",
      label = "TIGHT LEDGES",
      value = function(game)
        return Options.tightLedgesEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.tightLedges = not opts.tightLedges
        return true
      end,
    },
    -- FEATURE 2026-08-11 -- direct user request: "add option in
    -- settings to turn logging on (off by default)." Gates `lib/
    -- DoomLog.lua`'s own persistent per-session log file -- console
    -- output (`print`) is unaffected either way; this only controls
    -- whether a real file gets created and written to disk.
    {
      id = "pokedoom_logging",
      label = "LOGGING",
      -- SIMPLIFIED 2026-08-19, direct user report: this used to show the
      -- real, current `DoomLog.status()` string once actually on (a
      -- resolved file path, or the exact failure reason) -- but
      -- `DoomLog.lua`'s own `lastStatus` can genuinely still read "off"
      -- for a moment right after the toggle flips on (it only updates
      -- the next time something actually tries to log), which rendered
      -- as the confusing "ON (off)" the user reported. Per their own
      -- direct request ("it should just be off and on"), this row is
      -- now a plain toggle display -- `DoomLog.status()` is still
      -- reachable directly (console, or a future diagnostics row) for
      -- anyone actually debugging a broken logger.
      value = function(game)
        return Options.loggingEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.logging = not opts.logging
        return true
      end,
    },
    -- Phase 21: a genuine master ON/OFF switch (2026-08-06, "there
    -- should be a toggle enemies off or on") for regular mode's own
    -- ambient hostile system (roaming DOOM demons, or possessed citizen
    -- NPCs -- see the ENEMY TYPE row right below) -- OFF means none
    -- exist at all, full stop. Default OFF.
    {
      id = "pokedoom_demons",
      label = "ENEMIES",
      value = function(game)
        return Options.demonsEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.demons = not opts.demons
        return true
      end,
    },
    -- User request (2026-08-06): "a toggle to switch from pokemon npcs
    -- as enemies or demons as enemies" -- see `Options.enemyType`'s own
    -- header comment for exactly what this controls in each mode.
    {
      id = "pokedoom_enemy_type",
      label = "ENEMY TYPE",
      value = function(game)
        return Options.enemyType(game) == "pokemon" and "POKEMON" or "DEMONS"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.enemyType = (opts.enemyType == "pokemon") and "demons" or "pokemon"
        return true
      end,
    },
    -- User request (2026-08-10): "add new setting 'enemy drops' where
    -- you can choose money, ammo (will give you ammo in any random gun
    -- or money and ammo." Gates `lib/DoomDemons.lua`'s own kill-reward
    -- choke point (`startDeath`, via `grantKillReward`) -- MONEY
    -- (default, preserves this mod's own prior unconditional-money-
    -- on-kill behavior exactly, so nobody who never touches this row
    -- sees any change) / AMMO (a random real ammo type -- `clip`/
    -- `shell`/`misl`/`cell` -- DOOM has no per-kill ammo-drop precedent
    -- of its own, same "this mod's own addition" category as the
    -- currency-per-kill feature itself) / BOTH. Three-way cycle, same
    -- `step`-through-an-ordered-list shape every other >2-value row in
    -- this project would use if one existed yet -- this is the first.
    {
      id = "pokedoom_enemy_drops",
      label = "ENEMY DROPS",
      value = function(game)
        local d = Options.enemyDrops(game)
        if d == "ammo" then return "AMMO" end
        if d == "both" then return "BOTH" end
        return "MONEY"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "enemyDrops", { "money", "ammo", "both" })
        return true
      end,
    },
    -- User request (2026-08-10): "add an option for 'pokemon gore'...
    -- 4 settings 'NPCs, Pokemon, All, None' which will disable killing
    -- either pokemon npcs, pokemon, all of them, or not be able to kill
    -- anything other than doom demons." Each value names what's ALLOWED
    -- to be killed (corrected same day -- see this file's own
    -- `DEFAULTS.pokemonGore` comment above for the full derivation),
    -- "NPCs" (default, 2026-08-12) allowing human NPCs only, Pokemon
    -- protected. Four-way cycle, same step-through-an-ordered-list
    -- shape ENEMY DROPS above already established for a >2-value row.
    {
      id = "pokedoom_pokemon_gore",
      label = "POKEMON GORE",
      value = function(game)
        local v = Options.pokemonGore(game)
        if v == "npcs" then return "NPCS" end
        if v == "pokemon" then return "POKEMON" end
        if v == "all" then return "ALL" end
        return "NONE"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "pokemonGore", { "npcs", "pokemon", "all", "none" })
        return true
      end,
    },
    -- User request (2026-08-10): "add an option to settings for camera
    -- and options will be 'locked, freelook' and freelook should
    -- actually let you freelook instead of being locked on the y axis."
    -- "LOCKED" (default) is this mod's own original, deliberate design
    -- (see `DEFAULTS.camera`'s own comment above) -- "FREELOOK" gates
    -- `lib/DoomView.lua`'s own `lockPitch`, letting vertical look
    -- input (already tracked live by the host's own `FirstPerson.pitch`
    -- the whole time, just force-reset to 0 every frame until now)
    -- actually move the camera. Two-way cycle, same shape ENEMY TYPE
    -- above already uses for a 2-value row.
    {
      id = "pokedoom_camera",
      label = "CAMERA",
      value = function(game)
        return Options.freelookEnabled(game) and "FREELOOK" or "LOCKED"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.camera = (opts.camera == "freelook") and "locked" or "freelook"
        return true
      end,
    },
    -- User request (2026-08-10, the 13-row batch -- see DEFAULTS' own
    -- header comment above). Scales demon HP/damage/speed
    -- (`lib/DoomDemons.lua`'s own `DIFFICULTY_SCALE`).
    {
      id = "pokedoom_demon_difficulty",
      label = "DEMON DIFFICULTY",
      value = function(game)
        local v = Options.demonDifficulty(game)
        if v == "easy" then return "EASY" end
        if v == "hard" then return "HARD" end
        if v == "nightmare" then return "NIGHTMARE" end
        return "NORMAL"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "demonDifficulty", { "easy", "normal", "hard", "nightmare" })
        return true
      end,
    },
    -- Scales the ambient roaming demon population cap
    -- (`lib/DoomDemons.lua`'s own `DENSITY_SCALE`).
    {
      id = "pokedoom_demon_density",
      label = "DEMON DENSITY",
      value = function(game)
        local v = Options.demonDensity(game)
        if v == "low" then return "LOW" end
        if v == "high" then return "HIGH" end
        return "NORMAL"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "demonDensity", { "low", "normal", "high" })
        return true
      end,
    },
    -- Gates only the AMBIENT/random invasion trigger
    -- (`lib/DoomTownInvasion.lua`'s own `tick`) -- the debug START
    -- INVASION row stays usable either way, matching this project's own
    -- debug-tool-vs-feature-toggle precedent (SPAWN ENEMY vs. DEMONS).
    {
      id = "pokedoom_town_invasions",
      label = "TOWN INVASIONS",
      value = function(game)
        return Options.townInvasionsEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.townInvasions = not opts.townInvasions
        return true
      end,
    },
    -- Scales the cooldown between invasions
    -- (`lib/DoomTownInvasion.lua`'s own `FREQUENCY_SCALE`).
    {
      id = "pokedoom_invasion_frequency",
      label = "INVASION FREQUENCY",
      value = function(game)
        local v = Options.invasionFrequency(game)
        if v == "rare" then return "RARE" end
        if v == "frequent" then return "FREQUENT" end
        return "NORMAL"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "invasionFrequency", { "rare", "normal", "frequent" })
        return true
      end,
    },
    -- Some players get motion sick from head bob -- gates
    -- `lib/DoomView.lua`'s own `bobOffset`.
    {
      id = "pokedoom_view_bob",
      label = "VIEW BOB",
      value = function(game)
        return Options.viewBobEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.viewBob = not opts.viewBob
        return true
      end,
    },
    -- This mod's own addition (real DOOM has no free 3D camera to shake)
    -- -- gates `lib/DoomView.lua`'s own `triggerShake`/`shakeOffset`,
    -- triggered by explosions (`lib/DoomWeapons.lua`) and taking damage
    -- (`lib/DoomView.lua`'s own `checkDamageShake`).
    {
      id = "pokedoom_screen_shake",
      label = "SCREEN SHAKE",
      value = function(game)
        return Options.screenShakeEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.screenShake = not opts.screenShake
        return true
      end,
    },
    -- Gates `lib/DoomHud.lua`'s own status-bar draw only -- the
    -- flat-2D-fallback safety gate (`visible()`) is untouched.
    {
      id = "pokedoom_hud",
      label = "HUD",
      value = function(game)
        return Options.hudEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.hud = not opts.hud
        return true
      end,
    },
    -- Gates `lib/DoomHud.lua`'s own `drawPaletteFlash` (the red damage/
    -- gold pickup screen tint) -- separate from HUD above, for players
    -- sensitive to screen flashing specifically.
    {
      id = "pokedoom_palette_flash",
      label = "PALETTE FLASH",
      value = function(game)
        return Options.paletteFlashEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.paletteFlash = not opts.paletteFlash
        return true
      end,
    },
    -- Gates `lib/DoomWeapons.lua`'s own view model draw only -- firing/
    -- input logic is unaffected, only the gun's own visibility.
    {
      id = "pokedoom_show_weapon",
      label = "SHOW WEAPON",
      value = function(game)
        return Options.showWeaponEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.showWeapon = not opts.showWeapon
        return true
      end,
    },
    -- PISTOL ONLY (default, the real `G_PlayerReborn` values) / ALL
    -- WEAPONS (every weapon owned, full ammo, for skipping the pickup
    -- grind) -- gates `lib/DoomWeapons.lua`'s own `loadWeaponSave`.
    {
      id = "pokedoom_starting_loadout",
      label = "STARTING LOADOUT",
      value = function(game)
        return Options.startingLoadout(game) == "all" and "ALL WEAPONS" or "PISTOL ONLY"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.startingLoadout = (opts.startingLoadout == "all") and "pistol" or "all"
        return true
      end,
    },
    -- Default ON -- preserves the real DOOM `P_GiveWeapon` auto-switch
    -- exactly. Gates `lib/DoomWeapons.lua`'s own `giveWeapon`.
    {
      id = "pokedoom_weapon_switch_on_pickup",
      label = "WEAPON SWITCH ON PICKUP",
      value = function(game)
        return Options.weaponSwitchOnPickupEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.weaponSwitchOnPickup = not opts.weaponSwitchOnPickup
        return true
      end,
    },
    -- Default ON, per the user's own explicit request (every other row
    -- in this 13-row batch defaults to "preserve prior behavior" --
    -- this is the one deliberate exception). Gates `lib/DoomKill.lua`'s
    -- own `checkPartyKillConfirm` -- see that function's own header
    -- comment for the full "shoot twice within a window" design.
    {
      id = "pokedoom_party_kill_confirmation",
      label = "PARTY KILL CONFIRMATION",
      value = function(game)
        return Options.partyKillConfirmationEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.partyKillConfirmation = not opts.partyKillConfirmation
        return true
      end,
    },
    -- User request (2026-08-10): "add setting to doom settings: Party
    -- Killing (so you can disable being able to kill your party at
    -- all, so the bullets will just fly through them to whatever
    -- target is past them." OFF filters the player's own real
    -- following party Pokemon OUT of hit-candidate selection entirely
    -- (`lib/DoomKill.lua`'s own `isPartyNpc`/`npcKillBlocked`, the same
    -- "not a valid target at all" mechanism POKEMON GORE already uses
    -- above) -- a shot simply passes through to whatever's behind them,
    -- exactly like it would if they weren't there. Default ON,
    -- preserving this mod's own existing behavior for anyone who never
    -- touches this row.
    {
      id = "pokedoom_party_killing",
      label = "PARTY KILLING",
      value = function(game)
        return Options.partyKillingEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.partyKilling = not opts.partyKilling
        return true
      end,
    },
    -- OFF (default) / 5 MIN / 10 MIN / 30 MIN -- an automatic version of
    -- the manual RESPAWN NPCS row above, on a real countdown. Gates
    -- `lib/DoomKill.lua`'s own automatic timer tick
    -- (`Options.npcRespawnSeconds`).
    {
      id = "pokedoom_npc_respawn_timer",
      label = "NPC RESPAWN TIMER",
      value = function(game)
        local v = Options.npcRespawnTimer(game)
        if v == "5min" then return "5 MIN" end
        if v == "10min" then return "10 MIN" end
        if v == "30min" then return "30 MIN" end
        return "OFF"
      end,
      step = function(game, dir)
        cycleValue(Options.get(game), "npcRespawnTimer", { "off", "5min", "10min", "30min" })
        return true
      end,
    },
    -- User request (2026-08-07): "add a setting to give player infinite
    -- ammo." Gates every real ammo-decrement site in
    -- `lib/DoomWeapons.lua` (pistol/shotgun/chaingun/rocket/plasma/BFG),
    -- not a one-time refill -- ammo simply never drops while ON.
    {
      id = "pokedoom_infinite_ammo",
      label = "INFINITE AMMO",
      value = function(game)
        return Options.infiniteAmmoEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.infiniteAmmo = not opts.infiniteAmmo
        return true
      end,
    },
    -- User request (2026-08-07): "a infinite health setting too." Reuses
    -- `lib/DoomHealth.lua`'s own `DoomHealth.damage()` `opts.godmode`
    -- seam (left open by `phases/phase-14-god-mode.md`, the real
    -- `IDDQD` phase, not yet built) rather than a second immunity check.
    -- NOTE for the user: as of this build nothing yet deals real damage
    -- to the player outside the `pokedoom_hurt` dev command (no demon/
    -- NPC attack is wired to `DoomHealth.damage()` yet), so this won't
    -- show a visible difference in a normal fight until that lands --
    -- it's wired and ready for when it does.
    {
      id = "pokedoom_infinite_health",
      label = "INFINITE HEALTH",
      value = function(game)
        return Options.infiniteHealthEnabled(game) and "ON" or "OFF"
      end,
      step = function(game, dir)
        local opts = Options.get(game)
        opts.infiniteHealth = not opts.infiniteHealth
        return true
      end,
    },
  }
end

-- FEATURE 2026-08-19 -- see the DOOM MODE row's own header comment
-- above for the full request. Fires at most ONCE per save, guarded by
-- `opts.autoActivatedOnce` (persisted right alongside `opts.enabled`
-- itself, so it survives across sessions) -- once it has fired, DOOM
-- MODE goes back to being a normal, freely user-controlled toggle even
-- if the player turns it back off afterward, matching how every other
-- toggle in this project works ("off means off," never re-forced). A
-- fresh/legacy save with no `autoActivatedOnce` key at all reads as
-- "not yet fired" via a plain nil-check -- correct for a genuinely new
-- save AND for a save written before this feature existed.
--
-- Both import files' own `install()` restore their `status.state` to
-- "ready" from disk (`checkExistingExtraction`) as early as their own
-- first real `input.step` tick if the player already imported them in
-- an earlier session -- this hook runs every tick right alongside
-- those, so it always observes their up-to-date state, at worst one
-- tick (1/60s) behind, never meaningfully stale.
local installed = false
function Options.install()
  if installed then return end
  installed = true
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, opts = pcall(Options.get, game)
    if ok and opts and not opts.enabled and not opts.autoActivatedOnce and assetsReady() then
      opts.enabled = true
      opts.autoActivatedOnce = true
      local log = getDoomLog()
      if log then
        pcall(log.event, "OPTIONS", "DOOM MODE auto-activated -- WAD + BigUpper pk3 both ready")
      end
    end
    return next(game, dt)
  end)
end

return Options
