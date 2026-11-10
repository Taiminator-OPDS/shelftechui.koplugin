--[[
Insights (Aleph ideas C3 + D4): the second page of the reading summary you
pull down on home (swipe it sideways, or tap INSIGHTS).

  ┌ LAST 26 WEEKS ······························· 112 DAYS READ ┐
  │ ▢▤■▢■▤ … one square a day: blank, some (pinstripes), a lot   │
  └──────────────────────────────────────────────────────────────┘
  ┌ 2026 GOAL ─────────────┐ ┌ FINISH FORECAST ─┐
  │ 9 of 12 books   [■■■▤|] │ │ Thursday          │
  │ 1 behind pace · 7 wk   │ │ War of the Wor… 2h │
  └────────────────────────┘ └──────────────────┘
  ┌ WHEN YOU READ ··························· MOSTLY 9–11 PM ┐
  │ ▁▁▁▁▁▁▂▃▂▁▁▁▂▂▁▁▁▂▃▄▅██▄                                │
  └──────────────────────────────────────────────────────────┘
  [LONGEST STREAK 23 DAYS] [BEST DAY 3H 12M] [PAGES / HR 41]

From KOReader's reading statistics; the goal is Bookshelf's yearly reading
goal (its micro-module's setting).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Widget = require("ui/widget/widget")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local function withDB(fn)
    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    if not lfs.attributes(path, "mode") then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local conn = SQ3.open(path)
    local ok, res = pcall(fn, conn)
    conn:close()
    if not ok then logger.warn("ShelfTechUI: insights query failed:", res) return nil end
    return res
end

local function dayKey(t) return os.date("%Y-%m-%d", t) end

--- Everything the page shows (cached for 10 minutes).
local cache = { at = 0 }
function M.gather()
    if cache.data and os.time() - cache.at < 600 then return cache.data end
    local d = { days = {}, hours = {}, weeks = 26 }
    for h = 0, 23 do d.hours[h] = 0 end
    local now = os.time()
    withDB(function(conn)
        local since = now - (d.weeks * 7 + 7) * 86400
        local res = conn:exec(string.format([[SELECT strftime('%%Y-%%m-%%d', start_time, 'unixepoch', 'localtime'),
            sum(min(duration, 120)) FROM page_stat_data WHERE start_time >= %d GROUP BY 1;]], since))
        if res and res[1] then
            for i = 1, #res[1] do d.days[res[1][i]] = tonumber(res[2][i]) or 0 end
        end
        res = conn:exec(string.format([[SELECT CAST(strftime('%%H', start_time, 'unixepoch', 'localtime') AS INTEGER),
            sum(min(duration, 120)) FROM page_stat_data WHERE start_time >= %d GROUP BY 1;]], now - 90 * 86400))
        if res and res[1] then
            for i = 1, #res[1] do d.hours[tonumber(res[1][i]) or 0] = tonumber(res[2][i]) or 0 end
        end
        -- records, over everything
        res = conn:exec([[SELECT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') AS day,
            sum(min(duration, 120)) FROM page_stat_data GROUP BY day ORDER BY day;]])
        local best, streak, longest, prev = 0, 0, 0, nil
        if res and res[1] then
            for i = 1, #res[1] do
                local secs = tonumber(res[2][i]) or 0
                best = math.max(best, secs)
                local y, m, dd = res[1][i]:match("(%d+)-(%d+)-(%d+)")
                local t = os.time{ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }
                if prev and math.floor((t - prev) / 86400 + 0.5) == 1 then streak = streak + 1 else streak = 1 end
                longest = math.max(longest, streak)
                prev = t
            end
        end
        d.best_day, d.longest = best, longest
        local row = conn:exec(string.format("SELECT count(*), sum(min(duration, 120)) FROM page_stat_data WHERE start_time >= %d;",
            now - 90 * 86400))
        local pages, secs = tonumber(row and row[1] and row[1][1]), tonumber(row and row[2] and row[2][1])
        if pages and secs and secs > 600 then d.pages_hr = math.floor(pages / secs * 3600 + 0.5) end
    end)
    -- the year's goal: Bookshelf's yearly reading goal, books finished this year
    d.goal = 24
    pcall(function()
        local v = require("lib/bookshelf_settings_store").read("micromodule_reading_goal_yearly")
        if tonumber(v) then d.goal = tonumber(v) end
    end)
    d.done = 0
    pcall(function()
        local year = os.date("%Y")
        for _i, b in ipairs(require("bos_recs").library().books or {}) do
            if b.state == "finished" then
                local Repo = require("lib/bookshelf_book_repository")
                local on = Repo.finishedOn and Repo.finishedOn(b.filepath)
                if on and tostring(on):sub(1, 4) == year then d.done = d.done + 1 end
            end
        end
    end)
    -- the book you're on, and when you'll finish it
    pcall(function()
        for _i, e in ipairs(require("readhistory").hist or {}) do
            local f = require("bos_reading").forecastFile(e.file)
            if f then
                d.forecast = f
                d.forecast_title = (e.text or e.file:match("([^/]+)$") or ""):gsub("%.%w+$", "")
                break
            end
        end
    end)
    cache = { at = os.time(), data = d }
    return d
end

local Insights = Widget:extend{ width = nil }
M.Insights = Insights

function Insights:init()
    self.data = M.gather()
    local w = self.width - Look.SHADOW
    local cell = math.max(S(6), math.floor((w - S(20) - (self.data.weeks - 1) * S(2)) / self.data.weeks))
    local hm_h = S(30) + 7 * (cell + S(2)) + S(26)
    self.height = hm_h + S(108) + S(110) + 3 * (Look.SHADOW + S(14)) + S(58) + Look.SHADOW_SMALL
end

function Insights:getSize() return Geom:new{ w = self.width, h = self.height } end

local function boxTitle(bb, x, y, w, left, right)
    Look.label(bb, left, x + S(10), y + S(6), w - S(20), S(18), 9)
    if right then Look.label(bb, right, x + S(10), y + S(6), w - S(20), S(18), 9, { align = "right" }) end
end

function Insights:paintTo(bb, x, y)
    local d = self.data
    local w = self.width - Look.SHADOW
    local cy = y
    -- the heatmap
    local weeks = d.weeks
    local cell = math.max(S(6), math.floor((w - S(20) - (weeks - 1) * S(2)) / weeks))
    local hm_h = S(30) + 7 * (cell + S(2)) + S(26)
    Look.box(bb, x, cy, w, hm_h, { shadow = Look.SHADOW })
    local read_days = 0
    local now = os.time()
    local today_wd = tonumber(os.date("%w", now))
    local start = now - ((weeks - 1) * 7 + today_wd) * 86400
    local maxs = 1
    for _k, v in pairs(d.days) do maxs = math.max(maxs, v) end
    for wk = 0, weeks - 1 do
        for wd = 0, 6 do
            local t = start + (wk * 7 + wd) * 86400
            if t <= now then
                local secs = d.days[dayKey(t)] or 0
                local cx = x + S(10) + wk * (cell + S(2))
                local yy = cy + S(28) + wd * (cell + S(2))
                if secs > 0 then read_days = read_days + 1 end
                if secs >= math.max(1800, maxs * 0.45) then
                    bb:paintRect(cx, yy, cell, cell, BLACK)
                else
                    bb:paintRect(cx, yy, cell, cell, BLACK)
                    bb:paintRect(cx + 1, yy + 1, cell - 2, cell - 2, WHITE)
                    if secs > 0 then
                        for k = 0, cell - 3, 2 do bb:paintRect(cx + 1, yy + 1 + k, cell - 2, 1, BLACK) end
                    end
                end
            end
        end
    end
    boxTitle(bb, x, cy, w, T(_("Last %1 weeks"), weeks), T(require("gettext").ngettext("%1 day read", "%1 days read", read_days), read_days))
    -- legend
    local ly = cy + hm_h - S(22)
    local lx = x + S(10)
    lx = lx + Look.label(bb, _("Less"), lx, ly, S(60), S(16), 8) + S(8)
    for k = 1, 3 do
        local s = S(10)
        bb:paintRect(lx, ly + S(3), s, s, BLACK)
        if k < 3 then bb:paintRect(lx + 1, ly + S(3) + 1, s - 2, s - 2, WHITE) end
        if k == 2 then for j = 0, s - 3, 2 do bb:paintRect(lx + 1, ly + S(3) + 1 + j, s - 2, 1, BLACK) end end
        lx = lx + s + S(6)
    end
    Look.label(bb, _("More"), lx + S(2), ly, S(60), S(16), 8)
    cy = cy + hm_h + Look.SHADOW + S(14)

    -- the goal | the forecast
    local gh = S(108)
    local gw = math.floor((w - S(14)) * 0.56)
    Look.box(bb, x, cy, gw, gh, { shadow = Look.SHADOW })
    boxTitle(bb, x, cy, gw, T(_("%1 goal"), os.date("%Y")))
    local Page = require("bos_page")
    local big = tostring(d.done)
    local tw = require("ui/widget/textwidget"):new{ text = big, face = Page.serif(22, true) }
    tw:paintTo(bb, x + S(10), cy + S(28))
    local bw_ = tw:getSize().w
    tw:free()
    Look.label(bb, T(_("of %1 books"), d.goal), x + S(16) + bw_, cy + S(34), gw - bw_ - S(26), S(22), 11, { keep_case = true, bold = false })
    local by = cy + S(66)
    local barw = gw - S(20)
    local frac = math.min(1, d.done / math.max(1, d.goal))
    Look.slimTrack(bb, x + S(10), by, barw, S(14), frac)
    local yday = tonumber(os.date("%j"))
    local pace_mark = yday / 365
    local px = x + S(10) + Look.LINE + math.floor((barw - 2 * Look.LINE) * pace_mark)
    bb:paintRect(px, by - S(4), math.max(2, S(2)), S(22), BLACK)
    local due = math.floor(d.goal * pace_mark + 0.5)
    local weeks_left = math.max(0, math.ceil((365 - yday) / 7))
    local ahead = d.done - due
    local status = ahead >= 0 and T(_("%1 ahead of pace"), ahead) or T(_("%1 behind pace"), -ahead)
    Look.label(bb, T(_("%1 · %2 weeks left"), status, weeks_left), x + S(10), cy + gh - S(24), gw - S(20), S(18), 8,
        { color = Look.GRAY })
    local fx = x + gw + S(14)
    local fw = w - gw - S(14)
    Look.box(bb, fx, cy, fw, gh, { shadow = Look.SHADOW })
    boxTitle(bb, fx, cy, fw, _("Finish forecast"))
    if d.forecast and d.forecast.day_long then
        Page.wrap(bb, (d.forecast.day_long:gsub("^%l", string.upper)), Page.serif(18, true), fx + S(10), cy + S(30), fw - S(20), 1, S(28))
        Look.label(bb, T("%1 · %2", d.forecast_title or "", require("bos_reading").hm(d.forecast.left_secs)),
            fx + S(10), cy + gh - S(30), fw - S(20), S(20), 8, { color = Look.GRAY })
    else
        Look.label(bb, _("Read a little more to see it."), fx + S(10), cy + S(34), fw - S(20), S(40), 9, { color = Look.GRAY })
    end
    cy = cy + gh + Look.SHADOW + S(14)

    -- when you read
    local hh = S(110)
    Look.box(bb, x, cy, w, hh, { shadow = Look.SHADOW })
    local maxh, peak = 0, 0
    for h = 0, 23 do if d.hours[h] > maxh then maxh, peak = d.hours[h], h end end
    local mostly
    if maxh > 0 then
        local function fmt(h)
            local t = os.time{ year = 2000, month = 1, day = 1, hour = h }
            return require("datetime").secondsToHour(t, G_reader_settings:isTrue("twelve_hour_clock"))
        end
        mostly = T(_("Mostly %1–%2"), fmt(peak), fmt((peak + 2) % 24))
    end
    boxTitle(bb, x, cy, w, _("When you read"), mostly)
    local chart_y, chart_h = cy + S(30), S(48)
    local slot = (w - S(20)) / 24
    for h = 0, 23 do
        local bh2 = maxh > 0 and math.max(S(2), math.floor(chart_h * d.hours[h] / maxh)) or S(2)
        bb:paintRect(x + S(10) + math.floor(h * slot), chart_y + chart_h - bh2, math.max(2, math.floor(slot) - S(2)), bh2, BLACK)
    end
    for _i, l in ipairs{ { 0, "12a" }, { 6, "6a" }, { 12, "12p" }, { 18, "6p" } } do
        Look.label(bb, l[2], x + S(10) + math.floor(l[1] * slot), chart_y + chart_h + S(4), S(40), S(16), 8)
    end
    cy = cy + hh + Look.SHADOW + S(14)

    -- records
    local rw = math.floor((w - 2 * S(12)) / 3)
    local recs = {
        { _("Longest streak"), T(require("gettext").ngettext("%1 day", "%1 days", d.longest or 0), d.longest or 0) },
        { _("Best day"), d.best_day and d.best_day > 0 and require("bos_reading").hm(d.best_day) or "–" },
        { _("Pages / hr"), d.pages_hr and tostring(d.pages_hr) or "–" },
    }
    for i, r in ipairs(recs) do
        local rx = x + (i - 1) * (rw + S(12))
        Look.box(bb, rx, cy, rw, S(58), { shadow = Look.SHADOW_SMALL })
        Look.label(bb, r[1], rx + S(8), cy + S(6), rw - S(16), S(16), 8)
        local t = require("ui/widget/textwidget"):new{ text = r[2], face = Page.serif(16, true), max_width = rw - S(16) }
        t:paintTo(bb, rx + S(8), cy + S(26))
        t:free()
    end
end

return M
