-- PokeDoom: importing GZDoom's own "BigUpper" menu font at runtime, the
-- same real principle as `lib/DoomWadImport.lua`'s DOOM WAD import
-- (Locked Decision 5) -- the player supplies something they already
-- legally have, this mod extracts only what it needs and ships nothing
-- itself.
--
-- BigUpper is NOT extractable from a real doom.wad -- confirmed directly
-- against the player's own already-extracted WAD contents (1923 real
-- files, zero big-letter-font lumps) and against `DOOM-master/
-- linuxdoom-1.10/m_menu.c` itself (`menuitem_t` entries carry a literal
-- graphic LUMP NAME per menu item -- `{1,"M_NGAME",M_NewGame,'n'}` --
-- vanilla DOOM's own big menu text is pre-drawn whole-word graphics,
-- never a reusable character font). BigUpper only exists because source
-- ports need to render arbitrary strings at that size.
--
-- FIX 2026-08-19 -- REAL ROOT CAUSE of "the font looks wrong compared to
-- real GZDoom," found only after the user directly disputed the previous
-- fix with a real GZDoom screenshot. The prior version of this file
-- extracted `zbigfont.lmp` out of `gzdoom.pk3` and concluded (WRONGLY,
-- from reading `gzdoom-master/src/gamedata/doomfont.h`'s fallback logic
-- in isolation) that this WAS real GZDoom's actual BigUpper. That
-- conclusion only looked right because `gzdoom.pk3` was the ONLY file
-- ever actually inspected -- a real GZDoom release ships SEVERAL pk3s
-- alongside `gzdoom.exe` (`brightmaps.pk3`, `game_support.pk3`,
-- `game_widescreen_gfx.pk3`, `lights.pk3`), and `zbigfont.lmp`'s own
-- glyph dimensions (`A` = 15x12) never got compared against anything
-- until this round. Checking every real pk3 in the install directory
-- (not just the one first found) turned up `game_support.pk3`, which
-- contains a genuine `filter/doom.id/fonts/bigupper/` folder of loose,
-- classic-DOOM-patch-format `.lmp` files, one per Unicode codepoint
-- (`0041.lmp` = 'A', etc) -- `A` here is 18x15, taller, with real
-- distinct lowercase glyphs (`0061.lmp` = 'a', 15x12 -- genuinely
-- shorter than uppercase, a real mixed-case font) -- matching the user's
-- own reference screenshot exactly, and matching this project's own
-- pre-2026-08-12 dev-scaffolding art (a manual, temporary copy of this
-- SAME real folder out of GZDoom's GitHub source tree) almost exactly
-- too. The `filter/doom.id/` path prefix is GZDoom's own real per-IWAD
-- resource-filter convention -- content under it only loads when the
-- active IWAD is `doom.wad`, exactly the game this project targets --
-- and GZDoom auto-loads any `fonts/<name>/` folder of loose patches as a
-- "Folder"-type font by name, which is how `V_GetFont("BigUpper")`
-- actually finds this at runtime with no FONTDEFS entry anywhere (
-- confirmed: `fontdefs.txt` inside `gzdoom.pk3` has zero mentions of
-- "upper"). `zbigfont.lmp`/`gzdoom.pk3` is a real file, and a real
-- GZDoom install genuinely has it, but it's `V_GetFont("BigFont")`'s own
-- generic ZBIGFONT fallback used by OTHER, smaller UI text -- not what
-- the actual menu screen the user compared against renders with.
--
-- This file now extracts the whole `bigupper` folder (every real loose
-- `.lmp` patch in it) from `game_support.pk3` -- a SIBLING of whatever
-- `gzdoom.pk3` the player picks in the file dialog below, since every
-- real GZDoom release ships both in the same install directory next to
-- `gzdoom.exe`. `lib/DoomBigFont.lua` owns decoding each patch (DOOM's
-- real `patch_t` format, `DOOM-master/linuxdoom-1.10/r_defs.h:356-364`)
-- and recoloring it via the player's own already-extracted `playpal.lmp`
-- (Locked Decision 5's WAD import already puts this on disk for every
-- other DOOM-derived color lookup); this file owns only getting the raw
-- lump bytes from the player's own GZDoom install onto disk, mirroring
-- `DoomWadImport.lua`'s own `choose`/`validateHeader`/`status`/`row`/
-- `install` shape closely enough to read as the same real pattern.
--
-- Real provenance (read directly from GZDoom's own shipped
-- `credits/dbigfont.txt`, not assumed): "DBIGFONT, SBIGFONT -- Taken
-- from sp_usimp.zip (Ultimate Simplicity) by Agent Spork -- sp_usimp.txt
-- contains the following permissions: Authors MAY use the contents of
-- this file as a base for modification or reuse. Permissions have been
-- obtained from original authors for any of their resources modified or
-- included in this file." So this is a third-party community font (not
-- id Software's, not even GZDoom-team-original) -- the real, honest
-- credit for this file is "Agent Spork (Ultimate Simplicity)," not a
-- generic id Software credit -- surfaced in the file-picker prompt below
-- and logged once on a successful import, same as this project already
-- credits every other borrowed fact.
--
-- CHANGED 2026-08-19, second round -- the folder-picker approach directly
-- above (still visible in this file's own git history) turned out to be
-- dead on the current engine, for a DIFFERENT and more fundamental reason
-- than the sibling-file confusion the first 2026-08-19 round fixed: a
-- real diagnostic log showed the dialog itself opening and returning a
-- real, confirmed-correct folder path, yet EVERY subsequent `io.open` on
-- a file inside it (`game_support.pk3`, `gzdoom.pk3`) failing with
-- `ok=true, fp=false` -- no Lua error, just a clean "could not open."
-- Root-caused directly against `gen1recomp-dev-0.29/src/mods/Sandbox.lua`
-- /`LegacyCompat.lua`: a mod's own `io.open` no longer reaches genuine
-- disk for any path outside this mod's own installed folder at all
-- (silently redirected into an isolated, empty-by-default per-mod
-- "compat overlay" instead) -- and `ffi` itself (this file's OWN
-- `resolvePhysfsMount`/`resolvePhysfsUnmount`, below, now deleted) is
-- flatly denied to mod code too (`Sandbox.lua`'s own `DENIED_PREFIX`
-- table lists it by name), so even the raw `PHYSFS_mount` escape hatch
-- this file used to rely on for mounting an EXTERNAL absolute-path pk3
-- is gone, permanently, not just broken for this specific folder shape.
-- `fsShim.mount`'s own real refusal message states the engine's intended
-- replacement outright: "ship the files inside your mod and use
-- mod:read." Since `love.filesystem.mount` is ALSO refused for mod code
-- now (confirmed: `fsShim.mount()` always returns `false`), there is no
-- remaining way to MOUNT a `.pk3`'s own zip contents as a live
-- filesystem -- so this file no longer tries to.
--
-- CHANGED 2026-08-19, THIRD round -- the second round (still in this
-- file's own git history) asked the player to pre-extract `game_support.
-- pk3` themselves with an outside archive tool before this row could do
-- anything. Direct user question, once that shipped: "is there really no
-- way for the program to extract a zip for you." Worth checking again
-- rather than accepting the manual workaround as final -- `Sandbox.lua`'s
-- own COMPLETE deny-list for the `love` global mod code sees
-- (`BLOCKED_LOVE`) lists only `filesystem`, `thread`, `system`, and
-- `event`, with its own header comment stating outright "Everything else
-- LÖVE exposes passes through." `love.data` isn't on that list at all --
-- and `love.data.decompress("string", "deflate", bytes)` is LÖVE's own
-- real, built-in raw-DEFLATE decompressor (a documented LÖVE 11.x API),
-- which is EXACTLY the one piece `love.filesystem.mount`/FFI used to
-- provide: ZIP's own compression method 8 ("deflated") is a raw deflate
-- stream, no zlib/gzip wrapper, matching that format string precisely.
-- Parsing a ZIP's own plain, published byte structure (central
-- directory, local file headers -- PKWARE's own APPNOTE.txt spec) needs
-- nothing beyond ordinary string/byte manipulation, already unrestricted
-- for mod code. `lib/DoomZipReader.lua` (new) is that reader -- a small,
-- general, reusable "read every entry under a path prefix out of a whole
-- zip file's own bytes" utility, not tied to this file's own BigUpper use
-- specifically. The player now copies the WHOLE, unmodified
-- `game_support.pk3` file itself (no extraction, no other tool) into
-- this mod's own `import/` folder -- read there with plain `io.open`, a
-- bare relative path the sandbox's own real `classify`/`ownExists` logic
-- DOES resolve against genuine disk content (confirmed directly against
-- that file's own source, the same fix `lib/DoomWadImport.lua`'s own
-- identical 2026-08-19 change applies for the WAD import row) -- then
-- unzipped entirely in Lua.

local V = ...
local DoomWadImport = V.require("DoomWadImport")
local DoomZipReader = V.require("DoomZipReader")

local DoomGZDoomImport = {}

DoomGZDoomImport.LABEL = "IMPORT GZDOOM FONT"
local PROMPT = "Copy game_support.pk3 (from your GZDoom install, next to gzdoom.exe) into this mod's "
  .. "import/ folder -- imports the BigUpper menu font (by Agent Spork, Ultimate Simplicity, via GZDoom)"

DoomGZDoomImport.status = { state = "none", error = nil }

local function getDoomLog()
  local ok, DoomLog = pcall(V.require, "DoomLog")
  return ok and DoomLog or nil
end

-- ------- the import folder -- see this file's own third 2026-08-19
-- header addendum for the full derivation. The player copies the WHOLE,
-- unmodified `game_support.pk3` file itself into this mod's own
-- `import/` folder (the same folder `lib/DoomWadImport.lua`'s own WAD
-- row already uses) -- `extract()`, below, unzips it entirely in Lua via
-- `lib/DoomZipReader.lua`, no manual pre-extraction needed.
local IMPORT_DIR = "import"

local function findImportedPk3()
  local okItems, items = pcall(love.filesystem.getDirectoryItems, IMPORT_DIR)
  if not (okItems and items) then return nil end
  for _, name in ipairs(items) do
    if name:lower() == "game_support.pk3" then
      return IMPORT_DIR .. "/" .. name
    end
  end
  return nil
end

function DoomGZDoomImport.canDialog()
  -- Kept (always true now) for any caller that still checks this before
  -- offering the row -- the import-folder scan works identically on
  -- every platform, unlike the dead native folder picker it replaced.
  return true
end

-- ------- where the extracted lumps land -- this mod's own folder, same
-- real-OS-path machinery `DoomWadImport.lua` already proved correct
-- (`gameRoot()`'s own verified-root fix), never re-derived here. Unlike
-- the old zbigfont.lmp single-file version, BigUpper is a whole FOLDER
-- of loose per-codepoint patches -- mirrored here as a folder too.

local REL_OUTPUT_DIR = "assets/generated/gzdoom/bigupper"
local SOURCE_DIR_IN_PK3 = "filter/doom.id/fonts/bigupper" -- the real path INSIDE game_support.pk3, for player-facing instructions only now
local SANITY_GLYPH = "0041.lmp" -- 'A', Unicode 0x0041 -- confirmed present in a real install

function DoomGZDoomImport.outputDir()
  return DoomWadImport.absoluteModPath(REL_OUTPUT_DIR)
end

-- Every real BigUpper glyph this file ever writes lands as
-- "<outputDir>/<4-hex-digit-codepoint>.lmp" -- `lib/DoomBigFont.lua`
-- reads a specific one back by formatting the same codepoint the same
-- way, no directory listing needed at draw time.
function DoomGZDoomImport.glyphPath(codepoint)
  local dir = DoomGZDoomImport.outputDir()
  if not dir then return nil end
  return dir .. "/" .. ("%04X"):format(codepoint) .. ".lmp"
end

-- ------- the extraction itself: find game_support.pk3 in this mod's own
-- import/ folder, read its whole bytes with plain `io.open` (a bare
-- relative path -- see this file's own third 2026-08-19 header addendum
-- for why that reaches real disk), unzip every real glyph patch under
-- `filter/doom.id/fonts/bigupper/` via `lib/DoomZipReader.lua`, write
-- each one into this mod's own real output folder. No external tool, no
-- manual pre-extraction, no mount, no FFI.
function DoomGZDoomImport.extract()
  local pk3Path = findImportedPk3()
  if not pk3Path then
    return false, "game_support.pk3 not found in this mod's " .. IMPORT_DIR .. "/ folder -- copy it there "
      .. "from your GZDoom install (it sits next to gzdoom.exe)"
  end

  local okOpen, fp, openErr = pcall(io.open, pk3Path, "rb")
  if not (okOpen and fp) then
    return false, "could not open " .. pk3Path .. ": " .. tostring(openErr)
  end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 0) then
    return false, "could not read " .. pk3Path
  end

  local entries, zipErr = DoomZipReader.extractPrefix(bytes, SOURCE_DIR_IN_PK3 .. "/")
  if not entries then
    return false, "could not read " .. pk3Path .. " as a zip: " .. tostring(zipErr)
  end
  if #entries == 0 then
    return false, SOURCE_DIR_IN_PK3 .. " not found inside " .. pk3Path .. " -- is this really game_support.pk3?"
  end

  local outDir = DoomGZDoomImport.outputDir()
  if not outDir then
    return false, "could not resolve this mod's own output folder"
  end
  pcall(DoomWadImport.ensureDir, outDir)

  local copied = 0
  for _, entry in ipairs(entries) do
    local name = entry.name:match("([^/]+)$") -- just the filename, dropping the filter/doom.id/... prefix
    if name and name:lower():sub(-4) == ".lmp" then -- skip font.inf, only real glyph patches
      local okWriteOpen, outFp = pcall(io.open, outDir .. "/" .. name, "wb")
      if okWriteOpen and outFp then
        local okWrite = pcall(outFp.write, outFp, entry.data)
        pcall(outFp.close, outFp)
        if okWrite then copied = copied + 1 end
      end
    end
  end

  if copied == 0 then
    return false, "found " .. SOURCE_DIR_IN_PK3 .. " but could not copy any real glyph out of it"
  end

  local okSanity, sanityFp = pcall(io.open, outDir .. "/" .. SANITY_GLYPH, "rb")
  if okSanity and sanityFp then pcall(sanityFp.close, sanityFp) end
  if not (okSanity and sanityFp) then
    return false, "copied " .. copied .. " glyph(s) but the 'A' glyph (" .. SANITY_GLYPH .. ") never landed"
  end

  return true, copied
end

-- ------- the whole flow, from one keypress (mirrors DoomWadImport.import)

-- FIX 2026-08-12 -- the very first real playtest of this row reported
-- "it failed" with no further detail, and this file had never actually
-- logged WHY -- only a successful import got a `DoomLog.event` call.
-- Per CLAUDE.md's own hard rule ("a bug that survives one fix attempt
-- gets logging before a second attempt is made"), every real failure
-- path now logs its own specific reason (the same `status.error` string
-- the options row itself never shows, since the row's own `value()`
-- only ever displays the fixed word "FAILED") the moment it happens,
-- not just on the next report.

local function fail(reason)
  DoomGZDoomImport.status.state = "failed"
  DoomGZDoomImport.status.error = reason
  local log = getDoomLog()
  if log then
    pcall(log.event, "GZFONT", "import FAILED: %s", tostring(reason))
    pcall(log.flush) -- same reasoning as main.lua's own save.writing handler:
                      -- a one-shot diagnostic must survive whatever happens next,
                      -- not wait on the periodic buffered flush.
  end
  return false
end

function DoomGZDoomImport.import(game)
  if DoomGZDoomImport.status.state == "building" then return false end

  DoomGZDoomImport.status.state = "building"
  local ok, errOrCount = DoomGZDoomImport.extract()
  if not ok then
    return fail(tostring(errOrCount))
  end
  DoomGZDoomImport.status.state = "ready"
  DoomGZDoomImport.status.error = nil
  local log = getDoomLog()
  if log then
    pcall(log.event, "GZFONT",
      "BigUpper imported (%d glyphs) from game_support.pk3 in this mod's %s/ folder -- font by Agent Spork (Ultimate Simplicity), via GZDoom",
      tonumber(errOrCount) or 0, IMPORT_DIR)
  end
  return true
end

-- ------- the options row (mirrors DoomWadImport.row)

function DoomGZDoomImport.row()
  return {
    id = "pokedoom_gzdoom_font",
    label = DoomGZDoomImport.LABEL,
    value = function()
      if DoomGZDoomImport.status.state == "building" then return "IMPORTING" end
      if DoomGZDoomImport.status.state == "ready" then return "READY" end
      if DoomGZDoomImport.status.state == "failed" then return "FAILED" end
      return "IMPORT"
    end,
    step = function(game)
      local log = getDoomLog()
      if log then pcall(log.event, "GZFONT", "row step() called") end
      local ok, err = pcall(DoomGZDoomImport.import, game)
      if log then
        pcall(log.event, "GZFONT", "row step(): import() pcall ok=%s err=%s",
          tostring(ok), tostring(not ok and err or nil))
        pcall(log.flush)
      end
      return true
    end,
  }
end

-- ------- remembering a previous import across restarts (restated from
-- DoomWadImport.lua's own `checkExistingExtraction`, same reasoning: the
-- extracted lumps are still sitting on disk from an earlier session even
-- though `status` itself starts fresh as "none" every process start).

local function checkExistingExtraction()
  local dir = DoomGZDoomImport.outputDir()
  if not dir then return end
  local ok, fp = pcall(io.open, dir .. "/" .. SANITY_GLYPH, "rb")
  if ok and fp then
    pcall(fp.close, fp)
    DoomGZDoomImport.status.state = "ready"
  end
end

local installed = false
local checkedExistingExtraction = false
function DoomGZDoomImport.install()
  if installed then return end
  installed = true
  -- Deferred to the first real `input.step` tick, same reasoning as
  -- `DoomWadImport.install()`'s own identical deferral: this runs a real
  -- `io.open` at module-load time otherwise, before the game window
  -- exists, which this project has already confirmed once can misbehave
  -- in ways that never surface as a normal Lua error.
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if not checkedExistingExtraction then
      checkedExistingExtraction = true
      pcall(checkExistingExtraction)
    end
    return next(game, dt)
  end)
end

return DoomGZDoomImport
