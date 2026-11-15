--[[
Bookshelf home: the ShelfTechUI status bar across the top of the shelf.

The shelf makes room for it: Bookshelf's footer reserve grows by the bar's
height (so covers, lists and pagination all still fit), and the bar is placed
at the head of the shelf's main column. Installed once, from the plugin, into
Bookshelf's widget class; if this Bookshelf version has none of the hooks it
needs, it logs a warning and leaves Bookshelf alone.
--]]

local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")

local Home = { live = nil, h = 0, installed = false }

local function enabled()
    return require("bos_settings_store").get("home_status_bar") ~= false
end

--- The status bar at the shelf's width, inset by Bookshelf's own side margin.
local function buildBar(self)
    local pad
    pcall(function() pad = self:_layoutPrimitives() end)
    pad = pad or 12
    local chips = require("bos_controls").shown("home")
    if #chips == 0 then return nil end
    local StatusBar = require("bos_statusbar")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local bar = StatusBar:new{ width = self.width - 2 * pad, chips = chips }
    Home.bar = bar
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = math.floor(pad * 0.75) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, bar },
    }
end

function Home.install()
    if Home.installed then return true end
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" then return false end
    if BW._bos_home then Home.installed = true return true end

    -- 1. grow the footer reserve by the bar's height. _footerReserveH is a
    --    file-local function shared (as an upvalue) by the layout and every
    --    row-count helper, so replacing it once reaches all of them.
    local found_fn, found_idx, orig_reserve
    for _name, fn in pairs(BW) do
        if type(fn) == "function" then
            for i = 1, 255 do
                local n, v = debug.getupvalue(fn, i)
                if not n then break end
                if n == "_footerReserveH" and type(v) == "function" then
                    found_fn, found_idx, orig_reserve = fn, i, v
                    break
                end
            end
        end
        if found_fn then break end
    end
    if not (found_fn and type(BW._rebuild) == "function" and type(BW._buildFooterRow) == "function") then
        logger.warn("ShelfTechUI: this Bookshelf version can't host the status bar; leaving it alone")
        return false
    end
    BW._bos_home = true
    Home.installed = true
    debug.setupvalue(found_fn, found_idx, function()
        return orig_reserve() + (Home.h or 0)
    end)

    -- 2. measure the bar before each full rebuild, then put it at the head
    --    of the shelf's main column (everything below shifts down)
    local orig_rebuild = BW._rebuild
    BW._rebuild = function(self, ...)
        Home.live = self
        Home.h = 0
        Home.bar, Home.above = nil, nil
        local bar
        if enabled() then
            local okB, b = pcall(buildBar, self)
            if okB then bar = b else logger.warn("ShelfTechUI: status bar failed:", b) end
            if bar then Home.h = bar:getSize().h end
        end
        local res = table.pack(orig_rebuild(self, ...))
        if bar and Home.h > 0 then
            local placed = pcall(function()
                local d = self._shelf_dims
                local og = self._overlap_group
                local main_frame = d and og and og[d.footer_overlap_idx - 1]
                local column = main_frame and main_frame[1]
                local first = column and column[1]
                -- main_frame = FrameContainer{ VerticalGroup{ VerticalSpan(PAD), inner_content } }
                if not (first and first.width and not first[1]) then error("layout") end
                column[1] = VerticalGroup:new{ align = "left", bar, VerticalSpan:new{ width = first.width } }
                column:resetLayout()
                -- the page-turn refresh region starts below the bar now
                if d.wipe_rows_top then d.wipe_rows_top = d.wipe_rows_top + Home.h end
            end)
            if not placed then
                Home.h = 0
                if bar.free then pcall(bar.free, bar) end
            end
        end
        Home.watch()
        return unpack(res, 1, res.n)
    end

    -- the footer's tinted panel (wallpaper) must not grow by the bar's height
    if type(BW._footerPanelRectRaw) == "function" then
        local orig_panel = BW._footerPanelRectRaw
        BW._footerPanelRectRaw = function(self, ...)
            local r = table.pack(orig_panel(self, ...))
            local bh = Home.h or 0
            if bh > 0 and r[2] and r[4] then
                r[2] = r[2] + bh
                r[4] = math.max(1, r[4] - bh)
            end
            return unpack(r, 1, r.n)
        end
    end

    -- the shelf rows' last gap is measured from the footer's icons, which the
    -- layout finds half way down the (now taller) reserve: take the bar's
    -- share back out, or the last row's titles run under the footer keys
    pcall(function()
        local GridMargins = require("lib/bookshelf_grid_margins")
        local orig_split = GridMargins.split
        GridMargins.split = function(o)
            local bh = Home.h or 0
            if bh > 0 and type(o) == "table" and (o.foot_offset or 0) > 0 then
                o.foot_offset = math.max(0, o.foot_offset - math.ceil(bh / 2))
            end
            return orig_split(o)
        end
    end)

    -- the shelf paints only what's dirty: when a window over it closes, the
    -- bar's strip is often left as it was. So after the shelf paints, the
    -- bar is asked whether it still says what's true (once per burst of paints)
    if type(BW.paintTo) == "function" then
        local orig_paint = BW.paintTo
        BW.paintTo = function(self, ...)
            local res = table.pack(orig_paint(self, ...))
            if self == Home.live then Home.painted() end
            return unpack(res, 1, res.n)
        end
    end

    -- the footer row itself keeps its own height
    local orig_footer = BW._buildFooterRow
    BW._buildFooterRow = function(self, content_w, total_pages, footer_h)
        return orig_footer(self, content_w, total_pages, footer_h - (Home.h or 0))
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The bar keeps up: the time each minute, the battery as it changes, and
-- charging, Wi-Fi and the light when the device says so (Home.poke, from the
-- plugin's event handlers). Nothing is painted unless what a chip shows has
-- changed, and never under another window.
-- ---------------------------------------------------------------------------

local function shelfOnStack()
    for _i, win in ipairs(UIManager._window_stack or {}) do
        if win.widget == Home.live then return true end
    end
    return false
end

--- Paint the bar again if what it shows has changed.
function Home.sync()
    local bar, shelf = Home.bar, Home.live
    if not (bar and shelf and bar.dimen and bar.dimen.x) then return end
    if not bar:onTop() then return end
    local ok, sig = pcall(bar.signature, bar)
    if not ok then return end
    -- (Dash has a line of its own above the bar: the time and the battery)
    local above = false
    if Home.above then
        local okA, v = pcall(Home.above)
        above = okA and v or false
    end
    if sig == bar._sig and not above then Home.tried = nil return end
    -- (asked for once per change: if the shelf isn't painting just now, it
    -- isn't asked again and again)
    local what = sig .. (above and os.date("%H%M") or "")
    if Home.tried == what then return end
    Home.tried = what
    if above then
        local Geom = require("ui/geometry")
        UIManager:setDirty(shelf, "ui", Geom:new{ x = 0, y = 0, w = shelf.width, h = bar.dimen.y + bar.dimen.h })
        return
    end
    -- the whole shelf is painted (the chips may have moved: what's behind
    -- them is drawn again), only the bar's strip of the screen is refreshed
    UIManager:setDirty(shelf, "ui", bar.dimen)
end

--- The shelf was just painted: soon, see that the bar is still right.
function Home.painted()
    if not Home.bar or Home.checking then return end
    Home.checking = true
    UIManager:scheduleIn(0.3, function()
        Home.checking = false
        Home.sync()
    end)
end

local function minute()
    if not (Home.bar and shelfOnStack()) then Home.ticking = false return end
    Home.sync()
    UIManager:scheduleIn(61 - os.time() % 60, minute)
end

--- Start the minute's tick (once; it stops by itself when home is closed).
function Home.watch()
    if not Home.bar then return end
    UIManager:unschedule(minute)
    Home.ticking = true
    UIManager:scheduleIn(61 - os.time() % 60, minute)
end

--- Something changed (charging, Wi-Fi, the light, waking up): look now, and
--- once more when the device has settled.
function Home.poke()
    if not Home.bar then return end
    pcall(function() require("bos_status").invalidate() end)
    UIManager:unschedule(Home.sync)
    UIManager:scheduleIn(0.3, Home.sync)
    UIManager:scheduleIn(2.5, function() Home.sync() end)
    if not Home.ticking then Home.watch() end
end

--- Rebuild the live shelf (after the bar's setting changes).
function Home.refresh()
    for _i, win in ipairs(UIManager._window_stack or {}) do
        local w = win.widget
        -- the shelf on screen (also one Bookshelf built before we were installed)
        if w and (w == Home.live or (w._shelf_dims and type(w._rebuild) == "function")) then
            local okR, err = pcall(function() w:_rebuild() end)
            if not okR then logger.warn("ShelfTechUI: shelf rebuild failed:", err) end
            UIManager:setDirty(w, "ui")
            return
        end
    end
end

return Home
