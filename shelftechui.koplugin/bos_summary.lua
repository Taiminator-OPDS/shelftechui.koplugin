--[[
The reading summary (Bookshelf home): swipe down from the top of the shelf.

    6:42 PM                                   82%  ⌔     ← Bookshelf's status line
    42 min        5 h 10        6 days        12
    TODAY         LAST 7 DAYS   STREAK        BOOKS THIS YEAR
    RECENT
    ┌────┐ ┌────┐ ┌────┐ ┌────┐
    │    │ │    │ │    │ │    │      ← tap a cover to open the book
    │3h12│ │ 48m│ │5h02│ │1h30│      ← time spent reading it
    └────┘ └────┘ └────┘ └────┘
    ─────────────────────────────
    Reading calendar                    ›

Figures come from KOReader's reading statistics (statistics.sqlite3), read
only; covers from Bookshelf (or KOReader's cover browser). Tap outside it,
swipe up, or press Back to close.
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Store = require("bos_settings_store")
local UI = require("bos_ui")
local S, BLACK, WHITE = UI.S, UI.BLACK, UI.WHITE
local Screen = Device.screen

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- ---------------------------------------------------------------------------
-- Figures (KOReader's statistics database, read-only)
-- ---------------------------------------------------------------------------

local function withDB(fn)
    local DataStorage = require("datastorage")
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local ok_o, conn = pcall(SQ3.open, path, "ro")
    if not ok_o or not conn then return nil end
    local ok, res = pcall(function()
        conn:exec("PRAGMA busy_timeout=200;")
        return fn(conn)
    end)
    conn:close()
    if not ok then logger.warn("ShelfTechUI: statistics query failed:", res) return nil end
    return res
end

local function maxSec()
    local stats = G_reader_settings:readSetting("statistics")
    return (stats and stats.max_sec) or 120
end

local function dayStart(t)
    local d = os.date("*t", t)
    return os.time({ year = d.year, month = d.month, day = d.day, hour = 0, min = 0, sec = 0 })
end

--- Seconds read since `since` (each page capped, as KOReader counts it).
local function secondsSince(conn, since)
    local stmt = conn:prepare("SELECT sum(min(duration, ?)) FROM page_stat_data WHERE start_time >= ?")
    local row = stmt:reset():bind(maxSec(), since):step()
    stmt:close()
    return tonumber(row and row[1]) or 0
end

local function figures()
    return withDB(function(conn)
        local now = os.time()
        local today = dayStart(now)
        local f = {}
        f.today = secondsSince(conn, today)
        f.week = secondsSince(conn, today - 6 * 86400)
        -- streak: consecutive days with some reading, ending today (or
        -- yesterday, so the morning doesn't break it)
        local days = {}
        local stmt = conn:prepare("SELECT DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') "
            .. "FROM page_stat_data WHERE start_time >= ?")
        local row = stmt:reset():bind(today - 400 * 86400):step()
        while row do
            days[row[1]] = true
            row = stmt:step()
        end
        stmt:close()
        local streak, t = 0, now
        if not days[os.date("%Y-%m-%d", t)] then t = t - 86400 end
        while days[os.date("%Y-%m-%d", t)] do
            streak = streak + 1
            t = t - 86400
        end
        f.streak = streak
        local y = os.date("*t", now)
        local year_start = os.time({ year = y.year, month = 1, day = 1, hour = 0 })
        stmt = conn:prepare("SELECT count(DISTINCT id_book) FROM page_stat_data WHERE start_time >= ?")
        row = stmt:reset():bind(year_start):step()
        stmt:close()
        f.books_year = tonumber(row and row[1]) or 0
        return f
    end)
end

--- Seconds spent reading one book (by KOReader's partial md5).
local function bookSeconds(conn, file)
    local util = require("util")
    local md5 = util.partialMD5(file)
    if not md5 then return nil end
    local stmt = conn:prepare("SELECT sum(min(p.duration, ?)) FROM page_stat_data p "
        .. "JOIN book b ON b.id = p.id_book WHERE b.md5 = ?")
    local row = stmt:reset():bind(maxSec(), md5):step()
    stmt:close()
    return tonumber(row and row[1])
end

local function duration(sec, short)
    sec = sec or 0
    local m = math.floor(sec / 60 + 0.5)
    if m < 60 then return T(short and _("%1m") or _("%1 min"), m) end
    local h = math.floor(m / 60)
    m = m % 60
    if short then return T(_("%1h%2"), h, string.format("%02d", m)) end
    return m > 0 and T(_("%1 h %2"), h, string.format("%02d", m)) or T(_("%1 h"), h)
end

-- ---------------------------------------------------------------------------
-- Recent books
-- ---------------------------------------------------------------------------

local function recentFiles(n)
    local out = {}
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok then return out end
    pcall(function() ReadHistory:reload() end)
    local lfs = require("libs/libkoreader-lfs")
    for _i, e in ipairs(ReadHistory.hist or {}) do
        if #out >= n then break end
        if e.file and not e.dim and lfs.attributes(e.file, "mode") == "file" then
            table.insert(out, { file = e.file, title = e.text })
        end
    end
    return out
end

local function coverBB(file)
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    if okR and Repo and Repo.getCoverBB then
        local ok, bb = pcall(Repo.getCoverBB, file)
        if ok and bb then return bb end
    end
    local okB, BIM = pcall(require, "bookinfomanager")
    if okB and BIM then
        local ok, info = pcall(BIM.getBookInfo, BIM, file, true)
        if ok and info and info.cover_bb and not info.ignore_cover then return info.cover_bb end
    end
end

local function titleOf(entry)
    local title = entry.title or entry.file:match("([^/]+)$") or ""
    return (title:gsub("%.%w+$", ""))
end

--- A row of covers with a time-read badge on each.
local Shelf = InputContainer:extend{ width = nil, books = nil, on_open = nil }

function Shelf:init()
    self.gap = S(14)
    self.n = Store.get("summary_books") or 4
    self.cover_w = math.floor((self.width - S(4) - (self.n - 1) * self.gap) / self.n)
    self.cover_h = math.floor(self.cover_w * 1.5)
    self.title_h = S(24)
    self.height = self.cover_h + S(6) + self.title_h
    self.f_badge, self.badge_bold = UI.boldFace(12)
    self.f_title = UI.face(13)
    self.f_cover, self.cover_bold = UI.boldFace(14)
    self.badges = Store.get("summary_badges") ~= false
    local range = function() return self.dimen end
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapCover = { GestureRange:new{ ges = "tap", range = range } } }
end

function Shelf:getSize() return Geom:new{ w = self.width, h = self.height } end

function Shelf:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local w, h = self.cover_w, self.cover_h
    for i, b in ipairs(self.books) do
        local cx = x + (i - 1) * (w + self.gap)
        -- Bookshelf's cover look: an outline and a hard shadow
        bb:paintRect(cx + S(4), y + S(4), w, h, UI.shadowGray())
        local cover = b.cover
        if cover then
            local ok = pcall(function()
                local scaled = cover:scale(w, h)
                bb:blitFrom(scaled, cx, y, 0, 0, w, h)
                scaled:free()
            end)
            if not ok then cover = nil end
        end
        if not cover then
            -- no cover: a plain grey card with the title on it, as Bookshelf does
            local grey = require("ffi/blitbuffer").COLOR_GRAY_E
            bb:paintRect(cx, y, w, h, grey)
            local TextBoxWidget = require("ui/widget/textboxwidget")
            local tb = TextBoxWidget:new{ text = titleOf(b), face = self.f_cover, bold = self.cover_bold,
                width = w - S(16), alignment = "center", bgcolor = grey }
            local th = math.min(tb:getSize().h, h - S(44))
            tb:paintTo(bb, cx + S(8), y + math.floor((h - S(30) - th) / 2))
            tb:free()
        end
        -- outline
        local t = UI.line()
        bb:paintRect(cx, y, w, t, BLACK); bb:paintRect(cx, y + h - t, w, t, BLACK)
        bb:paintRect(cx, y, t, h, BLACK); bb:paintRect(cx + w - t, y, t, h, BLACK)
        -- time-read badge
        if self.badges and b.seconds and b.seconds > 0 then
            -- a square black tag in the corner, mono
            local Look = require("bos_look")
            local text = duration(b.seconds, true)
            local tw = Look.textWidth(require("bos_look").case(text), 11)
            local bw, bh = tw + S(12), S(20)
            local bx, by = cx + w - bw - S(6), y + h - bh - S(6)
            Look.box(bb, bx, by, bw, bh, { fill = BLACK, border = 0 })
            Look.label(bb, text, bx, by, bw, bh, 11, { align = "center", color = WHITE })
        end
        if cover then
            UI.drawText(bb, titleOf(b), self.f_title, cx, y + h + S(6), self.title_h, BLACK, w)
        end
        b._rect = Geom:new{ x = cx, y = y, w = w, h = self.height }
    end
end

function Shelf:onTapCover(_, ges)
    for _i, b in ipairs(self.books) do
        if inside(ges.pos, b._rect) then
            if self.on_open then self.on_open(b.file) end
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The figures row
-- ---------------------------------------------------------------------------

local Figures = require("ui/widget/widget"):extend{ width = nil, items = nil }

function Figures:init()
    self.height = S(64)
    self.f_num, self.num_bold = UI.boldFace(22)
    self.f_label, self.label_bold = UI.boldFace(10)
end

function Figures:getSize() return Geom:new{ w = self.width, h = self.height } end

function Figures:paintTo(bb, x, y)
    -- four square read-outs on hard shadows: the figure, and what it is
    local Look = require("bos_look")
    local n = #self.items
    local gap = S(10)
    local sh = Look.SHADOW_SMALL
    local cw = math.floor((self.width - sh - (n - 1) * gap) / n)
    local bh = self.height - sh - S(2)
    for i, it in ipairs(self.items) do
        local cx = x + (i - 1) * (cw + gap)
        Look.box(bb, cx, y, cw, bh, { shadow = sh })
        Look.label(bb, it.value, cx + S(6), y + S(4), cw - S(12), S(32), 19, { align = "center" })
        Look.label(bb, it.label, cx + S(4), y + S(34), cw - S(8), S(20), 9,
            { align = "center", color = Look.GRAY })
    end
end

-- ---------------------------------------------------------------------------
-- TODAY | INSIGHTS
-- ---------------------------------------------------------------------------

local Tabs = require("ui/widget/widget"):extend{ width = nil, page = 1, panel = nil }

function Tabs:getSize() return Geom:new{ w = self.width, h = S(40) } end

function Tabs:paintTo(bb, x, y)
    local Look = require("bos_look")
    local w = math.min(S(260), self.width)
    local tx = x + math.floor((self.width - w) / 2)
    local cells = { { key = 1, text = _("Today") }, { key = 2, text = _("Insights") } }
    local rects = Look.segments(bb, tx, y + S(4), w, S(30), cells, self.page)
    self.panel.tab_rects = rects
end

-- ---------------------------------------------------------------------------
-- The panel
-- ---------------------------------------------------------------------------

local Summary = InputContainer:extend{
    name = "bookshelfos_summary",
    covers_header = true,
}

function Summary:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.pad = UI.sidePad()
    self.shadow = S(3)
    local w = W - 2 * self.pad
    local rows = VerticalGroup:new{ align = "left" }
    table.insert(rows, VerticalSpan:new{ width = self.pad })
    local status = UI.buildStatusRow(w)
    if status then
        table.insert(rows, status)
        table.insert(rows, VerticalSpan:new{ width = S(14) })
    end

    local insights_on = Store.get("summary_insights") ~= false
    if insights_on then
        table.insert(rows, Tabs:new{ width = w, page = 1, panel = self })
        table.insert(rows, VerticalSpan:new{ width = S(10) })
    end

    if Store.get("summary_stats") ~= false then
        local f = figures()
        if f then
            table.insert(rows, Figures:new{ width = w, items = {
                { value = duration(f.today), label = _("Today") },
                { value = duration(f.week), label = _("Last 7 days") },
                { value = T(f.streak == 1 and _("%1 day") or _("%1 days"), f.streak), label = _("Streak") },
                { value = tostring(f.books_year), label = _("Books this year") },
            } })
        else
            table.insert(rows, UI.InfoRow:new{ width = w,
                text = _("Reading statistics are off: turn them on in Tools → Reading statistics.") })
        end
        table.insert(rows, VerticalSpan:new{ width = S(8) })
    end

    local n = Store.get("summary_books") or 4
    local books = recentFiles(n)
    -- B1: when the book you're on will be finished, at your pace
    for _i, b in ipairs(books) do
        local fc = require("bos_reading").forecastFile(b.file)
        if fc then
            if fc.day_short then
                table.insert(rows, UI.InfoRow:new{ width = w, text = T("%1 · %2", titleOf(b), fc.long) })
                table.insert(rows, VerticalSpan:new{ width = S(6) })
            end
            break
        end
    end
    if #books > 0 then
        withDB(function(conn)
            for _i, b in ipairs(books) do
                local ok, sec = pcall(bookSeconds, conn, b.file)
                b.seconds = ok and sec or nil
            end
        end)
        for _i, b in ipairs(books) do b.cover = coverBB(b.file) end
        table.insert(rows, UI.MenuTitle:new{ width = w, text = _("Recent") })
        table.insert(rows, VerticalSpan:new{ width = S(4) })
        local panel = self
        table.insert(rows, Shelf:new{ width = w, books = books, on_open = function(file)
            panel:closeThen(function() panel.openBook(file) end)
        end })
        table.insert(rows, VerticalSpan:new{ width = S(6) })
    end
    table.insert(rows, VerticalSpan:new{ width = S(8) })
    table.insert(rows, UI.ButtonRow:new{ width = w, menu = self, text = _("Reading calendar"),
        callback = function() UIManager:broadcastEvent(Event:new("ShowCalendarView")) end })
    table.insert(rows, VerticalSpan:new{ width = S(10) })
    self.rows = rows
    self[1] = rows
    self.pages = { rows }
    self.page_i = 1
    if insights_on then
        -- page 2: Insights (built when first shown)
        self.make_insights = function()
            local g = VerticalGroup:new{ align = "left" }
            table.insert(g, VerticalSpan:new{ width = self.pad })
            local st = UI.buildStatusRow(w)
            if st then
                table.insert(g, st)
                table.insert(g, VerticalSpan:new{ width = S(14) })
            end
            table.insert(g, Tabs:new{ width = w, page = 2, panel = self })
            table.insert(g, VerticalSpan:new{ width = S(12) })
            table.insert(g, require("bos_insights").Insights:new{ width = w })
            table.insert(g, VerticalSpan:new{ width = S(16) })
            return g
        end
    end
    self.panel_h = rows:getSize().h
    self.panel = Geom:new{ x = 0, y = 0, w = W, h = self.panel_h }
    local range = function() return self.dimen end
    self.ges_events = {
        SumTap = { GestureRange:new{ ges = "tap", range = range } },
        SumSwipe = { GestureRange:new{ ges = "swipe", range = range } },
        SumHold = { GestureRange:new{ ges = "hold", range = range } },
    }
    if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
end

function Summary.openBook(file)
    require("bos_shelf").open(file)
end

function Summary:region()
    return Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h + UI.line() + self.shadow }
end

function Summary:paintTo(bb, x, y)
    local W = self.dimen.w
    bb:paintRect(0, 0, W, self.panel_h, WHITE)
    self.rows:paintTo(bb, self.pad, 0)
    bb:paintRect(0, self.panel_h, W, UI.line(), BLACK)
    bb:paintRect(0, self.panel_h + UI.line(), W, self.shadow, UI.shadowGray())
end

function Summary:onShow()
    UIManager:setDirty(self, function() return "ui", self:region() end)
    return true
end

function Summary:onCloseWidget()
    local r = self:region()
    UIManager:setDirty(nil, function() return "ui", r end)
    if Summary.live == self then Summary.live = nil end
end

function Summary:closeThen(fn)
    UIManager:close(self)
    UIManager:nextTick(function()
        pcall(function() UIManager:forceRePaint() end)
        local ok, err = pcall(fn)
        if not ok then logger.warn("ShelfTechUI: summary action failed:", err) end
    end)
end

--- TODAY ⇄ INSIGHTS
function Summary:showPage(i)
    if i == self.page_i or not self.make_insights then return end
    local old = self:region()
    if i == 2 and not self.pages[2] then self.pages[2] = self.make_insights() end
    if not self.pages[i] then return end
    self.page_i = i
    self.rows = self.pages[i]
    self[1] = self.rows
    self.panel_h = self.rows:getSize().h
    self.panel = Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.panel_h }
    -- Everything under the panel is drawn again (not just the screen
    -- refreshed: with a nil widget nothing repaints, and Insights, the
    -- longer page, stayed on screen below Today), then one full refresh
    -- clears the e-ink ghost of the other page.
    UIManager:setDirty("all", "full")
end

function Summary:onSumTap(_, ges)
    for key, r in pairs(self.tab_rects or {}) do
        if inside(ges.pos, r) then self:showPage(key) return true end
    end
    if not inside(ges.pos, self.panel) then UIManager:close(self) end
    return true
end

function Summary:onSumSwipe(_, ges)
    if inside(ges.pos, self.panel) and (ges.direction == "west" or ges.direction == "east") and self.make_insights then
        self:showPage(ges.direction == "west" and 2 or 1)
        return true
    end
    if ges.direction == "north" or not inside(ges.pos, self.panel) then UIManager:close(self) end
    return true
end

function Summary:onSumHold() return true end
function Summary:onClose() UIManager:close(self) return true end

--- Seconds read on each of the last n days, oldest first: { { t, secs } }.
local function days(n)
    return withDB(function(conn)
        local out = {}
        local today = dayStart(os.time())
        local stmt = conn:prepare("SELECT sum(min(duration, ?)) FROM page_stat_data WHERE start_time >= ? AND start_time < ?")
        for i = n - 1, 0, -1 do
            local t0 = today - i * 86400
            local row = stmt:reset():bind(maxSec(), t0, t0 + 86400):step()
            table.insert(out, { t = t0, secs = tonumber(row and row[1]) or 0 })
        end
        stmt:close()
        return out
    end)
end

local M = { Panel = Summary, figures = figures, days = days, duration = duration }

function M.show()
    if Summary.live then
        UIManager:close(Summary.live)
        return
    end
    local panel = Summary:new{}
    Summary.live = panel
    UIManager:show(panel)
    return panel
end

return M
