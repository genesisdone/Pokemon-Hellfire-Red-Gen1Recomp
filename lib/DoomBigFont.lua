-- PokeDoom: the real DOOM/GZDoom "BigUpper" menu font, decoded from the
-- player's own real GZDoom install (`lib/DoomGZDoomImport.lua`), not a
-- dev-only manual copy.
--
-- Why this file exists at all: the user compared this mod's pause menu
-- against a real GZDoom screenshot and found it used the wrong font --
-- `lib/DoomFont.lua`'s `hu_font` (STCFN033-095) is DOOM's real small
-- MESSAGE font (pickup text, chat), never used for menu items in any
-- real DOOM source. Real DOOM's own menu items are pre-drawn whole-word
-- graphics (`M_NGAME` etc, `m_menu.c:250-259`) with no reusable
-- character font behind them at all. GZDoom fills that real gap with its
-- own bundled font, "BigUpper", which is what the user's own reference
-- screenshot actually shows.
--
-- FIX 2026-08-19 -- this file previously decoded `zbigfont.lmp`
-- (ZDoom's FON2 binary format), which the user directly disputed with a
-- real GZDoom screenshot -- that file turned out to be `V_GetFont(
-- "BigFont")`'s own generic small fallback, not the real BigUpper the
-- game's own actual menu renders with (see `lib/DoomGZDoomImport.lua`'s
-- own header for the full re-investigation and root cause: the real
-- BigUpper lives in a completely different, previously-unchecked file,
-- `game_support.pk3`, as a folder of loose classic-DOOM-patch-format
-- `.lmp` files -- one per Unicode codepoint, e.g. `0041.lmp` = 'A' --
-- under GZDoom's own `filter/doom.id/fonts/bigupper/` per-IWAD-filter
-- convention). This file now decodes THAT real format instead: DOOM's
-- own `patch_t`, verified directly against `DOOM-master/linuxdoom-1.10/
-- r_defs.h:356-364` (header: width/height/leftoffset/topoffset, all
-- signed 16-bit, then `columnofs[width]`, 32-bit offsets to each
-- column's own post stream) and `r_data.c`'s own `R_DrawColumnInCache`
-- (r_data.c:184-218, the real, authoritative unpacking logic -- confirms
-- each post is `topdelta(u8) length(u8) pad(u8) data[length] pad(u8)`,
-- terminated by `topdelta == 0xFF`, and that MULTIPLE posts per column
-- are real and must be handled, not just one).
--
-- BigUpper's own glyphs are GRAYSCALE, not pre-colored -- confirmed
-- previously against the FON2 file's own bundled palette (every real
-- glyph-color entry had R=G=B, a genuine luminance ramp) -- carried
-- forward here as the working assumption for THIS format too, since
-- classic DOOM patches carry no palette of their own at all; each pixel
-- byte is an INDEX into the game's real PLAYPAL, read via the same
-- already-extracted `playpal.lmp` `lib/DoomWadImport.lua`'s own WAD
-- import already puts on disk (Locked Decision 5) -- not independently
-- re-verified this round that BigUpper's own specific palette-index
-- range is exactly gray in every real IWAD's PLAYPAL, only that treating
-- it as one (R channel as the luminance proxy) reproduces the same
-- established "Red" translation this project already tuned once before.
-- This matches GZDoom's own `wadsrc/static/menudef.txt:18`: `Font
-- "BigUpper", "Red"` -- GZDoom recolors this font at DRAW time via its
-- own translation-table system, which is also why the reference
-- screenshot shows red text, not gray.
--
-- BigUpper genuinely HAS distinct lowercase glyphs in this real format
-- (`0061.lmp` = 'a', confirmed present and a different, shorter real
-- shape than `0041.lmp` = 'A') -- unlike `zbigfont.lmp`'s own
-- uppercase-only 32-96 range, this file no longer forces `text:upper()`.

local V = ...
local DoomGZDoomImport = V.require("DoomGZDoomImport")
local DoomWadImport = V.require("DoomWadImport")

local DoomBigFont = {}

-- No real glyph exists for space (0x20) -- same real gap `hu_font` has,
-- same fallback shape (`lib/DoomFont.lua`'s own `SPACE_ADVANCE`), a fixed
-- advance rather than a real glyph. Also used as the fallback advance for
-- any OTHER codepoint this specific extracted set doesn't happen to cover.
local SPACE_ADVANCE = 12

local function readFileBytes(absPath)
  local ok, fp = pcall(io.open, absPath, "rb")
  if not (ok and fp) then return nil end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 0) then return nil end
  return bytes
end

-- Grayscale luminance -> a real GZDoom red. Tuned across two earlier
-- rounds against real screenshots (see git history / phase docs for the
-- original derivation against `gzdoom-master/wadsrc/static/
-- textcolors.txt`'s own published "Red" translation range, then darkened
-- a second time to match `hu_font`'s own real antialiasing depth) --
-- unchanged by this round's format switch, since the color SEMANTICS
-- (grayscale ramp meant to be recolored at draw time) are the same, only
-- where the raw gray value now comes from (real PLAYPAL instead of
-- FON2's own bundled palette) changed.
local RED_BRIGHT = { 0xC0, 0x10, 0x10 }
local RED_DARK = { 0x18, 0x00, 0x00 }
local function grayToRed(l)
  local t = l / 255
  return RED_DARK[1] + t * (RED_BRIGHT[1] - RED_DARK[1]),
         RED_DARK[2] + t * (RED_BRIGHT[2] - RED_DARK[2]),
         RED_DARK[3] + t * (RED_BRIGHT[3] - RED_DARK[3])
end

-- ------- DOOM's real PLAYPAL (768 bytes, 256 entries of raw R,G,B -- no
-- header at all, the simplest lump format in the whole game) -- read
-- once, from the same `playpal.lmp` `lib/DoomWadImport.lua`'s own WAD
-- import already extracts for every other DOOM-derived color lookup in
-- this project (Locked Decision 5). `palette[i]` is 0-indexed, matching
-- a raw patch pixel byte's own value directly.
local function decodePlaypal(bytes)
  if not (bytes and #bytes >= 768) then return nil end
  local palette = {}
  for i = 0, 255 do
    local p = i * 3 + 1
    palette[i] = { bytes:byte(p), bytes:byte(p + 1), bytes:byte(p + 2) }
  end
  return palette
end

-- ------- DOOM's real `patch_t` decoder (see this file's own header for
-- the exact source citations). `bytes:byte` is 1-based; every raw offset
-- read from the file (columnofs, a post's own topdelta-derived row) is
-- 0-based per the format's own real definition and converted once, at
-- the point it's used, rather than carrying two different indexing
-- conventions through the function.
local function i16le(bytes, p)
  local lo, hi = bytes:byte(p, p + 1)
  if not (lo and hi) then return nil end
  local v = lo + hi * 256
  if v >= 32768 then v = v - 65536 end
  return v
end

local function u32le(bytes, p)
  local b1, b2, b3, b4 = bytes:byte(p, p + 3)
  if not (b1 and b2 and b3 and b4) then return nil end
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Returns { width, height, topoffset, indices } where `indices` is
-- COLUMN-MAJOR (`indices[col*height + row + 1]`, matching every other
-- DOOM-derived patch-shaped asset in this mod), a nil entry meaning "no
-- post ever covered this pixel" -- i.e. genuinely transparent, the real
-- format's own convention (there is no dedicated transparent color
-- index; a gap is encoded by the ABSENCE of a post, not a special pixel
-- value). `topoffset` matters here specifically because this font's
-- real glyphs are NOT all the same height -- confirmed directly:
-- `0041.lmp` ('A') is 18x15 with topoffset=0, but `0061.lmp` ('a') and
-- `0067.lmp` ('g') are both 12-15px tall with topoffset=-3 -- real DOOM's
-- own `V_DrawPatch` (`v_video.c:219`: `y -= patch->topoffset`) is what
-- actually aligns glyphs of differing height to a shared baseline;
-- `DoomBigFont.draw` below applies that exact same real formula.
local function decodePatch(bytes)
  if not (bytes and #bytes >= 10) then return nil end
  local width = i16le(bytes, 1)
  local height = i16le(bytes, 3)
  local topoffset = i16le(bytes, 7) or 0
  if not (width and height and width > 0 and height > 0
           and width < 1024 and height < 1024) then
    return nil
  end

  local indices = {}
  local columnofsPos = 9 -- 1-based: byte 8 (0-based) is where columnofs[0] starts
  for col = 0, width - 1 do
    local ofsFieldPos = columnofsPos + col * 4
    local colOfs = u32le(bytes, ofsFieldPos)
    if colOfs then
      local pos = colOfs + 1 -- 0-based file offset -> 1-based Lua string index
      local guard = 0
      while pos and pos <= #bytes and guard < height * 4 + 16 do
        guard = guard + 1
        local topdelta = bytes:byte(pos)
        if not topdelta or topdelta == 0xFF then break end
        local length = bytes:byte(pos + 1)
        if not length then break end
        local dataStart = pos + 3 -- skip topdelta, length, and one pad byte
        for row = 0, length - 1 do
          local b = bytes:byte(dataStart + row)
          if b then
            local y = topdelta + row
            if y >= 0 and y < height then
              indices[col * height + y + 1] = b
            end
          end
        end
        pos = dataStart + length + 1 -- skip data + trailing pad byte, next post (if any)
      end
    end
  end

  return { width = width, height = height, topoffset = topoffset, indices = indices }
end

-- Builds one real `love.graphics.newImage` from a decoded glyph's own
-- column-major index buffer, resolving each raw palette-index byte
-- through the real PLAYPAL and recoloring via `grayToRed` (any pixel no
-- post ever covered stays fully transparent).
local function glyphToImage(glyph, palette)
  local width, height = glyph.width, glyph.height
  local pixels = {}
  for i = 1, width * height * 4 do pixels[i] = 0 end
  for col = 0, width - 1 do
    for row = 0, height - 1 do
      local idx = glyph.indices[col * height + row + 1]
      if idx then
        local rgb = palette[idx]
        if rgb then
          local r, g, b = grayToRed(rgb[1]) -- R channel as the luminance proxy
          local base = (row * width + col) * 4
          pixels[base + 1] = r
          pixels[base + 2] = g
          pixels[base + 3] = b
          pixels[base + 4] = 255
        end
      end
    end
  end
  local chars = {}
  for i = 1, #pixels do chars[i] = string.char(math.floor(pixels[i] + 0.5)) end
  local raw = table.concat(chars)
  local okData, imageData = pcall(love.image.newImageData, width, height, "rgba8", raw)
  if not (okData and imageData) then return nil end
  local okImg, image = pcall(love.graphics.newImage, imageData)
  if not okImg then return nil end
  return { image = image, width = width, height = height, topoffset = glyph.topoffset or 0 }
end

-- ------- glyph cache -- each codepoint's patch is read and decoded
-- lazily, the first time it's actually drawn, then kept for the rest of
-- the session (the same lazy-per-asset shape `DoomWadImport.loadImage`
-- already uses for every other DOOM-derived sprite in this project,
-- rather than the old FON2 version's single upfront whole-font decode --
-- there's no directory listing available at draw time to decode
-- everything up front any more, and there's no need to). Invalidated if
-- either real dependency's own import status changes mid-session (a
-- fresh WAD or GZDoom import).

local cachedGZState, cachedWadState = nil, nil
local playpalCache = nil
local imageCache = {}

-- DIAGNOSTIC -- kept from the previous investigation (CLAUDE.md's own
-- "log before a second guess" rule) since this is exactly the kind of
-- runtime-only gap ("says ready but nothing renders") that already
-- happened once before with the old format.
local diagLogged = false
local function diagLog(fmt, ...)
  if diagLogged then return end
  local ok, DoomLog = pcall(V.require, "DoomLog")
  if ok and DoomLog then
    pcall(DoomLog.event, "BIGFONT", fmt, ...)
    pcall(DoomLog.flush)
  end
end

-- FIX 2026-08-19 -- real report: "it looks like the font is here now,
-- but only after a restart. it shouldnt take a restart." Root cause:
-- this invalidation check used to live ONLY inside `ensurePalette`,
-- which `getGlyph` (below) only ever calls AFTER already checking
-- `imageCache[codepoint]` and returning early on any hit -- including a
-- cached `false` ("no glyph") from a codepoint drawn even ONCE before
-- the GZDoom import finished (trivially likely: the very first frame the
-- Options menu opens, before the player has picked a file, already
-- tries to draw "OPTIONS" and every row label). Once cached as `false`,
-- that codepoint's own early-return in `getGlyph` never reached this
-- function again for the rest of the session, so the cache could never
-- self-heal after a later, successful import -- only a fresh process
-- (an empty `imageCache`) ever saw it. Split out so `getGlyph` can run
-- this check UNCONDITIONALLY, before it ever consults its own cache.
local function invalidateIfStateChanged()
  if DoomGZDoomImport.status.state ~= cachedGZState
     or DoomWadImport.status.state ~= cachedWadState then
    cachedGZState = DoomGZDoomImport.status.state
    cachedWadState = DoomWadImport.status.state
    playpalCache = nil
    imageCache = {}
  end
end

local function ensurePalette()
  invalidateIfStateChanged()
  if playpalCache then return playpalCache end
  if DoomGZDoomImport.status.state ~= "ready" then
    diagLog("ensurePalette: DoomGZDoomImport.status.state=%s (not ready)", tostring(DoomGZDoomImport.status.state))
    return nil
  end
  if DoomWadImport.status.state ~= "ready" then
    diagLog("ensurePalette: DoomWadImport.status.state=%s (not ready -- BigUpper needs the real PLAYPAL too)", tostring(DoomWadImport.status.state))
    return nil
  end
  local playpalPath = DoomWadImport.findAsset("playpal")
  if not playpalPath then
    diagLog("ensurePalette: DoomWadImport.findAsset('playpal') returned nil")
    return nil
  end
  local bytes = readFileBytes(playpalPath)
  local palette = decodePlaypal(bytes)
  if not palette then
    diagLog("ensurePalette: decodePlaypal FAILED for %s (bytes=%s)", tostring(playpalPath), tostring(bytes and #bytes))
    return nil
  end
  playpalCache = palette
  return palette
end

local function getGlyph(codepoint)
  invalidateIfStateChanged()
  local hit = imageCache[codepoint]
  if hit ~= nil then
    return hit or nil
  end
  local value = false
  local reason = nil
  local palette = ensurePalette()
  if palette then
    local path = DoomGZDoomImport.glyphPath(codepoint)
    local bytes = path and readFileBytes(path)
    if bytes then
      local ok, patch = pcall(decodePatch, bytes)
      if ok and patch then
        local okImg, image = pcall(glyphToImage, patch, palette)
        if okImg and image then
          value = image
        else
          reason = ("glyphToImage FAILED ok=%s result=%s"):format(tostring(okImg), tostring(image))
        end
      else
        reason = ("decodePatch FAILED ok=%s result=%s"):format(tostring(ok), tostring(patch))
      end
    else
      reason = "no glyph file on disk for codepoint " .. tostring(codepoint) .. " (" .. tostring(path) .. ")"
    end
  else
    reason = "ensurePalette() returned nil"
  end
  if not diagLogged then
    diagLogged = true
    diagLog("getGlyph(%d %q): %s", codepoint, string.char(codepoint), value and "OK" or ("FAILED -- " .. tostring(reason)))
  end
  imageCache[codepoint] = value
  return value or nil
end

function DoomBigFont.draw(text, x, y, r, g, b, a, scale)
  if not text then return 0 end
  scale = scale or 1
  local cursorX = x
  for i = 1, #text do
    local code = text:byte(i)
    if code == 32 then
      cursorX = cursorX + SPACE_ADVANCE * scale
    else
      local glyph = getGlyph(code)
      if glyph then
        love.graphics.setColor(r or 1, g or 1, b or 1, a or 1)
        -- real DOOM's own `V_DrawPatch` (v_video.c:219): `y -=
        -- patch->topoffset` -- aligns glyphs of differing height (e.g.
        -- 15px 'A', topoffset=0, vs 12px 'a', topoffset=-3) to a shared
        -- baseline instead of all flush-topping the same row `y`.
        love.graphics.draw(glyph.image, cursorX, y - glyph.topoffset * scale, 0, scale, scale)
        cursorX = cursorX + glyph.width * scale
      else
        cursorX = cursorX + SPACE_ADVANCE * scale
      end
    end
  end
  return cursorX - x
end

function DoomBigFont.measure(text, scale)
  if not text then return 0 end
  scale = scale or 1
  local width = 0
  for i = 1, #text do
    local code = text:byte(i)
    if code == 32 then
      width = width + SPACE_ADVANCE
    else
      local glyph = getGlyph(code)
      width = width + (glyph and glyph.width or SPACE_ADVANCE)
    end
  end
  return width * scale
end

return DoomBigFont
