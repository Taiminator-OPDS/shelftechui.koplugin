--[[
The retro glyphs: small line icons drawn straight into the framebuffer with
square strokes, so they match the 2px outlines round them at any size and need
no image files. Each takes (bb, x, y, s, ink) and draws inside the s x s box.

  home search bookmark contents notebook pages stats picture pin
--]]

local Blitbuffer = require("ffi/blitbuffer")
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local G = {}

local WEIGHT = require("bos_theme").current().glyph or 1
local function stroke(s) return math.max(WEIGHT < 1 and 1 or 2, math.floor(s / 10 * WEIGHT + 0.5)) end

--- A line of thickness t from (x0,y0) to (x1,y1).
function G.line(bb, x0, y0, x1, y1, t, ink)
    x0, y0, x1, y1 = math.floor(x0 + 0.5), math.floor(y0 + 0.5), math.floor(x1 + 0.5), math.floor(y1 + 0.5)
    if x0 == x1 or y0 == y1 then
        local x, y = math.min(x0, x1), math.min(y0, y1)
        bb:paintRect(x, y, math.abs(x1 - x0) + t, math.abs(y1 - y0) + t, ink)
        return
    end
    local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
    local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
    local err = dx + dy
    while true do
        bb:paintRect(x0, y0, t, t, ink)
        if x0 == x1 and y0 == y1 then break end
        local e2 = 2 * err
        if e2 >= dy then err = err + dy; x0 = x0 + sx end
        if e2 <= dx then err = err + dx; y0 = y0 + sy end
    end
end

local function rectOutline(bb, x, y, w, h, t, ink)
    bb:paintRect(x, y, w, t, ink)
    bb:paintRect(x, y + h - t, w, t, ink)
    bb:paintRect(x, y, t, h, ink)
    bb:paintRect(x + w - t, y, t, h, ink)
end
G.rectOutline = rectOutline

function G.home(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local cx = x + s / 2
    G.line(bb, x + s * 0.08, y + s * 0.48, cx - t / 2, y + s * 0.12, t, ink)
    G.line(bb, cx - t / 2, y + s * 0.12, x + s * 0.92 - t, y + s * 0.48, t, ink)
    local bx, bw = math.floor(x + s * 0.22), math.floor(s * 0.56)
    local by = math.floor(y + s * 0.42)
    rectOutline(bb, bx, by, bw, math.floor(y + s * 0.9) - by, t, ink)
end

function G.search(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local r = s * 0.3
    local cx, cy = x + s * 0.4, y + s * 0.4
    -- a ring
    for a = 0, 359, 6 do
        local rad = math.rad(a)
        bb:paintRect(math.floor(cx + r * math.cos(rad) - t / 2 + 0.5), math.floor(cy + r * math.sin(rad) - t / 2 + 0.5), t, t, ink)
    end
    G.line(bb, cx + r * 0.72, cy + r * 0.72, x + s * 0.9 - t, y + s * 0.9 - t, t + 1, ink)
end

--- A ribbon; `filled` for a bookmarked page.
function G.bookmark(bb, x, y, s, ink, filled)
    ink = ink or BLACK
    local t = stroke(s)
    local w = math.floor(s * 0.62)
    local bx = x + math.floor((s - w) / 2)
    local top, bot = y + math.floor(s * 0.06), y + math.floor(s * 0.94)
    local notch = math.floor(s * 0.26)
    local mid = bx + math.floor(w / 2)
    if filled then
        for yy = top, bot do
            local inset = 0
            if yy > bot - notch then
                inset = math.floor((yy - (bot - notch)) * (w / 2) / notch)
                bb:paintRect(bx, yy, math.max(0, math.floor(w / 2) - inset), 1, ink)
                bb:paintRect(mid + inset, yy, math.max(0, bx + w - mid - inset), 1, ink)
            else
                bb:paintRect(bx, yy, w, 1, ink)
            end
        end
    else
        bb:paintRect(bx, top, w, t, ink)
        bb:paintRect(bx, top, t, bot - top, ink)
        bb:paintRect(bx + w - t, top, t, bot - top, ink)
        G.line(bb, bx, bot - t, mid - t / 2, bot - notch, t, ink)
        G.line(bb, mid - t / 2, bot - notch, bx + w - t, bot - t, t, ink)
    end
end

function G.contents(bb, x, y, s, ink)
    ink = ink or BLACK
    local d = math.max(3, math.floor(s * 0.16))
    local lh = math.max(2, math.floor(s * 0.11))
    for i = 0, 2 do
        local yy = y + math.floor(s * 0.12) + i * math.floor(s * 0.32)
        bb:paintRect(x, yy, d, d, ink)
        bb:paintRect(x + d + math.floor(s * 0.16), yy + math.floor((d - lh) / 2), s - d - math.floor(s * 0.16), lh, ink)
    end
end

function G.notebook(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local w = math.floor(s * 0.86)
    local bx = x + math.floor((s - w) / 2)
    rectOutline(bb, bx, y + math.floor(s * 0.05), w, math.floor(s * 0.9), t, ink)
    local lx = bx + math.floor(w * 0.24)
    local lw = math.floor(w * 0.52)
    for i, f in ipairs{ 1, 1, 0.62 } do
        bb:paintRect(lx, y + math.floor(s * (0.12 + 0.2 * i)), math.floor(lw * f), t, ink)
    end
end

function G.pages(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local pw = math.floor(s * 0.38)
    local px = x + math.floor((s - pw) / 2)
    rectOutline(bb, px, y + math.floor(s * 0.04), pw, math.floor(s * 0.92), t, ink)
    local by, bh = y + math.floor(s * 0.16), math.floor(s * 0.68)
    local bw = math.floor(s * 0.14)
    -- the neighbours, half seen
    bb:paintRect(x, by, bw, t, ink); bb:paintRect(x + bw - t, by, t, bh, ink); bb:paintRect(x, by + bh - t, bw, t, ink)
    local rx = x + s - bw
    bb:paintRect(rx, by, bw, t, ink); bb:paintRect(rx, by, t, bh, ink); bb:paintRect(rx, by + bh - t, bw, t, ink)
end

function G.stats(bb, x, y, s, ink)
    ink = ink or BLACK
    local bw = math.floor(s * 0.2)
    local gap = math.floor((s - 3 * bw) / 2)
    for i, f in ipairs{ 0.45, 0.7, 0.95 } do
        local h = math.floor(s * f)
        bb:paintRect(x + (i - 1) * (bw + gap), y + s - h, bw, h, ink)
    end
end

--- A picture: a frame with a hill and a sun (Glimpse).
function G.picture(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local fy, fh = y + math.floor(s * 0.12), math.floor(s * 0.76)
    rectOutline(bb, x, fy, s, fh, t, ink)
    local by = fy + fh - t
    G.line(bb, x + t, by - math.floor(s * 0.08), x + math.floor(s * 0.38), fy + math.floor(fh * 0.42), t, ink)
    G.line(bb, x + math.floor(s * 0.38), fy + math.floor(fh * 0.42), x + math.floor(s * 0.62), by - math.floor(s * 0.18), t, ink)
    G.line(bb, x + math.floor(s * 0.55), by - math.floor(s * 0.12), x + math.floor(s * 0.72), fy + math.floor(fh * 0.6), t, ink)
    G.line(bb, x + math.floor(s * 0.72), fy + math.floor(fh * 0.6), x + s - 2 * t, by - math.floor(s * 0.08), t, ink)
    local d = math.max(3, math.floor(s * 0.16))
    bb:paintRect(x + s - math.floor(s * 0.3), fy + math.floor(fh * 0.18), d, d, ink)
end

--- A push pin.
function G.pin(bb, x, y, s, ink)
    ink = ink or BLACK
    local t = stroke(s)
    local hw = math.floor(s * 0.5)
    local hx = x + math.floor((s - hw) / 2)
    bb:paintRect(hx, y + math.floor(s * 0.06), hw, math.floor(s * 0.3), ink)
    bb:paintRect(x + math.floor(s * 0.14), y + math.floor(s * 0.36), s - 2 * math.floor(s * 0.14), t, ink)
    bb:paintRect(x + math.floor(s / 2) - math.floor(t / 2), y + math.floor(s * 0.36), t, math.floor(s * 0.6), ink)
end

G.BLACK, G.WHITE = BLACK, WHITE
return G
