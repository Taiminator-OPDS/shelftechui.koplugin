--[[
Wrapped: your year in books, as a story of full-screen cards.

  M.open(year)        put the year together (in the background, the first
                      time) and show it
  M.maybeNotify()     on home: from 1 December the year's card ("Your year is
                      ready"), once; in January, last year's once more if it
                      was never opened. Never over a book.
  M.settingsItems()   Settings → Reading → Wrapped

The cards, in order: the year, time read, books finished, the long haul (only
when a book started in an earlier year was finished this one), the book of
the year, authors and genres, when you read, your reader type, what you
marked, and the year on one page (save it as a picture, or as your sleep
screen). Tap the right of the screen for the next card, the left to go back;
swipe down or ✕ to close. Each card is one full refresh, so nothing of the
last one stays behind.

Numbers: bos_wrapped_data (on the device only; nothing is sent anywhere).
--]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Look = require("bos_look")
local Store = require("bos_settings_store")
local UI = require("bos_ui")
local Data = require("bos_wrapped_data")

local Screen = Device.screen
local S = Look.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

local MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"), _("July"),
    _("August"), _("September"), _("October"), _("November"), _("December") }
local WEEKDAYS = { _("Sunday"), _("Monday"), _("Tuesday"), _("Wednesday"), _("Thursday"), _("Friday"), _("Saturday") }

-- ---------------------------------------------------------------- drawing

local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and (UI.boldFace(size))) or (italic and (UI.italicFace(size)))
        or UI.face(size)
end

--- Big type (the theme's bold text face); returns its width and height.
local function big(bb, text, x, y, size, color, max_w)
    local tw = TextWidget:new{ text = text, face = tface(size, true), fgcolor = color or BLACK, bold = true,
        max_width = max_w, truncate_with_ellipsis = max_w ~= nil }
    local sz = tw:getSize()
    if bb then tw:paintTo(bb, x, y) end
    tw:free()
    return sz.w, sz.h
end

--- Text in up to `lines` lines; returns the height used. White text goes
--- on black (the reader-type card).
local function wrap(bb, text, face, x, y, w, lines, line_h, color)
    if not rawequal(color, WHITE) then return require("bos_page").wrap(bb, text, face, x, y, w, lines, line_h, color) end
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local args = { text = tostring(text or ""), face = face, width = w, fgcolor = WHITE, bgcolor = BLACK, line_height = 0.2 }
    local tb = TextBoxWidget:new(args)
    if lines and line_h and tb:getSize().h > lines * line_h then
        tb:free()
        args.height, args.height_overflow_show_ellipsis = lines * line_h, true
        tb = TextBoxWidget:new(args)
    end
    local h = tb:getSize().h
    if bb then tb:paintTo(bb, x, y) end
    tb:free()
    return h
end

local function serifI(size) return Look.serif(size, false, true) end

local function hours(secs)
    local h = secs / 3600
    if h >= 10 then return tostring(math.floor(h + 0.5)) end
    return string.format("%.1f", h)
end

local function dateShort(t) return t and os.date("%d %b %Y", t):gsub("^0", "") or "" end

local function cover(bb, b, x, y, w, h)
    if b and b.fp then
        require("bos_cover").paint(bb, b.fp, x, y, w, h, { shadow = Look.SHADOW_SMALL, title = b.title })
    else
        Look.box(bb, x, y, w, h, { shadow = Look.SHADOW_SMALL })
        if b and b.title then
            wrap(bb, b.title, Look.serif(math.max(8, math.floor(w / 8))), x + S(6), y + S(8), w - S(12), 5, math.floor(w / 6))
        end
    end
end

-- ---------------------------------------------------------------- the cards

--- Each card: function(c, bb, x, y, w, h) where c is the story (c.r: the
--- year; c:hit(rect, fn) for a button). x, y, w, h: the card's body.
local CARDS = {}

function CARDS.cover(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + math.floor(h * 0.18)
    Look.stripes(bb, x, cy, w, S(16))
    cy = cy + S(34)
    local _bw, bh = big(bb, tostring(r.year), x - S(4), cy, 96)
    cy = cy + bh + S(14)
    Look.label(bb, _("Your year"), x, cy, w, S(34), 24, {})
    Look.label(bb, _("in books"), x, cy + S(36), w, S(34), 24, {})
    cy = cy + S(90)
    wrap(bb, _("What you read, when you read, and the book that stayed with you."), serifI(19), x, cy, math.floor(w * 0.85), 3, S(28))
    Look.stripes(bb, x, y + math.floor(h * 0.82), w, S(16))
end

function CARDS.time(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(30)
    Look.label(bb, _("You read for"), x, cy, w, S(24), 14, {})
    cy = cy + S(30)
    local bw, bh = big(bb, hours(r.secs), x - S(2), cy, 84)
    Look.label(bb, _("hours"), x + bw + S(14), cy + bh - S(44), S(200), S(36), 22, {})
    cy = cy + bh + S(10)
    local days = r.secs / 86400
    local per_day = r.secs / 60 / math.max(1, r.days_in_year or 365)
    local line = days >= 1 and T(_("That's %1 whole days, or %2 minutes on an average day."), string.format("%.1f", days), math.floor(per_day + 0.5))
        or T(_("%1 minutes on an average day."), math.floor(per_day + 0.5))
    cy = cy + wrap(bb, line, serifI(18), x, cy, w, 3, S(26)) + S(24)
    -- each month
    local bx, by, bw2, bh2 = x, cy, w - Look.SHADOW, math.min(S(260), y + h - cy - S(30))
    Look.box(bb, bx, by, bw2, bh2, { shadow = Look.SHADOW })
    local top_m, top_v = 1, 0
    for i = 1, 12 do if r.months[i] > top_v then top_m, top_v = i, r.months[i] end end
    Look.label(bb, _("Hours each month"), bx + S(14), by + S(10), bw2 - S(28), S(20), 11, {})
    if top_v > 0 then
        Look.label(bb, T(_("Top: %1, %2 h"), MONTHS[top_m], hours(top_v)), bx + S(14), by + S(10), bw2 - S(28), S(20), 11,
            { align = "right", color = Look.GRAY })
    end
    local gx, gy, gw, gh = bx + S(14), by + S(40), bw2 - S(28), bh2 - S(76)
    local slot = math.floor(gw / 12)
    local letters = { "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" }
    for i = 1, 12 do
        local v = r.months[i]
        local hh = top_v > 0 and math.floor(gh * v / top_v) or 0
        if v > 0 then hh = math.max(S(3), hh) end
        local cx = gx + (i - 1) * slot
        Look.box(bb, cx + S(3), gy + gh - hh, slot - S(8), math.max(1, hh), { fill = i == top_m and BLACK or WHITE, border = math.max(1, S(1.5)) })
        Look.label(bb, letters[i], cx, gy + gh + S(6), slot - S(2), S(18), 10, { align = "center" })
    end
end

function CARDS.finished(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(20)
    local bw, bh = big(bb, tostring(#r.finished), x - S(2), cy, 76)
    Look.label(bb, _("books"), x + bw + S(16), cy + S(14), S(260), S(30), 22, {})
    Look.label(bb, _("finished"), x + bw + S(16), cy + S(44), S(260), S(30), 22, {})
    cy = cy + bh + S(12)
    local line = T(_("%1 pages."), r.pages)
    if r.longest and r.longest.pages then line = line .. " " .. T(_("Your longest was %1, at %2."), r.longest.title, r.longest.pages) end
    if #r.finished == 0 then line = _("Nothing finished yet this year: there's still time.") end
    cy = cy + wrap(bb, line, serifI(17), x, cy, w, 3, S(25)) + S(18)
    -- the wall
    local cols, gap = 6, S(10)
    local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
    local ch = math.floor(cw * 1.45)
    local rows = math.max(1, math.min(3, math.floor((y + h - cy - S(60)) / (ch + gap))))
    local shown = math.min(#r.finished, rows * cols)
    for i = 1, shown do
        local f = r.finished[#r.finished - i + 1] -- the latest first
        local k = i - 1
        cover(bb, f, x + (k % cols) * (cw + gap), cy + math.floor(k / cols) * (ch + gap), cw, ch)
    end
    cy = cy + math.ceil(shown / cols) * (ch + gap) + S(6)
    local more = #r.finished - shown
    local tail = {}
    if more > 0 then table.insert(tail, T(_("+ %1 more"), more)) end
    if r.abandoned > 0 then table.insert(tail, T(_("%1 set aside (we won't count them)"), r.abandoned)) end
    if #tail > 0 then Look.label(bb, table.concat(tail, " · "), x, cy, w, S(22), 11, { color = Look.GRAY }) end
end

-- The special one: books started in an earlier year, finished this year.
function CARDS.long_haul(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(20)
    Look.label(bb, _("The long haul"), x, cy, w, S(24), 14, {})
    cy = cy + S(32)
    local n = #r.long_haul
    local first_year = os.date("*t", r.long_haul[1].started).year
    for _i, b in ipairs(r.long_haul) do first_year = math.min(first_year, os.date("*t", b.started).year) end
    local title = n == 1 and T(_("Started in %1, finished in %2."), first_year, r.year)
        or T(_("%1 books started before %2 and finished in it."), n, r.year)
    cy = cy + wrap(bb, title, tface(26, true), x, cy, w, 3, S(36)) + S(10)
    cy = cy + wrap(bb, _("Some books take their time. These waited for you."), serifI(17), x, cy, w, 2, S(25)) + S(22)
    local cw = S(78)
    local ch = math.floor(cw * 1.45)
    local rows = math.max(1, math.min(4, math.floor((y + h - cy) / (ch + S(22)))))
    for i = 1, math.min(n, rows) do
        local b = r.long_haul[i]
        cover(bb, b, x, cy, cw, ch)
        local tx = x + cw + S(20)
        local tw = w - (tx - x)
        local th = wrap(bb, b.title or "", tface(18, true), tx, cy + S(2), tw, 2, S(26))
        if b.author then wrap(bb, b.author, serifI(15), tx, cy + S(4) + th, tw, 1, S(22)) end
        Look.label(bb, T(_("%1 → %2"), dateShort(b.started), dateShort(b.finished)), tx, cy + ch - S(46), tw, S(20), 11, { keep_case = true })
        local bw2 = big(bb, T(_("%1 days"), b.days), tx, cy + ch - S(26), 16)
        cy = cy + ch + S(22)
    end
end

function CARDS.top(c, bb, x, y, w, h)
    local r, t = c.r, c.r.top
    local cy = y + S(18)
    Look.label(bb, _("The book of your year"), x, cy, w, S(24), 14, { align = "center" })
    cy = cy + S(36)
    local cw = math.min(math.floor(w * 0.42), S(230))
    local ch = math.floor(cw * 1.5)
    cover(bb, t, x + math.floor((w - cw) / 2), cy, cw, ch)
    cy = cy + ch + S(18)
    cy = cy + wrap(bb, t.title or "", tface(22, true), x, cy, w, 2, S(30)) + S(2)
    if t.author then cy = cy + wrap(bb, t.author, serifI(16), x, cy, w, 1, S(24)) end
    cy = cy + S(16)
    local boxes = { { hours(t.secs) .. " h", _("with it") } }
    if t.days then table.insert(boxes, { tostring(t.days), t.days == 1 and _("day to finish") or _("days to finish") }) end
    if t.rating and t.rating > 0 then table.insert(boxes, { string.rep("★", t.rating), _("your rating") }) end
    local gap = S(12)
    local bw2 = math.floor((w - (#boxes - 1) * gap - Look.SHADOW_SMALL) / #boxes)
    for i, b in ipairs(boxes) do
        local bx = x + (i - 1) * (bw2 + gap)
        Look.box(bb, bx, cy, bw2, S(86), { shadow = Look.SHADOW_SMALL })
        big(bb, b[1], bx + S(12), cy + S(8), 26, BLACK, bw2 - S(20))
        Look.label(bb, b[2], bx + S(12), cy + S(56), bw2 - S(20), S(20), 10, {})
    end
    cy = cy + S(86) + S(18)
    if t.sitting and t.sitting.secs and t.sitting.secs >= 600 then
        local mins = math.floor(t.sitting.secs / 60 + 0.5)
        local dur = mins >= 60 and T(_("%1 h %2"), math.floor(mins / 60), string.format("%02d", mins % 60)) or T(_("%1 minutes"), mins)
        wrap(bb, T(_("Your longest sitting with it: %1, on a %2 in %3."), dur, WEEKDAYS[os.date("*t", t.sitting.at).wday],
            MONTHS[os.date("*t", t.sitting.at).month]), serifI(16), x, cy, w, 2, S(24))
    end
end

function CARDS.authors(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(18)
    Look.label(bb, _("Your top authors"), x, cy, w, S(24), 14, {})
    cy = cy + S(34)
    for i, a in ipairs(r.authors) do
        local rh = i == 1 and S(64) or S(46)
        big(bb, tostring(i), x, cy + (i == 1 and S(4) or S(4)), i == 1 and 32 or 22)
        local tx = x + S(56)
        wrap(bb, a.name, Look.serif(i == 1 and 24 or 18), tx, cy, w - S(56), 1, S(32))
        Look.label(bb, T(a.books == 1 and _("%1 book · %2 h") or _("%1 books · %2 h"), a.books, hours(a.secs)),
            tx, cy + rh - S(26), w - S(56), S(20), 10, {})
        bb:paintRect(x, cy + rh, w, math.max(1, S(1.5)), Look.INK)
        cy = cy + rh + S(10)
    end
    if #r.genres > 0 then
        cy = cy + S(16)
        Look.label(bb, _("Your genres"), x, cy, w, S(24), 14, {})
        cy = cy + S(34)
        for _i, g in ipairs(r.genres) do
            local lw = math.floor(w * 0.32)
            Look.label(bb, g.name, x, cy, lw, S(26), 12, { keep_case = false })
            Look.track(bb, x + lw + S(8), cy + S(5), w - lw - S(70), S(16), g.pct / 100)
            Look.label(bb, g.pct .. "%", x + w - S(56), cy, S(56), S(26), 12, { align = "right" })
            cy = cy + S(36)
        end
    end
end

function CARDS.habits(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(16)
    Look.label(bb, _("You read most at"), x, cy, w, S(24), 14, {})
    cy = cy + S(28)
    local ph = r.peak_hour or 21
    local label = ph == 0 and _("midnight") or ph == 12 and _("noon")
        or (ph < 12 and T(_("%1 am"), ph) or T(_("%1 pm"), ph - 12))
    local _bw, bh = big(bb, label, x - S(2), cy, 52)
    cy = cy + bh + S(12)
    -- each hour
    local bx, bw2, bh2 = x, w - Look.SHADOW, S(150)
    Look.box(bb, bx, cy, bw2, bh2, { shadow = Look.SHADOW })
    local maxv = 0
    for i = 1, 24 do maxv = math.max(maxv, r.hours[i]) end
    local gx, gy, gw, gh = bx + S(12), cy + S(12), bw2 - S(24), bh2 - S(46)
    local slot = gw / 24
    for i = 1, 24 do
        local v = r.hours[i]
        local hh = maxv > 0 and math.floor(gh * v / maxv) or 0
        if v > 0 then hh = math.max(S(2), hh) end
        local hx = gx + math.floor((i - 1) * slot)
        bb:paintRect(hx + 1, gy + gh - hh, math.max(1, math.floor(slot) - S(2)), hh, (i - 1) == ph and Look.INK or Look.GRAY)
    end
    local marks = { { 0, _("midnight") }, { 6, _("6 am") }, { 12, _("noon") }, { 18, _("6 pm") } }
    for _i, m in ipairs(marks) do
        Look.label(bb, m[2], gx + math.floor(m[1] * slot), gy + gh + S(6), S(120), S(18), 9, {})
    end
    cy = cy + bh2 + Look.SHADOW + S(18)
    local gap = S(14)
    local cw = math.floor((w - gap - Look.SHADOW_SMALL) / 2)
    local function stat(bx2, title, value, sub)
        Look.box(bb, bx2, cy, cw, S(120), { shadow = Look.SHADOW_SMALL })
        Look.label(bb, title, bx2 + S(14), cy + S(10), cw - S(28), S(20), 11, { color = Look.GRAY })
        big(bb, value, bx2 + S(14), cy + S(34), 26, BLACK, cw - S(28))
        Look.label(bb, sub, bx2 + S(14), cy + S(86), cw - S(28), S(20), 10, { keep_case = true })
    end
    if r.busiest_day then
        stat(x, _("Busiest day"), WEEKDAYS[r.busiest_day.wday], T(_("%1 min on average"), math.floor(r.busiest_day.avg / 60 + 0.5)))
    end
    if r.streak and r.streak.n > 0 then
        stat(x + cw + gap, _("Longest streak"), T(r.streak.n == 1 and _("%1 day") or _("%1 days"), r.streak.n),
            r.streak.n > 1 and (os.date("%d %b", r.streak.from):gsub("^0", "") .. " – " .. os.date("%d %b", r.streak.to):gsub("^0", "")) or "")
    end
    cy = cy + S(120) + S(20)
    wrap(bb, T(_("You read on %1 days of the year."), r.days_read), serifI(17), x, cy, w, 2, S(25))
end

function CARDS.persona(c, bb, x, y, w, h)
    local r = c.r
    local p = r.persona
    -- inverted: white on black
    local cy = y + math.floor(h * 0.16)
    Look.label(bb, _("You are"), x, cy, w, S(24), 14, { color = WHITE })
    cy = cy + S(34)
    cy = cy + wrap(bb, p.name, tface(40, true), x, cy, w, 3, S(52), WHITE) + S(20)
    Look.stripes(bb, x, cy, w, S(14), WHITE)
    cy = cy + S(34)
    for _i, f in ipairs(p.facts) do
        Look.label(bb, f[1], x, cy, math.floor(w * 0.3), S(26), 12, { color = WHITE })
        wrap(bb, f[2], serifI(17), x + math.floor(w * 0.32), cy, math.floor(w * 0.68), 2, S(25), WHITE)
        cy = cy + S(48)
    end
    Look.label(bb, _("One of 30 reader types, from when, how long and how much you read."), x, y + h - S(30), w, S(20), 9, { color = WHITE })
end

function CARDS.highlights(c, bb, x, y, w, h)
    local r = c.r
    local cy = y + S(18)
    local figs = { { tostring(r.highlights), _("highlights") }, { tostring(r.notes), _("notes") } }
    if r.words and r.words > 0 then table.insert(figs, { tostring(r.words), _("words looked up") }) end
    local fw = math.floor(w / #figs)
    for i, f in ipairs(figs) do
        local fx = x + (i - 1) * fw
        local _bw, bh = big(bb, f[1], fx, cy, 50)
        Look.label(bb, f[2], fx, cy + bh + S(2), fw - S(8), S(20), 11, {})
    end
    cy = cy + S(110)
    if r.quote then
        Look.label(bb, _("A line you marked"), x, cy, w, S(22), 12, {})
        cy = cy + S(30)
        local qx, qw = x + S(24), w - S(48) - Look.SHADOW
        local qh = require("bos_page").wrap(nil, "“" .. r.quote.text .. "”", Look.serif(22), 0, 0, qw, 7, S(32))
        local box_h = qh + S(96)
        Look.box(bb, x, cy, w - Look.SHADOW, box_h, { shadow = Look.SHADOW })
        wrap(bb, "“" .. r.quote.text .. "”", Look.serif(22), qx, cy + S(24), qw, 7, S(32))
        Look.stripes(bb, qx, cy + S(30) + qh, qw, S(10))
        Look.label(bb, (r.quote.title or "") .. (r.quote.author and (" · " .. r.quote.author) or ""), qx, cy + S(50) + qh, qw, S(20), 10, {})
        cy = cy + box_h + S(24)
    end
    if r.most_marked and r.most_marked.n > 0 then
        wrap(bb, T(_("Most marked: %1, %2 highlights."), r.most_marked.title, r.most_marked.n), serifI(16), x, cy, w, 2, S(24))
    end
end

function CARDS.summary(c, bb, x, y, w, h, for_picture)
    local r = c.r
    local cy = y + S(8)
    local bw2 = w - Look.SHADOW
    local bh_title = S(40)
    local cell_h = S(78)
    local figs = {
        { _("Time read"), hours(r.secs) .. " h" },
        { _("Books finished"), tostring(#r.finished) },
        { _("Top author"), r.authors[1] and r.authors[1].name or "—" },
        { _("Top genre"), r.genres[1] and r.genres[1].name or "—" },
        { _("Longest streak"), T(r.streak.n == 1 and _("%1 day") or _("%1 days"), r.streak.n) },
        { _("Highlights"), tostring(r.highlights) },
    }
    local rows = math.ceil(#figs / 2)
    local book_h = S(150)
    local box_h = bh_title + rows * cell_h + book_h
    Look.box(bb, x, cy, bw2, box_h, { shadow = Look.SHADOW })
    Look.stripes(bb, x + S(8), cy + S(10), bw2 - S(16), S(20))
    local cap = T(_("My %1 in books"), r.year)
    local tw = Look.textWidth(Look.case(cap), 13) + S(20)
    bb:paintRect(x + math.floor((bw2 - tw) / 2), cy + S(6), tw, S(28), Look.PAPER)
    Look.label(bb, cap, x, cy + S(6), bw2, S(28), 13, { align = "center" })
    bb:paintRect(x, cy + bh_title, bw2, Look.LINE, Look.INK)
    local half = math.floor(bw2 / 2)
    for i, f in ipairs(figs) do
        local k = i - 1
        local fx, fy = x + (k % 2) * half, cy + bh_title + math.floor(k / 2) * cell_h
        Look.label(bb, f[1], fx + S(14), fy + S(8), half - S(24), S(18), 10, { color = Look.GRAY })
        big(bb, f[2], fx + S(14), fy + S(28), 22, BLACK, half - S(28))
        bb:paintRect(fx, fy + cell_h, half, Look.LINE, Look.INK)
        if k % 2 == 0 then bb:paintRect(fx + half, fy, Look.LINE, cell_h, Look.INK) end
    end
    local by = cy + bh_title + rows * cell_h + S(14)
    if r.top then
        local cw = S(80)
        cover(bb, r.top, x + S(14), by, cw, math.floor(cw * 1.5) > book_h - S(28) and book_h - S(28) or math.floor(cw * 1.5))
        local tx = x + S(14) + cw + S(18)
        Look.label(bb, _("Book of the year"), tx, by, bw2 - (tx - x) - S(10), S(18), 10, { color = Look.GRAY })
        wrap(bb, r.top.title or "", Look.serif(19), tx, by + S(24), bw2 - (tx - x) - S(14), 2, S(26))
        Look.label(bb, r.persona.name, tx, by + book_h - S(48), bw2 - (tx - x) - S(14), S(18), 10, {})
    end
    if for_picture then return end
    -- keys
    local ky = y + h - S(60)
    local gap = S(14)
    local kw = math.floor((w - gap - Look.SHADOW_SMALL) / 2)
    local rect = Look.button(bb, x, ky, kw, S(52), _("Save as picture"), { size = 13, on = true })
    c:hit(rect, function() M.savePicture(c) end)
    rect = Look.button(bb, x + kw + gap, ky, kw, S(52), _("See it again"), { size = 13 })
    c:hit(rect, function() c:go(1) end)
end

function CARDS.empty(c, bb, x, y, w, h)
    local cy = y + math.floor(h * 0.25)
    big(bb, tostring(c.r.year), x, cy, 72)
    cy = cy + S(110)
    wrap(bb, _("Not much to wrap yet: read a little more this year, and your year in books will be here."),
        serifI(20), x, cy, w, 4, S(30))
end

-- ---------------------------------------------------------------- the story

local Story = InputContainer:extend{
    name = "stui_wrapped",
    covers_fullscreen = true,
    r = nil,
}

function Story:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local r = self.r
    if (r.secs or 0) < 600 then
        self.cards = { "empty" }
    else
        self.cards = { "cover", "time", "finished" }
        if #r.long_haul > 0 then table.insert(self.cards, "long_haul") end
        if r.top then table.insert(self.cards, "top") end
        if #r.authors > 0 then table.insert(self.cards, "authors") end
        table.insert(self.cards, "habits")
        table.insert(self.cards, "persona")
        if r.highlights > 0 or r.notes > 0 or (r.words or 0) > 0 then table.insert(self.cards, "highlights") end
        table.insert(self.cards, "summary")
    end
    self.i = 1
    local all = function() return self.dimen end
    self.ges_events = {
        WTap = { GestureRange:new{ ges = "tap", range = all } },
        WSwipe = { GestureRange:new{ ges = "swipe", range = all } },
        WHold = { GestureRange:new{ ges = "hold", range = all } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } }, Next = { { Device.input.group.PgFwd } },
            Prev = { { Device.input.group.PgBack } } }
    end
end

function Story:hit(rect, fn) table.insert(self.hits, { rect = rect, fn = fn }) end

--- One card, with its frame: the bars along the top, the year, ✕.
function Story:paintCard(bb, id, for_picture)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local dark = id == "persona"
    local paper, ink = dark and BLACK or Look.PAPER, dark and WHITE or Look.INK
    bb:paintRect(0, 0, W, H, paper)
    local pad = S(24)
    local x, w = pad, W - 2 * pad
    local y = S(18)
    if not for_picture then
        -- progress bars, one per card
        local n = #self.cards
        local gap = S(5)
        local sw = math.floor((w - (n - 1) * gap) / n)
        for k = 1, n do
            local sx = x + (k - 1) * (sw + gap)
            bb:paintRect(sx, y, sw, S(6), ink)
            if k > self.i then bb:paintRect(sx + 1, y + 1, sw - 2, S(6) - 2, paper) end
        end
    end
    y = y + S(16)
    Look.label(bb, T(_("Wrapped · %1"), self.r.year), x, y, w, S(36), 11, { color = ink })
    if not for_picture then
        local kw = S(44)
        local rect
        if dark then
            Look.label(bb, "✕", x + w - kw, y, kw, S(36), 16, { align = "center", color = WHITE })
            rect = Geom:new{ x = x + w - kw - S(10), y = 0, w = kw + S(30), h = y + S(46) }
        else
            rect = Look.button(bb, x + w - kw, y, kw, S(36), "✕", { size = 14 })
            rect = Geom:new{ x = rect.x - S(10), y = 0, w = rect.w + S(30), h = rect.y + rect.h + S(10) }
        end
        self:hit(rect, function() self:onClose() end)
    end
    y = y + S(46)
    local foot = for_picture and S(10) or S(34)
    local ok, err = pcall(CARDS[id], self, bb, x, y, w, H - y - foot, for_picture)
    if not ok then logger.warn("ShelfTechUI: Wrapped card", id, err) end
    if not for_picture and id ~= "summary" then
        if self.i > 1 then Look.label(bb, _("‹ back"), x, H - S(30), w, S(22), 10, { color = dark and WHITE or Look.GRAY }) end
        Look.label(bb, self.i < #self.cards and _("tap for the next card ›") or "", x, H - S(30), w, S(22), 10,
            { align = "right", color = dark and WHITE or Look.GRAY })
    end
end

function Story:paintTo(bb, x, y)
    self.hits = {}
    self:paintCard(bb, self.cards[self.i])
end

function Story:go(i)
    self.i = math.max(1, math.min(#self.cards, i))
    UIManager:setDirty(self, "full")
end

local function inside(p, r) return p and r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end

function Story:onWTap(_, ges)
    for k = #(self.hits or {}), 1, -1 do
        local h = self.hits[k]
        if inside(ges.pos, h.rect) then h.fn() return true end
    end
    if ges.pos.x < Screen:getWidth() * 0.35 then self:onPrev() else self:onNext() end
    return true
end

function Story:onWSwipe(_, ges)
    local d = ges.direction
    if d == "south" or d == "north" then self:onClose()
    elseif d == "west" then self:onNext()
    elseif d == "east" then self:onPrev() end
    return true
end

function Story:onWHold() return true end
function Story:onNext() if self.i < #self.cards then self:go(self.i + 1) end return true end
function Story:onPrev() if self.i > 1 then self:go(self.i - 1) end return true end

function Story:onShow() UIManager:setDirty(self, "full") return true end
function Story:onCloseWidget() UIManager:setDirty(nil, "full") end
function Story:onClose() UIManager:close(self) return true end

M.Story = Story

-- ---------------------------------------------------------------- the picture

function M.savePicture(story)
    local W, H = Screen:getWidth(), Screen:getHeight()
    local bb = Blitbuffer.new(W, H, Screen.bb:getType())
    local saved_i = story.i
    local ok, err = pcall(function() story:paintCard(bb, "summary", true) end)
    story.hits = {}
    local dir
    pcall(function() dir = require("ui/widget/screenshoter"):getScreenshotDir() end)
    dir = dir or (require("datastorage"):getFullDataDir() .. "/screenshots")
    require("util").makePath(dir)
    local path = T("%1/wrapped-%2.png", dir, story.r.year)
    if ok then ok, err = pcall(function() bb:writePNG(path) end) end
    bb:free()
    story.i = saved_i
    if not ok then
        logger.warn("ShelfTechUI: Wrapped picture:", err)
        UIManager:show(InfoMessage:new{ text = _("The picture couldn't be saved."), timeout = 3 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = T(_("Saved as %1.\n\nUse it as your sleep screen?"), path),
        ok_text = _("Use it"),
        cancel_text = _("No"),
        ok_callback = function()
            G_reader_settings:saveSetting("screensaver_type", "document_cover")
            G_reader_settings:saveSetting("screensaver_document_cover", path)
            UIManager:show(InfoMessage:new{ text = _("It's your sleep screen now (Settings → Device → Screen → Sleep screen to change it)."), timeout = 4 })
        end,
    })
end

-- ---------------------------------------------------------------- open

M._busy = false

local function show(r)
    r.days_in_year = (os.date("*t").year == r.year) and tonumber(os.date("%j")) or 365
    UIManager:show(Story:new{ r = r })
end

--- Put the year together (a background process: seconds on a big library),
--- keep it, and show it. A past year's numbers are kept for good; this
--- year's are worked out again after six hours.
function M.open(year)
    year = year or os.date("*t").year
    if M._busy then return end
    Store.set("wrapped_opened_" .. year, true)
    local kept = Data.cached(year)
    local this_year = os.date("*t").year == year
    if kept and (not this_year or os.time() - (kept.at or 0) < 6 * 3600) then
        show(kept)
        return
    end
    local ffiutil = require("ffi/util")
    local ok, pid = pcall(ffiutil.runInSubProcess, function()
        local okC, r = pcall(Data.compute, year)
        if okC and r then Data.save(year, r) else logger.warn("ShelfTechUI: Wrapped failed:", r) end
    end)
    if not ok or not pid then
        -- no background process here: work it out now
        local okC, r = pcall(Data.compute, year)
        if okC and r then Data.save(year, r) show(r) end
        return
    end
    M._busy = true
    local msg = InfoMessage:new{ text = T(_("Putting your %1 together…"), year) }
    UIManager:show(msg)
    local waited = 0
    local function poll()
        if not ffiutil.isSubProcessDone(pid) and waited < 120 then
            waited = waited + 1
            UIManager:scheduleIn(0.5, poll)
            return
        end
        M._busy = false
        UIManager:close(msg)
        local r = Data.cached(year)
        if r and (r.at or 0) >= os.time() - 300 then
            show(r)
        else
            UIManager:show(InfoMessage:new{ text = _("Your year couldn't be put together. Is Reading statistics on (Tools → Reading statistics)?") })
        end
    end
    UIManager:scheduleIn(0.5, poll)
end

-- ---------------------------------------------------------------- the notification

local Note = InputContainer:extend{ name = "stui_wrapped_note", year = nil, again = false }

function Note:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.cw = W - 2 * S(40)
    self.ch = S(400)
    self.card = Geom:new{ x = S(40), y = math.floor((H - self.ch) / 2) - S(40), w = self.cw, h = self.ch }
    local all = function() return self.dimen end
    self.ges_events = { NTap = { GestureRange:new{ ges = "tap", range = all } } }
end

function Note:region()
    local c = self.card
    return Geom:new{ x = c.x, y = c.y, w = c.w + S(10), h = c.h + S(10) }
end

function Note:paintTo(bb)
    local c = self.card
    self.hits = {}
    Look.box(bb, c.x, c.y, c.w, c.h, { shadow = S(8) })
    local bh = S(34)
    Look.stripes(bb, c.x + Look.LINE, c.y + Look.LINE + S(6), c.w - 2 * Look.LINE, bh - S(12))
    local cap = _("Wrapped")
    local tw = Look.textWidth(Look.case(cap), 12) + S(20)
    bb:paintRect(c.x + math.floor((c.w - tw) / 2), c.y + Look.LINE + S(4), tw, bh - S(8), Look.PAPER)
    Look.label(bb, cap, c.x, c.y + Look.LINE + S(2), c.w, bh - S(4), 12, { align = "center" })
    bb:paintRect(c.x, c.y + bh, c.w, Look.LINE, Look.INK)
    local x, w = c.x + S(26), c.w - S(52)
    local y = c.y + bh + S(22)
    Look.label(bb, self.again and _("Still waiting for you") or _("Your year is ready"), x, y, w, S(22), 12, {})
    y = y + S(30)
    local _bw, h1 = big(bb, tostring(self.year), x, y, 40)
    y = y + h1
    local _bw2, h2 = big(bb, _("in books"), x, y, 40)
    y = y + h2 + S(12)
    wrap(bb, _("What you read, when you read, and the book that stayed with you. About a minute."), serifI(16), x, y, w, 3, S(24))
    local ky = c.y + c.h - S(80)
    local gap = S(14)
    local ow = math.floor((w - gap) * 0.6)
    local r1 = Look.button(bb, x, ky, ow, S(52), _("Open") .. " ›", { size = 14, on = true })
    local r2 = Look.button(bb, x + ow + gap, ky, w - ow - gap - Look.SHADOW_SMALL, S(52), _("Later"), { size = 14 })
    table.insert(self.hits, { rect = r1, fn = function() UIManager:close(self) M.open(self.year) end })
    table.insert(self.hits, { rect = r2, fn = function() UIManager:close(self) end })
end

function Note:onNTap(_, ges)
    for _i, h in ipairs(self.hits or {}) do
        if inside(ges.pos, h.rect) then h.fn() return true end
    end
    if not inside(ges.pos, self.card) then UIManager:close(self) end
    return true
end

function Note:onShow() UIManager:setDirty(self, function() return "ui", self:region() end) return true end
function Note:onCloseWidget()
    local r = self:region()
    UIManager:setDirty(nil, function() return "ui", r end)
end

M.Note = Note

local function readerOpen()
    local R = package.loaded["apps/reader/readerui"]
    return R and R.instance ~= nil
end

--- On home, from 1 December: this year's card, once. In January: last
--- year's, once more, if it was never opened. Only with an hour of reading
--- or more to wrap.
function M.maybeNotify(now)
    if Store.get("wrapped_notify") == false or readerOpen() then return false end
    local d = os.date("*t", now or os.time())
    local year, key, again
    if d.month == 12 then
        year, key = d.year, "wrapped_shown_" .. d.year
    elseif d.month == 1 then
        year, key, again = d.year - 1, "wrapped_reminded_" .. (d.year - 1), true
        if Store.get("wrapped_opened_" .. year) then return false end
    else
        return false
    end
    if Store.get(key) then return false end
    if Data.secondsIn(year) < 3600 then return false end
    Store.set(key, true)
    UIManager:show(Note:new{ year = year, again = again })
    return true
end

-- ---------------------------------------------------------------- Settings → Reading

function M.settingsItems()
    local this = os.date("*t").year
    return {
        {
            text = T(_("This year so far (%1)"), this),
            callback = function() M.open(this) end,
        },
        {
            text = T(_("Last year (%1)"), this - 1),
            enabled_func = function() return Data.secondsIn(this - 1) >= 600 end,
            callback = function() M.open(this - 1) end,
        },
        {
            text = _("Tell me in December"),
            description = _("On home from 1 December, once: your year is ready. If you haven't opened it by New Year, once more in January."),
            checked_func = function() return Store.get("wrapped_notify") ~= false end,
            callback = function() Store.set("wrapped_notify", Store.get("wrapped_notify") == false and true or false) end,
        },
    }
end

return M
