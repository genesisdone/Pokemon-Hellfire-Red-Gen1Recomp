-- PokeDoom Phase 21: the real DOOM demon roster as ambient, roaming
-- world entities -- requested 2026-08-06: "add all enemies to the game...
-- tie it into horde mode. also in the regular mode (horde mode disable)
-- the demons should be able to hurt and kill citizens & pokemon around
-- gen1recomp, they should only spawn outdoors... citizens should run
-- away when theyre being targeted by demons... the demon roaming
-- indefinitely, and killing anything it comes across." Roster data (real
-- mobjinfo stats + real `info.c` sprite/frame/tic tables) is Phase 21's
-- own already-completed audit (phases/phase-21-demon-roster.md) --
-- confirmed present in this project's own extracted reference WAD: the
-- 10-demon Doom-1/Ultimate-Doom roster (Zombieman, Shotgun Guy, Imp,
-- Demon, Spectre, Cacodemon, Baron of Hell, Lost Soul, Spider
-- Mastermind, Cyberdemon). The Doom-II-only roster that audit also found
-- (Chaingunner, Hell Knight, Arachnotron, Mancubus, Revenant, Arch-vile,
-- Wolfenstein SS, Commander Keen, Icon of Sin) has no assets in this
-- WAD -- same treatment as the super shotgun (Locked Decision 2), not
-- implemented here.
--
-- ------- a real, stated simplification, not a silent one
--
-- The sprite/frame/tic DATA below is read fresh from `info.c`'s own
-- state tables (grepped and hand-decoded this round, frame numbers ->
-- letters via DOOM's own `0=A,1=B,...` convention, `FF_FULLBRIGHT`
-- ignored the same way Phase 4 already does for weapon flashes -- this
-- mod has no lighting model to apply it differently anyway) -- not
-- guessed. What's DELIBERATELY simplified is the AI/animation DRIVER:
-- porting DOOM's own exact `P_SetPsprite`-style per-tic state-chain
-- machine a second time for 10 demons (each with its own real
-- attack/pain/chase timing) would be a project on the scale of Phases
-- 2-5 combined (the entire weapon framework); a demon here instead
-- cycles its own real run-frame LIST on a plain looping clock (the same
-- idiom `lib/DoomItems.lua`'s own ARM1/BON1 pickup animation already
-- uses) and plays its own real, full death/xdeath frame sequence
-- (`lib/DoomKill.lua`'s own Zombieman-XDeath technique, Phase 8,
-- generalized per demon) on a kill -- not DOOM's own frame-exact
-- attack timing. Movement/targeting is NOT ported from DOOM's own
-- `A_Chase`/`P_NewChaseDir` BSP-blockmap algorithm at all -- Phase 21's
-- own Audit 5 found and recommended reusing the host's own already-
-- working `HordeMobs.lua` flow-field/step-toward-target technique
-- instead, since DOOM's real algorithm assumes a world model (a fixed
-- blockmap, BSP line collision) this engine doesn't have; this file
-- restates a simpler direct-step version of that same idea (see "roam
-- and chase movement" below).

local V = ...
local Host = V.host
local DoomWadImport = V.require("DoomWadImport")
local DoomLog = V.require("DoomLog")
local DoomKill = V.require("DoomKill")
local DoomWeapons = V.require("DoomWeapons")
local DoomItems = V.require("DoomItems")
local DoomBlood = V.require("DoomBlood")
local DoomHud = V.require("DoomHud")
local DoomHealth = V.require("DoomHealth")
local Options = V.require("DoomOptions")
local DoomGround = V.require("DoomGround")
local DoomSpriteCache = V.require("DoomSpriteCache")
-- The real movement/pathing/targeting/attack-decision AI, split out
-- 2026-08-19 -- see that file's own header comment, and this file's own
-- `DoomDemonAI.attach(...)` call site below, for the full derivation.
local DoomDemonAI = V.require("DoomDemonAI")
local Voxel3D = Host.require("Voxel3D")
local SpriteBillboards = Host.require("SpriteBillboards")
local FirstPerson = Host.require("FirstPerson")
-- CHANGED 2026-08-19 -- direct user report: the real, current potato_voxel
-- release (1.8.2, confirmed by inspecting its actual shipped `lib/`
-- folder -- no `Horde.lua` or any of its siblings anywhere in it) has
-- dropped Horde Mode entirely, which this hard hard `Host.require` doesn't
-- survive -- `require` throws on a missing module, so simply loading this
-- file crashed PokeDoom's entire install on that host version (matching
-- the user's own Mod Manager screenshot: "FAILED: potato voxel: lib/
-- Horde.lua is missing"). `Horde` was never PokeDoom's own feature (see
-- `docs/horde-reincorporation.md`) -- only a few small, deliberate reuses
-- of the HOST's own already-existing fields survived that removal, so
-- this needs to become a soft dependency, not a hard requirement.
local okHorde, Horde = pcall(Host.require, "Horde")
if not okHorde then Horde = nil end

-- Lazy, matching this file's own established `require("src.core.Game")`
-- pattern elsewhere (deferred to first actual use, not top-level, since
-- a base-engine module isn't guaranteed ready at MOD install time the
-- way another mod's own `V.require`d lib is).
local Collision
local function getCollision()
  if Collision == nil then
    local ok, mod = pcall(require, "src.world.Collision")
    Collision = (ok and mod) or false
  end
  return Collision or nil
end

local DoomDemons = {}

-- ------- roster -- real mobjinfo stats (info.c, read fresh) plus real
-- per-demon sprite/frame/tic data (also info.c, read fresh this round)
--
-- `speed` is DOOM's own real map-units-per-tic mobjinfo value, kept only
-- as the RELATIVE scale every demon's own real-world-px/second move
-- speed is anchored against (see `DEMON_SPEED_SCALE`, in the
-- continuous-movement section below) -- CLAUDE.md's own "no principled
-- DOOM-map-unit conversion" rule, same proportional-anchor treatment
-- every other speed figure in this project already gets.
-- `melee`/`missile`/`hitscan` describe which real attack a demon has
-- (from its own real `meleestate`/`missilestate` fields) -- used only to
-- pick which real damage formula applies on a kill, not to gate whether
-- it can attack at all (every demon here kills a caught citizen/
-- follower outright on contact, matching Phase 8's own already-locked
-- "no per-NPC pain-state system, every hit that lands is a kill" design
-- for `ow.npcs`, restated here for the demon's OWN attack instead of
-- the player's).
local function frames(letters, tics)
  return { letters = letters, tics = tics }
end

-- ------- Phase 22, Round 1: per-monster damage, real DOOM formulas
--
-- Every one of these ten real attack functions (`p_enemy.c`, audited
-- fresh in `phases/phase-22-demon-behavior-parity.md`) rolls damage the
-- exact same simple shape: `(1 + P_Random()%dieSides) * damageMult` --
-- plain RNG, not the tic-rate/fixed-point kind of formula CLAUDE.md's
-- own "avoid math-derived code" rule warns about, so it's ported
-- directly rather than restated as something else. `math.random(n)`
-- already returns 1..n inclusive, the same shape as `1+P_Random()%n`,
-- so no bit-math is needed either.
--
-- Five of these ten demons have NO real melee attack at all in real
-- DOOM (Zombieman/Shotgun Guy/Spider Mastermind are pure hitscan,
-- Cyberdemon is pure rocket, Lost Soul's only "melee" is its own body-
-- charge slamming into you) -- Phase 22's own real ranged-attack round
-- hasn't shipped yet, so for now, until it does, each of those five
-- uses its own REAL ranged-attack damage roll as a temporary stand-in
-- for what happens on simple contact, rather than an invented flat
-- number or (worse) leaving them harmless until a future round. This
-- is flagged per-entry below and should be revisited once Phase 22's
-- own ranged-attack round actually gives each of them their real
-- attack instead of a contact stand-in.
DoomDemons.ROSTER = {
  ZOMBIEMAN = {
    sprite = "POSS", radius = 20, height = 56, speed = 8, spawnHealth = 20, painChance = 200,
    seeSound = "DSPOSIT1", painSound = "DSPOPAIN", deathSound = "DSPODTH1", activeSound = "DSPOSACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 4), pain = "G",
    die = frames({ "H", "I", "J", "K" }, 5), dieFreeze = "L",
    xdie = frames({ "M", "N", "O", "P", "Q", "R", "S", "T" }, 5), xdieFreeze = "U", hasXDeath = true,
    -- Real DOOM: pure hitscan (`A_PosAttack`, `(1+rand%5)*3`), no real
    -- melee attack at all -- Phase 22 Round 2: a real hitscan attack now,
    -- not a contact stand-in (see `attackType` below).
    damageDie = 5, damageMult = 3, attackType = "hitscan", attackSound = "DSPISTOL",
    -- Real ATK1-3 chain: E(10)->F(8,fire)->E(8) (`info.c:320-322`) --
    -- animation-fidelity audit, played once whenever an attack actually
    -- fires (see `startAttackAnim`).
    atk = frames({ "E", "F", "E" }, 8),
    -- `attackCycleTics` -- see this file's own 2026-08-10 "soldier
    -- demons killing the player too fast" fix, right before `tickDemon`'s
    -- own missile-fire branch, for the full derivation: the REAL total
    -- duration of one full attack state cycle (`10+8+8=26` tics,
    -- `info.c:320-322`), i.e. the minimum real time between the START of
    -- one shot and the earliest possible START of the next -- distinct
    -- from `atk`'s own uniform-8-tic ANIMATION DISPLAY value above,
    -- which was never meant to double as real per-state timing.
    attackCycleTics = 26,
  },
  SHOTGUYGUY = {
    sprite = "SPOS", radius = 20, height = 56, speed = 8, spawnHealth = 30, painChance = 170,
    seeSound = "DSPOSIT2", painSound = "DSPOPAIN", deathSound = "DSPODTH2", activeSound = "DSPOSACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 3), pain = "G",
    die = frames({ "H", "I", "J", "K" }, 5), dieFreeze = "L",
    xdie = frames({ "M", "N", "O", "P", "Q", "R", "S", "T" }, 5), xdieFreeze = "U", hasXDeath = true,
    -- Real DOOM: 3 independent hitscan pellets per attack (`A_SPosAttack`),
    -- each its own `(1+rand%5)*3` roll AND its own randomly-spread aim
    -- angle (`angle = bangle + (P_Random()-P_Random())<<20`) -- genuinely
    -- ported 2026-08-10 (see `firePellets`'s own header comment below for
    -- the full audit/derivation) rather than the earlier single-pellet
    -- simplification this comment used to describe.
    --
    -- FIXED 2026-08-10, same day -- user report: "it seems like enemies
    -- are hitting me a lot more than in the actual doom game... health
    -- going down fully within 5 seconds... it was the soldier enemies."
    -- The previous `attackCooldown = 0.4` on this entry was ITSELF the
    -- bug -- its own header comment (right above, now corrected) claimed
    -- it stood in for `A_SpidRefire`'s sustained-burst pacing, but
    -- re-reading `info.c:1164-1179`/`p_enemy.c:821-843` fresh shows
    -- Shotgun Guy's own real attack state (`S_SPOS_ATK1-3`) NEVER calls
    -- `A_SpidRefire` at all -- that function is Spider Mastermind-only
    -- (`S_SPID_ATK3`, a DIFFERENT state). Shotgun Guy fires ONE 3-pellet
    -- volley per attack, then must play out its FULL real state chain
    -- (10+10+10=30 tics, `info.c:353-355`) before `A_Chase` can even run
    -- again -- a real, hard minimum this mod had NO equivalent for at
    -- all (`checkMissileRangeReal`'s own movecount/reactiontime/hold-
    -- fire gating governs whether to START an attack from the chase
    -- state, the same real thing `P_CheckMissileRange` gates, but never
    -- modeled the attack STATE CHAIN's own separate minimum duration
    -- once firing begins) -- so the stale 0.4s value let this mod's own
    -- Shotgun Guy re-fire a full 3-pellet volley (up to 45 damage) at
    -- roughly DOUBLE real DOOM's own fastest possible cadence. Removed
    -- outright; `tickDemon`'s own missile-fire branch now falls back to
    -- `attackCycleTics` (see ZOMBIEMAN's own matching header comment)
    -- for any roster entry that doesn't need its own explicit override.
    damageDie = 5, damageMult = 3, attackType = "hitscan", attackSound = "DSSHOTGN",
    pelletCount = 3,
    -- Real ATK1-3 chain: E(10)->F(10,fire,fullbright)->E(10)
    -- (`info.c:353-355`) -- `attackCycleTics` is this SAME real total
    -- (10+10+10=30), the minimum real time before another shot.
    atk = frames({ "E", "F", "E" }, 9),
    attackCycleTics = 30,
  },
  IMP = {
    sprite = "TROO", radius = 20, height = 56, speed = 8, spawnHealth = 60, painChance = 200,
    seeSound = "DSBGSIT1", painSound = "DSPOPAIN", deathSound = "DSBGDTH1", activeSound = "DSBGACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 3), pain = "H",
    die = frames({ "I", "J", "K", "L" }, 8), dieFreeze = "M",
    xdie = frames({ "N", "O", "P", "Q", "R", "S", "T" }, 5), xdieFreeze = "U", hasXDeath = true,
    -- Real DOOM melee claw (`A_TroopAttack`, `(1+rand%8)*3`) when close,
    -- else a real thrown fireball (`MT_TROOPSHOT`, sprite `BAL1`,
    -- `(1+rand%8)*3` on impact -- same formula, real DOOM's own
    -- coincidence, not a mod simplification) when not -- Phase 22 Round 2.
    -- ADDED 2026-08-08 (sound-system audit) -- `A_TroopAttack`'s own
    -- melee branch (`p_enemy.c:923`) plays `sfx_claw` (DSCLAW) on every
    -- landed swing -- was entirely missing.
    damageDie = 8, damageMult = 3, attackType = "projectile_dual", meleeSound = "DSCLAW",
    projectileSprite = "BAL1", projectileDamageDie = 8, projectileDamageMult = 3,
    -- Real ATK1-3 chain (shared by melee and missile): E(8)->F(8)->
    -- G(6,attack fires) (`info.c:588-590`). `attackCycleTics` (2026-08-10
    -- fix, see ZOMBIEMAN's own matching header comment) is this SAME
    -- real total (8+8+6=22) -- this roster entry never had ANY minimum
    -- re-fire gate before this fix (only SHOTGUYGUY/SPIDERMASTERMIND/
    -- CYBERDEMON had an explicit `attackCooldown`), so its own fireball
    -- could refire as fast as `checkMissileRangeReal`'s own movecount/
    -- reactiontime gating alone allowed -- meaningfully faster than real
    -- DOOM's own state-chain minimum.
    atk = frames({ "E", "F", "G" }, 7),
    attackCycleTics = 22,
  },
  DEMON = {
    sprite = "SARG", radius = 30, height = 56, speed = 10, spawnHealth = 150, painChance = 180,
    seeSound = "DSSGTSIT", painSound = "DSDMPAIN", deathSound = "DSSGTDTH", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 2), pain = "H",
    die = frames({ "I", "J", "K", "L", "M" }, 6), dieFreeze = "N", hasXDeath = false,
    -- Real DOOM melee bite (`A_SargAttack`, `(1+rand%10)*4`) -- Demon's
    -- ONLY attack in real DOOM, no ranged fallback at all.
    damageDie = 10, damageMult = 4,
    -- ADDED 2026-08-08 (sound-system audit) -- found NOT inside
    -- `A_SargAttack` itself (that function has no `S_StartSound` call
    -- at all, confirmed by direct read) but in the GENERIC melee-attack
    -- trigger every demon with a real `meleestate` shares
    -- (`A_Chase`'s own melee branch, `p_enemy.c:724-729`:
    -- `if (actor->info->attacksound) S_StartSound(actor, actor->info->
    -- attacksound)`, fired the instant melee range is detected, before
    -- the attack state itself even runs) -- Demon/Spectre's own real
    -- mobjinfo `attacksound` is `sfx_sgtatk` (DSSGTATK, `info.c:1427`),
    -- non-zero, unlike Imp/Baron's own (0 -- their real sound instead
    -- comes from INSIDE their own attack function, see those roster
    -- entries). Restated here as the same `meleeSound` field/mechanism
    -- Imp/Baron already use -- functionally identical real result (a
    -- sound plays exactly once per landed melee attack), even though
    -- the real C code reaches it from a different call site.
    meleeSound = "DSSGTATK",
    -- Real ATK1-3 chain: E(8)->F(8)->G(8,bite lands) (`info.c:621-623`).
    atk = frames({ "E", "F", "G" }, 8),
  },
  SPECTRE = {
    -- Real DOOM: identical states/sounds/damage to Demon, MF_SHADOW
    -- (translucent) the only difference -- restated with a `translucent`
    -- flag rather than a duplicated table, per this project's own
    -- porting-methodology rule (functional parity, not byte-identical
    -- data duplication for its own sake).
    sprite = "SARG", radius = 30, height = 56, speed = 10, spawnHealth = 150, painChance = 180,
    seeSound = "DSSGTSIT", painSound = "DSDMPAIN", deathSound = "DSSGTDTH", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 2), pain = "H",
    die = frames({ "I", "J", "K", "L", "M" }, 6), dieFreeze = "N", hasXDeath = false,
    translucent = true,
    -- Same real attack as Demon -- byte-identical in `info.c`.
    damageDie = 10, damageMult = 4, meleeSound = "DSSGTATK",
    atk = frames({ "E", "F", "G" }, 8),
  },
  CACODEMON = {
    sprite = "HEAD", radius = 31, height = 56, speed = 8, spawnHealth = 400, painChance = 128,
    seeSound = "DSCACSIT", painSound = "DSDMPAIN", deathSound = "DSCACDTH", activeSound = "DSDMACT",
    -- Real DOOM: Cacodemon's own idle AND float-chase states are each a
    -- SINGLE self-looping frame -- unlike every other demon here (all
    -- of which alternate 2 idle frames), it never blinks between two
    -- letters at all (`info.c:638-639`, confirmed fresh in this
    -- animation-fidelity audit).
    stand = frames({ "A" }, 10), run = frames({ "A" }, 3), pain = "E",
    -- STATED GAP (animation-fidelity audit): real DOOM's own pain state
    -- is genuinely 3 frames, E,E,F (`info.c:643-645`) -- every OTHER
    -- demon's own real pain sequence is just its one letter held twice,
    -- so this project's own single-static-letter pain display already
    -- matches those exactly; Cacodemon is the only one where the real
    -- sequence actually ends on a DIFFERENT letter (F), which this
    -- single-letter model can't show. Not fixed -- would need its own
    -- separate animated-pain system (a third hold/index pair, alongside
    -- `stand`'s and `run`'s own) for the sake of one extra frame on one
    -- demon; judged disproportionate for now, flagged rather than
    -- silently accepted.
    die = frames({ "G", "H", "I", "J", "K" }, 8), dieFreeze = "L", hasXDeath = false,
    floats = true, -- MF_FLOAT|MF_NOGRAVITY (info.c) -- hovers rather than ground-walks
    -- Real DOOM melee bite (`A_HeadAttack`'s own internal melee-range
    -- short-circuit, `(1+rand%6)*10`) when close, else a real thrown
    -- fireball (`MT_HEADSHOT`, sprite `BAL2`, `(1+rand%8)*5` on impact)
    -- when not -- Phase 22 Round 2.
    damageDie = 6, damageMult = 10, attackType = "projectile_dual",
    projectileSprite = "BAL2", projectileDamageDie = 8, projectileDamageMult = 5,
    -- Real ATK1-3 chain: B(5)->C(5)->D(5,fire,fullbright) (`info.c:640-
    -- 642`). `attackCycleTics` (2026-08-10 fix, see ZOMBIEMAN's own
    -- matching header comment) is this SAME real total (5+5+5=15) --
    -- Cacodemon's own real fastest possible re-fire rate.
    atk = frames({ "B", "C", "D" }, 5),
    attackCycleTics = 15,
  },
  BARONOFHELL = {
    sprite = "BOSS", radius = 24, height = 64, speed = 8, spawnHealth = 1000, painChance = 50,
    seeSound = "DSBRSSIT", painSound = "DSDMPAIN", deathSound = "DSBRSDTH", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 3), pain = "H",
    die = frames({ "I", "J", "K", "L", "M", "N" }, 8), dieFreeze = "O", hasXDeath = false,
    -- Real DOOM melee claw (`A_BruisAttack`, `(1+rand%8)*10`) when close,
    -- else a real thrown fireball (`MT_BRUISERSHOT`, sprite `BAL7`,
    -- `(1+rand%8)*8` on impact) when not -- Phase 22 Round 2.
    -- ADDED 2026-08-08 (sound-system audit) -- `A_BruisAttack`'s own
    -- melee branch (`p_enemy.c:988`) plays `sfx_claw` (DSCLAW) on every
    -- landed swing, the same real sound Imp's own claw uses -- was
    -- entirely missing.
    damageDie = 8, damageMult = 10, attackType = "projectile_dual", meleeSound = "DSCLAW",
    projectileSprite = "BAL7", projectileDamageDie = 8, projectileDamageMult = 8,
    -- Real ATK1-3 chain: E(8)->F(8)->G(8,attack fires) (`info.c:673-
    -- 675`), the exact same real timing as Demon's own. `attackCycleTics`
    -- (2026-08-10 fix, see ZOMBIEMAN's own matching header comment) is
    -- this SAME real total (8+8+8=24).
    atk = frames({ "E", "F", "G" }, 8),
    attackCycleTics = 24,
  },
  LOSTSOUL = {
    sprite = "SKUL", radius = 16, height = 56, speed = 8, spawnHealth = 100, painChance = 256,
    seeSound = nil, painSound = "DSDMPAIN", deathSound = "DSFIRXPL", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "B" }, 6), pain = "E",
    -- Real DOOM: a Lost Soul's own corpse VANISHES rather than freezing
    -- permanently (`S_SKULL_DIE6`'s own real nextstate is `S_NULL`, not
    -- a `-1`-tics freeze the way every other demon's own final death
    -- frame is) -- ported faithfully as `dieVanishes`, a genuine,
    -- confirmed per-demon difference, not an oversight.
    --
    -- FIXED 2026-08-06 (fresh animation-fidelity audit): the real death
    -- chain is SIX letters, not five -- `S_SKULL_DIE1..DIE6` decode to
    -- F,G,H,I,J,K (`info.c:731-736`) -- this entry was missing the final
    -- "K" frame entirely, one real frame short before vanishing.
    die = frames({ "F", "G", "H", "I", "J", "K" }, 6), dieVanishes = true, hasXDeath = false,
    floats = true,
    -- Real DOOM: Lost Soul's own only attack IS a body-slam charge
    -- (`A_SkullAttack`) -- its own real impact damage, `(1+rand%8)*3`
    -- (`PIT_CheckThing`'s own shared `MF_SKULLFLY` collision formula).
    -- The charge MOVEMENT itself (flying directly at the target at a
    -- real faster-than-walking speed, rather than the normal grid-step
    -- walk every other demon here uses) is IMPLEMENTED, Phase 22 Round 3
    -- -- `attackType = "charge"` (see `startLostSoulCharge`/
    -- `tickLostSoulCharge`). ADDED 2026-08-08 (sound-system audit):
    -- `meleeSound` here is the real charge-launch shriek (`sfx_sklatk`,
    -- DSSKLATK), reusing the same field/mechanism every other melee-
    -- style attack sound in this roster uses -- see `startLostSoulCharge`'s
    -- own header comment for the exact real trigger point.
    damageDie = 8, damageMult = 3, attackType = "charge", meleeSound = "DSSKLATK",
    -- Real DOOM ATK3/ATK4 (`info.c:727-728`): C/D alternate at 4 tics
    -- for as long as the charge is actually in flight (`MF_SKULLFLY`),
    -- not just a brief windup before it -- `pose()` cycles this for the
    -- entire real duration of `m.charging`, matching that shape, rather
    -- than a one-shot flash like every other demon's own `atk`.
    atk = frames({ "C", "D" }, 4),
  },
  SPIDERMASTERMIND = {
    sprite = "SPID", radius = 128, height = 100, speed = 12, spawnHealth = 3000, painChance = 40,
    seeSound = "DSSPISIT", painSound = "DSDMPAIN", deathSound = "DSSPIDTH", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D", "E", "E", "F", "F" }, 3), pain = "I",
    -- `metalWalkIndices` (2026-08-08 audit): real `A_Metal`
    -- (`p_enemy.c:1765-1769`, `sfx_metal`/DSMETAL) fires at
    -- `S_SPID_RUN1`/`RUN5`/`RUN9` (`info.c:739,743,747`) -- indices
    -- 1/5/9 of this file's own shared `run` letter list above, which
    -- already encodes real DOOM's own identical RUN1-RUN12 letter
    -- pattern. Found entirely unplayed before this round.
    metalWalkIndices = { 1, 5, 9 },
    -- FIXED 2026-08-08 (per-monster audit, user request: "audit the
    -- spider mastermind's behaviour and animations... make sure theyre
    -- 1:1 with doom") -- real death chain `S_SPID_DIE1..DIE10`
    -- (`info.c:757-767`) is NOT a uniform hold: J=20 tics (A_Scream,
    -- the death cry), K/L/M/N/O/P/Q/R=10 tics each, S=30 tics (DIE10)
    -- BEFORE finally freezing forever on that same S (DIE11, tics=-1).
    -- This roster entry used to list only J-R at a flat 10 tics each,
    -- skipping S as a real held frame entirely and freezing on it
    -- immediately after R instead -- shorter overall (90 tics vs. the
    -- real 130) and with the opening scream frame held at HALF its own
    -- real duration. `ticsForDeathLetter` (this file's own new small
    -- helper, above `startDeath`) now reads a per-letter tics array for
    -- exactly this case; every other roster entry's own flat-number
    -- `die`/`xdie` fields are untouched and still work identically.
    die = frames({ "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S" },
                  { 20, 10, 10, 10, 10, 10, 10, 10, 10, 30 }),
    dieFreeze = "S", hasXDeath = false,
    boss = true,
    -- Real DOOM: no melee at all -- reuses Shotgun Guy's own exact
    -- pellet function (`A_SPosAttack`) in a sustained refire burst --
    -- confirmed CORRECT during the 2026-08-08 audit: `A_SPosAttack`
    -- itself hardcodes `S_StartSound(actor, sfx_shotgn)` on every real
    -- shot (`p_enemy.c:832`), and `mobjinfo[MT_SPIDER].attacksound` is
    -- literally `sfx_shotgn` too (`info.c:1608`) -- there is no separate
    -- "minigun" sound or attack function anywhere in the original
    -- source; the machine-gun IMPRESSION comes entirely from cadence
    -- (below), not a different sound.
    damageDie = 5, damageMult = 3, attackType = "hitscan", attackSound = "DSSHOTGN",
    -- FIXED 2026-08-08, same audit -- user report: "is not shooting me
    -- with a minigun like it does in doom." Real cadence, re-derived
    -- from the state chain (`S_SPID_ATK2`(4 tics, fires)->`ATK3`(4
    -- tics, fires)->`ATK4`(1 tic, `A_SpidRefire` check)->loops back to
    -- `ATK2`): successive shots are 4 tics apart, then 5 (4+1), then 4,
    -- then 5, alternating -- an average 4.5-tic real gap, `4.5/35`
    -- real seconds, roughly 7.8 shots/second once a burst is underway.
    -- The previous flat `0.3` (~3.3 shots/sec) was under half that real
    -- rate -- restated as the derived AVERAGE (a flat cooldown remains
    -- this project's own deliberate simplification of the exact
    -- alternating-gap shape, not the gap itself being wrong) rather
    -- than an unexplained round number.
    pelletCount = 3, attackCooldown = 4.5 / 35,
    -- Real ATK2/ATK3 (`info.c:752-753`, muzzle-flash frames G/H) -- the
    -- real ATK1 windup (A, a full 20 tics) is deliberately skipped here:
    -- this roster entry already fires on a fast cooldown rather than
    -- DOOM's own real slow-windup-then-continuous-burst, so a full
    -- 20-tic windup before every shot would read as "always winding up,
    -- never firing" against this mod's own much faster cadence.
    atk = frames({ "G", "H" }, 4),
  },
  CYBERDEMON = {
    sprite = "CYBR", radius = 40, height = 110, speed = 16, spawnHealth = 4000, painChance = 20,
    seeSound = "DSCYBSIT", painSound = "DSDMPAIN", deathSound = "DSCYBDTH", activeSound = "DSDMACT",
    stand = frames({ "A", "B" }, 10), run = frames({ "A", "A", "B", "B", "C", "C", "D", "D" }, 3), pain = "G",
    die = frames({ "H", "I", "J", "K", "L", "M", "N", "O" }, 10), dieFreeze = "P", hasXDeath = false,
    boss = true,
    -- Real DOOM: no melee at all -- a real thrown rocket (`MT_ROCKET`,
    -- same sprite/explosion this mod's own player rocket launcher
    -- already uses, `lib/DoomWeapons.lua`'s `PROJECTILE_VISUAL.ROCKET`),
    -- `(1+rand%8)*20` direct hit -- Phase 22 Round 2. Real 128-unit-
    -- radius splash on impact (`A_Explode`) implemented 2026-08-10
    -- (`demonProjectileSplash`, gated on `p.sprite == "MISL"` in
    -- `updateDemonProjectiles`) -- was a stated scope cut, now closed.
    -- STILL a stated simplification: real DOOM fires 3 rockets per
    -- attack cycle, re-aiming between each (`A_CyberAttack` x3, `info.c`'s
    -- own `S_CYBER_ATK1-6` chain) -- restated here as a single shot per
    -- cooldown rather than porting the exact 3-shot burst timing a second
    -- time for an ambient demon (this project's own "avoid math-derived
    -- code" preference for the simpler equivalent, same category as
    -- Spider Mastermind's own restated refire burst above) -- a real,
    -- flagged scope cut, not silently dropped.
    damageDie = 8, damageMult = 20, attackType = "projectile_only",
    projectileSprite = "MISL", projectileDamageDie = 8, projectileDamageMult = 20,
    attackCooldown = 1.5,
    -- Real ATK1/ATK2 (`info.c:820-821`): E(6)->F(12,rocket fires) --
    -- real DOOM repeats this 3x per cycle re-aiming between shots,
    -- restated here as a single shot per cooldown (see this entry's own
    -- comment above), so only one windup-then-fire pair is shown too.
    atk = frames({ "E", "F" }, 8),
  },
}

-- Stable, ordered name list -- for the spawn-test menu (cycling) and the
-- ambient spawner's own random pick, so iteration order never depends on
-- `pairs()`'s unspecified order (the same reasoning `lib/DoomWeapons.
-- lua`'s own `unownedWeapons` already documents for its own key list).
DoomDemons.NAMES = {
  "ZOMBIEMAN", "SHOTGUYGUY", "IMP", "DEMON", "SPECTRE", "CACODEMON",
  "BARONOFHELL", "LOSTSOUL", "SPIDERMASTERMIND", "CYBERDEMON",
}

-- FEATURE 2026-08-08 -- user's own explicit pick, from three difficulty-
-- distribution options presented earlier this session: "Badge count...
-- Bucket the 10 demons into tiers by the difficulty ranking we already
-- built for money rewards... gate which tiers can spawn by badge count."
-- `Badges.count(data, save)` (`gen1recomp-dev/src/inventory/Badges.lua`,
-- read fresh) is a real, already-tracked field -- the 8 real Kanto gym
-- badges, in their own real earn order (`BOULDERBADGE`.. `EARTHBADGE`,
-- that file's own `VANILLA` list, `data/scripts/victories.lua`'s real
-- gym sequence) -- no new save data needed. `DEMON_UNLOCK_ORDER` is this
-- roster sorted by the exact same per-kill `MONEY_REWARD` difficulty
-- proxy already used elsewhere in this file (ZOMBIEMAN 10 .. CYBERDEMON
-- 600) -- the 2 cheapest are available from a fresh save (0 badges), and
-- each of the 8 real badges unlocks exactly one more in ascending
-- difficulty order, so the last (Earth) badge unlocks the 10th and final
-- demon (Cyberdemon) -- 2 starting + 8 badge-gated = 10, the whole
-- roster, with no leftover gap. `lib/DoomBadgeRewards.lua` reuses this
-- exact same list for its own "a new enemy has found its way into
-- Kanto" announcement, so the two can never drift out of sync on what
-- unlocks when.
DoomDemons.DEMON_UNLOCK_ORDER = {
  "ZOMBIEMAN", "SHOTGUYGUY", "IMP", "LOSTSOUL", "DEMON", "SPECTRE",
  "CACODEMON", "BARONOFHELL", "SPIDERMASTERMIND", "CYBERDEMON",
}

-- Human-readable name for a roster key, for the badge-earned announcement
-- and any other player-facing text -- the roster itself is keyed by the
-- internal all-caps identifier (`ZOMBIEMAN`, `BARONOFHELL`), never shown
-- to the player as-is.
local DEMON_DISPLAY_NAME = {
  ZOMBIEMAN = "the Zombieman", SHOTGUYGUY = "the Shotgun Guy",
  IMP = "the Imp", LOSTSOUL = "the Lost Soul", DEMON = "the Demon",
  SPECTRE = "the Spectre", CACODEMON = "the Cacodemon",
  BARONOFHELL = "the Baron of Hell", SPIDERMASTERMIND = "the Spider Mastermind",
  CYBERDEMON = "the Cyberdemon",
}
DoomDemons.demonDisplayName = function(name) return DEMON_DISPLAY_NAME[name] or name end

local function currentBadgeCount()
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.save) then return 0 end
  local okB, Badges = pcall(require, "src.inventory.Badges")
  if not (okB and Badges) then return 0 end
  local okC, n = pcall(Badges.count, Game.data, Game.save)
  return (okC and n) or 0
end

-- The first 2 entries are always unlocked (0 badges); every entry after
-- that requires badge count `index - 2` (so index 3 = badge 1, index
-- 10 = badge 8), matching `DEMON_UNLOCK_ORDER`'s own header comment.
local function availableDemonNames(badgeCount)
  local list = {}
  for i, name in ipairs(DoomDemons.DEMON_UNLOCK_ORDER) do
    if i <= 2 or badgeCount >= (i - 2) then list[#list + 1] = name end
  end
  return list
end

-- The real, shared entry point: `ambientSpawnTick` below and `lib/
-- DoomTownInvasion.lua`'s own `beginInvasion` both now call this instead
-- of picking uniformly across the whole `DoomDemons.NAMES` roster, so
-- the badge-gated difficulty curve applies to ambient spawns AND town
-- invasions alike (user's own explicit instruction: "the dynamic
-- difficulty changes should apply to invasions too"). The TEST ENEMY
-- debug row (`spawnRow` below) deliberately still cycles the full,
-- ungated `DoomDemons.NAMES` list -- a modder's own explicit manual
-- test tool, not the real progression path this gates.
function DoomDemons.pickDemonName()
  local available = availableDemonNames(currentBadgeCount())
  if #available == 0 then return DoomDemons.DEMON_UNLOCK_ORDER[1] end
  return available[math.random(#available)]
end

-- ------- live demon state
--
-- One entry per spawned demon: `{ name, roster, cx, cy, px, py,
-- facing, hp, state = "roam"/"chase"/"dying", frame/frameHold (current
-- animation), target (an ow.npcs member, or nil), mapId, entity }`.
local demons = {}
local nextDemonId = 1

-- ------- map helpers, restated from lib/DoomItems.lua's own
-- (this project's own established "restate small pure-shape pieces per
-- file" precedent -- see that file's own header comment for why)
local function isInteriorMap(map)
  local ok, Game = pcall(require, "src.core.Game")
  if not (ok and Game and Game.data and Game.data.field) then return false end
  local indoor = Game.data.field.indoorEncounters
  if not (indoor and map and map.def) then return false end
  return map.def.index >= indoor.firstIndoorMap
     and map.def.tileset ~= indoor.excludedTileset
end

-- FEATURE 2026-08-08 -- user's own explicit instruction, superseding
-- this file's own earlier 2026-08-06 design ("demons should... sometimes
-- wonder out to a city where it can kill people," see `GRASS_SPAWN_
-- CHANCE`'s own header comment further down): "demons should not be
-- able to spawn in a town. they should only spawn in grass or other
-- areas. no towns." Real, structured town classification, confirmed by
-- reading `gen1recomp-dev/src/world/Map.lua` directly rather than
-- assumed: `Map.isFlyTown(def)` is the base engine's own real
-- `BuildFlyLocationsList` town/route distinction (the eleven vanilla
-- Kanto towns, `def.index < NUM_CITY_MAPS` -- explicitly NOT the same
-- as `Map.isOutdoor`, since Route 4/10 are outdoor with fly warps but
-- are not towns, `Map.lua:163-166`'s own comment). Exported here as
-- `DoomDemons.isTownMap` since `lib/DoomTownInvasion.lua` (the new
-- deliberate-invasion-event system this same request also asks for)
-- needs the identical check and already depends on this file for
-- `spawnDemon`/`NAMES` -- the reverse dependency would be circular.
local function isTownMap(map)
  if not (map and map.def) then return false end
  local ok, Map = pcall(require, "src.world.Map")
  if not (ok and Map and Map.isFlyTown) then return false end
  local okCall, isTown = pcall(Map.isFlyTown, map.def)
  return okCall and isTown or false
end
DoomDemons.isTownMap = isTownMap

local function walkableCell(map, cx, cy)
  return map:inBounds(cx, cy) and map:isWalkableCell(cx, cy)
     and not map:isWaterCell(cx, cy) and not map:isWarpTileCell(cx, cy)
end

-- FIXED 2026-08-07 -- user report: "this demon is... clipping through
-- objects they shouldnt be able to clip through." `walkableCell` (and
-- every demon movement check built on it -- `canOccupy`/`slideX`/
-- `slideZ`, below) only ever tested STATIC map-tile walkability --
-- never whether another solid entity (a real NPC, a trainer, the
-- player) is currently standing in that cell. Confirmed by reading the
-- PLAYER's own real collision fresh (`DramaticShapeVoxelMod-dev/lib/
-- FreeMove.lua`'s own `blockedCell`, `gen1recomp-dev/src/world/
-- Collision.lua`'s own `verdict`/`Collision.occupied`): the player's
-- own movement checks BOTH tile walkability AND entity occupancy
-- (`Collision.occupied(state.entities, cx, cy, mover)`, `state.entities`
-- confirmed to be the exact same `ow.entities` this whole project
-- already reads/writes elsewhere -- `OverworldController.lua`'s own
-- `self.entities = { self.player }` plus every real NPC inserted right
-- after it) -- demons had no equivalent second check at all, so any
-- non-`passable` NPC (this project's own fake entities -- blood, puffs,
-- items, gibs -- are all `passable=true` and correctly never block
-- anything) was simply invisible to demon collision, explaining exactly
-- the reported clipping. `entityBlocksCell` restates that same real
-- check for demon movement to call alongside `walkableCell`, not
-- instead of it -- `hasLineOfSight`/`blocksSight` (above) deliberately
-- do NOT gain this check: real DOOM's own `P_CheckSight` is a pure
-- wall-geometry test, never blocked by a mobj standing in the way.
local function entityBlocksCell(ow, cx, cy)
  local Coll = getCollision()
  if not (Coll and ow and ow.entities) then return false end
  local ok, occupant = pcall(Coll.occupied, ow.entities, cx, cy)
  return ok and occupant ~= nil
end

-- FIXED 2026-08-07 -- user report: a demon standing visibly right next
-- to the player kept failing to notice/attack them near a pond.
-- `hasLineOfSight` (below) was built by reusing `walkableCell` as its
-- own per-cell blocking test -- but `walkableCell` answers a MOVEMENT
-- question ("can a demon's own feet stand here"), not a SIGHT one, and
-- bundles THREE different exclusion reasons into one flag: a real solid
-- obstruction (wall/rock/building -- `not isWalkableCell`), water (this
-- mod's own deliberate demon-can't-swim rule, `isWaterCell`), and a
-- warp/door floor tile (`isWarpTileCell`). Real DOOM's own `P_CheckSight`
-- (p_enemy.c:188,201, `p_sight.c`) is purely a BSP/wall-geometry test --
-- nothing about a liquid floor or a warp-triggering floor tile blocks
-- vision in DOOM, only actual wall lines do. Reusing `walkableCell`
-- meant a single water or warp/door tile lying on the straight line
-- between a demon and its target -- trivially likely for two characters
-- standing on opposite sides of even a small pond, exactly this
-- screenshot's own situation -- silently failed `checkMeleeRangeReal`/
-- `checkMissileRangeReal`'s own real sight requirement every single
-- tic, even at melee range, with no way to ever recover since neither
-- side's position relative to the water changes. `blocksSight` is the
-- correct, narrower test: only a genuine non-walkable cell (a real
-- obstruction) blocks sight; water and warp/door tiles do not.
-- FIX 2026-08-08 -- user report: a demon "shouldve been able to see me"
-- across "a wall i can jump over, which is smaller and very easily able
-- to see above and across" -- a real Gen 1 LEDGE (`gen1recomp-dev/src/
-- world/OverworldController.lua`'s own real `checkLedgeHop`, matched
-- against `Game.data.field.ledges`' own real per-tileset `standingTile`/
-- `ledgeTile` pairs, `data/tilesets/ledge_tiles.asm`), not a genuine
-- wall. Confirmed by reading that real function fresh: a ledge hop is a
-- SEPARATE, special-cased tile-ID match, entirely independent of the
-- tile's own normal walkability -- meaning a ledge tile is very likely
-- NOT in the tileset's own generic `walkable` list at all (walking onto
-- it from the "wrong" side has to bump like a wall for the one-way hop
-- to make sense as a real mechanic), which is exactly why `blocksSight`
-- above -- built on plain `isWalkableCell` -- was treating a low,
-- see-over ledge exactly like a solid, floor-to-ceiling obstruction.
-- `isLedgeTile` checks a cell's own real collision tile ID against every
-- real ledge tile ID this map's own tileset uses (any facing/input --
-- for SIGHT purposes a ledge from any direction is still just a small
-- step, not a wall), cached per tileset since `Game.data.field.ledges`
-- doesn't change at runtime.
local ledgeTileSetCache = {}
local function ledgeTileSetFor(tileset)
  local cached = ledgeTileSetCache[tileset]
  if cached then return cached end
  local set = {}
  local ok, Game = pcall(require, "src.core.Game")
  if ok and Game and Game.data and Game.data.field and Game.data.field.ledges then
    for _, ledge in ipairs(Game.data.field.ledges) do
      if (ledge.tileset or "OVERWORLD") == tileset then
        set[ledge.ledgeTile] = true
      end
    end
  end
  ledgeTileSetCache[tileset] = set
  return set
end

local function isLedgeTile(map, cx, cy)
  local set = ledgeTileSetFor(map.def.tileset)
  return set[map:cellTile(cx, cy)] or false
end

local function blocksSight(map, cx, cy)
  if not map:inBounds(cx, cy) then return true end
  if map:isWalkableCell(cx, cy) then return false end
  return not isLedgeTile(map, cx, cy)
end

-- FEATURE 2026-08-06 -- user's own original ask: "demons should only
-- really spawn in grass, and be able to sometimes wonder out to a city
-- where it can kill people." `Map:isGrassCell` is the same real, public,
-- per-CELL check the base engine's own wild-encounter roll already uses
-- (`OverworldController.lua`'s own real encounter code: `self.map:
-- isGrassCell(p.cellX, p.cellY)`) -- the precise, per-tile signal, not a
-- map-wide guess. `preferGrass` biases toward it without making it
-- absolute: mostly grass, occasionally not -- GRASS_SPAWN_CHANCE is a
-- judgment call (no DOOM precedent for this at all), flagged adjustable
-- like every other undreived number in this project. Only the ambient
-- spawner passes `preferGrass` -- the SPAWN ENEMY debug row still
-- places its own test demon right next to the player regardless of
-- terrain, since that's a deliberate, convenient test spawn, not the
-- real ambient system this ask is actually about.
--
-- SUPERSEDED 2026-08-08 (see `isTownMap`'s own header comment above):
-- the "sometimes wonder out to a city" half of the original ask no
-- longer applies -- `ambientSpawnTick` now excludes town maps
-- entirely, at the user's own later, explicit instruction. This
-- constant/function still governs ordinary GRASS-vs-anywhere-else
-- placement on whatever non-town map a demon spawns on; the town
-- exclusion is a separate, additional gate in `ambientSpawnTick` below,
-- not a change to this preference itself.
local GRASS_SPAWN_CHANCE = 0.85

-- FIX 2026-08-08 -- user report: "make sure demon spawning detects
-- collisoons and walls and arent spawning where they arent supposed to
-- be and arent spawning in places they could get stuck," filed
-- alongside a real "couldn't find the last demon at all" report even
-- WITH the near-the-player radius fix already in. Root cause: every
-- spawn-point search up to this point only ever checked `walkableCell`
-- -- a bare SINGLE-CELL test, the same one `Map:isWalkableCell` itself
-- answers, with no idea whether an entity already occupies that cell
-- (two demons -- or a demon and an NPC/gib/item -- could spawn
-- overlapping) and no idea whether the cell is actually reachable at
-- all once occupied (a real, if rare, decorative 1-cell pocket fully
-- boxed in by unwalkable tiles on every side -- walkable to STAND on,
-- but with nowhere for the demon's own real movement/roam search,
-- `pickNewChaseDir`, to ever succeed FROM). `isGoodSpawnCell` below
-- adds both real checks this mod's own movement code already relies on
-- elsewhere: `entityBlocksCell` (the same real occupancy check
-- `canOccupy`, this file's own movement collision, already uses) for
-- the spawn cell itself, and a plain walkable-and-unoccupied-neighbor
-- check (at least one of the 4 cardinal cells) so a demon is never
-- placed somewhere its own real roam logic could never escape from.
-- FIX 2026-08-08 -- user report + screenshot: demons visibly standing in
-- a fenced-off decorative pocket beyond the player's own reachable side
-- of a town map. `isGoodSpawnCell` above only ever checked LOCAL
-- walkability (the cell itself, plus one open neighbor) -- correct for
-- "is this cell physically standable and not a single-cell dead end,"
-- but blind to whether that standable patch is actually CONNECTED to
-- the area the player can walk to at all. Real Gen 1 map data routinely
-- carries small walkable pockets never meant to be entered (a walled
-- garden behind a fence, decorative grass strips outside the intended
-- play area) -- walkable per the raw tile grid (`Map:isWalkableCell`,
-- confirmed by reading `gen1recomp-dev/src/world/Map.lua` fresh: it is
-- a pure per-cell tileset-membership test with no idea of connectivity),
-- but sealed off from the player's own reachable region by solid tiles
-- on every real path in. `reachableFromPlayer` is a bounded
-- 4-directional flood fill from the player's own current cell over the
-- same `walkableCell` test demon movement already uses, capped at
-- `MAX_REACHABLE_CELLS` so a large outdoor map can't make this
-- expensive -- this project's own "avoid math-derived code" rule
-- targets transplanted DOOM tic-rate/fixed-point formulas, not graph
-- search, so a real flood fill is the correct, readable tool here, not
-- a math substitute for one.
-- FIX 2026-08-11 -- user report + screenshot: a Town Invasion demon
-- spawning and then permanently "riding a wall," never finding the
-- player even at point-blank range or after nearby gunfire; user's own
-- follow-up clarified it "really felt like they were inside of an
-- invisible wall because i could not get in the same section as them."
-- Root cause: this flood's own neighbor test below only ever called
-- `walkableCell` (static tile data) -- the exact same single-check gap
-- `isGoodSpawnCell` was fixed for on 2026-08-07 (demons clipping through
-- solid NPCs) by ALSO checking `entityBlocksCell`, but that fix was
-- never carried into this shared BFS's own traversal, so a solid ENTITY
-- (most relevantly: any of this mod's own solid decorative props --
-- `lib/DoomProps.lua`'s `solid = true` roster entries, e.g. a fence,
-- pillar, or tree placed via the Q menu -- sitting across a narrow
-- chokepoint) is invisible to the flood: it walks straight through that
-- cell since the underlying TILE is walkable, and marks both sides
-- "reachable" from each other. But `entityBlocksCell` is exactly what
-- the player's own real movement collision (`FreeMove`'s `Collision.
-- occupied`, confirmed in this file's own 2026-08-07 fix comment above)
-- and a demon's own real movement (`canOccupy`, which already calls
-- `entityBlocksCell`) BOTH genuinely respect -- so a solid entity can
-- truly wall off a pocket from the player while this flood claims it's
-- connected. Since `DoomTownInvasion.lua`'s own `beginInvasion` computes
-- this SAME set once and threads it through both spawn placement
-- (`isGoodSpawnCell`) and, via `DoomDemons.noiseAlert`, the live
-- gunfire-alert check (`heardNoiseAlert`), the bug reached both symptoms
-- at once: a demon could spawn in a pocket the player can never actually
-- walk into, and gunfire would still read as "heard" there (the flood
-- says reachable) even though nothing about that demon's real situation
-- would ever let it close the distance. Fixed by adding the same
-- `entityBlocksCell` check to this flood's own per-step neighbor test,
-- not just to the final candidate cell `isGoodSpawnCell` already
-- checked.
local MAX_REACHABLE_CELLS = 4000
local function reachKey(map, cx, cy)
  return cy * map.widthCells + cx
end
local function reachableFromPlayer(ow)
  local map = ow.map
  local px = ow.player and ow.player.cellX
  local py = ow.player and ow.player.cellY
  if not (px and py and walkableCell(map, px, py)) then return nil end
  local seen = { [reachKey(map, px, py)] = true }
  local queue = { { px, py } }
  local head, count = 1, 1
  local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  while head <= #queue and count < MAX_REACHABLE_CELLS do
    local cur = queue[head]
    head = head + 1
    for _, d in ipairs(NEIGHBORS) do
      local nx, ny = cur[1] + d[1], cur[2] + d[2]
      local k = reachKey(map, nx, ny)
      if not seen[k] and walkableCell(map, nx, ny) and not entityBlocksCell(ow, nx, ny) then
        seen[k] = true
        count = count + 1
        queue[#queue + 1] = { nx, ny }
        if count >= MAX_REACHABLE_CELLS then break end
      end
    end
  end
  return seen
end
-- Exported so a caller spawning several demons in one batch (`lib/
-- DoomTownInvasion.lua`'s own `beginInvasion`) can compute this ONCE
-- and thread it through every `spawnDemonNear` call instead of each one
-- independently recomputing the same bounded BFS -- see this function's
-- own use inside `randomWalkablePoint`/`randomWalkablePointNear` for
-- the full Phase 26 derivation.
DoomDemons.reachableFromPlayer = reachableFromPlayer

-- P_NoiseAlert / P_FireWeapon (p_pspr.c:246-257, p_enemy.c:154-166,
-- re-read fresh) -- real DOOM's ONE call site: every player weapon
-- shot floods a noise outward from the player's own current SECTOR,
-- through connected areas (open, non-closed-door two-sided lines,
-- stopping after at most one `ML_SOUNDBLOCK`-flagged line), setting
-- `sec->soundtarget` on every sector reached. `A_Look` (the idle "no
-- target yet" state every monster starts in, p_enemy.c:604-627) checks
-- its OWN sector's `soundtarget` FIRST, before falling back to a real
-- sighted/facing-cone search (`P_LookForPlayers`, already ported here
-- as `findTarget`'s own non-allaround call) -- if set, a normal
-- (non-`MF_AMBUSH`) monster wakes and targets the noise source
-- INSTANTLY, no line-of-sight needed at all: real DOOM's own way of
-- letting a gunshot "pull" monsters from other rooms. No demon on this
-- roster is ever placed with a real ambush/deaf equivalent (confirmed:
-- nothing in this file's own roster table or spawn code sets one), so
-- that branch is N/A here, not a gap.
--
-- This mod's own per-map world has no equivalent "sector"/
-- "sound-blocking line" concept to flood through (a Gen1 building
-- interior is a wholly separate loaded map, not a sub-room of the
-- outdoor one the way a DOOM level partitions itself) -- the honest,
-- state-driven equivalent (CLAUDE.md's own "avoid math-derived code"
-- rule) is this file's own already-proven `reachableFromPlayer` flood,
-- the same bounded walkable-connectivity BFS spawn validation already
-- trusts, not an invented substitute.
--
-- Called from `lib/DoomWeapons.lua`'s own `fireWeapon` -- the single
-- real dispatcher every weapon's trigger-press already routes through,
-- the direct equivalent of `P_FireWeapon` itself. Cached by (map,
-- player cell) rather than recomputed on every call: an automatic
-- weapon (chaingun/plasma rifle) calls this every tic it's held, same
-- as real DOOM re-alerting on every individual round fired, but nothing
-- about the ALERTED AREA changes between shots unless the player has
-- actually moved to a different cell -- recomputing the bounded BFS on
-- every tic of held automatic fire would be a real, avoidable lag
-- source (Phase 26's own lag audit), and real DOOM's own `soundtarget`
-- is itself never invalidated by anything OTHER than a fresh
-- `P_NoiseAlert` call, so reusing the last flood until the player
-- actually moves is faithful, not a shortcut.
local noiseAlertMapId, noiseAlertCX, noiseAlertCY, noiseAlertReachable
function DoomDemons.noiseAlert(ow)
  if not (ow and ow.map and ow.player) then return end
  local mapId = ow.map.id
  local cx, cy = ow.player.cellX, ow.player.cellY
  if mapId ~= noiseAlertMapId or cx ~= noiseAlertCX or cy ~= noiseAlertCY then
    noiseAlertMapId, noiseAlertCX, noiseAlertCY = mapId, cx, cy
    noiseAlertReachable = reachableFromPlayer(ow)
  end
end

-- Read by `tickDemon`'s own idle ("roam", no target) branch, mirroring
-- `A_Look`'s real `targ = actor->subsector->sector->soundtarget` read --
-- true only while the LATEST noise alert (a) belongs to the demon's own
-- current map and (b) actually reaches the demon's own current cell.
local function heardNoiseAlert(ow, m)
  return noiseAlertMapId == ow.map.id and noiseAlertReachable
     and noiseAlertReachable[reachKey(ow.map, m.cx, m.cy)] and true or false
end

local function isGoodSpawnCell(ow, cx, cy, reachable)
  local map = ow.map
  if not (walkableCell(map, cx, cy) and not entityBlocksCell(ow, cx, cy)) then
    return false
  end
  if reachable and not reachable[reachKey(map, cx, cy)] then
    return false
  end
  local NEIGHBORS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  for _, d in ipairs(NEIGHBORS) do
    local nx, ny = cx + d[1], cy + d[2]
    if walkableCell(map, nx, ny) and not entityBlocksCell(ow, nx, ny) then
      return true
    end
  end
  return false
end

-- FIX 2026-08-09 -- Phase 26 lag audit: `reachable` is now an OPTIONAL
-- 4th parameter -- a pre-computed set from `reachableFromPlayer`, for a
-- caller spawning several demons in one batch (see `DoomTownInvasion.
-- lua`'s own `beginInvasion`, the confirmed real culprit: computing this
-- BOUNDED-BUT-REAL up-to-4000-cell BFS fresh for every one of 5-9
-- demons in a town invasion, all in the same synchronous tick, was a
-- genuine, confirmed frame-time spike -- independently found by two
-- separate audit passes). Falls back to computing it fresh when not
-- supplied, so every OTHER existing caller (the ambient spawner, the
-- SPAWN ENEMY debug row) is completely unaffected.
local function randomWalkablePoint(ow, preferGrass, reachable)
  local map = ow.map
  reachable = reachable or reachableFromPlayer(ow)
  if preferGrass and math.random() < GRASS_SPAWN_CHANCE then
    for _ = 1, 40 do
      local cx = math.random(0, map.widthCells - 1)
      local cy = math.random(0, map.heightCells - 1)
      local ok, isGrass = pcall(function() return map:isGrassCell(cx, cy) end)
      if isGoodSpawnCell(ow, cx, cy, reachable) and ok and isGrass then return cx, cy end
    end
  end
  for _ = 1, 40 do
    local cx = math.random(0, map.widthCells - 1)
    local cy = math.random(0, map.heightCells - 1)
    if isGoodSpawnCell(ow, cx, cy, reachable) then return cx, cy end
  end
  return nil
end

-- FIX 2026-08-08 -- user report on `lib/DoomTownInvasion.lua`'s own
-- event: "i got to 3 demons left then never saw another demon."
-- `spawnDemon` (via `randomWalkablePoint` above, `preferGrass=true`)
-- picks a point ANYWHERE on the whole map -- fine for ambient spawning
-- (the player is expected to run into them over the course of normal,
-- unhurried play), but wrong for a deliberate "invasion" the player is
-- meant to actively hunt down in one sitting: a town map can easily
-- place 2-3 of the random points behind buildings or in a far corner
-- the player's own current position gives no real reason to walk
-- toward. A real invasion should converge AROUND the player, not
-- scatter across the whole map. Same real bounded-retry shape as
-- `randomWalkablePoint` above (including the same `isGoodSpawnCell`
-- collision/reachability check, not just bare walkability), just
-- centered on a given cell within a fixed radius instead of the whole
-- map, falling back to the unconstrained version if nothing nearby is
-- found (should be rare -- towns aren't large enough for a real search
-- radius to fail outright).
-- `reachable` -- see `randomWalkablePoint`'s own matching header
-- comment above -- an optional pre-computed set, so a caller spawning a
-- whole batch of demons around the same center only pays the BFS once.
local function randomWalkablePointNear(ow, centerCx, centerCy, radius, reachable)
  local map = ow.map
  reachable = reachable or reachableFromPlayer(ow)
  for _ = 1, 40 do
    local cx = centerCx + math.random(-radius, radius)
    local cy = centerCy + math.random(-radius, radius)
    if cx >= 0 and cy >= 0 and cx < map.widthCells and cy < map.heightCells
       and isGoodSpawnCell(ow, cx, cy, reachable) then
      return cx, cy
    end
  end
  return randomWalkablePoint(ow, false, reachable)
end

-- ------- animation clock -- same looping-clock idiom as
-- lib/DoomItems.lua's own ARM1/BON1 pickup animation, restated
local DOOM_TICRATE, FRAME_RATE = 35, 60
local function ticsToFrames(tics)
  return math.max(1, math.floor(tics * FRAME_RATE / DOOM_TICRATE + 0.5))
end

-- A_Metal (p_enemy.c:1765-1769): plays a real walking-clank sound
-- (`sfx_metal`, DSMETAL) at specific points in a monster's own real RUN
-- cycle, layered ON TOP of the normal `A_Chase` movement that same
-- state also runs, not a replacement for it. Spider Mastermind's own
-- real cycle uses it at `S_SPID_RUN1`/`RUN5`/`RUN9` (`info.c:739,743,
-- 747`) -- exactly frame INDICES 1/5/9 of this roster's own already-
-- correct 12-entry `run` sequence below (`A,A,B,B,C,C,D,D,E,E,F,F`,
-- the same letter-doubling pattern real DOOM's own RUN1-RUN12 states
-- already encode) -- found entirely missing during the 2026-08-08
-- audit of this specific monster. `roster.metalWalkIndices` opts a
-- roster entry in; every other demon leaves it unset and is unaffected.
-- FIX 2026-08-08 (user report, with a raw session log showing DSMETAL
-- firing far more often than real DOOM's own cadence, worse still with
-- multiple Spider Masterminds alive at once). Root cause: `advanceRunFrame`
-- (this function's own caller) runs from each demon's `pose()`, the
-- RENDER path -- called once per DRAWN frame via `VoxelScene`, decoupled
-- from this engine's own fixed 60Hz `input.step` tick
-- (`gen1recomp-dev/src/core/FixedStep.lua`, `STEP = 1/60`, confirmed
-- fresh) -- and this engine's own frame cap
-- (`DramaticShapeVoxelMod-dev/lib/FrameCap.lua`) is user-adjustable above
-- 60fps. `ticsToFrames` (above) converts a DOOM tic count into a FRAME
-- count assuming a 60Hz reference; at any higher real render rate the
-- whole run cycle -- and every DSMETAL trigger embedded in it at frame
-- indices 1/5/9 -- advances proportionally faster than DOOM's own real
-- spacing, exactly the class of bug already fixed once for
-- `maybePlayActiveSound`'s own per-tic roll (see that function's own
-- 2026-08-08 comment, same root cause: a render/render-rate-coupled
-- trigger standing in for what should be a real-time-paced one).
-- `METAL_SOUND_INTERVAL` restates real DOOM's own RUN1->RUN5->RUN9
-- spacing (info.c:739,743,747: each `A_Metal` call is 4 run-frames apart,
-- 4 frames * 3 tics/frame = 12 tics, 12/35 real seconds) as a real-time
-- cooldown gating the SOUND trigger only -- the visual frame advance
-- itself is deliberately left alone, matching this function's own prior
-- pause-gate fix's scope (`BUGS.md:2381-2395`'s "not something to
-- re-architect for one sound") -- so the clank plays at DOOM's own real
-- cadence regardless of how many times per second `pose()` itself is
-- actually called.
local METAL_SOUND_INTERVAL = 12 / 35
local function playMetalWalkSound(m)
  local indices = m.roster.metalWalkIndices
  if not indices then return end
  local hit = false
  for _, i in ipairs(indices) do if i == m.frameIndex then hit = true break end end
  if not hit then return end
  -- FIX 2026-08-08 (user report: "doom sounds are still being played in
  -- pause menu"). The overworld still draws beneath a non-opaque menu
  -- like `StartMenu` (`StateStack:draw()` draws every state from
  -- `visibleBase()` up), so `pose()` -- and this sound -- kept firing
  -- while paused without this check.
  if not FirstPerson.onTop() then return end
  local now = love.timer and love.timer.getTime() or 0
  if m.lastMetalSoundTime and (now - m.lastMetalSoundTime) < METAL_SOUND_INTERVAL then return end
  m.lastMetalSoundTime = now
  local ok, snd = pcall(DoomWadImport.loadSound, "DSMETAL")
  if ok and snd then DoomWadImport.playClone("DSMETAL (" .. m.name .. " walk)", snd) end
end

local function advanceRunFrame(m)
  local run = m.roster.run
  m.frameHold = (m.frameHold or 0) - 1
  if m.frameHold <= 0 then
    m.frameIndex = (m.frameIndex or 0) % #run.letters + 1
    m.frameHold = ticsToFrames(run.tics)
    playMetalWalkSound(m)
  end
  return run.letters[m.frameIndex or 1]
end

-- Real DOOM's own idle state alternates two frames for every demon here
-- except Cacodemon (a genuine, confirmed single-frame exception, see
-- that roster entry's own comment) -- a SEPARATE hold/index pair from
-- `advanceRunFrame`'s own (`m.standFrameHold`/`m.standFrameIndex`, not
-- `m.frameHold`/`m.frameIndex`) so switching between idle and moving
-- never corrupts either animation's own independent cycle position.
local function advanceStandFrame(m)
  local stand = m.roster.stand
  m.standFrameHold = (m.standFrameHold or 0) - 1
  if m.standFrameHold <= 0 then
    m.standFrameIndex = (m.standFrameIndex or 0) % #stand.letters + 1
    m.standFrameHold = ticsToFrames(stand.tics)
  end
  return stand.letters[m.standFrameIndex or 1]
end

-- FIXED 2026-08-06 -- user report: "many enemies dont have an attack
-- animation." True -- `pose()` never had an "attacking" visual state at
-- all; a demon that fired a hitscan/projectile/melee/charge attack kept
-- showing whatever run/stand frame it already happened to be on. Every
-- roster entry now carries a real `atk` windup-then-fire sequence (read
-- fresh from `info.c`, cited per-entry), played once (via
-- `startAttackAnim`, called from every real attack-firing call site)
-- whenever an attack actually lands -- a THIRD independent hold/index
-- pair (`m.attackFrameHold`/`m.attackFrameIndex`), same reasoning as
-- `stand`'s own separate pair from `run`'s: none of the three should
-- ever corrupt another's own cycle position.
-- FIX 2026-08-08 -- user report: "i dont actually see a shooting
-- animation coming from spider mastermind." Root cause, found by tracing
-- the real numbers rather than guessing: Spider Mastermind's own real
-- refire cadence (`checkSpidRefireReal`, gated by `m.roster.attackCooldown
-- = 4.5/35s`  0.129s per shot) fires a NEW shot -- and therefore a new
-- call to THIS function -- faster than the G->H attack sequence takes to
-- finish playing (`ticsToFrames(atk.tics)` = `ticsToFrames(4)` = 7 render
-- frames per letter at this engine's own 60Hz reference, ~14 total for
-- both G and H). Unconditionally restarting `m.attackFrameIndex` back to
-- 1 on every call (the original behavior) meant a sustained burst kept
-- snapping back to the FIRST attack frame before ever reaching the
-- second -- the player only ever saw one static frame the whole burst,
-- easily read as "no shooting animation" at all. Real DOOM's own state
-- chain (`info.c` S_SPID_ATK2/ATK3, BOTH the G and H frames call
-- `A_SPosAttack`) genuinely alternates G/H continuously for the whole
-- burst, never restarting mid-burst -- restated here as: don't restart
-- an attack animation that's already playing, only start a fresh one
-- when the demon wasn't already mid-attack-animation. Every other real
-- attack type (melee/projectile/charge) fires far less often than its
-- own `atk` sequence takes to finish, so this changes nothing observable
-- for them -- `m.attacking` is already false again well before their
-- next real attack call arrives.
local function startAttackAnim(m)
  if not m.roster.atk then return end
  if m.attacking then return end
  m.attacking = true
  m.attackFrameIndex = 1
  m.attackFrameHold = ticsToFrames(m.roster.atk.tics)
end

-- Returns the current attack letter, or nil once the one-shot sequence
-- has fully played (at which point `m.attacking` is cleared and `pose()`
-- falls through to whatever it would otherwise show). Lost Soul's own
-- `atk` is a special case -- see `tickLostSoulCharge`, which keeps
-- `m.attacking` (and this function) running for its own real full
-- charge duration instead of firing it once.
local function advanceAttackFrame(m)
  local atk = m.roster.atk
  m.attackFrameHold = (m.attackFrameHold or 0) - 1
  if m.attackFrameHold <= 0 then
    m.attackFrameHold = ticsToFrames(atk.tics)
    local nextIndex = (m.attackFrameIndex or 1) + 1
    if nextIndex > #atk.letters then
      if m.roster.attackType == "charge" then
        nextIndex = 1 -- real DOOM loops C/D for the charge's own full real flight duration
      else
        m.attacking = false
        return atk.letters[#atk.letters] -- hold the final frame this exact tick; cleared from the next pose() call on
      end
    end
    m.attackFrameIndex = nextIndex
  end
  return atk.letters[m.attackFrameIndex or 1]
end

-- ------- sprite loading + mesh (same real technique as lib/DoomKill.
-- lua's gib / lib/DoomItems.lua's item entities -- real depth-tested
-- billboards via the unmodified VoxelScene/drawEntity pipeline, not a
-- screen-space overlay)
-- FIXED 2026-08-06 -- user report: "the demons are... completely
-- invisible." Real DOOM's own sprite-rotation rule (confirmed against
-- `wadext-master/wadext.cpp:147`, which extracts files under the exact
-- raw WAD lump name with no synthesis of its own): a sprite STATE has
-- EITHER one lump ending in rotation digit `0` (used from every viewing
-- angle) OR eight separate lumps, rotations `1`-`8` -- DOOM's own real
-- asset validation (`R_InitSpriteDefs`) refuses a partial mix, so it is
-- always exactly one of those two shapes, never both, never neither.
-- Hardcoding `0` (this function's own previous, only, lookup) is correct
-- for states that genuinely look the same from any angle (common for a
-- flat corpse's own final resting frame) but wrong for a directional
-- one -- a walking/standing demon almost always IS directional, so
-- `POSSA0` (etc, for every roster entry) never existed as an extracted
-- file at all, and every single lookup failed the exact same way, which
-- is why the symptom was "completely invisible," not intermittent.
-- Fixed: try `0` first (unchanged, cheap, and correct when it hits),
-- fall back to `1` (an arbitrary, single, always-present-when-
-- rotations-exist pick, matching this project's own already-established
-- "billboards face one fixed way, no real per-angle tracking"
-- simplification -- `SpriteBillboards.lua`'s own "the card always faces
-- SOUTH" precedent) when it doesn't, then (this roster's own real
-- Spider Mastermind quirk, 2026-08-07: its `SPID` sheet reuses several
-- rotation-1 images across TWO different frame letters in one compound
-- lump, `SPIDA1D1`/`SPIDB1E1`/`SPIDC1F1` -- a plain rotation-1 lookup
-- only ever matches the FIRST slot, leaving D/E/F invisible) a real
-- compound-lump search -- see `DoomSpriteCache.newSpriteLoader`'s own
-- header for the shared implementation this now delegates to.
local loadDemonSprite = DoomSpriteCache.newSpriteLoader(true)

-- Every demon targets the SAME world height as a standing NPC's own
-- real card (`NPC_CARD_WORLD_HEIGHT`, restated from lib/DoomKill.lua's
-- own gib mesh -- a person-scale reference this project already
-- calibrated once, reused rather than re-guessed) rather than each
-- demon's own wildly different real DOOM height (a Cyberdemon is
-- genuinely much taller than a Zombieman in DOOM) -- a real, flagged
-- simplification: this mod has no principled DOOM-map-unit-to-world-px
-- conversion (CLAUDE.md), so relative demon SIZE differences are not
-- currently represented, only relative image aspect ratio is.
local DEMON_WORLD_HEIGHT = 16

-- FIXED 2026-08-06 -- user report + screenshot: a giant, disproportionate
-- blob appearing at a demon's own death location -- "the big sprite bug
-- after killed is back but for doom npcs now." This is the EXACT SAME
-- bug class `lib/DoomKill.lua`'s own citizen-gib system already found
-- and fixed once (see that file's own `calibrationRatio`/
-- `worldUnitsPerNativePixel` header comment for the full original
-- diagnosis): `buildDemonMesh` (below) used to re-normalize EVERY
-- frame's own image HEIGHT independently to the same fixed
-- `DEMON_WORLD_HEIGHT`, frame by frame -- fine for a demon's own stand/
-- run frames (which stay roughly the same native proportions), but a
-- death/xdeath frame naturally gets WIDER and SHORTER as a real DOOM
-- sprite artist drew the gore spreading outward and the body
-- collapsing -- force-normalizing THAT frame's own short native height
-- up to the same fixed target balloons its width proportionally, giving
-- exactly the giant/disproportionate blob reported. This also silently
-- affected demon-fired projectile explosion sprites (`BAL1`/`BAL2`/
-- `BAL7`), which share this exact same mesh builder via the
-- `pokedoomDemon` marker -- fireball splash frames have the identical
-- "spreads wider as it bursts" shape.
--
-- Fixed the same way `lib/DoomKill.lua` already proved out: freeze one
-- `worldUnitsPerNativePixel` scale ratio, calibrated ONCE per sprite
-- SHEET (not per frame) from a stable reference frame, then apply that
-- SAME ratio uniformly to every other frame's own true native
-- dimensions -- so a frame's real proportions always come through
-- correctly, scaled by one consistent physical size, never
-- independently re-fit to a fixed height. Keyed per sprite prefix
-- (`POSS`/`TROO`/.../`BAL1`/`MISL`/etc.), since this file's roster
-- covers ten genuinely different sprite sheets, not `DoomKill.lua`'s
-- own single gib type -- each needs its own independent calibration,
-- not one shared global ratio.
local demonScaleRatio = {}

-- The stable reference frame to calibrate a REAL DEMON'S own sprite
-- prefix ratio from -- its own real `stand` letter (its most "normal,"
-- least-distorted pose). Restated as a fallback guess ("A") for a
-- genuinely unclassified prefix this file has never seen before.
local function calibrationLetterFor(spritePrefix)
  for _, roster in pairs(DoomDemons.ROSTER) do
    if roster.sprite == spritePrefix then return roster.stand.letters[1] end
  end
  return "A" -- last-resort guess -- every real DOOM sprite has an "A" frame
end

-- FIXED 2026-08-07 -- user report: "the explosion is too big with the
-- size bug. audit every entity added by the mod looking for the size
-- bug before i can find them myself." Full audit found this same bug
-- class -- independently calibrating a sprite to `DEMON_WORLD_HEIGHT`
-- (16 world units, full person/monster height) -- silently affecting
-- EVERY non-demon effect sprite this mesh builder is reused for, not
-- just blood: the player's own rocket/plasma/BFG (`MISL`/`PLSS`/`PLSE`/
-- `BFS1`/`BFE1`, `lib/DoomWeapons.lua`) in flight AND exploding, and the
-- Imp/Cacodemon/Baron of Hell's own thrown fireballs (`BAL1`/`BAL2`/
-- `BAL7`, this file's own `DEMON_PROJECTILE_VISUAL`) -- every one of
-- these was being rendered as tall as a Zombieman. Real DOOM has no
-- per-sprite rescale step at all; every sprite draws at its own true
-- native pixel size against one shared screen-projection scale, which
-- is exactly why a rocket or a fireball naturally reads small next to a
-- monster in real DOOM. Fixed centrally, not per-caller: any sprite
-- prefix in `NON_DEMON_PREFIXES` below skips independent calibration
-- entirely and instead shares ZOMBIEMAN's own already-calibrated ratio
-- (a fixed, consistent reference -- real DOOM's own sprite sizes don't
-- rescale based on who fired/spawned them either), so each one's own
-- true native pixel dimensions are read against that ONE shared
-- per-pixel scale, preserving its real, small-relative-to-a-demon
-- proportions instead of being force-fit to person height. Add any
-- FUTURE non-demon effect sprite (a new projectile, a new particle) to
-- this same list before it ever ships -- see CLAUDE.md's own "every new
-- sprite/entity type must share ONE calibrated scale" hard rule.
--
-- `BLUD`/`PUFF` RE-ADDED HERE 2026-08-07 (this same day, later round) --
-- history matters, so it's kept rather than silently overwritten. They
-- were moved OUT earlier the same day after the user reported blood "no
-- longer in the viewport AT ALL" -- at the time, blamed on this shared
-- ratio rounding a genuinely tiny WAD patch toward imperceptible, and
-- "fixed" by giving both their own dedicated fixed height (8,
-- `lib/DoomBlood.lua`/`lib/DoomPuff.lua`'s own `BLOOD_WORLD_HEIGHT`/
-- `PUFF_WORLD_HEIGHT`). But that SAME round also found and fixed a
-- SEPARATE, genuinely confirmed bug in those two files' own mesh
-- hooks -- `SpriteBillboards.shadowQuad` never wrapped, silently
-- falling through to whichever OTHER file's own demon-only recognizer
-- installed first (the identical class of bug `lib/DoomDemons.lua`'s
-- own Phase 21 Round 4 already found and fixed once for its own hook) --
-- and the two fixes shipped in the SAME round, never independently
-- isolated. A completely broken shadow/mesh lookup is a full,
-- unconditional invisibility bug on its own, regardless of size, which
-- means the height bump was never actually confirmed necessary --
-- only convenient timing made it look like the fix. User report,
-- 2026-08-07 (this round): "the puff effect is too big just as the
-- blood effect is too big and has been too big even though multiple
-- 'fixes' were implemented" -- direct evidence the height-8 guess was
-- the wrong one, stacked on top of (and confused with) the real
-- shadowQuad fix. Per CLAUDE.md's own standing practice ("prefer
-- reverting to the simplest, most-proven-working pattern over layering
-- another speculative fix on top of the last one"): back these two out
-- to the same shared-ratio scheme every other non-demon effect sprite
-- here already proves out, now that the shadowQuad fix (still in
-- place, unrelated to this table) is what should actually be
-- responsible for either sprite ever being visible at all -- see
-- `lib/DoomBlood.lua`/`lib/DoomPuff.lua`'s own updated header comments
-- for the mesh-hook side of this same change.
-- `BAR1`/`BEXP` added 2026-08-10 -- the real explosive barrel
-- (`MT_BARREL`) and its own real explosion sequence, `lib/
-- DoomBarrels.lua`'s new entity -- a reasonably large real WAD patch
-- (comparable to a person, `42*FRACUNIT` real height) whose true
-- proportions matter, matching option 1 of CLAUDE.md's own sprite-scale
-- hard rule (share an already-calibrated ratio), not option 2 (a tiny
-- particle's own fixed height).
--
-- `STIM`/`BON1`/`BON2`/`CLIP`/`SHEL`/`ROCK`/`CELL`/`MEDI`/`ARM1`/`ARM2`/
-- `SOUL` added 2026-08-10 -- `lib/DoomItems.lua`'s own real
-- `REWARD_TABLE` pickups, same round as the barrel additions above.
-- User report, confirmed against the real extracted textures: a clip
-- (9x11px, the smallest real sprite in the whole table) and a medikit
-- (28x19px) both rendered "too big" -- root cause was that file's OWN
-- fixed-height simplification forcing every item's larger axis to an
-- identical target regardless of its own real size, exactly the bug
-- this table exists to prevent. See that file's own updated `ITEM_
-- WORLD_HEIGHT` header comment for the full derivation. These sprites
-- are all real, physical-object-sized WAD patches (9px to 31px on
-- their long axis -- meaningfully bigger than `BLUD`/`PUFF`'s own 5px
-- patches, already proven safe to share this same ratio without
-- rounding to invisible), so option 1 (share Zombieman's ratio,
-- preserving each item's TRUE relative size) is the right bucket, not
-- option 2 (a tiny particle's own fixed height) -- the bucket these
-- items were wrongly filed under before.
-- Added 2026-08-10 for `lib/DoomProps.lua`'s own real DOOM decorative
-- "thing" roster (pillars, torches, poles, hanging gore, pools, lights
-- -- see that file's own header comment for the full citation). Only
-- prefixes with NO existing real roster entry need adding here --
-- corpse props reusing an actual monster's own sprite (`POSS`/`SPOS`/
-- `TROO`/`SARG`/`SKUL`/`HEAD`, e.g. "Dead Zombieman") already get that
-- exact monster's own real per-species calibration for free via the
-- roster branch below, which is MORE correct than forcing them through
-- this shared table -- deliberately left out of this list. `PLAY` (the
-- player's own sprite, reused for "Dead Marine"/"Bloody Mess") has no
-- roster entry of its own, so it DOES need to be here.
local NON_DEMON_PREFIXES = {
  MISL = true, PLSS = true, PLSE = true, BFS1 = true, BFE1 = true,
  BAL1 = true, BAL2 = true, BAL7 = true, BLUD = true, PUFF = true,
  BAR1 = true, BEXP = true,
  STIM = true, BON1 = true, BON2 = true, CLIP = true, SHEL = true,
  ROCK = true, CELL = true, MEDI = true, ARM1 = true, ARM2 = true,
  SOUL = true,
  PLAY = true, ELEC = true, COL1 = true, COL2 = true, COL3 = true,
  COL4 = true, COL6 = true, SMIT = true, TRE1 = true, TRE2 = true,
  FCAN = true, POL1 = true, POL2 = true, POL3 = true, POL4 = true,
  POL5 = true, POL6 = true, GOR1 = true, GOR2 = true, GOR3 = true,
  GOR4 = true, GOR5 = true, HDB1 = true, HDB2 = true, HDB3 = true,
  HDB4 = true, HDB5 = true, HDB6 = true, POB1 = true, POB2 = true,
  BRS1 = true, CAND = true, CBRA = true, COLU = true, TLMP = true,
  TLP2 = true, TBLU = true, TGRN = true, TRED = true, SMBT = true,
  SMGT = true, SMRT = true,
  -- FIX 2026-08-11 -- user report + screenshot: the backpack pickup
  -- (`BPAK`) rendered far too large. Root cause: `BPAK` was never added
  -- here, so `calibrationRatioFor` fell through to its own last-resort
  -- branch -- independently calibrating a brand-new sprite prefix to
  -- `DEMON_WORLD_HEIGHT` (16 world units, a FULL STANDING PERSON's own
  -- height), exactly the anti-pattern this table exists to prevent
  -- (CLAUDE.md's own sprite-scale hard rule). `lib/DoomItems.lua`'s own
  -- `placeBackpackLandmark` gives `BPAK` a real, separate one-per-save
  -- world placement OUTSIDE `REWARD_TABLE` (see that file's own header
  -- comment), which is presumably why it was missed when this table was
  -- first built from that table's own entries -- it's still a real
  -- pickup item, routing through the exact same `buildItemMesh` path
  -- every other item here already does (confirmed: `lib/DoomItems.lua`
  -- line ~719 sets `spriteName = point.sprite or point.name`, `"BPAK"`
  -- for a backpack point, no special-case bypass), so it belongs in
  -- this table on the same footing as `STIM`/`CLIP`/`MEDI`/etc.
  BPAK = true,
}

local function calibrationRatioFor(spritePrefix)
  if not spritePrefix then return nil end
  if demonScaleRatio[spritePrefix] then return demonScaleRatio[spritePrefix] end
  if NON_DEMON_PREFIXES[spritePrefix] then
    local zombieman = DoomDemons.ROSTER.ZOMBIEMAN
    local ratio = zombieman and calibrationRatioFor(zombieman.sprite)
    if not ratio then return nil end
    demonScaleRatio[spritePrefix] = ratio
    return ratio
  end
  local ok, refImage = pcall(loadDemonSprite, spritePrefix, calibrationLetterFor(spritePrefix))
  if not (ok and refImage) then return nil end
  local _, ih0 = refImage:getDimensions()
  if not (ih0 and ih0 > 0) then return nil end
  local ratio = DEMON_WORLD_HEIGHT / ih0
  demonScaleRatio[spritePrefix] = ratio
  return ratio
end

local meshCache, lastMeshWadState = {}, nil
local function buildDemonMesh(image, spritePrefix)
  local iw, ih = image:getDimensions()
  if not (iw and ih and iw > 0 and ih > 0) then return nil end
  local ratio = calibrationRatioFor(spritePrefix)
  if not ratio then return nil end
  local worldH = ih * ratio
  local worldW = iw * ratio
  local halfW = worldW / 2
  local u0, u1 = 0.5 / iw, (iw - 0.5) / iw
  local v0, v1 = 0.5 / ih, (ih - 0.5) / ih
  local verts = {
    { 8 - halfW, 0, 0, u0, v1, 1 }, { 8 + halfW, 0, 0, u1, v1, 1 },
    { 8 + halfW, worldH, 0, u1, v0, 1 }, { 8 - halfW, worldH, 0, u0, v0, 1 },
  }
  local indices = {}
  Voxel3D.pushQuad(indices, 0)
  return Voxel3D.newMesh(verts, indices)
end

local function demonMesh(cacheKey, image, spritePrefix)
  if DoomWadImport.status.state ~= lastMeshWadState then
    lastMeshWadState = DoomWadImport.status.state
    meshCache = {}
    demonScaleRatio = {}
  end
  local cached = meshCache[cacheKey]
  if cached ~= nil then return cached or nil end
  local okM, mesh = pcall(buildDemonMesh, image, spritePrefix or cacheKey:sub(1, 4))
  mesh = (okM and mesh) or false
  meshCache[cacheKey] = mesh
  return mesh or nil
end

-- ADDED 2026-08-08 -- the real-world-unit height a sprite renders at via
-- `buildDemonMesh`'s own shared ratio math, exported so a caller whose
-- entity is NOT ground-anchored (a flying projectile, unlike every
-- walking demon/NPC this whole ratio scheme was designed for) can work
-- out its own vertical center correction rather than re-deriving/
-- duplicating this ratio lookup. See `lib/DoomWeapons.lua`'s
-- `makeProjectileEntity` for the actual caller and the bug this exists
-- to fix.
local function worldHeightFor(spritePrefix, image)
  if not (image and spritePrefix) then return nil end
  local ok, iw, ih = pcall(function() return image:getDimensions() end)
  if not (ok and ih and ih > 0) then return nil end
  local ratio = calibrationRatioFor(spritePrefix)
  if not ratio then return nil end
  return ih * ratio
end

-- Public exports -- `lib/DoomHordeControl.lua` reuses this exact same
-- real sprite-loading/mesh-building/caching logic to reskin Horde Mode's
-- own spawned mobs with real DOOM demon sprites, rather than duplicating
-- it (this is meaningfully more than a "small pure-shape piece," unlike
-- this project's usual restate-per-file precedent -- worth sharing here).
DoomDemons.loadSprite = loadDemonSprite
DoomDemons.mesh = demonMesh
DoomDemons.worldHeightFor = worldHeightFor

-- Also exported for `lib/DoomHordeControl.lua` (2026-08-07): that file's
-- own Horde-mob reskin used to show a single frozen frame forever (no
-- stand/run cycling, no attack animation, no death sequence) because it
-- never had access to this file's own real per-frame animation-clock
-- logic -- these four functions are the exact same real state machine
-- ambient demons already use, operating on any table shaped the same way
-- (`.roster`, `.frameHold`/`.frameIndex`, `.standFrameHold`/
-- `.standFrameIndex`, `.attackFrameHold`/`.attackFrameIndex`,
-- `.attacking`), not specifically an ambient demon's own `m`.
DoomDemons.advanceRunFrame = advanceRunFrame
DoomDemons.advanceStandFrame = advanceStandFrame
DoomDemons.startAttackAnim = startAttackAnim
DoomDemons.advanceAttackFrame = advanceAttackFrame
-- Phase 27 unification audit (2026-08-09): exported so `lib/
-- DoomHordeControl.lua` can stop re-typing its own copy of this exact
-- function -- CLAUDE.md's own "any DOOM per-tic mechanic needs a real
-- 35Hz accumulator" hard rule already flags this function's hardcoded
-- `FRAME_RATE = 60` as a known, still-open bug (correct only at the
-- default frame cap); a second, un-exported copy meant that bug's
-- eventual fix would silently never reach Horde-reskinned demon
-- animation.
DoomDemons.ticsToFrames = ticsToFrames

-- Phase 22, Round 4: Spectre's own `translucent` roster flag, made a
-- real visual, not just data that sits unused. Real DOOM's own
-- mechanism (`R_DrawFuzzColumn`, audited in Phase 22's own source
-- read) is a per-pixel post-process trick specific to its software
-- rasterizer -- no direct equivalent exists in this engine's mesh-based
-- voxel renderer, so this is a stated FUNCTIONAL-parity choice ("hard to
-- see," not pixel-identical) rather than a port: a dim color-multiply
-- tint applied only around this one entity's own draw call, via a
-- `Voxel3D.draw` wrap. Deliberately NOT alpha (`love.graphics.
-- setColor`'s 4th channel) -- alpha blending against an opaque solid-
-- terrain 3D pass depends on that pass actually being blend-enabled,
-- which was not independently confirmed here; a plain color-multiply
-- tint is a far safer bet (day/night and palette-mode tinting already
-- prove color multiply works throughout this renderer) and still reads
-- as "a shadowy, hard-to-make-out shape" -- the real functional ask.
-- Flagged as the least-verified piece of this whole phase; worth
-- confirming in actual play.
local pendingTranslucentDraw = false

-- FIX 2026-08-11 -- Phase 30 (Spectre audit): the dim-tint approximation
-- above was a static, unchanging 0.4 gray -- fine for "hard to make
-- out," but missing the one real, defining QUALITY of DOOM's own actual
-- fuzz effect confirmed by re-reading `R_DrawFuzzColumn` fresh (`r_draw.
-- c:257-368`): it's a constantly-shimmering, TV-static-like effect, not
-- a flat dim shape -- every fuzz-drawn column re-samples the framebuffer
-- at a jittered row offset from a shared, continuously-advancing
-- `fuzzpos` counter (`FUZZTABLE = 50` entries, incremented across EVERY
-- fuzz pixel drawn that frame, by any fuzz-drawn thing, not per-monster-
-- independent). This engine's own mesh renderer has no equivalent
-- per-pixel post-process pass to port literally (same stated limitation
-- as the dim-tint choice itself) -- but the real, functionally-relevant
-- part of that mechanism is faithfully portable: a shared, real-time-
-- driven brightness wobble applied to every translucent (Spectre)
-- draw at once, re-rolled periodically rather than held constant.
-- State-driven (a real-time accumulator re-rolling a target value on a
-- fixed cadence), not a transplanted per-pixel formula -- matches
-- CLAUDE.md's own "avoid math-derived code" preference for the simpler
-- equivalent. 0.09s between re-rolls / a 0.28-0.5 alpha band are visual-
-- rendering judgment calls (no DOOM-source-derivable "correct" flicker
-- speed exists for a mesh renderer), not derived facts -- kept as
-- literals inside one small state table (not separate named module
-- constants) specifically to avoid adding to this file's own local-
-- variable count, which is already near Lua's real 200-local-per-scope
-- ceiling (see this project's own `pokedoom_lua_200_local_limit` memory
-- / `DoomDemons.lua`'s own compile-failure history).
-- No new top-level `local` at all for this state (not even one) -- a
-- real compile check confirmed this file's own main chunk is AT Lua's
-- real 200-local ceiling already (see `pokedoom_lua_200_local_limit`
-- memory / this file's own compile-failure history), so even a single
-- additional module-local variable breaks the whole file. Carried as a
-- private field on the already-existing `DoomDemons` table instead --
-- a table FIELD assignment, unlike a `local` declaration, never
-- consumes a local-variable slot, the same established workaround this
-- file's own `pickNewChaseDir` dead-zone fix used for the identical
-- reason (see `phases/phase-31-ai-pathing-audit.md`'s own Finding 2).
DoomDemons.shadowShimmer = { alpha = 0.4, accum = 0 }

local installedMeshHook = false
local function installDemonMeshHook()
  if installedMeshHook then return end
  installedMeshHook = true
  local inner = SpriteBillboards.mesh
  local reskin = function(def, frame)
    -- Set UNCONDITIONALLY, for every def this ever sees (not just the
    -- demon branch below) -- self-corrects a real leak risk: if a
    -- translucent Spectre's own mesh lookup succeeds but `drawEntity`
    -- then aborts before ever reaching `Voxel3D.draw` (e.g. the image
    -- wasn't ready this exact frame), a STALE `true` would otherwise
    -- carry over and wrongly tint the next unrelated entity's own draw.
    -- Every entity's own mesh lookup (this function, or its
    -- `shadowQuad` alias below) always runs immediately before that
    -- SAME entity's own draw call in `VoxelScene.lua`'s real
    -- `drawEntity`, so resetting here on every call keeps this in sync
    -- regardless of which entity is currently being processed.
    pendingTranslucentDraw = def and def.pokedoomDemon and def.pokedoomTranslucent == true
    if def and def.pokedoomDemon then
      -- `pokedoomSpritePrefix` is the real sprite-sheet prefix this
      -- specific def's own image came from (`POSS`/`TROO`/.../`BAL1`/
      -- `MISL`), used to calibrate that sheet's own scale ratio -- NOT
      -- derived from `pokedoomCacheKey` (which some callers prefix, e.g.
      -- demon-fired projectiles' own `"proj-" .. sprite .. letter`, so a
      -- naive substring parse would grab the wrong four characters).
      local ok, mesh = pcall(demonMesh, def.pokedoomCacheKey, def.pokedoomImage, def.pokedoomSpritePrefix)
      if ok then return mesh end
      return nil
    end
    return inner(def, frame)
  end
  SpriteBillboards.mesh = reskin
  -- `SpriteBillboards.shadowQuad` (the sun/occlusion-silhouette pass --
  -- see that file's own header comment) is set ONCE, at that file's own
  -- load time, to `SpriteBillboards.mesh`'s ORIGINAL, unwrapped function
  -- (`SpriteBillboards.shadowQuad = SpriteBillboards.mesh`) -- a snapshot
  -- by value, not a live alias, so reassigning `.mesh` above never
  -- reaches it. Left alone, a demon's shadow/sun/occlusion pass would
  -- always call the ORIGINAL function with a synthetic `def.image` this
  -- mod invented (e.g. "pokedoom-demon-POSS") that has no real asset file
  -- behind it, silently fail to build a card, and cache `false` for that
  -- key forever -- not a wrong sprite, but a demon with no shadow and no
  -- occlusion silhouette. Wrapped the identical way, sharing the same
  -- underlying `demonMesh`/`inner` this file already uses for the solid
  -- draw, so shadow and solid geometry stay the same shape (VoxelScene's
  -- own load-bearing requirement, per its header comment).
  SpriteBillboards.shadowQuad = reskin
end

local function worldPos(cx, cy)
  return cx * 16 + 8, cy * 16 + 8
end

local function groundY(ow, cx, cy)
  return DoomGround.heightAt(ow.map, cx, cy)
end

local function makeDemonEntity(m)
  return {
    passable = true,
    px = m.px, py = m.py,
    cellX = m.cx, cellY = m.cy,
    draw = function() end, -- see lib/DoomItems.lua's own identical note: the classic
                            -- non-voxel 2D render path needs SOME :draw(), even a no-op
    pose = function()
      -- Real DOOM's own run-cycle animation plays whenever a demon is
      -- actually walking, not only while it has a target ("roam" and
      -- "chase" are this mod's own AI states, not a DOOM concept -- a
      -- roaming demon still moves, so it should still show its own
      -- real walk cycle, not the idle stand frame). `m.moving` is the
      -- literal per-frame movement flag `stepToward` sets.
      local letter
      if m.state == "dying" then
        -- `m.roster.stand` is now a `frames()` table (idle alternation,
        -- fixed in this same animation-fidelity audit), not a bare
        -- letter -- this fallback (only reached if `m.dyingLetter` was
        -- somehow never set, which `startDeath` always does in
        -- practice) needs an actual string, so it reads the stand
        -- table's own first letter directly rather than the table
        -- itself.
        letter = m.dyingLetter or m.roster.stand.letters[1]
      elseif m.staggerTimer and m.staggerTimer > 0 and m.roster.pain then
        -- Phase 22, Round 4: the real pain-state sprite (`roster.pain`,
        -- already present per-demon data since the original roster
        -- audit, never actually shown until now) during the new
        -- movement/attack-halting stagger `tickDemon` applies. Takes
        -- priority over an in-progress attack animation below, matching
        -- real DOOM's own pain state always interrupting whatever a
        -- monster was doing.
        letter = m.roster.pain
      elseif m.attacking and m.roster.atk then
        -- FIXED 2026-08-06 (user report: "many enemies dont have an
        -- attack animation") -- see `startAttackAnim`'s own header
        -- comment for the full fix.
        letter = advanceAttackFrame(m) or advanceStandFrame(m)
      elseif m.moving then
        letter = advanceRunFrame(m)
      else
        letter = advanceStandFrame(m)
      end
      -- CONFIRMED 2026-08-06 by a real crash log the user provided, not
      -- static analysis: "render pipeline voxel failed: ...VoxelScene.
      -- lua:530: attempt to perform arithmetic on local 'vy' (a nil
      -- value) -- disabled for this session." `VoxelScene.lua`'s own
      -- `posesOf` (its real line 521/526, read directly) destructures
      -- SIX values from every entity's `pose()` unconditionally --
      -- `sprite, vx, vy, facing, phase, flip = e:pose()` -- then computes
      -- `e.py - vy` with NO nil check at all. The `if not image then
      -- return nil end` this line used to have returned exactly ONE
      -- value (bare `nil`) instead of six, so `vy` was `nil` and this
      -- crashed the ENTIRE voxel 3D pipeline for the rest of the game
      -- session -- not just this one demon failing to render, but every
      -- other entity, and PKDOOM MODE's own first-person view, dead for
      -- good until a full relaunch. This is almost certainly the real,
      -- sole root cause of the user's whole "stuck in the flat 2D view"
      -- report -- every `Pipelines.setLevel`/`Voxel.setLevel` fix this
      -- investigation tried was correct but irrelevant, since the entire
      -- 3D pipeline had already been shut off by the engine itself after
      -- this crash, regardless of what level was selected.
      --
      -- Fixed by never returning fewer than six values: `image` may
      -- still legitimately be `nil`/`false` (the WAD not ready yet, or a
      -- genuinely missing lump) -- that's fine, and was ALWAYS fine,
      -- because everything downstream of `pose()` already tolerates a
      -- bad image gracefully, via pcall, several layers deep (`Sprite
      -- Billboards.mesh`'s own wrap -> `demonMesh` -> `buildDemonMesh`'s
      -- own `image:getDimensions()` call, all caught) -- `drawEntity`
      -- itself just skips drawing that frame's card. The ONLY genuinely
      -- unsafe thing was aborting `pose()` itself with the wrong return
      -- shape, which happened BEFORE any of that safety net could apply.
      local image = loadDemonSprite(m.roster.sprite, letter)
      local spriteObj = {
        def = {
          pokedoomDemon = true, pokedoomCacheKey = m.roster.sprite .. letter,
          pokedoomSpritePrefix = m.roster.sprite,
          pokedoomImage = image, trueColor = true,
          image = "pokedoom-demon-" .. m.roster.sprite,
          -- Phase 22, Round 4: Spectre's own `translucent` roster flag,
          -- made real -- see `installTranslucentDrawHook`'s own header
          -- comment for the full reasoning/caveat.
          pokedoomTranslucent = m.roster.translucent,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      return spriteObj, m.px, m.py, m.facing or "down", 0, false
    end,
  }
end

local function removeDemonEntity(ow, m)
  m.inserted = false
  if not (m.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == m.entity then table.remove(ow.entities, i) break end
  end
  m.entity = nil
end

-- ------- NPC (citizen) targeting -- restated ray-free proximity/sight
-- check, not a raycast (a demon doesn't need to fire through terrain
-- the way a weapon shot does) -- P_LookForPlayers' own real shape
-- (p_enemy.c:498-558): a 180-degree cone in front unless the target is
-- within melee range, in which case it notices regardless of facing.
-- Restated against `ow.npcs` (citizens) instead of `players[]`.
local DETECT_RADIUS = 96 -- world px, 6 cells -- a judgment call (no DOOM
                          -- precedent for demon sight range in this
                          -- engine's own world scale), flagged as
                          -- adjustable, matching every other "no source
                          -- to derive from" number in this project.
-- CORRECTED 2026-08-07 -- user report: "this demon is not trying to
-- kill me, it should be." Originally widened from 10 to 20 to paper
-- over a real structural mismatch: this project's own OLD movement
-- system left `m.px`/`.py` snapped to a cell CENTER once "arrived,"
-- while the target's own position was always continuous, so two
-- genuinely adjacent entities could still measure up to 16+ world units
-- apart depending on exactly where each stood in its own cell. The
-- SAME day's later continuous-movement rewrite (see this file's own
-- "continuous movement + collision" section) removed that root cause
-- structurally -- `m.px`/`.py` are now always the demon's own true,
-- exact position, never grid-snapped -- so this radius no longer needs
-- to compensate for anything. Left at 20 anyway: it still has no real
-- DOOM-source precedent to derive from either way (`MELEERANGE` itself
-- has no principled DOOM-map-unit conversion, same as `DETECT_RADIUS`
-- above), and there's no strong reason to shrink a value that already
-- reads as a reasonable "close enough to bite" reach.
local MELEE_RADIUS = 20

-- FIXED 2026-08-06 -- user report: an ambient demon killed citizens but
-- "not trying to hurt the player" at all. `findTarget` below only ever
-- searched `ow.npcs` -- the player is a separate object (`ow.player`),
-- never in that list, so a demon could never even consider the player a
-- target in the first place, let alone catch one. This was a real gap
-- against the original ask ("killing anything it comes across"), not by
-- design. Player contact damage, not an instant kill (`DoomKill.killNpc`
-- is citizen-only and has no concept of health), on the same real 0-100
-- health scale `lib/DoomHealth.lua` already uses. Cooldown is a judgment
-- call (no DOOM precedent for "ambient demon touches the player" at
-- all), flagged adjustable like every other undreived number in this
-- project.
--
-- Phase 22, Round 1 (2026-08-06): the amount ITSELF is no longer a flat
-- constant -- each roster entry now carries its own real `damageDie`/
-- `damageMult` (the exact `(1+rand%dieSides)*mult` shape every one of
-- these ten demons' own real attack functions actually uses, audited
-- fresh in `phases/phase-22-demon-behavior-parity.md`), rolled per hit
-- by `rollDemonDamage` below.
-- Phase 22, Round 2 (2026-08-06): was a single MODULE-level cooldown
-- shared across every demon at once -- meaning a Zombieman's own shot
-- could be blocked just because a totally unrelated Demon bit the
-- player a moment earlier. Real DOOM has no such cross-monster
-- coupling at all: every monster's own attack cycle (its own state
-- machine) is entirely independent of every other monster's. Moved to
-- a per-demon field (`m.attackCooldown`, initialized lazily below) to
-- match that -- each demon now has its own real attack rhythm.
-- Real DOOM's own `A_SargAttack`/`A_TroopAttack`/etc have no cooldown of
-- their own beyond their attack-animation STATE durations (this file's
-- own `startAttackAnim`/roster attack-frame timing already covers that
-- part) -- but this mod's own melee-contact branch fires every tic the
-- player stays in range, with no per-attack animation gate slowing it
-- down the way a real state chain would. `PLAYER_MELEE_COOLDOWN` is kept
-- as this file's own explicit, judgment-call stand-in for that missing
-- per-attack pacing (CLAUDE.md's "implementation is an open choice"),
-- not a real DOOM constant. Ranged/hitscan/charge attacks need no such
-- stand-in any more -- `checkMissileRangeReal`'s own real reactiontime/
-- movecount/distance-chance gating (above `tickDemon`) already paces
-- those the same real way DOOM itself does.
local PLAYER_MELEE_COOLDOWN = 0.8

-- FEATURE 2026-08-10 -- user request: a new "DEMON DIFFICULTY" options
-- row (EASY/NORMAL/HARD/NIGHTMARE, `lib/DoomOptions.lua`). No DOOM
-- precedent (real DOOM's own skill levels change ITEM/monster COUNT and
-- a couple of special-cased behaviors, not a uniform per-monster stat
-- multiplier -- this mod's own simpler addition, same "no DOOM
-- precedent" category as the currency-per-kill/enemy-drops features). A
-- plain lookup table, not a formula, per this project's own "avoid
-- math-derived code" rule -- every number here is a flagged judgment
-- call. Applied at every real choke point a demon's own hp/damage/speed
-- passes through: `spawnDemon`'s own `m.hp` assignment (below),
-- `rollDemonDamage` (melee AND the ranged-hit path at `tickDemon`'s own
-- hitscan branch, both real callers), the demon-projectile inline damage
-- roll (`updateDemonProjectiles`, same formula restated there rather
-- than shared -- see that site's own comment), and `demonSpeedPxPerSec`
-- just below.
local DIFFICULTY_SCALE = {
  easy      = { hp = 0.65, damage = 0.70, speed = 0.90 },
  normal    = { hp = 1.00, damage = 1.00, speed = 1.00 },
  hard      = { hp = 1.50, damage = 1.35, speed = 1.10 },
  nightmare = { hp = 2.25, damage = 1.75, speed = 1.25 },
}

local function difficultyScale()
  return DIFFICULTY_SCALE[Options.demonDifficulty()] or DIFFICULTY_SCALE.normal
end

-- Single source of truth for a demon's real, difficulty-scaled max HP --
-- every real reader of `roster.spawnHealth` (both real spawn sites below,
-- and the XDeath overkill-ratio check, `p_inter.c`'s real `target->health
-- < -target->info->spawnhealth`) goes through this instead of the raw
-- roster field, so the XDeath threshold stays correctly proportional to
-- whatever this demon's own actual spawn HP was scaled to.
local function scaledSpawnHealth(roster)
  return math.max(1, math.floor(roster.spawnHealth * difficultyScale().hp))
end

local function rollDemonDamage(roster)
  local die = roster.damageDie or 8
  local mult = roster.damageMult or 3
  local raw = math.random(die) * mult
  return math.max(1, math.floor(raw * difficultyScale().damage))
end

-- FEATURE 2026-08-10 -- direct user request: "the bullets for soldier
-- demons do different damage points at different distances, and for
-- other different reasons. audit doom and find out every last reason
-- for damage being different on each bullet hit." Re-read real DOOM's
-- own complete hitscan pipeline fresh for this (`A_PosAttack`/
-- `A_SPosAttack`, p_enemy.c:802-844, plus `PTR_ShootTraverse`,
-- p_map.c:899-1018) rather than assumed: NO distance-based damage
-- formula exists anywhere in it. Every hitscan pellet's own damage is
-- always exactly `(1+rand%5)*3` (this file's own `rollDemonDamage`,
-- confirmed correct), completely independent of range --
-- `PTR_ShootTraverse` passes the already-rolled `la_damage` straight
-- through to `P_DamageMobj` with no modification at all.
--
-- What DOES make an attack's own AGGREGATE damage read as
-- distance-dependent: `A_PosAttack`/`A_SPosAttack` also give every
-- pellet its own real random AIM ANGLE (`angle = bangle +
-- (P_Random()-P_Random())<<20`) -- the identical angular spread
-- produces a bigger real-world miss distance at long range than up
-- close (basic trigonometry), so more of a multi-pellet attacker's own
-- shots connect at close range than at range, even though no single
-- pellet's own damage number ever changes. This mod's own hitscan
-- resolution previously had NO miss chance at all (a firing demon
-- always connected, unconditionally) -- this is the real, closest
-- equivalent, and the real gap this audit actually found and closed.
-- `HITSCAN_PELLET_SPREAD` reuses the SAME real spread constant `lib/
-- DoomWeapons.lua`'s own player shotgun already uses (`MAX_SPREAD`,
-- itself DOOM's own angle already converted once) rather than
-- re-deriving a second number, and tests the spread against a target's
-- hit-radius via plain trig instead of transplanting DOOM's own real
-- fixed-point BAM-angle math -- this project's own "avoid math-derived
-- code" preference for the simpler equivalent.
local HITSCAN_PELLET_SPREAD = math.rad(5.6) -- matches lib/DoomWeapons.lua's own MAX_SPREAD (A_FireShotgun, p_pspr.c)
local HITSCAN_TARGET_RADIUS = 6 -- world px, matches lib/DoomKill.lua's own HIT_RADIUS for a shootable target

local function pelletConnects(dist)
  local offset = (math.random() - math.random()) * HITSCAN_PELLET_SPREAD
  local missDist = math.abs(dist * math.sin(offset))
  return missDist <= HITSCAN_TARGET_RADIUS
end

local function npcCenter(npc)
  local px = npc.px or (npc.cellX and npc.cellX * 16)
  local py = npc.py or (npc.cellY and npc.cellY * 16)
  if not (px and py) then return nil end
  return px + 8, py + 8
end

-- Real DOOM's own `P_LookForPlayers` (`p_enemy.c:498-558`, audited in
-- Phase 22) only notices a target roughly in front of it -- excluding a
-- 180-degree rear cone -- UNLESS that target is within melee range, in
-- which case it notices regardless of facing (a demon standing right
-- behind you still gets bitten). Restated against this engine's own
-- discrete 4-way `m.facing` (no continuous view angle exists to check
-- an exact degree threshold against): the excluded rear half-plane is
-- exactly the DOOM check's own real shape (front 180 kept, rear 180
-- dropped), just expressed as a facing-relative sign check instead of
-- an angle comparison -- Phase 22, Round 4.
local function inFacingCone(m, dx, dz, d2)
  if d2 <= MELEE_RADIUS * MELEE_RADIUS then return true end
  if m.facing == "down" then return dz >= 0
  elseif m.facing == "up" then return dz <= 0
  elseif m.facing == "right" then return dx >= 0
  elseif m.facing == "left" then return dx <= 0
  end
  return true
end

-- `allaround`: real DOOM's own `P_LookForPlayers(actor, allaround)` --
-- confirmed fresh, TWO real call sites with two real different values,
-- not one uniform rule: `A_Look` (p_enemy.c:626), a monster's own
-- periodic idle scan while sitting in `spawnstate`, passes `false` (the
-- facing-cone gate `inFacingCone` already applies below) -- but
-- `A_Chase`'s OWN inline reacquisition, the SAME tic a monster's
-- current target goes invalid (p_enemy.c:708), passes `true` -- no cone
-- at all -- and only reverts the monster to `spawnstate` (p_enemy.c:711,
-- where its own NEXT look, via `A_Look`, WOULD be cone-gated again) if
-- even THAT unrestricted search comes up empty. `tickDemon`'s own
-- top-of-function target-drop check calls this function again on the
-- exact same tic, mirroring that real inline retry -- `allaround=true`
-- there; every other call site (a demon that's simply never acquired
-- anything yet, or has been sitting in `roam` for a while) keeps the
-- real cone.
local function findTarget(ow, m, allaround)
  if not ow then return nil end
  -- Real, continuous position -- NOT `worldPos(m.cx, m.cy)` (a cell
  -- CENTER derived once per tick) -- using the true position directly
  -- avoids reintroducing the exact grid-quantization imprecision the
  -- continuous-movement rewrite above exists to remove.
  local mx, mz = m.px, m.py
  local best, bestD
  for _, npc in ipairs(ow.npcs or {}) do
    if not npc.pokedoomBeingHunted then
      local nx, nz = npcCenter(npc)
      if nx then
        local dx, dz = nx - mx, nz - mz
        local d2 = dx * dx + dz * dz
        if d2 <= DETECT_RADIUS * DETECT_RADIUS and (not bestD or d2 < bestD)
           and (allaround or inFacingCone(m, dx, dz, d2)) then
          best, bestD = npc, d2
        end
      end
    end
  end
  -- The player is a real target too now -- see this section's own
  -- header comment. Not gated on `pokedoomBeingHunted` (that flag only
  -- ever means "a DIFFERENT demon already claimed this citizen," a
  -- one-victim-per-demon rule that has no reason to also cap how many
  -- demons can be after the player at once).
  --
  -- FIXED 2026-08-07 -- user report: "Enemies continue hunting the
  -- player after the player is dead." Real `P_LookForPlayers`
  -- (p_enemy.c:527-530) checks `if (player->health <= 0) continue;`
  -- BEFORE ever considering that player a candidate target at all -- a
  -- dead player is simply never noticed, full stop. This mod had no
  -- equivalent check anywhere: a demon that had already caught the
  -- player kept `m.target` pointed at them regardless of death (see
  -- `tickDemon`'s own new check below for that half), and any demon
  -- that HADN'T yet acquired a target would find the dead player fresh
  -- via this very function with nothing stopping it.
  --
  -- NOT changed 2026-08-08 -- briefly tried making the player an
  -- absolute priority over any NPC after a report that a demon went
  -- for an NPC instead of the player; the user's own follow-up
  -- corrected this: demons hunting NPCs is intended, the real bug was
  -- that the CLOSER candidate (the player, that time) wasn't the one
  -- picked -- a genuine distance/sight bug, not a missing priority
  -- rule. Reverted back to plain closest-candidate-wins, unchanged from
  -- before that attempt.
  if ow.player and DoomHealth.isAlive() then
    local px, pz = npcCenter(ow.player)
    if px then
      local dx, dz = px - mx, pz - mz
      local d2 = dx * dx + dz * dz
      if d2 <= DETECT_RADIUS * DETECT_RADIUS and (not bestD or d2 < bestD)
         and (allaround or inFacingCone(m, dx, dz, d2)) then
        best, bestD = ow.player, d2
      end
    end
  end
  return best
end

-- ------- citizen flee -- driving an NPC's own movement fields directly
-- (`.moving`, `.targetX`, `.targetY`, `.facing`, `.progress`), the exact
-- shape `HordeMobs.lua`'s own `stepMob` already drives on a Horde-owned
-- NPC (`DramaticShapeVoxelMod-dev/lib/HordeMobs.lua:316-319`) -- the
-- only difference is the direction: AWAY from the demon instead of
-- downhill on a flow field toward the player. `NPC.lua` itself has no
-- flee mode of its own (confirmed by direct read) -- this is a genuine,
-- new-to-this-project behavior override, not a port of an existing one,
-- applied only while the NPC is a live target and undone implicitly the
-- moment this stops being called each frame (the NPC's own normal wander
-- timer resumes on its own, nothing to explicitly restore).
local function stepCitizenFlee(ow, npc, demonCx, demonCy)
  if npc.moving then return end
  local dx = npc.cellX - demonCx
  local dy = npc.cellY - demonCy
  local dirs = {}
  if math.abs(dx) >= math.abs(dy) then
    dirs[1] = { dx >= 0 and 1 or -1, 0 }
    dirs[2] = { 0, dy >= 0 and 1 or -1 }
  else
    dirs[1] = { 0, dy >= 0 and 1 or -1 }
    dirs[2] = { dx >= 0 and 1 or -1, 0 }
  end
  for _, d in ipairs(dirs) do
    local tx, ty = npc.cellX + d[1], npc.cellY + d[2]
    if walkableCell(ow.map, tx, ty) then
      npc.facing = (d[1] == 1 and "right") or (d[1] == -1 and "left")
                or (d[2] == 1 and "down") or "up"
      npc.targetX, npc.targetY = tx, ty
      npc.moving = true
      npc.progress = 0
      return
    end
  end
end

-- Exported so `lib/DoomHordeControl.lua` can reuse this exact same real
-- flee-step for citizens threatened by a Horde mob, instead of
-- reimplementing it -- see that file's own "locals flee" section for why.
DoomDemons.stepCitizenFlee = stepCitizenFlee

-- FEATURE 2026-08-07 -- user report: "the projectiles the player shoots
-- do not fire from the barrel of the gun and therefore miss many of the
-- shots it takes that would make it in the original doom." Traced to a
-- real, confirmed gap: real DOOM's own `P_SpawnPlayerMissile`
-- (p_mobj.c:934-987) auto-aims the VERTICAL slope of every hitscan/
-- missile shot via `P_AimLineAttack` -- essential in vanilla DOOM, which
-- has NO mouselook at all, so a player could never otherwise hit a
-- target whose center sits above or below their own fixed eye height.
-- This mod's own weapon fire uses `FirstPerson.pitch` for its vertical
-- aim component, but that field is deliberately forced to 0 at all
-- times while PKDOOM MODE is on (`lib/DoomView.lua`'s own `lockPitch`,
-- matching DOOM's real fixed-forward view) -- meaning every shot travels
-- perfectly level with NO auto-aim to compensate, unlike real DOOM.
-- Against this mod's own OPEN, terrain-varied world (unlike DOOM's own
-- typically level combat floors), a level shot whose height was fixed at
-- the SHOOTER's own local ground+eye height routinely sails clean over
-- or under a target standing on different terrain, or a floating
-- Cacodemon -- exactly matching "shots that would hit in real DOOM are
-- missing here." This export lets `lib/DoomWeapons.lua`'s own new
-- auto-aim search (mirroring `P_AimLineAttack`'s real intent, adapted to
-- this engine's own grid/entity model rather than DOOM's own BSP line
-- trace) find a demon candidate the same way it already can for citizens
-- via `ow.npcs`.
-- FOUND 2026-08-08 -- the demon half of the same root cause fixed the
-- same round in `lib/DoomWeapons.lua`'s own NPC aim branch (see that
-- file's own matching header comment for the full diagnosis and why
-- ~20 prior trajectory-only fixes never touched this symptom). This
-- used to report `m.roster.height or 56` -- DOOM's own real, RAW,
-- never-converted `mobjinfo.height` stat (56 for most of the roster, 64
-- for Baron of Hell, 100 for Spider Mastermind, 110 for Cyberdemon) --
-- as if it were a usable world-unit height. It never was: every demon
-- in this mod actually RENDERS at the same shared, calibrated
-- `DEMON_WORLD_HEIGHT` (16 world units, see that constant's own header
-- comment a few hundred lines up -- "every demon targets the SAME world
-- height... relative demon SIZE differences are not currently
-- represented"), regardless of its own real DOOM height stat. Aiming at
-- `gh + roster.height/2` therefore searched for a target center anywhere
-- from `gh+28` (most of the roster) to `gh+55` (Cyberdemon) -- every one
-- of those points sitting well above the demon's own real rendered top
-- edge at `gh+16`, worse the taller a demon's real DOOM stat happens to
-- be, which is exactly why this got dramatically worse against bosses
-- and never fully resolved even for the "regular" 56-height roster.
-- Real center-mass for every demon's own actual rendered card is
-- `DEMON_WORLD_HEIGHT / 2` -- the same fixed value every demon shares,
-- matching how they're actually drawn, not how tall DOOM's own source
-- says they'd be at DOOM's own unconverted scale.
function DoomDemons.aimTargets(ow)
  local list = {}
  if not ow then return list end
  for _, m in ipairs(demons) do
    if m.mapId == ow.map.id and m.state ~= "dying" then
      list[#list + 1] = { x = m.px + 8, z = m.py + 8, height = DEMON_WORLD_HEIGHT, cx = m.cx, cy = m.cy }
    end
  end
  return list
end

-- ------- continuous movement + collision (2026-08-07, replacing this
-- section's own earlier grid-cell-teleport-with-a-visual-glide system)
--
-- User's own explicit request: "the pathing is based on the pokemon
-- grid system. this was not in the original doom. instead the 3d space
-- should just be treated like a normal 3d space with no grid and the
-- doom enemies should just be able to walk wherever as long as they
-- dont walk past collision." Confirmed real DOOM's own movement is
-- genuinely continuous, never grid-snapped: `P_XYMovement`
-- (p_mobj.c:206-260) moves a mobj by its own fixed-point momentum every
-- single tic, checked by `P_TryMove`/`P_CheckPosition` against real 2D
-- line/circle collision -- there is no concept of a "cell" anywhere in
-- that path. The old cell-to-cell-with-a-visual-glide system was this
-- project's OWN earlier adaptation choice, not something DOOM itself
-- ever did -- and the grid-quantized position it left a demon's own
-- `m.px`/`m.py` snapped to once "arrived" (always exactly a cell
-- CENTER) was the real, confirmed root cause of this same day's earlier
-- `MELEE_RADIUS` dead-zone bug -- this rewrite removes that root cause
-- structurally instead of continuing to compensate for it with a wider
-- radius.
--
-- Mirrors the HOST mod's own real continuous-movement collision
-- (`DramaticShapeVoxelMod-dev/lib/FreeMove.lua`'s own `slideX`/`slideZ`,
-- the PLAYER's own free-roam walk) -- read and imitated, never edited
-- (CLAUDE.md's "addon, not a fork" rule): a demon is a circle in the
-- ground plane (`DEMON_RADIUS`), slid by however far it's actually
-- trying to move this frame, CLAMPED per axis at the first cell edge
-- that refuses it -- simplified from the host's own version to what a
-- demon actually needs (no tile-pair/surf/entity-occupancy checks --
-- those are real Gen1 ROUTE mechanics for the player alone, never real
-- DOOM monster behavior to begin with).
--
-- `DEMON_RADIUS` is one shared judgment call, not each roster entry's
-- own real DOOM `radius` field (20-128 DOOM map units, already present
-- in the roster data) -- there is no principled DOOM-map-unit
-- conversion (CLAUDE.md, same standing fact `MELEE_RADIUS`/
-- `DETECT_RADIUS` already cite), and Spider Mastermind's own real
-- 128-unit radius taken literally as world px would be too wide to fit
-- through almost any corridor in this Pokémon-scale world -- the exact
-- opposite of what this whole rewrite is trying to fix. Smaller than
-- half a cell (8) so a demon can always fit through a single-cell-wide
-- gap.
local DEMON_RADIUS = 6
local SLIDE_EPS = 0.01

-- Real DOOM's own `xspeed[]`/`yspeed[]` tables (p_enemy.c:56-63) scale a
-- diagonal step to ~0.71716 of a straight one (47000/65536) so a
-- diagonal move doesn't cover more real ground per tic than an axis
-- one -- this project's own exact `1/sqrt(2)` is close enough to that
-- real ratio and simpler to justify than reproducing DOOM's own
-- specific fixed-point approximation.
local DIAG = 0.70710678

-- Anchors a demon's own real DOOM `speed` mobjinfo value (8 is the most
-- common real value -- Zombieman/Shotgun Guy/Imp/Cacodemon/Baron/Lost
-- Soul all share it) to real world px/second -- preserves this
-- project's own already-tuned pacing exactly (the old system's own
-- `CELL_STEP_BASE_FRAMES=24` frames, ~0.4s, to cross a 16px cell at
-- speed=8 and 60fps works out to the same 40px/s this scale produces),
-- rather than picking a fresh, unverified number.
local DEMON_SPEED_SCALE = 5 -- world px/second per roster.speed unit

local function demonSpeedPxPerSec(m)
  return (m.roster.speed or 8) * DEMON_SPEED_SCALE * difficultyScale().speed
end

-- The real per-axis clamp -- mirrors `FreeMove.lua`'s own `slideX`/
-- `slideZ` exactly in shape: probe the strip of cells the circular body
-- would sweep into along this ONE axis, and if any refuse it, clamp the
-- new position to that cell's own near face (radius + a hair of
-- epsilon) instead of entering it. Calling both in sequence (below) is
-- what produces real wall-sliding: the blocked axis stops, the free one
-- keeps going, precisely the reason a body walking a fence line at an
-- angle glides along it instead of catching on every tile boundary.
local function slideX(ow, m, dx)
  if dx == 0 then return true end
  local r = DEMON_RADIUS
  local nx = m.px + dx
  local z0 = math.floor((m.py - r + SLIDE_EPS) / 16)
  local z1 = math.floor((m.py + r - SLIDE_EPS) / 16)
  local edge = dx > 0 and math.floor((nx + r) / 16) or math.floor((nx - r) / 16)
  local blocked = false
  for zc = z0, z1 do
    if not walkableCell(ow.map, edge, zc) or entityBlocksCell(ow, edge, zc) then blocked = true break end
  end
  if blocked then
    if dx > 0 then nx = math.min(nx, edge * 16 - r - SLIDE_EPS)
    else nx = math.max(nx, (edge + 1) * 16 + r + SLIDE_EPS) end
  end
  m.px = nx
  return not blocked
end

local function slideZ(ow, m, dz)
  if dz == 0 then return true end
  local r = DEMON_RADIUS
  local nz = m.py + dz
  local x0 = math.floor((m.px - r + SLIDE_EPS) / 16)
  local x1 = math.floor((m.px + r - SLIDE_EPS) / 16)
  local edge = dz > 0 and math.floor((nz + r) / 16) or math.floor((nz - r) / 16)
  local blocked = false
  for xc = x0, x1 do
    if not walkableCell(ow.map, xc, edge) or entityBlocksCell(ow, xc, edge) then blocked = true break end
  end
  if blocked then
    if dz > 0 then nz = math.min(nz, edge * 16 - r - SLIDE_EPS)
    else nz = math.max(nz, (edge + 1) * 16 + r + SLIDE_EPS) end
  end
  m.py = nz
  return not blocked
end

-- Moves along a (dx,dz) unit vector by `dist` world px this frame,
-- axis-separated (slideX then slideZ, same order the host's own free
-- walk uses) so a demon slides along whatever it grazes instead of
-- stopping dead on first contact -- real DOOM's own actual wall
-- behavior, not a grid-cell "yes/no" verdict. Returns the distance
-- actually covered, for the caller to judge whether this direction is
-- still making real progress or has effectively stalled against
-- something solid.
local function slideMove(ow, m, dx, dz, dist)
  local startX, startZ = m.px, m.py
  slideX(ow, m, dx * dist)
  slideZ(ow, m, dz * dist)
  local movedX, movedZ = m.px - startX, m.py - startZ
  return math.sqrt(movedX * movedX + movedZ * movedZ)
end

-- Roam has no real DOOM precedent at all (already an established,
-- confirmed fact in this file -- real monsters with no target just
-- stand in `A_Look`, they never wander) -- a free, any-angle continuous
-- glide straight at the waypoint is this mod's own simplest real
-- equivalent of "walk wherever, respecting only collision," matching
-- the user's own literal request for this mod-original system, where
-- there's no real 8-direction algorithm to stay faithful to in the
-- first place (unlike chase, below, which keeps DOOM's own real
-- 8-direction `P_NewChaseDir` -- only how each direction is walked
-- changed here, not which directions exist).
local function stepToward(ow, m, targetX, targetZ, dist)
  local dx, dz = targetX - m.px, targetZ - m.py
  local remaining = math.sqrt(dx * dx + dz * dz)
  if remaining < 1 then m.moving = false return end
  local ux, uz = dx / remaining, dz / remaining
  local moved = slideMove(ow, m, ux, uz, math.min(dist, remaining))
  if ux > 0.3 then m.facing = "right"
  elseif ux < -0.3 then m.facing = "left"
  elseif uz > 0 then m.facing = "down"
  else m.facing = "up" end
  m.moving = moved > SLIDE_EPS
  if moved < dist * 0.1 then
    m.roamWaypoint = nil -- effectively blocked; force a fresh pick next tick
  end
end

-- A target can vanish some way OTHER than this demon's own catch (the
-- player kills the same citizen first, or it walks into an interior and
-- the engine's own map-transition rebuild drops it from `ow.npcs`) --
-- checked against `save.killedNpcs`, the SAME real persistence table
-- `lib/DoomKill.lua`'s own kill path writes to, rather than an NPC field
-- presence check (an already-removed NPC's own Lua table still exists in
-- memory with all its old fields intact, so "does `.px` still exist"
-- never actually goes false the way a naive check might assume).
--
-- Moved up from lower in this file (2026-08-06) so `updateDemonProjectiles`
-- below (a forward reference otherwise -- a real bug, caught before ever
-- running, not shipped) can call it too, checking whether a projectile's
-- own aimed-at target has vanished mid-flight.
local function targetIsGone(ow, npc)
  if not npc then return true end
  -- The player is never "gone" this way -- there's no killedNpcs/ow.npcs
  -- membership to check for them at all (they're a different kind of
  -- object entirely), and unlike a citizen the player can't be removed
  -- out from under a demon mid-chase.
  if ow and ow.player and npc == ow.player then return false end
  local ok, Game = pcall(require, "src.core.Game")
  local killed = ok and Game.save and Game.save.killedNpcs
  if killed and killed[npc.id] then return true end
  local found = false
  for _, live in ipairs(ow.npcs or {}) do
    if live == npc then found = true break end
  end
  return not found
end

-- ------- "Pokemon NPCs as enemies" alternate ambient mode -- user
-- request (2026-08-06): "a toggle to switch from pokemon npcs as
-- enemies or demons as enemies," answered "both" when asked which
-- context it affects. This is the regular-mode half: instead of
-- spawning a synthetic DOOM-demon entity, an EXISTING citizen NPC is
-- marked hostile in place and hunts the PLAYER directly (kept to
-- player-only, not other citizens, to avoid an unbounded citizen-vs-
-- citizen chain reaction, a purely mod-original mechanic with no real
-- DOOM precedent to draw a scope boundary from otherwise) -- reusing
-- the exact same live-NPC-movement-field-driving technique
-- `stepCitizenFlee` above already proves out (toward the target
-- instead of away). Needs no fake entity, sprite, or mesh at all --
-- unlike an ambient demon, a possessed citizen already renders itself
-- through the engine's own real, unmodified NPC pipeline; it's the same
-- object the whole time, just walking somewhere different for a while.
--
-- Placed here (after `targetIsGone`, before the demon-projectile
-- system) rather than right next to `stepCitizenFlee` above -- a real
-- forward-reference bug, caught before it could ever run: this section
-- needs `targetIsGone`, which is itself defined right above this point
-- for the exact same reason (see that function's own header comment).
local possessedCitizens = {}

local function stepCitizenChase(ow, npc, targetCx, targetCy)
  if npc.moving then return end
  local dx, dy = targetCx - npc.cellX, targetCy - npc.cellY
  if dx == 0 and dy == 0 then return end
  local dirs = {}
  if math.abs(dx) >= math.abs(dy) then
    dirs[1] = { dx > 0 and 1 or -1, 0 }
    if dy ~= 0 then dirs[2] = { 0, dy > 0 and 1 or -1 } end
  else
    dirs[1] = { 0, dy > 0 and 1 or -1 }
    if dx ~= 0 then dirs[2] = { dx > 0 and 1 or -1, 0 } end
  end
  for _, d in ipairs(dirs) do
    local tx, ty = npc.cellX + d[1], npc.cellY + d[2]
    if walkableCell(ow.map, tx, ty) then
      npc.facing = (d[1] == 1 and "right") or (d[1] == -1 and "left")
                or (d[2] == 1 and "down") or "up"
      npc.targetX, npc.targetY = tx, ty
      npc.moving = true
      npc.progress = 0
      return
    end
  end
end

-- Judgment calls, same category as every other undreived number in
-- this project -- there is no real DOOM precedent for "a possessed
-- Pokemon NPC's own attack" to anchor these to at all, since this is a
-- purely mod-original alternate mode, not a DOOM-derived mechanic.
local POSSESS_MELEE_RADIUS = 10
local POSSESS_DAMAGE = 5
local POSSESS_COOLDOWN = 0.8
local MAX_POSSESSED = 4
local POSSESS_CHECK_INTERVAL = 6

local function tickPossessedCitizen(ow, entry, dt)
  local npc = entry.npc
  if entry.dead or targetIsGone(ow, npc) then entry.dead = true return end
  if not ow.player then return end
  local px, pz = npcCenter(ow.player)
  local nx, nz = npcCenter(npc)
  if not (px and nx) then return end
  stepCitizenChase(ow, npc, ow.player.cellX, ow.player.cellY)
  local dx, dz = px - nx, pz - nz
  if dx * dx + dz * dz <= POSSESS_MELEE_RADIUS * POSSESS_MELEE_RADIUS then
    entry.attackCooldown = (entry.attackCooldown or 0) - dt
    if entry.attackCooldown <= 0 then
      entry.attackCooldown = POSSESS_COOLDOWN
      pcall(DoomHealth.damage, POSSESS_DAMAGE, { source = "demon", attacker = npc })
    end
  end
end

local possessTimer = 0
local function ambientPossessTick(ow, dt)
  possessTimer = possessTimer - dt
  if possessTimer > 0 then return end
  possessTimer = POSSESS_CHECK_INTERVAL
  if isInteriorMap(ow.map) then return end
  local count = 0
  for _, e in ipairs(possessedCitizens) do
    if e.mapId == ow.map.id and not e.dead then count = count + 1 end
  end
  if count >= MAX_POSSESSED then return end
  local candidates = {}
  for _, npc in ipairs(ow.npcs or {}) do
    if not (npc.pokedoomPossessed or npc.pokedoomBeingHunted or npc.pikachuFollower) then
      candidates[#candidates + 1] = npc
    end
  end
  if #candidates == 0 then return end
  local npc = candidates[math.random(#candidates)]
  npc.pokedoomPossessed = true
  npc.wanders = false
  possessedCitizens[#possessedCitizens + 1] = { npc = npc, mapId = ow.map.id, attackCooldown = 0 }
end

-- Reverts every currently-possessed citizen back to normal (its own
-- `wanders` behavior resumes on its own, nothing else to restore) --
-- called whenever ENEMIES turns off or ENEMY TYPE switches away from
-- "pokemon", the same "off means off" cleanup the demon system's own
-- teardown branch already does for its own entities.
local function clearPossessedCitizens()
  for _, e in ipairs(possessedCitizens) do
    if e.npc then
      e.npc.pokedoomPossessed = nil
      e.npc.wanders = true
    end
  end
  possessedCitizens = {}
end

-- ------- demon-fired projectiles (Phase 22 Round 2) -- real DOOM
-- fireball/rocket sprites, read fresh from `info.c`: Imp's `MT_TROOPSHOT`
-- (sprite `BAL1`, `info.c:233-237`), Cacodemon's `MT_HEADSHOT` (`BAL2`,
-- `info.c:238-242`), Baron of Hell's `MT_BRUISERSHOT` (`BAL7`,
-- `info.c:658-662`) all share the exact same real shape: flight frames
-- A/B ping-pong at 4 tics, explosion frames C/D/E at 6 tics each.
-- Cyberdemon reuses `MT_ROCKET` (`MISL`) -- the identical sprite/timing
-- `lib/DoomWeapons.lua`'s own player rocket launcher already ports
-- (`PROJECTILE_VISUAL.ROCKET`): a single static flight frame (real DOOM
-- has no rocket spin), explosion frames B/C/D. The entity/pose/mesh-hook
-- shape below is the same one that file's own `makeProjectileEntity`
-- uses for the player's own weapons -- restated here rather than shared
-- directly, since demon projectiles reuse THIS file's own sprite-
-- loading/mesh cache (`loadDemonSprite`/`demonMesh`) and mark their
-- synthetic def `pokedoomDemon = true` (the existing mesh hook's own
-- marker, reused rather than added a third time -- a demon's own
-- fireball genuinely IS demon content, unlike the player's own weapon
-- projectiles in the other file, where reusing that same flag would
-- have been a real category error).
-- FOUND 2026-08-08 -- direct user request, sound-system audit ("might
-- not have every sound"): a demon's own thrown fireball/rocket was
-- entirely SILENT, both launching and exploding -- `fireDemonProjectile`/
-- `updateDemonProjectiles` below never played a sound at all, for any of
-- the 4 roster monsters that actually throw one (Imp, Cacodemon, Baron
-- of Hell, Cyberdemon). Real DOOM: every one of `MT_TROOPSHOT`/
-- `MT_HEADSHOT`/`MT_BRUISERSHOT`'s own real mobjinfo (info.c:1914-1938,
-- 1940-1964, 1524-1548) shares the identical real `seesound`/`deathsound`
-- pair -- `sfx_firsht` (DSFIRSHT) on spawn, `sfx_firxpl` (DSFIRXPL) on
-- impact -- a real DOOM mobjinfo's own `seesound` plays automatically
-- the instant `P_SpawnMobj` creates it (the same real mechanism this
-- project's own player rocket/plasma already reproduces the EFFECT of,
-- see `lib/DoomWeapons.lua`'s own `Actions.fireMissile`/`.firePlasma`
-- header comment). `MT_ROCKET` (Cyberdemon's own reused rocket) instead
-- uses the real `sfx_rlaunc`/`sfx_barexp` (DSRLAUNC/DSBAREXP) pair
-- already ported for the player's own rocket launcher (`lib/
-- DoomWeapons.lua`'s `PROJECTILE.ROCKET`).
local DEMON_PROJECTILE_VISUAL = {
  BAL1 = { flightLetters = { "A", "B" }, flightTics = 4, explodeLetters = { "C", "D", "E" }, explodeTics = 6,
           launchSound = "DSFIRSHT", deathSound = "DSFIRXPL" },
  BAL2 = { flightLetters = { "A", "B" }, flightTics = 4, explodeLetters = { "C", "D", "E" }, explodeTics = 6,
           launchSound = "DSFIRSHT", deathSound = "DSFIRXPL" },
  BAL7 = { flightLetters = { "A", "B" }, flightTics = 4, explodeLetters = { "C", "D", "E" }, explodeTics = 6,
           launchSound = "DSFIRSHT", deathSound = "DSFIRXPL" },
  MISL = { flightLetters = { "A" }, flightTics = 4, explodeLetters = { "B", "C", "D" }, explodeTics = 6,
           launchSound = "DSRLAUNC", deathSound = "DSBAREXP" },
}

local function playDemonSound(lump, label)
  if not lump then return end
  local ok, snd = pcall(DoomWadImport.loadSound, lump)
  if ok and snd then DoomWadImport.playClone(lump .. " (" .. label .. ")", snd) end
end

-- World px/frame -- no principled DOOM-map-unit conversion exists for
-- this (CLAUDE.md's own locked decision on speed scaling), so the
-- BASELINE (5.0, for the 10-FRACUNIT fireballs) is a judgment call, same
-- category as every other undreived speed figure in this project --
-- picked to roughly match `lib/DoomWeapons.lua`'s own player-projectile
-- speeds rather than invented independently.
--
-- FIXED 2026-08-10 -- direct user request: "find out which demons shoot
-- projectiles and implement all projectiles as closely as possible with
-- the real doom." Real DOOM's own mobjinfo speeds (`info.c`, read fresh)
-- are NOT uniform across these 4 projectile types the way a single flat
-- constant here implied: `MT_TROOPSHOT`/`MT_HEADSHOT` (Imp/Cacodemon
-- fireballs) are both `10*FRACUNIT`, `MT_BRUISERSHOT` (Baron of Hell) is
-- `15*FRACUNIT` (1.5x), and `MT_ROCKET` (Cyberdemon, the same real
-- rocket type the player's own launcher fires) is `20*FRACUNIT` (2x) --
-- a real, meaningful difference in how fast each demon's own shot
-- crosses the screen that a single shared speed constant silently
-- erased. Anchored to the SAME already-tuned 5.0 baseline for the
-- 10-FRACUNIT pair (rather than deriving a fresh number) and scaled by
-- the exact real DOOM ratio for the other two.
local DEMON_PROJECTILE_SPEED = {
  BAL1 = 5.0,  -- MT_TROOPSHOT, 10*FRACUNIT
  BAL2 = 5.0,  -- MT_HEADSHOT, 10*FRACUNIT
  BAL7 = 7.5,  -- MT_BRUISERSHOT, 15*FRACUNIT (1.5x the 10-FRACUNIT baseline)
  MISL = 10.0, -- MT_ROCKET, 20*FRACUNIT (2x the 10-FRACUNIT baseline)
}
local DEMON_PROJECTILE_HIT_RADIUS = 10 -- world px, matches this file's own MELEE_RADIUS

local demonProjectiles = {}
local nextDemonProjectileId = 1

local function makeDemonProjectileEntity(proj)
  local entity
  entity = {
    passable = true,
    px = proj.x, py = proj.z, cellX = math.floor(proj.x / 16), cellY = math.floor(proj.z / 16),
    draw = function() end,
    pose = function()
      local visual = DEMON_PROJECTILE_VISUAL[proj.sprite]
      local letters = proj.exploding and visual.explodeLetters or visual.flightLetters
      local letter = letters[proj.animIndex] or letters[1]
      local ok, image = pcall(loadDemonSprite, proj.sprite, letter)
      if not ok then image = nil end
      local spriteObj = {
        def = {
          pokedoomDemon = true, pokedoomCacheKey = "proj-" .. proj.sprite .. letter,
          pokedoomSpritePrefix = proj.sprite,
          pokedoomImage = image, trueColor = true, image = "pokedoom-demonproj-" .. proj.sprite,
        },
      }
      function spriteObj:resolveImage() return self.def.pokedoomImage end
      local gh = groundY(proj.ow, entity.cellX, entity.cellY)
      -- FIXED 2026-08-10 -- user report: "enemies projectiles added a
      -- few phases ago float above the enemies, the same bug as the
      -- players projectiles floating above them." Confirmed: this
      -- function never received the 2026-08-08 vertical-anchor fix
      -- `lib/DoomWeapons.lua`'s own `makeProjectileEntity` got for the
      -- identical bug (see that function's own header comment for the
      -- full derivation) -- `buildDemonMesh`'s billboard quads run from
      -- LOCAL y=0 (bottom edge) to y=worldH (top edge), correct for a
      -- ground-anchored walking demon/NPC but wrong for a flying
      -- projectile, whose `proj.y` is meant to read as its own CENTER,
      -- not its lowest visible pixel -- without this shift, the whole
      -- sprite renders stacked above its true position, a constant bias
      -- independent of aim/trajectory (exactly why the earlier player-
      -- projectile bug survived ~20 trajectory-focused fix attempts
      -- before the real cause was found in rendering instead). This
      -- file already has its own local `worldHeightFor` (used by `lib/
      -- DoomWeapons.lua` via the `DoomDemons.worldHeightFor` export for
      -- that exact fix) -- reused directly here rather than duplicated.
      local halfWorldH = 0
      if image then
        local okH, worldH = pcall(worldHeightFor, proj.sprite, image)
        if okH and worldH then halfWorldH = worldH / 2 end
      end
      local vy = entity.py - (proj.y - gh - halfWorldH)
      return spriteObj, entity.px, vy, "down", 0, false
    end,
  }
  return entity
end

local function removeDemonProjectileEntity(ow, proj)
  proj.inserted = false
  if not (proj.entity and ow and ow.entities) then return end
  for i, e in ipairs(ow.entities) do
    if e == proj.entity then table.remove(ow.entities, i) break end
  end
  proj.entity = nil
end

-- Aims once, at the target's position AT THE MOMENT OF FIRING -- real
-- DOOM's own `P_SpawnMissile` does the same (a straight line, no
-- homing/re-aim mid-flight).
-- FIX 2026-08-08 (Phase 24 audit, Tier 1 #5) -- moved up from its own
-- later declaration (still there for `checkMissileRangeReal`'s own use)
-- so it's in scope here -- Lua has no hoisting, and `fireDemonProjectile`/
-- `updateDemonProjectiles` below need it too, for the same real bug
-- class CLAUDE.md's own hard rule is about: `p.animTimer` used to be a
-- raw DOOM tic count (`visual.flightTics`/`explodeTics`, e.g. 4 or 6)
-- decremented by exactly `1` per call, with `updateDemonProjectiles`
-- confirmed called once per real `input.step` tick (60Hz, not 35Hz) --
-- a confirmed 60/35 ~= 1.71x speedup, the same bug already fixed for
-- `maybePlayActiveSound`/`checkMissileRangeReal`/`m.moveCount` but never
-- applied to demon-fired projectiles. Every Imp/Cacodemon/Baron of Hell
-- fireball and Cyberdemon rocket animated noticeably faster than real
-- DOOM. Fixed by converting `animTimer` to real seconds remaining
-- (`tics * DOOM_TIC_SECONDS`, decremented by real `dt`) -- the same
-- plain float-countdown shape this file's own `m.reactionTime`/
-- `m.threshold` already use, correct here (unlike a discrete gate that
-- needs an exact-zero OBSERVATION) since this is purely a visual
-- frame-advance clock, not something else's gate condition.
local DOOM_TIC_SECONDS = 1 / 35

-- Forward-declared: the real body (below `applyAoeDamageToDemon`, since
-- it calls that function plus `losClear`, both defined much later in
-- this file) is assigned further down. Lua has no hoisting -- this is
-- the standard declare-then-assign idiom for a function whose real
-- dependencies aren't in scope yet at its most natural call site
-- (`updateDemonProjectiles`, right below), matching this file's own
-- established precedent of moving small dependencies earlier where
-- practical (Phase 24 audit, Tier 1 #5) -- not practical here, since
-- `applyAoeDamageToDemon`/`losClear` are large and have their own deep
-- dependency chains (`startDeath`/`retargetOntoAttacker`/`rollPain`)
-- that would all need moving too.
local demonProjectileSplash

-- FIX 2026-08-11 -- user report + screenshot: a demon-fired projectile
-- (a Cacodemon fireball, visibly a floating red ball) rendering well
-- above the demon that fired it, not coming "straight from them." This
-- is the exact same root-cause CATEGORY already found and fixed for
-- `DoomDemons.aimTargets` on 2026-08-08 (see that function's own header
-- comment for the full diagnosis) -- just a DIFFERENT call site the
-- same fix was never carried to, the exact "trace every parallel
-- implementation" gap CLAUDE.md's own hard rule warns about. This spawn
-- point used to read `groundY(...) + (m.roster.height or 56) / 2` --
-- DOOM's own real, RAW, never-converted `mobjinfo.height` stat (56 for
-- most of the roster, up to 110 for Cyberdemon) treated as if it were a
-- usable world-unit height. It never was: every demon in this mod
-- actually renders at the same shared, calibrated `DEMON_WORLD_HEIGHT`
-- (16 world units), regardless of its own real DOOM height stat --
-- spawning at `roster.height/2` put the fireball's origin anywhere from
-- `gh+28` (most of the roster) to `gh+55` (Cyberdemon), well above the
-- demon's own real rendered top edge at `gh+16`. Fixed to match
-- `aimTargets`'s own already-proven center-mass value,
-- `DEMON_WORLD_HEIGHT / 2` -- the same point the player's own auto-aim
-- already searches for when shooting AT this demon, so the fireball now
-- visually originates from the same place the demon visually is.
local function fireDemonProjectile(ow, m, target)
  local visual = DEMON_PROJECTILE_VISUAL[m.roster.projectileSprite]
  if not visual then return end
  local mx, mz = m.px, m.py -- real, continuous firing position -- see `findTarget`'s own matching note
  local tx, tz = npcCenter(target)
  if not tx then return end
  local dx, dz = tx - mx, tz - mz
  local dist = math.sqrt(dx * dx + dz * dz)
  if dist < 1 then return end
  -- Real per-type speed (see DEMON_PROJECTILE_SPEED's own header comment
  -- for the info.c-sourced ratios) -- falls back to the 10-FRACUNIT
  -- baseline if this sprite somehow isn't in the table.
  local spd = DEMON_PROJECTILE_SPEED[m.roster.projectileSprite] or 5.0
  nextDemonProjectileId = nextDemonProjectileId + 1
  demonProjectiles[#demonProjectiles + 1] = {
    id = nextDemonProjectileId, mapId = ow.map.id, ow = ow,
    -- kept for Phase 15's own death-camera turn-toward-attacker (`lib/
    -- DoomView.lua`), which needs the firing demon's own LIVE position,
    -- not just the projectile's static impact point.
    owner = m,
    sprite = m.roster.projectileSprite,
    damageDie = m.roster.projectileDamageDie or m.roster.damageDie,
    damageMult = m.roster.projectileDamageMult or m.roster.damageMult,
    x = mx, y = groundY(ow, m.cx, m.cy) + DEMON_WORLD_HEIGHT / 2, z = mz,
    dx = dx / dist * spd, dz = dz / dist * spd, speed = spd,
    target = target, targetIsPlayer = (ow.player and target == ow.player) or false,
    animIndex = 1, animTimer = visual.flightTics * DOOM_TIC_SECONDS, traveled = 0,
  }
  playDemonSound(visual.launchSound, m.roster.projectileSprite .. " launch, " .. m.name)
end

-- Kills an NPC a demon (or demon projectile) caught -- the real,
-- consistently-repeated ending shared by every real DOOM catch-a-
-- citizen path (melee, Lost Soul charge, hitscan, a landed projectile):
-- clear the citizen's own hunted flag, do the actual kill, and announce
-- it (only on a CONFIRMED kill -- `ok`, not unconditionally; one real
-- call site was missing this guard before this was factored out).
-- Extracted 2026-08-19 during a project-wide readability audit -- this
-- exact sequence was independently repeated 4 times across this file.
-- Does NOT touch a demon's own `m.target`/`m.state` -- each real caller
-- clears those itself, since what happens to THEM afterward genuinely
-- differs by call site (a melee kill returns to roam immediately;
-- others don't).
local function catchAndKillNpc(ow, npc)
  npc.pokedoomBeingHunted = nil
  local ok = pcall(DoomKill.killNpc, ow, npc)
  if ok and DoomHud and DoomHud.announce and Options.messagesEnabled() then
    DoomHud.announce("A demon got someone.")
  end
end

-- Advances every live demon projectile one tick: travel, target-
-- proximity/expiry check, explosion lifecycle, and keeping its own
-- visual entity's position fields LIVE every tick (never frozen at
-- construction -- the exact real bug already caught and fixed once this
-- same day in this file's own ambient-demon entities, applied here from
-- the start instead of re-discovering it a second time).
-- FIX 2026-08-09 -- Phase 26 lag audit: same O(projectiles × entities)
-- per-tick membership-scan waste found and fixed the same way
-- elsewhere this round (see `syncDemons`'s own matching comment above).
-- A demon projectile is always removed the instant it leaves its own
-- map (below), so it can never outlive a real `ow.entities` rebuild the
-- way a demon/gib/item can -- this map-id check is still included for
-- defense in depth/consistency with every sibling fix, not because a
-- concrete failure mode was found without it.
local lastProjectileEntitiesMapId = nil
local function updateDemonProjectiles(ow, dt)
  if ow.map.id ~= lastProjectileEntitiesMapId then
    for _, p in ipairs(demonProjectiles) do p.inserted = false end
    lastProjectileEntitiesMapId = ow.map.id
  end
  for i = #demonProjectiles, 1, -1 do
    local p = demonProjectiles[i]
    if p.mapId ~= ow.map.id then
      removeDemonProjectileEntity(ow, p)
      table.remove(demonProjectiles, i)
    elseif p.exploding then
      p.animTimer = (p.animTimer or 0) - dt
      if p.animTimer <= 0 then
        local visual = DEMON_PROJECTILE_VISUAL[p.sprite]
        p.animIndex = (p.animIndex or 1) + 1
        if p.animIndex > #visual.explodeLetters then
          removeDemonProjectileEntity(ow, p)
          table.remove(demonProjectiles, i)
        else
          p.animTimer = visual.explodeTics * DOOM_TIC_SECONDS
        end
      end
    else
      local visual = DEMON_PROJECTILE_VISUAL[p.sprite]
      p.x, p.z = p.x + p.dx, p.z + p.dz
      p.traveled = p.traveled + (p.speed or 5.0)
      p.animTimer = (p.animTimer or 0) - dt
      if p.animTimer <= 0 then
        p.animTimer = visual.flightTics * DOOM_TIC_SECONDS
        p.animIndex = (p.animIndex or 0) % #visual.flightLetters + 1
      end
      p.entity = p.entity or makeDemonProjectileEntity(p)
      p.entity.px, p.entity.py = p.x, p.z
      p.entity.cellX, p.entity.cellY = math.floor(p.x / 16), math.floor(p.z / 16)
      if not p.inserted then
        table.insert(ow.entities, p.entity)
        p.inserted = true
      end
      local exploded = p.traveled > DETECT_RADIUS * 3 or not ow.map:inBounds(p.entity.cellX, p.entity.cellY)
      if not exploded and targetIsGone(ow, p.target) then
        exploded = true -- the target it was aimed at is already gone; let it fizzle in place
      end
      if not exploded then
        local tx, tz = npcCenter(p.target)
        if tx then
          local ddx, ddz = tx - p.x, tz - p.z
          if ddx * ddx + ddz * ddz <= DEMON_PROJECTILE_HIT_RADIUS * DEMON_PROJECTILE_HIT_RADIUS then
            exploded = true
            -- Same formula `rollDemonDamage` above uses, restated rather
            -- than shared (a projectile's own `damageDie`/`damageMult`
            -- were copied from its owner's roster at spawn time, not the
            -- roster table itself) -- see DIFFICULTY_SCALE's own header
            -- comment for why this also gets the difficulty multiplier.
            local damage = math.max(1, math.floor(
              math.random(p.damageDie or 8) * (p.damageMult or 3) * difficultyScale().damage))
            if p.targetIsPlayer then
              if p.owner then p.owner.lastHitKind = "ranged" end -- real fireball impact
              pcall(DoomHealth.damage, damage, { source = "demon", attacker = p.owner })
            else
              catchAndKillNpc(ow, p.target)
            end
          end
        end
      end
      if exploded then
        p.exploding = true
        p.animIndex = 1
        p.animTimer = visual.explodeTics * DOOM_TIC_SECONDS
        playDemonSound(visual.deathSound, p.sprite .. " impact")
        -- FEATURE 2026-08-10 -- direct user request: "find out which
        -- demons shoot projectiles and implement all projectiles as
        -- closely as possible with the real doom." Real DOOM: ONLY
        -- `MT_ROCKET`'s own deathstate calls `A_Explode` (confirmed
        -- fresh -- `S_TBALLX1`/`S_RBALLX1`/`S_BRBALLX1`, the Imp/
        -- Cacodemon/Baron of Hell fireball deathstates, all have `NULL`
        -- actions, no splash at all) -- the Cyberdemon's own reused
        -- rocket is the one demon projectile with real area damage on
        -- impact, previously a stated, flagged scope cut on this
        -- roster's own CYBERDEMON entry ("no splash... a real, flagged
        -- scope cut, not silently dropped") -- implemented now.
        if p.sprite == "MISL" then
          pcall(demonProjectileSplash, ow, p.x, p.y, p.z, p.owner)
        end
      end
    end
  end
end

-- ------- per-demon tick
local ROAM_WAYPOINT_RADIUS = 6 -- cells

local function pickRoamWaypoint(ow, m)
  for _ = 1, 10 do
    local cx = m.cx + math.random(-ROAM_WAYPOINT_RADIUS, ROAM_WAYPOINT_RADIUS)
    local cy = m.cy + math.random(-ROAM_WAYPOINT_RADIUS, ROAM_WAYPOINT_RADIUS)
    if walkableCell(ow.map, cx, cy) then
      m.roamWaypoint = { cx, cy }
      return
    end
  end
end

-- ------- Lost Soul's own real charge attack (Phase 22, Round 3) --
-- real DOOM's `A_SkullAttack` (`p_enemy.c:1419-1442`, audited in
-- `phases/phase-22-demon-behavior-parity.md`): the ENTIRE attack is the
-- movement -- it launches directly at the target's CURRENT position at
-- a real, faster-than-walking speed (`SKULLSPEED = 20*FRACUNIT`, vs. its
-- own listed mobjinfo `speed = 8`), deals damage purely by touching
-- whatever it hits, then snaps back to its own spawn/roam state
-- INSTANTLY either way (a real, confirmed difference from every other
-- demon here -- no return-flight animation). Restated as a straight-line
-- world-px flight rather than porting the real fine-angle/momentum
-- vector math (`finecosine`/`finesine`) -- this project's own "avoid
-- math-derived code" preference for the state-driven equivalent; the
-- FUNCTIONAL result (launches once at the target, travels in a straight
-- line, hits or gives up) is the same.
local LOSTSOUL_CHARGE_SPEED = 6.0 -- world px/frame -- faster than this file's own normal grid-step demon speeds, a judgment call (no principled DOOM-map-unit conversion), matching every other undreived speed figure in this project
local LOSTSOUL_CHARGE_MAX_TRAVEL = 200 -- world px -- gives up and returns to roam if the charge overshoots this far with no hit, rather than flying forever

local function startLostSoulCharge(m)
  local tx, tz = npcCenter(m.target)
  if not tx then return end
  local mx, mz = m.px, m.py -- real, continuous launch position -- see `findTarget`'s own matching note
  local dx, dz = tx - mx, tz - mz
  local dist = math.sqrt(dx * dx + dz * dz)
  if dist < 1 then return end
  m.charging = true
  -- ADDED 2026-08-08 (sound-system audit) -- `A_SkullAttack`'s own real
  -- first two lines (`p_enemy.c:1429-1431`): `actor->flags |=
  -- MF_SKULLFLY; S_StartSound(actor, actor->info->attacksound)` -- Lost
  -- Soul's own real mobjinfo `attacksound` is `sfx_sklatk` (DSSKLATK,
  -- `info.c:1583`), a distinct "shriek" played the INSTANT the charge
  -- begins -- was entirely missing (the roster entry had no
  -- `attackSound`/`meleeSound` field at all).
  playDemonSound(m.roster.meleeSound, m.name .. " charge")
  startAttackAnim(m) -- Real DOOM's own ATK3/ATK4 C/D loop, held for the charge's own real full duration (see `advanceAttackFrame`'s own "charge" special-case)
  m.chargeDx, m.chargeDz = dx / dist * LOSTSOUL_CHARGE_SPEED, dz / dist * LOSTSOUL_CHARGE_SPEED
  m.chargeTraveled = 0
  -- `.px`/`.py` become the demon's own real, continuous flight position
  -- for the duration of the charge -- `stepToward`'s own cell-stepping
  -- is bypassed entirely while charging (mirroring how real DOOM's own
  -- `MF_SKULLFLY` flag overrides its normal move logic during flight).
  m.px, m.py = mx, mz
end

local function tickLostSoulCharge(ow, m)
  m.px = m.px + m.chargeDx
  m.py = m.py + m.chargeDz
  m.chargeTraveled = m.chargeTraveled + LOSTSOUL_CHARGE_SPEED
  m.cx, m.cy = math.floor(m.px / 16), math.floor(m.py / 16)
  local hit = false
  if m.target and not targetIsGone(ow, m.target) then
    local tx, tz = npcCenter(m.target)
    if tx then
      local dx, dz = tx - m.px, tz - m.py
      if dx * dx + dz * dz <= MELEE_RADIUS * MELEE_RADIUS then hit = true end
    end
  else
    m.target = nil
  end
  if hit then
    if ow.player and m.target == ow.player then
      m.lastHitKind = "ranged" -- charge has no melee/ranged split (single real obituary)
      pcall(DoomHealth.damage, rollDemonDamage(m.roster), { source = "demon", attacker = m })
    else
      local caught = m.target
      m.target = nil
      catchAndKillNpc(ow, caught)
    end
    m.charging = false
    m.attacking = false
    m.state = "roam"
  elseif m.chargeTraveled >= LOSTSOUL_CHARGE_MAX_TRAVEL or not m.target then
    m.charging = false
    m.attacking = false
    m.state = "roam"
  end
end

-- Real DOOM's own pain-state interrupt (`P_DamageMobj`, `p_inter.c`,
-- audited in this phase's own Phase 22 doc): landing a hit rolls
-- `P_Random() < painchance`, and on success `P_SetMobjState(target,
-- painstate)` briefly takes over -- no new attack, no chase movement,
-- until the pain frames finish (2-3 real tics per monster here, ~0.06-
-- 0.1s at DOOM's own 35Hz, functionally instant). `demonResolver`/
-- `demonAoeResolver` below already rolled `painChance` and played the
-- real pain SOUND on a successful roll, but never actually interrupted
-- anything -- purely cosmetic. This is Phase 22's own Round 4: a real,
-- short, state-driven stagger (a plain `dt` countdown, not a tic-exact
-- port of DOOM's own 2-3-tic pain-state timing, which would be
-- imperceptibly short at this engine's own frame rate anyway) that
-- actually halts movement/attack while it's active -- long enough to be
-- a real, visible flinch, unlike DOOM's own near-instant version.
local PAIN_STAGGER_DURATION = 0.25
-- Exported 2026-08-07 so `lib/DoomHordeControl.lua`'s own reskinned-mob
-- pain flinch (added same round) uses the exact same real duration as
-- the ambient system's, rather than a second, independently-guessed one.
DoomDemons.PAIN_STAGGER_DURATION = PAIN_STAGGER_DURATION

-- ------- real DOOM movement/pathing/targeting/attack-decision AI
--
-- Moved to its own file, `lib/DoomDemonAI.lua`, 2026-08-19 during a
-- project-wide readability audit -- this file (`lib/DoomDemons.lua`) was
-- already at Lua's real, hard 200-local-per-function compile ceiling
-- (see that file's own header comment for the full derivation, plus this
-- file's own remaining comments citing the same history). Every citation
-- and fix-history comment for `A_Chase`/`P_NewChaseDir`/
-- `P_CheckMeleeRange`/`P_CheckMissileRange` and the rest of this roster's
-- own real attack-decision logic now lives there, unchanged -- read that
-- file directly for the full design/derivation, not restated here.
-- `attach(deps)` is a mechanical, behavior-preserving call: every
-- function this file used to define inline is now defined there instead,
-- closing over the exact same live state (this file's own `demons` list,
-- `DoomDemons._demonAI`, every helper it already calls) via `deps`
-- instead of direct upvalue capture -- runs identically either way.
local DoomAI = DoomDemonAI.attach({
  DoomDemons = DoomDemons,
  DoomLog = DoomLog,
  DoomHealth = DoomHealth,
  DoomWadImport = DoomWadImport,
  DoomBlood = DoomBlood,
  FirstPerson = FirstPerson,
  demons = demons,
  blocksSight = blocksSight,
  walkableCell = walkableCell,
  entityBlocksCell = entityBlocksCell,
  npcCenter = npcCenter,
  targetIsGone = targetIsGone,
  heardNoiseAlert = heardNoiseAlert,
  findTarget = findTarget,
  stepCitizenFlee = stepCitizenFlee,
  startAttackAnim = startAttackAnim,
  playDemonSound = playDemonSound,
  rollDemonDamage = rollDemonDamage,
  catchAndKillNpc = catchAndKillNpc,
  groundY = groundY,
  pelletConnects = pelletConnects,
  fireDemonProjectile = fireDemonProjectile,
  startLostSoulCharge = startLostSoulCharge,
  tickLostSoulCharge = tickLostSoulCharge,
  demonSpeedPxPerSec = demonSpeedPxPerSec,
  worldPos = worldPos,
  stepToward = stepToward,
  pickRoamWaypoint = pickRoamWaypoint,
  DEMON_RADIUS = DEMON_RADIUS,
  SLIDE_EPS = SLIDE_EPS,
  MELEE_RADIUS = MELEE_RADIUS,
  DETECT_RADIUS = DETECT_RADIUS,
  DIAG = DIAG,
  DOOM_TIC_SECONDS = DOOM_TIC_SECONDS,
  PLAYER_MELEE_COOLDOWN = PLAYER_MELEE_COOLDOWN,
})
-- Re-localized here because code further down in THIS file still calls
-- them directly: `tickDemon` (this file's own tick dispatch),
-- `ticsToSeconds`/`REACTIONTIME_TICS`/`BASETHRESHOLD_TICS`/`DIR.NODIR`
-- (`spawnDemon`/`spawnPickedDemon`'s own real per-monster init, matching
-- p_mobj.c's own spawn-time `reactiontime = info->reactiontime`), and
-- `playSeeSound`/`ticsToSeconds`/`BASETHRESHOLD_TICS` again
-- (`retargetOntoAttacker`'s own real `A_Chase`-adjacent retarget, p_inter.c).
local tickDemon = DoomAI.tickDemon
local ticsToSeconds = DoomAI.ticsToSeconds
local playSeeSound = DoomAI.playSeeSound
local REACTIONTIME_TICS = DoomAI.REACTIONTIME_TICS
local BASETHRESHOLD_TICS = DoomAI.BASETHRESHOLD_TICS
local DIR = DoomAI.DIR

-- ------- ambient spawner (regular mode, Horde Mode off)
--
-- Outdoors only ("they should only spawn outdoors, so indoors are
-- safe") -- the same real `isInteriorMap` check `lib/DoomItems.lua`
-- already established for its own world-scatter pickups. A population
-- cap and a spawn-attempt timer, not an unbounded flood -- a judgment
-- call (DOOM has no equivalent to "ambient, persistent open-world
-- demon density"), flagged as adjustable, same category as every
-- other "no source to derive from" number in this project.
local MAX_AMBIENT_DEMONS = 4
local SPAWN_CHECK_INTERVAL = 6 -- seconds

-- FEATURE 2026-08-10 -- user request: a new "DEMON DENSITY" options row
-- (LOW/NORMAL/HIGH, `lib/DoomOptions.lua`). Scales the population cap
-- above rather than the spawn-check cadence -- "how many can be around
-- at once" reads more directly as "density" than "how often a check
-- happens," and the existing `SPAWN_CHECK_INTERVAL`/eligibility roll
-- naturally still fills back up to whatever cap is currently active.
local DENSITY_SCALE = { low = 0.5, normal = 1.0, high = 1.75 }

local function currentMaxAmbientDemons()
  local scale = DENSITY_SCALE[Options.demonDensity()] or 1.0
  return math.max(1, math.floor(MAX_AMBIENT_DEMONS * scale))
end
local spawnTimer = 0

local function ambientDemonCount(mapId)
  local n = 0
  for _, m in ipairs(demons) do
    if m.mapId == mapId and m.state ~= "dying" then n = n + 1 end
  end
  return n
end

-- CORRECTED 2026-08-07 -- part of the same audit as `findTarget`'s own
-- `allaround` fix above (user report: demons standing near town
-- buildings that just never path to anyone). Real DOOM's own monsters
-- each carry a per-instance `angle` set by the level designer when the
-- map was built -- effectively arbitrary from a player's own
-- perspective, but never a single hardcoded direction repeated for
-- every monster on the level. This mod has no level-authored angle to
-- read (demons spawn at random runtime points, not fixed map
-- positions) -- every ambient demon defaulted to `facing = "down"`
-- unconditionally, meaning `inFacingCone`'s own real cone gate
-- (confirmed correct, faithful DOOM behavior on its own) combined with
-- that CONSTANT default to produce a real, deterministic, avoidable
-- bias: any freshly-spawned, not-yet-moved demon approached from the
-- north (or, once it's taken a step or two, whatever direction it
-- happens to be walking away from) could go unnoticed indefinitely,
-- regardless of how close the player actually was, until literally
-- within melee range. Picking a real random facing at spawn is this
-- mod's own closest equivalent to DOOM's own per-instance authored
-- angle -- not a DOOM fact to derive, but the same kind of judgment
-- call `GRASS_SPAWN_CHANCE`/`DETECT_RADIUS` above already are.
local FACINGS = { "down", "up", "left", "right" }
local function randomFacing()
  return FACINGS[math.random(#FACINGS)]
end

local function spawnDemon(ow, name, atCx, atCy)
  local roster = DoomDemons.ROSTER[name]
  if not roster then return nil end
  local cx, cy = atCx, atCy
  if not cx then
    cx, cy = randomWalkablePoint(ow, true)
  end
  if not cx then return nil end
  local px, py = worldPos(cx, cy)
  local m = {
    id = nextDemonId, name = name, roster = roster,
    cx = cx, cy = cy, px = px, py = py, facing = randomFacing(),
    hp = scaledSpawnHealth(roster), state = "roam", mapId = ow.map.id,
    -- real A_Chase/P_NewChaseDir state (p_mobj.c:504's own spawn-time
    -- `reactiontime = info->reactiontime`, plus this port's own
    -- `threshold`/`moveDir`/`moveCount`/`justAttacked`/`justHit` --
    -- see the AI-system section above `tickDemon` for what drives each).
    reactionTime = ticsToSeconds(REACTIONTIME_TICS), threshold = 0,
    moveDir = DIR.NODIR, moveCount = 0, justAttacked = false, justHit = false,
  }
  nextDemonId = nextDemonId + 1
  demons[#demons + 1] = m
  return m
end

-- Exported so `lib/DoomTownInvasion.lua` can spawn its own deliberate-
-- event demons through the exact same real init path ambient spawning
-- uses (reactiontime/threshold/moveDir etc all correctly seeded),
-- rather than hand-building a second, driftable copy of this table
-- shape the way the SPAWN ENEMY debug row once did before it was fixed
-- to call this same function (see that row's own header comment).
DoomDemons.spawnDemon = spawnDemon

-- Exported for `lib/DoomTownInvasion.lua`'s own invasion spawning --
-- see `randomWalkablePointNear`'s own header comment for the real bug
-- this fixes ("never saw another demon"). Finds a point near the given
-- center first, then spawns through the SAME real `spawnDemon` above
-- (now accepting an explicit position) rather than a second, separate
-- init path.
--
-- `reachable` -- see `randomWalkablePoint`'s own Phase 26 header
-- comment: an OPTIONAL pre-computed `reachableFromPlayer` set, so
-- `DoomTownInvasion.lua`'s own `beginInvasion` (spawning 5-9 demons in
-- a loop around the SAME fixed player position) can compute it once and
-- pass it to every call instead of each one independently recomputing
-- the same bounded BFS from scratch.
function DoomDemons.spawnDemonNear(ow, name, centerCx, centerCy, radius, reachable)
  local cx, cy = randomWalkablePointNear(ow, centerCx, centerCy, radius or 12, reachable)
  if not cx then return nil end
  return spawnDemon(ow, name, cx, cy)
end

local function ambientSpawnTick(ow, dt)
  spawnTimer = spawnTimer - dt
  if spawnTimer > 0 then return end
  spawnTimer = SPAWN_CHECK_INTERVAL
  if isInteriorMap(ow.map) then return end
  -- FIX 2026-08-08 (user's own explicit instruction, see `isTownMap`'s
  -- own header comment above for the full derivation): ambient demons
  -- no longer spawn on a town map at all, superseding this file's own
  -- earlier "sometimes wonder out to a city" design. A demon spawns and
  -- stays confined to whatever single map it spawned on (`m.mapId` is
  -- set once and never changed -- confirmed by reading `syncEntities`'s
  -- own real per-map teardown/keep logic above), so excluding town maps
  -- at the SPAWN point alone is sufficient to keep them out of every
  -- town outside a deliberate `lib/DoomTownInvasion.lua` event -- no
  -- separate "don't cross into a town while roaming" check is needed.
  if isTownMap(ow.map) then return end
  if ambientDemonCount(ow.map.id) >= currentMaxAmbientDemons() then return end
  spawnDemon(ow, DoomDemons.pickDemonName())
end

-- ------- item drops (`P_KillMobj`, p_inter.c:719-757, the SAME real
-- function `startDeath` below already ports the XDeath/Death split
-- from) -- added 2026-08-08, user request: "make sure enemies can drop
-- items just like they do in the original doom source code." Re-read
-- that function fresh rather than trusting any earlier summary: real
-- vanilla DOOM's own item-drop logic is a short, hand-coded per-monster-
-- type chain, NOT a generic per-monster-type table field (that's a
-- later Boom/MBF/source-port addition, `mobjinfo[type].droppeditem`,
-- absent from this original 1993/1994 source entirely) --
--
--   if (target->type == MT_WOLFSS || target->type == MT_POSSESSED)
--       item = MT_CLIP;
--   else if (target->type == MT_SHOTGUY)
--       item = MT_SHOTGUN;
--   else if (target->type == MT_CHAINGUY)
--       item = MT_CHAINGUN;
--   else
--       return;                    // every OTHER monster: no drop at all
--
-- restated here as a name-keyed table rather than an if/else chain
-- (equivalent shape, more readable against this project's own
-- name-keyed `DoomDemons.ROSTER`). Only two of those four real monster
-- types exist anywhere in this roster (`ZOMBIEMAN` = MT_POSSESSED,
-- `SHOTGUYGUY` = MT_SHOTGUY, both confirmed by their own real sprite
-- prefixes, `POSS`/`SPOS`) -- Wolfenstein SS and the Chaingunner are
-- simply absent from `DoomDemons.ROSTER` entirely (never added in an
-- earlier phase, a real, pre-existing roster gap, not something this
-- round silently drops), so their own drop branches never apply here,
-- a faithful consequence of the real per-type chain rather than an
-- omission of this round's own. Every OTHER demon in this roster (Imp,
-- Demon/Spectre, Cacodemon, Baron, Lost Soul, Spider Mastermind,
-- Cyberdemon) correctly drops nothing, matching that real `else return`
-- default exactly.
--
-- CHANGED 2026-08-08 -- user's own explicit instruction: "the only 2
-- ways the player should be able to get weapons is buy them in
-- pokeshops, or through getting badges" (see `lib/DoomBadgeRewards.
-- lua`). Real DOOM's own `SHOTGUYGUY` drop IS specifically the shotgun
-- weapon itself (`item = MT_SHOTGUN`, above) -- a deliberate deviation
-- from that real behavior, not an oversight, so it's dropped from this
-- table entirely rather than swapped for an invented substitute (e.g.
-- shells) that has no real source backing either. `ZOMBIEMAN`'s own
-- clip drop is unaffected -- ammo, not a weapon, outside this rule.
local DROP_TABLE = {
  ZOMBIEMAN = { name = "CLIP" },
}

-- Real DOOM spawns the drop unconditionally on death (`P_KillMobj`
-- calls this before ever branching on XDeath vs. plain Death a few
-- lines below it, `p_inter.c:700-717` vs. `719-757`) -- at the exact
-- point the monster died (`P_SpawnMobj(target->x, target->y, ...)`),
-- this roster's own live `m.cx`/`m.cy` (derived from `m.px`/`m.py`
-- every tick, see `tickDemon`'s own header comment).
local function dropDeadItem(ow, m)
  local drop = DROP_TABLE[m.name]
  if not drop then return end
  pcall(DoomItems.dropItem, ow, m.cx, m.cy, drop.name, drop)
end

-- ------- death (a player's own weapon hit, via the target-resolver
-- seam below) -- real per-demon XDeath-vs-Death split ported from
-- `P_KillMobj` (p_inter.c:719-725, already cited once in Phase 8's own
-- audit): XDeath only when the demon HAS one (`hasXDeath`) AND the
-- overkill is big enough that health goes more negative than its own
-- max health -- otherwise the plain Death sequence, matching real DOOM
-- exactly rather than the "always gibs" simplification Phase 8 chose
-- for overworld NPCs (which have no real health pool of their own to
-- compare against, unlike a real DOOM demon, which does).
-- Most real death chains hold every one of their own letters for the
-- exact same real tic count, so `frames(letters, tics)` (this file's
-- own shared helper, above) takes ONE flat number applied uniformly --
-- correct for those. Spider Mastermind's own real death chain does NOT
-- (`S_SPID_DIE1..DIE10`, `info.c:757-767`: J=20 tics, K-R=10 each,
-- S=30) -- found during the 2026-08-08 audit of that monster
-- specifically. `frames()` also accepts a per-letter tics ARRAY for
-- exactly this case (`{20,10,10,10,10,10,10,10,10,30}`); this helper
-- reads either shape transparently so every OTHER roster entry's own
-- existing flat-number `die`/`xdie` fields need no change at all.
local function ticsForDeathLetter(tics, index)
  if type(tics) == "table" then return tics[index] or tics[#tics] end
  return tics
end
-- Phase 27 unification audit (2026-08-09): exported so `lib/
-- DoomHordeControl.lua`'s own `dieStatesFor` can call this directly
-- instead of assigning `roster.die.tics` (the WHOLE field) as a flat
-- per-letter value -- a real, confirmed bug for SPIDERMASTERMIND
-- specifically, whose `die.tics` is the per-letter ARRAY this function
-- exists to index into: the un-exported duplicate silently passed the
-- table itself through as `domTics`, which `hordeDeathAdvance` then
-- compared against `0`, a Lua runtime error swallowed by that call's
-- own `pcall` wrapper -- net effect, a Spider Mastermind killed in
-- Horde Mode played its death sound and then simply vanished, no death
-- animation or corpse ever created.
DoomDemons.ticsForDeathLetter = ticsForDeathLetter

-- FEATURE 2026-08-08 -- user request: "killing a demon at all at any
-- point in time should give you in game currency (the exact same
-- currency used to buy in pokeshops) and each monster should give you
-- a different amount based on their difficulty." No DOOM precedent for
-- this at all (vanilla DOOM has no currency) -- this mod's own
-- addition. Real money storage confirmed via source:
-- `Game.save.money`, a plain integer (`gen1recomp-dev/src/core/
-- SaveData.lua`), the SAME field real trainer-battle prize money
-- (`BattleState.lua`'s own `self.game.save.money = ... + prize`) and
-- Pay Day payouts already add to directly -- no separate "add money"
-- function exists anywhere in this engine to call into instead, so
-- this does the same direct add. This mod has no existing demon
-- difficulty-tier system (confirmed: `ROSTER` above has no `tier`/
-- `difficulty` field for any of the 10 demons) -- these are hand-
-- picked values, informed by each demon's own real `spawnHealth` but
-- not mechanically derived from it (a straight formula would give Lost
-- Soul -- genuinely dangerous despite modest HP, real DOOM's own
-- `MF_SKULLFLY` body-charge attack -- an unfairly low reward for how
-- threatening it actually is), same "judgment call, not a derived
-- fact" category as every other undreived number in this project.
local MONEY_REWARD = {
  ZOMBIEMAN = 10, SHOTGUYGUY = 15, IMP = 20, DEMON = 35, SPECTRE = 40,
  LOSTSOUL = 25, CACODEMON = 75, BARONOFHELL = 150,
  SPIDERMASTERMIND = 400, CYBERDEMON = 600,
}

-- FEATURE 2026-08-10 -- user request: "add new setting 'enemy drops'
-- where you can choose money, ammo (will give you ammo in any random
-- gun or money and ammo." Real DOOM has no per-kill drop mechanic of
-- its own (monsters don't drop pickups on death outside a scripted few
-- boss-specific triggers, none of which apply here) -- same "this mod's
-- own addition" category as the currency-per-kill feature this extends,
-- not a DOOM-sourced mechanic. `DoomWeapons.giveAmmo(ammoType, clips)`
-- (already real, exported, Phase 13) is reused directly rather than
-- reimplemented -- one real clip-load of a uniformly-random ammo type,
-- same flat amount regardless of monster difficulty (money already
-- scales by difficulty via `MONEY_REWARD` above; layering a SECOND
-- hand-tuned difficulty curve onto ammo too would be new, unrequested
-- scope for a first version of this setting).
local AMMO_TYPES = { "clip", "shell", "misl", "cell" }
local AMMO_DISPLAY = { clip = "bullets", shell = "shells", misl = "rockets", cell = "cells" }

-- `DoomHud.announceKill`'s own top-left feed (`HU_MSGX,Y = 0,0`,
-- Phase 15/23's own established reuse) -- `demonDisplayName` returns
-- "the X" (built for a sentence like "the Zombieman now spawns," `lib/
-- DoomBadgeRewards.lua`) -- stripped of its leading article here, since
-- the user's own originally-requested phrasing is just the bare name
-- ("Zombieman killed!", not "The Zombieman killed!"). `moneyReward`/
-- `ammoType` are each optional now (one, the other, or both, matching
-- the new ENEMY DROPS setting) -- the message shape adapts to whichever
-- actually happened this kill.
local function announceKillReward(m, moneyReward, ammoType)
  if not (DoomHud and DoomHud.announceKill) then return end
  local name = DoomDemons.demonDisplayName(m.name):gsub("^[Tt]he ", "")
  local parts = {}
  if moneyReward then parts[#parts + 1] = "$" .. moneyReward end
  if ammoType then parts[#parts + 1] = "some " .. (AMMO_DISPLAY[ammoType] or ammoType) end
  if #parts == 0 then return end
  DoomHud.announceKill(name .. " killed! You got " .. table.concat(parts, " and ") .. ".")
end

local function grantKillReward(m)
  local drops = Options.enemyDrops()
  local giveMoney = drops == "money" or drops == "both"
  local giveAmmoDrop = drops == "ammo" or drops == "both"

  local moneyReward
  if giveMoney then
    moneyReward = MONEY_REWARD[m.name]
    if moneyReward then
      local ok, Game = pcall(require, "src.core.Game")
      if ok and Game and Game.save then
        Game.save.money = (Game.save.money or 0) + moneyReward
      else
        moneyReward = nil
      end
    end
  end

  local grantedAmmoType
  if giveAmmoDrop then
    local ammoType = AMMO_TYPES[math.random(#AMMO_TYPES)]
    if DoomWeapons.giveAmmo(ammoType, 1) then
      grantedAmmoType = ammoType
    end
  end

  if moneyReward or grantedAmmoType then
    announceKillReward(m, moneyReward, grantedAmmoType)
  end
end

-- `startDeath` is confirmed the one real choke point every demon kill
-- passes through regardless of weapon or cause (its own two real call
-- sites -- direct hitscan/melee, and AOE/splash -- both only ever run
-- once `m.hp <= 0`), so the kill reward lives here rather than
-- duplicated at each call site.
local function startDeath(ow, m, overkillHealth)
  m.state = "dying"
  grantKillReward(m)
  local roster = m.roster
  local useXDeath = roster.hasXDeath and overkillHealth < -scaledSpawnHealth(roster)
  local seq = useXDeath and roster.xdie or roster.die
  m.deathLetters = seq.letters
  m.deathTics = seq.tics
  m.deathIndex = 1
  m.dyingLetter = seq.letters[1]
  m.deathHold = ticsToFrames(ticsForDeathLetter(seq.tics, 1))
  m.deathFreeze = useXDeath and roster.xdieFreeze or roster.dieFreeze
  m.deathVanishes = (not useXDeath) and roster.dieVanishes
  local ok, snd = pcall(DoomWadImport.loadSound, roster.deathSound)
  if ok and snd then DoomWadImport.playClone(roster.deathSound .. " (" .. m.name .. " death)", snd) end
  dropDeadItem(ow, m)
end

-- FIXED 2026-08-08 -- user report: "skull death animations arent working
-- properly. they dont finish then it disappears." Root cause: the
-- `m.deathVanishes` branch above (Lost Soul's own real `dieVanishes`,
-- set because `S_SKULL_DIE6`'s own real nextstate is `S_NULL` rather
-- than a `-1`-tics freeze the way every OTHER demon's own final death
-- frame is, per that roster field's own header comment) `return`ed
-- immediately, BEFORE the shared per-letter advance logic below it ever
-- ran -- so a Lost Soul's own `m.dyingLetter` stayed pinned at
-- `seq.letters[1]` (real DOOM's own `F`, `S_SKULL_DIE1`) for the entire
-- 6-second hold this branch used instead: the animation never advanced
-- past its own FIRST frame at all, then the whole entity vanished
-- outright once the timer expired -- exactly "doesn't finish, then
-- disappears." Real DOOM (`info.c:731-736`) plays all SIX real death
-- letters (`S_SKULL_DIE1..DIE6`, 6 tics each) in full, THEN -- unlike
-- every other demon here, which freezes forever on its own last real
-- death frame as a corpse -- removes the object immediately
-- (`P_SetMobjState`'s own real `state == S_NULL` branch calls
-- `P_RemoveMobj` on the spot, p_mobj.c). Fixed by running the exact
-- same shared per-letter advance every OTHER demon already uses
-- unconditionally, and only branching on `deathVanishes` at the one
-- real point real DOOM's own state chain actually differs: what
-- happens once the LAST letter's own hold time elapses -- freeze
-- (`m.deathFreeze`) for a normal demon, or an immediate `pokedoomDead`
-- removal (real DOOM's own `S_NULL`) for a Lost Soul.
local function tickDeath(m)
  if m.dyingLetter == m.deathFreeze then return end -- held on the last frame (non-vanishing demons)
  m.deathHold = m.deathHold - 1
  if m.deathHold <= 0 then
    m.deathIndex = m.deathIndex + 1
    if m.deathIndex > #m.deathLetters then
      if m.deathVanishes then
        m.pokedoomDead = true
      else
        m.dyingLetter = m.deathFreeze
      end
    else
      m.dyingLetter = m.deathLetters[m.deathIndex]
      m.deathHold = ticsToFrames(ticsForDeathLetter(m.deathTics, m.deathIndex))
    end
  end
end
-- Phase 27 unification audit, follow-up (2026-08-09) -- direct user
-- request after "every demon uses the soldier death animation" in Horde
-- Mode: "its two completely different codebases... things that couldve
-- just been called instead of remaking." This function has NOTHING
-- ambient-demon-specific in its actual body -- it only ever reads/writes
-- plain state fields (`.dyingLetter`/`.deathFreeze`/`.deathHold`/
-- `.deathIndex`/`.deathLetters`/`.deathTics`/`.deathVanishes`/
-- `.pokedoomDead`) on whatever table it's given. Exported so `lib/
-- DoomHordeControl.lua`'s own Horde-death corpse can be driven by this
-- SAME real, already-proven advance logic directly, instead of
-- `hordeDeathAdvance`'s own separate hand-rolled reimplementation (the
-- most likely real home of the "always shows the wrong monster's death"
-- bug, now deleted outright rather than debugged further -- removing a
-- duplicate closes whatever was wrong with it, known cause or not).
DoomDemons.tickDeath = tickDeath

-- ------- target-resolver / AOE-resolver -- the player's own weapons vs
-- a live demon, restated ray-vs-cylinder geometry (same shape as
-- lib/DoomKill.lua's overworldNpcResolver / lib/DoomHordeTarget.lua's
-- hordeMobResolver -- this project's own established pattern for "test
-- a straight ray against a list of world-space things") against
-- `demons` instead of `ow.npcs`/`HordeMobs.list()`.
local HIT_RADIUS = 10 -- wider than an NPC's (6) -- the FLOOR every
                       -- demon's own hit cylinder now widens up FROM
                       -- (below), not a flat value applied to all of them

-- FIXED 2026-08-07 -- user report: "this cacodemon took 58 shots...
-- and spent the rest of the 142 shots shooting a spider mastermind and
-- didnt kill them at all, and seemed like i didnt hit them much
-- either." The Cacodemon count (58 vs. ~40 expected at a perfect hit
-- rate for its real 400 HP against the chaingun's own ~10 avg damage,
-- p_pspr.c A_FireCGun -> P_GunShot) is within normal variance -- not a
-- bug. The Spider Mastermind failing to die from 84 shots is ALSO not
-- a bug on its own (3000 real HP needs ~300 hits at 100% accuracy,
-- math no weapon-side fix changes) -- but "seemed like i didnt hit
-- them much" pointed at something real: this resolver's own hit
-- cylinder, right above, was a genuinely FLAT constant for every demon
-- regardless of type -- the comment that used to sit here already
-- named the exact problem ("Spider Mastermind's radius is 128") but
-- the fix applied at the time only bumped the flat value from 6 to 10,
-- never actually reading each monster's own real roster `radius` field
-- to scale it. A Spider Mastermind's true DOOM collision radius (128
-- map units, `info.c` `mobjinfo[MT_SPIDER].radius`, restated in this
-- file's own roster table already) is more than 12x a regular demon's
-- (20) -- rendering proportionally huge on screen in this mod too
-- (its own true WAD sprite aspect ratio, shared-Zombieman-ratio
-- scaled) -- yet was being hit-tested with the SAME roughly
-- person-sized cylinder as a Lost Soul (16). Any horizontal miss
-- (chaingun's own real random spread on refire shots, `P_GunShot`'s
-- `(random-random)<<18`, `weapons.md`) that would have clearly still
-- landed on the Spider Mastermind's own real, much wider body sailed
-- past this resolver's own undersized fixed cylinder instead. Fixed by
-- reading each demon's own `m.roster.radius` and using whichever is
-- LARGER between it and the existing flat floor -- small demons keep
-- their already-working behavior unchanged; a Spider Mastermind
-- (128)/Cyberdemon (40) become dramatically easier to actually land a
-- shot on, matching their real, much bigger DOOM hitbox.
local function hitRadiusFor(m)
  return math.max(HIT_RADIUS, m.roster.radius or HIT_RADIUS)
end

-- FIX 2026-08-10 -- user report + screenshot: firing a plasma rifle
-- point-blank at a Cyberdemon showed the impact explosion rendering
-- BEHIND the demon's own model, "for most enemies and npcs," and the
-- same for blood. Root cause, confirmed by tracing the actual formula:
-- `t = ((mx-ox)*dx+(mz-oz)*dz)/flat` (used both to pick the closest
-- candidate along the ray AND, until now, directly as the blood-spawn
-- position) is the ray's closest-approach-to-CENTER parameter, not
-- where the ray actually crosses the target's own hit-cylinder surface
-- -- geometrically correct for picking "which target is nearest," but
-- for anything with real radius (a Cyberdemon's real 40, `hitRadiusFor`
-- above), especially at close range, the closest-approach-to-center
-- point can sit well past the near-facing surface, deep inside or
-- through the model -- exactly matching "renders behind them."
--
-- This solves the real ray-vs-circle intersection (`|O + tD - C|^2 =
-- r^2`, expanded to a quadratic in `t`) for the SMALLER positive root
-- -- the point where the ray actually ENTERS the hit-cylinder, i.e. the
-- true near-facing surface -- and is used only for where an effect
-- SPAWNS, never for target selection (the existing closest-approach
-- `t` above stays exactly as-is for that, since comparing relative
-- distances between multiple candidates is a different, still-correct
-- use of the same projection). Falls back to the closest-approach point
-- itself if the discriminant is somehow negative (shouldn't happen once
-- the caller has already confirmed a hit via that same closest-approach
-- test, but real floating-point rounding at a near-tangent graze is
-- worth guarding rather than crashing on a `math.sqrt` of a negative
-- number).
local function nearEntryT(ox, oz, dx, dz, flat, mx, mz, rad, fallbackT)
  local ex, ez = ox - mx, oz - mz
  local halfB = dx * ex + dz * ez
  local c = ex * ex + ez * ez - rad * rad
  local disc = halfB * halfB - flat * c
  if disc < 0 then return fallbackT end
  return (-halfB - math.sqrt(disc)) / flat
end

-- P_DamageMobj's own real retarget rule (p_inter.c:904-915, already
-- cited in this project's own references/damage-and-death.md): on ANY
-- non-lethal hit, `if (!target->threshold ...) { target->target =
-- source; target->threshold = BASETHRESHOLD; if (spawnstate) ->
-- seestate }`. Two genuinely separate real effects share this one gate,
-- and this file's own `tickDemon` header comment (above) used to
-- conflate them: (1) INFIGHTING -- a demon already committed to one
-- target retargets onto a DIFFERENT attacker once its threshold has
-- decayed to 0 -- genuinely needs a second damage source, correctly
-- absent in this mod (only the player damages demons). (2)
-- ACQUISITION -- a demon with NO target at all (threshold also reads 0
-- for it, since it starts there and never left) retargets onto
-- WHOEVER just hit it, immediately -- needs no second source, and is
-- the actual mechanism behind "a passive DOOM monster snaps awake and
-- retaliates the instant it's shot." This mod's own hit resolvers
-- never implemented either half -- a demon shot while roaming (no
-- target) or while chasing something else with an expired threshold
-- just kept doing whatever it was doing, only playing a pain
-- sound/stagger. Fixed here, called from both `demonResolver` (direct
-- hit) and `demonAoeResolver` (splash) on any non-lethal connecting
-- hit, matching real DOOM applying this on every hit, not just misses.
local function retargetOntoAttacker(ow, m)
  if not (ow and ow.player) then return end
  if (m.threshold or 0) > 0 then return end
  if m.target == ow.player then return end -- already on the player, nothing to change
  DoomLog.event("DEMON", "%s (id=%s) retargeted onto player (was %s) via retargetOntoAttacker",
    m.name, tostring(m.id), m.target and "chasing something else" or "no target")
  if m.target then m.target.pokedoomBeingHunted = nil end
  m.target = ow.player
  ow.player.pokedoomBeingHunted = true
  m.threshold = ticsToSeconds(BASETHRESHOLD_TICS)
  -- "if (target->state == &states[target->info->spawnstate]) ->
  -- seestate": this mod has no true spawnstate distinct from "roam"
  -- (every non-chasing, non-dying demon IS roam -- see `findTarget`'s
  -- own header comment) -- the real equivalent here is simply making
  -- sure a roaming demon actually switches into chase.
  if m.state == "roam" then
    m.state = "chase"
    m.roamWaypoint = nil
    pcall(playSeeSound, m)
  end
end

-- FIXED 2026-08-07 -- found while adding diagnostic logging for the
-- user's own separate "still missing demons" report, not itself the
-- reported symptom but a real, confirmed, compounding bug: the vertical
-- hit-acceptance band below used to run from `gh - 2` up to only `gh +
-- m.roster.height/4 + 10` -- the TOP QUARTER of a demon's own height
-- plus a small buffer. But `computeAutoAimPitch` (above, this same
-- file's own real auto-aim target) aims at each candidate's CENTER-MASS
-- (`gh + height/2`), not its lower quarter. For every demon in this
-- roster except the very shortest, `height/2` sits ABOVE `height/4+10`
-- -- e.g. a Zombieman (height 56): aim point 28, old band top only 24,
-- a 4-unit gap; Spider Mastermind (height 100): aim point 50, old band
-- top 35, a 15-unit gap. A shot correctly auto-aimed at a demon's own
-- real center would sail just above this resolver's own acceptance
-- window and register as a clean miss regardless. Widened to comfortably
-- contain the real aim point (`height/2`) with the same `+10` buffer.
-- FIX 2026-08-09 -- Phase 26 lag audit: `demonResolver` used to log
-- unconditionally on EVERY weapon-fire resolution, hit or miss -- the
-- one place in this whole file's own diagnostic logging that never got
-- the same real-time throttle every other AI-decision log here already
-- uses (`checkMissileRangeReal`'s own gate log, `maybePlayActiveSound`,
-- etc). Since this runs on the player's own trigger-pull hot path (once
-- per pellet -- a shotgun blast is 7 calls in one trigger pull -- and
-- continuously during chaingun automatic fire), the miss branch
-- especially could log many times per real second. A plain module-local
-- real-time gate, not a per-demon one (this resolver has no single
-- demon to attach a per-instance accumulator to when it's the MISS
-- branch firing) -- a counter, not a transplanted formula, matching
-- CLAUDE.md's own "avoid math-derived code" preference.
local HIT_LOG_INTERVAL = 0.5 -- real seconds
local lastHitLogTime = 0
local function logHitEvent(...)
  local now = love.timer and love.timer.getTime() or 0
  if now - lastHitLogTime < HIT_LOG_INTERVAL then return end
  lastHitLogTime = now
  DoomLog.event(...)
end

-- Real pain-chance roll + consequences (`P_DamageMobj`'s own pain-state
-- interrupt, p_inter.c:645-660) -- extracted 2026-08-09 (Phase 27
-- unification audit, Finding A4 -- direct user follow-up after the
-- Horde death-animation bug: "its two completely different codebases...
-- things that couldve just been called instead of remaking") from what
-- had been TWO independent hand-rolled copies in THIS file alone
-- (`demonResolver`'s own direct-hit path, `applyAoeDamageToDemon`'s
-- shared splash/spray path) plus a THIRD, structurally different
-- reimplementation in `lib/DoomHordeControl.lua`'s own `tickMobAnimation`
-- (which had no real hit-time signal to trigger from at all, and
-- resorted to polling `entry.hp` frame-to-frame to infer "a hit must
-- have just landed"). Operates on any table shaped like an ambient
-- demon `m` (`.roster`, `.name`, `.staggerTimer`, `.spidBursting`,
-- `.justHit`) -- exported so `lib/DoomHordeTarget.lua`'s own
-- `hordeMobResolver` can call this directly at the real moment a Horde
-- mob is hit, eliminating that HP-polling guess entirely rather than
-- just deduplicating its math.
local function rollPain(m, soundSuffix)
  if math.random(0, 255) >= m.roster.painChance then return false end
  local ok, snd = pcall(DoomWadImport.loadSound, m.roster.painSound)
  if ok and snd then
    DoomWadImport.playClone(
      m.roster.painSound .. " (" .. tostring(m.name) .. " pain" ..
      (soundSuffix and (", " .. soundSuffix) or "") .. ")", snd)
  end
  -- Phase 22, Round 4: the real pain-state interrupt, not just its
  -- sound (see `tickDemon`'s own header comment on `staggerTimer`).
  m.staggerTimer = PAIN_STAGGER_DURATION
  -- 2026-08-08 -- real DOOM's own PAIN state always exits BACK to
  -- `seestate`/RUN1, never resumes mid-ATK-chain (`S_SPID_PAIN2`'s own
  -- real `nextstate` is `S_SPID_RUN1`, not back into the attack loop,
  -- `info.c:756`) -- so a hit mid-burst genuinely stops firing and has
  -- to pass a fresh `P_CheckMissileRange` roll to start again. Harmless
  -- (just always `false`) for anything that never sets it, like a
  -- Horde-mob `anim` table.
  m.spidBursting = false
  -- MF_JUSTHIT (p_inter.c:635-637): set on a successful pain roll --
  -- `checkMissileRangeReal`'s own first check -- fires back immediately
  -- next chance, bypassing reactiontime/the hold-fire roll entirely.
  -- Also harmless for a Horde mob, which has no real reactiontime/
  -- missile-range gate of its own to read this field.
  m.justHit = true
  return true
end
DoomDemons.rollPain = rollPain

local function demonResolver(ow, r, maxT, damage, weaponName)
  local ox, oy, oz, dx, dy, dz = r[1], r[2], r[3], r[4], r[5], r[6]
  local flat = dx * dx + dz * dz
  if flat < 1e-6 then return nil end
  local best, bestT, bestM
  for _, m in ipairs(demons) do
    if m.mapId == ow.map.id and m.state ~= "dying" then
      local mx, mz = m.px + 8, m.py + 8
      local t = ((mx - ox) * dx + (mz - oz) * dz) / flat
      if t > 0 and t < maxT and (not bestT or t < bestT) then
        local hx, hz = ox + dx * t - mx, oz + dz * t - mz
        local rad = hitRadiusFor(m)
        if hx * hx + hz * hz <= rad * rad then
          local gh = groundY(ow, m.cx, m.cy)
          local y = oy + dy * t
          -- FIX (parallel-implementation audit): this band used to read
          -- `gh + m.roster.height / 2 + 10`, DOOM's own raw, never-
          -- converted `mobjinfo.height` stat -- the exact same wrong
          -- basis `aimTargets`/`fireDemonProjectile` were independently
          -- found and fixed to use `DEMON_WORLD_HEIGHT` instead (see
          -- those functions' own header comments), since every demon
          -- here actually renders at that one shared calibrated height
          -- regardless of its own real DOOM height stat. This resolver's
          -- own band was never carried over to match, so a shot aimed
          -- well above a tall demon's true rendered top edge (up to
          -- `gh+65` for a Cyberdemon, vs. its real rendered top at
          -- `gh+16`) still registered as a hit.
          if y >= gh - 2 and y <= gh + DEMON_WORLD_HEIGHT / 2 + 10 then
            best, bestT, bestM = m, t, m
          end
        end
      end
    end
  end
  if not bestM then
    local liveOnMap = 0
    for _, m in ipairs(demons) do
      if m.mapId == ow.map.id and m.state ~= "dying" then liveOnMap = liveOnMap + 1 end
    end
    logHitEvent("HIT", "demonResolver: [%s] no demon hit (%d live demon(s) on this map)",
      tostring(weaponName or "?"), liveOnMap)
    return nil
  end
  logHitEvent("HIT", "demonResolver: [%s] hit %s (id=%s) for %s dmg, hp now %s",
    tostring(weaponName or "?"), bestM.name, tostring(bestM.id), tostring(damage), tostring(bestM.hp - (damage or 1)))
  local hitT = nearEntryT(ox, oz, dx, dz, flat, bestM.px + 8, bestM.py + 8, hitRadiusFor(bestM), bestT)
  -- FIX 2026-08-11 -- same real gap as every other hit-resolver's own
  -- matching fix this round (`lib/DoomPuff.lua`'s header comment has the
  -- full render-contract derivation) -- the ray's own real termination
  -- height was available and never passed through.
  pcall(DoomBlood.spawn, ow, ox + dx * hitT, oz + dz * hitT, damage, oy + dy * hitT)
  bestM.hp = bestM.hp - (damage or 1)
  -- P_DamageMobj (p_inter.c:641-644): `reactiontime = 0` on EVERY hit
  -- that connects, pain or not -- "if attacked, react immediately"
  -- (a demon can't hold its `reactiontime` grace period against
  -- something that's already shooting back at it).
  bestM.reactionTime = 0
  if bestM.hp > 0 then
    retargetOntoAttacker(ow, bestM)
    rollPain(bestM)
  else
    startDeath(ow, bestM, bestM.hp)
  end
  -- Second return value, new 2026-08-10: the corrected near-surface `t`
  -- (see `nearEntryT`'s own header comment above) -- `lib/DoomWeapons.
  -- lua`'s own `updateProjectiles` uses this, when present, to correct
  -- a projectile's own explosion SPRITE position the exact same way,
  -- instead of exploding wherever the projectile's raw per-tick step
  -- happened to leave it (which can be well past a wide-radius target's
  -- near surface at close range) -- existing callers that only read the
  -- first return value are unaffected.
  return best, hitT
end

-- Real line-of-sight between two world points, restated from
-- `lib/DoomHordeTarget.lua`'s own `losClear` (itself restated from
-- `lib/DoomWeapons.lua`'s own private `terrainRange`, not an exported
-- seam) -- this project's own established "restate small pure-shape
-- pieces per file" precedent. DOOM's real `P_CheckSight` (`PIT_
-- RadiusAttack`'s own real gate, p_map.c:1191) has no BSP here to port;
-- "does a straight ray from A to B ever dip below local ground height"
-- is this engine's own established stand-in, the same reasoning `lib/
-- DoomKill.lua`'s own `occludedFromCamera` already uses for gib
-- visibility.
local function losClear(ow, ox, oy, oz, tx, ty, tz)
  local dx, dy, dz = tx - ox, ty - oy, tz - oz
  local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dist < 1e-6 then return true end
  dx, dy, dz = dx / dist, dy / dist, dz / dist
  local step = 3
  local t = step
  while t < dist do
    local x, y, z = ox + dx * t, oy + dy * t, oz + dz * t
    local cx, cy = math.floor(x / 16), math.floor(z / 16)
    if not ow.map:inBounds(cx, cy) then return false end
    local gh = groundY(ow, cx, cy)
    if y < gh - 0.5 or y < 0 then return false end
    t = t + step
  end
  return true
end

-- Shared "a splash/spray hit connected" consequence -- death or pain
-- roll, retarget, stagger -- factored out of the old `radius`-only body
-- below so the new `spray` branch (added this round) gets the exact
-- same real behavior `demonResolver`'s own direct-hit path already has,
-- without a second hand-copied version silently drifting from it.
local function applyAoeDamageToDemon(ow, m, damage, soundSuffix)
  if damage <= 0 then return end
  -- FIX 2026-08-09 -- Phase 27 unification audit, Finding B2:
  -- `P_SpawnBlood` (p_mobj.c:836-859) fires on every landed hit in real
  -- DOOM, splash/spray included -- `demonResolver`'s own DIRECT-hit path
  -- already spawns blood; this shared AOE-consequence function never
  -- did, so a rocket splash-kill or BFG-spray-kill on a demon showed no
  -- blood at all while a direct hit on the identical demon did.
  -- FIX 2026-08-11 -- same real gap as every other hit-resolver's own
  -- matching fix this round (`lib/DoomPuff.lua`'s header comment has the
  -- full render-contract derivation) -- a splash/spray hit has no single
  -- ray to pull a termination height from, so it uses this demon's own
  -- real, already-shared render center-mass instead (`DEMON_WORLD_
  -- HEIGHT/2`, the exact same point `aimTargets`/`demonResolver` already
  -- treat as this demon's own center).
  pcall(DoomBlood.spawn, ow, m.px + 8, m.py + 8, damage, groundY(ow, m.cx, m.cy) + DEMON_WORLD_HEIGHT / 2)
  m.hp = m.hp - damage
  -- P_DamageMobj (p_inter.c:641-644) -- unconditional on any connecting
  -- hit, splash/spray included -- see `demonResolver`'s own matching
  -- comment.
  m.reactionTime = 0
  if m.hp <= 0 then
    startDeath(ow, m, m.hp)
  else
    retargetOntoAttacker(ow, m)
    rollPain(m, soundSuffix)
  end
end

-- FEATURE 2026-08-10 -- direct user request: "find out which demons
-- shoot projectiles and implement all projectiles as closely as
-- possible with the real doom." The real `P_RadiusAttack`/
-- `PIT_RadiusAttack` (`p_map.c:1164-1233`, read fresh) `A_Explode`
-- fires when a `MT_ROCKET` dies -- the Cyberdemon's own reused rocket
-- is the ONLY demon projectile that gets one (confirmed: the three
-- fireball types' own deathstates have no action at all). Real,
-- confirmed behavior ported here, not assumed:
--   - EVERY real `MF_SHOOTABLE` thing within radius takes damage,
--     including OTHER monsters (`PIT_RadiusAttack` has no species
--     check at all, unlike the direct-hit `PIT_CheckThing` -- real
--     DOOM splash damage is genuine monster-vs-monster "infighting"),
--     with the one explicit exception below.
--   - `MT_CYBORG`/`MT_SPIDER` (Cyberdemon/Spider Mastermind) are always
--     EXEMPT from splash/concussion damage ("Boss spider and cyborg
--     take no damage from concussion", `p_map.c:1172-1177`) -- the
--     exact same real exemption `demonAoeResolver`'s own `radius`
--     branch below already ports for the PLAYER's rocket, restated
--     here for a DEMON's own rocket.
--   - Linear falloff by distance, gated on real line-of-sight
--     (`P_CheckSight`) -- restated via this file's own `losClear`.
--   - Radius 32 world px / max damage 128 -- the exact same real
--     128-DOOM-unit `A_Explode` radius and the exact same proportional
--     conversion `lib/DoomWeapons.lua`'s own `ROCKET_SPLASH_RADIUS`
--     already established for the player's IDENTICAL `MT_ROCKET` type
--     -- restated rather than a fresh number, since it's literally the
--     same real projectile.
-- NPCs have no partial HP pool in this mod (this file's own established
-- "every landed hit is a kill" design for `ow.npcs`, same as the direct-
-- hit citizen-kill branch in `updateDemonProjectiles` above) -- any
-- connecting splash within range/LOS is a straight kill via the same
-- `DoomKill.killNpc` path, not a damage roll.
local SPLASH_RADIUS = 32      -- 128 DOOM map units, same conversion as lib/DoomWeapons.lua's ROCKET_SPLASH_RADIUS
local SPLASH_MAX_DAMAGE = 128 -- DOOM's own real number, no conversion needed

demonProjectileSplash = function(ow, x, y, z, owner)
  if not (ow and ow.map) then return end

  -- Player -- never boss-exempt (that exemption is a specific real
  -- monster-type check, not something that applies to the player).
  if ow.player and DoomHealth.isAlive() then
    local px, pz = npcCenter(ow.player)
    if px then
      local dx, dz = px - x, pz - z
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist <= SPLASH_RADIUS then
        local damage = math.floor(SPLASH_MAX_DAMAGE * (1 - dist / SPLASH_RADIUS))
        local gh = groundY(ow, ow.player.cellX, ow.player.cellY)
        if damage > 0 and losClear(ow, x, y, z, px, gh, pz) then
          -- FIX (DIFFICULTY_SCALE audit): every OTHER demon-damage-to-
          -- player path in this file (`rollDemonDamage`, and the direct-
          -- hit projectile impact roll in `updateDemonProjectiles`)
          -- applies `difficultyScale().damage` -- this Cyberdemon-rocket
          -- splash path never did, so EASY/HARD/NIGHTMARE never actually
          -- changed how much a rocket splash hurt the player, unlike
          -- every other demon attack. Scaled the same way, floored, with
          -- the same real minimum of 1 `rollDemonDamage` already uses.
          local scaledDamage = math.max(1, math.floor(damage * difficultyScale().damage))
          pcall(DoomHealth.damage, scaledDamage, { source = "demon", attacker = owner })
        end
      end
    end
  end

  -- Other demons -- real infighting via splash, same boss exemption as
  -- the player-rocket-vs-demons `radius` branch below.
  for _, m in ipairs(demons) do
    if m ~= owner and m.mapId == ow.map.id and m.state ~= "dying" and not m.roster.boss then
      local mx, mz = m.px + 8, m.py + 8
      local dx, dz = mx - x, mz - z
      local dist = math.sqrt(dx * dx + dz * dz)
      if dist <= SPLASH_RADIUS then
        local damage = math.floor(SPLASH_MAX_DAMAGE * (1 - dist / SPLASH_RADIUS))
        if damage > 0 and losClear(ow, x, y, z, mx, groundY(ow, m.cx, m.cy), mz) then
          applyAoeDamageToDemon(ow, m, damage, "splash")
        end
      end
    end
  end

  -- Citizens/NPCs -- iterated backward since a kill removes the NPC
  -- from `ow.npcs` mid-loop (the same real reason `lib/DoomKill.lua`'s
  -- own AOE resolver already iterates its own NPC list backward).
  if ow.npcs then
    for i = #ow.npcs, 1, -1 do
      local npc = ow.npcs[i]
      if npc ~= ow.player then
        local nx, nz = npcCenter(npc)
        if nx then
          local dx, dz = nx - x, nz - z
          local dist = math.sqrt(dx * dx + dz * dz)
          if dist <= SPLASH_RADIUS
             and losClear(ow, x, y, z, nx, groundY(ow, npc.cellX, npc.cellY), nz) then
            npc.pokedoomBeingHunted = nil
            pcall(DoomKill.killNpc, ow, npc)
          end
        end
      end
    end
  end
end

-- FIXED 2026-08-08 -- direct user request: "audit doom source code...
-- make sure per weapon damage for every enemy is feature parity with
-- doom." Re-read `A_BFGSpray` fresh (`p_pspr.c:781-811`) rather than
-- trusting this function's own old header comment, which claimed BFG
-- spray was "already covered via demonResolver's own per-ray call" --
-- false: `demonResolver` is the DIRECT-hit ray-vs-cylinder resolver for
-- the player's own straight-line shots (pistol/shotgun/plasma/rocket
-- travel, etc.); nothing anywhere ever actually fanned out BFG's real
-- 40 rays against `demons` at all. `lib/DoomWeapons.lua`'s own
-- `explodeProjectile` DOES emit a real `kind = "spray"` AOE event on a
-- BFG detonation, and `lib/DoomHordeTarget.lua`'s own `hordeAoeResolver`
-- DOES handle it in full (40-ray fan, real 15d8 damage per connecting
-- ray) -- but ONLY for Horde Mode's own spawned mobs, since that's the
-- only file that ever implemented it. This function's own early `if
-- event.kind ~= "radius" then return end` silently dropped the spray
-- event for every ambient demon, every single time -- the BFG, real
-- DOOM's own signature "clears a room" weapon, has been doing NOTHING
-- to PKDOOM MODE's actual primary enemy type (ambient demons) this
-- whole time. Ported the missing spray branch below, restated from
-- `hordeAoeResolver`'s own already-correct implementation against
-- `demons` instead of `HordeMobs.list()`.
--
-- Also added a real line-of-sight gate to the EXISTING `radius` branch
-- (rocket splash), which never had one: real `PIT_RadiusAttack` only
-- damages a target `if (P_CheckSight(thing, bombspot))`
-- (`p_map.c:1191`) -- a rocket exploding on the other side of a wall
-- should not splash-damage a demon standing behind it, but this
-- resolver used to apply falloff damage purely by straight-line
-- distance, with no solid-geometry check at all.
--
-- One real, confirmed asymmetry ported deliberately, not overlooked:
-- `A_BFGSpray` calls `P_DamageMobj` directly, never going through
-- `P_RadiusAttack`/`PIT_RadiusAttack` at all -- so the Spider
-- Mastermind/Cyberdemon "no splash damage" boss exemption
-- (`PIT_RadiusAttack`'s own real `MT_CYBORG`/`MT_SPIDER` check,
-- `p_map.c:1175-1177`, already ported to this function's own `radius`
-- branch) genuinely does NOT apply to BFG spray in real DOOM -- a boss
-- CAN be hit by BFG rays. The `spray` branch below intentionally has no
-- `not m.roster.boss` guard, matching that real difference exactly.
local function demonAoeResolver(ow, event)
  if event.kind == "radius" then
    for _, m in ipairs(demons) do
      -- Phase 22, Round 4: `boss` (Spider Mastermind, Cyberdemon), made
      -- real -- real DOOM's own `PIT_RadiusAttack` (`p_map.c:1175-1177`,
      -- audited in this phase's own doc) explicitly exempts `MT_CYBORG`/
      -- `MT_SPIDER` from ANY splash/radius damage -- direct hits only
      -- (`demonResolver`, unaffected, still lands normally on a boss).
      -- There is no real `MF_BOSS` flag anywhere in linuxdoom-1.10 (also
      -- confirmed in that same audit) -- this roster's own `boss = true`
      -- field is this project's own restatement of the same real, if
      -- ad-hoc, `actor->type` check.
      if m.mapId == ow.map.id and m.state ~= "dying" and not m.roster.boss then
        local mx, mz = m.px + 8, m.py + 8
        local dx, dz = mx - event.x, mz - event.z
        local dist = math.sqrt(dx * dx + dz * dz)
        if dist <= event.radius then
          local damage = math.floor(event.maxDamage * (1 - dist / event.radius))
          if damage > 0 and losClear(ow, event.x, event.y, event.z, mx, groundY(ow, m.cx, m.cy), mz) then
            applyAoeDamageToDemon(ow, m, damage, "splash")
          end
        end
      end
    end
  elseif event.kind == "spray" then
    -- Real `A_BFGSpray`: 40 independently aimed rays fanned across a
    -- real 90-degree arc (`event.arc`/`event.rays`, set by `lib/
    -- DoomWeapons.lua`'s own `explodeProjectile`), each ray's own real
    -- `P_AimLineAttack` finding the CLOSEST thing directly along THAT
    -- ray's specific direction (not a radius sweep) -- restated here as
    -- the same ray-vs-cylinder closest-hit search `demonResolver` above
    -- already uses for a single ray, run once per fan angle.
    for i = 0, event.rays - 1 do
      local angle = event.facing - event.arc / 2 + (event.arc / event.rays) * i
      local dx, dz = math.sin(angle), math.cos(angle)
      local flat = dx * dx + dz * dz
      if flat > 1e-6 then
        local maxDist = 320 -- world px -- generous enough for this engine's own map scale, matching DoomHordeTarget's own identical constant
        local bestT, bestM
        for _, m in ipairs(demons) do
          if m.mapId == ow.map.id and m.state ~= "dying" then
            local mx, mz = m.px + 8, m.py + 8
            local t = ((mx - event.x) * dx + (mz - event.z) * dz) / flat
            if t > 0 and t <= maxDist and (not bestT or t < bestT) then
              local hx, hz = event.x + dx * t - mx, event.z + dz * t - mz
              local rad = hitRadiusFor(m)
              if hx * hx + hz * hz <= rad * rad then
                local gh = groundY(ow, m.cx, m.cy)
                -- The fan ray is horizontal (`dy = 0`, matching real
                -- `A_BFGSpray`'s own `P_AimLineAttack` call, which fires
                -- along the shooter's own flat facing angle with no
                -- vertical component) -- height along it never changes
                -- with `t`, so the ray's own Y is just `event.y` itself.
                local y = event.y
                -- FIX (parallel-implementation audit): same stale
                -- `m.roster.height` basis as `demonResolver`'s own
                -- vertical band above -- see that resolver's own header
                -- comment for the full derivation; kept consistent here
                -- with the shared `DEMON_WORLD_HEIGHT` render height.
                if y >= gh - 2 and y <= gh + DEMON_WORLD_HEIGHT / 2 + 10 then
                  bestT, bestM = t, m
                end
              end
            end
          end
        end
        if bestM then
          local mx, mz = bestM.px + 8, bestM.py + 8
          if losClear(ow, event.x, event.y, event.z, mx, groundY(ow, bestM.cx, bestM.cy), mz) then
            local damage = 0
            for _ = 1, event.diceCount do damage = damage + math.random(1, event.diceSides) end
            applyAoeDamageToDemon(ow, bestM, damage, "spray")
          end
        end
      end
    end
  end
end

-- ------- per-frame sync
-- FIX 2026-08-09 -- Phase 26 lag audit: the insertion check below used
-- to re-scan all of `ow.entities` every tick, for every live demon on
-- the current map, just to check "am I already inserted" -- confirmed
-- independently by two audit passes as the same O(demons × entities)
-- waste pattern shipped six times project-wide (see `lib/DoomKill.lua`'s
-- own `syncGibEntities` for the full derivation). Real `m.inserted`
-- flag instead, invalidated whenever the CURRENT map changes (the one
-- real case `ow.entities` gets rebuilt out from under a cached flag) --
-- demons on a DIFFERENT map already get their entity torn down via
-- `removeDemonEntity` regardless, so this only needs to track the one
-- map that's actually live.
local lastDemonEntitiesMapId = nil
local function syncDemons(ow)
  if not (ow and ow.map and ow.entities) then return end
  if ow.map.id ~= lastDemonEntitiesMapId then
    for _, m in ipairs(demons) do m.inserted = false end
    lastDemonEntitiesMapId = ow.map.id
  end
  for i = #demons, 1, -1 do
    local m = demons[i]
    if m.mapId ~= ow.map.id then
      -- Not the current map -- same "engine-owned arrays get rebuilt on
      -- every transition" reasoning `lib/DoomKill.lua`'s own gib sync
      -- already established (BUGS.md's own Bug 5 precedent): tear the
      -- entity down if it's stale, but keep the demon's own state
      -- alive for whenever the player returns to that map.
      removeDemonEntity(ow, m)
    else
      if m.pokedoomDead then
        if m.target then m.target.pokedoomBeingHunted = nil end
        removeDemonEntity(ow, m)
        table.remove(demons, i)
      else
        m.entity = m.entity or makeDemonEntity(m)
        -- FIXED 2026-08-06 -- user report + screenshot: demons floating
        -- up into the sky as they moved, looking like they roam in 3D
        -- on a game that's a 2D grid. Root cause: `makeDemonEntity(m)`
        -- snapshots `px`/`py`/`cellX`/`cellY` onto the entity table ONCE,
        -- at creation -- never again. `VoxelScene.lua`'s own `posesOf`
        -- (its real lines 519-527) reads the entity's OWN `.py`/`.cellX`/
        -- `.cellY` directly for the DRAW position's depth coordinate and
        -- the ground-height lookup (`gh = groundAt(state.map, e.cellX,
        -- e.cellY)`), and computes `lift = e.py - vy` against `vy` (the
        -- LIVE current `m.py`, freshly read every `pose()` call) -- so as
        -- a demon walked away from its own spawn point, `e.py` stayed
        -- frozen at the OLD value while `vy` kept advancing, and that
        -- growing difference became a bogus vertical LIFT, plus the
        -- ground-height lookup itself stayed pinned to the spawn cell's
        -- own elevation. A real NPC never hits this because its own
        -- `.py`/`.cellX`/`.cellY` ARE its live movement fields, updated
        -- in place by its own real move code -- this entity is a plain
        -- one-shot table this file built itself, with no such live
        -- link. Fixed by re-syncing it from `m`'s own live state every
        -- tick, right here, so `e.py` never lags behind `vy` at all
        -- (demons have no hop/arc animation of their own, so `lift`
        -- should always land on exactly 0).
        m.entity.px, m.entity.py = m.px, m.py
        m.entity.cellX, m.entity.cellY = m.cx, m.cy
        if not m.inserted then
          table.insert(ow.entities, m.entity)
          m.inserted = true
        end
      end
    end
  end
end

-- ------- spawn-test menu support (Phase 21's own original ask: "i want
-- a menu in the settings menu to spawn the enemies in game to test")
--
-- COMBINED INTO ONE ROW 2026-08-10, direct user request: "test enemy and
-- spawn enemy should be combined into one button, where you choose the
-- weapon [demon] by clicking right or left and click a to spawn."
--
-- This used to be TWO rows, deliberately, for a real reason: the actual
-- row-input contract (`gen1recomp-dev/src/ui/OptionsMenu.lua:526-538`,
-- re-read fresh for this change) gives a row EITHER `.activate(game)`
-- (A only) OR `.step(game, dir)` (left/right AND A all route through
-- `step` -- pressing A computes `dir = input:wasPressed("left") and -1
-- or 1`, i.e. `dir=1`, IDENTICAL to pressing right, with the dispatcher
-- itself passing no other signal). A row carrying BOTH fields is worse,
-- not better: the dispatcher's own real `if row.activate then ... elseif
-- row.step then ...` order means `.activate` wins outright and `.step`
-- never runs AT ALL for that row, even on a genuine left/right press --
-- so simply attaching both isn't a valid way to get "cycle on L/R, do
-- something else on A" from one row either.
--
-- The real fix: a `.step`-only row whose own `step` function reads the
-- SAME real input state the dispatcher itself already consulted this
-- exact frame (`game.input:wasPressed("a")`), rather than trusting the
-- ambiguous `dir` parameter alone. Confirmed SAFE to re-read, not a
-- guess: `Input:wasPressed(btn)` (`gen1recomp-dev/src/core/Input.lua:
-- 382-384`) is a pure read of `self.pressed[btn]`, a table rebuilt once
-- per fixed step (`Input:step()`) and never mutated again until the
-- NEXT step -- every caller within the same tick sees the identical
-- value, confirmed by the dispatcher's OWN code already calling
-- `wasPressed("a")` more than once in the same `:update()` pass. So this
-- row's own `step` can genuinely tell "this call happened because A was
-- pressed" apart from "this call happened because left/right was
-- pressed," and branch to spawn instead of cycling.
local spawnCursor = 1

local function spawnPickedDemon(ow)
  local name = DoomDemons.NAMES[spawnCursor]
  local roster = DoomDemons.ROSTER[name]
  if not roster then return end
  local cx = ow.player.cellX + (ow.player.facing == "right" and 2 or ow.player.facing == "left" and -2 or 0)
  local cy = ow.player.cellY + (ow.player.facing == "down" and 2 or ow.player.facing == "up" and -2 or 0)
  if not walkableCell(ow.map, cx, cy) then cx, cy = ow.player.cellX, ow.player.cellY end
  if not walkableCell(ow.map, cx, cy) then return end
  local px, py = worldPos(cx, cy)
  local m = {
    id = nextDemonId, name = name, roster = roster,
    cx = cx, cy = cy, px = px, py = py, facing = randomFacing(),
    hp = scaledSpawnHealth(roster), state = "roam", mapId = ow.map.id,
    -- FIXED 2026-08-07 -- this debug spawn path built its own `m`
    -- table by hand and had drifted out of sync with `spawnDemon`'s
    -- own real AI-state initialization (added the same phase this
    -- row was last touched) -- missing `reactionTime`/`threshold`/
    -- `moveDir`/`moveCount`/`justAttacked`/`justHit` meant a test-
    -- spawned demon skipped its own real reactiontime grace period
    -- and (harmlessly, but wastefully) re-ran a full direction
    -- search on its very first tick instead of starting from a
    -- proper "not moving yet" rest state. Matches `spawnDemon`
    -- exactly now, so a debug-spawned demon behaves identically to
    -- an ambient one, not a second, slightly-different code path.
    reactionTime = ticsToSeconds(REACTIONTIME_TICS), threshold = 0,
    moveDir = DIR.NODIR, moveCount = 0, justAttacked = false, justHit = false,
  }
  nextDemonId = nextDemonId + 1
  demons[#demons + 1] = m
end

function DoomDemons.spawnRow()
  return {
    id = "pokedoom_spawn_demon",
    label = "TEST ENEMY",
    value = function()
      return DoomDemons.NAMES[spawnCursor]
    end,
    step = function(game, dir)
      if game and game.input and game.input.wasPressed and game.input:wasPressed("a") then
        local ok, ow = pcall(function() return require("src.core.Game").overworld end)
        if ok and ow and ow.player and ow.map then pcall(spawnPickedDemon, ow) end
        return false -- spawning doesn't change the displayed NAME cursor
      end
      spawnCursor = ((spawnCursor - 1 + (dir or 1)) % #DoomDemons.NAMES) + 1
      return true
    end,
  }
end

local installedTranslucentDrawHook = false
local function installTranslucentDrawHook()
  if installedTranslucentDrawHook then return end
  installedTranslucentDrawHook = true
  local inner = Voxel3D.draw
  Voxel3D.draw = function(mesh, texture, model, pull, sunModel)
    if pendingTranslucentDraw then
      pendingTranslucentDraw = false
      love.graphics.setColor(DoomDemons.shadowShimmer.alpha, DoomDemons.shadowShimmer.alpha, DoomDemons.shadowShimmer.alpha, 1)
      inner(mesh, texture, model, pull, sunModel)
      love.graphics.setColor(1, 1, 1, 1)
      return
    end
    return inner(mesh, texture, model, pull, sunModel)
  end
end

-- ------- install
local installed = false
-- ------- input.step tick dispatch -- one function per real concern,
-- hung off `DoomDemons._demonAI` (the same real workaround this file
-- already uses throughout for new functions, not a stylistic choice: it
-- is already at Lua's own 200-local-per-scope compile ceiling, so a new
-- top-level `local function` risks a real compile error). Extracted
-- 2026-08-19 during a project-wide readability audit -- `install()`'s
-- own `input.step` hook used to be one ~105-line function mixing pause/
-- mode gating, the pokemon-vs-demon ambient dispatch, the shadow-
-- shimmer tick, and full teardown all in one body; structural cleanup
-- only, no behavior change.

-- ENEMY TYPE = "pokemon": ambient citizens get POSSESSED (chase/attack
-- as themselves) instead of real demons spawning -- see
-- `Options.enemyType`'s own header comment for the full derivation.
function DoomDemons._demonAI.tickPokemonMode(ow, dt)
  pcall(ambientPossessTick, ow, dt)
  for i = #possessedCitizens, 1, -1 do
    local e = possessedCitizens[i]
    if e.mapId == ow.map.id then pcall(tickPossessedCitizen, ow, e, dt) end
    if e.dead then table.remove(possessedCitizens, i) end
  end
end

-- ENEMY TYPE = "demon" (default): the real ambient roster -- spawn,
-- tick every live demon (death-animation or real AI), sync entities,
-- advance projectiles.
function DoomDemons._demonAI.tickDemonMode(ow, dt)
  if #possessedCitizens > 0 then clearPossessedCitizens() end
  pcall(ambientSpawnTick, ow, dt)
  for _, m in ipairs(demons) do
    if m.mapId == ow.map.id then
      if m.state == "dying" then
        pcall(tickDeath, m)
      else
        pcall(tickDemon, ow, m, dt)
      end
    end
  end
  pcall(syncDemons, ow)
  pcall(updateDemonProjectiles, ow, dt)
end

-- Nested inside the SAME `FirstPerson.onTop()` pausing gate as every
-- other per-tick demon update -- a paused game must freeze the shimmer
-- exactly where it is too, not keep animating behind a menu.
function DoomDemons._demonAI.updateShadowShimmer(dt)
  pcall(function()
    DoomDemons.shadowShimmer.accum = DoomDemons.shadowShimmer.accum + dt
    if DoomDemons.shadowShimmer.accum >= 0.09 then
      DoomDemons.shadowShimmer.accum = DoomDemons.shadowShimmer.accum - 0.09
      DoomDemons.shadowShimmer.alpha = 0.28 + math.random() * (0.5 - 0.28)
    end
  end)
end

-- PKDOOM MODE (or the DEMONS row specifically) is off, or Horde Mode is
-- active -- tear every live entity down, same reasoning `lib/
-- DoomItems.lua`'s own `teardownItems` already established (the classic
-- 2D render path still walks `ow.entities` unconditionally). NOT reached
-- just from pausing -- `install()`'s own nested `if FirstPerson.onTop()`
-- keeps a paused game frozen instead of routing here.
function DoomDemons._demonAI.teardownAllDemons(ow)
  for _, m in ipairs(demons) do removeDemonEntity(ow, m) end
  for _, p in ipairs(demonProjectiles) do removeDemonProjectileEntity(ow, p) end
  demonProjectiles = {}
  if #possessedCitizens > 0 then clearPossessedCitizens() end
end

function DoomDemons.install()
  if installed then return end
  installed = true
  installDemonMeshHook()
  installTranslucentDrawHook()
  DoomWeapons.registerTargetResolver(demonResolver)
  DoomWeapons.registerAoeResolver(demonAoeResolver)

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    local ok, ow = pcall(function() return require("src.core.Game").overworld end)
    -- CORRECTED 2026-08-06 (user report: Horde Mode's own enemies were
    -- still Pokémon-sprite mobs, not real DOOM demons -- "i asked you to
    -- add the roster of enemies from doom 1:1... and that should be the
    -- enemies"). This file's own ambient roaming system is REGULAR MODE
    -- ONLY now -- it fully stands down while Horde Mode is active, rather
    -- than the earlier "keep roaming alongside Horde's own wave" design.
    -- The real Horde tie-in is `lib/DoomHordeControl.lua`'s own reskin of
    -- Horde's own spawned mobs to real DOOM demon sprites (wave-scaled
    -- difficulty), reusing Horde's own proven chase/attack/HP system
    -- rather than running a second, separate demon population alongside
    -- it -- avoids the double-source-of-demons confusion (and spawn-rate
    -- stacking) the earlier design risked.
    -- CHANGED 2026-08-06 (user request: "there should be a toggle
    -- enemies off or on") -- `Options.demonsEnabled()` moved from an
    -- inner check (gating only the ambient auto-spawner, so existing/
    -- debug-spawned demons survived it being off -- a real, deliberate
    -- fix earlier the same day for the SPAWN ENEMY debug row) into this
    -- outer gate, so the DEMONS row is now a genuine master switch:
    -- OFF means no demons exist at all, full stop, matching the plain
    -- "enemies off or on" the user actually asked for. A demon placed
    -- by the debug row while this is off simply won't persist -- an
    -- intentional, intuitive tradeoff (the row tests a feature that has
    -- to be turned on to test, the same way any other toggle-gated
    -- feature works), not a regression of that earlier fix.
    -- `Horde` may be nil now (see this file's own header note on `Horde`
    -- above) -- a host without Horde Mode at all can never have an active
    -- run, so `Horde and Horde.active` correctly reads as "not active"
    -- via the `not` below without needing its own separate nil branch.
    if ok and ow and Options.enabled() and Options.demonsEnabled() and not (Horde and Horde.active) then
      -- FIXED 2026-08-06 -- user report: demon AI kept running while the
      -- game was paused (a menu open). `FirstPerson.onTop()` (public,
      -- `FirstPerson.lua`'s own real "is the overworld what's actually
      -- on top of the stack, with nothing -- a menu, a dialog, a battle
      -- -- covering it" check) is the same real signal this mod's own
      -- camera/weapon/HUD code already uses to know the game genuinely
      -- has focus (`DoomView.lua`'s `bobOffset`, `DoomWeapons.lua`'s
      -- `active()`, both via `FirstPerson.driving()`, which is just
      -- `engaged() and onTop()` -- `onTop()` alone is used directly here
      -- rather than `driving()` because `engaged()` also requires the
      -- free-roam camera rung specifically, which has nothing to do with
      -- whether the SIMULATION should be paused). Per the user's own
      -- explicit standing rule (now in CLAUDE.md): pausing means paused,
      -- no matter what, until unpaused -- no per-system exceptions.
      --
      -- Deliberately its own `if`, nested INSIDE the real "is the mode
      -- even on" gate, not folded into one combined condition -- pausing
      -- must FREEZE demons in place (nothing here runs, entities stay
      -- exactly where `ow.entities` already has them), not tear them
      -- down the way the `elseif` branch below does for the mode
      -- genuinely being off. Folding `FirstPerson.onTop()` into that
      -- same combined condition would have sent "just paused" down the
      -- teardown branch too, deleting every demon the instant a menu
      -- opened -- a real, worse regression this nesting avoids.
      if FirstPerson.onTop() then
        if Options.enemyType() == "pokemon" then
          DoomDemons._demonAI.tickPokemonMode(ow, dt)
        else
          DoomDemons._demonAI.tickDemonMode(ow, dt)
        end
        DoomDemons._demonAI.updateShadowShimmer(dt)
      end
    elseif ok and ow then
      DoomDemons._demonAI.teardownAllDemons(ow)
    end
    return next(game, dt)
  end)
end

return DoomDemons
