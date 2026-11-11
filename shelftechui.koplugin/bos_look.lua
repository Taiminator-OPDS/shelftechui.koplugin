--[[
ShelfTechUI's design language, in one place: the "retro tech" Bookshelf look
every screen is drawn with.

  type      Bookshelf's own faces for text people read; the monospaced
            "infont" in bold capitals for chrome (tabs, labels, buttons,
            numbers)
  boxes     square corners, a 2px black outline, a hard black shadow
            down and to the right (no soft grey, no rounding)
  titles    a pinstriped strip with a close box (Retro.TitleStrip)
  fills     pinstripes for a filled part (progress, brightness)
  handles   a square handle that sits on its shadow, and drops onto it
            (black) while held
  pressed   black, pushed down onto the shadow

Every primitive follows the theme in use (bos_theme): its type, frames,
shadows, bands, tracks and handles. The descriptions above are Retro's; the
other themes swap each part for their own.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local Theme = require("bos_theme")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local L = {}

local function S(v) return Screen:scaleBySize(v) end
L.S = S

local th = Theme.current()
L.theme = th

L.BLACK, L.WHITE = BLACK, WHITE
L.GRAY = Blitbuffer.COLOR_DARK_GRAY
L.MID = Blitbuffer.COLOR_GRAY_9
L.LIGHT = Blitbuffer.COLOR_LIGHT_GRAY
L.INK = th.ink                      -- outlines
L.PAPER = th.paper                  -- a box's fill
L.PRESS = th.press                  -- a pressed or "on" key

L.LINE = math.max(1, math.floor(S(th.line == 0 and 1 or th.line) + 0.5))  -- outlines
L.THIN = math.max(1, S(1.5))        -- separators inside a strip
L.SHADOW = S(4)                     -- room for the shadow of a panel or a card
L.SHADOW_SMALL = S(3)               -- of a button or a tile
L.RADIUS = (th.frame == "round" or th.frame == "stitched") and S(th.radius) or 0  -- KOReader frames' corners

local PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$") or ".")
local FONT_DIR = PLUGIN_DIR .. "/fonts"

-- The theme's fonts live in the plugin's fonts/: KOReader's Font:getFace
-- resolves them by file name like its own (so KOReader's widgets can name
-- them), and never emboldens them (they come in the weight they're meant to
-- be seen in).
local lfs = require("libs/libkoreader-lfs")
local ours = {}
local function isOurs(name)
    if type(name) ~= "string" or name:find("/", 1, true) then return false end
    local hit = ours[name]
    if hit == nil then
        hit = name:match("%.[ot]tf$") ~= nil and lfs.attributes(FONT_DIR .. "/" .. name, "mode") == "file"
        ours[name] = hit
    end
    return hit
end

if not Font._stui_themed then
    Font._stui_themed = true
    local orig = Font.getFace
    Font.getFace = function(self, font, size, faceindex)
        local real = (font and self.fontmap[font]) or font
        if not isOurs(real) then return orig(self, font, size, faceindex) end
        local FontList = require("fontlist")
        local old = FontList.fontdir
        FontList.fontdir = FONT_DIR
        local ok, f = pcall(orig, self, font, size, faceindex)
        FontList.fontdir = old
        if ok and f then
            f.is_real_bold = true
            return f
        end
        return orig(self, "cfont", size)
    end
    -- the controls' face, everywhere KOReader's widgets ask for "infont"
    -- (every screen the retro skin restyled sets its controls in it)
    if th.chrome ~= "infont" then
        Font.fontmap.infont = th.chrome
        Font.fontmap.smallinfont = th.chrome
    end
end

--- A face from the plugin's fonts/ (or KOReader's own), at `size`.
function L.face(file, size)
    local ok, f = pcall(Font.getFace, Font, file, size)
    if ok and f then return f end
    return Font:getFace("cfont", size)
end

--- The face for controls (Retro: KOReader's monospaced "infont").
function L.mono(size)
    return Font:getFace("infont", size)
end

--- The theme's reading-UI face (lists, rows, dialogs, Bookshelf's home), or
--- nil to keep Bookshelf's own font (Retro).
function L.text(size, bold, italic)
    local s = th.text
    if not s then return nil end
    local file = bold and (italic and s.bolditalic or s.bold) or (italic and s.italic or s.regular)
    return L.face(file or s.regular, size)
end

-- KOReader's widgets take a face by name: "stui_chrome" and "stui_text" are
-- the theme's (screens restyled by ShelfTechUI ask for these).
do
    if not Font._stui_hooked then
        Font._stui_hooked = true
        local orig = Font.getFace
        Font.getFace = function(self, font, size, faceindex)
            if font == "stui_chrome" then
                return L.mono(size or 20)
            elseif font == "stui_text" then
                return L.text(size or 20) or orig(self, "cfont", size, faceindex)
            end
            return orig(self, font, size, faceindex)
        end
    end
end

--- The book-title face (Retro: Noto Serif, KOReader's own), falling back to
--- the UI font where a build doesn't carry it.
function L.serif(size, bold, italic)
    if th.serif then
        local s = th.serif
        local file = bold and (italic and s.bolditalic or s.bold) or (italic and s.italic or s.regular)
        return L.face(file or s.regular, size)
    end
    local name = bold and (italic and "NotoSerif-BoldItalic.ttf" or "NotoSerif-Bold.ttf")
        or (italic and "NotoSerif-Italic.ttf" or "NotoSerif-Regular.ttf")
    local ok, face = pcall(Font.getFace, Font, name, size)
    if ok and face then return face end
    return Font:getFace(bold and "tfont" or "cfont", size)
end

local function tw(text, face, color, max_w, bold)
    return TextWidget:new{ text = text or "", face = face, fgcolor = color or BLACK, bold = bold ~= false,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil }
end

--- Text as the theme sets controls: capitals or as written.
function L.case(text)
    text = tostring(text or "")
    return th.upper and text:upper() or text
end

function L.textWidth(text, size, bold)
    local t = tw(text, L.mono(size), nil, nil, bold)
    local w = t:getSize().w
    t:free()
    return w
end

--- Control text in the box x,y,w,h; align "left" | "center" | "right".
function L.label(bb, text, x, y, w, h, size, opts)
    opts = opts or {}
    local s = opts.keep_case and text or L.case(text)
    local t = tw(s, L.mono(size or 13), opts.color, math.max(1, w), opts.bold)
    local sz = t:getSize()
    local tx = x
    if opts.align == "center" then tx = x + math.floor((w - sz.w) / 2)
    elseif opts.align == "right" then tx = x + w - sz.w end
    t:paintTo(bb, tx, y + math.floor((h - sz.h) / 2))
    t:free()
    return sz.w
end

-- ------------------------------------------------------------ small drawing

local function outline(bb, x, y, w, h, t, c)
    bb:paintRect(x, y, w, t, c)
    bb:paintRect(x, y + h - t, w, t, c)
    bb:paintRect(x, y, t, h, c)
    bb:paintRect(x + w - t, y, t, h, c)
end
L.outline = outline

local function dashedH(bb, x, y, w, t, c)
    local d, g = S(4), S(3)
    for xx = x, x + w - 1, d + g do bb:paintRect(xx, y, math.min(d, x + w - xx), t, c) end
end
local function dashedV(bb, x, y, h, t, c)
    local d, g = S(4), S(3)
    for yy = y, y + h - 1, d + g do bb:paintRect(x, yy, t, math.min(d, y + h - yy), c) end
end
L.dashedH, L.dashedV = dashedH, dashedV

--- A filled diamond centred on cx, cy (half-diagonal r).
local function diamond(bb, cx, cy, r, c)
    for dy = -r, r do
        local half = r - math.abs(dy)
        bb:paintRect(cx - half, cy + dy, 2 * half + 1, 1, c)
    end
end
L.diamond = diamond

local function disc(bb, cx, cy, r, c)
    for dy = -r, r do
        local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        bb:paintRect(cx - half, cy + dy, 2 * half, 1, c)
    end
end
L.disc = disc

-- ------------------------------------------------------------ bands and fills

--- The theme's band: the decoration in a title strip's free room (Retro:
--- pinstripes).
function L.stripes(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    local c = color or th.ink
    local line = math.max(1, S(1))
    local mid = y + math.floor(h / 2)
    local b = th.band
    if b == "stripes" then
        for yy = y, y + h - line, S(3) do bb:paintRect(x, yy, w, line, color or BLACK) end
    elseif b == "double" then
        bb:paintRect(x, mid - S(3), w, line, c)
        bb:paintRect(x, mid + S(2), w, line, c)
        diamond(bb, x + math.floor(w / 2), mid, S(5), WHITE)
        diamond(bb, x + math.floor(w / 2), mid, S(4), c)
        diamond(bb, x + math.floor(w / 2), mid, S(2), WHITE)
    elseif b == "ticks" then
        for xx = x, x + w - line, S(6) do bb:paintRect(xx, y + math.floor(h * 0.2), line, h - 2 * math.floor(h * 0.2), c) end
    elseif b == "dashed" then
        dashedH(bb, x, mid, w, math.max(1, S(2)), L.MID)
    elseif b == "rule" then
        bb:paintRect(x, mid, w, line, c)
    end
end

--- A bar's empty part (Retro: pinstripes).
function L.fill(bb, x, y, w, h)
    if w <= 0 or h <= 0 then return end
    local f = th.fill
    if f == "stripes" then
        local line = math.max(1, S(1))
        for yy = y, y + h - line, S(3) do bb:paintRect(x, yy, w, line, BLACK) end
    elseif f == "segments" then
        for xx = x, x + w - 1, S(7) do bb:paintRect(xx, y, math.min(S(5), x + w - xx), h, L.LIGHT) end
    elseif f == "hatch" then
        for xx = x, x + w - 1, S(4) do bb:paintRect(xx, y, math.min(S(2), x + w - xx), h, L.LIGHT) end
    else
        bb:paintRect(x, y, w, h, Blitbuffer.COLOR_GRAY_D)
    end
end

-- ------------------------------------------------------------ boxes

--- The shadow under a box at x,y,w,h, `sh` deep, in the theme's way.
function L.shadow(bb, x, y, w, h, sh, color)
    if not sh or sh <= 0 then return end
    local s = th.shadow
    if s == "hard" then
        if th.frame == "stitched" then
            bb:paintRoundedRect(x + sh, y + sh, w, h, color or th.shade, S(th.radius))
        else
            bb:paintRect(x + sh, y + sh, w, h, color or th.shade)
        end
    elseif s == "soft" then
        bb:paintRoundedRect(x, y + sh, w, h, th.shade, S(th.radius))
    elseif s == "pages" then
        -- the page block: leaves behind, edge by edge
        for k = sh, 1, -1 do
            bb:paintRect(x + k, y + k, w, h, k % 2 == 1 and th.shade or WHITE)
        end
    end
end

--- A box: outline, fill, and the theme's shadow.
--- opts: border, fill, color, shadow
function L.box(bb, x, y, w, h, opts)
    opts = opts or {}
    local b = opts.border or L.LINE
    local sh = opts.shadow or 0
    -- white and black (as every screen asks) are the theme's paper and press
    local fill = opts.fill or th.paper
    if fill == WHITE then fill = th.paper elseif fill == BLACK then fill = th.press end
    local c = opts.color or th.ink
    if c == BLACK then c = th.ink end
    local f = th.frame
    if sh > 0 then L.shadow(bb, x, y, w, h, sh) end
    if f == "round" or f == "stitched" then
        local r = math.min(S(th.radius), math.floor(math.min(w, h) / 2))
        if b > 0 then
            bb:paintRoundedRect(x, y, w, h, c, r)
            bb:paintRoundedRect(x + b, y + b, w - 2 * b, h - 2 * b, fill, math.max(0, r - b))
        else
            bb:paintRoundedRect(x, y, w, h, fill, r)
        end
        if f == "stitched" and w > S(24) and h > S(20) then
            local i = b + S(3)
            local sc = fill == th.paper and L.MID or WHITE
            dashedH(bb, x + i + S(3), y + i, w - 2 * i - S(6), 1, sc)
            dashedH(bb, x + i + S(3), y + h - i - 1, w - 2 * i - S(6), 1, sc)
            dashedV(bb, x + i, y + i + S(3), h - 2 * i - S(6), 1, sc)
            dashedV(bb, x + w - i - 1, y + i + S(3), h - 2 * i - S(6), 1, sc)
        end
        return
    end
    if b > 0 then
        bb:paintRect(x, y, w, h, c)
        bb:paintRect(x + b, y + b, w - 2 * b, h - 2 * b, fill)
        if f == "double" and b >= 3 then
            -- an engraved double rule: line, gap, line
            outline(bb, x + 1, y + 1, w - 2, h - 2, b - 2, fill)
        elseif f == "brackets" and w > S(20) and h > S(14) then
            local k, t = math.min(S(12), math.floor(w / 3)), math.max(2, S(3))
            for _i, p in ipairs{ { x, y, 1, 1 }, { x + w, y, -1, 1 }, { x, y + h, 1, -1 }, { x + w, y + h, -1, -1 } } do
                local px, py, sx, sy = p[1], p[2], p[3], p[4]
                bb:paintRect(sx > 0 and px or px - k, sy > 0 and py or py - t, k, t, c)
                bb:paintRect(sx > 0 and px or px - t, sy > 0 and py or py - k, t, k, c)
            end
        end
    else
        bb:paintRect(x, y, w, h, fill)
    end
end

--- Over a frame KOReader drew itself (a plain outline, `b` thick): the
--- theme's details (Fantasy's double rule, Sci-fi's corner brackets,
--- Rustic's stitching).
function L.decorate(bb, x, y, w, h, b)
    b = b or L.LINE
    local f = th.frame
    if f == "double" and b >= 3 then
        outline(bb, x + 1, y + 1, w - 2, h - 2, b - 2, WHITE)
    elseif f == "brackets" and w > S(20) and h > S(14) then
        local k, t = math.min(S(12), math.floor(w / 3)), math.max(2, S(3))
        local c = th.ink
        bb:paintRect(x, y, k, t, c) bb:paintRect(x, y, t, k, c)
        bb:paintRect(x + w - k, y, k, t, c) bb:paintRect(x + w - t, y, t, k, c)
        bb:paintRect(x, y + h - t, k, t, c) bb:paintRect(x, y + h - k, t, k, c)
        bb:paintRect(x + w - k, y + h - t, k, t, c) bb:paintRect(x + w - t, y + h - k, t, k, c)
    elseif f == "stitched" and w > S(24) and h > S(20) then
        local i = b + S(3)
        dashedH(bb, x + i + S(3), y + i, w - 2 * i - S(6), 1, L.MID)
        dashedH(bb, x + i + S(3), y + h - i - 1, w - 2 * i - S(6), 1, L.MID)
        dashedV(bb, x + i, y + i + S(3), h - 2 * i - S(6), 1, L.MID)
        dashedV(bb, x + w - i - 1, y + i + S(3), h - 2 * i - S(6), 1, L.MID)
    end
end

--- A button with the theme's shadow; pressed (`down`): filled, pushed onto
--- its shadow. `label` (control text) or `paint(bb, x, y, w, h, ink)`.
--- Returns the rect it answers to (shadow included).
function L.button(bb, x, y, w, h, label, opts)
    opts = opts or {}
    local enabled = opts.enabled ~= false
    local down = opts.down
    local on = opts.on -- a toggle that's on: filled, still raised
    local sh = opts.shadow or L.SHADOW_SMALL
    local o = (down and th.shadow == "hard") and sh or 0
    L.box(bb, x + o, y + o, w, h, { shadow = (enabled and not down) and sh or 0,
        fill = (down or on) and th.press or th.paper, color = enabled and th.ink or L.LIGHT, border = opts.border })
    if th.frame == "page" and not (down or on) and w > S(30) and h > S(24) then
        -- a dog-eared corner
        local d = S(9)
        for i = 0, d - 1 do
            bb:paintRect(x + o + w - d + i, y + o + 1, d - i, 1, WHITE)
            bb:paintRect(x + o + w - d, y + o + 1 + i, i + 1, 1, L.LIGHT)
        end
        bb:paintRect(x + o + w - d, y + o + 1, 1, d, th.ink)
        bb:paintRect(x + o + w - d, y + o + d, d, 1, th.ink)
    end
    local ink = (down or on) and WHITE or (enabled and BLACK or L.MID)
    if opts.paint then
        opts.paint(bb, x + o, y + o, w, h, ink)
    elseif label then
        L.label(bb, label, x + o + S(4), y + o, w - S(8), h, opts.size or 14,
            { align = "center", color = ink, keep_case = opts.keep_case })
    end
    return Geom:new{ x = x, y = y, w = w + sh, h = h + sh }
end

--- A panel's edge across the screen at y (`dir` 1: the panel is above and
--- its edge faces down; -1: below, facing up), `sh` deep. Retro: a rule and
--- a hard black band.
function L.edge(bb, x, y, w, dir, sh)
    local t = th.frame == "double" and 1 or L.LINE
    local c = th.ink
    local s = th.shadow
    local ry = dir > 0 and (y - t) or y
    bb:paintRect(x, ry, w, t, c)
    if th.frame == "double" then
        bb:paintRect(x, dir > 0 and (y - S(4)) or (y + S(3)), w, 1, c)
    end
    if s == "hard" then
        bb:paintRect(x, dir > 0 and y or (y - sh), w, sh, th.shade)
    elseif s == "soft" then
        bb:paintRect(x, dir > 0 and y or (y - S(3)), w, S(3), th.shade)
    elseif s == "pages" then
        for k = 1, S(6) do
            bb:paintRect(x, dir > 0 and (y + k - 1) or (y - k), w, 1, k % 3 == 0 and th.shade or WHITE)
        end
    elseif th.frame == "brackets" then
        bb:paintRect(x, dir > 0 and (y + S(2)) or (y - S(3)), w, 1, c)
    end
end

-- ------------------------------------------------------------ tracks

local function knobShape(bb, cx, cy, held, big)
    local k = th.knob
    if k == "round" then
        local r = big and S(13) or S(11)
        disc(bb, cx, cy, r, held and th.press or th.ink)
        if not held then disc(bb, cx, cy, r - math.max(2, S(1.5)), th.paper) end
    elseif k == "diamond" then
        local r = big and S(10) or S(9)
        diamond(bb, cx, cy, r, th.ink)
        if not held then diamond(bb, cx, cy, r - S(2), WHITE) end
    elseif k == "bar" then
        local h = big and S(30) or S(24)
        bb:paintRect(cx - S(2), cy - math.floor(h / 2), S(4), h, held and L.GRAY or BLACK)
    elseif k == "ribbon" then
        local w, h = S(12), big and S(32) or S(28)
        local x0, y0 = cx - math.floor(w / 2), cy - S(6)
        local notch = S(7)
        for yy = 0, h - 1 do
            if yy < h - notch then
                bb:paintRect(x0, y0 + yy, w, 1, held and L.GRAY or BLACK)
            else
                local cut = math.floor((yy - (h - notch)) * (w / 2) / notch)
                bb:paintRect(x0, y0 + yy, math.floor(w / 2) - cut, 1, held and L.GRAY or BLACK)
                bb:paintRect(x0 + math.floor(w / 2) + cut, y0 + yy, w - math.floor(w / 2) - cut, 1, held and L.GRAY or BLACK)
            end
        end
    else
        return false
    end
    return true
end

--- The track's body at x,y,w,h, filled to `fw` px. Returns nothing.
local function trackBody(bb, x, y, w, h, fw, b)
    local tk = th.track
    local cy = y + math.floor(h / 2)
    if tk == "pill" then
        local ph = math.min(h, S(6))
        bb:paintRoundedRect(x, cy - math.floor(ph / 2), w, ph, Blitbuffer.COLOR_GRAY_D, math.floor(ph / 2))
        if fw > 0 then bb:paintRoundedRect(x, cy - math.floor(ph / 2), math.max(ph, fw), ph, BLACK, math.floor(ph / 2)) end
    elseif tk == "line" or tk == "ribbon" then
        local lh = tk == "line" and math.max(2, S(3)) or 1
        bb:paintRect(x, cy - math.floor(lh / 2), w, lh, tk == "line" and L.LIGHT or th.ink)
        if fw > 0 then bb:paintRect(x, cy - math.floor(S(3) / 2), fw, S(3), BLACK) end
    elseif tk == "segments" then
        local sh = math.min(h, S(10))
        local sy = cy - math.floor(sh / 2)
        outline(bb, x, sy, w, sh, 1, th.ink)
        for xx = x + S(2), x + w - S(3), S(7) do
            bb:paintRect(xx, sy + S(2), math.min(S(5), x + w - S(2) - xx), sh - S(4), (xx < x + fw) and BLACK or L.LIGHT)
        end
    elseif tk == "groove" then
        local gh = math.min(h, th.frame == "stitched" and S(12) or S(6))
        local gy = cy - math.floor(gh / 2)
        if th.frame == "stitched" then
            bb:paintRoundedRect(x, gy, w, gh, th.ink, S(6))
            bb:paintRoundedRect(x + S(2), gy + S(2), w - S(4), gh - S(4), WHITE, S(4))
            L.fill(bb, x + S(2), gy + S(2), w - S(4), gh - S(4))
            if fw > 0 then bb:paintRoundedRect(x + S(2), gy + S(2), math.max(S(4), fw - S(2)), gh - S(4), th.press, S(4)) end
        else
            bb:paintRoundedRect(x, gy, w, gh, L.LIGHT, math.floor(gh / 2))
            if fw > 0 then bb:paintRoundedRect(x, gy, math.max(gh, fw), gh, th.press, math.floor(gh / 2)) end
        end
    else
        -- retro: a framed pinstriped bar, filled black
        L.box(bb, x, y, w, h, { border = b })
        L.fill(bb, x + b, y + b + 1, w - 2 * b, h - 2 * b - 2)
        if fw > 0 then bb:paintRect(x + b, y + b, math.min(fw, w - 2 * b), h - 2 * b, BLACK) end
    end
end

--- A track with a filled part, as far as `frac`. Returns the inner x and
--- width (for hit testing).
function L.track(bb, x, y, w, h, frac, opts)
    opts = opts or {}
    local b = opts.border or L.LINE
    frac = math.max(0, math.min(1, frac or 0))
    if th.track == "stripes" then
        L.box(bb, x, y, w, h, { border = b })
        local ix, iw = x + b, w - 2 * b
        local fw = math.floor(iw * frac + 0.5)
        if fw > 0 then
            local pad = math.max(1, S(2))
            L.fill(bb, ix, y + b + pad, fw, h - 2 * b - 2 * pad)
        end
        return ix, iw
    end
    trackBody(bb, x, y, w, h, math.floor(w * frac + 0.5), b)
    return x, w
end

--- The handle on a track, centred on cx, cy (Retro: a square on its shadow,
--- black and dropped onto it while held).
function L.handle(bb, cx, cy, h, held)
    if knobShape(bb, cx, cy, held, true) then return end
    local w = math.max(S(14), math.floor(h * 0.62))
    local sh = L.SHADOW_SMALL
    local x, y = cx - math.floor(w / 2), cy - math.floor(h / 2)
    local o = held and sh or 0
    L.box(bb, x + o, y + o, w, h, { shadow = held and 0 or sh, fill = held and BLACK or WHITE })
    -- a grip: three short lines
    local ink = held and WHITE or BLACK
    local gl = math.floor(w * 0.45)
    for i = -1, 1 do
        bb:paintRect(x + o + math.floor((w - gl) / 2), y + o + math.floor(h / 2) + i * S(4), gl, math.max(1, S(1)), ink)
    end
end

--- The small handle on a slim track.
function L.knob(bb, cx, cy, held)
    if knobShape(bb, cx, cy, held, false) then return end
    local w, h = S(16), S(20)
    local sh = S(2)
    local x, y = cx - math.floor(w / 2), cy - math.floor(h / 2)
    local o = held and sh or 0
    L.box(bb, x + o, y + o, w, h, { shadow = held and 0 or sh, fill = held and BLACK or WHITE })
end

--- A slim progress track, filled as far as `frac`, with chapter ticks
--- standing through it and the knob (`held` nil: no knob). ticks: list of x
--- positions. Returns the inner x and width.
function L.slimTrack(bb, x, y, w, h, frac, ticks, held, origin_x)
    local b = L.LINE
    local stripes = th.track == "stripes"
    local ix, iw = stripes and x + b or x, stripes and w - 2 * b or w
    local fw = math.floor(iw * math.max(0, math.min(1, frac)) + 0.5)
    trackBody(bb, x, y, w, h, stripes and fw or fw, b)
    local tw = (th.line <= 1) and 1 or math.max(2, S(2))
    local ext = (th.track == "pill" or th.track == "groove") and 0 or S(3)
    for _i, tx in ipairs(ticks or {}) do
        if th.track == "pill" then
            bb:paintRect(tx - math.floor(tw / 2), y + math.floor(h / 2) - S(3), math.max(2, S(2)), S(6), WHITE)
        else
            bb:paintRect(tx - math.floor(tw / 2), y - ext, tw, h + 2 * ext, th.ink)
        end
    end
    if origin_x then bb:paintRect(origin_x - 1, y - S(6), math.max(2, S(2)), h + S(12), BLACK) end
    if held ~= nil then L.knob(bb, ix + fw, y + math.floor(h / 2), held) end
    return ix, iw
end

--- Segmented tabs (a frame, thin separators, control text; the selected or
--- pressed cell filled). cells: { key, text | paint(bb, r, sel) }.
--- Returns { key = rect } and the list of rects in order.
function L.segments(bb, x, y, w, h, cells, selected, opts)
    opts = opts or {}
    local b = opts.border or L.LINE
    local sep = L.THIN
    L.box(bb, x, y, w, h, { border = b, shadow = opts.shadow })
    local n = #cells
    local fixed, n_flex = 0, 0
    for _i, c in ipairs(cells) do
        if c.width then fixed = fixed + c.width else n_flex = n_flex + 1 end
    end
    local free = w - 2 * b - (n - 1) * sep - fixed
    local cw = n_flex > 0 and math.floor(free / n_flex) or 0
    -- one size for all: shrink until the longest label fits
    local size = opts.size or 13
    for _i = 1, 6 do
        local fits = true
        for _j, c in ipairs(cells) do
            if c.text and not c.width and L.textWidth(L.case(c.text), size) > cw - S(8) then
                fits = false break
            end
        end
        if fits or size <= 9 then break end
        size = size - 1
    end
    local by_key, list = {}, {}
    local cx = x + b
    for i, c in ipairs(cells) do
        local this_w = c.width or cw
        if i == n then this_w = x + w - b - cx end
        local r = Geom:new{ x = cx, y = y + b, w = this_w, h = h - 2 * b }
        local sel = (c.key ~= nil and c.key == selected) or c.selected or (opts.pressed ~= nil and opts.pressed == c.key)
        if sel then bb:paintRect(r.x, r.y, r.w, r.h, th.press) end
        local ink = sel and WHITE or (c.enabled == false and L.MID or BLACK)
        if c.paint then
            c.paint(bb, r, sel, ink)
        elseif c.text then
            L.label(bb, c.text, r.x + S(3), r.y, r.w - S(6), r.h, c.size or size,
                { align = "center", color = ink, keep_case = c.keep_case })
        end
        if c.key ~= nil then by_key[c.key] = r end
        list[i] = r
        cx = cx + this_w
        if i < n then
            bb:paintRect(cx, y + b, sep, h - 2 * b, th.ink)
            cx = cx + sep
        end
    end
    return by_key, list
end

--- A section heading: grey control text, a dotted leader to the right edge
--- (or to a value on the right).
function L.heading(bb, text, x, y, w, h, right)
    local tw_ = L.label(bb, text, x, y, w, h, 12, { color = L.GRAY })
    local rw = 0
    if right then rw = L.label(bb, right, x, y, w, h, 12, { align = "right" }) + S(10) end
    local d = math.max(1, S(1.5))
    local ly = y + math.floor(h / 2) + S(1)
    for dx = x + tw_ + S(10), x + w - rw - d, S(5) do bb:paintRect(dx, ly, d, d, L.MID) end
end


return L
