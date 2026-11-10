--[[
ShelfTechUI's own ways around a book (separate from KOReader's lists, which
stay as they are), three pages behind one tab strip:

  Contents    the chapters, in pages: indented by level, page numbers on a
              dotted leader, the chapter you're in inverted.
  Notebook    bookmarks, highlights and notes as boxed cards (the passage in
              italics, your note in a box), with filter chips (All,
              Highlights, Notes, Marks) and the order (the book's / newest).
  Pages       the carousel (the page you're aiming at, big, its neighbours at
              the sides, a track with chapter ticks, ‹ › and hold for a
              chapter) or the grid of thumbnails; it also stands in for
              KOReader's skim bar.

  Nav.showContents(ui)  Nav.showNotebook(ui[, "bookmarks"|"highlights"|"notes"])
  Nav.showPages(ui)     Nav.showScrubber(ui)   Nav.showResults(...)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local UI = require("bos_ui")
local Retro = require("bos_retro")
local Look = require("bos_look")
local S = UI.S
local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GRAY, LIGHT = Blitbuffer.COLOR_DARK_GRAY, Blitbuffer.COLOR_LIGHT_GRAY

local Nav = {}

local LINE = Look.LINE
local THIN = math.max(1, S(1))
local SHADOW = S(4)

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local function mono(size) return require("bos_look").mono(size) end

local function text(bb, str, x, y, w, h, opts)
    opts = opts or {}
    local face, bold = opts.face, opts.bold
    if not face then
        if opts.bold then face, bold = UI.boldFace(opts.size or 16) else face = UI.face(opts.size or 16) end
    end
    local tw = TextWidget:new{ text = str or "", face = face, bold = bold, fgcolor = opts.color or BLACK,
        max_width = math.max(1, w) }
    local s = tw:getSize()
    local tx = x
    if opts.align == "center" then tx = x + math.floor((w - s.w) / 2)
    elseif opts.align == "right" then tx = x + w - s.w end
    tw:paintTo(bb, tx, y + math.floor((h - s.h) / 2))
    tw:free()
    return s.w
end

local function textWidth(str, face, bold)
    local tw = TextWidget:new{ text = str or "", face = face, bold = bold }
    local w = tw:getSize().w
    tw:free()
    return w
end

local function box(bb, x, y, w, h, opts)
    opts = opts or {}
    local b = opts.border or LINE
    Look.box(bb, x, y, w, h, { border = b, shadow = opts.shadow, color = opts.color, fill = opts.fill })
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function dots(bb, x0, x1, y)
    local d = math.max(1, S(1.5))
    for dx = x0, x1 - d, S(5) do bb:paintRect(dx, y, d, d, GRAY) end
end

--- A square retro button; pressed: black, pushed onto its shadow.
local function button(bb, x, y, w, h, label, opts)
    opts = opts or {}
    local enabled = opts.enabled ~= false
    local down = opts.down
    local sh = S(3)
    local ox = down and sh or 0
    box(bb, x + ox, y + ox, w, h, { shadow = (enabled and not down) and sh or 0,
        fill = down and BLACK or WHITE, color = enabled and BLACK or LIGHT })
    text(bb, label, x + ox + S(4), y + ox, w - S(8), h, { face = opts.face or mono(opts.size or 14), bold = true,
        align = "center", color = down and WHITE or (enabled and BLACK or LIGHT) })
    return Geom:new{ x = x, y = y, w = w + sh, h = h + sh }
end

-- ---------------------------------------------------------------------------
-- The book
-- ---------------------------------------------------------------------------

local function currentPage(ui)
    local ok, p = pcall(function() return ui:getCurrentPage() end)
    if ok and p then return p end
    return ui.view and ui.view.state and ui.view.state.page or 1
end

local function pageCount(ui)
    local ok, n = pcall(function() return ui.document:getPageCount() end)
    return ok and n or 1
end

local function pageString(ui, pn_or_xp)
    if type(pn_or_xp) == "number" then
        -- the book's own page labels (reference pages), when it has them and they're on
        local ok, label = pcall(function()
            if ui.pagemap and ui.pagemap:wantsPageLabels() then
                return ui.pagemap:getXPointerPageLabel(ui.document:getPageXPointer(pn_or_xp))
            end
        end)
        if ok and label then return tostring(label) end
        return tostring(pn_or_xp)
    end
    local ok, s = pcall(function() return ui.bookmark:getBookmarkPageString(pn_or_xp) end)
    if ok and s then return s end
    return tostring(pn_or_xp)
end

local function goPage(ui, page)
    pcall(function() ui.link:addCurrentLocationToStack() end)
    ui:handleEvent(Event:new("GotoPage", page))
end

local function tocItems(ui)
    local toc = ui.toc
    if not toc then return {} end
    pcall(function() toc:fillToc() end)
    return toc.toc or {}
end

-- ---------------------------------------------------------------------------
-- A drawn, tappable area
-- ---------------------------------------------------------------------------

local Area = InputContainer:extend{ width = 0, height = 0, draw = nil, tap = nil, hold = nil, swipe = nil, pan = nil }

function Area:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local r = function() return self.dimen end
    self.ges_events = {}
    if self.tap then self.ges_events.AreaTap = { GestureRange:new{ ges = "tap", range = r } } end
    if self.hold then self.ges_events.AreaHold = { GestureRange:new{ ges = "hold", range = r } } end
    if self.swipe then self.ges_events.AreaSwipe = { GestureRange:new{ ges = "swipe", range = r } } end
    if self.pan then
        for _i, g in ipairs{ "touch", "pan", "hold_pan", "pan_release", "hold_release" } do
            self.ges_events["Area_" .. g] = { GestureRange:new{ ges = g, range = r } }
            self["onArea_" .. g] = function(a, _, ges) return a.pan(a, g, ges) end
        end
    end
end

function Area:getSize() return Geom:new{ w = self.width, h = self.height } end

function Area:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h = x, y, self.width, self.height
    bb:paintRect(x, y, self.width, self.height, WHITE)
    if self.draw then
        local ok, err = pcall(self.draw, self, bb, x, y)
        if not ok then logger.warn("ShelfTechUI: nav draw:", err) end
    end
end

function Area:onAreaTap(_, ges) return self.tap and self:tap(ges.pos) and true or false end
function Area:onAreaHold(_, ges) return self.hold and self:hold(ges.pos) and true or false end
function Area:onAreaSwipe(_, ges) return self.swipe and self:swipe(ges) and true or false end

function Area:repaint(mode)
    if not self.dimen.x then return end
    UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
    UIManager:setDirty(nil, mode or "ui", self.dimen)
end

function Area:press(key, fn)
    self.pressed = key
    self:repaint("fast")
    UIManager:forceRePaint()
    self.pressed = nil
    if fn then fn() end
end

-- ---------------------------------------------------------------------------
-- The full-screen window: Contents, Notebook and Pages (and search results)
-- ---------------------------------------------------------------------------

local Window = InputContainer:extend{
    name = "bookshelfos_nav",
    covers_fullscreen = true,
    ui = nil,
    mode = "contents",      -- "contents" | "notebook" | "pages" | "results"
    filter = "all",         -- notebook: "all" | "highlight" | "note" | "bookmark"
    view = nil,             -- pages: "carousel" | "grid"
}

local MODES = {
    { key = "contents", text = _("Contents"), caption = _("Contents") },
    { key = "notebook", text = _("Notebook"), caption = _("Notebook") },
    { key = "pages", text = _("Pages"), caption = _("Pages") },
}
-- the old names still open the right page
local MODE_ALIAS = { bookmarks = { "notebook", "bookmark" }, highlights = { "notebook", "highlight" },
    notes = { "notebook", "note" }, map = { "pages" }, scrubber = { "pages", nil, "carousel" } }
local CAPTION = {}
for _i, md in ipairs(MODES) do CAPTION[md.key] = md.caption end
CAPTION.results = _("Search results")

function Window:init()
    local alias = MODE_ALIAS[self.mode]
    if alias then
        self.mode = alias[1]
        if alias[2] then self.filter = alias[2] end
        if alias[3] then self.view = alias[3] end
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.m = S(18)
    self.w = sw - 2 * self.m
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextPage = { { Device.input.group.PgFwd } },
            PrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.strip_h = S(38)
    self.book_h = S(52)
    self.tabs_h = S(40)
    self.filters_h = S(32)
    self.pager_h = S(54)
    self:rebuild()
end

function Window:headH()
    if self.mode == "results" then
        return self.strip_h + S(6) + self.book_h + self.filters_h + S(8) + S(6) + S(6)
    end
    local h = self.strip_h + S(6) + self.book_h + self.tabs_h + S(10)
    if self.mode == "notebook" or self.mode == "pages" then h = h + self.filters_h + S(8) end
    return h + S(6)
end

function Window:rebuild()
    self.body_h = Screen:getHeight() - self:headH() - self.pager_h
    if self.mode == "contents" then self:buildContents()
    elseif self.mode == "pages" then self:buildPages()
    elseif self.mode == "results" then self:buildResults()
    else self:buildNotes() end
    self[1] = Area:new{
        width = Screen:getWidth(), height = Screen:getHeight(),
        draw = function(a, bb, x, y) self:draw(a, bb, x, y) end,
        tap = function(a, pos) return self:onTapAt(a, pos) end,
        hold = function(a, pos) return self:onHoldAt(a, pos) end,
        swipe = function(_a, ges)
            local fwd = ges.direction == "west" or ges.direction == "north"
            local back = ges.direction == "east" or ges.direction == "south"
            if self.mode == "pages" and self.view == "carousel" then
                if fwd then self:selectPage(self.sel + 1) elseif back then self:selectPage(self.sel - 1) end
            elseif fwd then self:goPage(self.page + 1)
            elseif back then self:goPage(self.page - 1) end
            return true
        end,
        pan = function(_a, g, ges) return self:panTrack(g, ges) end,
    }
    if self.mode == "pages" then self:requestThumbs() end
end

-- ----- contents ---------------------------------------------------------------

function Window:buildContents()
    local ui = self.ui
    self.items = tocItems(ui)
    self.row_h = S(50)
    self.per_page = math.max(1, math.floor(self.body_h / self.row_h))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
    local cur = currentPage(ui)
    local idx
    pcall(function() idx = ui.toc:getTocIndexByPage(cur) end)
    self.current_index = idx
    self.page = idx and math.ceil(idx / self.per_page) or 1
end

function Window:drawContents(a, bb, x, y)
    local m, w = self.m, self.w
    a.hits = {}
    if #self.items == 0 then
        text(bb, _("This book has no table of contents."), x + m, y + S(30), w, S(40),
            { face = UI.italicFace(18), color = GRAY, align = "center" })
        return
    end
    local cur = currentPage(self.ui)
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.items, first + self.per_page - 1) do
        local item = self.items[i]
        local ry = y + (i - first) * self.row_h
        local depth = math.max(1, item.depth or 1)
        local is_current = i == self.current_index
        local pressed = a.pressed == i
        local inv = is_current or pressed
        if inv then bb:paintRect(x + m - S(8), ry + S(3), w + S(16), self.row_h - S(6), BLACK) end
        local ink = inv and WHITE or BLACK
        local indent = (depth - 1) * S(22)
        local lx = x + m + indent
        if is_current then
            text(bb, "\u{25B8}", lx, ry, S(16), self.row_h, { face = mono(15), bold = true, color = WHITE })
        end
        lx = lx + S(18)
        local ps = pageString(self.ui, item.xpointer or item.page)
        local pf = mono(14)
        local pw = textWidth(ps, pf, true)
        local tw_max = x + m + w - pw - S(30) - lx
        local face, bold
        if depth == 1 then face, bold = UI.boldFace(18) else face = UI.face(17) end
        local read = not is_current and item.page and item.page < cur
        local tw = text(bb, item.title or "", lx, ry, tw_max, self.row_h, { face = face, bold = bold,
            color = inv and WHITE or (read and GRAY or BLACK) })
        if not inv then dots(bb, lx + tw + S(10), x + m + w - pw - S(10), ry + math.floor(self.row_h / 2) + S(6)) end
        text(bb, ps, x + m + w - pw, ry, pw, self.row_h, { face = pf, bold = true, color = ink, align = "right" })
        if not inv and i < first + self.per_page - 1 and i < #self.items then
            bb:paintRect(x + m, ry + self.row_h - THIN, w, THIN, LIGHT)
        end
        table.insert(a.hits, { rect = Geom:new{ x = x, y = ry, w = Screen:getWidth(), h = self.row_h },
            index = i, item = item })
    end
end

-- ----- the notebook: bookmarks, highlights and notes ---------------------------------

local FILTERS = {
    { key = "all", text = _("All") },
    { key = "highlight", text = _("Highlights") },
    { key = "note", text = _("Notes") },
    { key = "bookmark", text = _("Marks") },
}

local function annotationType(item)
    if item.drawer then return item.note and item.note ~= "" and "note" or "highlight" end
    return "bookmark"
end

local function serif(size, italic)
    return require("bos_look").serif(size, false, italic)
end

function Window:buildNotes()
    local ui = self.ui
    local all = (ui.annotation and ui.annotation.annotations) or {}
    self.counts = { all = 0, highlight = 0, note = 0, bookmark = 0 }
    self.items = {}
    for index, item in ipairs(all) do
        local t = annotationType(item)
        self.counts.all = self.counts.all + 1
        self.counts[t] = self.counts[t] + 1
        if self.filter == "all" or self.filter == t then
            table.insert(self.items, { index = index, item = item, type = t })
        end
    end
    local newest = require("bos_settings_store").get("notebook_order") == "newest"
    if newest then
        table.sort(self.items, function(a, b)
            local da, db = tostring(a.item.datetime or ""), tostring(b.item.datetime or "")
            if da ~= db then return da > db end
            return a.index > b.index
        end)
    end
    -- cards (each as tall as its text) laid out into pages
    local w = self.w - SHADOW
    local inner = w - 2 * S(12) - 2 * LINE
    self.pages_list = {}
    local page, used = {}, 0
    local cur_page = currentPage(ui)
    local start_page
    for _i, e in ipairs(self.items) do
        local h = 2 * LINE + 2 * S(10) + S(20) -- frame, padding, the meta line
        if e.type == "bookmark" then
            h = h + S(24)
        else
            local quote = e.item.text
            if quote and quote ~= "" then
                local tb = TextBoxWidget:new{ text = tostring(quote):gsub("%s+", " "), face = serif(15, true),
                    width = inner }
                e.quote_h = math.min(tb:getSize().h, S(110))
                tb:free()
                h = h + S(6) + e.quote_h
            end
        end
        if e.item.note and e.item.note ~= "" then
            local tb = TextBoxWidget:new{ text = e.item.note, face = UI.face(14), width = inner - S(70) }
            e.note_h = math.min(tb:getSize().h, S(64))
            tb:free()
            h = h + S(10) + e.note_h + S(12)
        end
        e.h = h + SHADOW + S(12)
        if used + e.h > self.body_h and #page > 0 then
            table.insert(self.pages_list, page)
            page, used = {}, 0
        end
        table.insert(page, e)
        used = used + e.h
        local ok, pn = pcall(function() return ui.bookmark:getBookmarkPageNumber(e.item) end)
        e.pn = ok and pn or nil
        if not newest and not start_page and e.pn and e.pn >= cur_page then start_page = #self.pages_list + 1 end
    end
    if #page > 0 then table.insert(self.pages_list, page) end
    self.pages = math.max(1, #self.pages_list)
    self.page = math.min(self.pages, self.page or start_page or 1)
end

local TYPE_LABEL = { highlight = _("Highlight"), note = _("Highlight + note"), bookmark = _("Bookmark") }

function Window:chapterOf(e)
    local chapter = e.item.chapter
    if not chapter or chapter == "" then
        pcall(function() chapter = self.ui.toc:getTocTitleByPage(e.pn) end)
    end
    return chapter or ""
end

function Window:drawCard(a, bb, x, cy, e)
    local m, w = self.m, self.w - SHADOW
    local item = e.item
    local ch = e.h - SHADOW - S(12)
    local pressed = a.pressed == e
    box(bb, x + m, cy, w, ch, { shadow = SHADOW, fill = pressed and LIGHT or WHITE })
    local px = x + m + LINE + S(12)
    local pw = w - 2 * LINE - 2 * S(12)
    local py = cy + LINE + S(10)
    -- the meta line: a marker, what it is and where; the page on the right
    local here = e.pn and e.pn == currentPage(self.ui)
    local ps = require("bos_look").case((_("p.") .. " " .. pageString(self.ui, item.page)))
    if here then ps = require("bos_look").case(_("You're here")) .. " · " .. ps end
    local pf = mono(11)
    local rw = textWidth(ps, pf, true)
    text(bb, ps, px + pw - rw, py, rw, S(20), { face = pf, bold = true })
    local mx = px
    if e.type == "bookmark" then
        require("bos_glyphs").bookmark(bb, mx, py + S(2), S(16), BLACK, true)
    elseif e.type == "note" then
        bb:paintRect(mx, py + S(12), S(12), math.max(2, S(3)), BLACK)
    else
        bb:paintRect(mx + S(1), py + S(4), S(11), S(11), BLACK)
    end
    local meta = TYPE_LABEL[e.type] or ""
    local chapter = self:chapterOf(e)
    if chapter ~= "" then meta = meta .. " · " .. chapter end
    text(bb, require("bos_look").case(meta), mx + S(20), py, pw - rw - S(32), S(20), { face = mono(11), bold = true })
    py = py + S(20)
    if e.type == "bookmark" then
        local when = item.datetime and tostring(item.datetime):sub(1, 10)
        local line = T(_("Page %1"), pageString(self.ui, item.page))
        if when and when ~= "" then line = T(_("%1, added %2"), line, when) end
        text(bb, line, px, py + S(2), pw, S(22), { face = serif(15) })
        py = py + S(24)
    elseif e.quote_h then
        local tb = TextBoxWidget:new{ text = tostring(item.text):gsub("%s+", " "), face = serif(15, true),
            width = pw, height = e.quote_h, height_overflow_show_ellipsis = true }
        tb:paintTo(bb, px, py + S(6))
        tb:free()
        py = py + S(6) + e.quote_h
    end
    if e.note_h then
        local ny = py + S(10)
        local nh = e.note_h + S(12)
        box(bb, px, ny, pw, nh, { border = LINE })
        text(bb, require("bos_look").case(_("Note")), px + S(8), ny + S(4), S(56), S(20), { face = mono(10), bold = true })
        local tb = TextBoxWidget:new{ text = item.note, face = UI.face(14), width = pw - S(70), height = e.note_h,
            height_overflow_show_ellipsis = true }
        tb:paintTo(bb, px + S(62), ny + S(6))
        tb:free()
    end
end

function Window:drawNotes(a, bb, x, y)
    local m, w = self.m, self.w
    a.hits = {}
    local list = self.pages_list[self.page] or {}
    if #list == 0 then
        local msg
        if self.filter == "bookmark" then
            msg = _("No bookmarks yet.\nTap the bookmark key on the toolbar to mark a page.")
        elseif self.filter == "all" or self.filter == "highlight" then
            msg = _("Nothing here yet.\nHold a word on the page, then drag, to highlight a passage.")
        else
            msg = _("None of these yet.")
        end
        local tb = TextBoxWidget:new{ text = msg, face = UI.italicFace(17), width = w, alignment = "center",
            fgcolor = GRAY }
        tb:paintTo(bb, x + m, y + S(30))
        tb:free()
        return
    end
    local cy = y + S(4)
    for _i, e in ipairs(list) do
        self:drawCard(a, bb, x, cy, e)
        table.insert(a.hits, { rect = Geom:new{ x = x, y = cy, w = Screen:getWidth(), h = e.h }, entry = e })
        cy = cy + e.h
    end
end

-- ----- pages: the carousel and the grid ------------------------------------------
--
-- One view for moving through the book (Aleph idea D1, in place of the page
-- map and the skim sheet): the carousel shows the page you're aiming at, big,
-- with its neighbours at the sides, over a track with chapter ticks; the grid
-- shows a screenful of small pages. Swipe to browse, tap the page to read
-- from it, drag the track, ‹ › step a page (hold: a chapter).

local function pagesView()
    return require("bos_settings_store").get("pages_view") == "grid" and "grid" or "carousel"
end

function Window:buildPages()
    local ui = self.ui
    local n = pageCount(ui)
    local cur = currentPage(ui)
    self.map_n, self.map_cur = n, cur
    self.view = self.view or pagesView()
    self.sel = self.sel or cur
    -- which pages carry a bookmark or a highlight
    self.map_marks = {}
    for _i, item in ipairs((ui.annotation and ui.annotation.annotations) or {}) do
        local ok, pn = pcall(function() return ui.bookmark:getBookmarkPageNumber(item) end)
        if ok and type(pn) == "number" then
            local mk = self.map_marks[pn] or {}
            if item.drawer then mk.hl = true else mk.mark = true end
            self.map_marks[pn] = mk
        end
    end
    self.thumbs = self.thumbs or {}
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    if self.view == "carousel" then
        -- the big page, its neighbours at 2/3, the controls under it
        -- (no pager under the carousel: its room goes to the page)
        self.ctl_h = S(132)
        local stage_h = self.body_h + self.pager_h - self.ctl_h - S(8)
        local th = stage_h - S(28)
        local tw = math.floor(th * sw / sh)
        if tw > math.floor(sw * 0.6) then
            tw = math.floor(sw * 0.6)
            th = math.floor(tw * sh / sw)
        end
        self.car = { stage_h = stage_h, tw = tw, th = th,
            sw_ = math.floor(tw * 0.66), sh_ = math.floor(th * 0.66) }
        self.pages, self.page = 1, 1
        return
    end
    -- the grid: three rows of thumbnails, the page's own shape, as many columns as fit
    local landscape = sw > sh
    local rows = landscape and 2 or 3
    local gap_y = S(12)
    local label_h = S(26)
    local cell_h = math.floor((self.body_h - S(6) - (rows - 1) * gap_y) / rows)
    local th = cell_h - label_h - S(8)
    local tw = math.floor(th * sw / sh)
    local gap_x = S(16)
    local cols = math.max(2, math.floor((self.w + gap_x) / (tw + S(4) + gap_x)))
    local col_w = math.floor((self.w - (cols - 1) * gap_x) / cols)
    if tw > col_w - S(4) then
        tw = col_w - S(4)
        th = math.floor(tw * sh / sw)
    end
    self.grid = { rows = rows, cols = cols, col_w = col_w, cell_h = cell_h, gap_x = gap_x, gap_y = gap_y,
        tw = tw, th = th, label_h = label_h }
    self.per_page = rows * cols
    self.pages = math.max(1, math.ceil(n / self.per_page))
    self.page = self.page or math.ceil(self.sel / self.per_page)
    self.page = math.max(1, math.min(self.pages, self.page))
end

function Window:screenRange()
    local first = (self.page - 1) * self.per_page + 1
    return first, math.min(self.map_n, first + self.per_page - 1)
end

--- Draws page `p` of a reflowable book right here (not in KOReader's
--- background thumbnailer) and scales it to w x h. The reading position is
--- put back after. nil for a PDF or on failure.
function Window:renderPage(p, w, h)
    local ui = self.ui
    if not ui.rolling then return nil end
    local doc = ui.document
    local out
    local ok, err = pcall(function()
        local W, H = Screen:getWidth(), Screen:getHeight()
        local xp = doc:getXPointer()
        local full = Blitbuffer.new(W, H, Screen.bb:getType())
        full:fill(WHITE)
        doc:drawCurrentViewByPage(full, 0, 0, Geom:new{ x = 0, y = 0, w = W, h = H }, p)
        doc:gotoXPointer(xp)
        local scale = math.min(w / W, h / H)
        out = require("ui/renderimage"):scaleBlitBuffer(full, math.floor(W * scale), math.floor(H * scale), true)
    end)
    if not ok then logger.warn("ShelfTechUI: page render failed:", err) return nil end
    return out
end

--- Pages: KOReader's thumbnailer makes them in the background and each is
--- drawn in as it arrives. In a reflowable book the page in the middle of
--- the carousel is drawn at once, and any the thumbnailer hasn't delivered
--- after a moment are drawn here, one at a time, so a page never stays blank.
function Window:requestThumbs()
    local th = self.ui.thumbnail
    if th and self.batch_id then pcall(function() th:cancelPageThumbnailRequests(self.batch_id) end) end
    Window.batch_seq = (Window.batch_seq or 0) + 1
    local batch = "bookshelfos_pages_" .. Window.batch_seq
    self.batch_id = batch
    self.wanted = {}
    -- keep memory in check: pages drawn here, far from where you are, go
    local near = function(key)
        local p = tonumber(key:match("^(%d+)@"))
        if not p then return false end
        if self.view == "carousel" then return math.abs(p - self.sel) <= 3 end
        local first = (self.page - 1) * (self.per_page or 1) + 1
        return p >= first - (self.per_page or 0) and p < first + 2 * (self.per_page or 0)
    end
    for key, t in pairs(self.thumbs) do
        if type(t) == "table" and t.owned and not near(key) then
            pcall(function() t.bb:free() end)
            self.thumbs[key] = nil
        elseif t == false then
            self.thumbs[key] = nil
        end
    end
    local function want(p, w, h, prefetch, now)
        if p < 1 or p > self.map_n then return end
        local key = p .. "@" .. w
        if self.thumbs[key] then return end -- (a failed one is asked for again)
        if now then
            local bb = self:renderPage(p, w, h)
            if bb then self.thumbs[key] = { bb = bb, owned = true } return end
        end
        if not prefetch then table.insert(self.wanted, { p = p, w = w, h = h, key = key }) end
        if th then
            pcall(function()
                th:getPageThumbnail(p, w, h, batch, function(tile, batch_id, async)
                    if batch_id ~= self.batch_id or self.closed then return end
                    if tile and tile.bb and not self.thumbs[key] then
                        self.thumbs[key] = tile
                        if async and not prefetch then self:thumbArrived() end
                    end
                end)
            end)
        end
    end
    if self.view == "carousel" then
        local c = self.car
        want(self.sel, c.tw, c.th, false, true)
        want(self.sel - 1, c.sw_, c.sh_)
        want(self.sel + 1, c.sw_, c.sh_)
        want(self.sel + 1, c.tw, c.th, true)
    else
        local g = self.grid
        local first, last = self:screenRange()
        for p = first, last do want(p, g.tw, g.th) end
        for p = last + 1, math.min(self.map_n, last + self.per_page) do want(p, g.tw, g.th, true) end
    end
    self:scheduleFill(batch)
end

--- What the thumbnailer hasn't delivered in a moment is drawn here.
function Window:scheduleFill(batch)
    if not self.ui.rolling then return end
    local function step()
        if self.closed or self.batch_id ~= batch or self.mode ~= "pages" then return end
        for _i, wnt in ipairs(self.wanted or {}) do
            if not self.thumbs[wnt.key] then
                local bb = self:renderPage(wnt.p, wnt.w, wnt.h)
                self.thumbs[wnt.key] = bb and { bb = bb, owned = true } or false
                self:thumbArrived()
                UIManager:scheduleIn(0.05, step)
                return
            end
        end
    end
    UIManager:scheduleIn(self.ui.thumbnail and 1.5 or 0.05, step)
end

function Window:thumbArrived()
    if self._thumb_pending then return end
    self._thumb_pending = true
    UIManager:scheduleIn(0.25, function()
        self._thumb_pending = false
        if self.closed or self.mode ~= "pages" then return end
        pcall(function() self[1]:repaint("ui") end)
    end)
end

--- A page in a frame of its own shape: the thumbnail, or faint lines of text.
function Window:pageFrame(bb, p, fx, fy, tw, th, b, opts)
    opts = opts or {}
    local fw, fh = tw + 2 * b, th + 2 * b
    if (opts.shadow or 0) > 0 then Look.shadow(bb, fx, fy, fw, fh, opts.shadow) end
    bb:paintRect(fx, fy, fw, fh, Look.INK)
    local ix, iy, iw, ih = fx + b, fy + b, tw, th
    bb:paintRect(ix, iy, iw, ih, WHITE)
    local tile = self.thumbs and self.thumbs[p .. "@" .. tw]
    if tile and tile.bb then
        local tbw, tbh = tile.bb:getWidth(), tile.bb:getHeight()
        local dx = ix + math.floor((iw - tbw) / 2)
        local dy = iy + math.floor((ih - tbh) / 2)
        bb:blitFrom(tile.bb, math.max(ix, dx), math.max(iy, dy), 0, 0, math.min(iw, tbw), math.min(ih, tbh))
    else
        local lh = math.max(S(6), math.floor(ih / 16))
        local k = 0
        for ly = iy + lh, iy + ih - lh, lh do
            k = k + 1
            bb:paintRect(ix + S(8), ly, iw - S(16) - ((k % 4 == 0) and math.floor(iw * 0.35) or 0), math.max(1, S(1.5)),
                opts.dim and LIGHT or GRAY)
        end
    end
    if opts.pressed then bb:lightenRect(ix, iy, iw, ih, 0.5) end
    return fw, fh
end

function Window:pagesHeading(bb, x, y, w, h)
    -- [CAROUSEL|GRID] ......... range ........ [⌕]
    local cells = { { key = "carousel", text = _("Carousel") }, { key = "grid", text = _("Grid") } }
    local segw = math.min(S(220), math.floor(w * 0.42))
    self.view_rects = self:drawTabs(bb, x, y, segw, h, cells, self.view, self[1] and self[1].pressed_view, 11)
    local kw = h + S(8)
    local kx = x + w - kw - S(3)
    local down = self[1] and self[1].pressed_search
    local o = down and S(3) or 0
    box(bb, kx + o, y + o, kw, h, { shadow = down and 0 or S(3), fill = down and BLACK or WHITE })
    require("bos_glyphs").search(bb, kx + o + math.floor((kw - S(18)) / 2), y + o + math.floor((h - S(18)) / 2), S(18),
        down and WHITE or BLACK)
    self.search_rect = Geom:new{ x = kx, y = y, w = kw + S(3), h = h + S(3) }
    local range
    if self.view == "grid" then
        local first, last = self:screenRange()
        range = T(_("Pages %1–%2 of %3"), first, last, self.map_n)
    else
        range = T(_("%1 pages"), self.map_n)
    end
    text(bb, require("bos_look").case(range), x + segw + S(12), y, kx - x - segw - S(24), h, { face = mono(11), bold = true,
        color = GRAY, align = "right" })
end

-- the carousel ---------------------------------------------------------------

function Window:drawCarousel(a, bb, x, y)
    local sw = Screen:getWidth()
    local c = self.car
    local m, w = self.m, self.w
    a.hits = {}
    -- the stage: faint ruled lines, the neighbours half off it, the page in the middle
    local stage_y, stage_h = y, c.stage_h
    for yy = stage_y + S(4), stage_y + stage_h - S(4), S(8) do
        bb:paintRect(x, yy, sw, math.max(1, S(1)), LIGHT)
    end
    local b = LINE
    local cx = x + math.floor((sw - c.tw) / 2) - b
    local cy = stage_y + math.floor((stage_h - c.th) / 2) - b
    local side_y = stage_y + math.floor((stage_h - c.sh_) / 2) - b
    local gap = S(18)
    if self.sel > 1 then
        self:pageFrame(bb, self.sel - 1, cx - gap - c.sw_ - 2 * b, side_y, c.sw_, c.sh_, b, { dim = true })
        table.insert(a.hits, { rect = Geom:new{ x = 0, y = stage_y, w = math.max(1, cx - gap), h = stage_h }, step = -1 })
    end
    if self.sel < self.map_n then
        local rx = cx + c.tw + 2 * b + gap
        self:pageFrame(bb, self.sel + 1, rx, side_y, c.sw_, c.sh_, b, { dim = true })
        table.insert(a.hits, { rect = Geom:new{ x = rx, y = stage_y, w = sw - rx, h = stage_h }, step = 1 })
    end
    local here = self.sel == self.map_cur
    self:pageFrame(bb, self.sel, cx, cy, c.tw, c.th, here and math.max(3, S(4)) or b,
        { shadow = SHADOW, pressed = a.pressed == "sel" })
    table.insert(a.hits, { rect = Geom:new{ x = cx, y = cy, w = c.tw + 2 * b, h = c.th + 2 * b }, sel = true })
    -- markers above the page (never on it)
    local mk = self.map_marks[self.sel] or {}
    local tags = {}
    if here then table.insert(tags, _("You're here")) end
    if mk.mark then table.insert(tags, _("Bookmark")) end
    if mk.hl then table.insert(tags, _("Highlights")) end
    if #tags > 0 then
        local tg = require("bos_look").case(table.concat(tags, " · "))
        local tf = mono(10)
        local tw_ = textWidth(tg, tf, true) + S(14)
        local tx = x + math.floor((sw - tw_) / 2)
        box(bb, tx, cy - S(4) - S(20) < stage_y and stage_y + S(2) or cy - S(24), tw_, S(20), { fill = BLACK })
        text(bb, tg, tx, cy - S(4) - S(20) < stage_y and stage_y + S(2) or cy - S(24), tw_, S(20),
            { face = tf, bold = true, color = WHITE, align = "center" })
    end
    bb:paintRect(x, stage_y + stage_h - LINE, sw, LINE, BLACK)

    -- the controls: chapter · page of n · %, then ‹ [track] ›, then a hint
    local ky = stage_y + stage_h + S(10)
    local chapter
    pcall(function() chapter = self.ui.toc:getTocTitleByPage(self.sel) end)
    if not chapter or chapter == "" then chapter = (self.ui.doc_props or {}).display_title or "" end
    local pct = math.floor((self.sel - 1) / math.max(1, self.map_n - 1) * 100 + 0.5)
    local right = require("bos_look").case(T(_("Page %1 of %2 · %3%"), pageString(self.ui, self.sel), self.map_n, pct))
    local rf = mono(11)
    local rw = textWidth(right, rf, true)
    text(bb, right, x + m + w - rw, ky, rw, S(26), { face = rf, bold = true })
    text(bb, chapter, x + m, ky, w - rw - S(16), S(26), { face = require("bos_look").serif(15, true) })
    ky = ky + S(36)
    local kw, kh = S(44), S(38)
    self.step_rects = {}
    self.step_rects.prev = button(bb, x + m, ky, kw, kh, "\u{2039}", { enabled = self.sel > 1,
        down = a.pressed == "prev", size = 20 })
    self.step_rects.next = button(bb, x + m + w - kw - S(3), ky, kw, kh, "\u{203A}", { enabled = self.sel < self.map_n,
        down = a.pressed == "next", size = 20 })
    local tx0, tx1 = x + m + kw + S(18), x + m + w - kw - S(3) - S(14)
    local th = S(12)
    local ty = ky + math.floor((kh - th) / 2)
    local ix, iw = tx0 + LINE, tx1 - tx0 - 2 * LINE
    local frac = (self.sel - 1) / math.max(1, self.map_n - 1)
    local Reading = require("bos_reading")
    local ticks = {}
    for _i, t in ipairs(Reading.tickXs(self.ui, ix, iw, S(14))) do table.insert(ticks, t.x) end
    local ox
    if self.map_cur ~= self.sel then
        ox = ix + math.floor(iw * (self.map_cur - 1) / math.max(1, self.map_n - 1) + 0.5)
    end
    require("bos_look").slimTrack(bb, tx0, ty, tx1 - tx0, th, frac, ticks, self.dragging and true or false, ox)
    self.track = { x0 = ix, x1 = ix + iw, y = ky - S(6), h = kh + S(12) }
    ky = ky + kh + S(14)
    local hint_l = require("bos_look").case(_("Tap the page to read · swipe to browse"))
    local hint_r = require("bos_look").case(_("Hold ‹ › = chapter"))
    local hf = mono(9)
    local hw = textWidth(hint_r, hf, true)
    text(bb, hint_l, x + m, ky, w - hw - S(12), S(18), { face = hf, bold = true, color = GRAY })
    text(bb, hint_r, x + m + w - hw, ky, hw, S(18), { face = hf, bold = true, color = GRAY })
end

function Window:selectPage(p, mode)
    p = math.max(1, math.min(self.map_n, p))
    if p == self.sel then return end
    self.sel = p
    self:requestThumbs()
    self[1]:repaint(mode or "ui")
end

function Window:carouselChapter(dir)
    local ui, p = self.ui, self.sel
    local n
    pcall(function()
        if dir > 0 then n = ui.toc:getNextChapter(p)
        else n = ui.toc:isChapterStart(p) and ui.toc:getPreviousChapter(p) or ui.toc:getPreviousChapter(p + 1) end
    end)
    self:selectPage(n or (dir > 0 and self.map_n or 1))
end

function Window:trackPage(px)
    local t = self.track
    local frac = math.max(0, math.min(1, (px - t.x0) / math.max(1, t.x1 - t.x0)))
    return math.max(1, math.min(self.map_n, math.floor(frac * (self.map_n - 1) + 1.5)))
end

--- Dragging the carousel's track: the handle follows, the page catches up.
function Window:panTrack(g, ges)
    local t = self.track
    if self.mode ~= "pages" or self.view ~= "carousel" or not t then return false end
    local pos = ges.pos
    local on = pos.y >= t.y and pos.y < t.y + t.h and pos.x >= t.x0 - S(24) and pos.x <= t.x1 + S(24)
    if g == "touch" then
        if not on then return false end
        self.dragging = true
        self.sel = self:trackPage(pos.x)
        self[1]:repaint("fast")
        return true
    end
    if not self.dragging then return false end
    if g == "pan" or g == "hold_pan" then
        local p = self:trackPage(pos.x)
        if p ~= self.sel then
            self.sel = p
            self[1]:repaint("fast")
        end
        return true
    end
    self.dragging = false
    self.sel = self:trackPage(pos.x)
    self:requestThumbs()
    self[1]:repaint("ui")
    return true
end

-- the grid ---------------------------------------------------------------------

function Window:drawPages(a, bb, x, y)
    if self.view == "carousel" then return self:drawCarousel(a, bb, x, y) end
    local m = self.m
    local g = self.grid
    a.hits = {}
    local first, last = self:screenRange()
    local cur = self.map_cur
    local cy0 = y + S(4)
    for p = first, last do
        local i = p - first
        local col, row = i % g.cols, math.floor(i / g.cols)
        local cx = x + m + col * (g.col_w + g.gap_x)
        local cy = cy0 + row * (g.cell_h + g.gap_y)
        local here = p == cur
        local b = here and math.max(3, S(4)) or LINE
        local fx = cx + math.floor((g.col_w - g.tw) / 2) - b
        local _fw, fh = self:pageFrame(bb, p, fx, cy, g.tw, g.th, b, { shadow = S(4), pressed = a.pressed == p })
        -- the markers sit in the label under the page, never on the page itself:
        --   black chip: you're here · grey chip: read · ribbon: bookmarked · dot: highlighted
        local mk = self.map_marks[p] or {}
        local read = p < cur
        local label = pageString(self.ui, p)
        local lf = mono(12)
        local lh = g.label_h - S(4)
        local ly = cy + fh + S(8)
        local mark_w = mk.mark and S(16) or 0
        local hl_w = mk.hl and S(12) or 0
        local lw = textWidth(label, lf, true) + S(16) + mark_w + hl_w
        local lx = cx + math.floor((g.col_w - lw) / 2)
        local b2 = math.max(1, S(1.5))
        bb:paintRect(lx, ly, lw, lh, BLACK)
        if not here then bb:paintRect(lx + b2, ly + b2, lw - 2 * b2, lh - 2 * b2, read and LIGHT or WHITE) end
        local ink = here and WHITE or BLACK
        local tx = lx + S(8)
        if mk.mark then
            require("bos_glyphs").bookmark(bb, tx - S(2), ly + math.floor((lh - S(14)) / 2), S(14), ink, true)
            tx = tx + mark_w
        end
        local tw_ = textWidth(label, lf, true)
        text(bb, label, tx, ly, tw_, lh, { face = lf, bold = true, color = ink })
        tx = tx + tw_ + S(6)
        if mk.hl then
            local d = S(6)
            bb:paintRect(tx, ly + math.floor((lh - d) / 2), d, d, ink)
        end
        table.insert(a.hits, { rect = Geom:new{ x = cx, y = cy, w = g.col_w, h = g.cell_h }, map_page = p })
    end
end


-- ----- search results ------------------------------------------------------------

function Window:buildResults()
    local ui = self.ui
    local w = self.w
    local face = UI.face(16)
    self.items = {}
    self.pages_list = {}
    local page, used = {}, 0
    local start_page
    for idx, item in ipairs(self.results or {}) do
        local e = { idx = idx, item = item }
        local ok, pn = pcall(function()
            return ui.rolling and ui.document:getPageFromXPointer(item.start) or item.start
        end)
        e.pn = ok and pn or nil
        local tb = TextBoxWidget:new{ text = item.text or "", face = face, width = w - S(14) }
        e.text_h = math.min(tb:getSize().h, S(88))
        tb:free()
        e.h = S(28) + e.text_h + S(16)
        table.insert(self.items, e)
        if used + e.h > self.body_h and #page > 0 then
            table.insert(self.pages_list, page)
            page, used = {}, 0
        end
        table.insert(page, e)
        used = used + e.h
        if not start_page and self.start_index and idx >= self.start_index then start_page = #self.pages_list + 1 end
    end
    if #page > 0 then table.insert(self.pages_list, page) end
    self.pages = math.max(1, #self.pages_list)
    self.page = math.min(self.pages, self.page or start_page or 1)
end

function Window:drawResults(a, bb, x, y)
    local m, w = self.m, self.w
    a.hits = {}
    local list = self.pages_list[self.page] or {}
    if #list == 0 then
        text(bb, _("No results."), x + m, y + S(30), w, S(40), { face = UI.italicFace(18), color = GRAY,
            align = "center" })
        return
    end
    local cur = currentPage(self.ui)
    local cy = y
    for i, e in ipairs(list) do
        if a.pressed == e.idx then bb:paintRect(x, cy, Screen:getWidth(), e.h, LIGHT) end
        local chapter
        pcall(function() chapter = self.ui.toc:getTocTitleByPage(e.pn) end)
        local head = T("%1  \u{00B7}  %2", e.idx, _("p.") .. " " .. tostring(e.item.mandatory or e.pn or ""))
        if chapter and chapter ~= "" then head = head .. "  \u{00B7}  " .. chapter end
        if e.pn == cur then head = head .. "  \u{00B7}  " .. _("This page") end
        local hx = x + m
        -- the result's number in a small black box
        text(bb, require("bos_look").case(head), hx, cy + S(4), w, S(22), { face = mono(12), bold = true,
            color = (e.pn and e.pn > cur) and BLACK or GRAY })
        local tb = TextBoxWidget:new{ text = e.item.text or "", face = UI.face(16), width = w - S(14),
            height = e.text_h, height_overflow_show_ellipsis = true }
        tb:paintTo(bb, hx + S(12), cy + S(28))
        tb:free()
        bb:paintRect(hx, cy + S(30), LINE, e.text_h - S(4), BLACK)
        if i < #list then bb:paintRect(x + m, cy + e.h - THIN, w, THIN, LIGHT) end
        table.insert(a.hits, { rect = Geom:new{ x = x, y = cy, w = Screen:getWidth(), h = e.h }, result = e })
        cy = cy + e.h
    end
end

--- The query, how many, and NEW SEARCH.
function Window:drawQuery(a, bb, x, y, w, h)
    local label = require("bos_look").case(_("New search"))
    local bw = textWidth(label, mono(12), true) + S(26)
    self.newsearch_rect = button(bb, x + w - bw - S(3), y, bw, h - S(2), label,
        { down = a.pressed_query, size = 12 })
    local count = require("bos_look").case(T(_("%1 results"), #(self.results or {})))
    local cf = mono(12)
    local cw = textWidth(count, cf, true)
    local q = "\u{201C}" .. tostring(self.query or "") .. "\u{201D}"
    local face, bold = UI.boldFace(18)
    local qw = text(bb, q, x, y, w - bw - cw - S(40), h, { face = face, bold = bold })
    text(bb, count, x + qw + S(14), y, cw, h, { face = cf, bold = true, color = GRAY })
end

-- ----- the window ----------------------------------------------------------

function Window:draw(a, bb, x, y)
    local sw = Screen:getWidth()
    local m, w = self.m, self.w
    -- title strip
    local strip = Retro.TitleStrip:new{ width = sw, height = self.strip_h,
        -- the tabs below already say which page this is: only search results get a caption
        caption = self.mode == "results" and (CAPTION[self.mode] or "") or "", size = 14,
        close_callback = function() self:onClose() end }
    strip:paintTo(bb, x, y)
    self.close_rect = strip.close_rect
    local cy = y + self.strip_h + S(6)
    -- the book, and how far in
    local props = self.ui.doc_props or {}
    local pct = math.floor(currentPage(self.ui) / math.max(1, pageCount(self.ui)) * 100 + 0.5)
    local pct_text = pct .. "%"
    local pf = mono(14)
    local pw = textWidth(pct_text, pf, true) + S(18)
    box(bb, x + m + w - pw, cy + S(12), pw, S(28), { border = math.max(1, S(1.5)) })
    text(bb, pct_text, x + m + w - pw, cy + S(12), pw, S(28), { face = pf, bold = true, align = "center" })
    local title_face, title_bold = UI.boldFace(20)
    text(bb, props.display_title or "", x + m, cy, w - pw - S(14), S(30), { face = title_face, bold = title_bold })
    local authors = tostring(props.authors or ""):gsub("\n", ", ")
    text(bb, authors, x + m, cy + S(28), w - pw - S(14), S(22), { face = UI.italicFace(15), color = GRAY })
    cy = cy + self.book_h
    if self.mode == "results" then
        self.tab_rects, self.filter_rects = nil, nil
        self:drawQuery(a, bb, x + m, cy, w, self.filters_h + S(4))
        cy = cy + self.filters_h + S(8) + S(6)
        bb:paintRect(x + m, cy - S(6), w, LINE, BLACK)
        self.body_y = cy
        self:drawResults(a, bb, x, cy)
        self:drawPager(a, bb, x)
        return
    end
    -- tabs
    local n_notes = #((self.ui.annotation and self.ui.annotation.annotations) or {})
    self.tab_cells = {}
    for _i, md in ipairs(MODES) do
        local label = md.text
        if md.key == "notebook" and n_notes > 0 then label = label .. " (" .. n_notes .. ")" end
        table.insert(self.tab_cells, { key = md.key, text = label })
    end
    local tab_size = sw < S(560) and 11 or 12
    self.tab_rects = self:drawTabs(bb, x + m, cy, w, self.tabs_h, self.tab_cells, self.mode, a.pressed_tab, tab_size)
    cy = cy + self.tabs_h + S(10)
    self.filter_rects = nil
    self.order_rect, self.view_rects, self.search_rect = nil, nil, nil
    if self.mode == "notebook" then
        local cells = {}
        for _i, f in ipairs(FILTERS) do
            local n = self.counts and self.counts[f.key] or 0
            table.insert(cells, { key = f.key, text = f.text .. " \u{00B7} " .. n })
        end
        self.filter_cells = cells
        -- the order: the book's, or newest first
        local newest = require("bos_settings_store").get("notebook_order") == "newest"
        local ol = require("bos_look").case((newest and _("Newest") or _("In order")))
        local ow = textWidth(ol, mono(11), true) + S(22)
        self.filter_rects = self:drawTabs(bb, x + m, cy, w - ow - S(14), self.filters_h, cells, self.filter,
            a.pressed_filter, sw < S(560) and 10 or 11)
        self.order_rect = button(bb, x + m + w - ow - S(3), cy, ow, self.filters_h - S(3), ol,
            { down = a.pressed_order, size = 11 })
        cy = cy + self.filters_h + S(8)
    elseif self.mode == "pages" then
        self:pagesHeading(bb, x + m, cy, w, self.filters_h)
        cy = cy + self.filters_h + S(8)
    end
    bb:paintRect(x + m, cy, w, LINE, BLACK)
    cy = cy + S(6)
    self.body_y = cy
    if self.mode == "contents" then self:drawContents(a, bb, x, cy)
    elseif self.mode == "pages" then self:drawPages(a, bb, x, cy)
    else self:drawNotes(a, bb, x, cy) end
    self:drawPager(a, bb, x)
end

function Window:drawPager(a, bb, x)
    local sw = Screen:getWidth()
    local m, w = self.m, self.w
    local py = Screen:getHeight() - self.pager_h
    bb:paintRect(x, py, sw, self.pager_h, WHITE)
    self.pager_rects = {}
    local bw, bh = S(46), S(34)
    local by = py + math.floor((self.pager_h - bh) / 2) - S(2)
    local function pb(key, bx, label, en)
        self.pager_rects[key] = button(bb, bx, by, bw, bh, label, { enabled = en, down = a.pressed_pager == key,
            size = 15 })
    end
    -- one page: no page controls at all
    if self.pages <= 1 then return end
    pb("first", x + m, "\u{00AB}", self.page > 1)
    pb("prev", x + m + bw + S(14), "\u{2039}", self.page > 1)
    local rx = x + m + w - bw - S(3)
    pb("next", rx - bw - S(14), "\u{203A}", self.page < self.pages)
    pb("last", rx, "\u{00BB}", self.page < self.pages)
    text(bb, string.format("%d / %d", self.page, self.pages), x + m, py, w, self.pager_h,
        { face = mono(15), bold = true, align = "center" })
end

--- Segmented tabs; returns { key = rect }.
function Window:drawTabs(bb, x, y, w, h, cells, selected, pressed, size)
    local b = math.max(1, S(1.5))
    bb:paintRect(x, y, w, h, BLACK)
    bb:paintRect(x + b, y + b, w - 2 * b, h - 2 * b, WHITE)
    local n = #cells
    local cw = math.floor((w - 2 * b - (n - 1) * b) / n)
    local cx = x + b
    local rects = {}
    for i, c in ipairs(cells) do
        local this_w = (i == n) and (x + w - b - cx) or cw
        local sel = c.key == selected or pressed == c.key
        if sel then bb:paintRect(cx, y + b, this_w, h - 2 * b, BLACK) end
        text(bb, require("bos_look").case(tostring(c.text)), cx + S(3), y, this_w - S(6), h,
            { face = mono(size or 13), bold = true, align = "center", color = sel and WHITE or BLACK })
        rects[c.key] = Geom:new{ x = cx, y = y, w = this_w, h = h }
        cx = cx + this_w
        if i < n then
            bb:paintRect(cx, y + b, b, h - 2 * b, BLACK)
            cx = cx + b
        end
    end
    return rects
end

function Window:refreshAll(mode)
    UIManager:setDirty(self, mode or "ui")
end

function Window:goPage(n)
    n = math.max(1, math.min(self.pages, n))
    if n == self.page then return end
    self.page = n
    if self.mode == "pages" then self:requestThumbs() end
    -- a new screenful of pages: a full refresh, so no ghosting
    self:refreshAll(self.mode == "pages" and "full" or "ui")
end

function Window:onNextPage()
    if self.mode == "pages" and self.view == "carousel" then self:selectPage(self.sel + 1) return true end
    self:goPage(self.page + 1) return true
end
function Window:onPrevPage()
    if self.mode == "pages" and self.view == "carousel" then self:selectPage(self.sel - 1) return true end
    self:goPage(self.page - 1) return true
end

function Window:setMode(mode)
    if mode == self.mode then return end
    self.mode = mode
    self.page = nil
    self.filter = "all"
    self.filter_rects = nil
    self:rebuild()
    self:refreshAll("full")
end

function Window:setView(view)
    if view == self.view then return end
    require("bos_settings_store").set("pages_view", view)
    self.view = view
    self.page = nil
    self:rebuild()
    self:refreshAll("full")
end

function Window:setFilter(key)
    if key == self.filter then return end
    self.filter = key
    self.page = 1
    self:buildNotes()
    self.page = 1
    self:refreshAll("ui")
end

function Window:onTapAt(a, pos)
    if self.close_rect and inside(pos, self.close_rect) then self:onClose() return true end
    if self.mode == "results" and self.newsearch_rect and inside(pos, self.newsearch_rect) then
        a.pressed_query = true
        a:repaint("fast")
        UIManager:forceRePaint()
        a.pressed_query = nil
        local searcher = self.searcher
        self:onClose()
        if searcher then UIManager:nextTick(function() searcher:onShowFulltextSearchInput() end) end
        return true
    end
    for key, r in pairs(self.tab_rects or {}) do
        if inside(pos, r) then self:setMode(key) return true end
    end
    for key, r in pairs(self.filter_rects or {}) do
        if inside(pos, r) then self:setFilter(key) return true end
    end
    if self.order_rect and inside(pos, self.order_rect) then
        local Store = require("bos_settings_store")
        Store.set("notebook_order", Store.get("notebook_order") == "newest" and "book" or "newest")
        self.page = nil
        self:buildNotes()
        self:refreshAll("ui")
        return true
    end
    for key, r in pairs(self.view_rects or {}) do
        if inside(pos, r) then self:setView(key) return true end
    end
    if self.search_rect and inside(pos, self.search_rect) then
        a.pressed_search = true
        a:repaint("fast")
        UIManager:forceRePaint()
        a.pressed_search = nil
        local ui = self.ui
        self:onClose()
        UIManager:nextTick(function() ui:handleEvent(Event:new("ShowFulltextSearchInput")) end)
        return true
    end
    if self.mode == "pages" and self.view == "carousel" then
        local t = self.track
        if t and pos.y >= t.y and pos.y < t.y + t.h and pos.x >= t.x0 and pos.x <= t.x1 then
            self:selectPage(self:trackPage(pos.x))
            return true
        end
        for key, r in pairs(self.step_rects or {}) do
            if inside(pos, r) then
                a:press(key, function() self:selectPage(self.sel + (key == "next" and 1 or -1)) end)
                return true
            end
        end
        for _i, hit in ipairs(a.hits or {}) do
            if inside(pos, hit.rect) then
                if hit.step then self:selectPage(self.sel + hit.step)
                elseif hit.sel then a:press("sel", function() self:open({ map_page = self.sel }) end) end
                return true
            end
        end
        return true
    end
    for key, r in pairs(self.pager_rects or {}) do
        if inside(pos, r) then
            local target = ({ first = 1, prev = self.page - 1, next = self.page + 1, last = self.pages })[key]
            a.pressed_pager = key
            a:repaint("fast")
            UIManager:forceRePaint()
            a.pressed_pager = nil
            self:goPage(target)
            a:repaint("ui")
            return true
        end
    end
    for _i, hit in ipairs(a.hits or {}) do
        if inside(pos, hit.rect) then
            local key = hit.map_page or hit.index or hit.entry or (hit.result and hit.result.idx)
            a:press(key, function() self:open(hit) end)
            return true
        end
    end
    return true
end

function Window:open(hit)
    local ui = self.ui
    if hit.result then
        local searcher = self.searcher
        if searcher then searcher.findall_results_item_index = hit.result.idx end
        self._result_opened = true
        self:onClose()
        if searcher then searcher:gotoResultsItem(hit.result.idx) end
        return
    end
    self:onClose()
    if hit.map_page then
        goPage(ui, hit.map_page)
    elseif hit.item and self.mode == "contents" then
        pcall(function() ui.link:addCurrentLocationToStack() end)
        if hit.item.xpointer then
            ui:handleEvent(Event:new("GotoXPointer", hit.item.xpointer, hit.item.xpointer))
        else
            ui:handleEvent(Event:new("GotoPage", hit.item.page))
        end
    elseif hit.entry then
        pcall(function() ui.link:addCurrentLocationToStack() end)
        ui.bookmark:gotoBookmark(hit.entry.item.page, hit.entry.item.pos0)
    end
end

function Window:onHoldAt(a, pos)
    if self.mode == "pages" and self.view == "carousel" then
        local r = self.step_rects or {}
        if inside(pos, r.prev) then self:carouselChapter(-1) return true end
        if inside(pos, r.next) then self:carouselChapter(1) return true end
        return true
    end
    if self.mode ~= "notebook" then return true end
    for _i, hit in ipairs(a.hits or {}) do
        if inside(pos, hit.rect) and hit.entry then
            self:cardActions(hit.entry, hit.rect)
            return true
        end
    end
    return true
end

--- Hold a card: Go to · Note · Remove.
function Window:cardActions(e, rect)
    local ui = self.ui
    local items = {
        { text = _("Go to"), callback = function() self:open({ entry = e }) end },
    }
    table.insert(items, { text = (e.item.note and e.item.note ~= "") and _("Edit note") or _("Add note"),
        callback = function()
            ui.bookmark:setBookmarkNote(e.index, nil, nil, function()
                self:buildNotes()
                self:refreshAll("ui")
            end)
        end })
    table.insert(items, { text = _("Remove"), separator_before = true, callback = function()
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = e.type == "bookmark" and _("Remove this bookmark?") or _("Remove this highlight?"),
            ok_text = _("Remove"),
            ok_callback = function()
                pcall(function() ui.bookmark:removeItem(e.item, e.index) end)
                self:buildNotes()
                self:refreshAll("ui")
            end,
        })
    end })
    local anchor = Geom:new{ x = rect.x + self.m, y = rect.y + S(8), w = S(260), h = S(24) }
    UI.openList(items, anchor)
end

function Window:onShow()
    self:refreshAll("full")
    return true
end

function Window:onCloseWidget()
    self.closed = true
    if self.mode == "results" and self.searcher and not self._result_opened then
        local first = (self.pages_list[self.page] or {})[1]
        self.searcher.findall_results_item_index = first and first.idx or nil
    end
    if self.batch_id and self.ui.thumbnail then
        pcall(function() self.ui.thumbnail:cancelPageThumbnailRequests(self.batch_id) end)
    end
    -- the pages drawn here are ours to free (the thumbnailer's are its cache's)
    for _k, t in pairs(self.thumbs or {}) do
        if type(t) == "table" and t.owned and t.bb then pcall(function() t.bb:free() end) end
    end
    self.thumbs = nil
    UIManager:setDirty(nil, "full")
end

function Window:onClose()
    UIManager:close(self)
    return true
end

Nav.Window = Window

function Nav.show(ui, mode, opts)
    opts = opts or {}
    UIManager:show(Window:new{ ui = ui, mode = mode or "contents", filter = opts.filter, view = opts.view })
end
function Nav.showContents(ui) Nav.show(ui, "contents") end
--- The notebook, on one filter ("bookmarks", "highlights", "notes") or all.
function Nav.showNotebook(ui, which)
    if which and MODE_ALIAS[which] then Nav.show(ui, which) else Nav.show(ui, "notebook") end
end
function Nav.showBookmarks(ui) Nav.show(ui, "bookmarks") end
function Nav.showHighlights(ui) Nav.show(ui, "highlights") end
Nav.showNotes = Nav.showHighlights
function Nav.showPages(ui) Nav.show(ui, "pages") end
Nav.showMap = Nav.showPages
--- KOReader's skim bar and "Skim document": PAGES, on the carousel.
function Nav.showScrubber(ui) Nav.show(ui, "pages", { view = "carousel" }) end

--- KOReader's in-book search results, as a retro page (`searcher`: ReaderSearch).
function Nav.showResults(ui, searcher, results, start_index)
    UIManager:show(Window:new{ ui = ui, mode = "results", searcher = searcher, results = results,
        query = searcher and searcher.last_search_text, start_index = start_index })
end

--- KOReader's skim bar (the "Skim document" action, the status bar, its
--- gestures) opens PAGES instead, while ShelfTechUI's screens are on.
function Nav.installSkim()
    if Nav._skim_installed then return end
    local ok, ReaderGoto = pcall(require, "apps/reader/modules/readergoto")
    if not ok or not ReaderGoto then return end
    Nav._skim_installed = true
    local orig = ReaderGoto.onShowSkimtoDialog
    ReaderGoto.onShowSkimtoDialog = function(self, ...)
        local on = require("bos_settings_store").get("custom_nav") ~= false
        if on and self.ui and self.ui.document and Device:isTouchDevice() then
            Nav.showScrubber(self.ui)
            return true
        end
        return orig(self, ...)
    end
end

return Nav
