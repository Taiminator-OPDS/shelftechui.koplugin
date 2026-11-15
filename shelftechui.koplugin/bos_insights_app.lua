--[[
Insights: your reading in numbers, as an app of its own (it used to be a tab
of the summary you pull down on home; that panel's key opens this now).

  [ME ▾]                                        [CALENDAR]
  ── On this device ────────────────────────────────────
  the heat map, the goal, the forecast, when you read, records
  (bos_insights: from KOReader's reading statistics)
  ── On Hardcover ─────────────────────────────────────
  books and pages, this year, the average of your ratings, the year month
  by month, the last years, your ratings, the authors you read most

[ME ▾] is a list: you, then the readers you follow on Hardcover. Picking one
shows their figures from Hardcover (a reader's device statistics are theirs
alone, so a friend's page has the Hardcover half only).

  M.open(who)     who: nil (you) or { id, name } (a reader you follow)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local Page = require("bos_page")
local UI = require("bos_ui")
local Screen = Device.screen
local S = Look.S
local BLACK = Blitbuffer.COLOR_BLACK

local M = {}

local function HC() return require("bos_hardcover") end

local function thousands(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function tile(bb, x, y, w, h, label, value, sub)
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW_SMALL })
    Look.label(bb, label, x + S(8), y + S(6), w - S(16), S(16), 8)
    local t = require("ui/widget/textwidget"):new{ text = value, face = Page.serif(18, true), max_width = w - S(16) }
    t:paintTo(bb, x + S(8), y + S(24))
    t:free()
    if sub then Look.label(bb, sub, x + S(8), y + h - S(22), w - S(16), S(16), 8, { color = Look.GRAY }) end
end

--- Bars with a label under each: values { { label, n } }.
local function bars(bb, x, y, w, h, values, title, right)
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW })
    Look.label(bb, title, x + S(10), y + S(6), w - S(20), S(18), 9)
    if right then Look.label(bb, right, x + S(10), y + S(6), w - S(20), S(18), 9, { align = "right" }) end
    local n = #values
    if n == 0 then return end
    local max = 1
    for _i, v in ipairs(values) do max = math.max(max, v[2]) end
    local cy, chart_h = y + S(30), h - S(30) - S(26)
    local slot = (w - S(20)) / n
    local bw = math.max(S(4), math.floor(slot * 0.62))
    for i, v in ipairs(values) do
        local bh = v[2] > 0 and math.max(S(3), math.floor(chart_h * v[2] / max)) or math.max(1, S(1))
        local bx = x + S(10) + math.floor((i - 1) * slot + (slot - bw) / 2)
        bb:paintRect(bx, cy + chart_h - bh, bw, bh, BLACK)
        if v[2] > 0 and slot >= S(26) then
            Look.label(bb, tostring(v[2]), bx - S(10), cy + chart_h - bh - S(16), bw + S(20), S(14), 7, { align = "center", color = Look.GRAY })
        end
        Look.label(bb, v[1], x + S(10) + math.floor((i - 1) * slot), cy + chart_h + S(5), math.floor(slot), S(16), 7, { align = "center" })
    end
end

--- The Hardcover half: figures `st` (bos_hardcover.stats), in the room from
--- y to bottom. Returns nothing; draws as much as fits.
local function drawHardcover(bb, x, y, w, bottom, st)
    local year = os.date("%Y")
    local tw = math.floor((w - 3 * S(10)) / 4)
    local th = S(74)
    tile(bb, x, y, tw - Look.SHADOW_SMALL, th, _("Books read"), thousands(st.books), st.capped and _("or more") or nil)
    tile(bb, x + tw + S(10), y, tw - Look.SHADOW_SMALL, th, year, thousands(st.year_books), T(_("%1 pages"), thousands(st.year_pages)))
    tile(bb, x + 2 * (tw + S(10)), y, tw - Look.SHADOW_SMALL, th, _("Pages"), thousands(st.pages))
    tile(bb, x + 3 * (tw + S(10)), y, tw - Look.SHADOW_SMALL, th, _("Average"),
        st.average and ("\u{2605} " .. string.format("%.1f", st.average)) or "\u{2013}", st.rated > 0 and T(_("%1 rated"), st.rated) or nil)
    y = y + th + Look.SHADOW_SMALL + S(14)
    -- the goal
    if st.goal and st.goal.goal > 0 and bottom - y > S(60) then
        local gh = S(52)
        Look.box(bb, x, y, w - Look.SHADOW, gh, { shadow = Look.SHADOW })
        Look.label(bb, T(_("%1 goal"), year), x + S(10), y + S(6), w, S(18), 9)
        Look.label(bb, T(_("%1 of %2 books"), st.goal.progress, st.goal.goal), x + S(10), y + S(6), w - S(24) - Look.SHADOW, S(18), 9, { align = "right" })
        Look.slimTrack(bb, x + S(10), y + S(30), w - S(20) - Look.SHADOW, S(12), math.min(1, st.goal.progress / st.goal.goal))
        y = y + gh + Look.SHADOW + S(14)
    end
    -- this year, month by month
    if bottom - y > S(130) then
        local vals = {}
        local names = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }
        for m = 1, 12 do vals[m] = { names[m], st.months[m] or 0 } end
        bars(bb, x, y, w - Look.SHADOW, S(118), vals, T(_("%1, month by month"), year), T(_("%1 books"), st.year_books))
        y = y + S(118) + Look.SHADOW + S(14)
    end
    -- the last years | their ratings
    if bottom - y > S(130) then
        local half = math.floor((w - S(14)) / 2)
        local vals, y0 = {}, tonumber(year)
        for yr = y0 - 5, y0 do vals[#vals + 1] = { "'" .. tostring(yr):sub(3), st.years[tostring(yr)] or 0 } end
        bars(bb, x, y, half - Look.SHADOW, S(118), vals, _("Books a year"))
        local dist = {}
        for r = 1, 5 do dist[r] = { r .. "\u{2605}", st.dist[r] or 0 } end
        bars(bb, x + half + S(14), y, w - half - S(14) - Look.SHADOW, S(118), dist, _("Ratings"))
        y = y + S(118) + Look.SHADOW + S(14)
    end
    -- the authors read most
    if #st.authors > 0 and bottom - y > S(50) then
        Look.label(bb, _("Most read authors"), x, y, w, S(18), 9)
        y = y + S(22)
        local line = {}
        for i = 1, math.min(5, #st.authors) do
            local a = st.authors[i]
            line[#line + 1] = a.name .. (a.n > 1 and (" (" .. a.n .. ")") or "")
        end
        Page.wrap(bb, table.concat(line, "  ·  "), Page.serif(14, false, true), x, y, w, math.max(1, math.floor((bottom - y) / S(22))), S(22))
    end
end

function M.open(who)
    if M.page and not M.page.closed then UIManager:close(M.page) end
    local o = { who = who, pg = 1 }
    local page
    local function load()
        o.st, o.err = nil, nil
        local H = HC()
        if not H.signedIn() then return end
        H.stats(o.who and o.who.id or nil, function(st, why)
            if page.closed then return end
            o.st, o.err = st, why
            page:refresh("ui")
        end)
    end
    local function pick(rect)
        local items = { { text = _("Me"), callback = function() o.who, o.pg = nil, 1 load() page:refresh("ui") end } }
        local H = HC()
        if H.signedIn() then
            for _i, p in ipairs(H.socialCached().people or {}) do
                items[#items + 1] = { text = p.name or p.username or "?", callback = function()
                    o.who, o.pg = { id = p.id, name = p.name or p.username }, 1
                    load()
                    page:refresh("ui")
                end }
            end
            if #items == 1 then
                items[#items + 1] = { text = _("(the readers you follow on Hardcover show here)"), enabled = false, callback = function() end }
            end
        else
            items[#items + 1] = { text = _("Sign in to Hardcover to see friends…"), callback = function()
                UIManager:close(page)
                require("bos_hardcover_ui").open()
            end }
        end
        UI.openList(items, rect)
    end
    page = Page:new{ caption = _("Insights"),
        draw = function(self, bb, y, w)
            local x = self.pad
            local H = Screen:getHeight()
            local bottom = H - S(12)
            -- [WHO ▾]                                   [CALENDAR]
            local name = o.who and o.who.name or _("Me")
            local kw = math.min(math.floor(w * 0.55), Look.textWidth(Look.case(name), 12) + S(54))
            local rk = Look.button(bb, x, y, kw, S(40), name .. "  \u{25BE}", { size = 12, on = true })
            self:hit(rk, function() pick(Geom:new{ x = x, y = y, w = kw, h = S(40) }) end)
            if not o.who then
                local cw = S(150)
                local rc = Look.button(bb, x + w - cw - Look.SHADOW_SMALL, y, cw, S(40), _("Calendar"), { size = 12 })
                self:hit(rc, function() UIManager:broadcastEvent(Event:new("ShowCalendarView")) end)
            end
            y = y + S(40) + Look.SHADOW_SMALL + S(14)
            local signed = HC().signedIn()
            local device = not o.who
            -- you: two pages (this device; Hardcover). A friend: Hardcover.
            local pages = (device and signed) and 2 or 1
            o.pg = math.max(1, math.min(pages, o.pg))
            o.pages = pages
            local foot = pages > 1 and S(50) or 0
            if device and o.pg == 1 then
                Page.heading(bb, _("On this device"), x, y, w)
                y = y + S(30)
                if not o.widget then
                    local okW, wd = pcall(function() return require("bos_insights").Insights:new{ width = w } end)
                    o.widget = okW and wd or false
                end
                if o.widget then
                    o.widget:paintTo(bb, x, y)
                else
                    Page.wrap(bb, _("Reading statistics are off: turn them on in Tools → Reading statistics."), Page.serif(15, false, true), x, y, w, 3, S(23), Look.GRAY)
                end
            else
                Page.heading(bb, o.who and T(_("%1 on Hardcover"), o.who.name) or _("On Hardcover"), x, y, w)
                y = y + S(30)
                if o.st then
                    drawHardcover(bb, x, y, w, bottom - foot, o.st)
                else
                    Page.wrap(bb, o.err or (signed and _("Loading…") or _("Sign in to Hardcover to see this.")), Page.serif(15, false, true), x, y, w, 3, S(23), Look.GRAY)
                end
            end
            if pages > 1 then
                local fh, kw2 = S(38), S(56)
                local fy = H - fh - S(12)
                local rp = Look.button(bb, x, fy, kw2, fh, "\u{2039}", { size = 15, enabled = o.pg > 1 })
                if o.pg > 1 then self:hit(rp, function() o.pg = o.pg - 1 self:refresh("ui") end) end
                local rn = Look.button(bb, x + w - kw2 - Look.SHADOW_SMALL, fy, kw2, fh, "\u{203A}", { size = 15, enabled = o.pg < pages })
                if o.pg < pages then self:hit(rn, function() o.pg = o.pg + 1 self:refresh("ui") end) end
                Look.label(bb, o.pg == 1 and _("This device") or _("Hardcover"), x + kw2, fy, w - 2 * kw2, fh, 11, { align = "center" })
            end
        end,
        on_swipe = function(self, dir)
            if dir == "west" and o.pg < (o.pages or 1) then o.pg = o.pg + 1 self:refresh("ui")
            elseif dir == "east" then
                if o.pg > 1 then o.pg = o.pg - 1 self:refresh("ui") else self:onClose() end
            end
        end,
        on_close = function() M.page = nil end }
    M.page = page
    page:show()
    load()
    -- the list of readers, fresh for the next time it's opened
    pcall(function() HC().socialTouch() end)
    return page
end

return M
