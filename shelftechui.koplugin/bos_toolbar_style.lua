--[[--
Drawing helpers for the reading toolbar and its stats panel, and the hooks
into Bookshelf (all optional; everything falls back when Bookshelf is absent):
whether it's running, its side inset, its night-mode-aware shadow, whether it
shows the micro-modules launcher.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local ImageWidget = require("ui/widget/imagewidget")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local Screen = Device.screen
local Look = require("bos_look")

local M = {}

local function S(v) return Screen:scaleBySize(v) end
M.S = S

M.BLACK = Blitbuffer.COLOR_BLACK
M.WHITE = Blitbuffer.COLOR_WHITE
M.DARK = Blitbuffer.COLOR_DARK_GRAY
M.GRAY = Blitbuffer.COLOR_GRAY
M.GRAY_9 = Blitbuffer.COLOR_GRAY_9
M.LIGHT = Blitbuffer.COLOR_LIGHT_GRAY

function M.line() return S(2) end

local function try(name)
    local ok, mod = pcall(require, name)
    if ok and mod then return mod end
end

function M.nightMode()
    local NM = try("lib/bookshelf_night_mode_sync")
    if NM and NM.active then
        local ok, on = pcall(NM.active, Screen)
        if ok then return on and true or false end
    end
    return G_reader_settings:isTrue("night_mode")
end

--- The hard shadow: black, or a faint grey in night mode (the screen is
--- inverted then, so black would read as a bright halo).
function M.shadowGray()
    if M.nightMode() then return Blitbuffer.gray(0.15) end
    return Blitbuffer.COLOR_BLACK
end

local function textWidget(text, face, color, max_w, bold)
    return TextWidget:new{ text = text, face = face, fgcolor = color or M.BLACK,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil, bold = bold and true or nil }
end

function M.textWidth(text, face, bold)
    local t = textWidget(text, face, nil, nil, bold == true)
    local w = t:getSize().w
    t:free()
    return w
end

--- Text vertically centred in a box of height h at x. Returns its width.
--- bold: true = KOReader bold; "synth" = draw twice, shifted (fonts without a bold file).
function M.drawText(bb, text, face, x, y, h, color, max_w, bold)
    local shift = 0
    if bold == "synth" then
        shift = math.max(1, math.floor((face.size or 20) / 30 + 0.5))
        if max_w then max_w = max_w - shift end
    end
    local t = textWidget(text, face, color, max_w, bold == true)
    local sz = t:getSize()
    local ty = y + math.floor((h - sz.h) / 2)
    t:paintTo(bb, x, ty)
    if shift > 0 then t:paintTo(bb, x + shift, ty) end
    t:free()
    return sz.w + shift
end

local icon_cache = {}

--- Paints an icon: a file under the plugin's icons/ ("x.svg", "line/x.svg"),
--- an absolute path, or a KOReader icon name ("chevron.left"). With `white`,
--- it is drawn white (for a cell filled black).
function M.paintIcon(bb, file, x, y, size, white, dim)
    local key = file .. "@" .. size
    local iw = icon_cache[key]
    if iw == nil then
        local args = { width = size, height = size, alpha = true, is_icon = true }
        if file:match("%.svg$") or file:match("%.png$") then
            args.file = file
        else
            args.file = nil
            local IconWidget = require("ui/widget/iconwidget")
            iw = IconWidget:new{ icon = file, width = size, height = size, alpha = true }
        end
        if not iw then iw = ImageWidget:new(args) end
        local ok = pcall(function() iw:_render() end)
        if not ok then iw = false end
        icon_cache[key] = iw
    end
    if not iw then return end
    if white or dim then
        -- draw it into a scratch buffer and use it as a mask
        local tmp = Blitbuffer.new(size, size, Blitbuffer.TYPE_BB8)
        tmp:fill(M.WHITE)
        iw:paintTo(tmp, 0, 0)
        local ink = white and M.WHITE or M.GRAY_9
        for yy = 0, size - 1 do
            for xx = 0, size - 1 do
                local v = tmp:getPixel(xx, yy):getColor8().a
                if v < 128 then bb:setPixel(x + xx, y + yy, ink) end
            end
        end
        tmp:free()
    else
        iw:paintTo(bb, x, y)
    end
end

--- The retro progress track. Returns the inner x and width.
function M.progressBar(bb, x, y, w, h, frac)
    return Look.track(bb, x, y, w, h, frac)
end

--- Side inset Bookshelf uses for its status line (so ours lines up with it).
function M.sidePad()
    local SL = try("lib/status_line")
    if SL and SL.sidePad then
        local ok, p = pcall(SL.sidePad, Screen:getWidth(), Size.padding.fullscreen)
        if ok and type(p) == "number" and p > 0 then return p end
    end
    return S(16)
end

return M
