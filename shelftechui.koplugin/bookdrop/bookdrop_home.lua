--[[
Bookdrop's home: the store front, in pages (no scrolling, kind to e-ink).

    [■]≡≡≡≡≡≡≡≡≡≡≡[ BOOKDROP ]≡≡≡≡≡≡≡≡≡≡≡[⌕][⚙]
    [ ⌕  Search titles, authors, subjects…    ]
    [ STORE | CATEGORIES ▾ | RECENT | MANGA   ]
    NEW AND NOTEWORTHY ................ [SEE ALL ›]
    ▉▉▉   ▉▉▉   ▉▉▉
    title  title  title
    FICTION & LITERATURE .............. [SEE ALL ›]
    …
              « ‹   1 / 3   › »

Swipe left/right (or up/down) or use the arrows to turn pages. Covers are
decoded once and kept for the life of the screen; when a cover arrives only
the page is redrawn.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local QRWidget = require("ui/widget/qrwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local _ = require("gettext")

local Style = require("bookdrop_style")
local S = Style.S
local Screen = Device.screen

-- ---------------------------------------------------------------------------
-- Support (a retro window with the QR code)
-- ---------------------------------------------------------------------------

local DonationDialog = InputContainer:extend{ modal = true }

function DonationDialog:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if Device:hasKeys() then self.key_events.Close = { { Device.input.group.Back } } end
    self.ges_events = {
        TapClose = { GestureRange:new{ ges = "tap", range = Geom:new{ x = 0, y = 0, w = sw, h = sh } } },
    }
    local win_w = math.floor(sw * 0.8)
    local inner = win_w - 2 * Style.LINE
    local qr_size = math.floor(math.min(sw, sh) * 0.42)
    local face = Style.face(16)
    local body = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = S(18) },
        TextBoxWidget:new{
            text = _("Enjoying Bookdrop?\nScan the code with your phone to support the project."),
            alignment = "center", face = face, width = inner - S(40),
        },
        VerticalSpan:new{ width = S(18) },
        QRWidget:new{ text = "https://ko-fi.com/davidc465", width = qr_size, height = qr_size },
        VerticalSpan:new{ width = S(10) },
        TextBoxWidget:new{ text = "ko-fi.com/davidc465", alignment = "center",
            face = Style.mono(13), bold = true, width = inner - S(40) },
        VerticalSpan:new{ width = S(18) },
    }
    local window = FrameContainer:new{
        bordersize = Style.LINE, color = Style.BLACK, radius = 0, padding = 0, margin = 0,
        background = Style.WHITE,
        VerticalGroup:new{
            Style.TitleStrip{ width = inner, caption = _("Support Bookdrop"), height = S(32),
                on_close = function() self:onClose() end },
            CenterContainer:new{ dimen = Geom:new{ w = inner, h = body:getSize().h }, body },
        },
    }
    local ws = window:getSize()
    self.rect = Geom:new{ x = math.floor((sw - ws.w) / 2), y = math.floor((sh - ws.h) / 2), w = ws.w, h = ws.h }
    self.window = window
    self.dimen = Geom:new{ x = self.rect.x, y = self.rect.y, w = ws.w + Style.SHADOW, h = ws.h + Style.SHADOW }
end

function DonationDialog:paintTo(bb)
    local r = self.rect
    Style.shadow(bb, r.x, r.y, r.w, r.h)
    self.window:paintTo(bb, r.x, r.y)
end

function DonationDialog:onTapClose() self:onClose() return true end
function DonationDialog:onShow() UIManager:setDirty(self, "ui", self.dimen) return true end
function DonationDialog:onClose() UIManager:close(self, "ui", self.dimen) return true end

-- ---------------------------------------------------------------------------
-- Home
-- ---------------------------------------------------------------------------

local StoreHome = InputContainer:extend{
    name = "bookdrop_home",
    covers_fullscreen = true,
    featured_books = nil,
    category_cards = nil,
    on_book = nil,
    on_search = nil,
    on_new_arrivals = nil,
    on_all_books = nil,
    on_recent = nil,
    on_manga = nil,
    settings_builder = nil,
    has_recent = false,
}

--- Run a callback that opens something over home (home stays underneath, so
--- coming back is instant).
function StoreHome:run(callback, value)
    if callback then callback(value) end
end

function StoreHome:sections()
    local list = {}
    if #self.featured_books > 0 then
        table.insert(list, { title = _("New and noteworthy"), books = self.featured_books,
            callback = self.on_new_arrivals })
    end
    for _i, card in ipairs(self.category_cards) do
        if card.books and #card.books > 0 then table.insert(list, card) end
    end
    table.insert(list, { support = true })
    return list
end

function StoreHome:init()
    self.featured_books = self.featured_books or {}
    self.category_cards = self.category_cards or {}
    self.cover_cache = {}
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    local m = Style.MARGIN
    local w = sw - 2 * m

    self.strip = Style.TitleStrip{
        width = sw, caption = _("Bookdrop"),
        on_close = function() self:onClose() end,
        actions = {
            { glyph = Style.GLYPH.cog, callback = function() self:showSettings() end },
        },
    }
    self.title_bar = self.strip -- (older callers measure it)

    local search_h = S(40)
    local search = Style.Painted:new{
        width = w, height = search_h,
        draw = function(p, bb, x, y)
            local down = p.pressed == 1
            Style.box(bb, x, y, w, search_h, { border = math.max(1, S(1.5)), fill = down and Style.BLACK or Style.WHITE })
            local ink = down and Style.WHITE or Style.GRAY
            Style.text(bb, Style.GLYPH.search, x + S(14), y, S(20), search_h, { face = Style.symbol(13), color = ink })
            Style.text(bb, _("Search titles, authors, subjects…"), x + S(42), y, w - S(56), search_h,
                { face = Style.italic(16), color = ink })
        end,
        tap = function(p)
            p:press(1, function() if self.on_search then self.on_search(self) end end)
            return true
        end,
    }

    self.tab_cells = {
        { text = _("Store"), selected = true, callback = function() end },
        { text = _("Categories") .. " \u{25BE}", callback = function(rect) self:showCategories(rect) end },
        { text = _("Recent"), enabled = self.has_recent, callback = function() self:run(self.on_recent) end },
        { text = _("Manga"), enabled = self.on_manga ~= nil, callback = function() self:run(self.on_manga) end },
    }
    self.tabs = Style.Tabs(self.tab_cells, w, { height = S(38), size = 13 })

    local pager_h = S(52)
    local head = VerticalGroup:new{
        align = "left",
        self.strip,
        VerticalSpan:new{ width = S(12) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = m }, search },
        VerticalSpan:new{ width = S(10) },
        HorizontalGroup:new{ HorizontalSpan:new{ width = m }, self.tabs },
        VerticalSpan:new{ width = S(6) },
    }
    local body_h = sh - head:getSize().h - pager_h

    -- pages of sections
    -- two shelves a page: covers sized to fit, as many to a shelf as fit
    self.label_h = S(40)
    self.caption_h = S(42)
    local per_page = 2
    local room = math.floor(body_h / per_page) - self.label_h - self.caption_h - Style.SHADOW - S(10)
    self.cover_h = math.min(room, math.floor((w - 2 * S(22)) / 3 * 1.45))
    self.cover_w = math.floor(self.cover_h / 1.45)
    local min_gap = S(20)
    self.per_shelf = math.max(3, math.min(4, math.floor((w + min_gap) / (self.cover_w + Style.SHADOW + min_gap))))
    self.section_h = self.label_h + self.cover_h + Style.SHADOW + self.caption_h + S(10)
    self.pages_list = {}
    local page = {}
    for _i, sec in ipairs(self:sections()) do
        if #page >= per_page then
            table.insert(self.pages_list, page)
            page = {}
        end
        table.insert(page, sec)
    end
    if #page > 0 then table.insert(self.pages_list, page) end
    self.page = 1

    self.body = Style.Painted:new{
        width = sw, height = body_h,
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
        pages = function() return #self.pages_list end,
        on_page = function(n) self:goPage(n) end,
    }

    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0, background = Style.WHITE,
        VerticalGroup:new{
            align = "left",
            head,
            self.body,
            HorizontalGroup:new{ HorizontalSpan:new{ width = m }, self.pager },
        },
    }
end

function StoreHome:drawPage(bb, x, y, p)
    bb:paintRect(x, y, p.width, p.height, Style.WHITE)
    local m = Style.MARGIN
    local w = p.width - 2 * m
    p.hits = {}
    local cy = y
    for _i, sec in ipairs(self.pages_list[self.page] or {}) do
        if sec.support then
            local line = Style.LabelLine(_("Enjoying Bookdrop?"), w, _("Support"), nil, { height = self.label_h })
            line:paintTo(bb, x + m, cy + S(4))
            table.insert(p.hits, { rect = Geom:new{ x = x + m, y = cy, w = w, h = self.label_h + S(8) },
                support = true })
            cy = cy + self.label_h + S(8)
        else
            local line = Style.LabelLine(sec.title, w, sec.callback and _("See all") or nil, nil,
                { height = self.label_h })
            line:paintTo(bb, x + m, cy)
            if sec.callback then
                table.insert(p.hits, { rect = Geom:new{ x = x + m, y = cy, w = w, h = self.label_h },
                    section = sec })
            end
            cy = cy + self.label_h
            local n = self.per_shelf
            local gap = math.floor((w - n * (self.cover_w + Style.SHADOW)) / (n - 1)) + Style.SHADOW
            for i = 1, math.min(n, #sec.books) do
                local book = sec.books[i]
                local bx = x + m + (i - 1) * (self.cover_w + gap)
                local pressed = p.pressed == book
                local ox = pressed and Style.SHADOW or 0
                Style.drawCover(bb, book, bx + ox, cy + ox, self.cover_w, self.cover_h, self.cover_cache)
                local face, bold = Style.face(14, true)
                local tb = TextBoxWidget:new{ text = book.title or _("Untitled"), width = self.cover_w + Style.SHADOW,
                    face = face, bold = bold, alignment = "left",
                    height = self.caption_h - S(8), height_overflow_show_ellipsis = true }
                tb:paintTo(bb, bx, cy + self.cover_h + Style.SHADOW + S(6))
                tb:free()
                table.insert(p.hits, { rect = Geom:new{ x = bx, y = cy, w = self.cover_w + Style.SHADOW,
                    h = self.cover_h + Style.SHADOW + self.caption_h }, book = book })
            end
            cy = cy + self.cover_h + Style.SHADOW + self.caption_h + S(10)
        end
    end
end

function StoreHome:tapBody(p, pos)
    for _i, hit in ipairs(p.hits or {}) do
        if Style.inside(pos, hit.rect) then
            if hit.book then
                p:press(hit.book, function() self:run(self.on_book, hit.book) end)
            elseif hit.section then
                self:run(hit.section.callback)
            elseif hit.support then
                self:showDonation()
            end
            return true
        end
    end
    return true
end

function StoreHome:goPage(n)
    n = math.max(1, math.min(#self.pages_list, n))
    if n == self.page then return end
    self.page = n
    Style.fullRefresh(self)
end

function StoreHome:onNextPage() self:goPage(self.page + 1) return true end
function StoreHome:onPrevPage() self:goPage(self.page - 1) return true end

function StoreHome:showCategories(anchor)
    local rows = {}
    for _i, card in ipairs(self.category_cards) do
        local cb = card.callback
        table.insert(rows, { text = card.title, chevron = true, callback = function() self:run(cb) end })
    end
    table.insert(rows, { text = _("All books"), bold = true, separator = true, chevron = true,
        callback = function() self:run(self.on_all_books or self.on_new_arrivals) end })
    table.insert(rows, { text = _("New arrivals"), chevron = true,
        callback = function() self:run(self.on_new_arrivals) end })
    UIManager:show(Style.DropMenu:new{
        caption = _("Categories"), rows = rows, anchor = anchor or self.tabs.dimen,
        width = math.floor(Screen:getWidth() * 0.66),
    })
end

--- The settings window (entries in Bookdrop's text form, see
--- Style.rowsFromEntries). Called again by entries to move between pages.
function StoreHome:showSettings(entries)
    entries = entries or (self.settings_builder and self.settings_builder(self))
    if not entries or #entries == 0 then return end
    local rows = Style.rowsFromEntries(entries)
    -- one settings window at a time
    if self._settings_menu then UIManager:close(self._settings_menu) end
    local menu = Style.DropMenu:new{
        caption = rows.caption or _("Settings"), rows = rows,
        anchor = self.strip.dimen, align_right = true,
        width = math.floor(Screen:getWidth() * 0.82),
    }
    self._settings_menu = menu
    UIManager:show(menu)
end

function StoreHome:showDonation()
    UIManager:show(DonationDialog:new{})
end

--- Covers arrived: redraw the page if any of its books changed.
function StoreHome:refreshCovers()
    local changed = false
    for _i, sec in ipairs(self.pages_list[self.page] or {}) do
        for _j, book in ipairs(sec.books or {}) do
            if book.cover_path and book._drawn_path ~= book.cover_path then
                book._drawn_path = book.cover_path
                changed = true
            end
        end
    end
    -- (whole screen, without a flash: covers can arrive several times)
    if changed then UIManager:setDirty(self, "ui") end
end

--- A book was viewed: RECENT has something to show now.
function StoreHome:enableRecent()
    if self.has_recent then return end
    self.has_recent = true
    self.tab_cells[3].enabled = true
end

-- e-ink: nothing reaches the panel unless it is asked to refresh, so the
-- whole screen is refreshed when home appears
function StoreHome:onShow()
    Style.fullRefresh(self)
    return true
end

function StoreHome:onClose()
    UIManager:close(self, "ui")
    return true
end

function StoreHome:onCloseWidget()
    self._bookdrop_closed = true
    Style.freeCache(self.cover_cache)
end

return StoreHome
