-- PokeDoom: a minimal, pure-Lua ZIP reader -- extracts every entry under
-- a given path prefix out of a whole zip file's own raw bytes, with no
-- external tool and no engine-level mount step.
--
-- ADDED 2026-08-19, replacing the "player pre-extracts this themselves"
-- workaround `lib/DoomGZDoomImport.lua` shipped earlier the same day.
-- That workaround existed because the two REAL zip-reading paths this
-- project used before (`love.filesystem.mount`, raw FFI `PHYSFS_mount`)
-- are both now hard-blocked for mod code on the current engine
-- (confirmed directly against `gen1recomp-dev-0.29/src/mods/Sandbox.lua`
-- -- `ffi` is in that file's own `DENIED_PREFIX` table, and `fsShim.
-- mount()` always returns `false` with an explicit "mounting is
-- refused" message). Direct user question -- "is there really no way
-- for the program to extract a zip for you" -- prompted a closer look
-- rather than accepting the manual-extraction workaround as final: that
-- same file's own `BLOCKED_LOVE` table (the actual, complete deny-list
-- for the `love` global mod code sees) lists only `filesystem`,
-- `thread`, `system`, and `event` -- with its own header comment stating
-- outright, "Everything else LÖVE exposes passes through." `love.data`
-- is not on that list at all, and `love.data.decompress` is LÖVE's own
-- real, built-in raw-DEFLATE decompressor (a documented LÖVE 11.x API,
-- `format = "deflate"` -- matches ZIP's own compression method 8
-- exactly: a raw deflate stream, no zlib/gzip wrapper). That's the one
-- real gap `love.filesystem.mount`/FFI used to fill; parsing a ZIP's own
-- plain, published byte-level structure (central directory, local file
-- headers) needs nothing beyond ordinary string/byte manipulation, both
-- already unrestricted for mod code. Together, that's a complete,
-- working zip reader with no blocked API anywhere in it.
--
-- ZIP format read directly from the format's own public specification
-- (APPNOTE.TXT, PKWARE's own published ZIP spec) -- every field/offset
-- below is that spec's own real layout, not guessed:
--   End Of Central Directory record: signature 0x06054b50 ("PK\5\6"),
--     located by scanning backward from the file's own end (it can carry
--     a variable-length comment after it, so it isn't at a fixed offset).
--   Central Directory File Header: signature 0x02014b50 ("PK\1\2") --
--     one per entry, carries the entry's own name, compression method,
--     compressed size, and the byte offset of its LOCAL header.
--   Local File Header: signature 0x04034b50 ("PK\3\4") -- immediately
--     precedes an entry's own actual compressed data; needed because its
--     own filename/extra-field lengths (not always identical to the
--     central directory's copy) determine exactly where that data
--     starts.

local DoomZipReader = {}

local function u16(s, i)
  local b1, b2 = s:byte(i, i + 1)
  return b1 + b2 * 256
end

local function u32(s, i)
  local b1, b2, b3, b4 = s:byte(i, i + 3)
  return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- The EOCD's own trailing comment can be up to 65535 bytes -- search the
-- last (22 + 65535) bytes of the file for its real signature, from the
-- END backward (a comment could coincidentally contain the same 4 bytes
-- earlier in the file; scanning from the end and taking the LAST real
-- match is the standard, spec-correct way every real zip reader handles
-- this).
local EOCD_SIG = "PK\5\6"
local MAX_COMMENT = 65535
local function findEocd(bytes)
  local searchFrom = math.max(1, #bytes - (22 + MAX_COMMENT))
  local best = nil
  local at = searchFrom
  while true do
    local s, e = bytes:find(EOCD_SIG, at, true)
    if not s then break end
    best = s
    at = s + 1
  end
  return best
end

-- Returns a list of `{name, data}` for every real entry whose own name
-- starts with `prefix`, or `nil, reason` if `bytes` isn't a real zip at
-- all (or the central directory can't be found/parsed).
function DoomZipReader.extractPrefix(bytes, prefix)
  if type(bytes) ~= "string" or #bytes < 22 then
    return nil, "not a zip file (too small)"
  end
  local eocdAt = findEocd(bytes)
  if not eocdAt then
    return nil, "no end-of-central-directory record found -- not a real zip file"
  end
  local cdCount = u16(bytes, eocdAt + 10)
  local cdOffset = u32(bytes, eocdAt + 16)

  local out = {}
  local pos = cdOffset + 1 -- ZIP offsets are 0-based; Lua strings are 1-based
  for _ = 1, cdCount do
    if pos + 46 > #bytes + 1 then break end
    if bytes:sub(pos, pos + 3) ~= "PK\1\2" then break end
    local method = u16(bytes, pos + 10)
    local compSize = u32(bytes, pos + 20)
    local nameLen = u16(bytes, pos + 28)
    local extraLen = u16(bytes, pos + 30)
    local commentLen = u16(bytes, pos + 32)
    local localOffset = u32(bytes, pos + 42)
    local name = bytes:sub(pos + 46, pos + 46 + nameLen - 1)

    if name:sub(1, #prefix) == prefix and not name:match("/$") then -- skip the directory entry itself
      local lp = localOffset + 1
      if bytes:sub(lp, lp + 3) == "PK\3\4" then
        local lNameLen = u16(bytes, lp + 26)
        local lExtraLen = u16(bytes, lp + 28)
        local dataStart = lp + 30 + lNameLen + lExtraLen
        local raw = bytes:sub(dataStart, dataStart + compSize - 1)
        local entryData
        if method == 0 then
          entryData = raw -- stored, no compression at all
        elseif method == 8 then
          local ok, decompressed = pcall(love.data.decompress, "string", "deflate", raw)
          if ok and type(decompressed) == "string" then entryData = decompressed end
        end
        if entryData then
          out[#out + 1] = { name = name, data = entryData }
        end
      end
    end

    pos = pos + 46 + nameLen + extraLen + commentLen
  end

  return out
end

return DoomZipReader
