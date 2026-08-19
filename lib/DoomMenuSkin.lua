-- PokeDoom Phase 20: the pause menu (StartMenu) and its Options
-- submenu (OptionsMenu), redrawn in real DOOM's own menu visual
-- language -- the real skull cursor, and (as of 2026-08-08) the real
-- GZDoom "BigUpper" menu font -- while every LABEL and VALUE stays
-- exactly what gen1recomp's own menus already say (no DOOM vocabulary
-- substituted in, per the phase doc's own design). Scoped to just these
-- two menus this round, at the user's own explicit instruction ("strat
-- phase 20 only doing the main pause manu and the options menu, not
-- doing any of the menus under for now") -- full audit and design
-- already done in phases/phase-20-doom-pause-menu.md, re-read at the
-- point of use for every DOOM fact cited below rather than re-derived
-- from memory.
--
-- Two design calls the phase doc explicitly left open, decided here
-- (both flagged in this session's own reply, not silently assumed):
--   1. Background dimming -- vanilla `linuxdoom-1.10` does NOT dim
--      behind its own menu (`m_menu.c`'s `M_StartControlPanel` just
--      flips `menuactive`; `M_Drawer` draws straight over the last
--      rendered frame). Defaulted to matching that -- the primary
--      source authority -- rather than the user's own reference
--      screenshot, which the phase doc's own audit already suspected
--      came from a different source port.
--   2. Whether this rides the master PKDOOM MODE toggle or gets its
--      own row -- defaulted to the master toggle, matching every
--      other PKDOOM visual system in this project (the HUD, the view,
--      the weapons) -- no new options row.
--
-- FONT SWAP 2026-08-08: the user compared this menu against a real
-- GZDoom screenshot and pointed out the font was wrong -- `hu_font`
-- (`lib/DoomFont.lua`, still used elsewhere in this mod for pickup
-- messages/killfeed, untouched) is DOOM's real small MESSAGE font,
-- never used for any real menu anywhere in DOOM's source (vanilla menu
-- items are pre-drawn whole-word graphics with no reusable character
-- font behind them at all). The user's reference screenshot's actual
-- font is GZDoom's own "BigUpper" -- a real font, but GZDoom's own
-- bundled creation (not in any real IWAD, so `wadext` can't extract it,
-- and its own license restricts reuse to "the game from which it
-- originated"). At the user's own explicit instruction, this menu now
-- draws with `lib/DoomBigFont.lua`, a TEMPORARY dev-only decoder
-- reading BigUpper's raw `.lmp` files from a hand-copied dev folder
-- (`assets/generated/doom/gzdoom-fonts/`) -- see that file's own header
-- comment for the full derivation and the explicit "not the final
-- asset location" caveat. Swapping the font meant retuning every
-- spacing constant below too (BigUpper's own real glyphs are already
-- ~15-21px tall, roughly 2x `hu_font`'s own size) -- `TEXT_SCALE` and
-- the row-step constants are no longer literal `m_menu.c` values, they
-- are fitted to THIS substitute font's own real proportions.

local V = ...
local Options = V.require("DoomOptions")
local DoomBigFont = V.require("DoomBigFont")
local DoomFont = V.require("DoomFont") -- hu_font: OptionsMenu's own value line, see the 2026-08-08 OPTIONS AUDIT comment below
local DoomWadImport = V.require("DoomWadImport")
local DoomGZDoomImport = V.require("DoomGZDoomImport")
local DoomSpriteCache = V.require("DoomSpriteCache")
local DoomVirtualCanvas = V.require("DoomVirtualCanvas")
-- FEATURE 2026-08-10 -- direct user request: "the doom settings needs
-- the doom settings skin, right now it has the original pokemon
-- settings. implement it in the same way as the other settings menus."
-- `lib/DoomSettingsMenu.lua` is this mod's OWN "Doom Settings" nested
-- screen (not a `require("src.ui...")` base-engine module the way
-- `StartMenu`/`OptionsMenu` below are) -- reached the normal `V.require`
-- way instead.
local DoomSettingsMenu = V.require("DoomSettingsMenu")

local DoomMenuSkin = {}

-- ------- real DOOM constants (m_menu.c, re-read fresh this round)
--
-- `VIRTUAL_W, VIRTUAL_H = 320, 200`: DOOM's own real SCREENWIDTH/
-- SCREENHEIGHT -- shared via `lib/DoomVirtualCanvas.lua` so this menu
-- skin and the rest of this mod's own DOOM-native overlays (the status
-- bar, pickup messages, the town-invasion counter) all use the same
-- real coordinate system from one real source, not three independently-
-- typed copies of the same two numbers.
local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H

-- FIX 2026-08-08, superseded the same day: the original "text too
-- small" fix (before the font itself was identified as the real
-- problem) boosted `hu_font` by a `TEXT_SCALE` of 1.5. Now that menu
-- text draws through `DoomBigFont` (a font already sized close to real
-- DOOM's own menu-graphic scale, see that file's own header comment),
-- no artificial boost is needed -- kept at 1 rather than removed
-- outright so every draw/measure call site still has one shared,
-- easily-retuned scale knob if further sizing feedback comes in.
local TEXT_SCALE = 1

-- ------- FIX 2026-08-08 (user playtest report): "the skull is not
-- aligned with the text." Real DOOM's own skull draw call (m_menu.c:
-- 1802-1803) is `V_DrawPatchDirect(x + SKULLXOFF, currentMenu->y - 5 +
-- itemOn*LINEHEIGHT, ...)` -- `SKULLXOFF=-32` (m_menu.c:128) and the
-- `-5` are BOTH fixed pixel nudges tuned against DOOM's own real
-- per-item WORD-GRAPHIC patches' own particular `grAb` top/left
-- conventions, a completely different patch family from this port's own
-- menu-font glyphs (which offset themselves by THEIR OWN, unrelated,
-- per-glyph `grAb` convention, same idea whether that font is `hu_font`
-- or `DoomBigFont`). Chaining those two DIFFERENT
-- patch families' own offset conventions together (this file's original
-- 1x implementation) is exactly the kind of coincidental, unverified
-- number-reuse CLAUDE.md's own scale/position guidance warns against --
-- reusing `-32`/`-5` here would be reusing a number tuned for a
-- different graphic, not real parity. Replaced with a robust GEOMETRIC
-- rule instead: the skull's own real pixel HEIGHT (`patch.image:
-- getHeight()`, ignoring its own `grAb` top entirely) vertically centers
-- it against its own row's real step distance, and a small fixed gap
-- (independent of either patch family's own offsets) separates its
-- right edge from the text column -- see `drawSkull` below.
local SKULL_GAP = 6

-- `skullAnimCounter` starts at 10 (`M_StartControlPanel`, m_menu.c:
-- 1852-1853), decrements once per real 35Hz DOOM tic (`M_Ticker`),
-- and at 0 flips `whichSkull` and resets to 8 -- NOT 10 again
-- (m_menu.c:1836-1839) -- so the very first interval is 10 tics and
-- every one after it is 8. Restated as a real-time (seconds) countdown
-- rather than a per-call tic decrement: this draws from `love.draw`,
-- whose own call rate is neither DOOM's real 35Hz nor this engine's
-- own fixed 60Hz game-logic step (confirmed the two are genuinely
-- different this same session, auditing `lib/DoomDemons.lua`'s own
-- sound-frequency bug) -- a dt-based countdown reproduces the real
-- cadence regardless of the actual render rate.
local DOOM_TIC_SECONDS = 1 / 35
local SKULL_FIRST_SECONDS = 10 * DOOM_TIC_SECONDS
local SKULL_SECONDS = 8 * DOOM_TIC_SECONDS

-- ------- asset loading
--
-- Skull cursor (`M_SKULL1`/`M_SKULL2`, m_menu.c:175), the real
-- `M_OPTTTL` Options header, and the real thermo-bar patches
-- (`M_THERML`/`M`/`R`/`O`) all load through this one cache -- see the
-- 2026-08-08 OPTIONS AUDIT comment on `drawRows` below for the thermo
-- bar's own real derivation (this used to be flagged "not built here,"
-- true until this round found this mod's own real range-valued rows).
local loadPatch = DoomSpriteCache.newAssetLoader()

-- ------- pause-menu logo
--
-- Real DOOM's own `M_DrawMainMenu` (m_menu.c:856-859) draws the real
-- `M_DOOM` patch every time that menu is active, INCLUDING reached
-- mid-game via ESC (there is no separate pause-specific menu in
-- vanilla DOOM at all -- confirmed by reading the source: `MainDef`,
-- `MainMenu[]`, and `M_DrawMainMenu` are the ONE structure serving both
-- the title screen and the in-game pause menu). This mod's own pause
-- menu had no equivalent header, a real, user-flagged discrepancy from
-- the reference screenshot. The real `M_DOOM` patch itself literally
-- says "DOOM," which would contradict this file's own no-DOOM-
-- vocabulary design rule (see the header comment) -- rather than reuse
-- it or invent new header text unilaterally, this was flagged back to
-- the user, who supplied this mod's own real logo (`assets/menu/
-- pokedoom_logo.png`, a genuine mod-owned asset, not extracted from
-- any WAD -- this project's FIRST committed non-generated image, so it
-- lives outside `assets/generated/` entirely, matching that folder's
-- own reserved meaning). Confirmed transparent (RGBA, real alpha=0
-- corners) before wiring it in, so it floats over the paused game view
-- the same way the real `M_DOOM` patch does, not as an opaque box.
-- FIX 2026-08-19 -- REAL ROOT CAUSE of "i dont see the logo in the main
-- menu": this used to read from `DoomWadImport.absoluteModPath(...)`, the
-- SAME real absolute-path convention confirmed this same round to get
-- silently redirected into this mod's own sandboxed compat overlay
-- storage for mod code (see `lib/DoomWadImport.lua`'s own `assetList`
-- header comment for the full derivation) -- correct for a RUNTIME-
-- GENERATED file (extracted WAD assets), but this logo is a real, shipped
-- mod asset checked into this repo's own `assets/menu/` folder, genuinely
-- living inside this mod's own installed package tree, not the overlay.
-- A bare RELATIVE path (no `absoluteModPath` involved at all) is what
-- actually resolves there -- the exact same fix `lib/DoomWadImport.lua`'s
-- own import-folder scan already proved correct this same round.
local logoImage = false -- false = not yet attempted; nil is never cached here
local function loadLogo()
  if logoImage ~= false then return logoImage or nil end
  local value = nil
  do
    local ok, fp = pcall(io.open, "assets/menu/pokedoom_logo.png", "rb")
    if ok and fp then
      local okRead, bytes = pcall(fp.read, fp, "*a")
      pcall(fp.close, fp)
      if okRead and type(bytes) == "string" and #bytes > 0 then
        local okData, fileData = pcall(love.filesystem.newFileData, bytes, "pokedoom_logo.png")
        if okData and fileData then
          local okImg, image = pcall(love.graphics.newImage, fileData)
          if okImg and image then value = image end
        end
      end
    end
  end
  logoImage = value
  return value
end

-- Fit by HEIGHT and centered horizontally, since this mod's own real
-- logo doesn't share real `M_DOOM`'s own roughly-square proportions.
-- Swapped once already, same shape both times -- `loadLogo` always
-- re-reads whatever real file currently sits at `assets/menu/
-- pokedoom_logo.png` (originally a 500x155 "PokéDOOM" wordmark,
-- replaced 2026-08-08 with a 200x92 "Pokémon Hellfire Red"-style logo,
-- both user-supplied) -- no dimension-specific code here, so a future
-- swap needs no code change either.
-- FIX 2026-08-08 (user report: "make the pokedoom logo smaller. its too
-- big right now") -- reduced from the original `50` to `32`, for the
-- WIDE 500x155 wordmark logo active at the time.
--
-- FIX 2026-08-08 (later, same day, after the logo asset itself was
-- swapped to the 200x92 "Pokémon Hellfire Red" logo): "make the logo in
-- the pause menu bigger. i didnt like the way it looked last time which
-- is why i made it smaller but i like this one" -- the earlier shrink
-- was specifically a reaction to the OLD wide wordmark reading too big;
-- the new, more compact logo doesn't have that problem, so this is
-- sized up again, past the original `50` -- a visual-parameter judgment
-- call (CLAUDE.md's "Nature of the port"), not a regression back to a
-- literal old value.
local LOGO_TOP_Y = 6
local LOGO_HEIGHT = 46
local function drawLogo()
  local logo = loadLogo()
  if not logo then return end
  local iw, ih = logo:getDimensions()
  local scale = LOGO_HEIGHT / ih
  local w = iw * scale
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(logo, (VIRTUAL_W - w) / 2, LOGO_TOP_Y, 0, scale, scale)
end

local function tickSkull(state, dt)
  state.doomSkullFrame = state.doomSkullFrame or 1
  state.doomSkullTimer = (state.doomSkullTimer or SKULL_FIRST_SECONDS) - dt
  if state.doomSkullTimer <= 0 then
    state.doomSkullFrame = state.doomSkullFrame == 1 and 2 or 1
    state.doomSkullTimer = SKULL_SECONDS
  end
end

-- x0: the text column's own left edge. rowY: the same y passed to this
-- row's own `DoomBigFont.draw` call. rowStep: the real vertical distance
-- from this row to the next (`LIST_LINE_STEP`/`ROW_STEP` below) -- used
-- ONLY as a stand-in for "how tall this row's own text visually reads,"
-- to vertically center the skull against it; see the FIX comment above
-- `SKULL_GAP` for why this doesn't chain through either patch's own
-- `grAb` top the way the 1x version did. `scale`: defaults to
-- `TEXT_SCALE` (the list style's own real scale) -- the rows style
-- passes its own separate `ROWS_TEXT_SCALE` instead, since its label
-- font now shrinks independently (see the 2026-08-08 "5 rows visible"
-- fix below).
local function drawSkull(state, x0, rowY, rowStep, scale)
  scale = scale or TEXT_SCALE
  local patch = loadPatch(state.doomSkullFrame == 1 and "M_SKULL1" or "M_SKULL2")
  if not patch then return end
  local iw = patch.image:getWidth() * scale
  local ih = patch.image:getHeight() * scale
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(patch.image, x0 - SKULL_GAP * scale - iw, rowY + (rowStep - ih) / 2, 0, scale, scale)
end

-- ------- virtual-canvas transform
--
-- CENTERED on both axes, not bottom-anchored the way `lib/DoomHud.
-- lua`'s own status-bar transform is -- that file's own transform
-- deliberately keeps DOOM's real bottom-screen furniture flush against
-- a widescreen window's own bottom edge, a real DOOM concept (the
-- status bar always sits at SCREENHEIGHT). A menu has no equivalent
-- "must sit flush against an edge" real constraint -- `M_Drawer`'s own
-- real layout centers everything within its own 320x200 space -- so
-- any window-aspect-ratio slack splits evenly here instead. See
-- `lib/DoomVirtualCanvas.lua`'s own header for why this transform lives
-- there now, shared with `lib/DoomTownInvasion.lua`'s own identical copy.
local virtualScaleAndOffset = DoomVirtualCanvas.centered

-- FEATURE 2026-08-08 (user report, two reference screenshots: unpaused
-- vs. paused) -- "in the original doom game there is a slight yellow
-- screen overlay underneath the text on top of the rest of the screen
-- when the game is pause." Checked vanilla `linuxdoom-1.10` first, per
-- CLAUDE.md's hard rule: `D_Display` (d_main.c:193-310) has no screen-
-- wide tint of any kind while `menuactive` -- confirmed by grepping
-- every `.c` file for `menuactive` and for `tint`/`dim`/`shade` in
-- `m_menu.c`/`v_video.c`/`st_stuff.c`, zero hits. This is a REAL
-- mechanic, but a `gzdoom-master` one, not vanilla DOOM's own (the
-- secondary source, cited explicitly per that same hard rule) --
-- `System_M_Dim` (`src/menu/doommenu.cpp:332-348`) fills the whole
-- screen with `gameinfo.dimcolor` at `gameinfo.dimamount` alpha before
-- any menu content draws on top, UNLESS the user's own `dimamount` cvar
-- overrides it (defaults to `-1`, meaning "use gameinfo," per that same
-- function). DOOM's own real per-game value
-- (`wadsrc/static/mapinfo/doomcommon.txt:39-40`, shared by DOOM/DOOM2 in
-- GZDoom): `dimcolor = "30 26 00"` (hex RGB, a dark yellow/olive --
-- exactly the "slight yellow" the user described) at `dimamount = 0.5`.
-- FIX 2026-08-08 (user report, screenshot): "there are a few pixels at
-- the top and bottom of the screen that arent getting the overlay."
-- Root cause: this used to fill exactly `(0,0)-(VIRTUAL_W,VIRTUAL_H)`
-- INSIDE the already-scaled/translated virtual-canvas transform (the
-- same space `drawList`/`drawRows` draw text into) -- correct in
-- principle, but `virtualScaleAndOffset`'s own `scale` is rarely an
-- exact integer against a real window size, and `love.graphics.
-- rectangle`'s fill bounds can round to a fraction of a pixel short of
-- the true edge at a non-integer scale, leaving a real, visible sliver
-- of the untinted world peeking through right at the top/bottom seam.
-- Real GZDoom's own `System_M_Dim` doesn't have this problem at all --
-- it fills `twod->GetWidth()/GetHeight()`, the WHOLE real render
-- target, not a scaled sub-rectangle -- so this is restated the same
-- way: filled in raw screen space, BEFORE the virtual push/translate/
-- scale (see the call site below), covering the actual window
-- dimensions directly with no scale math to round against at all.
local MENU_DIM_COLOR = { 0x30 / 255, 0x26 / 255, 0x00 / 255 }
local MENU_DIM_AMOUNT = 0.5
local function drawMenuDim(w, h)
  love.graphics.setColor(MENU_DIM_COLOR[1], MENU_DIM_COLOR[2], MENU_DIM_COLOR[3], MENU_DIM_AMOUNT)
  love.graphics.rectangle("fill", 0, 0, w, h)
  love.graphics.setColor(1, 1, 1, 1)
end

-- ------- list style -- StartMenu/Menu instances: .items, .index,
-- .scroll, .game. Real DOOM's own generic per-item loop (`M_Drawer`,
-- m_menu.c:1793-1798): one patch per item, LINEHEIGHT apart, skull
-- cursor SKULLXOFF left of the column, tracking `itemOn` -- restated
-- with `DoomBigFont.draw(item.label, ...)` standing in for DOOM's own
-- pre-drawn word-graphics (per the phase doc's own design: keep
-- gen1recomp's real text, borrow only DOOM's real font/cursor/rhythm).
-- As many rows as this canvas can comfortably hold -- this mod's own
-- 320x200 DOOM-native space has considerably more room than the tiny
-- 160x144 canvas `StartMenu.lua`'s own `maxVisible` was originally
-- sized for. `markSkin` (below) widens a list menu's real `maxVisible`
-- field to at least this, once, right after construction -- leaving it
-- at the old, smaller cap would make this skin able to SHOW more rows
-- than the underlying `Menu:update()`'s own real scroll math believes
-- are visible, so `self.index` could scroll out of view of what's
-- actually being drawn.
-- FIX 2026-08-08 (user playtest report, screenshots): "the text is too
-- big and far apart" -- comparing pic 2 (real GZDoom) directly: its 6
-- menu items occupy roughly 45% of screen height; this mod's own first
-- BigUpper attempt used 8 items to occupy roughly 94% -- a ~1.6x
-- looser packing per row than real DOOM's own. `LIST_LINE_STEP` was
-- `26` (an estimate made before actually seeing this font rendered);
-- restored to real DOOM's own literal `LINEHEIGHT` constant (m_menu.c:
-- 129) instead -- now that `DoomBigFont`'s own real glyph proportions
-- are close to what DOOM's own real menu-item GRAPHICS were (the thing
-- LINEHEIGHT was actually tuned to fit), that literal real constant is
-- appropriate again, unlike the earlier `hu_font` version where it
-- wasn't (hu_font's own glyphs are much smaller than a real menu-item
-- graphic, hence that round's own `TEXT_SCALE` boost instead).
-- FIX 2026-08-08 (later, same day) -- user report: once the Pokédex
-- unlocks (a real 9th item added to this menu's own item list --
-- Pokédex/Pokémon/Item/name/Save/Option/Link/Mods/Quit), the list no
-- longer fit this canvas's own then-current 8-row cap, pushing "Quit"
-- itself behind a "More" scroll -- "it should be able to show all the
-- options there at once with nothing cutting off the screen." Tightened
-- from the real `LINEHEIGHT` literal back down slightly so 9 rows fit
-- (`LIST_VISIBLE_CAP`, below, recomputes to 9 at this value) -- a small,
-- deliberate deviation from the real DOOM constant this was restored to
-- above, made because this mod's own item count (up to 9) genuinely
-- exceeds any real DOOM menu's own row count, which is exactly the kind
-- of case CLAUDE.md's own "Nature of the port" rule already flags as a
-- visual-parameter judgment call rather than a fact to keep re-deriving.
local LIST_LINE_STEP = 14

-- FIX 2026-08-08 (later, same day): now that a real logo occupies the
-- top of the canvas (see `drawLogo` above), the item list starts right
-- below it. Originally set to `62`, mirroring real DOOM's own `MainDef`
-- `y=64` (m_menu.c:267) -- but that value was derived against DOOM's
-- OWN logo/gap proportions, and once the logo was shrunk (`LOGO_HEIGHT`
-- 50->32, a separate fix the same day) it left a visibly oversized gap
-- the user flagged directly ("the logo and pause text should be closer
-- together now"). Tightened to sit just under the logo's own real
-- bottom edge (`LOGO_TOP_Y + LOGO_HEIGHT` = 6+32 = 38) plus a small
-- breathing gap, rather than reusing DOOM's own now-inapplicable fixed
-- offset.
--
-- FIX 2026-08-08 (later, same day, alongside `LOGO_HEIGHT`'s own second
-- resize above): kept at the same real relationship this constant was
-- originally derived from (`LOGO_TOP_Y + LOGO_HEIGHT` plus the same ~8px
-- breathing gap) rather than left stale against the now-taller logo,
-- which would have pushed the list up into the logo's own new bottom
-- edge -- 6 + 46 + 8 = 60.
local LIST_TOP_Y = 60
local LIST_BOTTOM_MARGIN = 10
local LIST_VISIBLE_CAP = math.floor((VIRTUAL_H - LIST_TOP_Y - LIST_BOTTOM_MARGIN) / LIST_LINE_STEP)

-- FIX 2026-08-08 (same round as `LIST_LINE_STEP`'s own resize above) --
-- user request: "make more smaller and further up with a bigger
-- distinction between it and the actual list of option. just like the
-- more in the options menu." Previously drawn at full `TEXT_SCALE`
-- immediately after the last visible row, with no separation at all --
-- unlike `drawRows`' own real "More" treatment (`ROWS_TEXT_SCALE`, a
-- smaller label scale, plus `MORE_EXTRA_GAP`, extra clearance before
-- it), which this now deliberately matches: same literal values, reused
-- here as their own named constants (declared before `ROWS_TEXT_SCALE`/
-- `MORE_EXTRA_GAP` exist as locals further down the file, so those two
-- can't be referenced directly from `drawList`, defined above them).
local LIST_MORE_SCALE = 0.55
local LIST_MORE_EXTRA_GAP = 8

-- FIX 2026-08-08 (user playtest report): "new game is New Game,
-- options it Options... POKEMON SHOULD BE Pokemon - no accent mark on
-- the e and no space between letters." gen1recomp's own real labels
-- (`gen1recomp-dev/src/ui/StartMenu.lua`/`OptionsMenu.lua`) are
-- genuinely stored ALL-CAPS at the source (`Strings("ITEM")`,
-- `Strings("POKéMON")`, confirmed by reading those files directly) --
-- this file's own earlier "keep gen1recomp's own real text" design
-- choice (see the header comment) meant displaying that verbatim, all-
-- caps text, which is why the very first BigUpper render still looked
-- all-caps even though this font is genuinely mixed-case. The user's
-- own explicit instruction here overrides that specific presentation
-- choice: DISPLAY in Title Case, matching real DOOM's own real menu
-- vocabulary style (pic 2). `item.label`/`r.label` themselves are left
-- completely untouched (the vanilla, PKDOOM-MODE-off render still
-- shows gen1recomp's own real, unmodified string) -- this is a
-- display-only transform applied at draw time in this file alone.
--
-- Also found and fixed the real cause of the FIRST screenshot's own
-- stray "POKA MON" (not just "too small text" -- a second, separate,
-- previously-unnoticed bug): `Strings("POKéMON")`'s real 'é' is UTF-8
-- (bytes `0xC3 0xA9`, confirmed by reading the raw source bytes
-- directly), but `DoomBigFont.draw`'s own per-BYTE codepoint lookup
-- (matching `DoomFont.draw`'s own established convention, correct for
-- pure ASCII) has no UTF-8 DECODING step -- it looked up byte `0xC3`
-- and byte `0xA9` as two SEPARATE, wrong "codepoints." `0xA9` has no
-- real BigUpper glyph (falls back to a blank space, same as before),
-- but `0x00C3` -- confirmed present in this mod's own copied BigUpper
-- set -- is a REAL glyph (`Ã`), which is what actually rendered,
-- misread as a stray "A" against a red background at this font's own
-- size. Per the user's own explicit instruction ("no accent mark"),
-- fixed by transliterating the exact UTF-8 sequence to plain "e" as
-- part of the same prettify step, rather than building general UTF-8
-- decoding for what is, in this whole project, one accented character
-- in one label.
local ACCENT_STRIP = {
  ["\195\169"] = "e", -- UTF-8 'é' (0xC3 0xA9)
}

local function prettify(text)
  if not text then return text end
  for utf8seq, plain in pairs(ACCENT_STRIP) do
    text = text:gsub(utf8seq, plain)
  end
  text = text:lower()
  text = text:gsub("^%l", string.upper)
  text = text:gsub("%s%l", string.upper)
  return text
end

local function drawList(menu)
  drawLogo()
  local items = menu.items or {}
  if #items == 0 then return end
  local widest = 0
  for _, item in ipairs(items) do
    if item.label then
      widest = math.max(widest, DoomBigFont.measure(prettify(item.label), TEXT_SCALE))
    end
  end
  local visible = math.min(#items, menu.maxVisible or LIST_VISIBLE_CAP)
  local y0 = LIST_TOP_Y
  local x0 = math.max(48, (VIRTUAL_W - widest) / 2)
  local scroll = menu.scroll or 0
  local drawn = 0
  for row = 1, visible do
    local item = items[scroll + row]
    if not item then break end
    local y = y0 + (row - 1) * LIST_LINE_STEP
    DoomBigFont.draw(prettify(item.label), x0, y, nil, nil, nil, nil, TEXT_SCALE)
    if scroll + row == menu.index then
      drawSkull(menu, x0, y, LIST_LINE_STEP)
    end
    drawn = row
  end
  if scroll + drawn < #items then
    DoomBigFont.draw("More", x0, y0 + drawn * LIST_LINE_STEP + LIST_MORE_EXTRA_GAP, nil, nil, nil, nil, LIST_MORE_SCALE)
  end
end

-- ------- rows style -- OptionsMenu instances: .rows, .index, .scroll,
-- .game. Each row is a real two-line unit (label, then its current
-- value) -- the same shape `OptionRows.draw` already uses, restated in
-- DOOM's own font/cursor instead of that file's bordered-box style. The
-- real CANCEL row (`OptionsMenu:draw`'s own `#self.rows + 1` index) is
-- drawn as a fixed extra row at the bottom, matching that same real
-- indexing so the skull cursor lands on it correctly.
--
-- 2026-08-08 OPTIONS AUDIT -- the user compared this menu against real
-- 1993 DOOM's own actual Options screen and asked for a source-verified
-- audit rather than another guess. Re-read `m_menu.c` fresh:
--   - `OptionsDef` (m_menu.c:364-372): real start position `x=60,y=37`.
--     `M_DrawOptions` (m_menu.c:951-966) draws `M_OPTTTL` (the real
--     "OPTIONS" header patch) at `(108,15)` -- both reused verbatim
--     below, the same way this file already reuses `M_SKULL1/2`'s own
--     real positions, since `M_OPTTTL` is functionally the same word
--     gen1recomp's own vocabulary already uses here ("OPTION"/
--     "OPTIONS"), unlike `M_DOOM` on the pause menu (which the user was
--     shown, then supplied a real replacement logo for instead).
--   - `M_DrawThermo` (m_menu.c:1182-1201): a real slider is `M_THERML`
--     (left cap) + `M_THERMM` repeated `thermWidth` times, 8px stride
--     each (`xx += 8`, m_menu.c:1196) + `M_THERMR` (right cap), with
--     `M_THERMO` (the knob) drawn at `x+8 + thermDot*8`. Confirmed all
--     4 patches already present in this project's own extracted assets
--     (`m_therml`/`m_thermm`/`m_thermr`/`m_thermo`, 6x13/9x13/6x13/5x11
--     real px). Real DOOM only uses this for genuinely RANGE-valued
--     settings (Screen Size, Mouse Sensitivity, Sound Volume) -- every
--     enum/toggle row (End Game, Messages, Graphic Detail) stays plain
--     text even in real DOOM, confirmed by reading `M_DrawOptions`
--     itself, which only calls `M_DrawThermo` twice. This mod's own
--     OptionsMenu (`gen1recomp-dev/src/ui/OptionsMenu.lua`, read fresh)
--     has exactly three genuine 0-7 range settings of its own (Music
--     Vol/SFX Vol/Pikachu Vol, `volLabel`/`stepVolume`, confirmed
--     `0-7` inclusive) -- `SLIDER_ROWS` below identifies those three by
--     their own real row `id` and draws a real thermo bar for them
--     instead of text, reading the RAW numeric value directly out of
--     `menu.game.save.options[id]` (the formatted `r.value(...)`
--     function only returns a display STRING like "OFF"/"5", not a
--     number a slider can position against).
--
-- Two things the user explicitly asked to KEEP, deliberately NOT
-- matching real DOOM 1:1 for: (1) label-then-value STACKED on two
-- lines, rather than real DOOM's own actual same-line inline layout
-- (confirmed from source: `V_DrawPatchDirect(OptionsDef.x+120,
-- OptionsDef.y+LINEHEIGHT*messages,...)` -- real DOOM draws a row's
-- value patch at the SAME y as its label, offset sideways, not
-- underneath) -- the user's own explicit words: "have the button name
-- then the on off indicator under that. i want it like this"; (2) the
-- LABEL line stays `DoomBigFont`, but the VALUE line (for non-slider
-- rows) now uses `DoomFont` (`hu_font`, "a smaller doom font," the
-- user's own words) instead of `DoomBigFont` -- a genuine two-font
-- row, not something real DOOM itself does (every real DOOM menu
-- string is one font/patch family at a time) but a deliberate,
-- explicit user choice for this mod's own presentation.
--
-- FIX (spacing): the immediately preceding round's `ROW_STEP=22`/
-- `ROW_VALUE_OFFSET=11` was a mis-scaled estimate -- it assumed the
-- value line would shrink by the SAME ratio as the list style's single
-- -line rows, but a row here is genuinely TWO STACKED LINES, and at
-- the time both were still `DoomBigFont`-sized (up to 21px tall) --
-- 22px total was nowhere near enough room even for the label alone,
-- confirmed directly by the user's own screenshot (every row's text
-- overlapping into an illegible smear). `ROW_VALUE_OFFSET=18` gives the
-- `DoomBigFont` label line its own real, full line height (matching
-- `LIST_LINE_STEP`) before the (now smaller, `hu_font`) value line
-- starts; `ROW_STEP=34` leaves that value line real room of its own
-- before the NEXT row's label begins.
-- FIX 2026-08-08 (later, same day): "not enough items are shown...
-- needs to be atleast 5... make the button names smaller so more can
-- fit." `ROWS_TEXT_SCALE` is a SEPARATE scale from the pause list's own
-- `TEXT_SCALE` (which the user separately confirmed is "perfect," not
-- to be touched) -- shrinking the label font specifically for
-- OptionsMenu rows, independent of the pause menu. At `0.55`, a label's
-- own real max glyph height (21px) drops to ~11.5px, leaving enough of
-- `ROW_STEP`'s own budget for the (unscaled, already-small) `hu_font`
-- value line beneath it. `ROWS_TOP_Y`/`ROWS_CANCEL_GAP` tightened
-- alongside it (still clearing the real header/CANCEL row) to fit a 6th
-- row, comfortably past the user's own stated "at least 5" floor.
local ROWS_TEXT_SCALE = 0.55
local ROW_STEP = 20
local ROW_VALUE_OFFSET = 11
local ROWS_TOP_Y = 36 -- clears the real M_OPTTTL header drawn at y=15/height=15
local ROWS_CANCEL_GAP = 18 -- clear space reserved above the fixed CANCEL row
local ROWS_X0 = 56
-- FIX 2026-08-08: "move more down to slightly disconnect it from the
-- list so it doesnt look like an extension to the list" -- an extra gap
-- ON TOP OF the normal `ROW_STEP` before drawing "More", so it visually
-- reads as a separate footer line rather than one more row.
local MORE_EXTRA_GAP = 8
-- FIX 2026-08-08: "move cancel up a small bit. its too close to the
-- bottom" -- was `VIRTUAL_H - 16`.
local ROWS_CANCEL_Y = VIRTUAL_H - 24

-- FIX 2026-08-08: "when scrolling down or up the skull is always one
-- ahead of whats being rendered." Root cause, confirmed by reading
-- `gen1recomp-dev/src/ui/OptionRows.lua` fresh: the REAL scroll math
-- this menu's own `:update()` runs every frame (`OptionsMenu.lua:560`,
-- `self.scroll = OptionRows.clampScroll(self.index, self.scroll, #rows,
-- cancelRow)`) reads a SHARED module constant, `OptionRows.VISIBLE =
-- 4` (`OptionRows.lua:14`) -- baked in for that file's OWN real
-- bordered-box rendering (4 boxes tall), completely independent of
-- HOW MANY ROWS THIS FILE ACTUALLY DRAWS. Once this file's own real
-- visible-row count differs from 4 (it does -- see `ROWS_VISIBLE_CAP`
-- below), the host's own scroll-clamping decides "should I scroll yet"
-- against a WINDOW SIZE THIS FILE ISN'T ACTUALLY DRAWING, producing
-- exactly the reported one-row desync. The EXACT same class of bug
-- `markSkin`'s own `menu.maxVisible` widening already fixes for the
-- "list" style (`StartMenu`) -- `OptionRows.VISIBLE` has no per-
-- instance override seam the way `maxVisible` does, though, so instead
-- of widening a shared module constant (real risk: `OptionRows.lua`'s
-- own header comment says its shared by the mod manager's own unrelated
-- options UI too, which would visually break at a different row count
-- it wasn't designed for), this wraps `OptionsMenu.update` itself
-- (below, in `wrapOptionsMenu`) and RECOMPUTES `self.scroll` afterward
-- using THIS file's own real visible-row count, only while PKDOOM MODE
-- is on -- `clampScrollFor` below is `OptionRows.clampScroll`'s own
-- real algorithm (re-read fresh, ported line-for-line), parameterized
-- by visible count instead of hardcoded.
local ROWS_VISIBLE_CAP = math.floor((ROWS_CANCEL_Y - ROWS_CANCEL_GAP - ROWS_TOP_Y) / ROW_STEP)

local function clampScrollFor(index, scroll, total, bottomRow, visibleCount)
  if bottomRow and index >= bottomRow then
    return math.max(0, total - visibleCount)
  elseif index <= scroll then
    return index - 1
  elseif index > scroll + visibleCount then
    return index - visibleCount
  end
  return scroll
end

local HEADER_PATCH_NAME = "M_OPTTTL"
local HEADER_X, HEADER_Y = 108, 15 -- m_menu.c:953, verbatim real DOOM position
local function drawOptionsHeader()
  local patch = loadPatch(HEADER_PATCH_NAME)
  if not patch then return end
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.draw(patch.image, HEADER_X - patch.left, HEADER_Y - patch.top)
end

-- row id -> max value (inclusive); every row here is this mod's own
-- real 0-7 volume range (`OptionsMenu.lua`'s own `stepVolume`, clamped
-- `math.max(0, math.min(7, ...))`) -- `thermWidth` reuses real DOOM's
-- own `maxValue + 1` convention (`mouseSensitivity`'s real thermWidth
-- of 10 for a 0-9 range, m_menu.c:961-962), so the bar has exactly
-- enough discrete positions for the real range it represents.
local SLIDER_ROWS = { musicVol = 7, sfxVol = 7, pikaVol = 7 }
local THERM_STRIDE = 8 -- m_menu.c:1196, the real per-segment pixel stride

-- FIX 2026-08-08 (user playtest report, screenshot): "the sliders are
-- overlapping with text below it." The thermo bar's own real patches
-- (13px tall, up to ~76px wide at native 1x for this mod's own 0-7
-- range) were still drawn at native scale even after `ROW_STEP`/
-- `ROWS_TEXT_SCALE` shrank everything AROUND it to fit more rows (the
-- same round that first introduced sliders never actually got played
-- before this shrink happened) -- a real, previously-untested gap: the
-- slider never went through the same scale-down as the label/skull/
-- hu_font value line. `scale` (the caller passes `ROWS_TEXT_SCALE`,
-- same as every other rows-style element) now applies uniformly to
-- both the stride (so segments still tile edge-to-edge) and each
-- patch's own draw size, exactly the same pattern `drawSkull` already
-- established for its own `scale` parameter.
local function drawThermo(x, y, maxValue, dot, scale)
  scale = scale or 1
  local left = loadPatch("M_THERML")
  local mid = loadPatch("M_THERMM")
  local right = loadPatch("M_THERMR")
  local knob = loadPatch("M_THERMO")
  if not (left and mid and right and knob) then return end
  love.graphics.setColor(1, 1, 1, 1)
  local stride = THERM_STRIDE * scale
  local xx = x
  love.graphics.draw(left.image, xx - left.left * scale, y - left.top * scale, 0, scale, scale)
  xx = xx + stride
  local thermWidth = maxValue + 1
  for _ = 1, thermWidth do
    love.graphics.draw(mid.image, xx - mid.left * scale, y - mid.top * scale, 0, scale, scale)
    xx = xx + stride
  end
  love.graphics.draw(right.image, xx - right.left * scale, y - right.top * scale, 0, scale, scale)
  local clampedDot = math.max(0, math.min(maxValue, dot or 0))
  love.graphics.draw(knob.image, (x + stride) + clampedDot * stride - knob.left * scale, y - knob.top * scale, 0, scale, scale)
end

local function drawRows(menu)
  drawOptionsHeader()
  local rows = menu.rows or {}
  local cancelRow = #rows + 1
  local cancelY = ROWS_CANCEL_Y
  local visible = math.min(#rows, ROWS_VISIBLE_CAP)
  local x0 = ROWS_X0
  local y0 = ROWS_TOP_Y
  local scroll = menu.scroll or 0
  local drawn = 0
  for row = 1, visible do
    local i = scroll + row
    local r = rows[i]
    if not r then break end
    local y = y0 + (row - 1) * ROW_STEP
    DoomBigFont.draw(prettify(r.label), x0, y, nil, nil, nil, nil, ROWS_TEXT_SCALE)
    local sliderMax = r.id and SLIDER_ROWS[r.id]
    if sliderMax then
      local raw = menu.game and menu.game.save and menu.game.save.options
        and menu.game.save.options[r.id]
      drawThermo(x0, y + ROW_VALUE_OFFSET, sliderMax, tonumber(raw) or 0, ROWS_TEXT_SCALE)
    elseif r.value then
      local ok, value = pcall(r.value, menu.game)
      -- FIX 2026-08-08 (user report: "the text below button names has a
      -- darker outline than the button names"). `DoomFont.draw` here
      -- used to pass no color at all, drawing `hu_font`'s own real WAD
      -- pixel colors completely unmodified -- a genuinely different red
      -- (id Software's own STCFN art, antialiasing to near-black at the
      -- edges) from `DoomBigFont`'s own synthesized gradient (see that
      -- file's own header comment for the full reasoning). Tinting this
      -- specific call toward the SAME darker-red family the label line
      -- now uses pulls both lines of a row into one visually consistent
      -- style, rather than reading as two unrelated fonts stacked on top
      -- of each other -- every OTHER `DoomFont.draw` call site (pickup
      -- messages, the killfeed) is deliberately left untinted, since
      -- those want the real, unmodified DOOM message-font color.
      if ok and value then DoomFont.draw(tostring(value), x0, y + ROW_VALUE_OFFSET, 0.85, 0.3, 0.3, 1) end
    end
    if i == menu.index then
      drawSkull(menu, x0, y, ROW_STEP, ROWS_TEXT_SCALE)
    end
    drawn = row
  end
  if scroll + drawn < #rows then
    DoomBigFont.draw("More", x0, y0 + drawn * ROW_STEP + MORE_EXTRA_GAP, nil, nil, nil, nil, ROWS_TEXT_SCALE)
  end
  DoomBigFont.draw(menu.pokedoomBottomLabel or "Cancel", x0, cancelY, nil, nil, nil, nil, ROWS_TEXT_SCALE)
  if menu.index == cancelRow then
    drawSkull(menu, x0, cancelY, ROW_STEP, ROWS_TEXT_SCALE)
  end
end

-- ------- wrap seam
--
-- Suppresses the vanilla `Menu:draw()`/`OptionsMenu:draw()` box+text
-- ONLY while `Options.enabled()` (checked LIVE, every call, not baked
-- in once at menu-open time -- so toggling PKDOOM MODE mid-menu, e.g.
-- from a row inside this very Options menu, takes effect immediately,
-- matching every other PKDOOM visual system's own "OFF changes
-- nothing" behavior) -- the real DOOM-styled draw happens separately,
-- from the outer `love.draw` wrap below, in this file's own dedicated
-- 320x200 virtual space rather than inside whichever transform
-- `Game:draw()` happens to have active while a Screen's own `:draw()`
-- runs (the classic 160x144-letterboxed one, confirmed by reading
-- `gen1recomp-dev/src/core/Game.lua:459-479` this round -- the wrong
-- space for a menu meant to read as DOOM's own real 320x200 UI).
-- FIX 2026-08-08 (user playtest report, screenshot 2): "has a white
-- background for some reason. it should be the world viewport behind
-- the menu just like the regular main menu." Root cause, confirmed by
-- reading source: `gen1recomp-dev/src/ui/OptionsMenu.lua:34` sets
-- `OptionsMenu.isOpaque = true` (a class-level field every instance
-- inherits) -- `Game:draw()` (`gen1recomp-dev/src/core/Game.lua`) reads
-- this via `StateStack:visibleBase()` to decide the index of the
-- highest OPAQUE state on the stack, and skips drawing everything
-- beneath it (including the overworld/3D world) entirely, clearing to
-- white instead -- real, vanilla `OptionsMenu` behavior (it draws its
-- own real full-screen box first, so this is intentional there).
-- `StartMenu`/`Menu.lua` carry no such field at all, which is why the
-- pause menu (screenshot 1) already showed the world correctly.
--
-- `pokedoomWasOpaque` snapshots whether THIS menu was really opaque in
-- its own real vanilla form (true only for `OptionsMenu`); the
-- `love.draw` wrap below then sets the LIVE `isOpaque` field every
-- frame, before the real `Game:draw()` runs, so PKDOOM MODE being on
-- forces it transparent (world shows through, matching the pause menu)
-- while OFF restores the real vanilla opaque white screen exactly --
-- checked live, not cached, matching every other PKDOOM visual system's
-- own "OFF changes nothing" rule.
-- `bottomLabel`: the real word drawn for the fixed extra row at the
-- bottom of a "rows" menu -- real `OptionsMenu` genuinely says "Cancel"
-- (`OptionsMenu.lua`'s own literal `"CANCEL"` bottom row), but this
-- mod's OWN "Doom Settings" screen (`lib/DoomSettingsMenu.lua`) uses
-- "Back" for that same real row instead (a nested screen returning to
-- its parent, not exiting the whole menu) -- stashed on the menu
-- instance itself (`pokedoomBottomLabel`) so `drawRows` below can stay
-- one shared function for both instead of forking a near-duplicate.
-- FIX 2026-08-11 -- real, reported bug: "no menu still exists, only the
-- yellow overlay... the normal menu from gen1recomp is impossible to
-- use" once PKDOOM MODE is on. Root cause: this skin's own `love.draw`
-- wrap (below) only draws real menu TEXT once the DOOM WAD is imported
-- (`loadPatch`/`DoomBigFont` both require `DoomWadImport.status.state
-- == "ready"`), but `menu.draw` here was unconditionally suppressed the
-- moment `Options.enabled()` was true, REGARDLESS of whether the skin
-- could actually render anything -- so a player with PKDOOM MODE on but
-- no WAD imported yet got the skin's own dim overlay and NOTHING else:
-- no skinned text (WAD not ready) AND no normal text (suppressed here).
-- A reskin should never leave the player with a LESS usable menu than
-- the unskinned original -- gated on WAD readiness so the real menu
-- renders normally until the skin can actually replace it.
-- FIX 2026-08-19, direct user request: "if you choose doom wad, it will
-- show the menus before gzdoom.pk3 is extracted. this shouldnt be the
-- case. both should need to be extracted before anything changes."
-- Previously checked `DoomWadImport.status.state` alone -- a real,
-- previously-noted-but-unfixed gap (this file's own earlier diagnostic
-- comment above already flagged it: "wadReady() alone gates the skin,
-- but BigUpper needs its OWN import too"). Renamed from `wadReady` to
-- `menuAssetsReady` to name what it actually checks now that it's both.
local function menuAssetsReady()
  return DoomWadImport.status.state == "ready" and DoomGZDoomImport.status.state == "ready"
end

-- DIAGNOSTIC 2026-08-19 -- real report: "the font doesnt show up in
-- pause menu" even after a confirmed-successful BigUpper import (436
-- glyphs, logged) -- per CLAUDE.md's own "log before a second guess"
-- rule, this logs the actual real gate values the very first time the
-- skinned `love.draw` path runs for a real menu, rather than guessing a
-- third time: whether a skinned menu is even found on the stack at all,
-- and the real live status of both real imports the skin now actually
-- requires (`menuAssetsReady()`, above -- at the time this diagnostic
-- was first added, the skin's own gate only checked `DoomWadImport`,
-- which is exactly what led to this report: the skin could draw with
-- every BigUpper glyph silently falling back to blank space whenever
-- the GZDoom font import hadn't finished yet. Fixed the same day, same
-- FIX note above `menuAssetsReady` -- kept here since this diagnostic
-- log line is still genuinely useful for any FUTURE gate-timing report).
local skinDiagLogged = false
local function skinDiagLog(fmt, ...)
  if skinDiagLogged then return end
  skinDiagLogged = true
  local ok, DoomLog = pcall(V.require, "DoomLog")
  if ok and DoomLog then
    pcall(DoomLog.event, "MENUSKIN", fmt, ...)
    pcall(DoomLog.flush)
  end
end

local function markSkin(menu, kind, bottomLabel)
  menu.pokedoomMenuSkin = kind
  menu.pokedoomBottomLabel = bottomLabel
  menu.pokedoomWasOpaque = (menu.isOpaque == true)
  if kind == "list" and menu.maxVisible then
    menu.maxVisible = math.max(menu.maxVisible, LIST_VISIBLE_CAP)
    if menu.clampScroll then menu:clampScroll() end
  end
  local originalDraw = menu.draw
  menu.draw = function(self)
    if Options.enabled() and menuAssetsReady() then return end
    originalDraw(self)
  end
  return menu
end

local startWrapped = false
local function wrapStartMenu()
  if startWrapped then return end
  local ok, StartMenu = pcall(require, "src.ui.StartMenu")
  if not (ok and StartMenu and StartMenu.new) then return end
  startWrapped = true
  local inner = StartMenu.new
  StartMenu.new = function(...)
    local menu = inner(...)
    if menu then markSkin(menu, "list") end
    return menu
  end
end

-- FIX 2026-08-08, generalized 2026-08-10 for `wrapDoomSettingsMenu`
-- below -- see `clampScrollFor`'s own header comment above for the full
-- root cause (the real `OptionRows.VISIBLE=4` module constant the
-- vanilla scroll math reads doesn't match this file's own actual
-- visible-row count). Chains through whatever real `:update` the class
-- already has FIRST (so vanilla scroll/input handling, and PKDOOM MODE
-- off, are both completely unaffected), then RECOMPUTES `self.scroll`
-- using this file's own real `ROWS_VISIBLE_CAP` only while the skin is
-- actually active. `lib/DoomSettingsMenu.lua`'s own `:update` calls the
-- exact same real `OptionRows.clampScroll` -- the identical desync bug
-- exists there too the moment it's skinned to show a different row
-- count, so it needs the identical fix, not a fresh one.
local function installRowsScrollFix(cls)
  local innerUpdate = cls.update
  if not innerUpdate then return end
  cls.update = function(self, ...)
    innerUpdate(self, ...)
    if Options.enabled() and self.pokedoomMenuSkin == "rows" then
      local rows = self.rows or {}
      local cancelRow = #rows + 1
      self.scroll = clampScrollFor(self.index, self.scroll or 0,
        #rows, cancelRow, ROWS_VISIBLE_CAP)
    end
  end
end

local optionsWrapped = false
local function wrapOptionsMenu()
  if optionsWrapped then return end
  local ok, OptionsMenu = pcall(require, "src.ui.OptionsMenu")
  if not (ok and OptionsMenu and OptionsMenu.new) then return end
  optionsWrapped = true
  local inner = OptionsMenu.new
  OptionsMenu.new = function(...)
    local menu = inner(...)
    if menu then markSkin(menu, "rows") end
    return menu
  end
  installRowsScrollFix(OptionsMenu)
end

-- FEATURE 2026-08-10 -- direct user request: apply the same real DOOM
-- rows skin to this mod's OWN "Doom Settings" screen. Same wrap shape
-- as `wrapOptionsMenu` above, against `lib/DoomSettingsMenu.lua`'s own
-- class instead of the base engine's `OptionsMenu` -- that file already
-- builds its own `.rows`/`.index`/`.scroll`/`.game` in the exact same
-- shape `drawRows` below already expects (it was deliberately modeled
-- on `OptionsMenu`'s own real fields for this reason), so no changes to
-- `drawRows` itself are needed beyond the `bottomLabel` param above.
local doomSettingsWrapped = false
local function wrapDoomSettingsMenu()
  if doomSettingsWrapped then return end
  if not (DoomSettingsMenu and DoomSettingsMenu.new) then return end
  doomSettingsWrapped = true
  local inner = DoomSettingsMenu.new
  DoomSettingsMenu.new = function(...)
    local menu = inner(...)
    if menu then markSkin(menu, "rows", "Back") end
    return menu
  end
  installRowsScrollFix(DoomSettingsMenu)
end

-- Whatever screen the real game engine currently has on top of its own
-- stack, if (and only if) it's one of the menus wrapped above.
local function currentSkinnedMenu()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.stack and Game.stack.top) then return nil end
  local okTop, top = pcall(function() return Game.stack:top() end)
  if okTop and top and top.pokedoomMenuSkin then return top end
  return nil
end

local installed = false
function DoomMenuSkin.install()
  if installed then return end
  installed = true
  wrapStartMenu()
  wrapOptionsMenu()
  wrapDoomSettingsMenu()

  -- Wrapping `love.draw` directly, the same real seam `lib/DoomHud.
  -- lua`'s own status bar already uses -- installed AFTER that file
  -- (see main.lua's own install order) so this menu skin layers ON
  -- TOP of the HUD, matching a real DOOM menu drawing over its own
  -- status bar.
  local innerDraw = love.draw
  love.draw = function(...)
    -- Live `isOpaque` toggle (see the FIX comment on `markSkin` above)
    -- MUST happen before `innerDraw(...)` runs -- that call chain is
    -- what reaches the real `Game:draw()`/`StateStack:visibleBase()`
    -- logic this is correcting.
    local menu = currentSkinnedMenu()
    -- Only logs once a real skinned menu is actually on the stack (not
    -- on the very first `love.draw` call from game boot, which would
    -- latch the one-shot immediately with "no menu found" and hide the
    -- moment that actually matters -- the player opening the menu).
    if menu then
      skinDiagLog("draw: menu=%s enabled=%s wadReady=%s gzState=%s",
        tostring(menu.pokedoomMenuSkin),
        tostring(Options.enabled()), tostring(DoomWadImport.status.state), tostring(DoomGZDoomImport.status.state))
    end
    -- FIX 2026-08-11 -- see `markSkin`'s own matching fix above: only
    -- force non-opaque (letting the paused game show through) when the
    -- skin is ACTUALLY going to draw over it -- otherwise this left the
    -- background see-through with nothing skinned drawn on top either,
    -- worse than the original opaque menu the player could at least read.
    if menu and menu.pokedoomWasOpaque then
      menu.isOpaque = not (Options.enabled() and menuAssetsReady())
    end
    if innerDraw then innerDraw(...) end
    if not (Options.enabled() and menuAssetsReady()) then return end
    if not menu then return end
    tickSkull(menu, love.timer and love.timer.getDelta() or 0)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    pcall(drawMenuDim, w, h)
    local scale, vox, voy = virtualScaleAndOffset(w, h)
    love.graphics.push()
    love.graphics.translate(vox, voy)
    love.graphics.scale(scale, scale)
    if menu.pokedoomMenuSkin == "list" then
      pcall(drawList, menu)
    elseif menu.pokedoomMenuSkin == "rows" then
      pcall(drawRows, menu)
    end
    love.graphics.pop()
    love.graphics.setColor(1, 1, 1, 1)
  end
end

return DoomMenuSkin
