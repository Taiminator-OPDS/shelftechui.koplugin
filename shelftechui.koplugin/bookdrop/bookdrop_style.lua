--[[
Bookdrop's design language: the Bookshelf OS look (Bookshelf's typefaces,
segmented tab strips, outlined chips, label lines, square covers with a hard
shadow) with its "retro tech" chrome (pinstriped title strips, square buttons
with a hard shadow, monospaced capitals for small labels).

When Bookshelf OS / Bookshelf are installed their typefaces are used; on their
own, KOReader's fonts stand in, and everything still works.

  S(n), face(size, bold), italic(size), mono(size)
  stripes(bb, x, y, w, h)   box(bb, x, y, w, h, opts)   text(bb, …)
  Painted                   a drawn, tappable widget (tap / hold / swipe)
  TitleStrip                the pinstriped strip with a close box and caption
  Tabs                      a segmented strip of tabs
  LabelLine                 "SECTION ...................... ACTION ›"
  Pager                     « ‹ 2 / 5 › » at the foot of a page
  Cover                     a book cover (or a typeset stand-in) with a shadow
  DropMenu                  a retro drop-down window of rows
  Loading                   a small retro "working…" window
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local Screen = Device.screen

local Style = {}

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, LIGHT = Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_LIGHT_GRAY
Style.BLACK, Style.WHITE, Style.GRAY, Style.LIGHT = BLACK, WHITE, GRAY, LIGHT

local function S(n) return Screen:scaleBySize(n) end
Style.S = S
-- (bundled in ShelfTechUI: its theme's frames, type and case)
local okLook, Look = pcall(require, "bos_look")
if not (okLook and type(Look) == "table" and Look.box) then Look = nil end
Style.LINE = Look and Look.LINE or math.max(2, S(2))
Style.THIN = math.max(1, S(1))
Style.SHADOW = S(4)
Style.MARGIN = S(18)

-- ---------------------------------------------------------------------------
-- Type
-- ---------------------------------------------------------------------------

local okUI, BOS = pcall(require, "bos_ui")
if not (okUI and type(BOS) == "table" and BOS.face) then BOS = nil end

--- Bookshelf's UI face (bold when asked), or KOReader's.
function Style.face(size, bold)
    if BOS then
        if bold then return BOS.boldFace(size) end
        return BOS.face(size), false
    end
    return Font:getFace("cfont", size), bold == true
end

function Style.italic(size)
    if BOS and BOS.italicFace then return BOS.italicFace(size) end
    return Font:getFace("cfont", size)
end

function Style.mono(size)
    if Look then return Look.mono(size) end
    return Font:getFace("infont", size)
end

--- Control text as the theme sets it (capitals, or as written).
function Style.case(text)
    text = tostring(text or "")
    if Look then return Look.case(text) end
    return text:upper()
end

function Style.symbol(size) return Font:getFace("symbols", size) end

Style.GLYPH = {
    search = "\u{F002}", cog = "\u{F013}", book = "\u{F02D}", heart = "\u{F004}",
    clock = "\u{F017}", grid = "\u{F00A}", list = "\u{F03A}", download = "\u{F019}",
    image = "\u{F03E}",
}

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

--- The shadow under a box (the theme's, in ShelfTechUI; else hard black).
function Style.shadow(bb, x, y, w, h)
    if Look then return Look.shadow(bb, x, y, w, h, Style.SHADOW) end
    bb:paintRect(x + Style.SHADOW, y + Style.SHADOW, w, h, BLACK)
end

function Style.stripes(bb, x, y, w, h)
    if w < S(12) or h <= 0 then return end
    if Look then return Look.stripes(bb, x, y, w, h) end
    local line = math.max(1, S(1))
    for yy = y, y + h - line, S(3) do bb:paintRect(x, yy, w, line, BLACK) end
end

--- A square box: outline, fill and (unless pressed) a hard shadow.
function Style.box(bb, x, y, w, h, opts)
    opts = opts or {}
    local b = opts.border or Style.LINE
    local sh = opts.shadow or 0
    if Look and not opts.shadow_color then
        return Look.box(bb, x, y, w, h, { border = b, shadow = sh, color = opts.color, fill = opts.fill })
    end
    if sh > 0 then bb:paintRect(x + sh, y + sh, w, h, opts.shadow_color or BLACK) end
    if b > 0 then bb:paintRect(x, y, w, h, opts.color or BLACK) end
    bb:paintRect(x + b, y + b, w - 2 * b, h - 2 * b, opts.fill or WHITE)
end

--- Text into bb: align "left" | "center" | "right", vertically centred in h.
--- Returns the width drawn.
function Style.text(bb, str, x, y, w, h, opts)
    opts = opts or {}
    local face, bold = opts.face, opts.bold
    if not face then face, bold = Style.face(opts.size or 15, opts.bold) end
    local tw = TextWidget:new{ text = str or "", face = face, bold = bold,
        fgcolor = opts.color or BLACK, max_width = w }
    local s = tw:getSize()
    local tx = x
    if opts.align == "center" then tx = x + math.floor((w - s.w) / 2)
    elseif opts.align == "right" then tx = x + w - s.w end
    tw:paintTo(bb, tx, y + math.floor((h - s.h) / 2))
    tw:free()
    return s.w
end

function Style.textWidth(str, face, bold)
    local tw = TextWidget:new{ text = str or "", face = face, bold = bold }
    local w = tw:getSize().w
    tw:free()
    return w
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end
Style.inside = inside

-- ---------------------------------------------------------------------------
-- A drawn, tappable widget
-- ---------------------------------------------------------------------------

local Painted = InputContainer:extend{
    width = 0, height = 0,
    draw = nil,     -- fn(self, bb, x, y)
    tap = nil,      -- fn(self, pos) -> handled
    hold = nil,     -- fn(self, pos) -> handled
    swipe = nil,    -- fn(self, ges) -> handled
}
Style.Painted = Painted

function Painted:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local range = function() return self.dimen end
    self.ges_events = {}
    if self.tap then self.ges_events.TapPainted = { GestureRange:new{ ges = "tap", range = range } } end
    if self.hold then self.ges_events.HoldPainted = { GestureRange:new{ ges = "hold", range = range } } end
    if self.swipe then self.ges_events.SwipePainted = { GestureRange:new{ ges = "swipe", range = range } } end
end

function Painted:getSize() return Geom:new{ w = self.width, h = self.height } end

function Painted:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h = x, y, self.width, self.height
    -- every drawn widget is opaque: a redraw (page turn, a press) must not
    -- land on what was there before
    if not self.transparent then bb:paintRect(x, y, self.width, self.height, WHITE) end
    if self.draw then
        local ok, err = pcall(self.draw, self, bb, x, y)
        if not ok then logger.warn("Bookdrop: draw failed:", err) end
    end
end

function Painted:onTapPainted(_, ges) return self.tap and self:tap(ges.pos) and true or false end
function Painted:onHoldPainted(_, ges) return self.hold and self:hold(ges.pos) and true or false end
function Painted:onSwipePainted(_, ges) return self.swipe and self:swipe(ges) and true or false end

--- Repaint just this widget (and refresh its area).
function Painted:repaint(mode)
    if not self.dimen.x then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, mode or "ui", self.dimen)
end

--- Show a press: draw pressed, push it to the screen, then run fn.
function Painted:press(key, fn)
    self.pressed = key
    self:repaint("fast")
    UIManager:forceRePaint()
    self.pressed = nil
    if fn then fn() end
end

-- ---------------------------------------------------------------------------
-- The pinstriped title strip
-- ---------------------------------------------------------------------------

--- opts: width, caption, on_close, actions = { { glyph =, callback = } } (right)
function Style.TitleStrip(opts)
    local h = opts.height or S(38)
    local w = opts.width
    local actions = opts.actions or {}
    local btn = h - S(10)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            bb:paintRect(x, y, w, h, WHITE)
            local right = x + w - S(10)
            self.action_rects = {}
            for i = #actions, 1, -1 do
                local a = actions[i]
                local bx = right - btn
                local by = y + math.floor((h - btn) / 2)
                local down = self.pressed == i
                Style.box(bb, bx, by, btn, btn, { border = Style.LINE, fill = down and BLACK or WHITE })
                local g = TextWidget:new{ text = a.glyph, face = Style.symbol(14),
                    fgcolor = down and WHITE or BLACK }
                local gs = g:getSize()
                g:paintTo(bb, bx + math.floor((btn - gs.w) / 2), by + math.floor((btn - gs.h) / 2))
                g:free()
                self.action_rects[i] = Geom:new{ x = bx - S(4), y = y, w = btn + S(8), h = h }
                right = bx - S(8)
            end
            local left = x + S(8)
            if opts.on_close then
                local sz = S(18)
                local cx, cy = x + S(12), y + math.floor((h - sz) / 2)
                Style.box(bb, cx, cy, sz, sz, { border = Style.LINE, fill = self.pressed == "close" and BLACK or WHITE })
                self.close_rect = Geom:new{ x = x, y = y, w = sz + S(24), h = h }
                left = cx + sz + S(10)
            end
            Style.stripes(bb, left, y + S(9), right - left, h - S(18))
            local cap = Style.case(tostring(opts.caption or ""))
            if cap ~= "" then
                local face = Style.mono(14)
                local cw = math.min(right - left - S(8), Style.textWidth(cap, face, true) + S(22))
                local cx = left + math.floor((right - left - cw) / 2)
                bb:paintRect(cx, y + S(5), cw, h - S(10), WHITE)
                Style.text(bb, cap, cx, y, cw, h, { face = face, bold = true, align = "center" })
            end
            bb:paintRect(x, y + h - Style.LINE, w, Style.LINE, BLACK)
        end,
        tap = function(self, pos)
            if self.close_rect and inside(pos, self.close_rect) then
                self:press("close", opts.on_close)
                return true
            end
            for i, r in pairs(self.action_rects or {}) do
                if inside(pos, r) then
                    self:press(i, actions[i].callback)
                    return true
                end
            end
            return true
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Segmented tabs
-- ---------------------------------------------------------------------------

--- cells: { { text, selected, enabled, callback } }; opts: height, size
function Style.Tabs(cells, w, opts)
    opts = opts or {}
    local h = opts.height or S(40)
    local face = Style.mono(opts.size or 14)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            local b = math.max(1, S(1.5))
            bb:paintRect(x, y, w, h, BLACK)
            bb:paintRect(x + b, y + b, w - 2 * b, h - 2 * b, WHITE)
            local n = #cells
            local cw = math.floor((w - 2 * b - (n - 1) * b) / n)
            local cx = x + b
            self.rects = {}
            for i, c in ipairs(cells) do
                local this_w = (i == n) and (x + w - b - cx) or cw
                local sel = c.selected or self.pressed == i
                local en = c.enabled ~= false
                if sel then bb:paintRect(cx, y + b, this_w, h - 2 * b, BLACK) end
                Style.text(bb, Style.case(tostring(c.text)), cx + S(4), y, this_w - S(8), h,
                    { face = face, bold = true, align = "center",
                      color = sel and WHITE or (en and BLACK or GRAY) })
                self.rects[i] = Geom:new{ x = cx, y = y, w = this_w, h = h }
                cx = cx + this_w
                if i < n then
                    bb:paintRect(cx, y + b, b, h - 2 * b, BLACK)
                    cx = cx + b
                end
            end
        end,
        tap = function(self, pos)
            for i, r in ipairs(self.rects or {}) do
                if inside(pos, r) then
                    local c = cells[i]
                    if c.enabled == false or not c.callback then return true end
                    self:press(i, function() c.callback(r) end)
                    return true
                end
            end
            return true
        end,
    }
end

-- ---------------------------------------------------------------------------
-- A label line: "SECTION ........................ SEE ALL ›"
-- ---------------------------------------------------------------------------

function Style.LabelLine(label, w, action, callback, opts)
    opts = opts or {}
    local h = opts.height or S(36)
    local face = Style.mono(opts.size or 14)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            bb:paintRect(x, y, w, h, WHITE)
            local lw = Style.text(bb, Style.case(tostring(label)), x, y, w, h, { face = face, bold = true })
            local aw = 0
            if action then
                local atext = Style.case(tostring(action)) .. "  \u{203A}"
                local af = Style.mono(12)
                aw = Style.textWidth(atext, af, true) + S(18)
                local ax = x + w - aw
                local ah = S(26)
                local ay = y + math.floor((h - ah) / 2)
                local down = self.pressed == "action"
                Style.box(bb, ax, ay, aw, ah, { border = math.max(1, S(1.5)), fill = down and BLACK or WHITE })
                Style.text(bb, atext, ax, ay, aw, ah, { face = af, bold = true, align = "center",
                    color = down and WHITE or BLACK })
                self.action_rect = Geom:new{ x = ax - S(6), y = y, w = aw + S(6), h = h }
                aw = aw + S(10)
            end
            -- the dotted leader between them
            local lx = x + lw + S(10)
            local rx = x + w - aw - S(4)
            local dot = math.max(1, S(1.5))
            for dx = lx, rx - dot, S(5) do
                bb:paintRect(dx, y + math.floor(h / 2) + S(5), dot, dot, GRAY)
            end
        end,
        tap = callback and function(self, pos)
            self:press("action", callback)
            return true
        end or nil,
    }
end

-- ---------------------------------------------------------------------------
-- Pager
-- ---------------------------------------------------------------------------

--- opts: width, page, pages, on_page(n), more (true: a next page can be fetched)
function Style.Pager(opts)
    local w, h = opts.width, opts.height or S(48)
    local btn_w, btn_h = S(46), S(34)
    return Painted:new{
        width = w, height = h,
        draw = function(self, bb, x, y)
            -- clear first: a page turn redraws this over the last count
            bb:paintRect(x, y, w, h, WHITE)
            local by = y + math.floor((h - btn_h) / 2) - S(2)
            local face = Style.mono(15)
            local function button(key, bx, label, enabled)
                local down = self.pressed == key
                local ox = down and Style.SHADOW - S(1) or 0
                Style.box(bb, bx + ox, by + ox, btn_w, btn_h, {
                    shadow = (enabled and not down) and S(3) or 0,
                    fill = down and BLACK or WHITE, color = enabled and BLACK or LIGHT })
                Style.text(bb, label, bx + ox, by + ox, btn_w, btn_h, { face = face, bold = true,
                    align = "center", color = down and WHITE or (enabled and BLACK or LIGHT) })
                self.rects[key] = Geom:new{ x = bx - S(6), y = y, w = btn_w + S(12), h = h }
            end
            self.rects = {}
            local page, pages = opts.page(), opts.pages()
            local more = opts.more and opts.more()
            local cx = x + math.floor(w / 2)
            button("first", x, "\u{00AB}", page > 1)
            button("prev", x + btn_w + S(14), "\u{2039}", page > 1)
            -- (the right-hand buttons leave room for their shadows inside the pager)
            local rx = x + w - btn_w - Style.SHADOW
            button("next", rx - btn_w - S(14), "\u{203A}", page < pages or more)
            button("last", rx, "\u{00BB}", page < pages)
            local label = more and string.format("%d / %d+", page, pages) or string.format("%d / %d", page, pages)
            Style.text(bb, label, cx - S(80), y, S(160), h, { face = face, bold = true, align = "center" })
        end,
        tap = function(self, pos)
            local page, pages = opts.page(), opts.pages()
            local more = opts.more and opts.more()
            local target
            for key, r in pairs(self.rects or {}) do
                if inside(pos, r) then
                    if key == "first" and page > 1 then target = 1
                    elseif key == "prev" and page > 1 then target = page - 1
                    elseif key == "next" and (page < pages or more) then target = page + 1
                    elseif key == "last" and page < pages then target = pages end
                    if target then self:press(key, function() opts.on_page(target) end) end
                    return true
                end
            end
            return true
        end,
    }
end

-- ---------------------------------------------------------------------------
-- Covers
-- ---------------------------------------------------------------------------

--- Draw a book's cover (or a typeset stand-in) into bb, with a frame and a
--- hard shadow. Decoded images are kept in `cache` (path..size -> bb) so page
--- turns and refreshes don't decode again.
function Style.drawCover(bb, book, x, y, w, h, cache)
    Style.shadow(bb, x, y, w, h)
    local path = book.cover_path
    local drawn = false
    if path then
        local key = path .. "@" .. w .. "x" .. h
        local img = cache and cache[key]
        if not img then
            local ok, iw = pcall(ImageWidget.new, ImageWidget, {
                file = path, width = w, height = h, scale_factor = 0, alpha = true,
                file_do_cache = false,
            })
            if ok and iw then
                local ok2 = pcall(function() iw:_render() end)
                if ok2 and iw._bb then
                    img = { bb = iw._bb:copy(), w = iw._bb:getWidth(), h = iw._bb:getHeight() }
                    if cache then cache[key] = img end
                end
                iw:free()
            end
        end
        if img then
            bb:paintRect(x, y, w, h, WHITE)
            local ix = x + math.floor((w - img.w) / 2)
            local iy = y + math.floor((h - img.h) / 2)
            bb:blitFrom(img.bb, ix, iy, 0, 0, img.w, img.h)
            drawn = true
        end
    end
    if not drawn then
        -- a typeset stand-in: title and author on a pinstriped plate
        bb:paintRect(x, y, w, h, WHITE)
        Style.stripes(bb, x + S(6), y + S(6), w - S(12), S(12))
        Style.stripes(bb, x + S(6), y + h - S(18), w - S(12), S(12))
        local face, bold = Style.face(w > S(120) and 16 or 12, true)
        local tb = TextBoxWidget:new{
            text = (book.title or _("Untitled")) .. "\n\n" .. (book.author or ""),
            width = w - S(16), alignment = "center", face = face, bold = bold,
            height = h - S(48), height_overflow_show_ellipsis = true,
        }
        local th = tb:getSize().h
        tb:paintTo(bb, x + S(8), y + math.floor((h - th) / 2))
        tb:free()
    end
    -- the frame
    local b = Style.THIN
    bb:paintRect(x, y, w, b, BLACK)
    bb:paintRect(x, y + h - b, w, b, BLACK)
    bb:paintRect(x, y, b, h, BLACK)
    bb:paintRect(x + w - b, y, b, h, BLACK)
end

function Style.freeCache(cache)
    for k, img in pairs(cache or {}) do
        if img.bb then img.bb:free() end
        cache[k] = nil
    end
end

-- ---------------------------------------------------------------------------
-- A retro drop-down window of rows
-- ---------------------------------------------------------------------------
--[[ rows: { { text, value (right, grey), checked (true|false|nil), bold,
             heading, back, chevron, separator, enabled, callback } } ]]

local DropMenu = InputContainer:extend{
    name = "bookdrop_dropmenu",
    modal = true,
    rows = nil,
    caption = nil,
    anchor = nil,       -- Geom to hang under (else centred)
    width = nil,
    align_right = false,
}
Style.DropMenu = DropMenu

function DropMenu:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.row_h = S(46)
    self.strip_h = S(30)
    self.w = self.width or math.floor(sw * 0.72)
    local top = self.anchor and (self.anchor.y + self.anchor.h + S(6)) or math.floor(sh * 0.12)
    local avail = sh - top - S(20) - Style.SHADOW - self.strip_h - 2 * Style.LINE
    self.per_page = math.max(3, math.floor(avail / self.row_h))
    self.page = 1
    self.pages = math.max(1, math.ceil(#self.rows / self.per_page))
    if self.pages > 1 then
        self.per_page = self.per_page - 1 -- room for the page row
        self.pages = math.max(1, math.ceil(#self.rows / self.per_page))
    end
    local x
    if self.anchor then
        x = self.align_right and (self.anchor.x + self.anchor.w - self.w) or self.anchor.x
    else
        x = math.floor((sw - self.w) / 2)
    end
    x = math.max(S(10), math.min(x, sw - self.w - S(10) - Style.SHADOW))
    self.x, self.y = x, top
    self:layout()
    local all = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.ges_events = {
        TapMenu = { GestureRange:new{ ges = "tap", range = all } },
        SwipeMenu = { GestureRange:new{ ges = "swipe", range = all } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function DropMenu:visible()
    local list = {}
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.rows, first + self.per_page - 1) do table.insert(list, self.rows[i]) end
    return list
end

function DropMenu:layout()
    local n = #self:visible() + (self.pages > 1 and 1 or 0)
    self.h = self.strip_h + n * self.row_h + 2 * Style.LINE
    self.rect = Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
    self.dimen = Geom:new{ x = self.x, y = self.y, w = self.w + Style.SHADOW, h = self.h + Style.SHADOW }
end

function DropMenu:paintTo(bb)
    local r = self.rect
    Style.box(bb, r.x, r.y, r.w, r.h, { shadow = Style.SHADOW })
    local b = Style.LINE
    local x, w = r.x + b, r.w - 2 * b
    -- strip
    local sy = r.y + b
    Style.stripes(bb, x + S(6), sy + S(8), w - S(12), self.strip_h - S(16))
    local cap = Style.case(tostring(self.caption or ""))
    if cap ~= "" then
        local face = Style.mono(12)
        local cw = math.min(w - S(20), Style.textWidth(cap, face, true) + S(20))
        local cx = x + math.floor((w - cw) / 2)
        bb:paintRect(cx, sy + S(4), cw, self.strip_h - S(8), WHITE)
        Style.text(bb, cap, cx, sy, cw, self.strip_h, { face = face, bold = true, align = "center" })
    end
    bb:paintRect(x, sy + self.strip_h - Style.THIN, w, Style.THIN, BLACK)
    -- rows
    local y = sy + self.strip_h
    self.row_rects = {}
    for i, row in ipairs(self:visible()) do
        local en = row.enabled ~= false and (row.callback ~= nil or row.back)
        local down = self.pressed == row
        if down then bb:paintRect(x, y, w, self.row_h, BLACK) end
        local ink = down and WHITE or ((row.heading or en or row.checked ~= nil) and BLACK or GRAY)
        local tx = x + S(16)
        if row.checked ~= nil then
            local sz = S(18)
            local cy = y + math.floor((self.row_h - sz) / 2)
            Style.box(bb, tx, cy, sz, sz, { border = math.max(1, S(1.5)), color = ink,
                fill = row.checked and ink or (down and BLACK or WHITE) })
            tx = tx + sz + S(12)
        elseif row.back then
            Style.text(bb, "\u{2039}", tx, y, S(16), self.row_h, { size = 20, bold = true, color = ink })
            tx = tx + S(20)
        end
        local right = x + w - S(14)
        if row.chevron then
            Style.text(bb, "\u{203A}", right - S(12), y, S(12), self.row_h, { size = 20, bold = true, color = ink })
            right = right - S(20)
        end
        if row.value then
            local vf = Style.mono(12)
            local vw = Style.text(bb, Style.case(tostring(row.value)), tx, y, right - tx, self.row_h,
                { face = vf, bold = true, align = "right", color = down and WHITE or GRAY })
            right = right - vw - S(12)
        end
        if row.heading then
            Style.text(bb, Style.case(tostring(row.text)), tx, y, right - tx, self.row_h,
                { face = Style.mono(13), bold = true, color = ink })
        else
            Style.text(bb, row.text, tx, y, right - tx, self.row_h,
                { size = 17, bold = row.bold or row.back, color = ink })
        end
        if i > 1 and not down then
            bb:paintRect(x + S(12), y, w - S(24), Style.THIN, row.separator and BLACK or LIGHT)
        end
        self.row_rects[i] = { row = row, rect = Geom:new{ x = x, y = y, w = w, h = self.row_h } }
        y = y + self.row_h
    end
    if self.pages > 1 then
        bb:paintRect(x + S(12), y, w - S(24), Style.THIN, LIGHT)
        Style.text(bb, string.format("\u{2039}   %d / %d   \u{203A}", self.page, self.pages), x, y, w, self.row_h,
            { face = Style.mono(14), bold = true, align = "center" })
        self.page_rect = Geom:new{ x = x, y = y, w = w, h = self.row_h }
    end
end

function DropMenu:turn(delta)
    local old = self.dimen
    self.page = (self.page - 1 + delta) % self.pages + 1
    self:layout()
    UIManager:setDirty(self.under, "ui", old)
    UIManager:setDirty(self, "ui", self.dimen)
end

function DropMenu:onTapMenu(_, ges)
    if not inside(ges.pos, self.rect) then
        self:onClose()
        return true
    end
    if self.page_rect and inside(ges.pos, self.page_rect) then
        self:turn(ges.pos.x < self.page_rect.x + self.page_rect.w / 2 and -1 or 1)
        return true
    end
    for _i, rr in ipairs(self.row_rects or {}) do
        if inside(ges.pos, rr.rect) then
            local row = rr.row
            if row.enabled == false or not row.callback then return true end
            self.pressed = row
            UIManager:widgetRepaint(self, 0, 0)
            UIManager:setDirty(nil, "fast", rr.rect)
            UIManager:forceRePaint()
            self.pressed = nil
            if not row.keep_open then self:onClose() end
            -- after this tap is done: what it opens must not get its tail
            UIManager:nextTick(function()
                local ok, err = pcall(row.callback)
                if not ok then logger.warn("Bookdrop: menu row failed:", err) end
            end)
            return true
        end
    end
    return true
end

function DropMenu:onSwipeMenu(_, ges)
    if self.pages > 1 and inside(ges.pos, self.rect) then
        if ges.direction == "west" or ges.direction == "north" then self:turn(1) return true end
        if ges.direction == "east" or ges.direction == "south" then self:turn(-1) return true end
    end
    self:onClose()
    return true
end

function DropMenu:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

function DropMenu:onClose()
    UIManager:close(self, "ui")
    return true
end

--- Rows from KOReader-style text entries ("✓  Name", "□  Name", "‹  Back",
--- "Name  ·  Value  ›") as used by Bookdrop's settings.
function Style.rowsFromEntries(entries)
    local rows = {}
    for i, e in ipairs(entries or {}) do
        local text = tostring(e.text or "")
        local row = { callback = e.callback, bold = e.bold, separator = e.separator, enabled = e.enabled }
        if text:find("^\u{2713}%s+") then row.checked = true; text = text:gsub("^\u{2713}%s+", "")
        elseif text:find("^\u{25A1}%s+") then row.checked = false; text = text:gsub("^\u{25A1}%s+", "") end
        if text:find("^\u{2039}%s+") then row.back = true; text = text:gsub("^\u{2039}%s+", "") end
        if text:find("%s+\u{203A}$") then row.chevron = true; text = text:gsub("%s+\u{203A}$", "") end
        local name, value = text:match("^(.-)%s+\u{00B7}%s+(.+)$")
        if name then text, row.value = name, value end
        if not e.callback and not row.back and e.bold then row.heading = true end
        row.text = text
        -- the first heading names the window; it isn't a row
        if i == 1 and row.heading then rows.caption = text else table.insert(rows, row) end
    end
    return rows
end

-- ---------------------------------------------------------------------------
-- A small "working…" window
-- ---------------------------------------------------------------------------

local Loading = InputContainer:extend{
    name = "bookdrop_loading",
    text = nil,          -- "Searching Fiction…"
    detail = nil,        -- "2 of 5 libraries answered"
    cancellable = false, -- tap anywhere (or CANCEL) to stop
    modal = true,
}
Style.Loading = Loading

function Loading:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local face, bold = Style.face(17, true)
    self.w = math.min(sw - S(60), math.max(S(340), Style.textWidth(self.text or "", face, bold) + S(60)))
    self.strip_h = S(30)
    self.h = self.strip_h + S(64) + (self.cancellable and S(62) or 0)
    self.rect = Geom:new{ x = math.floor((sw - self.w) / 2), y = math.floor((sh - self.h) / 2), w = self.w, h = self.h }
    self.dimen = Geom:new{ x = self.rect.x, y = self.rect.y, w = self.w + Style.SHADOW, h = self.h + Style.SHADOW }
    if self.cancellable then
        local all = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self.ges_events = { TapCancel = { GestureRange:new{ ges = "tap", range = all } } }
        if Device:hasKeys() then self.key_events = { Cancel = { { Device.input.group.Back } } } end
    end
end

function Loading:paintTo(bb)
    local r = self.rect
    Style.box(bb, r.x, r.y, r.w, r.h, { shadow = Style.SHADOW })
    local b = Style.LINE
    local sh = self.strip_h
    Style.stripes(bb, r.x + b + S(6), r.y + b + S(8), r.w - 2 * b - S(12), sh - S(16))
    local face = Style.mono(12)
    local cap = Style.case((self.cancelled and _("Stopping") or _("Working")))
    local cw = Style.textWidth(cap, face, true) + S(20)
    bb:paintRect(r.x + math.floor((r.w - cw) / 2), r.y + b + S(4), cw, sh - S(8), WHITE)
    Style.text(bb, cap, r.x, r.y + b, r.w, sh, { face = face, bold = true, align = "center" })
    bb:paintRect(r.x + b, r.y + b + sh, r.w - 2 * b, Style.THIN, BLACK)
    local y = r.y + b + sh
    Style.text(bb, self.text or "", r.x + S(20), y + S(6), r.w - S(40), S(30), { size = 17, bold = true, align = "center" })
    Style.text(bb, self.detail or "", r.x + S(20), y + S(36), r.w - S(40), S(22),
        { face = Style.italic(14), color = GRAY, align = "center" })
    if self.cancellable then
        local bw, bh = S(150), S(38)
        local bx = r.x + math.floor((r.w - bw) / 2)
        local by = r.y + r.h - bh - S(18)
        local down = self.cancelled
        Style.box(bb, bx + (down and S(3) or 0), by + (down and S(3) or 0), bw, bh,
            { shadow = down and 0 or S(3), fill = down and BLACK or WHITE })
        Style.text(bb, Style.case(_("Cancel")), bx + (down and S(3) or 0), by + (down and S(3) or 0), bw, bh,
            { face = Style.mono(15), bold = true, align = "center", color = down and WHITE or BLACK })
    end
end

function Loading:setDetail(detail)
    if detail == self.detail then return end
    self.detail = detail
    UIManager:setDirty(self, "ui", self.dimen)
end

function Loading:onTapCancel() return self:onCancel() end

function Loading:onCancel()
    if self.cancelled then return true end
    self.cancelled = true
    UIManager:setDirty(self, "fast", self.dimen)
    if self.dismiss_callback then pcall(self.dismiss_callback) end
    if self.on_cancel then pcall(self.on_cancel) end
    -- never left on screen: whatever the work behind it is doing, Cancel
    -- takes this window away (the work sees `cancelled` and stops)
    UIManager:scheduleIn(0.3, function() UIManager:close(self) end)
    return true
end

function Loading:onShow()
    UIManager:setDirty(self, "ui", self.dimen)
    return true
end

function Loading:onCloseWidget()
    self._bookdrop_gone = true
    UIManager:setDirty(nil, "ui", self.dimen)
end

--- A full refresh of the whole screen for `widget` (repainted from it up):
--- the standard whenever a new screen of books appears.
function Style.fullRefresh(widget)
    UIManager:setDirty(widget, "full")
end

return Style
