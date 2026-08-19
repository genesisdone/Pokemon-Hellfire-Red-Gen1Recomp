-- PokeDoom Phase 12: the player health/armor/damage pipeline -- a port of
-- `P_DamageMobj`'s own player branch (p_inter.c:774-884, read fresh at
-- the point of use here, not trusted from phases/phase-12-health-armor-
-- damage.md's own earlier audit, per CLAUDE.md's hard rule that a past
-- derivation can carry forward a mistake). See that phase doc for the
-- full audit and the phase's own central open question this file
-- deliberately does NOT resolve: nothing in this mod's own scope
-- currently damages the player at all (no attacking overworld NPCs, no
-- FPS combat in the turn-based battle system), so this pipeline is real
-- and correct but otherwise inert until that question has an answer --
-- exercised for now only through this file's own `pokedoom_hurt` dev
-- command, the documented stopgap that phase's own checklist calls for.
--
-- ------- what's ported, and what deliberately isn't
--
-- Ported: the starting values (`G_PlayerReborn`, g_game.c:800-833:
-- health=MAXHEALTH=100, everything else zeroed), the real armor-
-- absorption formula, the health/damagecount bookkeeping, and
-- `ST_calcPainOffset`'s real 5-tier pain formula (st_stuff.c:729-743).
--
-- NOT ported, all for real, documented reasons rather than oversight:
--   - The difficulty-based damage halving (`gameskill == sk_baby`,
--     p_inter.c:799-800) -- this mod has no difficulty-tier system at
--     all (Phase 6 backlog item, not built).
--   - The knockback/thrust physics (p_inter.c:806-832) -- real DOOM
--     shoves the target using the INFLICTOR's own world position and
--     mass; this mod has no "inflictor" concept with a world position
--     yet (the same "player.attacker has nowhere real to point" gap
--     phase-12-health-armor-damage.md's own Design section already
--     flags), so there is nothing to compute a shove direction FROM.
--   - The "end of game hell hack" (sector special 11, p_inter.c:838-842)
--     -- a level-specific scripted-death trick tied to a sector-special
--     system this mod has no equivalent of at all.
--   - Force-feedback rumble (`I_Tactile`, p_inter.c:883) -- hardware-
--     specific, no equivalent API reached for here.
--   - `damagecount`'s own real per-tic decay (`P_DeathThink`,
--     p_user.c:223-224 while alive too, via the main player-think path)
--     -- nothing in this mod's own scope reads `damagecount` for
--     display yet (Phase 11's ouch/attacked face states stay blocked
--     pending the same open question above), so there is nothing for a
--     decay tick to actually feed; the field is still tracked correctly
--     on every `damage()` call, just never ticked down on its own yet.

local V = ...
local DoomWadImport = V.require("DoomWadImport")
local Options = V.require("DoomOptions")

local DoomHealth = {}

-- MAXHEALTH = 100 (p_local.h:33). armorpoints/armortype/attacker/
-- damagecount all fall out of G_PlayerReborn's own `memset(p, 0, ...)`
-- before `health` is set explicitly -- ported here as the same starting
-- table shape, not deferred to an install()/reset function, since
-- nothing in this file needs the mode to be freshly toggled on the way
-- lib/DoomMove.lua's own momentum does (that file resets on the PKDOOM
-- MODE enable-edge because momentum can coast; health has no equivalent
-- "left over from last time" concern -- it just sits at whatever it
-- last was, matching a real DOOM player between levels of the same
-- game, not reset by the mode toggle itself).
local player = {
  health = 100,
  armorpoints = 0,
  armortype = 0,
  attacker = nil,
  -- playerstate: DOOM's own real field/enum names (PST_LIVE/PST_DEAD,
  -- p_player.h), added for Phase 15 (phases/phase-15-player-death.md).
  -- Set to PST_DEAD the instant `damage()` below drives health to 0 --
  -- this file's own equivalent of `P_KillMobj`'s player branch
  -- (p_inter.c:699-717). PST_REBORN (the "USE was pressed while dead"
  -- transition, p_user.c:227-228) is intentionally not modeled as a
  -- third state here: what a USE/fire press should actually DO once
  -- dead is Phase 15's own unresolved design question (three options,
  -- none chosen -- see that phase doc's Design section), so there is no
  -- real transition to represent yet.
  playerstate = "PST_LIVE",
  damagecount = 0,
  -- bonuscount: real DOOM's own pickup-flash counter
  -- (`P_TouchSpecialThing`'s common tail, `player->bonuscount +=
  -- BONUSADD`, `BONUSADD = 6`, p_inter.c:51,658) -- set on every
  -- successful pickup, decaying back to 0 the same way `damagecount`
  -- does. Reachable via Phase 13's own `DoomHealth.giveBonus()` below,
  -- since neither this mod's world pickups NOR its own battle/trainer
  -- rewards have a real `P_TouchSpecialThing` call site to inherit it
  -- from automatically.
  bonuscount = 0,
}

function DoomHealth.isAlive()
  return player.health > 0
end

function DoomHealth.isDead()
  return player.playerstate == "PST_DEAD"
end

function DoomHealth.playerState()
  return player.playerstate
end

-- The real `attacker` mobj `P_DeathThink` (p_user.c:200-221) turns the
-- death-camera to face, live, every tic -- exposed so `lib/DoomView.lua`
-- can read whatever `damage()` below stored (usually a live demon mob
-- table with its own `.px`/`.py`, occasionally just a descriptive string
-- for a source with no real world position, e.g. Horde's own contact
-- damage -- callers that can't offer a position simply don't get the
-- turn-to-face effect, checked defensively at the read site rather than
-- guessed at here).
function DoomHealth.attacker()
  return player.attacker
end

function DoomHealth.damageCount()
  return player.damagecount
end

function DoomHealth.bonusCount()
  return player.bonuscount
end

-- `BONUSADD = 6` (p_inter.c:51) -- the flash counter every real
-- `P_TouchSpecialThing` pickup adds, regardless of item type. Exposed
-- so Phase 13's own pickup/reward call sites (`lib/DoomItems.lua`,
-- `lib/DoomRewards.lua`) can trigger the SAME real signal
-- `ST_doPaletteStuff`'s bonus-tint flash and `ST_updateFaceWidget`'s
-- evil-grin state both key off, without each needing its own
-- BONUSADD-shaped knowledge.
function DoomHealth.giveBonus()
  player.bonuscount = 6
end

-- Real DOOM's own status-bar widgets show the RAW health/armor number,
-- NOT clamped to 100 despite the widget type being called "percent" --
-- a soulsphere (Phase 13's own future item roster) can genuinely read
-- "200%" in real DOOM, confirmed by `w_health`'s own real init binding
-- directly to `&plyr->health` with no clamp (`st_stuff.c:1298-1306`).
-- Exposed as two raw accessors rather than a single `healthPercent()`
-- name that would wrongly imply clamping.
function DoomHealth.health()
  return player.health
end

function DoomHealth.armor()
  return player.armorpoints
end

-- ST_calcPainOffset (st_stuff.c:729-743): `health = min(health, 100)`,
-- then `(100-health)*5/101` (`ST_NUMPAINFACES = 5`, confirmed fresh
-- here, not assumed from Phase 11's own earlier citation) floored via
-- real DOOM's own C integer division. Returns a plain 0-4 tier, NOT
-- DOOM's own `ST_FACESTRIDE`-multiplied flat face-array offset --
-- that multiply is C's own implementation detail for indexing one big
-- face array, not a functional part of "which of the 5 pain tiers is
-- this," and this port's own face tables (lib/DoomHud.lua) can index
-- by tier directly instead (CLAUDE.md's own "Nature of the port":
-- behavioral re-implementation, not a transplant of C's own array
-- arithmetic).
function DoomHealth.painTier()
  local health = math.min(player.health, 100)
  return math.floor(((100 - health) * 5) / 101)
end

-- P_DamageMobj's own player branch (p_inter.c:835-884), the exact real
-- order of operations: dead players take no further damage; a
-- sub-1000 hit is fully ignored under god mode or invulnerability
-- (opts.godmode/opts.invulnerable -- an explicit, documented seam for
-- phases/phase-14-god-mode.md to fill in later by passing its own real
-- cheat/powerup state through these two flags, NOT built here, since
-- this phase has no cheat-code or powerup system of its own to read
-- yet); armor absorbs a THIRD (type 1, green) or a HALF (type 2, blue)
-- of the damage, capped at whatever `armorpoints` actually has left,
-- reverting to type 0 exactly when fully spent; the REMAINING damage
-- (after absorption -- `amount` is mutated in place below, matching
-- the real C variable reuse) is what reaches health, floored at 0;
-- `attacker`/`damagecount` are set from the POST-absorption amount too
-- (confirmed directly against the source's own comment, p_inter.c:875:
-- "add damage after armor / invuln"), `damagecount` capped at 100
-- ("teleport stomp does 10k points...", the exact real reason DOOM
-- itself gives for that cap).
--
-- opts: { source (whatever dealt the damage, may be nil for
-- environmental damage, matching real DOOM's own nullable `source`),
-- attacker (optional -- a live table with `.px`/`.py`, for Phase 15's own
-- death-camera turn-to-face; falls back to `source` when omitted),
-- godmode, invulnerable }.
function DoomHealth.damage(amount, opts)
  opts = opts or {}
  if player.health <= 0 then return end
  -- INFINITE HEALTH setting (user request, 2026-08-07): gated HERE, at
  -- the actual mutation point, rather than only at today's one caller
  -- (`DoomHealth.hurt`'s dev command below) -- so it transparently
  -- covers whatever real damage source eventually lands too (Phase 14's
  -- own god-mode cheat, or a future demon/NPC attack), without every
  -- future caller needing to remember to pass it through `opts`. Reuses
  -- the exact `amount < 1000` real-DOOM threshold `opts.godmode`/
  -- `opts.invulnerable` already use (p_inter.c:847-852) rather than a
  -- separate, differently-shaped check.
  if amount < 1000 and (opts.godmode or opts.invulnerable or Options.infiniteHealthEnabled()) then
    return
  end

  if player.armortype ~= 0 then
    local saved
    if player.armortype == 1 then
      saved = math.floor(amount / 3)
    else
      saved = math.floor(amount / 2)
    end
    if player.armorpoints <= saved then
      saved = player.armorpoints
      player.armortype = 0
    end
    player.armorpoints = player.armorpoints - saved
    amount = amount - saved
  end

  player.health = math.max(0, player.health - amount)
  player.attacker = opts.attacker or opts.source
  player.damagecount = math.min(100, player.damagecount + amount)

  -- P_KillMobj's player branch (p_inter.c:699-717), the instant health
  -- reaches 0 -- Phase 15 (phases/phase-15-player-death.md). Everything
  -- else that branch does (MF_SOLID off, P_DropWeapon, forcing the
  -- automap closed) is either handled at the read sites (`lib/
  -- DoomWeapons.lua`'s own `Actions.lower`, now real DOOM's own dead-
  -- player branch too) or has no equivalent in this mod (no automap).
  if player.health <= 0 then
    player.playerstate = "PST_DEAD"
  end

  -- FIXED 2026-08-06 (user report: "make sure the damage overlay and
  -- player sound from doom is here. right now its not"). The visual
  -- flash (`lib/DoomHud.lua`'s own `drawPaletteFlash`) already existed
  -- and was already correctly wired to `damagecount` -- what was
  -- genuinely, completely missing was any sound at all. Real DOOM's own
  -- `MT_PLAYER` mobjinfo (`info.c:1108-1132`, read fresh here):
  -- `painchance = 255` (out of 256 -- effectively always) and
  -- `painsound = sfx_plpain` (`DSPLPAIN`, confirmed against `sounds.c`'s
  -- own real lump-name table). 255/256 is close enough to "always" that
  -- rolling it adds a real chance of silence with no audible benefit --
  -- played unconditionally on every landed hit instead, matching this
  -- project's own "avoid math-derived code" preference for the simpler,
  -- still-functionally-faithful equivalent. Real DOOM's own generic
  -- `P_DamageMobj` pain-sound trigger only fires on a hit that DOESN'T
  -- kill outright (`p_inter.c`'s own `if (target->health <= 0) {
  -- P_KillMobj(...); return; } ... painchance roll` -- the roll is only
  -- reached past the death check) -- restated here the same way: only
  -- while the player is still alive after this hit.
  if player.health > 0 then
    local ok, snd = pcall(DoomWadImport.loadSound, "DSPLPAIN")
    if ok and snd then DoomWadImport.playClone("DSPLPAIN", snd) end
  end
end

-- G_PlayerReborn's own real reset (g_game.c:800-833), this file's own
-- slice of it: health back to MAXHEALTH, armor/attacker/damagecount/
-- bonuscount zeroed, playerstate back to PST_LIVE. Deliberately does NOT
-- touch weapons/ammo (`lib/DoomWeapons.lua`'s own domain -- that file's
-- real weaponowned[]/ammo reset, Phase 13) or move the player anywhere --
-- Phase 15's own Design section lays out three different options for
-- what "the player died, now what" should actually mean in this mod, and
-- every one of them needs THIS reset as a shared first step, but which
-- other resets/actions accompany it depends on which option gets chosen.
-- Not yet wired to any real input -- exposed so that decision has a real
-- primitive to call into once made, rather than needing one invented
-- later under time pressure.
function DoomHealth.reborn()
  player.health = 100
  player.armorpoints = 0
  player.armortype = 0
  player.attacker = nil
  player.damagecount = 0
  player.bonuscount = 0
  player.playerstate = "PST_LIVE"
end

-- ------- pickup/reward "give" functions (Phase 13) -- the healing/
-- armor counterparts to `damage()` above, each a direct port of its own
-- real `P_Give*` function (p_inter.c, re-read fresh this round rather
-- than trusted from phases/phase-13-item-pickups.md's own summary).

-- P_GiveBody (p_inter.c:228-242): STIM/MEDI's own real shape -- refuses
-- (returns false) once already at/above MAXHEALTH=100, otherwise adds
-- `amount` capped at 100. NOT the same as BON1/SOUL below, which can
-- push health past 100 -- a real, deliberate DOOM asymmetry between the
-- "body" items and the "bonus" items, not collapsed into one function.
function DoomHealth.giveBody(amount)
  if player.health >= 100 then return false end
  player.health = math.min(player.health + amount, 100)
  return true
end

-- BON1 (p_inter.c:383-389): always +1 health, uncapped past 100 up to
-- 200, and -- confirmed directly from source, no `if` guard exists on
-- this case at all -- ALWAYS consumed regardless of current health,
-- unlike `giveBody` above.
function DoomHealth.giveHealthBonus()
  player.health = math.min(player.health + 1, 200)
  return true
end

-- SOUL (p_inter.c:400-407): the soulsphere, +100 health up to 200, same
-- "always consumed, no guard" shape as the bonus globe above.
function DoomHealth.giveSoul()
  player.health = math.min(player.health + 100, 200)
  return true
end

-- P_GiveArmor (p_inter.c:251-266): a real, easy-to-miss detail -- this
-- is NOT additive. `hits = armortype*100` (type 1 -> 100, type 2 -> 200)
-- is a hard SET, refused outright (`return false`) if `armorpoints` is
-- already >= that amount (don't let a worse pickup downgrade a better
-- one, or a redundant one do nothing but still get consumed).
function DoomHealth.giveArmor(armortype)
  local hits = armortype * 100
  if player.armorpoints >= hits then return false end
  player.armortype = armortype
  player.armorpoints = hits
  return true
end

-- BON2 (p_inter.c:391-398): always +1 armor, uncapped past 100 up to
-- 200, always consumed (same no-guard shape as BON1/SOUL) -- and sets
-- `armortype = 1` ONLY if currently 0 (wearing blue armor and picking up
-- a bonus globe stays blue, does not downgrade to green -- a real,
-- specific asymmetry confirmed directly from the source's own `if
-- (!player->armortype) player->armortype = 1`, not assumed).
function DoomHealth.giveArmorBonus()
  player.armorpoints = math.min(player.armorpoints + 1, 200)
  if player.armortype == 0 then player.armortype = 1 end
  return true
end

-- ------- decay: `damagecount`/`bonuscount` both tick down by 1 per real
-- DOOM tic (`P_PlayerThink`, p_user.c:355-359: `if (player->damagecount)
-- player->damagecount--; if (player->bonuscount) player->bonuscount--;`)
-- -- previously not ported at all (this file's own earlier header
-- comment: "nothing in this mod's own scope reads damagecount for
-- display yet"), now real, since `lib/DoomHud.lua`'s own palette-flash
-- and evil-grin face state (Phase 13) are genuine consumers. Converted
-- to real-time decay (`amount * dt * DOOM_TICRATE`) rather than a
-- frame-counted accumulator -- this is cosmetic screen-flash timing, the
-- same "doesn't need Phase-5-level rigor" reasoning `lib/DoomHud.lua`'s
-- own face-widget timing already uses, not a gameplay-rate stat.
local DOOM_TICRATE = 35
local installed = false
function DoomHealth.install()
  if installed then return end
  installed = true

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    player.damagecount = math.max(0, player.damagecount - dt * DOOM_TICRATE)
    player.bonuscount = math.max(0, player.bonuscount - dt * DOOM_TICRATE)
    return next(game, dt)
  end)
end

-- ------- dev command: hurt yourself without a real damage source
--
-- The exact same stopgap `lib/DoomWeapons.lua`'s own `pokedoom_give`
-- already established for "no pickup system yet" -- lets the Health%/
-- Armor% widgets and the damage pipeline itself be verified in-game
-- before phases/phase-12-health-armor-damage.md's own central open
-- question (what should actually damage the player) has an answer.
-- Unconditional, no `Options.enabled()` gate, matching `pokedoom_give`'s
-- own precedent exactly -- a raw testing tool, not a real game action.
function DoomHealth.hurt(amount)
  amount = tonumber(amount) or 10
  DoomHealth.damage(amount)
  print(("[PokeDoom] took %d damage -- health=%d armor=%d"):format(
    amount, player.health, player.armorpoints))
end

_G.pokedoom_hurt = DoomHealth.hurt

return DoomHealth
