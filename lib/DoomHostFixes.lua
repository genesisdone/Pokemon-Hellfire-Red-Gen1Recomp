-- PokeDoom: real, verified fixes/workarounds for HOST-mod
-- (potato_voxel-main) bugs found while developing this mod -- never an
-- edit to that mod's own files (CLAUDE.md's addon-not-a-fork rule), only
-- live table-field wraps, the same idiom this whole project already uses
-- elsewhere.
--
-- Factored out of `main.lua` 2026-08-19 during a project-wide
-- readability audit -- this used to sit inline near the top of that
-- file, ahead of PokeDoom's own actual module-wiring sequence, making a
-- newcomer scroll past ~130 lines of unrelated host-mod bug history
-- before reaching this mod's own real `install()` calls. Called once,
-- from `main.lua`, in the same relative position this code used to run
-- at (module load time, before any other require) -- no behavior change,
-- just moved.
--
-- DIAGNOSTIC 2026-08-12 (user report: "PREBUILD MAP CACHE" -- a
-- potato_voxel-main feature, this mod never calls it or anything it
-- depends on -- "tries to cache the first map, then immediately says
-- failed and stays on that," reproduced only with this mod installed).
-- `ChunkMesher.pump` (read directly, `potato_voxel-main/lib/
-- ChunkMesher.lua:1326-1338`) always picks an `urgent` job over
-- everything else in its queue if one exists; `CachePrebuild.update`
-- (same file's sibling `CachePrebuild.lua`) queues every prebuild job
-- as NOT urgent on purpose, specifically so background prebuilding
-- never steals a frame budget from the map the player is actually
-- standing on. If the CURRENT map keeps re-issuing urgent requests, a
-- background prebuild job can sit in the queue forever and never get a
-- turn -- which reads exactly like "stuck," with no error and no
-- crash, matching the report (no new lua-error.log entry from this).
-- Nothing found by reading this mod's own source calls `ChunkMesher.
-- request`/`Structures.invalidate` directly, so whether that's really
-- what's happening here, and if so what in THIS mod's own per-tick
-- work on the current map could be triggering it, needs real numbers,
-- not another guess -- watches `CachePrebuild.status()` and `ChunkMesher.
-- pending()` (both real, public exports; `CachePrebuild` may not exist
-- on every host fork this mod supports, hence the pcall) every 2s
-- while a build is actually running, on the SAME periodic diagnostic
-- tick already proven to reach the log file.

local V = ...
local Host = V.host

local DoomHostFixes = {}

-- Idempotency-guarded, matching every other real `.install()` in this
-- project -- `main.lua` calls this once directly for its own returned
-- values, and `lib/DoomDiagnostics.lua` also wants the same resolved
-- `CachePrebuild`/`ChunkMesher` state for its own periodic watch; without
-- this guard a second call would re-wrap `CachePrebuild.start` a second
-- time (double-logging every call) and re-run the MeshCache probe. Six
-- separate cached locals rather than a packed/unpacked table -- LuaJIT
-- (this engine's real runtime) doesn't reliably ship `table.unpack`.
local installed = false
local cachedCachePrebuild, cachedChunkMesher, cachedOkPrebuild, cachedOkChunkMesher,
      cachedPrebuildErr, cachedChunkMesherErr
function DoomHostFixes.install()
  if installed then
    return cachedCachePrebuild, cachedChunkMesher, cachedOkPrebuild, cachedOkChunkMesher,
      cachedPrebuildErr, cachedChunkMesherErr
  end
  installed = true
  local DoomLog = V.require("DoomLog")

  local okPrebuild, CachePrebuild = pcall(Host.require, "CachePrebuild")
  local prebuildResolveErr = (not okPrebuild) and CachePrebuild or nil
  if not okPrebuild then CachePrebuild = nil end
  local okChunkMesher, ChunkMesher = pcall(Host.require, "ChunkMesher")
  local chunkMesherResolveErr = (not okChunkMesher) and ChunkMesher or nil
  if not okChunkMesher then ChunkMesher = nil end
  local okMeshCache, MeshCache = pcall(Host.require, "MeshCache")
  if not okMeshCache then MeshCache = nil end

  -- DIAGNOSTIC 2026-08-12, round 2 -- both modules above resolve fine
  -- (confirmed by a real boot-time log line, not assumed), yet
  -- `CachePrebuild.status()` has never once reported "BUILDING" across
  -- multiple real button presses -- ruling out the resolve-failure theory
  -- outright. The remaining live question is whether the row's own press
  -- handler is reaching `CachePrebuild.start()` AT ALL, and if it is,
  -- what it actually returns -- `Prebuild.start` (potato_voxel-main/lib/
  -- CachePrebuild.lua:117-129) silently returns `false` with NO state
  -- change whenever `Prebuild.enumerate(data.maps)` comes back with zero
  -- jobs, which would produce exactly this symptom (repeated presses,
  -- status never leaves "PREBUILD", nothing for the status/pending watch
  -- above to ever catch). Wraps the live `CachePrebuild.start` field
  -- itself -- the same table-field idiom this whole project already uses
  -- for exactly this kind of external observation (CLAUDE.md) -- so every
  -- real call is logged with its actual return value, flushed
  -- immediately. This is the direct, definitive answer instead of another
  -- inference from a status string that might never even be reached.
  -- FIX 2026-08-12, round 3 -- the actual root cause, confirmed directly
  -- (not inferred): `potato_voxel-main/lib/MeshCache.lua`'s own
  -- `MeshCache.dir()` calls `os.execute('mkdir "<path>" 2>nul')` exactly
  -- once per process (`dirTried`/`cacheDir` are private upvalues, reset
  -- fresh each run) to make sure its disk cache folder exists. On Windows,
  -- plain `mkdir` returns a NONZERO exit code when the target directory
  -- ALREADY exists (verified live on this exact machine: `mkdir` against
  -- the real, already-present cache folder exits 1) -- `mkdir -p`, which
  -- WOULD be idempotent, is Unix-only syntax and always fails first on
  -- Windows, so the fallback plain `mkdir` is what actually runs, and it
  -- fails the instant the folder isn't brand new. Once that happens,
  -- `MeshCache.dir()` returns nil for the rest of that process's life, and
  -- every real call site in that file (`saveTerrain`/`saveWater`/
  -- `loadTerrain`/`saveAux`/`loadAux`/`invalidate`/`available` -- checked
  -- each one) reaches `MeshCache.dir()` through the live table field, not
  -- a captured local, and silently no-ops. Matches the real, verified
  -- symptom exactly: only the very first map ever cached (before the
  -- folder existed to trip this) has real files on disk, nothing since,
  -- and `CachePrebuild.start()` returning true=fresh-start on every one
  -- of 12 rapid presses (each run's jobs "complete" almost instantly
  -- because every write inside them fails immediately, not because they
  -- succeed).
  --
  -- Fixed here, not in that file: replaces the live `MeshCache.dir` field
  -- with a corrected version that verifies WRITABILITY directly (try
  -- writing a real probe file) instead of trusting a shell command's exit
  -- code, and only calls mkdir when the probe write actually fails --
  -- sidesteps the Windows already-exists case entirely, works identically
  -- whether the folder existed already or not, and preserves the same
  -- portableBaseDir-first/save-directory-fallback priority the original
  -- function used.
  if MeshCache then
    local dirResolved, dirValue = false, false
    local function resolvedMeshCacheDir()
      if dirResolved then return dirValue end
      dirResolved = true
      dirValue = false
      local okSave, SaveDataMod = pcall(require, "src.core.SaveData")
      local base
      if okSave and SaveDataMod and SaveDataMod.portableBaseDir then
        local okBase, b = pcall(SaveDataMod.portableBaseDir)
        if okBase and b then base = b end
      end
      if not base and love.filesystem and love.filesystem.getSaveDirectory then
        base = love.filesystem.getSaveDirectory()
      end
      if not base then return nil end
      local sep = package.config:sub(1, 1)
      local d = base .. sep .. "mod-derived" .. sep .. "potato_voxel" .. sep .. "meshes"
      local probe = d .. sep .. ".pokedoom-writable-probe.tmp"
      local function writable()
        local fp = io.open(probe, "wb")
        if not fp then return false end
        fp:close()
        os.remove(probe)
        return true
      end
      if not writable() then
        local q = d:gsub('"', '\\"')
        os.execute('mkdir "' .. q .. '" 2>nul')
        os.execute('mkdir -p "' .. q .. '" 2>/dev/null')
        if not writable() then return nil end
      end
      dirValue = d
      return d
    end
    pcall(function() MeshCache.dir = resolvedMeshCacheDir end)
  end

  if CachePrebuild and CachePrebuild.start then
    local innerPrebuildStart = CachePrebuild.start
    CachePrebuild.start = function(game)
      local ok, result = pcall(innerPrebuildStart, game)
      pcall(DoomLog.event, "DIAG",
        "CachePrebuild.start() CALLED -- pcall ok=%s returned=%s",
        tostring(ok), tostring(ok and result or result))
      pcall(DoomLog.flush)
      if ok then return result end
      error(result, 0)
    end
  end

  -- Cached (not left as this function's own private locals) because
  -- `lib/DoomDiagnostics.lua`'s own periodic diagnostic tick reads all
  -- six of these to keep watching `CachePrebuild.status()`/`ChunkMesher.
  -- pending()` live -- the same real values that block already closed
  -- over before this code moved into its own file.
  cachedCachePrebuild, cachedChunkMesher = CachePrebuild, ChunkMesher
  cachedOkPrebuild, cachedOkChunkMesher = okPrebuild, okChunkMesher
  cachedPrebuildErr, cachedChunkMesherErr = prebuildResolveErr, chunkMesherResolveErr
  return CachePrebuild, ChunkMesher, okPrebuild, okChunkMesher, prebuildResolveErr, chunkMesherResolveErr
end

return DoomHostFixes
