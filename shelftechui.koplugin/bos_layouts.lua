--[[
Home layouts: what home shows, chosen in Settings → Home → Home layout (or the
"Layout" chip on the home bar).

  shelf   Bookshelf's home, as it has always been (with the search field
          beside the chips at its top: bos_statusbar)
  dash    a now-reading card, four cards (streak, this week, up next in
          series, a pick), and one row of covers chosen by chips

Dash is drawn in place of Bookshelf's shelf, inside its own window
(BookshelfWidget.paintTo / handleEvent), so everything that comes and goes
with home (parking a book under it, closing it, the window stack, the screen
kept under dialogs) behaves exactly as with the shelf. Books open through
Bookshelf (bos_shelf.open), so going back to home is the instant way.

Everything is drawn with bos_look, so the theme applies; covers come from
bos_cover (cached at display size).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local Store = require("bos_settings_store")
local UI = require("bos_ui")

local Screen = Device.screen
local S = Look.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

M.ORDER = { "shelf", "dash" }
M.NAMES = { shelf = _("Shelf"), dash = _("Dash") }
M.DESC = {
    shelf = _("Bookshelf's home: the book you're reading on top, your shelves as tabs, and the books under them."),
    dash = _("The book you're reading, your streak, this week, what's next in a series and a pick, with one row of covers."),
}

function M.id()
    local v = Store.get("home_layout")
    -- (the Read layout is gone since 1.8.1: anyone on it is back on Shelf)
    if v == "dash" then return v end
    return "shelf"
end

-- What the drawing keeps between paints: the page of rows, each row's first
-- book, Dash's chosen list, and what can be tapped.
local st = { page = 1, off = {}, dash_list = nil, hits = {}, rows = {}, pages = 1 }

--- The theme's text face, else Bookshelf's own (Retro keeps Bookshelf's font).
local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and (UI.boldFace(size))) or (italic and (UI.italicFace(size)))
        or UI.face(size)
end

local function inside(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function shelfWidget()
    return require("bos_shelf").shelfWidget()
end

local function repaint(mode, rect)
    local bw = shelfWidget()
    if bw then UIManager:setDirty(bw, mode or "ui", rect) end
end

-- ---------------------------------------------------------------- the lists

local data = { at = 0 }

--- Forget what was gathered (a book was opened, read, finished…).
function M.invalidate()
    data = { at = 0 }
    st.bar = nil
    -- the book just read moves up and shows its progress (not a library rebuild)
    local Recs = package.loaded["bos_recs"]
    if Recs and Recs.touch then
        pcall(function()
            local h = require("readhistory").hist
            Recs.touch(h and h[1] and h[1].file)
        end)
    end
end

local function bookOf(b)
    return { filepath = b.filepath, title = b.title, author = b.authors and b.authors[1],
        pct = b.pct, state = b.state }
end

local function onlineOf(item)
    local Online = require("bos_online")
    local author = item.author
    if not author and type(item.authors) == "table" then author = item.authors[1] end
    local mine = Online.owned(item)
    return { online = item, title = item.title, author = author,
        cover_path = Online.cachedCoverPath(item, "M"), dashed = true, owned = mine and mine.filepath or nil }
end

local function gather()
    if data.lists and os.time() - data.at < 30 then return data end
    local lists, by = {}, {}
    local function add(id, label, books, opts)
        if not books or #books == 0 then return end
        local r = { id = id, label = label, books = books }
        for k, v in pairs(opts or {}) do r[k] = v end
        table.insert(lists, r)
        by[id] = r
    end
    local function conv(list, n)
        local out = {}
        for _i, b in ipairs(list or {}) do
            if #out >= n then break end
            table.insert(out, bookOf(b))
        end
        return out
    end
    local ok, err = pcall(function()
        local Recs = require("bos_recs")
        local L = Recs.library()
        if L then
            local reading, recent, finished = {}, {}, {}
            for _i, b in ipairs(L.books) do
                if b.rank then table.insert(recent, b) end
                if b.state == "reading" then table.insert(reading, b) end
                if b.state == "finished" then table.insert(finished, b) end
            end
            local function byRank(a, b) return (a.rank or 1e9) < (b.rank or 1e9) end
            table.sort(reading, byRank)
            table.sort(recent, byRank)
            table.sort(finished, byRank)
            add("continue", _("Continue reading"), conv(reading, 30), { big = true, short = _("Reading") })
            add("recent", _("Recent"), conv(recent, 40), { short = _("Recent") })
            add("upnext", Recs.labelFor("upnext"), conv(Recs.list("upnext", 40), 40), { short = _("Up next") })
            add("because", Recs.labelFor("because"), conv(Recs.list("because", 40), 40), { short = _("Because") })
            add("pickup", Recs.labelFor("pickup"), conv(Recs.list("pickup", 40), 40), { short = _("Pick up") })
            add("authors", Recs.labelFor("authors"), conv(Recs.list("authors", 40), 40), { short = _("Authors") })
            add("genres", Recs.labelFor("genres"), conv(Recs.list("genres", 40), 40), { short = _("Genres") })
            add("discover", Recs.labelFor("discover"), conv(Recs.list("discover", 40), 40), { short = _("Discover") })
            add("finished", _("Finished"), conv(finished, 40), { short = _("Finished") })
        end
        local okO, Online = pcall(require, "bos_online")
        if okO and Online then
            if Online.enabled() then
                for _i, sh in ipairs(Online.SHELVES) do
                    local items = {}
                    for _j, it in ipairs(Online.rowItems(sh.which)) do
                        if #items >= 30 then break end
                        table.insert(items, onlineOf(it))
                    end
                    add("online_" .. sh.which, _("Recommended for you"), items, { short = _("For you") })
                end
            end
            local want = {}
            for _j, it in ipairs(Online.wantList()) do table.insert(want, onlineOf(it)) end
            add("want", _("Want to read"), want, { short = _("Want") })
        end
    end)
    if not ok then logger.warn("ShelfTechUI: home layout lists:", err) end
    data = { lists = lists, by = by, at = os.time() }
    return data
end

-- ---------------------------------------------------------------- books

local function openBook(b)
    if b.online then require("bos_online").showSheet(b.online) return end
    if b.filepath then
        M.invalidate()
        require("bos_shelf").open(b.filepath)
    end
end

local function bookPage(b, list)
    if b.online then require("bos_online").showSheet(b.online) return end
    local files = {}
    for _i, x in ipairs(list or {}) do if x.filepath then table.insert(files, x.filepath) end end
    require("bos_bookpage").show(b.filepath, { list = files })
end

-- online covers, decoded once at their size
local img_cache, img_order = {}, {}
local function imageAt(path, w, h)
    local key = path .. "@" .. w .. "x" .. h
    if img_cache[key] ~= nil then return img_cache[key] or nil end
    local ok, bb = pcall(function()
        return require("ui/renderimage"):renderImageFile(path, false, w, h)
    end)
    img_cache[key] = (ok and bb) or false
    table.insert(img_order, key)
    while #img_order > 24 do
        local old = table.remove(img_order, 1)
        local e = img_cache[old]
        img_cache[old] = nil
        if e then pcall(function() e:free() end) end
    end
    return img_cache[key] or nil
end

--- A cover in cw x ch at x, y (bottom-aligned), with its progress under it.
--- Returns the rect it answers to.
local function drawCover(bb, b, x, y, cw, ch, opts)
    opts = opts or {}
    if b.filepath then
        require("bos_cover").paint(bb, b.filepath, x, y, cw, ch, { shadow = Look.SHADOW_SMALL, title = b.title })
    else
        -- not on the device: a dashed card, its cover when one was fetched
        local d = math.max(2, S(2))
        bb:paintRect(x, y, cw, ch, WHITE)
        Look.dashedH(bb, x, y, cw, d, Look.INK)
        Look.dashedH(bb, x, y + ch - d, cw, d, Look.INK)
        Look.dashedV(bb, x, y, ch, d, Look.INK)
        Look.dashedV(bb, x + cw - d, y, ch, d, Look.INK)
        local img = b.cover_path and imageAt(b.cover_path, cw - 4 * d, ch - 4 * d)
        if img then
            bb:blitFrom(img, x + math.floor((cw - img:getWidth()) / 2), y + math.floor((ch - img:getHeight()) / 2),
                0, 0, img:getWidth(), img:getHeight())
        else
            local Page = require("bos_page")
            Page.wrap(bb, b.title or "", Look.mono(math.max(8, math.floor(cw / 10))), x + S(6), y + S(8),
                cw - S(12), 5, S(14))
        end
        if b.owned then pcall(function() require("bos_online").paintBadge(bb, x + d, y, cw - 2 * d, ch - d) end) end
    end
    local h = ch + Look.SHADOW_SMALL
    if opts.progress ~= false and b.pct and b.pct > 0 and b.pct < 0.995 then
        local ph = math.max(S(5), math.floor(cw / 18))
        Look.track(bb, x, y + ch + S(8), cw, ph, b.pct)
        h = ch + S(8) + ph
    end
    return Geom:new{ x = x, y = y, w = cw + Look.SHADOW_SMALL, h = h }
end

-- ---------------------------------------------------------------- pieces

local function glyphButton(bb, x, y, w, h, glyph, opts)
    opts = opts or {}
    return Look.button(bb, x, y, w, h, nil, { on = opts.on, paint = function(b2, bx, by, bw, bh, ink)
        local tw = TextWidget:new{ text = glyph, face = UI.symbolFace(UI.ptForPx(math.floor(bh * 0.46))), fgcolor = ink }
        local sz = tw:getSize()
        tw:paintTo(b2, bx + math.floor((bw - sz.w) / 2), by + math.floor((bh - sz.h) / 2))
        tw:free()
    end })
end

local function hit(rect, fn, hold, opts)
    table.insert(st.hits, { rect = rect, fn = fn, hold = hold, flash = not (opts and opts.no_flash) })
end

--- Bookshelf's start menu, opening down from the ☰ key at the top of Dash
--- (Bookshelf's own key is at the bottom of the shelf, and its menu
--- grew up from there, across the screen from the key that was tapped).
--- A tap on the key while the menu is open lands on the menu's window, which
--- closes it, as with Bookshelf's own key.
function M.openStartMenu(bw, key)
    local Park = package.loaded["lib/bookshelf_reader_park"]
    if Park and Park.isParked and Park.isParked() then
        -- a book is parked under home: Bookshelf closes it first (its own path)
        return pcall(bw._openStartMenu, bw, true)
    end
    local okS, StartMenu = pcall(require, "lib/bookshelf_start_menu")
    if not (okS and StartMenu and StartMenu.open) then return pcall(bw._openStartMenu, bw, true) end
    local inset = key.y + key.h + S(6)
    local ok, err = pcall(StartMenu.open, bw, inset, key, "library", nil, true, "left")
    if not ok then
        logger.warn("ShelfTechUI: start menu from the top:", err)
        pcall(bw._openStartMenu, bw, true)
    end
end

--- Choose a layout from a list under `anchor`.
function M.choose(anchor)
    local items = {}
    for _i, id in ipairs(M.ORDER) do
        table.insert(items, { text = (M.id() == id and "\u{2713} " or "    ") .. M.NAMES[id],
            callback = function() M.set(id) end })
    end
    UI.openList(items, anchor or Geom:new{ x = S(18), y = S(40), w = S(46), h = S(40) })
end

--- The top of Dash: the date, time and battery; then the start
--- menu, search and layout keys, and your home chips on the right.
local function drawTop(bw, bb, W, pad)
    local y = S(8)
    local line_h = S(22)
    local clock = os.date(G_reader_settings:isTrue("twelve_hour_clock") and "%I:%M %p" or "%H:%M"):gsub("^0", "")
    Look.label(bb, clock .. "  \u{00B7}  " .. os.date("%a %d %b"), pad, y, W - 2 * pad, line_h, 11,
        { color = Look.GRAY })
    local right
    if Device:hasBattery() then
        local ok, lvl = pcall(function() return Device:getPowerDevice():getCapacity() end)
        if ok and type(lvl) == "number" then right = lvl .. "%" end
    end
    if right then Look.label(bb, right, pad, y, W - 2 * pad, line_h, 11, { align = "right", color = Look.GRAY }) end
    y = y + line_h + S(6)
    local bh, kw, gap = S(40), S(46), S(10)
    local x = pad
    local r = glyphButton(bb, x, y, kw, bh, UI.GLYPH.bars)
    local menu_key = r
    hit(r, function() M.openStartMenu(bw, menu_key) end, nil, { no_flash = true })
    x = x + kw + gap + Look.SHADOW_SMALL
    -- one search field, as on a Kindle's or a Kobo's home: your own books as
    -- you type, then the store's libraries (bos_store). It takes the room
    -- the home chips leave (at least 40% of the width).
    local chips = {}
    if Store.get("home_status_bar") ~= false then
        local okC, list = pcall(function() return require("bos_controls").shown("home") end)
        chips = okC and list or {}
    end
    local rest = W - pad - x
    local chips_w = #chips > 0 and math.min(math.floor(rest * 0.6), #chips * S(62)) or 0
    local fw = rest - chips_w - (chips_w > 0 and gap or 0) - Look.SHADOW_SMALL
    Look.box(bb, x, y, fw, bh, { shadow = Look.SHADOW_SMALL })
    do
        local tw = TextWidget:new{ text = UI.GLYPH.search, face = UI.symbolFace(UI.ptForPx(math.floor(bh * 0.38))), fgcolor = Look.INK }
        local sz = tw:getSize()
        tw:paintTo(bb, x + S(12), y + math.floor((bh - sz.h) / 2))
        tw:free()
        local lx = x + S(12) + sz.w + S(10)
        local hint = fw > S(300) and _("Search your books and the store")
            or fw > S(190) and _("Books and the store") or _("Search")
        local t2 = TextWidget:new{ text = hint, face = tface(13), fgcolor = Look.GRAY, max_width = fw - (lx - x) - S(8) }
        local s2 = t2:getSize()
        t2:paintTo(bb, lx, y + math.floor((bh - s2.h) / 2))
        t2:free()
    end
    hit(Geom:new{ x = x, y = y - S(4), w = fw + Look.SHADOW_SMALL, h = bh + S(8) },
        function() require("bos_store").open{ search = true } end,
        function() UIManager:sendEvent(Event:new("ShowFileSearch")) end, { no_flash = true })
    x = x + fw + Look.SHADOW_SMALL + gap
    -- your home chips (bos_statusbar) in what's left
    local bar_w = W - pad - x
    local bar_h = bh
    if bar_w > S(60) and #chips > 0 then
        if not st.bar or st.bar.width ~= bar_w then
            local ok, bar = pcall(function()
                local chips = require("bos_controls").shown("home")
                if #chips == 0 then return nil end
                return require("bos_statusbar"):new{ width = bar_w, chips = chips }
            end)
            st.bar = ok and bar or nil
        end
        if st.bar then
            st.bar:paintTo(bb, x, y)
            bar_h = math.max(bh, st.bar:getSize().h)
        end
    end
    y = y + bar_h + Look.SHADOW_SMALL + S(12)
    bb:paintRect(pad, y, W - 2 * pad, Look.LINE, Look.INK)
    return y + Look.LINE + S(12)
end

-- ---------------------------------------------------------------- Dash

local function card(bb, x, y, w, h, title, right)
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW })
    local bh = S(24)
    local tw = Look.textWidth(Look.case(title), 10) + S(12)
    Look.stripes(bb, x + Look.LINE + S(4), y + Look.LINE + S(3), w - 2 * Look.LINE - S(8), bh - S(6))
    bb:paintRect(x + Look.LINE + S(6), y + Look.LINE, tw, bh, Look.PAPER)
    Look.label(bb, title, x + Look.LINE + S(6), y + Look.LINE, tw, bh, 10, { align = "center" })
    if right then
        local rw = Look.textWidth(Look.case(right), 10) + S(12)
        bb:paintRect(x + w - Look.LINE - S(6) - rw, y + Look.LINE, rw, bh, Look.PAPER)
        Look.label(bb, right, x + w - Look.LINE - S(6) - rw, y + Look.LINE, rw, bh, 10, { align = "center" })
    end
    bb:paintRect(x, y + Look.LINE + bh, w, Look.LINE, Look.INK)
    return y + Look.LINE * 2 + bh
end

local stats_cache = { at = 0 }
local function stats()
    if stats_cache.f and os.time() - stats_cache.at < 60 then return stats_cache end
    local Sum = require("bos_summary")
    local okF, f = pcall(Sum.figures)
    local okD, d = pcall(Sum.days, 7)
    stats_cache = { f = okF and f or {}, days = okD and d or {}, at = os.time() }
    return stats_cache
end

local forecast_cache = {}
local function forecast(file)
    local e = forecast_cache[file]
    if e and os.time() - e.at < 120 then return e.f end
    local ok, f = pcall(function() return require("bos_reading").forecastFile(file) end)
    forecast_cache = { [file] = { f = ok and f or nil, at = os.time() } }
    return ok and f or nil
end

local function textBlock(bb, text, face, x, y, w, lines, line_h, color)
    return require("bos_page").wrap(bb, text, face, x, y, w, lines, line_h, color)
end

local function drawSmallBook(bb, b, list, x, y, w, h, empty)
    if not b then
        textBlock(bb, empty, Look.serif(13, false, true), x, y + S(6), w, 3, S(20), Look.GRAY)
        return
    end
    local ch = h
    local cw = math.floor(ch / 1.5)
    local rect = drawCover(bb, b, x, y, cw, ch, { progress = false })
    local tx = x + cw + S(14)
    local th = textBlock(bb, b.title or "", tface(15, true), tx, y + S(2), w - (tx - x), 2, S(22))
    if b.author then
        textBlock(bb, b.author, Look.serif(13, false, true), tx, y + S(4) + th, w - (tx - x), 1, S(20))
    end
    hit(Geom:new{ x = x, y = y, w = w, h = h }, function() openBook(b) end, function() bookPage(b, list) end)
    return rect
end

local function drawDash(bw, bb, W, H)
    local pad = S(18)
    local w = W - 2 * pad
    local y = drawTop(bw, bb, W, pad)
    local D = gather()
    -- now reading
    local nowr = D.by.continue and D.by.continue.books[1]
    local ch_h = math.floor(H * 0.215)
    Look.box(bb, pad, y, w, ch_h, { shadow = Look.SHADOW })
    local ip = S(14)
    if nowr then
        local cvh = ch_h - 2 * ip
        local cvw = math.floor(cvh / 1.5)
        drawCover(bb, nowr, pad + ip, y + ip, cvw, cvh, { progress = false })
        local bwid = S(84)
        local tx = pad + ip + cvw + S(18)
        local tw = pad + w - ip - bwid - S(14) - tx
        Look.label(bb, _("Now reading"), tx, y + ip, tw, S(18), 10, { color = Look.GRAY })
        local ty = y + ip + S(22)
        ty = ty + textBlock(bb, nowr.title or "", tface(22, true), tx, ty, tw, 2, S(30))
        if nowr.author then
            textBlock(bb, nowr.author, Look.serif(15, false, true), tx, ty + S(4), tw, 1, S(22))
        end
        local pct = nowr.pct or 0
        local by = y + ch_h - ip - S(10)
        Look.track(bb, tx, by, tw, S(10), pct)
        local f = nowr.filepath and forecast(nowr.filepath)
        local line = T("%1%", math.floor(pct * 100 + 0.5)) .. (f and f.short and ("  \u{00B7}  " .. f.short) or "")
        Look.label(bb, line, tx, by - S(24), tw, S(20), 10, { keep_case = true })
        local bx = pad + w - ip - bwid
        local r = Look.button(bb, bx, y + ip, bwid, ch_h - 2 * ip - Look.SHADOW_SMALL, _("Read") .. " \u{203A}", { size = 13, on = true })
        local book = nowr
        hit(r, function() openBook(book) end)
        hit(Geom:new{ x = pad, y = y, w = bx - pad, h = ch_h }, function() openBook(book) end,
            function() bookPage(book, D.by.continue.books) end)
    else
        textBlock(bb, _("Nothing open right now. Pick a book below, or search your library."),
            Look.serif(16, false, true), pad + ip, y + ip, w - 2 * ip, 3, S(24), Look.GRAY)
    end
    y = y + ch_h + Look.SHADOW + S(14)
    -- four cards
    local cgap = S(14)
    local cw = math.floor((w - cgap - Look.SHADOW) / 2)
    local ch = math.floor(H * 0.15)
    local St = stats()
    local Sum = require("bos_summary")
    -- streak
    local x1, x2 = pad, pad + cw + cgap
    local by = card(bb, x1, y, cw, ch, _("Streak"))
    local streak = St.f.streak or 0
    local big = TextWidget:new{ text = tostring(streak), face = tface(34, true), fgcolor = BLACK }
    local bsz = big:getSize()
    local inner = y + ch - by
    big:paintTo(bb, x1 + S(14), by + math.floor((inner - bsz.h) / 2))
    big:free()
    local sx = x1 + S(14) + bsz.w + S(14)
    Look.label(bb, streak == 1 and _("day in a row") or _("days in a row"), sx, by + math.floor(inner / 2) - S(24), cw - (sx - x1) - S(8), S(18), 10)
    local sq = math.min(S(16), math.floor((cw - (sx - x1) - S(12)) / 7) - S(3))
    for i, d in ipairs(St.days or {}) do
        local qx = sx + (i - 1) * (sq + S(3))
        Look.box(bb, qx, by + math.floor(inner / 2) + S(2), sq, sq, { fill = d.secs > 0 and BLACK or WHITE, border = math.max(1, S(1.5)) })
    end
    hit(Geom:new{ x = x1, y = y, w = cw, h = ch }, function() require("bos_summary").show() end)
    -- this week
    by = card(bb, x2, y, cw, ch, _("This week"), St.f.week and Sum.duration(St.f.week, true) or nil)
    local days = St.days or {}
    local maxs = 1
    for _i, d in ipairs(days) do maxs = math.max(maxs, d.secs) end
    local bars_h = y + ch - by - S(30)
    local slot = math.floor((cw - S(24)) / math.max(1, #days))
    for i, d in ipairs(days) do
        local bx = x2 + S(12) + (i - 1) * slot
        local bh = math.floor(bars_h * d.secs / maxs)
        if d.secs > 0 then bh = math.max(S(3), bh) end
        bb:paintRect(bx + S(3), by + S(8) + bars_h - bh, slot - S(8), bh, Look.INK)
        bb:paintRect(bx + S(3), by + S(8) + bars_h, slot - S(8), math.max(1, S(1)), Look.INK)
        Look.label(bb, os.date("%a", d.t):sub(1, 1), bx, by + S(10) + bars_h, slot - S(2), S(18), 9, { align = "center" })
    end
    hit(Geom:new{ x = x2, y = y, w = cw, h = ch }, function() UIManager:sendEvent(Event:new("ShowCalendarView")) end)
    y = y + ch + Look.SHADOW + cgap
    -- up next in series (else pick back up)
    local up = D.by.upnext or D.by.pickup
    by = card(bb, x1, y, cw, ch, up == D.by.pickup and up and _("Pick back up") or _("Up next in series"))
    drawSmallBook(bb, up and up.books[1], up and up.books, x1 + S(12), by + S(10), cw - S(24), y + ch - by - S(20),
        _("Start a series and the next book shows up here."))
    -- a pick: online, else want to read, else discover
    local pick, ptitle
    for _i, id in ipairs{ "online_all" } do
        if D.by[id] then pick, ptitle = D.by[id], _("Online pick") break end
    end
    if not pick and D.by.want then pick, ptitle = D.by.want, _("Want to read") end
    if not pick and D.by.discover then pick, ptitle = D.by.discover, _("Discover") end
    by = card(bb, x2, y, cw, ch, ptitle or _("Discover"))
    drawSmallBook(bb, pick and pick.books[1], pick and pick.books, x2 + S(12), by + S(10), cw - S(24), y + ch - by - S(20),
        _("Turn on online picks (Settings → Connect) for books you don't have yet."))
    y = y + ch + Look.SHADOW + S(16)
    -- chips: which list the covers below show
    local ids = {}
    for _i, id in ipairs{ "continue", "recent", "upnext", "because", "discover", "want", "finished" } do
        if D.by[id] then table.insert(ids, id) end
    end
    if #ids > 0 then
        if not (st.dash_list and D.by[st.dash_list]) then st.dash_list = ids[1] end
        local items, on = {}, {}
        for i, id in ipairs(ids) do
            items[i] = { text = D.by[id].short or D.by[id].label, key = id }
            if id == st.dash_list then on[id] = true end
        end
        local Page = require("bos_page")
        local rects, used = Page.chips(nil, items, pad, y, w - S(70), 11, on)
        -- only the chips that fit on one line
        local rows_y = rects[1] and rects[1].y
        local shown = {}
        for i, r in ipairs(rects) do if r.y == rows_y then shown[#shown + 1] = items[i] end end
        rects = Page.chips(bb, shown, pad, y, w - S(70), 11, on)
        for i, r in ipairs(rects) do
            local id = shown[i].key
            hit(r, function() st.dash_list = id st.off.dash = 1 repaint() end)
        end
        local list = D.by[st.dash_list]
        local ar = Look.button(bb, pad + w - S(62), y, S(58), S(26), _("All") .. " \u{203A}", { size = 10 })
        hit(ar, function() M.showList(list) end)
        y = y + S(26) + S(16)
        -- the covers, as big as the rest of the screen allows
        local footer = S(10)
        local room = H - y - footer - S(24)
        local gap = S(14)
        local ccw = math.floor(w / 5.3)
        local cch = math.floor(ccw * 1.5)
        if cch > room then cch = math.max(S(60), room) ccw = math.floor(cch / 1.5) end
        local n = math.max(1, math.floor((w + gap) / (ccw + gap)))
        local off = math.max(1, math.min(st.off.dash or 1, math.max(1, #list.books - n + 1)))
        st.off.dash = off
        local x = pad
        for k = off, math.min(#list.books, off + n - 1) do
            local b = list.books[k]
            local rect = drawCover(bb, b, x, y, ccw, cch)
            hit(rect, function() openBook(b) end, function() bookPage(b, list.books) end)
            x = x + ccw + gap
        end
        st.rows = { { rect = Geom:new{ x = 0, y = y, w = W, h = cch + S(20) }, row = list, n = n, key = "dash" } }
        local sy = y + cch + S(20)
        if sy + S(10) < H then
            Look.stripes(bb, pad, sy, w, S(8))
            bb:paintRect(pad, sy + S(8), w, math.max(2, S(3)), Look.INK)
        end
    end
end

-- ---------------------------------------------------------------- the whole list

--- All of a list, as a page of covers (‹ › or swipe for more).
function M.showList(row)
    if not row then return end
    local Page = require("bos_page")
    local page_no = 1
    local p
    p = Page:new{ caption = row.label, draw = function(self, bb, y, w)
        local H = Screen:getHeight()
        local x0 = self.pad
        local cols = 3
        local gap = S(20)
        local cw = math.floor((w - (cols - 1) * gap) / cols)
        local ch = math.floor(cw * 1.5)
        local footer = S(60)
        local rh = ch + S(24) + S(10)
        local rows = math.max(1, math.floor((H - y - footer) / rh))
        local per = rows * cols
        local pages = math.max(1, math.ceil(#row.books / per))
        page_no = math.max(1, math.min(page_no, pages))
        for i = (page_no - 1) * per + 1, math.min(#row.books, page_no * per) do
            local k = i - (page_no - 1) * per - 1
            local cx = x0 + (k % cols) * (cw + gap)
            local cy = y + math.floor(k / cols) * rh
            local b = row.books[i]
            local rect = drawCover(bb, b, cx, cy, cw, ch)
            self:hit(rect, function(pg) openBook(b) end, function() bookPage(b, row.books) end)
        end
        if pages > 1 then
            local fy = H - footer + S(8)
            local r = Look.button(bb, x0, fy, S(64), S(40), "\u{2039}", { size = 16, enabled = page_no > 1 })
            if page_no > 1 then self:hit(r, function(pg) page_no = page_no - 1 pg:refresh("ui") end) end
            Look.label(bb, T("%1 / %2", page_no, pages), x0, fy, w, S(40), 13, { align = "center" })
            r = Look.button(bb, x0 + w - S(64) - Look.SHADOW_SMALL, fy, S(64), S(40), "\u{203A}", { size = 16, enabled = page_no < pages })
            if page_no < pages then self:hit(r, function(pg) page_no = page_no + 1 pg:refresh("ui") end) end
        end
    end,
    on_swipe = function(self, dir)
        if dir == "west" then page_no = page_no + 1 self:refresh("ui")
        elseif dir == "east" then
            if page_no > 1 then page_no = page_no - 1 self:refresh("ui") else self:onClose() end
        end
    end }
    p:show()
end

-- ---------------------------------------------------------------- paint and gestures

function M.paint(bw, bb, x, y)
    local W, H = Screen:getWidth(), Screen:getHeight()
    st.hits = {}
    bb:paintRect(x, y, W, H, Look.PAPER)
    drawDash(bw, bb, W, H)
    if st.flash then bb:invertRect(st.flash.x, st.flash.y, st.flash.w, st.flash.h) end
end

local DIAGONAL = { northeast = true, northwest = true, southeast = true, southwest = true }

--- true when the gesture was ours.
function M.gesture(bw, event, ges)
    if type(ges) ~= "table" or not ges.pos then return false end
    local W, H = Screen:getWidth(), Screen:getHeight()
    local kind, dir = ges.ges, ges.direction
    if kind == "swipe" then
        -- KOReader's own (pull-down from the top), the edge swipes and a
        -- diagonal refresh stay as they are on the shelf
        if DIAGONAL[dir] then return false end
        if dir == "south" and ges.pos.y < H * 0.08 then return false end
        if (dir == "north" or dir == "south") and (ges.pos.x < W * 0.1 or ges.pos.x > W * 0.9) then return false end
    end
    -- the home chips answer for themselves
    if st.bar and st.bar.dimen and st.bar.dimen.x and inside(ges.pos, st.bar.dimen)
            and (kind == "tap" or kind == "hold") then
        st.bar:handleEvent(event)
        return true
    end
    if kind == "tap" or kind == "hold" then
        for i = #st.hits, 1, -1 do
            local h = st.hits[i]
            local fn = kind == "tap" and h.fn or h.hold
            if fn and inside(ges.pos, h.rect) then
                if h.flash then
                    -- pressed, on screen at once; then the action
                    st.flash = h.rect
                    UIManager:setDirty(bw, "fast", h.rect)
                    UIManager:forceRePaint()
                    st.flash = nil
                    UIManager:setDirty(bw, "ui", h.rect)
                end
                UIManager:nextTick(function()
                    local ok, err = pcall(fn)
                    if not ok then logger.warn("ShelfTechUI: home layout action:", err) end
                end)
                return true
            end
        end
        return true
    end
    if kind == "swipe" then
        -- sideways on a row: that row moves; elsewhere (and up/down): the page
        for _i, r in ipairs(st.rows or {}) do
            if inside(ges.pos, r.rect) and (dir == "west" or dir == "east") then
                local key = r.key or r.row.id
                local step = math.max(1, r.n - 1)
                local cur = st.off[key] or 1
                local nxt = dir == "west" and cur + step or cur - step
                nxt = math.max(1, math.min(nxt, math.max(1, #r.row.books - r.n + 1)))
                if nxt ~= cur then
                    st.off[key] = nxt
                    UIManager:setDirty(bw, "ui", r.rect)
                end
                return true
            end
        end
        return true
    end
    -- anything else (pans, two fingers): not for the shelf under us
    return true
end

-- ---------------------------------------------------------------- switching

function M.set(id)
    if not M.NAMES[id] then return end
    Store.set("home_layout", id ~= "shelf" and id or nil)
    st.page, st.off, st.bar, st.hits, st.rows = 1, {}, nil, {}, {}
    M.invalidate()
    local bw = shelfWidget()
    if bw then
        if id == "shelf" then pcall(bw._rebuild, bw) end
        UIManager:setDirty(bw, "full")
    end
end

--- The next layout, round (the Layout chip's tap, the gesture action).
function M.cycle()
    local cur = M.id()
    for i, id in ipairs(M.ORDER) do
        if id == cur then return M.set(M.ORDER[i % #M.ORDER + 1]) end
    end
end

-- ---------------------------------------------------------------- install

function M.install()
    if M._installed then return true end
    local ok, BW = pcall(require, "lib/bookshelf_widget")
    if not ok or type(BW) ~= "table" or type(BW.paintTo) ~= "function" or type(BW.handleEvent) ~= "function" then
        return false
    end
    M._installed = true
    local orig_paint = BW.paintTo
    BW.paintTo = function(self, bb, x, y)
        if M.id() ~= "shelf" then
            -- Bookshelf's own guards: an "Opening file…" placeholder or a
            -- book being swapped is on screen, not home
            local stack = UIManager._window_stack
            local top = stack and stack[#stack] and stack[#stack].widget
            if top and top.invisible and top.text then return end
            if self._suppress_transition_paint then return end
            -- what Bookshelf asked for this frame (kept parts of the screen
            -- under a closed window are already there)
            pcall(self._takePaintClip, self, bb)
            local skip = self._underlay_skip
            self._underlay_skip = nil
            if skip and self._first_paint_done and bb == Screen.bb then return end
            local Underlay = package.loaded["lib/bookshelf_underlay"]
            if Underlay and Underlay.covered() then Underlay.invalidate() end
            local okP, err = pcall(M.paint, self, bb, x or 0, y or 0)
            if okP then
                self._first_paint_done = true
                if Underlay and bb == Screen.bb then Underlay.shelfPainted() end
                return
            end
            logger.warn("ShelfTechUI: home layout failed, showing the shelf:", err)
        end
        return orig_paint(self, bb, x, y)
    end
    local orig_ev = BW.handleEvent
    BW.handleEvent = function(self, event)
        if M.id() ~= "shelf" and event.handler == "onGesture" and not Device.screen_saver_lock then
            local okG, done = pcall(M.gesture, self, event, event.args and event.args[1])
            if not okG then logger.warn("ShelfTechUI: home layout gesture:", done)
            elseif done then return true end
        end
        return orig_ev(self, event)
    end
    -- coming back to home (from a book, a dialog): fresh lists
    if type(BW.onShow) == "function" then
        local orig_show = BW.onShow
        BW.onShow = function(self, ...)
            M.invalidate()
            return orig_show(self, ...)
        end
    end
    return true
end

return M
