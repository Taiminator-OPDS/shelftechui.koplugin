--[[
The text sheet (Aa): KOReader's bottom reader menu, redesigned in Bookshelf's
design language. Applied once, when the plugin loads.

  * A bottom sheet with a black top rule and small rounded corners.
  * Named tabs (SCREEN, MARGINS, PAGE, TEXT, CONTRAST, MORE...) in a Bookshelf
    tab strip at the top, plus a close button.
  * Every setting gets its label on top and one clear, full-width control:
      - off/on settings      -> a checkbox you tap anywhere on the row
      - choices              -> a segmented strip (selected = filled black)
      - levels (margins, line spacing, contrast, font size...)
                             -> a stepped bar with − and + at the ends
      - the old "⋮" button   -> a value chip showing the real current value;
                                tap it for precise adjustment
  * Font size: one control (bar = preset sizes, −/+ = fine steps, chip = exact size).
  * Fonts: the Text tab starts with your current and recent fonts, each shown in
    its own typeface; "All N fonts" opens a font sheet with live preview. Hold a
    font to make it the default (or fallback) font.

Everything still goes through KOReader's own handlers, so behaviour is unchanged:
hold a control to make that value the default, hold a setting's name for its
help and current/default values, greyed-out options stay greyed out.
Touch devices only; keyboard-only devices keep the stock menu.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfigDialog = require("ui/widget/configdialog")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local Screen = Device.screen

-- Keyboard-only devices navigate the stock menu with a focus cursor: leave them alone.
if not Device:isTouchDevice() then return end

local function S(n) return Screen:scaleBySize(n) end

local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
local GRAY_TEXT = Blitbuffer.COLOR_DARK_GRAY

local STYLE = {
    margin       = S(16),                 -- left/right inner margin of the sheet
    top_rule     = require("bos_look").LINE, -- rule along the top of the sheet
    radius       = require("bos_look").RADIUS, -- sheet corner radius (the theme's; Retro: square)
    strip_h      = S(42),                 -- tab strip height
    strip_line   = require("bos_look").LINE, -- tab strip / segmented outline
    control_h    = S(38),                 -- height of segmented strips, bars, buttons
    label_size   = 16,                    -- setting name font size
    seg_size     = 15,                    -- segmented strip font size
    track_h      = S(16),                 -- level bar thickness
    track_fill   = Blitbuffer.COLOR_DARK_GRAY,
    line         = require("bos_look").LINE, -- outline of chips, buttons, checkboxes, bar
    hairline     = Blitbuffer.COLOR_LIGHT_GRAY,
    uppercase    = true,                  -- bold uppercase labels in strips (bookshelf)
}

-- Tab names, by the stock tab icon.
local TAB_NAMES = {
    ["appbar.rotation"] = _("Screen"),
    ["appbar.crop"]     = _("Margins"),
    ["appbar.pagefit"]  = _("Zoom"),
    ["appbar.pageview"] = _("Page"),
    ["appbar.textsize"] = _("Text"),
    ["appbar.contrast"] = _("Contrast"),
    ["appbar.settings"] = _("More"),
}

-- Bookshelf's UI font, as every ShelfTechUI surface
local UI = require("bos_ui")
local function face(size, bold)
    if bold then return (UI.boldFace(size)) end
    return UI.face(size)
end

local function upper(text)
    text = tostring(text)
    if not STYLE.uppercase then return text end
    if not require("bos_look").theme.upper then return text end
    local ok, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok and Utf8Proc.uppercase_dumb then
        local ok2, res = pcall(Utf8Proc.uppercase_dumb, text)
        if ok2 and res then return res end
    end
    return require("bos_look").case(text)
end

local function box(w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, VerticalSpan:new{ width = 0 } }
end

-- ---------------------------------------------------------------------------
-- Building blocks
-- ---------------------------------------------------------------------------

-- Fixed-size tap/hold area. Its own Tap/Hold events are not propagated to
-- children (so nested tap areas don't steal each other's taps).
local Tap = InputContainer:extend{
    width = nil, height = nil, enabled = true,
    callback = nil,       -- function(ges)
    hold_callback = nil,  -- function(ges)
}

function Tap:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapIt = { GestureRange:new{ ges = "tap", range = self.dimen } },
        HoldIt = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Tap:handleEvent(event)
    if event.handler == "onTapIt" or event.handler == "onHoldIt" then
        local args = event.args or { n = 0 }
        return self[event.handler](self, unpack(args, 1, args.n or #args))
    end
    return InputContainer.handleEvent(self, event)
end

function Tap:onTapIt(_, ges)
    if self.enabled ~= false and self.callback then self.callback(ges) end
    return true
end

function Tap:onHoldIt(_, ges)
    if self.hold_callback then
        self.hold_callback(ges)
        return true
    end
    return true
end

-- Outlined rounded box (two concentric rounded rects: clean corners).
local Card = WidgetContainer:extend{
    bordersize = STYLE.line, padding = 0, radius = STYLE.radius,
    background = WHITE, color = BLACK,
}

function Card:getSize()
    local s = self[1]:getSize()
    local chrome = 2 * (self.bordersize + self.padding)
    return Geom:new{ w = s.w + chrome, h = s.h + chrome }
end

function Card:paintTo(bb, x, y)
    local sz = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local t = self.bordersize
    if t > 0 then bb:paintRoundedRect(x, y, sz.w, sz.h, self.color, self.radius) end
    bb:paintRoundedRect(x + t, y + t, sz.w - 2 * t, sz.h - 2 * t, self.background,
        math.max(0, self.radius - t))
    self[1]:paintTo(bb, x + t + self.padding, y + t + self.padding)
end

-- The sheet: white panel with a black rule along its rounded top edge.
-- Its bottom edge (and bottom corners) is pushed below the screen.
local Sheet = WidgetContainer:extend{ radius = 0, rule = 0, extra_bottom = 0 }

function Sheet:getSize()
    local s = self[1]:getSize()
    return Geom:new{ w = Screen:getWidth(), h = s.h + self.rule + self.extra_bottom }
end

function Sheet:paintTo(bb, x, y)
    local sz = self:getSize()
    -- Only the on-screen part counts (refreshes and "tap outside to close").
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = math.min(sz.h, Screen:getHeight() - y) }
    bb:paintRoundedRect(x, y, sz.w, sz.h, BLACK, self.radius)
    bb:paintRoundedRect(x, y + self.rule, sz.w, sz.h - self.rule, WHITE, self.radius)
    self[1]:paintTo(bb, x, y + self.rule)
end

-- Square checkbox, filled with a white tick when on (bookshelf's check-square).
local function makeCheckbox(on, enabled)
    local d = S(26)
    local ink = enabled and BLACK or GRAY_TEXT
    local inner_d = d - 2 * STYLE.line
    return Card:new{
        bordersize = STYLE.line, radius = STYLE.radius, color = ink, background = on and ink or WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = inner_d, h = inner_d },
            on and TextWidget:new{ text = "✓", face = face(17, true), fgcolor = WHITE }
               or VerticalSpan:new{ width = 0 } },
    }
end

-- Outlined chip holding a value (tap for precise adjustment).
local function makeChip(text, enabled, max_w)
    local ink = enabled and BLACK or GRAY_TEXT
    return Card:new{
        bordersize = STYLE.line, radius = STYLE.radius, color = ink,
        FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0,
            padding_left = S(10), padding_right = S(10), padding_top = S(1), padding_bottom = S(1),
            TextWidget:new{ text = text, face = face(14, true), fgcolor = ink,
                            max_width = max_w and (max_w - 2 * STYLE.line - S(20)) or nil },
        },
    }
end

-- Square outlined button with a glyph (−, +).
local function makeStepButton(glyph, enabled)
    local d = STYLE.control_h
    local ink = enabled and BLACK or GRAY_TEXT
    local inner = d - 2 * STYLE.line
    return Card:new{
        bordersize = STYLE.line, radius = STYLE.radius, color = ink,
        CenterContainer:new{ dimen = Geom:new{ w = inner, h = inner },
            TextWidget:new{ text = glyph, face = face(20, true), fgcolor = ink } },
    }
end

-- Level bar: rounded outlined track, dark fill up to the current step, ticks
-- between steps, and a small notch under the default step.
local LevelBar = WidgetContainer:extend{
    width = 0, height = 0, steps = 1, position = nil, default = nil, enabled = true,
}

function LevelBar:getSize() return Geom:new{ w = self.width, h = self.height } end

function LevelBar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local th = STYLE.track_h
    local ty = y + math.floor((self.height - th) / 2)
    local w = self.width
    local r = 0 -- the retro look: a square track, pinstriped fill
    local ink = self.enabled and BLACK or GRAY_TEXT
    local t = STYLE.line
    bb:paintRoundedRect(x, ty, w, th, ink, r)
    bb:paintRoundedRect(x + t, ty + t, w - 2 * t, th - 2 * t, WHITE, math.max(0, r - t))
    local inner_w = w - 2 * t
    local step_w = inner_w / self.steps
    if self.position and self.position > 0 then
        local fw = math.floor(step_w * self.position + 0.5)
        if self.enabled then
            require("bos_look").fill(bb, x + t, ty + t + S(2), fw, th - 2 * t - S(4))
        else
            bb:paintRect(x + t, ty + t, fw, th - 2 * t, Blitbuffer.COLOR_LIGHT_GRAY)
        end
    end
    -- ticks between steps
    for i = 1, self.steps - 1 do
        local tx = x + t + math.floor(step_w * i + 0.5)
        local filled = self.position and i < self.position
        bb:paintRect(tx, ty + t + S(2), 1, th - 2 * t - S(4),
            filled and WHITE or Blitbuffer.COLOR_GRAY_9)
    end
    -- default notch (small bar under the track)
    if self.default then
        local cx = x + t + math.floor(step_w * (self.default - 0.5) + 0.5)
        bb:paintRect(cx - S(5), ty + th + S(3), S(10), S(3), GRAY_TEXT)
    end
end

-- ---------------------------------------------------------------------------
-- Current / default positions (same matching as the stock ConfigOption)
-- ---------------------------------------------------------------------------

local function value_diff(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) end
    if type(a) == "string" then return a == b and 0 or 1 end
    return 1
end

local function closestIndex(val, values)
    if val == nil or not values or #values == 0 then return nil end
    local idx, min_diff
    for i, v in ipairs(values) do
        if val == v then return i end
        local d
        if type(val) == "table" then
            d = value_diff(val[1], type(v) == "table" and v[1] or v)
        else
            d = value_diff(val, v)
        end
        if min_diff == nil or d <= min_diff then
            min_diff, idx = d, i
        end
    end
    return idx
end

local function currentItem(dialog, opt)
    if not opt.name then return nil end
    local val = opt.current_func and opt.current_func() or dialog.configurable[opt.name]
    if opt.values and #opt.values > 0 then
        return closestIndex(val, opt.values)
    elseif opt.args then
        for i, a in ipairs(opt.args) do
            if a == val then return i end
        end
    end
end

local function defaultItem(dialog, opt)
    local d = opt.default_pos
    if opt.name and opt.values and #opt.values > 0 then
        local saved = G_reader_settings:readSetting(dialog.config_options.prefix .. "_" .. opt.name)
        if saved ~= nil then d = closestIndex(saved, opt.values) or d end
    end
    return d
end

local function fmtNumber(v)
    if type(v) ~= "number" then return tostring(v) end
    if v == math.floor(v) then return string.format("%d", v) end
    return (string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", ""))
end

-- Human-readable current value of an option (for its chip).
local function valueText(dialog, opt)
    local p = opt.more_options_param or {}
    local name = p.name or opt.name
    local val
    if opt.current_func and not p.name then
        val = opt.current_func()
    else
        val = dialog.configurable[name]
    end
    if val == nil then return nil end
    if p.value_table then
        local v = p.value_table[val + (p.value_table_shift or 0)]
        if v then return fmtNumber(v) end
    end
    if opt.show_true_value_func and (not p.name or p.name == opt.name) then
        local ok, s = pcall(opt.show_true_value_func, val)
        if ok and s then return tostring(s) end
    end
    if p.name == "font_size" or name == "font_size" then
        if dialog.config_options.prefix == "kopt" then
            return "×" .. fmtNumber(val) -- reflow font scale factor
        end
        return fmtNumber(val) .. "\u{202F}pt"
    end
    if opt.labels and opt.values and not p.name then
        for i, v in ipairs(opt.values) do
            if v == val then return tostring(opt.labels[i]) end
        end
    end
    if type(val) == "table" then
        local parts = {}
        for _, v in ipairs(val) do table.insert(parts, fmtNumber(v)) end
        return table.concat(parts, " / ")
    end
    local unit = p.unit and ("\u{202F}" .. p.unit) or ""
    return fmtNumber(val) .. unit
end

-- Recognise off/on toggles (shown as a checkbox).
local OFF = { ["off"] = true, [_("off")] = true }
local ON = { ["on"] = true, [_("on")] = true }
local function isOnOff(opt)
    local t = opt.toggle
    return t and #t == 2 and not opt.more_options and opt.values and #opt.values == 2
        and OFF[t[1]] and ON[t[2]]
end

-- An action toggle (no values: e.g. font size decrease/increase).
local function isAction(opt)
    return opt.toggle and opt.values and #opt.values == 0 and opt.args and #opt.args == 2
end

-- ---------------------------------------------------------------------------
-- Actions (ported 1:1 from the stock widgets)
-- ---------------------------------------------------------------------------

local function withSource(source, fn)
    Notification:setNotifySource(source)
    fn()
    UIManager:tickAfterNext(function() Notification:resetNotifySource() end)
end

local function choose(dialog, opt, position, source)
    withSource(source, function()
        dialog:onConfigChoose(opt.values, opt.name, opt.event, opt.args, position, opt.hide_on_apply)
    end)
end

local function fineTune(dialog, opt, dir)
    withSource(Notification.SOURCE_BOTTOM_MENU_FINE, function()
        dialog:onConfigFineTuneChoose(opt.values, opt.name, opt.event, opt.args, dir,
            opt.hide_on_apply, opt.fine_tune_param)
    end)
end

local function moreOptions(dialog, opt, name_text)
    if opt.show_true_value_func and opt.more_options_param
            and not opt.more_options_param.show_true_value_func then
        opt.more_options_param.show_true_value_func = opt.show_true_value_func
    end
    withSource(Notification.SOURCE_BOTTOM_MENU_MORE, function()
        local default_value_original
        if opt.more_options_param and opt.more_options_param.names then
            local o1 = dialog:findOptionByName(opt.more_options_param.names[1])
            local o2 = dialog:findOptionByName(opt.more_options_param.names[2])
            default_value_original = { o1.default_value, o2.default_value }
        else
            default_value_original = opt.default_value
        end
        dialog:onConfigMoreChoose(opt.values, default_value_original, opt.name,
            opt.event, "⋮", name_text, opt.more_options_param)
    end)
end

local function makeDefault(dialog, opt, name_text, position, kind)
    if kind == "toggle" then
        if opt.name == "font_fine_tune" then
            dialog:onMakeFineTuneDefault("font_size", _("Font Size"), opt.values or opt.args,
                opt.toggle, position == 1 and "-" or "+")
        else
            dialog:onMakeDefault(opt.name, name_text, opt.values or opt.args, opt.toggle, position)
        end
    elseif kind == "icons" then
        dialog:onMakeDefault(opt.name, name_text, opt.values, opt.labels or opt.values, position)
    elseif kind == "text" then
        dialog:onMakeDefault(opt.name, name_text, opt.values or opt.args,
            opt.values or opt.item_text, position)
    else -- level
        if position == "-" or position == "+" then
            dialog:onMakeFineTuneDefault(opt.name, name_text, opt.values, opt.labels or opt.args, position)
        else
            dialog:onMakeDefault(opt.name, name_text, opt.values, opt.labels or opt.args, position)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------------------

-- Segmented strip (bookshelf tab strip look). cells: { text= | icon= }
local function segmented(cells, selected, w, enabled, on_tap, on_hold)
    local h = STYLE.control_h
    local b = STYLE.strip_line
    local n = #cells
    local inner_w = w - 2 * b - (n - 1) * b
    local cw = math.floor(inner_w / n)
    local extra = inner_w - cw * n
    -- one font size for all cells: shrink until the longest label fits
    local fsize = STYLE.seg_size
    for _ = 1, 6 do
        local fits = true
        for _, c in ipairs(cells) do
            if c.text then
                local tw = TextWidget:new{ text = upper(c.text), face = require("bos_look").mono(fsize - 2), bold = true }
                if tw:getSize().w > cw - S(6) then fits = false end
                tw:free()
            end
        end
        if fits then break end
        fsize = fsize - 1
    end
    local ink = enabled and BLACK or GRAY_TEXT
    local hg = HorizontalGroup:new{}
    for i, c in ipairs(cells) do
        if i > 1 then
            table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = ink })
        end
        local this_w = cw + (i == n and extra or 0)
        local sel = i == selected
        local inner
        if c.icon then
            local isz = math.min(h - S(6), this_w - S(6))
            inner = IconWidget:new{ icon = c.icon, width = isz, height = isz, dim = not enabled }
        else
            inner = TextWidget:new{ text = upper(c.text), face = require("bos_look").mono(fsize - 2), bold = true,
                                    fgcolor = ink, max_width = this_w - S(4) }
        end
        table.insert(hg, Tap:new{
            width = this_w, height = h,
            enabled = enabled,
            callback = function() on_tap(i) end,
            hold_callback = on_hold and function() on_hold(i) end,
            -- the selected cell is painted white-on-black by inverting it
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0, background = WHITE,
                invert = sel and enabled,
                CenterContainer:new{ dimen = Geom:new{ w = this_w, h = h }, inner },
            },
        })
        if sel and not enabled then
            -- disabled + selected: grey underline instead of an inverted cell
            hg[#hg][1][1][1] = VerticalGroup:new{ inner, LineWidget:new{
                dimen = Geom:new{ w = math.floor(this_w * 0.5), h = S(2) }, background = GRAY_TEXT } }
        end
    end
    return FrameContainer:new{
        bordersize = b, margin = 0, padding = 0, color = ink, background = WHITE, hg,
    }
end

-- [−] ===bar=== [+]
local function levelControl(w, steps, position, default, enabled, on_pick, on_minus, on_plus, on_hold)
    local h = STYLE.control_h
    local gap = S(12)
    local minus = Tap:new{ width = h, height = h, enabled = enabled, callback = on_minus,
        hold_callback = on_hold and function() on_hold("-") end,
        makeStepButton("−", enabled) }
    local plus = Tap:new{ width = h, height = h, enabled = enabled, callback = on_plus,
        hold_callback = on_hold and function() on_hold("+") end,
        makeStepButton("+", enabled) }
    local bar_w = w - 2 * h - 2 * gap
    local bar = LevelBar:new{ width = bar_w, height = h, steps = steps,
                              position = position, default = default, enabled = enabled }
    local function stepAt(ges)
        local x = ges.pos.x - (bar.dimen and bar.dimen.x or 0)
        return math.max(1, math.min(steps, math.ceil(x / bar_w * steps)))
    end
    local bar_tap = Tap:new{
        width = bar_w, height = h, enabled = enabled,
        callback = function(ges) on_pick(stepAt(ges)) end,
        hold_callback = on_hold and function(ges) on_hold(stepAt(ges)) end,
        bar,
    }
    return HorizontalGroup:new{
        align = "center",
        minus, HorizontalSpan:new{ width = gap }, bar_tap, HorizontalSpan:new{ width = gap }, plus,
    }
end

-- ---------------------------------------------------------------------------
-- The sheet
-- ---------------------------------------------------------------------------

local Redesign = {}

function Redesign.tabName(tab, idx)
    if TAB_NAMES[tab.icon] then return TAB_NAMES[tab.icon] end
    local first = tab.options and tab.options[1]
    return first and (first.name_text or first.alt_name_text) or tostring(idx)
end

function Redesign.buildStrip(dialog, w)
    local opts = dialog.config_options
    local h = STYLE.strip_h
    local b = STYLE.strip_line
    local close_w = S(50)
    local n = #opts
    local inner_w = w - 2 * b - n * b - close_w
    local cw = math.floor(inner_w / n)
    local extra = inner_w - cw * n
    local fsize = 16
    for _ = 1, 6 do
        local fits = true
        for i, tab in ipairs(opts) do
            local tw = TextWidget:new{ text = upper(Redesign.tabName(tab, i)), face = require("bos_look").mono(fsize - 2), bold = true }
            if tw:getSize().w > cw - S(14) then fits = false end
            tw:free()
        end
        if fits then break end
        fsize = fsize - 1
    end
    local hg = HorizontalGroup:new{}
    for i, tab in ipairs(opts) do
        if i > 1 then
            table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = BLACK })
        end
        local this_w = cw + (i == 1 and extra or 0)
        local sel = i == dialog.panel_index
        table.insert(hg, Tap:new{
            width = this_w, height = h,
            callback = function()
                if dialog.panel_index ~= i then
                    dialog:handleEvent(require("ui/event"):new("ShowConfigPanel", i))
                end
            end,
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0, background = WHITE, invert = sel,
                CenterContainer:new{ dimen = Geom:new{ w = this_w, h = h },
                    TextWidget:new{ text = upper(Redesign.tabName(tab, i)), face = require("bos_look").mono(fsize - 2), bold = true,
                                    max_width = this_w - S(4) } },
            },
        })
    end
    table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = BLACK })
    table.insert(hg, Tap:new{
        width = close_w, height = h,
        callback = function() dialog:closeDialog() end,
        CenterContainer:new{ dimen = Geom:new{ w = close_w, h = h },
            IconWidget:new{ icon = "close", width = S(24), height = S(24) } },
    })
    return FrameContainer:new{ bordersize = b, margin = 0, padding = 0, color = BLACK, hg }
end

-- Label line: name (hold for help/values) ..... [chip]
function Redesign.labelLine(dialog, opt, name_text, enabled, w, chip_text, on_chip)
    local h = S(30)
    local chip
    if chip_text then
        chip = Tap:new{
            width = 0, height = 0, enabled = enabled,
            callback = on_chip,
            makeChip(chip_text, enabled, math.floor(w * 0.5)),
        }
        local cs = chip[1]:getSize()
        chip.width, chip.height = cs.w, cs.h
        chip.dimen.w, chip.dimen.h = cs.w, cs.h
    end
    local chip_w = chip and chip.width or 0
    local label = TextWidget:new{
        text = name_text or "", face = face(STYLE.label_size),
        fgcolor = enabled and BLACK or GRAY_TEXT,
        max_width = w - chip_w - S(12),
    }
    local label_w = label:getSize().w + S(8)
    local label_tap = Tap:new{
        width = label_w, height = h,
        hold_callback = function()
            if opt.name_text_hold_callback then
                opt.name_text_hold_callback(dialog.configurable, opt,
                    dialog.config_options.prefix, dialog.document)
            end
        end,
        LeftContainer:new{ dimen = Geom:new{ w = label_w, h = h }, label },
    }
    local og = OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, label_tap }
    if chip then
        table.insert(og, RightContainer:new{ dimen = Geom:new{ w = w, h = h }, chip })
    end
    return og
end

-- One setting block. Returns a widget (or nil when hidden) and its "merged" fine-tune option, if consumed.
function Redesign.optionBlock(dialog, opt, next_opt, w)
    local enabled = true
    if opt.enabled_func then
        enabled = opt.enabled_func(dialog.configurable, dialog.document) and true or false
    end
    local name_text = opt.name_text_func and opt.name_text_func(dialog.configurable, dialog.document)
                      or opt.name_text or opt.alt_name_text
    local cur = currentItem(dialog, opt)
    local def = defaultItem(dialog, opt)
    local vg = VerticalGroup:new{ align = "left" }
    local consumed

    local function chipFor(o)
        if not o.more_options then return nil end
        return valueText(dialog, o) or "…"
    end

    if isOnOff(opt) then
        -- off/on -> checkbox row; tap anywhere flips it, hold makes the current value the default
        local on = cur == 2
        local h = S(44)
        local label = TextWidget:new{ text = name_text or "", face = face(STYLE.label_size),
                                      fgcolor = enabled and BLACK or GRAY_TEXT, max_width = w - S(50) }
        local row = Tap:new{
            width = w, height = h, enabled = enabled,
            callback = function() choose(dialog, opt, on and 1 or 2, Notification.SOURCE_BOTTOM_MENU_TOGGLE) end,
            hold_callback = function()
                if opt.name_text_hold_callback then
                    opt.name_text_hold_callback(dialog.configurable, opt,
                        dialog.config_options.prefix, dialog.document)
                end
            end,
            OverlapGroup:new{
                dimen = Geom:new{ w = w, h = h },
                LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, label },
                RightContainer:new{ dimen = Geom:new{ w = w, h = h }, makeCheckbox(on, enabled) },
            },
        }
        table.insert(vg, row)
        return vg
    end

    local items_icons = opt.item_icons_func and opt.item_icons_func(dialog.configurable, dialog.document)
                        or opt.item_icons

    if opt.item_text and type(opt.item_font_size) == "table" then
        -- Font sizes: one level control. Merge the following decrease/increase
        -- action (fine tune + exact size chip) into it.
        local fine = next_opt and next_opt.toggle and #next_opt.toggle == 2
            and (next_opt.name == "font_fine_tune"
                 or (next_opt.more_options_param and next_opt.more_options_param.name == opt.name))
            and next_opt or nil
        if fine then consumed = fine end
        local label_text = (fine and (fine.name_text or name_text)) or name_text or _("Font Size")
        local chip, on_chip
        if fine and fine.more_options then
            chip = valueText(dialog, fine) or "…"
            on_chip = function() moreOptions(dialog, fine, label_text) end
        else
            chip = valueText(dialog, opt)
        end
        table.insert(vg, Redesign.labelLine(dialog, fine or opt, label_text, enabled, w, chip, on_chip))
        table.insert(vg, VerticalSpan:new{ width = S(4) })
        local steps = #opt.item_text
        table.insert(vg, levelControl(w, steps, cur, def, enabled,
            function(i) choose(dialog, opt, i, Notification.SOURCE_BOTTOM_MENU_ICON) end,
            function()
                if fine then choose(dialog, fine, 1, Notification.SOURCE_BOTTOM_MENU_FINE)
                elseif cur and cur > 1 then choose(dialog, opt, cur - 1, Notification.SOURCE_BOTTOM_MENU_ICON) end
            end,
            function()
                if fine then choose(dialog, fine, 2, Notification.SOURCE_BOTTOM_MENU_FINE)
                elseif cur and cur < steps then choose(dialog, opt, (cur or 0) + 1, Notification.SOURCE_BOTTOM_MENU_ICON) end
            end,
            function(pos)
                if pos == "-" or pos == "+" then
                    if fine then makeDefault(dialog, fine, label_text, pos == "-" and 1 or 2, "toggle") end
                else
                    makeDefault(dialog, opt, name_text, pos, "text")
                end
            end))
        return vg, consumed
    end

    if isAction(opt) then
        -- standalone decrease/increase action: [−] chip [+]
        local chip = chipFor(opt)
        table.insert(vg, Redesign.labelLine(dialog, opt, name_text, enabled, w, nil))
        table.insert(vg, VerticalSpan:new{ width = S(4) })
        local h = STYLE.control_h
        local mid_w = w - 2 * h - 2 * S(12)
        local mid = chip and Tap:new{ width = mid_w, height = h, enabled = enabled,
                callback = function() moreOptions(dialog, opt, name_text) end,
                CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = h }, makeChip(chip, enabled, mid_w) } }
            or box(mid_w, h)
        table.insert(vg, HorizontalGroup:new{
            align = "center",
            Tap:new{ width = h, height = h, enabled = enabled,
                callback = function() choose(dialog, opt, 1, Notification.SOURCE_BOTTOM_MENU_FINE) end,
                hold_callback = function() makeDefault(dialog, opt, name_text, 1, "toggle") end,
                makeStepButton("−", enabled) },
            HorizontalSpan:new{ width = S(12) }, mid, HorizontalSpan:new{ width = S(12) },
            Tap:new{ width = h, height = h, enabled = enabled,
                callback = function() choose(dialog, opt, 2, Notification.SOURCE_BOTTOM_MENU_FINE) end,
                hold_callback = function() makeDefault(dialog, opt, name_text, 2, "toggle") end,
                makeStepButton("+", enabled) },
        })
        return vg
    end

    if opt.buttonprogress then
        local steps = #opt.values
        table.insert(vg, Redesign.labelLine(dialog, opt, name_text, enabled, w,
            chipFor(opt) or valueText(dialog, opt),
            opt.more_options and function() moreOptions(dialog, opt, name_text) end or nil))
        table.insert(vg, VerticalSpan:new{ width = S(4) })
        local function step(dir)
            if opt.fine_tune then
                fineTune(dialog, opt, dir)
            else
                local p = (cur or opt.default_pos or 1) + (dir == "-" and -1 or 1)
                if p >= 1 and p <= steps then
                    choose(dialog, opt, p, Notification.SOURCE_BOTTOM_MENU_PROGRESS)
                end
            end
        end
        table.insert(vg, levelControl(w, steps, cur, def, enabled,
            function(i) choose(dialog, opt, i, Notification.SOURCE_BOTTOM_MENU_PROGRESS) end,
            function() step("-") end,
            function() step("+") end,
            function(pos)
                if (pos == "-" or pos == "+") and not opt.fine_tune then return end
                makeDefault(dialog, opt, name_text, pos, "level")
            end))
        return vg
    end

    -- Choices: icons, text items or a toggle -> segmented strip
    local cells, kind = {}, nil
    if items_icons then
        kind = "icons"
        for _, ic in ipairs(items_icons) do table.insert(cells, { icon = ic }) end
    elseif opt.item_text then
        kind = "text"
        for _, t in ipairs(opt.item_text) do table.insert(cells, { text = t }) end
    elseif opt.toggle then
        kind = "toggle"
        for _, t in ipairs(opt.toggle) do table.insert(cells, { text = t }) end
    end
    if not kind then return nil end

    local chip = chipFor(opt)
    table.insert(vg, Redesign.labelLine(dialog, opt, name_text, enabled, w, chip,
        opt.more_options and function() moreOptions(dialog, opt, name_text) end or nil))
    table.insert(vg, VerticalSpan:new{ width = S(4) })
    table.insert(vg, segmented(cells, cur, w, enabled,
        function(i)
            local src = kind == "toggle"
                and ((opt.values and #opt.values == 0) and Notification.SOURCE_BOTTOM_MENU_FINE
                     or Notification.SOURCE_BOTTOM_MENU_TOGGLE)
                or Notification.SOURCE_BOTTOM_MENU_ICON
            choose(dialog, opt, i, src)
        end,
        function(i) makeDefault(dialog, opt, name_text, i, kind) end))
    return vg
end

-- ---------------------------------------------------------------------------
-- Fonts (EPUB/FB2/... only): quick picks + a full font sheet
-- ---------------------------------------------------------------------------

local Fonts = {}

function Fonts.engine()
    local ok, cre = pcall(function() return require("document/credocument"):engineInit() end)
    return ok and cre or nil
end

-- { name=, display=, file=, index=, mono= } for a cre font face name
function Fonts.info(cre, name)
    local file, index, mono = cre.getFontFaceFilenameAndFaceIndex(name)
    if not file then
        file, index, mono = cre.getFontFaceFilenameAndFaceIndex(name, nil, true)
    end
    local display = name
    if file and index then
        local ok, FontList = pcall(require, "fontlist")
        if ok then display = FontList:getLocalizedFontName(file, index) or name end
    end
    return { name = name, display = display, file = file, index = index, mono = mono }
end

function Fonts.face(info, size)
    if info.file and info.index then
        local ok, f = pcall(Font.getFace, Font, info.file, size, info.index)
        if ok and f then return f end
    end
    return face(size)
end

function Fonts.list(dialog)
    local cre = Fonts.engine()
    if not cre then return {} end
    local faces = cre.getFontFaces() or {}
    local rf = dialog.ui.font
    if rf.sortFaceList then
        local ok, sorted = pcall(rf.sortFaceList, rf, faces)
        if ok and sorted then faces = sorted end
    end
    return faces, cre
end

function Fonts.defaults(dialog)
    local doc = dialog.ui.document
    return G_reader_settings:readSetting("cre_font") or (doc and doc.default_font),
           G_reader_settings:readSetting("fallback_font") or (doc and doc.fallback_fonts and doc.fallback_fonts[1])
end

-- Apply a font the same way KOReader's font menu does.
function Fonts.apply(dialog, name)
    local rf = dialog.ui.font
    rf:onSetFont(name)
    if rf.addToRecentlySelectedList then pcall(rf.addToRecentlySelectedList, rf, name) end
end

-- Hold: make it the default / fallback (or monospace) font, as in the font menu.
function Fonts.makeDefault(dialog, info, after)
    local rf = dialog.ui.font
    if rf.makeDefault then
        rf:makeDefault(info.name, info.mono, { updateItems = function() if after then after() end end })
    end
end

-- Full-height font sheet ------------------------------------------------------

local FontSheet = InputContainer:extend{
    dialog = nil,
    page = 1,
    modal = true,
}

function FontSheet:init()
    self.W, self.H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.W, h = self.H }
    self.ges_events = {
        TapOutside = { GestureRange:new{ ges = "tap", range = self.dimen } },
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.faces, self.cre = Fonts.list(self.dialog)
    self.infos = {}
    -- open on the page holding the current font
    self.row_h = S(54)
    self:layout()
    local cur = self.dialog.ui.font.font_face
    for i, name in ipairs(self.faces) do
        if name == cur then self.page = math.floor((i - 1) / self.per_page) + 1 end
    end
    self:render()
end

function FontSheet:layout()
    self.sheet_h = math.floor(self.H * 0.72)
    local chrome = S(12) + S(40) + S(10) + S(52) + S(8) + STYLE.top_rule
    self.per_page = math.max(3, math.floor((self.sheet_h - chrome) / (self.row_h + Size.line.thin)))
    self.pages = math.max(1, math.ceil(#self.faces / self.per_page))
end

function FontSheet:infoFor(name)
    if not self.infos[name] then self.infos[name] = Fonts.info(self.cre, name) end
    return self.infos[name]
end

function FontSheet:render()
    local w = self.W - 2 * STYLE.margin
    local rf = self.dialog.ui.font
    local def, fallback = Fonts.defaults(self.dialog)
    self.page = math.max(1, math.min(self.page, self.pages))

    -- header: FONTS ............ ✕
    local hh = S(40)
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = hh },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = hh },
            TextWidget:new{ text = _("Fonts"), face = face(24, true) } },
        RightContainer:new{ dimen = Geom:new{ w = w, h = hh },
            Tap:new{ width = S(44), height = hh, callback = function() self:close() end,
                CenterContainer:new{ dimen = Geom:new{ w = S(44), h = hh },
                    IconWidget:new{ icon = "close", width = S(24), height = S(24) } } } },
    }

    local list = VerticalGroup:new{ align = "left" }
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.faces, first + self.per_page - 1) do
        local name = self.faces[i]
        local info = self:infoFor(name)
        local current = name == rf.font_face
        local marks = {}
        if name == def then table.insert(marks, "★") end
        if name == fallback then table.insert(marks, "�") end
        local right = HorizontalGroup:new{ align = "center" }
        if #marks > 0 then
            table.insert(right, TextWidget:new{ text = table.concat(marks, " "), face = face(16),
                                                fgcolor = GRAY_TEXT })
            table.insert(right, HorizontalSpan:new{ width = S(12) })
        end
        if current then table.insert(right, makeCheckbox(true, true)) end
        local right_w = right:getSize().w
        local label = TextWidget:new{
            text = info.display, face = Fonts.face(info, 21),
            max_width = w - right_w - S(16),
        }
        if i > first then
            table.insert(list, LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.thin },
                                               background = STYLE.hairline })
        end
        table.insert(list, Tap:new{
            width = w, height = self.row_h,
            callback = function()
                Fonts.apply(self.dialog, name)
                self:refreshAll()
            end,
            hold_callback = function()
                Fonts.makeDefault(self.dialog, info, function() self:refreshAll() end)
            end,
            OverlapGroup:new{
                dimen = Geom:new{ w = w, h = self.row_h },
                LeftContainer:new{ dimen = Geom:new{ w = w, h = self.row_h }, label },
                RightContainer:new{ dimen = Geom:new{ w = w, h = self.row_h }, right },
            },
        })
    end
    local list_h = self.per_page * (self.row_h + Size.line.thin)

    -- footer pager: ‹  Page x of y  ›   (bookshelf footer)
    local fh = S(52)
    local function btn(icon, enabled, cb)
        return Tap:new{ width = S(56), height = fh, enabled = enabled, callback = cb,
            CenterContainer:new{ dimen = Geom:new{ w = S(56), h = fh },
                IconWidget:new{ icon = icon, width = S(28), height = S(28), dim = not enabled } } }
    end
    local T = require("ffi/util").template
    local mid_w = w - 4 * S(56)
    local footer = HorizontalGroup:new{
        align = "center",
        btn("chevron.first", self.page > 1, function() self:gotoPage(1) end),
        btn("chevron.left", self.page > 1, function() self:gotoPage(self.page - 1) end),
        CenterContainer:new{ dimen = Geom:new{ w = mid_w, h = fh },
            TextWidget:new{ text = string.format("%d / %d", self.page, self.pages), face = require("bos_look").mono(15), bold = true } },
        btn("chevron.right", self.page < self.pages, function() self:gotoPage(self.page + 1) end),
        btn("chevron.last", self.page < self.pages, function() self:gotoPage(self.pages) end),
    }

    local content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = S(12) },
        header,
        VerticalSpan:new{ width = S(10) },
        LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.medium }, background = GRAY_TEXT },
        TopContainer:new{ dimen = Geom:new{ w = w, h = list_h }, list }, -- fixed height
        footer,
        VerticalSpan:new{ width = S(8) },
    }

    self.sheet = Sheet:new{
        radius = STYLE.radius, rule = STYLE.top_rule, extra_bottom = STYLE.radius,
        HorizontalGroup:new{ HorizontalSpan:new{ width = STYLE.margin }, content },
    }
    self[1] = BottomContainer:new{
        dimen = Geom:new{ w = self.W, h = self.H + STYLE.radius },
        self.sheet,
    }
    UIManager:setDirty(self, function() return "ui", self.sheet.dimen or self.dimen end)
end

function FontSheet:gotoPage(p)
    if p ~= self.page and p >= 1 and p <= self.pages then
        self.page = p
        self:render()
    end
end

function FontSheet:onSwipe(_, ges)
    if ges.direction == "west" then self:gotoPage(self.page + 1) return true end
    if ges.direction == "east" then self:gotoPage(self.page - 1) return true end
    if ges.direction == "south" then self:close() return true end
    return true
end

function FontSheet:onTapOutside(_, ges)
    if self.sheet and self.sheet.dimen and ges.pos:notIntersectWith(self.sheet.dimen) then
        self:close()
    end
    return true
end

-- Re-render this sheet and the bottom menu behind it (the current font changed).
function FontSheet:refreshAll()
    UIManager:nextTick(function()
        local dlg = self.dialog
        if dlg and dlg.update then
            dlg:update()
            UIManager:setDirty(dlg, function() return "ui", dlg.dialog_frame.dimen end)
        end
        self:render()
    end)
end

function FontSheet:close()
    UIManager:close(self)
end

function FontSheet:onCloseWidget()
    local d = self.sheet and self.sheet.dimen
    UIManager:setDirty("all", function() return "ui", d end)
end

function FontSheet:onClose() self:close() return true end

-- The Font block shown at the top of the Text tab.
function Redesign.fontBlock(dialog, w)
    local rf = dialog.ui and dialog.ui.font
    if not (rf and rf.onSetFont and dialog.ui.document and dialog.ui.document.setFontFace) then return nil end
    local faces, cre = Fonts.list(dialog)
    if not cre or #faces == 0 then return nil end
    local available = {}
    for _, f in ipairs(faces) do available[f] = true end

    -- quick picks: current font, then the most recently selected ones
    local picks, seen = {}, {}
    local function add(name)
        if name and available[name] and not seen[name] and #picks < 3 then
            seen[name] = true
            table.insert(picks, name)
        end
    end
    add(rf.font_face)
    for _, name in ipairs(rf.fonts_recently_selected
                          or G_reader_settings:readSetting("cre_fonts_recently_selected") or {}) do
        add(name)
    end
    for _, name in ipairs(faces) do add(name) end

    local vg = VerticalGroup:new{ align = "left" }
    local T = require("ffi/util").template
    local open_all = function()
        UIManager:show(FontSheet:new{ dialog = dialog })
    end
    -- label line: Font ............ [All 24 fonts]
    local fake_opt = { name_text_hold_callback = nil }
    table.insert(vg, Redesign.labelLine(dialog, fake_opt, _("Font"), true, w,
        T(_("All %1 fonts"), #faces), open_all))
    table.insert(vg, VerticalSpan:new{ width = S(4) })

    -- strip of quick picks, each name drawn in its own typeface
    local h = S(46)
    local b = STYLE.strip_line
    local n = #picks
    local inner_w = w - 2 * b - (n - 1) * b
    local cw = math.floor(inner_w / n)
    local extra = inner_w - cw * n
    local hg = HorizontalGroup:new{}
    for i, name in ipairs(picks) do
        if i > 1 then
            table.insert(hg, LineWidget:new{ dimen = Geom:new{ w = b, h = h }, background = BLACK })
        end
        local this_w = cw + (i == n and extra or 0)
        local info = Fonts.info(cre, name)
        local sel = name == rf.font_face
        table.insert(hg, Tap:new{
            width = this_w, height = h,
            callback = function()
                if not sel then
                    Fonts.apply(dialog, name)
                    UIManager:nextTick(function()
                        dialog:update()
                        UIManager:setDirty(dialog, function() return "ui", dialog.dialog_frame.dimen end)
                    end)
                end
            end,
            hold_callback = function()
                Fonts.makeDefault(dialog, info, function()
                    dialog:update()
                    UIManager:setDirty(dialog, function() return "ui", dialog.dialog_frame.dimen end)
                end)
            end,
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = 0, background = WHITE, invert = sel,
                CenterContainer:new{ dimen = Geom:new{ w = this_w, h = h },
                    TextWidget:new{ text = info.display, face = Fonts.face(info, 18),
                                    max_width = this_w - S(12) } },
            },
        })
    end
    table.insert(vg, FrameContainer:new{
        bordersize = b, margin = 0, padding = 0, color = BLACK, background = WHITE, hg,
    })
    return vg
end

function Redesign.buildPanel(dialog, w)
    local tab = dialog.config_options[dialog.panel_index] or dialog.config_options[1]
    local options = tab.options or {}
    local list = VerticalGroup:new{ align = "left" }
    local shown = {}
    for i, opt in ipairs(options) do
        local show = opt.show
        if opt.show_func then show = opt.show_func(dialog.configurable, dialog.document) end
        if show ~= false then table.insert(shown, opt) end
    end
    local skip = {}
    local count = 0
    -- Font picker at the top of the text tab (reflowable documents only)
    if tab.icon == "appbar.textsize" and dialog.config_options.prefix == "copt" then
        local ok, block = pcall(Redesign.fontBlock, dialog, w)
        if not ok then logger.warn("reader menu redesign: font block", block) end
        if ok and block then
            table.insert(list, block)
            count = count + 1
        end
    end
    for i, opt in ipairs(shown) do
        if not skip[opt] then
            local ok, block, consumed = pcall(Redesign.optionBlock, dialog, opt, shown[i + 1], w)
            if not ok then
                logger.warn("reader menu redesign: option", opt.name, block)
                block = nil
            end
            if consumed then skip[consumed] = true end
            if block then
                if count > 0 then
                    table.insert(list, VerticalSpan:new{ width = S(9) })
                    table.insert(list, LineWidget:new{ dimen = Geom:new{ w = w, h = Size.line.thin },
                                                       background = STYLE.hairline })
                    table.insert(list, VerticalSpan:new{ width = S(7) })
                end
                table.insert(list, block)
                count = count + 1
            end
        end
    end
    return list, count
end

function Redesign.update(dialog)
    local W = Screen:getWidth()
    local w = W - 2 * STYLE.margin
    local strip = Redesign.buildStrip(dialog, w)
    local panel, count = Redesign.buildPanel(dialog, w)
    dialog._redesign_rows = count
    local content = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = S(12) },
        strip,
        VerticalSpan:new{ width = S(14) },
        panel,
        VerticalSpan:new{ width = S(18) },
    }
    local sheet = Sheet:new{
        radius = STYLE.radius,
        rule = STYLE.top_rule,
        extra_bottom = STYLE.radius,
        HorizontalGroup:new{ HorizontalSpan:new{ width = STYLE.margin }, content },
    }
    dialog.dialog_frame = sheet
    dialog[1] = BottomContainer:new{
        dimen = Geom:new{ w = W, h = Screen:getHeight() + STYLE.radius },
        sheet,
    }
end

-- ---------------------------------------------------------------------------
-- Hook into ConfigDialog
-- ---------------------------------------------------------------------------

if ConfigDialog._bos_sheet then return true end
ConfigDialog._bos_sheet = true

local orig_update = ConfigDialog.update
function ConfigDialog:update()
    if require("bos_settings_store").get("text_sheet") == false then
        self.dialog_frame = nil
        return orig_update(self)
    end
    self.layout = {}
    local ok, err = pcall(Redesign.update, self)
    if not ok then
        logger.warn("reader menu redesign failed, using the stock menu:", err)
        self.dialog_frame = nil
        return orig_update(self)
    end
end

-- Switching tabs: repaint what's behind when the sheet gets shorter.
function ConfigDialog:onShowConfigPanel(index)
    self.panel_index = index
    local old_dimen = self.dialog_frame and self.dialog_frame.dimen and self.dialog_frame.dimen:copy()
    self:update()
    local fresh = self.is_fresh
    UIManager:setDirty(fresh and self or "all", function()
        local d = self.dialog_frame.dimen
        local r = old_dimen and d and old_dimen:combine(d) or d or old_dimen
        self.is_fresh = false
        return "ui", r
    end)
    return true
end

return true
