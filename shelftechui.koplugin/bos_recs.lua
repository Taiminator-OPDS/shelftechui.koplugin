--[[
Recommendations from your own library (Aleph idea A1, taken further).

Every book is scored against what you read: the same author, the same series,
shared genres and subjects (Calibre's metadata.opf included, through
Bookshelf), weighted by your stars and by what you finished, kept reading, or
put on hold. Nothing leaves the device.

  lists:  because    Because you read <the book you finished last>
          upnext     Up next in series (the next unread after your furthest)
          pickup     Pick back up (started, not opened for a while, or on hold)
          authors    More by authors you finish
          genres     Unread in your top genres
          discover   Everything unread, best matches first, lightly shuffled
                     each day
  byAuthor(fp), series(fp): for the series and author pages

These are Bookshelf shelf sources ("For you"), so they're shelves like any
other: on home, in a shelf of shelves, in any view.
--]]

local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local M = {}

M.LISTS = {
    { id = "because", label = _("Because you read…") },
    { id = "upnext", label = _("Up next in series") },
    { id = "pickup", label = _("Pick back up") },
    { id = "authors", label = _("More by authors you finish") },
    { id = "genres", label = _("Unread in your top genres") },
    { id = "discover", label = _("Discover") },
}

local function repo()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    return ok and Repo or nil
end

local function lower(s) return type(s) == "string" and s:lower() or nil end

local function stateOf(b)
    if b.status == "finished" or b.status == "complete" then return "finished" end
    if b.status == "on_hold" or b.status == "abandoned" then return "on_hold" end
    if b.pct and b.pct >= 0.99 then return "finished" end
    if b.status == "reading" or (b.pct and b.pct > 0) then return "reading" end
    return "unread"
end

-- ---------------------------------------------------------------- the library

local lib = { gen = nil }

--- Every book with what it's about and how far you are, plus your profile
--- (author and genre weights), rebuilt when Bookshelf's data changes.
function M.library()
    local Repo = repo()
    if not Repo then return nil end
    local gen = Repo.dataGeneration and Repo.dataGeneration()
    if lib.books and lib.gen == gen and lib.at and os.time() - lib.at < 600 then return lib end
    local books = {}
    local ok, err = pcall(function()
        local list = Repo.getAll(nil, 100000, 0, nil, nil, { light_only = true, lazy_cover = true }) or {}
        local opened = {}
        pcall(function()
            for i, e in ipairs(require("readhistory").hist or {}) do
                if e.file and not opened[e.file] then opened[e.file] = { time = e.time, rank = i } end
            end
        end)
        local hydrated = 0
        for _i, r in ipairs(list) do
            local fp = r.filepath
            -- a book KOReader hasn't indexed yet: read its metadata once
            if type(fp) == "string" and (not r.authors or #r.authors == 0) and hydrated < 400 then
                hydrated = hydrated + 1
                local okM, meta = pcall(Repo.buildBookMeta, fp, { want_cover = false })
                if okM and type(meta) == "table" and meta.title then r = meta end
            end
            if type(fp) == "string" then
                local pct, status, rating = Repo.readProgress(fp)
                local b = {
                    rec = r, filepath = fp, title = r.title, authors = r.authors or {},
                    series = r.series_name, series_num = tonumber(r.series_num),
                    genres = {}, pct = pct, status = status, rating = tonumber(rating),
                    opened = opened[fp] and opened[fp].time, rank = opened[fp] and opened[fp].rank,
                }
                for _j, g in ipairs(r.genres or {}) do
                    local k = lower(g)
                    if k and k ~= "" then table.insert(b.genres, k) end
                end
                b.state = stateOf(b)
                -- lower-cased once, for the library's search (E2)
                b.hay = ((b.title or "") .. " " .. table.concat(b.authors, " ") .. " " .. (b.series or "")):lower()
                b.akeys = {}
                for _j, a in ipairs(b.authors) do local k = lower(a) if k then b.akeys[k] = true end end
                b.skey = lower(b.series)
                table.insert(books, b)
            end
        end
    end)
    if not ok then logger.warn("ShelfTechUI: recommendations could not read the library:", err) end
    -- the profile: what you finish, rate and abandon
    local aw, gw, seen_series = {}, {}, {}
    for _i, b in ipairs(books) do
        local w = ({ finished = 3, reading = 1, on_hold = -1.5 })[b.state] or 0
        if b.rating then w = w + (b.rating - 3) * 1.5 end
        if w ~= 0 then
            for k in pairs(b.akeys) do aw[k] = (aw[k] or 0) + w end
            for _j, g in ipairs(b.genres) do gw[g] = (gw[g] or 0) + w * 0.6 end
        end
        if b.skey and b.state ~= "unread" then seen_series[b.skey] = true end
    end
    lib = { books = books, gen = gen, at = os.time(), aw = aw, gw = gw, seen_series = seen_series }
    return lib
end

function M.invalidate() lib = { gen = nil } end

--- After reading: the order you opened books in (from the history), and
--- `fp`'s progress, brought up to date without rebuilding the library (a
--- rebuild reads every book's record: ~0.1 s per 300 books on an e-reader).
function M.touch(fp)
    if not lib.books then return end
    local opened = {}
    pcall(function()
        for i, e in ipairs(require("readhistory").hist or {}) do
            if e.file and not opened[e.file] then opened[e.file] = { time = e.time, rank = i } end
        end
    end)
    local Repo = repo()
    for _i, b in ipairs(lib.books) do
        local o = opened[b.filepath]
        b.opened, b.rank = o and o.time, o and o.rank
        if fp and b.filepath == fp and Repo then
            local okP, pct, status, rating = pcall(Repo.readProgress, fp)
            if okP then
                b.pct, b.status, b.rating = pct, status, tonumber(rating)
                b.state = stateOf(b)
            end
        end
    end
end

--- How well an unread book fits what you read.
local function score(L, b)
    local s = 0
    for k in pairs(b.akeys) do s = s + math.max(-3, (L.aw[k] or 0)) end
    for _j, g in ipairs(b.genres) do s = s + (L.gw[g] or 0) * 0.5 end
    if b.skey and L.seen_series[b.skey] then s = s + 2 end
    return s
end

--- Likeness of two books (for "Similar" and "Because you read").
local function likeness(a, b)
    local s = 0
    for k in pairs(a.akeys) do if b.akeys[k] then s = s + 4 end end
    if a.skey and a.skey == b.skey then s = s + 5 end
    local ga = {}
    for _i, g in ipairs(a.genres) do ga[g] = true end
    for _i, g in ipairs(b.genres) do if ga[g] then s = s + 2 end end
    return s
end

local function find(L, fp)
    for _i, b in ipairs(L.books) do if b.filepath == fp then return b end end
end

local function sortBy(list, f)
    table.sort(list, function(a, b)
        local x, y = f(a), f(b)
        if x ~= y then return x > y end
        return (a.title or "") < (b.title or "")
    end)
    return list
end

-- ---------------------------------------------------------------- the lists

--- The book you finished last (for "Because you read …").
function M.lastFinished()
    local L = M.library()
    if not L then return nil end
    local best
    for _i, b in ipairs(L.books) do
        if b.state == "finished" and b.rank and (not best or b.rank < best.rank) then best = b end
    end
    return best
end

function M.list(which, limit)
    local L = M.library()
    if not L then return {} end
    limit = limit or 60
    local out = {}
    if which == "because" then
        local seed = M.lastFinished()
        if not seed then return {} end
        for _i, b in ipairs(L.books) do
            if b ~= seed and b.state == "unread" then
                local s = likeness(seed, b)
                if s > 0 then b._s = s + score(L, b) * 0.2 table.insert(out, b) end
            end
        end
        sortBy(out, function(b) return b._s end)
    elseif which == "upnext" then
        -- per series: the next unread after the furthest one you've read
        local by = {}
        for _i, b in ipairs(L.books) do
            if b.skey then
                local s = by[b.skey] or { books = {}, last_read = nil, active = 0 }
                table.insert(s.books, b)
                if b.state ~= "unread" and b.series_num then
                    s.last_read = math.max(s.last_read or -1, b.series_num)
                end
                if b.opened then s.active = math.max(s.active, b.opened) end
                by[b.skey] = s
            end
        end
        for _k, s in pairs(by) do
            if s.last_read then
                local nxt
                for _i, b in ipairs(s.books) do
                    if b.state == "unread" and b.series_num and b.series_num > s.last_read
                            and (not nxt or b.series_num < nxt.series_num) then nxt = b end
                end
                if nxt then nxt._s = s.active table.insert(out, nxt) end
            end
        end
        sortBy(out, function(b) return b._s end)
    elseif which == "pickup" then
        local now = os.time()
        for _i, b in ipairs(L.books) do
            if b.state == "on_hold" or (b.state == "reading" and (not b.opened or now - b.opened > 7 * 86400)) then
                b._s = b.opened or 0
                table.insert(out, b)
            end
        end
        sortBy(out, function(b) return b._s end)
    elseif which == "authors" then
        for _i, b in ipairs(L.books) do
            if b.state == "unread" then
                local s = 0
                for k in pairs(b.akeys) do s = math.max(s, L.aw[k] or 0) end
                if s >= 3 then b._s = s + score(L, b) * 0.1 table.insert(out, b) end
            end
        end
        sortBy(out, function(b) return b._s end)
    elseif which == "genres" then
        local top = {}
        for g, w in pairs(L.gw) do if w > 0 then table.insert(top, { g = g, w = w }) end end
        table.sort(top, function(a, b) return a.w > b.w end)
        local want = {}
        for i = 1, math.min(3, #top) do want[top[i].g] = top[i].w end
        for _i, b in ipairs(L.books) do
            if b.state == "unread" then
                local s = 0
                for _j, g in ipairs(b.genres) do s = s + (want[g] or 0) end
                if s > 0 then b._s = s table.insert(out, b) end
            end
        end
        sortBy(out, function(b) return b._s end)
    elseif which == "discover" then
        -- ranked picks, shuffled a little (the same order all day)
        local seed = tonumber(os.date("%Y%j"))
        local function jitter(fp)
            local h = seed
            for i = 1, #fp do h = (h * 31 + fp:byte(i)) % 1000003 end
            return (h % 1000) / 1000
        end
        local maxs = 1
        for _i, b in ipairs(L.books) do
            if b.state == "unread" then
                b._s = score(L, b)
                maxs = math.max(maxs, math.abs(b._s))
                table.insert(out, b)
            end
        end
        for _i, b in ipairs(out) do b._s = b._s + jitter(b.filepath) * maxs * 0.35 end
        sortBy(out, function(b) return b._s end)
    end
    while #out > limit do table.remove(out) end
    return out
end

function M.byAuthor(author)
    local L = M.library()
    local k = lower(author)
    if not (L and k) then return {} end
    local out = {}
    for _i, b in ipairs(L.books) do if b.akeys[k] then table.insert(out, b) end end
    table.sort(out, function(x, y)
        if x.skey ~= y.skey then return (x.skey or "~") < (y.skey or "~") end
        if x.series_num and y.series_num and x.series_num ~= y.series_num then return x.series_num < y.series_num end
        return (x.title or "") < (y.title or "")
    end)
    return out
end

function M.series(name)
    local L = M.library()
    local k = lower(name)
    if not (L and k) then return {} end
    local out = {}
    for _i, b in ipairs(L.books) do if b.skey == k then table.insert(out, b) end end
    table.sort(out, function(x, y) return (x.series_num or 999) < (y.series_num or 999) end)
    return out
end

function M.book(fp)
    local L = M.library()
    return L and find(L, fp)
end

--- Your top genres (for online picks): { "science fiction", ... }
function M.topGenres(n)
    local L = M.library()
    local top = {}
    for g, w in pairs(L and L.gw or {}) do if w > 0 then table.insert(top, { g = g, w = w }) end end
    table.sort(top, function(a, b) return a.w > b.w end)
    local out = {}
    for i = 1, math.min(n or 3, #top) do out[i] = top[i].g end
    return out
end

--- Authors you finish, most finished first.
function M.topAuthors(n)
    local L = M.library()
    local names, w = {}, {}
    for _i, b in ipairs(L and L.books or {}) do
        for _j, a in ipairs(b.authors) do
            local k = lower(a)
            if k and (L.aw[k] or 0) >= 3 and not w[k] then
                w[k] = L.aw[k]
                table.insert(names, a)
            end
        end
    end
    table.sort(names, function(a, b) return w[a:lower()] > w[b:lower()] end)
    while #names > (n or 3) do table.remove(names) end
    return names
end

--- Series you've started, with the books you have of each.
function M.startedSeries()
    local L = M.library()
    local out, seen = {}, {}
    for _i, b in ipairs(L and L.books or {}) do
        if b.skey and L.seen_series[b.skey] and not seen[b.skey] then
            seen[b.skey] = true
            table.insert(out, { name = b.series, author = b.authors[1] })
        end
    end
    return out
end

-- ---------------------------------------------------------------- Bookshelf shelves

local SOURCE_ID = "stui_foryou"

local function labelFor(which)
    if which == "because" then
        local seed = M.lastFinished()
        return seed and T(_("Because you read %1"), seed.title or "") or _("Because you read…")
    end
    for _i, l in ipairs(M.LISTS) do if l.id == which then return l.label end end
    return _("For you")
end
M.labelFor = labelFor

function M.registerSource()
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if not okS then return end
    local ok, err = Sources.register(SOURCE_ID, {
        api = 1,
        label = function() return _("For you (ShelfTechUI)") end,
        available = function() return true end,
        -- fetch mode: the lists keep their own order (best first)
        fetch = function(source, _drill, offset, limit)
            local which = source and source.which or "discover"
            if which == "because" then M.relabelBecause() end
            local list = M.list(which, 200)
            local out = {}
            for i = (offset or 0) + 1, math.min(#list, (offset or 0) + (limit or 20)) do
                out[#out + 1] = list[i].rec
            end
            return out, #list
        end,
        refresh = function(_source, _drill, done)
            M.invalidate()
            if done then done() end
        end,
        pick = function(draft, done)
            local UI = require("bos_ui")
            local items = {}
            for _i, l in ipairs(M.LISTS) do
                table.insert(items, { text = l.label, callback = function()
                    draft.source = { kind = SOURCE_ID, which = l.id }
                    draft.label = draft.label or labelFor(l.id)
                    done()
                end })
            end
            UI.openList(items, nil, function() end)
        end,
    })
    if not ok then logger.warn("ShelfTechUI: For you shelves not registered:", err) end
end

--- "Because you read X" follows the last book you finished.
function M.relabelBecause()
    pcall(function()
        local TabModel = require("lib/bookshelf_tab_model")
        local want = labelFor("because")
        local tabs = TabModel.load()
        local changed = false
        for _i, t in ipairs(tabs) do
            if type(t.source) == "table" and t.source.kind == SOURCE_ID and t.source.which == "because"
                    and t.label ~= want and (t.auto_label ~= false) then
                t.label = want
                changed = true
            end
        end
        if changed then TabModel.saveDeferred(tabs) end
    end)
end

--- Once: a FOR YOU shelf of shelves on home, holding the lists (and the
--- want-to-read list).
function M.seed()
    local Store = require("bos_settings_store")
    if Store.get("foryou_seeded") then return end
    local okT, TabModel = pcall(require, "lib/bookshelf_tab_model")
    if not okT then return end
    local ok, err = pcall(function()
        local tabs = TabModel.load()
        for _i, t in ipairs(tabs) do if t.id == "stui_foryou" then return end end
        -- on a spine shelf, each list stands as its own labelled run of books
        local parent = { id = "stui_foryou", label = _("For you"), source = { kind = TabModel.SHELVES_KIND },
            filter = {}, sort_priority = {}, view_mode = "spines", enabled = true }
        local anchor = tabs[1] and tabs[1].id
        if anchor then TabModel.insertAfter(tabs, anchor, parent) else table.insert(tabs, parent) end
        -- (1.7.0: FOR YOU is the recommendations from the internet, added by
        -- bos_online.syncShelves, and Want to read; the lists from your own
        -- library are a row on the Dash layout)
        local kids = {}
        for _i, which in ipairs(kids) do
            TabModel.insertChild(tabs, "stui_foryou", { id = "stui_fy_" .. which, label = labelFor(which),
                source = { kind = SOURCE_ID, which = which }, filter = {}, sort_priority = {},
                view_mode = "covers", enabled = true })
        end
        TabModel.insertChild(tabs, "stui_foryou", { id = "stui_fy_want", label = _("Want to read"),
            source = { kind = "stui_want" }, filter = {}, sort_priority = {}, view_mode = "covers", enabled = true })
        TabModel.save(tabs)
    end)
    if not ok then logger.warn("ShelfTechUI: For you shelf not added:", err) end
    Store.set("foryou_seeded", true)
end

return M
