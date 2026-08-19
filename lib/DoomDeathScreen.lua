-- PokeDoom: a full-screen "YOU LOST" death treatment. Direct user
-- request, 2026-08-11: "i want killing any essential NPC will show a
-- red overlay on the screen, and on top of that, text that says 'YOU
-- LOST' and smaller subtext under that saying the reason you lost,
-- which will dynamically change based on what you do. for example if
-- you kill oak, the subtext will say 'You can't kill Professor Oak' and
-- play a gunshot and doom monster dying sound effect." Generalized once
-- the design was already underway: "i want the same screen to be the
-- death screen now, and say as the subtext dynamically changing text
-- that has the name of the enemy, or thing that killed you where xxx
-- will be replaced with the name," with a literal 7-line taunt list to
-- pick from.
--
-- This mod's own addition, no real DOOM precedent -- real single-player
-- DOOM has no "YOU LOST"/taunt screen at all; death is a silent level
-- reload (see `lib/DoomView.lua`'s own Phase 15 notes, and its own
-- `announceDeath`/`OBITUARIES`, the direct ancestor of this feature's
-- killer-identification logic, restated rather than shared below since
-- that function feeds a small killfeed LINE while this one feeds a
-- full-screen overlay with a different, taunt-shaped text list).
--
-- Reuses `lib/DoomHealth.lua`'s existing real death/respawn machinery
-- wholesale for the essential-NPC case rather than inventing a second
-- one: killing an essential NPC calls `DoomHealth.damage(1000, {...})`
-- -- the same real ">=1000 always-lethal, bypasses invincibility"
-- threshold that file's own header comment already cites from
-- `p_inter.c:847-852` -- so `DoomHealth.isDead()`/`tryRespawn`'s own
-- USE-to-respawn flow (`lib/DoomView.lua`) apply completely unchanged;
-- this file only owns the NEW visual/audio treatment and the killer-
-- name resolution feeding its subtext.

local V = ...
local Host = V.host
local DoomHealth = V.require("DoomHealth")
local DoomFont = V.require("DoomFont")
local DoomWadImport = V.require("DoomWadImport")
local Options = V.require("DoomOptions")
local FirstPerson = Host.require("FirstPerson")

local DoomDeathScreen = {}

-- Lazy require, NOT a top-level one -- `lib/DoomView.lua` itself
-- requires this file (to gate `tryRespawn` on `canRespawn()`), so a
-- top-level `V.require("DoomView")` here would be a real require cycle.
-- By the time `loadSave()` below actually runs, both modules are
-- already fully loaded -- the same lazy-require idiom this codebase
-- already uses for the identical reason (`lib/DoomWeapons.lua`'s own
-- `getDoomDemons()`, `lib/DoomBarrels.lua`'s own `getDoomWeapons()`).
local DoomView
local function getDoomView()
  DoomView = DoomView or V.require("DoomView")
  return DoomView
end

-- ------- essential NPCs -- a deliberately curated, extensible set of
-- major, one-of-a-kind story characters (not shop/service NPCs -- a
-- separate, not-yet-built idea, see phases/phase-8-kill-mechanic.md's
-- own audit notes). Real trainerClass ids confirmed by reading
-- `gen1recomp-dev/data/generated/trainers.lua` directly, not guessed:
-- every real gym leader, the Elite Four, Giovanni, and all three Rival
-- battle stages. Professor Oak has no trainerClass at all (he never
-- battles the player anywhere in real Gen 1) -- identified instead by
-- his own real, consistent map-object sprite id, confirmed by reading
-- `gen1recomp-dev/data/generated/maps.lua` directly: every one of his
-- real appearances (Pallet Town, Oak's Lab x2, the Champion's Room, the
-- Hall of Fame) uses `sprite = "SPRITE_OAK"`.
local ESSENTIAL_TRAINER_CLASSES = {
  OPP_BROCK = "BROCK", OPP_MISTY = "MISTY", OPP_LT_SURGE = "LT. SURGE",
  OPP_ERIKA = "ERIKA", OPP_KOGA = "KOGA", OPP_SABRINA = "SABRINA",
  OPP_BLAINE = "BLAINE", OPP_GIOVANNI = "GIOVANNI",
  OPP_LORELEI = "LORELEI", OPP_BRUNO = "BRUNO", OPP_AGATHA = "AGATHA",
  OPP_LANCE = "LANCE",
  OPP_RIVAL1 = "YOUR RIVAL", OPP_RIVAL2 = "YOUR RIVAL", OPP_RIVAL3 = "YOUR RIVAL",
}

-- Returns a display name if `npc` is one of the essential characters
-- above, else nil. Exported so `lib/DoomKill.lua` can decide whether a
-- particular kill should force the death screen at all.
function DoomDeathScreen.essentialNpcName(npc)
  if not (npc and npc.def) then return nil end
  if npc.def.sprite == "SPRITE_OAK" then return "PROFESSOR OAK" end
  if npc.def.trainerClass then
    return ESSENTIAL_TRAINER_CLASSES[npc.def.trainerClass]
  end
  return nil
end

-- ------- killer display name -- feeds the taunt subtext below.
-- Restates (doesn't share) `lib/DoomView.lua`'s own `announceDeath`
-- identification logic for a demon attacker (`attacker.name`, the real
-- roster key, e.g. "ZOMBIEMAN" -- already matches DOOM's real hu_font's
-- own uppercase-only rendering, no title-casing needed), extended here
-- for an essential NPC (via `essentialNpcName` above) and a barrel
-- (`lib/DoomBarrels.lua`'s own splash damage passes either a live
-- barrel table or nothing at all as `attacker`, never a `.name`/`.def`
-- -- distinguished from a demon/NPC purely by having NEITHER, since a
-- barrel entity carries no separate type marker to check directly).
local function killerDisplayName(attacker)
  if type(attacker) ~= "table" then
    return "SOMETHING"
  end
  local essential = DoomDeathScreen.essentialNpcName(attacker)
  if essential then return essential end
  if attacker.name then return attacker.name end -- demon roster key
  if attacker.def then
    if attacker.def.trainerClass then
      return (attacker.def.trainerClass:gsub("^OPP_", ""))
    end
    return "A TRAINER"
  end
  if attacker.state and attacker.hp ~= nil then return "A BARREL" end
  return "SOMETHING"
end

-- ------- taunt subtext -- literal, user-specified list, `%s` standing
-- in for "xxx".
local TAUNTS = {
  "A %s killed you",
  "A %s totally bashed you",
  "A %s kinda didn't like you",
  "A %s? Dude you suck",
  "A %s gave you a rash",
  "A %s gave you carpet burn",
  "A %s gave you a wet willy",
}

-- ------- lives -- direct user request, 2026-08-11: "dying should have
-- 3 lives, where you can respawn, after that, you should not be able to
-- respawn and it will give you an option to load a save or quit."
-- Persisted on the save file (`Game.save.pokedoomLives`), the same
-- "a flat field on `Game.save`, seeded on `save.created`, defaulted on
-- `save.loaded` for an older save that predates this field" shape every
-- other per-save PokeDoom counter in this codebase already uses (`lib/
-- DoomBarrels.lua`'s own `save.doomBarrels`, `lib/DoomItems.lua`'s own
-- `save.pokedoomWeapons`) -- loading an EARLIER save genuinely restores
-- however many lives were left at that point, not a blanket reset,
-- matching how every other piece of this mod's own persisted state
-- already behaves.
local DEFAULT_LIVES = 3
local function currentLives()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save) then return DEFAULT_LIVES end
  if Game.save.pokedoomLives == nil then Game.save.pokedoomLives = DEFAULT_LIVES end
  return Game.save.pokedoomLives
end
local function consumeLife()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game.save) then return end
  Game.save.pokedoomLives = math.max(0, currentLives() - 1)
end

-- ------- one-time-per-death state: rolled/resolved exactly once on the
-- alive->dead edge (matching `lib/DoomView.lua`'s own `announceDeath`
-- edge-detection idiom, restated here rather than shared since this
-- file owns a wholly separate concern), never re-rolled every frame
-- while the screen is showing -- otherwise the subtext would visibly
-- flicker between different taunts each frame.
local active = false
local subtext = nil
local respawnAllowed = false
local selectedOption = 1 -- 1 = LOAD A SAVE, 2 = QUIT -- only used while respawnAllowed is false

-- FIX 2026-08-11 -- user report + screenshot: an essential-NPC kill
-- (Professor Oak) showed a random taunt ("...KINDA DIDN'T LIKE YOU")
-- instead of the specific "You can't kill Professor Oak" message from
-- the ORIGINAL request this whole feature started from -- the taunt
-- list was always meant for an ordinary death (killed BY something),
-- not for the essential-NPC-punishment case, which needs its own fixed
-- wording naming who was killed, not who did the killing. Distinguished
-- here by reusing `essentialNpcName` against the attacker itself: the
-- ONLY path that ever sets `DoomHealth`'s own attacker to an essential
-- NPC's own table is `punishEssentialKill` below, so if that check
-- matches, this death is unambiguously an essential-kill punishment,
-- not a real DOOM-style death by something else.
--
-- Same distinction decides `respawnAllowed`: an essential-NPC kill NEVER
-- allows a respawn at all (the user's own words: "not be able to
-- respawn" -- unconditional, no lives check). An ordinary death only
-- allows it while a life remains -- checked and CONSUMED here, once,
-- the instant death happens, so the screen's own "can I respawn" state
-- is fully settled before it's ever drawn or read by `lib/DoomView.lua`'s
-- own `tryRespawn`.
local function beginDeathScreen()
  local attacker = DoomHealth.attacker()
  local essential = DoomDeathScreen.essentialNpcName(attacker)
  selectedOption = 1
  if essential then
    subtext = "YOU CAN'T KILL " .. essential
    respawnAllowed = false
  else
    local name = killerDisplayName(attacker)
    local taunt = TAUNTS[math.random(#TAUNTS)]
    subtext = taunt:format(name)
    if currentLives() > 0 then
      consumeLife()
      respawnAllowed = true
    else
      respawnAllowed = false
    end
  end

  local ok1, gunshot = pcall(DoomWadImport.loadSound, "DSPISTOL")
  if ok1 and gunshot then DoomWadImport.playClone("DSPISTOL (death screen)", gunshot) end
  -- DSPODTH1 -- Zombieman's own real death scream (`info.c`), already
  -- used/proven elsewhere in this mod -- reused rather than a fresh
  -- guess, per CLAUDE.md's own "default to reusing an already-proven
  -- reference" visual/audio-parameter guidance.
  local ok2, scream = pcall(DoomWadImport.loadSound, "DSPODTH1")
  if ok2 and scream then DoomWadImport.playClone("DSPODTH1 (death screen)", scream) end
end

-- Read by `lib/DoomView.lua`'s own `tryRespawn` as an extra gate before
-- honoring a USE press -- the single source of truth for whether THIS
-- death is respawnable, resolved once above rather than re-derived here.
function DoomDeathScreen.canRespawn()
  return respawnAllowed
end

-- ------- forcing a real death for an essential-NPC kill. Called by
-- `lib/DoomKill.lua` from its own PLAYER-caused kill call sites only
-- (`overworldNpcResolver`/`overworldNpcAoeResolver`) -- deliberately
-- NOT from the shared `kill()` function itself, which a roaming demon's
-- own citizen-hunting AI (`lib/DoomDemons.lua`) also calls through
-- `DoomKill.killNpc`: a demon killing an essential NPC on its own is
-- not something the PLAYER did, so it shouldn't punish the player.
function DoomDeathScreen.punishEssentialKill(npc)
  local name = DoomDeathScreen.essentialNpcName(npc)
  if not name then return end
  if not DoomHealth.isAlive() then return end -- already dead, nothing to force
  pcall(DoomHealth.damage, 1000, { attacker = npc, source = "essential_npc" })
end

-- ------- the draw, two halves for the same reason `lib/DoomHud.lua`'s
-- own `drawPaletteFlash` is: a full-bleed color rect needs RAW screen
-- pixels to cover the true window regardless of letterboxing (see that
-- function's own header comment for the exact bug this avoids), while
-- the text needs the shared 320x200 virtual-canvas transform `DoomFont`
-- itself is built around. `lib/DoomHud.lua`'s own `install()` calls
-- these two functions itself, at the right point inside its own
-- existing transform -- this file installs no `love.draw` of its own.
--
-- HEADER_SCALE/SUBTEXT_SCALE/RED_ALPHA are visual-rendering judgment
-- calls, not derivable DOOM facts (CLAUDE.md's own "Nature of the
-- port" section -- this whole screen is a mod-original addition with
-- no real DOOM reference to match anyway); easy to retune here if they
-- read too big/small/dark in play.
local RED_ALPHA = 0.78
function DoomDeathScreen.drawOverlayBackground()
  if not (Options.enabled() and DoomHealth.isDead() and FirstPerson.onTop()) then return end
  local w, h = love.graphics.getWidth(), love.graphics.getHeight()
  love.graphics.setColor(0.5, 0, 0, RED_ALPHA)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

local HEADER_SCALE, SUBTEXT_SCALE = 4, 1.2
local VIRTUAL_W = 320 -- matches lib/DoomFont.lua's/DoomHud.lua's own established virtual canvas
-- FIX 2026-08-11 -- user report + screenshot: the subtext ran off both
-- edges of the screen ("...ROFESSOR OAK KINDA DIDN'T LIKE...", missing
-- its own leading "P" and trailing "YOU") -- `DoomFont.draw` only ever
-- CLIPS at `VIRTUAL_W` (`lib/DoomFont.lua`'s own real `HUlib_
-- drawTextLine` port, which real DOOM's own single-line HUD text never
-- needed to wrap either), it never wraps, and centering a string wider
-- than the whole 320-unit virtual canvas around its own midpoint pushes
-- the START x negative, clipping the LEFT edge too. A taunt with a long
-- substituted name (a full trainer name, "PROFESSOR OAK") routinely
-- exceeds 320 units at any real reading size. `wrapSubtext` below is a
-- small, self-contained greedy word-wrap (accumulate words while they
-- still fit `DoomFont.measure` against a real max width, break to a new
-- line otherwise) -- `DoomFont` itself has no wrapping of its own to
-- extend, so this is new, minimal, mod-original code, not a DOOM port.
local SUBTEXT_MARGIN = 12 -- virtual px kept clear on each side
local SUBTEXT_MAX_WIDTH = VIRTUAL_W - SUBTEXT_MARGIN * 2
local function wrapSubtext(text, scale, maxWidth)
  local lines = {}
  local current = ""
  for word in text:gmatch("%S+") do
    local candidate = (current == "") and word or (current .. " " .. word)
    if current == "" or DoomFont.measure(candidate, scale) <= maxWidth then
      current = candidate
    else
      lines[#lines + 1] = current
      current = word
    end
  end
  if current ~= "" then lines[#lines + 1] = current end
  return lines
end

-- Real hu_font glyph patches run roughly 7-8px tall at scale 1 (a
-- visual-rendering judgment call, not a derivable DOOM fact, same
-- category as HEADER_SCALE/SUBTEXT_SCALE above -- `DoomFont` exposes no
-- single "font height" of its own to read this from directly).
local SUBTEXT_LINE_HEIGHT = 9 * SUBTEXT_SCALE

-- ------- the bottom prompt -- either a respawn hint (`respawnAllowed`)
-- or, once out of lives / on an essential-NPC kill, a real two-option
-- LOAD A SAVE / QUIT choice. Direct user request: "to the dying screens
-- that let you respawn it should show text at the bottom that says
-- 'Press any key to respawn'." The actual respawn INPUT stays bound to
-- the real USE button (`lib/DoomView.lua`'s own `tryRespawn`, `Input:
-- wasPressed("a")`, which this engine's own real button mapping already
-- spreads across several physical keys, Phase 15's own note) -- "any
-- key" here is the on-screen PROMPT WORDING the user asked for, the same
-- common game convention real DOOM's own finale screens use ("press a
-- key to continue"), not a rewrite of this mod's whole input-polling
-- surface to genuinely watch every keyboard key.
local PROMPT_SCALE = 1
local PROMPT_Y = 145
local OPTION_GAP = 12

local function drawRespawnPrompt()
  local text = "PRESS ANY KEY TO RESPAWN"
  local w = DoomFont.measure(text, PROMPT_SCALE)
  DoomFont.draw(text, (VIRTUAL_W - w) / 2, PROMPT_Y, 0.9, 0.9, 0.9, 1, PROMPT_SCALE)
end

-- FIX 2026-08-11 -- user report: "the actual highlighted button should
-- be the darker text instead of the lighter text like it is now" --
-- swapped: the selected option now draws darker, the unselected one
-- lighter (the reverse of the first version's bright-yellow-selected/
-- dim-gray-unselected treatment).
local function drawGameOverOptions()
  local options = { "LOAD A SAVE", "QUIT" }
  for i, label in ipairs(options) do
    local w = DoomFont.measure(label, PROMPT_SCALE)
    local y = PROMPT_Y + (i - 1) * OPTION_GAP
    -- FIX 2026-08-11 -- user request: "swap the colors of the selected
    -- items in you lost screen" -- swapped back to bright-white-selected/
    -- dark-unselected (the reverse of the immediately prior round's own
    -- swap).
    if i == selectedOption then
      DoomFont.draw(label, (VIRTUAL_W - w) / 2, y, 1, 1, 1, 1, PROMPT_SCALE)
    else
      DoomFont.draw(label, (VIRTUAL_W - w) / 2, y, 0.35, 0.3, 0.3, 1, PROMPT_SCALE)
    end
  end
end

function DoomDeathScreen.drawOverlayText()
  if not (Options.enabled() and DoomHealth.isDead() and FirstPerson.onTop()) then return end
  if not subtext then return end -- input.step hasn't rolled one yet this death (one-frame gap at worst)
  local header = "YOU LOST"
  local hw = DoomFont.measure(header, HEADER_SCALE)
  DoomFont.draw(header, (VIRTUAL_W - hw) / 2, 62, 1, 1, 1, 1, HEADER_SCALE)

  local lines = wrapSubtext(subtext, SUBTEXT_SCALE, SUBTEXT_MAX_WIDTH)
  local startY = 108 - (#lines - 1) * SUBTEXT_LINE_HEIGHT / 2
  for i, line in ipairs(lines) do
    local lw = DoomFont.measure(line, SUBTEXT_SCALE)
    DoomFont.draw(line, (VIRTUAL_W - lw) / 2, startY + (i - 1) * SUBTEXT_LINE_HEIGHT,
      1, 0.85, 0.85, 1, SUBTEXT_SCALE)
  end

  if respawnAllowed then
    pcall(drawRespawnPrompt)
  else
    pcall(drawGameOverOptions)
  end
end

-- ------- LOAD A SAVE / QUIT actions.
--
-- `Game:returnToTitle()` (`gen1recomp-dev/src/core/Game.lua:176-180`) is
-- a real, already-public method -- confirmed by reading it directly,
-- not guessed -- described in its OWN neighboring `makeTitleState`
-- comment as "used at boot and by the START-menu QUIT confirmation," and
-- called the exact same way from `src/script/Commands.lua`'s own real
-- Hall of Fame ending sequence: stop the music, pop the whole state
-- stack, push a fresh title screen. That's the real, working CONTINUE
-- flow this mod already has everywhere else -- reused outright rather
-- than building a second save-slot picker from scratch, since the
-- player lands on the exact same title screen a real "load a save"
-- action already means in this game.
-- FIX 2026-08-11 -- user report: pressing CONTINUE on the title screen
-- after choosing LOAD A SAVE "just goes back to the main menu" instead
-- of actually loading anything. Root cause: `Game:returnToTitle()` pops
-- the whole stack and replaces it with a fresh title screen, but does
-- NOT touch `lib/DoomHealth.lua`'s own `playerstate` at all -- that's a
-- pure in-memory field this file never reset, so `DoomHealth.isDead()`
-- was STILL true the instant CONTINUE's own `SaveData.load()`/
-- `restoreSave` pushed the loaded overworld back onto the stack. The
-- very next `input.step` tick, this file's own `install()` wrap saw
-- `Options.enabled() and FirstPerson.onTop() and DoomHealth.isDead()`
-- all still true (the overworld genuinely was back on top) and kept
-- drawing THIS SAME red overlay + LOAD A SAVE/QUIT choice directly over
-- the freshly-loaded game, with `handleGameOverInput` still live too --
-- so the very next "a" press (the player, seeing what still looked like
-- the title screen, pressing CONTINUE again) actually re-selected LOAD
-- A SAVE and called `returnToTitle()` a second time, wiping out the
-- just-loaded overworld and landing back at the title -- the exact
-- "continue just goes back to the main menu" loop reported. Fixed by
-- resetting BOTH this file's own local death-screen state AND
-- `DoomHealth`'s real dead flag (`DoomHealth.reborn()`, the same real
-- reset `lib/DoomView.lua`'s own `tryRespawn` already uses for an
-- ordinary respawn) before returning to the title -- nothing is left
-- claiming the player is still dead once CONTINUE actually runs.
local function loadSave()
  active = false
  subtext = nil
  respawnAllowed = false
  selectedOption = 1
  pcall(DoomHealth.reborn)
  pcall(function() getDoomView().resetDeathCamera() end)
  local ok, Game = pcall(require, "src.core.Game")
  if ok and Game.returnToTitle then
    pcall(Game.returnToTitle, Game)
  end
end

local function quitGame()
  if love.event and love.event.quit then love.event.quit() end
end

-- ------- edge detection + reset, same real shape every other always-on
-- system in this mod already uses (CLAUDE.md's own pausing hard rule:
-- nested inside the "is this system even on" gate, not folded into it,
-- so a paused game freezes the screen exactly where it is instead of
-- tearing it down).
-- Up/down to move the highlighted option, the same real USE button
-- (`Input:wasPressed("a")`) every other confirm in this mod already
-- uses (`lib/DoomView.lua`'s own `tryRespawn`, `lib/DoomSettingsMenu.
-- lua`'s own row navigation for the up/down convention itself) to
-- commit it. Only ever polled while `not respawnAllowed` -- the
-- respawn screen's own USE press is handled entirely by `lib/DoomView.
-- lua`'s `tryRespawn`, unrelated to this selector.
local function handleGameOverInput()
  local ok, Game = pcall(require, "src.core.Game")
  local input = ok and Game.input
  if not (input and input.wasPressed) then return end
  if input:wasPressed("up") or input:wasPressed("down") then
    selectedOption = selectedOption == 1 and 2 or 1
  end
  if input:wasPressed("a") then
    if selectedOption == 1 then loadSave() else quitGame() end
  end
end

local installed = false
function DoomDeathScreen.install()
  if installed then return end
  installed = true
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if Options.enabled() and FirstPerson.onTop() then
      if DoomHealth.isDead() then
        if not active then
          active = true
          pcall(beginDeathScreen)
        end
        if not respawnAllowed then
          pcall(handleGameOverInput)
        end
      else
        active = false
        subtext = nil
      end
    end
    return next(game, dt)
  end)

  -- Lives persistence -- see `currentLives`/`consumeLife`'s own header
  -- comment above for the full reasoning. A brand-new save always gets
  -- a fresh `DEFAULT_LIVES`; an existing/loaded save keeps whatever was
  -- persisted, only defaulting when the field itself doesn't exist yet
  -- (an older save that predates this feature).
  V.mod.events:on("save.created", function()
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game.save then Game.save.pokedoomLives = DEFAULT_LIVES end
  end)
  V.mod.events:on("save.loaded", function()
    local ok, Game = pcall(require, "src.core.Game")
    if ok and Game.save and Game.save.pokedoomLives == nil then
      Game.save.pokedoomLives = DEFAULT_LIVES
    end
  end)
end

return DoomDeathScreen
