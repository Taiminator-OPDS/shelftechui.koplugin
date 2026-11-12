--[[
The library (Aleph idea C1): every book on one retro page, for finding and
tidying rather than browsing (Bookshelf's shelves do the browsing; this reads
the same library, so nothing is counted twice).

  ‹ ═══ [LIBRARY · 148] ═══
  [⌕ Title, author or series            ]
  [BOOKS|AUTHORS|SERIES]   [SORT: AUTHOR] [FILTER · 1] [⊞]
  ☐ ▮ A Princess of Mars       E. R. BURROUGHS     FINISHED   A
  ☑ ▮ The Gods of Mars         E. R. BURROUGHS     UNREAD     C
  …                                                           D …   (tap a letter)
  ███ 2 SELECTED   [STATUS] [COLLECTION]   [DONE] ███   (hold a book to select)

Authors and Series list the names (tap: their page). A book opens its book
page; the A–Z rail jumps to a letter of what the list is sorted by.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Page = require("bos_page")
local Recs = require("bos_recs")
local Store = require("bos_settings_store")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local STATE = { finished = _("Finished"), reading = nil, on_hold = _("On hold"), unread = _("Unread") }
local SORTS = {
    { key = "title", text = _("Title") },
    { key = "author", text = _("Author") },
    { key = "recent", text = _("Recent") },
    { key = "progress", text = _("Progress") },
}
local FILTERS = {
    { key = "all", text = _("All") },
    { key = "unread", text = _("Unread") },
    { key = "reading", text = _("Reading") },
    { key = "finished", text = _("Finished") },
    { key = "on_hold", text = _("On hold") },
}

local function sortKey(b, by)
    if by == "author" then
        local a = b.authors[1] or ""
        local surname = a:match("(%S+)%s*$") or a
        return (surname .. " " .. (b.series or "") .. string.format("%05.1f", b.series_num or 0) .. (b.title or "")):lower()
    end
    return tostring(b.title or ""):lower():gsub("^the ", ""):gsub("^a ", "")
end

local function firstLetter(s)
    local c = tostring(s or ""):match("%a")
    return c and c:upper() or "#"
end

local Library = Page:extend{ caption = _("Library") }

function Library:init()
    Page.init(self)
    self.view = self.view or "books"
    self.sort = Store.get("library_sort") or "title"
    self.filter = Store.get("library_filter") or "all"
    self.grid = Store.get("library_grid") == true
    self.query = nil
    self.selected = {}
    self.pg = 1
    self:build()
end

function Library:build()
    local L = Recs.library()
    local books = L and L.books or {}
    self.total = #books
    self.caption = T(_("Library · %1"), self.total)
    local q = self.query and self.query:lower()
    if self.view == "books" then
        local out = {}
        for _i, b in ipairs(books) do
            local ok = self.filter == "all" or b.state == self.filter
            if ok and q then ok = b.hay:find(q, 1, true) ~= nil end
            if ok then table.insert(out, b) end
        end
        local by = self.sort
        if by == "recent" then
            table.sort(out, function(a, b) return (a.opened or 0) > (b.opened or 0) end)
        elseif by == "progress" then
            table.sort(out, function(a, b) return (a.pct or 0) > (b.pct or 0) end)
        else
            for _i, b in ipairs(out) do b._k = sortKey(b, by) end
            table.sort(out, function(a, b) return a._k < b._k end)
        end
        self.rows = out
    else
        local groups, order = {}, {}
        for _i, b in ipairs(books) do
            local names = self.view == "authors" and b.authors or { b.series }
            for _j, n in ipairs(names) do
                if n and n ~= "" and (not q or n:lower():find(q, 1, true)) then
                    local g = groups[n]
                    if not g then g = { name = n, books = 0, read = 0 } groups[n] = g table.insert(order, g) end
                    g.books = g.books + 1
                    if b.state == "finished" then g.read = g.read + 1 end
                end
            end
        end
        table.sort(order, function(a, b)
            local x = self.view == "authors" and (a.name:match("(%S+)%s*$") or a.name) or a.name
            local y = self.view == "authors" and (b.name:match("(%S+)%s*$") or b.name) or b.name
            return x:lower() < y:lower()
        end)
        self.rows = order
    end
end

function Library:letterOf(r)
    if self.view == "books" then
        if self.sort == "author" then
            local a = r.authors[1] or ""
            return firstLetter(a:match("(%S+)%s*$") or a)
        end
        if self.sort == "title" then return firstLetter(tostring(r.title or ""):gsub("^[Tt]he ", ""):gsub("^[Aa] ", "")) end
        return nil
    end
    if self.view == "authors" then return firstLetter(r.name:match("(%S+)%s*$") or r.name) end
    return firstLetter(r.name)
end

function Library:selectedCount()
    local n = 0
    for _k in pairs(self.selected) do n = n + 1 end
    return n
end

function Library.drawBody(self, bb, y, w)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local x = self.pad
    -- search
    local sh = S(36)
    Look.box(bb, x, y, w, sh)
    require("bos_glyphs").search(bb, x + S(10), y + math.floor((sh - S(16)) / 2), S(16))
    local qtext = self.query and ("\u{201C}" .. self.query .. "\u{201D}  ×") or _("Title, author or series")
    Look.label(bb, qtext, x + S(36), y, w - S(46), sh, 11, { keep_case = true, bold = self.query ~= nil,
        color = self.query and BLACK or Look.GRAY })
    self:hit(Geom:new{ x = x, y = y, w = w, h = sh }, function(p) p:askQuery() end)
    y = y + sh + S(10)
    -- [BOOKS|AUTHORS|SERIES]  SORT  FILTER  ⊞
    local seg = { { key = "books", text = _("Books") }, { key = "authors", text = _("Authors") }, { key = "series", text = _("Series") } }
    local ch = S(30)
    local segw = math.min(S(240), math.floor(w * 0.48))
    local by = Look.segments(bb, x, y, segw, ch, seg, self.view)
    for _i, c in ipairs(seg) do
        local r = by[c.key]
        if r then self:hit(r, function(p) p.view = c.key p.pg = 1 p.selected = {} p:build() p:refresh("ui") end) end
    end
    if self.view == "books" then
        local cx = x + w
        local function chip(text, fn, on)
            local cw = Look.textWidth(require("bos_look").case(text), 9) + S(14)
            cx = cx - cw
            Look.box(bb, cx, y, cw, ch, { fill = on and BLACK or WHITE })
            Look.label(bb, text, cx, y, cw, ch, 9, { align = "center", color = on and WHITE or BLACK })
            self:hit(Geom:new{ x = cx, y = y, w = cw, h = ch }, fn)
            cx = cx - S(6)
        end
        chip(self.grid and "\u{2630}" or "\u{25A6}", function(p)
            p.grid = not p.grid Store.set("library_grid", p.grid) p.pg = 1 p:refresh("ui")
        end)
        local fname
        for _i, f in ipairs(FILTERS) do if f.key == self.filter then fname = f.text end end
        chip(self.filter == "all" and _("Filter") or T(_("Filter: %1"), fname), function(p, r) p:chooseFilter() end,
            self.filter ~= "all")
        local sname
        for _i, s in ipairs(SORTS) do if s.key == self.sort then sname = s.text end end
        chip(T(_("Sort: %1"), sname or ""), function(p) p:chooseSort() end)
    end
    y = y + ch + S(12)
    bb:paintRect(x, y - S(4), w, Look.LINE, BLACK)

    -- the A–Z rail
    local rail_w = S(28)
    local letters = {}
    local first_row = {}
    for i, r in ipairs(self.rows) do
        local l = self:letterOf(r)
        if l and not first_row[l] then first_row[l] = i table.insert(letters, l) end
    end
    local bar_h = self:selectedCount() > 0 and S(52) or 0
    local list_w = #letters > 1 and (w - rail_w - S(6)) or w
    local list_h = H - y - S(36) - bar_h
    if #letters > 1 then
        local step = math.max(S(14), math.floor(list_h / #letters))
        local shown = math.min(#letters, math.floor(list_h / math.max(1, S(16))))
        local every = math.ceil(#letters / math.max(1, shown))
        local ly = y
        for i = 1, #letters, every do
            local l = letters[i]
            local h = math.max(S(16), math.floor(list_h * every / #letters))
            Look.label(bb, l, x + w - rail_w, ly, rail_w, math.min(h, S(24)), 10, { align = "center" })
            local target = first_row[l]
            self:hit(Geom:new{ x = x + w - rail_w - S(4), y = ly, w = rail_w + S(8), h = h }, function(p)
                p.pg = math.floor((target - 1) / math.max(1, p.per or 1)) + 1
                p:refresh("ui")
            end)
            ly = ly + h
        end
        local _s = step
    end

    -- the rows (or the grid)
    if self.view == "books" and self.grid then
        local cw = S(76)
        local cols = math.max(2, math.floor((list_w + S(14)) / (cw + S(14))))
        local rh = math.floor(cw * 1.5) + S(30)
        local rows_n = math.max(1, math.floor(list_h / rh))
        self.per = cols * rows_n
        self.pages = math.max(1, math.ceil(#self.rows / self.per))
        self.pg = math.min(self.pg, self.pages)
        local first = (self.pg - 1) * self.per + 1
        for i = first, math.min(#self.rows, first + self.per - 1) do
            local k = i - first
            local cx = x + (k % cols) * math.floor(list_w / cols)
            local cy = y + math.floor(k / cols) * rh
            local b = self.rows[i]
            require("bos_cover").paint(bb, b.filepath, cx, cy, cw, math.floor(cw * 1.5), { shadow = S(3), title = b.title })
            if self.selected[b.filepath] then
                Look.box(bb, cx - S(4), cy - S(4), S(22), S(22), { fill = BLACK })
                Look.label(bb, "\u{2713}", cx - S(4), cy - S(4), S(22), S(22), 11, { align = "center", color = WHITE })
            end
            self:hit(Geom:new{ x = cx, y = cy, w = cw + S(4), h = rh }, function(p) p:tapBook(i) end, function(p) p:toggle(b) end)
        end
    else
        local rh = S(56)
        self.per = math.max(1, math.floor(list_h / rh))
        self.pages = math.max(1, math.ceil(#self.rows / self.per))
        self.pg = math.min(self.pg, self.pages)
        local first = (self.pg - 1) * self.per + 1
        for i = first, math.min(#self.rows, first + self.per - 1) do
            local r = self.rows[i]
            local ry = y + (i - first) * rh
            if self.view == "books" then
                local selecting = self:selectedCount() > 0
                local tx = x
                if selecting then
                    local on = self.selected[r.filepath]
                    Look.box(bb, x, ry + math.floor((rh - S(18)) / 2), S(18), S(18), { fill = on and BLACK or WHITE })
                    if on then Look.label(bb, "\u{2713}", x, ry + math.floor((rh - S(18)) / 2), S(18), S(18), 9, { align = "center", color = WHITE }) end
                    tx = x + S(28)
                end
                require("bos_cover").paint(bb, r.filepath, tx, ry + S(6), S(28), S(42), { shadow = S(2), border = math.max(1, S(1.5)) })
                local st = r.state == "reading" and (math.floor((r.pct or 0) * 100) .. "%") or (STATE[r.state] or "")
                local sw = S(78)
                Look.label(bb, r.title or "", tx + S(40), ry + S(6), list_w - (tx - x) - S(40) - sw, S(24), 13, { keep_case = true })
                Look.label(bb, table.concat(r.authors, ", "), tx + S(40), ry + S(30), list_w - (tx - x) - S(40) - sw, S(18), 9, { color = Look.GRAY })
                Look.label(bb, st, x + list_w - sw, ry, sw, rh, 9, { align = "right" })
                self:hit(Geom:new{ x = x, y = ry, w = list_w, h = rh }, function(p) p:tapBook(i) end, function(p) p:toggle(r) end)
            else
                Look.label(bb, r.name, x, ry + S(6), list_w - S(120), S(26), 14, { keep_case = true })
                Look.label(bb, T(_("%1 books · %2 read"), r.books, r.read), x, ry + S(32), list_w, S(18), 9, { color = Look.GRAY })
                Look.label(bb, "\u{203A}", x + list_w - S(20), ry, S(20), rh, 14)
                local name, view = r.name, self.view
                self:hit(Geom:new{ x = x, y = ry, w = list_w, h = rh }, function()
                    if view == "authors" then require("bos_series").showAuthor(name) else require("bos_series").showSeries(name) end
                end)
            end
            bb:paintRect(x, ry + rh - math.max(1, S(1.5)), list_w, math.max(1, S(1.5)), Look.LIGHT)
        end
    end
    if #self.rows == 0 then
        Page.wrap(bb, self.query and _("Nothing matches.") or _("No books yet."), Page.serif(15, false, true), x, y + S(20), w, 2, S(24))
    end
    -- pager
    local py = H - S(36) - bar_h
    if self.pages and self.pages > 1 then
        Look.label(bb, T("\u{2039}   %1 / %2   \u{203A}", self.pg, self.pages), x, py, w, S(32), 12, { align = "center" })
        self:hit(Geom:new{ x = 0, y = py, w = math.floor(W / 2), h = S(36) }, function(p) p:turn(-1) end)
        self:hit(Geom:new{ x = math.floor(W / 2), y = py, w = math.floor(W / 2), h = S(36) }, function(p) p:turn(1) end)
    end
    -- the selection bar
    if bar_h > 0 then
        local sy = H - bar_h
        bb:paintRect(0, sy, W, bar_h, BLACK)
        Look.label(bb, T(_("%1 selected"), self:selectedCount()), x, sy, w * 0.4, bar_h, 10, { color = WHITE })
        local bx = x + w
        local function wbtn(text, fn, inverse)
            local bw = Look.textWidth(require("bos_look").case(text), 10) + S(18)
            bx = bx - bw
            local by2 = sy + math.floor((bar_h - S(30)) / 2)
            bb:paintRect(bx, by2, bw, S(30), WHITE)
            if not inverse then bb:paintRect(bx + Look.LINE, by2 + Look.LINE, bw - 2 * Look.LINE, S(30) - 2 * Look.LINE, BLACK) end
            Look.label(bb, text, bx, by2, bw, S(30), 10, { align = "center", color = inverse and BLACK or WHITE })
            self:hit(Geom:new{ x = bx, y = sy, w = bw, h = bar_h }, fn)
            bx = bx - S(8)
        end
        wbtn(_("Done"), function(p) p.selected = {} p:refresh("ui") end, true)
        wbtn(_("Collection"), function(p) p:toCollection() end)
        wbtn(_("Status"), function(p) p:setStatus() end)
    end
end

function Library:turn(d)
    local n = self.pg + d
    if n >= 1 and n <= (self.pages or 1) then self.pg = n self:refresh("ui") end
end

function Library:tapBook(i)
    local b = self.rows[i]
    if self:selectedCount() > 0 then return self:toggle(b) end
    local list = {}
    for _j, r in ipairs(self.rows) do list[#list + 1] = r.filepath end
    require("bos_bookdetail").show(b.filepath)
end

function Library:toggle(b)
    if self.selected[b.filepath] then self.selected[b.filepath] = nil else self.selected[b.filepath] = true end
    self:refresh("ui")
end

function Library:askQuery()
    if self.query then
        self.query = nil
        self.pg = 1
        self:build()
        self:refresh("ui")
        return
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Search the library"),
        input_hint = _("Title, author or series"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dlg:getInputText()
                UIManager:close(dlg)
                if q and q:match("%S") then
                    self.query = q
                    self.pg = 1
                    self:build()
                    self:refresh("ui")
                end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Library:chooseSort()
    local items = {}
    for _i, s in ipairs(SORTS) do
        table.insert(items, { text = s.text, callback = function()
            self.sort = s.key
            Store.set("library_sort", s.key)
            self.pg = 1
            self:build()
            self:refresh("ui")
        end })
    end
    require("bos_ui").openList(items, nil)
end

function Library:chooseFilter()
    local items = {}
    for _i, f in ipairs(FILTERS) do
        table.insert(items, { text = f.text, callback = function()
            self.filter = f.key
            Store.set("library_filter", f.key)
            self.pg = 1
            self:build()
            self:refresh("ui")
        end })
    end
    require("bos_ui").openList(items, nil)
end

function Library:setStatus()
    local BookPage = require("bos_bookdetail")
    local items = {}
    for _i, s in ipairs{ { "new", _("Unread") }, { "reading", _("Reading") }, { "complete", _("Finished") }, { "abandoned", _("On hold") } } do
        table.insert(items, { text = s[2], callback = function()
            for fp in pairs(self.selected) do BookPage.setSummary(fp, "status", s[1]) end
            self.selected = {}
            Recs.invalidate()
            self:build()
            self:refresh("ui")
        end })
    end
    require("bos_ui").openList(items, nil)
end

function Library:toCollection()
    local ok, RC = pcall(require, "readcollection")
    if not ok then return end
    local names = {}
    pcall(function() RC:_read() end)
    for name in pairs(RC.coll or {}) do table.insert(names, name) end
    table.sort(names)
    local items = {}
    for _i, name in ipairs(names) do
        table.insert(items, { text = name, callback = function()
            local files = {}
            for fp in pairs(self.selected) do files[fp] = true end
            pcall(function() RC:addItemsMultiple(files, { [name] = true }) end)
            pcall(function() RC:write({ [name] = true }) end)
            self.selected = {}
            self:refresh("ui")
            require("ui/widget/notification"):notify(T(_("Added to %1"), name))
        end })
    end
    if #items == 0 then
        UIManager:show(require("ui/widget/infomessage"):new{ text = _("No collections yet: make one in KOReader's file browser (Collections) or Bookshelf.") })
        return
    end
    require("bos_ui").openList(items, nil)
end

function M.show()
    Library:new{ draw = Library.drawBody, on_swipe = function(self, dir)
        if dir == "west" then self:turn(1)
        elseif dir == "east" then if self.pg > 1 then self:turn(-1) else self:onClose() end end
    end }:show()
end

-- ---------------------------------------------------------------- the start menu entry

local ACTION = "stui_library"

--- Once: Store and Transfer in the start menu too, after the Library (the
--- start menu is the launcher: everything ShelfTechUI has is one tap from it).
function M.seedLauncher()
    if Store.get("launcher_seeded") then return end
    local ok, Model = pcall(require, "lib/bookshelf_start_menu_model")
    if not ok or not Model.load then return end
    Store.set("launcher_seeded", true)
    pcall(function()
        local items = Model.load()
        local has, at = {}, 1
        for i, it in ipairs(items) do
            if type(it.action) == "table" then
                if it.action.stui_store then has.store = true end
                if it.action.stui_transfer then has.transfer = true end
                if it.action[ACTION] or it.action.bookshelfos_settings then at = i + 1 end
            end
        end
        if not has.transfer and require("bos_transfer").available() then
            table.insert(items, at, { id = "sm_stui_transfer", type = "action", label = _("Transfer"),
                icon = "\xEF\x82\x93", action = { stui_transfer = true } })
        end
        if not has.store then
            table.insert(items, at, { id = "sm_stui_store", type = "action", label = _("Store"),
                icon = "\xEF\x81\xBA", action = { stui_store = true } })
        end
        Model.save(items)
    end)
end

function M.seedStartMenu()
    if Store.get("library_seeded") then return end
    local ok, Model = pcall(require, "lib/bookshelf_start_menu_model")
    if not ok or not Model.load then return end
    Store.set("library_seeded", true)
    pcall(function()
        local items = Model.load()
        for _i, it in ipairs(items) do
            if type(it.action) == "table" and it.action[ACTION] then return end
        end
        local at = 1
        for i, it in ipairs(items) do
            if type(it.action) == "table" and it.action.bookshelfos_settings then at = i + 1 end
        end
        table.insert(items, at, { id = "sm_stui_library", type = "action", label = _("Library"),
            icon = "\xEF\x80\xAD", action = { [ACTION] = true } })
        Model.save(items)
    end)
end

return M
