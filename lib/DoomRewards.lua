-- PokeDoom Phase 13: battle-win item reward, locked at the user's explicit
-- direction (2026-08-05) and, per that same request, implemented alongside
-- the world-item scatter in `lib/DoomItems.lua`. No real DOOM equivalent to
-- port -- DOOM has no concept of "loot drops" at all, every item is
-- hand-placed and deterministic -- so, per CLAUDE.md's porting-methodology
-- hard rule, what stays 1:1 with DOOM is the item ROSTER and effects
-- (`lib/DoomItems.lua`'s own shared `REWARD_TABLE`/`applyEffect`, each
-- cited against its real `P_Give*` source); the REWARD MECHANIC itself
-- (rolling one on a battle win) is this mod's own design, same category of
-- judgment call as the random-Kanto-scatter placement.
--
-- REMOVED 2026-08-08 -- this file used to also grant a random unowned
-- weapon on every trainer-battle win. User's own explicit instruction:
-- "the only 2 ways the player should be able to get weapons is buy them
-- in pokeshops, or through getting badges" -- see `lib/DoomBadgeRewards.
-- lua` for the badge-earned replacement. Deleted outright rather than
-- left disconnected, per this project's own "don't leave dead code"
-- convention.
--
-- ------- the hook: NOT `battle.ended` -- the UI is already gone by then
--
-- The first version of this file hooked `Runtime.emit("battle.ended",
-- ...)` (`BattleState:finish()`, line 4649) -- a real, single choke
-- point every battle passes through, but confirmed too LATE for an
-- in-battle announcement: `finish()` itself calls `self.game.stack:pop()`
-- (line 4648) -- popping the battle screen off the UI stack -- BEFORE
-- that event ever fires, so `self:sayNext(...)` (the exact mechanism
-- `awardExp()` uses to show "X gained N EXP. Points!", `BattleState.lua:
-- 3694-3742`) has no battle text box left to queue into by the time this
-- file's own code could run. The user asked directly for parity with
-- how EXP is announced -- inside the battle's own UI, not a console
-- print or a message that only appears after returning to the overworld.
--
-- Found the real fix by tracing where `self.result = "win"` actually
-- gets set (`BattleState:enemyMonFainted`, line 3808 -- the money-for-
-- winning/trainer-end-battle-text block ending at line 3988): this runs
-- exactly ONCE per battle, only on the call where the LAST enemy mon
-- faints (a trainer battle with mons still alive takes an earlier
-- return inside this same function to send out the next one instead,
-- confirmed by reading the function's own full body, not assumed) --
-- and the battle UI is still fully alive at this point, mid-message-
-- queue, the exact same moment `awardExp()` (called at the very top of
-- this same function) shows its own EXP text. Wrapping the whole method
-- (a live table field on the `BattleState` class/prototype -- the same
-- monkey-patch idiom this codebase already uses for base-engine and
-- host-mod fields alike, CLAUDE.md's own sanctioned seam) and checking
-- `self.result == "win"` AFTER calling through gives exactly the right
-- once-per-battle, UI-still-alive hook, guarded per-battle-instance
-- (`self.pokedoomRewarded`) against `enemyMonFainted` being called
-- earlier in the SAME battle for a non-final enemy mon.

local V = ...
local DoomItems = V.require("DoomItems")
local Options = V.require("DoomOptions")

local DoomRewards = {}

-- ------- battle-win item reward (alongside the existing EXP system, not
-- replacing any part of it)
--
-- Real `P_GiveAmmo`'s own doc comment (p_inter.c:68-69) -- literally
-- says `num` "is the number of clip loads, not the individual count,"
-- so a 1-12 roll against that real parameter is a clean fit for "how
-- big a win reward feels," not an invented conversion: at the top of
-- that range, Cells (`clipammo[am_cell]=20`, `lib/DoomWeapons.lua`'s own
-- `CLIPAMMO`) pay out 12*20=240 cells in one win, a genuinely large,
-- rare-feeling top roll. Every non-ammo entry grants exactly 1 unit --
-- its own real DOOM effect applied once, per the user's own explicit
-- "1 for the rest." Returns the text to show, or nil if the roll turned
-- out to be a no-op (e.g. an armor roll that wasn't actually better than
-- what's already held) -- matching every real `P_Give*`'s own "wasn't
-- needed" contract, not force-announcing a reward that didn't apply.
local function awardBattleWinItem()
  local entry = DoomItems.pickItem()
  local ammoClips = entry.kind == "ammo" and math.random(1, 12) or nil
  local message = DoomItems.messageFor(entry) -- BEFORE applyEffect -- see that function's own header comment
  local applied = DoomItems.applyEffect(entry, ammoClips)
  if not applied then return nil end
  -- `showHudMessage = false`: this reward's own text goes into the
  -- battle's `self:sayNext(...)` queue (below, in `install()`), not the
  -- overworld HUD -- see `announcePickup`'s own header comment for the
  -- real bug this fixes (the message was showing twice, once correctly
  -- in-battle and once again, redundantly, back in the overworld).
  DoomItems.announcePickup(entry, message, false)
  return message
end

local installed = false
function DoomRewards.install()
  if installed then return end
  installed = true

  local BattleState = require("src.battle.BattleState")
  local realEnemyMonFainted = BattleState.enemyMonFainted
  function BattleState:enemyMonFainted(...)
    local result = realEnemyMonFainted(self, ...)
    if Options.enabled() and self.result == "win" and not self.pokedoomRewarded then
      self.pokedoomRewarded = true
      -- pcall-guarded: this whole block runs inside a wrapped, real
      -- BattleState method -- an unhandled error here (a bad roll out of
      -- DoomItems, a broken `sayNext` call) would otherwise propagate
      -- straight up through the base engine's own battle-end flow and
      -- take the battle screen down with it, instead of just silently
      -- skipping this optional reward, matching this codebase's own
      -- established defensive style for every other real-engine-method
      -- wrap (e.g. `lib/DoomBadgeRewards.lua`'s own identical
      -- `checkVictoryRewards` wrap).
      pcall(function()
        local itemMsg = awardBattleWinItem()
        if itemMsg then self:sayNext(itemMsg) end
      end)
    end
    return result
  end
end

return DoomRewards
