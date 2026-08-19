-- FEATURE 2026-08-08 -- user's own explicit request, delivered alongside
-- picking "badge count" as the difficulty-gate design (see `lib/
-- DoomDemons.lua`'s own `DEMON_UNLOCK_ORDER` header comment for that
-- half): "i also only want weapons to be able to be gotten when getting
-- badges... the only 2 ways the player should be able to get weapons is
-- buy them in pokeshops, or through getting badges. it should be
-- dynamic which weapon you get, so the farther you are in the campaign,
-- the better weapon you will get from a badge." Also specifies the exact
-- announcement sequence: "A new enemy has found its way into Kanto." /
-- "??? now spawns." (the newly-unlocked demon) / "You've gained the
-- ???" (the newly-granted weapon, when this badge grants one).
--
-- No DOOM precedent for any of this (DOOM has no gym-badge concept at
-- all) -- this whole file is this mod's own design, same category of
-- judgment call as the town-invasion event or the random item scatter.
-- What DOES stay real and 1:1 is the underlying weapon grant itself
-- (`DoomWeapons.giveWeapon`, already a real `P_GiveWeapon` port) and the
-- badge data this reads (`gen1recomp-dev/src/inventory/Badges.lua`'s own
-- real `Badges.count`/`Badges.list`, the actual 8 Kanto gym badges in
-- their own real earn order).
--
-- ------- the hook: `OverworldState:checkVictoryRewards`
--
-- `gen1recomp-dev/src/world/OverworldController.lua:3052-3053` is the
-- ONE real place in the whole base engine that ever sets
-- `Game.save.inventory[reward.badge] = 1` (confirmed by grepping the
-- entire engine tree for the literal assignment -- a single hit) --
-- called from `OverworldState:checkVictoryRewards`, itself called once
-- per trainer-battle win from `OverworldState`'s own battle-finish
-- closure. Wrapped here the same live-table-field idiom this whole
-- codebase already uses for base-engine and host-mod fields alike
-- (`lib/DoomRewards.lua`'s own `BattleState:enemyMonFainted` wrap is the
-- closest sibling example) -- comparing `Badges.count` before and after
-- the real call, rather than re-deriving which badge was earned from
-- `trainerClass`/`partyIndex` ourselves, so this can never drift out of
-- sync with whatever `victories.lua`'s own real reward table actually
-- does.
local V = ...
local DoomDemons = V.require("DoomDemons")
local DoomWeapons = V.require("DoomWeapons")
local DoomHud = V.require("DoomHud")
local Options = V.require("DoomOptions")
local Host = V.host
local FirstPerson = Host.require("FirstPerson")

local DoomBadgeRewards = {}

-- ------- which badge grants which weapon
--
-- Fist and pistol are always owned from the start (`lib/DoomWeapons.
-- lua`'s own real `G_PlayerReborn` starting loadout, Phase 13) -- the
-- remaining 6 real DOOM weapons, in real DOOM's own rough power/pickup
-- order (chainsaw is an early E1M1-style melee upgrade over the fist;
-- shotgun/chaingun/rocket launcher/plasma rifle/BFG9000 follow real
-- DOOM's own number-key ordering, `lib/DoomWeapons.lua`'s own
-- `WEAPON_KEYS` "2".."7"). 8 real Kanto badges exist
-- (`gen1recomp-dev/src/inventory/Badges.lua`'s own `VANILLA` list) but
-- only 6 weapons remain to hand out -- badges 1-6 (Boulder..Marsh) each
-- grant one, badges 7-8 (Volcano, Earth) grant no NEW weapon since the
-- whole arsenal is already owned by then. A real, flagged gap, not a
-- silent one: those last two badges still fire the enemy-unlock half of
-- the announcement (see `DoomDemons.DEMON_UNLOCK_ORDER`, which runs the
-- full 8 badges) just not a weapon line.
local BADGE_WEAPON_ORDER = {
  "CHAINSAW", "SHOTGUN", "CHAINGUN", "ROCKETLAUNCHER", "PLASMARIFLE", "BFG9000",
}

local WEAPON_DISPLAY_NAME = {
  CHAINSAW = "chainsaw", SHOTGUN = "shotgun", CHAINGUN = "chaingun",
  ROCKETLAUNCHER = "rocket launcher", PLASMARIFLE = "plasma rifle",
  BFG9000 = "BFG9000",
}

-- ------- the announcement sequencer
--
-- `lib/DoomHud.lua`'s own `announce()` is a real, deliberate single-slot
-- mechanism (`player->message`'s own real DOOM behavior -- a second
-- write overwrites the first before it's ever shown, confirmed by
-- reading that function fresh) -- correct parity for an ordinary pickup,
-- but wrong for this feature: the user's own requested sequence is 2-3
-- DISTINCT lines that all need to actually be seen, not the last one
-- winning silently. Rather than turning the shared, real-DOOM-parity
-- `announce()` into a queue (which would change every OTHER caller's
-- own real single-overwrite behavior too), this is a small, local
-- sequencer specific to this feature: each line is held for
-- `ANNOUNCE_GAP` real seconds before the next one is handed to the
-- normal `announce()` call -- a plain counter, not a transplanted
-- formula, matching CLAUDE.md's own "avoid math-derived code" rule.
local ANNOUNCE_GAP = 3.0
local queue = {}
local queueTimer = 0

local function enqueue(text)
  queue[#queue + 1] = text
end

local function tickQueue(dt)
  if #queue == 0 then return end
  queueTimer = queueTimer - dt
  if queueTimer <= 0 then
    local text = table.remove(queue, 1)
    if DoomHud.announce then DoomHud.announce(text) end
    queueTimer = ANNOUNCE_GAP
  end
end

-- ------- the actual reward: called once per badge index (1 = Boulder ..
-- 8 = Earth) the instant `Badges.count` crosses it
local function onBadgeEarned(badgeIndex)
  local demonUnlockIndex = badgeIndex + 2 -- see DoomDemons.DEMON_UNLOCK_ORDER's own header comment
  local demonName = DoomDemons.DEMON_UNLOCK_ORDER[demonUnlockIndex]
  if demonName then
    enqueue("A new enemy has found its way into Kanto.")
    enqueue(DoomDemons.demonDisplayName(demonName) .. " now spawns.")
  end
  local weaponName = BADGE_WEAPON_ORDER[badgeIndex]
  if weaponName then
    pcall(DoomWeapons.giveWeapon, weaponName)
    enqueue("You've gained the " .. (WEAPON_DISPLAY_NAME[weaponName] or weaponName) .. ".")
  end
end

local function currentBadgeCount()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.save) then return 0 end
  local okB, Badges = pcall(require, "src.inventory.Badges")
  if not (okB and Badges) then return 0 end
  local okC, n = pcall(Badges.count, Game.data, Game.save)
  return (okC and n) or 0
end

-- A save that already held badges before this feature existed (or that
-- earned a badge while PKDOOM MODE was off, so `checkVictoryRewards`'s
-- own wrap below saw `Options.enabled() == false` and skipped it) would
-- otherwise never receive the weapon(s) those badges are meant to grant
-- -- `pickDemonName` (lib/DoomDemons.lua) has no equivalent gap, since it
-- reads the live badge count fresh on every call, but a weapon grant is
-- a one-time event that only happens right here. Silently backfills
-- (`giveWeapon` is itself idempotent -- a no-op if already owned) rather
-- than replaying the "You've gained the..." announcement for something
-- that isn't a new moment for the player -- called once on every save
-- load, same as `lib/DoomWeapons.lua`'s own `loadWeaponSave`.
local function catchUpOwnedWeapons()
  local badgeCount = currentBadgeCount()
  for n = 1, math.min(badgeCount, #BADGE_WEAPON_ORDER) do
    pcall(DoomWeapons.giveWeapon, BADGE_WEAPON_ORDER[n])
  end
end

local installed = false
function DoomBadgeRewards.install()
  if installed then return end
  installed = true

  V.mod.events:on("save.loaded", function() pcall(catchUpOwnedWeapons) end)
  V.mod.events:on("save.created", function() pcall(catchUpOwnedWeapons) end)

  local OverworldState = require("src.world.OverworldController")
  local realCheckVictoryRewards = OverworldState.checkVictoryRewards
  OverworldState.checkVictoryRewards = function(self, trainerClass, partyIndex)
    local before = currentBadgeCount()
    local result = realCheckVictoryRewards(self, trainerClass, partyIndex)
    local after = currentBadgeCount()
    if Options.enabled() and after > before then
      -- Loop rather than assume `after == before + 1`: a real gym win
      -- only ever grants one badge, but this stays correct even for an
      -- unusual case (a save import, a debug console poke) that jumps
      -- the count by more than one in a single call.
      for n = before + 1, after do
        pcall(onBadgeEarned, n)
      end
    end
    return result
  end

  -- Locked Decision 6 (CLAUDE.md): any always-on `input.step` tick this
  -- mod adds must check `FirstPerson.onTop()` so a paused game genuinely
  -- freezes -- the queue simply stops draining while paused/menu'd and
  -- resumes exactly where it left off, never torn down.
  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if Options.enabled() and FirstPerson.onTop() then
      pcall(tickQueue, dt)
    end
    return next(game, dt)
  end)
end

return DoomBadgeRewards
