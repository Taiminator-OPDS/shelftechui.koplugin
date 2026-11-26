--[[
A book's details: Bookshelf's own book window (hold a book), and what we add
to it.

  M.show(fp)                  open Bookshelf's window for a book of yours
                              (from the store, a series page, the library
                              list…); KOReader's book information if
                              Bookshelf's home isn't there to host it
  M.setSummary(fp, k, v)      a book's status or rating, saved where
                              KOReader and Bookshelf read them
  M.similarStrip(book, w, modalRef, sp)  the About tab's "Similar" row:
                              books from the internet like this one (its
                              series and author first, then the rest of your
                              recommendations), covers, "In library" on the
                              ones you have; a tap opens the store on it (or
                              your own copy). nil when there are none.
--]]

local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Look = require("bos_look")
local UI = require("bos_ui")
local S = Look.S

local M = {}

local function repo()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    return ok and Repo or nil
end

local function readerUI(fp)
    local R = package.loaded["apps/reader/readerui"]
    local ui = R and R.instance
    if ui and ui.document and ui.document.file == fp then return ui end
end

function M.show(fp, opts)
    local ok, done = pcall(function()
        local bw = require("bos_shelf").shelfWidget()
        if not (bw and bw._showBookDetail) or readerUI(fp) then return false end
        local Repo = repo()
        local book = Repo and Repo.buildBook and Repo.buildBook(fp) or { filepath = fp }
        bw:_showBookDetail(book, opts)
        return true
    end)
    if ok and done then return true end
    if not ok then logger.warn("ShelfTechUI: Bookshelf's book window:", done) end
    -- in a book, or without Bookshelf's home: KOReader's own
    local okI = pcall(function() require("apps/filemanager/filemanagerbookinfo"):show(fp) end)
    return okI
end

function M.setSummary(fp, field, value)
    local ui = readerUI(fp)
    local ok, err = pcall(function()
        local ds = ui and ui.doc_settings or require("docsettings"):open(fp)
        local summary = ds:readSetting("summary") or {}
        summary[field] = value
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        if not ui then ds:flush() end
        pcall(function() require("ui/widget/booklist").setBookInfoCacheProperty(fp, field, value) end)
    end)
    if not ok then logger.warn("ShelfTechUI: book status not saved:", err) end
    local Repo = repo()
    if Repo then
        pcall(Repo.invalidateProgressCache, fp)
        pcall(Repo.invalidateReadStateCache)
    end
    pcall(function() require("bos_recs").invalidate() end)
end

-- ---------------------------------------------------------------- the row

local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and UI.boldFace(size)) or (italic and UI.italicFace(size)) or UI.face(size)
end

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

local COLS = 4

-- One row of covers, COLS across, with their titles and authors under them.
local Similar = InputContainer:extend{
    width = nil,
    items = nil,       -- bos_online's picks
    modal = nil,       -- function() → the window this row is in
}

-- The row's measures for a width: cover w, h, gap, label height, height.
local function measures(width)
    local pad, gap = S(18), S(16)
    local cw = math.floor((width - 2 * pad - (COLS - 1) * gap - Look.SHADOW_SMALL) / COLS)
    local ch = math.floor(cw * 1.5)
    local label_h = S(44)
    return pad, gap, cw, ch, label_h, S(6) + ch + S(6) + label_h + S(10)
end

function Similar:init()
    local _p, _g, _cw, _ch, _lh, h = measures(self.width)
    self.height = h
    self.dimen = Geom:new{ w = self.width, h = h }
    self.hits = {}
    self.ges_events = { RTap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } } }
    -- their covers, fetched now if they aren't on file (only the ones shown)
    local first = {}
    for i = 1, math.min(COLS, #self.items) do
        if not self.items[i].cover_path then first[#first + 1] = self.items[i] end
    end
    if #first > 0 then
        pcall(function()
            require("bos_online").fetchCovers(first, function()
                self:reload()
            end, COLS)
        end)
    end
end

function Similar:reload()
    local ok, list = pcall(function() return require("bos_online").forBook(self.query) end)
    if ok and list then self.items = list end
    if self.dimen and self.dimen.x then
        UIManager:setDirty(self.show_parent or "all", function() return "ui", self.dimen end)
    end
end

function Similar:getSize() return Geom:new{ w = self.width, h = self.height } end

function Similar:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.hits = {}
    local pad, gap, cw, ch = measures(self.width)
    local Online = require("bos_online")
    local Page = require("bos_page")
    for k = 1, COLS do
        local it = self.items[k]
        if not it then break end
        local cx = x + pad + (k - 1) * (cw + gap)
        local cy = y + S(6)
        Look.box(bb, cx, cy, cw, ch, { shadow = Look.SHADOW_SMALL, border = math.max(1, S(1)) })
        local drawn = false
        if it.cover_path then
            local okI, img = pcall(function()
                return require("ui/renderimage"):renderImageFile(it.cover_path, false, cw - 2, ch - 2)
            end)
            if okI and img then
                bb:blitFrom(img, cx + math.floor((cw - img:getWidth()) / 2), cy + math.floor((ch - img:getHeight()) / 2),
                    0, 0, img:getWidth(), img:getHeight())
                img:free()
                drawn = true
            end
        end
        if not drawn then
            local fs = math.max(10, math.floor(cw / 9))
            Page.wrap(bb, it.title or "", Look.serif(fs, true), cx + S(6), cy + S(8), cw - S(12), 5, math.floor(fs * 1.5))
        end
        if it.owned then Online.paintBadge(bb, cx + 1, cy, cw - 2, ch - 1) end
        local th = Page.wrap(bb, it.title or "", tface(12, true), cx, cy + ch + S(6), cw, 2, S(17))
        if it.author and it.author ~= "" and th < S(30) then
            Page.wrap(bb, it.author, Look.serif(11, false, true), cx, cy + ch + S(6) + th, cw, 1, S(16), Look.GRAY)
        end
        table.insert(self.hits, { rect = Geom:new{ x = cx - S(4), y = cy - S(4), w = cw + S(8), h = self.height - S(4) }, fn = function() self:open(it) end })
    end
end

--- A book tapped: the window closes, and the store opens on it (or your own
--- copy's window, when it's in your library).
function Similar:open(it)
    local modal = self.modal and self.modal()
    local item = it.pick or it
    UIManager:nextTick(function()
        if modal then pcall(function() if modal.onClose then modal:onClose() else UIManager:close(modal) end end) end
        UIManager:nextTick(function()
            local ok, err = pcall(function() require("bos_online").showSheet(item) end)
            if not ok then logger.warn("ShelfTechUI: opening a recommendation:", err) end
        end)
    end)
end

function Similar:onRTap(_, ges)
    for k = #self.hits, 1, -1 do
        local h = self.hits[k]
        if inside(ges.pos, h.rect) then
            -- (no flash: inside the About tab's scroll this row is drawn
            -- off screen first, so its rects aren't the screen's)
            h.fn()
            return true
        end
    end
    return false
end

--- The row for a book of yours (Bookshelf's record of it), `width` wide;
--- nil for a remote record or when there's nothing to show.
function M.similarStrip(book, width, modalRef, show_parent)
    if type(book) ~= "table" or type(book.filepath) ~= "string" or book.is_remote or book.is_folder then return nil end
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if okS and Sources.isRemotePath and Sources.isRemotePath(book.filepath) then return nil end
    local Online = require("bos_online")
    if not Online.enabled() then return nil end
    local query = { title = book.title, authors = book.authors or {}, series = book.series_name }
    local ok, list = pcall(Online.forBook, query)
    if not (ok and type(list) == "table" and #list > 0) then return nil end
    return Similar:new{ width = width, items = list, query = query, modal = modalRef, show_parent = show_parent }
end

return M
