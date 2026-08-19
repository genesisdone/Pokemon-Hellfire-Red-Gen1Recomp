-- PokeDoom: a single shared "safe ground height at a cell" lookup.
--
-- Factored out 2026-08-19 during a project-wide readability audit, at
-- direct user request ("look through every code file for the mod and
-- look for issues with human readability"). The audit found the exact
-- same three-line pattern -- `local ok, got = pcall(VoxelScene.groundAt,
-- map, cx, cy); ... (ok and got) or 0` -- independently reimplemented
-- roughly 20 times across `DoomBarrels.lua`, `DoomBlood.lua`,
-- `DoomDemons.lua`, `DoomKill.lua`, `DoomProps.lua`, `DoomPuff.lua`, and
-- `DoomWeapons.lua`. CLAUDE.md's own hard rule on parallel
-- implementations exists specifically because this shape of duplication
-- has already caused real, repeat bugs in this project (a fix to one
-- copy not reaching its siblings) -- this is that same risk, just for a
-- lookup instead of an entity lifecycle.
--
-- `VoxelScene.groundAt(map, cx, cy)` is the host mod's own real terrain-
-- height query (`Host.require("VoxelScene")`) -- wrapped in `pcall`
-- because every one of this project's own prior copies already found it
-- can legitimately fail for an unloaded/out-of-range cell, and every one
-- of them chose the same safe fallback: 0.

local V = ...
local Host = V.host
local VoxelScene = Host.require("VoxelScene")

local DoomGround = {}

-- Returns the real ground height at (cx, cy) on `map`, or 0 if
-- VoxelScene can't answer -- the same fallback every prior copy of this
-- lookup already used. `map` is a real map object (`ow.map`, `proj.ow.
-- map`, etc.) -- pass whichever one the caller already has in scope.
function DoomGround.heightAt(map, cx, cy)
  local ok, got = pcall(VoxelScene.groundAt, map, cx, cy)
  return (ok and got) or 0
end

return DoomGround
