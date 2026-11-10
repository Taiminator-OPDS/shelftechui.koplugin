--[[
Results (a search, a category, recently viewed), in pages.

    [■]≡≡≡≡≡≡≡≡≡≡≡[ BOOKDROP ]≡≡≡≡≡≡≡≡≡≡≡≡≡[⌕]
    Fiction                                  [SORT ▾]
    1–40 of 1,204 titles · EPUB      [ LIST | COVERS ]
    ─────────────────────────────────────────────────
    ▉  Pride and Prejudice
    ▉  Jane Austen
    ▉  EPUB · EN · 1813             [GUTENBERG]
    …
              « ‹   2 / 4+   › »

Only the books on the page are drawn and only their covers fetched; turning
past the last page loads the next batch from the library, landing on the new
page. Sort and view changes stay on this screen.
--]]

local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local Style = require("bookdrop_style")
local S = Style.S
local Screen = Device.screen

local StoreMenu = InputContainer:extend{
    name = "bookdrop_results",
    covers_fullscreen = true,
    books = nil,
    title = nil,
    subtitle = nil,
    view_mode = "list",
    sort_value = "",
    sort_label = nil,
    sort_options = nil,
    query = nil,
    on_book = nil,
    on_close = nil,
    on_search = nil,
    on_view = nil,        -- fn(mode): remember the choice
    on_sort = nil,        -- fn(value)
    on_load_more = nil,   -- fn(next_page): fetch more, reopen at next_page
    on_covers = nil,      -- fn(books, widget): fetch these covers
    has_more = false,
    start_page = 1,
}

local function nonempty(value) return value and value ~= "" and value end

local function details(book)
    local parts = {}
    for _i, v in ipairs({ book.available_formats or book.format, book.language, book.year or book.published_date,
            book.size }) do
        if nonempty(v) then table.insert(parts, tostring(v)) end
    end
    return table.concat(parts, "  \u{00B7}  ")
end

function StoreMenu:init()
    self.books = self.books or {}
    self.cover_cache = {}
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    local m = Style.MARGIN
    self.w = sw - 2 * m
    local w = self.w

    local actions = {}
    if self.on_search then
        table.insert(actions, { glyph = Style.GLYPH.search, callback = function() self.on_search(self) end })
    end
    self.strip = Style.TitleStrip{ width = sw, caption = _("Bookdrop"),
        on_close = function() self:onClose() end, actions = actions }
    self.title_bar = self.strip

    -- title and SORT
    local title_h = S(44)
    local sort_w = S(110)
    local title = Style.Painted:new{
        width = w, height = title_h,
        draw = function(p, bb, x, y)
            local face, bold = Style.face(22, true)
            local t = self.title or ""
            if self.query and self.query:match("%S") then t = "\u{201C}" .. self.query .. "\u{201D}" end
            Style.text(bb, t, x, y, w - sort_w - S(10), title_h, { face = face, bold = bold })
            if self.sort_options and #self.sort_options > 1 then
                local down = p.pressed == "sort"
                local bh = S(30)
                local by = y + math.floor((title_h - bh) / 2)
                Style.box(bb, x + w - sort_w, by, sort_w, bh, { border = math.max(1, S(1.5)),
                    fill = down and Style.BLACK or Style.WHITE })
                Style.text(bb, _("Sort") .. " \u{25BE}", x + w - sort_w, by, sort_w, bh,
                    { face = Style.mono(13), bold = true, align = "center", color = down and Style.WHITE or Style.BLACK })
                p.sort_rect = Geom:new{ x = x + w - sort_w - S(6), y = y, w = sort_w + S(6), h = title_h }
            end
        end,
        tap = function(p, pos)
            if p.sort_rect and Style.inside(pos, p.sort_rect) then
                p:press("sort", function() self:showSortMenu(p.sort_rect) end)
            elseif self.on_search and self.query and self.query:match("%S") then
                self.on_search(self)
            end
            return true
        end,
    }
    -- summary and LIST | COVERS
    local view_w = S(176)
    local sub_h = S(36)
    self.view_tabs = Style.Tabs({
        { text = _("List"), selected = self.view_mode ~= "covers", callback = function() self:setView("list") end },
        { text = _("Covers"), selected = self.view_mode == "covers", callback = function() self:setView("covers") end },
    }, view_w, { height = S(30), size = 12 })
    local summary = Style.Painted:new{
        width = w - view_w - S(10), height = sub_h,
        draw = function(p, bb, x, y)
            local text = self.subtitle or ""
            if self.sort_label and self.sort_label ~= "" then text = text .. "  \u{00B7}  " .. self.sort_label end
            Style.text(bb, text, x, y, p.width, sub_h, { face = Style.italic(14), color = Style.GRAY })
        end,
    }
    local head = VerticalGroup:new{
        align = "left",
        self.strip,
        VerticalSpan:new{ width = S(8) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = m }, title },
        HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = m }, summary,
            HorizontalSpan:new{ width = S(10) }, self.view_tabs },
        VerticalSpan:new{ width = S(8) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = m },
            Style.Painted:new{ width = w, height = Style.LINE, draw = function(_p, bb, x, y)
                bb:paintRect(x, y, w, Style.LINE, Style.BLACK) end } },
        VerticalSpan:new{ width = S(6) },
    }
    local pager_h = S(52)
    self.body_h = sh - head:getSize().h - pager_h
    self:paginate()
    self.page = math.max(1, math.min(self.start_page or 1, self.pages))

    self.body = Style.Painted:new{
        width = sw, height = self.body_h,
        draw = function(p, bb, x, y) self:drawPage(bb, x, y, p) end,
        tap = function(p, pos) return self:tapBody(p, pos) end,
        hold = function() return true end,
        swipe = function(_p, ges)
            if ges.direction == "west" or ges.direction == "north" then self:goPage(self.page + 1)
            elseif ges.direction == "east" or ges.direction == "south" then self:goPage(self.page - 1) end
            return true
        end,
    }
    self.pager = Style.Pager{
        width = w, height = pager_h,
        page = function() return self.page end,
        pages = function() return self.pages end,
        more = function() return self.has_more end,
        on_page = function(n) self:goPage(n) end,
    }
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = Style.WHITE,
        VerticalGroup:new{ align = "left", head, self.body,
            HorizontalGroup:new{ HorizontalSpan:new{ width = m }, self.pager } },
    }
    self:fetchPageCovers()
end

function StoreMenu:paginate()
    if self.view_mode == "covers" then
        self.cell_w = math.floor((self.w - 2 * S(22)) / 3) - Style.SHADOW
        self.cell_cover_h = math.floor(self.cell_w * 1.45)
        self.cell_h = self.cell_cover_h + Style.SHADOW + S(46)
        local rows = math.max(1, math.floor(self.body_h / self.cell_h))
        self.per_page = rows * 3
    else
        self.row_h = S(112)
        self.per_page = math.max(1, math.floor(self.body_h / self.row_h))
    end
    self.pages = math.max(1, math.ceil(#self.books / self.per_page))
end

function StoreMenu:pageBooks()
    local list = {}
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.books, first + self.per_page - 1) do table.insert(list, self.books[i]) end
    return list
end

function StoreMenu:drawPage(bb, x, y, p)
    bb:paintRect(x, y, p.width, p.height, Style.WHITE)
    p.hits = {}
    local m = Style.MARGIN
    local books = self:pageBooks()
    if #books == 0 then
        Style.text(bb, _("No books here."), x, y, p.width, S(120), { face = Style.italic(18), align = "center",
            color = Style.GRAY })
        return
    end
    if self.view_mode == "covers" then
        local gap = math.floor((self.w - 3 * self.cell_w - Style.SHADOW) / 2)
        for i, book in ipairs(books) do
            local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
            local bx = x + m + col * (self.cell_w + gap)
            local by = y + S(4) + row * self.cell_h
            local ox = p.pressed == book and Style.SHADOW or 0
            Style.drawCover(bb, book, bx + ox, by + ox, self.cell_w, self.cell_cover_h, self.cover_cache)
            local face, bold = Style.face(13, true)
            local tb = TextBoxWidget:new{ text = book.title or _("Untitled"), width = self.cell_w + Style.SHADOW,
                face = face, bold = bold, height = S(36), height_overflow_show_ellipsis = true }
            tb:paintTo(bb, bx, by + self.cell_cover_h + Style.SHADOW + S(6))
            tb:free()
            table.insert(p.hits, { rect = Geom:new{ x = bx, y = by, w = self.cell_w + Style.SHADOW, h = self.cell_h },
                book = book })
        end
        return
    end
    local cover_h = self.row_h - S(26)
    local cover_w = math.floor(cover_h * 0.68)
    for i, book in ipairs(books) do
        local by = y + (i - 1) * self.row_h
        local pressed = p.pressed == book
        if pressed then bb:paintRect(x, by, p.width, self.row_h - Style.THIN, Style.LIGHT) end
        Style.drawCover(bb, book, x + m, by + S(10), cover_w, cover_h, self.cover_cache)
        local tx = x + m + cover_w + Style.SHADOW + S(16)
        local tw = x + m + self.w - tx
        local face, bold = Style.face(18, true)
        local t = TextBoxWidget:new{ text = book.title or _("Untitled"), width = tw, face = face, bold = bold,
            height = S(46), height_overflow_show_ellipsis = true }
        t:paintTo(bb, tx, by + S(8))
        local th = math.min(t:getSize().h, S(46))
        t:free()
        Style.text(bb, book.author or _("Unknown author"), tx, by + S(10) + th, tw, S(24),
            { face = Style.italic(15), color = Style.GRAY })
        -- details, and the library as a chip
        local src = Style.case(tostring(book.source or _("Catalog")))
        local sf = Style.mono(11)
        local cw = Style.textWidth(src, sf, true) + S(16)
        local cy = by + self.row_h - S(36)
        Style.box(bb, x + m + self.w - cw, cy, cw, S(24), { border = math.max(1, S(1.5)) })
        Style.text(bb, src, x + m + self.w - cw, cy, cw, S(24), { face = sf, bold = true, align = "center" })
        Style.text(bb, Style.case(details(book)), tx, cy, tw - cw - S(10), S(24),
            { face = Style.mono(12), bold = true, color = Style.GRAY })
        if i < #books then
            bb:paintRect(x + m, by + self.row_h - Style.THIN, self.w, Style.THIN, Style.LIGHT)
        end
        table.insert(p.hits, { rect = Geom:new{ x = x, y = by, w = p.width, h = self.row_h }, book = book })
    end
end

function StoreMenu:tapBody(p, pos)
    for _i, hit in ipairs(p.hits or {}) do
        if Style.inside(pos, hit.rect) then
            p:press(hit.book, function()
                p:repaint("ui")
                if self.on_book then self.on_book(hit.book) end
            end)
            return true
        end
    end
    return true
end

function StoreMenu:goPage(n)
    if n > self.pages then
        -- past the last page: fetch more, and land on the new page
        if self.has_more and self.on_load_more then
            self.on_load_more(n)
        end
        return
    end
    n = math.max(1, n)
    if n == self.page then return end
    self.page = n
    Style.fullRefresh(self)
    self:fetchPageCovers()
end

function StoreMenu:onNextPage() self:goPage(self.page + 1) return true end
function StoreMenu:onPrevPage() self:goPage(self.page - 1) return true end

function StoreMenu:fetchPageCovers()
    if self.on_covers then
        UIManager:nextTick(function()
            if not self._bookdrop_closed then self.on_covers(self:pageBooks(), self) end
        end)
    end
end

--- LIST / COVERS: re-lay the page in place, keeping the first book in view.
function StoreMenu:setView(mode)
    if mode == self.view_mode then return end
    local first = (self.page - 1) * self.per_page + 1
    self.view_mode = mode
    self:paginate()
    self.page = math.max(1, math.ceil(first / self.per_page))
    if self.on_view then self.on_view(mode) end
    self:rebuildTabs()
    Style.fullRefresh(self)
    self:fetchPageCovers()
end

function StoreMenu:rebuildTabs()
    -- redraw the LIST | COVERS strip with the new selection
    local list, covers = self.view_mode ~= "covers", self.view_mode == "covers"
    local fresh = Style.Tabs({
        { text = _("List"), selected = list, callback = function() self:setView("list") end },
        { text = _("Covers"), selected = covers, callback = function() self:setView("covers") end },
    }, self.view_tabs.width, { height = self.view_tabs.height, size = 12 })
    self.view_tabs.draw = fresh.draw
    self.view_tabs.tap = fresh.tap
end

function StoreMenu:showSortMenu(anchor)
    local rows = {}
    for _i, option in ipairs(self.sort_options or {}) do
        local value, label = option[1], option[2]
        table.insert(rows, { text = _(label), checked = (self.sort_value or "") == value,
            callback = function()
                if (self.sort_value or "") ~= value and self.on_sort then self.on_sort(value) end
            end })
    end
    UIManager:show(Style.DropMenu:new{ caption = _("Sort"), rows = rows, anchor = anchor, align_right = true,
        width = math.floor(Screen:getWidth() * 0.6) })
end

--- Covers arrived: redraw the page if any of its books changed.
function StoreMenu:refreshCovers()
    local changed = false
    for _i, book in ipairs(self:pageBooks()) do
        if book.cover_path and book._drawn_path ~= book.cover_path then
            book._drawn_path = book.cover_path
            changed = true
        end
    end
    if changed then UIManager:setDirty(self, "ui") end
end

-- e-ink: refresh the whole screen when the list appears (the header too)
function StoreMenu:onShow()
    Style.fullRefresh(self)
    return true
end

function StoreMenu:onClose()
    UIManager:close(self, "ui")
    if self.on_close then self.on_close() end
    return true
end

function StoreMenu:onCloseWidget()
    self._bookdrop_closed = true
    Style.freeCache(self.cover_cache)
end

return StoreMenu
