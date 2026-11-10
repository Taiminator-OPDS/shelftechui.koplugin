--[[
The sheet design (the text sheet's look, shared): what the dictionary and
KOReader's lists (Contents, Bookmarks, the page list, search results) are
built with, so they read as one family with Aa.

  STYLE           the tokens: margins, the black top rule, radius, strip and
                  control heights, label and chip sizes, the grey hairline
  Sheet           a sheet with a black rule and small rounded corners, from
                  the bottom (or the top) of the screen
  strip(cells,w)  a tab strip / segmented control: thin outline and dividers,
                  bold capitals, the selected cell filled black; icon cells
  chip(text)      an outlined value chip (bold)
  label(…)        "Name ............ [chip]", the text sheet's label line
  Tap             a tappable area (tap / hold callbacks)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local UI = require("bos_ui")
local S = UI.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY = Blitbuffer.COLOR_DARK_GRAY
local Screen = Device.screen

local M = {}

M.STYLE = {
    margin     = S(16),                 -- left/right inner margin of a sheet
    top_rule   = S(2),                  -- black rule along the sheet's edge
    radius     = 0,                     -- sheet corner radius (the retro look: square)
    strip_h    = S(42),                 -- tab strip height
    strip_line = Size.border.default,   -- strip / segmented outline
    control_h  = S(38),                 -- segmented strips, buttons
    label_size = 16,                    -- label text
    chip_size  = 14,                    -- chip text (bold)
    seg_size   = 15,                    -- strip text (bold capitals)
    line       = S(2),                  -- chip outline
    hairline   = Blitbuffer.COLOR_LIGHT_GRAY,
}
local STYLE = M.STYLE

local function face(size, bold)
    if bold then return (UI.boldFace(size)) end
    return UI.face(size)
end
M.face = face

-- ---------------------------------------------------------------------------

local Tap = InputContainer:extend{ width = 0, height = 0, callback = nil, hold_callback = nil, enabled = true }
M.Tap = Tap

function Tap:init()
    local sz = self[1] and self[1]:getSize()
    self.dimen = Geom:new{ w = sz and sz.w or self.width, h = sz and sz.h or self.height }
    local range = function() return self.dimen end
    self.ges_events = {
        TapIt = { GestureRange:new{ ges = "tap", range = range } },
        HoldIt = { GestureRange:new{ ges = "hold", range = range } },
    }
end

function Tap:onTapIt()
    if self.enabled == false or not self.callback then return self.enabled ~= false and self.callback ~= nil end
    self.callback()
    return true
end

function Tap:onHoldIt()
    if self.hold_callback then self.hold_callback() return true end
    return false
end

-- ---------------------------------------------------------------------------

--- A sheet: from the bottom ("bottom", rule along its top) or the top
--- ("top", rule along its bottom). The far edge runs off-screen, so only the
--- near corners are rounded.
local Sheet = WidgetContainer:extend{ from = "bottom" }
M.Sheet = Sheet

function Sheet:getSize()
    local s = self[1]:getSize()
    return Geom:new{ w = Screen:getWidth(), h = s.h + STYLE.top_rule }
end

function Sheet:paintTo(bb, x, y)
    local sz = self:getSize()
    local r, rule = STYLE.radius, STYLE.top_rule
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    if self.from == "top" then
        -- extend above the screen so the top corners don't show
        bb:paintRoundedRect(x, y - r, sz.w, sz.h + r, BLACK, r)
        bb:paintRoundedRect(x, y - r, sz.w, sz.h + r - rule, WHITE, r)
        self[1]:paintTo(bb, x, y)
    else
        bb:paintRoundedRect(x, y, sz.w, sz.h + r, BLACK, r)
        bb:paintRoundedRect(x, y + rule, sz.w, sz.h + r - rule, WHITE, r)
        self[1]:paintTo(bb, x, y + rule)
    end
end

-- ---------------------------------------------------------------------------

--- A tab strip / segmented control.
--- cells: { { text = | icon =, width = (fixed), selected, enabled, callback, hold_callback } }
--- opts: { height, size }
function M.strip(cells, w, opts)
    opts = opts or {}
    local h = opts.height or STYLE.strip_h
    local b = STYLE.strip_line
    local n = #cells
    local fixed, flex = 0, 0
    for _i, c in ipairs(cells) do
        if c.width then fixed = fixed + c.width else flex = flex + 1 end
    end
    local inner = w - 2 * b - (n - 1) * b
    local share = flex > 0 and math.floor((inner - fixed) / flex) or 0
    local extra = inner - fixed - share * flex
    -- one size for every label, the largest that fits (as the text sheet)
    local fsize = opts.size or STYLE.seg_size + 1
    for _ = 1, 6 do
        local fits = true
        for _i, c in ipairs(cells) do
            if c.text and not c.width then
                local tw = TextWidget:new{ text = UI.caps(c.text), face = face(fsize, true) }
                if tw:getSize().w > share - S(14) then fits = false end
                tw:free()
            end
        end
        if fits or fsize <= 12 then break end
        fsize = fsize - 1
    end
    local hg = HorizontalGroup:new{}
    local first_flex = true
    for i, c in ipairs(cells) do
        if i > 1 then table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = BLACK }) end
        local cw = c.width or share
        if not c.width and first_flex then cw = cw + extra first_flex = false end
        local sel = c.selected
        local inner_w
        if c.icon then
            inner_w = IconWidget:new{ icon = c.icon, width = S(24), height = S(24), invert = sel, alpha = true,
                dim = c.enabled == false }
        else
            inner_w = TextWidget:new{ text = UI.caps(c.text), face = face(fsize, true), max_width = cw - S(8),
                fgcolor = sel and WHITE or (c.enabled == false and GRAY or BLACK) }
        end
        local tap = Tap:new{
            width = cw, height = h, enabled = c.enabled ~= false,
            callback = c.callback, hold_callback = c.hold_callback,
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0, background = sel and BLACK or WHITE,
                CenterContainer:new{ dimen = Geom:new{ w = cw, h = h }, inner_w },
            },
        }
        c.tap = tap
        table.insert(hg, tap)
    end
    local frame = FrameContainer:new{ bordersize = b, margin = 0, padding = 0, color = BLACK, background = WHITE, hg }
    frame.bos_sheet_strip = true
    frame.cells = cells
    return frame
end

--- An outlined value chip.
function M.chip(text, opts)
    opts = opts or {}
    local enabled = opts.enabled ~= false
    local ink = enabled and BLACK or GRAY
    local tw = TextWidget:new{ text = text, face = face(STYLE.chip_size, true), fgcolor = opts.filled and WHITE or ink,
        max_width = opts.max_width }
    local th = tw:getSize().h
    return FrameContainer:new{
        bordersize = STYLE.line, radius = 0, color = ink, margin = 0,
        background = opts.filled and BLACK or WHITE,
        padding = 0, padding_left = S(10), padding_right = S(10), padding_top = S(1), padding_bottom = S(1),
        CenterContainer:new{ dimen = Geom:new{ w = tw:getSize().w, h = th }, tw },
    }
end

--- "Name ............ [chip]". left: text or a widget.
function M.label(left, w, chip_widget, opts)
    opts = opts or {}
    local h = opts.height or S(32)
    local chip_w = chip_widget and chip_widget:getSize().w or 0
    local lw = left
    if type(left) == "string" then
        lw = TextWidget:new{ text = left, face = face(opts.size or STYLE.label_size, opts.bold),
            max_width = w - chip_w - S(12), fgcolor = opts.color or BLACK }
    end
    local dim = Geom:new{ w = w, h = h }
    return OverlapGroup:new{
        dimen = dim,
        LeftContainer:new{ dimen = dim:copy(), lw },
        chip_widget and RightContainer:new{ dimen = dim:copy(), chip_widget } or nil,
    }
end

--- A grey hairline across `w`.
function M.hairline(w)
    return LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.medium }, background = STYLE.hairline }
end

return M
