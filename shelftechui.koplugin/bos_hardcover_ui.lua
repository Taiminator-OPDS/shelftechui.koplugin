--[[
Hardcover's screens (the talking to Hardcover is bos_hardcover).

  M.open(tab)            the app: HOME (a dashboard: your goal, what you're
                         reading, friends, popular, genres and moods) ·
                         FRIENDS · READING · WANT · READ · EXPLORE (browse by
                         genre or mood), a search; or the sign-in screen
  M.browseTag(key, name) the app on the books with a genre or a mood
  M.openBook(book)       a book: your shelf and rating for it, the quotes
                         readers liked most, reviews, and the way to the store
  M.tab(bw, book, modal) the "Hardcover" tab of Bookshelf's book window
  M.rateDialog(title, cur, done)   five stars, by halves

All of it draws from what's already here and fetches in the background:
a tab shows "Loading…" until its answer comes, never a frozen screen.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local HC = require("bos_hardcover")
local Look = require("bos_look")
local Page = require("bos_page")
local UI = require("bos_ui")
local Screen = Device.screen
local S = Look.S
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = {}

local function tface(size, bold, italic)
    return Look.text(size, bold, italic) or (bold and UI.boldFace(size)) or (italic and UI.italicFace(size)) or UI.face(size)
end

local TABS = {
    { key = "home", text = _("Home") },
    { key = "friends", text = _("Friends") },
    { key = "reading", text = _("Reading"), status = 2 },
    { key = "want", text = _("Want") , status = 1 },
    { key = "read", text = _("Read"), status = 3 },
    { key = "explore", text = _("Explore") },
}
-- lists reached from Explore (a genre, a mood, Popular) or the search key:
-- shown under Explore, with a way back to it
local VIEWS = { search = true, popular = true, tag = true }

local STATUS_NAME = { [1] = _("Want to read"), [2] = _("Reading"), [3] = _("Read"), [4] = _("Paused"), [5] = _("Did not finish") }

local function notify(text)
    pcall(function() require("ui/widget/notification"):notify(text) end)
end

local function count(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return string.format("%.1fM", n / 1000000) end
    if n >= 1000 then return (string.format("%.1fk", n / 1000):gsub("%.0k", "k")) end
    return tostring(n)
end

-- ---------------------------------------------------------------- covers

local img_cache, img_order = {}, {}
local function imageAt(path, w, h)
    local key = path .. "@" .. w .. "x" .. h
    if img_cache[key] ~= nil then return img_cache[key] or nil end
    local ok, bb = pcall(function() return require("ui/renderimage"):renderImageFile(path, false, w, h) end)
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

local function freeImages()
    for _k, e in pairs(img_cache) do if e then pcall(function() e:free() end) end end
    img_cache, img_order = {}, {}
end

local function drawCover(bb, b, x, y, w, h)
    Look.box(bb, x, y, w, h, { shadow = Look.SHADOW_SMALL, border = math.max(1, S(1)) })
    local path = HC.coverPath(b)
    local img = path and imageAt(path, w - 2, h - 2)
    if img then
        bb:blitFrom(img, x + math.floor((w - img:getWidth()) / 2), y + math.floor((h - img:getHeight()) / 2),
            0, 0, img:getWidth(), img:getHeight())
        local d = math.max(1, S(1))
        bb:paintRect(x, y, w, d, Look.INK) bb:paintRect(x, y + h - d, w, d, Look.INK)
        bb:paintRect(x, y, d, h, Look.INK) bb:paintRect(x + w - d, y, d, h, Look.INK)
    else
        local fs = math.max(8, math.floor(w / 9))
        Page.wrap(bb, b.title or "", Look.serif(fs, true), x + S(6), y + S(8), w - S(12), 4, math.floor(fs * 1.5))
        if b.author and h > S(110) then
            Look.label(bb, b.author, x + S(6), y + h - S(22), w - S(12), S(16), math.max(7, math.floor(w / 14)), { color = Look.GRAY })
        end
    end
end

--- "★ 4.2" in small control text; returns its width.
local function ratingText(b)
    if not (b.rating and b.rating > 0) then return nil end
    return string.format("\u{2605} %.1f", b.rating)
end

-- ---------------------------------------------------------------- signing in

local function typeKey(done)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Hardcover key"),
        description = _("The API key from hardcover.app (Account → API). It's long: pasting it from a phone or a computer, through Transfer, is easier."),
        input = "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Connect"), is_enter_default = true, callback = function()
                local key = dlg:getInputText()
                UIManager:close(dlg)
                done(key)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

--- The sign-in screen's body. `st` is the page's sign-in state.
local function drawSignIn(self, bb, y, w)
    local x = self.pad
    local st = self.signin
    y = y + Page.wrap(bb, _("Your Hardcover shelves, what your friends are reading, and what readers say about a book. Books you read here go on your shelves by themselves."),
        Look.serif(16, false, true), x, y, w, 4, S(24), Look.GRAY) + S(16)
    if not HC.connected() then
        Look.box(bb, x, y, w - Look.SHADOW, S(110), { shadow = Look.SHADOW })
        Page.wrap(bb, _("Connect to Wi-Fi to sign in."), Look.serif(17, true), x + S(18), y + S(18), w - S(40), 2, S(26))
        local r = Look.button(bb, x + S(18), y + S(58), S(180), S(38), _("Wi-Fi"), { size = 13, on = true })
        self:hit(r, function()
            pcall(function()
                require("ui/network/manager"):runWhenOnline(function() if not self.closed then self:startSignIn() self:refresh("ui") end end)
            end)
        end)
        return
    end
    local card_h = S(270)
    Look.box(bb, x, y, w - Look.SHADOW, card_h, { shadow = Look.SHADOW })
    local q = S(190)
    local qx, qy = x + S(20), y + S(22)
    local tx = qx + q + S(22)
    local tw = x + w - Look.SHADOW - S(16) - tx
    local function qr(url)
        if st.qr_url ~= url then
            if st.qr then st.qr:free() end
            local ok, QRWidget = pcall(require, "ui/widget/qrwidget")
            st.qr = ok and QRWidget:new{ text = url, width = q, height = q } or nil
            st.qr_url = url
        end
        if st.qr then st.qr:paintTo(bb, qx, qy) end
    end
    if st.mode == "link" then
        -- a code to approve on hardcover.app/link
        if st.link then
            qr(st.link.qr)
            Look.label(bb, _("Scan, or go to"), tx, y + S(22), tw, S(20), 10, { color = Look.GRAY })
            Page.wrap(bb, (st.link.uri:gsub("^https?://", "")), Look.serif(19, true), tx, y + S(46), tw, 2, S(27))
            Look.label(bb, _("and enter"), tx, y + S(108), tw, S(20), 10, { color = Look.GRAY })
            local big = require("ui/widget/textwidget"):new{ text = st.link.code, face = Look.serif(28, true), fgcolor = BLACK }
            big:paintTo(bb, tx, y + S(130))
            big:free()
            Look.label(bb, st.note or _("Waiting for you to approve…"), tx, y + S(186), tw, S(20), 10, { color = Look.GRAY })
        else
            Page.wrap(bb, st.note or _("Asking Hardcover for a code…"), Look.serif(17, false, true), x + S(20), y + S(26), w - S(50), 4, S(26))
        end
    else
        -- an API key, pasted into Transfer's page
        local url = st.transfer_url
        if url then
            qr(url)
            Look.label(bb, _("1 · Scan, or open in a browser"), tx, y + S(22), tw, S(20), 10, { color = Look.GRAY })
            Page.wrap(bb, st.transfer_shown or url, Look.serif(16, true), tx, y + S(46), tw, 3, S(23))
            if st.transfer_code then
                Look.label(bb, T(_("Code %1"), st.transfer_code), tx, y + S(120), tw, S(20), 11)
            end
            Page.wrap(bb, _("2 · On that page, get a key from Hardcover and paste it."), Look.serif(14, false, true), tx, y + S(150), tw, 3, S(21), Look.GRAY)
            Look.label(bb, st.note or _("Waiting for the key…"), x + S(20), y + card_h - S(34), w - S(60), S(20), 10, { color = Look.GRAY })
        else
            Page.wrap(bb, st.note or _("Starting Transfer…"), Look.serif(17, false, true), x + S(20), y + S(26), w - S(50), 4, S(26))
        end
    end
    y = y + card_h + Look.SHADOW + S(18)
    local bw = math.floor((w - S(14)) / 2) - Look.SHADOW_SMALL
    local r1 = Look.button(bb, x, y, bw, S(42), _("Type the key here"), { size = 12 })
    self:hit(r1, function()
        typeKey(function(key)
            st.note = _("Checking the key…")
            self:refresh("ui")
            HC.setKey(key, function(user, why)
                if self.closed then return end
                if user then self:signedIn() else st.note = why self:refresh("ui") end
            end)
        end)
    end)
    if HC.clientId() then
        local other = st.mode == "link" and _("Use a key instead") or _("Use a link code")
        local r2 = Look.button(bb, x + bw + S(14) + Look.SHADOW_SMALL, y, bw, S(42), other, { size = 12 })
        self:hit(r2, function()
            st.mode = st.mode == "link" and "key" or "link"
            self:startSignIn()
            self:refresh("ui")
        end)
    end
end

-- ---------------------------------------------------------------- the app

local App = Page:extend{ name = "stui_hardcover", caption = _("Hardcover") }

function App:init()
    Page.init(self)
    self.data, self.err, self.loading, self.pg = {}, {}, {}, {}
    -- (opens on the dashboard; a tab asked for, from elsewhere, opens that)
    self.tab = self.tab or "home"
    self.signin = { mode = HC.clientId() and "link" or "key" }
    self.draw = function(page, bb, y, w) page:body(bb, y, w) end
    self.on_swipe = function(page, dir)
        if dir == "west" then page:turn(1)
        elseif dir == "east" then
            -- (on a list of Explore's first page: back to Explore)
            if VIEWS[page.tab] and (page.pg[page.tab] or 1) <= 1 then page:pick("explore") else page:turn(-1) end
        end
    end
    self.on_more = function(page, rect) page:more(rect) end
    self.on_close = function(page)
        HC.link.cancel()
        if page.signin.qr then page.signin.qr:free() end
        if page.transfer_started then pcall(function() require("bos_transfer").hardcover(nil) end) end
        freeImages()
        M.app = nil
    end
    if HC.signedIn() then self:load(self.tab) else self:startSignIn() end
end

function App:signedIn()
    HC.link.cancel()
    pcall(function() require("bos_transfer").hardcover(nil) end)
    local u = HC.user()
    notify(T(_("Hardcover: signed in as %1"), u and (u.name or u.username) or "?"))
    self.data, self.err, self.loading = {}, {}, {}
    self:load(self.tab)
    self:refresh("ui")
    -- recommendations (the store's row, FOR YOU) take Hardcover's from now on
    pcall(function() require("bos_online").refreshInBackground(true) end)
end

--- Begin (or begin again) the way of signing in that's chosen.
function App:startSignIn()
    local st = self.signin
    st.note, st.link, st.transfer_url = nil, nil, nil
    HC.link.cancel()
    if not HC.connected() then return end
    if st.mode == "link" then
        HC.link.start(function(link, why)
            if self.closed then return end
            if not link then st.note = why self:refresh("ui") return end
            st.link = link
            self:refresh("ui")
            local function poll()
                if self.closed or st.link ~= link or HC.signedIn() then return end
                HC.link.poll(function(what, arg)
                    if self.closed or st.link ~= link then return end
                    if what == "done" then return self:signedIn() end
                    if what == "over" then st.link, st.note = nil, arg self:refresh("ui") return end
                    UIManager:scheduleIn((HC.link.state and HC.link.state.every) or link.every, poll)
                end)
            end
            UIManager:scheduleIn(link.every, poll)
        end)
    else
        -- Transfer's page takes the key (it's long: pasted, not typed)
        local ok, err = pcall(function()
            local Transfer = require("bos_transfer")
            local started, why = Transfer.start()
            if not started then st.note = why return end
            self.transfer_started = true
            Transfer.hardcover(function(key, answer)
                HC.setKey(key, function(user, why2)
                    answer(user ~= nil, user and (user.name or user.username) or why2)
                    if self.closed then return end
                    if user then self:signedIn() else st.note = why2 self:refresh("ui") end
                end)
            end)
            st.transfer_url = Transfer.url(true, "hardcover")
            st.transfer_shown = Transfer.url(false, "hardcover")
            st.transfer_code = Transfer.code()
            if not st.transfer_url then st.note = _("No Wi-Fi address yet. Connect to Wi-Fi, or type the key here.") end
        end)
        if not ok then logger.warn("ShelfTechUI: Hardcover sign-in:", err) st.note = _("Transfer couldn't start. Type the key here.") end
    end
end

function App:load(tab, force)
    if self.loading[tab] then return end
    if self.data[tab] and not force then return end
    self.loading[tab] = true
    self.err[tab] = nil
    local asked_tag = self.tag_name
    local function got(list, why)
        self.loading[tab] = nil
        if self.closed then return end
        -- (a genre's books that come after another genre was picked: not these)
        if tab == "tag" and self.tag_name ~= asked_tag then return end
        if list then self.data[tab] = list else self.err[tab] = why end
        if list then
            local books = {}
            for _i, it in ipairs(list) do books[#books + 1] = it.book or it end
            HC.fetchCovers(books, function() if not self.closed and self:shows(tab) then self:refresh("ui") end end, 16)
        end
        if self:shows(tab) then self:refresh("ui") end
    end
    if force then
        HC.forget(tab == "friends" and "friends" or tab == "popular" and "trending" or tab == "tag" and "tag:"
            or tab == "explore" and "tags" or tab == "home" and "" or "shelf")
    end
    if tab == "home" then
        -- the dashboard: a bit of everything, each drawn when it comes
        self.loading[tab] = nil
        self.data.home = true
        for _i, t in ipairs({ "reading", "friends", "popular" }) do
            if force then self.data[t] = nil end
            self:load(t)
        end
        self:loadTags(force)
    elseif tab == "explore" then
        self.loading[tab] = nil
        self.data.explore = true
        if force then self.data.popular = nil end
        self:load("popular")
        self:loadTags(force)
    elseif tab == "tag" then
        HC.byTag(self.tag_key, self.tag_name, got)
    elseif tab == "friends" then
        -- the readers you follow, each with what they're on (bos_hardcover
        -- keeps it; `force` asks Hardcover again)
        HC.social(function(soc, why)
            if (soc.at or 0) == 0 and why then return got(nil, why) end
            local books = {}
            for _i, who in ipairs(soc.people) do
                local row = who.reading[1] or who.finished[1]
                if row then books[#books + 1] = row.book end
            end
            self.loading[tab] = nil
            if self.closed then return end
            self.data[tab] = soc.people
            HC.fetchCovers(books, function() if not self.closed and self:shows(tab) then self:refresh("ui") end end, 16)
            if self:shows(tab) then self:refresh("ui") end
        end, force)
    elseif tab == "popular" then HC.trending(got)
    elseif tab == "search" then
        if self.search_kind == "people" then
            HC.searchPeople(self.query or "", function(list, why)
                self.loading[tab] = nil
                if self.closed then return end
                if list then list.people = true self.data[tab] = list else self.err[tab] = why end
                if self.tab == tab then self:refresh("ui") end
            end)
        else
            HC.search(self.query or "", got)
        end
    else
        for _i, t in ipairs(TABS) do if t.key == tab then HC.shelf(t.status, got) end end
    end
    if not self.goal_asked then
        self.goal_asked = true
        HC.goal(function(g) if g and not self.closed then self.goal = g self:refresh("ui") end end)
    end
end

--- Is what `tab` holds on screen now (as the tab, or part of the dashboard
--- or Explore)?
function App:shows(tab)
    if self.tab == tab then return true end
    if self.tab == "home" then return tab == "reading" or tab == "friends" or tab == "popular" or tab == "tags" end
    if self.tab == "explore" then return tab == "popular" or tab == "tags" end
    return false
end

function App:loadTags(force)
    if (self.tags and not force) or self.tags_asked then return end
    self.tags_asked = true
    if force then HC.forget("tags") end
    HC.tags(function(t)
        self.tags_asked = nil
        if self.closed then return end
        self.tags = t
        if self:shows("tags") then self:refresh("ui") end
    end)
end

function App:pick(tab)
    self.tab = tab
    self:load(tab)
    self:refresh("ui")
end

--- The books with a genre or a mood (`key`: "genre" | "mood").
function App:showTag(key, name)
    if self.tag_key ~= key or self.tag_name ~= name then
        self.tag_key, self.tag_name = key, name
        self.data.tag, self.err.tag, self.loading.tag, self.pg.tag = nil, nil, nil, 1
    end
    self:pick("tag")
end

function App:turn(d)
    local pages = self.pages or 1
    local cur = self.pg[self.tab] or 1
    local nxt = math.max(1, math.min(pages, cur + d))
    if nxt ~= cur then self.pg[self.tab] = nxt self:refresh("ui") end
end

function App:search()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    local function go(kind)
        local q = dlg:getInputText()
        UIManager:close(dlg)
        if q and q:match("%S") then
            self.query, self.search_kind = q, kind
            self.data.search, self.err.search, self.pg.search = nil, nil, 1
            self:pick("search")
        end
    end
    dlg = InputDialog:new{
        title = _("Search Hardcover"),
        input = self.query or "",
        input_hint = _("A title or an author; or a reader's name"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("People"), callback = function() go("people") end },
            { text = _("Books"), is_enter_default = true, callback = function() go("books") end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function App:more(rect)
    local items = {}
    if HC.signedIn() then
        table.insert(items, { text = _("Refresh"), callback = function() self:load(self.tab, true) self:refresh("ui") end })
        table.insert(items, { text = _("Hardcover settings"), callback = function() M.settings() end })
        table.insert(items, { text = _("Sign out"), callback = function()
            HC.signOut()
            self.data, self.err, self.loading, self.goal, self.goal_asked = {}, {}, {}, nil, nil
            self.signin = { mode = HC.clientId() and "link" or "key" }
            self:startSignIn()
            self:refresh("ui")
        end })
    else
        table.insert(items, { text = _("Hardcover settings"), callback = function() M.settings() end })
    end
    UI.openList(items, rect)
end

function App:body(bb, y, w)
    local x = self.pad
    local H = Screen:getHeight()
    if not HC.signedIn() then return drawSignIn(self, bb, y, w) end
    -- [name · goal ...........................] [search]
    local u = HC.user() or {}
    local kh = S(40)
    local line = u.name or u.username or ""
    if self.goal and self.goal.goal > 0 then
        line = line .. "  ·  " .. T(_("%1 of %2 this year"), self.goal.progress, self.goal.goal)
    end
    Look.label(bb, line, x, y, w - S(56), kh, 12, { keep_case = true })
    local rs = Look.button(bb, x + w - S(46) - Look.SHADOW_SMALL, y, S(46), kh, nil, { paint = function(b2, bx, by, bw2, bh2, ink)
        pcall(UI.paintIcon, b2, UI.PLUGIN_DIR .. "icons/search.svg", bx + math.floor((bw2 - S(22)) / 2), by + math.floor((bh2 - S(22)) / 2), S(22), ink == WHITE)
    end })
    self:hit(rs, function() self:search() end)
    y = y + kh + S(12)
    -- tabs (Search joins them once there's been one)
    local cells = {}
    for _i, t in ipairs(TABS) do cells[#cells + 1] = { key = t.key, text = t.text } end
    -- (a search's results, a genre's or a mood's books and Popular are
    -- Explore's: it stays marked)
    local by_key = Look.segments(bb, x, y, w - Look.SHADOW_SMALL, S(38), cells, VIEWS[self.tab] and "explore" or self.tab,
        { size = 11, shadow = Look.SHADOW_SMALL })
    for key, r in pairs(by_key) do self:hit(r, function() if self.tab ~= key then self:pick(key) end end) end
    y = y + S(38) + Look.SHADOW_SMALL + S(16)

    local foot = S(52)
    local bottom = H - foot - S(8)
    if self.tab == "home" then self.pages = 1 return self:drawHome(bb, x, y, w, H - S(16)) end
    if self.tab == "explore" then self.pages = 1 return self:drawExplore(bb, x, y, w, H - S(16)) end
    if VIEWS[self.tab] then
        -- ‹ EXPLORE   what this list is ("Fantasy · genre", "“salt” · books")
        local what
        if self.tab == "tag" then
            what = T(self.tag_key == "mood" and _("%1 · mood · the most read first") or _("%1 · genre · the most read first"), self.tag_name or "")
        elseif self.tab == "search" then
            what = T(self.search_kind == "people" and _("“%1” · readers") or _("“%1” · books"), self.query or "")
        else
            what = _("Popular this month")
        end
        local bw = S(120)
        local rb = Look.button(bb, x, y - S(6), bw, S(34), "\u{2039} " .. _("Explore"), { size = 10 })
        self:hit(rb, function() self:pick("explore") end)
        Look.label(bb, what, x + bw + S(16), y - S(6), w - bw - S(16), S(34), 11, { keep_case = true })
        y = y + S(40)
    end
    local list = self.data[self.tab]
    if not list then
        local msg = self.err[self.tab] or _("Loading…")
        Page.wrap(bb, msg, Look.serif(17, false, true), x, y + S(10), w, 4, S(26), Look.GRAY)
        if self.err[self.tab] then
            local r = Look.button(bb, x, y + S(80), S(160), S(40), _("Try again"), { size = 13, on = true })
            self:hit(r, function() self:load(self.tab, true) self:refresh("ui") end)
        end
        self.pages = 1
        return
    end
    if #list == 0 then
        local empty = {
            friends = _("You don't follow anyone on Hardcover yet. Follow readers on hardcover.app and they show here, with what they're reading and how far along they are."),
            reading = _("Nothing on your Reading shelf. Open a book here and it's put there by itself."),
            want = _("Nothing on your Want to read shelf. Find a book in Popular or Search and add it."),
            read = _("Nothing on your Read shelf yet."),
            popular = _("Nothing to show just now."),
            tag = T(_("Hardcover has no books tagged “%1” yet."), self.tag_name or ""),
            search = self.search_kind == "people" and T(_("No reader found for “%1”. Try their username."), self.query or "")
                or T(_("Nothing found for “%1”."), self.query or ""),
        }
        Page.wrap(bb, empty[self.tab] or "", Look.serif(17, false, true), x, y + S(10), w, 5, S(26), Look.GRAY)
        self.pages = 1
        return
    end

    local pages
    if self.tab == "search" and list.people then
        -- readers found: a row each; a tap opens their page (to follow them)
        local rh = S(64)
        local per = math.max(1, math.floor((bottom - y) / rh))
        pages = math.max(1, math.ceil(#list / per))
        local cur = math.max(1, math.min(pages, self.pg[self.tab] or 1))
        self.pg[self.tab] = cur
        for k = 1, per do
            local who = list[(cur - 1) * per + k]
            if not who then break end
            local ry = y + (k - 1) * rh
            Page.wrap(bb, who.name or who.username or "?", tface(16, true), x, ry, w - S(150), 1, S(24))
            local facts = { "@" .. tostring(who.username or "") }
            if who.books then facts[#facts + 1] = T(_("%1 books"), count(who.books)) end
            if who.followers then facts[#facts + 1] = T(_("%1 followers"), count(who.followers)) end
            Look.label(bb, table.concat(facts, "  ·  "), x, ry + S(26), w - S(150), S(18), 9, { color = Look.GRAY, keep_case = true })
            if HC.isFollowing(who.id) then Look.label(bb, _("Following"), x + w - S(140), ry + S(8), S(116), S(24), 9, { align = "right" }) end
            Look.label(bb, "\u{203A}", x + w - S(20), ry + S(4), S(20), S(30), 16, { align = "right" })
            if k < per and list[(cur - 1) * per + k + 1] then bb:paintRect(x, ry + rh - S(8), w, 1, Look.LIGHT) end
            self:hit(Geom:new{ x = x, y = ry - S(4), w = w, h = rh - S(6) }, function() M.openProfile(who) end)
        end
    elseif self.tab == "friends" then
        -- one row a reader, those reading now first: the cover of what
        -- they're on, their name, the book and how far along they are
        local rh = S(100)
        local per = math.max(1, math.floor((bottom - y) / rh))
        pages = math.max(1, math.ceil(#list / per))
        local cur = math.max(1, math.min(pages, self.pg[self.tab] or 1))
        self.pg[self.tab] = cur
        for k = 1, per do
            local who = list[(cur - 1) * per + k]
            if not who then break end
            local ry = y + (k - 1) * rh
            M.friendRow(self, bb, who, x, ry, w, rh)
            if k < per and list[(cur - 1) * per + k + 1] then bb:paintRect(x, ry + rh - S(7), w, 1, Look.LIGHT) end
        end
    else
        -- a grid of covers
        local cols, gap = 4, S(16)
        local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
        local ch = math.floor(cw * 1.5)
        local label_h = S(56)
        local rh = ch + label_h + S(10)
        local rows = math.max(1, math.floor((bottom - y) / rh))
        local per = rows * cols
        pages = math.max(1, math.ceil(#list / per))
        local cur = math.max(1, math.min(pages, self.pg[self.tab] or 1))
        self.pg[self.tab] = cur
        for k = 1, per do
            local b = list[(cur - 1) * per + k]
            if not b then break end
            local cx = x + ((k - 1) % cols) * (cw + gap)
            local cy = y + math.floor((k - 1) / cols) * rh
            drawCover(bb, b, cx, cy, cw, ch)
            -- how far along (Reading), your stars (Read), readers' stars (the rest)
            local under
            if b.mine and b.mine.status == 2 and b.mine.pages and (b.mine.edition_pages or b.pages) then
                local total = b.mine.edition_pages or b.pages
                under = T(_("%1%"), math.floor(100 * b.mine.pages / math.max(1, total)))
            elseif b.mine and b.mine.rating then
                under = "\u{2605} " .. string.format("%.1f", b.mine.rating):gsub("%.0$", "")
            else
                under = ratingText(b)
            end
            local th = Page.wrap(bb, b.title, tface(12, true), cx, cy + ch + S(8), cw, 2, S(17))
            if under then Look.label(bb, under, cx, cy + ch + S(9) + th, cw, S(16), 9, { color = Look.GRAY }) end
            self:hit(Geom:new{ x = cx - S(4), y = cy - S(4), w = cw + S(8), h = rh - S(4) }, function() M.openBook(b) end)
        end
    end
    self.pages = pages
    if pages > 1 then
        local fh, kw = S(40), S(60)
        local fy = H - fh - S(14)
        local cur = self.pg[self.tab] or 1
        local rp = Look.button(bb, x, fy, kw, fh, "\u{2039}", { size = 16, enabled = cur > 1 })
        if cur > 1 then self:hit(rp, function() self:turn(-1) end) end
        local rn = Look.button(bb, x + w - kw - Look.SHADOW_SMALL, fy, kw, fh, "\u{203A}", { size = 16, enabled = cur < pages })
        if cur < pages then self:hit(rn, function() self:turn(1) end) end
        Look.label(bb, T(_("%1 / %2"), cur, pages), x + kw, fy, w - 2 * kw, fh, 12, { align = "center" })
    end
end

-- ---------------------------------------------------------------- home and explore

--- What goes under a cover: how far along (Reading), your stars (Read),
--- readers' stars (the rest).
local function underCover(b)
    if b.mine and b.mine.status == 2 and b.mine.pages and (b.mine.edition_pages or b.pages) then
        local total = b.mine.edition_pages or b.pages
        return T(_("%1%"), math.floor(100 * b.mine.pages / math.max(1, total)))
    elseif b.mine and b.mine.rating then
        return "\u{2605} " .. string.format("%.1f", b.mine.rating):gsub("%.0$", "")
    end
    return ratingText(b)
end

--- A row of `cols` covers with their titles; returns the height used.
function App:coverRow(bb, books, x, y, w, cols, max)
    local gap = S(14)
    local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
    local ch = math.floor(cw * 1.5)
    for k = 1, math.min(cols, max or cols, #books) do
        local b = books[k]
        local cx = x + (k - 1) * (cw + gap)
        drawCover(bb, b, cx, y, cw, ch)
        local th = Page.wrap(bb, b.title, tface(11, true), cx, y + ch + S(6), cw, 1, S(16))
        local under = underCover(b)
        if under then Look.label(bb, under, cx, y + ch + S(7) + th, cw, S(15), 8, { color = Look.GRAY }) end
        self:hit(Geom:new{ x = cx - S(4), y = y - S(4), w = cw + S(8), h = ch + S(44) }, function() M.openBook(b) end)
    end
    return ch + S(44)
end

--- A section's heading; a tap on it (with "All" on the right) goes to `to`.
function App:section(bb, text, x, y, w, to)
    Page.heading(bb, text, x, y, w, to and _("All") or nil)
    if to then
        self:hit(Geom:new{ x = x, y = y - S(8), w = w, h = S(38) }, function()
            if type(to) == "function" then to() else self:pick(to) end
        end)
    end
    return S(32)
end

--- Genres or moods as keys, wrapped onto lines (at most `max_lines`);
--- a tap opens their books. Returns the height used.
function App:tagKeys(bb, key, names, x, y, w, max_lines, size)
    local kh, gap = S(34), S(9)
    local cx, cy, line = x, y, 1
    size = size or 11
    for _i, name in ipairs(names or {}) do
        local label = key == "mood" and (name:sub(1, 1):upper() .. name:sub(2)) or name
        local cw = Look.textWidth(Look.case(label), size) + S(26)
        if cx > x and cx + cw > x + w - Look.SHADOW_SMALL then
            if line >= max_lines then break end
            cx, cy, line = x, cy + kh + gap, line + 1
        end
        local r = Look.button(bb, cx, cy, cw, kh, label, { size = size })
        self:hit(r, function() self:showTag(key, name) end)
        cx = cx + cw + gap
    end
    return (cy - y) + kh + Look.SHADOW_SMALL
end

--- The dashboard: your goal, what you're reading, what your friends are
--- reading, this month's popular books and genres and moods to browse,
--- as many of them as the page has room for.
function App:drawHome(bb, x, y, w, bottom)
    -- your goal: "12 of 30 books in 2026", a bar, and how you're doing
    if self.goal and self.goal.goal > 0 then
        local g = self.goal
        local gh = S(58)
        Look.box(bb, x, y, w - Look.SHADOW_SMALL, gh, { shadow = Look.SHADOW_SMALL })
        local metric = g.metric == "pages" and _("pages") or _("books")
        local frac = math.min(1, g.progress / math.max(1, g.goal))
        local t = os.date("*t")
        local due = math.floor(g.goal * (t.yday / 365) + 0.5)
        local note = g.progress >= g.goal and _("Done!") or (g.progress >= due and _("On track") or T(_("%1 behind"), due - g.progress))
        Look.label(bb, T(_("%1 of %2 %3 in %4"), g.progress, g.goal, metric, os.date("%Y")), x + S(14), y + S(6), w - S(150), S(22), 12, { keep_case = true })
        Look.label(bb, T(_("%1%"), math.floor(frac * 100)) .. "  ·  " .. note, x + w - S(200), y + S(6), S(176), S(22), 10, { align = "right" })
        Look.slimTrack(bb, x + S(14), y + S(36), w - S(30) - Look.SHADOW_SMALL, S(10), frac)
        y = y + gh + Look.SHADOW_SMALL + S(16)
    end
    local function room(h) return y + h <= bottom end
    local cols = 6
    local cw = math.floor((w - (cols - 1) * S(14) - Look.SHADOW_SMALL) / cols)
    local row_h = math.floor(cw * 1.5) + S(44) + S(32) + S(14)
    -- (genres and moods always get their two lines, at the end)
    local tags = self.tags
    local tags_h = tags and (S(32) + 2 * S(43) + S(10)) or 0
    -- what you're reading
    local reading = self.data.reading
    if room(row_h + tags_h) then
        y = y + self:section(bb, _("Continue reading"), x, y, w, "reading")
        if reading and #reading > 0 then
            y = y + self:coverRow(bb, reading, x, y, w, cols) + S(14)
        else
            local msg = reading and _("Nothing on your Reading shelf. Books you open here go there by themselves.")
                or self.err.reading or _("Loading…")
            y = y + Page.wrap(bb, msg, Look.serif(14, false, true), x, y, w, 2, S(22), Look.GRAY) + S(18)
        end
    end
    -- friends reading now (those who are, first)
    local friends = self.data.friends
    local fr_h = S(86)
    if friends and #friends > 0 and room(S(32) + fr_h + tags_h) then
        y = y + self:section(bb, _("Friends reading"), x, y, w, "friends")
        local shown = 0
        for _i, who in ipairs(friends) do
            if shown >= 2 or not room(fr_h + tags_h) then break end
            if who.reading[1] or shown == 0 then
                M.friendRow(self, bb, who, x, y, w, fr_h)
                y = y + fr_h
                shown = shown + 1
            end
        end
        y = y + S(6)
    end
    -- this month's popular books, when there's room for them too
    local popular = self.data.popular
    if popular and #popular > 0 and room(row_h + tags_h) then
        y = y + self:section(bb, _("Popular this month"), x, y, w, function() self:pick("popular") end)
        y = y + self:coverRow(bb, popular, x, y, w, cols) + S(14)
    end
    -- genres and moods: a line of each, all of them on Explore
    if tags and room(tags_h) then
        y = y + self:section(bb, _("Browse by genre and mood"), x, y, w, "explore")
        y = y + self:tagKeys(bb, "genre", tags.genre, x, y, w, 1) + S(10)
        self:tagKeys(bb, "mood", tags.mood, x, y, w, 1)
    end
end

--- Explore: every genre and mood to browse by, and this month's popular books.
function App:drawExplore(bb, x, y, w, bottom)
    local tags = self.tags
    if not tags then
        Page.wrap(bb, _("Loading…"), Look.serif(17, false, true), x, y + S(10), w, 2, S(26), Look.GRAY)
        return
    end
    Page.wrap(bb, _("Books by what readers on Hardcover tag them with, the most read first."),
        Look.serif(14, false, true), x, y, w, 2, S(22), Look.GRAY)
    y = y + S(30)
    y = y + self:section(bb, _("Genres"), x, y, w)
    y = y + self:tagKeys(bb, "genre", tags.genre, x, y, w, 5) + S(18)
    y = y + self:section(bb, _("Moods"), x, y, w)
    y = y + self:tagKeys(bb, "mood", tags.mood, x, y, w, 3) + S(18)
    local popular = self.data.popular
    local cols = 6
    local cw = math.floor((w - (cols - 1) * S(14) - Look.SHADOW_SMALL) / cols)
    if popular and #popular > 0 and y + S(32) + math.floor(cw * 1.5) + S(44) <= bottom then
        y = y + self:section(bb, _("Popular this month"), x, y, w, function() self:pick("popular") end)
        self:coverRow(bb, popular, x, y, w, cols)
    end
end

--- The app, on the books with a genre or a mood.
function M.browseTag(key, name)
    local app = M.open()
    if app and HC.signedIn() then app:showTag(key, name) end
    return app
end

function M.open(tab)
    if M.app and not M.app.closed then
        if tab and HC.signedIn() then M.app:pick(tab) end
        return M.app
    end
    M.app = App:new{ tab = tab }
    M.app:show()
    if not M.pruned then
        M.pruned = true
        UIManager:scheduleIn(20, HC.prune)
        UIManager:scheduleIn(8, function() pcall(HC.shrinkOld) end)
    end
    return M.app
end

-- ---------------------------------------------------------------- readers

local function stars(r) return "\u{2605} " .. (string.format("%.1f", r):gsub("%.0$", "")) end

--- "42% · page 130" for a book someone is in the middle of.
local function howFar(row)
    local parts = {}
    if row.percent then parts[#parts + 1] = T(_("%1%"), row.percent) end
    if row.page and row.page > 0 then parts[#parts + 1] = T(_("page %1"), row.page) end
    return #parts > 0 and table.concat(parts, "  ·  ") or nil
end

--- One reader, as a row of a friends list (the app's Friends tab): a dot
--- that's filled while they're reading, their name, what they're on and
--- how far along. A tap opens their page.
function M.friendRow(host, bb, who, x, y, w, rh)
    local row = who.reading[1]
    local last = not row and who.finished[1]
    local book = (row or last or {}).book
    local ch = rh - S(18)
    local cw = math.floor(ch / 1.5)
    if book then drawCover(bb, book, x, y, cw, ch) else Look.box(bb, x, y, cw, ch, { border = math.max(1, S(1)) }) end
    local tx = x + cw + S(16)
    local tw = w - cw - S(16) - S(24)
    -- ● Name                                   ›
    local d = S(10)
    if row then Look.disc(bb, tx + math.floor(d / 2), y + S(11), math.floor(d / 2), BLACK)
    else
        Look.disc(bb, tx + math.floor(d / 2), y + S(11), math.floor(d / 2), BLACK)
        Look.disc(bb, tx + math.floor(d / 2), y + S(11), math.floor(d / 2) - math.max(1, S(1.5)), WHITE)
    end
    Page.wrap(bb, who.name or who.username or "?", tface(15, true), tx + d + S(8), y, tw - d - S(8), 1, S(22))
    Look.label(bb, "\u{203A}", x + w - S(20), y + S(20), S(20), S(30), 16, { align = "right" })
    if row then
        Page.wrap(bb, row.book.title, Look.serif(14, false, true), tx, y + S(26), tw, 1, S(21))
        local far = howFar(row)
        if row.percent then
            Look.slimTrack(bb, tx, y + S(56), math.min(tw, S(220)), S(10), row.percent / 100)
            if far then Look.label(bb, far, tx + math.min(tw, S(220)) + S(12), y + S(50), tw - S(232), S(20), 9, { color = Look.GRAY }) end
        else
            Look.label(bb, far or _("Reading"), tx, y + S(52), tw, S(18), 9, { color = Look.GRAY })
        end
    elseif last then
        Page.wrap(bb, last.book.title, Look.serif(14, false, true), tx, y + S(26), tw, 1, S(21), Look.GRAY)
        Look.label(bb, _("Finished") .. (last.rating and ("  ·  " .. stars(last.rating)) or ""), tx, y + S(52), tw, S(18), 9, { color = Look.GRAY })
    else
        Look.label(bb, _("Nothing lately"), tx, y + S(28), tw, S(18), 9, { color = Look.GRAY })
    end
    host:hit(Geom:new{ x = x, y = y, w = w, h = rh - S(8) }, function() M.openProfile(who) end)
end

--- A reader's page: what they're reading and how far, what they finished
--- lately, their counts, and the way to their figures (Insights).
function M.openProfile(who)
    local o = { who = who }
    local page
    page = Page:new{ caption = _("Reader"),
        draw = function(self, bb, y, w)
            local x = self.pad
            local u = o.full or o.who
            local H = Screen:getHeight()
            y = y + Page.wrap(bb, u.name or u.username or "?", Look.serif(22, true), x, y, w - S(150), 1, S(32))
            if u.username then Look.label(bb, "@" .. u.username, x, y, w - S(150), S(18), 10, { color = Look.GRAY, keep_case = true }) y = y + S(22) end
            -- [FIGURES ›]: their reading in numbers
            local rs = Look.button(bb, x + w - S(140) - Look.SHADOW_SMALL, y - S(52), S(140), S(40), _("Insights"), { size = 12 })
            self:hit(rs, function() require("bos_insights_app").open({ id = u.id, name = u.name or u.username }) end)
            -- [FOLLOW] / [✓ FOLLOWING] (a tap on Following stops)
            local following = HC.isFollowing(u.id)
            local fl = o.following_busy and _("…") or (following and ("\u{2713} " .. _("Following")) or _("Follow"))
            local rf = Look.button(bb, x + w - S(140) - Look.SHADOW_SMALL, y - S(52) + S(40) + Look.SHADOW_SMALL + S(8), S(140), S(36), fl,
                { size = 11, on = not following and not o.following_busy })
            self:hit(rf, function()
                if o.following_busy then return end
                local function send(on)
                    o.following_busy = true
                    self:refresh("ui")
                    HC.follow(u.id, on, function(ok, why)
                        o.following_busy = nil
                        if ok then notify(on and T(_("Following %1"), u.name or u.username) or T(_("No longer following %1"), u.name or u.username))
                        else notify(why or _("Hardcover didn't take that.")) end
                        if M.app and not M.app.closed then M.app.data.friends = nil M.app:load(M.app.tab) M.app:refresh("ui") end
                        if not self.closed then self:refresh("ui") end
                    end)
                end
                if not following then return send(true) end
                local ButtonDialog = require("ui/widget/buttondialog")
                local dlg
                dlg = ButtonDialog:new{ title = T(_("Stop following %1?"), u.name or u.username), title_align = "center",
                    buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                        { text = _("Stop following"), callback = function() UIManager:close(dlg) send(false) end } } } }
                UIManager:show(dlg)
            end)
            local facts = {}
            if u.books then facts[#facts + 1] = T(_("%1 books"), count(u.books)) end
            if u.want then facts[#facts + 1] = T(_("%1 to read"), count(u.want)) end
            if u.followers then facts[#facts + 1] = T(_("%1 followers"), count(u.followers)) end
            if #facts > 0 then Look.label(bb, table.concat(facts, "  ·  "), x, y, w - S(160), S(20), 10) y = y + S(26) end
            if u.bio then y = y + Page.wrap(bb, u.bio, Look.serif(13, false, true), x, y, w - S(160), 2, S(20), Look.GRAY) + S(6) end
            y = math.max(y, self.pad + S(118))
            y = y + S(8)
            if o.err and not o.full then
                Page.wrap(bb, o.err, Look.serif(15, false, true), x, y, w, 3, S(23), Look.GRAY)
                return
            end
            -- READING NOW
            local reading = u.reading or {}
            Page.heading(bb, #reading > 0 and _("Reading now") or _("Not reading anything just now"), x, y, w)
            y = y + S(30)
            local rh = S(86)
            for k = 1, math.min(#reading, 3) do
                local row = reading[k]
                local ch = rh - S(14)
                local cw = math.floor(ch / 1.5)
                drawCover(bb, row.book, x, y, cw, ch)
                local tx, tw = x + cw + S(16), w - cw - S(16)
                Page.wrap(bb, row.book.title, Look.serif(15, true), tx, y, tw, 1, S(22))
                if row.book.author then Page.wrap(bb, row.book.author, Look.serif(12, false, true), tx, y + S(22), tw, 1, S(18), Look.GRAY) end
                local far = howFar(row)
                if row.percent then
                    Look.slimTrack(bb, tx, y + S(50), math.min(tw, S(240)), S(10), row.percent / 100)
                    if far then Look.label(bb, far, tx + math.min(tw, S(240)) + S(12), y + S(44), tw - S(252), S(20), 9, { color = Look.GRAY }) end
                elseif far then
                    Look.label(bb, far, tx, y + S(46), tw, S(18), 9, { color = Look.GRAY })
                end
                self:hit(Geom:new{ x = x, y = y, w = w, h = rh - S(6) }, function() M.openBook(row.book) end)
                y = y + rh
            end
            y = y + S(6)
            -- RECENTLY FINISHED: covers with their stars
            local done = u.finished or {}
            if #done > 0 then
                Page.heading(bb, _("Finished lately"), x, y, w)
                y = y + S(30)
                local cols, gap = 5, S(14)
                local cw = math.floor((w - (cols - 1) * gap - Look.SHADOW_SMALL) / cols)
                local ch = math.floor(cw * 1.5)
                local rowh = ch + S(34)
                local rows = math.max(1, math.floor((H - y - S(10)) / rowh))
                for k = 1, math.min(#done, rows * cols) do
                    local row = done[k]
                    local cx = x + ((k - 1) % cols) * (cw + gap)
                    local cy = y + math.floor((k - 1) / cols) * rowh
                    drawCover(bb, row.book, cx, cy, cw, ch)
                    if row.rating then Look.label(bb, stars(row.rating), cx, cy + ch + S(6), cw, S(16), 9, { color = Look.GRAY }) end
                    self:hit(Geom:new{ x = cx - S(4), y = cy - S(4), w = cw + S(8), h = rowh - S(2) }, function() M.openBook(row.book) end)
                end
            elseif not o.full then
                Look.label(bb, _("Loading…"), x, y, w, S(22), 10, { color = Look.GRAY })
            end
        end }
    page:show()
    local function covers(u)
        local books = {}
        for _i, r in ipairs(u.reading or {}) do books[#books + 1] = r.book end
        for _i, r in ipairs(u.finished or {}) do books[#books + 1] = r.book end
        HC.fetchCovers(books, function() if not page.closed then page:refresh("ui") end end, 16)
    end
    covers(who)
    HC.profile(who.id, function(full, why)
        if page.closed then return end
        if full then o.full = full covers(full) else o.err = why end
        page:refresh("ui")
    end)
    return page
end

--- Send this device's reading history to Hardcover (asked first, with the
--- numbers): finished books with their dates, books in progress with how
--- far. See bos_hardcover.sendHistory for what is and isn't touched.
function M.sendHistory()
    if not HC.signedIn() then notify(_("Sign in to Hardcover first.")) return end
    local list, done_n, going_n = {}, 0, 0
    pcall(function()
        local L = require("bos_recs").library()
        local Repo = require("lib/bookshelf_book_repository")
        for _i, b in ipairs(L and L.books or {}) do
            local done = b.status == "complete"
            local pct = tonumber(b.pct)
            if b.filepath and b.title and (done or (pct and pct > 0.02)) and not (HC.linkFor(b.filepath) or {}).status then
                local on
                if done then pcall(function() on = Repo.finishedOn and Repo.finishedOn(b.filepath) end) end
                on = type(on) == "string" and on:match("^%d%d%d%d%-%d%d%-%d%d") or nil
                list[#list + 1] = { file = b.filepath, title = b.title, author = b.authors and b.authors[1] or nil,
                    done = done, finished_on = on, percent = pct }
                if done then done_n = done_n + 1 else going_n = going_n + 1 end
            end
        end
    end)
    if #list == 0 then
        notify(_("Nothing to send: every book you've read here is on Hardcover already."))
        return
    end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    dlg = ButtonDialog:new{
        title = T(_("Send to Hardcover: %1 finished, %2 in progress?\nOnly books Hardcover has under the same title and author. A book already on your shelves there is left as it is."), done_n, going_n),
        title_align = "center",
        buttons = { {
            { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
            { text = _("Send"), callback = function()
                UIManager:close(dlg)
                notify(_("Sending your reading history… you can carry on."))
                HC.sendHistory(list, function(out, why)
                    if not out then notify(why or _("Hardcover didn't take it.")) return end
                    local msg = T(_("Hardcover: %1 added, %2 already there, %3 not found."), out.sent, out.already, out.unmatched)
                    if (out.left or 0) > 0 then msg = msg .. " " .. T(_("%1 more: send again."), out.left) end
                    notify(msg)
                    if M.app and not M.app.closed then M.app.data = {} M.app:load(M.app.tab) M.app:refresh("ui") end
                end)
            end },
        } },
    }
    UIManager:show(dlg)
end

-- ---------------------------------------------------------------- five stars

--- Your rating, by halves: [−] ★★★★☆ 4 [+], No rating, Save.
function M.rateDialog(title, current, done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local value = current or 0
    local dlg
    local function show()
        if dlg then UIManager:close(dlg) end
        -- (five places, spaced: in the theme's fonts the stars come from a
        -- fallback font, wider than a letter, and touching ones overlapped)
        local stars = _("No rating")
        if value > 0 then
            local cells = {}
            for i = 1, 5 do
                cells[i] = value >= i and "\u{2605}" or (value >= i - 0.5 and "\u{00BD}" or "\u{2606}")
            end
            stars = table.concat(cells, "  ") .. "   " .. (string.format("%.1f", value):gsub("%.0$", ""))
        end
        dlg = ButtonDialog:new{
            title = title,
            title_align = "center",
            buttons = {
                {
                    { text = "\u{2212}", enabled = value > 0, callback = function() value = math.max(0, value - 0.5) show() end },
                    { text = stars, enabled = false },
                    { text = "+", enabled = value < 5, callback = function() value = math.min(5, value + 0.5) show() end },
                },
                {
                    { text = "1", callback = function() value = 1 show() end },
                    { text = "2", callback = function() value = 2 show() end },
                    { text = "3", callback = function() value = 3 show() end },
                    { text = "4", callback = function() value = 4 show() end },
                    { text = "5", callback = function() value = 5 show() end },
                },
                {
                    { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                    { text = _("Save"), is_enter_default = true, callback = function() UIManager:close(dlg) done(value) end },
                },
            },
        }
        UIManager:show(dlg)
    end
    show()
end

-- ---------------------------------------------------------------- a book

--- What a book's body draws; shared by the book page and the book
--- window's tab. `o`: { book (as known so far), full (once fetched), err,
--- section, pg, compact }.
local function drawBook(host, bb, x, y, w, bottom, o)
    local b = o.full or o.book
    local hit = function(r, fn) host:hit(r, fn) end
    -- the cover, and beside it what the book is
    local cw = o.compact and S(92) or S(128)
    local ch = math.floor(cw * 1.5)
    drawCover(bb, b, x, y, cw, ch)
    local tx = x + cw + S(18)
    local tw = w - cw - S(18)
    local ty = y
    ty = ty + Page.wrap(bb, b.title or "", Look.serif(o.compact and 18 or 21, true), tx, ty, tw, 3, o.compact and S(25) or S(29)) + S(2)
    if b.author then ty = ty + Page.wrap(bb, b.author, Look.serif(14, false, true), tx, ty, tw, 1, S(22), Look.GRAY) end
    local facts = {}
    if b.year then facts[#facts + 1] = tostring(b.year) end
    if b.pages then facts[#facts + 1] = T(_("%1 pages"), b.pages) end
    if #facts > 0 then Look.label(bb, table.concat(facts, "  ·  "), tx, ty + S(2), tw, S(20), 10, { color = Look.GRAY }) ty = ty + S(24) end
    if b.rating and b.rating > 0 then
        Look.label(bb, T(_("%1  ·  %2 ratings  ·  %3 readers"), ratingText(b), count(b.ratings), count(b.readers)), tx, ty, tw, S(20), 10)
    end
    y = y + ch + Look.SHADOW_SMALL + S(14)

    -- your shelf for it: [WANT TO READ] [READING] [READ]
    local mine = b.mine
    local cells = {
        { key = 1, text = STATUS_NAME[1] }, { key = 2, text = STATUS_NAME[2] }, { key = 3, text = STATUS_NAME[3] },
    }
    local by = Look.segments(bb, x, y, w - Look.SHADOW_SMALL, S(40), cells, mine and mine.status or nil,
        { size = 11, shadow = Look.SHADOW_SMALL, pressed = o.setting })
    for key, r in pairs(by) do
        hit(r, function()
            if (mine and mine.status == key) or o.setting then return end
            o.setting = key
            host:redraw()
            HC.setStatus(b.id, key, function(entry, why)
                o.setting = nil
                if entry then
                    b.mine = b.mine or {}
                    b.mine.id, b.mine.status = entry.id, entry.status
                    if o.book ~= b then o.book.mine = b.mine end
                    notify(T(_("Hardcover: %1"), STATUS_NAME[key]))
                    if o.on_change then o.on_change(b) end
                else
                    notify(why or _("Hardcover didn't take that."))
                end
                host:redraw()
            end)
        end)
    end
    y = y + S(40) + Look.SHADOW_SMALL + S(10)
    -- your stars (once it's on a shelf)
    if mine and mine.id then
        Look.label(bb, _("Your rating"), x, y, S(120), S(30), 10, { color = Look.GRAY })
        local _r, sw = Page.stars(bb, x + S(120), y + S(4), S(22), mine.rating or 0)
        local all = Geom:new{ x = x, y = y - S(4), w = S(120) + sw + S(10), h = S(38) }
        hit(all, function()
            M.rateDialog(b.title or "", mine.rating, function(v)
                HC.rate(mine.id, v, b.id, function(entry, why)
                    if entry then mine.rating = entry.rating notify(_("Hardcover: rating saved")) else notify(why or _("Hardcover didn't take that.")) end
                    host:redraw()
                end)
            end)
        end)
        if mine.rating then
            Look.label(bb, (string.format("%.1f", mine.rating):gsub("%.0$", "")), x + S(120) + sw + S(12), y, S(60), S(30), 11)
        end
        -- [REMOVE]: off your shelves altogether (added by mistake)
        local rw = S(96)
        local rr = Look.button(bb, x + w - rw - Look.SHADOW_SMALL, y - S(1), rw, S(30), o.removing and _("…") or _("Remove"), { size = 10 })
        hit(rr, function()
            if o.removing then return end
            local ButtonDialog = require("ui/widget/buttondialog")
            local dlg
            dlg = ButtonDialog:new{
                title = T(_("Take “%1” off your Hardcover shelves?\nYour rating, dates and progress for it there go too. The book on this device isn't touched."), b.title or ""),
                title_align = "center",
                buttons = { { { text = _("Cancel"), callback = function() UIManager:close(dlg) end },
                    { text = _("Remove"), callback = function()
                        UIManager:close(dlg)
                        o.removing = true
                        host:redraw()
                        HC.removeBook(mine.id, b.id, function(ok, why)
                            o.removing = nil
                            if ok then
                                b.mine = nil
                                if o.book ~= b then o.book.mine = nil end
                                notify(_("Hardcover: removed from your shelves"))
                                if o.on_change then o.on_change(b) end
                            else
                                notify(why or _("Hardcover didn't take that."))
                            end
                            host:redraw()
                        end)
                    end } } } }
            UIManager:show(dlg)
        end)
        y = y + S(40)
    end
    -- the readers you follow who have it: "Ana 42%  ·  Tomás ★ 5" (a tap on
    -- a name opens their page)
    local also = HC.friendsWith(b.title, b.id)
    if also and #also > 0 then
        local lx = x + Look.label(bb, _("Friends"), x, y, S(120), S(26), 10, { color = Look.GRAY }) + S(12)
        for k = 1, math.min(#also, 3) do
            local e = also[k]
            local text = (e.who.name or e.who.username or "?") .. "  "
                .. (e.status == 2 and (e.percent and T(_("%1%"), e.percent) or _("reading")) or (e.rating and stars(e.rating) or _("read")))
            local tw2 = Look.textWidth(text, 10) + S(16)
            if lx + tw2 > x + w then break end
            Look.box(bb, lx, y + S(1), tw2, S(24), { border = math.max(1, S(1)) })
            Look.label(bb, text, lx, y + S(1), tw2, S(24), 10, { align = "center", keep_case = true })
            hit(Geom:new{ x = lx - S(3), y = y - S(5), w = tw2 + S(6), h = S(36) }, function() M.openProfile(e.who) end)
            lx = lx + tw2 + S(8)
        end
        y = y + S(34)
    end
    if o.err then
        Page.wrap(bb, o.err, Look.serif(15, false, true), x, y + S(6), w, 3, S(23), Look.GRAY)
        return
    end
    if not o.full then
        Look.label(bb, _("Loading…"), x, y + S(6), w, S(24), 11, { color = Look.GRAY })
        return
    end

    -- ABOUT · QUOTES · REVIEWS
    local full = o.full
    local secs = { { key = "about", text = _("About") },
        { key = "quotes", text = #full.quotes > 0 and T(_("Quotes %1"), #full.quotes) or _("Quotes") },
        { key = "reviews", text = #full.reviews > 0 and T(_("Reviews %1"), #full.reviews) or _("Reviews") } }
    o.section = o.section or "about"
    local chips = Page.chips(bb, secs, x, y, w, 10, { [o.section] = true })
    for i, r in ipairs(chips) do
        hit(Geom:new{ x = r.x - S(3), y = r.y - S(6), w = r.w + S(6), h = r.h + S(12) }, function()
            o.section, o.pg = secs[i].key, 1
            host:redraw()
        end)
    end
    y = y + S(26) + S(14)
    local foot = S(48)
    local room = bottom - y - foot
    o.pg = o.pg or 1
    local pages = 1
    if o.section == "about" then
        -- its genres and moods (as readers tagged it): a tap shows more books
        -- with it, in the app
        local tags = {}
        for k, g in ipairs(full.genres or {}) do if k <= 4 then tags[#tags + 1] = { text = g, key = "genre", name = g } end end
        for k, m in ipairs(full.moods or {}) do if k <= 3 then tags[#tags + 1] = { text = m, key = "mood", name = m } end end
        if #tags > 0 then
            -- (one line: as many as fit)
            local rects = Page.chips(nil, tags, x, y, w, 9)
            local keep = {}
            for i, r in ipairs(rects) do if r.y == y then keep[#keep + 1] = tags[i] end end
            rects = Page.chips(bb, keep, x, y, w, 9)
            for i, r in ipairs(rects) do
                local t = keep[i]
                hit(Geom:new{ x = r.x - S(3), y = r.y - S(6), w = r.w + S(6), h = r.h + S(12) }, function()
                    -- (the book's own page closes: the app is under it)
                    if host.draw and host.onClose then pcall(function() host:onClose() end) end
                    M.browseTag(t.key, t.name)
                end)
            end
            y = y + S(26) + S(12)
            room = bottom - y - foot
        end
        local text = (full.description and full.description ~= "") and full.description or _("Hardcover has no description for this book.")
        text = text:gsub("<[^>]+>", ""):gsub("\r", "")
        -- by the page: as many lines as fit, then the next page
        local lh = S(24)
        local lines = math.max(3, math.floor(room / lh))
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local tb = TextBoxWidget:new{ text = text, face = Look.serif(15), width = w, height = lines * lh, line_height = 0.3, alignment = "left" }
        pcall(function()
            pages = math.max(1, tb.virtual_line_num and math.ceil(#(tb.vertical_string_list or {}) / math.max(1, tb.lines_per_page or lines)) or 1)
            for _i = 2, math.min(o.pg, pages) do tb:scrollDown() end
        end)
        o.pg = math.min(o.pg, pages)
        tb:paintTo(bb, x, y)
        tb:free()
    else
        local items = o.section == "quotes" and full.quotes or full.reviews
        if #items == 0 then
            Page.wrap(bb, o.section == "quotes" and _("No one has shared a quote from this book yet. Yours can be the first: highlight a passage while reading and choose Hardcover.")
                or _("No reviews without spoilers yet."), Look.serif(15, false, true), x, y, w, 4, S(23), Look.GRAY)
        else
            -- as many as fit on a page, each whole
            local face = o.section == "quotes" and Look.serif(15, false, true) or Look.serif(14)
            local lh = S(23)
            local max_lines = math.max(3, math.floor((room - S(30)) / lh))
            local starts, yy, i = { 1 }, 0, 1
            while i <= #items do
                local h = math.min(Page.wrap(nil, items[i].text, face, 0, 0, w - S(16), nil, nil), max_lines * lh) + S(34)
                if yy > 0 and yy + h > room then starts[#starts + 1] = i yy = 0 else yy = yy + h i = i + 1 end
            end
            pages = #starts
            o.pg = math.min(o.pg, pages)
            local from, to = starts[o.pg], (starts[o.pg + 1] or (#items + 1)) - 1
            for k = from, to do
                local it = items[k]
                bb:paintRect(x, y + S(3), S(3), math.min(Page.wrap(nil, it.text, face, 0, 0, w - S(16), nil, nil), max_lines * lh) - S(2), BLACK)
                local h = Page.wrap(bb, it.text, face, x + S(16), y, w - S(16), max_lines, lh)
                local by_line = (it.who and (it.who.name or it.who.username) or "")
                if it.rating then by_line = "\u{2605} " .. string.format("%.1f", it.rating):gsub("%.0$", "") .. "  ·  " .. by_line end
                if (it.likes or 0) > 0 then by_line = by_line .. "  ·  " .. T(it.likes == 1 and _("%1 like") or _("%1 likes"), it.likes) end
                Look.label(bb, by_line, x + S(16), y + h + S(4), w - S(16), S(18), 9, { color = Look.GRAY })
                y = y + h + S(34)
            end
        end
    end
    o.pages = pages
    local fy = bottom - S(40)
    local kw = S(56)
    if pages > 1 then
        local rp = Look.button(bb, x, fy, kw, S(36), "\u{2039}", { size = 15, enabled = o.pg > 1 })
        if o.pg > 1 then hit(rp, function() o.pg = o.pg - 1 host:redraw() end) end
        local rn = Look.button(bb, x + kw + S(70), fy, kw, S(36), "\u{203A}", { size = 15, enabled = o.pg < pages })
        if o.pg < pages then hit(rn, function() o.pg = o.pg + 1 host:redraw() end) end
        Look.label(bb, T(_("%1 / %2"), o.pg, pages), x + kw, fy, S(70) + Look.SHADOW_SMALL, S(36), 11, { align = "center" })
    end
    -- the way to the book itself
    if not o.no_store then
        local sw = S(190)
        local rs = Look.button(bb, x + w - sw - Look.SHADOW_SMALL, fy, sw, S(36), _("Find in the store"), { size = 12, on = true })
        hit(rs, function()
            -- (the store looks for it in your libraries, by title and author)
            local okS, err = pcall(function()
                require("bos_store").open{ book = { title = b.title, author = b.author, year = b.year, cover_path = HC.coverPath(b),
                    pick = { title = b.title, author = b.author, year = b.year, description = b.description or false } } }
            end)
            if not okS then logger.warn("ShelfTechUI: Hardcover to the store:", err) end
        end)
    end
end

local function fetchBook(o, redraw)
    HC.book(o.book.id, function(full, why)
        if full then
            o.full = full
            if o.book.mine and not full.mine then full.mine = o.book.mine end
            HC.fetchCovers({ full }, redraw, 1)
        else
            o.err = why
        end
        redraw()
    end)
end

function M.openBook(book)
    local o = { book = book }
    local page
    page = Page:new{ caption = _("Hardcover"),
        draw = function(self, bb, y, w)
            drawBook(self, bb, self.pad, y, w, Screen:getHeight() - S(12), o)
        end,
        on_swipe = function(self, dir)
            if dir == "west" and (o.pg or 1) < (o.pages or 1) then o.pg = o.pg + 1 self:refresh("ui")
            elseif dir == "east" then
                if (o.pg or 1) > 1 then o.pg = o.pg - 1 self:refresh("ui") else self:onClose() end
            end
        end,
        on_more = function(self, rect)
            UI.openList({
                { text = _("Refresh"), callback = function()
                    HC.forget("book" .. book.id)
                    o.full, o.err = nil, nil
                    fetchBook(o, function() if not self.closed then self:refresh("ui") end end)
                    self:refresh("ui")
                end },
            }, rect)
        end,
        on_close = function()
            -- your shelves may have changed: the app's lists are asked again
            if o.changed and M.app and not M.app.closed then
                M.app.data = {}
                M.app:load(M.app.tab)
                M.app:refresh("ui")
            end
        end }
    page.redraw = function(self) if not self.closed then self:refresh("ui") end end
    o.on_change = function() o.changed = true end
    page:show()
    fetchBook(o, function() page:redraw() end)
    return page
end

-- ---------------------------------------------------------------- the book window's tab

local Tab = InputContainer:extend{ width = 0, height = 0, book = nil, show_parent = nil }

function Tab:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.hits = {}
    self.ges_events = {
        HTap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        HSwipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
    self.o = nil
    self.note = nil
    if HC.signedIn() then self:find() end
end

function Tab:hit(rect, fn) table.insert(self.hits, { rect = rect, fn = fn }) end

function Tab:redraw()
    if self.dimen and self.dimen.x then
        UIManager:setDirty(self.show_parent or "all", function() return "ui", self.dimen end)
    end
end

--- Which Hardcover book this file is: the one it was linked to, or the
--- likeliest by title and author (kept when it's certain).
function Tab:find()
    local file = self.book.filepath
    local link = HC.linkFor(file)
    local function show(b)
        self.o = { book = b, compact = true, no_store = true, on_change = function(nb)
            local l = HC.linkFor(file) or { id = nb.id, title = nb.title, author = nb.author, pages = nb.pages }
            if nb.mine then l.entry, l.status = nb.mine.id, nb.mine.status end
            HC.setLink(file, l)
        end }
        fetchBook(self.o, function() self:redraw() end)
        self:redraw()
    end
    if link then return show({ id = link.id, title = link.title, author = link.author, pages = link.pages }) end
    self.note = _("Looking on Hardcover…")
    HC.match(self.book.title, self.book.author, function(b, sure, why)
        self.note = nil
        if not b then
            self.note = why or _("Hardcover doesn't seem to have this book. Search for it to link it.")
        elseif sure then
            HC.setLink(file, { id = b.id, title = b.title, author = b.author, pages = b.pages })
            show(b)
        else
            self.guess = b
            HC.fetchCovers({ b }, function() self:redraw() end, 1)
        end
        self:redraw()
    end)
end

--- Pick the book by hand: a search, then a list to choose from.
function Tab:choose()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Find this book on Hardcover"),
        input = self.book.title or "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local q = dlg:getInputText()
                UIManager:close(dlg)
                self.note, self.guess, self.o = _("Searching…"), nil, nil
                self:redraw()
                HC.search(q, function(list, why)
                    self.note = nil
                    if not list or #list == 0 then self.note = why or _("Nothing found.") self:redraw() return end
                    local items = {}
                    for i = 1, math.min(8, #list) do
                        local b = list[i]
                        items[#items + 1] = { text = b.title .. (b.author and ("  ·  " .. b.author) or "") .. (b.year and ("  ·  " .. b.year) or ""),
                            callback = function()
                                HC.setLink(self.book.filepath, { id = b.id, title = b.title, author = b.author, pages = b.pages })
                                self.guess = nil
                                self:find()
                            end }
                    end
                    UI.openList(items, nil)
                    self:redraw()
                end)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Tab:getSize() return Geom:new{ w = self.width, h = self.height } end

function Tab:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    self.hits = {}
    bb:paintRect(x, y, self.width, self.height, WHITE)
    local pad = S(18)
    local w = self.width - 2 * pad
    local ok, err = pcall(function()
        if not HC.signedIn() then
            local h = Page.wrap(bb, _("Sign in to Hardcover to put this book on your shelves, rate it, and see the quotes readers liked most."),
                Look.serif(16, false, true), x + pad, y + S(22), w, 4, S(25), Look.GRAY)
            local r = Look.button(bb, x + pad, y + S(22) + h + S(16), S(220), S(44), _("Sign in"), { size = 13, on = true })
            self:hit(r, function() self:leave(function() M.open() end) end)
            return
        end
        if self.o then
            drawBook(self, bb, x + pad, y + S(14), w, y + self.height - S(6), self.o)
            -- (the wrong book? a small key to choose another)
            local r = Geom:new{ x = x + self.width - pad - S(150), y = y + self.height - S(46), w = S(150), h = S(36) }
            Look.button(bb, r.x, r.y, r.w - Look.SHADOW_SMALL, S(36), _("Not this book?"), { size = 10 })
            self:hit(r, function() self:choose() end)
            return
        end
        if self.guess then
            local b = self.guess
            Look.label(bb, _("Is it this one?"), x + pad, y + S(14), w, S(20), 11, { color = Look.GRAY })
            local cw, ch = S(92), S(138)
            drawCover(bb, b, x + pad, y + S(44), cw, ch)
            local tx = x + pad + cw + S(18)
            local th = Page.wrap(bb, b.title, Look.serif(18, true), tx, y + S(44), w - cw - S(18), 3, S(25))
            if b.author then Page.wrap(bb, b.author, Look.serif(14, false, true), tx, y + S(48) + th, w - cw - S(18), 1, S(22), Look.GRAY) end
            local by = y + S(44) + ch + S(20)
            local r1 = Look.button(bb, x + pad, by, S(150), S(42), _("Yes"), { size = 13, on = true })
            self:hit(r1, function()
                HC.setLink(self.book.filepath, { id = b.id, title = b.title, author = b.author, pages = b.pages })
                self.guess = nil
                self:find()
            end)
            local r2 = Look.button(bb, x + pad + S(170), by, S(190), S(42), _("No, search"), { size = 13 })
            self:hit(r2, function() self:choose() end)
            return
        end
        local h = Page.wrap(bb, self.note or "", Look.serif(16, false, true), x + pad, y + S(22), w, 4, S(25), Look.GRAY)
        if self.note and not self.note:find("…", 1, true) then
            local r = Look.button(bb, x + pad, y + S(22) + h + S(16), S(220), S(44), _("Search Hardcover"), { size = 13, on = true })
            self:hit(r, function() self:choose() end)
        end
    end)
    if not ok then logger.warn("ShelfTechUI: Hardcover tab:", err) end
end

--- Close the book window, then do something.
function Tab:leave(fn)
    local modal = self.modal and self.modal()
    UIManager:nextTick(function()
        if modal then pcall(function() if modal.onClose then modal:onClose() else UIManager:close(modal) end end) end
        UIManager:nextTick(fn)
    end)
end

function Tab:onHTap(_, ges)
    for k = #self.hits, 1, -1 do
        local h = self.hits[k]
        if Page.inside(ges.pos, h.rect) then
            UI.press(h.rect, h.fn)
            return true
        end
    end
    return false
end

function Tab:onHSwipe(_, ges)
    local o = self.o
    if not o then return false end
    if ges.direction == "west" and (o.pg or 1) < (o.pages or 1) then o.pg = o.pg + 1 self:redraw() return true end
    if ges.direction == "east" and (o.pg or 1) > 1 then o.pg = o.pg - 1 self:redraw() return true end
    return false
end

--- The tab for Bookshelf's book window (a book of yours on the device),
--- while Hardcover is in use (signed in, or never yet declined).
function M.tab(bw, book, modal)
    -- (a key in the window's About tab, once you're signed in: nothing
    -- there to tap for someone who doesn't use Hardcover)
    if HC.get("tab_hidden") == true or not HC.signedIn() then return nil end
    if type(book) ~= "table" or type(book.filepath) ~= "string" or book.is_remote or book.is_folder then return nil end
    local okS, Sources = pcall(require, "lib/bookshelf_sources")
    if okS and Sources.isRemotePath and Sources.isRemotePath(book.filepath) then return nil end
    return {
        id = "stui_hardcover",
        label = _("Hardcover"),
        widget_builder = function(avail_w, avail_h, show_parent)
            return Tab:new{ width = avail_w, height = avail_h, book = book, modal = modal, show_parent = show_parent }
        end,
    }
end

-- ---------------------------------------------------------------- settings

--- Hardcover's settings, as a short list (also under Settings → Connect).
function M.settings()
    local function yesno(key, default) return HC.get(key, default) and _("Yes") or _("No") end
    local items
    local function build()
        local u = HC.user()
        items = {
            { text = HC.signedIn() and T(_("Signed in as %1"), u and (u.name or u.username) or "?") or _("Not signed in"),
                callback = function() M.open() end },
            { text = T(_("Shelve books as you read them: %1"), yesno("auto_status", true)), callback = function()
                HC.set("auto_status", not HC.get("auto_status", true)) M.settings() end },
            { text = T(_("Send how far along you are: %1"), yesno("auto_progress", true)), callback = function()
                HC.set("auto_progress", not HC.get("auto_progress", true)) M.settings() end },
            { text = T(_("Ask for a rating at a book's end: %1"), yesno("ask_rating", true)), callback = function()
                HC.set("ask_rating", not HC.get("ask_rating", true)) M.settings() end },
            { text = T(_("Quotes you share are: %1"), ({ _("Public"), _("For followers"), _("Private") })[HC.get("quote_privacy", 1)] or _("Public")),
                callback = function() HC.set("quote_privacy", HC.get("quote_privacy", 1) % 3 + 1) M.settings() end },
            { text = T(_("Friends on home's covers: %1"), yesno("home_badges", true)), callback = function()
                HC.set("home_badges", not HC.get("home_badges", true))
                HC.links_gen = (HC.links_gen or 0) + 1
                pcall(function() require("bos_home").refresh() end)
                M.settings() end },
            { text = T(_("On Home, your books not on this device: %1"),
                ({ reading_want = _("Reading and Want to read"), reading = _("Reading"), off = _("None") })[HC.get("library_ghosts", "reading_want")] or _("None")),
                callback = function()
                    local nxt = { reading_want = "reading", reading = "off", off = "reading_want" }
                    HC.set("library_ghosts", nxt[HC.get("library_ghosts", "reading_want")] or "reading_want")
                    pcall(function() require("bos_home").refresh() end)
                    M.settings() end },
            { text = T(_("Hardcover in a book's window: %1"), HC.get("tab_hidden") and _("No") or _("Yes")), callback = function()
                HC.set("tab_hidden", not HC.get("tab_hidden") and true or nil) M.settings() end },
            { text = _("Send this device's reading history…"), callback = function() M.sendHistory() end },
            { text = HC.clientId() and _("App ID: set (link codes)") or _("App ID: none (sign in with a key)"), callback = function() M.askClientId() end },
        }
    end
    build()
    UI.openList(items, nil)
end

function M.askClientId()
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title = _("Hardcover app ID"),
        description = _("With an app ID from Hardcover (Account → API → Developer Apps: a \"Mobile, desktop, or CLI\" app with Device Authorization on), signing in is a short code approved on a phone, with no key to paste. Leave empty to sign in with a key."),
        input = HC.clientId() or "",
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = (dlg:getInputText() or ""):gsub("%s", "")
                HC.set("client_id", v ~= "" and v or nil)
                UIManager:close(dlg)
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return M
