-- PokeDoom: real, session-log-backed runtime diagnostics -- gate-state
-- toggle logging, one-time WAD-root/host-fix resolution logging, and the
-- `onTop()`/`CachePrebuild` watches. Factored out of `main.lua` 2026-08-19
-- during a project-wide readability audit -- this used to be a large
-- inline `do...end` block ahead of that file's own module-wiring
-- sequence; moved here verbatim (no behavior change) so `main.lua` reads
-- as "wire up every real feature module" without ~200 lines of
-- diagnostic history in the middle of it. The `input.step` handler body
-- is also split into named local functions here (`logToggleEdge`/
-- `logWadRootOnce`/`watchOnTopEdge`/`watchCachePrebuild`) instead of one
-- long branchy function, per that same audit.
--
-- DIAGNOSTIC 2026-08-11 -- user report: on a Steam Deck (Linux) build,
-- toggling DOOM MODE on does nothing at all -- no first-person switch,
-- nothing spawns -- after two rounds of fixes to the host-mod dependency
-- resolution (see BUGS.md's own 2026-08-11 entry) that turned out NOT to
-- be the cause: the Mods panel now shows PokeDoom as genuinely enabled
-- with no error, confirming `main.lua` itself loads and runs to
-- completion fine on this platform -- so the real gap is somewhere
-- AFTER load, specific to what happens once DOOM MODE is actually
-- switched on. Per CLAUDE.md's own "a bug that survives one fix attempt
-- gets logging before a second attempt is made" rule -- rather than
-- guess a third time with no way to test on the actual affected
-- platform, this logs the exact three live gating values almost
-- everything in this mod checks before doing anything
-- (`Options.enabled()`, `FirstPerson.driving()`, `FirstPerson.onTop()`)
-- to `lib/DoomLog.lua`'s own real, persistent, per-session log FILE
-- (`DoomWadImport.absoluteModPath("logs")`, or a `love.filesystem` save-
-- dir fallback -- either way a real file on disk, no dev console or
-- terminal needed to read it, just this mod's own `logs/` folder or the
-- game's own save directory) -- throttled to once every 2 real seconds
-- so a short play session still produces a readable, non-flooded log.
-- Once toggled on and reproduced, this log's own `[DIAG]` lines show
-- exactly which of the three gates is (or isn't) true, narrowing the
-- next fix to a real, evidenced cause instead of another guess.

local V = ...
local Host = V.host

local DoomDiagnostics = {}

local installed = false
function DoomDiagnostics.install()
  if installed then return end
  installed = true

  local mod = V.mod
  local Options = V.require("DoomOptions")
  local DoomWadImport = V.require("DoomWadImport")
  local DoomLog = V.require("DoomLog")
  local CachePrebuild, ChunkMesher, okPrebuild, okChunkMesher, prebuildResolveErr, chunkMesherResolveErr =
    V.require("DoomHostFixes").install()
  local FirstPerson = Host.require("FirstPerson")

  local diagAccum = 0
  local lastLoggedEnabled = nil
  local lastLoggedOnTop = nil
  local loggedWadRoot = false
  local lastPrebuildBuilding = false

  -- EXTENDED 2026-08-11, second same-day follow-up -- the previous
  -- periodic-only version (once every 2s) caught something the first
  -- capture couldn't: `onTop()` isn't stuck false the whole time -- it
  -- was genuinely TRUE for a real ~4s window (matching the user's own
  -- confirmed free movement and a real item pickup mid-window), then
  -- flipped back to false and stayed there for the rest of the session.
  -- That's a real state TRANSITION, not "never engages" -- worth
  -- catching the exact moment it happens, not just a snapshot up to 2s
  -- late. `logBreakdown` now fires on every real onTop() EDGE (in
  -- addition to the existing periodic sample), pulling apart `onTop()`'s
  -- own real body (`Game.stack:top() == Game.overworld`,
  -- `DramaticShapeVoxelMod-dev/lib/FirstPerson.lua:165-171`) into its
  -- own two sides plus `engaged()` (`driving()`'s other real half) --
  -- previously written but never actually captured, since the log that
  -- reported the true->false transition was still running the OLDER
  -- version of this file from before that breakdown existed.
  -- EXTENDED 2026-08-11, THIRD same-day follow-up -- the previous round
  -- confirmed `engaged()` is false for the ENTIRE session, including
  -- during the ~4s window `onTop()` was genuinely true (with confirmed
  -- free movement and a real item pickup) -- so `onTop()`'s own
  -- fluctuation was a red herring; `engaged()` is the real, permanent
  -- block. Its own real body (`DramaticShapeVoxelMod-dev/lib/
  -- VoxelState.lua`'s `Voxel.isFreeCam(Voxel.level)` AND `Voxel3D.lua`'s
  -- `Voxel3D.available()`) is itself two independently-failable halves --
  -- `Voxel3D.available()` in particular ends in a real GPU shader
  -- COMPILE attempt (`Voxel3D.shader()`, `pcall(love.graphics.newShader,
  -- src)`), cached FOREVER the first time anything calls it, success or
  -- failure, never retried -- a genuine, plausible Steam-Deck/Mesa-
  -- driver GLSL-compatibility gap would look EXACTLY like this: a
  -- permanent, session-long `false` with no error thrown anywhere
  -- (`pcall` swallows a real compile failure into a clean `false`
  -- return, by that function's own design). Splitting `engaged()` into
  -- its own two real halves, plus directly probing whether
  -- `Voxel3D.shader()` itself ever returned a real shader object,
  -- confirms or rules out a host-mod-level rendering-capability problem
  -- outside this addon's own scope (CLAUDE.md's own hard rule: never
  -- edit the host, a missing capability is a blocker to raise, not
  -- something to patch around) rather than a PokeDoom logic bug.
  -- EXTENDED 2026-08-11, FOURTH same-day follow-up -- confirmed:
  -- `Voxel3D.available()=true` AND `hasCompiledShader=true` the entire
  -- session, ruling out the GPU-shader-compile theory outright (good --
  -- 3D rendering genuinely works on this platform). The ONLY thing false
  -- the whole time is `isFreeCam`, which is pure logic (`Voxel.level ==
  -- Voxel.FP_LEVEL`, `FP_LEVEL = 6`, `VoxelState.lua:58-62`) -- so
  -- `Voxel.level` itself must not actually be sitting at 6, despite
  -- `lib/DoomView.lua`'s own `lockFirstPerson()` writing it there (via
  -- BOTH `Pipelines.setLevel("voxel", Voxel.FP_LEVEL)` and `Voxel.
  -- setLevel(Voxel.FP_LEVEL)`) every single `input.step` tick while
  -- `Options.enabled()` is true. That function's own header comment
  -- already documents a real, previously-fixed version of exactly this
  -- shape of bug (`Pipelines.level("voxel")` getting silently
  -- overwritten by something else later in the same frame) -- logging
  -- the RAW numeric level from both real stores (`Voxel.level` and
  -- `Pipelines.level("voxel")`, not just the derived boolean) shows
  -- directly whether the write is landing at all, or landing and then
  -- being reverted before the next sample.
  local function logBreakdown(tag)
    local okState, stackTopNil, overworldNil, sameRef, engaged, isFreeCam, voxel3dAvailable, hasShader, voxelLevel, pipelineLevel = pcall(function()
      local Game = require("src.core.Game")
      local Voxel = Host.require("VoxelState")
      local Voxel3D = Host.require("Voxel3D")
      local Pipelines = require("src.render.Pipelines")
      local top = Game.stack and Game.stack:top()
      local ow = Game.overworld
      local okShader, sh = pcall(Voxel3D.shader)
      return top == nil, ow == nil, top == ow, FirstPerson.engaged(),
        Voxel.isFreeCam(Voxel.level), Voxel3D.available(), okShader and sh ~= nil,
        Voxel.level, Pipelines.level("voxel")
    end)
    pcall(DoomLog.event, "DIAG",
      "%s breakdown ok=%s stackTop==nil:%s Game.overworld==nil:%s (top==overworld):%s engaged()=%s isFreeCam=%s Voxel3D.available()=%s hasCompiledShader=%s Voxel.level=%s Pipelines.level=%s (FP_LEVEL=6)",
      tag, tostring(okState), tostring(stackTopNil), tostring(overworldNil), tostring(sameRef),
      tostring(engaged), tostring(isFreeCam), tostring(voxel3dAvailable), tostring(hasShader),
      tostring(voxelLevel), tostring(pipelineLevel))
  end

  local function logToggleEdge(enabled)
    if enabled == lastLoggedEnabled then return end
    lastLoggedEnabled = enabled
    pcall(DoomLog.event, "DIAG", "DOOM MODE toggled: Options.enabled()=%s", tostring(enabled))
  end

  -- DIAGNOSTIC 2026-08-12 -- the CachePrebuild/ChunkMesher watch added
  -- for the prebuild-hang report has NEVER once fired in a real session
  -- log, despite the user reporting the row pressed multiple times --
  -- meaning either the row's click genuinely isn't reaching
  -- `CachePrebuild.start()` at all, or (checked first, since it's the
  -- cheaper thing to rule out) the pcall'd host `require("CachePrebuild"/
  -- "ChunkMesher")` resolution itself is silently failing every session,
  -- which would make every later check a guaranteed no-op regardless of
  -- what the player does. Logs the real, definitive answer once, at
  -- boot, instead of continuing to guess from the absence of a line that
  -- was never going to appear either way.
  local function logWadRootOnce()
    if loggedWadRoot then return end
    loggedWadRoot = true
    local ok, err = pcall(function()
      DoomLog.event("DIAG", "DoomWadImport root info: %s status.state=%s",
        DoomWadImport.gameRootDebugInfo(), tostring(DoomWadImport.status.state))
    end)
    if not ok then
      pcall(DoomLog.event, "DIAG", "DoomWadImport root info FAILED: %s", tostring(err))
    end
    pcall(DoomLog.event, "DIAG",
      "CachePrebuild resolve: ok=%s err=%s | ChunkMesher resolve: ok=%s err=%s",
      tostring(okPrebuild), tostring(prebuildResolveErr),
      tostring(okChunkMesher), tostring(chunkMesherResolveErr))
  end

  local function watchOnTopEdge()
    local okTop, onTop = pcall(function() return FirstPerson.onTop() end)
    if okTop and onTop ~= lastLoggedOnTop then
      local prev = lastLoggedOnTop
      lastLoggedOnTop = onTop
      pcall(DoomLog.event, "DIAG", "onTop() EDGE: %s -> %s", tostring(prev), tostring(onTop))
      logBreakdown("edge")
    end
    return okTop, onTop
  end

  -- FIX 2026-08-12 -- the periodic (every-2s) CachePrebuild watch below
  -- never once fired before the reported freeze: the log's own last
  -- periodic line landed at t=44.01s, the freeze happened before the
  -- next one at ~46s could log anything, and NOTHING appears in the
  -- session log after that point at all -- no Lua error either (lua-
  -- error.log's own last entry is still the older, unrelated save
  -- crash). That shape -- the log just stops, no crash, process has to
  -- be killed by hand -- means the freeze is a genuine hang somewhere
  -- in the host's own PREBUILD code, not a normal error a pcall could
  -- have caught, and every 2 seconds is far too coarse a window to
  -- catch a hang that can happen within one single frame of pressing
  -- the row. Checked every frame instead (unconditional, like the
  -- onTop() EDGE check), and flushed IMMEDIATELY (`DoomLog.flush`, not
  -- left to the periodic buffer) the instant `CachePrebuild.status()`
  -- first reports BUILDING -- exactly the same "the diagnostic's own
  -- line must survive whatever happens next" lesson the save-crash
  -- diagnostic already taught (`lib/DoomHostFixes.lua`'s own
  -- `CachePrebuild.start` wrap).
  local function watchCachePrebuildEdge()
    if not CachePrebuild then return end
    local okStatus, status = pcall(CachePrebuild.status)
    if not (okStatus and type(status) == "string") then return end
    local building = status:find("BUILDING") ~= nil
    if building == lastPrebuildBuilding then return end
    lastPrebuildBuilding = building
    local okDone, done, total = pcall(CachePrebuild.progress)
    local okPending, pending
    if ChunkMesher then okPending, pending = pcall(ChunkMesher.pending) end
    pcall(DoomLog.event, "DIAG",
      "CachePrebuild EDGE building=%s status=%s done/total=%s/%s ChunkMesher.pending()=%s",
      tostring(building), tostring(status), tostring(okDone and done or "?"),
      tostring(okDone and total or "?"), tostring(okPending and pending or "?"))
    pcall(DoomLog.flush)
  end

  local function watchCachePrebuildPeriodic()
    if not CachePrebuild then return end
    local okStatus, status = pcall(CachePrebuild.status)
    if not (okStatus and type(status) == "string" and status:find("BUILDING")) then return end
    local okDone, done, total = pcall(CachePrebuild.progress)
    local okPending, pending
    if ChunkMesher then okPending, pending = pcall(ChunkMesher.pending) end
    pcall(DoomLog.event, "DIAG",
      "CachePrebuild watch: status=%s done/total=%s/%s ChunkMesher.pending()=%s",
      tostring(status), tostring(okDone and done or "?"), tostring(okDone and total or "?"),
      tostring(okPending and pending or "?"))
    pcall(DoomLog.flush)
  end

  mod.hooks:wrap("input.step", function(next, game, dt)
    diagAccum = diagAccum + (dt or 0)
    local enabled = Options.enabled()
    logToggleEdge(enabled)
    logWadRootOnce()
    local okTop, onTop = watchOnTopEdge()
    watchCachePrebuildEdge()

    if diagAccum >= 2 then
      diagAccum = 0
      local okDrive, driving = pcall(function() return FirstPerson.driving() end)
      pcall(DoomLog.event, "DIAG",
        "enabled=%s driving=%s(ok=%s) onTop=%s(ok=%s)",
        tostring(enabled), tostring(driving), tostring(okDrive), tostring(onTop), tostring(okTop))
      logBreakdown("periodic")
      watchCachePrebuildPeriodic()
    end
    return next(game, dt)
  end)
end

return DoomDiagnostics
