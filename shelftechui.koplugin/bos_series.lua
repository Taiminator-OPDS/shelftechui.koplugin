--[[
Series and author pages (Aleph idea C2, C6), on the retro page:

  ‹ ═══ [SERIES] ═══
  ▮▮▮  Barsoom
       Edgar Rice Burroughs
       [■■■][▤▤▤][┄┄┄]        completion ruler: read · on the device · missing
       1 OF 3 READ · 2 ON DEVICE
  ┌──────────────────────────────────────┐
  │ ▮ UP NEXT · BOOK 2                   │
  │   The Gods of Mars       [START]     │
  │   ~5H 20M AT YOUR PACE               │
  └──────────────────────────────────────┘
  01 ▮ A Princess of Mars    FINISHED · ★ 5
  02 ▮ The Gods of Mars      UNREAD · UP NEXT
  03 ┊ The Warlord of Mars   NOT ON DEVICE   [FIND]

Books missing from the series are known only with online picks on (Open
Library); without them the ruler counts what's on the device. The author
page is the same, with the author's portrait (online, when on) and their
books by series.
--]]

local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local T = require("ffi/util").template
local _ = require("gettext")

local Look = require("bos_look")
local Page = require("bos_page")
local Recs = require("bos_recs")
local Screen = Device.screen
local BLACK, WHITE = Look.BLACK, Look.WHITE
local S = Look.S

local M = {}

local STATE = { finished = _("Finished"), reading = _("Reading"), on_hold = _("On hold"), unread = _("Unread") }

local function dashedBox(bb, x, y, w, h)
    local d = math.max(2, S(2))
    for k = 0, w - 1, S(8) do
        bb:paintRect(x + k, y, math.min(S(4), w - k), d, BLACK)
        bb:paintRect(x + k, y + h - d, math.min(S(4), w - k), d, BLACK)
    end
    for k = 0, h - 1, S(8) do
        bb:paintRect(x, y + k, d, math.min(S(4), h - k), BLACK)
        bb:paintRect(x + w - d, y + k, d, math.min(S(4), h - k), BLACK)
    end
end

--- The ruler: one cell per book — read (black), on the device (pinstripes),
--- missing (dashed).
local function ruler(bb, x, y, w, h, cells)
    local n = #cells
    if n == 0 then return end
    local gap = S(4)
    local cw = math.max(S(6), math.floor((w - (n - 1) * gap) / n))
    if cw * n + (n - 1) * gap > w then gap = 0 cw = math.floor(w / n) end
    for i, c in ipairs(cells) do
        local cx = x + (i - 1) * (cw + gap)
        if c == "missing" then
            dashedBox(bb, cx, y, cw, h)
        else
            Look.box(bb, cx, y, cw, h, { fill = c == "read" and BLACK or WHITE })
            if c ~= "read" then Look.fill(bb, cx + Look.LINE, y + Look.LINE + 1, cw - 2 * Look.LINE, h - 2 * Look.LINE - 2) end
        end
    end
end

local pace_cache
--- Seconds a page, over everything you've read (asked once a session).
local function secsPerPage()
    if pace_cache ~= nil then return pace_cache or nil end
    pace_cache = false
    pcall(function()
        local DataStorage = require("datastorage")
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local row = conn:exec("SELECT sum(min(duration, 120)), count(*) FROM page_stat_data;")
        conn:close()
        local secs, n = tonumber(row and row[1] and row[1][1]), tonumber(row and row[2] and row[2][1])
        if secs and n and n > 50 then pace_cache = secs / n end
    end)
    return pace_cache or nil
end

local function timeAtPace(b)
    local pages
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    if okR and Repo.pageCountFor then pcall(function() pages = Repo.pageCountFor(b.filepath) end) end
    local pace = secsPerPage()
    if pages and pace then return pages * pace end
end

--- The page for a set of books: `kind` "series" or "author".
local function show(kind, name, books, author, missing)
    local caption = kind == "series" and _("Series") or _("Author")
    local function draw(self, bb, y, w)
        local W, H = Screen:getWidth(), Screen:getHeight()
        local x = self.pad
        -- the stack (or the portrait), the name, the ruler
        local cw, ch = S(70), S(105)
        local portrait
        if kind == "author" then
            local okO, Online = pcall(require, "bos_online")
            portrait = okO and Online.enabled() and Online.portraitPath(name)
        end
        if portrait then
            local okI, img = pcall(function()
                return require("ui/renderimage"):renderImageFile(portrait, false, S(96), S(120))
            end)
            if okI and img then
                Look.box(bb, x, y, img:getWidth() + 2 * Look.LINE, img:getHeight() + 2 * Look.LINE, { shadow = S(4) })
                bb:blitFrom(img, x + Look.LINE, y + Look.LINE, 0, 0, img:getWidth(), img:getHeight())
                img:free()
            end
        else
            local Cover = require("bos_cover")
            for i = math.min(3, #books), 1, -1 do
                local b = books[i]
                Cover.paint(bb, b.filepath, x + (i - 1) * S(14), y + (3 - i) * S(8), cw, ch, { shadow = S(3), title = b.title })
            end
        end
        local tx = x + S(112)
        local tw = W - self.pad - tx
        local ty = y
        ty = ty + Page.wrap(bb, name, Page.serif(21, true), tx, ty, tw, 2, S(28)) + S(2)
        if author and kind == "series" then
            Look.label(bb, author, tx, ty, tw, S(20), 12, { keep_case = true, bold = false })
            self:hit(Geom:new{ x = tx, y = ty, w = tw, h = S(22) }, function() M.showAuthor(author) end)
            ty = ty + S(24)
        end
        local cells, read, have = {}, 0, 0
        for _i, b in ipairs(books) do
            have = have + 1
            if b.state == "finished" then read = read + 1 table.insert(cells, "read") else table.insert(cells, "have") end
        end
        for _i = 1, #(missing or {}) do table.insert(cells, "missing") end
        ruler(bb, tx, ty + S(4), tw, S(14), cells)
        ty = ty + S(26)
        local summary = T(_("%1 of %2 read · %3 on device"), read, #cells, have)
        Look.label(bb, summary, tx, ty, tw, S(20), 10)
        y = math.max(y + S(128), ty + S(30))

        -- up next
        local nxt
        for _i, b in ipairs(books) do if b.state == "unread" or b.state == "reading" then nxt = b break end end
        if nxt then
            local bh = S(96)
            Look.box(bb, x, y, w - Look.SHADOW, bh, { shadow = Look.SHADOW })
            require("bos_cover").paint(bb, nxt.filepath, x + S(10), y + S(10), S(50), S(75), { shadow = S(2) })
            local nx = x + S(76)
            local label = nxt.state == "reading" and _("Continue") or _("Up next")
            if nxt.series_num and kind == "series" then label = label .. " · " .. T(_("Book %1"), nxt.series_num) end
            Look.label(bb, label, nx, y + S(10), w - S(200), S(18), 9, { color = Look.GRAY })
            Page.wrap(bb, nxt.title or "", Page.serif(15, true), nx, y + S(30), w - S(210), 2, S(22))
            local t = timeAtPace(nxt)
            if t then Look.label(bb, T(_("~%1 at your pace"), require("bos_reading").hm(t)), nx, y + bh - S(28), w - S(200), S(18), 9) end
            local bl = nxt.state == "reading" and _("Resume") or _("Start")
            local bw = Look.textWidth(require("bos_look").case(bl), 12) + S(26)
            local r = Look.button(bb, x + w - Look.SHADOW - bw - S(14), y + math.floor((bh - S(38)) / 2), bw, S(38), bl,
                { on = true, size = 12 })
            self:hit(r, function(p) p:onClose() require("bos_shelf").open(nxt.filepath) end)
            self:hit(Geom:new{ x = x, y = y, w = w - bw - S(30), h = bh }, function() require("bos_bookdetail").show(nxt.filepath) end)
            y = y + bh + Look.SHADOW + S(14)
        end

        -- the list
        bb:paintRect(x, y, w, Look.LINE, BLACK)
        local rh = S(62)
        local rows = {}
        for _i, b in ipairs(books) do table.insert(rows, { book = b, n = b.series_num }) end
        for _i, m in ipairs(missing or {}) do table.insert(rows, { missing = m, n = m.series_num }) end
        if kind == "series" then
            table.sort(rows, function(a, b) return (a.n or 999) < (b.n or 999) end)
        end
        local per = math.max(1, math.floor((H - y - S(50)) / rh))
        self.pages = math.max(1, math.ceil(#rows / per))
        self.pg = math.min(self.pg or 1, self.pages)
        local first = (self.pg - 1) * per + 1
        for i = first, math.min(#rows, first + per - 1) do
            local r = rows[i]
            local ry = y + (i - first) * rh
            local num = kind == "series" and string.format("%02d", r.n or i) or string.format("%02d", i)
            Look.label(bb, num, x, ry, S(30), rh, 12)
            local title, sub
            if r.book then
                local b = r.book
                require("bos_cover").paint(bb, b.filepath, x + S(36), ry + S(8), S(30), S(45), { shadow = S(2), border = math.max(1, S(1.5)) })
                title = b.title or ""
                sub = STATE[b.state] or ""
                if b.rating then sub = sub .. " · \u{2605} " .. b.rating end
                if b == nxt then sub = sub .. " · " .. _("Up next") end
                if kind == "author" and b.series then sub = sub .. " · " .. b.series .. (b.series_num and (" #" .. b.series_num) or "") end
                self:hit(Geom:new{ x = 0, y = ry, w = W, h = rh }, function() require("bos_bookdetail").show(b.filepath) end)
            else
                local m = r.missing
                dashedBox(bb, x + S(36), ry + S(8), S(30), S(45))
                title = m.title or ""
                sub = _("Not on device")
                local fl = _("Find")
                local fw = Look.textWidth(require("bos_look").case(fl), 10) + S(16)
                local fr = Look.button(bb, x + w - fw - S(4), ry + math.floor((rh - S(28)) / 2), fw, S(28), fl, { size = 10 })
                self:hit(fr, function() require("bos_online").find(m) end)
                self:hit(Geom:new{ x = 0, y = ry, w = x + w - fw - S(10), h = rh }, function() require("bos_online").showSheet(m) end)
            end
            Look.label(bb, title, x + S(80), ry + S(8), w - S(150), S(24), 13, { keep_case = true })
            Look.label(bb, sub, x + S(80), ry + S(32), w - S(150), S(20), 9, { color = Look.GRAY })
            bb:paintRect(x, ry + rh - Look.LINE, w, Look.LINE, BLACK)
        end
        if self.pages > 1 then
            Look.label(bb, T("%1 / %2", self.pg, self.pages), x, H - S(40), w, S(30), 12, { align = "center" })
        end
    end
    local p = Page:new{ caption = caption, draw = draw, on_swipe = function(self, dir)
        if dir == "west" and (self.pg or 1) < (self.pages or 1) then self.pg = (self.pg or 1) + 1 self:refresh("ui")
        elseif dir == "east" then
            if (self.pg or 1) > 1 then self.pg = self.pg - 1 self:refresh("ui") else self:onClose() end
        end
    end }
    return p:show()
end

function M.showSeries(name)
    local books = Recs.series(name)
    local author = books[1] and books[1].authors[1]
    local missing
    local okO, Online = pcall(require, "bos_online")
    if okO and Online.enabled() then missing = Online.missingInSeries(name, author, books) end
    return show("series", name, books, author, missing)
end

function M.showAuthor(name)
    local books = Recs.byAuthor(name)
    local missing
    local okO, Online = pcall(require, "bos_online")
    if okO and Online.enabled() then missing = Online.missingByAuthor(name, books) end
    return show("author", name, books, nil, missing)
end

return M
