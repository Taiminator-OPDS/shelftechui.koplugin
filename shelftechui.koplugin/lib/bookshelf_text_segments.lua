-- bookshelf_text_segments.lua
-- UTF-8 aware label segmentation for mixed text + icon labels.
--
-- Ordinary Unicode text (Latin-1, CJK, combining accents, punctuation) stays
-- in the text class so it can be bolded. Icon-like codepoints (Nerd Font PUA,
-- dingbats, emoji ranges) are isolated so renderers can leave them regular.

local Utf8Proc = require("ffi/utf8proc")
local util     = require("util")

local Segments = {}

-- UTF-8-aware uppercase. Lua's string.upper / :upper() only touches
-- ASCII bytes, so accented characters pass through unchanged --
-- "séries" uppercases to "SéRIES" instead of "SÉRIES" (issue #81).
-- Utf8Proc.uppercase_dumb uppercases each codepoint correctly;
-- util.fixUtf8 guards against malformed input (the same pattern
-- KOReader's util.lower uses for lowercasing).
-- An SVG/PNG icon in a label: "[icon=NAME]", as the icon picker inserts it
-- (and Bookends writes it). NAME is a file in KOReader's icons folder, so it
-- keeps its case: file names are case-sensitive on an e-reader.
local ICON_TOKEN = "%[icon=([^%]]+)%]"

function Segments.upper(str)
    if not str or str == "" then return str end
    if not str:find("[icon=", 1, true) then
        return Utf8Proc.uppercase_dumb(util.fixUtf8(str, "?"))
    end
    -- Upper-case around the icon tokens, never inside them.
    local out, pos = {}, 1
    while true do
        local s0, e0 = str:find(ICON_TOKEN, pos)
        if not s0 then break end
        if s0 > pos then out[#out + 1] = Utf8Proc.uppercase_dumb(util.fixUtf8(str:sub(pos, s0 - 1), "?")) end
        out[#out + 1] = str:sub(s0, e0)
        pos = e0 + 1
    end
    if pos <= #str then out[#out + 1] = Utf8Proc.uppercase_dumb(util.fixUtf8(str:sub(pos), "?")) end
    return table.concat(out)
end

local function isContinuation(byte)
    return byte and byte >= 0x80 and byte < 0xC0
end

local function decodeAt(str, index)
    local b1 = string.byte(str, index)
    if not b1 then return nil end
    if b1 < 0x80 then
        return 1, b1, true
    end
    if b1 < 0xC0 then
        return 1, b1, false
    end

    local b2 = string.byte(str, index + 1)
    if b1 < 0xE0 then
        if not isContinuation(b2) then return 1, b1, false end
        return 2, (b1 - 0xC0) * 0x40 + (b2 - 0x80), true
    end

    local b3 = string.byte(str, index + 2)
    if b1 < 0xF0 then
        if not isContinuation(b2) or not isContinuation(b3) then
            return 1, b1, false
        end
        return 3,
            (b1 - 0xE0) * 0x1000 + (b2 - 0x80) * 0x40 + (b3 - 0x80),
            true
    end

    local b4 = string.byte(str, index + 3)
    if b1 < 0xF8 then
        if not isContinuation(b2) or not isContinuation(b3) or not isContinuation(b4) then
            return 1, b1, false
        end
        return 4,
            (b1 - 0xF0) * 0x40000
                + (b2 - 0x80) * 0x1000
                + (b3 - 0x80) * 0x40
                + (b4 - 0x80),
            true
    end

    return 1, b1, false
end

function Segments.isIconCodepoint(cp)
    return (cp >= 0xE000 and cp <= 0xF8FF)       -- BMP private use: Nerd Font / MDI
        or (cp >= 0xF0000 and cp <= 0xFFFFD)     -- supplementary private use A
        or (cp >= 0x100000 and cp <= 0x10FFFD)   -- supplementary private use B
        or (cp >= 0x2600 and cp <= 0x27BF)       -- misc symbols / dingbats
        or (cp >= 0x1F000 and cp <= 0x1FAFF)     -- emoji and pictographs
end

function Segments.labelSegments(label)
    label = label or ""
    local segments = {}
    local current = nil
    local i = 1

    while i <= #label do
        -- "[icon=NAME]": an image segment of its own (see ICON_TOKEN).
        local ts, te, name = label:find("^" .. ICON_TOKEN, i)
        if ts then
            current = nil
            segments[#segments + 1] = { class = "image", name = name, text = label:sub(ts, te) }
            i = te + 1
            goto continue
        end
        do
        local chunk_len, codepoint, valid = decodeAt(label, i)
        chunk_len = chunk_len or 1
        local class = (not valid or Segments.isIconCodepoint(codepoint)) and "icon" or "text"
        local chunk = label:sub(i, i + chunk_len - 1)

        if current and current.class == class then
            current.text = current.text .. chunk
        else
            current = { class = class, text = chunk }
            segments[#segments + 1] = current
        end

        i = i + chunk_len
        end
        ::continue::
    end

    return segments
end

return Segments
