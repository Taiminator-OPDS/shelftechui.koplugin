--[[
Online picks (Aleph ideas A4, A5, C6), from Open Library: opt-in (Settings →
For you → Online picks), over Wi-Fi only, fetched at most once a day, with no
account and nothing about you sent but the authors, series and genres asked
about.

  Missing from your series      books in series you've started that aren't
                                on the device
  More by authors you finish    their other works
  Popular in <your top genre>   Open Library's subject lists

Each pick opens a sheet with its description: FIND hands the title to
Bookdrop's search (its OPDS and Internet Archive sources); + WANT keeps it on
the Want to read shelf (a Bookshelf shelf, "stui_want").

The store itself is Bookdrop (bundled in bookdrop/): a Store shelf, first in
FOR YOU ("stui_store"), has a tile for its home, its search, each of its
categories and its manga reader.

On home, the picks are three shelves inside FOR YOU ("stui_online": series,
authors, genres), shown while online picks are on. They're filled from what
was fetched; the day's fetch runs in a background process when a shelf is
drawn (or you pull down to refresh), and the shelves redraw when it's done.

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

function M.enabled() return Store.get("online_picks") == true end

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
function M.rowItems(which)
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
        -- the covers the shelves show, so they draw from the cache
        for _i, row in ipairs(rows) do
            for j, p in ipairs(row.items or {}) do
                if j <= 8 then pcall(M.coverPath, p) end
            end
        end
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

--- The online shelves inside FOR YOU: added once, then shown only while
--- online picks are on.
M.SHELVES = {
    { id = "stui_fy_online_series", which = "series", label = _("Missing from your series") },
    { id = "stui_fy_online_authors", which = "authors", label = _("More by authors you finish") },
    { id = "stui_fy_online_genres", which = "genres", label = _("Popular in your genres") },
}

function M.syncShelves()
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        local by = {}
        for _i, t in ipairs(tabs) do by[t.id] = t end
        if not by.stui_foryou then return end
        local on, changed = M.enabled(), false
        local add = not Store.get("foryou_online_seeded")
        for _i, s in ipairs(M.SHELVES) do
            local t = by[s.id]
            if not t and add then
                t = { id = s.id, label = s.label, source = { kind = "stui_online", which = s.which },
                    filter = {}, sort_priority = {}, view_mode = "covers", enabled = on }
                TabModel.insertChild(tabs, "stui_foryou", t)
                -- before Want to read
                local at, want
                for i, x in ipairs(tabs) do
                    if x == t then at = i elseif x.id == "stui_fy_want" then want = i end
                end
                if at and want and want < at then
                    table.remove(tabs, at)
                    table.insert(tabs, want, t)
                end
                changed = true
            elseif t and (t.enabled ~= false) ~= on then
                t.enabled = on
                changed = true
            end
        end
        if changed then TabModel.save(tabs) end
    end)
    if not ok then logger.warn("ShelfTechUI: online shelves not updated:", err) end
    Store.set("foryou_online_seeded", true)
end

--- Settings → For you → Online picks.
function M.setEnabled(on)
    Store.set("online_picks", on and true or false)
    M.syncShelves()
    if on then M.refreshInBackground(true) end
    pcall(function() require("lib/bookshelf_sources").changed("stui_online") end)
end
function M.fresh() return store():readSetting("day") == os.date("%Y-%m-%d") end

--- Runs `fn` with fresh picks: fetched once a day, over Wi-Fi.
function M.withPicks(fn, force)
    if not M.enabled() then return fn(M.rows()) end
    if (M.fresh() and not force) or not connected() then return fn(M.rows()) end
    local InfoMessage = require("ui/widget/infomessage")
    local msg = InfoMessage:new{ text = _("Fetching picks from Open Library…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    UIManager:nextTick(function()
        local ok, rows = pcall(M.fetch)
        UIManager:close(msg)
        if not ok then logger.warn("ShelfTechUI: online picks failed:", rows) rows = M.rows() end
        local okF, err = pcall(fn, rows)
        if not okF then logger.warn("ShelfTechUI: online picks page failed:", err) end
    end)
end

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

--- The ONLINE tab of a book page: picks by its author or in its series.
function M.forBook(d)
    local out, seen = {}, {}
    local author = d.authors and d.authors[1] and d.authors[1]:lower()
    for _i, row in ipairs(M.rows()) do
        for _j, p in ipairs(row.items or {}) do
            if not seen[p.key] and ((author and p.author and p.author:lower() == author) or (d.series and p.series == d.series)) then
                seen[p.key] = true
                p.dashed = true
                p.cover_path = M.coverPath(p)
                table.insert(out, p)
            end
        end
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
            M.showSheet(book.stui_want or { title = book.title, author = book.author })
            return true
        end,
        info = function(book)
            M.showSheet(book.stui_want or { title = book.title, author = book.author })
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
            local list = M.rowItems(source and source.which or "genres")
            local out = {}
            for i = (offset or 0) + 1, math.min(#list, (offset or 0) + (limit or 20)) do
                local p = list[i]
                local path = p.cover_i and (cacheDir() .. "/c" .. p.cover_i .. "M.jpg")
                if path and lfs.attributes(path, "mode") ~= "file" then path = nil end
                out[#out + 1] = { filepath = "stuionline://" .. tostring(p.key):gsub("^/", ""), title = p.title,
                    authors = { p.author }, author = p.author, series_name = p.series, cover_image_path = path,
                    stui_pick = p }
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
            M.showSheet(book.stui_pick or { title = book.title, author = book.author })
            return true
        end,
        info = function(book)
            M.showSheet(book.stui_pick or { title = book.title, author = book.author })
        end,
    })
    if not ok then logger.warn("ShelfTechUI: online picks shelf not registered:", err) end

    ok, err = Sources.register("stui_store", {
        api = 1,
        label = function() return _("Store (Bookdrop)") end,
        available = function() return true end,
        remote_prefix = "stuistore://",
        fetch = function(_source, _drill, offset, limit)
            local list = M.storeTiles()
            local out = {}
            for i = (offset or 0) + 1, math.min(#list, (offset or 0) + (limit or 20)) do
                local tile = list[i]
                out[#out + 1] = { filepath = "stuistore://" .. tile.id, title = tile.title,
                    authors = { tile.sub }, author = tile.sub }
            end
            return out, #list
        end,
        open = function(book) return M.runStoreTile(book) end,
        info = function(book) M.runStoreTile(book) end,
    })
    if not ok then logger.warn("ShelfTechUI: Store shelf not registered:", err) end
end

-- ---------------------------------------------------------------- finding it

--- FIND: Bookdrop's search for the title and author.
--- Bookdrop (bundled), of the UI on screen.
function M.bookdrop()
    local bd
    pcall(function()
        local FM = require("apps/filemanager/filemanager").instance
        bd = FM and FM.bookdrop
        if not bd then
            local RU = require("apps/reader/readerui").instance
            bd = RU and RU.bookdrop
        end
    end)
    return bd
end

-- ---------------------------------------------------------------- the store (Bookdrop)

--- The Store shelf's tiles: Bookdrop's home, its search, its categories, manga.
function M.storeTiles()
    local bd = M.bookdrop()
    if not bd then return {} end
    local out = {
        { id = "home", title = _("Bookdrop store"), sub = _("Browse the catalogue"),
            run = function() bd:showStoreHome() end },
        { id = "search", title = _("Search the store"), sub = _("Title, author or ISBN"),
            run = function() bd:showSearchDialog() end },
    }
    local ok, cats = pcall(function() return bd:homeCategoryDefinitions() end)
    for _i, c in ipairs(ok and cats or {}) do
        table.insert(out, { id = "cat_" .. tostring(c.key), title = c.title, sub = _("Store shelf"), run = c.callback })
    end
    if bd.openManga then
        table.insert(out, { id = "manga", title = _("Manga"), sub = _("Bookdrop's manga reader"),
            run = function() bd:openManga() end })
    end
    return out
end

function M.runStoreTile(book)
    local id = tostring(book.filepath or ""):match("^stuistore://(.*)$")
    for _i, tile in ipairs(M.storeTiles()) do
        if tile.id == id then
            local ok, err = pcall(tile.run)
            if not ok then logger.warn("ShelfTechUI: store tile failed:", err) end
            return true
        end
    end
    return true
end

--- Once: a Store shelf, first in FOR YOU.
function M.seedStore()
    if Store.get("foryou_store_seeded") then return end
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        local parent_at
        for i, t in ipairs(tabs) do
            if t.id == "stui_fy_store" then return end
            if t.id == "stui_foryou" then parent_at = i end
        end
        if not parent_at then return end
        local t = { id = "stui_fy_store", label = _("Store"), source = { kind = "stui_store" },
            filter = {}, sort_priority = {}, view_mode = "covers", enabled = true }
        TabModel.insertChild(tabs, "stui_foryou", t)
        for i, x in ipairs(tabs) do
            if x == t then table.remove(tabs, i) break end
        end
        table.insert(tabs, parent_at + 1, t)
        TabModel.save(tabs)
    end)
    if not ok then logger.warn("ShelfTechUI: Store shelf not added:", err) end
    Store.set("foryou_store_seeded", true)
end

function M.find(item)
    local query = item.title or ""
    if item.author then query = query .. " " .. item.author end
    local bd = M.bookdrop()
    if bd and bd.runSearch then
        local ok, err = pcall(function() bd:runSearch(query, 1, bd.getFilters and bd:getFilters() or nil, query) end)
        if ok then return true end
        logger.warn("ShelfTechUI: Bookdrop search failed:", err)
    end
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = T(_("Bookdrop isn't installed. Search for this book in your OPDS catalogues:\n\n%1"), query) })
end

-- ---------------------------------------------------------------- the sheet

local Page = require("bos_page")

--- A pick's details at the foot of the screen: cover, title, author, year,
--- description, FIND IN BOOKDROP and + WANT.
function M.showSheet(item)
    local InputContainer = require("ui/widget/container/inputcontainer")
    local GestureRange = require("ui/gesturerange")
    local Sheet = InputContainer:extend{ name = "stui_online_sheet" }
    local W, H = Screen:getWidth(), Screen:getHeight()
    local sh = math.floor(H * 0.42)
    local rect = Geom:new{ x = S(10), y = H - sh - S(10), w = W - S(20) - Look.SHADOW, h = sh }
    function Sheet:init()
        self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
        self.ges_events = { SheetTap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
        if Device:hasKeys() then self.key_events = { Close = { { Device.input.group.Back } } } end
        self.desc = M.description(item)
        self.cover = M.coverPath(item, "M")
    end
    function Sheet:paintTo(bb)
        self.rects = {}
        local x, y, w, h = rect.x, rect.y, rect.w, rect.h
        Look.box(bb, x, y, w, h, { shadow = Look.SHADOW })
        local strip = S(26)
        Look.stripes(bb, x + Look.LINE, y + Look.LINE + S(2), w - 2 * Look.LINE, strip - S(4))
        bb:paintRect(x, y + strip, w, Look.LINE, BLACK)
        local cap = require("bos_look").case((item.series and item.series or (item.author or _("Online pick"))))
        local cw = math.min(w - S(80), Look.textWidth(cap, 9) + S(14))
        Look.box(bb, x + S(8), y + S(4), cw, strip - S(8))
        Look.label(bb, cap, x + S(8), y + S(4), cw, strip - S(8), 9, { align = "center" })
        Look.box(bb, x + w - S(36), y + S(4), S(28), strip - S(8))
        Look.label(bb, "\u{00D7}", x + w - S(36), y + S(4), S(28), strip - S(8), 12, { align = "center" })
        self.rects.close = Geom:new{ x = x + w - S(48), y = y, w = S(48), h = strip + S(8) }
        local cy = y + strip + S(14)
        local cvw, cvh = S(80), S(120)
        local _r = Page.coverRow(bb, { { dashed = true, cover_path = self.cover, title = item.title } }, x + S(6), cy, cvw + S(20), cvw,
            { no_shelf = true })
        local tx = x + S(14) + cvw + S(18)
        local tw = x + w - S(14) - tx
        local ty = cy
        ty = ty + Page.wrap(bb, item.title or "", Page.serif(16, true), tx, ty, tw, 2, S(24))
        local by = (item.author or "") .. (item.year and (" · " .. item.year) or "")
        Look.label(bb, by, tx, ty, tw, S(20), 11, { keep_case = true, bold = false })
        ty = ty + S(26)
        local bh = S(38)
        local lines = math.max(1, math.floor((y + h - S(14) - bh - S(14) - ty) / S(20)))
        if self.desc then
            Page.wrap(bb, self.desc, Page.serif(13), tx, ty, tw, lines, S(20))
        elseif not (M.enabled() and connected()) then
            Look.label(bb, _("Connect to Wi-Fi for the description."), tx, ty, tw, S(20), 9, { color = Look.GRAY })
        end
        local fy = y + h - S(14) - bh
        local fl = _("Find in Bookdrop")
        local fw = Look.textWidth(require("bos_look").case(fl), 11) + S(24)
        self.rects.find = Look.button(bb, tx, fy, fw, bh, fl, { on = true, size = 11 })
        local wl = M.isWanted(item) and _("\u{2713} Want") or _("+ Want")
        local ww = Look.textWidth(require("bos_look").case(wl), 11) + S(24)
        self.rects.want = Look.button(bb, tx + fw + S(14), fy, ww, bh, wl, { size = 11 })
    end
    function Sheet:onSheetTap(_, ges)
        local pos = ges.pos
        local r = self.rects or {}
        if Page.inside(pos, r.close) or not Page.inside(pos, rect) then UIManager:close(self)
        elseif Page.inside(pos, r.find) then UIManager:close(self) M.find(item)
        elseif Page.inside(pos, r.want) then
            M.toggleWant(item)
            UIManager:setDirty(self, "ui", rect)
        end
        return true
    end
    function Sheet:onClose() UIManager:close(self) return true end
    function Sheet:onShow() UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = rect.y, w = W, h = H - rect.y }) return true end
    function Sheet:onCloseWidget() UIManager:setDirty(nil, "ui", Geom:new{ x = 0, y = rect.y, w = W, h = H - rect.y }) end
    UIManager:show(Sheet:new{})
end

-- ---------------------------------------------------------------- the page

--- FOR YOU · ONLINE: the picks as store rows.
function M.showPicks(force)
    if not M.enabled() then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Online picks are off. Turn them on in Settings → For you → Online picks (Wi-Fi only, fetched once a day from Open Library).") })
        return
    end
    M.withPicks(function(rows)
        local function draw(self, bb, y, w)
            local x = self.pad
            local W, H = Screen:getWidth(), Screen:getHeight()
            local day = store():readSetting("day")
            local info = day and T(_("Open Library · updated %1"), day) or _("Open Library · not fetched yet")
            Look.label(bb, info, x, y - S(6), w - S(150), S(20), 9, { color = Look.GRAY })
            Look.label(bb, _("Dashed = not on device"), x, y - S(6), w, S(20), 9, { color = Look.GRAY, align = "right" })
            y = y + S(22)
            if #rows == 0 then
                local msg = connected() and _("Nothing found yet: read and finish a few books, then pull down to refresh.")
                    or _("Connect to Wi-Fi, then pull down to fetch picks.")
                Page.wrap(bb, msg, Page.serif(15, false, true), x, y + S(20), w, 4, S(24))
                return
            end
            local cw = S(60)
            for _i, row in ipairs(rows) do
                if y + S(22) + cw * 1.5 + S(30) > H then break end
                Page.heading(bb, row.title, x, y, w)
                y = y + S(28)
                local items = {}
                for _j, p in ipairs(row.items) do
                    p.dashed = true
                    p.cover_path = M.coverPath(p)
                    table.insert(items, p)
                end
                local rects, rh = Page.coverRow(bb, items, x, y, w, cw)
                for j, r in ipairs(rects) do
                    local p = items[j]
                    self:hit(r, function() M.showSheet(p) end)
                end
                y = y + rh + S(10)
            end
        end
        Page:new{ caption = _("For you · Online"), draw = draw,
            on_more = function(self, rect)
                require("bos_ui").openList({
                    { text = _("Refresh now"), callback = function() self:onClose() M.showPicks(true) end },
                    { text = _("Want to read"), callback = function() M.showWant() end },
                }, rect)
            end }:show()
    end, force)
end

function M.showWant()
    local function draw(self, bb, y, w)
        local list = M.wantList()
        if #list == 0 then
            Page.wrap(bb, _("Nothing yet. Tap + WANT on an online pick to keep it here."), Page.serif(15, false, true),
                self.pad, y + S(10), w, 3, S(24))
            return
        end
        local items = {}
        for _i, it in ipairs(list) do
            local p = { online = true, key = it.key, title = it.title, author = it.author, year = it.year,
                cover_i = it.cover_i, series = it.series, dashed = true }
            p.cover_path = M.coverPath(p)
            table.insert(items, p)
        end
        local cw = S(70)
        local per = math.max(1, math.floor((w + S(14)) / (cw + S(14))))
        for r0 = 1, #items, per do
            local row = {}
            for i = r0, math.min(#items, r0 + per - 1) do table.insert(row, items[i]) end
            local rects, rh = Page.coverRow(bb, row, self.pad, y, w, cw)
            for j, r in ipairs(rects) do self:hit(r, function() M.showSheet(row[j]) end) end
            y = y + rh + S(14)
            if y > Screen:getHeight() - S(120) then break end
        end
    end
    Page:new{ caption = _("Want to read"), draw = draw }:show()
end

return M
