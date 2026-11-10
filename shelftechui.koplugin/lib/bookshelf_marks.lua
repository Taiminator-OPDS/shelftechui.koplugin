--[[
Selection marks laid over a picker's cards: a radio mark (one choice of
many: the plank picker) and a checkbox (each on or off: the ornament
collection). Painted, not a font glyph, so they are the same size and weight
on every device, and each sits on a white ground so it reads over a picture.

  Marks.Radio:new{ checked = bool, size = px? }
  Marks.Check:new{ checked = bool, enabled = bool?, size = px? }
  Marks.size() -> the default size in px
]]
local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")

local Marks = {}

function Marks.size() return require("device").screen:scaleBySize(22) end

local function line(bb, x0, y0, x1, y1, t, c)
    local n = math.max(math.abs(x1 - x0), math.abs(y1 - y0), 1)
    for i = 0, n do
        local x = math.floor(x0 + (x1 - x0) * i / n - t / 2 + 0.5)
        local y = math.floor(y0 + (y1 - y0) * i / n - t / 2 + 0.5)
        bb:paintRect(x, y, t, t, c)
    end
end

local Radio = Widget:extend{ checked = false, size = nil }
function Radio:getSize()
    local s = self.size or Marks.size()
    return Geom:new{ w = s, h = s }
end
function Radio:paintTo(bb, x, y)
    local s = self:getSize().w
    self.dimen = Geom:new{ x = x, y = y, w = s, h = s }
    local r = math.floor(s / 2)
    local cx, cy = x + r, y + r
    local t = math.max(2, math.floor(s / 10))
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_WHITE)
    bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, t)
    if self.checked then
        bb:paintCircle(cx, cy, math.max(2, math.floor(r * 0.5)), Blitbuffer.COLOR_BLACK)
    end
end

local Check = Widget:extend{ checked = false, enabled = true, size = nil }
function Check:getSize()
    local s = self.size or Marks.size()
    return Geom:new{ w = s, h = s }
end
function Check:paintTo(bb, x, y)
    local s = self:getSize().w
    self.dimen = Geom:new{ x = x, y = y, w = s, h = s }
    local t = math.max(2, math.floor(s / 10))
    local c = self.enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY
    local radius = math.floor(s / 6)
    bb:paintRoundedRect(x, y, s, s, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(x, y, s, s, t, c, radius, true)
    if self.checked then
        local w = math.max(2, math.floor(s / 7))
        line(bb, x + s * 0.24, y + s * 0.52, x + s * 0.42, y + s * 0.70, w, c)
        line(bb, x + s * 0.42, y + s * 0.70, x + s * 0.76, y + s * 0.32, w, c)
    end
end

Marks.Radio, Marks.Check = Radio, Check
return Marks
