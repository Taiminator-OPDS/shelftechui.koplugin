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
    { id = "stui_fy_online_series", which = "series", label = _("More in your series") },
    { id = "stui_fy_online_authors", which = "authors", label = _("More by authors you read") },
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
            local list = M.rowItems(source and source.which or "genres")
            local out = {}
            -- nothing fetched yet: one card on the first shelf saying how
            if #list == 0 and (source and source.which) == "series" and #M.rows() == 0 then
                return { { filepath = "stuionline://_setup", title = _("Recommendations"),
                    authors = { _("Turn on Wi-Fi") }, author = _("Turn on Wi-Fi"), stui_setup = true } }, 1
            end
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
            if book.stui_setup then M.setup() return true end
            M.showSheet(book.stui_pick or { title = book.title, author = book.author, online = true })
            return true
        end,
        info = function(book)
            if book.stui_setup then M.setup() return end
            M.showSheet(book.stui_pick or { title = book.title, author = book.author, online = true })
        end,
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

--- Once (1.7.0): FOR YOU holds the recommendations (and Want to read)
--- only. The lists from your own library (Because you read, Up next…) and
--- the Store tiles leave it; recommendations are turned on.
function M.forYouOnlineOnly()
    if Store.get("foryou_online_only") then return end
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    if Store.get("online_picks") == nil then Store.set("online_picks", true) end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        local changed = false
        for _i, id in ipairs{ "stui_fy_because", "stui_fy_upnext", "stui_fy_pickup", "stui_fy_authors", "stui_fy_genres",
                "stui_fy_discover", "stui_fy_store" } do
            for k = #tabs, 1, -1 do
                if tabs[k].id == id then
                    if TabModel.removeTree then TabModel.removeTree(tabs, id) else table.remove(tabs, k) end
                    changed = true
                    break
                end
            end
        end
        local by = {}
        for _i, s in ipairs(M.SHELVES) do by[s.id] = s end
        for _i, t in ipairs(tabs) do
            if by[t.id] and t.label ~= by[t.id].label then t.label = by[t.id].label changed = true end
        end
        if changed then TabModel.save(tabs) end
    end)
    if not ok then logger.warn("ShelfTechUI: For you not updated:", err) end
    Store.set("foryou_online_only", true)
    Store.set("foryou_online_seeded", nil) -- (add the three shelves if they were never added)
    M.syncShelves()
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
