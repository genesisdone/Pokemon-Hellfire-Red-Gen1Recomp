-- PokeDoom: a persistent, per-session log file -- user request
-- (2026-08-07): "weve had alot of bugs through the entire process of
-- making this mod. add as many logs to logs that would help diagnose
-- when issues arise, and let dated timed log files in a log folder in
-- the mod folder be made, so i can just send it to you."
--
-- Every real bug this whole project has diagnosed so far (this session
-- alone: the water/warp line-of-sight bug, the retarget-on-damage gap,
-- the auto-aim pitch sign inversion, the entity-clipping gap) was found
-- by reading a LIVE console window over the user's own shoulder in a
-- screenshot -- a real, working diagnostic channel, but a fragile one:
-- only ever as complete as whatever happened to fit in the visible
-- scrollback at the exact moment of the screenshot, and gone entirely
-- the instant the window closes. This file gives every one of those
-- same messages a second, PERSISTENT home: a real file on disk, one per
-- play session, dated and timed in its own filename.
--
-- CORRECTED 2026-08-07 (same day, next round) -- user report: "i dont
-- see any logs after playing. i tried playing 2 times." The first
-- version of this file tried exactly ONE approach (a raw `io.open`
-- against an absolute path built from `love.filesystem.getSource()` +
-- shelling out to `mkdir`/PowerShell to create the folder first, reused
-- from `lib/DoomWadImport.lua`'s own proven wadext-output-folder
-- machinery) and, on ANY failure anywhere in that chain, silently fell
-- back to console-only logging with no detail about WHY -- exactly the
-- kind of single-attempt, unverified-in-practice approach this
-- project's own standing practice warns against for anything that
-- can't actually be seen running here. Two real changes this round:
-- (1) every step now reports its OWN specific failure reason to the
-- console instead of one swallowed pcall, so if this still doesn't
-- work, the NEXT report can include the exact error line instead of
-- just "no logs" again; (2) a real, PROVEN-reliable fallback --
-- `love.filesystem` (LOVE's own sandboxed save-directory API,
-- `createDirectory`/`newFile`/`append`), the exact same mechanism this
-- project's own save-game system (`gen1recomp-dev/src/core/
-- SaveData.lua`) already relies on successfully -- if the real-mod-
-- folder attempt fails for ANY reason (a shell/PowerShell restriction,
-- a permissions error, an antivirus lock, `io.popen` disabled in this
-- particular LOVE build/config). Either way, the ACTUAL resolved path
-- is printed to the console once, so "where's the file" never depends
-- on which of the two backends actually worked.

local V = ...
local DoomWadImport = V.require("DoomWadImport")

-- FIX 2026-08-11 -- direct user report: with the new LOGGING toggle
-- (below) confirmed ON and persisted across a restart, "no file ever
-- shows up" -- not even the fallback, which should be near-impossible
-- to fail on its own (`tryLoveFilesystem` is LOVE's own sandboxed save-
-- directory API, unrelated to anything below). Root cause: this used to
-- be a plain top-level `local DoomOptions = V.require("DoomOptions")`,
-- then called directly as `DoomOptions.loggingEnabled` inside
-- `ensureOpen`'s own `pcall(...)`. If `DoomOptions` were ever nil at
-- that point (a require-order fragility this file's own top level has
-- no real control over -- `V.require`'s nested-load behavior this deep
-- in the require graph was asserted, not proven, for THIS specific
-- module pair), indexing `.loggingEnabled` on nil throws WHILE
-- CONSTRUCTING pcall's own arguments -- before pcall's protection even
-- starts -- which would silently kill `DoomLog.write` in its entirety:
-- no file, no console print, no trace anywhere. Lazy, pcall-guarded
-- instead, matching this project's own established `getDoomLog()`-style
-- idiom (`lib/DoomWadImport.lua`, same file) for exactly this class of
-- risk -- a failure here now safely defaults to "don't log" rather than
-- silently breaking the whole function.
local DoomOptions
local function getDoomOptions()
  if DoomOptions then return DoomOptions end
  local ok, mod = pcall(V.require, "DoomOptions")
  if ok then DoomOptions = mod end
  return DoomOptions
end

local DoomLog = {}

local logFile = nil     -- either a plain io file handle, or a love.filesystem File -- both support :write/:flush the same way
local logPath = nil      -- a human-readable path string, for the console message only
local sessionStart = nil
local usingFallback = false

local function timestampForFilename()
  local ok, s = pcall(os.date, "%Y-%m-%d_%H-%M-%S")
  return (ok and s) or tostring(os.time())
end

local function elapsed()
  if not sessionStart then return 0 end
  local ok, now = pcall(love.timer.getTime)
  if not (ok and now) then return 0 end
  return now - sessionStart
end

-- ------- attempt 1: a real file inside this mod's own folder on disk
-- (what the user actually asked for) -- reuses `lib/DoomWadImport.lua`'s
-- own exported `absoluteModPath`/`ensureDir`.
local function tryRealFolder(filename)
  local dir = DoomWadImport.absoluteModPath("logs")
  if not dir then
    return nil, "DoomWadImport.absoluteModPath(\"logs\") returned nil -- love.filesystem.getSource() or V.mod.path unavailable"
  end
  local ok, err = pcall(DoomWadImport.ensureDir, dir)
  if not ok then
    return nil, "ensureDir(" .. tostring(dir) .. ") raised: " .. tostring(err)
  end
  local path = dir .. "/" .. filename
  local fp, openErr = io.open(path, "w")
  if not fp then
    return nil, "io.open(" .. tostring(path) .. ", \"w\") failed: " .. tostring(openErr)
      .. " (the mkdir/PowerShell step above may not have actually created the folder -- see its own line above this one)"
  end
  return fp, nil, path
end

-- ------- attempt 2: LOVE's own sandboxed save-directory API -- no
-- shelling out, no raw OS path assembly, the same real mechanism this
-- project's own save-game system already uses successfully. Always
-- available in a real LOVE game; the only realistic way this can fail
-- is a genuinely full/read-only disk.
local function tryLoveFilesystem(filename)
  local okDir = pcall(love.filesystem.createDirectory, "logs")
  if not okDir then
    return nil, "love.filesystem.createDirectory(\"logs\") raised an error"
  end
  local rel = "logs/" .. filename
  local fp, openErr = love.filesystem.newFile(rel)
  if not fp then
    return nil, "love.filesystem.newFile(" .. rel .. ") failed: " .. tostring(openErr)
  end
  local okOpen, openErr2 = fp:open("w")
  if not okOpen then
    return nil, "File:open(\"w\") on " .. rel .. " failed: " .. tostring(openErr2)
  end
  local okSaveDir, saveDir = pcall(love.filesystem.getSaveDirectory)
  local shown = (okSaveDir and saveDir and (saveDir .. "/" .. rel)) or rel
  return fp, nil, shown
end

-- The actual file-creation attempt is LAZY -- triggered by the first
-- real log line, not by `DoomLog.install()` itself (called at MOD LOAD
-- time, before the game window/loop even exists). This is the one real
-- difference from `lib/DoomWadImport.lua`'s own proven use of the same
-- `ensureDir`/shell-mkdir mechanism: that only ever runs in response to
-- an interactive CHOOSE DOOM WAD menu press, well after the game has
-- fully booted -- shelling out to PowerShell/mkdir during the mod's own
-- synchronous load, before anything else has run, is untested territory
-- this project has never actually exercised before. Deferring the
-- attempt to the first real write sidesteps that timing difference
-- entirely, at zero cost (nothing needs a log file before something
-- actually happens worth logging).
-- FEATURE 2026-08-11 -- direct user request: "add option in settings to
-- turn logging on (off by default)." Checked FIRST, before touching
-- `attempted` at all -- so this stays live-toggleable: the option
-- starts OFF, `attempted` never latches while it's off, and flipping it
-- ON mid-session still opens a real file on the very next log line,
-- rather than the file only ever being decided once at whatever moment
-- the first log call happened to land. Console output (`DoomLog.write`'s
-- own `print(line)`) is intentionally NOT gated by this -- only the
-- persistent file is.
-- FIX 2026-08-11, round 2 -- the LOGGING toggle still didn't produce a
-- file after the round-1 fix above. Diagnosing this the normal way (send
-- another log) is circular -- the very thing broken is the mechanism
-- that would produce that log. `lastStatus` records exactly what
-- happened on the one real attempt this session (which branch ran, and
-- the real error string from whichever `io`/`love.filesystem` call
-- actually failed), and `DoomLog.status()` exposes it -- wired into the
-- LOGGING row's own displayed VALUE text (`lib/DoomOptions.lua`) so the
-- failure reason is readable directly in the pause menu, no console or
-- file needed to see it.
local lastStatus = "not attempted yet"
function DoomLog.status()
  return lastStatus
end

local attempted = false
local function ensureOpen()
  local opts = getDoomOptions()
  if not opts then lastStatus = "DoomOptions unavailable"; return end
  local okOpt, enabled = pcall(opts.loggingEnabled)
  if not (okOpt and enabled) then
    lastStatus = okOpt and "off" or ("loggingEnabled() errored: " .. tostring(enabled))
    return
  end
  if attempted then return end
  attempted = true

  local filename = "pokedoom-" .. timestampForFilename() .. ".log"

  -- FIX 2026-08-12 (direct user request: logs must land in the top-level
  -- `logs/` folder under the game's OWN save directory -- e.g.
  -- `%APPDATA%\pokemon-love2d\logs\` on this Windows machine -- not
  -- nested inside `mods/POKEDOOM/`, and without hardcoding any one
  -- system's path: "shouldnt be this specific path, but be agnostic for
  -- any system and os." `tryLoveFilesystem` below is EXACTLY that: pure
  -- `love.filesystem` calls (`createDirectory`/`newFile`), which already
  -- resolve the correct save directory for whatever OS this happens to
  -- run on, with zero OS-specific logic of this mod's own. `tryRealFolder`
  -- (real io.* against `DoomWadImport.absoluteModPath`) was the ORIGINAL
  -- primary attempt -- it targets `<gameRoot>/mods/POKEDOOM/logs/`, which
  -- only exists nested under the mod folder once `gameRoot()` resolves
  -- correctly (2026-08-12's own earlier fix, needed for real reasons --
  -- `tools/wadext.exe`/extracted assets genuinely have to live inside the
  -- mod's own folder, not the save directory root). That earlier fix's
  -- side effect was moving THIS file's own log output out of the
  -- top-level folder the user actually wants for logs specifically.
  -- Swapped: `tryLoveFilesystem` now tries FIRST (matching what the user
  -- asked for and already the more portable of the two), `tryRealFolder`
  -- stays as the fallback for the rare case the save directory itself
  -- isn't writable.
  local fp, err1, path1 = tryLoveFilesystem(filename)
  if fp then
    logFile, logPath, usingFallback = fp, path1, false
  else
    print("[PokeDoom][LOG] LOVE save-directory attempt failed (" .. tostring(err1) .. ") -- falling back to the real mod folder")
    local fp2, err2, path2 = tryRealFolder(filename)
    if fp2 then
      logFile, logPath, usingFallback = fp2, path2, true
    else
      print("[PokeDoom][LOG] fallback also failed (" .. tostring(err2) .. ") -- console output only this session")
      lastStatus = ("BOTH FAILED -- save directory: " .. tostring(err1) .. " | real folder: " .. tostring(err2))
    end
  end

  if logFile then
    sessionStart = love.timer and love.timer.getTime() or 0
    pcall(function()
      logFile:write(("PokeDoom session log -- started %s\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
      logFile:write("Every line below also prints live to the game's own console; this file is the same record, kept.\n\n")
      if logFile.flush then logFile:flush() end
    end)
    print("[PokeDoom][LOG] writing session log to: " .. tostring(logPath)
      .. (usingFallback and " (the real mod folder -- LOVE's own save directory wasn't writable this run, see the line above)" or ""))
    lastStatus = "OK: " .. tostring(logPath) .. (usingFallback and " (fallback)" or "")
  end
end

-- ADDED 2026-08-08 -- direct user request: "add to the logs: what exact
-- weapon i was using, time and date stamps for each line." The session-
-- relative `[%8.2f]` (seconds since this session started) already
-- existed and stays -- it's what makes correlating nearby lines within
-- one fight easy -- but it can't answer "when did this happen" once a
-- log file is looked at hours or days later, or whether two pasted logs
-- came from the same play session at all. Every line now also carries a
-- real wall-clock stamp.
local function wallClock()
  local ok, s = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  return (ok and s) or "????-??-?? ??:??:??"
end

-- FIX 2026-08-09 -- Phase 26 lag audit (user request: "audit the code
-- of the doom mod and look for any sources of lag"). `DoomLog.write`
-- used to call `logFile:flush()` -- a real, synchronous OS disk-write
-- syscall -- on EVERY single call, with no buffering at all. Confirmed,
-- independently, by FOUR separate audit passes as the shared root cause
-- behind their own hot-path findings: `demonResolver`/
-- `overworldNpcResolver` log every weapon shot against a demon/NPC (hit
-- OR miss), `computeAutoAimPitch` logs every shot fired at all, and
-- `DoomWadImport.playClone` logs every sound trigger project-wide,
-- including every gunshot -- meaning sustained chaingun fire alone was
-- forcing several synchronous disk flushes per real second, on exactly
-- the path players actually notice a stutter on. This file's own
-- comment already correctly notes every write is meant to be safe to
-- lose ("a logging failure... must never be what breaks actual
-- gameplay") -- the same reasoning extends naturally to accepting a
-- SMALL bounded amount of NOT-yet-flushed data at any instant, in
-- exchange for removing that syscall from the common case. Flushes now
-- happen periodically instead: after `FLUSH_INTERVAL_LINES` accumulated
-- writes, or after `FLUSH_INTERVAL_SECONDS` of real time since the last
-- flush, whichever comes first -- a plain counter/timer, not a
-- transplanted formula, matching CLAUDE.md's own "avoid math-derived
-- code" preference. Worst-case data loss on a hard crash is bounded to
-- under ~20 lines or ~1 real second, whichever is smaller -- a real,
-- deliberate, small tradeoff for a log file whose own stated purpose is
-- best-effort diagnosis, not a durability guarantee.
local FLUSH_INTERVAL_LINES = 20
local FLUSH_INTERVAL_SECONDS = 1
local linesSinceFlush = 0
local lastFlushTime = 0

local function maybeFlush(force)
  if not (logFile and logFile.flush) then return end
  linesSinceFlush = linesSinceFlush + 1
  local now = elapsed()
  if force or linesSinceFlush >= FLUSH_INTERVAL_LINES
     or (now - lastFlushTime) >= FLUSH_INTERVAL_SECONDS then
    logFile:flush()
    linesSinceFlush = 0
    lastFlushTime = now
  end
end

-- Exposed so a genuinely important moment (a caught error, a session
-- ending) can force the buffered tail out immediately rather than
-- risking it sitting unflushed -- not currently called from anywhere,
-- a real escape hatch for future use rather than unused dead code: this
-- project's own persistent-log feature exists specifically so a crash
-- doesn't lose the diagnostic trail, and a future crash-handler hook
-- should reach for this instead of re-adding a per-write flush.
function DoomLog.flush()
  maybeFlush(true)
end

-- Every real write is pcall-wrapped -- a logging failure (disk full, a
-- permissions error, the folder got deleted mid-session) must never be
-- what breaks actual gameplay, matching this whole project's own
-- established defensive style everywhere else a `pcall` already guards
-- something non-essential.
function DoomLog.write(line)
  local ok = pcall(function()
    ensureOpen()
    print(line) -- unchanged existing behavior -- still visible live in the console
    if logFile then
      logFile:write(("[%s][%8.2f] %s\n"):format(wallClock(), elapsed(), line))
      maybeFlush()
    end
  end)
  return ok
end

function DoomLog.event(category, fmt, ...)
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = fmt end
  DoomLog.write(("[PokeDoom][%s] %s"):format(category, msg))
end

function DoomLog.path()
  return logPath
end

-- Kept as a real, callable entry point (still called from `main.lua`)
-- for anyone reading that file expecting the usual `.install()`
-- convention every other module here follows -- but the actual work is
-- deferred, per `ensureOpen`'s own header comment above, so this itself
-- does nothing eager anymore.
function DoomLog.install()
end

return DoomLog
