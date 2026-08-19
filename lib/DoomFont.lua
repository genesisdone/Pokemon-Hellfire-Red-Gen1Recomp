-- PokeDoom Phase 16: DOOM's real HUD/message bitmap font -- a direct
-- port of `HUlib_drawTextLine` (`hu_lib.c:99-139`, read fresh at the
-- point of use per CLAUDE.md's hard rule), the exact function every
-- real DOOM on-screen text (pickup messages, chat, the automap title)
-- draws through. Replaces `lib/DoomHud.lua`'s own earlier stopgap (the
-- base engine's own Pokémon-style GB font, `src.render.Font`) -- see
-- phases/phase-16-pickup-text.md for the full audit this implements.
--
-- Two real, specific facts this file ports that the earlier stopgap
-- had no equivalent of:
--   1. DOOM's own message font is UPPERCASE ONLY -- `HUlib_drawTextLine`
--      calls `toupper()` on every character before drawing, confirmed
--      directly from source, not assumed. "Picked up a stimpack."
--      genuinely renders as "PICKED UP A STIMPACK." in real DOOM.
--   2. It's a PROPORTIONAL font -- each glyph advances by its OWN real
--      patch width (`w = SHORT(l->f[c-l->sc]->width); x += w`), not a
--      fixed per-character cell -- unlike the GB font this replaces,
--      which is fixed-width (a Game Boy tile-grid convention with no
--      DOOM equivalent).
--
-- Real lump family: `STCFN033`-`STCFN095` (`HU_Init`, hu_stuff.c:392-
-- 412 -- `sprintf(buffer,"STCFN%.3d",j++)` starting at `HU_FONTSTART =
-- '!'` = 33 through `HU_FONTEND = '_'` = 95, hu_stuff.h:30-34) -- 63
-- real patches, one per character, each with its own real `grAb`
-- offset the same way every other DOOM patch in this mod already has
-- (`DoomWadImport.loadSpriteAsset`, not the offset-blind `loadImage`).

local V = ...
local DoomWadImport = V.require("DoomWadImport")

local DoomFont = {}

-- Matches this mod's own established 320x200 virtual-canvas convention
-- (`lib/DoomHud.lua`'s own `VIRTUAL_W`) -- DOOM's real `SCREENWIDTH`,
-- what `HUlib_drawTextLine`'s own real clip check (`x+w > SCREENWIDTH`)
-- clips against.
local VIRTUAL_W = 320

local HU_FONTSTART, HU_FONTEND = 33, 95 -- '!'..'_'
local SPACE_ADVANCE = 4 -- HUlib_drawTextLine's own real fixed space/out-of-range advance

local glyphCache, lastWadState = {}, nil
local function loadGlyph(code)
  if DoomWadImport.status.state ~= lastWadState then
    lastWadState = DoomWadImport.status.state
    glyphCache = {}
  end
  if glyphCache[code] == nil then
    local value = false
    if lastWadState == "ready" then
      local ok, asset = pcall(DoomWadImport.loadSpriteAsset, ("STCFN%03d"):format(code))
      if ok and asset then value = asset end
    end
    glyphCache[code] = value
  end
  return glyphCache[code] or nil
end

-- Draws `text` at virtual-canvas pixel (x, y), DOOM's own real way:
-- uppercased, space/out-of-range chars advance a fixed 4px, every real
-- glyph draws its own patch (offset by its own real grAb `left`/`top`,
-- the same convention every other patch in this mod already follows)
-- and advances by its own real width, clipped at `VIRTUAL_W` the same
-- way real DOOM clips at `SCREENWIDTH`. Silently draws nothing if no
-- WAD is imported yet -- matching every other DOOM-asset consumer in
-- this mod, no crash, no placeholder text standing in for it. Returns
-- the pixel width actually drawn (mirroring `HUlib_drawTextLine`'s own
-- final cursor position minus its start, in case a future caller wants
-- to know how far it went, e.g. to draw something after it).
-- r/g/b/a: optional tint, defaulting to white (every existing caller's
-- own unchanged behavior) -- added 2026-08-07 for the killfeed message
-- (`lib/DoomHud.lua`'s own `drawMessage`, drawing the shared feed slot's
-- own `feedColor`), which needs to render in a distinct color from the
-- regular white pickup-message text.
-- scale: optional uniform size multiplier, defaulting to 1 (every
-- existing caller's own unchanged behavior) -- added 2026-08-08 for
-- `lib/DoomMenuSkin.lua`'s own menu text, which reads too small at 1x
-- against real DOOM's own reference menu screenshot (a rendering-
-- PARAMETER judgment call, not a re-derivable DOOM fact -- see
-- CLAUDE.md's own "Nature of the port" rule; real DOOM's own menu
-- items are pre-drawn word-graphics several times a hu_font glyph's
-- own size, so this port's substitute text needs its own explicit
-- size boost to carry comparable visual weight, not a 1:1 pixel
-- reproduction of a constant DOOM's source never actually specifies
-- for this purpose). Scales each glyph's own draw size AND its own
-- advance width uniformly, so proportional spacing is preserved at
-- any scale.
function DoomFont.draw(text, x, y, r, g, b, a, scale)
  if not text or DoomWadImport.status.state ~= "ready" then return 0 end
  scale = scale or 1
  text = text:upper()
  local cursorX = x
  for i = 1, #text do
    local code = text:byte(i)
    if code == 32 then -- space
      cursorX = cursorX + SPACE_ADVANCE * scale
      if cursorX >= VIRTUAL_W then break end
    elseif code >= HU_FONTSTART and code <= HU_FONTEND then
      local glyph = loadGlyph(code)
      if glyph then
        local w = glyph.image:getWidth() * scale
        if cursorX + w > VIRTUAL_W then break end
        love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
        love.graphics.draw(glyph.image, cursorX - glyph.left * scale, y - glyph.top * scale, 0, scale, scale)
        cursorX = cursorX + w
      else
        -- lump didn't decode -- skip it, same fixed advance as an
        -- out-of-range character, so a single missing glyph doesn't
        -- collapse every following character onto the same x.
        cursorX = cursorX + SPACE_ADVANCE * scale
      end
    else
      -- out-of-range character (lowercase already uppercased above, so
      -- this only reaches characters DOOM's own real font simply has no
      -- glyph for at all, e.g. certain punctuation) -- same fixed
      -- advance HUlib_drawTextLine's own real else-branch uses.
      cursorX = cursorX + SPACE_ADVANCE * scale
      if cursorX >= VIRTUAL_W then break end
    end
  end
  return cursorX - x
end

-- ADDED 2026-08-08 (Phase 20, DOOM pause menu skin) -- the same real
-- per-glyph width logic as `DoomFont.draw` above, without actually
-- drawing anything: lets a caller center text (a menu column, a title)
-- against its own real rendered width the same way `Menu.lua`'s own
-- vanilla box-fitting logic already does for gen1recomp's font, rather
-- than guessing a fixed column position. Real DOOM's own menus don't
-- need this (`M_Drawer`'s pre-drawn word-graphics are pre-sized), but
-- this mod's own menu content is dynamic gen1recomp text, not a fixed
-- DOOM patch, so measuring it before drawing is the equivalent this
-- port genuinely needs that the original never did.
-- scale: optional uniform size multiplier, defaulting to 1 -- see
-- `DoomFont.draw`'s own scale param above (added the same round, same
-- reason: `lib/DoomMenuSkin.lua` needs to center columns against text
-- it's ALSO drawing at a non-1x size).
function DoomFont.measure(text, scale)
  if not text or DoomWadImport.status.state ~= "ready" then return 0 end
  scale = scale or 1
  text = text:upper()
  local width = 0
  for i = 1, #text do
    local code = text:byte(i)
    if code == 32 then
      width = width + SPACE_ADVANCE
    elseif code >= HU_FONTSTART and code <= HU_FONTEND then
      local glyph = loadGlyph(code)
      width = width + (glyph and glyph.image:getWidth() or SPACE_ADVANCE)
    else
      width = width + SPACE_ADVANCE
    end
  end
  return width * scale
end

return DoomFont
