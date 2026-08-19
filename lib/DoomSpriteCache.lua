-- PokeDoom: shared WAD-sprite caching loaders.
--
-- Factored out 2026-08-19 during a project-wide readability audit, at
-- direct user request ("look through every code file for the mod and
-- look for issues with human readability"). The audit found the exact
-- same two caching patterns independently reimplemented across four
-- files: `lib/DoomHud.lua`'s `loadHudAsset`, `lib/DoomMenuSkin.lua`'s
-- `loadPatch`, `lib/DoomKill.lua`'s `loadGibSprite`, `lib/DoomItems.lua`'s
-- `loadItemImage`, and `lib/DoomDemons.lua`'s `loadDemonSprite`.
-- CLAUDE.md's own hard rule on parallel implementations exists
-- specifically because this shape of duplication has already caused
-- real, repeat bugs in this project.
--
-- Each `new*Loader()` call returns a FRESH closure with its own private
-- cache table -- callers never share a cache with each other (a demon's
-- own sprite cache and an item's own icon cache are unrelated data),
-- only the caching/invalidation LOGIC is shared.

local V = ...
local DoomWadImport = V.require("DoomWadImport")

local DoomSpriteCache = {}

-- Pattern A: a name -> WAD sprite ASSET (image + real grAb leftoffset/
-- topoffset, `DoomWadImport.loadSpriteAsset`) cache, invalidated
-- whenever `DoomWadImport.status.state` changes. Used by anything that
-- needs a patch's own real DOOM anchor point, not just its pixels --
-- `lib/DoomHud.lua`'s status-bar digits/face, `lib/DoomMenuSkin.lua`'s
-- skull cursor/thermo-bar patches.
function DoomSpriteCache.newAssetLoader()
  local cache = {}
  local lastWadState = nil
  return function(nameSubstring)
    if DoomWadImport.status.state ~= lastWadState then
      lastWadState = DoomWadImport.status.state
      cache = {}
    end
    local hit = cache[nameSubstring]
    if hit ~= nil then return hit or nil end
    local value = false
    if lastWadState == "ready" then
      local ok, asset = pcall(DoomWadImport.loadSpriteAsset, nameSubstring)
      if ok and asset then value = asset end
    end
    cache[nameSubstring] = value
    return value or nil
  end
end

-- Pattern B: a (spritePrefix, letter) -> plain `love.graphics.Image`
-- cache (`DoomWadImport.loadImage`), trying real DOOM's own rotation-0
-- (all-angle) lump first, then rotation-1 -- this project's own
-- established "billboards face one fixed way, no real per-angle
-- tracking" simplification (`SpriteBillboards.lua`'s own "the card
-- always faces SOUTH" precedent). Used by anything that only needs
-- pixels, not a real DOOM anchor point -- `lib/DoomKill.lua`'s gib
-- sprites, `lib/DoomItems.lua`'s pickup icons, `lib/DoomDemons.lua`'s
-- roster.
--
-- `includeCompoundFallback` (default false): opts into a THIRD real
-- lookup, `DoomWadImport.findSpriteFrameName`, for the rare real case a
-- single lump encodes two different frame letters' own rotation-1 art
-- at once (e.g. Spider Mastermind's real `SPIDA1D1` -- confirmed
-- 2026-08-07, see `DoomWadImport.findSpriteFrameName`'s own header for
-- the full real-lump-format audit). Only `lib/DoomDemons.lua`'s own
-- roster actually needs this (compound lumps are a real DOOM monster-
-- sheet thing, not something items/gibs use) -- other callers leave it
-- off rather than paying for a lookup they'll never hit.
function DoomSpriteCache.newSpriteLoader(includeCompoundFallback)
  local cache = {}
  local lastWadState = nil
  return function(spritePrefix, letter)
    if DoomWadImport.status.state ~= lastWadState then
      lastWadState = DoomWadImport.status.state
      cache = {}
    end
    local base = spritePrefix .. letter
    local full = base .. "0"
    if cache[full] == nil then
      local value = false
      if lastWadState == "ready" then
        local ok, img = pcall(DoomWadImport.loadImage, full)
        if ok and img then
          value = img
        else
          local full1 = base .. "1"
          local ok1, img1 = pcall(DoomWadImport.loadImage, full1)
          if ok1 and img1 then
            value = img1
            cache[full1] = img1
          elseif includeCompoundFallback then
            local exact = DoomWadImport.findSpriteFrameName(spritePrefix, letter, "1")
            if exact then
              local ok2, img2 = pcall(DoomWadImport.loadImage, exact)
              if ok2 and img2 then
                value = img2
                cache[exact] = img2
              end
            end
          end
        end
      end
      cache[full] = value
    end
    return cache[full] or nil
  end
end

return DoomSpriteCache
