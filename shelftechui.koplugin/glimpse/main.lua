--[[--
Glimpse: peek at maps, family trees and other reference images from anywhere
in the book, without losing your reading position.

EPUB-only (crengine): the book's HTML is parsed directly (see
glimpse_scanner.lua), which gives real pixel dimensions plus captions/alt
text for filtering out ornaments and icons.
]]

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local CheckButton = require("ui/widget/checkbutton")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageViewer = require("ui/widget/imageviewer")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local MovableContainer = require("ui/widget/container/movablecontainer")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local RadioButtonTable = require("ui/widget/radiobuttontable")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local TileCacheItem = require("document/tilecacheitem")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local md5 = require("ffi/sha2").md5
local _ = require("gettext")
local T = require("ffi/util").template
local Screen = Device.screen



local _PLUGIN_DIR = (debug.getinfo(1, "S").source or ""):match("@?(.*)/[^/]*$") or "."











do
    local mo = _PLUGIN_DIR .. "/l10n/" .. tostring(_.current_lang) .. "/glimpse.mo"
    pcall(function() _.loadMO(mo) end)
end

local scanner
do
    local ok, mod = pcall(dofile, _PLUGIN_DIR .. "/glimpse_scanner.lua")
    if ok then scanner = mod end
end

-- The retro Bookshelf look: chrome (buttons, menus, tabs, counters) in the
-- monospaced face, bold capitals; the book's own words (captions) stay as
-- they are.
-- (bundled in ShelfTechUI: the face and case of its theme)
local okLook, Look = pcall(require, "bos_look")
if not okLook then Look = nil end
local function chromeFace(size)
    if Look then return Look.mono(math.max(9, size - 2)) end
    return Font:getFace("infont", math.max(9, size - 2))
end
local function U(text)
    text = tostring(text or "")
    if Look and not Look.theme.upper then return text end
    local ok, Utf8Proc = pcall(require, "ffi/utf8proc")
    if ok and Utf8Proc and Utf8Proc.uppercase_dumb then
        local ok2, res = pcall(Utf8Proc.uppercase_dumb, text)
        if ok2 and res then return res end
    end
    return text:upper()
end

local SCOPE_KEY = "glimpse_scope"




local FILTER_KEY = "glimpse_filter"

local ENABLED_KEY = "glimpse_enabled"
local INVERT_KEY = "glimpse_invert_night"
local NAV_BUTTONS_KEY = "glimpse_nav_buttons"
local NAV_LOOP_KEY = "glimpse_nav_loop"
local ZOOMCTL_KEY = "glimpse_zoom_control"
local MINIMAP_KEY = "glimpse_minimap"
local CAPTIONS_KEY = "glimpse_captions"
local BOOKMARK_LABEL_KEY = "glimpse_bookmark_label"
local NUMERIC_PILL_KEY = "glimpse_numeric_pill"
local TOP_MENU_KEY = "glimpse_top_menu_zone"
local SHADOW_KEY = "glimpse_disable_shadow"
local FAST_SWITCH_KEY = "glimpse_fast_image_switch"
local SUPPRESS_UNSUPPORTED_KEY = "glimpse_suppress_unsupported"
local BOOKMARKS_KEY = "glimpse_include_bookmarks"
local LAYOUT_RIGHT_KEY = "glimpse_layout_right"
local PREF_ALIGN_KEY = "glimpse_pref_align"
local PORTRAIT_POS_KEY = "glimpse_portrait_pos"
local MINI_MODE_KEY = "glimpse_mini_mode"
local MINI_POS_KEY = "glimpse_mini_pos"
local MAX_ZOOM_KEY = "glimpse_max_zoom"
local GESTURE_TIP_KEY = "glimpse_gesture_tip_shown"

local GESTURE_DOUBLETAP_KEY = "glimpse_gesture_doubletap"
local GESTURE_SWIPE_KEY = "glimpse_gesture_swipe"
local GESTURE_PINCH_KEY = "glimpse_gesture_pinch"




local function _prefAlign()
    local v = G_reader_settings:readSetting(PREF_ALIGN_KEY)
    if v == "left" or v == "right" then return v end
    return G_reader_settings:isTrue(LAYOUT_RIGHT_KEY) and "right" or "left"
end

local function _portraitPos()
    local v = G_reader_settings:readSetting(PORTRAIT_POS_KEY)
    if v == "bottom" or v == "top" then return v end
    return "side"
end



local function _resolvePlacement()
    local pref = _prefAlign()
    if Screen:getWidth() > Screen:getHeight() then return pref end
    local pos = _portraitPos()
    if pos == "top" or pos == "bottom" then return pos end
    return pref
end




local function _miniMode()
    return G_reader_settings:isTrue(MINI_MODE_KEY)
end




local function _miniPos()
    local v = G_reader_settings:readSetting(MINI_POS_KEY)
    local x, y = 0.5, 0.5
    if type(v) == "table" then
        local vx, vy = tonumber(v.x), tonumber(v.y)
        if vx then x = math.min(1, math.max(0, vx)) end
        if vy then y = math.min(1, math.max(0, vy)) end
    end
    return x, y
end




local DEFAULT_MAX_ZOOM = 2.0
local MAX_ZOOM_CHOICES = { 1.5, 2.0, 2.5, 3.0, 4.0 }


local MIN_MAX_ZOOM = 1.0
local MAX_MAX_ZOOM = 10.0
local function _maxZoomMult()
    local v = tonumber(G_reader_settings:readSetting(MAX_ZOOM_KEY))
    if not v then return DEFAULT_MAX_ZOOM end
    return math.min(MAX_MAX_ZOOM, math.max(MIN_MAX_ZOOM, v))
end
local function _isPresetZoom(mult)
    for _, m in ipairs(MAX_ZOOM_CHOICES) do
        if m == mult then return true end
    end
    return false
end







local QUICK_ACTIONS_KEY = "glimpse_quick_actions"
local QUICK_ACTIONS = {
    { key = "hide",       default = true  },
    { key = "mode",       default = true  },
    { key = "rotate",     default = true  },
    { key = "showinbook", default = true  },
    { key = "prevnext",   default = false },
    { key = "zoomctl",    default = false },
    { key = "minimap",    default = false },
    { key = "captions",   default = false },
    { key = "bookmarks",  default = false },
    { key = "invert",     default = true  },
    { key = "layout",     default = false },
    { key = "minimode",   default = true  },
}
local function _quick_enabled(key)
    local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
    if type(cfg) == "table" and cfg[key] ~= nil then return cfg[key] end
    for _, d in ipairs(QUICK_ACTIONS) do
        if d.key == key then return d.default end
    end
    return false
end



local function _any_quick_enabled()
    for _, d in ipairs(QUICK_ACTIONS) do
        if _quick_enabled(d.key) then return true end
    end
    return false
end
local function _quick_label(key)
    return ({
        hide       = _("Ignore Image"),
        mode       = _("Mode switch"),
        rotate     = _("Rotate image"),
        showinbook = _("Show in Book"),
        prevnext   = _("Nav Buttons Toggle"),
        zoomctl    = _("Zoom Controls Toggle"),
        minimap    = _("Mini Map Toggle"),
        captions   = _("Image Captions Toggle"),
        bookmarks  = _("Include Bookmarks Toggle"),
        invert     = _("Invert in Night Mode Toggle"),
        layout     = _("Layout"),
        minimode   = _("Panel Size Switch"),
    })[key] or key
end










local SHADOW_BAYER8 = {
    { 0, 32,  8, 40,  2, 34, 10, 42},
    {48, 16, 56, 24, 50, 18, 58, 26},
    {12, 44,  4, 36, 14, 46,  6, 38},
    {60, 28, 52, 20, 62, 30, 54, 22},
    { 3, 35, 11, 43,  1, 33,  9, 41},
    {51, 19, 59, 27, 49, 17, 57, 25},
    {15, 47,  7, 39, 13, 45,  5, 37},
    {63, 31, 55, 23, 61, 29, 53, 21},
}





local function paint_dot(bb, cx, cy, r, fg, bg)
    for dy = -r - 1, r + 1 do
        for dx = -r - 1, r + 1 do
            local cov = r - math.sqrt(dx * dx + dy * dy) + 0.5
            if cov > 0 then
                if cov > 1 then cov = 1 end
                local v = math.floor(bg + cov * (fg - bg) + 0.5)
                bb:paintRect(cx + dx, cy + dy, 1, 1, Blitbuffer.Color8(v))
            end
        end
    end
end






local _bm_dot_cache = {}
local function bookmark_dot_stencil(box_w, box_h, v)
    local key = box_w .. "x" .. box_h .. ":" .. v
    local st = _bm_dot_cache[key]
    if st ~= nil then return st or nil end
    local ok, src = pcall(RenderImage.renderSVGImageFile, RenderImage,
        _PLUGIN_DIR .. "/assets/dot-bookmark.svg", box_w, box_h)
    if not (ok and src) then
        _bm_dot_cache[key] = false
        return nil
    end
    local w, h = src:getWidth(), src:getHeight()
    local dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)




    for yy = 0, h - 1 do
        for xx = 0, w - 1 do
            local a = src:getPixel(xx, yy):getAlpha()
            local a_above = yy > 0 and src:getPixel(xx, yy - 1):getAlpha() or 0
            a = math.floor((a + a_above) / 2 + 0.5)
            dst:setPixel(xx, yy, Blitbuffer.ColorRGB32(v, v, v, a))
        end
    end
    src:free()
    _bm_dot_cache[key] = dst
    return dst
end







local GlimpseDots = Widget:extend{
    nb = 1,
    cur = 1,
    is_bookmark = nil,
    dot_r = Screen:scaleBySize(3),
    pitch = Screen:scaleBySize(11),
    height = Screen:scaleBySize(10),
}

function GlimpseDots:getSize()
    return Geom:new{
        w = (self.nb - 1) * self.pitch + 2 * self.dot_r,
        h = self.height,
    }
end

function GlimpseDots:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self:getSize().w, h = self.height }
    local cy = y + math.floor(self.height / 2)
    local x0 = x + self.dot_r

    local box_w = 2 * self.dot_r
    local box_h = math.ceil(box_w * 7 / 6)
    for i = 1, self.nb do
        local cx = x0 + (i - 1) * self.pitch
        local v = i == self.cur and 0xFF or 0x66
        local glyph = self.is_bookmark and self.is_bookmark[i]
            and bookmark_dot_stencil(box_w, box_h, v)
        if glyph then
            local gw, gh = glyph:getWidth(), glyph:getHeight()


            local nudge = Screen:scaleBySize(1) - 1
            bb:alphablitFrom(glyph, cx - math.floor(gw / 2),
                cy - math.floor(gh / 2) + nudge, 0, 0, gw, gh)
        else
            paint_dot(bb, cx, cy, self.dot_r, v, 0x00)
        end
    end
end


local GlimpseEllipsis = Widget:extend{
    size = Screen:scaleBySize(18),
}

function GlimpseEllipsis:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function GlimpseEllipsis:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local r = math.max(2, math.floor(self.size / 9))
    local cx = x + math.floor(self.size / 2)
    local cy = y + math.floor(self.size / 2)
    paint_dot(bb, cx - 3 * r, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx, cy, r, 0x00, 0xFF)
    paint_dot(bb, cx + 3 * r, cy, r, 0x00, 0xFF)
end








local function make_rounded_stencil(w, h, r, stroke, fill, outline)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    local no_fill = fill == nil
    if r < 1 then
        -- square (the retro look): an outline `stroke` wide, the fill inside
        -- (a new buffer is transparent: only the outline and fill are painted)
        local oc = outline or fill or 0
        local oc32 = Blitbuffer.ColorRGB32(oc, oc, oc, 0xFF)
        local t = math.min(stroke or 0, math.floor(math.min(w, h) / 2))
        if not no_fill then
            bb:paintRect(0, 0, w, h, Blitbuffer.ColorRGB32(fill, fill, fill, 0xFF))
        end
        if t > 0 then
            bb:paintRect(0, 0, w, t, oc32)
            bb:paintRect(0, h - t, w, t, oc32)
            bb:paintRect(0, 0, t, h, oc32)
            bb:paintRect(w - t, 0, t, h, oc32)
        end
        return bb
    end





    local iL, iR, iT, iB = r, w - r, r, h - r
    local has_interior = iR > iL and iB > iT
    if has_interior and not no_fill then
        bb:paintRect(iL, iT, iR - iL, iB - iT,
            Blitbuffer.ColorRGB32(fill, fill, fill, 0xFF))
    end
    local function emit(px, py)
        local sx = math.min(math.max(px + 0.5, r), w - r)
        local sy = math.min(math.max(py + 0.5, r), h - r)
        local dx, dy = px + 0.5 - sx, py + 0.5 - sy
        local d = math.sqrt(dx * dx + dy * dy)
        local cov = math.min(math.max(r - d + 0.5, 0), 1)
        if cov > 0 then
            local t_in = math.min(math.max((r - stroke) - d + 0.5, 0), 1)
            if no_fill then


                local a = cov * (1 - t_in)
                if a > 0 then
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                        outline, outline, outline,
                        math.floor(a * 255 + 0.5)))
                end
            else
                local g = math.floor(outline + t_in * (fill - outline) + 0.5)
                bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                    g, g, g, math.floor(cov * 255 + 0.5)))
            end
        end
    end
    for py = 0, h - 1 do
        if has_interior and py >= iT and py < iB then
            for px = 0, iL - 1 do emit(px, py) end
            for px = iR, w - 1 do emit(px, py) end
        else
            for px = 0, w - 1 do emit(px, py) end
        end
    end
    return bb
end






local function make_corner_stencil(w, h, r, corners, stroke, fill, outline, sides)
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
    local no_fill = fill == nil
    if r < 1 then
        -- square (the retro look), painted in a few rects instead of pixel by pixel
        local oc = outline or fill or 0
        local oc32 = Blitbuffer.ColorRGB32(oc, oc, oc, 0xFF)
        local t = math.min(stroke or 0, math.floor(math.min(w, h) / 2))
        if not no_fill then
            bb:paintRect(0, 0, w, h, Blitbuffer.ColorRGB32(fill, fill, fill, 0xFF))
        end
        if t > 0 then
            if (not sides) or sides.t then bb:paintRect(0, 0, w, t, oc32) end
            if (not sides) or sides.b then bb:paintRect(0, h - t, w, t, oc32) end
            if (not sides) or sides.l then bb:paintRect(0, 0, t, h, oc32) end
            if (not sides) or sides.r then bb:paintRect(w - t, 0, t, h, oc32) end
        end
        return bb
    end




    local side_t = (not sides) or sides.t
    local side_b = (not sides) or sides.b
    local side_l = (not sides) or sides.l
    local side_r = (not sides) or sides.r



    local function arc_center(px, py)
        local cx, cy, on
        if px < r and py < r then cx, cy, on = r, r, corners.tl
        elseif px >= w - r and py < r then cx, cy, on = w - r, r, corners.tr
        elseif px < r and py >= h - r then cx, cy, on = r, h - r, corners.bl
        elseif px >= w - r and py >= h - r then cx, cy, on = w - r, h - r, corners.br
        end
        if on then return cx, cy end
    end
    for py = 0, h - 1 do
        for px = 0, w - 1 do
            local cov, dist_edge
            local ccx, ccy = arc_center(px, py)
            if ccx then
                local dx, dy = px + 0.5 - ccx, py + 0.5 - ccy
                local d = math.sqrt(dx * dx + dy * dy)
                cov = math.min(math.max(r - d + 0.5, 0), 1)
                dist_edge = r - d
            else
                cov = 1

                dist_edge = math.huge
                if side_l then dist_edge = math.min(dist_edge, px + 0.5) end
                if side_r then dist_edge = math.min(dist_edge, w - 0.5 - px) end
                if side_t then dist_edge = math.min(dist_edge, py + 0.5) end
                if side_b then dist_edge = math.min(dist_edge, h - 0.5 - py) end
            end
            if cov > 0 then
                local t_in = math.min(math.max(dist_edge - stroke + 0.5, 0), 1)
                if no_fill then
                    local a = cov * (1 - t_in)
                    if a > 0 then
                        bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                            outline, outline, outline,
                            math.floor(a * 255 + 0.5)))
                    end
                else
                    local g = math.floor(outline + t_in * (fill - outline) + 0.5)
                    bb:setPixel(px, py, Blitbuffer.ColorRGB32(
                        g, g, g, math.floor(cov * 255 + 0.5)))
                end
            end
        end
    end
    return bb
end













local INVERT_FILL_MIN = 0xF0
local function invert_stencil_fill(bb, stencil, x, y, w, h, y0, y1)
    for yy = y0 or 0, (y1 or h) - 1 do
        for xx = 0, w - 1 do
            local s = stencil:getPixel(xx, yy):getColorRGB32()
            if s.alpha > 127 and s.r >= INVERT_FILL_MIN then
                bb:setPixel(x + xx, y + yy,
                    bb:getPixel(x + xx, y + yy):getColorRGB32():invert())
            end
        end
    end
end











local _shadow_cache = {}
local function drop_shadow_bb(w, h, r, blur, dy, opacity, night, dither)
    local value = night and 0xFF or 0x00
    local key = table.concat({ w, h, r, blur, dy, opacity, value,
        dither and 1 or 0 }, ":")
    if _shadow_cache[key] then return _shadow_cache[key] end
    local sw, sh = w + 2 * blur, h + 2 * blur + dy
    local bb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)






    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r
    local function emit(px, py)

        local sx = math.min(math.max(px + 0.5, blur + r), blur + w - r)
        local sy = math.min(math.max(py + 0.5, blur + r), blur + h - r)
        local ddx, ddy = px + 0.5 - sx, py + 0.5 - sy
        local dist = math.sqrt(ddx * ddx + ddy * ddy) - r
        local cov = dist <= 0 and 1 or math.max(0, 1 - dist / blur)
        if cov > 0 then

            cov = cov * cov * (3 - 2 * cov)
            if dither then








                local level = opacity * cov * 255
                local threshold = (SHADOW_BAYER8[(px % 8) + 1][(py % 8) + 1] + 0.5) * 4
                if level > threshold then
                    bb:setPixel(px, py,
                        Blitbuffer.ColorRGB32(value, value, value, 255))
                end
            else
                local a = math.floor(opacity * cov * 255 + 0.5)
                if a > 0 then
                    bb:setPixel(px, py,
                        Blitbuffer.ColorRGB32(value, value, value, a))
                end
            end
        end
    end
    for py = 0, sh - 1 do
        if py >= inT and py < inB then
            for px = 0, inL - 1 do emit(px, py) end
            for px = inR, sw - 1 do emit(px, py) end
        else
            for px = 0, sw - 1 do emit(px, py) end
        end
    end
    _shadow_cache[key] = bb
    return bb
end




-- The retro Bookshelf look: a hard shadow, square, down and to the right
-- (no blur). Painted before the widget, which then covers its own part.
local HARD_SHADOW = Screen:scaleBySize(3)
local HARD_PANEL_SHADOW = Screen:scaleBySize(6)
local function paint_drop_shadow(bb, x, y, w, h, r, blur, dy, day_op, night_op, dither)
    if G_reader_settings:isTrue(SHADOW_KEY) then return end
    local col = Screen.night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    bb:paintRect(x + HARD_SHADOW, y + HARD_SHADOW, w, h, col)
    do return end
    local night = Screen.night_mode
    local s = drop_shadow_bb(w, h, r, blur, dy,
        night and night_op or day_op, night, dither)
    local sw, sh = s:getWidth(), s:getHeight()
    local ox, oy = x - blur, y - blur + dy


    local inL, inR = blur + r, blur + w - r
    local inT, inB = blur + r, blur + h - r
    if inR <= inL or inB <= inT then
        bb:alphablitFrom(s, ox, oy, 0, 0, sw, sh)
        return
    end
    bb:alphablitFrom(s, ox, oy, 0, 0, sw, inT)
    bb:alphablitFrom(s, ox, oy + inB, 0, inB, sw, sh - inB)
    bb:alphablitFrom(s, ox, oy + inT, 0, inT, inL, inB - inT)
    bb:alphablitFrom(s, ox + inR, oy + inT, inR, inT, sw - inR, inB - inT)
end











local CHROME_OUTLINE = Screen:scaleBySize(2)
local _outline_cache = {}
local function paint_chrome_outline(bb, x, y, w, h, r, corners, sides)
    local ow = CHROME_OUTLINE
    local c = corners or { tl = true, tr = true, bl = true, br = true }
    local s = sides or { t = true, b = true, l = true, r = true }
    local gl, gr = s.l and ow or 0, s.r and ow or 0
    local gt, gb = s.t and ow or 0, s.b and ow or 0
    local ow_w, ow_h = w + gl + gr, h + gt + gb
    if ow_w <= 0 or ow_h <= 0 then return end
    local key = table.concat({ ow_w, ow_h, r + ow,
        c.tl and 1 or 0, c.tr and 1 or 0, c.bl and 1 or 0, c.br and 1 or 0 }, ":")
    local sbb = _outline_cache[key]
    if not sbb then

        sbb = make_corner_stencil(ow_w, ow_h, r + ow, c, 1, 0xFF, 0xFF)
        _outline_cache[key] = sbb
    end
    bb:alphablitFrom(sbb, x - gl, y - gt, 0, 0, ow_w, ow_h)
end






local GlimpsePill = WidgetContainer:extend{
    inner = nil,
    padding_h = Screen:scaleBySize(9),
    height = Screen:scaleBySize(21),
    radius = 0,
    stroke = Screen:scaleBySize(2),
    inverted = nil,


    square_bottom = false,



    inner_dy = 0,




    fixed_height = false,
}

function GlimpsePill:init()
    self[1] = self.inner
end

function GlimpsePill:getSize()
    local inner = self.inner:getSize()
    return Geom:new{
        w = inner.w + 2 * self.padding_h,
        h = self.fixed_height and self.height
            or math.max(self.height, inner.h),
    }
end

function GlimpsePill:paintTo(bb, x, y)
    local size = self:getSize()
    local w, h = size.w, size.h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }
    if not self._bg_bb or self._bg_w ~= w or self._bg_h ~= h then
        if self._bg_bb then self._bg_bb:free() end
        local fill = self.inverted and 0xFF or 0x00
        local outline = self.inverted and 0x00 or 0xFF
        if self.square_bottom then
            self._bg_bb = make_corner_stencil(w, h, self.radius,
                { tl = true, tr = true, bl = false, br = false },
                self.stroke, fill, outline)
        else
            self._bg_bb = make_rounded_stencil(w, h, self.radius, self.stroke,
                fill, outline)
        end
        self._bg_w, self._bg_h = w, h
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
    local inner_size = self.inner:getSize()
    self.inner:paintTo(bb,
        x + math.floor((w - inner_size.w) / 2),
        y + math.floor((h - inner_size.h) / 2) + self.inner_dy)
end

function GlimpsePill:free(...)
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    WidgetContainer.free(self, ...)
end






local GlimpseBadge = Widget:extend{
    num = 1,
    glyph = nil,
    icon = nil,
    height = Screen:scaleBySize(17),
    radius = 0,
    stroke = Screen:scaleBySize(1),
    pad_h = Screen:scaleBySize(4),
}

function GlimpseBadge:init()
    if self.icon then
        local sz = Screen:scaleBySize(11)
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, sz, sz)
        if ok and ibb then self._icon_bb = ibb end
        self._w = self.height
    else
        self._txt = TextWidget:new{
            text = self.glyph or tostring(self.num),
            face = chromeFace(12),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        self._w = math.max(self.height, self._txt:getSize().w + 2 * self.pad_h)
    end
end

function GlimpseBadge:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function GlimpseBadge:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    if self._icon_bb then
        local iw, ih = self._icon_bb:getWidth(), self._icon_bb:getHeight()
        bb:alphablitFrom(self._icon_bb,
            x + math.floor((self._w - iw) / 2),
            y + math.floor((self.height - ih) / 2),
            0, 0, iw, ih)
    elseif self._txt then
        local ts = self._txt:getSize()
        self._txt:paintTo(bb, x + math.floor((self._w - ts.w) / 2),
            y + math.floor((self.height - ts.h) / 2))
    end
end

function GlimpseBadge:free()
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    if self._icon_bb then self._icon_bb:free(); self._icon_bb = nil end
    if self._txt then self._txt:free() end
end






local GlimpseDimVeil = Widget:extend{
    cells = nil,
    except = nil,
    dim = 0.6,
}

function GlimpseDimVeil:getSize()
    return Geom:new{ w = 0, h = 0 }
end

function GlimpseDimVeil:paintTo(bb, x, y)
    for _, c in ipairs(self.cells or {}) do
        if c.idx ~= self.except then
            bb:lightenRect(x + c.x, y + c.y, c.w, c.h, self.dim)
        end
    end
end





local GlimpseMoreButton = Widget:extend{
    size = Screen:scaleBySize(42),
    radius = 0,
    stroke = Screen:scaleBySize(2),
    icon = nil,
    icon_size = Screen:scaleBySize(18),
    disabled = nil,
    disabled_gray = 0xB4,



    outline = false,
    outline_sides = nil,
    square_top = false,
    corners = nil,


}

function GlimpseMoreButton:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function GlimpseMoreButton:_corners()
    if self.corners then return self.corners end
    if not self.square_top then
        return { tl = true, tr = true, bl = true, br = true }
    end
    return { tl = false, tr = false, bl = true, br = true }
end

function GlimpseMoreButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local cc = self:_corners()


    if self.outline then


        paint_chrome_outline(bb, x, y, self.size, self.size, self.radius,
            cc, self.outline_sides)
    elseif not self.disabled then
        paint_drop_shadow(bb, x, y, self.size, self.size, self.radius,
            Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    end


    local bgkey = table.concat({
        cc.tl and 1 or 0, cc.tr and 1 or 0, cc.bl and 1 or 0, cc.br and 1 or 0,
        tostring(self.disabled) }, ":")
    if self._bg_bb and self._bg_key ~= bgkey then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if not self._bg_bb then



        self._bg_key = bgkey
        self._bg_bb = make_corner_stencil(self.size, self.size,
            self.radius, cc, self.stroke, 0xFF,
            self.disabled and self.disabled_gray or 0x00)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self.size, self.size)

    if self.icon and not self._icon_bb then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            if self.disabled then

                local g = self.disabled_gray
                for yy = 0, ibb:getHeight() - 1 do
                    for xx = 0, ibb:getWidth() - 1 do
                        local c = ibb:getPixel(xx, yy):getColorRGB32()
                        if c.alpha > 0 then
                            ibb:setPixel(xx, yy,
                                Blitbuffer.ColorRGB32(g, g, g, c.alpha))
                        end
                    end
                end
            end
            self._icon_bb = ibb
        end
    end
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb,
            x + math.floor((self.size - self.icon_size) / 2),
            y + math.floor((self.size - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
    else
        if not self._icon then
            self._icon = GlimpseEllipsis:new{}
        end
        local isz = self._icon:getSize()
        self._icon:paintTo(bb,
            x + math.floor((self.size - isz.w) / 2),
            y + math.floor((self.size - isz.h) / 2))
    end
    if self.inverted then




        invert_stencil_fill(bb, self._bg_bb, x, y, self.size, self.size)
    end
end

function GlimpseMoreButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
end








local GlimpseZoomControl = Widget:extend{
    width = GlimpseMoreButton.size,


    height = GlimpseMoreButton.size * 3,
    radius = 0,
    stroke = Screen:scaleBySize(2),
    inset = Screen:scaleBySize(2),
    divider_gray = 0xDB,



    divider_gray_night = 0xC4,
    disabled_gray = 0xCC,
    fit_disabled = false,
    minus_disabled = false,
    plus_disabled = false,
    inverted_zone = nil,



    no_fit = false,


    outline = false,
    outline_sides = nil,
    square_bottom = false,
    square_right = false,

    merge_bottom = false,



    square_side = nil,

    group_shadow = nil,

}

function GlimpseZoomControl:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function GlimpseZoomControl:_ensureIcons()
    if self._icons_done then return end
    self._icons_done = true
    local function render(name, sz)
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            _PLUGIN_DIR .. "/assets/" .. name, sz, sz)
        if ok and ibb then return ibb end
    end


    local function dim(ibb)
        if not ibb then return end
        local g = self.disabled_gray
        for yy = 0, ibb:getHeight() - 1 do
            for xx = 0, ibb:getWidth() - 1 do
                local c = ibb:getPixel(xx, yy):getColorRGB32()
                if c.alpha > 0 then
                    ibb:setPixel(xx, yy, Blitbuffer.ColorRGB32(g, g, g, c.alpha))
                end
            end
        end
        return ibb
    end
    local s16, s18 = Screen:scaleBySize(16), Screen:scaleBySize(18)
    self._minus_bb = render("zoom-minus.svg", s16)
    self._plus_bb  = render("zoom-plus.svg", s16)
    self._fit_bb   = render("zoom-fit.svg", s18)
    self._minus_dim_bb = dim(render("zoom-minus.svg", s16))
    self._plus_dim_bb  = dim(render("zoom-plus.svg", s16))
    self._fit_dim_bb   = dim(render("zoom-fit.svg", s18))
end

function GlimpseZoomControl:paintTo(bb, x, y)
    local w, h = self.width, self.height
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }


    local bgkey = tostring(self.square_side) .. tostring(self.square_bottom)
        .. tostring(self.square_right) .. tostring(self.merge_bottom)
    if self._bg_side ~= bgkey then
        if self._bg_bb then self._bg_bb:free() end
        self._bg_bb = nil
        self._bg_side = bgkey
    end
    local c = { tl = true, tr = true, bl = true, br = true }
    if self.square_side == "left" then c.tl, c.bl = false, false
    elseif self.square_side == "right" then c.tr, c.br = false, false end
    if self.square_bottom then c.bl, c.br = false, false end
    if self.square_right then c.tr, c.br = false, false end
    if not self._bg_bb then


        self._bg_bb = make_corner_stencil(w, h, self.radius, c, self.stroke,
            0xFF, 0x00,
            self.merge_bottom
                and { t = true, b = false, l = true, r = true } or nil)
    end


    local s2 = Screen:scaleBySize(2)
    if self.outline then


        paint_chrome_outline(bb, x, y, w, h, self.radius, c, self.outline_sides)
    elseif self.group_shadow then
        local g = self.group_shadow
        paint_drop_shadow(bb, x + g.x_off, y, g.w, g.h, self.radius, s2, s2, 0.3, 0.5)
    else
        paint_drop_shadow(bb, x, y, w, h, self.radius, s2, s2, 0.3, 0.5)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)

    local nz = self.no_fit and 2 or 3
    local zone = h / nz
    local dth = math.max(1, Screen:scaleBySize(1))
    local dx = x + self.inset
    local dw = w - 2 * self.inset
    local dg = Screen.night_mode and self.divider_gray_night
        or self.divider_gray
    local dcol = Blitbuffer.ColorRGB32(dg, dg, dg, 0xFF)
    for i = 1, nz - 1 do
        bb:paintRect(dx, y + math.floor(i * zone - dth / 2), dw, dth, dcol)
    end
    if self.merge_bottom then

        bb:paintRect(dx, y + h - dth, dw, dth, dcol)
    end

    self:_ensureIcons()
    local function icon(ibb, cy)
        if not ibb then return end
        bb:alphablitFrom(ibb,
            x + math.floor((w - ibb:getWidth()) / 2),
            y + math.floor(cy - ibb:getHeight() / 2),
            0, 0, ibb:getWidth(), ibb:getHeight())
    end
    icon(self.plus_disabled and self._plus_dim_bb or self._plus_bb,
        zone / 2)
    if not self.no_fit then
        icon(self.fit_disabled and self._fit_dim_bb or self._fit_bb, h / 2)
    end
    icon(self.minus_disabled and self._minus_dim_bb or self._minus_bb,
        h - zone / 2)


    if self.inverted_zone then
        local z0 = math.floor(self.inverted_zone * zone)
        local z1 = math.floor((self.inverted_zone + 1) * zone)
        invert_stencil_fill(bb, self._bg_bb, x, y, w, h, z0, z1)
    end
end

function GlimpseZoomControl:free()
    for _, k in ipairs({ "_bg_bb", "_minus_bb", "_plus_bb", "_fit_bb",
            "_minus_dim_bb", "_plus_dim_bb", "_fit_dim_bb" }) do
        if self[k] then self[k]:free(); self[k] = nil end
    end
    self._icons_done = nil
end






local GlimpseDragGrip = Widget:extend{
    size = Screen:scaleBySize(24),

    art_w = 19,
    art_h = 13,
}

function GlimpseDragGrip:getSize()
    return Geom:new{ w = self.size, h = self.size }
end

function GlimpseDragGrip:paintTo(bb, x, y)
    local s = self.size
    self.dimen = Geom:new{ x = x, y = y, w = s, h = s }
    if not self._icon_bb then
        local iw = math.floor(s * self.art_w / 24 + 0.5)
        local ih = math.floor(iw * self.art_h / self.art_w + 0.5)
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            _PLUGIN_DIR .. "/assets/drag.svg", iw, ih)
        if ok and ibb then self._icon_bb = ibb end
    end
    local ibb = self._icon_bb
    if not ibb then return end
    bb:alphablitFrom(ibb,
        x + math.floor((s - ibb:getWidth()) / 2),
        y + math.floor((s - ibb:getHeight()) / 2),
        0, 0, ibb:getWidth(), ibb:getHeight())
end

function GlimpseDragGrip:free()
    if self._icon_bb then self._icon_bb:free(); self._icon_bb = nil end
end












local function rotate_bb_quadrant(src, deg)
    deg = deg % 360
    if deg == 0 then return src:copy() end
    local w, h = src:getWidth(), src:getHeight()
    local dst
    if deg == 180 then
        dst = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                dst:setPixel(w - 1 - x, h - 1 - y, src:getPixel(x, y))
            end
        end
    else
        dst = Blitbuffer.new(h, w, Blitbuffer.TYPE_BBRGB32)
        for y = 0, h - 1 do
            for x = 0, w - 1 do
                if deg == 90 then
                    dst:setPixel(h - 1 - y, x, src:getPixel(x, y))
                else
                    dst:setPixel(y, w - 1 - x, src:getPixel(x, y))
                end
            end
        end
    end
    return dst
end

local GlimpseMiniMap = Widget:extend{
    radius = 0,
    border = Screen:scaleBySize(2),
    rect_border = Screen:scaleBySize(2),
    rect_radius = 0,
    fade = 0.68,
    max_aspect = 1.0,




    box_w = nil, box_h = nil,
    corners = nil,
    thumb = nil,
    off_x = nil, off_y = nil,
    disp_w = nil, disp_h = nil,
    viewer = nil,
    outline = false,
    outline_sides = nil,
    no_shadow = false,

}

function GlimpseMiniMap:getSize()
    return Geom:new{ w = self.box_w, h = self.box_h }
end



function GlimpseMiniMap:_viewportRect()
    local v = self.viewer
    local wg = v and v._image_wg
    if not (wg and wg._bb_w and wg._bb_h and wg.width and wg.height) then return end
    local fx = math.min(1, wg.width / wg._bb_w)
    local fy = math.min(1, wg.height / wg._bb_h)
    local cx = wg.center_x_ratio or v._center_x_ratio or 0.5
    local cy = wg.center_y_ratio or v._center_y_ratio or 0.5
    local rw = fx * self.disp_w
    local rh = fy * self.disp_h
    local rx = self.off_x + cx * self.disp_w - rw / 2
    local ry = self.off_y + cy * self.disp_h - rh / 2
    rx = math.min(math.max(rx, self.off_x), self.off_x + self.disp_w - rw)
    ry = math.min(math.max(ry, self.off_y), self.off_y + self.disp_h - rh)
    return math.floor(rx + 0.5), math.floor(ry + 0.5),
        math.floor(rw + 0.5), math.floor(rh + 0.5)
end

function GlimpseMiniMap:paintTo(bb, x, y)
    local w, h = self.box_w, self.box_h
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }



    local paper = 0xFF
    local ink = 0x00

    local skey = w .. "x" .. h .. ":" ..
        (self.corners.tl and "1" or "0") .. (self.corners.tr and "1" or "0") ..
        (self.corners.bl and "1" or "0") .. (self.corners.br and "1" or "0")
    if self._skey ~= skey then
        if self._base then self._base:free() end
        if self._ring then self._ring:free() end
        if self._ibright then self._ibright:free() end
        if self._idim then self._idim:free() end
        self._base = make_corner_stencil(w, h, self.radius, self.corners,
            self.border, paper, paper)
        self._ring = make_corner_stencil(w, h, self.radius, self.corners,
            self.border, nil, ink)






        local bright = self._base:copy()
        if self.thumb then
            bright:blitFrom(self.thumb, self.off_x, self.off_y,
                0, 0, self.disp_w, self.disp_h)
        end
        local dim = bright:copy()
        local fade = self.fade
        for py = 0, h - 1 do
            for px = 0, w - 1 do
                local ba = self._base:getPixel(px, py):getColorRGB32().alpha
                if ba < 0xFF then

                    local cb = bright:getPixel(px, py):getColorRGB32()
                    bright:setPixel(px, py,
                        Blitbuffer.ColorRGB32(cb.r, cb.g, cb.b, ba))
                    local cd = dim:getPixel(px, py):getColorRGB32()
                    dim:setPixel(px, py,
                        Blitbuffer.ColorRGB32(cd.r, cd.g, cd.b, ba))
                elseif fade > 0 then

                    local c = dim:getPixel(px, py):getColorRGB32()
                    dim:setPixel(px, py, Blitbuffer.ColorRGB32(
                        math.floor(c.r * (1 - fade) + paper * fade + 0.5),
                        math.floor(c.g * (1 - fade) + paper * fade + 0.5),
                        math.floor(c.b * (1 - fade) + paper * fade + 0.5),
                        c.alpha))
                end
            end
        end
        self._ibright = bright
        self._idim = dim
        self._skey = skey
    end


    if self.outline then



        paint_chrome_outline(bb, x, y, w, h, self.radius, self.corners,
            self.outline_sides)
    elseif not self.no_shadow then
        paint_drop_shadow(bb, x, y, w, h, self.radius,
            Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    end




    local temp = self._idim:copy()
    local rx, ry, rw, rh = self:_viewportRect()
    if rx then

        local cx, cy = math.max(0, rx), math.max(0, ry)
        local cw = math.min(rx + rw, w) - cx
        local ch = math.min(ry + rh, h) - cy
        local t = self.rect_border



        local r = math.min(self.rect_radius,
            math.floor(rw / 2), math.floor(rh / 2))
        if cw == rw and ch == rh and r >= 1 then
            local vkey = rw .. "x" .. rh .. ":" .. r
            if self._vkey ~= vkey then
                if self._vp_ring then self._vp_ring:free() end
                if self._vp_mask then self._vp_mask:free() end
                if self._vp_piece then self._vp_piece:free() end
                self._vp_ring = make_rounded_stencil(rw, rh, r, t, nil, ink)
                self._vp_mask = make_rounded_stencil(rw, rh, r, 0, 0xFF, 0xFF)
                self._vp_piece = Blitbuffer.new(rw, rh, Blitbuffer.TYPE_BBRGB32)
                self._vkey = vkey
            end
            local piece = self._vp_piece
            piece:blitFrom(self._ibright, 0, 0, rx, ry, rw, rh)


            for _, corner in ipairs({ { 0, 0 }, { rw - r, 0 },
                                      { 0, rh - r }, { rw - r, rh - r } }) do
                for py = corner[2], corner[2] + r - 1 do
                    for px = corner[1], corner[1] + r - 1 do
                        local a = self._vp_mask:getPixel(px, py)
                            :getColorRGB32().alpha
                        if a < 0xFF then
                            local c = piece:getPixel(px, py):getColorRGB32()
                            piece:setPixel(px, py,
                                Blitbuffer.ColorRGB32(c.r, c.g, c.b, a))
                        end
                    end
                end
            end
            temp:alphablitFrom(piece, rx, ry, 0, 0, rw, rh)
            temp:alphablitFrom(self._vp_ring, rx, ry, 0, 0, rw, rh)
        else

            if cw > 0 and ch > 0 then
                temp:blitFrom(self._ibright, cx, cy, cx, cy, cw, ch)
            end
            local rcol = Blitbuffer.ColorRGB32(ink, ink, ink, 0xFF)
            temp:paintRect(rx, ry, rw, t, rcol)
            temp:paintRect(rx, ry + rh - t, rw, t, rcol)
            temp:paintRect(rx, ry, t, rh, rcol)
            temp:paintRect(rx + rw - t, ry, t, rh, rcol)
        end
    end
    bb:alphablitFrom(temp, x, y, 0, 0, w, h)
    temp:free()
    bb:alphablitFrom(self._ring, x, y, 0, 0, w, h)
end

function GlimpseMiniMap:free()
    for _, k in ipairs({ "_base", "_ring", "_ibright", "_idim", "thumb",
                         "_vp_ring", "_vp_mask", "_vp_piece" }) do
        if self[k] and self[k].free then self[k]:free() end
        self[k] = nil
    end
    self._skey = nil
    self._vkey = nil
end







local GlimpseCaption = Widget:extend{
    text = "",
    max_width = 0,
    radius = 0,
    stroke = Screen:scaleBySize(2),
    pad_h = Screen:scaleBySize(8),
    pad_v = Screen:scaleBySize(4),
    border_gray = 0x00,
}

function GlimpseCaption:init()
    local face = Font:getFace("cfont", 12)



    local text_cap = self.max_width - 2 * self.pad_h
    if text_cap < 1 then text_cap = 1 end
    local probe = TextWidget:new{ text = self.text, face = face, bold = true }
    local natural = probe:getSize().w
    probe:free()
    local box_w = math.min(natural + Screen:scaleBySize(1), text_cap)
    if box_w < 1 then box_w = 1 end
    self._text = TextBoxWidget:new{
        text = self.text,
        face = face,
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        width = box_w,
        alignment = "left",

    }
end

function GlimpseCaption:getSize()
    local s = self._text:getSize()
    return Geom:new{
        w = s.w + 2 * self.pad_h,
        h = s.h + 2 * self.pad_v,
    }
end





function GlimpseCaption:_buildBg(w, h)
    self._bg_bb = make_rounded_stencil(w, h, self.radius, self.stroke,
        0xFF, self.border_gray)
    self._text:paintTo(self._bg_bb, self.pad_h, self.pad_v)
end

function GlimpseCaption:paintTo(bb, x, y)
    self.dimen = self:getSize()
    self.dimen.x, self.dimen.y = x, y
    local w, h = self.dimen.w, self.dimen.h
    if not self._bg_bb then self:_buildBg(w, h) end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, w, h)
end

function GlimpseCaption:free()
    if self._text then self._text:free() end
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
end






local GlimpseBookmarkPill = Widget:extend{
    text = "",
    icon = nil,
    max_width = 0,
    radius = 0,
    stroke = Screen:scaleBySize(2),
    pad_h = Screen:scaleBySize(8),
    pad_v = Screen:scaleBySize(4),
    gap = Screen:scaleBySize(4),
    icon_size = Screen:scaleBySize(16),
    border_gray = 0x00,
}

function GlimpseBookmarkPill:init()
    if self.icon then
        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then self._icon_bb = ibb end
    end
    local iw = self._icon_bb and self._icon_bb:getWidth() or 0
    local gap = iw > 0 and self.gap or 0


    local text_cap = self.max_width - 2 * self.pad_h - iw - gap
    if text_cap < 1 then text_cap = nil end
    self._txt = TextWidget:new{
        text = self.text,
        face = Font:getFace("cfont", 12),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = text_cap,
    }
    local ts = self._txt:getSize()
    self._w = 2 * self.pad_h + iw + gap + ts.w
    self._h = 2 * self.pad_v + math.max(self.icon_size, ts.h)
end

function GlimpseBookmarkPill:getSize()
    return Geom:new{ w = self._w, h = self._h }
end

function GlimpseBookmarkPill:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self._h }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self._h,
            self.radius, self.stroke, 0xFF, self.border_gray)
    end
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self._h)
    local cx = x + self.pad_h
    if self._icon_bb then
        local iw, ih = self._icon_bb:getWidth(), self._icon_bb:getHeight()
        bb:alphablitFrom(self._icon_bb, cx,
            y + math.floor((self._h - ih) / 2), 0, 0, iw, ih)
        cx = cx + iw + self.gap
    end
    local ts = self._txt:getSize()
    self._txt:paintTo(bb, cx, y + math.floor((self._h - ts.h) / 2))
end

function GlimpseBookmarkPill:free()
    if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    if self._icon_bb then self._icon_bb:free(); self._icon_bb = nil end
    if self._txt then self._txt:free() end
end





local GlimpseTextButton = Widget:extend{
    text = "",
    bold = false,
    icon = nil,
    icon_size = Screen:scaleBySize(16),
    icon_gap = Screen:scaleBySize(7),
    height = Screen:scaleBySize(42),
    radius = 0,
    stroke = Screen:scaleBySize(2),
    padding_h = Screen:scaleBySize(14),
    inverted = nil,
}

function GlimpseTextButton:init()
    self._text_wg = TextWidget:new{
        text = U(self.text),
        face = chromeFace(15),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local content_w = self._text_wg:getSize().w
    if self.icon then


        local ok, ibb = pcall(RenderImage.renderSVGImageFile, RenderImage,
            self.icon, self.icon_size, self.icon_size)
        if ok and ibb then
            self._icon_bb = ibb
            content_w = content_w + self.icon_size + self.icon_gap
        end
    end
    self._w = content_w + 2 * self.padding_h
end

function GlimpseTextButton:getSize()
    return Geom:new{ w = self._w, h = self.height }
end



function GlimpseTextButton:setWidth(w)
    if w and w > 0 and w ~= self._w then
        self._w = w
        if self._bg_bb then self._bg_bb:free(); self._bg_bb = nil end
    end
end

function GlimpseTextButton:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self._w, h = self.height }
    if not self._bg_bb then
        self._bg_bb = make_rounded_stencil(self._w, self.height,
            self.radius, self.stroke, 0xFF, 0x00)
    end

    paint_drop_shadow(bb, x, y, self._w, self.height, self.radius,
        Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    bb:alphablitFrom(self._bg_bb, x, y, 0, 0, self._w, self.height)
    local tsz = self._text_wg:getSize()
    local icon_w = self._icon_bb and (self.icon_size + self.icon_gap) or 0
    local cx = x + math.floor((self._w - icon_w - tsz.w) / 2)
    if self._icon_bb then
        bb:alphablitFrom(self._icon_bb, cx,
            y + math.floor((self.height - self.icon_size) / 2),
            0, 0, self._icon_bb:getWidth(), self._icon_bb:getHeight())
        cx = cx + self.icon_size + self.icon_gap
    end
    self._text_wg:paintTo(bb, cx, y + math.floor((self.height - tsz.h) / 2))
    if self.inverted then


        invert_stencil_fill(bb, self._bg_bb, x, y, self._w, self.height)
    end
end

function GlimpseTextButton:free()
    if self._bg_bb then
        self._bg_bb:free()
        self._bg_bb = nil
    end
    if self._icon_bb then
        self._icon_bb:free()
        self._icon_bb = nil
    end
    if self._text_wg then
        self._text_wg:free()
    end
end









local GlimpseTabSwitcher = Widget:extend{
    segments = nil,
    active = 1,
    height = Screen:scaleBySize(42),
    radius = 0,
    active_radius = 0,
    stroke = Screen:scaleBySize(2),
    pad = Screen:scaleBySize(5),
    seg_pad = Screen:scaleBySize(12),
    label_gap = Screen:scaleBySize(6),


    badge_h = Screen:scaleBySize(17),
    badge_min_w = Screen:scaleBySize(17),
    badge_pad = Screen:scaleBySize(3),
    badge_radius = 0,
    badge_stroke = math.max(1, Screen:scaleBySize(1)),
    border_active = 0x56,
    border_inactive = 0x89,
}

function GlimpseTabSwitcher:init()
    local face = chromeFace(15)
    local cface = chromeFace(12)
    self._lbl, self._cnt, self._badge_w = {}, {}, {}
    local seg_content = 0
    for i, seg in ipairs(self.segments) do
        local fg = (i == self.active) and Blitbuffer.COLOR_WHITE
            or Blitbuffer.COLOR_BLACK
        self._lbl[i] = TextWidget:new{
            text = U(seg.label), face = face, bold = true, fgcolor = fg }
        self._cnt[i] = TextWidget:new{
            text = tostring(seg.count), face = cface, bold = true, fgcolor = fg }
        local bw = math.max(self.badge_min_w,
            self._cnt[i]:getSize().w + 2 * self.badge_pad)
        self._badge_w[i] = bw
        local cw = self._lbl[i]:getSize().w + self.label_gap + bw
        if cw > seg_content then seg_content = cw end
    end
    self._seg_w = seg_content + 2 * self.seg_pad
    self._w = 2 * self._seg_w + 2 * self.pad
    self._nat_w = self._w
    self._seg_dimens = {}
end





function GlimpseTabSwitcher:setWidth(w)
    w = math.max(w or 0, self._nat_w)
    self._seg_w = math.floor((w - 2 * self.pad) / 2)
    self._w = 2 * self._seg_w + 2 * self.pad
end

function GlimpseTabSwitcher:getSize()
    return Geom:new{ w = self._w, h = self.height }
end

function GlimpseTabSwitcher:paintTo(bb, x, y)
    local w, h = self._w, self.height
    self.dimen = Geom:new{ x = x, y = y, w = w, h = h }

    paint_drop_shadow(bb, x, y, w, h, self.radius,
        Screen:scaleBySize(2), Screen:scaleBySize(2), 0.3, 0.5)
    if not self._wrap_bb then
        self._wrap_bb = make_rounded_stencil(w, h, self.radius,
            self.stroke, 0xFF, 0x00)
    end
    bb:alphablitFrom(self._wrap_bb, x, y, 0, 0, w, h)

    local seg_h = h - 2 * self.pad
    if not self._active_bb then
        self._active_bb = make_rounded_stencil(self._seg_w, seg_h,
            self.active_radius, self.stroke, 0x00, 0x00)
    end
    bb:alphablitFrom(self._active_bb,
        x + self.pad + (self.active - 1) * self._seg_w, y + self.pad,
        0, 0, self._seg_w, seg_h)

    self._badge_bb = self._badge_bb or {}
    for i = 1, #self.segments do
        local seg_x = x + self.pad + (i - 1) * self._seg_w
        self._seg_dimens[i] = Geom:new{ x = seg_x, y = y, w = self._seg_w, h = h }
        local lbl, cnt = self._lbl[i], self._cnt[i]
        local lsz, csz = lbl:getSize(), cnt:getSize()
        local bw = self._badge_w[i]
        local cx = seg_x + math.floor(
            (self._seg_w - (lsz.w + self.label_gap + bw)) / 2)
        lbl:paintTo(bb, cx, y + math.floor((h - lsz.h) / 2))
        local bx = cx + lsz.w + self.label_gap
        local by = y + math.floor((h - self.badge_h) / 2)
        if not self._badge_bb[i] then
            local col = (i == self.active) and self.border_active
                or self.border_inactive
            self._badge_bb[i] = make_rounded_stencil(bw, self.badge_h,
                self.badge_radius, self.badge_stroke, nil, col)
        end
        bb:alphablitFrom(self._badge_bb[i], bx, by, 0, 0, bw, self.badge_h)
        cnt:paintTo(bb, bx + math.floor((bw - csz.w) / 2),
            by + math.floor((self.badge_h - csz.h) / 2))
    end
end

function GlimpseTabSwitcher:hitSegment(pos)
    for i, d in ipairs(self._seg_dimens or {}) do
        if d and pos:intersectWith(d) then return i end
    end
end

function GlimpseTabSwitcher:free()
    if self._wrap_bb then self._wrap_bb:free(); self._wrap_bb = nil end
    if self._active_bb then self._active_bb:free(); self._active_bb = nil end
    if self._badge_bb then
        for _, b in pairs(self._badge_bb) do if b then b:free() end end
        self._badge_bb = nil
    end
    for _, t in ipairs(self._lbl or {}) do t:free() end
    for _, t in ipairs(self._cnt or {}) do t:free() end
end







local GlimpseMenuRow = Widget:extend{
    text = "",
    icon_bb = nil,
    lead_wg = nil,
    width = 0,
    height = Screen:scaleBySize(44),
    icon_col = 0,
    icon_size = Screen:scaleBySize(18),
    pad_left = Screen:scaleBySize(16),






    dimmed = false,
}

function GlimpseMenuRow:init()
    self._text_wg = TextWidget:new{
        text = U(self.text),
        face = chromeFace(15),
        bold = true,
        fgcolor = self.dimmed and Blitbuffer.COLOR_GRAY
            or Blitbuffer.COLOR_BLACK,
    }
end

function GlimpseMenuRow:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function GlimpseMenuRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }

    if self.icon_bb then
        bb:alphablitFrom(self.icon_bb,
            x + self.pad_left + math.floor((self.icon_size - self.icon_bb:getWidth()) / 2),
            y + math.floor((self.height - self.icon_bb:getHeight()) / 2),
            0, 0, self.icon_bb:getWidth(), self.icon_bb:getHeight())
    elseif self.lead_wg then
        local lsz = self.lead_wg:getSize()
        self.lead_wg:paintTo(bb,
            x + self.pad_left + math.floor((self.icon_size - lsz.w) / 2),
            y + math.floor((self.height - lsz.h) / 2))
    end
    local tsz = self._text_wg:getSize()
    self._text_wg:paintTo(bb,
        x + self.pad_left + self.icon_col,
        y + math.floor((self.height - tsz.h) / 2))
end

function GlimpseMenuRow:free()
    if self._text_wg then self._text_wg:free() end
    if self.lead_wg then self.lead_wg:free() end
end








local GlimpseCard = WidgetContainer:extend{
    radius = 0,
    stroke = Screen:scaleBySize(2),
    outline = 0x00,


    shadow_blur = Screen:scaleBySize(4),
    shadow_dy = Screen:scaleBySize(3),
}

function GlimpseCard:getSize()
    return self[1]:getSize()
end

function GlimpseCard:paintTo(bb, x, y)
    local sz = self[1]:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    if not self._fill_bb or self._bg_w ~= sz.w or self._bg_h ~= sz.h then
        if self._fill_bb then self._fill_bb:free() end
        if self._ring_bb then self._ring_bb:free() end
        self._bg_w, self._bg_h = sz.w, sz.h

        self._fill_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, 0xFF, 0xFF)

        self._ring_bb = make_rounded_stencil(sz.w, sz.h,
            self.radius, self.stroke, nil, self.outline)
    end




    paint_drop_shadow(bb, x, y, sz.w, sz.h, self.radius,
        self.shadow_blur, self.shadow_dy, 0.3, 0.5, true)
    bb:alphablitFrom(self._fill_bb, x, y, 0, 0, sz.w, sz.h)
    self[1]:paintTo(bb, x, y)
    bb:alphablitFrom(self._ring_bb, x, y, 0, 0, sz.w, sz.h)
end

function GlimpseCard:free(full)
    if self._fill_bb then self._fill_bb:free(); self._fill_bb = nil end
    if self._ring_bb then self._ring_bb:free(); self._ring_bb = nil end
    WidgetContainer.free(self, full)
end





local _menu_icon_cache = {}
local function menu_icon(path, size, dimmed)
    local key = path .. ":" .. size .. (dimmed and ":dim" or "")
    local ibb = _menu_icon_cache[key]
    if ibb == nil then
        local ok, r = pcall(RenderImage.renderSVGImageFile, RenderImage,
            path, size, size)
        ibb = (ok and r) or false
        if ibb and dimmed then



            local gray = Blitbuffer.COLOR_GRAY:getColorRGB32()
            for yy = 0, ibb:getHeight() - 1 do
                for xx = 0, ibb:getWidth() - 1 do
                    local c = ibb:getPixel(xx, yy):getColorRGB32()
                    if c.alpha > 0 then
                        ibb:setPixel(xx, yy, Blitbuffer.ColorRGB32(
                            gray.r, gray.g, gray.b, c.alpha))
                    end
                end
            end
        end
        _menu_icon_cache[key] = ibb
    end
    return ibb or nil
end






local GlimpsePopupMenu = InputContainer:extend{
    items = nil,
    footer_item = nil,


    footer_gap = Screen:scaleBySize(8),
    anchor = nil,
    pad_left = Screen:scaleBySize(16),
    pad_right = Screen:scaleBySize(16),
    icon_size = Screen:scaleBySize(18),
    icon_gap = Screen:scaleBySize(12),
    row_h = Screen:scaleBySize(44),
}

function GlimpsePopupMenu:init()


    local all_items = {}
    for _, it in ipairs(self.items) do all_items[#all_items + 1] = it end
    if self.footer_item then all_items[#all_items + 1] = self.footer_item end
    local any_lead = false
    for _, it in ipairs(all_items) do
        if it.icon or it.check ~= nil then any_lead = true break end
    end
    local icon_col = any_lead and (self.icon_size + self.icon_gap) or 0


    local max_text_w = 0
    local probes = {}
    for i, it in ipairs(all_items) do
        local wg = TextWidget:new{
            text = U(it.text), face = chromeFace(15), bold = true,
        }
        probes[i] = wg
        max_text_w = math.max(max_text_w, wg:getSize().w)
    end
    for _, wg in ipairs(probes) do wg:free() end
    local row_w = self.pad_left + icon_col + max_text_w + self.pad_right

    self._rows = {}


    local function build_card(list)
        local vg = VerticalGroup:new{ align = "left" }
        for i, it in ipairs(list) do
            local icon_bb, lead_wg
            if it.icon then

                icon_bb = menu_icon(it.icon, self.icon_size, it.dimmed)
            elseif it.check ~= nil then


                lead_wg = TextWidget:new{
                    text = it.check and "☑" or "☐",
                    face = Font:getFace("cfont", 22),
                    fgcolor = it.dimmed and Blitbuffer.COLOR_GRAY
                        or Blitbuffer.COLOR_BLACK,
                }
            end
            local row = GlimpseMenuRow:new{
                text = it.text, icon_bb = icon_bb, lead_wg = lead_wg,
                width = row_w, height = self.row_h, icon_col = icon_col,
                icon_size = self.icon_size, pad_left = self.pad_left,
                dimmed = it.dimmed,
            }
            row._dimmed = it.dimmed
            row._callback = it.callback

            row._dimmed_cb = it.dimmed_callback


            row._check_get = it.check_get
            row._lead_wg = lead_wg
            self._rows[#self._rows + 1] = row
            table.insert(vg, row)
            if i < #list then
                table.insert(vg, LineWidget:new{
                    background = Blitbuffer.COLOR_GRAY,
                    dimen = Geom:new{ w = row_w, h = Screen:scaleBySize(1) },
                })
            end
        end
        return GlimpseCard:new{ vg }
    end

    local content
    if self.footer_item then


        content = VerticalGroup:new{ align = "left",
            build_card(self.items),
            VerticalSpan:new{ width = self.footer_gap },
            build_card({ self.footer_item }),
        }
    else
        content = build_card(self.items)
    end

    self.movable = MovableContainer:new{
        anchor = self.anchor,
        content,
    }
    self[1] = CenterContainer:new{
        dimen = Screen:getSize(),
        self.movable,
    }
    if Device:isTouchDevice() then
        self.ges_events.Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight() },
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
end







GlimpsePopupMenu.shadow_pad = GlimpseCard.shadow_blur + GlimpseCard.shadow_dy

function GlimpsePopupMenu:refreshRegion()
    local d = self.movable and self.movable.dimen
    if not d then return nil end
    local p = self.shadow_pad
    return Geom:new{ x = d.x - p, y = d.y - p, w = d.w + 2 * p, h = d.h + 2 * p }
end

function GlimpsePopupMenu:dismiss()
    local region = self:refreshRegion()


    local restore = self._restore_region
    if type(restore) == "function" then restore = restore() end
    if region and restore then
        region = region:combine(restore)
    end
    UIManager:close(self, "ui", region)
end

function GlimpsePopupMenu:onTap(_, ges)
    for _, row in ipairs(self._rows) do
        if row.dimen and ges.pos:intersectWith(row.dimen) then



            if row._dimmed then
                if row._dimmed_cb then row._dimmed_cb() end
                return true
            end
            if row._check_get then





                if row._callback then row._callback() end
                if row._lead_wg and row._lead_wg.setText then
                    row._lead_wg:setText(row._check_get() and "☑" or "☐")
                end

                UIManager:setDirty(self, "ui", self:refreshRegion())
                return true
            end

            local cb = row._callback
            self:dismiss()
            if cb then cb() end
            return true
        end
    end

    self:dismiss()
    return true
end

function GlimpsePopupMenu:onClose()
    self:dismiss()
    return true
end




function GlimpsePopupMenu:onSetRotationMode(rotation)
    if self.on_rotate and rotation ~= nil
            and rotation ~= Screen:getRotationMode() then
        self:dismiss()
        self.on_rotate(rotation)
        return true
    end
end

function GlimpsePopupMenu:onCloseWidget()


    if self.on_dismiss then self.on_dismiss() end
end



















local GlimpseZoomImage = ImageWidget:extend{
    _crop_x = nil,
    _crop_y = nil,
    _src_bb = nil,
    _src_disposable = nil,
}








local ZOOM_GRID = 64

function GlimpseZoomImage:_render()
    if self._bb then return end
    local want = self.scale_factor
    local w, h = self.width, self.height
    local src = self._src_bb
    if not src then




        self.scale_factor = 1
        self.width, self.height = nil, nil
        ImageWidget._render(self)
        self.scale_factor, self.width, self.height = want, w, h
        src = self._bb
        self._src_bb, self._src_disposable = src, self._bb_disposable
    end
    self._initial_scale_factor = want

    local src_w, src_h = src:getWidth(), src:getHeight()


    local scale = want
    if scale == 0 then
        scale = math.min(w / src_w, h / src_h)
    elseif scale == nil then
        scale = 1
    end



    local p
    if src_w * scale > w or src_h * scale > h then
        p = math.max(1, math.floor(scale * ZOOM_GRID + 0.5))
        scale = p / ZOOM_GRID
    end
    self.scale_factor = scale
    local full_w = math.max(1, math.floor(src_w * scale))
    local full_h = math.max(1, math.floor(src_h * scale))


    self._bb_w, self._bb_h = full_w, full_h
    self._max_off_center_x_ratio = 0
    self._max_off_center_y_ratio = 0
    if full_w > w then self._max_off_center_x_ratio = 0.5 - w / 2 / full_w end
    if full_h > h then self._max_off_center_y_ratio = 0.5 - h / 2 / full_h end
    local function clamp(v, lim)
        if v < 0.5 - lim then return 0.5 - lim end
        if v > 0.5 + lim then return 0.5 + lim end
        return v
    end
    self.center_x_ratio = clamp(self.center_x_ratio,
        self._max_off_center_x_ratio)
    self.center_y_ratio = clamp(self.center_y_ratio,
        self._max_off_center_y_ratio)
    self._offset_x = math.floor(self.center_x_ratio * full_w - w / 2)
    self._offset_y = math.floor(self.center_y_ratio * full_h - h / 2)


    if not p then


        if scale ~= 1 then
            self._bb = RenderImage:scaleBlitBuffer(src, full_w, full_h, false)
            self._bb_disposable = true
        else
            self._bb = src
            self._bb_disposable = false
        end
        self._crop_x, self._crop_y = 0, 0
    else

        local vx0 = math.max(0, math.min(self._offset_x, full_w))
        local vy0 = math.max(0, math.min(self._offset_y, full_h))
        local vx1 = math.max(vx0, math.min(full_w, self._offset_x + w))
        local vy1 = math.max(vy0, math.min(full_h, self._offset_y + h))

        local function snap_lo(v)
            return ZOOM_GRID * math.floor(v / scale / ZOOM_GRID)
        end
        local function snap_hi(v, lim)
            local s = ZOOM_GRID * math.ceil(v / scale / ZOOM_GRID)
            return math.min(lim, s)
        end
        local sx0 = math.max(0, snap_lo(vx0))
        local sy0 = math.max(0, snap_lo(vy0))
        local sw = math.max(ZOOM_GRID, snap_hi(vx1, src_w) - sx0)
        local sh = math.max(ZOOM_GRID, snap_hi(vy1, src_h) - sy0)
        sw = math.min(sw, src_w - sx0)
        sh = math.min(sh, src_h - sy0)



        local sub = src:viewport(sx0, sy0, sw, sh)
        self._bb = RenderImage:scaleBlitBuffer(sub,
            math.max(1, math.floor(sw * scale)),
            math.max(1, math.floor(sh * scale)), false)
        self._bb_disposable = true

        self._crop_x = sx0 / ZOOM_GRID * p
        self._crop_y = sy0 / ZOOM_GRID * p
    end
end




function GlimpseZoomImage:_cropCovers()
    if not (self._bb and self._crop_x) then return false end
    local cw, ch = self._bb:getWidth(), self._bb:getHeight()
    local x0 = math.max(0, self._offset_x)
    local y0 = math.max(0, self._offset_y)
    local x1 = math.min(self._bb_w, self._offset_x + self.width)
    local y1 = math.min(self._bb_h, self._offset_y + self.height)
    return x0 >= self._crop_x and y0 >= self._crop_y
        and x1 <= self._crop_x + cw and y1 <= self._crop_y + ch
end




function GlimpseZoomImage:_dropRender()
    if self._bb and self._bb_disposable and self._bb.free then
        self._bb:free()
    end
    self._bb, self._bb_disposable = nil, nil
    self.scale_factor = self._initial_scale_factor or self.scale_factor
end

function GlimpseZoomImage:free()
    ImageWidget.free(self)
    if self._src_bb and self._src_disposable and self._src_bb.free then
        self._src_bb:free()
    end
    self._src_bb, self._src_disposable = nil, nil
    self._crop_x, self._crop_y = nil, nil
end

function GlimpseZoomImage:paintTo(bb, x, y)
    if self.hide then return end
    self:getSize()
    if not self:_cropCovers() then



        self:_dropRender()
        self:getSize()
    end


    local ox, oy = self._offset_x, self._offset_y
    self._offset_x = ox - self._crop_x
    self._offset_y = oy - self._crop_y
    ImageWidget.paintTo(self, bb, x, y)
    self._offset_x, self._offset_y = ox, oy
end





function GlimpseZoomImage:getScaleFactorExtrema()
    local minf = ImageWidget.getScaleFactorExtrema(self)
    return minf, math.huge
end
















local GlimpseViewer = ImageViewer:extend{
    image_metas = nil,
    gallery_hidden_count = 0,
    on_image_shown = nil,
    on_hide = nil,
    on_show_in_book = nil,
    on_rotate = nil,
    on_show_menu = nil,
    scope = nil,
    on_toggle_scope = nil,


    scope_locked = false,
    scope_lock_reason = nil,
    on_toggle_bookmarks = nil,
    on_choose_layout = nil,
    get_pref = nil,
    set_pref = nil,


    shown_metas = nil,
    shown_list = nil,
    ignored_metas = nil,
    ignored_list = nil,
    primary_tab = "shown",
    on_ignore = nil,
    on_unignore = nil,
    on_remove_bookmark = nil,


    gallery_cols = 3,



    with_title_bar = false,






    panel_ratio = 505 / 630,
    band_ratio = 0.5,
    panel_vgap = 0,
    panel_border = Screen:scaleBySize(2),
    panel_radius = 0,


    shadow_width = Screen:scaleBySize(131),
    shadow_overlap = Screen:scaleBySize(66),

    image_right_gap = Screen:scaleBySize(12),
    image_padding = Screen:scaleBySize(2),




    mini_ratio = 0.5,
    mini_radius = 0,





    mini_shadow = math.floor(Screen:scaleBySize(10) * 1.55 + 0.5),
    mini_shadow_bias = 0.13,



    mini_shadow_night = 1.6,
    mini_grip_inset = Screen:scaleBySize(6),
    mini_map_max_w = Screen:scaleBySize(61),



    alpha = 0.25,









    disable_double_tap = true,
}

function GlimpseViewer:init()
    self._cur_rotation = self:_prefFor(1).rotation or 0
    ImageViewer.init(self)
    self:_buildMoreButton()
    self:update()
end










function GlimpseViewer:onShow()
    return true
end

function GlimpseViewer:_prefFor(i)
    local meta = self.image_metas and self.image_metas[i]
    if meta and self.get_pref then
        return self.get_pref(meta) or {}
    end
    return {}
end













function GlimpseViewer:_resolveGeometry()








    self._place = _resolvePlacement()
    self._horizontal = self._place == "top" or self._place == "bottom"
    self._on_right = self._place == "right"
    self._inner = ({ left = "right", right = "left",
                     top = "bottom", bottom = "top" })[self._place]






    self._mini = _miniMode() and not self._gallery_mode
    if self._mini then
        self._horizontal = false
        self._on_right = false
    end

    if self._mini then
        local side = math.floor(
            math.min(Screen:getWidth(), Screen:getHeight()) * self.mini_ratio)
        self._panel_w, self._panel_h = side, side

        self.width = self._panel_w - 2 * self.panel_border
        self.height = self._panel_h - 2 * self.panel_border
    elseif self._horizontal then

        self._panel_w = Screen:getWidth()
        self._panel_h = math.floor(Screen:getHeight() * self.band_ratio)

        self.width = self._panel_w - 2 * self.panel_border
        self.height = self._panel_h - self.panel_border
    else
        self._panel_w = math.floor(Screen:getWidth() * self.panel_ratio)
        self._panel_h = Screen:getHeight() - 2 * self.panel_vgap




        self.width = self._panel_w - self.panel_border
        self.height = self._panel_h - 2 * self.panel_border
    end
end

function GlimpseViewer:update()




    if self._zooming and not self._gallery_mode
            and self._overlay and self._image_layer and self._image_layer.dimen then
        return self:_updateImageOnly()
    end
    self:_clean_image_wg()




    if self._more_frame and self._more_is_gallery == _any_quick_enabled() then
        self._more_frame:free()
        self:_buildMoreButton()
    end






    local orig_dimen = self.main_frame.dimen and self.main_frame.dimen:copy()

    self:_resolveGeometry()










    local mfd = self.main_frame.dimen
    if mfd and (mfd.w ~= self._panel_w or mfd.h ~= self._panel_h) then
        self.main_frame.dimen = nil
        self.dimen = nil
    end

    while table.remove(self.frame_elements) do end
    self.frame_elements:resetLayout()

    self.img_container_h = self.height
    if self._gallery_mode then
        self:_buildGallery()
    else
        self._gallery_cells = nil
        self:_new_image_wg()
    end
    self:_buildPill()





    local image_layer = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        self.image_container,
    }
    local overlay = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.height },
        image_layer,
    }




    self._overlay = overlay
    self._image_layer = image_layer





    local image_area_w = self._mini and self.width
        or (self.width - self.image_right_gap)





    local btn_inset = self._mini and 0
        or (self._place == "top" and self.panel_radius
            or Screen:scaleBySize(14))
    local btn_gap = self._mini and 0 or Screen:scaleBySize(10)




    local show_zc = (not self._gallery_mode)
        and G_reader_settings:isTrue(ZOOMCTL_KEY)





    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    self._nav_prev_frame, self._nav_next_frame = nil, nil


    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY) and not self._mini
        and self._images_list and (self._images_list_nb or 1) > 1
    local cur = self._images_list_cur or 1
    local nb = self._images_list_nb or 1
    if self._gallery_mode then




        nav = true
        cur = self._gallery_page or 1
        nb = self:_galleryPages()
    end
    if self._close_frame then
        self._close_frame:free()
        self._close_frame = nil
    end


    local loop = G_reader_settings:isTrue(NAV_LOOP_KEY) and nb > 1
    if nav then
        self._nav_prev_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/prev.svg",
            disabled = (not loop) and cur <= 1 or nil,
        }
        self._nav_prev_frame.overlap_offset = {
            Screen:scaleBySize(16),
            self.height - self._nav_prev_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_prev_frame)
        self._nav_next_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/next.svg",
            disabled = (not loop) and cur >= nb or nil,
        }
        self._nav_next_frame.overlap_offset = {
            image_area_w - self._nav_next_frame.size,
            self.height - self._nav_next_frame.size - btn_inset,
        }
        table.insert(overlay, self._nav_next_frame)
    end




    if self._gallery_mode then



        self._close_frame = GlimpseMoreButton:new{
            icon = _PLUGIN_DIR .. "/assets/back.svg",
        }
        local size = self._close_frame.size
        self._close_frame.overlap_offset = {
            self._nav_next_frame.overlap_offset[1],
            self._nav_next_frame.overlap_offset[2] - btn_gap - size,
        }
        table.insert(overlay, self._close_frame)
    elseif self._more_frame and self:_hasQuickActions() then
        local more_size = self._more_frame:getSize()
        local more_x, more_y
        if self._nav_next_frame then


            more_x = self._nav_next_frame.overlap_offset[1]
                - btn_gap - more_size.w
            more_y = self._nav_next_frame.overlap_offset[2]
        else

            more_x = image_area_w - more_size.w
            more_y = self.height - more_size.h - btn_inset
            if self._mini then





                more_x = more_x + self.panel_border
                more_y = more_y + self.panel_border
            end
        end




        self._more_frame.outline = self._mini or false
        self._more_frame.square_top = (self._mini and show_zc) or false
        self._more_frame.corners = self._mini
            and { tl = not show_zc, tr = false, bl = false, br = false } or nil

        self._more_frame.outline_sides = self._mini and
            { t = not show_zc, b = false, l = true, r = false } or nil
        self._more_frame.overlap_offset = { more_x, more_y }
        table.insert(overlay, self._more_frame)
    elseif self._more_frame then




        self._more_frame.overlap_offset = nil
        self._more_frame.dimen = nil
    end
    if self._pill_frame then











        local pill_is_button = self._gallery_mode
            or (self:_isOverFit() and not self._mini
                and not G_reader_settings:isTrue(ZOOMCTL_KEY))
        local bottom_inset
        if self._mini then



            bottom_inset = -self.panel_border
        elseif pill_is_button then
            bottom_inset = btn_inset
        else
            local pill_h = self._pill_frame:getSize().h
            bottom_inset = btn_inset
                + math.floor((GlimpseMoreButton.size - pill_h) / 2)
        end


        local left_bound = Screen:scaleBySize(16)
        if self._nav_prev_frame and self._nav_prev_frame.overlap_offset then
            left_bound = self._nav_prev_frame.overlap_offset[1]
                + self._nav_prev_frame.size
        end
        local right_bound = image_area_w
        for _, f in ipairs({ self._more_frame, self._close_frame,
                self._nav_next_frame }) do
            if f and f.overlap_offset then
                right_bound = math.min(right_bound, f.overlap_offset[1])
            end
        end



        if self._gallery_mode then
            local pill_left = self._nav_prev_frame
                and (left_bound + btn_gap) or left_bound



            if self._pill_frame.setWidth then


                local switcher_right = self._nav_next_frame.overlap_offset[1] - btn_gap
                self._pill_frame:setWidth(switcher_right - pill_left)
            end
            self._pill_frame.overlap_offset = {
                pill_left, self.height - self._pill_frame:getSize().h - bottom_inset,
            }
        else
            local pill_size = self._pill_frame:getSize()
            local pill_x =
                math.floor(left_bound + (right_bound - left_bound - pill_size.w) / 2)
            if self._mini then




                pill_x = math.floor((self.width - pill_size.w) / 2)
                pill_x = math.min(pill_x, right_bound - pill_size.w)
                pill_x = math.max(pill_x, 0)
            end
            self._pill_frame.overlap_offset = {
                pill_x,
                self.height - pill_size.h - bottom_inset,
            }
        end
        table.insert(overlay, self._pill_frame)
    end



    if self._zoomctl_frame and not show_zc then
        self._zoomctl_frame:free()
        self._zoomctl_frame = nil
    end


    if self._zoomctl_frame and self._zoomctl_frame.no_fit ~= (self._mini or false) then
        self._zoomctl_frame:free()
        self._zoomctl_frame = nil
    end
    if show_zc then
        if not self._zoomctl_frame then
            self._zoomctl_frame = GlimpseZoomControl:new{
                no_fit = self._mini or false,
                height = GlimpseMoreButton.size * (self._mini and 2 or 3),
            }
        end
        local zc = self._zoomctl_frame
        local over_fit = self:_isOverFit()
        zc.fit_disabled = not over_fit
        zc.minus_disabled = not over_fit
        zc.plus_disabled = self:_isAtMax()
        zc.inverted_zone = nil
        local zsz = zc:getSize()
        local anchor = self._nav_next_frame
            or (self._more_frame and self._more_frame.overlap_offset
                and self._more_frame)
        local zx, zy
        if anchor and anchor.overlap_offset then
            local asz = anchor:getSize()
            zx = anchor.overlap_offset[1] + (asz.w - zsz.w)
            zy = anchor.overlap_offset[2] - btn_gap - zsz.h
        else
            zx = image_area_w - zsz.w
            zy = self.height - zsz.h - btn_inset
            if self._mini then


                zx = zx + self.panel_border
                zy = zy + self.panel_border
            end
        end



        zc.outline = self._mini or false




        zc.square_right = self._mini or false
        zc.square_bottom = self._mini or false
        zc.merge_bottom = false
        if self._mini and self._more_frame and self._more_frame.overlap_offset then
            zy = zy + self.panel_border



            zc.merge_bottom = true
        end

        zc.outline_sides = self._mini and
            { t = true, b = false, l = true, r = false } or nil
        zc.overlap_offset = { zx, zy }
        table.insert(overlay, zc)
    end



    if self._bookmark_pill_wg then
        self._bookmark_pill_wg:free()
        self._bookmark_pill_wg = nil
    end
    local inset = Screen:scaleBySize(12)


    if not self._gallery_mode and not self._mini then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        if meta and meta.is_bookmark
                and G_reader_settings:nilOrTrue(BOOKMARK_LABEL_KEY) then
            local label
            if meta.chapter and meta.chapter ~= "" then
                label = T(_("Page %1 (%2)"), meta.page or "?", meta.chapter)
            else
                label = T(_("Page %1"), meta.page or "?")
            end
            self._bookmark_pill_wg = GlimpseBookmarkPill:new{
                text = label,
                icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                max_width = image_area_w - 2 * inset,
            }
            self._bookmark_pill_wg.overlap_offset = { inset, inset }
            table.insert(overlay, self._bookmark_pill_wg)
        end
    end



    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if G_reader_settings:nilOrTrue(CAPTIONS_KEY) and not self._gallery_mode
            and not self._mini then
        local meta = self.image_metas
            and self.image_metas[self._images_list_cur or 1]
        local caption = meta and meta.caption
        if caption and caption ~= "" then
            self._caption_wg = GlimpseCaption:new{
                text = caption,
                max_width = image_area_w - 2 * inset,
            }
            local cap_y = inset
            if self._bookmark_pill_wg then
                cap_y = inset + self._bookmark_pill_wg:getSize().h
                    + Screen:scaleBySize(6)
            end
            self._caption_wg.overlap_offset = { inset, cap_y }
            table.insert(overlay, self._caption_wg)
        end
    end







    if self._on_right then
        for _, wdg in ipairs(overlay) do
            local off = wdg.overlap_offset


            if off and wdg ~= self._bookmark_pill_wg then
                local ok, sz = pcall(wdg.getSize, wdg)
                local ww = (ok and sz and sz.w) or 0
                off[1] = self.width - off[1] - ww
            end
        end





        local pf, nf = self._nav_prev_frame, self._nav_next_frame
        if pf and pf.overlap_offset and nf and nf.overlap_offset then
            pf.overlap_offset, nf.overlap_offset = nf.overlap_offset, pf.overlap_offset
        end
    end








    if self._grip_frame then
        self._grip_frame:free()
        self._grip_frame = nil
    end
    if self._mini then
        self._grip_frame = GlimpseDragGrip:new{}
        local gs = self._grip_frame:getSize()
        self._grip_frame.overlap_offset = {
            self.width - gs.w - self.mini_grip_inset,
            self.mini_grip_inset,
        }
        table.insert(overlay, self._grip_frame)
    end
    self:_buildMiniMap()
    table.insert(self.frame_elements, overlay)
    self.frame_elements:resetLayout()







    self.main_frame.background = nil
    self.main_frame.radius = nil
    self.main_frame.bordersize = 0
    self.main_frame.padding = 0



    local b = self.panel_border
    if self._mini then

        self.main_frame.padding_left = b
        self.main_frame.padding_right = b
        self.main_frame.padding_top = b
        self.main_frame.padding_bottom = b
    elseif self._horizontal then
        self.main_frame.padding_left = b
        self.main_frame.padding_right = b
        self.main_frame.padding_top = self._place == "top" and 0 or b
        self.main_frame.padding_bottom = self._place == "bottom" and 0 or b
    else
        self.main_frame.padding_left = self._on_right and b or 0
        self.main_frame.padding_right = self._on_right and 0 or b
        self.main_frame.padding_top = self.panel_vgap + b
        self.main_frame.padding_bottom = self.panel_vgap + b
    end




    self[1].align = nil
    local SW, SH = Screen:getWidth(), Screen:getHeight()
    if self._mini then



        local rx, ry = _miniPos()
        local mx = math.floor((SW - self._panel_w) * rx + 0.5)
        local my = math.floor((SH - self._panel_h) * ry + 0.5)
        self._mini_x, self._mini_y = mx, my
        self[1].dimen = Geom:new{ x = mx, y = my,
            w = self._panel_w, h = self._panel_h }
    elseif self._place == "right" then
        self[1].dimen = Geom:new{ x = SW - self._panel_w, y = 0,
            w = self._panel_w, h = SH }
    elseif self._place == "top" then
        self[1].dimen = Geom:new{ x = 0, y = 0, w = SW, h = self._panel_h }
    elseif self._place == "bottom" then
        self[1].dimen = Geom:new{ x = 0, y = SH - self._panel_h,
            w = SW, h = self._panel_h }
    else
        self[1].dimen = Geom:new{ x = 0, y = 0, w = SW, h = SH }
    end
    if not self._panel_paint_hooked then
        self._panel_paint_hooked = true
        local orig_paintTo = self.main_frame.paintTo
        local viewer = self
        self.main_frame.paintTo = function(frame, bb, x, y)
            viewer:_paintPanel(bb, x, y)
            orig_paintTo(frame, bb, x, y)
            viewer:_paintMiniBorder(bb, x, y)
            viewer:_restoreCorners(bb, x, y)
        end
    end







    local wfm_mode = Device:hasKaleidoWfm() and "partial" or "ui"
    local fast = self._fast_refresh
    self._fast_refresh = nil












    local flash_switch = self._flash_switch
    self._flash_switch = nil



    if flash_switch and not fast
            and not G_reader_settings:nilOrTrue(FAST_SWITCH_KEY) then
        wfm_mode = "full"
    end
    self.dithered = not fast







    local switching = self._switching
    self._switching = nil
    if switching and not self._gallery_mode and not self._suppress_refresh
            and not self._full_band_refresh
            and self._overlay and self._image_layer
            and G_reader_settings:nilOrTrue(FAST_SWITCH_KEY) then
        self:_repaintOverlayFast(wfm_mode)
        return
    end
    if self._suppress_refresh then


        return
    end







    local full_band = self._full_band_refresh
    self._full_band_refresh = nil
    if full_band then






        UIManager:setDirty(self, function()
            if not self.main_frame.dimen then return end
            local d = self:_growForShadow(self.main_frame.dimen:combine(orig_dimen))
            return wfm_mode, d, not fast
        end)
        return
    end







    self._skip_shadow_paint = true
    local alpha = self.alpha


    self.alpha = false
    UIManager:setDirty(self, function()




        if not self.main_frame.dimen then return end
        return wfm_mode, self.main_frame.dimen:combine(orig_dimen), not fast
    end)
    self.alpha = alpha
end











function GlimpseViewer:_cornerRadius()
    return self._mini and self.mini_radius or self.panel_radius
end








function GlimpseViewer:_miniShadowReach()
    if Screen.night_mode then
        return math.floor(self.mini_shadow * self.mini_shadow_night + 0.5)
    end
    return self.mini_shadow
end

function GlimpseViewer:_miniShadowPad()
    return self:_miniShadowReach() + self:_miniShadowOffset()
end





function GlimpseViewer:_miniShadowOffset()
    return math.floor(self:_miniShadowReach() * self.mini_shadow_bias + 0.5)
end






function GlimpseViewer:_paintMiniCard(bb, x, y)
    local w, h = self._panel_w, self._panel_h



    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1
    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())
    local skey = tostring(night) .. tostring(render_inv) .. "mini"
    local shadow_disabled = G_reader_settings:isTrue(SHADOW_KEY)
    local s = self:_miniShadowReach()







    local soff = self:_miniShadowOffset()
    local pad = self:_miniShadowPad()
    local sw_, sh_ = w + 2 * pad, h + 2 * pad
    if not shadow_disabled and (not self._mini_shadow_bb
            or self._mini_shadow_bb:getWidth() ~= sw_
            or self._mini_shadow_bb:getHeight() ~= sh_
            or self._mini_shadow_key ~= skey) then
        if self._mini_shadow_bb then self._mini_shadow_bb:free() end
        self._mini_shadow_key = skey
        self._mini_shadow_bb = Blitbuffer.new(sw_, sh_, Blitbuffer.TYPE_BBRGB32)
        local sv = render_inv and 0x00 or (night and 0xFF or 0x00)
        local peak = night and 1.0 or 0.8






        local hw, hh = w / 2, h / 2
        local rr = math.min(self.mini_radius, hw, hh)







        -- the retro look: a hard shadow, offset down and right, in two rects
        local hard = math.min(HARD_PANEL_SHADOW, pad)
        local sc = Blitbuffer.ColorRGB32(sv, sv, sv, 255)
        self._mini_shadow_bb:paintRect(pad + w, pad + hard, hard, h, sc)
        self._mini_shadow_bb:paintRect(pad + hard, pad + h, w, hard, sc)
        self._mini_shadow_bb:setInverse(render_inv and 1 or 0)
    end
    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow and not shadow_disabled then
        bb:alphablitFrom(self._mini_shadow_bb, x - pad, y - pad, 0, 0, sw_, sh_)
    end




    local r = self:_cornerRadius()
    local geo = self:_cornerGeom(x, y)
    local n = #geo
    if self._under_corner_bbs and (self._under_corner_r ~= r
            or #self._under_corner_bbs ~= n) then
        for _, b in ipairs(self._under_corner_bbs) do b:free() end
        self._under_corner_bbs = nil
    end
    if not self._under_corner_bbs then
        self._under_corner_bbs = {}
        for k = 1, n do
            self._under_corner_bbs[k] = Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32)
        end
        self._under_corner_r = r
    end
    local ucb = self._under_corner_bbs
    for k = 1, n do
        if skip_shadow then
            bb:blitFrom(ucb[k], geo[k][1], geo[k][2], 0, 0, r, r)
        else
            ucb[k]:setInverse(render_inv and 1 or 0)
            ucb[k]:blitFrom(bb, 0, 0, geo[k][1], geo[k][2], r, r)
        end
    end


    if not self._mini_card_bb or self._mini_card_bb:getWidth() ~= w
            or self._mini_card_bb:getHeight() ~= h
            or self._mini_card_key ~= skey then
        if self._mini_card_bb then self._mini_card_bb:free() end
        self._mini_card_key = skey
        self._mini_card_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
        local body = render_inv and 0x00 or 0xFF
        local edge = render_inv and 0xFF or 0x00
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        local bw = self.panel_border
        self._mini_card_bb:paintRectRGB32(0, 0, w, h, c_body)
        self._mini_card_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        self._mini_card_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        self._mini_card_bb:paintRectRGB32(0, 0, bw, h, c_edge)
        self._mini_card_bb:paintRectRGB32(w - bw, 0, bw, h, c_edge)
        local corners = {
            { cx = r,     cy = r,     xd = -1, yd = -1 },
            { cx = w - r, cy = r,     xd = 1,  yd = -1 },
            { cx = r,     cy = h - r, xd = -1, yd = 1  },
            { cx = w - r, cy = h - r, xd = 1,  yd = 1  },
        }
        for _, c in ipairs(corners) do
            local sq_x = c.xd > 0 and c.cx or (c.cx - r)
            local sq_y = c.yd > 0 and c.cy or (c.cy - r)
            for px2 = sq_x, sq_x + r - 1 do
                for py2 = sq_y, sq_y + r - 1 do
                    local fx, fy = px2 + 0.5, py2 + 0.5
                    local d = math.sqrt((fx - c.cx) ^ 2 + (fy - c.cy) ^ 2)
                    local cov = math.min(math.max(r - d + 0.5, 0), 1)
                    local t_in = math.min(math.max((r - bw) - d + 0.5, 0), 1)
                    local g = math.floor(edge + t_in * (body - edge) + 0.5)
                    self._mini_card_bb:setPixel(px2, py2,
                        Blitbuffer.ColorRGB32(g, g, g,
                            math.floor(cov * 255 + 0.5)))
                end
            end
        end
        self._mini_card_bb:setInverse(render_inv and 1 or 0)
    end
    bb:alphablitFrom(self._mini_card_bb, x, y, 0, 0, w, h)
    self:_saveCorners(bb, x, y)
end







function GlimpseViewer:_paintMiniBorder(bb, x, y)
    if not self._mini then return end
    local w, h = self._panel_w, self._panel_h
    local r = self:_cornerRadius()
    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1
    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())
    local edge = render_inv and 0xFF or 0x00
    local bw = self.panel_border


    local mid_w, mid_h = w - 2 * r, h - 2 * r








    local key = table.concat({ mid_w, mid_h, bw, edge,
        render_inv and 1 or 0 }, ":")
    if self._mini_edge_key ~= key then
        for _, k in ipairs({ "_mini_edge_h", "_mini_edge_v" }) do
            if self[k] then self[k]:free(); self[k] = nil end
        end
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)
        if mid_w > 0 and bw > 0 then
            local b = Blitbuffer.new(mid_w, bw, Blitbuffer.TYPE_BBRGB32)
            b:paintRectRGB32(0, 0, mid_w, bw, c_edge)
            b:setInverse(render_inv and 1 or 0)
            self._mini_edge_h = b
        end
        if mid_h > 0 and bw > 0 then
            local b = Blitbuffer.new(bw, mid_h, Blitbuffer.TYPE_BBRGB32)
            b:paintRectRGB32(0, 0, bw, mid_h, c_edge)
            b:setInverse(render_inv and 1 or 0)
            self._mini_edge_v = b
        end
        self._mini_edge_key = key
    end
    local eh, ev = self._mini_edge_h, self._mini_edge_v
    if eh then
        bb:blitFrom(eh, x + r, y, 0, 0, mid_w, bw)
        bb:blitFrom(eh, x + r, y + h - bw, 0, 0, mid_w, bw)
    end
    if ev then
        bb:blitFrom(ev, x, y + r, 0, 0, bw, mid_h)
        bb:blitFrom(ev, x + w - bw, y + r, 0, 0, bw, mid_h)
    end
end

function GlimpseViewer:_paintPanel(bb, x, y)
    if self._mini then return self:_paintMiniCard(bb, x, y) end
    local w, h = self._panel_w, self._panel_h
    local py = y + self.panel_vgap


    local on_right = self._on_right













    local night = Screen.night_mode
    local inv = bb.getInverse and bb:getInverse() == 1








    local render_inv = inv
        and not (night and Device.isAndroid and Device:isAndroid())


    local skey = tostring(night) .. tostring(render_inv) .. self._place


    local shadow_disabled = G_reader_settings:isTrue(SHADOW_KEY)






    local shadow_h = h + 2 * self.panel_vgap


    local sv = render_inv and 0x00 or (night and 0xFF or 0x00)
    local speak = night and 1.0 or 0.5



    local swidth = night and math.floor(self.shadow_width * 1.5 + 0.5) or self.shadow_width





    local mirror_far = self._on_right or self._place == "bottom"
    local free_len = self._horizontal and w or shadow_h
    local exp_bw = self._horizontal and free_len or swidth
    local exp_bh = self._horizontal and swidth or free_len
    if not shadow_disabled and (not self._shadow_bb
            or self._shadow_bb:getWidth() ~= exp_bw
            or self._shadow_bb:getHeight() ~= exp_bh
            or self._shadow_night ~= skey) then
        if self._shadow_bb then self._shadow_bb:free() end
        self._shadow_night = skey
        self._shadow_bb = Blitbuffer.new(exp_bw, exp_bh,
            Blitbuffer.TYPE_BBRGB32)
        local function origFrac(tt)
            if night then




                return tt < 0.5 and (1 - 0.8 * tt)
                    or 0.6 * (1 - (tt - 0.5) * 2) ^ 2
            else
                return 1 - tt
            end
        end

















        -- the retro look: a solid band just past the panel's edge, painted
        -- in one rect (no per-pixel dithering)
        local band = math.min(swidth, self.shadow_overlap + HARD_PANEL_SHADOW)
        local sc = Blitbuffer.ColorRGB32(sv, sv, sv, 255)
        if self._horizontal then
            local y0 = mirror_far and (swidth - band) or 0
            self._shadow_bb:paintRect(0, y0, free_len, band, sc)
        else
            local x0 = mirror_far and (swidth - band) or 0
            self._shadow_bb:paintRect(x0, 0, band, free_len, sc)
        end
        self._shadow_bb:setInverse(render_inv and 1 or 0)
    end


    local skip_shadow = self._skip_shadow_paint
    self._skip_shadow_paint = nil
    if not skip_shadow and not shadow_disabled then






        local ov = self.shadow_overlap
        if self._horizontal then
            local sy = (self._place == "top") and (y + h - ov)
                or (y + ov - swidth)
            bb:alphablitFrom(self._shadow_bb, x, sy, 0, 0, w, swidth)
        else
            local sx = on_right and (x + ov - swidth) or (x + w - ov)
            bb:alphablitFrom(self._shadow_bb, sx, y, 0, 0, swidth, shadow_h)
        end
    end








    local cr = self.panel_radius
    local cpy = y + self.panel_vgap


    if self._under_corner_bbs and (self._under_corner_r ~= cr
            or #self._under_corner_bbs ~= 2) then
        for _, b in ipairs(self._under_corner_bbs) do b:free() end
        self._under_corner_bbs = nil
    end
    if not self._under_corner_bbs then
        self._under_corner_bbs = {
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
            Blitbuffer.new(cr, cr, Blitbuffer.TYPE_BBRGB32),
        }
        self._under_corner_r = cr
    end
    local ucb = self._under_corner_bbs

    local ugeo = self:_cornerGeom(x, cpy)
    if skip_shadow then
        bb:blitFrom(ucb[1], ugeo[1][1], ugeo[1][2], 0, 0, cr, cr)
        bb:blitFrom(ucb[2], ugeo[2][1], ugeo[2][2], 0, 0, cr, cr)
    else

        ucb[1]:setInverse(render_inv and 1 or 0)
        ucb[2]:setInverse(render_inv and 1 or 0)
        ucb[1]:blitFrom(bb, 0, 0, ugeo[1][1], ugeo[1][2], cr, cr)
        ucb[2]:blitFrom(bb, 0, 0, ugeo[2][1], ugeo[2][2], cr, cr)
    end

    if not self._panel_bb or self._panel_bb:getWidth() ~= w
            or self._panel_bb:getHeight() ~= h or self._panel_night ~= skey then
        if self._panel_bb then
            self._panel_bb:free()
        end
        self._panel_night = skey
        self._panel_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)






        local body = render_inv and 0x00 or 0xFF
        local edge = render_inv and 0xFF or 0x00
        local c_body = Blitbuffer.ColorRGB32(body, body, body, 0xFF)
        local c_edge = Blitbuffer.ColorRGB32(edge, edge, edge, 0xFF)



        local bw = night and math.max(2, Screen:scaleBySize(1))
            or self.panel_border
        local r = self.panel_radius


        self._panel_bb:paintRectRGB32(0, 0, w, h, c_body)
        if self._place ~= "top" then
            self._panel_bb:paintRectRGB32(0, 0, w, bw, c_edge)
        end
        if self._place ~= "bottom" then
            self._panel_bb:paintRectRGB32(0, h - bw, w, bw, c_edge)
        end
        if self._place ~= "right" then
            self._panel_bb:paintRectRGB32(w - bw, 0, bw, h, c_edge)
        end
        if self._place ~= "left" then
            self._panel_bb:paintRectRGB32(0, 0, bw, h, c_edge)
        end





        local corners
        if self._place == "left" then
            corners = { {cx=w-r, cy=r, xd=1, yd=-1}, {cx=w-r, cy=h-r, xd=1, yd=1} }
        elseif self._place == "right" then
            corners = { {cx=r, cy=r, xd=-1, yd=-1}, {cx=r, cy=h-r, xd=-1, yd=1} }
        elseif self._place == "top" then
            corners = { {cx=r, cy=h-r, xd=-1, yd=1}, {cx=w-r, cy=h-r, xd=1, yd=1} }
        else
            corners = { {cx=r, cy=r, xd=-1, yd=-1}, {cx=w-r, cy=r, xd=1, yd=-1} }
        end
        for _, c in ipairs(corners) do
            local sq_x = c.xd > 0 and c.cx or (c.cx - r)
            local sq_y = c.yd > 0 and c.cy or (c.cy - r)
            for px = sq_x, sq_x + r - 1 do
                for pyy = sq_y, sq_y + r - 1 do
                    local fx, fy = px + 0.5, pyy + 0.5
                    local d = math.sqrt((fx - c.cx) ^ 2 + (fy - c.cy) ^ 2)
                    local cov = math.min(math.max(r - d + 0.5, 0), 1)
                    local t_in = math.min(math.max((r - bw) - d + 0.5, 0), 1)
                    local g = math.floor(edge + t_in * (body - edge) + 0.5)
                    self._panel_bb:setPixel(px, pyy,
                        Blitbuffer.ColorRGB32(g, g, g, math.floor(cov * 255 + 0.5)))
                end
            end
        end
        self._panel_bb:setInverse(render_inv and 1 or 0)
    end
    bb:alphablitFrom(self._panel_bb, x, py, 0, 0, w, h)
    self:_saveCorners(bb, x, py)
end






function GlimpseViewer:_cornerGeom(x, py)
    local w, h, r = self._panel_w, self._panel_h, self:_cornerRadius()
    if self._mini then


        return {
            { x,         py,         r, r },
            { x + w - r, py,         0, r },
            { x,         py + h - r, r, 0 },
            { x + w - r, py + h - r, 0, 0 },
        }
    end
    if self._horizontal then


        local oy = (self._place == "top") and (py + h - r) or py
        local ccy = (self._place == "top") and 0 or r
        return {
            { x, oy, r, ccy },
            { x + w - r, oy, 0, ccy },
        }
    else


        local ox = self._on_right and x or (x + w - r)
        local ccx = self._on_right and r or 0
        return {
            { ox, py, ccx, r },
            { ox, py + h - r, ccx, 0 },
        }
    end
end









function GlimpseViewer:_saveCorners(bb, x, py)
    local r, bw = self:_cornerRadius(), self.panel_border
    local geo = self:_cornerGeom(x, py)
    local n = #geo

    if self._corner_bbs and (self._corner_r ~= r or #self._corner_bbs ~= n) then
        for _, b in ipairs(self._corner_bbs) do b:free() end
        self._corner_bbs = nil
    end
    if not self._corner_bbs then
        self._corner_bbs = {}
        for k = 1, n do
            self._corner_bbs[k] = Blitbuffer.new(r, r, Blitbuffer.TYPE_BBRGB32)
        end
        self._corner_r = r
    end







    local ring = self.image_padding
    local keep_r = r - bw - ring
    for k = 1, n do
        local g = geo[k]
        local cbb = self._corner_bbs[k]
        if self._mini then
            keep_r = (k <= 2) and (r - bw - ring) or (r - bw)
        end
        cbb:blitFrom(bb, 0, 0, g[1], g[2], r, r)
        local ccx, ccy = g[3], g[4]
        for pyy = 0, r - 1 do
            for pxx = 0, r - 1 do
                local d = math.sqrt((pxx + 0.5 - ccx) ^ 2 + (pyy + 0.5 - ccy) ^ 2)
                local t_in = math.min(math.max(keep_r - d + 0.5, 0), 1)
                if t_in > 0 then
                    local c = cbb:getPixel(pxx, pyy):getColorRGB32()
                    cbb:setPixel(pxx, pyy, Blitbuffer.ColorRGB32(
                        c.r, c.g, c.b, math.floor((1 - t_in) * 255 + 0.5)))
                end
            end
        end
    end
end

function GlimpseViewer:_restoreCorners(bb, x, y)
    if not self._corner_bbs then return end
    local r = self:_cornerRadius()


    if self._corner_r ~= r then return end
    local py = y + (self._mini and 0 or self.panel_vgap)
    local geo = self:_cornerGeom(x, py)
    for k = 1, math.min(#geo, #self._corner_bbs) do
        bb:alphablitFrom(self._corner_bbs[k], geo[k][1], geo[k][2], 0, 0, r, r)
    end
end





function GlimpseViewer:_growForShadow(d)
    if G_reader_settings:isTrue(SHADOW_KEY) then return d end
    if self._mini then

        local s = self:_miniShadowPad()
        local nx = math.max(0, d.x - s)
        local ny = math.max(0, d.y - s)
        d.w = math.min(Screen:getWidth() - nx, d.w + (d.x - nx) + s)
        d.h = math.min(Screen:getHeight() - ny, d.h + (d.y - ny) + s)
        d.x, d.y = nx, ny
        return d
    end
    local extra = 2 * self.shadow_width - self.shadow_overlap + 1
    if self._place == "right" then
        local nx = math.max(0, d.x - extra)
        d.w = d.w + (d.x - nx); d.x = nx
    elseif self._place == "top" then
        d.h = math.min(Screen:getHeight() - d.y, d.h + extra)
    elseif self._place == "bottom" then
        local ny = math.max(0, d.y - extra)
        d.h = d.h + (d.y - ny); d.y = ny
    else
        d.w = math.min(Screen:getWidth() - d.x, d.w + extra)
    end
    return d
end





function GlimpseViewer:onSetRotationMode(rotation)
    if rotation ~= nil and rotation ~= Screen:getRotationMode() then
        UIManager:close(self)
        if self.on_rotate then
            self.on_rotate(rotation)
        end
    end
    return true
end

function GlimpseViewer:onCloseWidget()
    if self._shadow_bb then
        self._shadow_bb:free()
        self._shadow_bb = nil
    end
    if self._panel_bb then
        self._panel_bb:free()
        self._panel_bb = nil
    end
    if self._corner_bbs then
        self._corner_bbs[1]:free()
        self._corner_bbs[2]:free()
        self._corner_bbs = nil
    end
    if self._under_corner_bbs then
        self._under_corner_bbs[1]:free()
        self._under_corner_bbs[2]:free()
        self._under_corner_bbs = nil
    end
    if self._more_frame then
        self._more_frame:free()
    end
    if self._nav_prev_frame then self._nav_prev_frame:free() end
    if self._nav_next_frame then self._nav_next_frame:free() end
    if self._close_frame then self._close_frame:free() end
    if self._zoomctl_frame then self._zoomctl_frame:free() end
    if self._minimap_frame then self._minimap_frame:free() end
    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
        self._gallery_head_wgs = nil
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
        self._gallery_badges = nil
    end
    if self._caption_wg then
        self._caption_wg:free()
        self._caption_wg = nil
    end
    if self._bookmark_pill_wg then
        self._bookmark_pill_wg:free()
        self._bookmark_pill_wg = nil
    end
    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end
    self:_resetHiRes()















    ImageViewer.onCloseWidget(self)
    table.remove(UIManager._refresh_func_stack)












    UIManager:setDirty(nil, function()


        if not self.main_frame.dimen then return end



        local d = self:_growForShadow(self.main_frame.dimen:copy())






        return "full", d, true
    end)




    if self._reader_refresh_count ~= nil then
        local saved = self._reader_refresh_count
        self._reader_refresh_count = nil
        UIManager:nextTick(function() UIManager.refresh_count = saved end)
    end
end



function GlimpseViewer:_new_image_wg()


    local avail_w = self.width
    local max_image_h = self.img_container_h - self.image_padding * 2
    local max_image_w = avail_w - self.image_padding * 2






    local wg_scale = self.scale_factor
    local src = self.image
    if wg_scale == 0 then
        local fit = self:_computeFitScaleFactor()
        if fit and fit >= 1 then
            wg_scale = fit
        end
    elseif wg_scale > 1 then








        local hi = self:_getHiRes()
        if hi then
            local r = hi:getWidth() / self.image:getWidth()
            if r > 1 then
                src = hi
                wg_scale = wg_scale / r
            end
        end
    end
    self._image_wg = GlimpseZoomImage:new{
        image = src,
        image_disposable = false,
        alpha = true,
        width = max_image_w,
        height = max_image_h,
        rotation_angle = self._cur_rotation or 0,
        scale_factor = wg_scale,
        center_x_ratio = self._center_x_ratio,
        center_y_ratio = self._center_y_ratio,













        original_in_nightmode = false,
    }
    self.image_container = CenterContainer:new{
        dimen = Geom:new{ w = avail_w, h = self.img_container_h },
        self._image_wg,
    }
end









function GlimpseViewer:_updateImageOnly()
    if not (self._image_layer and self._image_layer.dimen and self._overlay) then
        self._zooming = nil
        return self:update()
    end





    if self:_isOverFit() ~= self._chrome_over_fit then
        self._zooming = nil
        return self:update()
    end
    self:_clean_image_wg()
    self:_new_image_wg()


    self._image_layer[1] = self.image_container
    local zc = self._zoomctl_frame
    if zc then
        local over_fit = self:_isOverFit()
        zc.fit_disabled = not over_fit
        zc.minus_disabled = not over_fit
        zc.plus_disabled = self:_isAtMax()
        zc.inverted_zone = nil
    end


    self:_buildMiniMap()
    self:_repaintOverlayFast("ui")
end






function GlimpseViewer:_getHiRes()
    if not self.hires_decode then return nil end
    if self._hi_bb == false then return nil end
    if self._hi_bb then return self._hi_bb end
    local hi = self.hires_decode(self._images_list_cur or 1)
    if not hi then self._hi_bb = false; return nil end

    if self.image and hi:getWidth() <= self.image:getWidth() * 1.05 then
        if hi.free then hi:free() end
        self._hi_bb = false
        return nil
    end
    self._hi_bb = hi
    return hi
end




function GlimpseViewer:_resetHiRes()
    if self._hi_bb and self._hi_bb ~= false and self._hi_bb.free then
        self._hi_bb:free()
    end
    self._hi_bb = nil
end



function GlimpseViewer:_buildPill()



    self._chrome_over_fit = self:_isOverFit()
    if self._pill_frame then
        self._pill_frame:free()
        self._pill_frame = nil
    end
    self._pill_dots = nil
    if self._gallery_mode then




        if self:_hasIgnoredTab() then


            local shown_n = self.shown_metas and #self.shown_metas or 0
            self._pill_frame = GlimpseTabSwitcher:new{
                segments = {
                    { label = _("Gallery"), count = shown_n },
                    { label = _("Ignored"), count = self:_ignoredCount() },
                },
                active = (self._gallery_tab == "ignored") and 2 or 1,
            }
        end
        return
    end


    if self:_isOverFit() then
        if not self._mini and not G_reader_settings:isTrue(ZOOMCTL_KEY) then






            self._pill_frame = GlimpseTextButton:new{
                text = _("Reset"),
                bold = true,
                icon = _PLUGIN_DIR .. "/assets/zoom.svg",
            }
        end
        return
    end
    if not (self._images_list and self._images_list_nb > 1) then return end
    local nb = self._images_list_nb




    local pill_square = self._mini or false
    local pill_h = self._mini
        and (Screen:scaleBySize(14) + 2 * GlimpsePill.stroke) or nil
    local pill_dy = self._mini and Screen:scaleBySize(1) or nil



    local dot_r = GlimpseDots.dot_r
    local natural_pitch = GlimpseDots.pitch
    local min_pitch = 2 * dot_r + Screen:scaleBySize(2)
    local budget = self:_pillAvailWidth() - 2 * GlimpsePill.padding_h
    local pitch = natural_pitch
    if nb > 1 then


        pitch = math.min(natural_pitch, (budget - 2 * dot_r) / (nb - 1))
    end
    if pitch >= min_pitch
       and not G_reader_settings:isTrue(NUMERIC_PILL_KEY) then

        local bm
        if self.image_metas then
            for i = 1, nb do
                local m = self.image_metas[i]
                if m and m.is_bookmark then
                    bm = bm or {}
                    bm[i] = true
                end
            end
        end
        local inner = GlimpseDots:new{
            nb = nb,
            cur = self._images_list_cur or 1,
            pitch = math.floor(pitch),
            is_bookmark = bm,
        }
        self._pill_dots = inner
        self._pill_frame = GlimpsePill:new{
            inner = inner,
            square_bottom = pill_square,
            height = pill_h,
            inner_dy = pill_dy,
        }
    else









        local counter_inverted = not self._mini
        self._pill_frame = GlimpsePill:new{
            inverted = counter_inverted,
            square_bottom = pill_square,
            height = pill_h,
            inner_dy = pill_dy,
            fixed_height = self._mini or false,
            inner = TextWidget:new{
                text = string.format("%d / %d", self._images_list_cur or 1, nb),
                face = chromeFace(13),
                bold = true,
                fgcolor = counter_inverted and Blitbuffer.COLOR_BLACK
                    or Blitbuffer.COLOR_WHITE,
            },
        }
    end
end





function GlimpseViewer:_pillAvailWidth()
    local image_area_w = self._mini and self.width
        or (self.width - self.image_right_gap)
    local btn_inset = self._mini and 0 or Screen:scaleBySize(16)
    local btn_gap = self._mini and 0 or Screen:scaleBySize(10)
    local btn_size = GlimpseMoreButton.size
    local nav = G_reader_settings:isTrue(NAV_BUTTONS_KEY) and not self._mini
        and self._images_list and (self._images_list_nb or 1) > 1
    local more_left
    if nav then
        more_left = image_area_w - 2 * btn_size - btn_gap
    elseif self:_hasQuickActions() then
        more_left = image_area_w - btn_size
    else

        more_left = image_area_w
    end
    local left_bound = nav and (btn_inset + btn_size) or btn_inset
    return more_left - left_bound - 2 * btn_gap
end

function GlimpseViewer:_buildMoreButton()




    self._more_is_gallery = not _any_quick_enabled()
    self._more_frame = GlimpseMoreButton:new{
        icon = self._more_is_gallery
            and (_PLUGIN_DIR .. "/assets/gallery.svg") or nil,
    }
end













function GlimpseViewer:_tabList()
    if self._gallery_tab == "ignored" then
        return self.ignored_list, self.ignored_metas,
            self.ignored_metas and #self.ignored_metas or 0
    end
    return self.shown_list, self.shown_metas,
        self.shown_metas and #self.shown_metas or 0
end

function GlimpseViewer:_ignoredCount()
    return self.ignored_metas and #self.ignored_metas or 0
end



function GlimpseViewer:_hasIgnoredTab()
    return self:_ignoredCount() > 0
end

function GlimpseViewer:_switchGalleryTab(tab)
    if tab == self._gallery_tab then return end
    self._gallery_tab = tab
    self._gallery_page = 1
    self._full_band_refresh = true
    self:update()
end








function GlimpseViewer:_refreshWholeScreen()
    UIManager:setDirty("all", "full", Geom:new{
        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
end

function GlimpseViewer:_enterGallery(page, tab)
    self._gallery_mode = true
    self._gallery_tab = tab or self.primary_tab or "shown"



    self:_resolveGeometry()
    local layout = self:_galleryLayout()
    if page then
        self._gallery_page = math.min(math.max(page, 1), #layout.pages)
    else
        self._gallery_page = layout.page_of[self._images_list_cur or 1] or 1
    end


    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
    self._full_band_refresh = true
    self:update()
    if _miniMode() then self:_refreshWholeScreen() end
end

function GlimpseViewer:_exitGallery(idx)




    if not idx and self._gallery_is_root then
        self:onClose()
        return
    end
    self._gallery_mode = false
    if idx then self._gallery_is_root = false end



    self._full_band_refresh = true
    if idx and idx ~= (self._images_list_cur or 1) then
        self:switchToImageNum(idx)
    else
        self:update()
    end
    if _miniMode() then self:_refreshWholeScreen() end
end

function GlimpseViewer:_galleryPages()
    return #self:_galleryLayout().pages
end


function GlimpseViewer:_contentOrigin()
    local mf = self.main_frame.dimen


    local b = self.panel_border
    local left_pad = self._place == "left" and 0 or b
    local top_pad = self._place == "top" and 0 or b
    return mf.x + left_pad, mf.y + self.panel_vgap + top_pad
end


function GlimpseViewer:_galleryHit(pos)
    if not self._gallery_cells then return nil end
    local ox, oy = self:_contentOrigin()
    for _, c in ipairs(self._gallery_cells) do
        if pos:intersectWith(Geom:new{
            x = ox + c.x, y = oy + c.y, w = c.w, h = c.h }) then
            return c
        end
    end
    return nil
end





function GlimpseViewer:_openMoveMenu(cell, pos)
    local metas = select(2, self:_tabList())
    local meta = metas and metas[cell.idx]
    if not meta then return end
    local ignored = self._gallery_tab == "ignored"
    local label, cb
    if meta.is_bookmark then


        label = _("Remove bookmark")
        cb = function()
            if self.on_remove_bookmark then
                self.on_remove_bookmark(meta, true, self._gallery_tab,
                    self._gallery_page)
            end
        end
    elseif ignored then
        label = _("Add back to Gallery")
        cb = function()
            if self.on_unignore then
                self.on_unignore(meta, "ignored", self._gallery_page)
            end
        end
    else
        label = _("Ignore this image")
        cb = function()
            if self.on_ignore then
                self.on_ignore(meta, "shown", self._gallery_page)
            end
        end
    end


    self._dim_except_idx = meta and cell.idx
    self:update()
    local menu
    menu = GlimpsePopupMenu:new{
        items = { { text = label, callback = cb } },
        on_rotate = function(rot) self:onSetRotationMode(rot) end,

        row_h = Screen:scaleBySize(38),
        pad_left = Screen:scaleBySize(12),
        pad_right = Screen:scaleBySize(12),




        anchor = function()
            local w = menu.movable and menu.movable.dimen
                and menu.movable.dimen.w or 0
            local ox = self.main_frame.dimen.x
            local pad = Screen:scaleBySize(4)
            local lift = Screen:scaleBySize(28)
            local x = math.floor((pos and pos.x or 0) - w / 2)
            local maxx = ox + self.width - w - pad
            if maxx < ox + pad then maxx = ox + pad end
            x = math.max(ox + pad, math.min(x, maxx))
            local y = (pos and pos.y or 0) - lift
            return Geom:new{ x = x, y = y, w = 0, h = 0 }, false
        end,
    }


    menu.on_dismiss = function()
        if self._dim_except_idx then
            self._dim_except_idx = nil
            self:update()
        end
    end
    UIManager:show(menu, function() return "ui", menu:refreshRegion() end)
end






function GlimpseViewer:_galleryLayout()
    local tab = self._gallery_tab or "shown"



    if self._gallery_layout_w ~= self.width then
        self._gallery_layouts = nil
        self._gallery_layout_w = self.width
    end
    self._gallery_layouts = self._gallery_layouts or {}
    if self._gallery_layouts[tab] then return self._gallery_layouts[tab] end
    local _, metas, nb = self:_tabList()
    local m = self:_galleryMetrics()


    local cols = self._horizontal and 4 or self.gallery_cols
    local col_w = math.floor(
        (m.area_w - 2 * m.pad - (cols - 1) * m.gap) / cols)
    local thumb_w = col_w - 2 * m.inset
    local layout = { pages = {}, page_of = {} }
    local page, heights = {}, {}
    for c = 1, cols do heights[c] = 0 end
    local function flush()
        if #page > 0 then
            layout.pages[#layout.pages + 1] = page
            page = {}
            for c = 1, cols do heights[c] = 0 end
        end
    end
    for i = 1, nb or 1 do
        local meta = metas and metas[i]
        local iw = meta and (meta.width or meta.attr_width)
        local ih = meta and (meta.height or meta.attr_height)
        if not (iw and ih and iw > 0 and ih > 0) then iw, ih = 1, 1 end





        local scale = math.min(thumb_w / iw, 1)
        local th = math.floor(ih * scale + 0.5)

        th = math.min(th, m.grid_h - 2 * m.inset)
        th = math.max(th, Screen:scaleBySize(24))
        local cell_h = th + 2 * m.inset

        local best = 1
        for c = 2, cols do
            if heights[c] < heights[best] then best = c end
        end
        local y = heights[best] > 0 and heights[best] + m.gap or 0
        if y + cell_h > m.grid_h and #page > 0 then
            flush()
            best, y = 1, 0
        end
        page[#page + 1] = {
            idx = i,
            x = m.pad + (best - 1) * (col_w + m.gap),
            y = m.top + y,
            w = col_w,
            h = math.min(cell_h, m.grid_h),
        }
        heights[best] = y + cell_h
        layout.page_of[i] = #layout.pages + 1
    end
    flush()
    if #layout.pages == 0 then layout.pages[1] = {} end
    self._gallery_layouts[tab] = layout
    return layout
end







function GlimpseViewer:_headMetrics()
    if self._head_metrics then return self._head_metrics end
    local t = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 16), bold = true }
    local s = TextWidget:new{
        text = "Gy", face = Font:getFace("cfont", 12), bold = true }
    local th1, th2 = t:getSize().h, s:getSize().h
    t:free(); s:free()
    local band_top = Screen:scaleBySize(3) + math.floor(th1 / 4)
    local gap = 0
    local below = Screen:scaleBySize(6)
    self._head_metrics = {
        band_top = band_top, th1 = th1, gap = gap,
        content_top = band_top + th1 + gap + th2 + below,
    }
    return self._head_metrics
end







function GlimpseViewer:_galleryMetrics()
    local content_top = self:_headMetrics().content_top
    return {
        area_w = self.width,
        pad = Screen:scaleBySize(16),
        top = content_top,
        bottom = Screen:scaleBySize(60),
        gap = Screen:scaleBySize(10),
        inset = Screen:scaleBySize(4),
        grid_h = self.img_container_h - content_top - Screen:scaleBySize(60),
    }
end

function GlimpseViewer:_galleryGo(delta)
    local pages = self:_galleryPages()
    local p = (self._gallery_page or 1) + delta
    if G_reader_settings:isTrue(NAV_LOOP_KEY) and pages > 1 then

        p = (p - 1) % pages + 1
    else
        p = math.min(math.max(p, 1), pages)
    end
    if p ~= self._gallery_page then
        self._gallery_page = p
        self:update()
    end
end







function GlimpseViewer:_thumb(i, w, h)
    self._thumb_bbs = self._thumb_bbs or {}


    local ckey = (self._gallery_tab or "shown") .. ":" .. i
    local t = self._thumb_bbs[ckey]
    if t and t.w == w and t.h == h then
        return t.bb
    end
    if t and t.bb then
        t.bb:free()
        self._thumb_bbs[ckey] = nil
    end
    local list = (self:_tabList())
    local src = list and list[i]
    local own = false
    if type(src) == "function" then
        src = src()
        own = true
    end
    if not src then return nil end
    local bw, bh = src:getWidth(), src:getHeight()
    local s = math.min(w / bw, h / bh, 1)
    local bb
    if s < 1 then
        bb = RenderImage:scaleBlitBuffer(src,
            math.max(1, math.floor(bw * s + 0.5)),
            math.max(1, math.floor(bh * s + 0.5)), own)
    else
        bb = own and src or src:copy()
    end



    self._thumb_bbs[ckey] = { bb = bb, w = w, h = h }
    return bb
end



function GlimpseViewer:_onBookmarkThumbReady(path)
    if self._thumb_bbs and self.image_metas then
        for i, m in ipairs(self.image_metas) do
            if m.path == path then
                for _, tab in ipairs({ "shown", "ignored" }) do
                    local ck = tab .. ":" .. i
                    local t = self._thumb_bbs[ck]
                    if t then
                        if t.bb then t.bb:free() end
                        self._thumb_bbs[ck] = nil
                    end
                end
            end
        end
    end
    if self._gallery_mode then






        if not self._bm_repaint_scheduled then
            self._bm_repaint_scheduled = true
            UIManager:nextTick(function()
                self._bm_repaint_scheduled = nil
                if self._gallery_mode then self:update() end
            end)
        end
    else
        local cur_idx = self._images_list_cur or 1
        local cur = self.image_metas and self.image_metas[cur_idx]
        if cur and cur.path == path then


            if self.image and self.image_disposable and self.image.free then
                self.image:free()
            end
            self.image = self._images_list[cur_idx]
            if type(self.image) == "function" then self.image = self.image() end
            self:update()
        end
    end
end




function GlimpseViewer:_buildGallery()
    local layout = self:_galleryLayout()
    local pages = #layout.pages
    self._gallery_page = math.min(math.max(self._gallery_page or 1, 1), pages)
    local m = self:_galleryMetrics()
    local grid = OverlapGroup:new{
        dimen = Geom:new{ w = self.width, h = self.img_container_h },
    }




    if self._gallery_head_wgs then
        for _, w in ipairs(self._gallery_head_wgs) do w:free() end
    end
    self._gallery_head_wgs = {}
    local function addHead(wg)
        table.insert(grid, wg)
        table.insert(self._gallery_head_wgs, wg)
    end
    if self._gallery_badges then
        for _, b in ipairs(self._gallery_badges) do b:free() end
    end
    self._gallery_badges = {}
    local band_top = self:_headMetrics().band_top
    local on_ignored_tab = self._gallery_tab == "ignored"
    local count = select(3, self:_tabList())
    local title_wg = TextWidget:new{
        text = U(on_ignored_tab and _("Ignored") or _("Gallery")),
        face = chromeFace(17),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local th1 = title_wg:getSize().h
    title_wg.overlap_offset = { m.pad, band_top }
    addHead(title_wg)



    local _list, tab_metas = self:_tabList()
    local n_bm = 0
    if tab_metas then
        for _idx = 1, #tab_metas do
            if tab_metas[_idx].is_bookmark then n_bm = n_bm + 1 end
        end
    end
    local n_img = count - n_bm
    local parts = {}
    if n_img > 0 or n_bm == 0 then
        parts[#parts + 1] = (n_img == 1) and _("1 image")
            or T(_("%1 images"), n_img)
    end
    if n_bm > 0 then
        parts[#parts + 1] = (n_bm == 1) and _("1 bookmark")
            or T(_("%1 bookmarks"), n_bm)
    end


    local count_wg = TextWidget:new{
        text = U(table.concat(parts, ", ")),
        face = chromeFace(13),
        bold = true,
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = m.area_w - 2 * m.pad,
    }
    local csz = count_wg:getSize()
    count_wg.overlap_offset = {
        m.area_w - m.pad - csz.w,
        band_top + math.floor((th1 - csz.h) / 2),
    }
    addHead(count_wg)
    -- pinstripes between the title and the count (the retro title strip)
    do
        local tw_ = title_wg:getSize().w
        local x0 = m.pad + tw_ + Screen:scaleBySize(12)
        local x1 = m.area_w - m.pad - csz.w - Screen:scaleBySize(12)
        if x1 - x0 > Screen:scaleBySize(20) then
            local sh = math.max(Screen:scaleBySize(8), th1 - Screen:scaleBySize(10))
            local stripes = Widget:new{ dimen = Geom:new{ w = x1 - x0, h = sh } }
            function stripes:getSize() return self.dimen end
            function stripes:free() end
            function stripes:paintTo(bb, x, y)
                local line = math.max(1, Screen:scaleBySize(1))
                for yy = y, y + self.dimen.h - line, Screen:scaleBySize(3) do
                    bb:paintRect(x, yy, self.dimen.w, line, Blitbuffer.COLOR_BLACK)
                end
            end
            stripes.overlap_offset = { x0, band_top + math.floor((th1 - sh) / 2) }
            addHead(stripes)
        end
    end

    if pages > 1 then
        local page_wg = TextWidget:new{
            text = string.format("%d / %d", self._gallery_page or 1, pages),
            face = chromeFace(13),
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = m.area_w - 2 * m.pad,
        }
        page_wg.overlap_offset = { m.pad, band_top + th1 + self:_headMetrics().gap }
        addHead(page_wg)
    end
    self._gallery_cells = {}
    for _, c in ipairs(layout.pages[self._gallery_page] or {}) do
        local bb = self:_thumb(c.idx,
            c.w - 2 * m.inset, c.h - 2 * m.inset)
        if bb then






            local is_spotlight = self._dim_except_idx == c.idx
            local bsize = is_spotlight
                and Screen:scaleBySize(2) or Screen:scaleBySize(1)
            local fpad = Screen:scaleBySize(2)



            local frame_w = bb:getWidth() + 2 * bsize + 2 * fpad





            local cell = LeftContainer:new{
                dimen = Geom:new{ w = c.w, h = c.h },
                FrameContainer:new{
                    bordersize = bsize,
                    color = is_spotlight and Blitbuffer.COLOR_BLACK
                        or Blitbuffer.COLOR_GRAY,
                    radius = 0,
                    padding = fpad,
                    ImageWidget:new{
                        image = bb,
                        image_disposable = false,
                        alpha = true,
                        original_in_nightmode = false,
                        scale_factor = 1,
                    },
                },
            }
            cell.overlap_offset = { c.x, c.y }
            table.insert(grid, cell)
            table.insert(self._gallery_cells,
                { x = c.x, y = c.y, w = c.w, h = c.h, idx = c.idx })



            if not on_ignored_tab then
                local badge = GlimpseBadge:new{ num = c.idx }
                badge.overlap_offset = {
                    c.x + m.inset + Screen:scaleBySize(3),
                    c.y + m.inset + Screen:scaleBySize(3),
                }
                table.insert(grid, badge)
                table.insert(self._gallery_badges, badge)


                local meta = self.image_metas and self.image_metas[c.idx]
                if meta and meta.is_bookmark then
                    local bmk = GlimpseBadge:new{
                        icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                    }
                    local bsz = bmk:getSize()
                    bmk.overlap_offset = {
                        c.x + frame_w - m.inset - Screen:scaleBySize(3) - bsz.w,
                        c.y + m.inset + Screen:scaleBySize(3),
                    }
                    table.insert(grid, bmk)
                    table.insert(self._gallery_badges, bmk)
                end
            end
        end
    end


    if self._dim_except_idx then
        table.insert(grid, GlimpseDimVeil:new{
            cells = self._gallery_cells,
            except = self._dim_except_idx,
            overlap_offset = { 0, 0 },
        })
    end
    self.image_container = grid
end




function GlimpseViewer:_hasQuickActions()
    return true
end






function GlimpseViewer:_showMoreMenu()




    local items = {}
    local cur_meta = self.image_metas
        and self.image_metas[self._images_list_cur or 1]
    local cur_is_bookmark = cur_meta and cur_meta.is_bookmark



    if _quick_enabled("hide") then
        if cur_is_bookmark then
            items[#items + 1] = {
                text = _("Remove bookmark"),
                icon = _PLUGIN_DIR .. "/assets/bookmark.svg",
                callback = function() self:_removeCurrentBookmark() end,
            }
        else
            items[#items + 1] = {
                text = _("Ignore Image"),
                icon = _PLUGIN_DIR .. "/assets/hide.svg",
                callback = function() self:_hideCurrentImage() end,
            }
        end
    end
    if _quick_enabled("mode") then


        local locked = self.scope_locked or false
        items[#items + 1] = {

            text = self.scope == "whole_book"
                and _("Mode: All images")
                or _("Mode: Spoiler-free"),
            icon = _PLUGIN_DIR .. "/assets/mode.svg",
            dimmed = locked,
            dimmed_callback = locked and function()
                UIManager:show(Notification:new{
                    text = self.scope_lock_reason
                        or _("Spoiler-free is not supported on MOBI files."),
                })
            end or nil,
            callback = function()
                if self.on_toggle_scope then self.on_toggle_scope() end
            end,
        }
    end


    if _quick_enabled("rotate") and not cur_is_bookmark then
        items[#items + 1] = {
            text = _("Rotate image"),
            icon = _PLUGIN_DIR .. "/assets/rotate.svg",
            callback = function() self:_rotateCurrent() end,
        }

        if (self._cur_rotation or 0) ~= 0 then
            items[#items + 1] = {
                text = _("Reset Rotation"),
                icon = _PLUGIN_DIR .. "/assets/reset-rotation.svg",
                callback = function() self:_setRotation(0) end,
            }
        end
    end
    if _quick_enabled("showinbook") then
        items[#items + 1] = {
            text = _("Show in Book"),
            icon = _PLUGIN_DIR .. "/assets/navigate.svg",
            callback = function() self:_showInBook() end,
        }
    end



    local mini_on = self._mini or false
    if _quick_enabled("prevnext") then
        items[#items + 1] = {
            text = _("Nav Buttons"),
            check = G_reader_settings:isTrue(NAV_BUTTONS_KEY),
            check_get = function() return G_reader_settings:isTrue(NAV_BUTTONS_KEY) end,
            callback = function() self:_togglePrevNext() end,
            dimmed = mini_on,
        }
    end
    if _quick_enabled("zoomctl") then
        items[#items + 1] = {
            text = _("Zoom Controls"),
            check = G_reader_settings:isTrue(ZOOMCTL_KEY),
            check_get = function() return G_reader_settings:isTrue(ZOOMCTL_KEY) end,
            callback = function() self:_toggleZoomControl() end,
        }
    end
    if _quick_enabled("minimap") then
        items[#items + 1] = {
            text = _("Mini Map"),
            check = G_reader_settings:isTrue(MINIMAP_KEY),
            check_get = function() return G_reader_settings:isTrue(MINIMAP_KEY) end,
            callback = function() self:_toggleMiniMap() end,
        }
    end
    if _quick_enabled("captions") then
        items[#items + 1] = {
            text = _("Image Captions"),
            check = G_reader_settings:nilOrTrue(CAPTIONS_KEY),
            check_get = function() return G_reader_settings:nilOrTrue(CAPTIONS_KEY) end,
            callback = function() self:_toggleCaptions() end,
            dimmed = mini_on,
        }
    end
    if _quick_enabled("bookmarks") then
        items[#items + 1] = {


            text = _("Include Bookmarks"),
            check = G_reader_settings:isTrue(BOOKMARKS_KEY),
            callback = function() self:_toggleBookmarks() end,
        }
    end
    if _quick_enabled("invert") then
        items[#items + 1] = {


            text = _("Invert in Night Mode"),
            check = G_reader_settings:isTrue(INVERT_KEY),
            check_get = function() return G_reader_settings:isTrue(INVERT_KEY) end,
            callback = function() self:_toggleInvert() end,
        }
    end
    if _quick_enabled("layout") then
        items[#items + 1] = {


            text = _("Layout"),
            icon = _PLUGIN_DIR .. "/assets/layout.svg",
            callback = function()
                if self.on_choose_layout then self.on_choose_layout() end
            end,
        }
    end
    if _quick_enabled("minimode") then





        local compact = G_reader_settings:isTrue(MINI_MODE_KEY)
        items[#items + 1] = {
            text = compact and _("Switch to Large") or _("Switch to Compact"),
            icon = _PLUGIN_DIR .. "/assets/"
                .. (compact and "scale-up.svg" or "scale-down.svg"),
            callback = function() self:_toggleMiniMode() end,
        }
    end



    local gallery_item = {
        text = _("Gallery"),
        icon = _PLUGIN_DIR .. "/assets/gallery.svg",
        callback = function() self:_enterGallery() end,
    }
    local footer_item = gallery_item
    if #items == 0 then
        items = { gallery_item }
        footer_item = nil
    end
    local menu
    menu = GlimpsePopupMenu:new{
        items = items,
        footer_item = footer_item,
        on_rotate = function(rot) self:onSetRotationMode(rot) end,








        anchor = function()




            if self._place == "top" then return end
            local d = self._more_frame and self._more_frame.dimen
            if not d then return end
            local mov = menu.movable
            local w = mov and mov.dimen and mov.dimen.w or 0
            local gap = Screen:scaleBySize(10)




            local x
            if self._mini then




                x = d.x - gap - w
                if x < 0 then x = d.x + d.w + gap end
                x = math.max(0, math.min(x, Screen:getWidth() - w))
            else
                x = self._on_right and d.x or (d.x + d.w - w)
            end
            return Geom:new{ x = x, y = d.y - gap, w = 0, h = d.h }, true
        end,
    }




    menu._restore_region = function()
        return self._more_frame and self._more_frame.dimen
    end
    menu.on_dismiss = function()
        if self._more_frame then self._more_frame.inverted = nil end
    end


    UIManager:show(menu, function()
        return "ui", menu:refreshRegion()
    end)
end




function GlimpseViewer:_showInBook()
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    if meta and self.on_show_in_book then
        self:onClose()
        self.on_show_in_book(meta)
    end
end




function GlimpseViewer:_rotateCurrent()
    self:_setRotation(((self._cur_rotation or 0) - 90) % 360)
end

function GlimpseViewer:_setRotation(rotation)
    self._cur_rotation = rotation
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    local meta = self.image_metas and self.image_metas[self._images_list_cur]
    if meta and self.set_pref then
        self.set_pref(meta, "rotation",
            self._cur_rotation ~= 0 and self._cur_rotation or nil)
    end
    self:update()
end

function GlimpseViewer:_toggleInvert()
    local cur = self._images_list_cur or 1
    G_reader_settings:saveSetting(INVERT_KEY,
        not G_reader_settings:isTrue(INVERT_KEY))


    if self._thumb_bbs then
        for _, t in pairs(self._thumb_bbs) do
            if t.bb then t.bb:free() end
        end
        self._thumb_bbs = nil
    end


    self:_resetHiRes()


    if self.image and self.image_disposable and self.image.free then
        self.image:free()
    end
    self.image = self._images_list[cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self:update()
end



function GlimpseViewer:_togglePrevNext()
    G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
        not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
    self:update()
end

function GlimpseViewer:_toggleZoomControl()
    G_reader_settings:saveSetting(ZOOMCTL_KEY,
        not G_reader_settings:isTrue(ZOOMCTL_KEY))
    self:update()
end

function GlimpseViewer:_toggleMiniMap()
    G_reader_settings:saveSetting(MINIMAP_KEY,
        not G_reader_settings:isTrue(MINIMAP_KEY))
    self:update()
end







function GlimpseViewer:_toggleMiniMode()
    G_reader_settings:saveSetting(MINI_MODE_KEY,
        not G_reader_settings:isTrue(MINI_MODE_KEY))
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil
    self.scale_factor = 0
    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5



    self._full_band_refresh = true
    self:update()
    self:_refreshWholeScreen()
end





function GlimpseViewer:_zoomStep(dir)
    if self._gallery_mode then return end
    self:_refreshScaleFactor()
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor()
    if not fit or fit <= 0 then return end
    local maxs = self:_maxScale() or fit
    if maxs <= fit + 1e-4 then return end
    local cur = (self.scale_factor == 0) and fit or self.scale_factor
    local mult = (maxs / fit) ^ (1 / 4)
    self:_applyNewScaleFactor(dir > 0 and cur * mult or cur / mult)
end

function GlimpseViewer:_toggleCaptions()
    G_reader_settings:saveSetting(CAPTIONS_KEY,
        not G_reader_settings:nilOrTrue(CAPTIONS_KEY))
    self:update()
end





function GlimpseViewer:_toggleBookmarks()
    if self.on_toggle_bookmarks then self.on_toggle_bookmarks() end
end










function GlimpseViewer:_gestureOn(key)
    if self._mini then return true end
    return G_reader_settings:nilOrTrue(key)
end

function GlimpseViewer:_checkDoubleTap(ges)

    if not self:_gestureOn(GESTURE_DOUBLETAP_KEY) then return end
    local now = time.now()
    local slop = Screen:scaleBySize(50)
    local lt = self._last_tap
    self._last_tap = { time = now, x = ges.pos.x, y = ges.pos.y }
    if lt and now - lt.time < time.ms(350)
       and math.abs(ges.pos.x - lt.x) <= slop
       and math.abs(ges.pos.y - lt.y) <= slop then
        self._last_tap = nil
        self:onGlimpseDoubleTap(nil, ges)
    end
end







function GlimpseViewer:onGlimpseDoubleTap(_, ges)
    local was_fit = self.scale_factor == 0


    local wg = self._image_wg
    if wg and ges and ges.pos then
        wg:getSize()
        local d = wg.dimen
        local cx = d and (d.x + d.w / 2) or Screen:getWidth() / 2
        local cy = d and (d.y + d.h / 2) or Screen:getHeight() / 2
        self._center_x_ratio, self._center_y_ratio =
            wg:getPanByCenterRatio(ges.pos.x - cx, ges.pos.y - cy)
    end
    self:_refreshScaleFactor()
    if was_fit then


        self:_applyNewScaleFactor(self:_maxScale() or self.scale_factor)
    else
        self.scale_factor = 0
        self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
        self._fast_refresh = true
        self._zooming = true
        self:update()
        self._zooming = nil
    end
    return true
end













function GlimpseViewer:_reapplyCardFrame()
    if not self._mini then return end
    local mf = self.main_frame
    if not (mf and mf.dimen) then return end
    self:_paintMiniBorder(Screen.bb, mf.dimen.x, mf.dimen.y)
    if self._corner_bbs then
        self:_restoreCorners(Screen.bb, mf.dimen.x, mf.dimen.y)
    end
end

function GlimpseViewer:_flashButton(frame, action)
    if frame.disabled then return end
    local d = frame.dimen
    frame.inverted = true
    UIManager:widgetRepaint(frame, d.x, d.y)
    self:_reapplyCardFrame()
    UIManager:setDirty(nil, "fast", d)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    action()
end



function GlimpseViewer:_flashZoomZone(zone, action)
    local zc = self._zoomctl_frame
    if not zc or not zc.dimen then action(); return end
    zc.inverted_zone = zone
    UIManager:widgetRepaint(zc, zc.dimen.x, zc.dimen.y)
    self:_reapplyCardFrame()
    UIManager:setDirty(nil, "fast", zc.dimen)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    action()
end




function GlimpseViewer:_inTopMenuZone(pos)
    local z = { x = 0, y = 0, w = 1, h = 1 / 8 }
    if G_defaults then
        local zz = G_defaults:readSetting("DTAP_ZONE_MENU")
        if zz then z = zz end
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    return pos:intersectWith(Geom:new{
        x = z.x * sw, y = z.y * sh, w = z.w * sw, h = z.h * sh })
end





function GlimpseViewer:onTap(_, ges)











    if self.on_show_menu and G_reader_settings:nilOrTrue(TOP_MENU_KEY)
       and G_reader_settings:readSetting("activate_menu") ~= "swipe"
       and self:_inTopMenuZone(ges.pos) then
        self.on_show_menu()
        return true
    end




    local grip = self:_gripHitRect()
    if grip and ges.pos:intersectWith(grip) then
        return true
    end
    if ges.pos:notIntersectWith(self.main_frame.dimen) then
        self:onClose()
        return true
    end
    if self._gallery_mode and self._close_frame and self._close_frame.dimen
       and ges.pos:intersectWith(self._close_frame.dimen) then
        self:_flashButton(self._close_frame, function()
            self:_exitGallery()
        end)
        return true
    end


    if not self._gallery_mode and self._more_frame and self._more_frame.dimen
       and ges.pos:intersectWith(self._more_frame.dimen) then
        if self._more_is_gallery then


            self:_flashButton(self._more_frame, function() self:_enterGallery() end)
        else



            local d = self._more_frame.dimen
            self._more_frame.inverted = true
            UIManager:widgetRepaint(self._more_frame, d.x, d.y)
            self:_reapplyCardFrame()
            UIManager:setDirty(nil, "fast", d)
            self:_showMoreMenu()
        end
        return true
    end
    if self._nav_prev_frame and self._nav_prev_frame.dimen
       and ges.pos:intersectWith(self._nav_prev_frame.dimen) then
        self:_flashButton(self._nav_prev_frame, function()
            if self._gallery_mode then self:_galleryGo(-1)
            else self:onShowPrevImage() end
        end)
        return true
    end
    if self._nav_next_frame and self._nav_next_frame.dimen
       and ges.pos:intersectWith(self._nav_next_frame.dimen) then
        self:_flashButton(self._nav_next_frame, function()
            if self._gallery_mode then self:_galleryGo(1)
            else self:onShowNextImage() end
        end)
        return true
    end



    if self._zoomctl_frame and self._zoomctl_frame.dimen
       and ges.pos:intersectWith(self._zoomctl_frame.dimen) then
        local d = self._zoomctl_frame.dimen
        local nz = self._zoomctl_frame.no_fit and 2 or 3
        local zone = math.min(nz - 1, math.max(0,
            math.floor((ges.pos.y - d.y) / (d.h / nz))))
        if nz == 2 and zone == 1 then zone = 2 end
        if zone == 0 then
            if not self:_isAtMax() then
                self:_flashZoomZone(0, function() self:_zoomStep(1) end)
            end
        elseif zone == 1 then
            if self:_isOverFit() then
                self:_flashZoomZone(1, function()
                    self.scale_factor = 0
                    self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
                    self:update()
                end)
            end
        else
            if self:_isOverFit() then

                self:_flashZoomZone(nz - 1, function() self:_zoomStep(-1) end)
            end
        end
        return true
    end


    if self._minimap_frame and self._minimap_frame.dimen
       and ges.pos:intersectWith(self._minimap_frame.dimen) then
        local mm = self._minimap_frame
        local d = mm.dimen
        local lx = ges.pos.x - (d.x + mm.off_x)
        local ly = ges.pos.y - (d.y + mm.off_y)
        if lx >= 0 and lx < mm.disp_w and ly >= 0 and ly < mm.disp_h then
            self:_recenterTo(lx / mm.disp_w, ly / mm.disp_h)
        end
        return true
    end
    if self._gallery_mode then


        local sw = self._pill_frame
        if sw and sw.hitSegment then
            local seg = sw:hitSegment(ges.pos)
            if seg then
                local tab = (seg == 2) and "ignored" or "shown"
                if tab ~= self._gallery_tab then
                    self:_switchGalleryTab(tab)
                end
                return true
            end
        end



        local cell = self:_galleryHit(ges.pos)
        if cell and self._gallery_tab == (self.primary_tab or "shown") then
            self:_exitGallery(cell.idx)
        end
        return true
    end



    if self._pill_dots and self._pill_frame and self._pill_frame.dimen then
        local d = self._pill_frame.dimen
        local pad = Screen:scaleBySize(20)
        local hit = Geom:new{
            x = d.x - pad, y = d.y - pad,
            w = d.w + 2 * pad, h = d.h + 2 * pad,
        }
        if ges.pos:intersectWith(hit) then
            local dots = self._pill_dots
            local dd = dots.dimen or d
            local rel = ges.pos.x - dd.x - dots.dot_r
            local idx = math.floor(rel / dots.pitch + 0.5) + 1
            idx = math.min(math.max(idx, 1), dots.nb)
            if idx ~= (self._images_list_cur or 1) then
                self:switchToImageNum(idx)
            end
            return true
        end
    end
    if self.scale_factor ~= 0 then



        if self._pill_frame and self._pill_frame.dimen
           and ges.pos:intersectWith(self._pill_frame.dimen) then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        else
            self:_checkDoubleTap(ges)
        end
        return true
    end
    self:_checkDoubleTap(ges)
    return true
end



function GlimpseViewer:onShowNextImage()
    if self._gallery_mode then
        self:_galleryGo(1)
        return true
    end
    local nb = self._images_list_nb or 1

    if G_reader_settings:isTrue(NAV_LOOP_KEY) and nb > 1
            and (self._images_list_cur or 1) >= nb then
        self:switchToImageNum(1)
        return true
    end
    return ImageViewer.onShowNextImage(self)
end

function GlimpseViewer:onShowPrevImage()
    if self._gallery_mode then
        self:_galleryGo(-1)
        return true
    end
    local nb = self._images_list_nb or 1

    if G_reader_settings:isTrue(NAV_LOOP_KEY) and nb > 1
            and (self._images_list_cur or 1) <= 1 then
        self:switchToImageNum(nb)
        return true
    end
    return ImageViewer.onShowPrevImage(self)
end

function GlimpseViewer:switchToImageNum(image_num)
    if not self._images_list
       or image_num < 1 or image_num > self._images_list_nb then
        return
    end
    self._cur_rotation = self:_prefFor(image_num).rotation or 0
    self._fit_scale_factor = nil
    self._scale_factor_0 = nil

    self:_resetHiRes()



    self._flash_switch = true



    self._switching = true
    ImageViewer.switchToImageNum(self, image_num)
    local meta = self.image_metas and self.image_metas[image_num]
    if meta and self.on_image_shown then
        self.on_image_shown(meta, image_num)
    end
    self:_prefetchNeighbors()
end









function GlimpseViewer:_prefetchNeighbors()
    if self._gallery_mode then return end


    local list = self._images_list
    if type(list) ~= "table" then return end
    self._prefetch_gen = (self._prefetch_gen or 0) + 1
    local gen = self._prefetch_gen
    local cur = self._images_list_cur or 1
    local nb = self._images_list_nb or 1
    local targets = {}
    if cur + 1 <= nb then targets[#targets + 1] = cur + 1 end
    if cur - 1 >= 1 then targets[#targets + 1] = cur - 1 end
    for _, idx in ipairs(targets) do
        local fn = list[idx]
        if type(fn) == "function" then
            UIManager:scheduleIn(0.15, function()
                if self._prefetch_gen ~= gen then return end
                local ok, bb = pcall(fn)
                if ok and bb and bb.free then bb:free() end
            end)
        end
    end
end






function GlimpseViewer:onSwipe(arg, ges)






    if self._mini and ges and ges.pos and self:_startCardDrag(ges.pos) then
        local ep = ges.end_pos
        if ep then
            self:_commitCardDrag(ep.x - ges.pos.x, ep.y - ges.pos.y)
        else
            self._dragging = false
        end
        return true
    end
    if self._gallery_mode then
        local d = ges.direction
        if d == "west" or d == "east" then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            self:_galleryGo(forward and 1 or -1)
        end
        return true
    end
    if self.scale_factor == 0 then



        local d = ges.direction
        if self._images_list and (d == "west" or d == "east")
                and self:_gestureOn(GESTURE_SWIPE_KEY) then
            local forward = d == "west"
            if BD.mirroredUILayout() then forward = not forward end
            if forward then
                self:onShowNextImage()
            else
                self:onShowPrevImage()
            end
        end
        return true
    end
    return ImageViewer.onSwipe(self, arg, ges)
end






function GlimpseViewer:onMultiSwipe(_, ges)
    return true
end




function GlimpseViewer:onSpread(arg, ges)
    if not self:_gestureOn(GESTURE_PINCH_KEY) then return true end
    return ImageViewer.onSpread(self, arg, ges)
end

function GlimpseViewer:onPinch(arg, ges)
    if not self:_gestureOn(GESTURE_PINCH_KEY) then return true end
    return ImageViewer.onPinch(self, arg, ges)
end





function GlimpseViewer:onHold(_, ges)
    if self._gallery_mode then
        local cell = self:_galleryHit(ges.pos)
        if cell then self:_openMoveMenu(cell, ges.pos) end
        return true
    end


    if self:_startCardDrag(ges.pos) then return true end
    return ImageViewer.onHold(self, _, ges)
end








function GlimpseViewer:_gripHitRect()
    local d = self._mini and self._grip_frame and self._grip_frame.dimen
    if not d then return nil end
    local pad = Screen:scaleBySize(8)
    local out = self.mini_grip_inset + self.panel_border + pad
    return Geom:new{
        x = d.x - pad, y = d.y - out,
        w = d.w + pad + out, h = d.h + out + pad,
    }
end





function GlimpseViewer:_startCardDrag(pos)
    local hit = self:_gripHitRect()
    if not hit then return false end
    if not pos or not pos.intersectWith or pos:notIntersectWith(hit) then
        return false
    end
    self._drag_org_x = self._mini_x or 0
    self._drag_org_y = self._mini_y or 0


    self._drag_from_x, self._drag_from_y = pos.x, pos.y
    self._drag_dx, self._drag_dy = 0, 0
    self._dragging = true
    return true
end





function GlimpseViewer:_commitCardDrag(dx, dy)
    self._dragging = false
    local SW, SH = Screen:getWidth(), Screen:getHeight()
    local w, h = self._panel_w, self._panel_h
    local nx = self._drag_org_x + (dx or 0)
    local ny = self._drag_org_y + (dy or 0)
    nx = math.min(math.max(nx, 0), math.max(0, SW - w))
    ny = math.min(math.max(ny, 0), math.max(0, SH - h))
    if nx == self._mini_x and ny == self._mini_y then return end
    local tx, ty = SW - w, SH - h
    G_reader_settings:saveSetting(MINI_POS_KEY, {
        x = tx > 0 and (nx / tx) or 0,
        y = ty > 0 and (ny / ty) or 0,
    })





    local old = self.main_frame.dimen and self.main_frame.dimen:copy()
    self._full_band_refresh = true
    self:update()
    if old then
        local region = self:_growForShadow(old)
        local now = self.main_frame.dimen
        if now then region = region:combine(self:_growForShadow(now:copy())) end
        UIManager:setDirty("all", "ui", region)
    end
end







function GlimpseViewer:onHoldRelease(_, ges)
    if self._gallery_mode then return true end
    if self._dragging then
        self:_commitCardDrag(ges.pos.x - (self._drag_from_x or ges.pos.x),
            ges.pos.y - (self._drag_from_y or ges.pos.y))
        return true
    end
    if self._panning then
        self._panning = false
        self._pan_relative_x = ges.pos.x - self._pan_relative_x
        self._pan_relative_y = ges.pos.y - self._pan_relative_y
        if math.abs(self._pan_relative_x) >= self.pan_threshold
                or math.abs(self._pan_relative_y) >= self.pan_threshold then
            self:panBy(-self._pan_relative_x, -self._pan_relative_y)
        end
    end
    return true
end






function GlimpseViewer:_repaintOverlayFast(mode)



    local ov, il = self._overlay, self._image_layer
    if not (ov and il) then return false end
    local ox, oy, region
    if il.dimen then
        ox, oy, region = il.dimen.x, il.dimen.y, il.dimen
    else



        local mf = self.main_frame
        if not (mf and mf.dimen) then return false end
        ox = mf.dimen.x + (mf.padding_left or 0)
        oy = mf.dimen.y + (mf.padding_top or 0)
        region = Geom:new{ x = ox, y = oy, w = self.width, h = self.height }
    end
    self.dithered = false
    if self._image_wg then self._image_wg.dithered = false end
    UIManager:widgetRepaint(ov, ox, oy)





    local mf = self.main_frame
    if self._mini then
        self:_reapplyCardFrame()
    elseif self._corner_bbs and mf and mf.dimen then
        self:_restoreCorners(Screen.bb, mf.dimen.x, mf.dimen.y)
    end
    UIManager:setDirty(nil, mode, region)
    return true
end















function GlimpseViewer:onPan(arg, ges)
    if ges and ges.mousewheel_direction and ges.mousewheel_direction ~= 0 then
        if ges.mousewheel_direction > 0 then
            self:onZoomIn(0.2)
        else
            self:onZoomOut(0.2)
        end
        return true
    end





    if self._mini and ges and ges.pos and ges.relative then
        if not self._dragging then


            local sp = ges.start_pos
            if not sp then
                sp = Geom:new{ x = ges.pos.x - (ges.relative.x or 0),
                               y = ges.pos.y - (ges.relative.y or 0), w = 1, h = 1 }
            end
            self:_startCardDrag(sp)
        end
        if self._dragging then


            self._drag_dx = ges.relative.x or 0
            self._drag_dy = ges.relative.y or 0
            return true
        end
    end
    return ImageViewer.onPan(self, arg, ges)
end

function GlimpseViewer:onPanRelease(arg, ges)
    if self._dragging then
        self:_commitCardDrag(self._drag_dx, self._drag_dy)
        return true
    end
    return ImageViewer.onPanRelease(self, arg, ges)
end










function GlimpseViewer:_isOverFit()
    if self.scale_factor == 0 then return false end
    local fit = self._fit_scale_factor or self:_computeFitScaleFactor() or 1
    return self.scale_factor > fit + 0.001
end



function GlimpseViewer:_isAtMax()
    if self.scale_factor == 0 then return false end
    local maxs = self:_maxScale()
    if not maxs then return false end
    return self.scale_factor >= maxs - 0.001
end





function GlimpseViewer:_computeFitScaleFactor()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if iw and ih and iw > 0 and ih > 0 then
        if self._cur_rotation == 90 or self._cur_rotation == 270 then
            iw, ih = ih, iw
        end








        return math.min(1.5,
            (self.width - self.image_padding * 2) / iw,
            (self.img_container_h - self.image_padding * 2) / ih)
    end
end



function GlimpseViewer:_displayedImageSize()
    local iw = self.image and self.image.getWidth and self.image:getWidth()
    local ih = self.image and self.image.getHeight and self.image:getHeight()
    if not (iw and ih and iw > 0 and ih > 0) then return end
    if self._cur_rotation == 90 or self._cur_rotation == 270 then
        iw, ih = ih, iw
    end
    return iw, ih
end




function GlimpseViewer:_minimapThumb(disp_w, disp_h)
    disp_w, disp_h = math.floor(disp_w + 0.5), math.floor(disp_h + 0.5)
    if disp_w < 1 or disp_h < 1 then return end
    local deg = self._cur_rotation or 0

    local pre_w, pre_h = disp_w, disp_h
    if deg == 90 or deg == 270 then pre_w, pre_h = disp_h, disp_w end
    local src = self._images_list and self._images_list[self._images_list_cur or 1]
    local own = false
    if type(src) == "function" then src = src(); own = true end
    if not src or not src.getWidth then return end
    local sw, sh = src:getWidth(), src:getHeight()
    local scaled = RenderImage:scaleBlitBuffer(src,
        math.max(1, pre_w), math.max(1, pre_h), own)

    local rotated = rotate_bb_quadrant(scaled, deg)
    if rotated ~= scaled then scaled:free() end
    return rotated
end









function GlimpseViewer:_buildMiniMap()
    local overlay = self._overlay
    if not overlay then return end

    if self._minimap_frame then
        for i = #overlay, 1, -1 do
            if overlay[i] == self._minimap_frame then
                table.remove(overlay, i)
                break
            end
        end
        self._minimap_frame:free()
        self._minimap_frame = nil
    end



    if self._zoomctl_frame then
        self._zoomctl_frame.square_side = nil
        self._zoomctl_frame.group_shadow = nil
    end
    local show_mm = (not self._gallery_mode)
        and G_reader_settings:isTrue(MINIMAP_KEY)
        and self:_isOverFit()
    if not show_mm then return end
    local iw, ih = self:_displayedImageSize()
    if not (iw and ih) then return end
    local image_area_w = self._mini and self.width
        or (self.width - self.image_right_gap)
    local btn_gap = self._mini and 0 or Screen:scaleBySize(10)


    local btn_inset = self._mini and 0
        or (self._place == "top" and self.panel_radius
            or Screen:scaleBySize(14))
    local show_zc = (not self._gallery_mode)
        and G_reader_settings:isTrue(ZOOMCTL_KEY)
    local border = GlimpseMiniMap.border
    local zc = self._zoomctl_frame






    local box_h = self._mini and math.floor(self.height / 3)
        or (show_zc and zc and zc:getSize().h) or GlimpseZoomControl.height




    local inner_h = box_h - 2 * border
    local disp_h = math.max(1, inner_h)
    local disp_w = math.max(1, math.floor(disp_h * iw / ih + 0.5))
    local max_inner
    if self._mini then


        max_inner = self.mini_map_max_w - 2 * border
    else
        max_inner = image_area_w - 2 * Screen:scaleBySize(14) - 2 * border
        if show_zc and zc then
            max_inner = max_inner - zc:getSize().w - btn_gap + border
        end
    end



    max_inner = math.min(max_inner, math.floor(inner_h * GlimpseMiniMap.max_aspect + 0.5))
    if disp_w > max_inner and max_inner > 0 then
        disp_w = max_inner
        disp_h = math.max(1, math.floor(disp_w * ih / iw + 0.5))
    end
    local box_w = disp_w + 2 * border
    if self._mini then



        inner_h = disp_h
        box_h = disp_h + 2 * border
    end
    box_h = math.floor(box_h + 0.5)
    local inner_w = box_w - 2 * border
    local off_x = border + math.floor((inner_w - disp_w) / 2 + 0.5)
    local off_y = border + math.floor((inner_h - disp_h) / 2 + 0.5)
    local mm = GlimpseMiniMap:new{
        box_w = box_w, box_h = box_h,
        off_x = off_x, off_y = off_y,
        disp_w = disp_w, disp_h = disp_h,
        thumb = self:_minimapThumb(disp_w, disp_h),
        viewer = self,


        radius = 0,
        outline = self._mini or false,

        outline_sides = self._mini and
            { t = true, b = false, l = false, r = true } or nil,
    }
    local mx, my
    if self._mini then







        mx = -self.panel_border
        my = self.height - box_h + self.panel_border
        mm.corners = { tl = false, bl = false, br = false, tr = true }
    elseif show_zc and zc and zc.overlap_offset then



        local zoff = zc.overlap_offset
        local zsz = zc:getSize()
        my = zoff[2]
        if self._on_right then
            mx = zoff[1] + zsz.w - border
            mm.corners = { tl = false, bl = false, tr = true, br = true }
            zc.square_side = "right"
        else
            mx = zoff[1] - box_w + border
            mm.corners = { tl = true, bl = true, tr = false, br = false }
            zc.square_side = "left"
        end

        mm.no_shadow = true
        zc.group_shadow = {
            x_off = math.min(mx - zoff[1], 0),
            w = zsz.w + box_w - border,
            h = zsz.h,
        }
    else
        mm.corners = { tl = true, tr = true, bl = true, br = true }
        local anchor = self._nav_next_frame
            or (self._more_frame and self._more_frame.overlap_offset
                and self._more_frame)
        if anchor and anchor.overlap_offset then
            local asz = anchor:getSize()






            if anchor.overlap_offset[1] + asz.w / 2 < self.width / 2 then
                mx = anchor.overlap_offset[1]
            else
                mx = anchor.overlap_offset[1] + (asz.w - box_w)
            end
            my = anchor.overlap_offset[2] - btn_gap - box_h
        else
            mx = image_area_w - box_w
            my = self.height - box_h - btn_inset
        end

        mx = math.max(0, math.min(mx, self.width - box_w))
    end
    mm.overlap_offset = { mx, my }
    self._minimap_frame = mm
    table.insert(overlay, mm)
end




function GlimpseViewer:_recenterTo(cx, cy)
    local wg = self._image_wg
    if not wg or not wg._bb then return end
    cx = math.min(math.max(cx, 0.5 - wg._max_off_center_x_ratio),
        0.5 + wg._max_off_center_x_ratio)
    cy = math.min(math.max(cy, 0.5 - wg._max_off_center_y_ratio),
        0.5 + wg._max_off_center_y_ratio)
    local ox = math.floor(cx * wg._bb_w - wg.width / 2)
    local oy = math.floor(cy * wg._bb_h - wg.height / 2)
    if ox == wg._offset_x and oy == wg._offset_y then return end
    wg._offset_x, wg._offset_y = ox, oy
    wg.center_x_ratio, wg.center_y_ratio = cx, cy
    self._center_x_ratio, self._center_y_ratio = cx, cy
    self._skip_shadow_paint = true
    self.dithered = false
    local alpha = self.alpha
    self.alpha = false
    UIManager:setDirty(self, function()
        return "ui", wg.dimen or self.main_frame.dimen, false
    end)
    self.alpha = alpha
end

function GlimpseViewer:_refreshScaleFactor()
    if self._gallery_mode then


        return
    end
    if self.scale_factor == 0 then
        if self._image_wg then
            self._image_wg:getSize()
        end
        local fit = self._image_wg and self._image_wg:getScaleFactor()
        if not fit or fit <= 0 then



            fit = self:_computeFitScaleFactor()
        end
        if fit and fit > 0 then
            self._fit_scale_factor = fit
            self._scale_factor_0 = fit
        end
    end
    ImageViewer._refreshScaleFactor(self)
end

function GlimpseViewer:_applyNewScaleFactor(new_factor)
    if self._gallery_mode then return end
    self._fast_refresh = true




    self._zooming = true
    if self._image_wg then

        self._image_wg:getSize()
    end
    local fit = self._fit_scale_factor
    if not fit then



        fit = self:_computeFitScaleFactor()
        self._fit_scale_factor = fit
    end



    local ceil = self:_maxScale()
    if ceil and new_factor > ceil then new_factor = ceil end
    if fit and new_factor <= fit then
        if self.scale_factor ~= 0 then
            self.scale_factor = 0
            self._center_x_ratio, self._center_y_ratio = 0.5, 0.5
            self:update()
        end
        self._zooming = nil
        return
    end
    ImageViewer._applyNewScaleFactor(self, new_factor)
    self._zooming = nil
end







function GlimpseViewer:_nativeScale()
    local lo = self.image
    if not lo or not lo.getWidth then return nil end
    local lo_w = lo:getWidth()
    if lo_w <= 0 then return nil end
    local meta = self.image_metas and self.image_metas[self._images_list_cur or 1]
    local nat_w = meta and meta.width
    if not nat_w or nat_w <= lo_w then return 1.0 end
    return nat_w / lo_w
end









function GlimpseViewer:_maxScale()
    local nat = self:_nativeScale()




    local ceil = nat and nat * _maxZoomMult()
    local wg = self._image_wg
    if wg and wg._bb and wg.getScaleFactorExtrema then
        local ok, _minf, wmax = pcall(wg.getScaleFactorExtrema, wg)
        if ok and wmax and (not ceil or wmax < ceil) then
            ceil = wmax
        end
    end
    return ceil
end







function GlimpseViewer:panBy(x, y)
    local wg = self._image_wg
    if not wg or not wg._bb then return end
    local cx = (x + wg._offset_x + wg.width / 2) / wg._bb_w
    local cy = (y + wg._offset_y + wg.height / 2) / wg._bb_h
    cx = math.min(math.max(cx, 0.5 - wg._max_off_center_x_ratio),
        0.5 + wg._max_off_center_x_ratio)
    cy = math.min(math.max(cy, 0.5 - wg._max_off_center_y_ratio),
        0.5 + wg._max_off_center_y_ratio)
    local ox = math.floor(cx * wg._bb_w - wg.width / 2)
    local oy = math.floor(cy * wg._bb_h - wg.height / 2)
    if ox == wg._offset_x and oy == wg._offset_y then return end
    wg._offset_x, wg._offset_y = ox, oy
    wg.center_x_ratio, wg.center_y_ratio = cx, cy


    self._center_x_ratio, self._center_y_ratio = cx, cy
    self._skip_shadow_paint = true
    self.dithered = false
    local alpha = self.alpha
    self.alpha = false
    UIManager:setDirty(self, function()
        return "ui", wg.dimen or self.main_frame.dimen, false
    end)
    self.alpha = alpha
end

function GlimpseViewer:_hideCurrentImage()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    if meta and self.on_hide then
        self.on_hide(meta)
    end
    table.remove(self._images_list, cur)
    if self.image_metas then
        table.remove(self.image_metas, cur)
    end
    local nb = self._images_list_nb - 1
    self._images_list_nb = nb
    if nb < 1 then
        self:onClose()
        UIManager:show(Notification:new{
            text = _("Image ignored."),
        })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    self:_resetHiRes()
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{
        text = _("Image ignored."),
    })
    local meta2 = self.image_metas and self.image_metas[new_cur]
    if meta2 and self.on_image_shown then
        self.on_image_shown(meta2, new_cur)
    end
end






function GlimpseViewer:_removeCurrentBookmark()
    local cur = self._images_list_cur
    local meta = self.image_metas and self.image_metas[cur]
    if not (meta and meta.is_bookmark) then return end
    if self.on_remove_bookmark then
        self.on_remove_bookmark(meta, false)
    end
    table.remove(self._images_list, cur)
    if self.image_metas then
        table.remove(self.image_metas, cur)
    end
    local nb = self._images_list_nb - 1
    self._images_list_nb = nb
    if nb < 1 then
        self:onClose()
        UIManager:show(Notification:new{ text = _("Bookmark removed.") })
        return
    end
    if self.image and self.image_disposable and self.image.free then
        self.image:free()
        self.image = nil
    end
    self:_resetHiRes()
    local new_cur = math.min(cur, nb)
    self._cur_rotation = self:_prefFor(new_cur).rotation or 0
    self.image = self._images_list[new_cur]
    if type(self.image) == "function" then
        self.image = self.image()
    end
    self._images_list_cur = new_cur
    self:update()
    UIManager:show(Notification:new{ text = _("Bookmark removed.") })
    local meta2 = self.image_metas and self.image_metas[new_cur]
    if meta2 and self.on_image_shown then
        self.on_image_shown(meta2, new_cur)
    end
end



local Glimpse = WidgetContainer:extend{
    name = "glimpse",



    is_doc_only = false,


    github_repo = "Fank1/glimpse",
}

function Glimpse:onDispatcherRegisterActions()
    Dispatcher:registerAction("glimpse_show", {
        category = "none",
        event = "GlimpseShow",
        title = _("Open Glimpse"),
        reader = true,
    })
end

function Glimpse:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Glimpse:onGlimpseShow()



    if not G_reader_settings:nilOrTrue(ENABLED_KEY) then return true end
    self:showViewer()
    return true
end

function Glimpse:onCloseDocument()

    self:_bbCacheFree()
end







Glimpse.BB_CACHE_MAX = 3
function Glimpse:_bbCacheGet(key)
    local c = self._bb_cache
    local e = c and c.map[key]
    if not e then return nil end
    c.seq = c.seq + 1
    e.seq = c.seq
    return e.bb
end
function Glimpse:_bbCachePut(key, bb)
    local c = self._bb_cache
    if not c then c = { map = {}, n = 0, seq = 0 }; self._bb_cache = c end
    local prev = c.map[key]
    if prev then
        if prev.bb then prev.bb:free() end
        c.n = c.n - 1
    end
    c.seq = c.seq + 1
    c.map[key] = { bb = bb, seq = c.seq }
    c.n = c.n + 1
    while c.n > Glimpse.BB_CACHE_MAX do
        local lru_key, lru_seq
        for k, e in pairs(c.map) do
            if not lru_seq or e.seq < lru_seq then lru_seq, lru_key = e.seq, k end
        end
        if not lru_key then break end
        if c.map[lru_key].bb then c.map[lru_key].bb:free() end
        c.map[lru_key] = nil
        c.n = c.n - 1
    end
end
function Glimpse:_bbCacheFree()
    local c = self._bb_cache
    if not c then return end
    for k, e in pairs(c.map) do
        if e.bb then e.bb:free() end
        c.map[k] = nil
    end
    self._bb_cache = nil
end









function Glimpse:isScopeLocked()
    return self:_docFormat() == "mobi"
end


function Glimpse:scopeLockReason()
    return _("Spoiler-free is not supported on MOBI files.")
end

function Glimpse:getScope()
    if self:isScopeLocked() then return "whole_book" end
    return G_reader_settings:readSetting(SCOPE_KEY) or "read_so_far"
end

function Glimpse:getFilterLevel()
    return G_reader_settings:readSetting(FILTER_KEY) == "all"
        and "all" or "balanced"
end

function Glimpse:_hiddenPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_hidden")) or {}
end





function Glimpse:_forcedPaths()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_forced")) or {}
end


function Glimpse:_imgPrefs()
    return (self.ui.doc_settings and
            self.ui.doc_settings:readSetting("glimpse_img_prefs")) or {}
end

function Glimpse:_setImgPref(path, key, value)
    local all = self:_imgPrefs()
    local p = all[path] or {}
    p[key] = value
    local has = false
    for _ in pairs(p) do has = true break end
    all[path] = has and p or nil
    self.ui.doc_settings:saveSetting("glimpse_img_prefs", all)




    self.ui.doc_settings:flush()
end

function Glimpse:_hiddenCount()
    local n = 0
    for _ in pairs(self:_hiddenPaths()) do n = n + 1 end
    return n
end












function Glimpse:_metaPageNumber(meta)
    local doc = self.ui and self.ui.document
    if not (doc and doc.getPageFromXPointer) then return 0 end
    local xp
    if meta.node_path and meta.spine_index and meta.spine_index > 0
            and doc.isXPointerInDocument then
        local cand = string.format("/body/DocFragment[%d]/body/%s",
            meta.spine_index, meta.node_path)
        local ok = pcall(function() return doc:isXPointerInDocument(cand) end)
        if ok and doc:isXPointerInDocument(cand) then xp = cand end
    end
    if not xp and meta.spine_index and meta.spine_index > 0 then
        xp = self:_chapterXPointer(meta.spine_index)
    end
    if not xp then return 0 end
    local ok, page = pcall(function() return doc:getPageFromXPointer(xp) end)
    return (ok and page) or 0
end





function Glimpse:_collectBookmarkMetas()
    local out = {}
    local ann = self.ui and self.ui.annotation
    local bm = self.ui and self.ui.bookmark
    if not (ann and bm and ann.annotations) then return out end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local toc = self.ui and self.ui.toc
    for _, a in ipairs(ann.annotations) do
        if not a.drawer then
            local page = bm:getBookmarkPageNumber(a)
            if page then

                local chapter
                if toc and toc.getTocTitleByPage then
                    local ok, t = pcall(function()
                        return toc:getTocTitleByPage(page)
                    end)
                    if ok then chapter = t end
                end
                out[#out + 1] = {
                    is_bookmark = true,
                    page = page,
                    _page = page,
                    chapter = chapter,
                    xpointer = a.page,
                    path = "glimpse-bm:" .. tostring(a.page),
                    width = sw,
                    height = sh,
                }
            end
        end
    end
    return out
end






function Glimpse:_removeBookmark(meta)
    local ann = self.ui and self.ui.annotation
    local bm = self.ui and self.ui.bookmark
    if not (ann and bm and ann.annotations and meta and meta.xpointer) then
        return false
    end
    for i = #ann.annotations, 1, -1 do
        local a = ann.annotations[i]
        if not a.drawer and a.page == meta.xpointer then
            bm:removeItem(a, i)





            local dogear = self.ui and self.ui.view and self.ui.view.dogear
            if dogear and dogear.getRefreshRegion and dogear.icon
                    and dogear.icon.dimen then
                UIManager:setDirty(self.ui, function()
                    return "ui", dogear:getRefreshRegion()
                end)
            end
            return true
        end
    end
    return false
end



function Glimpse:_bookmarkPlaceholder(im)
    local w = math.max(2, math.floor((im.width or Screen:getWidth()) / 3))
    local h = math.max(2, math.floor((im.height or Screen:getHeight()) / 3))
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    return bb
end

function Glimpse:_bookmarkThumb(im)
    return self._bm_cache and self._bm_cache[im.path]
end



function Glimpse:_bmThumbSize()
    local ratio = GlimpseViewer.panel_ratio or 1
    local w = math.max(1, math.floor(Screen:getWidth() * ratio))
    return w, Screen:getHeight()
end









function Glimpse:_bmDiskDir()
    if self._bm_disk_dir ~= nil then return self._bm_disk_dir or nil end
    local dir = DataStorage:getDataDir() .. "/cache/glimpse-thumbs/"
    lfs.mkdir(dir)
    self._bm_disk_dir = dir
    return dir
end

function Glimpse:_bmDiskPath(im, w, h)
    local dir = self:_bmDiskDir()
    if not dir then return nil end
    local doc = self.ui and self.ui.document
    local file = (doc and doc.file) or "?"
    local nm = ""
    if Screen.night_mode and doc and doc.configurable
            and doc.configurable.nightmode_images == 1 then
        nm = "_nm"
    end
    local rhash = 0
    if doc and doc.getDocumentRenderingHash then
        local ok, r = pcall(function() return doc:getDocumentRenderingHash(false) end)
        if ok and r then rhash = r end
    end
    local key = string.format("%s|p%d|w%d|h%d|r%s%s",
        file, im.page, w, h, tostring(rhash), nm)
    return dir .. md5(key) .. ".tile"
end




function Glimpse:_loadBookmarkThumbFromDisk(im)
    local w, h = self:_bmThumbSize()
    local path = self:_bmDiskPath(im, w, h)
    if not path or not lfs.attributes(path, "mode") then return nil end
    local item = TileCacheItem:new{}
    local ok = pcall(function() item:load(path) end)
    if ok and item.bb then
        pcall(function() lfs.touch(path) end)
        return item.bb
    end
    return nil
end



function Glimpse:_saveBookmarkThumbToDisk(im, bb, w, h)
    local path = self:_bmDiskPath(im, w, h)
    if not path then return end
    local item = TileCacheItem:new{ bb = bb }
    pcall(function() item:dump(path) end)
end




function Glimpse:_pruneBookmarkDiskCache()
    if self._bm_pruned then return end
    self._bm_pruned = true
    local dir = self:_bmDiskDir()
    if not dir then return end
    local CAP = 64 * 1024 * 1024
    local files, total = {}, 0
    for name in lfs.dir(dir) do
        if name ~= "." and name ~= ".." then
            local p = dir .. name
            local a = lfs.attributes(p)
            if a and a.mode == "file" then
                files[#files + 1] = { path = p, size = a.size, mtime = a.modification }
                total = total + (a.size or 0)
            end
        end
    end
    if total <= CAP then return end
    table.sort(files, function(a, b) return a.mtime < b.mtime end)
    for _, f in ipairs(files) do
        if total <= CAP then break end
        if pcall(os.remove, f.path) then total = total - (f.size or 0) end
    end
end






function Glimpse:_suppressDogear()
    local dogear = self.ui and self.ui.view and self.ui.view.dogear
    if dogear and not self._dogear_orig_paint then
        self._dogear_orig_paint = dogear.paintTo
        dogear.paintTo = function() end
    end
end

function Glimpse:_restoreDogear()
    local dogear = self.ui and self.ui.view and self.ui.view.dogear
    if dogear and self._dogear_orig_paint then
        dogear.paintTo = self._dogear_orig_paint
    end
    self._dogear_orig_paint = nil
end







function Glimpse:_requestBookmarkThumb(im)
    if not (im and im.is_bookmark and im.page) then return end
    self._bm_cache = self._bm_cache or {}
    self._bm_pending = self._bm_pending or {}
    if self._bm_cache[im.path] or self._bm_pending[im.path] then return end




    local disk_bb = self:_loadBookmarkThumbFromDisk(im)
    if disk_bb then
        self._bm_cache[im.path] = disk_bb
        return
    end
    local thumb = self.ui and self.ui.thumbnail
    if not (thumb and thumb.getPageThumbnail) then return end
    self._bm_batch = self._bm_batch or "glimpse_bookmarks"
    self:_suppressDogear()
    self._bm_pending[im.path] = true






    local w, h = self:_bmThumbSize()






    local is_async = false
    thumb:getPageThumbnail(im.page, w, h, self._bm_batch,
        function(tile)
            if not self._bm_pending then return end
            self._bm_pending[im.path] = nil
            if tile and tile.bb then
                self._bm_cache[im.path] = tile.bb:copy()

                self:_saveBookmarkThumbToDisk(im, tile.bb, w, h)
                self:_pruneBookmarkDiskCache()
                if is_async and self._viewer
                        and self._viewer._onBookmarkThumbReady then
                    self._viewer:_onBookmarkThumbReady(im.path)
                end
            end
        end)
    is_async = true
end



function Glimpse:_freeBookmarkThumbs()
    self:_restoreDogear()
    local thumb = self.ui and self.ui.thumbnail
    if thumb and thumb.cancelPageThumbnailRequests and self._bm_batch then
        pcall(function() thumb:cancelPageThumbnailRequests(self._bm_batch) end)
    end
    if self._bm_cache then
        for k, bb in pairs(self._bm_cache) do
            if bb then pcall(function() bb:free() end) end
            self._bm_cache[k] = nil
        end
    end
    self._bm_cache, self._bm_pending = nil, nil
end









function Glimpse:_docFormat()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then return nil end
    if type(doc.getDocumentFileContent) ~= "function" then return "other" end
    local low = doc.file:lower()
    if low:match("%.fb2$") then return "fb2" end
    if low:match("%.mobi$") or low:match("%.prc$") then return "mobi" end
    return "epub"
end




function Glimpse:_mobiCoverSize()
    local doc = self.ui and self.ui.document
    local cre = doc and doc._document
    if not (cre and cre.getCoverPageImageData) then return nil end
    local ok, data, size = pcall(function() return cre:getCoverPageImageData() end)
    if not (ok and data and size and size > 0) then return nil end
    pcall(function() require("ffi").C.free(data) end)
    return size
end




function Glimpse:_fb2Text()
    local doc = self.ui and self.ui.document
    local file = doc and doc.file
    if not file then return nil end
    if self._fb2_text_file == file and self._fb2_text ~= nil then
        return self._fb2_text or nil
    end
    local f = io.open(file, "rb")
    local data = f and f:read("*a")
    if f then f:close() end
    self._fb2_text_file = file
    self._fb2_text = data or false
    return data
end

function Glimpse:_supportedReason()
    local doc = self.ui and self.ui.document
    if not doc or not doc.file then
        return false, _("No book is open.")
    end
    if not scanner then
        return false, _("Glimpse failed to load its scanner module. Try reinstalling the plugin.")
    end


    if type(doc.getDocumentFileContent) ~= "function" then
        return false, _("Glimpse works with EPUB, FB2 and MOBI books only (this document format is not supported)."), "unsupported"
    end
    return true
end




function Glimpse:_makeReader()


    if self:_docFormat() == "fb2" then
        local fb2 = self:_fb2Text()
        local function read_file(id)
            if not fb2 or not id then return nil end
            return scanner.fb2_read_binary(fb2, id)
        end
        return read_file, function() end
    end
    local doc = self.ui.document
    local arc
    local function read_file(path)
        local ok, data = pcall(doc.getDocumentFileContent, doc, path)
        if ok and type(data) == "string" and #data > 0 then
            return data
        end
        if arc == nil then
            local ok2, Archiver = pcall(require, "ffi/archiver")
            if ok2 and Archiver and Archiver.Reader then
                local r = Archiver.Reader:new()
                arc = r:open(doc.file) and r or false
            else
                arc = false
            end
        end
        if arc then
            local ok3, d = pcall(arc.extractToMemory, arc, path)
            if ok3 and type(d) == "string" and #d > 0 then
                return d
            end
        end
        return nil
    end
    local function close()
        if arc then pcall(arc.close, arc) end
        arc = nil
    end
    return read_file, close
end





function Glimpse:_currentSpineIndex()
    local doc = self.ui.document
    if type(doc.getXPointer) ~= "function" then return nil end
    local ok, xp = pcall(doc.getXPointer, doc)
    if ok and type(xp) == "string" then

        local n = xp:match("DocFragment%[(%d+)%]")
        if n then return tonumber(n) end


        local sect = xp:match("[sS]ection%[(%d+)%]")
        if sect then return tonumber(sect) end
    end
    return nil
end



function Glimpse:_chapterXPointer(spine_index)
    if not spine_index or spine_index < 1 then return nil end
    if self:_docFormat() == "fb2" then
        return string.format("/FictionBook/body/section[%d]", spine_index)
    end
    return string.format("/body/DocFragment[%d]", spine_index)
end



function Glimpse:_cachePath()






    local dir = DocSettings:getSidecarDir(self.ui.document.file)
    lfs.mkdir(dir)
    return dir .. "/glimpse.scan.lua"
end





function Glimpse:_getScan(force, cache_only)
    if self._scan and not force then
        return self._scan
    end
    local doc = self.ui.document
    local a = lfs.attributes(doc.file)


    local mtime = a and a.modification or 0
    local size = a and a.size or 0
    local cache = LuaSettings:open(self:_cachePath())

    if not force then
        local c = cache:readSetting("scan")
        if c and c.version == scanner.VERSION
           and cache:readSetting("mtime") == mtime
           and cache:readSetting("size") == size then
            self._scan = c
            return c
        end
    end
    if cache_only then return nil end

    local ok, result, err
    local fmt = self:_docFormat()
    if fmt == "fb2" then
        local fb2 = self:_fb2Text()
        if not fb2 then
            self._scan_err = "error"
            return nil
        end
        ok, result, err = pcall(scanner.scan_fb2, fb2)
    elseif fmt == "mobi" then
        local read_file, close = self:_makeReader()
        local cover_size = self:_mobiCoverSize()
        ok, result, err = pcall(scanner.scan_mobi, read_file, cover_size)
        close()
    else
        local read_file, close = self:_makeReader()
        ok, result, err = pcall(scanner.scan, read_file)
        close()
    end
    if not ok then
        logger.warn("Glimpse: scan failed:", result)
        self._scan_err = "error"
        return nil
    end
    if not result then
        self._scan_err = err or "error"
        return nil
    end
    self._scan = result
    self._scan_err = nil
    cache:saveSetting("mtime", mtime)
    cache:saveSetting("size", size)
    cache:saveSetting("scan", result)
    cache:flush()
    return result
end









local function _flatten_on_white(bb)
    if not bb then return bb end
    local ok, btype = pcall(function() return bb:getType() end)
    if not ok then return bb end
    if btype ~= Blitbuffer.TYPE_BB8A and btype ~= Blitbuffer.TYPE_BBRGB32 then
        return bb
    end
    local w, h = bb:getWidth(), bb:getHeight()

    local out_type = (btype == Blitbuffer.TYPE_BBRGB32)
        and Blitbuffer.TYPE_BBRGB32 or Blitbuffer.TYPE_BB8
    local flat = Blitbuffer.new(w, h, out_type)
    flat:fill(Blitbuffer.COLOR_WHITE)
    flat:alphablitFrom(bb, 0, 0, 0, 0, w, h)
    bb:free()
    return flat
end

function Glimpse:_render(read_file, im)
    local data = read_file(im.path)
    if not data and im.raw_path and im.raw_path ~= im.path then
        data = read_file(im.raw_path)
    end
    local bb
    if data then
        if im.format == "svg" or im.is_svg_doc then
            local ok, res = pcall(RenderImage.renderSVGImageDataWithCRengine,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
        if not bb then
            local ok, res = pcall(RenderImage.renderImageData,
                                  RenderImage, data, #data)
            if ok then bb = res end
        end
    end
    if not bb then
        logger.warn("Glimpse: could not render image", im.path)
        bb = RenderImage:renderCheckerboard(
            math.floor(Screen:getWidth() / 2),
            math.floor(Screen:getHeight() / 2),
            Screen.bb:getType())
    end
    return _flatten_on_white(bb)
end






function Glimpse:showViewer(whole_book_once)


    if self._viewer then
        self._viewer:onClose()
        return
    end
    local ok, msg, why = self:_supportedReason()
    if not ok then



        if not (why == "unsupported"
                and G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY)) then
            UIManager:show(InfoMessage:new{ text = msg })
        end
        return
    end






    local scan = self:_getScan(false, true)
    if not scan then
        local info = InfoMessage:new{ text = _("Scanning book for images…") }
        UIManager:show(info)
        UIManager:forceRePaint()
        scan = self:_getScan()
        UIManager:close(info)



        UIManager:forceRePaint()
    end
    if not scan then
        local why
        if self._scan_err == "no_container" or self._scan_err == "no_opf" then
            why = _("Glimpse works with EPUB, FB2 and MOBI books only (this document format is not supported).")
        else
            why = _("Could not scan this book for images.")
        end
        UIManager:show(InfoMessage:new{ text = why })
        return
    end

    local level = self:getFilterLevel()
    local kept_list = scanner.filter(scan.images, level)
    local kept_paths = {}
    for _, im in ipairs(kept_list) do kept_paths[im.path] = true end
    local forced = self:_forcedPaths()
    local hidden = self:_hiddenPaths()








    local shown_metas, ignored_metas = {}, {}
    for _, im in ipairs(scan.images) do
        local is_shown = (kept_paths[im.path] or forced[im.path])
            and not hidden[im.path]
        if is_shown then
            shown_metas[#shown_metas + 1] = im
        else
            ignored_metas[#ignored_metas + 1] = im
        end
    end




    local scope_hidden = 0
    if self:getScope() == "read_so_far" and not whole_book_once then
        local cur = self:_currentSpineIndex()
        if cur then
            local function clip(list)
                local kept = {}
                for _, im in ipairs(list) do
                    if im.spine_index <= cur then kept[#kept + 1] = im end
                end
                return kept
            end
            local before = #shown_metas
            shown_metas = clip(shown_metas)
            scope_hidden = before - #shown_metas
            ignored_metas = clip(ignored_metas)
        end
    end






    if G_reader_settings:isTrue(BOOKMARKS_KEY) then
        local bms = self:_collectBookmarkMetas()
        if #bms > 0 then
            for _, im in ipairs(shown_metas) do
                im._page = self:_metaPageNumber(im)
            end
            local merged, a, b = {}, 1, 1
            while a <= #shown_metas or b <= #bms do
                local ia, ib = shown_metas[a], bms[b]
                if ib == nil or (ia and (ia._page or 0) <= ib._page) then
                    merged[#merged + 1] = ia; a = a + 1
                else
                    merged[#merged + 1] = ib; b = b + 1
                end
            end
            shown_metas = merged
        end
    end








    local want_ignored_primary = self._review_ignored
        or (self._pending_gallery ~= nil)
    local primary_tab = "shown"
    if #shown_metas == 0 and want_ignored_primary and #ignored_metas > 0 then
        primary_tab = "ignored"
    end
    local imgs = (primary_tab == "shown") and shown_metas or ignored_metas

    if #imgs == 0 then





        if self:getScope() == "read_so_far" and not whole_book_once
                and scope_hidden > 0 then
            local msg = scope_hidden == 1
                and _("No images up to here yet – 1 further in the book.")
                or T(_("No images up to here yet – %1 further in the book."),
                    scope_hidden)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("Show whole book"),
                cancel_text = _("Close"),
                ok_callback = function()
                    self:showViewer(true)
                end,
            })
        elseif #ignored_metas > 0 then


            local msg = #ignored_metas == 1
                and _("No images to show – 1 was filtered out as irrelevant.")
                or T(_("No images to show – %1 were filtered out as irrelevant."),
                    #ignored_metas)
            UIManager:show(ConfirmBox:new{
                text = msg,
                ok_text = _("Review filtered-out"),
                ok_callback = function()
                    self._review_ignored = true
                    self:showViewer(whole_book_once)
                end,
            })
        else
            UIManager:show(InfoMessage:new{ text = _("No images to show.") })
        end
        return
    end
    self._review_ignored = nil
















    local read_file, close_reader = self:_makeReader()








    local cap_w = 2 * math.floor(Screen:getWidth() * GlimpseViewer.panel_ratio)
    local cap_h = 2 * Screen:getHeight()



    local function decode(im, hires)
        local night = Screen.night_mode
        local checked = G_reader_settings:isTrue(INVERT_KEY)
        local bb = self:_render(read_file, im)
        if bb and not hires then
            local w, h = bb:getWidth(), bb:getHeight()
            local s = math.min(1, cap_w / w, cap_h / h)
            if s < 1 then
                local scaled = RenderImage:scaleBlitBuffer(bb,
                    math.floor(w * s + 0.5), math.floor(h * s + 0.5), true)
                if scaled then bb = scaled end
            end
        end


        if bb and night and not checked then
            pcall(bb.invertRect, bb, 0, 0, bb:getWidth(), bb:getHeight())
        end
        return bb
    end




    local function make_list(metas)
        local list = { image_disposable = true }
        for i, im in ipairs(metas) do
            if im.is_bookmark then






                list[i] = function()
                    local bb = self:_bookmarkThumb(im)
                    if bb then return bb:copy() end
                    self:_requestBookmarkThumb(im)





                    bb = self:_bookmarkThumb(im)
                    if bb then return bb:copy() end
                    return self:_bookmarkPlaceholder(im)
                end
            else
            list[i] = function()
                local night = Screen.night_mode
                local checked = G_reader_settings:isTrue(INVERT_KEY)




                local key = im.path .. "|" .. tostring(night) .. tostring(checked)
                local cached = self:_bbCacheGet(key)
                if cached then

                    return cached:copy()
                end
                local bb = decode(im, false)
                if bb then self:_bbCachePut(key, bb:copy()) end
                return bb
            end
            end
        end
        return list
    end
    local shown_render = make_list(shown_metas)
    local ignored_render = make_list(ignored_metas)
    local images_list = (primary_tab == "shown") and shown_render or ignored_render



    local hires_decode = function(index)
        local im = imgs[index]
        if not im then return nil end


        if im.is_bookmark then
            local bb = self:_bookmarkThumb(im)
            return bb and bb:copy() or nil
        end
        return decode(im, true)
    end


    local start = 1
    local last = self.ui.doc_settings:readSetting("glimpse_last")
    if last then
        for i, im in ipairs(imgs) do
            if im.path == last then
                start = i
                break
            end
        end
    end




    local effective_scope = (self:getScope() == "read_so_far"
        and not whole_book_once) and "read_so_far" or "whole_book"

    local viewer
    viewer = GlimpseViewer:new{
        image = images_list,
        image_metas = imgs,

        hires_decode = hires_decode,


        shown_metas = shown_metas,
        shown_list = shown_render,
        ignored_metas = ignored_metas,
        ignored_list = ignored_render,
        primary_tab = primary_tab,

        gallery_hidden_count = scope_hidden,
        images_keep_pan_and_zoom = false,

        _suppress_refresh = true,
        on_image_shown = function(meta)
            self.ui.doc_settings:saveSetting("glimpse_last", meta.path)
        end,
        on_hide = function(meta)
            local h = self:_hiddenPaths()
            h[meta.path] = true
            self.ui.doc_settings:saveSetting("glimpse_hidden", h)
        end,
        get_pref = function(meta)
            return self:_imgPrefs()[meta.path] or {}
        end,
        set_pref = function(meta, key, value)
            self:_setImgPref(meta.path, key, value)
        end,
        on_show_in_book = function(meta)
            if not self.ui.rolling then return end

            if meta.is_bookmark then
                if self.ui.link then
                    self.ui.link:addCurrentLocationToStack()
                end
                self.ui.rolling:onGotoXPointer(meta.xpointer)
                return
            end
            if not meta.spine_index then return end
            if self.ui.link then
                self.ui.link:addCurrentLocationToStack()
            end






            local target = self:_chapterXPointer(meta.spine_index)
            if not target then return end
            local doc = self.ui.document
            if meta.node_path and doc and doc.isXPointerInDocument then
                local xp = string.format("/body/DocFragment[%d]/body/%s",
                    meta.spine_index, meta.node_path)
                local ok = pcall(function() return doc:isXPointerInDocument(xp) end)
                    and doc:isXPointerInDocument(xp)
                if ok then
                    local fname = meta.path and meta.path:match("[^/]+$")
                    local ok2, html = pcall(function()
                        return doc:getHTMLFromXPointer(xp, 0)
                    end)
                    if ok2 and html and fname
                            and html:find(fname, 1, true) then
                        target = xp
                    end
                end
            end
            self.ui.rolling:onGotoXPointer(target)
        end,


        on_rotate = function(rotation)
            self.ui.view:onSetRotationMode(rotation)
            self:showViewer(whole_book_once)
        end,



        on_show_menu = function()
            self.ui:handleEvent(Event:new("ShowMenu"))
        end,
        scope = effective_scope,
        scope_locked = self:isScopeLocked(),
        scope_lock_reason = self:scopeLockReason(),





        on_toggle_scope = function()
            local new_scope = effective_scope == "whole_book"
                and "read_so_far" or "whole_book"
            G_reader_settings:saveSetting(SCOPE_KEY, new_scope)
            if self._viewer then self._viewer:onClose() end
            self:showViewer()

            UIManager:show(Notification:new{
                text = new_scope == "whole_book"
                    and _("Mode: All images")
                    or _("Mode: Images up to here"),
            })
        end,



        on_toggle_bookmarks = function()
            local now_on = G_reader_settings:isTrue(BOOKMARKS_KEY)
            G_reader_settings:saveSetting(BOOKMARKS_KEY, not now_on)
            if self._viewer then self._viewer:onClose() end
            self:showViewer()
            UIManager:show(Notification:new{
                text = now_on and _("Bookmarked pages hidden")
                    or _("Bookmarked pages shown"),
            })
        end,


        on_choose_layout = function()
            self:_showLayoutDialog()
        end,



        on_ignore = function(meta, tab, page)
            local h = self:_hiddenPaths(); h[meta.path] = true
            local f = self:_forcedPaths(); f[meta.path] = nil
            self.ui.doc_settings:saveSetting("glimpse_hidden", h)
            self.ui.doc_settings:saveSetting("glimpse_forced", next(f) and f or nil)
            self.ui.doc_settings:flush()
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("Moved to Ignored") })
        end,


        on_unignore = function(meta, tab, page)
            local f = self:_forcedPaths(); f[meta.path] = true
            local h = self:_hiddenPaths(); h[meta.path] = nil
            self.ui.doc_settings:saveSetting("glimpse_forced", f)
            self.ui.doc_settings:saveSetting("glimpse_hidden", next(h) and h or nil)
            self.ui.doc_settings:flush()
            self._pending_gallery = { tab = tab, page = page }
            if self._viewer then self._viewer:onClose() end
            self:showViewer(whole_book_once)
            UIManager:show(Notification:new{ text = _("Added to Gallery") })
        end,




        on_remove_bookmark = function(meta, from_gallery, tab, page)
            self:_removeBookmark(meta)
            if from_gallery then
                self._pending_gallery = { tab = tab, page = page }
                if self._viewer then self._viewer:onClose() end
                self:showViewer(whole_book_once)


                UIManager:show(Notification:new{ text = _("Bookmark removed.") })
            end
        end,
    }
    self._viewer = viewer





    local orig_close_widget = viewer.onCloseWidget
    viewer.onCloseWidget = function(v)
        local meta = v.image_metas and v.image_metas[v._images_list_cur or 1]
        local view
        if meta and v.scale_factor ~= 0 then
            view = {
                path = meta.path,
                scale = v.scale_factor,
                cx = v._center_x_ratio,
                cy = v._center_y_ratio,
            }
        end
        self.ui.doc_settings:saveSetting("glimpse_view", view)
        self._viewer = nil
        self:_freeBookmarkThumbs()
        close_reader()
        return orig_close_widget(v)
    end




    if start > 1 then
        viewer:switchToImageNum(start)
    end
    self.ui.doc_settings:saveSetting("glimpse_last", imgs[start].path)
    local view = self.ui.doc_settings:readSetting("glimpse_view")
    if view and view.path == imgs[start].path
            and type(view.scale) == "number" and view.scale ~= 0 then
        viewer.scale_factor = view.scale
        viewer._center_x_ratio = view.cx or 0.5
        viewer._center_y_ratio = view.cy or 0.5
        viewer:update()
    end









    viewer._gallery_is_root = (primary_tab == "ignored")
    if self._pending_gallery then
        local pg = self._pending_gallery
        self._pending_gallery = nil
        local tab = pg.tab


        local n = (tab == "ignored") and #ignored_metas or #shown_metas
        if n == 0 then tab = (tab == "ignored") and "shown" or "ignored" end
        viewer:_enterGallery(pg.page, tab)
    elseif primary_tab == "ignored" then

        viewer:_enterGallery(1, "ignored")
    end
    viewer._suppress_refresh = nil







    viewer.alpha = false





    viewer._reader_refresh_count = UIManager.refresh_count
    UIManager.refresh_count = 0






    local SW, SH = Screen:getWidth(), Screen:getHeight()
    local open_region
    if viewer._mini then



        open_region = Geom:new{ x = viewer._mini_x or 0, y = viewer._mini_y or 0,
            w = viewer._panel_w, h = viewer._panel_h }
    elseif viewer._horizontal then
        local rh = math.min(SH, viewer._panel_h + 2)
        local ry = viewer._place == "bottom" and (SH - rh) or 0
        open_region = Geom:new{ x = 0, y = ry, w = SW, h = rh }
    else
        local rw = math.min(SW, viewer._panel_w + 2)
        local rx = viewer._on_right and (SW - rw) or 0
        open_region = Geom:new{ x = rx, y = 0, w = rw, h = SH }
    end
    UIManager:show(viewer, Device:hasKaleidoWfm() and "partial" or "ui",
        viewer:_growForShadow(open_region), nil, nil, true)
    viewer.alpha = nil
end














function Glimpse:addToMainMenu(menu_items)
    menu_items.glimpse = {
        text = _("Glimpse"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:_menuItems()
        end,
    }
end
















function Glimpse:_glimpseGestures()
    local g = self.ui and self.ui.gestures
    local data = g and g.data
    local seen, found = {}, {}
    if type(data) == "table" then
        for _, section in ipairs({ "gesture_reader", "gesture_fm" }) do
            local tbl = data[section]
            if type(tbl) == "table" then
                for ges, actions in pairs(tbl) do
                    if type(actions) == "table" and actions.glimpse_show
                            and not seen[ges] then
                        seen[ges] = true
                        found[#found + 1] = ges
                    end
                end
            end
        end
    elseif g and type(g.gestures) == "table" then

        for ges, actions in pairs(g.gestures) do
            if type(actions) == "table" and actions.glimpse_show
                    and not seen[ges] then
                seen[ges] = true
                found[#found + 1] = ges
            end
        end
    end
    return found
end

function Glimpse:_hasGesture()
    return #self:_glimpseGestures() > 0
end

function Glimpse:_gestureLabel()
    local found = self:_glimpseGestures()
    if #found == 0 then return _("Gesture to open: none set") end
    table.sort(found)
    for i, ges in ipairs(found) do
        found[i] = ges:gsub("_", " "):gsub("^%l", string.upper)
    end
    return T(_("Gesture to open: %1"), table.concat(found, ", "))
end








local _LAYOUT_DIR = _PLUGIN_DIR .. "/assets/layout/"
local _layout_img_cache = {}
local function render_layout_svg(name, pane_h)
    local key = name .. ":" .. pane_h
    local cached = _layout_img_cache[key]
    if cached ~= nil then return cached or nil end

    local nw, nh = 288, 365
    if name:sub(1, 9) == "landscape" then nw, nh = 365, 288 end

    local w = math.floor(pane_h * nw / nh + 0.5)
    local ok, bb = pcall(RenderImage.renderSVGImageFile, RenderImage,
        _LAYOUT_DIR .. name .. ".svg", w, pane_h)
    if not (ok and bb) then
        _layout_img_cache[key] = false
        return nil
    end
    _layout_img_cache[key] = bb
    return bb
end

local GlimpseLayoutPreview = Widget:extend{
    pos = "side",
    align = "left",
    pane_h = Screen:scaleBySize(190),
    gap = Screen:scaleBySize(28),
    label_gap = Screen:scaleBySize(6),
}

function GlimpseLayoutPreview:_portraitFile()
    if self.pos == "bottom" then return "portrait_bottom" end
    if self.pos == "top" then return "portrait_top" end
    return self.align == "right" and "portrait_right" or "portrait_left"
end

function GlimpseLayoutPreview:_landscapeFile()
    return self.align == "right" and "landscape_right" or "landscape_left"
end

function GlimpseLayoutPreview:_labelFace()
    return Font:getFace("cfont", 12)
end

function GlimpseLayoutPreview:_labelHeight()
    if not self._label_h then
        local probe = TextWidget:new{ text = "PORTRAIT", face = self:_labelFace(),
            bold = true }
        self._label_h = probe:getSize().h
        probe:free()
    end
    return self._label_h
end

function GlimpseLayoutPreview:getSize()


    local pw = math.floor(self.pane_h * 288 / 365 + 0.5)
    local lw = math.floor(self.pane_h * 365 / 288 + 0.5)
    return Geom:new{
        w = pw + self.gap + lw,
        h = self:_labelHeight() + self.label_gap + self.pane_h,
    }
end

function GlimpseLayoutPreview:paintTo(bb, x, y)
    local sz = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local label_h = self:_labelHeight()
    local img_y = y + label_h + self.label_gap
    local pbb = render_layout_svg(self:_portraitFile(), self.pane_h)
    local lbb = render_layout_svg(self:_landscapeFile(), self.pane_h)
    local pw = pbb and pbb:getWidth() or math.floor(self.pane_h * 288 / 365 + 0.5)

    local pl = TextWidget:new{ text = _("PORTRAIT"), face = self:_labelFace(),
        bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    pl:paintTo(bb, x, y)
    pl:free()
    if pbb then bb:alphablitFrom(pbb, x, img_y, 0, 0, pbb:getWidth(), self.pane_h) end

    local col2_x = x + pw + self.gap
    local ll = TextWidget:new{ text = _("LANDSCAPE"), face = self:_labelFace(),
        bold = true, fgcolor = Blitbuffer.COLOR_DARK_GRAY }
    ll:paintTo(bb, col2_x, y)
    ll:free()
    if lbb then bb:alphablitFrom(lbb, col2_x, img_y, 0, 0, lbb:getWidth(), self.pane_h) end
end





local GlimpseLayoutDialog = FocusManager:extend{
    pos = nil,
    align = nil,
    on_apply = nil,
}

function GlimpseLayoutDialog:init()


    self.layout = {}
    self.screen_width = Screen:getWidth()
    self.screen_height = Screen:getHeight()
    self.width = math.floor(math.min(self.screen_width, self.screen_height) * 0.78)
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.ges_events.TapClose = {
        GestureRange:new{ ges = "tap",
            range = Geom:new{ w = self.screen_width, h = self.screen_height } },
    }
    self.preview = GlimpseLayoutPreview:new{
        pos = self.pos or "side", align = self.align or "left" }


    local function refresh_preview()
        self.preview.pos = self.pos_table.checked_button.provider
        self.preview.align = self.align_table.checked_button.provider
        UIManager:setDirty(self, function() return "ui", self.preview.dimen end)
    end






    local radio_gap = Size.padding.large * 2
    local radio_face = Font:getFace("cfont", 22)
    local mark_w
    do
        local m = TextWidget:new{ text = "◉ ", face = Font:getFace("smallinfofont") }
        mark_w = m:getSize().w
        m:free()
    end
    local function radio_group(entries)
        local row = HorizontalGroup:new{ align = "center" }
        local buttons = {}
        for i, e in ipairs(entries) do
            local probe = TextWidget:new{ text = e.text, face = radio_face }
            local text_w = probe:getSize().w
            probe:free()
            local btn = CheckButton:new{
                text = e.text, radio = true, checked = e.checked,
                provider = e.provider, single_line = true,
                width = mark_w + text_w + Size.padding.small,
                bordersize = 0, margin = 0, padding = 0,
                face = radio_face, parent = self, show_parent = self,
            }
            btn.callback = function()
                if btn.checked then return end
                if row.checked_button and row.checked_button ~= btn then
                    row.checked_button:toggleCheck()
                end
                btn:toggleCheck()
                row.checked_button = btn
                refresh_preview()
            end
            if e.checked then row.checked_button = btn end
            buttons[#buttons + 1] = btn
            table.insert(row, btn)
            if i < #entries then
                table.insert(row, HorizontalSpan:new{ width = radio_gap })
            end
        end
        table.insert(self.layout, buttons)
        return row
    end

    self.align_table = radio_group{
        { text = _("Left"),  provider = "left",  checked = self.align == "left" },
        { text = _("Right"), provider = "right", checked = self.align == "right" },
    }
    self.pos_table = radio_group{
        { text = _("Side"),   provider = "side",   checked = self.pos == "side" },
        { text = _("Bottom"), provider = "bottom", checked = self.pos == "bottom" },
        { text = _("Top"),    provider = "top",    checked = self.pos == "top" },
    }

    local function section(text)
        return FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0,
            padding_left = Size.padding.large,
            padding_top = Size.padding.large,
            TextWidget:new{ text = text, bold = true,
                face = Font:getFace("cfont", 18) },
        }
    end


    local function left_aligned(tbl)
        return FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0,
            padding_left = Size.padding.large,
            tbl,
        }
    end

    local buttons = ButtonTable:new{
        width = self.width - 2 * Size.padding.default,
        buttons = { {
            { text = _("Close"), callback = function() self:onClose() end },
            { text = _("Apply"), callback = function()
                local p = self.pos_table.checked_button.provider
                local a = self.align_table.checked_button.provider
                self:onClose()
                if self.on_apply then self.on_apply(p, a) end
            end },
        } },
        zero_sep = true, show_parent = self,
    }
    self:mergeLayoutInVertical(buttons)




    local card_pad = Size.padding.large
    local card_w = self.width - 2 * card_pad
    local preview_card = FrameContainer:new{
        radius = 0, bordersize = Size.border.thick,
        color = Blitbuffer.COLOR_LIGHT_GRAY, margin = 0,
        padding = card_pad, background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = card_w - 2 * card_pad,
                h = self.preview:getSize().h },
            self.preview,
        },
    }


    local vgroup = VerticalGroup:new{ align = "left",
        VerticalSpan:new{ width = Size.padding.large } }
    table.insert(vgroup, CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = preview_card:getSize().h },
        preview_card })

    table.insert(vgroup, section(_("Preferred Alignment")))
    table.insert(vgroup, left_aligned(self.align_table))
    table.insert(vgroup, section(_("Portrait Position")))
    table.insert(vgroup, left_aligned(self.pos_table))
    table.insert(vgroup, VerticalSpan:new{ width = Size.padding.large })
    table.insert(vgroup, CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = buttons:getSize().h }, buttons })

    self.widget_frame = FrameContainer:new{
        radius = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE, vgroup,
    }
    self.movable = MovableContainer:new{ self.widget_frame }
    self[1] = WidgetContainer:new{
        align = "center",
        dimen = Geom:new{ x = 0, y = 0,
            w = self.screen_width, h = self.screen_height },
        self.movable,
    }
    UIManager:setDirty(self, function() return "ui", self.widget_frame.dimen end)
end

function GlimpseLayoutDialog:onShow()
    UIManager:setDirty(self, function() return "ui", self.widget_frame.dimen end)
    return true
end
function GlimpseLayoutDialog:onCloseWidget()
    UIManager:setDirty(nil, function() return "ui", self.widget_frame.dimen end)
end
function GlimpseLayoutDialog:onTapClose(arg, ges_ev)
    if ges_ev.pos:notIntersectWith(self.widget_frame.dimen) then self:onClose() end
    return true
end
function GlimpseLayoutDialog:onClose()
    UIManager:close(self)
    return true
end




function Glimpse:_showLayoutDialog()
    UIManager:show(GlimpseLayoutDialog:new{
        pos = _portraitPos(),
        align = _prefAlign(),
        on_apply = function(pos, align)

            local old_place = _resolvePlacement()


            G_reader_settings:saveSetting(PORTRAIT_POS_KEY,
                pos ~= "side" and pos or nil)
            G_reader_settings:saveSetting(PREF_ALIGN_KEY, align)
            G_reader_settings:saveSetting(LAYOUT_RIGHT_KEY,
                align == "right" or nil)
            if not self._viewer then return end


            if _resolvePlacement() == old_place then return end






            self._viewer:onClose()
            self:showViewer()
        end,
    })
end




function Glimpse:_panelSizeItem(compact, text)
    return {
        text = text,
        radio = true,
        checked_func = function()
            return G_reader_settings:isTrue(MINI_MODE_KEY) == compact
        end,
        callback = function()
            if G_reader_settings:isTrue(MINI_MODE_KEY) == compact then return end
            local v = self._viewer
            if v and v._toggleMiniMode then
                v:_toggleMiniMode()
            else
                G_reader_settings:saveSetting(MINI_MODE_KEY, compact)
            end
        end,
    }
end

function Glimpse:_menuItems()
    local function scope_item(value, text, help)
        return {
            text = text,

            help_text_func = function()
                if self:isScopeLocked() then
                    return self:scopeLockReason() .. "\n\n" .. help
                end
                return help
            end,
            radio = true,
            checked_func = function() return self:getScope() == value end,


            enabled_func = function() return not self:isScopeLocked() end,
            callback = function()
                G_reader_settings:saveSetting(SCOPE_KEY, value)
            end,
        }
    end
    return {
        {



            text = _("Enable Glimpse"),
            help_text = _("Master switch. When off, the bound gesture and the Open Glimpse entry do nothing – a quick way to silence Glimpse without unbinding its gesture."),
            checked_func = function()
                return G_reader_settings:nilOrTrue(ENABLED_KEY)
            end,
            callback = function()
                G_reader_settings:flipNilOrTrue(ENABLED_KEY)
            end,
        },
        {



            text_func = function() return self:_gestureLabel() end,
            enabled_func = function() return false end,
            help_text = _("Assign or change it under Taps and gestures → Gesture manager → (pick a gesture) → Reader → 'Open Glimpse'."),
        },
        {
            text = _("Open Glimpse"),
            help_text = _("Browse the maps, family trees and other reference images found in this book, without losing your reading position. Tip: bind the gesture action 'Open Glimpse' for one-touch access."),


            enabled_func = function()
                return self.ui and self.ui.document ~= nil
                    and G_reader_settings:nilOrTrue(ENABLED_KEY)
            end,
            callback = function(touchmenu_instance)
                if touchmenu_instance then
                    touchmenu_instance:closeMenu()
                end


                UIManager:scheduleIn(0.3, function()
                    self:showViewer()



                    if self._viewer and not self:_hasGesture()
                            and not G_reader_settings:isTrue(GESTURE_TIP_KEY) then
                        G_reader_settings:saveSetting(GESTURE_TIP_KEY, true)
                        UIManager:show(InfoMessage:new{
                            text = _("Tip: open Glimpse instantly with a gesture.\n\nSet one under Settings → Taps and gestures → Gesture manager → pick a gesture → Reader → 'Open Glimpse'.\n\n(This tip is shown only once.)"),
                        })
                    end
                end)
            end,
        },
        {


            text_func = function()
                return self:getScope() == "whole_book"
                    and _("Mode: Show all images")
                    or _("Mode: Show images up to current chapter")
            end,
            sub_item_table = {
                scope_item("read_so_far", _("Show images up to current chapter"),
                    _("Images that appear beyond your current position stay hidden, so you can't spoil yourself. Granularity is per chapter: images in the chapter you are currently reading are shown.")),
                scope_item("whole_book", _("Show all images"),
                    _("Show reference images from anywhere in the book, including parts you haven't reached yet.")),
            },
        },
        {


            text = _("Include Bookmarks in Gallery"),
            help_text = _("Also show the pages you've bookmarked (the dogear bookmark) in the Gallery, rendered as page thumbnails and marked with a bookmark badge, in reading order alongside the images – a quick way to keep a reference page a swipe away. Off by default. Also available from the viewer's ⋯ menu (see Quick Actions)."),
            checked_func = function()
                return G_reader_settings:isTrue(BOOKMARKS_KEY)
            end,
            callback = function()
                G_reader_settings:saveSetting(BOOKMARKS_KEY,
                    not G_reader_settings:isTrue(BOOKMARKS_KEY))
            end,
            separator = true,
        },
        {
            text = _("Quick Actions"),
            help_text = _("Choose which actions appear in the viewer's ⋯ menu. Reset Rotation is automatic (shown while an image is rotated)."),
            sub_item_table = (function()
                local t = {}
                for _, d in ipairs(QUICK_ACTIONS) do
                    local key = d.key
                    t[#t + 1] = {
                        text = _quick_label(key),
                        checked_func = function() return _quick_enabled(key) end,
                        keep_menu_open = true,
                        callback = function()
                            local cfg = G_reader_settings:readSetting(QUICK_ACTIONS_KEY)
                            if type(cfg) ~= "table" then cfg = {} end
                            cfg[key] = not _quick_enabled(key)
                            G_reader_settings:saveSetting(QUICK_ACTIONS_KEY, cfg)
                        end,
                    }
                end
                return t
            end)(),
            separator = true,
        },
        {
            text = _("Settings"),
            sub_item_table = {
                {
                    text = _("Gestures"),




                    help_text = _("These apply to the large panel. The compact panel always keeps swipe, pinch and double-tap on, because it hides the navigation buttons and the reset button."),
                    sub_item_table = {
                        {
                            text = _("Double-tap for maximum zoom"),
                            help_text = _("Double-tap the image to jump to the maximum zoom (centered on the tap), and again to return to the fitted view. On by default."),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_DOUBLETAP_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_DOUBLETAP_KEY)
                            end,
                        },
                        {
                            text = _("Swipe left/right to navigate"),
                            help_text = _("Swipe left or right across the image to move to the next or previous image. On by default. (The Gallery's swipe-to-page is unaffected.)"),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_SWIPE_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_SWIPE_KEY)
                            end,
                        },
                        {
                            text = _("Pinch to zoom in/out"),
                            help_text = _("Pinch or spread two fingers on the image to zoom out or in. On by default."),
                            checked_func = function()
                                return G_reader_settings:nilOrTrue(GESTURE_PINCH_KEY)
                            end,
                            callback = function()
                                G_reader_settings:flipNilOrTrue(GESTURE_PINCH_KEY)
                            end,
                        },
                    },
                    separator = true,
                },
                {
                    text_func = function()
                        local pos = _portraitPos()
                        local pos_label = pos == "bottom" and _("Bottom")
                            or pos == "top" and _("Top") or _("Side")
                        local align_label = _prefAlign() == "right"
                            and _("Right") or _("Left")

                        return T(_("Layout: %1 · %2"), pos_label, align_label)
                    end,
                    help_text = _("Where Glimpse opens: a side panel (left or right) or, in portrait, a band across the top or bottom. In landscape it always uses the preferred side."),
                    keep_menu_open = true,
                    callback = function() self:_showLayoutDialog() end,
                },
                {




                    text_func = function()
                        return G_reader_settings:isTrue(MINI_MODE_KEY)
                            and _("Panel Size: Compact")
                            or _("Panel Size: Large")
                    end,
                    help_text = _("Large fills one edge of the screen. Compact is a small card that floats over the page, which you drag by the grip in its top-right corner. The compact card hides the captions, the bookmark label, the navigation buttons and the reset button, and the Gallery always opens at the large size."),
                    sub_item_table = {
                        self:_panelSizeItem(false, _("Large")),
                        self:_panelSizeItem(true, _("Compact")),
                    },
                },
                {
                    text_func = function()
                        return T(_("Maximum zoom: %1%"),
                            math.floor(_maxZoomMult() * 100 + 0.5))
                    end,
                    help_text = _("How far you can zoom in, as a percentage of the image's own resolution. Double-tap jumps to this level and pinch stops here. Higher reveals more on detailed maps, but past 100% it is upscaling, so very high can look soft."),
                    sub_item_table = (function()
                        local t = {}
                        for _idx, mult in ipairs(MAX_ZOOM_CHOICES) do
                            local pct = math.floor(mult * 100 + 0.5)
                            t[_idx] = {
                                text = (mult == DEFAULT_MAX_ZOOM)
                                    and T(_("%1% (recommended)"), pct)
                                    or T(_("%1%"), pct),
                                radio = true,
                                checked_func = function()
                                    return _maxZoomMult() == mult
                                end,
                                callback = function()
                                    G_reader_settings:saveSetting(MAX_ZOOM_KEY, mult)
                                end,
                            }
                        end
                        t[#t + 1] = {
                            text_func = function()
                                local cur = _maxZoomMult()
                                if not _isPresetZoom(cur) then
                                    return T(_("Custom: %1%"),
                                        math.floor(cur * 100 + 0.5))
                                end
                                return _("Custom…")
                            end,
                            radio = true,
                            checked_func = function()
                                return not _isPresetZoom(_maxZoomMult())
                            end,
                            keep_menu_open = true,
                            separator = true,
                            callback = function(touchmenu_instance)
                                local SpinWidget = require("ui/widget/spinwidget")
                                UIManager:show(SpinWidget:new{





                                    title_text = T(_("Maximum zoom: %1%"),
                                        math.floor(_maxZoomMult() * 100 + 0.5)),
                                    info_text = _("Set the zoom ceiling as a percentage of the image's own resolution. Past 100% Glimpse enlarges the pixels, so a very high value can look soft."),
                                    value = math.floor(_maxZoomMult() * 100 + 0.5),
                                    value_min = math.floor(MIN_MAX_ZOOM * 100 + 0.5),
                                    value_max = math.floor(MAX_MAX_ZOOM * 100 + 0.5),
                                    value_step = 25,
                                    value_hold_step = 100,
                                    unit = "%",
                                    ok_text = _("Set"),
                                    callback = function(spin)
                                        G_reader_settings:saveSetting(
                                            MAX_ZOOM_KEY, spin.value / 100)
                                        if touchmenu_instance then
                                            touchmenu_instance:updateItems()
                                        end
                                    end,
                                })
                            end,
                        }
                        return t
                    end)(),
                },
                {
                    text = _("Navigation Loops Around"),
                    help_text = _("Let the ‹ › buttons and swipes wrap around at the ends: Next on the last image goes to the first, and Previous on the first goes to the last. The Gallery pages wrap the same way."),
                    checked_func = function()
                        return G_reader_settings:isTrue(NAV_LOOP_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(NAV_LOOP_KEY,
                            not G_reader_settings:isTrue(NAV_LOOP_KEY))
                    end,
                    separator = true,
                },
                {
                    text = _("Show Nav Buttons"),
                    help_text = _("Show ‹ and › buttons in the viewer for switching between images, as an alternative to swiping. A button is grayed out when there is no image on its side."),
                    checked_func = function()
                        return G_reader_settings:isTrue(NAV_BUTTONS_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(NAV_BUTTONS_KEY,
                            not G_reader_settings:isTrue(NAV_BUTTONS_KEY))
                    end,
                },
                {
                    text = _("Show Zoom Controls"),
                    help_text = _("Show a vertical −/fit/+ control in the viewer for zooming in and out, as an alternative to double-tap and pinch. The middle button returns to the fitted view."),
                    checked_func = function()
                        return G_reader_settings:isTrue(ZOOMCTL_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(ZOOMCTL_KEY,
                            not G_reader_settings:isTrue(ZOOMCTL_KEY))
                    end,
                },
                {
                    text = _("Show Mini Map"),
                    help_text = _("While zoomed in, show a small overview of the image with a rectangle marking the visible area. Tap the map to jump there. It docks to the zoom controls when those are on, and is hidden at the fitted view."),
                    checked_func = function()
                        return G_reader_settings:isTrue(MINIMAP_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(MINIMAP_KEY,
                            not G_reader_settings:isTrue(MINIMAP_KEY))
                    end,
                },
                {
                    text = _("Invert Images in Night Mode"),
                    help_text = _("While KOReader's night mode is on, show images inverted (light lines on a dark background). Also toggleable from the viewer's ⋯ menu."),
                    checked_func = function()
                        return G_reader_settings:isTrue(INVERT_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(INVERT_KEY,
                            not G_reader_settings:isTrue(INVERT_KEY))
                    end,
                },
                {
                    text = _("Show image captions"),
                    help_text = _("Show the image's caption from the book, overlaid in the viewer's top-left corner."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(CAPTIONS_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(CAPTIONS_KEY)
                    end,
                },
                {
                    text = _("Show bookmark label in corner"),
                    help_text = _("On a bookmarked page, show a label with the page number and chapter in the viewer's top-left corner. Turn off to hide it."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(BOOKMARK_LABEL_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(BOOKMARK_LABEL_KEY)
                    end,
                },
                {
                    text = _("Numbered indicator instead of dots"),
                    help_text = _("Show the position as a compact \"3 / 42\" counter instead of a row of dots. Useful when a book has so many images that the dots pill grows very wide. Off by default. (With many images Glimpse switches to the counter on its own; this makes it always so.)"),
                    checked_func = function()
                        return G_reader_settings:isTrue(NUMERIC_PILL_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(NUMERIC_PILL_KEY,
                            not G_reader_settings:isTrue(NUMERIC_PILL_KEY))
                    end,
                },
            },
        },
        {
            text = _("Advanced"),
            sub_item_table = {
                {
                    text = _("Respect KOReader top menu activation"),
                    help_text = _("On (default): while the viewer is open, a tap along the top edge opens KOReader's top menu over the drawer, but only when KOReader itself opens its menu on a tap (Settings → Taps and gestures → menu activation includes Tap). Off: Glimpse keeps the top edge for itself, so a top tap never opens the menu."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(TOP_MENU_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(TOP_MENU_KEY)
                    end,
                    separator = true,
                },
                {


                    text = _("Disable irrelevant image filtering"),
                    help_text = _("By default Glimpse sets aside covers, publisher logos, ornaments and other non-reference imagery, keeping maps, family trees, diagrams and illustrations. Enable this to switch that off and see every image in the book. (Individual wrongly-kept images can instead be ignored from the viewer's ⋯ menu; wrongly set-aside ones added back from the Gallery's Ignored tab.)"),
                    checked_func = function()
                        return self:getFilterLevel() == "all"
                    end,
                    callback = function()
                        local disabled_now = self:getFilterLevel() == "all"
                        G_reader_settings:saveSetting(FILTER_KEY,
                            disabled_now and "balanced" or "all")
                    end,
                },
                {
                    text = _("Suppress \"format not supported\" notice"),
                    help_text = _("Silence the message shown when Glimpse is opened on a book format it doesn't support (PDF, comics, manga…). Handy if a reading gesture sometimes triggers Glimpse on non-EPUB files. Off by default."),
                    checked_func = function()
                        return G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SUPPRESS_UNSUPPORTED_KEY,
                            not G_reader_settings:isTrue(SUPPRESS_UNSUPPORTED_KEY))
                    end,
                },
                {
                    text = _("Disable shadows"),
                    help_text = _("Remove the drawer's drop shadow. The shadow is a dithered gradient – the main cause of e-ink ghosting behind the drawer – so turn it off if a ghost lingers after closing Glimpse. No visible effect on LCD screens."),
                    checked_func = function()
                        return G_reader_settings:isTrue(SHADOW_KEY)
                    end,
                    callback = function()
                        G_reader_settings:saveSetting(SHADOW_KEY,
                            not G_reader_settings:isTrue(SHADOW_KEY))
                    end,
                },
                {
                    text = _("Fast image switching"),
                    help_text = _("Switch between images with a quick, flashless refresh instead of a full clear. On by default: faster and no flash. Turn it off if the previous image ghosts through the next one – most noticeable on detailed maps and on slower e-ink panels. No visible effect on LCD screens."),
                    checked_func = function()
                        return G_reader_settings:nilOrTrue(FAST_SWITCH_KEY)
                    end,
                    callback = function()
                        G_reader_settings:flipNilOrTrue(FAST_SWITCH_KEY)
                    end,
                    separator = true,
                },
                {
                    text = _("Rescan this book"),
                    help_text = _("Glimpse caches its scan of the book. Use this if the book file was replaced or images seem out of date."),
                    keep_menu_open = true,
                    callback = function()
                        local okay = self:_supportedReason()
                        if not okay then return end
                        self._scan = nil
                        local info = InfoMessage:new{ text = _("Scanning book for images…") }
                        UIManager:show(info)
                        UIManager:forceRePaint()
                        local scan = self:_getScan(true)
                        UIManager:close(info)
                        if scan then
                            UIManager:show(Notification:new{
                                text = T(_("Found %1 image(s)."), #scan.images),
                            })
                        else
                            UIManager:show(Notification:new{ text = _("Scan failed.") })
                        end
                    end,
                },
            },
        },
    }
end

--- ShelfTechUI's toolbar: the pictures the viewer would show (its filter, the
--- ones hidden or added by hand) before the current chapter's end, and in the
--- whole book. nil while the book is unscanned, unless `scan`.
function Glimpse:counts(scan)
    local s = self:_getScan(false, not scan)
    if not (s and s.images) then return nil end
    local kept = {}
    for _, im in ipairs(scanner.filter(s.images, self:getFilterLevel())) do kept[im.path] = true end
    local forced, hidden = self:_forcedPaths(), self:_hiddenPaths()
    local cur = self:_currentSpineIndex()
    local seen, total = 0, 0
    for _, im in ipairs(s.images) do
        if (kept[im.path] or forced[im.path]) and not hidden[im.path] then
            total = total + 1
            if cur and im.spine_index and im.spine_index <= cur then seen = seen + 1 end
        end
    end
    return { seen = seen, total = total }
end

return Glimpse
