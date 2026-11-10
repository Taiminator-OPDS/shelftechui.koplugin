--[[
A book's bottom corners, rounded: an anti-aliased OUTER edge (the book against
the shelf) and INNER edge (its border against the cover), so the cover inside
rounds with the border instead of keeping a square corner inside a round one.

Each pixel of an r x r square at each corner is covered by the book's outer
disc (radius r) and by its inner one (radius r - bw, the border's width) by
some fraction, measured at the pixel centre and blended over one pixel. It
becomes

    inner * itself + (outer - inner) * border + (1 - outer) * shelf

where `shelf` is the row directly below the foot (whatever is painted there:
plank, design, shadow) and `border` is the book's own border beside the
corner. So the colours all come from the screen; nothing is computed.
]]
local Blitbuffer = require("ffi/blitbuffer")

local M = {}

M._cov = {}

-- coverage(r, bw) -> cov[j][i] = { outer, inner } for column i from the outer
-- edge and row j up from the foot, both 0-based; cached per (r, bw)
local function coverage(r, bw)
    local key = r .. "/" .. bw
    local c = M._cov[key]
    if c then return c end
    c = {}
    local ri = r - bw
    for j = 0, r - 1 do
        c[j] = {}
        for i = 0, r - 1 do
            local dx, dy = r - (i + 0.5), r - (j + 0.5)
            local d = math.sqrt(dx * dx + dy * dy)
            local outer = math.max(0, math.min(1, r - d + 0.5))
            local inner = ri > 0 and math.max(0, math.min(1, ri - d + 0.5)) or 0
            c[j][i] = { outer, inner }
        end
    end
    M._cov[key] = c
    return c
end

local function rgb(bb, x, y)
    local c = bb:getPixel(x, y):getColorRGB32()
    return c.r, c.g, c.b
end

-- apply(bb, x, foot, w, r, bw): round the bottom corners of the book at
-- [x, x+w) whose last row is foot - 1. Leaves the book alone when it is
-- narrower than two corners, or when the corner or the row below it is off
-- the buffer.
function M.apply(bb, x, foot, w, r, bw)
    if not bb or not r or r < 2 or not w or w < 2 * r then return end
    local W, H = bb:getWidth(), bb:getHeight()
    if foot - r < 0 or foot >= H then return end
    local cov = coverage(r, bw or 1)
    local set = Blitbuffer.ColorRGB32
    local function corner(edge, dir)             -- edge: outer column; dir +1 / -1
        local far = edge + dir * (r - 1)
        if math.min(edge, far) < 0 or math.max(edge, far) >= W then return end
        -- the border beside the corner, just above its square
        local br, bg, bb_ = rgb(bb, edge, foot - r - 1 >= 0 and foot - r - 1 or 0)
        for j = 0, r - 1 do
            local y = foot - 1 - j
            for i = 0, r - 1 do
                local px = edge + dir * i
                local o, n = cov[j][i][1], cov[j][i][2]
                if n < 1 then
                    local sr, sg, sb = rgb(bb, px, foot)      -- the shelf below
                    local cr, cg, cb = rgb(bb, px, y)
                    local m = o - n
                    bb:setPixel(px, y, set(
                        n * cr + m * br + (1 - o) * sr,
                        n * cg + m * bg + (1 - o) * sg,
                        n * cb + m * bb_ + (1 - o) * sb, 0xFF))
                end
            end
        end
    end
    corner(x, 1)
    corner(x + w - 1, -1)
end

return M
