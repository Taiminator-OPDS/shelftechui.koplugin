--[[
The reading calendar (the Statistics plugin's month view), in the retro look
of the dictionary window:

  * the title bar with Bookshelf's bold title and pinstripes filling the room
    up to the close button, over a 2px rule
  * the day names in a black band, monospaced capitals in white
  * monospaced dates; today in a black cell
  * books as bars: black, white and dithered greys, each outlined
  * the month buttons as square retro buttons with a hard shadow

Only the look changes: the Statistics plugin builds and runs the calendar.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local logger = require("logger")

local UI = require("bos_ui")
local S = UI.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = { installed = false, month = nil }

local RETRO_SPANS = {
    { BLACK, WHITE },
    { WHITE, BLACK },
    { BLACK, Blitbuffer.COLOR_GRAY_D },
    { WHITE, Blitbuffer.COLOR_GRAY_5 },
    { BLACK, Blitbuffer.COLOR_GRAY_B },
    { WHITE, Blitbuffer.COLOR_GRAY_3 },
}

local function upvalue(fn, name)
    for i = 1, 80 do
        local n, v = debug.getupvalue(fn, i)
        if not n then return end
        if n == name then return v, i end
    end
end

local function stripes(bb, x, y, w, h)
    if w < S(20) then return end
    require("bos_look").stripes(bb, x, y, w, h)
end

--- A Button as a square retro button with a hard shadow.
local function retroButton(b)
    if not b or b._bos_retro then return end
    b._bos_retro = true
    local frame = b.frame or b[1]
    if frame then
        frame.radius = require("bos_look").RADIUS
        frame.bordersize = UI.line()
        frame.color = BLACK
        frame.background = WHITE
        frame.padding_left = S(8)
        frame.padding_right = S(8)
    end
    local orig = b.paintTo
    b.paintTo = function(self, bb, x, y)
        local f = self.frame or self[1]
        local s = f and f:getSize() or self:getSize()
        local sh = S(3)
        if self.enabled ~= false then require("bos_look").shadow(bb, x, y, s.w, s.h, sh) end
        return orig(self, bb, x, y)
    end
end

function M.restyle(view)
    -- the title bar: pinstripes up to the close button, a heavy rule under it
    local tb = view.title_bar
    if tb then
        local orig = tb.paintTo
        tb.paintTo = function(self, bb, x, y)
            orig(self, bb, x, y)
            pcall(function()
                local tw = self.title_widget
                local th = self:getHeight()
                local left = x + (self.title_h_padding or S(16)) + (tw and tw:getSize().w or 0) + S(14)
                local right = (self.right_button and self.right_button.dimen and self.right_button.dimen.x)
                    or (x + self:getSize().w - S(60))
                right = right - S(12)
                local band = S(16)
                stripes(bb, left, y + math.floor((th - band) / 2), right - left, band)
                bb:paintRect(x, y + th - S(2), self:getSize().w, S(2), BLACK)
            end)
        end
    end
    -- the day names: a black band, white monospaced capitals
    pcall(function()
        for _i, cell in ipairs(view.day_names) do
            local tw = cell[1] and cell[1][1]
            if tw and tw.text then
                tw.face = require("bos_look").mono(13)
                tw.fgcolor = WHITE
                tw:setText(require("bos_look").case(tostring(tw.text)))
            end
        end
        local orig = view.day_names.paintTo
        view.day_names.paintTo = function(self, bb, x, y)
            local s = self:getSize()
            bb:paintRect(x + view.outer_padding, y, s.w - view.outer_padding, s.h, BLACK)
            return orig(self, bb, x, y)
        end
    end)
    -- month buttons
    for _i, k in ipairs{ "page_info_first_chev", "page_info_left_chev", "page_info_right_chev",
                         "page_info_last_chev", "page_info_text" } do
        pcall(retroButton, view[k])
    end
    pcall(function()
        local t = view.page_info_text
        t.text_font_face = "stui_chrome"
        t.text_font_bold = true
    end)
end

function M.install()
    if M.installed then return true end
    local ok, CalendarView = pcall(require, "calendarview")
    if not ok or type(CalendarView) ~= "table" or type(CalendarView.init) ~= "function" then return false end
    M.installed = true
    local Store = require("bos_settings_store")
    local function on() return Store.get("skin_calendar") ~= false end

    -- the day cells
    local CalendarDay = upvalue(CalendarView._populateItems, "CalendarDay")
    if CalendarDay then
        local orig_day = CalendarDay.init
        CalendarDay.init = function(self, ...)
            local r = orig_day(self, ...)
            if self.filler or not on() then return r end
            pcall(function()
                local today = M.month == os.date("%Y-%m") and tonumber(self.daynum) == tonumber(os.date("%d"))
                local frame = self[1]
                frame.radius = require("bos_look").RADIUS
                if today then
                    frame.background = BLACK
                    frame.bordersize = UI.line()
                    self.daynum_w.fgcolor = WHITE
                    self.daynum_w:setText(" " .. tostring(self.daynum))
                end
            end)
            return r
        end
    end
    -- the book bars
    local CalendarWeek = upvalue(CalendarView._populateItems, "CalendarWeek")
    if CalendarWeek and type(CalendarWeek.update) == "function" then
        local spans, idx = upvalue(CalendarWeek.update, "SPAN_COLORS")
        local spans_rgb, idx_rgb = upvalue(CalendarWeek.update, "SPAN_COLORS_RGB")
        local orig_update = CalendarWeek.update
        CalendarWeek.update = function(self, ...)
            if not (on() and spans and idx) then return orig_update(self, ...) end
            debug.setupvalue(orig_update, idx, RETRO_SPANS)
            if idx_rgb then debug.setupvalue(orig_update, idx_rgb, RETRO_SPANS) end
            local res = table.pack(pcall(orig_update, self, ...))
            debug.setupvalue(orig_update, idx, spans)
            if idx_rgb then debug.setupvalue(orig_update, idx_rgb, spans_rgb) end
            if not res[1] then error(res[2], 0) end
            return unpack(res, 2, res.n)
        end
    end
    -- which month is being built (for "today")
    local orig_pop = CalendarView._populateItems
    CalendarView._populateItems = function(self, ...)
        M.month = self.cur_month
        return orig_pop(self, ...)
    end
    -- the view
    local orig_init = CalendarView.init
    CalendarView.init = function(self, ...)
        if not on() then return orig_init(self, ...) end
        self.font_face = "stui_chrome"
        local Skin = package.loaded["bos_skin"]
        local r
        if Skin and Skin.scoped then
            r = Skin.scoped("pill", { title_line = false }, orig_init, self, ...)
        else
            r = orig_init(self, ...)
        end
        local okR, err = pcall(M.restyle, self)
        if not okR then logger.warn("ShelfTechUI: calendar look:", err) end
        return r
    end
    return true
end

return M
