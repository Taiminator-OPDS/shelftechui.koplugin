--[[
Shelf ornaments were removed in ShelfTechUI 1.3.1 (with Bookshelf's themes,
wallpapers and plank designs). This stand-in answers the shelf code that used
to ask about them: none are ever placed, so every shelf packs books only.
--]]
local Widget = require("ui/widget/widget")

local M = {}
M.FREQ_SETTING = "ornament_frequency"
M._defer = false

-- A placed piece never exists any more; an empty widget if one is asked for.
M.Ornament = Widget:extend{ placement = nil, night = false }
function M.Ornament:init()
    local pl = self.placement or {}
    self.dimen = require("ui/geometry"):new{ w = pl.w or 0, h = pl.h or 0 }
end
function M.Ornament:getSize() return self.dimen end
function M.Ornament:paintTo() end

local EMPTY = {}
function M.frequency() return 0 end
function M.setChipFrequency() end
function M.allowRecent() return true end
function M.beginDeferred() end
function M.endDeferred() end
function M.list() return EMPTY end
function M.listAll() return EMPTY end
function M.listFor() return EMPTY end
function M.pick() return nil end
function M.maxWidth() return 0 end
function M.contentBox() return nil end
function M.ensureTemplate() end
function M.dir() return nil end
function M.folderStamp() return "" end
function M.stampChanged() return false end
function M.invalidate() end
function M.dropRenders() end
function M.pngDirectives() return "" end
function M.unpremultiply() end
function M.hash(s)
    local h = 0
    for i = 1, #tostring(s) do h = (h * 31 + tostring(s):byte(i)) % 2147483647 end
    return h
end

return M
