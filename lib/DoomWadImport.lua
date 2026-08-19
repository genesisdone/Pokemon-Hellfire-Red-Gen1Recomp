-- PokeDoom: importing a DOOM WAD, the same way the host mod's own
-- StadiumRomPick.lua imports a Pokemon Stadium ROM instead of asking the
-- player to drop a file in a folder by hand.
--
-- This project ships NONE of id Software's assets and never will -- they
-- are that game's copyrighted data. The player supplies their own
-- legally-owned WAD (the shareware doom1.wad, a registered doom.wad,
-- Doom II, Final Doom, or any other IWAD), exactly the same principle
-- gen1recomp-dev itself uses for the Pokemon ROM (src/import/
-- RomImporter.lua) and the voxel mod uses for the Stadium ROM
-- (lib/StadiumRomPick.lua) -- neither of those ships Nintendo's data
-- either. This file is a close structural mirror of StadiumRomPick.lua:
-- same native-dialog-per-OS approach (LOVE 11.5 has no file dialog of
-- its own), same "read an absolute path via plain io, not
-- love.filesystem" reasoning, same blocking-dialog-is-fine-on-an-options-
-- menu reasoning. It is a second copy of that pattern rather than a call
-- into the engine's own importer because a mod cannot reach that
-- module's private helpers, and it is worth restating rather than asking
-- the base engine to grow a seam for one caller.
--
-- EXTRACTION is native -- `lib/DoomWadNative.lua`, pure Lua, no external
-- tool. FIX 2026-08-19, direct user request: "i want native wad
-- extraction without any new applications attached for universal
-- support." This used to shell out to a compiled `wadext.exe`
-- (github.com/coelckers/wadext, the sibling `wadext-master/` checkout) --
-- a real, independent, open-source WAD extraction tool, but one that
-- needed a one-time C++ compile (CMake + a real C++ toolchain,
-- `scripts/dev-launch.ps1`'s own real build step) before this row would
-- even show anything but "NO TOOL." `DoomWadNative.lua` reads every
-- format/algorithm directly from wadext's own real source (its patch/
-- flat/DMX-sound decoders, its PNG grAb-chunk convention) and restates
-- them in Lua -- see that file's own header for the full derivation and
-- exact citations. wadext-master is kept as a reference checkout (this
-- project's own hard rule: DOOM/format facts come from real source, and
-- wadext's source is what this native version was actually read from)
-- but is no longer built or invoked at runtime.

-- the mod namespace (see main.lua)
local V = ...
local DoomWadNative = V.require("DoomWadNative")

local DoomWadImport = {}

DoomWadImport.LABEL = "IMPORT DOOM WAD"
local PROMPT = "Place your DOOM WAD (doom.wad, doom1.wad, doom2.wad, ...) in this mod's import/ folder"

DoomWadImport.status = { state = "none", error = nil }

-- CHANGED 2026-08-19 -- this file used to shell out (via `HostShell.
-- popen`, a per-OS native dialog, and `dir`/`find`/`mkdir` for asset
-- lookup and directory creation) for everything real-disk-related. All
-- of that is gone now: the native dialog was permanently dead on the
-- current engine's sandbox (see `findImportedWad`'s own header comment
-- below), and the shell-based asset lookup/mkdir was silently checking
-- real OS disk while every actual write already landed in this mod's own
-- sandboxed compat overlay instead (see `assetList`'s own header comment
-- further down) -- both fixed by switching to the same sandboxed
-- `love.filesystem`/`io.open` surface throughout, which is symmetric
-- with itself for a given path string in a way a shell command spawned
-- alongside it never was.
local DoomLog
local function getDoomLog()
  DoomLog = DoomLog or V.require("DoomLog")
  return DoomLog
end

-- ------- the import folder
--
-- CHANGED 2026-08-19 -- the native OS file dialog this function used to
-- open (still in this file's own git history) is dead on the current
-- engine, permanently: root-caused directly against `gen1recomp-dev-
-- 0.29/src/mods/Sandbox.lua`/`LegacyCompat.lua` after a real diagnostic
-- log showed the dialog itself opening fine (confirmed: `HostShell.popen`
-- returns a real pipe, and the player DID pick a real file) but every
-- subsequent `io.open()` on the path it returned failing with `ok=true,
-- fp=false` -- no Lua error, just a clean "could not open." That file's
-- own real `classify()` function explains why: a mod's own `io.open`
-- only ever reaches genuine, real disk for a path that resolves INSIDE
-- this mod's own installed folder (`ctx.modPath`) -- anything else,
-- including a real absolute path with a drive letter (exactly what a
-- native picker returns), gets silently redirected into an isolated,
-- empty-by-default per-mod "compat overlay" instead of the real file.
-- `fsShim.mount`'s own real refusal message states the engine's intended
-- replacement outright, word for word: "ship the files inside your mod
-- and use mod:read." Confirmed against a real, working precedent too --
-- `gen1recomp-mod-stadium2-importer-main`'s own manifest declares a
-- `required_imports` entry (a single, fixed, known MD5) instead of using
-- any picker at all. That exact mechanism doesn't fit THIS file's own
-- real need -- Stadium 2 has one canonical ROM dump to pin a hash
-- against; DOOM has dozens of legitimately different real IWAD releases
-- (doom.wad across multiple versions/re-releases, doom1.wad, doom2.wad,
-- tnt.wad, plutonia.wad, Freedoom's own IWADs) with no single hash to
-- declare -- so this file instead scans a plain `import/` folder inside
-- this mod's own installed directory for whatever `.wad` the player has
-- placed there themselves, using an ordinary RELATIVE path
-- (`io.open("import/doom.wad", ...)`), which `classify`'s own real
-- `ownExists`/`ownFull` logic DOES resolve against genuine disk content
-- -- confirmed directly against that file's own source, not assumed.
local IMPORT_DIR = "import"

local function ensureImportDir()
  pcall(love.filesystem.createDirectory, IMPORT_DIR)
end

-- Case-insensitive match on the real WAD extension -- any filename the
-- player used (doom.wad, DOOM2.WAD, doom1.wad, ...) is accepted; the
-- actual IWAD-vs-PWAD/real-format check happens in `validateHeader`
-- below, same as it always did.
local function findImportedWad()
  ensureImportDir()
  local log = getDoomLog()
  local okList, items = pcall(love.filesystem.getDirectoryItems, IMPORT_DIR)
  if not (okList and items) then
    if log then pcall(log.event, "WADIMPORT", "getDirectoryItems('%s') failed: ok=%s", IMPORT_DIR, tostring(okList)) end
    return nil
  end
  for _, name in ipairs(items) do
    if name:lower():match("%.wad$") then
      return IMPORT_DIR .. "/" .. name
    end
  end
  return nil
end

function DoomWadImport.canDialog()
  -- Kept (always true now) for any caller that still checks this before
  -- offering the row -- the import-folder scan works identically on
  -- every platform, unlike the dead per-OS native dialog it replaced.
  return true
end

-- ------- validation
--
-- A WAD's first 4 bytes are its magic: "IWAD" (a complete game -- what
-- this needs) or "PWAD" (a patch that overlays one, useless alone). This
-- is the WAD format's own published header layout -- reading it to check
-- the file is really a WAD is no different from checking a PNG's magic
-- bytes, and touches nothing of the copyrighted asset data that follows
-- it.
function DoomWadImport.validateHeader(path)
  local ok, fp, openErr = pcall(io.open, path, "rb")
  if not (ok and fp) then
    local log = getDoomLog()
    if log then
      pcall(log.event, "WADIMPORT", "validateHeader: io.open('%s') ok=%s openErr=%s",
        tostring(path), tostring(ok), tostring(openErr))
      pcall(log.flush)
    end
    return false, "could not open that file"
  end
  local okRead, header = pcall(fp.read, fp, 4)
  pcall(fp.close, fp)
  if not okRead then return false, "could not read that file" end
  if header == "PWAD" then
    return false, "that's a PWAD (a patch, not a full game) -- pick an IWAD"
  end
  if header ~= "IWAD" then
    return false, "that doesn't look like a WAD file"
  end
  return true
end

-- ------- where extracted assets land
--
-- Inside THIS mod's own folder, never the host's -- addon, not a fork
-- (CLAUDE.md). V.mod.path (confirmed by a debug print: "mods/PokeDoom-dev")
-- is relative to the GAME's own root, the same way love.filesystem/physfs
-- resolves it -- it is NOT a real OS path, so io.open (and shelling out to
-- run wadext.exe) can't use it directly, even though the file genuinely
-- exists where it says.
--
-- FIX 2026-08-11 (Steam Deck report: "the ui doesnt work, it doesnt put
-- me in first person, or spawn anything... the doom menu... doesnt show
-- the menu text at all" -- everything this file's own absolute-path
-- mechanism touches, at once). This used to be plain
-- `love.filesystem.getSource()` alone. Read fresh from the base engine's
-- own real source: `gen1recomp-dev/src/mods/LauncherMods.lua:181-194`'s
-- own comment states directly that for a FUSED build, "a fused build has
-- both [getSource() and the portable folder], and they are different
-- paths (the archive inside the executable vs the folder beside it)" --
-- and that the portable folder (not getSource()) is where a fused
-- build's own real, writable `mods/` folder actually lives
-- (`LauncherMods.lua:214-217`: "A fused portable build keeps its mods in
-- the game folder next to the executable"). `gen1recomp-dev/src/import/
-- CacheFs.lua:222-238`'s own `resolvePortableRoot` is the base engine's
-- own real resolution of that folder -- `SaveData.portableBaseDir()`,
-- falling back to `love.filesystem.getSource()` only when the portable
-- base isn't available (dev/source runs, where that function's own
-- comment confirms the two already coincide: "source run: the folder is
-- already the physfs source"). `SaveData.lua:542-544` reuses this exact
-- same fallback chain for its own save-slot path resolution -- this
-- isn't a new pattern invented here, it's the base engine's own
-- established idiom for "give me a real OS root," reused instead of
-- reinvented. This one function is the single upstream root every other
-- absolute-path consumer in this file derives from (`outputDir()`,
-- `assetList`'s shell `find`/`dir`, `readAssetBytes`'s `io.open`, wadext
-- invocation, `DoomBigFont.lua`'s own font/palette reads) -- fixing it
-- here fixes all of them without touching any of their own code.
-- FIX 2026-08-11, round 2 -- real log evidence from a genuinely fresh
-- Windows install (not just the Steam Deck) proved the actual bug: on a
-- FUSED build, `love.filesystem.getSource()` returns the path to the
-- EXECUTABLE FILE ITSELF (confirmed directly: the log's own
-- `resolvedRoot`/`getSource()` both read `...\gen1recomp-win64\
-- gen1recomp.exe`, a file, not a folder), not its containing directory
-- the way this file's own original comment assumed (true only for an
-- unfused/source `love .` run). Every absolute path built from it
-- (`root .. "/" .. V.mod.path .. "/" .. rel`) was therefore appending
-- onto a FILENAME -- `...\gen1recomp.exe/mods/POKEDOOM/tools/
-- wadext.exe` -- which can never exist on any platform. This, not
-- anything Linux/AppImage-specific, is why every fresh install (Steam
-- Deck AND a brand-new Windows PC alike) showed `NO TOOL` and `status.
-- state` stuck at `"none"`: `io.open` was correctly failing to open a
-- file path that was never real to begin with. The round-1 fix
-- (preferring `SaveData.portableBaseDir()`) is kept as a real, still-
-- correct improvement, but that call returned `nil` on this same
-- Windows machine (its own `resolvePortableRoot` needs a working
-- windowless `mkdir` probe to succeed first -- see `CacheFs.lua`), so
-- it never actually applied here -- this normalization step is what
-- fixes it regardless of which of the two resolves.
local function toDirectory(path)
  if not path then return nil end
  -- If `path` opens as a READABLE FILE, it's a file path (the fused
  -- exe) -- take its containing directory. A genuine directory path
  -- can't be opened this way (Lua's `io.open` fails on a directory),
  -- so this leaves an already-correct directory untouched.
  local ok, fp = pcall(io.open, path, "rb")
  if ok and fp then
    pcall(fp.close, fp)
    local dir = path:match("^(.*)[/\\][^/\\]*$")
    return dir or path
  end
  return path
end

-- FIX 2026-08-12 (fresh-install report: this mod zipped up and dropped
-- into `%APPDATA%\pokemon-love2d\mods\POKEDOOM` against a freshly
-- downloaded, non-portable fused `gen1recomp.exe` -- CHOOSE DOOM WAD
-- said NO TOOL, and the DOOM-skinned menu never appeared either, even
-- with PKDOOM MODE on). Root cause, confirmed against the base engine's
-- own real source: `SaveData.portableBaseDir()` (`src/core/SaveData.lua`
-- `detectPortable`) only ever resolves when a `portable.txt` marker sits
-- beside the executable -- absent here, so it returned nil, and the OLD
-- `gameRoot()` fell straight through to `love.filesystem.getSource()`,
-- which for a fused, non-portable build resolves to the EXE's OWN
-- folder. But `gen1recomp-dev/src/mods/LauncherMods.lua`'s own header
-- comment states directly that "love.filesystem looks in two places for
-- 'mods/': the save directory, and [the portable folder next to the
-- executable, when mounted]" -- and with no portable.txt, ONLY the save
-- directory is ever in play, which is exactly where a fused build's
-- user-dropped mod zip actually lands (`love.filesystem.
-- getSaveDirectory()` on a fused build omits the "LOVE\" prefix LÖVE
-- uses for an unfused/dev run -- confirmed by the user's own real path,
-- `%APPDATA%\pokemon-love2d\...`, not `%APPDATA%\LOVE\pokemon-love2d\`).
-- So the mod's own LUA loaded fine (love.filesystem legitimately reads
-- the save directory), but every REAL-OS-path consumer in this file
-- (wadextPath/outputDir/assetList/readAssetBytes) was built from the
-- exe's folder instead -- a location the player's zip was never placed
-- in -- reproducing NO TOOL exactly. The invisible DOOM menu is not a
-- second bug: `lib/DoomMenuSkin.lua`'s already-correct gate just never
-- saw `DoomWadImport.status.state == "ready"`, since import could never
-- even start.
--
-- Fixed: try every real candidate root, in priority order, and VERIFY
-- each one (does `<candidate>/<V.mod.path>/manifest.json` actually
-- open?) rather than trusting whichever candidate merely resolves
-- first, the way the old code did. `love.filesystem.getSaveDirectory()`
-- (always a real OS path -- that's its documented purpose, not a
-- virtual physfs one) is the new middle candidate: after
-- `portableBaseDir()` (a real portable install's own files still win
-- when both exist) and before the `getSource()` fallback (kept last --
-- a dev/source `love .` run's mods live next to the source, never in
-- the save directory). Falls back to the first candidate unverified if
-- NONE of them verify, matching the old behavior exactly, so no
-- previously-working install regresses.
local function candidateRoots()
  local out = {}
  local okSave, SaveData = pcall(require, "src.core.SaveData")
  if okSave and SaveData and SaveData.portableBaseDir then
    local okBase, base = pcall(SaveData.portableBaseDir)
    if okBase and type(base) == "string" and base ~= "" then
      out[#out + 1] = toDirectory(base)
    end
  end
  local okSaveDir, saveDir = pcall(love.filesystem.getSaveDirectory)
  if okSaveDir and type(saveDir) == "string" and saveDir ~= "" then
    out[#out + 1] = saveDir
  end
  local okSrc, src = pcall(love.filesystem.getSource)
  if okSrc and type(src) == "string" and src ~= "" then
    out[#out + 1] = toDirectory(src)
  end
  return out
end

local function rootHasMod(root)
  if not (root and V.mod and type(V.mod.path) == "string") then return false end
  local ok, fp = pcall(io.open, root .. "/" .. V.mod.path .. "/manifest.json", "rb")
  local found = ok and fp ~= nil
  if fp then pcall(fp.close, fp) end
  return found
end

local function gameRoot()
  local roots = candidateRoots()
  for _, root in ipairs(roots) do
    if rootHasMod(root) then return root end
  end
  return roots[1]
end

-- Diagnostic accessor, NOT a bare `print` -- a bare print only reaches
-- whatever console the platform happens to have (the Steam Deck's real
-- log capture confirmed this: neither this nor the pre-existing
-- `wadextAvailable` debug print below ever showed up in it). `lib/
-- DoomLog.lua`'s own `DoomLog.write` is the only thing that actually
-- writes to the persistent, readable log file -- and it can't be called
-- from THIS file directly, since `DoomLog.lua` itself does
-- `V.require("DoomWadImport")` at its own top (a real circular require
-- otherwise). `main.lua` already requires both and already has its own
-- `DoomLog.event("DIAG", ...)` diagnostic block -- this accessor exists
-- so that block can log the real, resolved values once at startup
-- instead of this file guessing at how to reach the log file itself.
function DoomWadImport.gameRootDebugInfo()
  local okSrc, src = pcall(love.filesystem.getSource)
  local okSaveDir, saveDir = pcall(love.filesystem.getSaveDirectory)
  local okSave, SaveData = pcall(require, "src.core.SaveData")
  local base = nil
  if okSave and SaveData and SaveData.portableBaseDir then
    local okBase, b = pcall(SaveData.portableBaseDir)
    if okBase then base = b end
  end
  return ("resolvedRoot=%s portableBaseDir=%s saveDirectory=%s getSource()=%s modPath=%s"):format(
    tostring(gameRoot()), tostring(base), tostring(okSaveDir and saveDir or nil),
    tostring(okSrc and src or nil), tostring(V.mod.path))
end

local function absoluteModPath(rel)
  local root = gameRoot()
  if not root then return nil end
  return root .. "/" .. V.mod.path .. "/" .. rel
end

function DoomWadImport.outputDir()
  return absoluteModPath("assets/generated/doom")
end

-- `DoomWadImport.ensureDir` is assigned further down, right after
-- `ensureDir`'s own definition -- a top-level assignment here would hit
-- the exact Lua forward-reference bug this project's own CLAUDE.md
-- warns about (`ensureDir` isn't declared `local` yet at this point in
-- the file, so this would silently resolve to an unrelated global).
DoomWadImport.absoluteModPath = absoluteModPath

-- Finds an extracted file by NAME SUBSTRING, searched RECURSIVELY under
-- outputDir() -- confirmed by direct inspection of a real extraction
-- (filenames/folder structure only, no asset content opened) that wadext
-- does NOT dump flat into the current directory: it organizes output
-- into its own subfolders (SPRITES/, FLATS/, sounds/, music/, patches/,
-- graphics/, MAPS/, decompiled/), all nested inside a folder named after
-- the WAD's own filename (doom.wad -> a `doom/` subfolder) -- so a flat,
-- top-level-only search never finds anything regardless of whether
-- conversion itself worked (it does: 1582 real PNGs confirmed present in
-- that same extraction, including the pistol's own pisga0.png). Nothing
-- here can hard-code the WAD-basename subfolder either, since it differs
-- between doom.wad/doom1.wad/doom2.wad/etc. -- recursing under
-- outputDir() sidesteps needing to know it. Only the lump name itself
-- (e.g. "PISGA0", DOOM's own published sprite-naming convention: 4-letter
-- sprite name + frame letter + rotation digit, a technical filename
-- format, not creative content) is ever reliable to search by.
-- Returns the first matching ABSOLUTE path, or nil.
-- **Bug found on the user's own playtest, 2026-08-06: this used to shell
-- out a fresh recursive directory search for EVERY distinct new name.**
-- Each call ran a real `dir /s` (Windows) / `find` (Unix) walking the
-- WHOLE extracted-assets tree (confirmed elsewhere in this project: wadext
-- produces 1582 real files for a full IWAD) -- fine as an occasional cost,
-- but every consumer in this mod caches by NAME only (`lib/DoomHud.lua`'s
-- `loadHudAsset`, `lib/DoomKill.lua`'s `loadGibSprite`, this file's own
-- earlier callers), so a NEW distinct name -- a gib's own first XDIE
-- frame, a different item's own pickup icon -- always paid this full
-- recursive-search cost fresh, no matter how many OTHER names had already
-- been looked up. On the user's own Windows-VM-over-a-Mac-UNC-share dev
-- setup (filesystem operations over SMB are dramatically slower than
-- local disk), this showed up as a genuine ~1.5s+ freeze on the FIRST
-- kill (needing its own first, never-before-looked-up gib sprite name)
-- and SEPARATELY on the first pickup (a different, also-first-time item
-- sprite name) -- exactly matching "the first pickup and first kill of
-- the game lag the game HARD... there is not any lag after that" (each
-- name's OWN cache, once warm, is instant from then on -- which is
-- exactly why nothing lagged again afterward).
--
-- Real fix: list the tree ONCE (no wildcard filter -- one recursive walk,
-- same underlying cost as a single one of the old per-name searches, not
-- a multiple of it), cache the full list of paths, and answer every
-- SUBSEQUENT `findAsset` call (any name, not just a repeat of the same
-- one) with a fast in-memory Lua substring match against that cached
-- list -- converting "N distinct names each pay their own full shell-out"
-- into "one shell-out total, however many distinct names ever get
-- looked up after it." Rebuilt the same way every other cache in this
-- mod already invalidates -- whenever `DoomWadImport.status.state`
-- transitions (a fresh WAD chosen/extracted mid-session shouldn't keep
-- answering from a stale listing).
-- FIX 2026-08-19 -- REAL ROOT CAUSE of "i don't see any of the assets
-- show up... are they actually importing at all" -- confirmed directly:
-- extraction reported success (1883 real lumps written, matching a fresh
-- import), yet a real shell `dir /b /s` scan of `outputDir()`'s own
-- absolute-looking path found the four category folders completely
-- EMPTY. `DoomWadNative.extract`'s own writes go through plain
-- `io.open(path, "wb")` -- the sandbox's own shimmed version for mod
-- code -- and `outputDir()`'s string (built from `gameRoot()`, itself
-- now confirmed to just be the sandbox's own `ctx.virtualRoot`, e.g.
-- `/pokeport/POKEDOOM`) gets redirected by that shim into this mod's own
-- REAL, WRITABLE per-mod "compat overlay" storage (confirmed directly on
-- disk: all 1883 files landed under `mod_compat/POKEDOOM/mods/POKEDOOM/
-- assets/generated/doom/`, not the real absolute path a shell command
-- resolves the same string to) -- the exact same real mechanism `lib/
-- DoomLog.lua`'s own writes already ride, successfully, this whole
-- project. The writes were never broken; this function was the one
-- still looking somewhere else for them -- a shell `dir`/`find`, which
-- only ever sees genuine OS disk, never that overlay. Switched to
-- `love.filesystem.getDirectoryItems` (the sandbox's own real, working
-- surface for exactly this string), recursing manually since it isn't
-- itself recursive -- now symmetric with how the write side already
-- resolves the very same path.
local assetListCache, assetListWadState = nil, nil

local function walkAssets(dir, out)
  local okItems, items = pcall(love.filesystem.getDirectoryItems, dir)
  if not (okItems and items) then return end
  for _, name in ipairs(items) do
    local full = dir .. "/" .. name
    local okInfo, info = pcall(love.filesystem.getInfo, full)
    if okInfo and info then
      if info.type == "directory" then
        walkAssets(full, out)
      else
        out[#out + 1] = full
      end
    end
  end
end

local function assetList(dir)
  if DoomWadImport.status.state ~= assetListWadState then
    assetListWadState = DoomWadImport.status.state
    assetListCache = nil
  end
  if assetListCache then return assetListCache end
  local list = {}
  walkAssets(dir, list)
  assetListCache = list
  return list
end

function DoomWadImport.findAsset(nameSubstring)
  local dir = DoomWadImport.outputDir()
  if not dir then return nil end
  local needle = nameSubstring:lower()
  for _, path in ipairs(assetList(dir)) do
    -- match against the filename only (the part after the last "/"), the
    -- same scope the old wildcard-filtered `dir`/`find` search itself had
    local name = path:match("[^/]+$") or path
    if name:lower():find(needle, 1, true) then
      return path
    end
  end
  return nil
end

-- DOOM's own real sprite lump naming (confirmed directly against
-- `doom.wad`'s own lump directory, not assumed): PREFIX + letter + rotation
-- digit, optionally followed by a SECOND letter+rotation pair when one
-- drawn image is reused for two different frame/rotation slots at once
-- (e.g. Spider Mastermind's own real `SPIDA1D1` -- frame A's rotation 1
-- and frame D's rotation 1 are the literal same drawing). A plain
-- substring search for "SPIDD1" never finds this lump, because "D1"
-- only ever appears as the SECOND pair, never as the prefix -- a real,
-- previously-unhandled gap (`lib/DoomDemons.lua`'s own `loadDemonSprite`
-- only ever tried the "0" and bare "1" suffixes) that leaves whichever
-- frame letter lands in the second slot with no way to be found at all,
-- rendering as invisible. Most roster demons' own sprites never do this
-- (each rotation they need has its own standalone lump, or is the FIRST
-- pair of a self-mirrored one, e.g. `POSSA2A8`) -- confirmed by directly
-- auditing every roster sprite's own real lump list -- SPID is the one
-- real exception among this roster, reusing frames across DIFFERENT
-- letters (not just self-mirroring) throughout its own stand/run/attack
-- sheet. Searches for a lump whose FIRST OR SECOND letter+rotation slot
-- matches exactly (not a loose substring), so it only ever returns a
-- lump that genuinely encodes the requested frame, never a coincidental
-- unrelated match elsewhere in the WAD.
function DoomWadImport.findSpriteFrameName(spritePrefix, letter, rotation)
  local dir = DoomWadImport.outputDir()
  if not dir then return nil end
  local prefixLower = spritePrefix:lower()
  local wantSlot = (letter .. rotation):lower()
  for _, path in ipairs(assetList(dir)) do
    local name = path:match("[^/]+$") or path
    local lower = name:lower()
    if lower:sub(1, #prefixLower) == prefixLower and lower:sub(-4) == ".png" then
      local body = lower:sub(#prefixLower + 1, -5) -- strip prefix and ".png"
      if (#body == 2 and body == wantSlot)
         or (#body == 4 and (body:sub(1, 2) == wantSlot or body:sub(3, 4) == wantSlot)) then
        return lower:sub(1, -5) -- the exact lump name, sufficient to re-find itself via loadImage
      end
    end
  end
  return nil
end

-- Reads the raw bytes of an extracted asset by name substring, or nil.
-- Shared by loadImage/loadSpriteAsset/loadSound below -- plain io (an
-- arbitrary absolute path, same as StadiumRomPick.read) rather than
-- love.filesystem: this mod's own folder may be reached by a live OS
-- directory mount or a packed archive depending on how it's installed,
-- and a bare io.open sidesteps needing to know which.
local function readAssetBytes(nameSubstring)
  local path = DoomWadImport.findAsset(nameSubstring)
  if not path then return nil end
  local ok, fp = pcall(io.open, path, "rb")
  if not (ok and fp) then return nil end
  local okRead, bytes = pcall(fp.read, fp, "*a")
  pcall(fp.close, fp)
  if not (okRead and type(bytes) == "string" and #bytes > 0) then return nil end
  return bytes
end

-- Reads a PNG's `grAb` chunk (leftoffset, topoffset as big-endian int32),
-- a real, standard ancillary PNG chunk -- NOT invented here. wadext's own
-- WritePNG (convert.cpp:521-525) writes this chunk with the patch's exact
-- `leftoffset`/`topoffset` fields (fileformat.h:81-82, straight off the
-- WAD's own patch_t header) whenever either is nonzero -- confirmed by
-- reading wadext's own source directly, not assumed carried-over data.
-- This is DOOM's real per-sprite `spriteoffset`/`spritetopoffset`
-- (r_things.c's own arrays, indexed by lump), previously assumed lost by
-- this project (Phase 4's own now-outdated notes) -- it was not; wadext
-- preserves it, this was just never read before. Returns 0, 0 (DOOM's
-- own default for a patch with no grAb chunk, per WritePNG's `if
-- (leftofs != 0 || topofs != 0)` guard) if the chunk isn't present.
local function readGrabOffset(bytes)
  if not (bytes and #bytes >= 8 and bytes:sub(1, 8) == "\137PNG\r\n\26\n") then
    return 0, 0
  end
  local pos = 9 -- 1-based: first byte after the 8-byte signature
  while pos + 8 <= #bytes + 1 do
    local b1, b2, b3, b4 = bytes:byte(pos, pos + 3)
    local length = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
    local ctype = bytes:sub(pos + 4, pos + 7)
    if ctype == "grAb" and length >= 8 then
      local d = pos + 8
      local l1, l2, l3, l4 = bytes:byte(d, d + 3)
      local t1, t2, t3, t4 = bytes:byte(d + 4, d + 7)
      local left = ((l1 * 256 + l2) * 256 + l3) * 256 + l4
      local top = ((t1 * 256 + t2) * 256 + t3) * 256 + t4
      if left >= 0x80000000 then left = left - 0x100000000 end
      if top >= 0x80000000 then top = top - 0x100000000 end
      return left, top
    end
    -- grAb always precedes IDAT in wadext's own chunk order (right after
    -- IHDR) -- no point scanning the (potentially large) pixel data.
    if ctype == "IDAT" or ctype == "IEND" then break end
    pos = pos + 8 + length + 4
  end
  return 0, 0
end

-- Loads an extracted PNG as a love.graphics.Image, or nil if it isn't
-- there (WAD not imported yet) or doesn't decode.
function DoomWadImport.loadImage(nameSubstring)
  local bytes = readAssetBytes(nameSubstring)
  if not bytes then return nil end
  local okData, fileData = pcall(love.filesystem.newFileData, bytes,
                                 nameSubstring .. ".png")
  if not (okData and fileData) then return nil end
  local okImg, image = pcall(love.graphics.newImage, fileData)
  if not okImg then return nil end
  return image
end

-- Same as loadImage, but also returns the sprite's real DOOM offsets (see
-- readGrabOffset above) -- what lib/DoomWeapons.lua's view-model renderer
-- actually needs to position a psprite the way R_DrawPSprite really does
-- (r_things.c:676-695), not an independent per-sprite centering guess.
-- Returns a single table ({image, left, top}) rather than 3 separate
-- values so it drops straight into the existing single-return-value
-- weaponAsset() cache in DoomWeapons.lua without that cache needing to
-- change shape.
function DoomWadImport.loadSpriteAsset(nameSubstring)
  local bytes = readAssetBytes(nameSubstring)
  if not bytes then return nil end
  local left, top = readGrabOffset(bytes)
  local okData, fileData = pcall(love.filesystem.newFileData, bytes,
                                 nameSubstring .. ".png")
  if not (okData and fileData) then return nil end
  local okImg, image = pcall(love.graphics.newImage, fileData)
  if not okImg then return nil end
  return { image = image, left = left, top = top }
end

-- FIX 2026-08-08 (user report: "the mod lags HEAVILY when first shooting
-- a gun, first picking up a doom item, and first doing other things").
-- This function used to have NO cache of its own at all -- every single
-- CALL (not just the first) re-read the file from disk and re-decoded a
-- brand-new `love.audio.newSource`, even for a sound already played a
-- hundred times this session. Every real call site already treats the
-- return value as a reusable "master" to `:clone():play()`
-- (`DoomWadImport.playClone`, this file's own shared sound-trigger hub)
-- -- the caching this comment adds is simply completing that existing
-- contract, not changing it: a name looked up once now stays decoded for
-- the rest of the session, so only the GENUINELY first play of any given
-- sound pays the real disk-read + `newSource` decode cost, exactly
-- matching how `loadImage`'s own callers already cache by name
-- (`lib/DoomWeapons.lua`'s `weaponAsset`, `lib/DoomItems.lua`'s
-- `spriteCache`, etc.) -- sound was the one asset kind with no such cache
-- anywhere, on the hot path of literally every gunshot and pickup.
-- Same real per-name/per-WAD-state invalidation shape every other cache
-- in this project already uses.
local soundCache = {}
local soundCacheWadState = nil
function DoomWadImport.loadSound(nameSubstring)
  if DoomWadImport.status.state ~= soundCacheWadState then
    soundCacheWadState = DoomWadImport.status.state
    soundCache = {}
  end
  local cached = soundCache[nameSubstring]
  if cached ~= nil then return cached or nil end
  local value = false
  local bytes = readAssetBytes(nameSubstring)
  if bytes then
    local okData, fileData = pcall(love.filesystem.newFileData, bytes,
                                   nameSubstring .. ".wav")
    if okData and fileData then
      local okSnd, source = pcall(love.audio.newSource, fileData, "static")
      if okSnd and source then value = source end
    end
  end
  soundCache[nameSubstring] = value
  return value or nil
end

-- FEATURE 2026-08-07 -- user request: "add logs for sounds playing
-- because it seems like theres something wrong with an enormous amount
-- of the same sound playing over and over again. i dont know what it
-- is." Every one of this mod's own real sound-play call sites already
-- follows the identical shape (`local ok, snd = pcall(DoomWadImport.
-- loadSound, NAME); if ok and snd then pcall(function() snd:clone():
-- play() end) end`) scattered across 8 files -- routed all of them
-- through this ONE shared function instead so every actual trigger-to-
-- play (not just a load/cache hit) gets a real, timestamped console
-- line with a running per-name count for THIS session, cheap enough to
-- leave in permanently as a real diagnostic tool, not a temporary
-- print to be found and stripped out later.
--
-- EXTENDED 2026-08-07 (later, same day) -- user request: "add as many
-- logs to logs that would help diagnose when issues arise... let dated
-- timed log files... be made." Routed through `lib/DoomLog.lua`'s own
-- `DoomLog.write` (still prints live, same as before, PLUS appends to a
-- real per-session file on disk) instead of a bare `print`. `getDoomLog`
-- itself now lives up near `commandOutput` (moved 2026-08-19, so the
-- dialog-invocation diagnostics added there could reach it too -- see
-- that function's own header comment) -- still lazy, not a top-level
-- require: `lib/DoomLog.lua` itself requires THIS file (for
-- `absoluteModPath`/`ensureDir`), so a top-level require here would be a
-- genuine circular load -- deferred to first actual USE (the first real
-- call, long after every module has finished loading), not first
-- textual appearance, so relocating the function's own position in this
-- file changes nothing about when `V.require("DoomLog")` itself actually
-- runs.

local soundPlayCounts = {}
function DoomWadImport.playClone(name, snd)
  if not snd then return end
  soundPlayCounts[name] = (soundPlayCounts[name] or 0) + 1
  local ok, log = pcall(getDoomLog)
  if ok and log then
    log.event("SFX", "%s (#%d this session, t=%.2f)",
      name, soundPlayCounts[name], love.timer and love.timer.getTime() or 0)
  else
    print(("[PokeDoom][SFX] %s (#%d this session, t=%.2f)")
      :format(name, soundPlayCounts[name], love.timer and love.timer.getTime() or 0))
  end
  pcall(function() snd:clone():play() end)
end

-- "Did anything land in the output folder" check -- FIX 2026-08-19, same
-- real root cause as `assetList`'s own header comment above: a shell
-- `dir`/`ls` only ever sees real OS disk, never the sandbox overlay
-- `outputDir()`'s own path actually resolves to for mod code. Switched
-- to the same sandboxed `love.filesystem.getDirectoryItems`.
local function outputDirHasFiles(dir)
  local okItems, items = pcall(love.filesystem.getDirectoryItems, dir)
  return okItems and items and #items > 0 or false
end

-- ------- the extraction itself
--
-- FIX 2026-08-19 -- same real root cause as `assetList`/`outputDirHasFiles`
-- above: a shell `mkdir`/`New-Item` creates a folder on real OS disk,
-- which is NOT where `io.open`'s own sandboxed writes actually go for
-- this same path string (the per-mod compat overlay). Switched to the
-- sandboxed `love.filesystem.createDirectory` -- academic in practice
-- (the overlay's own writer already creates its parent directories on
-- demand), but keeps this function honestly doing what its name claims
-- against the SAME location everything else here now agrees on.
local function ensureDir(dir)
  pcall(love.filesystem.createDirectory, dir)
end

-- Exported for `lib/DoomLog.lua` -- see `DoomWadImport.absoluteModPath`'s
-- own header comment above for why this is exported rather than
-- re-derived a second time.
DoomWadImport.ensureDir = ensureDir


function DoomWadImport.extract(wadPath)
  local outDir = DoomWadImport.outputDir()
  if not outDir then return false, "could not resolve this mod's own output folder" end

  -- CORRECTED 2026-08-19 -- this comment used to say the opposite (a raw
  -- OS mkdir was needed because outputDir() resolves to a "real absolute
  -- path" outside love.filesystem's own sandboxed mount) -- confirmed
  -- wrong: `ensureDir` (above) now uses `love.filesystem.createDirectory`
  -- itself, which is the one that actually lines up with where
  -- `DoomWadNative.extract`'s own `io.open` writes really land (this
  -- mod's own compat overlay, not real OS disk -- see `assetList`'s own
  -- header comment for the full derivation).
  ensureDir(outDir)

  local ok, errOrCount = DoomWadNative.extract(wadPath, outDir)
  if not ok then
    return false, tostring(errOrCount)
  end
  return true
end

-- FEATURE 2026-08-08 (user report: "the mod lags HEAVILY when first
-- shooting a gun, first picking up a doom item, and first doing other
-- things"). A real callback registry -- the same pattern Phase 17's own
-- "notify DoomMidiImport.lua immediately via a callback registry"
-- already established in this project -- fired exactly once the WAD's
-- own extracted assets are actually usable (`status.state == "ready"`),
-- whether that's from a FRESH import this session or from
-- `checkExistingExtraction` below finding one already on disk from an
-- earlier session. Consumers (`lib/DoomWeapons.lua`/`lib/DoomItems.lua`,
-- see their own `prewarm()` exports) register a handler that decodes
-- every sprite/sound name they know they'll need up front, right here,
-- rather than paying that same real disk-read + `love.graphics.
-- newImage`/`love.audio.newSource` decode cost the FIRST time gameplay
-- happens to touch each one -- moving the one-time cost to a single
-- predictable moment (already-expected to take a moment, right after
-- EXTRACTING/at mod load) instead of a surprise mid-combat freeze.
-- "If already ready, call immediately" covers the case a consumer's own
-- `install()` registers AFTER this module's own boot-time
-- `checkExistingExtraction()` already fired the ready event -- real
-- install order between files isn't otherwise guaranteed.
-- DIAGNOSTIC 2026-08-08 -- user report: "still lags for first pickup of
-- the game" AFTER the prewarm fix above landed. Per CLAUDE.md's own "a
-- bug that survives one fix attempt gets logging before a second
-- attempt" rule -- rather than guess a second time, log every real step
-- of this mechanism (whether `onReady` fired immediately or queued,
-- whether `fireReady` actually ran and how many callbacks it called, and
-- each individual `prewarm()`'s own real elapsed time -- see `lib/
-- DoomItems.lua`/`lib/DoomWeapons.lua`'s own matching additions) so the
-- next report's log can show WHERE the remaining time is actually going,
-- rather than guessing whether the wiring never fired at all vs. fired
-- but was itself slow vs. fired and was fast but something ELSE (mesh
-- building, a first-time `require`, etc.) is the real remaining cost.
-- FIX 2026-08-08 -- user report: the synchronous prewarm above ("still
-- lags for first pickup") DID start running (confirmed by the previous
-- round's own logging) but turned out to be a genuine regression, not a
-- fix: "5 minutes and i knew i wasnt even close to done... in the
-- original doom game there is no lag, and you dont have to sit at a
-- terminal for 20 minutes for it to not lag." Moving every decode to ONE
-- big synchronous loop just moved dozens of small in-gameplay hitches
-- into a single much WORSE blocking freeze at load time -- confirming
-- the real, per-file cost (this project's own already-documented SMB-
-- over-a-shared-folder dev environment, `readAssetBytes`'s own plain
-- `io.open` per asset -- 1582 real files for a full IWAD, each its own
-- separate open/read/decode, unlike real DOOM's own single already-open
-- WAD file plus a byte-offset seek) is real and substantial per name,
-- not something a bulk synchronous pass can hide by doing it "at a
-- better time." Per CLAUDE.md's own standing practice (revert to the
-- simplest proven-safe shape rather than layer another guess on an
-- already-wrong one): this is no longer a synchronous prewarm at all.
-- `DoomWadImport.enqueuePrewarm(fn)` queues one unit of work (a single
-- sprite or sound load); `DoomWadImport.pumpPrewarm()` -- called once per
-- real `input.step` tick from `lib/DoomItems.lua`'s own existing hook --
-- drains the queue for at most `PREWARM_FRAME_BUDGET` real seconds each
-- call, however many (or few) items that turns out to be. The player can
-- start playing THE INSTANT the WAD is ready -- nothing blocks -- and
-- warming happens invisibly across ordinary frame time from then on; on
-- a slow filesystem the queue simply takes longer to fully drain, but
-- never costs more than a fraction of a millisecond of any single real
-- frame, so it can never read as "lag" the way either the original bug
-- or last round's own regression did.
local prewarmQueue = {}
local prewarmQueueTotal = 0
local prewarmStartTime = nil

function DoomWadImport.enqueuePrewarm(fn)
  if not fn then return end
  -- Marks the start of a NEW drain cycle (queue was empty, about to become
  -- non-empty) -- not just the very first one ever: a WAD re-import fires
  -- `fireReady` again (see `readyCallbacks`' own header comment above),
  -- re-enqueuing a fresh batch after an earlier one already fully drained.
  -- Gating this on `prewarmQueueTotal == 0` too (the original shape) meant
  -- it only ever fired the FIRST time, so a second cycle's own completion
  -- log below would report elapsed time back to the first WAD's own start
  -- -- including all the idle time in between -- instead of that cycle's
  -- own real background duration.
  if #prewarmQueue == 0 then
    prewarmStartTime = love.timer and love.timer.getTime() or 0
  end
  prewarmQueue[#prewarmQueue + 1] = fn
  prewarmQueueTotal = prewarmQueueTotal + 1
end

-- FIX 2026-08-08 (Phase 24 audit, Tier 1 #3) -- `prewarmDone` used to
-- latch permanently `true` the moment the queue first drained to empty,
-- and the early-return checked `prewarmDone` ITSELF (not queue
-- contents) -- so anything enqueued afterward (see the #4 fix directly
-- below, which makes a WAD re-import enqueue a fresh batch) would sit
-- untouched forever, since the gate never re-opened. `#prewarmQueue ==
-- 0` alone is already the correct, sufficient early-return: it's true
-- exactly when there's nothing to do, and naturally becomes false again
-- the instant `enqueuePrewarm` adds something new -- no separate latch
-- needed, and the completion log below still only fires once per real
-- drain-to-empty (now correctly repeatable across multiple drains
-- instead of only the first).
local PREWARM_FRAME_BUDGET = 1 / 500 -- real seconds per input.step tick -- a small slice of even a 60Hz frame's own 1/60s budget, never enough to read as a stutter
function DoomWadImport.pumpPrewarm()
  if #prewarmQueue == 0 then return end
  local deadline = (love.timer and love.timer.getTime() or 0) + PREWARM_FRAME_BUDGET
  local processed = 0
  while #prewarmQueue > 0 and (love.timer and love.timer.getTime() or 0) < deadline do
    local fn = table.remove(prewarmQueue, 1)
    pcall(fn)
    processed = processed + 1
  end
  if #prewarmQueue == 0 and processed > 0 then
    local ok, log = pcall(getDoomLog)
    if ok and log then
      local elapsed = (love.timer and love.timer.getTime() or 0) - (prewarmStartTime or 0)
      log.event("PREWARM", "background prewarm complete: %d item(s) enqueued so far, %.2fs of background time (never blocking)",
        prewarmQueueTotal, elapsed)
    end
  end
end

-- FIX 2026-08-08 (Phase 24 audit, Tier 1 #4) -- `readyCallbacks` used
-- to be CONSUMED (cleared) the instant `fireReady` ran, so a consumer's
-- own `onReady` registration only ever fired once, ever. `DoomItems.
-- install()`/`DoomWeapons.install()` each register their own `prewarm`
-- function exactly once, at mod boot -- fine for the very first WAD
-- becoming ready, but `DoomWadImport.import()` doesn't block a SECOND
-- import once `status.state` is already `"ready"` (only `"building"`
-- blocks, see that function below), and the CHOOSE DOOM WAD row calls
-- `import()` unconditionally on every press. Re-picking a WAD mid-
-- session would silently skip prewarming the newly-extracted assets
-- entirely -- reintroducing the exact "lags on first shot/pickup" bug
-- this whole system exists to prevent, with zero safety net the second
-- time. Fixed by never clearing `readyCallbacks` -- every registered
-- callback now fires on EVERY real "ready" transition, not just the
-- first. `prewarm()`'s own re-enqueue is cheap and correct to repeat:
-- each underlying `loadNamedSprite`/`loadItemImage`/`loadSound` already
-- has its own per-name cache, keyed off `DoomWadImport.status.state`
-- (confirmed elsewhere in this file), so re-running prewarm after the
-- SAME WAD's own re-ready is a fast no-op cache hit, and after a NEW
-- WAD's own ready is exactly the fresh decode pass that's actually
-- needed.
local readyCallbacks = {}
local function fireReady()
  local ok, log = pcall(getDoomLog)
  local t0 = love.timer and love.timer.getTime() or 0
  if ok and log then
    log.event("PREWARM", "fireReady: calling %d registered callback(s)", #readyCallbacks)
  end
  for _, fn in ipairs(readyCallbacks) do pcall(fn) end
  if ok and log then
    local t1 = love.timer and love.timer.getTime() or 0
    log.event("PREWARM", "fireReady: done, total=%.3fs", t1 - t0)
  end
end

function DoomWadImport.onReady(fn)
  local ok, log = pcall(getDoomLog)
  readyCallbacks[#readyCallbacks + 1] = fn
  if DoomWadImport.status.state == "ready" then
    if ok and log then log.event("PREWARM", "onReady: already ready, calling immediately") end
    pcall(fn)
  else
    if ok and log then
      log.event("PREWARM", "onReady: not ready yet (state=%s), registered for this and every future ready transition", tostring(DoomWadImport.status.state))
    end
  end
end

-- ------- the whole flow, from one keypress (mirrors StadiumRomPick.import)

-- DIAGNOSTIC 2026-08-19 -- direct user report: "clicking choose gzdoom
-- folder or choose doom wad does nothing now, on any platform... before
-- the file prompt would show up... now clicking either button gives zero
-- feedback. and other buttons work." This function's own real failure
-- paths (`validateHeader`/`extract` both failing) already set `status.
-- error`, but the two paths this report actually points at --
-- `canDialog()` returning false, or `choose()` itself returning nil --
-- have never logged anything at all, so there is currently zero real
-- signal to diagnose this from. Per CLAUDE.md's own "a bug that survives
-- one fix attempt gets logging before a second attempt" rule -- this is
-- the FIRST attempt, but the symptom itself ("does nothing," identical
-- on a file this session never touched at all) gives no basis to guess a
-- fix from, so logging comes first here too. Every branch below now logs
-- what actually happened, unconditionally (`step` even logs the wrapping
-- `pcall`'s own true/false so a genuine uncaught error inside `import`
-- itself -- which would otherwise look EXACTLY like "does nothing" -- is
-- distinguishable from every other branch here for the first time).
function DoomWadImport.import(game)
  local log = getDoomLog()
  if DoomWadImport.status.state == "building" then return false end

  local path = findImportedWad()
  if log then
    pcall(log.event, "WADIMPORT", "findImportedWad() returned %s", path and ("'" .. tostring(path) .. "'") or "nil")
    pcall(log.flush)
  end
  if not path then
    DoomWadImport.status.state = "failed"
    DoomWadImport.status.error = "place a .wad file in this mod's import/ folder, then press this again"
    return false
  end

  local validOk, why = DoomWadImport.validateHeader(path)
  if not validOk then
    if log then
      pcall(log.event, "WADIMPORT", "validateHeader FAILED: %s (picked: %s)", tostring(why), tostring(path))
      pcall(log.flush)
    end
    DoomWadImport.status.state = "failed"
    DoomWadImport.status.error = why
    return false
  end

  DoomWadImport.status.state = "building"
  local ok, err = DoomWadImport.extract(path)
  if not ok then
    if log then
      pcall(log.event, "WADIMPORT", "extract FAILED: %s (picked: %s)", tostring(err), tostring(path))
      pcall(log.flush)
    end
    DoomWadImport.status.state = "failed"
    DoomWadImport.status.error = err
    return false
  end
  DoomWadImport.status.state = "ready"
  DoomWadImport.status.error = nil
  if log then
    pcall(log.event, "WADIMPORT", "import SUCCEEDED (picked: %s)", tostring(path))
    pcall(log.flush)
  end
  fireReady()
  return true
end

-- ------- the options row

function DoomWadImport.row()
  return {
    id = "pokedoom_wad",
    label = DoomWadImport.LABEL,
    value = function()
      if DoomWadImport.status.state == "building" then return "EXTRACTING" end
      if DoomWadImport.status.state == "ready" then return "READY" end
      if DoomWadImport.status.state == "failed" then return "FAILED" end
      return "IMPORT"
    end,
    step = function(game)
      local log = getDoomLog()
      if log then pcall(log.event, "WADIMPORT", "row step() called") end
      local ok, err = pcall(DoomWadImport.import, game)
      if log then
        pcall(log.event, "WADIMPORT", "row step(): import() pcall ok=%s err=%s",
          tostring(ok), tostring(not ok and err or nil))
        pcall(log.flush)
      end
      return true
    end,
  }
end

-- ------- remembering a previous extraction across restarts
--
-- DoomWadImport.status is plain in-memory Lua state -- it starts fresh
-- as "none" every time the game (re)starts, with no idea whether a WAD
-- was already imported in an earlier session, even though the actually
-- extracted files are still sitting on disk from that import (nothing
-- here ever deletes them). If outputDir() already has anything in it,
-- treat that as "already extracted" instead of making the player
-- re-pick and re-run wadext against the same WAD every single launch.
--
-- FIX 2026-08-08 -- user report: "it was almost 30 seconds before any
-- prewarm even actually started... we shouldnt be prewarming before the
-- game starts anyway." Found the real cause tracing this file's own
-- module-load-time code, not the prewarm queue itself (which only
-- enqueues closures -- effectively instant): this check used to run
-- UNCONDITIONALLY the moment `require("DoomWadImport")` returns, which
-- is during MOD LOADING -- before the game window/menu exists at all,
-- since every mod's own top-level `require()` code runs synchronously
-- as part of the loader's own boot sequence (`gen1recomp-dev/src/mods/
-- Loader.lua`). `outputDirHasFiles` (below) shells out via a real
-- `cmd.exe`/`dir /b` subprocess spawn+wait -- lighter than `assetList`'s
-- own recursive `/s` scan, but still a genuine blocking OS process on
-- this project's own already-documented slow SMB-mounted-share dev
-- environment (the same class of shell-out already confirmed to cost
-- real seconds elsewhere in this file). Run at module load, THIS single
-- call was blocking the ENTIRE GAME from becoming playable, not merely
-- delaying item prewarm -- exactly the user's own correct diagnosis.
-- Deferred to the FIRST real `input.step` tick instead (a new
-- `DoomWadImport.install()`, called from `main.lua` alongside every
-- other file's own `install()`) -- by then the game window/menu is
-- already up and rendering, so even a genuinely slow shell-out here
-- reads as, at worst, a brief pause before the WAD-dependent features
-- (item pickups, weapon sprites) go live, never as "the game itself
-- won't start." Timed and logged so the next report can confirm the
-- real cost of this specific call directly.
local function checkExistingExtraction()
  local dir = DoomWadImport.outputDir()
  if dir and outputDirHasFiles(dir) then
    DoomWadImport.status.state = "ready"
    fireReady()
  end
end

local installed = false
local checkedExistingExtraction = false
function DoomWadImport.install()
  if installed then return end
  installed = true
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if not checkedExistingExtraction then
      checkedExistingExtraction = true
      local t0 = love.timer and love.timer.getTime() or 0
      pcall(checkExistingExtraction)
      local ok, log = pcall(getDoomLog)
      if ok and log then
        local t1 = love.timer and love.timer.getTime() or 0
        log.event("PREWARM", "checkExistingExtraction (deferred to first tick): took %.3fs, state=%s",
          t1 - t0, tostring(DoomWadImport.status.state))
      end
    end
    return next(game, dt)
  end)
end

return DoomWadImport
