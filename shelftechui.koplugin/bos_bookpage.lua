--[[
The book page (Aleph idea A3): one retro page per book, from a shelf (tap
and hold a book, or its details) or from the reading toolbar (BOOK, or a tap
on the book card).

  ‹ ═══ [BOOK] ═══ ⋯
  ┌────┐ The War of the Worlds
  │    │ H. G. Wells                (tap: the author's page)
  │    │ ★★★★☆                      (tap a star to rate)
  └────┘ [UNREAD][READING][FINISHED][ON HOLD]
         [■■■■░░░░░░] 34%   [RESUME] [NOTEBOOK]
  [192 PAGES | EPUB | ADDED 3 NOV | BOOK 1 OF BARSOOM]
  The description, a few lines …   READ ALL
  [SCIENCE FICTION] [CLASSICS] [+3]
  Series strip: BARSOOM · 1 OF 3 READ · UP NEXT: THE GODS OF MARS ›
  ┌[SIMILAR][MORE BY WELLS][ONLINE]┐
  │ ▮ ▮ ▮ ▮ ▮                      │
  └────────────────────────────────┘
  ‹ PREV        3 OF 12 · READING        NEXT ›     (or swipe)

⋯ holds Bookshelf's own book window (edit, cover, reviews, collections).
--]]

local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Page = require("bos_page")
local Recs = require("bos_recs")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local STATUS = {
    { key = "new", text = _("Unread") },
    { key = "reading", text = _("Reading") },
    { key = "complete", text = _("Finished") },
    { key = "abandoned", text = _("On hold") },
}
local STATUS_NAME = { new = _("Unread"), reading = _("Reading"), complete = _("Finished"), abandoned = _("On hold") }

local function repo()
    local ok, Repo = pcall(require, "lib/bookshelf_book_repository")
    return ok and Repo or nil
end

local function readerUI(fp)
    local ok, ReaderUI = package.loaded["apps/reader/readerui"] ~= nil, package.loaded["apps/reader/readerui"]
    local ui = ok and ReaderUI.instance
    if ui and ui.document and (not fp or ui.document.file == fp) then return ui end
end

--- What the page shows about a book.
function M.info(fp)
    local d = { filepath = fp }
    local Repo = repo()
    if Repo then
        local okB, meta = pcall(Repo.buildBookMeta, fp, { want_cover = false })
        if okB and type(meta) == "table" then
            d.title, d.authors, d.description = meta.title, meta.authors, meta.description
            d.genres, d.series, d.series_num = meta.genres, meta.series_name, tonumber(meta.series_num)
            d.format, d.pages = meta.format, meta.page_count
        end
        local okP, pct, status, rating, pages = pcall(Repo.readProgress, fp)
        if okP then
            d.pct, d.rating = pct, tonumber(rating)
            d.pages = d.pages or pages
            d.status = ({ finished = "complete", on_hold = "abandoned", reading = "reading" })[status or ""]
        end
    end
    if not d.title then d.title = (fp:match("([^/]+)$") or fp):gsub("%.[^.]+$", "") end
    d.authors = d.authors or {}
    if type(d.authors) == "string" then d.authors = { d.authors } end
    if not d.status then d.status = (d.pct and d.pct > 0) and "reading" or "new" end
    local lfs = require("libs/libkoreader-lfs")
    local mt = lfs.attributes(fp, "modification")
    if mt then d.added = (os.date("%d %b %Y", mt):gsub("^0", "")) end
    if type(d.description) == "string" then
        d.description = d.description:gsub("<[^>]+>", " "):gsub("&nbsp;", " "):gsub("&amp;", "&")
            :gsub("&quot;", "\""):gsub("&#39;", "'"):gsub("%s+", " ")
    end
    return d
end

--- Writes the book's status or rating (into the open book's settings when
--- it's the one being read, so closing it doesn't undo this).
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
    Recs.invalidate()
end

-- ---------------------------------------------------------------- the page

local BookPage = Page:extend{ caption = _("Book") }

function BookPage:init()
    Page.init(self)
    self.tab = self.tab or "similar"
    self:load()
end

function BookPage:load()
    self.fp = self.list[self.index]
    self.d = M.info(self.fp)
    self.similar = nil
end

function BookPage:open(fp)
    local okS, Shelf = pcall(require, "bos_shelf")
    local ui = readerUI()
    self:onClose()
    if ui and ui.document.file == fp then return end
    if okS and Shelf.open then Shelf.open(fp)
    elseif ui then ui:switchDocument(fp)
    else require("apps/reader/readerui"):showReader(fp) end
end

function BookPage:go(delta)
    local i = self.index + delta
    if i < 1 or i > #self.list then return end
    self.index = i
    self:load()
    self:refresh("ui")
end

function BookPage:tabBooks()
    local d = self.d
    if self.tab == "author" then
        local out = {}
        for _i, b in ipairs(Recs.byAuthor(d.authors[1])) do
            if b.filepath ~= self.fp then table.insert(out, b) end
        end
        return out
    elseif self.tab == "online" then
        local okO, Online = pcall(require, "bos_online")
        return okO and Online.forBook(d) or {}
    end
    self.similar = self.similar or Recs.similar(self.fp, 12)
    return self.similar
end

function BookPage.drawBody(self, bb, y, w)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local x = self.pad
    local d = self.d
    -- cover | title, author, stars, status, progress, buttons
    local cw = math.min(math.floor(W * 0.26), S(140))
    local ch = math.floor(cw * 1.5)
    require("bos_cover").paint(bb, self.fp, x, y, cw, ch, { shadow = S(4), title = d.title })
    local tx = x + cw + S(4) + S(16)
    local tw = W - self.pad - tx
    local ty = y
    ty = ty + Page.wrap(bb, d.title, Page.serif(19, true), tx, ty, tw, 2, S(26))
    if d.authors[1] then
        local a = table.concat(d.authors, ", ")
        local aw = Look.label(bb, a, tx, ty + S(2), tw, S(22), 12, { keep_case = true, bold = false })
        bb:paintRect(tx, ty + S(20), math.min(aw, tw), math.max(1, S(1)), BLACK)
        self:hit(Geom:new{ x = tx, y = ty, w = math.min(aw, tw) + S(8), h = S(26) }, function(p)
            require("bos_series").showAuthor(d.authors[1])
        end)
        ty = ty + S(28)
    end
    local srects = Page.stars(bb, tx, ty, S(18), d.rating)
    for i, r in ipairs(srects) do
        self:hit(r, function(p)
            local v = (d.rating == i) and nil or i
            M.setSummary(p.fp, "rating", v)
            d.rating = v
            p:refresh("ui")
        end)
    end
    ty = ty + S(28)
    local on = { [d.status] = true }
    local rects, sh = Page.chips(bb, STATUS, tx, ty, tw, 9, on)
    for i, r in ipairs(rects) do
        self:hit(r, function(p)
            local st = STATUS[i].key
            M.setSummary(p.fp, "status", st)
            d.status = st
            p:refresh("ui")
        end)
    end
    ty = ty + sh + S(10)
    -- progress
    local pct = math.floor((d.pct or 0) * 100 + 0.5)
    if d.status == "complete" then pct = 100 end
    local pw = Look.textWidth("100%", 11)
    local bw = tw - pw - S(10)
    Look.slimTrack(bb, tx, ty, bw, S(14), pct / 100)
    Look.label(bb, pct .. "%", tx + tw - pw, ty, pw, S(14), 11, { align = "right" })
    ty = ty + S(24)
    -- [READ / RESUME] [NOTEBOOK]
    local label = d.status == "new" and _("Read") or (d.status == "complete" and _("Read again") or _("Resume"))
    local b1w = Look.textWidth(require("bos_look").case(label), 12) + S(28)
    local r1 = Look.button(bb, tx, ty, b1w, S(38), label, { on = true, size = 12, down = self.pressed == "read" })
    self:hit(r1, function(p) p:open(p.fp) end, nil, "read")
    local ui = readerUI(self.fp)
    if ui then
        local l2 = _("Notebook")
        local r2 = Look.button(bb, tx + b1w + S(14), ty, Look.textWidth(require("bos_look").case(l2), 12) + S(28), S(38), l2,
            { size = 12, down = self.pressed == "notebook" })
        self:hit(r2, function(p) p:onClose() require("bos_nav").showNotebook(ui) end, nil, "notebook")
    end
    y = math.max(y + ch + S(8), ty + S(44)) + S(10)

    -- facts: pages · format · added · series
    local facts = {}
    if d.pages then table.insert(facts, T(_("%1 pages"), d.pages)) end
    if d.format and d.format ~= "" then table.insert(facts, d.format) end
    if d.added then table.insert(facts, T(_("Added %1"), d.added)) end
    if d.series then table.insert(facts, d.series_num and T(_("#%1 %2"), d.series_num, d.series) or d.series) end
    if #facts > 0 then
        local fh = S(28)
        Look.box(bb, x, y, w, fh)
        local cx = x
        local cell = math.floor(w / #facts)
        for i, f in ipairs(facts) do
            local this = (i == #facts) and (x + w - cx) or cell
            Look.label(bb, f, cx + S(6), y, this - S(12), fh, 10)
            if i < #facts then bb:paintRect(cx + this - Look.LINE, y, Look.LINE, fh, BLACK) end
            cx = cx + this
        end
        y = y + fh + S(12)
    end

    -- description + READ ALL
    local foot_h = S(44)
    if d.description and d.description ~= "" then
        local face = Page.serif(14)
        local h = Page.wrap(bb, d.description, face, x, y, w, 4, S(22))
        y = y + h + S(4)
        local rl = require("bos_look").case(_("Read all"))
        local rw = Look.label(bb, rl, x, y, w, S(20), 10)
        bb:paintRect(x, y + S(17), rw, math.max(1, S(1)), BLACK)
        self:hit(Geom:new{ x = x - S(4), y = y - S(4), w = rw + S(12), h = S(28) }, function(p)
            local TextViewer = require("ui/widget/textviewer")
            UIManager:show(TextViewer:new{ title = d.title, text = d.description })
        end)
        y = y + S(28)
    end

    -- genre chips (two lines at most; the rest as +n)
    if d.genres and #d.genres > 0 then
        local items = {}
        for i, g in ipairs(d.genres) do if i <= 6 then items[i] = { text = g } end end
        if #d.genres > 6 then table.insert(items, { text = "+" .. (#d.genres - 6) }) end
        local _r, gh = Page.chips(bb, items, x, y, w, 9)
        y = y + gh + S(12)
    end

    -- series strip
    if d.series then
        local list = Recs.series(d.series)
        local read, nxt = 0, nil
        for _i, b in ipairs(list) do
            if b.state == "finished" then read = read + 1 end
        end
        for _i, b in ipairs(list) do
            if b.state == "unread" and b.filepath ~= self.fp then nxt = b break end
        end
        local text = T(_("%1 · %2 of %3 read"), d.series, read, #list)
        if nxt then text = text .. " · " .. T(_("Up next: %1"), nxt.title or "") end
        local sh2 = S(30)
        Look.box(bb, x, y, w - Look.SHADOW_SMALL, sh2, { shadow = Look.SHADOW_SMALL })
        Look.label(bb, text .. "  \u{203A}", x + S(10), y, w - S(24), sh2, 10)
        self:hit(Geom:new{ x = x, y = y, w = w, h = sh2 + S(4) }, function(p)
            require("bos_series").showSeries(d.series)
        end)
        y = y + sh2 + Look.SHADOW_SMALL + S(12)
    end

    -- SIMILAR | MORE BY … | ONLINE, and their covers
    local room = H - foot_h - y - S(8)
    local tabs = { { key = "similar", text = _("Similar") } }
    if d.authors[1] then
        local surname = d.authors[1]:match("(%S+)%s*$") or d.authors[1]
        table.insert(tabs, { key = "author", text = T(_("More by %1"), surname) })
    end
    local okO, Online = pcall(require, "bos_online")
    if okO and Online.enabled() then table.insert(tabs, { key = "online", text = _("Online") }) end
    local th = S(30)
    local cw2 = math.min(S(64), math.floor((room - th - S(30)) / 1.5))
    if cw2 >= S(30) then
        local boxh = th + S(14) + math.floor(cw2 * 1.5) + S(14)
        Look.box(bb, x, y, w - Look.SHADOW, boxh, { shadow = Look.SHADOW })
        local tabw = math.floor((w - Look.SHADOW) / #tabs)
        for i, t in ipairs(tabs) do
            local tx2 = x + (i - 1) * tabw
            local sel = t.key == self.tab
            if sel then bb:paintRect(tx2, y, (i == #tabs) and (x + w - Look.SHADOW - tx2) or tabw, th, BLACK) end
            if i > 1 then bb:paintRect(tx2, y, Look.LINE, th, BLACK) end
            Look.label(bb, t.text, tx2 + S(4), y, tabw - S(8), th, 10, { align = "center", color = sel and WHITE or BLACK })
            self:hit(Geom:new{ x = tx2, y = y, w = tabw, h = th }, function(p) p.tab = t.key p:refresh("ui") end)
        end
        bb:paintRect(x, y + th, w - Look.SHADOW, Look.LINE, BLACK)
        local books = self:tabBooks()
        if #books == 0 then
            local msg = self.tab == "online" and _("Nothing yet: pull down on For you · Online to fetch picks.")
                or _("Nothing like it in your library yet.")
            Look.label(bb, msg, x + S(12), y + th + S(10), w - S(24), S(24), 10, { color = Look.GRAY, keep_case = true, bold = false })
        else
            local rects = Page.coverRow(bb, books, x + S(8), y + th + S(14), w - Look.SHADOW - S(16), cw2,
                { no_shelf = true, gap = S(12) })
            for i, r in ipairs(rects) do
                local b = books[i]
                self:hit(r, function(p)
                    if b.online then require("bos_online").showSheet(b)
                    else M.show(b.filepath) end
                end)
            end
        end
    end

    -- ‹ PREV · 3 OF 12 · READING · NEXT ›
    local fy = H - foot_h
    bb:paintRect(0, fy, W, Look.LINE, BLACK)
    local mid = T(_("%1 of %2 · %3"), self.index, #self.list, STATUS_NAME[d.status] or "")
    Look.label(bb, mid, x, fy, w, foot_h, 10, { align = "center" })
    if self.index > 1 then
        Look.label(bb, "\u{2039} " .. _("Prev"), x, fy, S(90), foot_h, 10)
        self:hit(Geom:new{ x = 0, y = fy, w = S(110), h = foot_h }, function(p) p:go(-1) end)
    end
    if self.index < #self.list then
        Look.label(bb, _("Next") .. " \u{203A}", x + w - S(90), fy, S(90), foot_h, 10, { align = "right" })
        self:hit(Geom:new{ x = W - S(110), y = fy, w = S(110), h = foot_h }, function(p) p:go(1) end)
    end
end

function BookPage.more(self, rect)
    local d = self.d
    local items = {}
    if self.widget and self.widget._showBookDetail then
        table.insert(items, { text = _("Edit, cover and reviews (Bookshelf)"), callback = function()
            local w, fp = self.widget, self.fp
            self:onClose()
            local ok, err = pcall(function()
                local Repo = repo()
                local book = Repo and Repo.buildBook and Repo.buildBook(fp) or { filepath = fp }
                w:_showBookDetail(book, { stui_original = true })
            end)
            if not ok then logger.warn("ShelfTechUI: Bookshelf's book window failed:", err) end
        end })
    end
    if d.series then
        table.insert(items, { text = T(_("Series: %1"), d.series), callback = function() require("bos_series").showSeries(d.series) end })
    end
    if d.authors[1] then
        table.insert(items, { text = T(_("Author: %1"), d.authors[1]), callback = function() require("bos_series").showAuthor(d.authors[1]) end })
    end
    table.insert(items, { text = _("Book information (KOReader)"), callback = function()
        local fp = self.fp
        pcall(function() require("apps/filemanager/filemanagerbookinfo"):show(fp) end)
    end })
    require("bos_ui").openList(items, rect)
end

function BookPage.swipe(self, dir)
    if dir == "west" then self:go(1)
    elseif dir == "east" then
        if self.index > 1 then self:go(-1) else self:onClose() end
    end
end

--- Shows the page for `fp`; `opts.list` (files) makes ‹ › walk that list.
function M.show(fp, opts)
    opts = opts or {}
    local list = opts.list or { fp }
    local index
    for i, f in ipairs(list) do if f == fp then index = i break end end
    if not index then list = { fp } index = 1 end
    BookPage:new{ list = list, index = index, widget = opts.widget,
        draw = BookPage.drawBody, on_more = BookPage.more, on_swipe = BookPage.swipe }:show()
    return true
end

--- From the reader (BOOK on the toolbar): this book, with the ones you're
--- also reading as its neighbours.
function M.open(ui, fp)
    local list = { fp }
    for _i, b in ipairs(require("bos_reading").alsoReading(ui, 6)) do table.insert(list, b.file) end
    return M.show(fp, { list = list })
end

--- Bookshelf's book window opens this page instead (its own window stays
--- one tap away, under ⋯).
function M.install()
    if M._installed then return end
    M._installed = true
    pcall(function()
        local BW = require("lib/bookshelf_widget")
        local orig = BW._showBookDetail
        if type(orig) ~= "function" then return end
        BW._showBookDetail = function(self, book, opts)
            local Store = require("bos_settings_store")
            if Store.get("book_page") ~= false and not (opts and opts.stui_original) and type(book) == "table"
                    and type(book.filepath) == "string" and not book.is_remote and not book.opds
                    and not book.is_folder then
                local okS, Sources = pcall(require, "lib/bookshelf_sources")
                if not (okS and Sources.isRemotePath and Sources.isRemotePath(book.filepath)) then
                    local list
                    pcall(function() list = self:_currentViewBookPaths() end)
                    return M.show(book.filepath, { list = list, widget = self })
                end
            end
            return orig(self, book, opts)
        end
    end)
end

return M
