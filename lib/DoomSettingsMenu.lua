-- PokeDoom: the "Doom Settings" submenu. User request, 2026-08-10:
-- "put all these settings + the original settings added for the mod in
-- their own settings category that you can go inside of called 'Doom
-- Settings'." Every real PokeDoom settings row (the original ones this
-- mod already had, plus the 13-row batch added the same request) now
-- lives INSIDE this one nested screen, reached via a single "DOOM
-- SETTINGS" row spliced into the base engine's own top-level Options
-- menu (see `main.lua`'s own `ui.options.rows` hook) -- rather than the
-- ~24-row flat splice that used to sit directly in the vanilla list.
--
-- Debug/testing rows (TEST ENEMY, TEST ITEM, TEST WEAPON, START
-- INVASION) live here too, per a same-day follow-up request -- see
-- `buildRows`' own header comment below for that reasoning and for the
-- separate, same-day change that combined each debug tool's own former
-- pick+confirm row PAIR into one row apiece.
--
-- ------- how this actually plugs into the base engine's own menu stack
--
-- Confirmed by reading `gen1recomp-dev/src/ui/OptionsMenu.lua` and
-- `src/ui/Screens.lua` directly (never edited -- CLAUDE.md's own
-- addon-not-a-fork rule): a settings row can carry an `activate`
-- function instead of `value`/`step` (the base engine's own real MODS/
-- CONTROLS rows both already do this) -- pressing A calls
-- `activate(game)`, which those two rows use to `Screens.push(game, id)`
-- a NEW screen onto `game.stack`. `Screens.push` resolves `id` against
-- `game.data.screens` (`Data.screens`, written by the real, public
-- `mod.content.screens:register(id, { new = fn })` API,
-- `src/mods/Schemas.lua`'s own documented registry -- confirmed exact
-- example: `mod.content.screens:register("QuestLog", { new = function
-- (game) ... end })`) before falling back to a builtin `src.ui.<id>`
-- module. `main.lua` registers THIS file's own `DoomSettingsMenu.new`
-- under the id `"PokeDoomSettings"` for exactly that lookup.
--
-- `OptionsMenu` itself (the class the vanilla screen and MODS/CONTROLS
-- are built from) isn't reusable as-is for a nested screen showing only
-- THIS mod's own rows -- its own `buildRows` always assembles the FULL
-- vanilla row list (text speed, battle animation, etc.) plus every
-- OTHER mod's `ui.options.rows` hook contributions, which isn't what a
-- "Doom Settings" screen should show. Instead this class is built
-- directly on `src.ui.OptionRows` -- the SAME shared four-box-viewport
-- renderer and scroll-clamp `OptionsMenu` itself uses (`OptionRows.draw`/
-- `.clampScroll`, confirmed exported, reusable functions, not that
-- file's own private internals) -- with its own small `:update`/`:draw`
-- mirroring `OptionsMenu`'s own real input handling (`src/ui/
-- OptionsMenu.lua`'s own `:update`, restated rather than reused since
-- there's no smaller reusable seam for "handle a row list" alone without
-- also pulling in the vanilla row-building). Reaching `src.ui.OptionRows`/
-- `src.ui.Screens`/`src.core.Sound` via plain `require(...)` matches this
-- whole project's own already-established precedent for reaching the
-- base engine's real internals directly (e.g. `lib/DoomKill.lua`'s own
-- `require("src.core.Game")`/`"src.pokemon.Party"` etc.) -- reading and
-- calling the base engine's own modules, never editing them.

local V = ...
local Options = V.require("DoomOptions")
local DoomWadImport = V.require("DoomWadImport")
local DoomGZDoomImport = V.require("DoomGZDoomImport")
local DoomDemons = V.require("DoomDemons")
local DoomWeapons = V.require("DoomWeapons")
local DoomItems = V.require("DoomItems")
local DoomTownInvasion = V.require("DoomTownInvasion")
local OptionRows = require("src.ui.OptionRows")

local DoomSettingsMenu = {}
DoomSettingsMenu.__index = DoomSettingsMenu
DoomSettingsMenu.isOpaque = true

-- CHOOSE DOOM WAD (`DoomWadImport.row()`) is "an original setting added
-- for the mod" per the user's own broad phrasing -- folded in here
-- rather than left at the top level, so every real PokeDoom settings row
-- ends up in the same one place. Composed here (not inside `lib/
-- DoomOptions.lua` itself) to avoid a new cross-file require there for
-- one row -- this file is already the "assemble everything this screen
-- shows" seam.
--
-- MOVED IN 2026-08-10, direct user request: "test enemy, test weapon,
-- test item, and start invasion should also be in the doom settings."
-- Previously deliberately left at the top level as "developer tools, not
-- player-facing settings" -- the user's own follow-up request overrides
-- that call explicitly, so all four move in here too. GIVE WEAPON's own
-- real dev-mode gate (`_G.POKEPORT_DEV_MODE`, see `lib/DoomItems.lua`'s
-- matching 2026-08-08 fix for the full derivation -- true during this
-- project's own normal dev-launch workflow, false for a normal player)
-- is preserved exactly, just moved here with it.
local function buildRows()
  local rows = Options.rows()
  rows[#rows + 1] = DoomWadImport.row()
  -- CHOOSE GZDOOM.PK3 (`DoomGZDoomImport.row()`) -- the real menu font
  -- (`lib/DoomBigFont.lua`'s "BigUpper") import row, folded in right
  -- next to CHOOSE DOOM WAD since both are the same real "the player
  -- supplies something they already own, this mod extracts only what it
  -- needs" pattern, just from two different real sources.
  rows[#rows + 1] = DoomGZDoomImport.row()
  rows[#rows + 1] = DoomDemons.spawnRow()
  if _G.POKEPORT_DEV_MODE then
    rows[#rows + 1] = DoomWeapons.giveWeaponRow()
  end
  rows[#rows + 1] = DoomItems.spawnRow()
  rows[#rows + 1] = DoomTownInvasion.debugStartRow()
  return rows
end

function DoomSettingsMenu.new(game)
  return setmetatable({
    game = game,
    rows = buildRows(),
    index = 1,
    scroll = 0,
  }, DoomSettingsMenu)
end

-- Restated from `OptionsMenu:update` (`src/ui/OptionsMenu.lua`), same
-- shape, scoped to just this screen's own `self.rows` -- no vanilla-row
-- rebuild, no re-running the `ui.options.rows` hook (this screen only
-- ever shows what `buildRows` above assembled at construction time).
function DoomSettingsMenu:update(dt)
  local input = self.game.input
  local rows = self.rows
  local backRow = #rows + 1
  local changed = false
  if input:wasPressed("up") then
    self.index = self.index > 1 and self.index - 1 or backRow
  elseif input:wasPressed("down") then
    self.index = self.index < backRow and self.index + 1 or 1
  elseif input:wasPressed("left") or input:wasPressed("right")
      or input:wasPressed("a") then
    local dir = input:wasPressed("left") and -1 or 1
    local row = rows[self.index]
    if row and row.activate then
      if input:wasPressed("a") then row.activate(self.game) end
    elseif row and row.step then
      changed = row.step(self.game, dir) and true or false
    elseif input:wasPressed("a") then -- BACK
      if self.game.data then
        require("src.core.Sound").play(self.game.data, "Press_AB")
      end
      self.game.stack:pop()
    end
  elseif input:wasPressed("b") or input:wasPressed("start") then
    if self.game.data then
      require("src.core.Sound").play(self.game.data, "Press_AB")
    end
    self.game.stack:pop()
  end
  if changed and self.game.writeOptions then
    self.game:writeOptions()
  end
  self.scroll = OptionRows.clampScroll(self.index, self.scroll or 0, #rows, backRow)
end

function DoomSettingsMenu:draw()
  OptionRows.draw(self.game, self.rows, self.index, self.scroll or 0,
                  "BACK", #self.rows + 1)
end

return DoomSettingsMenu
