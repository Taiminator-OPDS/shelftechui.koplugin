--[[
ShelfTechUI design kit: Bookshelf's design language, plus the shared
controls every surface uses (one light control, one set of menu rows, one
drop-down card).

Design tokens (as Bookshelf draws them):
  * 2px black outlines, small corner radius, hard down-right grey shadow
    (softer in night mode);
  * tab strips: rectangular, thin black outline and dividers, the active
    cell filled black;
  * section labels in bold grey capitals; progress bars as a rounded outline
    with a dark grey fill; bold titles, italic authors.

Widgets:
  M.LightSlider  a brightness or warmth slider (− bar +)
  M.MenuTitle, M.CheckRow, M.ActionRow, M.InfoRow, M.Hairline   menu rows
  M.ChipMenu     a card with a pointer, dropping from what opened it
  M.Menus        the shared panels: light, wifi
                 (the home status bar, the reading toolbar's LIGHT and the
                 Quick Settings panel all draw light from M.Menus.light)
--]]

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Event          = require("ui/event")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local ImageWidget    = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size           = require("ui/size")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local logger         = require("logger")
local T              = require("ffi/util").template
local _              = require("gettext")
local Screen         = Device.screen
local Look           = require("bos_look")

local M = {}

M.PLUGIN_DIR = (debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./")

local function S(v) return Screen:scaleBySize(v) end
M.S = S

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local DARK, GRAY_9, LIGHT = Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_GRAY_9, Blitbuffer.COLOR_LIGHT_GRAY
M.BLACK, M.WHITE, M.DARK, M.LIGHT = BLACK, WHITE, DARK, LIGHT

local function try(name)
    local ok, mod = pcall(require, name)
    if ok and mod then return mod end
end

-- ---------------------------------------------------------------------------
-- Bookshelf presence & actions
-- ---------------------------------------------------------------------------

--- The Bookshelf plugin instance of the current UI (reader or file manager).
function M.bookshelfPlugin()
    local ok, ReaderUI = package.loaded["apps/reader/readerui"] ~= nil, package.loaded["apps/reader/readerui"]
    local ui = ok and ReaderUI.instance
    if not (ui and not ui.tearing_down) then
        local okf, FM = pcall(require, "apps/filemanager/filemanager")
        ui = okf and FM.instance or nil
    end
    local p = ui and ui.bookshelf
    if type(p) == "table" and p.onToggleBookshelf then return p, ui end
end

function M.hasBookshelf()
    return M.bookshelfPlugin() ~= nil
end


--- Send a Bookshelf event to the current UI (true when Bookshelf is there).
function M.bookshelfEvent(name, ...)
    local p, ui = M.bookshelfPlugin()
    if not p then return false end
    ui:handleEvent(Event:new(name, ...))
    return true
end

-- ---------------------------------------------------------------------------
-- Fonts (Bookshelf's UI font when installed, else KOReader's)
-- ---------------------------------------------------------------------------

local function bsFonts()
    local BF = try("lib/bookshelf_fonts")
    if BF and type(BF.getFace) == "function" then return BF end
end

function M.face(size)
    local BF = bsFonts()
    if BF then
        local ok, f = pcall(BF.getFace, BF, "cfont", size)
        if ok and f then return f end
    end
    return Font:getFace("cfont", size)
end

--- Bold face, and whether KOReader must embolden it (true) or it is a real bold file (false).
function M.boldFace(size)
    local BF = bsFonts()
    if BF then
        local ok, f, b = pcall(BF.getFace, BF, "cfont", size, { bold = true })
        if ok and f then return f, b and true or false end
    end
    return Font:getFace("cfont", size), true
end

function M.italicFace(size)
    local BF = bsFonts()
    if BF then
        local ok, f = pcall(BF.getFace, BF, "cfont", size, { italic = true })
        if ok and f then return f end
    end
    local ok, f = pcall(Font.getFace, Font, "NotoSans-Italic.ttf", size)
    if ok and f then return f end
    return M.face(size)
end

function M.caps(s)
    if type(s) ~= "string" or s == "" then return s end
    if not require("bos_look").theme.upper then return s end
    local ok, U = pcall(require, "ffi/utf8proc")
    if ok and U and U.uppercase_dumb then
        local ok2, r = pcall(U.uppercase_dumb, s)
        if ok2 and r then return r end
    end
    return require("bos_look").case(s)
end

-- ---------------------------------------------------------------------------
-- Painting helpers
-- ---------------------------------------------------------------------------

function M.line() return require("bos_look").LINE end
function M.stripLine() return Size.border.default end

function M.nightMode()
    local NM = try("lib/bookshelf_night_mode_sync")
    if NM and NM.active then
        local ok, on = pcall(NM.active, Screen)
        if ok then return on and true or false end
    end
    return G_reader_settings:isTrue("night_mode")
end

function M.shadowGray()
    if M.nightMode() then return Blitbuffer.gray(0.15) end
    return Blitbuffer.COLOR_BLACK -- the retro look: a hard black shadow
end

function M.sidePad()
    local SL = try("lib/status_line")
    if SL and SL.sidePad then
        local ok, p = pcall(SL.sidePad, Screen:getWidth(), Size.padding.fullscreen)
        if ok and type(p) == "number" and p > 0 then return p end
    end
    return Size.padding.fullscreen
end

--- A card, in the retro look: square, 2px outline, hard black shadow.
function M.card(bb, x, y, w, h, opts)
    opts = opts or {}
    Look.box(bb, x, y, w, h, { border = opts.border or M.line(), fill = opts.background or WHITE,
        color = opts.color, shadow = opts.shadow or 0 })
end

function M.disc(bb, cx, cy, r, color)
    bb:paintRoundedRect(cx - r, cy - r, r * 2, r * 2, color, r)
end

local function tw(text, face, color, max_w, bold)
    return TextWidget:new{ text = text, face = face, fgcolor = color or BLACK,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil, bold = bold and true or nil }
end

function M.textWidth(text, face, bold)
    local t = tw(text, face, nil, nil, bold)
    local w = t:getSize().w
    t:free()
    return w
end

function M.drawText(bb, text, face, x, y, h, color, max_w, bold)
    local t = tw(text, face, color, max_w, bold)
    local sz = t:getSize()
    t:paintTo(bb, x, y + math.floor((h - sz.h) / 2))
    t:free()
    return sz.w
end

function M.drawTextCentered(bb, text, face, x, y, w, h, color, bold)
    local t = tw(text, face, color, w, bold)
    local sz = t:getSize()
    t:paintTo(bb, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
    t:free()
end

local icon_cache = {}

--- Paints an icon file (svg/png path) or a KOReader icon name. `white` draws it
--- white (on a black cell); `dim` draws it grey.
function M.paintIcon(bb, icon, x, y, size, white, dim)
    local key = tostring(icon) .. "@" .. size
    local iw = icon_cache[key]
    if iw == nil then
        if type(icon) == "string" and (icon:match("%.svg$") or icon:match("%.png$")) then
            iw = ImageWidget:new{ file = icon, width = size, height = size, alpha = true, is_icon = true }
        else
            local IconWidget = require("ui/widget/iconwidget")
            iw = IconWidget:new{ icon = icon, width = size, height = size, alpha = true }
        end
        local ok = pcall(function() iw:_render() end)
        if not ok then iw = false end
        icon_cache[key] = iw
    end
    if not iw then return end
    if white or dim then
        local tmp = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        tmp:fill(WHITE)
        iw:paintTo(tmp, 0, 0)
        local ink = white and WHITE or GRAY_9
        for yy = 0, size - 1 do
            for xx = 0, size - 1 do
                if tmp:getPixel(xx, yy):getColor8().a < 128 then bb:setPixel(x + xx, y + yy, ink) end
            end
        end
        tmp:free()
    else
        iw:paintTo(bb, x, y)
    end
end

--- Bookshelf's progress bar: rounded outline track, dark grey fill.
--- Returns the inner x and width (for hit testing).
function M.progressBar(bb, x, y, w, h, frac, opts)
    do return Look.track(bb, x, y, w, h, frac) end
    opts = opts or {}
    local t = opts.border or math.max(1, S(1.5))
    local r = math.floor(h / 2)
    bb:paintRoundedRect(x, y, w, h, opts.color or BLACK, r)
    bb:paintRoundedRect(x + t, y + t, w - 2 * t, h - 2 * t, WHITE, math.max(0, r - t))
    frac = math.max(0, math.min(1, frac or 0))
    local inset = t + math.max(1, S(1.5))
    local iw = w - 2 * inset
    local fw = math.floor(iw * frac + 0.5)
    if fw > 0 then
        local ih = h - 2 * inset
        bb:paintRoundedRect(x + inset, y + inset, math.max(fw, ih), ih, opts.fill or DARK, math.floor(ih / 2))
    end
    return x + inset, iw
end

-- ---------------------------------------------------------------------------
-- Bookshelf's status line
-- ---------------------------------------------------------------------------

local _rec = { path = nil, book = nil, until_t = 0 }

--- Bookshelf's status row (same builder as its shelf / in-reader status line),
--- with its grey hairline. nil when Bookshelf isn't installed.
function M.buildStatusRow(width, file)
    local okS, Status = pcall(require, "bos_status")
    if okS and Status.enabled() then return Status.row(width) end
    local HeroCard = try("lib/bookshelf_hero_card")
    local Repo = try("lib/bookshelf_book_repository")
    local BW = try("lib/bookshelf_widget")
    if not (HeroCard and HeroCard.buildStatusRow and Repo and BW) then return nil end
    local book = {}
    if file then
        local now = os.time()
        book = _rec.path == file and now < _rec.until_t and _rec.book or nil
        if not book then
            local ok, b = pcall(Repo.buildBook, file, { want_cover = false })
            book = ok and b or {}
            _rec.path, _rec.book, _rec.until_t = file, book, now + 5
        end
    end
    local ok_s, state = pcall(BW.deviceState)
    if not ok_s then state = {} end
    local ok, row = pcall(HeroCard.buildStatusRow, book, state, width, true, nil, BLACK)
    if not ok or not row then return nil end
    local sz = row.getSize and row:getSize()
    if not sz or not sz.h or sz.h <= 0 then return nil end
    return row
end

-- ---------------------------------------------------------------------------
-- Light control (brightness / warmth)
-- ---------------------------------------------------------------------------

local Light = {}
M.Light = Light

function Light.hasBrightness() return Device:hasFrontlight() end
function Light.hasWarmth()
    local p = Device:getPowerDevice()
    return Device:hasNaturalLight() and p.fl_warmth_min ~= nil and p.fl_warmth_max ~= nil
end

--- The control for "brightness" or "warmth": { label, range(), get(), set(v) }.
function Light.control(kind)
    local p = Device:getPowerDevice()
    if kind == "warmth" then
        return {
            kind = kind, label = _("Warmth"),
            range = function() return p.fl_warmth_min, p.fl_warmth_max end,
            get = function() return p:toNativeWarmth(p:frontlightWarmth()) end,
            set = function(v)
                v = math.max(p.fl_warmth_min, math.min(p.fl_warmth_max, v))
                p:setWarmth(p:fromNativeWarmth(v))
            end,
        }
    end
    return {
        kind = "brightness", label = _("Brightness"),
        range = function() return p.fl_min, p.fl_max end,
        get = function() return p:isFrontlightOn() and p:frontlightIntensity() or p.fl_min end,
        set = function(v)
            v = math.max(p.fl_min, math.min(p.fl_max, v))
            if v <= p.fl_min then
                -- as KOReader's own dialog: the minimum turns the light off,
                -- keeping the previous level for when it's turned on again
                p:turnOffFrontlight()
            else
                p:setIntensity(v)
                if p:isFrontlightOff() then p:turnOnFrontlight() end
            end
            if p.updateResumeFrontlightState then p:updateResumeFrontlightState() end
        end,
    }
end

--- The value as shown: "off" (hidden), "level" (raw), "percent".
function Light.format(ctl, v, mode)
    if mode == "off" then return nil end
    local lo, hi = ctl.range()
    if mode == "percent" then
        if hi <= lo then return "0%" end
        return string.format("%d%%", math.floor((v - lo) / (hi - lo) * 100 + 0.5))
    end
    return tostring(math.floor(v + 0.5))
end

function Light.step(ctl, step_pct)
    local lo, hi = ctl.range()
    return math.max(1, math.floor((hi - lo) * (step_pct or 5) / 100 + 0.5))
end

-- ---------------------------------------------------------------------------
-- Glyphs (the Nerd Font symbols KOReader bundles; Bookshelf's start menu uses
-- the same font for its icons, so shortcuts and start menu look alike)
-- ---------------------------------------------------------------------------

M.GLYPH = {
    sun = "\u{F185}", moon = "\u{F186}", bookmark = "\u{F02E}", search = "\u{F002}",
    list = "\u{F03A}", grid = "\u{F00A}", grid_large = "\u{F009}", info = "\u{F05A}",
    wifi = "\u{F1EB}", calendar = "\u{F073}", refresh = "\u{F021}", cloud = "\u{F0C2}",
    globe = "\u{F0AC}", heart = "\u{F004}", folder = "\u{F07B}", book = "\u{F02D}",
    cart = "\u{F07A}",
    home = "\u{F015}", bars = "\u{F0C9}", power = "\u{F011}", font = "\u{F031}",
    thermometer = "\u{F2C9}", files = "\u{F0C5}", sliders = "\u{F1DE}", chart = "\u{F080}",
    star = "\u{F005}", tags = "\u{F02C}", clock = "\u{F017}", cog = "\u{F013}", rotate = "\u{F01E}",
    camera = "\u{F030}", dictionary = "\u{F1AB}",
    puzzle = "\u{F12E}", plug = "\u{F1E6}", bolt = "\u{F0E7}", flag = "\u{F024}",
    music = "\u{F001}", download = "\u{F019}", upload = "\u{F093}", terminal = "\u{F120}",
    rss = "\u{F09E}", key = "\u{F084}", bell = "\u{F0F3}", pencil = "\u{F040}",
}

function M.symbolFace(size)
    return Font:getFace("symbols", size)
end

--- Font:getFace sizes are scaled for the screen already: convert pixels back.
function M.ptForPx(px)
    local k = Screen:scaleBySize(1000) / 1000
    return math.max(6, math.floor(px / k + 0.5))
end

-- ---------------------------------------------------------------------------
-- Widget: brightness / warmth slider (one line:  ☀  [−] ━━━●━━━ [+]  50%)
-- ---------------------------------------------------------------------------

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

--[[ kind ("brightness"|"warmth"), width, buttons (bool), value ("off"|"level"|"percent"),
     step (percent of range), show_label (bool: the ☀ / 🌡 glyph), background (card colour) ]]
local LightSlider = InputContainer:extend{
    kind = "brightness", width = nil, buttons = true, value = "percent", step = 5,
    show_label = true, background = WHITE,
}
M.LightSlider = LightSlider

function LightSlider:init()
    self.ctl = Light.control(self.kind)
    self.height = S(40)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.f_value, self.value_bold = M.boldFace(15)
    self.f_glyph, self.glyph_bold = M.boldFace(19)
    local range = function() return self.dimen end
    self.ges_events = {
        LSTap = { GestureRange:new{ ges = "tap", range = range } },
        LSHold = { GestureRange:new{ ges = "hold", range = range } },
        LSTouch = { GestureRange:new{ ges = "touch", range = range } },
        LSPan = { GestureRange:new{ ges = "pan", range = range } },
        LSRelease = { GestureRange:new{ ges = "pan_release", range = range } },
        LSHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        LSHoldRelease = { GestureRange:new{ ges = "hold_release", range = range } },
    }
end

function LightSlider:getSize() return Geom:new{ w = self.width, h = self.height } end

function LightSlider:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    -- clear first: a repaint after a change must not draw over the old value
    bb:paintRect(x, y, self.width, self.height, self.background or WHITE)
    local lo, hi = self.ctl.range()
    local v = self.ctl.get() or lo
    local h, w = self.height, self.width
    local cx = x
    -- the glyph that names the slider (☀ brightness, 🌡 warmth)
    if self.show_label then
        local g = self.kind == "warmth" and M.GLYPH.thermometer or M.GLYPH.sun
        local t = TextWidget:new{ text = g, face = M.symbolFace(22), fgcolor = BLACK }
        local sz = t:getSize()
        t:paintTo(bb, cx + math.floor((S(28) - sz.w) / 2), y + math.floor((h - sz.h) / 2))
        t:free()
        cx = cx + S(28) + S(8)
    end
    -- the value on the right
    local right = x + w
    local val = Light.format(self.ctl, v, self.value)
    if val then
        local vw = Look.textWidth("100%", 15)
        Look.label(bb, val, right - vw, y, vw, h, 15, { align = "right" })
        right = right - vw - S(10)
    end
    local b = S(32)
    local by = y + math.floor((h - b) / 2) - S(1)
    local bx0, bx1 = cx, right
    if self.buttons then
        right = right - Look.SHADOW_SMALL
        Look.button(bb, cx, by, b, b, "\u{2212}", { size = 16, down = self.pressed_btn == "minus" })
        Look.button(bb, right - b, by, b, b, "+", { size = 16, down = self.pressed_btn == "plus" })
        self.minus_r = Geom:new{ x = cx, y = y, w = b, h = h }
        self.plus_r = Geom:new{ x = right - b, y = y, w = b, h = h }
        bx0, bx1 = cx + b + S(12), right - b - S(12)
    else
        self.minus_r, self.plus_r = nil, nil
        bx0, bx1 = cx + S(8), right - S(8)
    end
    local bh = S(18)
    local frac = hi > lo and (v - lo) / (hi - lo) or 0
    local ix, iw = Look.track(bb, bx0, y + math.floor((h - bh) / 2), bx1 - bx0, bh, frac)
    self.bar = { x = ix, w = iw, r = Geom:new{ x = bx0 - S(10), y = y, w = bx1 - bx0 + S(20), h = h } }
    local kx = ix + math.floor(iw * frac + 0.5)
    Look.handle(bb, kx, y + math.floor(h / 2) - S(1), S(30), self.dragging)
end

function LightSlider:refresh(kind)
    -- repaint the card it sits on too (so the background stays its colour)
    local target = self.card_widget or self
    local d = target.dimen or self.dimen
    UIManager:widgetRepaint(target, d.x, d.y)
    UIManager:setDirty(nil, kind or "ui", d)
end

function LightSlider:setFromX(x)
    local lo, hi = self.ctl.range()
    local frac = math.max(0, math.min(1, (x - self.bar.x) / math.max(1, self.bar.w)))
    self.ctl.set(lo + math.floor(frac * (hi - lo) + 0.5))
end

function LightSlider:onLSTap(_, ges)
    local pos = ges.pos
    if not self.bar then return true end
    local lo = self.ctl.range()
    local step = Light.step(self.ctl, self.step)
    if inside(pos, self.minus_r) then
        self.ctl.set((self.ctl.get() or lo) - step)
    elseif inside(pos, self.plus_r) then
        self.ctl.set((self.ctl.get() or lo) + step)
    elseif inside(pos, self.bar.r) then
        self:setFromX(pos.x)
    else
        return true
    end
    self:refresh()
    return true
end

function LightSlider:onLSHold(_, ges)
    -- hold − / + : the minimum / maximum
    local lo, hi = self.ctl.range()
    if inside(ges.pos, self.minus_r) then self.ctl.set(lo) self:refresh()
    elseif inside(ges.pos, self.plus_r) then self.ctl.set(hi) self:refresh() end
    return true
end

function LightSlider:onLSTouch(_, ges)
    if self.bar and inside(ges.pos, self.bar.r) then self.dragging = true end
    return true
end

function LightSlider:onLSPan(_, ges)
    local start = ges.start_pos or ges.pos
    if self.bar and (self.dragging or inside(start, self.bar.r)) then
        self.dragging = true
        self:setFromX(ges.pos.x)
        self:refresh("fast")
    end
    return true
end
LightSlider.onLSHoldPan = LightSlider.onLSPan

function LightSlider:onLSRelease(_, ges)
    if self.dragging then
        self.dragging = false
        self:setFromX(ges.pos.x)
        self:refresh()
    end
    return true
end
LightSlider.onLSHoldRelease = LightSlider.onLSRelease

-- ---------------------------------------------------------------------------
-- Chips (Bookshelf's chip buttons) and Kobo-style mini menus
-- ---------------------------------------------------------------------------

M.GLYPH.chevron = "\u{F054}"

--- The battery glyph for the current charge (or a bolt while charging).
function M.GLYPH.battery()
    local ok, lvl, charging = pcall(function()
        local p = Device:getPowerDevice()
        return p:getCapacity(), p:isCharging()
    end)
    if ok and charging then return "\u{F0E7}" end
    local levels = { "\u{F244}", "\u{F243}", "\u{F242}", "\u{F241}", "\u{F240}" }
    if not ok or type(lvl) ~= "number" then return levels[5] end
    return levels[math.max(1, math.min(5, math.floor(lvl / 25) + 1))]
end

-- ---- rows used inside a mini menu ----------------------------------------

local function rowTap(w)
    local range = function() return w.dimen end
    w.ges_events = { TapRow = { GestureRange:new{ ges = "tap", range = range } } }
end

--- A section heading: bold grey capitals (Bookshelf's section label), with an
--- optional value on the right.
local MenuTitle = require("ui/widget/widget"):extend{ width = nil, text = "", right = nil }
M.MenuTitle = MenuTitle
function MenuTitle:init()
    self.height = S(28)
    self.f, self.b = M.boldFace(12.5)
    self.fr, self.br = M.boldFace(14)
end
function MenuTitle:getSize() return Geom:new{ w = self.width, h = self.height } end
function MenuTitle:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local right = type(self.right) == "function" and self.right() or self.right
    Look.heading(bb, self.text, x, y, self.width, self.height, right)
end

--- Text ............ [✓]   (tap anywhere toggles)
local CheckRow = InputContainer:extend{ width = nil, text = "", checked = nil, toggle = nil, enabled = nil }
M.CheckRow = CheckRow
function CheckRow:init()
    self.height = S(46)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.f = M.face(17)
    self.ff, self.fb = M.boldFace(15)
    rowTap(self)
end
function CheckRow:getSize() return Geom:new{ w = self.width, h = self.height } end
function CheckRow:isEnabled() return not self.enabled or self.enabled() end
function CheckRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local en = self:isEnabled()
    M.drawText(bb, type(self.text) == "function" and self.text() or self.text, self.f, x, y, self.height,
        en and BLACK or GRAY_9, self.width - S(40))
    local d = S(26)
    local on = self.checked and self.checked()
    local cx, cy = x + self.width - d, y + math.floor((self.height - d) / 2)
    M.card(bb, cx, cy, d, d, { background = on and BLACK or WHITE, color = en and BLACK or GRAY_9,
        shadow = en and S(2) or 0 })
    if on then M.drawTextCentered(bb, "✓", self.ff, cx, cy, d, d, WHITE, self.fb) end
end
function CheckRow:onTapRow()
    if not self:isEnabled() then return true end
    if self.toggle then self.toggle() end
    -- the state may change a moment later (Wi-Fi): repaint now and shortly after
    local function again()
        if self.dimen and self.dimen.x then
            UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
            UIManager:setDirty(nil, "ui", self.dimen)
        end
    end
    again()
    UIManager:scheduleIn(1, again)
    UIManager:scheduleIn(3, again)
    return true
end

--- Text ................ ›   (tap: close the menu, then act)
local ActionRow = InputContainer:extend{ width = nil, text = "", callback = nil, menu = nil, chevron = true }
M.ActionRow = ActionRow
function ActionRow:init()
    self.height = S(46)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.f = M.face(17)
    rowTap(self)
end
function ActionRow:getSize() return Geom:new{ w = self.width, h = self.height } end
function ActionRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, self.pressed and BLACK or WHITE)
    M.drawText(bb, self.text, self.f, x, y, self.height, self.pressed and WHITE or BLACK,
        self.width - (self.chevron and S(30) or 0))
    if not self.chevron then return end
    local t = TextWidget:new{ text = M.GLYPH.chevron, face = M.symbolFace(11), fgcolor = self.pressed and WHITE or DARK }
    local sz = t:getSize()
    t:paintTo(bb, x + self.width - sz.w - S(4), y + math.floor((self.height - sz.h) / 2))
    t:free()
end
function ActionRow:onTapRow()
    local cb, menu = self.callback, self.menu
    if menu then UIManager:close(menu) end
    if cb then UIManager:nextTick(function()
        pcall(function() UIManager:forceRePaint() end)
        cb()
    end) end
    return true
end

--- A full-width retro button: [ ALL SETTINGS        › ] on a hard shadow.
--- Tap: pressed for a moment, the menu closes, then it acts.
local ButtonRow = InputContainer:extend{ width = nil, text = "", callback = nil, menu = nil, chevron = true }
M.ButtonRow = ButtonRow
function ButtonRow:init()
    self.btn_h = S(40)
    self.height = self.btn_h + Look.SHADOW_SMALL + S(4)
    self.dimen = Geom:new{ w = self.width, h = self.height }
    rowTap(self)
end
function ButtonRow:getSize() return Geom:new{ w = self.width, h = self.height } end
function ButtonRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local w = self.width - Look.SHADOW_SMALL
    Look.button(bb, x, y, w, self.btn_h, nil, { down = self.pressed, paint = function(bb2, bx, by, bw, bh, ink)
        Look.label(bb2, self.text, bx + S(14), by, bw - S(50), bh, 14, { color = ink })
        if self.chevron then Look.label(bb2, "\u{203A}", bx + bw - S(30), by, S(16), bh, 18, { color = ink }) end
    end })
end
function ButtonRow:onTapRow()
    self.pressed = true
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, "fast", self.dimen)
    UIManager:forceRePaint()
    self.pressed = false
    return ActionRow.onTapRow(self)
end


--- A line of information (grey).
local InfoRow = require("ui/widget/widget"):extend{ width = nil, text = "" }
M.InfoRow = InfoRow
function InfoRow:init()
    self.height = S(30)
    self.f = M.face(15)
end
function InfoRow:getSize() return Geom:new{ w = self.width, h = self.height } end
function InfoRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local text = type(self.text) == "function" and self.text() or self.text
    bb:paintRect(x, y, self.width, self.height, WHITE) -- (it's redrawn in place when what it says changes)
    M.drawText(bb, text or "", self.f, x, y, self.height, DARK, self.width)
end

local Hairline = require("ui/widget/widget"):extend{ width = nil }
M.Hairline = Hairline
function Hairline:getSize() return Geom:new{ w = self.width, h = S(13) } end
function Hairline:paintTo(bb, x, y)
    bb:paintRect(x, y + S(6), self.width, math.max(1, Size.line.thin), LIGHT)
end

-- ---- the mini menu (Kobo-style drop-down from a chip) ----------------------

local VerticalGroup = require("ui/widget/verticalgroup")

local ChipMenu = InputContainer:extend{
    name = "bookshelfos_menu",
    anchor = nil,      -- Geom of the chip
    width = nil,
    build = nil,       -- function(menu, inner_w) -> { row widgets }
    on_close = nil,
}
M.ChipMenu = ChipMenu

function ChipMenu:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.pad = S(16)
    self.shadow = S(3)
    self.caret = S(10)
    local w = math.min(self.width or S(340), sw - 2 * S(10))
    local inner_w = w - 2 * (M.line() + self.pad)
    self.rows = VerticalGroup:new{ align = "left" }
    for _i, r in ipairs(self.build(self, inner_w) or {}) do table.insert(self.rows, r) end
    -- registered as our child so its rows (sliders, switches) get the gestures
    self[1] = self.rows
    local h = self.rows:getSize().h + 2 * (M.line() + S(10))
    local a = self.anchor or Geom:new{ x = S(10), y = S(60), w = S(40), h = S(40) }
    local acx = a.x + math.floor(a.w / 2)
    local x = math.max(S(10), math.min(sw - S(10) - w - self.shadow, acx - math.floor(w / 3)))
    -- below the chip if it fits, else above it
    local below = a.y + a.h + self.caret + h + S(10) <= sh
    local y = below and (a.y + a.h + self.caret) or (a.y - self.caret - h)
    self.below = below
    self.card_r = Geom:new{ x = x, y = y, w = w, h = h }
    self.acx = math.max(x + S(18), math.min(x + w - S(18), acx))
    local range = function() return self.dimen end
    self.ges_events = {
        MenuTap = { GestureRange:new{ ges = "tap", range = range } },
        MenuSwipe = { GestureRange:new{ ges = "swipe", range = range } },
        MenuHold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function ChipMenu:region()
    local c = self.card_r
    local top = self.below and (c.y - self.caret) or c.y
    return Geom:new{ x = c.x, y = top, w = c.w + self.shadow, h = c.h + self.caret + self.shadow }
end

function ChipMenu:paintTo(bb, x, y)
    local c = self.card_r
    M.card(bb, c.x, c.y, c.w, c.h, { shadow = self.shadow, radius = S(6) })
    -- the caret pointing at the chip (outlined, like the card)
    local t = M.line()
    local n = self.caret
    for i = 0, n do
        local yy = self.below and (c.y - n + i) or (c.y + c.h - 1 + n - i)
        bb:paintRect(self.acx - i, yy, 2 * i + 1, 1, BLACK)
        local inner = i - t * 2
        if inner >= 0 then bb:paintRect(self.acx - inner, yy, 2 * inner + 1, 1, WHITE) end
    end
    -- open the card's edge under the caret
    local gap_y = self.below and c.y or (c.y + c.h - t)
    bb:paintRect(self.acx - n + t * 2, gap_y, 2 * (n - t * 2) + 1, t, WHITE)
    self.rows:paintTo(bb, c.x + t + self.pad, c.y + t + S(10))
end

function ChipMenu:onShow()
    UIManager:setDirty(self, function() return "ui", self:region() end)
    return true
end

function ChipMenu:onCloseWidget()
    local r = self:region()
    UIManager:setDirty(nil, function() return "ui", r end)
    if self.on_close then pcall(self.on_close) end
end

function ChipMenu:onMenuTap(_, ges)
    if not inside(ges.pos, self:region()) then UIManager:close(self) end
    return true
end
function ChipMenu:onMenuSwipe(_, ges)
    if not inside(ges.pos, self:region()) then UIManager:close(self) end
    return true
end
function ChipMenu:onMenuHold() return true end
function ChipMenu:onClose() UIManager:close(self) return true end

-- ---- the mini menus ---------------------------------------------------------

local Menus = {}
M.Menus = Menus

function Menus.light(menu, w, light_cfg)
    light_cfg = light_cfg or {}
    local rows = {}
    local function slider(kind)
        local sl = M.LightSlider:new{ kind = kind, width = w, buttons = light_cfg.buttons ~= false,
            value = light_cfg.value or "percent", step = light_cfg.step or 5, show_label = true }
        sl.card_widget = nil
        return sl
    end
    if Light.hasBrightness() then
        table.insert(rows, MenuTitle:new{ width = w, text = _("Brightness") })
        table.insert(rows, slider("brightness"))
    end
    if Light.hasWarmth() then
        table.insert(rows, MenuTitle:new{ width = w, text = _("Warmth") })
        table.insert(rows, slider("warmth"))
    end
    table.insert(rows, Hairline:new{ width = w })
    table.insert(rows, CheckRow:new{ width = w, text = _("Night mode"),
        checked = function() return G_reader_settings:isTrue("night_mode") end,
        toggle = function()
            UIManager:close(menu)
            UIManager:nextTick(function() UIManager:broadcastEvent(Event:new("ToggleNightMode")) end)
        end })
    return rows
end

--- KOReader's list of Wi-Fi networks. (Asked for plainly while connected,
--- KOReader only says "Connected to …": the list needs its long-press flag.
--- With Wi-Fi off, it's turned on first, then the list shows.)
function M.chooseNetwork()
    local NetworkMgr = require("ui/network/manager")
    local logger = require("logger")
    -- after the tap is over: the scan shows a box a stray tap would close
    UIManager:scheduleIn(0.3, function()
        local ok, err = pcall(function()
            if not NetworkMgr:isWifiOn() then
                NetworkMgr:toggleWifiOn(nil, true, true)
                return
            end
            local saved = NetworkMgr.wifi_toggle_long_press
            NetworkMgr.wifi_toggle_long_press = true
            local ok2, err2 = pcall(NetworkMgr.reconnectOrShowNetworkMenu, NetworkMgr, nil, true)
            NetworkMgr.wifi_toggle_long_press = saved
            if not ok2 then error(err2, 0) end
        end)
        if not ok then logger.warn("ShelfTechUI: choose a network failed:", err) end
    end)
end

function Menus.wifi(menu, w)
    local NetworkMgr = require("ui/network/manager")
    local Status = require("bos_status")
    local rows = {}
    -- what Wi-Fi is doing, in words, as it happens (the card stays up to date
    -- while it's open: no need to close and reopen it to see if it joined)
    local function status()
        local ph, ssid = Status.wifiPhase()
        if ph == "off" then return _("Wi-Fi is off") end
        if ph == "turning_on" then return _("Turning on…") end
        if ph == "connecting" then return _("Connecting…") end
        if ph == "turning_off" then return _("Turning off…") end
        if ph == "connected" then return ssid and T(_("Connected to %1"), ssid) or _("Connected") end
        return _("Not connected")
    end
    local check, info
    local function redraw()
        for _i, r in ipairs{ check, info } do
            if r and r.dimen and r.dimen.x then
                UIManager:widgetRepaint(r, r.dimen.x, r.dimen.y)
                UIManager:setDirty(nil, "ui", r.dimen)
            end
        end
    end
    local function shown()
        for _i, e in ipairs(UIManager._window_stack or {}) do if e.widget == menu then return true end end
        return false
    end
    local stop
    local function watch()
        if stop then stop() end
        stop = Status.watchWifi(redraw, shown)
    end
    table.insert(rows, MenuTitle:new{ width = w, text = _("Wi-Fi") })
    check = CheckRow:new{ width = w, text = _("Wi-Fi"),
        -- the switch shows where it's going, at once
        checked = function()
            local ph = Status.wifiPhase()
            return ph == "turning_on" or ph == "connecting" or ph == "connected" or ph == "idle"
        end,
        toggle = function()
            local on = NetworkMgr:isWifiOn()
            Status.wifiAsked(not on)
            redraw()
            UIManager:forceRePaint()
            UIManager:nextTick(function()
                UIManager:broadcastEvent(Event:new("ToggleWifi"))
                watch()
            end)
        end }
    table.insert(rows, check)
    info = InfoRow:new{ width = w, text = status }
    table.insert(rows, info)
    table.insert(rows, Hairline:new{ width = w })
    table.insert(rows, ActionRow:new{ width = w, menu = menu, text = _("Choose a network…"),
        callback = function() M.chooseNetwork() end })
    -- opened while it's already in between (toggled from somewhere else)
    if Status.wifiBusy() then watch() end
    return rows
end

--- A list of actions in the same drop-down card (the reading toolbar's ⋯).
--- items: { { text =, callback =, separator_before = bool }, ... }
function M.openList(items, anchor, on_close)
    local f = M.face(17)
    local widest = 0
    for _i, it in ipairs(items) do widest = math.max(widest, M.textWidth(it.text, f)) end
    local menu = ChipMenu:new{
        anchor = anchor,
        width = math.max(S(260), widest + 2 * S(16) + 2 * M.line() + S(24)),
        build = function(m, w)
            local rows = {}
            for _i, it in ipairs(items) do
                if it.separator_before and #rows > 0 then table.insert(rows, Hairline:new{ width = w }) end
                table.insert(rows, ActionRow:new{ width = w, menu = m, text = it.text,
                    callback = it.callback, chevron = false })
            end
            return rows
        end,
        on_close = on_close,
    }
    UIManager:show(menu)
    return menu
end

--- A touch answered at once, as a phone does: what was tapped flips to
--- black for a moment (a fast refresh of just that spot), then `fn` runs on
--- the next tick and `restore` (if given) redraws the spot. Big areas (a
--- whole page, an invisible corner) aren't flashed: `fn` just runs.
function M.press(rect, fn, restore)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local r = rect and Geom:new{ x = math.max(0, rect.x), y = math.max(0, rect.y), w = rect.w, h = rect.h }
    if r then
        r.w = math.min(r.w, sw - r.x)
        r.h = math.min(r.h, sh - r.y)
    end
    if not r or r.w <= 0 or r.h <= 0 or r.h > S(130) or (r.w * r.h) > (sw * S(130)) then
        fn()
        return
    end
    local ok = pcall(function()
        Screen.bb:invertRect(r.x, r.y, r.w, r.h)
        UIManager:setDirty(nil, "fast", r)
        UIManager:forceRePaint()
    end)
    UIManager:nextTick(function()
        fn()
        if ok and restore then pcall(restore, r) end
    end)
end

--- Open the drop-down menu `kind` ("light", "wifi") from what was tapped.
function M.openChipMenu(kind, anchor, opts)
    opts = opts or {}
    local builder = Menus[kind]
    if not builder then return false end
    local widths = { light = S(400), wifi = S(330) }
    local menu = ChipMenu:new{
        anchor = anchor, width = widths[kind],
        build = function(m, w) return builder(m, w, opts.light) end,
        on_close = opts.on_close,
    }
    UIManager:show(menu)
    return menu
end

return M
