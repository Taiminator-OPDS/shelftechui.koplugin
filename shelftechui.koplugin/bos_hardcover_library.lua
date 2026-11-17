--[[
Hardcover in the library: the books on your Reading and Want to read shelves
on Hardcover that aren't on this device stand at the end of Home, faded, with
a small GET under them. A tap opens the book in the store (the libraries are
asked for it there); a long press, its Hardcover page. Once you have it on the
device (from the store, Transfer, anywhere), the faded one goes.

    ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌ ─ ─ ─ ─ ┐
    │  yours   │ │  yours   │ │  yours   │   faded
    │          │ │          │ │          │ │         │
    │          │ │          │ │          │     [GET]
    └──────────┘ └──────────┘ └──────────┘ └ ─ ─ ─ ─ ┘

"On the device" is the book linked to Hardcover (bos_hardcover's links),
or one with the same title and author in the library (bos_online.owned).

Nothing here waits on the network while home draws: the shelves are what was
last fetched (bos_hardcover.mineCached), fetched again in the background when
older than a quarter of an hour and Wi-Fi is on; the faded covers are made
once each, a few at a time after home has drawn, and kept beside Hardcover's
covers. Settings → Hardcover: which shelves, or none.

Also a shelf source ("Hardcover: not on this device"), for a shelf of them
alone.

  M.install()     once (wraps the repository's shelf fetch for Home)
  M.records()     the faded books, as library records
--]]

local Blitbuffer = require("ffi/blitbuffer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

local M = {}

M.PREFIX = "stuihc://"
M.SOURCE = "stui_hcghost"

-- Hardcover, only once it's been used (a device never signed in pays nothing)
local function hc()
    local HC = package.loaded["bos_hardcover"]
    if HC then return HC end
    if M.unused == nil then
        local lfs = require("libs/libkoreader-lfs")
        M.unused = lfs.attributes(require("datastorage"):getSettingsDir() .. "/stui_hardcover.lua", "mode") ~= "file"
    end
    if M.unused then return nil end
    return require("bos_hardcover")
end

--- "reading_want" (default) | "reading" | "off"
function M.mode()
    local HC = hc()
    return HC and HC.get("library_ghosts", "reading_want") or "off"
end

local function coverDir()
    return require("datastorage"):getDataDir() .. "/cache/stui_hardcover"
end

local function exists(p)
    return p and require("libs/libkoreader-lfs").attributes(p, "mode") == "file"
end

-- ---------------------------------------------------------------- the faded covers

local W, H = 240, 360

--- GET in a small black pill, bottom right of a cover w x h.
local function getPill(bb, w, h)
    local Look = require("bos_look")
    local size = math.max(7, math.floor(w / 16))
    local ph = math.floor(w * 0.13)
    local pw = math.floor(w * 0.34)
    local x, y = w - pw - math.floor(w * 0.06), h - ph - math.floor(w * 0.06)
    bb:paintRoundedRect(x, y, pw, ph, Blitbuffer.COLOR_BLACK, math.floor(ph / 2))
    Look.label(bb, "\u{2193} " .. _("Get"), x, y, pw, ph, size, { align = "center", color = Blitbuffer.COLOR_WHITE })
end

--- From Hardcover's cover: scaled, faded, GET.
local function fromCover(src, out)
    local RenderImage = require("ui/renderimage")
    local img = RenderImage:renderImageFile(src, false)
    if not img then error("no image") end
    local iw, ih = img:getWidth(), img:getHeight()
    local h = math.max(1, math.floor(W * ih / math.max(1, iw) + 0.5))
    if iw ~= W then img = RenderImage:scaleBlitBuffer(img, W, h, true) end
    img:lightenRect(0, 0, W, h, 0.6)
    getPill(img, W, h)
    img:writePNG(out)
    img:free()
end

--- No cover: a pale card with the title and author, and GET.
local function placeholder(b, out)
    local Page = require("bos_page")
    local bb = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    local edge = Blitbuffer.COLOR_LIGHT_GRAY
    bb:paintRect(0, 0, W, 2, edge) bb:paintRect(0, H - 2, W, 2, edge)
    bb:paintRect(0, 0, 2, H, edge) bb:paintRect(W - 2, 0, 2, H, edge)
    local pad = 18
    local Font = require("ui/font")
    Page.wrap(bb, b.title or "", Font:getFace("cfont", 18), pad, 40, W - 2 * pad, 5, 26, Blitbuffer.COLOR_GRAY_9)
    if b.author then Page.wrap(bb, b.author, Font:getFace("cfont", 13), pad, 40 + 5 * 26 + 12, W - 2 * pad, 2, 20, Blitbuffer.COLOR_GRAY_9) end
    getPill(bb, W, H)
    bb:writePNG(out)
    bb:free()
end

local function ghostPath(b) return coverDir() .. "/" .. b.id .. "_g.png" end
local function placePath(b) return coverDir() .. "/" .. b.id .. "_p.png" end

-- made a few at a time after home has drawn; home redraws when they're done
local todo, todo_set, working = {}, {}, false
local function refreshHome()
    UIManager:unschedule(M._refresh)
    UIManager:scheduleIn(0.5, M._refresh)
end
function M._refresh()
    pcall(function() require("bos_home").refresh() end)
end
local function work()
    local HC = hc()
    local made = 0
    while #todo > 0 and made < 3 do
        local b = table.remove(todo, 1)
        todo_set[b.id] = nil
        local src = HC and HC.coverPath(b)
        local ok, err = pcall(function()
            if src then fromCover(src, ghostPath(b)) else placeholder(b, placePath(b)) end
        end)
        if not ok then logger.warn("ShelfTechUI: faded cover:", err) end
        made = made + 1
    end
    if #todo > 0 then UIManager:scheduleIn(0.2, work) return end
    working = false
    refreshHome()
end
local function want(b)
    if todo_set[b.id] then return end
    todo_set[b.id] = true
    todo[#todo + 1] = b
    if not working then
        working = true
        UIManager:scheduleIn(0.3, work)
    end
end

--- The faded cover's file, or nil while it's being made.
local function coverFor(b, HC)
    local g = ghostPath(b)
    if exists(g) then return g end
    local src = HC.coverPath(b)
    if src then want(b) end
    local p = placePath(b)
    if exists(p) then return p end
    if not src then want(b) end
    return nil
end

-- ---------------------------------------------------------------- which books

local memo = { key = nil, list = nil }

--- Your Hardcover books that aren't on this device (book tables), in the
--- order Hardcover has them (latest first), Reading before Want to read.
function M.books()
    local HC = hc()
    local mode = M.mode()
    if not HC or mode == "off" or not HC.signedIn() then return {} end
    local mine = HC.mineCached()
    -- fresh in the background (home redraws when it's here)
    pcall(HC.mineTouch, refreshHome)
    local libgen
    pcall(function()
        local L = require("bos_recs").library()
        libgen = L and (tostring(L.gen) .. ":" .. #L.books)
    end)
    local key = table.concat({ mode, HC.mine_gen or 0, mine.at or 0, HC.links_gen or 0, libgen or "-" }, "|")
    if memo.key == key then return memo.list end
    local linked = {}
    for file, link in pairs(HC.get("links") or {}) do
        if type(link) == "table" and link.id and exists(file) then linked[link.id] = true end
    end
    local Online = require("bos_online")
    local reading, wanted = {}, {}
    for _i, b in ipairs(mine.books or {}) do
        if (b.status == 2 or (b.status == 1 and mode == "reading_want")) and not linked[b.id]
                and not Online.owned({ title = b.title, author = b.author }) then
            if b.status == 2 then reading[#reading + 1] = b else wanted[#wanted + 1] = b end
        end
    end
    for _i, b in ipairs(wanted) do reading[#reading + 1] = b end
    memo.key, memo.list = key, reading
    return reading
end

--- The same, as library records (fresh tables each time: a shelf frees what
--- it painted).
function M.records()
    local HC = hc()
    local books = M.books()
    if #books == 0 then return {} end
    local out, no_cover = {}, {}
    for _i, b in ipairs(books) do
        if not HC.coverPath(b) then no_cover[#no_cover + 1] = b end
        out[#out + 1] = {
            filepath = M.PREFIX .. tostring(b.id), title = b.title, authors = { b.author }, author = b.author,
            cover_image_path = coverFor(b, HC), is_remote = true, source_kind = M.SOURCE,
            hardcover_rating = b.rating, hardcover_ratings_count = b.ratings, stui_hc_rating = b.rating and true or nil,
            stui_hc = b,
        }
    end
    -- Hardcover's covers, the first time they're needed
    if #no_cover > 0 then pcall(HC.fetchCovers, no_cover, function()
        for _i, b in ipairs(no_cover) do if HC.coverPath(b) then want(b) end end
    end, 12) end
    return out
end

-- ---------------------------------------------------------------- tapped

function M.open(book)
    local b = book and book.stui_hc
    if not b then return end
    local HC = hc()
    local item = { online = true, key = "hardcover:" .. tostring(b.id), title = b.title, author = b.author, year = b.year }
    require("bos_store").open{ book = { title = b.title, author = b.author, year = b.year, pick = item,
        cover_path = HC and HC.coverPath(b) } }
end

function M.info(book)
    local b = book and book.stui_hc
    if not b then return end
    require("bos_hardcover_ui").openBook(b)
end

-- ---------------------------------------------------------------- on Home

local function isHome(source, filter, opts)
    if type(source) ~= "table" then return false end
    if source.kind ~= "all" and source.kind ~= "library" then return false end
    if source.id or source.drill then return false end
    if type(filter) == "table" and next(filter) ~= nil then
        local okF, Filter = pcall(require, "lib/bookshelf_filter")
        if not okF or Filter.isActive(filter) then return false end
    end
    if opts and opts.light_only then return false end
    return true
end

--- After Home's own books: the faded ones (its last page, and as many pages
--- more as they need).
function M.extend(Repo, source, filter, offset, limit, opts, page, total)
    if Repo.spine_light or type(page) ~= "table" or type(total) ~= "number" then return nil end
    if not isHome(source, filter, opts) then return nil end
    local ghosts = M.records()
    if #ghosts == 0 then return nil end
    local off = offset or 0
    local lim = limit or (total + #ghosts)
    local out = {}
    for k, v in pairs(page) do out[k] = v end
    local i = math.max(0, off - total) + 1
    while #out < lim and ghosts[i] do
        out[#out + 1] = ghosts[i]
        i = i + 1
    end
    return out, total + #ghosts
end

function M.install()
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    if not okR or type(Repo) ~= "table" or Repo._stui_ghosts then return end
    Repo._stui_ghosts = true
    local orig = Repo.getBySource
    Repo.getBySource = function(source, filter, sort_priority, offset, limit, opts)
        local page, total = orig(source, filter, sort_priority, offset, limit, opts)
        local ok, p2, t2 = pcall(M.extend, Repo, source, filter, offset, limit, opts, page, total)
        if not ok then logger.warn("ShelfTechUI: Hardcover books on Home:", p2) return page, total end
        if p2 then return p2, t2 end
        return page, total
    end
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if okS then
        local okReg, err = Sources.register(M.SOURCE, {
            api = 1,
            label = function() return _("Hardcover: not on this device") end,
            available = function() local HC = hc() return HC and HC.signedIn() or false end,
            remote_prefix = M.PREFIX,
            list = function() return M.records() end,
            owns = function(book) return type(book) == "table" and type(book.filepath) == "string"
                and book.filepath:sub(1, #M.PREFIX) == M.PREFIX end,
            open = function(book) M.open(book) return true end,
            info = function(book) M.info(book) end,
        })
        if not okReg then logger.warn("ShelfTechUI: Hardcover shelf not registered:", err) end
    end
end

return M
