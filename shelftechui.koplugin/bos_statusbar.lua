--[[
The status bar on Bookshelf home: Kobo-style chips across the top,
right-aligned, just above Bookshelf's own status line.

Which chips, their order and their long-press come from Settings →
ShelfTechUI → Home status bar (bos_controls). By default:

    ☼  Light      a menu under the chip: brightness, warmth, night mode
    ⌔  Wi-Fi      a menu: on/off, status, choose a network   (filled while on)
    ⚙  Settings   the Settings app

A chip stays filled while its menu is open.
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")

local Controls = require("bos_controls")
local Store = require("bos_settings_store")
local UI = require("bos_ui")
local S, BLACK, WHITE = UI.S, UI.BLACK, UI.WHITE

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function glyphOf(c)
    local g = c.glyph
    if type(g) == "function" then return g() end
    return g
end

local StatusBar = InputContainer:extend{
    width = nil,
}

function StatusBar:init()
    self.labels = Store.get("home_chip_labels") == true
    self.chip_h = S(40)
    self.height = self.chip_h
    self.gap = S(8)
    self.pad = S(12)
    self.glyph_pt = UI.ptForPx(self.chip_h * 0.48)
    -- retro: monospaced capitals, square chips with a hard shadow
    local Font = require("ui/font")
    self.shadow = S(3)
    self.f_text, self.text_bold = require("bos_look").mono(15), true
    self.f_label, self.label_bold = require("bos_look").mono(12), true
    self.chips = self.chips or Controls.shown("home")
    self:layout()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    local range = function() return self.dimen end
    self.ges_events = {
        TapChip = { GestureRange:new{ ges = "tap", range = range } },
        HoldChip = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function StatusBar:getSize() return Geom:new{ w = self.width, h = self.height } end

--- What the chip says: its live text (battery %, time), else its name when
--- names are on, else nothing (icon only).
function StatusBar:chipText(c)
    local t = c.home.text and c.home.text()
    if t then return t, self.f_text, self.text_bold end
    if self.labels or not glyphOf(c) then return UI.caps(c.name), self.f_label, self.label_bold end
end

function StatusBar:chipWidth(c)
    local glyph_w = glyphOf(c) and math.floor(self.chip_h * 0.5) or 0
    local text, f, b = self:chipText(c)
    if not text then return math.max(self.chip_h + S(6), glyph_w + 2 * self.pad) end
    local tw = UI.textWidth(text, f, b)
    return self.pad + glyph_w + (glyph_w > 0 and S(6) or 0) + tw + self.pad
end

function StatusBar:paintChip(bb, c, x, y, w)
    local h = self.chip_h
    local active = false
    if c.active and not c.no_fill_home then
        local ok, v = pcall(c.active)
        active = ok and v and true or false
    end
    local sel = active or self.pressed == c
    local ink = sel and WHITE or BLACK
    -- pressed or on: pushed down onto its shadow
    local sh = self.shadow
    if sel then
        x, y = x + sh, y + sh
    else
        require("bos_look").shadow(bb, x, y, w, h, sh)
    end
    require("bos_look").box(bb, x, y, w, h, { border = UI.line(), fill = sel and BLACK or WHITE })
    local glyph = glyphOf(c)
    local glyph_w = glyph and math.floor(h * 0.5) or 0
    local text, f, b = self:chipText(c)
    local tw = text and UI.textWidth(text, f, b) or 0
    local content_w = glyph_w + ((glyph and text) and S(6) or 0) + tw
    local cx = x + math.floor((w - content_w) / 2)
    if glyph then
        local t = TextWidget:new{ text = glyph, face = UI.symbolFace(self.glyph_pt), fgcolor = ink }
        local sz = t:getSize()
        t:paintTo(bb, cx + math.floor((glyph_w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
        t:free()
    end
    if text then
        UI.drawText(bb, text, f, cx + glyph_w + (glyph and S(6) or 0), y, h, ink, tw + S(2), b)
    end
    c._rect = Geom:new{ x = sel and x - sh or x, y = sel and y - sh or y, w = w + sh, h = h + sh }
end

--- Rows of chips, each right-aligned (as Kobo's top bar). Too many for one
--- row: names go first, then the chips wrap onto another row.
function StatusBar:layout()
    local function measure()
        local widths, total = {}, 0
        for i, c in ipairs(self.chips) do
            widths[i] = c.spacer and 0 or self:chipWidth(c)
            total = total + widths[i] + ((i > 1 and not c.spacer) and self.gap or 0)
        end
        return widths, total
    end
    local widths, total = measure()
    if total > self.width and self.labels then
        self.labels = false
        widths, total = measure()
    end
    local rows, row, used = {}, {}, 0
    for i, c in ipairs(self.chips) do
        local need = widths[i] + ((#row > 0 and not c.spacer) and self.gap or 0)
        if #row > 0 and used + need + self.shadow > self.width then
            table.insert(rows, { items = row, w = used + self.shadow })
            row, used = {}, 0
            need = widths[i]
        end
        table.insert(row, { c = c, w = widths[i] })
        used = used + need
    end
    if #row > 0 then table.insert(rows, { items = row, w = used + self.shadow }) end
    self.rows = rows
    self.row_gap = S(8)
    self.height = math.max(1, #rows) * self.chip_h + math.max(0, #rows - 1) * self.row_gap + self.shadow
end

function StatusBar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    for r, row in ipairs(self.rows) do
        -- spacers share the free room; without one the row sits on the right
        local spacers = 0
        for _i, it in ipairs(row.items) do if it.c.spacer then spacers = spacers + 1 end end
        local free = math.max(0, self.width - row.w)
        local cx = x + (spacers == 0 and free or 0)
        local cy = y + (r - 1) * (self.chip_h + self.row_gap)
        local first = true
        for _i, it in ipairs(row.items) do
            if it.c.spacer then
                -- a spacer: pinstripes across its room
                local room = math.floor(free / spacers)
                local Retro = require("bos_retro")
                Retro.stripes(bb, cx + S(10), cy + math.floor((self.chip_h - S(14)) / 2), room - S(20), S(14))
                cx = cx + room
            else
                if not first then cx = cx + self.gap end
                self:paintChip(bb, it.c, cx, cy, it.w)
                cx = cx + it.w
                first = false
            end
        end
    end
end

--- Only while the shelf is on top (a toast may be): a repaint must never draw
--- the bar over a window opened above it (Settings, a plugin's dialog…).
function StatusBar:onTop()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if type(w) == "table" then
            if w._launchReader then return true end
            local is_toast = w.toast or (package.loaded["ui/widget/notification"]
                and getmetatable(w) == package.loaded["ui/widget/notification"])
            if not is_toast then return false end
        end
    end
    return false
end

function StatusBar:repaint(kind)
    if not (self.dimen and self.dimen.x) then return end
    if not self:onTop() then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, kind or "ui", self.dimen)
end

function StatusBar:chipAt(pos)
    for _i, c in ipairs(self.chips) do
        if not c.spacer and c._rect and inside(pos, c._rect) then return c end
    end
end

--- Flash a chip, as a button press.
function StatusBar:flash(c)
    self.pressed = c
    self:repaint("fast")
    UIManager:forceRePaint()
    self.pressed = nil
end

function StatusBar:onTapChip(_, ges)
    local c = self:chipAt(ges.pos)
    if not c then return false end
    if c.home.menu then
        self.pressed = c
        self:repaint("fast")
        local bar = self
        UI.openChipMenu(c.home.menu, c._rect, { on_close = function()
            bar.pressed = nil
            bar:repaint()
        end })
        return true
    end
    self:flash(c)
    UIManager:nextTick(function()
        Controls.tap("home", c, { anchor = c._rect })
        self:afterAction(c)
    end)
    return true
end

--- After a chip's action: the chip lifts again (one repaint; a chip that
--- shows a state, as Wi-Fi does, looks once more when the state has settled).
function StatusBar:afterAction(c)
    self:repaint()
    if c.slow and c.active then UIManager:scheduleIn(2, function() self:repaint() end) end
end

function StatusBar:onHoldChip(_, ges)
    local c = self:chipAt(ges.pos)
    if not c then return false end
    self:flash(c)
    UIManager:nextTick(function()
        Controls.hold("home", c, { anchor = c._rect })
        self:afterAction(c)
    end)
    return true
end

return StatusBar
