--[[
The Store: one screen, in the theme, over Bookdrop's libraries.

  M.open()               the storefront
  M.open{ query = … }    straight to results for a search
  M.open{ search = true } the storefront with the keyboard up
  M.openBook(book)       a book's page: a library's book, or a
                         recommendation (bos_online pick): its page shows at
                         once, and the libraries are asked for it

What's on it (as on a Kindle's or a Kobo's store):
  * a search field always at the top. Type, and the list under it follows:
    each library is asked in the background (its own process, at most three
    at a time) and the list fills in as each answers. Nothing waits for
    "Search" to be pressed, and nothing blocks the keyboard.
  * the storefront: Recommended for you (from what you read), Recently
    viewed, shelves of covers, and the categories to browse.
  * a book's page: cover, title, author, where it's from, one Download key,
    other formats, the description, more by the author.

Bookdrop (bundled, bookdrop/) still does the work: its libraries
(bookdrop_catalog_provider), cover cache, filters (which libraries, formats,
language) and downloads. Only the screens are new.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local _ = require("gettext")
local T = ffiutil.template

local Look = require("bos_look")
local Page = require("bos_page")
local UI = require("bos_ui")

local Screen = Device.screen
local S = Look.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and UI.boldFace(size)) or (italic and UI.italicFace(size)) or UI.face(size)
end

local function bookdrop() return require("bos_online").bookdrop() end
local function Provider() return require("bookdrop_catalog_provider") end
local function CoverCache() return require("bookdrop_covercache") end

-- ---------------------------------------------------------------- background work

-- One task = one forked process; its answer comes back through a pipe and
-- the callback runs here, on the UI's own loop. At most MAX at a time (each
-- is a copy of KOReader: a Kindle hasn't the memory for more), the rest
-- wait their turn. A task that can't be started is reported, never run
-- here: the screen must not freeze on a slow library.
local Async = { running = {}, waiting = {}, MAX = 3 }
local okBuf, buffer = pcall(require, "string.buffer")

local function encode(v)
    if not okBuf then return nil end
    local ok, s = pcall(buffer.encode, v)
    return ok and s or nil
end

local function decode(s)
    if not (okBuf and s and s ~= "") then return nil end
    local ok, v = pcall(buffer.decode, s)
    return ok and v or nil
end

local function collectLater(pid, fd)
    local tries = 0
    local function collect()
        tries = tries + 1
        if ffiutil.isSubProcessDone(pid) then
            if fd then pcall(ffiutil.readAllFromFD, fd) end
            return
        end
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            pcall(ffiutil.readAllFromFD, fd)
            fd = nil
        end
        if tries < 60 then UIManager:scheduleIn(2, collect) end
    end
    UIManager:scheduleIn(1, collect)
end

local function startJob(job)
    local ok, pid, fd = pcall(ffiutil.runInSubProcess, function(_pid, wfd)
        local r = table.pack(pcall(job.fn))
        local out
        if r[1] then
            out = encode({ ok = true, n = r.n - 1, unpack(r, 2, r.n) })
        else
            out = encode({ ok = false, err = tostring(r[2]) })
        end
        ffiutil.writeToFD(wfd, out or encode({ ok = false, err = "the answer could not be passed back" }) or "", true)
    end, true)
    if not ok or not pid then
        job.failed = true
        return false
    end
    job.pid, job.fd = pid, fd
    job.deadline = os.time() + (job.timeout or 25)
    return true
end

local poll
local function pump()
    -- start what can be started
    while #Async.running < Async.MAX and #Async.waiting > 0 do
        local job = table.remove(Async.waiting, 1)
        if not job.cancelled then
            if startJob(job) then
                table.insert(Async.running, job)
            else
                pcall(job.cb, false, "busy")
            end
        end
    end
    if #Async.running > 0 and not Async.polling then
        Async.polling = true
        UIManager:scheduleIn(0.15, poll)
    end
end

poll = function()
    Async.polling = false
    for i = #Async.running, 1, -1 do
        local job = Async.running[i]
        local done
        if job.cancelled then
            pcall(ffiutil.terminateSubProcess, job.pid)
            collectLater(job.pid, job.fd)
            done = true
        else
            local ready = job.fd and ffiutil.getNonBlockingReadSize(job.fd) ~= 0
            if ready or ffiutil.isSubProcessDone(job.pid) then
                local s = job.fd and ffiutil.readAllFromFD(job.fd) or ""
                local pid = job.pid
                if not ffiutil.isSubProcessDone(pid) then
                    UIManager:scheduleIn(1, function() ffiutil.isSubProcessDone(pid, true) end)
                end
                local r = decode(s)
                done = true
                if r and r.ok then
                    local ok, err = pcall(job.cb, true, unpack(r, 1, r.n or #r))
                    if not ok then logger.warn("ShelfTechUI: store:", err) end
                else
                    pcall(job.cb, false, r and r.err or "no answer")
                end
            elseif os.time() > job.deadline then
                pcall(ffiutil.terminateSubProcess, job.pid)
                collectLater(job.pid, job.fd)
                done = true
                pcall(job.cb, false, "timed out")
            end
        end
        if done then table.remove(Async.running, i) end
    end
    pump()
end

--- Run fn in the background; cb(ok, ...) with what it returned (or false,
--- why). Returns the job: job.cancelled = true drops it.
function Async.run(fn, cb, timeout)
    local job = { fn = fn, cb = cb, timeout = timeout }
    table.insert(Async.waiting, job)
    pump()
    return job
end
M.Async = Async

-- ---------------------------------------------------------------- a search

local Search = { cache = {}, order = {} }

local function searchKey(query, page, filters)
    local parts = { tostring(query or ""), tostring(page or 1), tostring(filters.content or ""),
        tostring(filters.language or ""), tostring(filters.sort or "") }
    local libs = {}
    for k, v in pairs(filters.libraries or {}) do if v == true then libs[#libs + 1] = k end end
    table.sort(libs)
    local fm = {}
    for k, v in pairs(filters.formats or {}) do if v == true then fm[#fm + 1] = k end end
    table.sort(fm)
    return table.concat(parts, "\1") .. "\1" .. table.concat(libs, ",") .. "\1" .. table.concat(fm, ",")
end

local function merge(session)
    local P = Provider()
    local books = {}
    for _i, part in ipairs(session.parts) do
        for _j, b in ipairs(part) do books[#books + 1] = b end
    end
    local q = session.query
    if q and q:match("%S") and P.matchesQuery then
        local keep = {}
        for _i, b in ipairs(books) do if P.matchesQuery(b, q) then keep[#keep + 1] = b end end
        books = keep
    end
    local ok, sorted = pcall(M.sortBooks, books, q, session.filters.sort, session.filters)
    session.books = ok and sorted or books
end

--- Other ways to ask for a title with its author in it ("dracula bram
--- stoker", "stoker dracula", "Dracula by Bram Stoker"): the title alone and
--- the author alone, the author at the end or at the start. What they
--- bring back is still kept only if it matches every word typed (title and
--- author together), so this only finds more, never less exact.
function M.subQueries(query)
    local q = tostring(query or ""):gsub("[,;]", " ")
    local out, seen = {}, { [q:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")] = true }
    local function add(t)
        t = t:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        local k = t:lower()
        if t ~= "" and not seen[k] then seen[k] = true out[#out + 1] = t end
    end
    local before, after = q:match("^(.-)%s+[Bb][Yy]%s+(.+)$")
    if before then add(before) add(after) end
    local w = {}
    for x in q:gmatch("%S+") do if x:lower() ~= "by" then w[#w + 1] = x end end
    local n = #w
    if n >= 3 then
        add(table.concat(w, " ", 1, n - 2))   -- the title, an author after it
        add(table.concat(w, " ", n - 1, n))   -- that author
        add(table.concat(w, " ", 3, n))       -- the title, an author before it
    elseif n == 2 then
        add(w[1]) add(w[2])
    end
    while #out > 3 do table.remove(out) end
    return out
end

--- Ask every chosen library for `query` (page `page`); on_update(session)
--- each time one answers. session: books (merged, best first), answered,
--- total (libraries), errors, finished, has_next.
function Search.start(query, page, filters, on_update, exact)
    local P = Provider()
    local session = { query = query, page = page or 1, filters = filters, parts = {}, books = {}, errors = {},
        answered = 0, total = 0, jobs = {}, has_next = false }
    local key = searchKey(query, page, filters)
    local hit = Search.cache[key]
    if hit and os.time() - hit.at < 600 then
        session.books, session.has_next, session.errors = hit.books, hit.has_next, {}
        session.total, session.answered, session.finished = hit.total, hit.total, true
        UIManager:nextTick(function() if not session.cancelled then on_update(session) end end)
        return session
    end
    local sources = {}
    for _i, id in ipairs(P.source_order) do
        if type(filters.libraries) ~= "table" or filters.libraries[id] == true then sources[#sources + 1] = id end
    end
    session.total = #sources
    if #sources == 0 then
        session.finished = true
        session.errors = { _("No libraries are chosen (Settings → Connect → Store).") }
        UIManager:nextTick(function() on_update(session) end)
        return session
    end
    for _i, id in ipairs(sources) do
        local job = Async.run(function()
            local result, err = P:searchSource(id, query, page, filters)
            -- none that match every word (a title and its author, typed
            -- together, which a library's own search may not take): ask
            -- for the title and the author on their own too
            local long = 0
            for w in tostring(query or ""):gmatch("[^%s,;]+") do if #w >= 3 and w:lower() ~= "the" then long = long + 1 end end
            if not exact and (page or 1) == 1 and P.matchesQuery and long >= 2 then
                local books = type(result) == "table" and result.books or {}
                local good = 0
                for _j, b in ipairs(books) do if P.matchesQuery(b, query) then good = good + 1 end end
                if good == 0 then
                    local have = {}
                    for _j, b in ipairs(books) do have[(b.title or "") .. "\0" .. (b.author or "")] = true end
                    for _k, sub in ipairs(M.subQueries(query)) do
                        local ok2, r2 = pcall(P.searchSource, P, id, sub, 1, filters)
                        for _j, b in ipairs(ok2 and type(r2) == "table" and r2.books or {}) do
                            local k = (b.title or "") .. "\0" .. (b.author or "")
                            if not have[k] and P.matchesQuery(b, query) then
                                have[k] = true
                                books[#books + 1] = b
                            end
                        end
                    end
                    if type(result) ~= "table" then result = { books = books } else result.books = books end
                    err = (#books > 0) and nil or err
                end
            end
            -- (most popular: Project Gutenberg's books with their download counts)
            if id == "gutenberg" and filters and filters.sort == "popular" and type(result) == "table" and result.books then
                pcall(M.gutenbergCounts, result.books)
            end
            return result, err
        end, function(ok, result, err)
            if session.cancelled then return end
            session.answered = session.answered + 1
            if ok and type(result) == "table" and result.books then
                for _j, b in ipairs(result.books) do b.provider = b.provider or id end
                table.insert(session.parts, result.books)
                session.has_next = session.has_next or result.has_next == true
            else
                table.insert(session.errors, (P.sources[id] or id) .. ": " .. tostring((ok and err) or result or err or "no answer"))
            end
            merge(session)
            if session.answered >= session.total then
                session.finished = true
                if #session.errors == 0 then
                    Search.cache[key] = { books = session.books, has_next = session.has_next, total = session.total, at = os.time() }
                    table.insert(Search.order, key)
                    while #Search.order > 16 do Search.cache[table.remove(Search.order, 1)] = nil end
                end
            end
            on_update(session)
        end, 45)
        table.insert(session.jobs, job)
    end
    return session
end

function Search.cancel(session)
    if not session then return end
    session.cancelled = true
    for _i, job in ipairs(session.jobs or {}) do job.cancelled = true end
end
M.Search = Search

-- ---------------------------------------------------------------- drawing pieces

local img_cache, img_order = {}, {}
local function imageAt(path, w, h)
    local key = path .. "@" .. w .. "x" .. h
    if img_cache[key] ~= nil then return img_cache[key] or nil end
    local ok, bb = pcall(function() return require("ui/renderimage"):renderImageFile(path, false, w, h) end)
    img_cache[key] = (ok and bb) or false
    table.insert(img_order, key)
    while #img_order > 30 do
        local old = table.remove(img_order, 1)
        local e = img_cache[old]
        img_cache[old] = nil
        if e then pcall(function() e:free() end) end
    end
    return img_cache[key] or nil
end

local function freeImages()
    for _k, e in pairs(img_cache) do if e then pcall(function() e:free() end) end end
    img_cache, img_order = {}, {}
end

--- A book's cover in w x h (its picture if there is one, else its title on
--- a card), with the theme's shadow.
local function drawCover(bb, b, x, y, w, h)
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW_SMALL, border = math.max(1, S(1)) })
    local path = b.cover_path
    local img = path and imageAt(path, w - 2, h - 2)
    if img then
        bb:blitFrom(img, x + math.floor((w - img:getWidth()) / 2), y + math.floor((h - img:getHeight()) / 2),
            0, 0, img:getWidth(), img:getHeight())
        local d = math.max(1, S(1))
        bb:paintRect(x, y, w, d, Look.INK) bb:paintRect(x, y + h - d, w, d, Look.INK)
        bb:paintRect(x, y, d, h, Look.INK) bb:paintRect(x + w - d, y, d, h, Look.INK)
    else
        local fs = math.max(8, math.floor(w / 9))
        Page.wrap(bb, b.title or "", Look.serif(fs, true), x + S(6), y + S(8), w - S(12), 4, math.floor(fs * 1.5))
        if b.author then
            Look.label(bb, b.author, x + S(6), y + h - S(22), w - S(12), S(16), math.max(7, math.floor(w / 14)), { color = Look.GRAY })
        end
    end
    -- on the device already
    if b.owned then pcall(function() require("bos_online").paintBadge(bb, x + 1, y, w - 2, h - 1) end) end
end

local function glyphKey(bb, x, y, w, h, glyph, on)
    return Look.button(bb, x, y, w, h, nil, { on = on, paint = function(b2, bx, by, bw, bh, ink)
        local tw = TextWidget:new{ text = glyph, face = UI.symbolFace(UI.ptForPx(math.floor(bh * 0.42))), fgcolor = ink }
        local sz = tw:getSize()
        tw:paintTo(b2, bx + math.floor((bw - sz.w) / 2), by + math.floor((bh - sz.h) / 2))
        tw:free()
    end })
end

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

--- A book's file size in bytes, as its library gives it: the file a
--- download would take (its first format), else the smallest offered, else
--- the size written on the book ("1.2 MB"); nil if no library said.
local function sizeBytes(b)
    if type(b) ~= "table" then return nil end
    local acqs = b.acquisitions or {}
    local first = acqs[1] and tonumber(acqs[1].size)
    if first and first > 0 then return first end
    local best
    for _i, a in ipairs(acqs) do
        local n = tonumber(a.size)
        if n and n > 0 and (not best or n < best) then best = n end
    end
    if best then return best end
    local n = tonumber(b.filesize)
    if n and n > 0 then return n end
    local text = type(b.size) == "string" and b.size or nil
    if text then
        local num, unit = text:gsub(",", "."):match("([%d%.]+)%s*([KkMmGg]?)[Bb]?")
        num = tonumber(num)
        if num then
            local mult = ({ k = 1024, m = 1048576, g = 1073741824 })[(unit or ""):lower()] or 1
            return num * mult
        end
    end
    return nil
end
M.sizeBytes = sizeBytes

local function sizeText(n)
    if not n then return nil end
    if n < 1048576 then return T(_("%1 KB"), math.max(1, math.floor(n / 1024 + 0.5))) end
    return T(_("%1 MB"), (string.format("%.1f", n / 1048576):gsub("%.0$", "")))
end
M.sizeText = sizeText

--- The store's sorts: how a list of results is ordered (Settings: store_sort).
M.SORTS = {
    { key = "", text = _("Best match") },
    { key = "popular", text = _("Most popular") },
    { key = "small", text = _("Smallest file first") },
    { key = "large", text = _("Largest file first") },
    { key = "newest", text = _("Newest") },
    { key = "oldest", text = _("Oldest") },
}

--- The sort kept from before, as it is now ("title" is Best match's).
local function storedSort()
    local s = require("bos_settings_store").get("store_sort")
    if s == "title" then return nil end
    return s
end
M.storedSort = storedSort

--- How many times a book was downloaded, where its library says: the
--- Internet Archive's own count, Project Gutenberg's (asked of Gutendex,
--- M.gutenbergCounts).
local function downloads(b)
    local n = tonumber(b and b.downloads)
    return n and n >= 0 and n or nil
end

local function gutenbergNumber(b)
    if not b or b.provider ~= "gutenberg" then return nil end
    return tostring(b.detail_url or b.provider_id or b.id or ""):match("/ebooks/(%d+)")
        or tostring(b.provider_id or ""):match("^(%d+)$")
end

--- Project Gutenberg's books' download counts, from Gutendex (the
--- catalogue's open API), 32 at a time; sets b.downloads. Blocking: in the
--- background.
function M.gutenbergCounts(books)
    local want, by = {}, {}
    for _i, b in ipairs(books or {}) do
        local n = not downloads(b) and gutenbergNumber(b)
        if n and not by[n] then by[n] = {} want[#want + 1] = n end
        if n then table.insert(by[n], b) end
    end
    local got = {}
    for i = 1, #want, 32 do
        local ids = {}
        for j = i, math.min(i + 31, #want) do ids[#ids + 1] = want[j] end
        local okR, payload = pcall(function()
            return require("bookdrop_opds_provider")._requestPayload("https://gutendex.com/books/?ids=" .. table.concat(ids, ","), "application/json")
        end)
        local okJ, data = pcall(function() return require("rapidjson").decode(payload) end)
        for _k, r in ipairs(okR and okJ and type(data) == "table" and data.results or {}) do
            local n = tostring(r.id)
            local c = tonumber(r.download_count)
            if c and by[n] then
                got[n] = c
                for _m, b in ipairs(by[n]) do b.downloads = c end
            end
        end
    end
    return got
end

--- Order books by `sort` (the libraries' own sorts, and by file size).
function M.sortBooks(books, query, sort, filters)
    local P = Provider()
    if sort == "title" then sort = "" end
    local by_size = sort == "small" or sort == "large"
    local ok, sorted = pcall(P.sortBooks, P, books, query, (by_size or sort == "popular") and "" or sort, filters)
    books = ok and sorted or books
    if sort == "popular" then
        -- (the most downloaded first, from every library together; books
        -- whose library doesn't count downloads after, best match first)
        local pos = {}
        for i, b in ipairs(books) do pos[b] = i end
        table.sort(books, function(a, b)
            local da, db = downloads(a), downloads(b)
            if da and db and da ~= db then return da > db end
            if (da ~= nil) ~= (db ~= nil) then return da ~= nil end
            return pos[a] < pos[b]
        end)
        return books
    end
    if by_size then
        -- (by size, the best match first among equals; a book whose size no
        -- library gave goes last)
        local pos = {}
        for i, b in ipairs(books) do pos[b] = i end
        table.sort(books, function(a, b)
            local sa, sb = sizeBytes(a), sizeBytes(b)
            if sa and sb and sa ~= sb then
                if sort == "small" then return sa < sb end
                return sa > sb
            end
            if (sa ~= nil) ~= (sb ~= nil) then return sa ~= nil end
            return pos[a] < pos[b]
        end)
    end
    return books
end

local function sourceLine(b)
    local parts = {}
    if b.source and b.source ~= "" then parts[#parts + 1] = b.source end
    local fmt = b.available_formats or b.format
    if fmt and fmt ~= "" and fmt ~= "EBOOK" then parts[#parts + 1] = fmt end
    local year = tostring(b.published_date or b.year or ""):match("%d%d%d%d")
    if year then parts[#parts + 1] = year end
    local size = sizeText(sizeBytes(b))
    if size then parts[#parts + 1] = size end
    local d = downloads(b)
    if d and d > 0 then
        local n = d >= 1000000 and string.format("%.1fM", d / 1000000) or d >= 1000 and string.format("%.1fk", d / 1000) or tostring(d)
        parts[#parts + 1] = T(_("%1 downloads"), (n:gsub("%.0([kM])$", "%1")))
    end
    return table.concat(parts, " · ")
end

-- ---------------------------------------------------------------- the screen

local Store = InputContainer:extend{
    name = "stui_store",
    covers_fullscreen = true,
}

function Store:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.pad = S(20)
    self.bar_y, self.bar_h = S(14), S(46)
    self.body_y = self.bar_y + self.bar_h + S(16)
    self.stack = { { kind = "home", page = 1, offs = {} } }
    self.hits = {}
    local all = function() return self.dimen end
    self.ges_events = {
        STap = { GestureRange:new{ ges = "tap", range = all } },
        SSwipe = { GestureRange:new{ ges = "swipe", range = all } },
        SHold = { GestureRange:new{ ges = "hold", range = all } },
    }
    if Device:hasKeys() then
        self.key_events = { Back = { { Device.input.group.Back } }, NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } } }
    end
    -- the search field: KOReader's own text input (keyboard layouts, a real
    -- keyboard, the cursor), drawn inside our box
    local InputText = require("ui/widget/inputtext")
    local key_w = self.bar_h
    self.field_x = self.pad + key_w + S(10)
    self.field_w = W - self.pad - self.field_x - key_w - S(10) - Look.SHADOW_SMALL
    -- two keys beside the field: ☰ (the storefront, the store's settings)
    -- and ⌂ home, at the top right as on every screen
    self.field_w = self.field_w - key_w - S(10) - Look.SHADOW_SMALL
    self.input = InputText:new{
        text = "", hint = _("Search your books and the store"),
        -- (room on the right for the × that clears it)
        width = self.field_w - S(40) - S(8) - S(40), face = tface(15),
        bordersize = 0, margin = 0, padding = S(4),
        parent = self, focused = false,
        edit_callback = function(edited) if edited then self:onTyped() end end,
        enter_callback = function() self:hideKeyboard() end,
    }
    self[1] = self.input
    self:homeData()
end

function Store:view() return self.stack[#self.stack] end

function Store:hit(rect, fn, hold) table.insert(self.hits, { rect = rect, fn = fn, hold = hold }) end

function Store:redraw(mode, region)
    if self.closed then return end
    if region then
        UIManager:setDirty(self, function() return mode or "ui", region end)
    else
        UIManager:setDirty(self, mode or "ui")
    end
end

-- KOReader asks this of Bookdrop's lists when covers arrive
function Store:refreshCovers()
    if self.closed then return end
    self:redraw("ui", Geom:new{ x = 0, y = self.body_y, w = self.dimen.w, h = self:bodyBottom() - self.body_y })
end

function Store:keyboardUp()
    return self.input and self.input:isKeyboardVisible() or false
end

--- Where the body ends: the keyboard's top while typing, else the screen's.
function Store:bodyBottom()
    local H = self.dimen.h
    if self:keyboardUp() then
        local kd = self.input:getKeyboardDimen()
        if kd and kd.h and kd.h > 0 then return H - kd.h - S(6) end
    end
    return H
end

--- KOReader's text input calls this when it's tapped (in place of showing
--- the keyboard itself).
function Store:onSwitchFocus() self:showKeyboard() end
function Store:getFocusableWidgetXY() return nil end

function Store:showKeyboard()
    if self:keyboardUp() then return end
    self.is_always_active = true -- taps reach us under the keyboard
    self.input:focus()
    self.input:onShowKeyboard()
    -- the list under the field, from the first key
    local v = self:view()
    if v.kind ~= "results" or not v.typed then
        self:push{ kind = "results", typed = true, query = self.input:getText(), books = {}, page = 1 }
    end
    self:redraw("ui")
end

function Store:hideKeyboard()
    if not self:keyboardUp() then return end
    self.input:onCloseKeyboard()
    self.input:unfocus()
    self.is_always_active = nil
    local v = self:view()
    if v.kind == "results" and v.typed and not (v.query and v.query:match("%S")) and not self.from_search then
        self:pop(true)
    end
    self:redraw("ui")
end

--- Is this the search screen that home's field opened (nothing under it
--- but the storefront it never showed)?
function Store:onSearchScreen()
    local v = self:view()
    return self.from_search and #self.stack == 2 and v.kind == "results" and v.typed == true
end

--- The storefront (the key beside the field on the search screen).
function Store:toStorefront()
    if self:keyboardUp() then
        self.input:onCloseKeyboard()
        self.input:unfocus()
        self.is_always_active = nil
    end
    while #self.stack > 1 do self:pop(true) end
    self:redraw("ui")
end

-- ---------------------------------------------------------------- data

function Store:filters(overrides)
    local bd = bookdrop()
    local f = {}
    for k, v in pairs(bd and bd.getFilters and bd:getFilters() or {}) do f[k] = v end
    -- your own libraries (added by address) are asked too
    local okL, Libs = pcall(require, "bos_store_libs")
    if okL then
        Libs.register()
        f.libraries = Libs.withLibraries(f.libraries)
    end
    -- the sort chosen in the store (results: Sort)
    local sort = storedSort()
    if sort ~= nil then f.sort = sort end
    for k, v in pairs(overrides or {}) do f[k] = v end
    return f
end

function Store:homeData()
    local bd = bookdrop()
    local rows = {}
    -- from what you read
    local Online = require("bos_online")
    local picks, seen = {}, {}
    local function add(list, into)
        for _j, p in ipairs(list) do
            if p.key and not seen[p.key] then
                seen[p.key] = true
                local mine = Online.owned(p)
                into[#into + 1] = { title = p.title, author = p.author, year = p.year, pick = p,
                    cover_path = Online.cachedCoverPath(p, "M"), owned = mine and mine.filepath or nil }
            end
        end
    end
    -- today's three first (the ones on home's FOR YOU), then the rest
    add(Online.daily(), picks)
    add(Online.rowItems("all"), picks)
    if #picks > 0 then
        table.insert(rows, { id = "foryou", title = _("Recommended for you"), books = picks })
        -- the covers of the ones on screen, fetched now if they aren't on file
        if not self._covers_asked then
            self._covers_asked = true
            local first = {}
            for i = 1, math.min(8, #picks) do first[i] = picks[i] end
            Online.fetchCovers(first, function()
                if not self.closed and self:view().kind == "home" then self:homeData() self:redraw("ui") end
            end, 8)
        end
    end
    -- what you've marked + WANT (it used to be a shelf in FOR YOU on home)
    local want = {}
    seen = {}
    add(Online.wantList(), want)
    if #want > 0 then table.insert(rows, { id = "want", title = _("Want to read"), books = want }) end
    local recent = bd and bd.settings and bd.settings:readSetting("recent_books", {}) or {}
    if #recent > 0 then
        for _i, b in ipairs(recent) do b.cover_path = b.cover_path or CoverCache():get(b) end
        table.insert(rows, { id = "recent", title = _("Recently viewed"), books = recent })
    end
    local okC, cat = pcall(function()
        return require("bookdrop_curated_home").build(bd.path, self:filters().formats)
    end)
    if okC and cat and cat.shelves then
        local sh = cat.shelves
        local function join(a, b) local o = {} for _i, x in ipairs(a or {}) do o[#o + 1] = x end for _i, x in ipairs(b or {}) do o[#o + 1] = x end return o end
        table.insert(rows, { id = "classics", title = _("Classics to start with"), books = join(sh.fiction, sh.nonfiction),
            more = { title = _("Fiction"), filters = { content = "book_fiction", sort = "" } } })
        table.insert(rows, { id = "comics", title = _("Comics and magazines"), books = join(sh.comics, sh.magazines),
            more = { title = _("Comics"), filters = { content = "book_comic", sort = "" } } })
        table.insert(rows, { id = "world", title = _("In Spanish and French"), books = join(sh.spanish, sh.french),
            more = { title = _("Spanish books"), filters = { language = "es", content = "" } } })
    end
    self.rows = rows
    self.categories = {
        { _("Fiction"), { content = "book_fiction", sort = "" } },
        { _("Non-fiction"), { content = "book_nonfiction", sort = "" } },
        { _("Comics"), { content = "book_comic", sort = "" } },
        { _("Magazines"), { content = "magazine", sort = "" } },
        { _("New arrivals"), { content = "", sort = "newest" } },
        { _("All books"), { content = "", sort = "" } },
        { _("Spanish"), { language = "es", content = "" } },
        { _("French"), { language = "fr", content = "" } },
    }
    -- your own libraries, each a shelf to browse (first, they're yours)
    local okL, Libs = pcall(require, "bos_store_libs")
    if okL then
        local mine = {}
        for _i, lib in ipairs(Libs.list()) do
            if lib.on ~= false and lib.browse then
                table.insert(mine, { lib.name, { libraries = { [lib.id] = true }, content = "", sort = "" } })
            end
        end
        for i = #mine, 1, -1 do table.insert(self.categories, 1, mine[i]) end
    end
end

-- ---------------------------------------------------------------- navigation

function Store:push(view)
    table.insert(self.stack, view)
    self:redraw("ui")
end

function Store:pop(quiet)
    local v = table.remove(self.stack)
    if v then
        Search.cancel(v.session)
        if v.jobs then for _i, j in ipairs(v.jobs) do j.cancelled = true end end
        if v.choose_timer then UIManager:unschedule(v.choose_timer) v.choose_timer = nil end
    end
    if #self.stack == 0 then
        self:close()
        return
    end
    local now = self:view()
    -- the field says what the screen under it is
    local want = now.kind == "results" and (now.query or "") or ""
    if self.input:getText() ~= want then
        self.setting_text = true
        self.input:setText(want)
        self.setting_text = nil
    end
    if now.kind == "home" then self:homeData() end
    if not quiet then self:redraw("ui") end
end

function Store:back()
    -- the search screen opened from home: Back is home, in one go
    if self:onSearchScreen() then
        self:close()
        return
    end
    if self:keyboardUp() then
        self:hideKeyboard()
        return
    end
    if #self.stack <= 1 then self:close() else self:pop() end
end

function Store:close()
    if self.closed then return end
    -- (the keyboard is its own window: it goes with the store, whatever
    -- closes it: opening your own book from the list, "All in your library")
    if self:keyboardUp() then
        pcall(function() self.input:onCloseKeyboard() end)
        self.is_always_active = nil
    end
    UIManager:close(self)
end

function Store:onCloseWidget()
    self.closed = true
    self._bookdrop_closed = true
    for _i, v in ipairs(self.stack or {}) do
        Search.cancel(v.session)
        if v.jobs then for _j, j in ipairs(v.jobs) do j.cancelled = true end end
    end
    if self.typing_timer then UIManager:unschedule(self.typing_timer) end
    pcall(function() self.input:onCloseWidget() end)
    freeImages()
    if M.current == self then M.current = nil end
    UIManager:setDirty(nil, "full")
end

function Store:onShow()
    UIManager:setDirty(self, "full")
    return true
end

-- ---------------------------------------------------------------- searching

--- A key was typed: the list follows, once the typing pauses.
function Store:onTyped()
    if self.setting_text then return end
    local text = self.input:getText() or ""
    local v = self:view()
    if not (v.kind == "results" and v.typed) then
        self:push{ kind = "results", typed = true, query = text, books = {}, page = 1 }
        v = self:view()
    end
    v.query = text
    if self.typing_timer then UIManager:unschedule(self.typing_timer) end
    local q = text:gsub("^%s+", ""):gsub("%s+$", "")
    if #q < 3 then
        Search.cancel(v.session)
        v.session, v.books, v.waiting, v.note = nil, {}, false, nil
    else
        v.waiting = true
        self.typing_timer = function()
            self.typing_timer = nil
            self:runSearch(v, q)
        end
        UIManager:scheduleIn(0.7, self.typing_timer)
    end
    -- your own books first, from the second letter, no Wi-Fi needed: looked
    -- up (and the list drawn) once the typing pauses for a moment, not on
    -- every key (each look and drawing of the covers holds the keyboard up)
    if self.mine_timer then UIManager:unschedule(self.mine_timer) end
    self.mine_timer = function()
        self.mine_timer = nil
        if self.closed or self:view() ~= v then return end
        v.mine = M.mine(q)
        self:refreshCovers()
    end
    UIManager:scheduleIn(0.25, self.mine_timer)
end

function Store:runSearch(v, q, page)
    Search.cancel(v.session)
    local ok_net = true
    pcall(function() ok_net = require("ui/network/manager"):isConnected() end)
    if not ok_net then
        v.waiting = false
        v.note = _("Wi-Fi is off.")
        v.offline = true
        self:refreshCovers()
        return
    end
    v.offline = nil
    v.waiting = true
    v.loading_more = page ~= nil
    v.session = Search.start(q, page or 1, v.filters or self:filters(), function(session)
        if self.closed or v.session ~= session then return end
        if page and page > 1 then
            -- a further page: after what's there
            if session.finished then
                local seen = {}
                for _i, b in ipairs(v.books) do seen[tostring(b.provider) .. ":" .. tostring(b.provider_id or b.id)] = true end
                for _i, b in ipairs(session.books) do
                    local k = tostring(b.provider) .. ":" .. tostring(b.provider_id or b.id)
                    if not seen[k] then seen[k] = true table.insert(v.books, b) end
                end
            end
        else
            v.books = session.books
        end
        v.answered, v.libraries = session.answered, session.total
        v.errors = session.errors
        v.has_more = session.has_next
        v.next_page = (page or 1) + 1
        if session.finished then
            v.waiting, v.loading_more = false, false
        end
        local bd = bookdrop()
        if bd and bd.loadCoversProgressively then
            pcall(bd.loadCoversProgressively, bd, v.books, self, 12)
        else
            self:refreshCovers()
        end
    end)
    self:refreshCovers()
end

--- A shelf of the store (a category): the libraries' own lists.
function Store:openShelf(title, overrides)
    self:hideKeyboard()
    local v = { kind = "results", title = title, query = "", filters = self:filters(overrides), books = {}, page = 1 }
    self:push(v)
    self:runSearch(v, "")
end

--- Results for a search asked for from elsewhere (FIND, a book's author).
function Store:openSearch(query)
    self:hideKeyboard()
    local v = { kind = "results", typed = true, query = query, books = {}, page = 1 }
    self.setting_text = true
    self.input:setText(query)
    self.setting_text = nil
    self:push(v)
    self:runSearch(v, query)
end

-- ---------------------------------------------------------------- a book

local function norm(s)
    return (tostring(s or ""):lower():gsub("%b()", " "):gsub("[%p]+", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function sameBook(b, title, author)
    local bt, t = norm(b.title), norm(title)
    if bt == "" or t == "" then return false end
    local title_ok = bt == t or bt:sub(1, #t + 1) == t .. " " or t:sub(1, #bt + 1) == bt .. " "
    if not title_ok then return false end
    if not author or author == "" then return true end
    local last = norm(author):match("(%S+)$")
    return last == nil or norm(b.author):find(last, 1, true) ~= nil
end

function Store:openBook(book)
    self:hideKeyboard()
    -- a recommendation that's on the device already: your copy's own page
    if book.owned then
        local ok = pcall(function() if not require("bos_bookdetail").show(book.owned) then error("no window") end end)
        if ok then return end
    end
    local v = { kind = "book", book = book, jobs = {}, page = 1 }
    if book.pick then
        -- a recommendation: what Open Library knows shows now; the
        -- libraries are asked whether they have it
        v.pick = book.pick
        v.book = { title = book.title, author = book.author, year = book.year, cover_path = book.cover_path, source = "" }
        v.state = "looking"
        self:push(v)
        self:lookFor(v)
        self:askHardcover(v)
        return
    end
    v.state = "details"
    self:push(v)
    self:askHardcover(v)
    local bd = bookdrop()
    if bd and bd.rememberBook then pcall(bd.rememberBook, bd, book) end
    self:hydrate(v, book)
end

--- What Hardcover's readers make of the book (when you're signed in
--- there): its rating, reviews and most liked quotes, for the book's page.
--- Only when it's certainly the same book (the same title and author).
function Store:askHardcover(v)
    local okH, HC = pcall(require, "bos_hardcover")
    if not okH or not HC.signedIn() or not HC.connected() then return end
    local function got(id)
        HC.book(id, function(full)
            if not full or self.closed then return end
            v.hc = full
            if self:view() == v then self:redraw("ui") end
        end)
    end
    if v.pick and v.pick.hc then return got(v.pick.hc) end
    local b = v.book
    if not (b and b.title and b.author and b.author ~= "") then return end
    HC.match(b.title, (b.author:gsub("%s*[,;&].*$", "")), function(hb, sure)
        if hb and sure then got(hb.id) end
    end)
end

--- The same book on Hardcover: its page there (found when the book was
--- opened, else looked up now by its title and author).
function Store:openOnHardcover(v)
    if v.hc then return require("bos_hardcover_ui").openBook(v.hc) end
    local okH, HC = pcall(require, "bos_hardcover")
    if not okH then return end
    local b = v.book or {}
    if not HC.connected() then
        UIManager:show(InfoMessage:new{ text = _("Hardcover needs Wi-Fi."), timeout = 3 })
        return
    end
    local author = tostring(b.author or ""):gsub("%s*[,;&].*$", "")
    local msg = InfoMessage:new{ text = _("Looking for it on Hardcover…") }
    UIManager:show(msg)
    HC.match(b.title or "", author, function(hb)
        UIManager:close(msg)
        if self.closed then return end
        if not hb then
            UIManager:show(InfoMessage:new{ text = T(_("“%1” isn't on Hardcover."), b.title or ""), timeout = 4 })
            return
        end
        HC.book(hb.id, function(full)
            if full then
                v.hc = v.hc or full
                require("bos_hardcover_ui").openBook(full)
            else
                require("bos_hardcover_ui").openBook(hb)
            end
        end)
    end)
end

--- The book's details and files, from its library.
function Store:hydrate(v, book)
    v.state = "details"
    local P, CC = Provider(), CoverCache()
    local job = Async.run(function()
        local hydrated, err = P:hydrate(book)
        if hydrated and not CC:get(hydrated) then pcall(function() CC:fetch(hydrated) end) end
        return hydrated, err
    end, function(ok, hydrated, err)
        if self.closed then return end
        if ok and type(hydrated) == "table" then
            hydrated.cover_path = CC:get(hydrated) or book.cover_path or v.book.cover_path
            if v.pick then
                hydrated.description = hydrated.description or v.book.description
            end
            v.book = hydrated
            v.state = "ready"
        else
            v.state = "error"
            v.error = tostring((ok and err) or hydrated or err or "")
        end
        if self:view() == v then self:redraw("ui") end
    end, 35)
    table.insert(v.jobs, job)
end

--- A recommendation: its description and cover (Open Library), and whether
--- a library has it.
function Store:lookFor(v)
    local Online = require("bos_online")
    local pick = v.pick
    local connected = false
    pcall(function() connected = require("ui/network/manager"):isConnected() end)
    if not connected then
        v.state = "offline"
        return
    end
    table.insert(v.jobs, Async.run(function()
        local desc = Online.description(pick)
        local cover = Online.coverPath(pick, "M")
        return desc or false, cover or false
    end, function(ok, desc, cover)
        if self.closed or not ok then return end
        if desc and not v.book.description then v.book.description = desc end
        if cover and not v.book.cover_path then v.book.cover_path = cover end
        if self:view() == v then self:redraw("ui") end
    end, 25))
    -- every library is asked; of the copies that are the same book (title
    -- and author), the one that takes the least room is opened. Once one is
    -- found the others get a few seconds more (a slow library's copy may be
    -- the small one), then the smallest so far. All of them, and the books
    -- with the same title by someone else, are Other matches.
    local function choose()
        if v.state ~= "looking" or self.closed then return end
        if v.choose_timer then UIManager:unschedule(v.choose_timer) v.choose_timer = nil end
        -- (the very title first: "Dracula" before "Dracula's Guest", which
        -- the looser match lets in for subtitles)
        local same, exact = {}, {}
        local want = norm(pick.title)
        for _i, b in ipairs(v.matches or {}) do
            if b._stui_same then
                same[#same + 1] = b
                if norm(b.title) == want then exact[#exact + 1] = b end
            end
        end
        if #same == 0 then return end
        if #exact > 0 then same = exact end
        same = M.sortBooks(same, pick.title or "", "small", self:filters())
        local b = same[1]
        v.found = b
        local keep_desc, keep_cover = v.book.description, v.book.cover_path
        b.cover_path = b.cover_path or CoverCache():get(b) or keep_cover
        v.book = b
        v.book.description = b.description or keep_desc
        self:hydrate(v, b)
        if self:view() == v then self:redraw("ui") end
    end
    v.matches = {}
    -- asked by the title and the author together ("Dracula Stoker": a
    -- common title doesn't bury the book); if that finds nothing, by the
    -- title alone (a library that only searches titles)
    -- ("Dracula, Bram Stoker" first; a library that writes the name
    -- otherwise, "B. Stoker", finds "Dracula Stoker"; then the title alone)
    local full = tostring(pick.author or ""):gsub("%s*[;&].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- ("Stoker, Bram" → "Bram Stoker")
    local last, first = full:match("^([^,]+),%s*(.+)$")
    if last then full = first .. " " .. last end
    local surname = full:match("(%S+)%s*$")
    local title = pick.title or ""
    local queries = { title }
    if surname and #surname > 1 and not norm(title):find(norm(surname), 1, true) then
        table.insert(queries, 1, title .. " " .. surname)
        if full:find("%s") then table.insert(queries, 1, title .. ", " .. full) end
    end
    local all = {}   -- every match from every query so far, by key
    local function run(qi)
        -- (exact: these queries are its own ways of asking already)
        v.session = Search.start(queries[qi], 1, self:filters{ sort = "" }, function(session)
            if self.closed or v.session ~= session then return end
            -- (the books that match, kept as they come: the title, and
            -- whether the author is the same too)
            for _i, b in ipairs(session.books) do
                local same = sameBook(b, pick.title, pick.author)
                if same or sameBook(b, pick.title, nil) then
                    local key = tostring(b.provider) .. ":" .. tostring(b.provider_id or b.id or b.title)
                    if not all[key] then
                        all[key] = b
                        b._stui_same = same or nil
                        table.insert(v.matches, b)
                    end
                end
            end
            if v.state == "looking" then
                local any = false
                for _i, b in ipairs(v.matches) do if b._stui_same then any = true break end end
                if session.finished then
                    if any then choose()
                    elseif qi < #queries then return run(qi + 1)
                    else v.state = "missing" end
                elseif any and not v.choose_timer then
                    v.choose_timer = function() v.choose_timer = nil choose() end
                    UIManager:scheduleIn(6, v.choose_timer)
                end
            end
            if self:view() == v then self:redraw("ui") end
        end, true)
    end
    run(1)
end

--- The other books that match the one from Hardcover (or a pick): every
--- copy the libraries have (same title and author, the smallest file first),
--- then the same title by someone else.
function Store:otherMatches(v)
    local title = (v.pick and v.pick.title) or v.book.title or ""
    local want = norm(title)
    -- the same book (its very title, then with more to it), then the same
    -- title by someone else; each the smallest file first
    local groups = { {}, {}, {} }
    for _i, b in ipairs(v.matches or {}) do
        if b ~= v.found then
            local g = (b._stui_same and norm(b.title) == want and 1) or (b._stui_same and 2) or 3
            table.insert(groups[g], b)
        end
    end
    local same = {}
    for _i, g in ipairs(groups) do
        for _j, b in ipairs(M.sortBooks(g, title, "small", self:filters())) do same[#same + 1] = b end
    end
    self:push{ kind = "results", title = _("Other matches"), query = title, books = same, page = 1, sort = "small",
        empty = _("No other copies in your libraries.") }
    self:redraw("ui")
end

local function destination(book, acq)
    local bd = bookdrop()
    if bd and bd.destinationFor then
        local ok, path = pcall(bd.destinationFor, bd, book, acq)
        if ok then return path end
    end
end

local function exists(path)
    return path and require("libs/libkoreader-lfs").attributes(path, "mode") == "file"
end

function Store:download(v, acq)
    local bd = bookdrop()
    if not (bd and bd.downloadBook) then return end
    local book = v.book
    bd.on_downloaded = function(path)
        bd.on_downloaded = nil
        if self.closed then return false end
        if self:view() == v then self:redraw("ui") end
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = T(_("%1 is on your device.\n\nRead it now?"), book.title),
            ok_text = _("Read now"), cancel_text = _("Later"),
            ok_callback = function() self:read(path) end,
        })
        return true
    end
    bd:downloadBook(book, acq)
end

--- Your own books matching what's typed, the ones you're reading first.
--- Bookshelf's own search does the matching (Repo.searchBooks: every word
--- in the title, the author, the series, and the genres if its setting says
--- so; the Kindle library too), so this finds exactly what its search key
--- found. Without it: title, author and series. At most `max` (default: all).
function M.mine(q, max)
    local words = {}
    for w in tostring(q or ""):lower():gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 or #table.concat(words) < 2 then return {} end
    local okL, L = pcall(function() return require("bos_recs").library() end)
    local by_fp = {}
    if okL and L and L.books then for _i, b in ipairs(L.books) do by_fp[b.filepath] = b end end
    local out
    local okR, found = pcall(function()
        local Repo = require("lib/bookshelf_book_repository")
        return Repo.searchBooks(table.concat(words, " "))
    end)
    if okR and type(found) == "table" then
        out = {}
        for _i, r in ipairs(found) do
            local fp = r.filepath
            if type(fp) == "string" then
                -- (the library's record when there is one: it knows how far you are)
                out[#out + 1] = by_fp[fp] or { filepath = fp, title = r.title, authors = r.authors or {}, series = r.series_name }
            end
        end
    else
        out = {}
        for _i, b in ipairs(okL and L and L.books or {}) do
            local hay = (tostring(b.title or "") .. " " .. table.concat(b.authors or {}, " ") .. " " .. tostring(b.series or "")):lower()
            local all = true
            for _j, w in ipairs(words) do if not hay:find(w, 1, true) then all = false break end end
            if all then out[#out + 1] = b end
        end
    end
    table.sort(out, function(a, b)
        local ra, rb = a.rank or 1e9, b.rank or 1e9
        if ra ~= rb then return ra < rb end
        return tostring(a.title or "") < tostring(b.title or "")
    end)
    if max then while #out > max do table.remove(out) end end
    return out
end

--- Every one of your books that matches: Bookshelf's own results view on
--- the Shelf layout (its groups by author, series and genre too); a page of
--- covers on Dash.
function Store:allMine(v)
    local q = (v.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local mine = v.mine or {}
    self:close()
    UIManager:nextTick(function()
        local ok, err = pcall(function()
            local Layouts = require("bos_layouts")
            local bw = require("bos_shelf").shelfWidget()
            if Layouts.id() == "shelf" and bw and bw._searchAndDrill then
                bw:_searchAndDrill(q)
                return
            end
            local books = {}
            for _i, b in ipairs(mine) do
                books[#books + 1] = { filepath = b.filepath, title = b.title, author = b.authors and b.authors[1], pct = b.pct }
            end
            Layouts.showList({ label = T(_("In your library: “%1”"), q), books = books })
        end)
        if not ok then logger.warn("ShelfTechUI: your library's results:", err) end
    end)
end

function Store:read(path)
    self:close()
    UIManager:nextTick(function()
        local ok, err = pcall(function() require("bos_shelf").open(path) end)
        if not ok then logger.warn("ShelfTechUI: store, opening the book:", err) end
    end)
end

function Store:otherFormats(v, anchor)
    local items = {}
    for i, acq in ipairs(v.book.acquisitions or {}) do
        local size = tonumber(acq.size) and (" · " .. sizeText(tonumber(acq.size))) or ""
        table.insert(items, { text = (acq.format or (acq.extension or "?"):upper()) .. size, callback = function()
            local path = destination(v.book, acq)
            if exists(path) then self:read(path) else self:download(v, acq) end
        end })
    end
    UI.openList(items, anchor, function() end)
end

-- ---------------------------------------------------------------- painting

function Store:paintTo(bb, x, y)
    local W, H = self.dimen.w, self.dimen.h
    self.hits = {}
    bb:paintRect(0, 0, W, H, Look.PAPER)
    self:paintBar(bb)
    local v = self:view()
    local bottom = self:bodyBottom()
    if v.kind == "home" then self:paintHome(bb, v, bottom)
    elseif v.kind == "results" then self:paintResults(bb, v, bottom)
    elseif v.kind == "book" then self:paintBook(bb, v, bottom) end
end

function Store:paintBar(bb)
    local W = self.dimen.w
    local y, h, pad = self.bar_y, self.bar_h, self.pad
    -- (× where Back leaves the store: the storefront, and the search screen
    -- home's field opened)
    local home = (#self.stack <= 1 and not self:keyboardUp()) or self:onSearchScreen()
    local r = Look.button(bb, pad, y, h, h, home and "\u{00D7}" or "\u{2039}", { size = 18 })
    self:hit(Geom:new{ x = 0, y = 0, w = r.x + r.w + S(4), h = y + h + S(10) }, function() self:back() end)
    -- the field
    local fx, fw = self.field_x, self.field_w
    Look.box(bb, fx, y, fw, h, { shadow = Look.SHADOW_SMALL })
    local gw = S(40)
    local tw = TextWidget:new{ text = UI.GLYPH.search, face = UI.symbolFace(UI.ptForPx(math.floor(h * 0.36))), fgcolor = Look.INK }
    local sz = tw:getSize()
    tw:paintTo(bb, fx + math.floor((gw - sz.w) / 2) + S(2), y + math.floor((h - sz.h) / 2))
    tw:free()
    local isz = self.input:getSize()
    self.input:paintTo(bb, fx + gw, y + math.floor((h - isz.h) / 2))
    self.field_rect = Geom:new{ x = fx, y = y - S(6), w = fw, h = h + S(12) }
    -- × inside the field, at its right end, once something is typed (as on
    -- a phone): it clears the field
    self.clear_rect = nil
    if (self.input:getText() or "") ~= "" then
        local d = S(28)
        local cx, cy = fx + fw - S(10) - d, y + math.floor((h - d) / 2)
        Look.disc(bb, cx + math.floor(d / 2), cy + math.floor(d / 2), math.floor(d / 2), Look.GRAY)
        Look.label(bb, "\u{00D7}", cx, cy - S(1), d, d, 16, { align = "center", color = WHITE })
        self.clear_rect = Geom:new{ x = fx + fw - S(48), y = y - S(6), w = S(48) + S(6), h = h + S(12) }
    end
    -- the keys on the right: ☰ (the storefront, settings), ⌂ home
    local kx = fx + fw + Look.SHADOW_SMALL + S(10)
    local rm = glyphKey(bb, kx, y, h, h, UI.GLYPH.bars)
    self.cog_rect = Geom:new{ x = rm.x, y = rm.y, w = h, h = h }
    self:hit(Geom:new{ x = rm.x - S(4), y = 0, w = h + S(8), h = y + h + S(10) }, function() self:settings() end)
    kx = kx + h + Look.SHADOW_SMALL + S(10)
    local rh = glyphKey(bb, kx, y, h, h, UI.GLYPH.home)
    self:hit(Geom:new{ x = rh.x - S(4), y = 0, w = W - rh.x + S(4), h = y + h + S(10) }, function()
        self:hideKeyboard()
        require("bos_shelf").home()
    end)
end

function Store:clear()
    self.setting_text = true
    self.input:setText("")
    self.setting_text = nil
    local v = self:view()
    if v.kind == "results" and v.typed then
        Search.cancel(v.session)
        v.query, v.books, v.session, v.waiting, v.note = "", {}, nil, false, nil
        if not self:keyboardUp() and not self.from_search then self:pop(true) end
    end
    self:redraw("ui")
end

function Store:settings()
    self:hideKeyboard()
    local items = {}
    -- (the storefront: the store's first page, from a search)
    if self:view().kind ~= "home" then
        table.insert(items, { text = _("Storefront"), callback = function() self:toStorefront() end })
    end
    for _i, it in ipairs{
        { text = _("Libraries, formats and language"), callback = function()
            pcall(function()
                require("bos_settings_store").set("settings_open_at", "stui_connect")
                require("bos_settings").open()
            end)
        end },
    } do table.insert(items, it) end
    table.insert(items, { text = _("Add a library by address…"), callback = function()
        M.addLibrary(function() if not self.closed then self:homeData() self:redraw("ui") end end)
    end })
    -- your libraries: remove one
    local Libs = require("bos_store_libs")
    if #Libs.list() > 0 then
        table.insert(items, { text = _("Remove a library…"), callback = function()
            local rows = {}
            for _i, lib in ipairs(Libs.list()) do
                local id, name = lib.id, lib.name
                table.insert(rows, { text = name .. "  ·  " .. Libs.host(lib.url), callback = function()
                    M.confirmRemove(id, name, function()
                        if not self.closed then self:homeData() self:redraw("ui") end
                    end)
                end })
            end
            UI.openList(rows, self.cog_rect, function() end)
        end })
    end
    local bd = bookdrop()
    if bd and bd.openManga then
        table.insert(items, { text = _("Manga"), callback = function() bd:openManga() end })
    end
    table.insert(items, { text = _("Refresh recommendations"), callback = function()
        require("bos_online").refreshInBackground(true)
        UIManager:show(InfoMessage:new{ text = _("Getting new recommendations: they'll be here in a minute."), timeout = 3 })
    end })
    -- (under its key, at the right, where it was tapped)
    UI.openList(items, self.cog_rect, function() end)
end

--- The footer: ‹ page / pages ›. Returns its height.
function Store:paintFooter(bb, v, pages, bottom)
    local W, pad = self.dimen.w, self.pad
    local fh = S(40)
    local y = bottom - fh - S(10)
    if pages <= 1 then return 0 end
    local kw = S(56)
    local rp = Look.button(bb, pad, y, kw, fh, "\u{2039}", { size = 16, enabled = v.page > 1 })
    self:hit(rp, function() self:turn(-1) end)
    local rn = Look.button(bb, W - pad - kw - Look.SHADOW_SMALL, y, kw, fh, "\u{203A}", { size = 16, enabled = v.page < pages })
    self:hit(rn, function() self:turn(1) end)
    Look.label(bb, T(_("%1 / %2"), v.page, pages), pad + kw, y, W - 2 * pad - 2 * kw, fh, 12, { align = "center" })
    return fh + S(20)
end

function Store:turn(d)
    local v = self:view()
    local pages = v.pages or 1
    local want = v.page + d
    if want < 1 then return end
    if want > pages then
        -- past the end of a list: the libraries' next page
        if v.kind == "results" and v.has_more and not v.waiting and v.session then
            v.want_page = want
            self:runSearch(v, v.session.query, v.next_page)
        end
        return
    end
    v.page = want
    self:redraw(v.kind == "book" and "ui" or "partial")
end

-- the storefront ---------------------------------------------------------

function Store:rowHeight(cw) return S(34) + math.floor(cw * 1.5) + S(44) + S(16) end

function Store:paintHome(bb, v, bottom)
    local W, pad = self.dimen.w, self.pad
    local x, w = pad, W - 2 * pad
    -- five covers across: two shelves and Browse fit the first page
    local cols, gap = 5, S(14)
    local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
    local ch = math.floor(cw * 1.5)
    local rh = self:rowHeight(cw)
    -- what goes on each page: rows of covers, then the categories
    local foot = S(60)
    local avail = bottom - self.body_y - foot
    local blocks = {}
    -- Browse first (as a Kindle's and a Kobo's store open on their
    -- categories): a compact grid of keys, then the rows of covers
    local ccols = w >= S(520) and 4 or 3
    local cat_rows = math.ceil(#self.categories / ccols)
    blocks[#blocks + 1] = { cats = true, h = S(34) + cat_rows * S(50) + S(12) }
    for _i, row in ipairs(self.rows or {}) do blocks[#blocks + 1] = { row = row, h = rh } end
    local pages, cur, used = {}, {}, 0
    for _i, b in ipairs(blocks) do
        if used + b.h > avail and #cur > 0 then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        cur[#cur + 1] = b
        used = used + b.h
    end
    if #cur > 0 then pages[#pages + 1] = cur end
    v.pages = #pages
    v.page = math.max(1, math.min(v.page, #pages))
    local y = self.body_y
    for _i, b in ipairs(pages[v.page] or {}) do
        if b.row then
            local row = b.row
            local n = #row.books
            local off = math.max(0, math.min(v.offs[row.id] or 0, math.max(0, n - cols)))
            v.offs[row.id] = off
            local right = (n > cols) and T(_("%1–%2 of %3  ›"), off + 1, math.min(n, off + cols), n) or (row.more and _("See all ›") or nil)
            Look.heading(bb, row.title, x, y, w, S(26), right)
            local head = Geom:new{ x = x, y = y - S(6), w = w, h = S(36) }
            if n > cols then
                self:hit(head, function()
                    v.offs[row.id] = (off + cols >= n) and 0 or off + cols
                    self:redraw("ui", Geom:new{ x = 0, y = y - S(6), w = W, h = rh })
                end)
            elseif row.more then
                self:hit(head, function() self:openShelf(row.more.title, row.more.filters) end)
            end
            local cy = y + S(34)
            for k = 1, cols do
                local book = row.books[off + k]
                if book then
                    local cx = x + (k - 1) * (cw + gap)
                    drawCover(bb, book, cx, cy, cw, ch)
                    Page.wrap(bb, book.title or "", tface(11, true), cx, cy + ch + S(8), cw, 2, S(17))
                    self:hit(Geom:new{ x = cx, y = cy, w = cw + gap, h = ch + S(44) }, function() self:openBook(book) end)
                end
            end
            b.rect = Geom:new{ x = 0, y = y, w = W, h = rh }
            b.swipe = function(dir)
                if n <= cols then return false end
                local to = off + (dir == "west" and cols or -cols)
                to = math.max(0, math.min(to, n - cols))
                if to == off then return false end
                v.offs[row.id] = to
                self:redraw("ui", Geom:new{ x = 0, y = y - S(6), w = W, h = rh })
                return true
            end
            y = y + rh
        elseif b.cats then
            Look.heading(bb, _("Browse"), x, y, w, S(26))
            local cy = y + S(34)
            local cgap = S(10)
            local bw2 = math.floor((w - (ccols - 1) * cgap - Look.SHADOW_SMALL) / ccols)
            for i, c in ipairs(self.categories) do
                local k = i - 1
                local bx, by = x + (k % ccols) * (bw2 + cgap), cy + math.floor(k / ccols) * S(50)
                local r = Look.button(bb, bx, by, bw2, S(40), c[1], { size = 11 })
                self:hit(r, function() self:openShelf(c[1], c[2]) end)
            end
            y = y + b.h
        end
    end
    v.blocks = pages[v.page]
    if #(self.rows or {}) == 0 or not (self.rows[1] and self.rows[1].id == "foryou") then
        -- no recommendations yet
        if v.page == #pages then
            local Online = require("bos_online")
            local note = Online.enabled() and _("Recommendations from what you read appear here once Wi-Fi has been on.")
                or _("Recommendations are off (Settings → Connect → Online picks).")
            Page.wrap(bb, note, Look.serif(13, false, true), x, y + S(4), w, 2, S(20), Look.GRAY)
        end
    end
    self:paintFooter(bb, v, #pages, bottom)
end

-- a list of books -----------------------------------------------------------

--- Recommendations, as covers, in the room between y and bottom (the
--- search screen before anything is typed). Returns false when there are
--- none to show.
function Store:paintSuggestions(bb, x, y, w, bottom)
    local Online = require("bos_online")
    if not self.suggest then
        local list, seen = {}, {}
        local function add(items)
            for _j, p in ipairs(items) do
                if p.key and not seen[p.key] and not Online.owned(p) then
                    seen[p.key] = true
                    list[#list + 1] = { title = p.title, author = p.author, year = p.year, pick = p }
                end
            end
        end
        add(Online.daily())
        add(Online.rowItems("all"))
        self.suggest = list
    end
    local list = self.suggest
    if #list == 0 then return false end
    local gap = S(14)
    local head, label_h = S(26), S(24)
    local room = bottom - y - head
    -- four, five or six across: whichever fills the room best (bigger
    -- covers when it's a tie)
    local cols, cw, ch, rh, best = 5, 0, 0, 0, -1
    for _i, n in ipairs{ 4, 5, 6 } do
        local w1 = math.floor((w - (n - 1) * gap - Look.SHADOW_SMALL) / n)
        local h1 = math.floor(w1 * 1.5)
        local r1 = h1 + label_h + S(10)
        local used = math.floor(room / r1) * r1
        if used > best then cols, cw, ch, rh, best = n, w1, h1, r1, used end
    end
    if best <= 0 then
        -- little room above the keyboard: smaller covers, one row
        ch = room - label_h - S(10)
        if ch < S(60) then return false end
        cw = math.floor(ch / 1.5)
        cols = math.max(5, math.floor((w + gap) / (cw + gap)))
        rh = ch + label_h + S(10)
    end
    local rows = math.max(1, math.floor(room / rh))
    Look.label(bb, _("Recommended for you"), x, y - S(4), w, S(18), 9, {})
    y = y + head - S(6)
    local shown = {}
    for k = 1, math.min(#list, rows * cols) do
        local b = list[k]
        b.cover_path = b.cover_path or Online.cachedCoverPath(b.pick, "M")
        shown[#shown + 1] = b.pick
        local cx = x + ((k - 1) % cols) * (cw + gap)
        local cy = y + math.floor((k - 1) / cols) * rh
        drawCover(bb, b, cx, cy, cw, ch)
        Page.wrap(bb, b.title or "", tface(10, true), cx, cy + ch + S(6), cw, 1, S(16))
        self:hit(Geom:new{ x = cx - S(4), y = cy - S(4), w = cw + S(8), h = rh - S(2) }, function() self:openBook(b) end)
    end
    -- their covers, fetched once if they aren't on file
    if not self.suggest_covers then
        self.suggest_covers = true
        Online.fetchCovers(shown, function()
            if not self.closed then self:redraw("ui") end
        end, #shown)
    end
    return true
end

function Store:paintResults(bb, v, bottom)
    local W, pad = self.dimen.w, self.pad
    local x, w = pad, W - 2 * pad
    local y = self.body_y
    -- what this list is, and how the asking is going
    local title
    if v.title then title = v.title
    elseif v.query and v.query:match("%S") then title = T(_("Results for “%1”"), (v.query:gsub("^%s+", ""):gsub("%s+$", "")))
    else title = _("Search") end
    local status
    if v.waiting and v.libraries and v.libraries > 0 then
        status = T(_("%1 of %2 libraries…"), v.answered or 0, v.libraries)
    elseif v.waiting then status = _("Asking the libraries…")
    elseif #v.books > 0 then status = T(#v.books == 1 and _("%1 book") or _("%1 books"), #v.books) .. (v.has_more and "+" or "") end
    Look.heading(bb, title, x, y, w, S(26), status)
    y = y + S(36)
    local typing = self:keyboardUp()
    -- the order: Best match, by file size, title, year (kept for next time)
    if #v.books > 1 and not typing then
        local cur = v.sort
        if cur == nil then cur = storedSort() or "" end
        if cur == "title" then cur = "" end
        local name = M.SORTS[1].text
        for _i, s2 in ipairs(M.SORTS) do if s2.key == cur then name = s2.text end end
        local label = T(_("Sort: %1"), name) .. " \u{25BE}"
        local sw = Look.textWidth(Look.case(label), 10) + S(28)
        local r = Look.button(bb, x + w - sw - Look.SHADOW_SMALL, y - S(4), sw, S(32), label, { size = 10 })
        self:hit(r, function() self:chooseSort(v, r) end)
        y = y + S(40)
    end
    local rh = S(108)
    local foot = typing and 0 or S(60)
    -- on this device: your own books that match, above the store's (the
    -- first page of a typed search)
    local mine = v.typed and v.mine or {}
    if #mine > 0 and (v.page or 1) == 1 then
        local n = math.min(#mine, typing and 2 or 3)
        local mh = S(66)
        Look.label(bb, T(#mine == 1 and _("On this device · %1 book") or _("On this device · %1 books"), #mine), x, y - S(4), w, S(18), 9, {})
        if #mine > n then
            -- the rest: every match, as Bookshelf's own search shows them
            local all = T(_("All %1 in your library"), #mine) .. " \u{203A}"
            local aw = Look.textWidth(Look.case(all), 9) + S(8)
            Look.label(bb, all, x + w - aw, y - S(4), aw, S(18), 9, { align = "right" })
            bb:paintRect(x + w - aw + S(8), y + S(12), aw - S(8), math.max(1, S(1)), Look.INK)
            self:hit(Geom:new{ x = x + w - aw - S(10), y = y - S(12), w = aw + S(10), h = S(34) }, function() self:allMine(v) end)
        end
        y = y + S(18)
        local mcw, mch = S(36), S(54)
        for k = 1, n do
            local b = mine[k]
            local ry = y + (k - 1) * mh
            local okc = pcall(function()
                require("bos_cover").paint(bb, b.filepath, x, ry, mcw, mch, { shadow = Look.SHADOW_SMALL, title = b.title })
            end)
            if not okc then Look.box(bb, x, ry, mcw, mch, {}) end
            local tx = x + mcw + S(18)
            local tw = w - (tx - x) - S(110)
            Page.wrap(bb, b.title or "", tface(14, true), tx, ry + S(2), tw, 1, S(22))
            local who = b.authors and b.authors[1] or ""
            if who ~= "" then Page.wrap(bb, who, Look.serif(12, false, true), tx, ry + S(26), tw, 1, S(18)) end
            local state = (b.status == "complete" and _("Finished")) or (b.pct and b.pct > 0 and T(_("%1% read"), math.floor(b.pct * 100 + 0.5))) or _("Not started")
            Look.button(bb, x + w - S(96) - Look.SHADOW_SMALL, ry + S(8), S(96), S(38), _("Read"), { size = 11 })
            Look.label(bb, state, tx, ry + mch - S(10), tw, S(16), 9, { color = Look.GRAY })
            self:hit(Geom:new{ x = 0, y = ry - S(4), w = W, h = mh }, function() self:read(b.filepath) end)
        end
        y = y + n * mh + S(4)
        bb:paintRect(x, y, w, Look.LINE, Look.INK)
        y = y + S(14)
        Look.label(bb, _("In the store"), x, y - S(4), w, S(18), 9, {})
        y = y + S(18)
    end
    local per = math.max(1, math.floor((bottom - y - foot) / rh))
    if #v.books == 0 then
        local msg
        local q = (v.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local wifi_busy = false
        if v.offline then pcall(function() wifi_busy = require("bos_status").wifiBusy() end) end
        if v.offline and wifi_busy then msg = require("bos_status").wifiText()
        elseif v.offline then msg = _("Wi-Fi is off. Turn it on to search the libraries.")
        elseif v.waiting then msg = _("Looking…")
        elseif v.typed and #q < 3 then msg = _("Type a title, an author or an ISBN: the list follows as you type.")
        elseif v.errors and #v.errors > 0 and (v.answered or 0) >= (v.libraries or 1) and #v.errors >= (v.libraries or 1) then
            msg = _("The libraries couldn't be reached:") .. "\n" .. table.concat(v.errors, "\n")
        elseif v.empty then msg = v.empty
        else msg = _("Nothing found. Try fewer words, or another spelling.") end
        -- nothing typed yet: recommendations fill the room (a tap opens
        -- one); typing takes over as before
        if v.typed and #q < 3 and #mine == 0 and self:paintSuggestions(bb, x, y, w, bottom) then return end
        Page.wrap(bb, msg, Look.serif(15, false, true), x, y + S(10), w, 8, S(24), Look.GRAY)
        if v.offline and not wifi_busy then
            local r = Look.button(bb, x, y + S(70), S(220), S(46), _("Turn on Wi-Fi"), { size = 12, on = true })
            self:hit(r, function()
                pcall(function()
                    -- Turning on… → Connecting…, in place of the key, as it happens
                    local Status = require("bos_status")
                    Status.wifiAsked(true)
                    self:redraw("ui")
                    Status.watchWifi(function() self:redraw("ui") end, function() return not self.closed and self:view() == v end)
                    require("ui/network/manager"):runWhenConnected(function()
                        if not self.closed then self:runSearch(v, (v.query or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
                    end)
                end)
            end)
        end
        v.pages = 1
        return
    end
    local pages = math.max(1, math.ceil(#v.books / per))
    if v.want_page and not v.waiting then
        v.page = math.min(v.want_page, pages)
        v.want_page = nil
    end
    v.pages = pages
    v.page = math.max(1, math.min(v.page, pages))
    if typing then v.page = 1 end
    local first = (v.page - 1) * per
    local cw, ch = S(62), S(93)
    for k = 1, per do
        local b = v.books[first + k]
        if not b then break end
        local ry = y + (k - 1) * rh
        drawCover(bb, b, x, ry, cw, ch)
        local tx = x + cw + S(18)
        local tw = w - (tx - x) - S(26)
        local th = Page.wrap(bb, b.title or "", tface(15, true), tx, ry, tw, 2, S(22))
        if b.author and b.author ~= "" then
            Page.wrap(bb, b.author, Look.serif(13, false, true), tx, ry + th + S(2), tw, 1, S(20))
        end
        Look.label(bb, sourceLine(b), tx, ry + ch - S(20), tw, S(18), 9, { color = Look.GRAY })
        Look.label(bb, "\u{203A}", x + w - S(20), ry, S(20), ch, 16, { align = "right", color = Look.GRAY })
        if k < per and v.books[first + k + 1] then
            local ly = ry + rh - S(8)
            for dx = tx, x + w, S(5) do bb:paintRect(dx, ly, math.max(1, S(1.5)), math.max(1, S(1.5)), Look.MID) end
        end
        self:hit(Geom:new{ x = 0, y = ry - S(6), w = W, h = rh }, function() self:openBook(b) end)
    end
    if not typing then
        local show_pages = pages + ((v.has_more and v.page == pages) and 1 or 0)
        v.pages = pages
        local W2 = self.dimen.w
        local fh = S(40)
        local fy = bottom - fh - S(10)
        if show_pages > 1 or v.loading_more then
            local kw = S(56)
            local rp = Look.button(bb, pad, fy, kw, fh, "\u{2039}", { size = 16, enabled = v.page > 1 })
            self:hit(rp, function() self:turn(-1) end)
            local can_next = v.page < pages or (v.has_more and not v.waiting)
            local rn = Look.button(bb, W2 - pad - kw - Look.SHADOW_SMALL, fy, kw, fh, "\u{203A}", { size = 16, enabled = can_next })
            self:hit(rn, function() self:turn(1) end)
            local mid = v.loading_more and _("More…") or T(_("%1 / %2"), v.page, pages) .. (v.has_more and "+" or "")
            Look.label(bb, mid, pad + kw, fy, W2 - 2 * pad - 2 * kw, fh, 12, { align = "center" })
        end
    end
end

--- The order of a list of results: chosen, kept for the next searches, and
--- the list ordered again here and now (no asking the libraries again).
function Store:chooseSort(v, anchor)
    local items = {}
    local cur = v.sort
    if cur == nil or cur == "title" then cur = storedSort() or "" end
    for _i, s2 in ipairs(M.SORTS) do
        items[#items + 1] = { text = (s2.key == cur and "\u{2713} " or "    ") .. s2.text, callback = function()
            require("bos_settings_store").set("store_sort", s2.key ~= "" and s2.key or nil)
            v.sort = s2.key
            local q = (v.query or ""):gsub("^%s+", ""):gsub("%s+$", "")
            v.books = M.sortBooks(v.books, q, s2.key, v.filters or self:filters())
            v.page = 1
            self:redraw("ui")
            -- most popular: Project Gutenberg's counts, asked for, then in order again
            if s2.key == "popular" then
                local books = v.books
                Async.run(function() return M.gutenbergCounts(books) end, function(okC, got)
                    if not okC or type(got) ~= "table" or next(got) == nil or self.closed then return end
                    for _i, b in ipairs(v.books) do
                        local n = gutenbergNumber(b)
                        if n and got[n] then b.downloads = got[n] end
                    end
                    if v.sort == "popular" then
                        v.books = M.sortBooks(v.books, q, "popular", v.filters or self:filters())
                        if self:view() == v then self:redraw("ui") end
                    end
                end, 30)
            end
        end }
    end
    UI.openList(items, anchor, function() end)
end

-- a book's page ----------------------------------------------------------

function Store:paintBook(bb, v, bottom)
    local W, pad = self.dimen.w, self.pad
    local x, w = pad, W - 2 * pad
    local y = self.body_y
    local b = v.book
    local cw = math.floor(w * 0.34)
    local ch = math.floor(cw * 1.5)
    -- its pages: the book; the rest of a long description; what Hardcover's
    -- readers say
    local hc = v.hc
    local hc_says = hc and (#hc.reviews > 0 or #hc.quotes > 0)
    local plist = { "main" }
    if v.long then plist[#plist + 1] = "about" end
    if hc_says then plist[#plist + 1] = "hc" end
    v.pages = #plist
    v.page = math.max(1, math.min(v.page or 1, #plist))
    local function pageOf(name) for i, n in ipairs(plist) do if n == name then return i end end end
    local function stars(r) return "\u{2605} " .. (string.format("%.1f", r):gsub("%.0$", "")) end
    if plist[v.page] == "about" then
        -- the rest of the description
        Look.heading(bb, _("About this book"), x, y, w, S(26))
        Page.wrap(bb, b.description or "", Look.serif(14), x, y + S(38), w, math.floor((bottom - y - S(110)) / S(23)), S(23))
        self:paintFooter(bb, v, #plist, bottom)
        return
    end
    if plist[v.page] == "hc" then
        -- reviews (none with spoilers), then the quotes readers liked most
        local right = hc.rating and hc.rating > 0 and (stars(hc.rating) .. " · " .. T(_("%1 ratings"), hc.ratings)) or nil
        Look.heading(bb, _("On Hardcover"), x, y, w, S(26), right)
        local yy = y + S(40)
        local room_end = bottom - S(118)
        local function block(text, face, by_line)
            local lh = S(22)
            local max = math.floor((room_end - yy - S(26)) / lh)
            if max < 2 then return false end
            local hgt = Page.wrap(bb, text, face, x + S(14), yy, w - S(14), math.min(max, 7), lh)
            bb:paintRect(x, yy + S(3), S(3), hgt - S(2), Look.INK)
            Look.label(bb, by_line, x + S(14), yy + hgt + S(3), w - S(14), S(18), 9, { color = Look.GRAY })
            yy = yy + hgt + S(34)
            return true
        end
        for _i, r in ipairs(hc.reviews) do
            local who = r.who and (r.who.name or r.who.username) or ""
            local by_line = (r.rating and (stars(r.rating) .. "  ·  ") or "") .. who
            if (r.likes or 0) > 0 then by_line = by_line .. "  ·  " .. T(r.likes == 1 and _("%1 like") or _("%1 likes"), r.likes) end
            if not block(r.text, Look.serif(14), by_line) then break end
        end
        if #hc.quotes > 0 and room_end - yy > S(110) then
            Look.label(bb, _("Quotes readers liked"), x, yy - S(6), w, S(18), 9, {})
            yy = yy + S(20)
            for _i, qt in ipairs(hc.quotes) do
                local who = qt.who and (qt.who.name or qt.who.username) or ""
                local by_line = who .. ((qt.likes or 0) > 0 and ("  ·  " .. T(qt.likes == 1 and _("%1 like") or _("%1 likes"), qt.likes)) or "")
                if not block(qt.text, Look.serif(14, false, true), by_line) then break end
            end
        end
        self:paintFooter(bb, v, #plist, bottom)
        -- your shelf and rating for it, and all of it: Hardcover's own page
        local ow = S(210)
        local ro = Look.button(bb, x + w - ow - Look.SHADOW_SMALL, bottom - S(106), ow, S(40), _("Open in Hardcover"), { size = 11 })
        self:hit(ro, function() require("bos_hardcover_ui").openBook(hc) end)
        return
    end
    drawCover(bb, b, x, y, cw, ch)
    local tx = x + cw + S(22)
    local tw = w - (tx - x)
    local ty = y
    ty = ty + Page.wrap(bb, b.title or "", tface(21, true), tx, ty, tw, 3, S(30)) + S(4)
    if b.author and b.author ~= "" then
        local ah = Page.wrap(bb, b.author, Look.serif(15, false, true), tx, ty, tw, 2, S(23))
        local author = b.author
        self:hit(Geom:new{ x = tx, y = ty - S(4), w = tw, h = ah + S(8) }, function()
            self:openSearch((author:gsub("%s*[,;&].*$", "")))
        end)
        ty = ty + ah + S(8)
    end
    local line = sourceLine(b)
    if b.year and not line:find(tostring(b.year), 1, true) then line = (line ~= "" and (line .. " · ") or "") .. tostring(b.year) end
    if line ~= "" then
        Look.label(bb, line, tx, ty, tw, S(18), 9, { color = Look.GRAY })
        ty = ty + S(24)
    end
    if b.language and b.language ~= "" then
        Look.label(bb, tostring(b.language), tx, ty, tw, S(18), 9, { color = Look.GRAY })
        ty = ty + S(24)
    end
    -- the key
    local ky = y + ch - S(52) - S(56)
    -- (a book from Hardcover or a pick: the other copies and books like it,
    -- a row of their own under the keys)
    local others = 0
    if v.pick then
        for _i, m in ipairs(v.matches or {}) do if m ~= v.found then others = others + 1 end end
    end
    if others > 0 then ky = ky - S(52) end
    -- Hardcover's readers: ★ 4.3 · 1.3k ratings · 2 reviews ›
    if hc and hc.rating and hc.rating > 0 and ty + S(22) <= ky - S(4) then
        local n = hc.ratings >= 1000 and (string.format("%.1fk", hc.ratings / 1000):gsub("%.0k", "k")) or tostring(hc.ratings)
        local text = stars(hc.rating) .. "  ·  " .. T(_("%1 ratings on Hardcover"), n)
        if #hc.reviews > 0 then text = text .. "  ·  " .. T(#hc.reviews == 1 and _("%1 review") or _("%1 reviews"), #hc.reviews) end
        text = text .. "  \u{203A}"
        Look.label(bb, text, tx, ty, tw, S(20), 10, {})
        self:hit(Geom:new{ x = tx, y = ty - S(6), w = tw, h = S(32) }, function()
            if pageOf("hc") then v.page = pageOf("hc") self:redraw("ui")
            else require("bos_hardcover_ui").openBook(hc) end
        end)
    end
    local kh = S(50)
    local acq = b.acquisitions and b.acquisitions[1]
    local path = acq and destination(b, acq)
    local bw2 = tw - Look.SHADOW_SMALL
    if v.state == "ready" and acq then
        if exists(path) then
            local r = Look.button(bb, tx, ky, bw2, kh, _("Read now"), { size = 14, on = true })
            self:hit(r, function() self:read(path) end)
        else
            local size = tonumber(acq.size) and (" · " .. sizeText(tonumber(acq.size))) or ""
            local r = Look.button(bb, tx, ky, bw2, kh, _("Download") .. " · " .. (acq.format or (acq.extension or ""):upper()) .. size,
                { size = 13, on = true })
            self:hit(r, function() self:download(v, acq) end)
        end
    else
        local label = (v.state == "looking" and _("Looking in the libraries…"))
            or (v.state == "details" and _("Getting the book…"))
            or (v.state == "missing" and _("Not in your libraries"))
            or (v.state == "offline" and _("Wi-Fi is off"))
            or (v.state == "ready" and _("No file to download"))
            or _("Couldn't get the book")
        Look.button(bb, tx, ky, bw2, kh, label, { size = 12, enabled = false })
    end
    -- under it: other formats / search / want
    local sy = ky + kh + S(14)
    local sh = S(40)
    local sgap = S(12)
    local half = math.floor((bw2 - sgap) / 2)
    local Online = require("bos_online")
    local want_item = v.pick or { key = "store:" .. tostring(b.id or b.title), title = b.title, author = b.author, online = true }
    local wl = Online.isWanted(want_item) and _("\u{2713} Want") or _("+ Want")
    -- (signed in to Hardcover: a key for the same book there; the row is
    -- in three then)
    local okH, HC = pcall(require, "bos_hardcover")
    local with_hc = okH and HC.signedIn and HC.signedIn() and b.title
    if with_hc then half = math.floor((bw2 - 2 * sgap) / 3) end
    local rw = Look.button(bb, tx, sy, half - Look.SHADOW_SMALL, sh, wl, { size = 11 })
    self:hit(rw, function()
        Online.toggleWant(want_item)
        self:redraw("ui", rw)
    end)
    if with_hc then
        local hx = tx + 2 * (half + sgap)
        local r = Look.button(bb, hx, sy, half - Look.SHADOW_SMALL, sh, _("Hardcover"), { size = 11, on = hc ~= nil })
        self:hit(r, function() self:openOnHardcover(v) end)
    end
    if v.state == "ready" and b.acquisitions and #b.acquisitions > 1 then
        local r = Look.button(bb, tx + half + sgap, sy, half - (with_hc and Look.SHADOW_SMALL or 0), sh, _("Formats") .. " \u{25BE}", { size = 11 })
        self:hit(r, function() self:otherFormats(v, r) end)
    elseif v.state == "missing" or v.state == "error" or v.state == "offline" then
        local r = Look.button(bb, tx + half + sgap, sy, half - (with_hc and Look.SHADOW_SMALL or 0), sh, v.state == "offline" and _("Try again") or _("Search"), { size = 11 })
        self:hit(r, function()
            if v.state == "offline" or v.state == "error" then
                if v.pick then v.state = "looking" self:lookFor(v) else self:hydrate(v, v.book) end
                self:redraw("ui")
            else
                self:openSearch(b.title or "")
            end
        end)
    end
    if others > 0 then
        local r = Look.button(bb, tx, sy + sh + S(12), bw2, sh, T(_("Other matches · %1"), others), { size = 11 })
        self:hit(r, function() self:otherMatches(v) end)
    end
    -- about
    local ay = y + ch + Look.SHADOW_SMALL + S(22)
    Look.heading(bb, _("About this book"), x, ay, w, S(26))
    ay = ay + S(36)
    local foot = S(70)
    local lines = math.max(1, math.floor((bottom - ay - foot) / S(23)))
    local desc = b.description
    if type(desc) == "string" and desc ~= "" then
        desc = desc:gsub("<[^>]+>", ""):gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&nbsp;", " ")
        b.description = desc
        local full = Page.wrap(nil, desc, Look.serif(14), 0, 0, w, nil, S(23))
        Page.wrap(bb, desc, Look.serif(14), x, ay, w, lines, S(23))
        local long = full > lines * S(23)
        if long ~= (v.long or false) then
            -- (known only once it's measured: the pages are counted again)
            v.long = long
            UIManager:nextTick(function() if not self.closed and self:view() == v then self:redraw("ui") end end)
        end
        if long then
            local r = Look.button(bb, x, bottom - S(56), S(170), S(40), _("Read more"), { size = 11 })
            self:hit(r, function() v.long = true v.page = 2 self:redraw("ui") end)
        elseif hc_says then
            local r = Look.button(bb, x, bottom - S(56), S(170), S(40), _("Reviews"), { size = 11 })
            self:hit(r, function() v.page = pageOf("hc") or 1 self:redraw("ui") end)
        end
    else
        local note = (v.state == "details" or v.state == "looking") and _("Getting the description…")
            or (v.state == "error" and (v.error or "")) or _("No description.")
        Page.wrap(bb, note, Look.serif(14, false, true), x, ay, w, 4, S(23), Look.GRAY)
    end
    if b.author and b.author ~= "" then
        local label = T(_("More by %1"), (b.author:gsub("%s*[,;&].*$", "")))
        local mw = math.min(w - S(190), Look.textWidth(Look.case(label), 11) + S(28))
        local r = Look.button(bb, x + w - mw - Look.SHADOW_SMALL, bottom - S(56), mw, S(40), label, { size = 11 })
        local author = b.author
        self:hit(r, function() self:openSearch((author:gsub("%s*[,;&].*$", ""))) end)
    end
end

-- ---------------------------------------------------------------- gestures

function Store:onSTap(_, ges)
    local pos = ges.pos
    -- the keyboard's own taps never get here; a tap in the field is the
    -- text input's (it shows the keyboard): make the list ready for it
    if self.clear_rect and inside(pos, self.clear_rect) then
        self:clear()
        return true
    end
    if inside(pos, self.field_rect) then
        if not self:keyboardUp() then self:showKeyboard() end
        return true
    end
    for k = #self.hits, 1, -1 do
        local h = self.hits[k]
        if inside(pos, h.rect) then
            -- the key or row answers the touch first, then does its thing
            UI.press(h.press or h.rect, h.fn, function(r)
                if not self.closed then self:redraw("ui", r) end
            end)
            return true
        end
    end
    return true
end

function Store:onSHold() return true end

function Store:onSSwipe(_, ges)
    local d = ges.direction
    local v = self:view()
    if self:keyboardUp() then
        if d == "south" then self:hideKeyboard() end
        return true
    end
    -- the store turns like a book: a swipe left is the next page, right the
    -- one before, on every screen of it (a row of covers moves on with the
    -- › beside its name)
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" then
        if v.page > 1 then self:turn(-1) elseif v.kind ~= "home" then self:back() end
    elseif d == "south" then
        if v.page > 1 then self:turn(-1) end
    end
    return true
end

function Store:onBack() self:back() return true end
function Store:onNextPage() self:turn(1) return true end
function Store:onPrevPage() self:turn(-1) return true end
function Store:onClose() self:close() return true end

M.Store = Store

-- ---------------------------------------------------------------- opening

--- opts: query (results for it), search (keyboard up), book (its page),
--- shelf = { title, filters }, list = { title, books, empty }.
--- Ask for a catalogue's address, read it in the background, and add it.
function M.addLibrary(done)
    local InputDialog = require("ui/widget/inputdialog")
    local Libs = require("bos_store_libs")
    local dialog
    dialog = InputDialog:new{
        title = _("Add a library"),
        description = _("The address of its catalogue (OPDS: a Calibre, Calibre-Web, Kavita or Komga server, a library's or publisher's feed), or of any website with a search: it's searched as you would, through its own search box. If the site's search isn't found, search it for a word in a browser and give the address of the results, with {q} in place of that word. With a password: https://name:password@address"),
        input = "https://",
        input_hint = "https://example.org/opds",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local url = Libs.tidy(dialog:getInputText())
                UIManager:close(dialog)
                if not url or url == "https://" then return end
                local msg = InfoMessage:new{ text = T(_("Reading %1…"), Libs.host(url)) }
                UIManager:show(msg)
                local function go()
                    Async.run(function() return Libs.probe(url) end, function(ok, info, err)
                        UIManager:close(msg)
                        if ok and type(info) == "table" then
                            local lib = Libs.add(info)
                            UIManager:show(InfoMessage:new{ text = T(_("%1 is added.\n\n%2"), lib.name,
                                lib.kind == "web" and _("It's a website: it's searched through its own search when you search, and a book's page is read for its files when you open it.")
                                or (lib.search and lib.browse) and _("It's asked when you search, and has a shelf under Browse.")
                                or lib.search and _("It's asked when you search.")
                                or _("It has a shelf under Browse (this catalogue can't be searched).")) })
                            if done then done(lib) end
                        else
                            UIManager:show(InfoMessage:new{ text = T(_("That library couldn't be added.\n\n%1"),
                                tostring((ok and err) or info or err or _("No answer."))) })
                        end
                    end, 40)
                end
                local okN, NetworkMgr = pcall(require, "ui/network/manager")
                if okN and NetworkMgr.runWhenConnected then NetworkMgr:runWhenConnected(go) else go() end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Remove one of your libraries, asked first; done() after.
function M.confirmRemove(id, name, done)
    UIManager:show(require("ui/widget/confirmbox"):new{
        text = T(_("Remove %1 from your libraries?\n\nIt's no longer asked when you search. Books downloaded from it stay."), name),
        ok_text = _("Remove"),
        ok_callback = function()
            require("bos_store_libs").remove(id)
            -- (searches cached with it in them: asked again)
            Search.cache, Search.order = {}, {}
            UIManager:show(InfoMessage:new{ text = T(_("%1 removed."), name), timeout = 2 })
            if done then done() end
        end,
    })
end

--- Settings → Connect → Store → Your libraries.
function M.libraryItems()
    local Libs = require("bos_store_libs")
    local items = {}
    for _i, lib in ipairs(Libs.list()) do
        local id = lib.id
        table.insert(items, {
            text = lib.name,
            description = Libs.host(lib.url) .. " · " .. (lib.kind == "web" and _("website, searched") or (lib.search and lib.browse) and _("search and browse")
                or lib.search and _("search") or _("browse")),
            mandatory_func = function() local l = Libs.find(id) return l and l.on ~= false and _("On") or _("Off") end,
            sub_item_table_func = function()
                return {
                    { text = _("Ask this library"), keep_menu_open = true,
                        checked_func = function() local l = Libs.find(id) return l and l.on ~= false end,
                        callback = function() local l = Libs.find(id) if l then Libs.setOn(id, l.on == false) end end },
                    { text = _("Read its catalogue again"), description = _("If the library changed how it's searched or what it lists."),
                        callback = function()
                            local l = Libs.find(id)
                            if not l then return end
                            Async.run(function() return Libs.probe(l.url) end, function(ok, info)
                                if ok and type(info) == "table" then info.name = l.name Libs.add(info) end
                                UIManager:show(InfoMessage:new{ text = ok and type(info) == "table" and _("Done.") or _("The library didn't answer."), timeout = 2 })
                            end, 40)
                        end },
                    { text = _("Remove"), callback = function(tm)
                        local l = Libs.find(id)
                        M.confirmRemove(id, l and l.name or id, function()
                            -- (back to the list, without it)
                            pcall(function() tm:backToUpperMenu() end)
                        end)
                    end },
                }
            end,
        })
    end
    table.insert(items, {
        text = _("Add a library by address…"),
        description = _("A catalogue that speaks OPDS (your own Calibre, Calibre-Web, Kavita or Komga server, a library's or publisher's feed), or any website with a search, searched through its own search box."),
        callback = function() M.addLibrary() end,
    })
    return items
end

function M.open(opts)
    opts = opts or {}
    if not bookdrop() then
        UIManager:show(InfoMessage:new{ text = _("The store isn't available here.") })
        return
    end
    local s = M.current
    if not s or s.closed then
        s = Store:new{ from_search = opts.search and true or nil }
        M.current = s
        UIManager:show(s)
    else
        -- already open under something (a book's page opened from it):
        -- bring it back to the front
        local stack = UIManager._window_stack or {}
        if stack[#stack] and stack[#stack].widget ~= s then
            for i = #stack, 1, -1 do
                if stack[i].widget == s then
                    local e = table.remove(stack, i)
                    table.insert(stack, e)
                    UIManager:setDirty(s, "ui")
                    break
                end
            end
        end
    end
    if opts.list then
        s:hideKeyboard()
        s:push{ kind = "results", title = opts.list.title, books = opts.list.books or {}, page = 1, empty = opts.list.empty }
    elseif opts.book then s:openBook(opts.book)
    elseif opts.query and opts.query:match("%S") then s:openSearch(opts.query)
    elseif opts.shelf then s:openShelf(opts.shelf.title, opts.shelf.filters)
    elseif opts.search then
        -- straight to the search screen: the field focused and the keyboard
        -- up before anything is painted, so the storefront never shows
        -- first (it used to flash by, then the search screen over it)
        local ok = pcall(function() s:showKeyboard() end)
        if not ok or not s:keyboardUp() then
            UIManager:nextTick(function() if not s.closed then s:showKeyboard() end end)
        end
    end
    return s
end

--- A book's page. `item`: a library's book, or a bos_online pick.
function M.openBook(item)
    if type(item) ~= "table" then return end
    if item.online or item.key and not item.provider then
        return M.open{ book = { title = item.title, author = item.author, year = item.year, pick = item,
            cover_path = require("bos_online").cachedCoverPath(item, "M") } }
    end
    return M.open{ book = item }
end

return M
