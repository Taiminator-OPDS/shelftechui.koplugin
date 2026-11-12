--[[
A full-screen retro page: the header ‹ [CAPTION] ⋯ over pinstripes, and a body
the page draws itself. Drawing registers what can be tapped (Page:hit), so a
page is a draw function and nothing else. The book, series, author and online
pages are built on it.

    local Page = require("bos_page")
    local p = Page:new{ caption = "Book", draw = function(self, bb, y0) ... end,
                        on_more = function(self, rect) ... end, on_swipe = function(self, dir) end }
    p:show()

Helpers for page bodies: Page.coverRow (a row of covers on a line shelf),
Page.chips (wrapped chips), Page.stars, Page.wrap (text in lines).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Look = require("bos_look")
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local S = Look.S

local Page = InputContainer:extend{
    name = "stui_page",
    covers_fullscreen = true,
    caption = "",
    draw = nil,       -- function(self, bb, y0, w)
    on_more = nil,    -- function(self, rect): the ⋯ key (none without)
    on_swipe = nil,   -- function(self, "west"|"east")
    on_close = nil,
}

Page.HEADER_H = S(44)

function Page:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.pad = S(16)
    local all = function() return self.dimen end
    self.ges_events = {
        PageTap = { GestureRange:new{ ges = "tap", range = all } },
        PageHold = { GestureRange:new{ ges = "hold", range = all } },
        PageSwipe = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function Page:getSize() return self.dimen end

--- Something tappable on the page: `fn(self)` on tap, `hold(self)` on hold.
function Page:hit(rect, fn, hold, key)
    table.insert(self.hits, { rect = rect, fn = fn, hold = hold, key = key })
end

function Page:paintTo(bb, x, y)
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.hits = {}
    bb:paintRect(0, 0, W, H, WHITE)
    -- ‹  ═══ [CAPTION] ═══  ⋯
    local hh = Page.HEADER_H
    local kw = S(40)
    Look.label(bb, "\u{2039}", S(6), 0, kw, hh, 22, { align = "center" })
    self:hit(Geom:new{ x = 0, y = 0, w = kw + S(14), h = hh }, function(p) p:onClose() end)
    local rx = W - S(6) - kw
    if self.on_more then
        Look.label(bb, "\u{22EF}", rx, 0, kw, hh, 18, { align = "center" })
        self:hit(Geom:new{ x = rx - S(8), y = 0, w = kw + S(14), h = hh }, function(p) p.on_more(p, Geom:new{ x = rx, y = 0, w = kw, h = hh }) end)
    end
    local sx0, sx1 = S(6) + kw + S(8), rx - S(8)
    Look.stripes(bb, sx0, math.floor((hh - S(20)) / 2), sx1 - sx0, S(20))
    local cap = require("bos_look").case(tostring(self.caption or ""))
    local cw = Look.textWidth(cap, 11) + S(18)
    local cx = sx0 + math.floor((sx1 - sx0 - cw) / 2)
    Look.box(bb, cx, math.floor((hh - S(24)) / 2), cw, S(24))
    Look.label(bb, cap, cx, math.floor((hh - S(24)) / 2), cw, S(24), 11, { align = "center" })
    bb:paintRect(0, hh - Look.LINE, W, Look.LINE, BLACK)
    if self.draw then
        local ok, err = pcall(self.draw, self, bb, hh + S(12), W - 2 * self.pad)
        if not ok then logger.warn("ShelfTechUI: page draw:", err) end
    end
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end
Page.inside = inside

function Page:onPageTap(_, ges)
    for i = #(self.hits or {}), 1, -1 do
        local h = self.hits[i]
        if h.fn and inside(ges.pos, h.rect) then
            if h.key then
                self.pressed = h.key
                self:refresh("fast", h.rect)
                UIManager:forceRePaint()
                self.pressed = nil
            end
            h.fn(self)
            return true
        end
    end
    return true
end

function Page:onPageHold(_, ges)
    for i = #(self.hits or {}), 1, -1 do
        local h = self.hits[i]
        if h.hold and inside(ges.pos, h.rect) then h.hold(self) return true end
    end
    return true
end

function Page:onPageSwipe(_, ges)
    if self.on_swipe then self.on_swipe(self, ges.direction) return true end
    if ges.direction == "east" then self:onClose() end
    return true
end

function Page:refresh(mode, rect)
    UIManager:setDirty(self, mode or "ui", rect)
end

function Page:show()
    UIManager:show(self)
    return self
end

function Page:onShow()
    UIManager:setDirty(self, "full")
    return true
end

function Page:onCloseWidget()
    self.closed = true
    if self.on_close then pcall(self.on_close, self) end
    UIManager:setDirty(nil, "full")
end

function Page:onClose()
    UIManager:close(self)
    return true
end

-- ---------------------------------------------------------------- body helpers

function Page.serif(size, bold, italic)
    return Look.serif(size, bold, italic)
end

--- Text in up to `max_lines` lines of width w; returns the height used.
function Page.wrap(bb, text, face, x, y, w, max_lines, line_h, color)
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local args = { text = tostring(text or ""), face = face, width = w, fgcolor = color or BLACK, line_height = 0.2 }
    local tb = TextBoxWidget:new(args)
    local h = tb:getSize().h
    if max_lines and line_h and h > max_lines * line_h then
        tb:free()
        args.height = max_lines * line_h
        args.height_overflow_show_ellipsis = true
        tb = TextBoxWidget:new(args)
        h = tb:getSize().h
    end
    if bb then tb:paintTo(bb, x, y) end
    tb:free()
    return h
end

--- Five stars (filled to `rating`); returns their rects (1..5).
function Page.stars(bb, x, y, s, rating)
    local TextWidget = require("ui/widget/textwidget")
    local rects = {}
    local face = Font:getFace("cfont", math.max(8, math.floor(s * 0.9)))
    for i = 1, 5 do
        local sx = x + (i - 1) * (s + S(6))
        local tw = TextWidget:new{ text = (rating and i <= rating) and "\u{2605}" or "\u{2606}", face = face, fgcolor = BLACK }
        local sz = tw:getSize()
        tw:paintTo(bb, sx + math.floor((s - sz.w) / 2), y + math.floor((s - sz.h) / 2))
        tw:free()
        rects[i] = Geom:new{ x = sx - S(3), y = y - S(6), w = s + S(6), h = s + S(12) }
    end
    return rects
end

--- Chips, wrapped onto lines; `on` marks selected keys. Returns the rects by
--- index and the height used.
function Page.chips(bb, items, x, y, w, size, on)
    local h = S(26)
    local gap = S(6)
    local cx, cy = x, y
    local rects = {}
    for i, it in ipairs(items) do
        local text = require("bos_look").case(tostring(it.text or it))
        local cw = Look.textWidth(text, size or 10) + S(14)
        if cx > x and cx + cw > x + w then
            cx = x
            cy = cy + h + gap
        end
        local sel = on and on[it.key or i]
        if bb then
            Look.box(bb, cx, cy, cw, h, { fill = sel and BLACK or WHITE })
            Look.label(bb, text, cx, cy, cw, h, size or 10, { align = "center", color = sel and WHITE or BLACK })
        end
        rects[i] = Geom:new{ x = cx, y = cy, w = cw, h = h }
        cx = cx + cw + gap
    end
    return rects, (cy - y) + h
end

--- A row of covers on a line shelf. books: { filepath | cover_path, title, dashed }.
--- Returns rects per book and the height used.
function Page.coverRow(bb, books, x, y, w, cw, opts)
    opts = opts or {}
    local ch = math.floor(cw * 1.5)
    local gap = opts.gap or S(14)
    local Cover = require("bos_cover")
    local rects = {}
    local cx = x + S(4)
    for i, b in ipairs(books) do
        if cx + cw > x + w then break end
        if bb then
            if b.dashed then
                -- not on the device: a dashed outline
                local d = math.max(2, S(2))
                bb:paintRect(cx, y, cw, ch, WHITE)
                for k = 0, cw, S(8) do
                    bb:paintRect(cx + k, y, math.min(S(4), cw - k), d, BLACK)
                    bb:paintRect(cx + k, y + ch - d, math.min(S(4), cw - k), d, BLACK)
                end
                for k = 0, ch, S(8) do
                    bb:paintRect(cx, y + k, d, math.min(S(4), ch - k), BLACK)
                    bb:paintRect(cx + cw - d, y + k, d, math.min(S(4), ch - k), BLACK)
                end
                if b.cover_path then
                    local okI, bbi = pcall(function()
                        local RenderImage = require("ui/renderimage")
                        return RenderImage:renderImageFile(b.cover_path, false, cw - 4 * d, ch - 4 * d)
                    end)
                    if okI and bbi then
                        bb:blitFrom(bbi, cx + 2 * d + math.floor((cw - 4 * d - bbi:getWidth()) / 2),
                            y + 2 * d + math.floor((ch - 4 * d - bbi:getHeight()) / 2), 0, 0, bbi:getWidth(), bbi:getHeight())
                        bbi:free()
                    end
                else
                    Page.wrap(bb, b.title or "", require("bos_look").mono(9), cx + S(6), y + S(8), cw - S(12), 5, S(14))
                end
            else
                Cover.paint(bb, b.filepath, cx, y, cw, ch, { shadow = S(3), title = b.title })
            end
            -- a recommendation that's on the device already
            if b.owned then pcall(function() require("bos_online").paintBadge(bb, cx, y, cw, ch) end) end
            if b.badge then
                local bw = Look.textWidth(b.badge, 9) + S(10)
                Look.box(bb, cx + cw - bw + S(6), y - S(6), bw, S(18), { fill = BLACK })
                Look.label(bb, b.badge, cx + cw - bw + S(6), y - S(6), bw, S(18), 9, { align = "center", color = WHITE })
            end
        end
        rects[i] = Geom:new{ x = cx, y = y, w = cw + S(3), h = ch + S(3) }
        cx = cx + cw + gap
    end
    local sy = y + ch + S(8)
    if bb and not opts.no_shelf then
        Look.stripes(bb, x, sy, w, S(8))
        bb:paintRect(x, sy + S(8), w, math.max(2, S(3)), BLACK)
    end
    return rects, ch + S(8) + (opts.no_shelf and 0 or S(12))
end

--- A small section title, grey caps with a dotted leader; `right` on the right.
function Page.heading(bb, text, x, y, w, right)
    Look.heading(bb, text, x, y, w, S(22), right)
    return S(22)
end

return Page
