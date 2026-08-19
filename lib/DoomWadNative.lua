-- PokeDoom: a native, pure-Lua DOOM WAD extractor -- replaces the
-- external `wadext.exe` (github.com/coelckers/wadext, this checkout's
-- sibling `wadext-master/`) this mod used to shell out to. Requested
-- 2026-08-19, direct user instruction: "i want native wad extraction
-- without any new applications attached for universal support. look at
-- how wad extraction works from wadext source code and see if you can
-- implement it." `wadext.exe` needed a one-time C++ compile (CMake + a
-- real C++ toolchain, `scripts/dev-launch.ps1`'s own real build step) --
-- a genuine per-machine setup cost and failure point ("CMake is not
-- installed," "no C++ compiler found") this file removes entirely: every
-- algorithm below is read directly from wadext's own real source and
-- restated in Lua, so extraction now needs nothing beyond this mod's own
-- Lua/LÖVE runtime, on any platform LÖVE itself already runs on.
--
-- Every format/algorithm here is cited against the exact wadext source
-- it was read from, not guessed or reimplemented from memory of "how
-- DOOM WADs generally work" -- this mirrors CLAUDE.md's own "DOOM facts
-- come from the source" hard rule, applied to wadext's own source
-- (itself already a real, independent, open-source reference this
-- project has never edited) instead of linuxdoom-1.10 this time, since
-- the WAD/patch/flat/DMX *file formats* -- as opposed to DOOM's own
-- *gameplay* logic -- are exactly what wadext exists to document in
-- working code.
--
-- Deliberately narrower in SCOPE than wadext itself, matching what this
-- mod's own consumers actually read (`DoomWadImport.findAsset`/
-- `.loadImage`/`.loadSpriteAsset`/`.loadSound`, used for sprites, menu
-- graphics, and sound effects only -- see Locked Decision 5 in
-- CLAUDE.md): converts real DOOM patches (sprites, menu graphics, HUD
-- digits, ...) to PNG and DMX sounds to WAV, exactly like wadext's own
-- default behavior; copies everything else through as a raw binary lump
-- with its real WAD lump name (PLAYPAL, COLORMAP, GENMIDI, ENDOOM, raw
-- map data, etc.) -- ready for a future consumer to read, matching
-- wadext's own real fallback ("`Extract`'s final `else` branch, wadext.
-- cpp:160-173: an unrecognized lump is just written out verbatim").
-- Deliberately SKIPPED, since nothing in this project reads them and
-- wadext's own real handling for them (`ExtractWad`, wadext.cpp:551-647)
-- is real extra machinery this mod has no consumer for: GL nodes
-- (GL_VERT/SEGS/SSECT/NODES/PVS), full map lump groups (THINGS through
-- BLOCKMAP/BEHAVIOR/SCRIPTS -- classic DOOM levels aren't rendered by
-- this engine at all), and TEXTURE1/TEXTURE2+PNAMES wall-texture
-- compositing (real, but Phase 19's own DOOM texture reskin, the one
-- feature that would consume it, is still "audited, not started" per
-- PHASE-PROGRESS.md). Flats (F_START/F_END, `FlatToPng`) ARE
-- implemented despite having no current consumer either, since Phase 19
-- explicitly names them as a future need and the conversion itself is
-- simple -- cheap to keep correct now rather than re-deriving later.
--
-- No fallback palette is embedded here for a WAD with no `PLAYPAL` lump
-- (wadext's own `GetPalette`, convert.cpp:291-309, falls back to a
-- literal hardcoded copy of id Software's own DOOM palette bytes) --
-- deliberately, per CLAUDE.md's own Locked Decision 5 ("this mod ships
-- none of id Software's DOOM assets, ever"): every real IWAD (doom.wad,
-- doom1.wad, doom2.wad, tnt.wad, plutonia.wad) already ships its own
-- real PLAYPAL lump, so this fallback would only ever matter for an
-- abnormal/corrupt file -- not worth shipping id's own palette bytes
-- pre-emptively to cover a case a real IWAD never actually hits.
-- Extraction just fails with a clear error instead if PLAYPAL is
-- missing.

local V = ...

local DoomWadNative = {}

-- ------- small binary helpers (1-based Lua string indexing throughout,
-- matching every other binary-format decoder already in this project --
-- `lib/DoomBigFont.lua`'s own `i16le`/`u32le` restated here rather than
-- shared, same reasoning `DoomGZDoomImport.lua` already gives for
-- duplicating small helpers instead of adding cross-file coupling for a
-- handful of lines.)

local function u8(bytes, p) return bytes:byte(p) end

local function u16le(bytes, p)
  local lo, hi = bytes:byte(p, p + 1)
  if not (lo and hi) then return nil end
  return lo + hi * 256
end

local function i32le(bytes, p)
  local b1, b2, b3, b4 = bytes:byte(p, p + 3)
  if not (b1 and b2 and b3 and b4) then return nil end
  local v = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
  if v >= 0x80000000 then v = v - 0x100000000 end
  return v
end

local function u32le(bytes, p)
  local v = i32le(bytes, p)
  if v and v < 0 then v = v + 0x100000000 end
  return v
end

local function i16le(bytes, p)
  local lo, hi = bytes:byte(p, p + 1)
  if not (lo and hi) then return nil end
  local v = lo + hi * 256
  if v >= 32768 then v = v - 65536 end
  return v
end

-- Big-endian u32, packed into a 4-byte Lua string -- every multi-byte
-- integer field inside a PNG chunk (length, and this mod's own grAb
-- payload) is big-endian, per the PNG spec (unlike every WAD/patch/DMX
-- field above, which are all real little-endian DOS-era formats).
local function u32be(n)
  n = n % 0x100000000
  local b4 = n % 256; n = (n - b4) / 256
  local b3 = n % 256; n = (n - b3) / 256
  local b2 = n % 256; n = (n - b2) / 256
  local b1 = n % 256
  return string.char(b1, b2, b3, b4)
end

-- ------- CRC32 (the real, standard IEEE 802.3 / zlib / PNG polynomial,
-- 0xEDB88320) -- needed only to compute the grAb chunk's own CRC (PNG's
-- pixel data itself is written by `love.image.ImageData:encode("png")`,
-- LÖVE's own real encoder -- this project has no reason to hand-write a
-- DEFLATE/zlib compressor when the engine already ships one; only the
-- ONE custom ancillary chunk wadext's own consumers (`DoomWadImport.
-- readGrabOffset`) expect needs to be built by hand, and a PNG chunk's
-- own CRC covers exactly the chunk type + data bytes, per the PNG spec).
-- LuaJIT (this engine's real runtime, confirmed already in use elsewhere
-- in this mod via `require("ffi")`, `lib/DoomGZDoomImport.lua`) has no
-- native bitwise operators (that's Lua 5.3+ syntax) -- it ships the
-- standard `bit` library instead (`bit.bxor`/`.band`/`.rshift`), used
-- here rather than a native `~`/`>>` this runtime can't parse at all.
local bit = require("bit")

local crcTable
local function buildCrcTable()
  crcTable = {}
  for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
      if bit.band(c, 1) == 1 then
        c = bit.bxor(0xEDB88320, bit.rshift(c, 1))
      else
        c = bit.rshift(c, 1)
      end
    end
    crcTable[n] = c
  end
end

local function crc32(str)
  if not crcTable then buildCrcTable() end
  local crc = 0xFFFFFFFF
  for i = 1, #str do
    local byte = str:byte(i)
    crc = bit.bxor(crcTable[bit.band(bit.bxor(crc, byte), 0xFF)], bit.rshift(crc, 8))
  end
  return bit.tobit(bit.bxor(crc, 0xFFFFFFFF)) % 0x100000000
end

-- ------- PNG writer
--
-- `rgba` is a plain Lua string of `width*height*4` bytes, row-major,
-- exactly what `love.image.newImageData(w, h, "rgba8", rgba)` expects
-- (this project's own already-proven convention -- `lib/DoomBigFont.lua`'s
-- `glyphToImage` builds an identical buffer the same way). LÖVE's own
-- `ImageData:encode("png")` does the real PNG/DEFLATE encoding; the only
-- hand-built part is inserting a `grAb` ancillary chunk (leftoffset/
-- topoffset, wadext's own `WritePNG`, convert.cpp:464-541: "if (leftofs
-- != 0 || topofs != 0) M_AppendPNGChunk(..., 'grAb', ...)") right after
-- the mandatory `IHDR` chunk -- `DoomWadImport.lua`'s own `readGrabOffset`
-- already scans for this exact chunk name/payload shape (2 big-endian
-- int32s) anywhere before `IDAT`/`IEND`, so this only needs to produce a
-- byte-valid chunk, not match wadext's exact chunk ORDER beyond "before
-- IDAT." Per the PNG spec, `IHDR` is ALWAYS the first chunk, immediately
-- after the 8-byte signature, and is always exactly 13 bytes of payload
-- (25 bytes total: 4 length + 4 "IHDR" + 13 data + 4 CRC) -- so byte
-- offset 8+25=33 (0-based) is always the position right after it,
-- unconditionally, for ANY spec-compliant encoder's output (LÖVE's
-- included) -- no general chunk-scanning needed to find the insertion
-- point.
local function buildGrabChunk(leftoffset, topoffset)
  local chunkType = "grAb"
  local payload = u32be(leftoffset) .. u32be(topoffset)
  local length = u32be(#payload)
  local crc = u32be(crc32(chunkType .. payload))
  return length .. chunkType .. payload .. crc
end

local function writePng(path, rgba, width, height, leftoffset, topoffset)
  local okData, imageData = pcall(love.image.newImageData, width, height, "rgba8", rgba)
  if not (okData and imageData) then
    return false, "love.image.newImageData failed"
  end
  local okEnc, fileData = pcall(imageData.encode, imageData, "png")
  if not (okEnc and fileData) then
    return false, "ImageData:encode(png) failed"
  end
  local okStr, pngBytes = pcall(fileData.getString, fileData)
  if not (okStr and type(pngBytes) == "string") then
    return false, "FileData:getString failed"
  end

  if leftoffset ~= 0 or topoffset ~= 0 then
    -- Signature (8) + IHDR chunk (4 length + 4 type + 13 data + 4 crc = 25) = 33.
    if #pngBytes >= 33 and pngBytes:sub(13, 16) == "IHDR" then
      local grab = buildGrabChunk(leftoffset, topoffset)
      pngBytes = pngBytes:sub(1, 33) .. grab .. pngBytes:sub(34)
    end
    -- If IHDR isn't exactly there (LÖVE's encoder output shape changed
    -- underneath this some future version), the PNG is still written,
    -- just without a grAb chunk -- a missing sprite OFFSET, not a
    -- missing sprite, and `readGrabOffset` already treats that as "0,0"
    -- rather than erroring.
  end

  local okOpen, fp = pcall(io.open, path, "wb")
  if not (okOpen and fp) then return false, "could not open " .. tostring(path) end
  local okWrite = pcall(fp.write, fp, pngBytes)
  pcall(fp.close, fp)
  if not okWrite then return false, "could not write " .. tostring(path) end
  return true
end

-- ------- WAV writer
--
-- Real DMX sound format (`isDoomSound`, wadext's fileformat.cpp:327-333,
-- and `DoomSoundHead`/`DoomSndToWav`, convert.cpp:708-768): an 8-byte
-- header -- u16 format (always 3), u16 sample rate, u16 sample count,
-- u16 reserved(usually 0, but genuinely part of a real 32-bit sample
-- count per `isDoomSound`'s own `GetInt(data+4)` 32-bit read; the header
-- fields are read separately here only because the raw PCM data that
-- follows doesn't depend on that count at all -- it's simply "everything
-- after the 8-byte header") -- followed by that many raw UNSIGNED 8-bit
-- PCM samples, mono. wadext's own `DoomSndToWav` does no trimming of the
-- format's own well-known leading/trailing pad sample -- copies
-- `length-8` bytes verbatim -- restated identically here for exact
-- parity rather than adding unverified "cleverness" wadext itself
-- doesn't do.
local function buildWavHeader(sampleRate, dataSize)
  local byteRate = sampleRate -- mono, 8-bit: bytesPerSecond == sampleRate
  local function u32le_(n)
    n = n % 0x100000000
    local b1 = n % 256; n = (n - b1) / 256
    local b2 = n % 256; n = (n - b2) / 256
    local b3 = n % 256; n = (n - b3) / 256
    local b4 = n % 256
    return string.char(b1, b2, b3, b4)
  end
  local function u16le_(n)
    n = n % 65536
    local b1 = n % 256
    local b2 = (n - b1) / 256
    return string.char(b1, b2)
  end
  return table.concat({
    "RIFF", u32le_(dataSize + 36), "WAVE",
    "fmt ", u32le_(16), u16le_(1), u16le_(1), u32le_(sampleRate), u32le_(byteRate),
    u16le_(1), u16le_(8),
    "data", u32le_(dataSize),
  })
end

local function isDoomSound(bytes)
  if not (bytes and #bytes >= 8) then return false end
  if bytes:byte(1) ~= 3 or bytes:byte(2) ~= 0 then return false end
  local dmxlen = u32le(bytes, 5)
  return dmxlen ~= nil and dmxlen <= (#bytes - 8)
end

local function writeWav(path, bytes)
  local sampleRate = u16le(bytes, 3) or 11025
  local dataSize = #bytes - 8
  if dataSize < 0 then return false, "sound lump too short" end
  local header = buildWavHeader(sampleRate, dataSize)
  local okOpen, fp = pcall(io.open, path, "wb")
  if not (okOpen and fp) then return false, "could not open " .. tostring(path) end
  local okW1 = pcall(fp.write, fp, header)
  local okW2 = okW1 and pcall(fp.write, fp, bytes:sub(9))
  pcall(fp.close, fp)
  if not (okW1 and okW2) then return false, "could not write " .. tostring(path) end
  return true
end

-- ------- DOOM patch format (sprites, menu graphics, HUD digits, ...)
--
-- `patch_t` header, verified against real DOOM source
-- (`DOOM-master/linuxdoom-1.10/r_defs.h:356-364`) during this same
-- project's own earlier BigUpper font work, and against wadext's own
-- copy (`fileformat.h:77-85`, byte-identical): width/height/leftoffset/
-- topoffset (all i16), then `columnofs[width]` (u32 each, byte offset
-- from the START of the patch to that column's own post stream).
--
-- `isPatch` (structural validator, restated from wadext's own real
-- detector, fileformat.cpp:54-87 -- NOT the simpler "just check length
-- and header sanity" version this project's OWN BigFont decoder used
-- for a known-good, hand-picked font glyph set): a lump is only treated
-- as a real patch if EVERY column offset points inside the lump, and at
-- least one column starts exactly where the column-offset table itself
-- ends -- this is what lets `IdentifyFileType` tell a real patch apart
-- from an arbitrary binary lump (PLAYPAL, a raw flat, DMXGUS, ...) that
-- merely happens to start with plausible-looking small numbers.
local function isPatch(bytes)
  if not (bytes and #bytes >= 13) then return false end
  local width = u16le(bytes, 1)
  local height = u16le(bytes, 3)
  local leftoffset = i16le(bytes, 5)
  local topoffset = i16le(bytes, 7)
  if not (width and height and leftoffset and topoffset) then return false end
  if not (height <= 4096 and width <= 4096 and width < #bytes / 4
          and math.abs(leftoffset) < 4096 and math.abs(topoffset) < 4096) then
    return false
  end
  local gapAtStart = true
  for x = 0, width - 1 do
    local ofs = u32le(bytes, 9 + x * 4)
    if not ofs then return false end
    if ofs == width * 4 + 8 then
      gapAtStart = false
    elseif ofs >= #bytes then
      return false
    end
  end
  return not gapAtStart
end

-- `IsHack` (wadext's own real name, convert.cpp:589-619): a known,
-- documented corruption some real vanilla DOOM patches have -- a 256-
-- pixel-tall column whose own post-length byte (a real `uint8_t`, max
-- 255) cannot represent 256, so those patches store `length=0` and rely
-- on a non-standard "read exactly `height` raw bytes anyway" convention
-- instead of the normal post-run encoding. `topdelta`/`length` both
-- being 0, with the very next post immediately signaling end-of-column
-- (`0xFF`), for EVERY column, is real DOOM's own way of flagging this
-- specific edge case -- restated exactly, not simplified, since a false
-- negative here would silently decode one of these patches as a blank
-- (all `length=0` posts) image instead of its real pixels.
local function isHackPatch(bytes, width, height)
  if height ~= 256 then return false end
  for x = 0, width - 1 do
    local colOfs = u32le(bytes, 9 + x * 4)
    if not colOfs then return false end
    local pos = colOfs + 1
    local topdelta = bytes:byte(pos)
    local length = bytes:byte(pos + 1)
    if not (topdelta == 0 and length == 0) then return false end
    local nextPos = pos + 256 + 4
    if bytes:byte(nextPos) ~= 0xFF then return false end
  end
  return true
end

-- Decodes a real DOOM patch into a row-major RGBA8 Lua string (matching
-- `love.image.newImageData`'s own expected layout, and wadext's own
-- `PatchToPng`, convert.cpp:621-705, restated field-for-field including
-- the real "tall patch" cumulative-topdelta compatibility rule
-- (`if (column->topdelta <= top) top += column->topdelta; else top =
-- column->topdelta;`, convert.cpp:667-674) -- a normal patch's own
-- topdelta values are always strictly increasing down a column, which
-- always takes the `else` branch (`top = topdelta` -- identical to this
-- project's own earlier, simpler BigFont decoder), but some real WADs
-- use column heights beyond 254px via a "DeePsea tall patch" convention
-- where topdelta values ENCODE A DELTA on top of the running total
-- instead of an absolute row -- silently wrong output for THOSE patches
-- without this exact real rule.
local function decodePatch(bytes, palette)
  local width = u16le(bytes, 1)
  local height = u16le(bytes, 3)
  local leftoffset = i16le(bytes, 5)
  local topoffset = i16le(bytes, 7)
  if not (width and height and width > 0 and height > 0) then return nil end

  local pixels = {}
  for i = 1, width * height * 4 do pixels[i] = 0 end -- alpha=0 everywhere by default (transparent)

  local function setPixel(x, y, colorIndex)
    if x < 0 or x >= width or y < 0 or y >= height then return end
    local rgb = palette[colorIndex]
    if not rgb then return end
    local base = (y * width + x) * 4
    pixels[base + 1] = rgb[1]
    pixels[base + 2] = rgb[2]
    pixels[base + 3] = rgb[3]
    pixels[base + 4] = 255
  end

  if isHackPatch(bytes, width, height) then
    for x = 0, width - 1 do
      local colOfs = u32le(bytes, 9 + x * 4)
      local dataStart = colOfs + 1 + 3 -- skip topdelta(1)+length(1)+pad(1)
      for y = 0, height - 1 do
        local b = bytes:byte(dataStart + y)
        if b then setPixel(x, y, b) end
      end
    end
  else
    local maxPos = #bytes - 2 -- wadext's own `maxcol = patch + length - 3` (0-based); +1 for Lua's 1-based indexing
    for x = 0, width - 1 do
      local colOfs = u32le(bytes, 9 + x * 4)
      if colOfs then
        local pos = colOfs + 1
        local top = -1
        while pos <= maxPos do
          local topdelta = bytes:byte(pos)
          if not topdelta or topdelta == 0xFF then break end
          if topdelta <= top then
            top = top + topdelta
          else
            top = topdelta
          end
          local len = bytes:byte(pos + 1) or 0
          if top + len > height then len = height - top end
          if len > 0 then
            local dataStart = pos + 3
            for i = 0, len - 1 do
              local b = bytes:byte(dataStart + i)
              if b then setPixel(x, top + i, b) end
            end
          end
          pos = pos + (bytes:byte(pos + 1) or 0) + 4
        end
      end
    end
  end

  local chars = {}
  for i = 1, #pixels do chars[i] = string.char(pixels[i]) end
  return table.concat(chars), width, height, leftoffset, topoffset
end

-- ------- DOOM flat format (floor/ceiling textures -- no header at all,
-- just a raw indexed bitmap; real dimensions have to be INFERRED from
-- the lump's own byte length, restated exactly from wadext's own real
-- table, `FlatToPng`, convert.cpp:544-559, "the same logic as ZDoom,
-- except for the 320x200 case which is for Raven's fullscreen images").
-- Not currently consumed by any code in this mod (see this file's own
-- header) -- implemented anyway since Phase 19 (the DOOM texture
-- reskin) already names flats as a real future need, and the conversion
-- itself is simple.
local FLAT_DIMENSIONS = {
  [64 * 64] = { 64, 64 },
  [8 * 8] = { 8, 8 },
  [16 * 16] = { 16, 16 },
  [32 * 32] = { 32, 32 },
  [128 * 128] = { 128, 128 },
  [256 * 256] = { 256, 256 },
  [64000] = { 320, 200 },
}

local function decodeFlat(bytes, palette)
  local dims = FLAT_DIMENSIONS[#bytes] or { 64, 64 }
  local width, height = dims[1], dims[2]
  local pixels = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local idx = bytes:byte(x + y * width + 1)
      local rgb = (idx and palette[idx]) or { 0, 0, 0 }
      local base = (y * width + x) * 4
      pixels[base + 1] = rgb[1]
      pixels[base + 2] = rgb[2]
      pixels[base + 3] = rgb[3]
      pixels[base + 4] = 255
    end
  end
  local chars = {}
  for i = 1, #pixels do chars[i] = string.char(pixels[i]) end
  return table.concat(chars), width, height
end

-- ------- PLAYPAL (DOOM's real palette lump -- 256 entries of raw R,G,B,
-- no header, confirmed byte-for-byte during this project's own BigUpper
-- font work this same session; `lib/DoomBigFont.lua`'s own
-- `decodePlaypal` restated here since that file only ever reads it from
-- an ALREADY-extracted `playpal.lmp` on disk, whereas this file needs it
-- from the WAD's own in-memory lump bytes, before anything is written
-- out at all).
local function decodePlaypal(bytes)
  if not (bytes and #bytes >= 768) then return nil end
  local palette = {}
  for i = 0, 255 do
    local p = i * 3 + 1
    palette[i] = { bytes:byte(p), bytes:byte(p + 1), bytes:byte(p + 2) }
  end
  return palette
end

-- ------- output path helpers
--
-- FIX 2026-08-19 -- REAL ROOT CAUSE of "i don't see any of the assets
-- show up... are they actually importing at all": this function used to
-- shell out (`New-Item`/`mkdir -p`) against `outputDir()`'s own path --
-- a real OS directory, genuinely created -- while every actual per-file
-- write immediately below it goes through plain `io.open`, this engine's
-- own SANDBOXED version for mod code, which redirects that exact same
-- path string into this mod's own separate, real, writable "compat
-- overlay" storage instead (confirmed directly on disk: every one of the
-- 1883 lumps a real extraction wrote landed under `mod_compat/POKEDOOM/
-- mods/POKEDOOM/assets/generated/doom/`, not the real absolute path a
-- shell command resolves the same string to -- the exact same real
-- mechanism `lib/DoomLog.lua`'s own writes already ride, successfully,
-- this whole project). The shell-created folder was real but empty, and
-- everything that later LOOKED for these files there (a shell `dir`/
-- `find` in `lib/DoomWadImport.lua`'s own `assetList`/
-- `outputDirHasFiles`, fixed the same round) also came up empty for the
-- identical reason. `love.filesystem.createDirectory` is the one that
-- actually agrees with where `io.open`'s own writes really go.
local function ensureDir(dir)
  pcall(love.filesystem.createDirectory, dir)
end

-- Lowercases and sanitizes a raw WAD lump name (up to 8 bytes, NUL-
-- padded, occasionally containing a real special character wadext's own
-- `MakeFileName`, wadext.cpp:74-101, escapes for path-safety) into a
-- real filesystem-safe filename base -- same escapes, restated.
local SPECIAL_CHARS = {
  ["\\"] = "^", ["/"] = "\xA7", [":"] = "\xA1", ["*"] = "\xB2", ["?"] = "\xBF",
}
local function sanitizeName(name)
  name = name:gsub("%z", "") -- trim NUL padding
  name = name:gsub(".", function(c) return SPECIAL_CHARS[c] end)
  return name:lower()
end

-- Collision-safe file writer: if `path` already exists, tries
-- `path(1)`, `path(2)`, ... -- restated from wadext's own real
-- `MakeFileName` loop (wadext.cpp:92-100), since this project's own
-- flattened category folders (see this file's own header: "PATCHES/"
-- covers what wadext itself splits across several real subfolders) make
-- a genuine same-name collision somewhat more likely here than in
-- wadext's own output shape.
local function uniquePath(dir, base, ext)
  local path = dir .. "/" .. base .. ext
  local n = 0
  while true do
    local ok, fp = pcall(io.open, path, "rb")
    if ok and fp then pcall(fp.close, fp) end
    if not (ok and fp) then return path end
    n = n + 1
    path = dir .. "/" .. base .. "(" .. n .. ")" .. ext
  end
end

-- ------- WAD directory parsing
--
-- Real WAD header (confirmed against this project's own already-
-- extracted knowledge of the format, and matching wadext's own
-- `FWadFile::Open` reading, wadfile.cpp): magic(4, already validated by
-- `DoomWadImport.validateHeader` before this ever runs) + numlumps
-- (i32 LE) + infotableofs (i32 LE). Each directory entry (16 bytes):
-- filepos (i32 LE, byte offset into the WAD), size (i32 LE), name
-- (8 bytes, NUL-padded, not necessarily NUL-terminated if exactly 8
-- real characters long).
local function parseDirectory(bytes)
  local numlumps = i32le(bytes, 5)
  local infotableofs = i32le(bytes, 9)
  if not (numlumps and infotableofs and numlumps > 0 and numlumps < 200000) then
    return nil, "bad WAD header (numlumps/infotableofs out of range)"
  end
  local lumps = {}
  for i = 0, numlumps - 1 do
    local entryPos = infotableofs + i * 16 + 1
    local filepos = i32le(bytes, entryPos)
    local size = i32le(bytes, entryPos + 4)
    local rawName = bytes:sub(entryPos + 8, entryPos + 15)
    if not (filepos and size) then
      return nil, ("directory entry %d out of range"):format(i)
    end
    local name = rawName:gsub("%z.*$", "") -- stop at the first NUL, if any
    lumps[#lumps + 1] = { index = i, name = name, upperName = name:upper(), filepos = filepos, size = size }
  end
  return lumps
end

-- Real map-data lump names (classic DOOM format, plus Hexen's own
-- BEHAVIOR/SCRIPTS) that always immediately follow a map marker lump --
-- skipped as a group (see this file's own header: not consumed by any
-- code in this mod, this engine doesn't render classic DOOM levels at
-- all). `isLevel`, restated from wadext's own real check (wadext.cpp:
-- 193-200): the lump right after a would-be map marker is really
-- THINGS (classic) or TEXTMAP (UDMF).
local MAP_LUMP_NAMES = {
  THINGS = true, LINEDEFS = true, SIDEDEFS = true, VERTEXES = true, SEGS = true,
  SSECTORS = true, NODES = true, SECTORS = true, REJECT = true, BLOCKMAP = true,
  BEHAVIOR = true, SCRIPTS = true, TEXTMAP = true, ZNODES = true, ENDMAP = true,
}
local function isLevelMarker(lumps, i)
  local nxt = lumps[i + 2] -- lumps is 1-indexed here (i is 0-based lump index)
  return nxt ~= nil and (nxt.upperName == "THINGS" or nxt.upperName == "TEXTMAP")
end

-- ------- the whole extraction
--
-- Mirrors wadext's own real top-level driver, `ExtractWad`
-- (wadext.cpp:540-649): walk every lump in real WAD directory order,
-- recognizing the real marker-lump pairs that bound sprites/flats, and
-- categorizing everything else by real content-sniffing (a patch, a
-- DMX sound, or "copy the bytes as-is") -- restated with this file's
-- own narrower scope (see header) rather than porting every real branch
-- wadext itself has.
function DoomWadNative.extract(wadPath, outDir)
  local okOpen, fp = pcall(io.open, wadPath, "rb")
  if not (okOpen and fp) then return false, "could not open " .. tostring(wadPath) end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 12) then
    return false, "could not read " .. tostring(wadPath)
  end

  local lumps, err = parseDirectory(bytes)
  if not lumps then return false, err end

  -- PLAYPAL must exist somewhere in this same WAD -- every real IWAD has
  -- one (see this file's own header for why no fallback is embedded).
  local palette = nil
  for _, lump in ipairs(lumps) do
    if lump.upperName == "PLAYPAL" and lump.size >= 768 then
      palette = decodePlaypal(bytes:sub(lump.filepos + 1, lump.filepos + lump.size))
      break
    end
  end
  if not palette then
    return false, "no PLAYPAL lump found in that WAD -- can't decode any patch/flat colors"
  end

  ensureDir(outDir)
  local spritesDir = outDir .. "/SPRITES"
  local patchesDir = outDir .. "/PATCHES"
  local flatsDir = outDir .. "/FLATS"
  local soundsDir = outDir .. "/SOUNDS"
  ensureDir(spritesDir)
  ensureDir(patchesDir)
  ensureDir(flatsDir)
  ensureDir(soundsDir)

  local written = 0
  local inSprites, inFlats = false, false
  local i = 1
  while i <= #lumps do
    local lump = lumps[i]
    local name = lump.upperName

    if name == "S_START" or name == "SS_START" then
      inSprites = true
    elseif name == "S_END" or name == "SS_END" then
      inSprites = false
    elseif name == "F_START" or name == "FF_START" then
      inFlats = true
    elseif name == "F_END" or name == "FF_END" then
      inFlats = false
    elseif name:match("^GL_") then
      -- real GL node lumps -- skipped entirely, see this file's header.
    elseif isLevelMarker(lumps, lump.index) then
      -- Skip the marker itself plus every immediately-following real
      -- map-data lump (a fixed, well-known real name set) -- stops at
      -- the first lump name that ISN'T one of them, so this never eats
      -- into the next unrelated lump by over-counting.
      i = i + 1
      while i <= #lumps and MAP_LUMP_NAMES[lumps[i].upperName] do
        i = i + 1
      end
      i = i - 1 -- the outer loop's own i=i+1 below re-lands correctly
    elseif lump.size > 0 then
      local data = bytes:sub(lump.filepos + 1, lump.filepos + lump.size)
      local base = sanitizeName(lump.name)

      if inFlats and not isPatch(data) then
        local ok, rgba, w, h = pcall(decodeFlat, data, palette)
        if ok and rgba then
          local path = uniquePath(flatsDir, base, ".png")
          if writePng(path, rgba, w, h, 0, 0) then written = written + 1 end
        end
      elseif isPatch(data) then
        local ok, rgba, w, h, l, t = pcall(decodePatch, data, palette)
        if ok and rgba then
          local dir = inSprites and spritesDir or patchesDir
          local path = uniquePath(dir, base, ".png")
          if writePng(path, rgba, w, h, l, t) then written = written + 1 end
        end
      elseif isDoomSound(data) then
        local path = uniquePath(soundsDir, base, ".wav")
        if writeWav(path, data) then written = written + 1 end
      else
        -- Real fallback, matching wadext's own final `else` branch
        -- (wadext.cpp:160-173): copy the raw lump bytes verbatim, named
        -- after the real lump name, into the top-level output folder --
        -- PLAYPAL/COLORMAP/GENMIDI/DMXGUS/ENDOOM/TEXTURE1/PNAMES/etc, or
        -- anything else this file doesn't specifically convert. Ready
        -- for a future consumer to read by name, same as `playpal.lmp`
        -- already is today.
        local path = uniquePath(outDir, base, ".lmp")
        local okOut, outFp = pcall(io.open, path, "wb")
        if okOut and outFp then
          local okW = pcall(outFp.write, outFp, data)
          pcall(outFp.close, outFp)
          if okW then written = written + 1 end
        end
      end
    end

    i = i + 1
  end

  if written == 0 then
    return false, "WAD parsed but nothing was extracted (0 lumps written)"
  end
  return true, written
end

return DoomWadNative
