--[[
Wrapped's numbers for one year, worked out from what is on the device:

  KOReader's reading statistics (statistics.sqlite3)   time, days, hours,
                                                       sittings, when each
                                                       book was first opened
  each book's sidecar (KOReader's .sdr)               finished and when,
                                                       rating, highlights,
                                                       notes
  Bookshelf's library (bos_recs)                      titles, authors,
                                                       series, genres, files
  the vocabulary builder (vocabulary_builder.sqlite3)  words looked up

  M.compute(year) -> the table below (runs for seconds on a big library on an
                     e-reader: Wrapped calls it in a background process and
                     keeps the result, M.cached(year))

  { year, at, secs, months[12], hours[24], weekdays[7] (secs; 1 = Sunday),
    days_read, streak = { n, from, to }, busiest_day = { wday, avg },
    peak_hour, longest_sitting = { secs, at, title },
    finished = { { fp, title, author, pages, started, finished, secs, rating } },
    pages, longest = { title, pages }, abandoned,
    long_haul = { { fp, title, author, started, finished, days } },
    top = { fp, title, author, secs, days, rating, sitting = { secs, at } },
    authors = { { name, books, secs } }, genres = { { name, pct } },
    highlights, notes, words, quote = { text, title, author },
    most_marked = { title, n }, persona = { name, facts = { { label, text } } } }
--]]

local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function yearBounds(year)
    return os.time({ year = year, month = 1, day = 1, hour = 0 }),
           os.time({ year = year + 1, month = 1, day = 1, hour = 0 })
end
M.yearBounds = yearBounds

local function dbPath(name)
    return require("datastorage"):getSettingsDir() .. "/" .. name
end

local function withDB(name, fn)
    local path = dbPath(name)
    if lfs.attributes(path, "mode") ~= "file" then return nil end
    local SQ3 = require("lua-ljsqlite3/init")
    local ok_o, conn = pcall(SQ3.open, path, "ro")
    if not ok_o or not conn then return nil end
    local ok, res = pcall(function()
        conn:exec("PRAGMA busy_timeout=500;")
        return fn(conn)
    end)
    conn:close()
    if not ok then logger.warn("ShelfTechUI: Wrapped could not read " .. name .. ":", res) return nil end
    return res
end

local function maxSec()
    local stats = G_reader_settings:readSetting("statistics")
    return (stats and stats.max_sec) or 120
end

local function dayKey(t) return os.date("%Y-%m-%d", t) end

--- "YYYY-MM-DD" (summary.modified) → a time at noon that day.
local function parseDate(s)
    local y, m, d = tostring(s or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    if not y then return nil end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function norm(s) return tostring(s or ""):lower():gsub("[%p%s]+", " "):gsub("^ ", ""):gsub(" $", "") end

-- ---------------------------------------------------------------- reading time

--- Everything from the statistics database for `year`.
local function fromStats(year)
    local y0, y1 = yearBounds(year)
    local cap = maxSec()
    return withDB("statistics.sqlite3", function(conn)
        local s = {
            secs = 0, months = {}, hours = {}, weekdays = {}, days = {},
            by_book = {}, books = {}, first = {}, last = {},
            longest_sitting = { secs = 0 }, sitting_by_book = {},
        }
        for i = 1, 12 do s.months[i] = 0 end
        for i = 1, 24 do s.hours[i] = 0 end
        for i = 1, 7 do s.weekdays[i] = 0 end
        -- the books KOReader knows
        local stmt = conn:prepare("SELECT id, title, authors, md5, series, pages FROM book")
        local row = stmt:step()
        while row do
            s.books[tonumber(row[1])] = { title = row[2], authors = row[3], md5 = row[4], series = row[5], pages = tonumber(row[6]) }
            row = stmt:step()
        end
        stmt:close()
        -- when each book was first and last read (all years)
        stmt = conn:prepare("SELECT id_book, min(start_time), max(start_time) FROM page_stat_data GROUP BY id_book")
        row = stmt:step()
        while row do
            s.first[tonumber(row[1])] = tonumber(row[2])
            s.last[tonumber(row[1])] = tonumber(row[3])
            row = stmt:step()
        end
        stmt:close()
        -- the year's pages, in order: time, when, and sittings (a break of
        -- 10 minutes, or another book, ends one)
        stmt = conn:prepare("SELECT id_book, start_time, duration FROM page_stat_data "
            .. "WHERE start_time >= ? AND start_time < ? ORDER BY start_time")
        row = stmt:reset():bind(y0, y1):step()
        local sit = nil
        local function closeSitting()
            if not sit then return end
            if sit.secs > s.longest_sitting.secs then
                s.longest_sitting = { secs = sit.secs, at = sit.at, book = sit.book }
            end
            local b = s.sitting_by_book[sit.book]
            if not b or sit.secs > b.secs then s.sitting_by_book[sit.book] = { secs = sit.secs, at = sit.at } end
            s.sittings = (s.sittings or 0) + 1
            s.sitting_secs = (s.sitting_secs or 0) + sit.secs
        end
        while row do
            local id, t, d = tonumber(row[1]), tonumber(row[2]), math.min(tonumber(row[3]) or 0, cap)
            if t and d and d > 0 then
                s.secs = s.secs + d
                local tm = os.date("*t", t)
                s.months[tm.month] = s.months[tm.month] + d
                s.hours[tm.hour + 1] = s.hours[tm.hour + 1] + d
                s.weekdays[tm.wday] = s.weekdays[tm.wday] + d
                s.days[dayKey(t)] = (s.days[dayKey(t)] or 0) + d
                s.by_book[id] = (s.by_book[id] or 0) + d
                if sit and sit.book == id and t - sit.last_end <= 600 then
                    sit.secs = sit.secs + d
                    sit.last_end = t + d
                else
                    closeSitting()
                    sit = { book = id, secs = d, at = t, last_end = t + d }
                end
            end
            row = stmt:step()
        end
        closeSitting()
        stmt:close()
        return s
    end)
end

local function wordsLookedUp(year)
    local y0, y1 = yearBounds(year)
    return withDB("vocabulary_builder.sqlite3", function(conn)
        local stmt = conn:prepare("SELECT count(*) FROM vocabulary WHERE create_time >= ? AND create_time < ?")
        local row = stmt:reset():bind(y0, y1):step()
        stmt:close()
        return tonumber(row and row[1]) or 0
    end)
end

-- ---------------------------------------------------------------- the books

--- Each book of the library with a sidecar: finished (and when), rating,
--- the year's highlights and notes, KOReader's md5 (to meet the statistics).
local function fromSidecars(year)
    local y0, y1 = yearBounds(year)
    local out = { books = {}, by_md5 = {}, by_title = {}, highlights = 0, notes = 0, marks = {} }
    local Recs = require("bos_recs")
    local L = Recs.library()
    local DocSettings = require("docsettings")
    for _i, b in ipairs(L and L.books or {}) do
        local fp = b.filepath
        local ok = pcall(function()
            if not DocSettings:hasSidecarFile(fp) then return end
            local ds = DocSettings:open(fp)
            local summary = ds:readSetting("summary") or {}
            local e = {
                fp = fp, title = b.title, author = b.authors and b.authors[1], series = b.series,
                genres = b.genres, status = summary.status, rating = tonumber(summary.rating),
                modified = parseDate(summary.modified), md5 = ds:readSetting("partial_md5_checksum"),
                pages = (ds:readSetting("doc_pages")) or (ds:readSetting("stats") or {}).pages,
                highlights = 0,
            }
            for _j, a in ipairs(ds:readSetting("annotations") or {}) do
                local when = parseDate(a.datetime)
                if when and when >= y0 and when < y1 then
                    if a.pos0 or a.drawer then
                        e.highlights = e.highlights + 1
                        out.highlights = out.highlights + 1
                        if a.text and a.text ~= "" then
                            table.insert(out.marks, { text = a.text, note = a.note, title = b.title,
                                author = e.author, at = when, fp = fp })
                        end
                    end
                    if a.note and a.note ~= "" then out.notes = out.notes + 1 end
                end
            end
            table.insert(out.books, e)
            if e.md5 then out.by_md5[e.md5] = e end
            out.by_title[norm(b.title)] = out.by_title[norm(b.title)] or e
        end)
        if not ok then logger.dbg("ShelfTechUI: Wrapped skipped", fp) end
    end
    return out
end

-- ---------------------------------------------------------------- your reader type

local function persona(r)
    local secs = math.max(1, r.secs)
    local function share(from, to) -- hours, inclusive, may wrap past midnight
        local t, h = 0, from
        repeat
            t = t + (r.hours[(h % 24) + 1] or 0)
            h = h + 1
        until (h % 24) == ((to + 1) % 24)
        return t / secs
    end
    local night, morning = share(21, 3), share(5, 9)
    local weekend = ((r.weekdays[1] or 0) + (r.weekdays[7] or 0)) / secs
    local adj, adj_fact
    if night >= 0.4 then
        adj, adj_fact = _("Night-Owl"), { _("Night owl"), T(_("%1% of your reading after 9 pm"), math.floor(night * 100 + 0.5)) }
    elseif morning >= 0.3 then
        adj, adj_fact = _("Early-Bird"), { _("Early bird"), T(_("%1% of your reading before 10 am"), math.floor(morning * 100 + 0.5)) }
    elseif weekend >= 0.5 then
        adj, adj_fact = _("Weekend"), { _("Weekender"), T(_("%1% of your reading on Saturdays and Sundays"), math.floor(weekend * 100 + 0.5)) }
    elseif r.days_read >= 200 then
        adj, adj_fact = _("Everyday"), { _("Every day"), T(_("You read on %1 days"), r.days_read) }
    else
        adj, adj_fact = _("Steady"), { _("Steady"), T(_("You read on %1 days"), r.days_read) }
    end
    -- what you read
    local series = {}
    for _i, f in ipairs(r.finished) do
        if f.series and f.series ~= "" then series[f.series] = (series[f.series] or 0) + 1 end
    end
    local binged = 0
    for _k, n in pairs(series) do if n >= 2 then binged = binged + 1 end end
    local avg_days
    do
        local n, sum = 0, 0
        for _i, f in ipairs(r.finished) do
            if f.started and f.finished and f.finished >= f.started then
                n = n + 1
                sum = sum + (f.finished - f.started) / 86400
            end
        end
        avg_days = n > 0 and sum / n or nil
    end
    local avg_sitting = r.sittings and r.sittings > 0 and (r.sitting_secs / r.sittings) or 0
    local finish_rate = r.started_count > 0 and math.min(1, #r.finished / r.started_count) or 0
    local noun, noun_fact
    if binged >= 1 then
        noun, noun_fact = _("Series Binger"), { _("Binger"), binged == 1 and _("A series read straight through")
            or T(_("%1 series read straight through"), binged) }
    elseif #r.finished >= 5 and finish_rate >= 0.8 then
        noun, noun_fact = _("Finisher"), { _("Finisher"), T(_("%1% of what you started, finished"), math.floor(finish_rate * 100 + 0.5)) }
    elseif avg_days and avg_days <= 7 and #r.finished >= 3 then
        noun, noun_fact = _("Sprinter"), { _("Sprinter"), T(_("%1 days a book, on average"), math.max(1, math.floor(avg_days + 0.5))) }
    elseif #r.genres >= 4 then
        noun, noun_fact = _("Explorer"), { _("Explorer"), T(_("%1 genres this year"), #r.genres) }
    elseif avg_sitting >= 45 * 60 then
        noun, noun_fact = _("Marathoner"), { _("Marathoner"), T(_("%1 minutes a sitting, on average"), math.floor(avg_sitting / 60 + 0.5)) }
    else
        noun, noun_fact = _("Reader"), { _("Reader"), T(_("%1 sittings this year"), r.sittings or 0) }
    end
    local third
    if finish_rate > 0 and noun ~= _("Finisher") then
        third = { _("Finisher"), T(_("%1% of what you started, finished"), math.floor(finish_rate * 100 + 0.5)) }
    else
        third = { _("Longest sitting"), T(_("%1 minutes"), math.floor((r.longest_sitting.secs or 0) / 60 + 0.5)) }
    end
    return { name = T(_("The %1 %2"), adj, noun), facts = { adj_fact, noun_fact, third } }
end

-- ---------------------------------------------------------------- the year

function M.compute(year)
    local y0, y1 = yearBounds(year)
    local st = fromStats(year) or { secs = 0, months = {}, hours = {}, weekdays = {}, days = {}, by_book = {},
        books = {}, first = {}, last = {}, longest_sitting = { secs = 0 }, sitting_by_book = {} }
    for i = 1, 12 do st.months[i] = st.months[i] or 0 end
    for i = 1, 24 do st.hours[i] = st.hours[i] or 0 end
    for i = 1, 7 do st.weekdays[i] = st.weekdays[i] or 0 end
    local sc = fromSidecars(year)
    local r = { year = year, at = os.time(), secs = st.secs, months = st.months, hours = st.hours,
        weekdays = st.weekdays, sittings = st.sittings, sitting_secs = st.sitting_secs }
    -- statistics book ↔ file (KOReader's md5, else the title)
    local function fileFor(id)
        local b = st.books[id]
        if not b then return nil end
        return (b.md5 and sc.by_md5[b.md5]) or sc.by_title[norm(b.title)]
    end
    local idFor = {}
    for id, b in pairs(st.books) do
        local e = fileFor(id)
        if e then idFor[e.fp] = id end
    end
    -- days, streak, busiest day, peak hour
    local days = {}
    for k in pairs(st.days) do table.insert(days, k) end
    table.sort(days)
    r.days_read = #days
    local best, cur, start, best_from, best_to = 0, 0, nil, nil, nil
    local prev
    for _i, k in ipairs(days) do
        local t = parseDate(k)
        if prev and t - prev <= 86400 + 7200 then cur = cur + 1 else cur, start = 1, t end
        if cur > best then best, best_from, best_to = cur, start, t end
        prev = t
    end
    r.streak = { n = best, from = best_from, to = best_to }
    local wday_count = {}
    for _i, k in ipairs(days) do
        local w = os.date("*t", parseDate(k)).wday
        wday_count[w] = (wday_count[w] or 0) + 1
    end
    local bw, bavg = nil, 0
    for w = 1, 7 do
        local n = wday_count[w] or 0
        local avg = n > 0 and st.weekdays[w] / n or 0
        if avg > bavg then bw, bavg = w, avg end
    end
    r.busiest_day = bw and { wday = bw, avg = bavg } or nil
    local ph, pv = nil, 0
    for h = 1, 24 do if st.hours[h] > pv then ph, pv = h - 1, st.hours[h] end end
    r.peak_hour = ph
    if st.longest_sitting.secs > 0 then
        local b = st.books[st.longest_sitting.book]
        r.longest_sitting = { secs = st.longest_sitting.secs, at = st.longest_sitting.at, title = b and b.title }
    else
        r.longest_sitting = { secs = 0 }
    end
    -- finished this year (KOReader's "finished", dated by the sidecar)
    r.finished, r.long_haul, r.pages, r.abandoned = {}, {}, 0, 0
    for _i, e in ipairs(sc.books) do
        local id = idFor[e.fp]
        local done = (e.status == "complete" or e.status == "finished")
        local when = e.modified or (done and id and st.last[id]) or nil
        if done and when and when >= y0 and when < y1 then
            local f = { fp = e.fp, title = e.title, author = e.author, series = e.series, pages = tonumber(e.pages),
                started = id and st.first[id] or nil, finished = when, secs = id and st.by_book[id] or 0,
                rating = e.rating, genres = e.genres }
            table.insert(r.finished, f)
            r.pages = r.pages + (f.pages or 0)
            if f.started and f.started < y0 then
                table.insert(r.long_haul, { fp = f.fp, title = f.title, author = f.author, started = f.started,
                    finished = f.finished, days = math.floor((f.finished - f.started) / 86400 + 0.5) })
            end
        elseif (e.status == "abandoned" or e.status == "on_hold") and when and when >= y0 and when < y1 then
            r.abandoned = r.abandoned + 1
        end
    end
    table.sort(r.finished, function(a, b) return a.finished < b.finished end)
    table.sort(r.long_haul, function(a, b) return a.days > b.days end)
    local longest
    for _i, f in ipairs(r.finished) do if f.pages and (not longest or f.pages > longest.pages) then longest = f end end
    r.longest = longest and { title = longest.title, pages = longest.pages } or nil
    -- books first opened this year (for "finished what you started")
    r.started_count = 0
    for id, t in pairs(st.first) do if t >= y0 and t < y1 then r.started_count = r.started_count + 1 end end
    -- the book of the year: the most time
    local top_id, top_secs = nil, 0
    for id, secs in pairs(st.by_book) do if secs > top_secs then top_id, top_secs = id, secs end end
    if top_id then
        local b, e = st.books[top_id], fileFor(top_id)
        local fin
        for _i, f in ipairs(r.finished) do if e and f.fp == e.fp then fin = f end end
        r.top = {
            fp = e and e.fp, title = (e and e.title) or (b and b.title) or "?",
            author = (e and e.author) or (b and b.authors), secs = top_secs, rating = e and e.rating,
            days = (fin and fin.started) and math.max(1, math.floor((fin.finished - fin.started) / 86400 + 0.5)) or nil,
            sitting = st.sitting_by_book[top_id],
        }
    end
    -- authors (by time) and genres (by time, from the library)
    local by_author, by_genre, genre_total = {}, {}, 0
    for id, secs in pairs(st.by_book) do
        local b, e = st.books[id], fileFor(id)
        local name = (e and e.author) or (b and b.authors and tostring(b.authors):match("^[^\n]+"))
        if name and name ~= "" and name ~= "N/A" then
            local a = by_author[name] or { name = name, books = 0, secs = 0 }
            a.books, a.secs = a.books + 1, a.secs + secs
            by_author[name] = a
        end
        for _j, g in ipairs(e and e.genres or {}) do
            by_genre[g] = (by_genre[g] or 0) + secs
            genre_total = genre_total + secs
        end
    end
    r.authors = {}
    for _k, a in pairs(by_author) do table.insert(r.authors, a) end
    table.sort(r.authors, function(a, b) return a.secs > b.secs end)
    while #r.authors > 5 do table.remove(r.authors) end
    r.genres = {}
    for g, secs in pairs(by_genre) do
        table.insert(r.genres, { name = g:gsub("^%l", string.upper), secs = secs })
    end
    table.sort(r.genres, function(a, b) return a.secs > b.secs end)
    while #r.genres > 4 do table.remove(r.genres) end
    for _i, g in ipairs(r.genres) do g.pct = math.floor(g.secs * 100 / math.max(1, genre_total) + 0.5) end
    -- what you marked
    r.highlights, r.notes = sc.highlights, sc.notes
    r.words = wordsLookedUp(year)
    local most
    for _i, e in ipairs(sc.books) do if e.highlights > 0 and (not most or e.highlights > most.highlights) then most = e end end
    r.most_marked = most and { title = most.title, n = most.highlights } or nil
    -- a line: one you wrote a note on, else from the book of the year, else
    -- the latest; short enough for a card
    local pick
    local function fits(m) local n = #m.text return n >= 30 and n <= 240 end
    for _i, m in ipairs(sc.marks) do if m.note and m.note ~= "" and fits(m) and (not pick or m.at > pick.at) then pick = m end end
    if not pick and r.top and r.top.fp then
        for _i, m in ipairs(sc.marks) do if m.fp == r.top.fp and fits(m) and (not pick or #m.text > #pick.text) then pick = m end end
    end
    if not pick then for _i, m in ipairs(sc.marks) do if fits(m) and (not pick or m.at > pick.at) then pick = m end end end
    r.quote = pick and { text = pick.text, title = pick.title, author = pick.author } or nil
    r.persona = persona(r)
    return r
end

-- ---------------------------------------------------------------- kept results

local function cacheFile(year)
    local dir = require("datastorage"):getDataDir() .. "/cache/stui_wrapped"
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(require("datastorage"):getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir .. "/" .. year .. ".lua"
end

function M.cached(year)
    local ok, s = pcall(function() return require("luasettings"):open(cacheFile(year)) end)
    return ok and s and s:readSetting("year") or nil
end

function M.save(year, r)
    local s = require("luasettings"):open(cacheFile(year))
    s:saveSetting("year", r)
    s:flush()
end

--- Seconds read in `year` (quick: is there anything to wrap?).
function M.secondsIn(year)
    local y0, y1 = yearBounds(year)
    return withDB("statistics.sqlite3", function(conn)
        local stmt = conn:prepare("SELECT sum(min(duration, ?)) FROM page_stat_data WHERE start_time >= ? AND start_time < ?")
        local row = stmt:reset():bind(maxSec(), y0, y1):step()
        stmt:close()
        return tonumber(row and row[1]) or 0
    end) or 0
end

return M
