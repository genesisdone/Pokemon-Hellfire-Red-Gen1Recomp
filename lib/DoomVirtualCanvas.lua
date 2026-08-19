-- PokeDoom: DOOM's own real 320x200 virtual canvas -- the shared
-- coordinate system every one of this mod's own screen-space DOOM-
-- native overlays (the pause menu skin, the status bar, the town-
-- invasion HUD counter) draws into, scaled/offset to fit the real
-- window.
--
-- Factored out 2026-08-19 during a project-wide readability audit, at
-- direct user request. `VIRTUAL_W, VIRTUAL_H = 320, 200` (DOOM's own
-- real SCREENWIDTH/SCREENHEIGHT) and a byte-identical `centered(w, h)`
-- transform were independently redefined in both `lib/DoomMenuSkin.lua`
-- and `lib/DoomTownInvasion.lua`.
--
-- `lib/DoomHud.lua`'s own transform is a genuinely DIFFERENT variant
-- (X centered, Y BOTTOM-anchored -- the real status bar always sits at
-- SCREENHEIGHT, not vertically centered) -- `bottomAnchored` below is
-- that same real math, offered here too so all three files share the
-- same two real constants even though they need different transforms.

local DoomVirtualCanvas = {}

DoomVirtualCanvas.VIRTUAL_W = 320
DoomVirtualCanvas.VIRTUAL_H = 200

-- CENTERED on both axes -- `M_Drawer`'s own real layout centers
-- everything within its own 320x200 space; any window-aspect-ratio
-- slack splits evenly on both edges. Used by the pause/options menu
-- skin and the town-invasion HUD counter.
function DoomVirtualCanvas.centered(w, h)
  local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H
  local scale = math.min(w / VIRTUAL_W, h / VIRTUAL_H)
  return scale, (w - VIRTUAL_W * scale) / 2, (h - VIRTUAL_H * scale) / 2
end

-- X centered, Y flush against the BOTTOM edge -- keeps DOOM's real
-- bottom-screen furniture (the status bar) flush against a widescreen
-- window's own bottom edge, matching the real `ST_Y`/SCREENHEIGHT
-- relationship instead of floating it mid-screen. Used by the status
-- bar HUD.
function DoomVirtualCanvas.bottomAnchored(w, h)
  local VIRTUAL_W, VIRTUAL_H = DoomVirtualCanvas.VIRTUAL_W, DoomVirtualCanvas.VIRTUAL_H
  local scale = math.min(w / VIRTUAL_W, h / VIRTUAL_H)
  return scale, (w - VIRTUAL_W * scale) / 2, h - VIRTUAL_H * scale
end

return DoomVirtualCanvas
