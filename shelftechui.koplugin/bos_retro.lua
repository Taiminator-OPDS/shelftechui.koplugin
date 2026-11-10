--[[
The retro side of the Bookshelf look ("retro tech"): the chrome the
dictionary window introduced, shared by KOReader's system pop-ups, the file
search, KOReader's main menu and the notifications.

  stripes(bb, …)        the pinstripes of a title bar
  TitleStrip            a pinstriped title bar: close box, caption in a white
                        box over the stripes, a 2px rule under it
  window(dialog, cap)   a KOReader dialog (anything with .movable[1] as its
                        frame) as a retro window: square, 2px outline, hard
                        shadow, a TitleStrip on top
  pinstripeTitleBar(tb) pinstripes in a TitleBar's free room, a 2px rule
  installDialogs()      InfoMessage and ConfirmBox
  installMenu()         KOReader's main menu (the tabs of icons)
  installSearch()       the file search dialog
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local UI = require("bos_ui")
local Store = require("bos_settings_store")
local S = UI.S
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

M.SHADOW = S(5)

local function on(key) return Store.get("skin_" .. key) ~= false end

function M.stripes(bb, x, y, w, h)
    if w < S(16) or h <= 0 then return end
    require("bos_look").stripes(bb, x, y, w, h)
end

local function textW(text, size)
    local tw = TextWidget:new{ text = text, face = require("bos_look").mono(size), bold = true }
    local w = tw:getSize().w
    tw:free()
    return w
end

local function drawText(bb, text, x, y, w, h, size, color)
    local tw = TextWidget:new{ text = text, face = require("bos_look").mono(size), bold = true,
        fgcolor = color or BLACK, max_width = w }
    local s = tw:getSize()
    tw:paintTo(bb, x + math.floor((w - s.w) / 2), y + math.floor((h - s.h) / 2))
    tw:free()
end

-- ---------------------------------------------------------------------------

local TitleStrip = InputContainer:extend{
    width = 0, height = nil, caption = "", close_callback = nil, size = 13,
}
M.TitleStrip = TitleStrip

function TitleStrip:init()
    self.height = self.height or S(30)
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    if self.close_callback then
        self.ges_events = { TapStrip = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
    end
end

function TitleStrip:getSize() return Geom:new{ w = self.width, h = self.height } end

function TitleStrip:paintTo(bb, x, y)
    local w, h = self.width, self.height
    self.dimen.x, self.dimen.y = x, y
    bb:paintRect(x, y, w, h, WHITE)
    M.stripes(bb, x + S(4), y + S(7), w - S(8), h - S(14))
    local left = x + S(8)
    if self.close_callback then
        local sz = S(16)
        local cx, cy = x + S(10), y + math.floor((h - sz) / 2)
        bb:paintRect(cx - S(4), y + S(4), sz + S(8), h - S(8), WHITE)
        bb:paintRect(cx, cy, sz, sz, BLACK)
        bb:paintRect(cx + S(2), cy + S(2), sz - S(4), sz - S(4), WHITE)
        self.close_rect = Geom:new{ x = cx - S(8), y = y, w = sz + S(16), h = h }
        left = cx + sz + S(10)
    end
    local cap = require("bos_look").case(tostring(self.caption or ""))
    if cap ~= "" then
        local avail = x + w - S(10) - left
        local cw = math.min(avail, textW(cap, self.size) + S(20))
        local cx = left + math.floor((avail - cw) / 2)
        bb:paintRect(cx, y + S(4), cw, h - S(8), WHITE)
        drawText(bb, cap, cx + S(10), y, cw - S(20), h, self.size)
    end
    bb:paintRect(x, y + h - UI.line(), w, UI.line(), BLACK)
end

function TitleStrip:onTapStrip(_, ges)
    local r = self.close_rect
    if r and ges.pos.x >= r.x and ges.pos.x < r.x + r.w and ges.pos.y >= r.y and ges.pos.y < r.y + r.h then
        self.close_callback()
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------

--- A widget and its hard shadow, the shadow inside its size (so refreshes and
--- "tap outside" cover it).
local Shadowed = WidgetContainer:extend{ shadow = nil }
M.Shadowed = Shadowed

function Shadowed:getSize()
    local s = self[1]:getSize()
    local sh = self.shadow or M.SHADOW
    return Geom:new{ w = s.w + sh, h = s.h + sh }
end

function Shadowed:paintTo(bb, x, y)
    local s = self[1]:getSize()
    local sh = self.shadow or M.SHADOW
    self.dimen = Geom:new{ x = x, y = y, w = s.w + sh, h = s.h + sh }
    local Look = require("bos_look")
    Look.shadow(bb, x, y, s.w, s.h, sh)
    self[1]:paintTo(bb, x, y)
    Look.decorate(bb, x, y, s.w, s.h)
end

--- A dialog as a retro window.
function M.window(dialog, caption, close_callback)
    local movable = dialog.movable
    local frame = movable and movable[1]
    if not frame or frame._bos_retro then return end
    frame._bos_retro = true
    frame.radius = require("bos_look").RADIUS
    frame.bordersize = 0
    local inner_w = frame:getSize().w
    local strip = TitleStrip:new{ width = inner_w, caption = caption, close_callback = close_callback }
    local window = FrameContainer:new{
        bordersize = UI.line(), color = BLACK, radius = require("bos_look").RADIUS, margin = 0, padding = 0, background = WHITE,
        VerticalGroup:new{ align = "left", strip, frame },
    }
    window._bos_retro = true
    movable[1] = Shadowed:new{ window }
    return window
end

--- Pinstripes in a TitleBar's free room, and a heavier rule under it.
function M.pinstripeTitleBar(tb)
    if not tb or tb._bos_stripes then return end
    tb._bos_stripes = true
    local orig = tb.paintTo
    tb.paintTo = function(self, bb, x, y)
        orig(self, bb, x, y)
        local ok, err = pcall(function()
            local th = self:getHeight()
            local w = self:getSize().w
            local tw = self.title_widget
            local tws = tw and tw:getSize() or Geom:new{ w = 0, h = 0 }
            local multi = tw and tw.text and tw.face and not tw.forced_width and tws.h > 0
                and getmetatable(tw) == require("ui/widget/textboxwidget")
            if multi then
                -- a text box is as wide as its room: measure the words
                local m = TextWidget:new{ text = tw.text, face = tw.face, bold = tw.bold }
                tws = m:getSize()
                m:free()
            end
            local right = (self.right_button and self.right_button.dimen and self.right_button.dimen.x)
                or (x + w - (self.has_right_icon and S(60) or S(4)))
            right = right - S(12)
            local band = S(14)
            local top = y + math.floor((th - band) / 2)
            if multi or self.info_text or self.subtitle then
                -- on the title's line, not the middle of the bar
                top = y + (self.title_top_padding or 0) + math.floor((tws.h - band) / 2)
                if self.title_top_padding == nil then top = top + S(6) end
            end
            if self.align == "left" then
                local lead = (self.inner_title_group and self.inner_title_group[1] and self.inner_title_group[1].width)
                    or (self.title_h_padding or S(16))
                local left = x + lead + tws.w + S(14)
                M.stripes(bb, left, top, right - left, band)
            else
                local tx = x + math.floor((w - tws.w) / 2)
                local left = x + S(16) + ((self.has_left_icon and S(44)) or 0)
                M.stripes(bb, left, top, tx - S(12) - left, band)
                M.stripes(bb, tx + tws.w + S(12), top, right - (tx + tws.w + S(12)), band)
            end
            bb:paintRect(x, y + th - UI.line(), w, UI.line(), BLACK)
        end)
        if not ok then logger.warn("ShelfTechUI: title stripes:", err) end
    end
end

-- ---------------------------------------------------------------------------
-- System pop-ups
-- ---------------------------------------------------------------------------

function M.installDialogs()
    local InfoMessage = require("ui/widget/infomessage")
    if not InfoMessage._bos_retro then
        InfoMessage._bos_retro = true
        local orig = InfoMessage.init
        InfoMessage.init = function(self, ...)
            local r = orig(self, ...)
            if on("dialogs") then
                local ok, err = pcall(M.window, self, _("Notice"), function() self:onTapClose() end)
                if not ok then logger.warn("ShelfTechUI: retro notice:", err) end
                -- at the top of the screen, like the small notifications
                -- (not over the middle of the page)
                pcall(function()
                    local TopContainer = require("ui/widget/container/topcontainer")
                    local CenterContainer = require("ui/widget/container/centercontainer")
                    local VerticalSpan = require("ui/widget/verticalspan")
                    local h = self.movable:getSize().h
                    self[1] = TopContainer:new{
                        dimen = Screen:getSize(),
                        VerticalGroup:new{
                            VerticalSpan:new{ width = S(12) },
                            CenterContainer:new{ dimen = Geom:new{ w = Screen:getWidth(), h = h }, self.movable },
                        },
                    }
                end)
            end
            return r
        end
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    if not ConfirmBox._bos_retro then
        ConfirmBox._bos_retro = true
        local orig = ConfirmBox.init
        ConfirmBox.init = function(self, ...)
            if not on("dialogs") then return orig(self, ...) end
            local Skin = package.loaded["bos_skin"]
            local r
            if Skin and Skin.scoped then r = Skin.scoped("retro", {}, orig, self, ...) else r = orig(self, ...) end
            -- no close box: its Cancel button is the way out
            local ok, err = pcall(M.window, self, _("Confirm"), nil)
            if not ok then logger.warn("ShelfTechUI: retro confirm:", err) end
            return r
        end
    end
end

-- ---------------------------------------------------------------------------
-- KOReader's main menu (the tabs of icons)
-- ---------------------------------------------------------------------------

function M.installMenu()
    local TouchMenu = require("ui/widget/touchmenu")
    if TouchMenu._bos_retro then return end
    TouchMenu._bos_retro = true
    local orig = TouchMenu.init
    TouchMenu.init = function(self, ...)
        local r = orig(self, ...)
        if not on("menu") then return r end
        local ok, err = pcall(function()
            local bar = self.bar
            -- the frame: square, a heavy outline
            local f = self.menu_frame
            f.radius = require("bos_look").RADIUS
            f.bordersize = UI.line()
            f.color = BLACK
            -- no stock separators: the selected tab is inverted instead
            local function quiet()
                for _i, sep in ipairs(bar.icon_seps or {}) do sep.style = "none" end
                if bar.bar_sep then bar.bar_sep.style = "none" end
            end
            for k, ib in ipairs(bar.icon_widgets or {}) do
                local cb = ib.callback
                ib.callback = function(...)
                    bar._bos_sel = k
                    local res = cb(...)
                    quiet()
                    return res
                end
            end
            quiet()
            -- (the first tab was opened during init, before the wrap)
            bar._bos_sel = bar._bos_sel or self.last_index or self.cur_tab or 1
            local orig_paint = bar.paintTo
            bar.paintTo = function(b, bb, x, y)
                orig_paint(b, bb, x, y)
                local h = b.height or b:getSize().h
                local w = b.width or b:getSize().w
                -- pinstripes in the stretch before the last tab
                local last = b.icon_widgets[#b.icon_widgets]
                local before = b.icon_widgets[#b.icon_widgets - 1]
                if last and before and last.dimen and before.dimen then
                    local sx = before.dimen.x + before.dimen.w + S(10)
                    local ex = last.dimen.x - S(10)
                    M.stripes(bb, sx, y + math.floor(h / 2) - S(8), ex - sx, S(16))
                end
                -- the open tab: inverted
                local sel = b.icon_widgets[b._bos_sel or 1]
                if sel and sel.dimen then
                    bb:invertRect(sel.dimen.x, y + S(3), sel.dimen.w, h - S(3) - UI.line())
                end
                bb:paintRect(x, y + h - UI.line(), w, UI.line(), BLACK)
            end
            -- the footer's text in the retro face
            if self.page_info_text then
                self.page_info_text.face = require("bos_look").mono(16)
                self.page_info_text.bold = true
            end
        end)
        if not ok then logger.warn("ShelfTechUI: retro menu:", err) end
        return r
    end
    -- keep the open tab current when the menu switches tabs by itself
    local orig_switch = TouchMenu.switchMenuTab
    TouchMenu.switchMenuTab = function(self, tab_num, ...)
        if self.bar then self.bar._bos_sel = tab_num end
        return orig_switch(self, tab_num, ...)
    end
end


--- InputDialogs created with `_bos_retro_wanted = true` become retro windows:
--- pinstriped title, square heavy frame, hard shadow.
function M.installRetroInput()
    local InputDialog = require("ui/widget/inputdialog")
    if InputDialog._bos_retro_input then return end
    InputDialog._bos_retro_input = true
    local orig_dialog = InputDialog.init
    InputDialog.init = function(self, ...)
        local r = orig_dialog(self, ...)
        if self._bos_retro_wanted then
            pcall(function()
                M.pinstripeTitleBar(self.title_bar)
                local f = self.dialog_frame or (self.movable and self.movable[1])
                if f then
                    f.radius = require("bos_look").RADIUS
                    f.bordersize = UI.line()
                    f.color = BLACK
                end
                if self.movable and self.movable[1] and not self.movable[1]._bos_shadowed then
                    local sh = Shadowed:new{ self.movable[1] }
                    sh._bos_shadowed = true
                    self.movable[1] = sh
                end
            end)
        end
        return r
    end
end

-- ---------------------------------------------------------------------------
-- File search
-- ---------------------------------------------------------------------------

function M.installSearch()
    local okF, FS = pcall(require, "apps/filemanager/filemanagerfilesearcher")
    if not (okF and FS) or FS._bos_retro then return end
    FS._bos_retro = true
    M.installRetroInput()
    local InputDialog = require("ui/widget/inputdialog")
    local orig_show = FS.onShowFileSearch
    FS.onShowFileSearch = function(fs, ...)
        if not on("search") then return orig_show(fs, ...) end
        local orig_new = InputDialog.new
        InputDialog.new = function(cls, o, ...)
            if type(o) == "table" then
                o._bos_retro_wanted = true
                -- a short title (room for the pinstripes); the question under it
                if o.title and not o.description then
                    o.description = o.title
                    o.title = _("File search")
                end
            end
            return orig_new(cls, o, ...)
        end
        local Skin = package.loaded["bos_skin"]
        local res = table.pack(pcall(function(...)
            if Skin and Skin.scoped then return Skin.scoped("retro", { title_line = false }, orig_show, fs, ...) end
            return orig_show(fs, ...)
        end, ...))
        InputDialog.new = orig_new
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, res.n)
    end
end

return M
