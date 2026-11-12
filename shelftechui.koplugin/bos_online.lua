--[[
Recommendations from the internet, from what you read (Open Library): over
Wi-Fi only, fetched at most once a day in a background process, with no
account and nothing about you sent but the authors, series and genres asked
about. On unless turned off (Settings → Connect → Recommendations).

  More in your series           books in series you've started that aren't
                                on the device
  More by authors you read      their other works
  Popular in <your top genre>   Open Library's subject lists

FOR YOU on home is these three shelves ("stui_online": series, authors,
genres) and Want to read ("stui_want"). A pick opens its page in the store
(bos_store): the libraries are asked for it, and it downloads from there.
+ WANT keeps it on the Want to read shelf.

The shelves are filled from what was fetched; the day's fetch runs when a
shelf is drawn (or you pull down to refresh), and the shelves redraw when
it's done.

Author pages get the author's portrait from Open Library too.

Everything fetched is kept under koreader/cache/stui_online.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Store = require("bos_settings_store")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local OL = "https://openlibrary.org"
local COVERS = "https://covers.openlibrary.org"

function M.enabled() return Store.get("online_picks") ~= false end

local function cacheDir()
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/cache/stui_online"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then
        lfs.mkdir(DataStorage:getDataDir() .. "/cache")
        lfs.mkdir(dir)
    end
    return dir
end

local function store()
    if not M._store then
        M._store = require("luasettings"):open(cacheDir() .. "/picks.lua")
    end
    return M._store
end

local function connected()
    local ok, on = pcall(function()
        local NM = require("ui/network/manager")
        return NM:isWifiOn() and NM:isConnected()
    end)
    return ok and on
end
M.connected = connected

local function urlencode(s)
    return (tostring(s):gsub("([^%w%-_%.~ ])", function(c) return string.format("%%%02X", c:byte()) end):gsub(" ", "+"))
end

local function getJSON(url)
    local ok, res = pcall(function()
        return require("lib/bookshelf_http").getJSON(url, { user_agent = "KOReader-ShelfTechUI (+https://github.com/koreader/koreader)",
            block_timeout = 10, total_timeout = 20 })
    end)
    if ok then return res end
    logger.warn("ShelfTechUI: Open Library request failed:", res)
end

local function norm(t)
    return tostring(t or ""):lower():gsub("^the ", ""):gsub("^a ", ""):gsub("[^%w]", "")
end

--- Titles already on the device (normalised), so picks never repeat them.
local function owned()
    local set = {}
    local L = require("bos_recs").library()
    for _i, b in ipairs(L and L.books or {}) do set[norm(b.title)] = true end
    return set
end

local function fromDoc(d)
    return {
        online = true, key = d.key, title = d.title,
        author = (d.author_name and d.author_name[1]) or (d.authors and d.authors[1] and d.authors[1].name),
        year = d.first_publish_year, cover_i = d.cover_i or d.cover_id,
        series_num = nil,
    }
end

-- ---------------------------------------------------------------- queries

local function searchDocs(params)
    local res = getJSON(OL .. "/search.json?" .. params
        .. "&fields=key,title,author_name,first_publish_year,cover_i&limit=25")
    return res and res.docs or {}
end

local function seriesPicks(name, author, have)
    local docs = searchDocs("q=" .. urlencode(name) .. (author and ("&author=" .. urlencode(author)) or ""))
    local out = {}
    for _i, d in ipairs(docs) do
        if d.title and not have[norm(d.title)] then
            local p = fromDoc(d)
            p.series = name
            table.insert(out, p)
            have[norm(d.title)] = true
        end
        if #out >= 6 then break end
    end
    return out
end

local function authorPicks(name, have)
    local docs = searchDocs("author=" .. urlencode(name) .. "&sort=editions")
    local out = {}
    for _i, d in ipairs(docs) do
        if d.title and not have[norm(d.title)] then
            table.insert(out, fromDoc(d))
            have[norm(d.title)] = true
        end
        if #out >= 8 then break end
    end
    return out
end

local function subjectPicks(genre, have)
    local slug = genre:lower():gsub("[^%w]+", "_"):gsub("^_", ""):gsub("_$", "")
    local res = getJSON(OL .. "/subjects/" .. slug .. ".json?limit=20")
    local out = {}
    for _i, w in ipairs(res and res.works or {}) do
        if w.title and not have[norm(w.title)] then
            table.insert(out, fromDoc(w))
            have[norm(w.title)] = true
        end
        if #out >= 8 then break end
    end
    return out
end

--- Fetches today's picks (blocking: run behind a "fetching" message).
function M.fetch()
    local Recs = require("bos_recs")
    local have = owned()
    local rows = {}
    local series = Recs.startedSeries()
    local miss = {}
    for i = 1, math.min(3, #series) do
        for _j, p in ipairs(seriesPicks(series[i].name, series[i].author, have)) do table.insert(miss, p) end
    end
    if #miss > 0 then table.insert(rows, { id = "series", title = _("Missing from your series"), items = miss }) end
    local more = {}
    for _i, a in ipairs(Recs.topAuthors(3)) do
        for _j, p in ipairs(authorPicks(a, have)) do table.insert(more, p) end
    end
    if #more > 0 then table.insert(rows, { id = "authors", title = _("More by authors you finish"), items = more }) end
    for _i, g in ipairs(Recs.topGenres(2)) do
        local pop = subjectPicks(g, have)
        if #pop > 0 then table.insert(rows, { id = "genres", title = T(_("Popular in %1"), g), items = pop }) end
    end
    local s = store()
    s:saveSetting("rows", rows)
    s:saveSetting("day", os.date("%Y-%m-%d"))
    s:flush()
    return rows
end

function M.rows() return store():readSetting("rows") or {} end

--- One home shelf's picks: "series", "authors" or "genres" (every genre row).
--- Today's three: one from each list (your series, your authors, your
--- genres), a different one each day, never a book you already have. The
--- same three all day; tomorrow the next in each list. FOR YOU on home is
--- these three, and they're the only covers fetched ahead of time.
local today = { day = nil, picks = nil }
function M.daily(day)
    day = day or os.date("%Y-%m-%d")
    if today.day == day and today.picks and today.n == #M.rows() then return today.picks end
    local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
    local n = math.floor(os.time({ year = tonumber(y) or 2000, month = tonumber(m) or 1, day = tonumber(d) or 1, hour = 12 }) / 86400)
    local lists = {}
    for _i, which in ipairs{ "series", "authors", "genres" } do
        local l = {}
        for _j, p in ipairs(M.rowItems(which)) do if not M.owned(p) then l[#l + 1] = p end end
        if #l > 0 then lists[#lists + 1] = l end
    end
    local out, seen = {}, {}
    local function take(p) if p and not seen[p.key] and #out < 3 then seen[p.key] = true out[#out + 1] = p return true end end
    -- one from each list, at today's place in it
    for _i, l in ipairs(lists) do take(l[(n % #l) + 1]) end
    -- fewer than three lists (or the same book in two): the next ones along
    local step = 1
    while #out < 3 and step <= 60 do
        local any = false
        for _i, l in ipairs(lists) do
            if #l > step - 1 then any = true end
            take(l[((n + step) % #l) + 1])
        end
        if not any then break end
        step = step + 1
    end
    today.day, today.picks, today.n = day, out, #M.rows()
    return out
end

function M.rowItems(which)
    if which == "daily" then return M.daily() end
    if which == "all" then
        -- one from each list in turn, so it isn't all one author
        local lists = { M.rowItems("series"), M.rowItems("authors"), M.rowItems("genres") }
        local out, seen, i = {}, {}, 1
        while true do
            local any = false
            for _k, l in ipairs(lists) do
                local p = l[i]
                if p then
                    any = true
                    if not seen[p.key] then seen[p.key] = true out[#out + 1] = p end
                end
            end
            if not any then break end
            i = i + 1
        end
        return out
    end
    local out, seen = {}, {}
    for _i, row in ipairs(M.rows()) do
        local id = row.id
        if not id then -- picks fetched before 1.1.5
            id = (row.title == _("Missing from your series") and "series")
                or (row.title == _("More by authors you finish") and "authors") or "genres"
        end
        if id == which then
            for _j, p in ipairs(row.items or {}) do
                if p.key and not seen[p.key] then
                    seen[p.key] = true
                    table.insert(out, p)
                end
            end
        end
    end
    return out
end

--- The day's fetch in a background process (nothing waits for it); the home
--- shelves redraw when it's done. Once a day, Wi-Fi only, unless `force`.
function M.refreshInBackground(force)
    if M._fetching or not M.enabled() or not connected() then return false end
    if not force and (M.fresh() or M._tried == os.date("%Y-%m-%d")) then return false end
    M._tried = os.date("%Y-%m-%d")
    local ffiutil = require("ffi/util")
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        local okF, rows = pcall(M.fetch)
        if not okF then logger.warn("ShelfTechUI: online picks failed:", rows) return end
        -- today's three covers, so FOR YOU draws from the cache (anything
        -- else fetches its covers when it's looked at: M.fetchCovers)
        M._store = nil
        for _i, p in ipairs(M.daily()) do pcall(M.coverPath, p) end
    end)
    if not ok or not pid then
        logger.warn("ShelfTechUI: online picks fetch not started:", pid)
        return false
    end
    M._fetching = true
    local waited = 0
    local function poll()
        if ffiutil.isSubProcessDone(pid) or waited > 120 then
            M._fetching = nil
            M._store = nil -- the child wrote the file: read it again
            pcall(function() require("lib/bookshelf_sources").changed("stui_online") end)
            return
        end
        waited = waited + 1
        UIManager:scheduleIn(1, poll)
    end
    UIManager:scheduleIn(1, poll)
    return true
end

--- The one list of recommendations (the Dash layout's row; FOR YOU on home
--- shows today's three of it: M.daily).
-- (one shelf since 1.8.0: more in your series, more by your authors and
-- popular in your genres, taken in turn)
M.SHELVES = {
    { id = "stui_fy_online", which = "all", label = _("Recommendations") },
}

--- Your own copy of a recommended book, if it's on the device (the same
--- title, and the same author when both are known): the library's book.
local own = { gen = false, by = nil }
function M.owned(p)
    if type(p) ~= "table" or not p.title then return nil end
    local okR, L = pcall(function() return require("bos_recs").library() end)
    if not okR or not L or not L.books then return nil end
    if own.by == nil or own.gen ~= L.gen or own.n ~= #L.books then
        own.by, own.gen, own.n = {}, L.gen, #L.books
        for _i, b in ipairs(L.books) do
            local k = norm(b.title)
            if k ~= "" then
                own.by[k] = own.by[k] or {}
                table.insert(own.by[k], b)
            end
        end
    end
    local hits = own.by[norm(p.title)]
    if not hits then return nil end
    local want = p.author and norm(p.author) or ""
    local surname = want:match("(%S+)$")
    for _i, b in ipairs(hits) do
        local have = norm(table.concat(b.authors or {}, " "))
        if want == "" or have == "" or (surname and have:find(surname, 1, true)) then return b end
    end
    return nil
end

--- "IN LIBRARY" across the foot of a cover drawn at x, y, w, h.
function M.paintBadge(bb, x, y, w, h)
    local bh = math.max(S(14), math.floor(h * 0.16))
    bb:paintRect(x, y + h - bh, w, bh, BLACK)
    local size = math.max(6, math.min(10, math.floor(w / 9)))
    Look.label(bb, _("In library"), x + 1, y + h - bh, w - 2, bh, size, { align = "center", color = WHITE })
end

--- A cover file with the badge painted on it (kept beside the cover), for
--- Bookshelf's own shelves, which draw the picture they're given.
function M.badgedCover(path)
    if not path then return nil end
    local lfs = require("libs/libkoreader-lfs")
    local out = path:gsub("%.%w+$", "") .. "_lib.png"
    if lfs.attributes(out, "mode") == "file" then return out end
    local ok = pcall(function()
        local img = require("ui/renderimage"):renderImageFile(path, false)
        if not img then error("no image") end
        M.paintBadge(img, 0, 0, img:getWidth(), img:getHeight())
        img:writePNG(out)
        img:free()
    end)
    return ok and lfs.attributes(out, "mode") == "file" and out or path
end

--- The covers of `items` that aren't on file yet (at most `max`), fetched
--- in the background; done() when any arrived. For the lists that are looked
--- at now and then (a book's Recommendations tab, the store's row), so
--- nothing is downloaded for covers nobody sees.
function M.fetchCovers(items, done, max)
    if not (M.enabled() and connected()) or M._covering then return false end
    local need = {}
    for _i, it in ipairs(items or {}) do
        local p = it.pick or it
        if p.cover_i and not M.cachedCoverPath(p, "M") then
            need[#need + 1] = p
            if #need >= (max or 9) then break end
        end
    end
    if #need == 0 then return false end
    local ffiutil = require("ffi/util")
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        for _i, p in ipairs(need) do pcall(M.coverPath, p) end
    end)
    if not ok or not pid then return false end
    M._covering = true
    local waited = 0
    local function poll()
        if ffiutil.isSubProcessDone(pid) or waited > 60 then
            M._covering = nil
            if done then pcall(done) end
            return
        end
        waited = waited + 1
        UIManager:scheduleIn(1, poll)
    end
    UIManager:scheduleIn(1, poll)
    return true
end

function M.syncShelves()
    -- FOR YOU is the shelf itself (today's three): shown while
    -- recommendations are on
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        for _i, t in ipairs(tabs) do
            if t.id == "stui_foryou" and (t.enabled ~= false) ~= M.enabled() then
                t.enabled = M.enabled()
                TabModel.save(tabs)
            end
        end
    end)
    if not ok then logger.warn("ShelfTechUI: For you not updated:", err) end
end

function M.setEnabled(on)
    Store.set("online_picks", on and true or false)
    M.syncShelves()
    if on then M.refreshInBackground(true) end
    pcall(function() require("lib/bookshelf_sources").changed("stui_online") end)
end
function M.fresh() return store():readSetting("day") == os.date("%Y-%m-%d") end

-- ---------------------------------------------------------------- covers, descriptions, portraits

function M.coverPath(item, size)
    if not item.cover_i then return nil end
    local path = cacheDir() .. "/c" .. item.cover_i .. (size or "M") .. ".jpg"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "file" then return path end
    if not (M.enabled() and connected()) then return nil end
    local ok, res = pcall(function()
        return require("lib/bookshelf_cover_fetch").download(COVERS .. "/b/id/" .. item.cover_i .. "-" .. (size or "M") .. ".jpg",
            path, nil, nil, { block_timeout = 8, total_timeout = 15 })
    end)
    return ok and res or nil
end

--- The cover already downloaded, or nil (never fetches: safe while drawing).
function M.cachedCoverPath(item, size)
    if not (item and item.cover_i) then return nil end
    local path = cacheDir() .. "/c" .. item.cover_i .. (size or "M") .. ".jpg"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "file" then return path end
end

function M.description(item)
    if item.description ~= nil then return item.description or nil end
    item.description = false
    if not (item.key and M.enabled() and connected()) then return nil end
    local key = item.key:match("^/works/") and item.key or ("/works/" .. tostring(item.key):gsub("^/", ""))
    local res = getJSON(OL .. key .. ".json")
    local d = res and res.description
    if type(d) == "table" then d = d.value end
    if type(d) == "string" then
        item.description = d:gsub("%[(.-)%]%(.-%)", "%1"):gsub("%-%-%-%-+.*$", "")
    end
    return item.description or nil
end

function M.portraitPath(name)
    if not name then return nil end
    local s = store()
    local map = s:readSetting("portraits") or {}
    local lfs = require("libs/libkoreader-lfs")
    local olid = map[name]
    if olid == false then return nil end
    if olid then
        local path = cacheDir() .. "/a" .. olid .. ".jpg"
        if lfs.attributes(path, "mode") == "file" then return path end
    end
    if not (M.enabled() and connected()) then return nil end
    if not olid then
        local res = getJSON(OL .. "/search/authors.json?q=" .. urlencode(name) .. "&limit=1")
        local doc = res and res.docs and res.docs[1]
        olid = doc and doc.key and tostring(doc.key):gsub("^/authors/", "") or false
        map[name] = olid
        s:saveSetting("portraits", map)
        s:flush()
        if not olid then return nil end
    end
    local path = cacheDir() .. "/a" .. olid .. ".jpg"
    local ok, res = pcall(function()
        return require("lib/bookshelf_cover_fetch").download(COVERS .. "/a/olid/" .. olid .. "-M.jpg?default=false",
            path, nil, nil, { block_timeout = 8, total_timeout = 15 })
    end)
    return ok and res or nil
end

--- For the series and author pages: what's out there that you don't have.
function M.missingInSeries(name, author, books)
    local have = {}
    for _i, b in ipairs(books or {}) do have[norm(b.title)] = true end
    local out = {}
    for _i, row in ipairs(M.rows()) do
        for _j, p in ipairs(row.items or {}) do
            if p.series == name and not have[norm(p.title)] then
                have[norm(p.title)] = true
                table.insert(out, p)
            end
        end
    end
    return out
end

function M.missingByAuthor(name, books)
    local have = {}
    for _i, b in ipairs(books or {}) do have[norm(b.title)] = true end
    local out = {}
    for _i, row in ipairs(M.rows()) do
        for _j, p in ipairs(row.items or {}) do
            if p.author and p.author:lower() == tostring(name):lower() and not have[norm(p.title)] then
                have[norm(p.title)] = true
                table.insert(out, p)
            end
        end
    end
    return out
end

--- The Recommendations tab of a book's window (bos_bookdetail): picks by its author or in its series first.
function M.forBook(d)
    -- this book's own first (the same series, the same author), then the
    -- rest of your recommendations, so the tab is never empty while there
    -- are any; a book that's on the device carries the badge
    local out, seen = {}, {}
    local author = d.authors and d.authors[1] and d.authors[1]:lower()
    local function take(p)
        if p.key and not seen[p.key] and norm(p.title) ~= norm(d.title) then
            seen[p.key] = true
            local mine = M.owned(p)
            table.insert(out, { online = true, key = p.key, title = p.title, author = p.author, series = p.series,
                year = p.year, cover_i = p.cover_i, dashed = true, cover_path = M.cachedCoverPath(p, "M"),
                owned = mine and mine.filepath or nil, pick = p })
        end
    end
    for _i, row in ipairs(M.rows()) do
        for _j, p in ipairs(row.items or {}) do
            if (author and p.author and p.author:lower() == author) or (d.series and p.series == d.series) then take(p) end
        end
    end
    for _i, p in ipairs(M.rowItems("all")) do
        if #out >= 12 then break end
        take(p)
    end
    return out
end


-- ---------------------------------------------------------------- want to read (A5)

function M.wantList() return Store.get("want_list") or {} end

function M.isWanted(item)
    for _i, w in ipairs(M.wantList()) do if w.key == item.key then return true end end
    return false
end

function M.toggleWant(item)
    local list = M.wantList()
    for i, w in ipairs(list) do
        if w.key == item.key then
            table.remove(list, i)
            Store.set("want_list", list)
            M.changed()
            return false
        end
    end
    table.insert(list, 1, { key = item.key, title = item.title, author = item.author, year = item.year,
        cover_i = item.cover_i, series = item.series })
    Store.set("want_list", list)
    M.changed()
    return true
end

function M.changed()
    pcall(function() require("lib/bookshelf_sources").changed("stui_want") end)
end

function M.registerSource()
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if not okS then return end
    local ok, err = Sources.register("stui_want", {
        api = 1,
        label = function() return _("Want to read (ShelfTechUI)") end,
        available = function() return true end,
        remote_prefix = "stuiwant://",
        fetch = function(_source, _drill, offset, limit)
            local list = M.wantList()
            local out = {}
            for i = (offset or 0) + 1, math.min(#list, (offset or 0) + (limit or 20)) do
                local w = list[i]
                local path = w.cover_i and (cacheDir() .. "/c" .. w.cover_i .. "M.jpg")
                local lfs = require("libs/libkoreader-lfs")
                if path and lfs.attributes(path, "mode") ~= "file" then path = nil end
                out[#out + 1] = { filepath = "stuiwant://" .. tostring(w.key):gsub("^/", ""), title = w.title,
                    authors = { w.author }, author = w.author, series_name = w.series, cover_image_path = path,
                    stui_want = w }
            end
            return out, #list
        end,
        open = function(book)
            M.showSheet(book.stui_want or { title = book.title, author = book.author, online = true })
            return true
        end,
        info = function(book)
            M.showSheet(book.stui_want or { title = book.title, author = book.author, online = true })
        end,
    })
    if not ok then logger.warn("ShelfTechUI: Want to read shelf not registered:", err) end

    local lfs = require("libs/libkoreader-lfs")
    ok, err = Sources.register("stui_online", {
        api = 1,
        label = function() return _("Online picks (ShelfTechUI)") end,
        available = function() return true end,
        remote_prefix = "stuionline://",
        fetch = function(source, _drill, offset, limit)
            if not M.enabled() then return {}, 0 end
            -- answers from what's cached; today's fetch runs in the background
            M.refreshInBackground(false)
            local list = M.rowItems(source and source.which or "daily")
            local out = {}
            -- nothing fetched yet: one card on the first shelf saying how
            local first = not source or source.which == nil or source.which == "series" or source.which == "all" or source.which == "daily"
            if #list == 0 and first and #M.rows() == 0 then
                return { { filepath = "stuionline://_setup", title = _("Recommendations"),
                    authors = { _("Turn on Wi-Fi") }, author = _("Turn on Wi-Fi"), stui_setup = true } }, 1
            end
            for i = (offset or 0) + 1, math.min(#list, (offset or 0) + (limit or 20)) do
                local p = list[i]
                local path = p.cover_i and (cacheDir() .. "/c" .. p.cover_i .. "M.jpg")
                if path and lfs.attributes(path, "mode") ~= "file" then path = nil end
                -- already on the device: its cover says so
                local mine = M.owned(p)
                local who = p.author
                if mine then
                    path = path and M.badgedCover(path) or path
                    who = _("In library") .. (p.author and (" \u{00B7} " .. p.author) or "")
                end
                out[#out + 1] = { filepath = "stuionline://" .. tostring(p.key):gsub("^/", ""), title = p.title,
                    authors = { who }, author = who, series_name = p.series, cover_image_path = path,
                    stui_pick = p, stui_owned = mine and mine.filepath or nil }
            end
            return out, #list
        end,
        refresh = function(_source, _drill, done)
            M.refreshInBackground(true)
            if done then done() end
        end,
        pick = function(draft, done)
            local items = {}
            for _i, s in ipairs(M.SHELVES) do
                table.insert(items, { text = s.label, callback = function()
                    draft.source = { kind = "stui_online", which = s.which }
                    draft.label = draft.label or s.label
                    done()
                end })
            end
            require("bos_ui").openList(items, nil, function() end)
        end,
        open = function(book)
            if book.stui_setup then M.setup() return true end
            M.showSheet(book.stui_pick or { title = book.title, author = book.author, online = true })
            return true
        end,
        info = function(book)
            if book.stui_setup then M.setup() return end
            M.showSheet(book.stui_pick or { title = book.title, author = book.author, online = true })
        end,
        -- (showSheet opens your own copy's page when the book is on the device)
    })
    if not ok then logger.warn("ShelfTechUI: online picks shelf not registered:", err) end

end

-- ---------------------------------------------------------------- finding it

--- FIND: Bookdrop's search for the title and author.
--- Bookdrop (bundled), of the UI on screen.
function M.bookdrop()
    local FM = package.loaded["apps/filemanager/filemanager"]
    local bd = FM and FM.instance and FM.instance.bookdrop
    if not bd then
        local RU = package.loaded["apps/reader/readerui"]
        bd = RU and RU.instance and RU.instance.bookdrop
    end
    return bd
end

-- ---------------------------------------------------------------- FOR YOU, recommendations only

--- 1.9.1: FOR YOU is one shelf of today's three picks, not a shelf of
--- shelves. Once: its folders go (Recommendations; Want to read, which lives
--- in the store), and the tab itself shows the three.
function M.dailyShelf()
    if Store.get("foryou_daily") then return end
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        local parent
        for _i, t in ipairs(tabs) do if t.id == "stui_foryou" then parent = t end end
        if not parent then return end
        for _i, kid in ipairs(TabModel.childrenOf("stui_foryou", tabs)) do
            if TabModel.removeTree then TabModel.removeTree(tabs, kid.id) end
        end
        for k = #tabs, 1, -1 do if tabs[k].parent == "stui_foryou" then table.remove(tabs, k) end end
        parent.source = { kind = "stui_online", which = "daily" }
        parent.view_mode = "covers"
        parent.enabled = M.enabled()
        TabModel.save(tabs)
    end)
    if not ok then logger.warn("ShelfTechUI: For you not updated:", err) end
    Store.set("foryou_daily", true)
    pcall(function() require("lib/bookshelf_sources").changed("stui_online") end)
end

--- The card shown before anything was fetched: Wi-Fi, then the fetch.
function M.setup()
    local InfoMessage = require("ui/widget/infomessage")
    pcall(function()
        require("ui/network/manager"):runWhenConnected(function()
            if M.refreshInBackground(true) or M._fetching then
                UIManager:show(InfoMessage:new{ text = _("Getting recommendations from what you've read: they'll be here in a minute."), timeout = 4 })
            else
                UIManager:show(InfoMessage:new{ text = _("Read or finish a book or two first: recommendations come from your series, authors and genres."), timeout = 5 })
            end
        end)
    end)
end

-- ---------------------------------------------------------------- in the store

--- A pick's page in the store (the libraries are asked for it there).
function M.showSheet(item)
    -- on the device already: its own page (Read, Notebook, Edit…)
    local mine = M.owned(item)
    if mine and mine.filepath then
        local ok = pcall(function() if not require("bos_bookdetail").show(mine.filepath) then error("no window") end end)
        if ok then return end
    end
    require("bos_store").openBook(item)
end

--- Search the store for a pick.
function M.find(item)
    local query = item.title or ""
    if item.author then query = query .. " " .. item.author end
    require("bos_store").open{ query = query }
end

--- The store, where the recommendations are its first row.
function M.showPicks(force)
    if force then M.refreshInBackground(true) end
    require("bos_store").open()
end

--- Want to read, as a list in the store.
function M.showWant()
    local books = {}
    for _i, it in ipairs(M.wantList()) do
        local p = { online = true, key = it.key, title = it.title, author = it.author, year = it.year,
            cover_i = it.cover_i, series = it.series }
        table.insert(books, { title = p.title, author = p.author, year = p.year, pick = p,
            cover_path = M.cachedCoverPath(p, "M") })
    end
    require("bos_store").open{ list = { title = _("Want to read"), books = books,
        empty = _("Nothing yet. Tap + WANT on a book's page to keep it here.") } }
end

return M
