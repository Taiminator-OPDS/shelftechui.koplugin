--[[
What the reading toolbar's book card knows about your reading.

  forecast(ui, page) -> { left_secs, days, day_text, short, long } or nil
      B1: when you'll finish at your pace ("Finish Thu · 2h 10m left"). The
      time left is this book's pages left x your time per page in it; the
      date comes from how long you read a day (all books, last 14 days).
  chapterPagesLeft(ui, page) -> n (this page included)
  alsoReading(ui, max) -> { { file, title, pct } ... }
      B5: other books you're part-way through, most recent first.
  switchTo(ui, file)
--]]

local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local M = {}

-- ---------------------------------------------------------------- pace

local pace_cache = { at = 0, secs = nil }

--- Seconds read a day, over the last 14 days (cached for 10 minutes).
function M.dailyPace(ui)
    local now = os.time()
    if pace_cache.at > now - 600 and pace_cache.secs ~= nil then return pace_cache.secs or nil end
    local secs = false
    local ok, err = pcall(function()
        local st = ui and ui.statistics
        if ui and not (st and st.settings and st.settings.is_enabled) then return end
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        if not lfs.attributes(DataStorage:getSettingsDir() .. "/statistics.sqlite3", "mode") then return end
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local since = now - 14 * 86400
        local row = conn:exec(string.format(
            "SELECT sum(duration), min(start_time) FROM page_stat_data WHERE start_time >= %d;", since))
        conn:close()
        local total = row and row[1] and tonumber(row[1][1]) or 0
        local first = row and row[2] and tonumber(row[2][1])
        -- this session, not saved yet
        for _p, list in pairs(st and st.page_stat or {}) do
            for _i, tuple in ipairs(list) do
                if tuple[2] and tuple[2] > 0 then total = total + tuple[2] end
            end
        end
        if total <= 0 then return end
        local days = 14
        if first then days = math.max(1, math.min(14, math.ceil((now - first) / 86400))) end
        secs = total / days
    end)
    if not ok then logger.warn("ShelfTechUI: reading pace failed:", err) end
    pace_cache = { at = now, secs = secs }
    return secs or nil
end

local function avgPerPage(ui)
    local st = ui and ui.statistics
    local avg = st and st.settings and st.settings.is_enabled and st.avg_time
    if not avg or avg ~= avg or avg <= 0 then return nil end
    return avg
end

--- "2h 10m" / "45m"
function M.hm(secs)
    local mins = math.max(1, math.floor(secs / 60 + 0.5))
    if mins < 60 then return T(_("%1m"), mins) end
    local h, m = math.floor(mins / 60), mins % 60
    if m == 0 then return T(_("%1h"), h) end
    return T(_("%1h %2m"), h, m)
end

local WEEKDAY_SHORT = { _("Sun"), _("Mon"), _("Tue"), _("Wed"), _("Thu"), _("Fri"), _("Sat") }
local WEEKDAY_LONG = { _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"), _("Thursday"), _("Friday"), _("Saturday") }

--- The finish line for `left` seconds of reading left.
function M.finish(left, ui)
    local f = { left_secs = left }
    local pace = M.dailyPace(ui)
    if pace and pace >= 60 then
        local days = math.max(0, math.ceil(left / pace) - 1)
        f.days = days
        local t = os.time() + days * 86400
        local wd = tonumber(os.date("%w", t)) + 1
        if days == 0 then f.day_short, f.day_long = _("today"), _("today")
        elseif days == 1 then f.day_short, f.day_long = _("tomorrow"), _("tomorrow")
        elseif days < 7 then f.day_short, f.day_long = WEEKDAY_SHORT[wd], WEEKDAY_LONG[wd]
        else
            local d = os.date("%d %b", t):gsub("^0", "")
            f.day_short, f.day_long = d, d
        end
    end
    if f.day_short then
        f.short = T(_("Finish %1 · %2 left"), f.day_short, M.hm(left))
        f.long = T(_("Finish %1, %2 left at your pace"), f.day_long, M.hm(left))
    else
        f.short = T(_("%1 left in book"), M.hm(left))
        f.long = f.short
    end
    return f
end

function M.forecast(ui, page)
    local doc = ui and ui.document
    if not doc then return nil end
    local avg = avgPerPage(ui)
    if not avg then return nil end
    local pages_left = doc:getTotalPagesLeft(page or ui:getCurrentPage())
    return M.finish(math.max(0, pages_left) * avg, ui)
end

--- The same for a book that isn't open, from the statistics database: your
--- time per page in it, its pages, how far you are (its sidecar).
function M.forecastFile(file)
    local f
    local ok, err = pcall(function()
        local DocSettings = require("docsettings")
        if not DocSettings:hasSidecarFile(file) then return end
        local ds = DocSettings:open(file)
        local pct = ds:readSetting("percent_finished")
        local summary = ds:readSetting("summary")
        if not pct or pct <= 0 or pct >= 0.995 or (summary and summary.status == "complete") then return end
        local DataStorage = require("datastorage")
        local lfs = require("libs/libkoreader-lfs")
        local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
        if not lfs.attributes(db, "mode") then return end
        local md5 = require("util").partialMD5(file)
        if not md5 then return end
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db)
        local stmt = conn:prepare("SELECT sum(min(p.duration, 120)), count(DISTINCT p.page), max(b.pages) "
            .. "FROM page_stat_data p JOIN book b ON b.id = p.id_book WHERE b.md5 = ?")
        local row = stmt:reset():bind(md5):step()
        stmt:close()
        conn:close()
        local secs, read, pages = tonumber(row and row[1]), tonumber(row and row[2]), tonumber(row and row[3])
        if not (secs and read and read > 0 and pages and pages > 0) then return end
        f = M.finish((1 - pct) * pages * secs / read)
        f.pct = pct
    end)
    if not ok then logger.warn("ShelfTechUI: forecast failed:", err) end
    return f
end

function M.chapterPagesLeft(ui, page)
    local toc = ui.toc
    local left = toc and toc:getChapterPagesLeft(page, true)
    if left == nil then left = ui.document:getTotalPagesLeft(page) end
    return left + 1
end

-- ---------------------------------------------------------------- also reading

local also = { key = nil, list = {} }

local function titleOf(file, ds)
    local props = ds and ds:readSetting("doc_props")
    local t = props and (props.display_title or props.title)
    if t and t ~= "" then return t end
    local name = file:match("([^/]+)$") or file
    return (name:gsub("%.[^.]+$", ""))
end

function M.alsoReading(ui, max)
    max = max or 3
    local current = ui and ui.document and ui.document.file
    local ok, err = pcall(function()
        local ReadHistory = require("readhistory")
        local hist = ReadHistory.hist or {}
        local key = (current or "") .. "|" .. tostring(hist[1] and hist[1].time) .. "|" .. #hist
        if also.key == key then return end
        local DocSettings = require("docsettings")
        local lfs = require("libs/libkoreader-lfs")
        local list = {}
        for i = 1, math.min(#hist, 20) do
            local e = hist[i]
            local file = e and e.file
            if file and file ~= current and lfs.attributes(file, "mode") == "file"
                    and DocSettings:hasSidecarFile(file) then
                local ds = DocSettings:open(file)
                local pct = ds:readSetting("percent_finished")
                local summary = ds:readSetting("summary")
                local status = summary and summary.status
                if pct and pct > 0 and pct < 0.995 and status ~= "complete" and status ~= "abandoned" then
                    table.insert(list, { file = file, title = titleOf(file, ds), pct = pct })
                end
                if ds.close then pcall(ds.close, ds) end
            end
            if #list >= 6 then break end
        end
        also = { key = key, list = list }
    end)
    if not ok then logger.warn("ShelfTechUI: also reading failed:", err) end
    local out = {}
    for i = 1, math.min(max, #also.list) do out[i] = also.list[i] end
    return out
end

-- ---------------------------------------------------------------- chapter ticks

local tick_cache = {}

--- Where the book's main chapters start: the top level of the table of
--- contents only (worked out once per book and page count, idea E4).
function M.majorTicks(ui)
    local doc = ui and ui.document
    if not doc then return {} end
    local n = doc:getPageCount()
    local key = tostring(doc.file) .. "#" .. n
    if tick_cache.key == key then return tick_cache.list end
    local list, last = {}, nil
    pcall(function()
        local ticks = ui.toc:getTocTicks(1) or {}
        for _i, p in ipairs(ticks) do
            if p ~= last and p > 1 and p <= n then table.insert(list, p) end
            last = p
        end
    end)
    tick_cache = { key = key, list = list }
    return list
end

--- The x positions of the ticks on a track (x0 .. x0+w over pages 1..n),
--- thinned so no two stand closer than `gap` pixels: a long table of
--- contents shows as an even rhythm, not a solid comb.
function M.tickXs(ui, x0, w, gap)
    local n = ui.document:getPageCount()
    -- never more than about a dozen along a track, however long the contents
    gap = math.max(gap or 0, math.floor(w / 12))
    local out, last = {}, nil
    for _i, p in ipairs(M.majorTicks(ui)) do
        local x = x0 + math.floor(w * (p - 1) / math.max(1, n - 1) + 0.5)
        if not last or x - last >= gap then
            if x0 + w - x >= gap / 2 then table.insert(out, { x = x, page = p }) end
            last = x
        end
    end
    return out
end

function M.switchTo(ui, file)
    if ui and ui.switchDocument then
        ui:switchDocument(file)
    else
        require("apps/reader/readerui"):showReader(file)
    end
end

return M
