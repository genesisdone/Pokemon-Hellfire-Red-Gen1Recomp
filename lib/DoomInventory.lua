-- PokeDoom Phase 13: DOOM weapons/ammo shown in the game's own real
-- ITEMS bag (PAUSE -> ITEMS), at the user's own explicit request ("i
-- should see any doom items i have... the same way i would find any
-- item ive gotten in game in pokemon gen 1"). Confirmed feasible by
-- direct investigation, not assumed: `mod.content.items` is a real,
-- documented mod-facing registry (`gen1recomp-dev/src/mods/Schemas.
-- lua:475-489`), the SAME generic `Registry:register(id, value, owner)`
-- API already used elsewhere for brand-new content
-- (`mod.content.maps:register("MY_CAVE", {...})`, that same file's own
-- example at line 521) -- not just `:patch`-ing existing ROM items, a
-- genuinely new registration. `save.inventory[id] = quantity`
-- (`src/inventory/Bag.lua`) is the real, plain backing store the bag
-- UI already reads (`src/ui/BagMenu.lua:22` etc) -- this file keeps
-- those counts in sync with `lib/DoomWeapons.lua`'s own real ammo/
-- ownership state every frame, rather than maintaining a second,
-- independently-mutated copy that could drift.
--
-- ------- what's shown, and what deliberately isn't
--
-- All 8 weapons (including fist/pistol -- the user's own explicit
-- follow-up: "the guns should show up in items too, not just bullets,"
-- read as every gun the player has, not just the found ones; this
-- mod's own starting-loadout distinction from `G_PlayerReborn` matters
-- for GAMEPLAY, not for whether the bag reflects reality) and the 4
-- ammo types: both are genuinely "inventory-shaped" in real DOOM --
-- persistent, quantity-tracked state that already exists in this mod
-- (`lib/DoomWeapons.lua`'s own `weaponowned`/`ammo` tables). Health/
-- armor pickups are deliberately NOT represented here: real DOOM has
-- no "held" stimpack/armor inventory at all -- a stimpack heals
-- INSTANTLY on touch (`P_TouchSpecialThing`, already how `lib/
-- DoomItems.lua`'s own world pickups work), never stored for later use,
-- so there is nothing to display in a bag slot for those; Health%/
-- Armor% already have their own real home on the DOOM status bar
-- (`lib/DoomHud.lua`, Phase 12).
--
-- ------- names: real DOOM terms, but SHORT enough to fit the bag's own
-- real single-line row (confirmed by reading `BagMenu.lua` directly:
-- `label`/`right` are drawn by a generic list widget with no line-wrap
-- of its own -- a long label runs straight into the "x123" quantity,
-- a real bug the user reported, e.g. "Rocket Launcher" overlapping its
-- own count). Base-engine code (`gen1recomp-dev`), so this can't be
-- fixed by adding wrapping there (CLAUDE.md's hard rule) -- shortening
-- names to the width every REAL Gen1 item name was already authored
-- against (the longest real ones, e.g. "Full Restore," sit around 12-13
-- characters) is the only fix available on this mod's own side. Every
-- name below is still real DOOM vocabulary (`d_englsh.h`'s own pickup
-- text, re-checked fresh), just the SHORT real noun rather than the
-- full sentence -- "Plasma Gun" specifically, not "Plasma Rifle" (real
-- DOOM's own `GOTPLASMA` text says "the plasma gun," never "rifle").

local V = ...
local DoomWeapons = V.require("DoomWeapons")
local Options = V.require("DoomOptions")

local DoomLog
local function getDoomLog()
  DoomLog = DoomLog or V.require("DoomLog")
  return DoomLog
end

local DoomInventory = {}

-- Weapon item ids -- prefixed to avoid any collision with a real Gen1
-- item id or another mod's own registration (`POKEDOOM_` matches this
-- project's own existing global-namespacing convention, `pokedoom_give`/
-- `pokedoom_hurt`). `name` is real DOOM weapon flavor, not a Pokémon
-- reskin (Locked Decision 2). `tossable = false` throughout: these
-- aren't discardable Poké Balls -- ownership is Phase 13's own real
-- `weaponowned[]` state, not something the bag's own TOSS action should
-- be allowed to mutate independently (that concern is unrelated to
-- selling -- see `price` below).
--
-- `price` added 2026-08-07 -- user report: "the doom items should be
-- able to be sold in shops for currency. right now they can be sold,
-- but for nothing. add value to them." Confirmed real and simple to
-- explain: `src/ui/ShopMenu.lua`'s own real sell flow (read fresh) only
-- ever excludes `def.keyItem`/an `HM_`-prefixed id from selling --
-- `tossable` isn't consulted there at all -- so every one of these rows
-- was ALREADY sellable, just for `math.floor(0/2)` Pokédollars every
-- time (`price` had never been set, defaulting to the field's own `0`).
-- Real DOOM has no economy/currency of any kind to derive a "correct"
-- price from (the same real gap this project's own CLAUDE.md already
-- names for pure visual judgment calls) -- these are a new, explicitly
-- mod-original judgment call, scaled relative to each other by real
-- combat usefulness/rarity and loosely against this engine's own
-- existing Gen1 shop price range (Poké Ball ¥200, Full Restore ¥3000)
-- rather than picked arbitrarily.
--
-- `FIST` is deliberately `keyItem = true`, not merely priced -- real
-- DOOM's own fist is a permanent, un-loseable baseline
-- (`weaponowned[wp_fist]` starts AND stays true, g_game.c:826; there is
-- no source function that ever revokes it) -- `keyItem` is this
-- engine's own real "can never be sold" flag (`ShopMenu.lua`'s own
-- literal check), the correct mechanism to keep that real DOOM fact
-- true here too, not an arbitrary ¥0.
local WEAPON_ITEMS = {
  FIST = { id = "POKEDOOM_FIST", name = "Fist", keyItem = true },
  PISTOL = { id = "POKEDOOM_PISTOL", name = "Pistol", price = 800 },
  SHOTGUN = { id = "POKEDOOM_SHOTGUN", name = "Shotgun", price = 2000 },
  CHAINGUN = { id = "POKEDOOM_CHAINGUN", name = "Chaingun", price = 3500 },
  ROCKETLAUNCHER = { id = "POKEDOOM_RLAUNCHER", name = "Rocket Lnchr", price = 6000 },
  PLASMARIFLE = { id = "POKEDOOM_PLASMA", name = "Plasma Gun", price = 8000 },
  BFG9000 = { id = "POKEDOOM_BFG9000", name = "BFG9000", price = 20000 },
  CHAINSAW = { id = "POKEDOOM_CHAINSAW", name = "Chainsaw", price = 1500 },
}

-- Ammo item ids, one per real DOOM ammo type (`lib/DoomWeapons.lua`'s
-- own `player.ammo` keys) -- shown regardless of whether any weapon
-- using that type is owned yet, matching real DOOM (ammo and weapon
-- ownership are genuinely independent state; you can find shells before
-- ever finding a shotgun). Names are the real noun each pickup message
-- itself uses (`GOTCLIP`: "a clip"; `GOTSHELLS`: "...shotgun shells";
-- `GOTROCKET`: "a rocket"; `GOTCELL`: "an energy cell"). `price` is
-- PER UNIT (the shop's own `unit = def.price/2` sell math and its
-- `unitPrice`-driven quantity box already multiply by however many the
-- player chooses to sell) -- see `WEAPON_ITEMS`'s own header comment
-- for why these numbers exist at all.
local AMMO_ITEMS = {
  -- FIX 2026-08-08 (user request): price raised from the original `4`
  -- to `10`.
  clip = { id = "POKEDOOM_BULLETS", name = "Clip", price = 10 },
  shell = { id = "POKEDOOM_SHELLS", name = "Shells", price = 10 },
  misl = { id = "POKEDOOM_ROCKETS", name = "Rocket", price = 100 },
  cell = { id = "POKEDOOM_CELLS", name = "Energy Cell", price = 40 },
}

-- Real, confirmed bug (2026-08-06 playtest): this used to run lazily,
-- inside the per-frame `input.step` hook below, gated on `Options.
-- enabled()` -- so registration didn't happen until the FIRST frame
-- PKDOOM MODE was actually on. Too late: `Loader.lua`'s own comment,
-- read directly after the bug report, says it outright -- "content
-- freezes at the merge boundary" (`Loader.lua:1045-1049`, right after
-- every mod's own top-level `main.lua` has finished running, well
-- BEFORE the game loop or any runtime hook ever fires). Every
-- `:register()` call this file made was hitting an ALREADY-FROZEN
-- registry and (near-certainly) throwing -- silently swallowed by this
-- function's own `pcall`, which is exactly why the bag fell back to
-- `label = def and def.name or id` -> the raw, underscore-full ID
-- string (`st_stuff.c`... no, this engine's own `BagMenu.lua:21`) --
-- confirmed by the user's own screenshot showing literal "POKEDOOM
-- BULLETS" rows instead of "Clip." Fixed by calling this ONCE,
-- unconditionally, at the SAME top-level mod-load time every other
-- real `mod.content.*:register(...)` example in this engine uses
-- (`DoomInventory.install()` below, not deferred into any hook) --
-- registration is a static content declaration, independent of whether
-- PKDOOM MODE happens to be toggled on in any given save; `syncCounts`
-- (still gated on `Options.enabled()`, still per-frame) is the only
-- part of this file that actually needs runtime state.
local function registerItems(mod)
  for _, item in pairs(WEAPON_ITEMS) do
    local ok, err = pcall(function()
      mod.content.items:register(item.id, {
        id = item.id, name = item.name, price = item.price or 0,
        tossable = false, keyItem = item.keyItem or nil,
      })
    end)
    if not ok then
      print(("[PokeDoom] item registration failed for %s: %s"):format(item.id, tostring(err)))
    end
  end
  for _, item in pairs(AMMO_ITEMS) do
    local ok, err = pcall(function()
      mod.content.items:register(item.id, {
        id = item.id, name = item.name, price = item.price or 0, tossable = false,
      })
    end)
    if not ok then
      print(("[PokeDoom] item registration failed for %s: %s"):format(item.id, tostring(err)))
    end
  end
end

-- Real Gen1 bag behavior (and this engine's own faithful port of it) is
-- that an item's slot disappears entirely once its count hits 0, never
-- lingering as an "x0" row -- so a weapon not yet owned, or an ammo type
-- still at 0, is represented by simply NOT having a key in
-- `save.inventory` at all (`nil`), not a zero written into one.
-- FIXED 2026-08-07, same round as adding `price` above -- without this,
-- selling would have looked free (the bag row visibly loses its "x1"/
-- "xN") for exactly one frame and then silently reappear: this function
-- runs every `input.step` and OVERWRITES `save.inventory[id]` straight
-- from `DoomWeapons`' own real state every single time, which selling
-- (`src/ui/ShopMenu.lua`'s own `Bag.remove`) never touches at all --
-- the very next tick would stomp the sale right back.
--
-- `lastSynced` -- private, NOT saved, separate from both `save.
-- inventory` and `DoomWeapons`' own state -- remembers what THIS
-- function itself last wrote for each row. That third value is load-
-- bearing: a raw "is the bag's displayed count lower than DoomWeapons'
-- own current truth" check (an earlier draft of this fix) can't tell a
-- sale apart from a fresh pickup that happened the SAME frame -- both
-- make DoomWeapons' own count exceed what's still displayed, for
-- opposite reasons (a sale lowers the DISPLAY out from under an
-- unchanged true count; a pickup raises the TRUE count before the
-- display has caught up). Comparing against "what I last wrote" instead
-- of "what's currently true" resolves that: a pickup never touches
-- `save.inventory` directly, so `shown == lastSynced` right up until
-- THIS function's own next write updates both together, while a sale
-- changes `save.inventory` WITHOUT going through this function at all,
-- so `shown` diverges from `lastSynced` the moment it happens --
-- exactly, and only, the real signal being looked for.
--
-- FIX 2026-08-19 -- REAL ROOT CAUSE tying together two separate same-day
-- reports: a pistol silently vanishing from both the bag AND
-- `weaponowned` outside any shop visit, and a new game starting with 0
-- ammo instead of the real 20-round starting clip even after `lib/
-- DoomWeapons.lua`'s own `loadWeaponSave` was fixed to force real
-- starting values on `save.created`. This table, exactly like that
-- file's own `Game.save.pokedoomWeapons` bug, is module-level and was
-- NEVER reset on a save transition -- unlike that field, though,
-- `lastSynced` isn't even save-namespaced at all, so nothing could have
-- caught this by reading the save data itself. On a genuine new game (or
-- any save switch), `save.inventory` becomes a real, fresh table (empty,
-- or whatever that save actually has) while `lastSynced` keeps whatever
-- this module last saw from the PREVIOUS save/session -- `syncCounts`
-- (below) runs every real tick starting on the very first one, reads
-- that stale `lastSynced` against the new save's genuinely different
-- `save.inventory`, and reads the difference as a real sale/consumption
-- event: `reconcileWeapon`'s "mine and not shown -> takeWeapon" fires
-- the instant a weapon that was owned in an earlier session isn't yet
-- reflected in the new save's own bag, and `reconcileAmmo`'s matching
-- "shown < mine -> takeAmmo" does the identical thing to ammo -- silently
-- erasing whatever `loadWeaponSave` had just correctly set, within the
-- very same tick a new game starts. Reset alongside `DoomWeapons`' own
-- real state on the identical two events -- see `resetSync` and
-- `DoomInventory.install()` below.
local lastSynced = {}

local function resetSync()
  lastSynced = {}
end

-- EXTENDED 2026-08-08 -- user request: "you should be able to buy doom
-- items randomly through pokeshops." A purchase (`src/ui/ShopMenu.lua`'s
-- own real buy flow, `Bag.add`) is the exact mirror image of a sale
-- through this same seam: it also mutates `save.inventory` directly,
-- without going through this file's own `syncCounts` -- so `shown`
-- diverging from `lastSynced` the OTHER way (higher, not lower) is
-- exactly, and only, a purchase, by the identical reasoning the
-- original sell-detection comment above already lays out. Reconciled
-- into `DoomWeapons`' own real ownership/ammo state the same way a
-- sale already was, just via `giveWeapon`/`giveAmmoUnits` instead of
-- `takeWeapon`/`takeAmmo`.
-- DIAGNOSTIC 2026-08-19 -- direct user report: a weapon (the pistol)
-- vanished from both the bag AND `weaponowned` after an ordinary weapon
-- switch, no shop visit involved -- the only real code path that can
-- revoke ownership at all is `takeWeapon`, called from here specifically
-- when this function reads "the bag USED to show this weapon, but
-- doesn't anymore" as a sale. Whether that's a genuine sale-detection
-- false positive (e.g. `save.inventory` getting reset/replaced by
-- something unrelated to a shop, with `lastSynced` -- module-level, not
-- save-scoped -- still holding a stale "mine" from before) was not
-- reproducible from reading the code alone; logs every real take/give
-- this function ever triggers, so the next report shows definitively
-- whether this is really what fired, matching CLAUDE.md's own "log
-- before a second guess" rule.
local function reconcileWeapon(save, name, item)
  if item.keyItem then return end
  local shown = save.inventory[item.id]
  local mine = lastSynced[item.id]
  if mine and not shown then
    local log = getDoomLog()
    if log then pcall(log.event, "INVENTORY", "reconcileWeapon: taking %s (bag no longer shows it, id=%s)", name, tostring(item.id)) end
    DoomWeapons.takeWeapon(name)
  elseif shown and not mine then
    local log = getDoomLog()
    if log then pcall(log.event, "INVENTORY", "reconcileWeapon: giving %s (bag shows it but wasn't ours, id=%s)", name, tostring(item.id)) end
    DoomWeapons.giveWeapon(name)
  end
end

local function reconcileAmmo(ammoType, item, save)
  local shown = save.inventory[item.id] or 0
  local mine = lastSynced[item.id] or 0
  if shown < mine then
    DoomWeapons.takeAmmo(ammoType, mine - shown)
  elseif shown > mine then
    -- Per-UNIT, not `giveAmmo`'s own "clip load" multiplier -- see
    -- `DoomWeapons.giveAmmoUnits`'s own header comment for why a shop
    -- purchase needs the raw-unit variant specifically.
    DoomWeapons.giveAmmoUnits(ammoType, shown - mine)
  end
end

local function syncCounts(save)
  save.inventory = save.inventory or {}
  for name, item in pairs(WEAPON_ITEMS) do
    reconcileWeapon(save, name, item)
  end
  for ammoType, item in pairs(AMMO_ITEMS) do
    reconcileAmmo(ammoType, item, save)
  end
  local owned = DoomWeapons.ownedSnapshot()
  for name, item in pairs(WEAPON_ITEMS) do
    save.inventory[item.id] = owned[name] and 1 or nil
    lastSynced[item.id] = save.inventory[item.id]
  end
  for ammoType, item in pairs(AMMO_ITEMS) do
    local count = DoomWeapons.ammoCount(ammoType)
    save.inventory[item.id] = count > 0 and count or nil
    lastSynced[item.id] = save.inventory[item.id]
  end
end

-- ------- Pokémart integration -- user request 2026-08-08: "you should
-- be able to buy doom items randomly through pokeshops in the normal
-- in game buy menu, with some shops selling one item, and other shops
-- selling another, all with prices which make sense for the rarity of
-- item, how powerful it is, and how rare it is." Confirmed the real,
-- sanctioned seam for this: `mod.content.text_pointers`
-- (`gen1recomp-dev/src/mods/Schemas.lua:1250-1258`, `semantics =
-- "deep"`) -- `:patch(mapLabel, {TEXT_CONST = {mart = {"NEW_ITEM_ID"}}})`
-- APPENDS to a specific mart clerk's own real stock list rather than
-- replacing it ("deep" semantics merge list fields, confirmed via
-- `src/mods/Merge.lua`), so this adds alongside each mart's existing
-- real Pokémon inventory, never clobbering it. Prices reuse the SAME
-- `price` field `WEAPON_ITEMS`/`AMMO_ITEMS` above already carry (added
-- 2026-08-07 for selling) -- `src/ui/ShopMenu.lua`'s own real buy flow
-- reads the identical `game.data.items[id].price` field for the BUY
-- cost, so no separate pricing scheme is needed; the existing "scaled
-- by real combat usefulness/rarity" values already do double duty, "a
-- different set price for each item" without inventing a second scale.
--
-- Distribution spreads roughly along real Kanto's own town progression
-- order (Viridian through Indigo Plateau) so a weapon's own real price
-- and a mart's own real place in the game stay in the same rough
-- ballpark, and "some shops sell one item, other shops sell another"
-- per the user's own words -- a judgment call, no DOOM or Gen1
-- precedent dictates which shop should sell what.
--
-- Deliberately NOT extended to health/armor (STIM/MEDI/ARM1/ARM2/BON1/
-- BON2/SOUL): those are the items `WEAPON_ITEMS`/`AMMO_ITEMS` above
-- already deliberately exclude from the bag entirely, since real DOOM
-- has no "held" stimpack/armor inventory to begin with (this file's
-- own header comment) -- a shop purchase of one would need a genuinely
-- different mechanism (apply the effect instantly on purchase, never
-- actually occupy a bag slot) than the reconcile pattern this file's
-- weapon/ammo rows already use, which assumes a real, persistent,
-- quantity-tracked owned state on the other end. Flagged as a real,
-- explicit gap for a later round, not silently dropped.
local MART_STOCK = {
  ViridianMart       = { "TEXT_VIRIDIANMART_CLERK", { "POKEDOOM_BULLETS" } },
  PewterMart         = { "TEXT_PEWTERMART_CLERK", { "POKEDOOM_SHELLS" } },
  CeruleanMart       = { "TEXT_CERULEANMART_CLERK", { "POKEDOOM_PISTOL" } },
  VermilionMart      = { "TEXT_VERMILIONMART_CLERK", { "POKEDOOM_SHOTGUN" } },
  LavenderMart       = { "TEXT_LAVENDERMART_CLERK", { "POKEDOOM_CHAINSAW" } },
  CeladonMart2F      = { "TEXT_CELADONMART2F_CLERK1", { "POKEDOOM_CELLS" } },
  CeladonMart4F      = { "TEXT_CELADONMART4F_CLERK", { "POKEDOOM_CHAINGUN" } },
  CeladonMart5F      = { "TEXT_CELADONMART5F_CLERK1", { "POKEDOOM_ROCKETS" } },
  FuchsiaMart        = { "TEXT_FUCHSIAMART_CLERK", { "POKEDOOM_RLAUNCHER" } },
  SaffronMart        = { "TEXT_SAFFRONMART_CLERK", { "POKEDOOM_PLASMA" } },
  CinnabarMart       = { "TEXT_CINNABARMART_CLERK", { "POKEDOOM_BULLETS" } },
  IndigoPlateauLobby = { "TEXT_INDIGOPLATEAULOBBY_CLERK", { "POKEDOOM_BFG9000" } },
}

local function patchMartStock(mod)
  for mapLabel, entry in pairs(MART_STOCK) do
    local textConst, items = entry[1], entry[2]
    local ok, err = pcall(function()
      mod.content.text_pointers:patch(mapLabel, { [textConst] = { mart = items } })
    end)
    if not ok then
      print(("[PokeDoom] mart stock patch failed for %s/%s: %s"):format(mapLabel, textConst, tostring(err)))
    end
  end
end

local installed = false
function DoomInventory.install()
  if installed then return end
  installed = true

  -- Unconditional, synchronous, right here at mod-load time -- NOT
  -- inside the hook below -- see `registerItems`'s own header comment
  -- for the real bug this fixes (the same real "content freezes at the
  -- merge boundary" timing applies to `text_pointers:patch` too).
  registerItems(V.mod)
  patchMartStock(V.mod)

  -- See `lastSynced`'s own 2026-08-19 header comment above for the full
  -- derivation -- both events mean "a DIFFERENT save's own `save.
  -- inventory` is now what `syncCounts` will read," so whatever this
  -- module last compared against is meaningless the moment either fires.
  V.mod.events:on("save.loaded", resetSync)
  V.mod.events:on("save.created", resetSync)

  V.mod.hooks:wrap("input.step", function(next, game, dt)
    if Options.enabled() then
      local ok, Game = pcall(require, "src.core.Game")
      local save = ok and Game.save
      if save then pcall(syncCounts, save) end
    end
    return next(game, dt)
  end)
end

return DoomInventory
