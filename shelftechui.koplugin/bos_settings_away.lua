--[[
The Settings app shows everything, wherever it's opened.

KOReader builds two menus: the file browser's (home) and the reader's (a
book). Some rows exist in only one: the sorting and display of the file
browser and Bookshelf's shelf settings at home; the font, style and
table of contents in a book. And when Bookshelf parks a book under home,
the menu is the reader's even though you're looking at home.

So each time the app is built, the rows of its sections are noted (names
only) for that side; the rows only the other side has are then added in
their places, marked "home ›" or "in a book ›". Tapping one goes there and
opens the app at that row:

  a home row, from a book parked under home: the book finishes closing
    (Bookshelf would have closed it a moment later anyway)
  a home row, from inside a book: home first, then the same
  a book row, at home: your last book opens, at that setting

  M.merge(plugin, sections)    called by bos_settings_page.sections
  M.openRow(sec_id, text)      open the app on that row (the side's own)
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Store = require("bos_settings_store")

local M = {}

local function text(it)
    if type(it) ~= "table" then return nil end
    local ok, t = pcall(function() return it.text_func and it.text_func() or it.text end)
    t = ok and t or nil
    if type(t) ~= "string" or t == "" or t == "KOMenu:separator" then return nil end
    return t
end

--- The stable part of a row's name ("Sort by: name" → "Sort by", "Style
--- tweaks (3)" → "Style tweaks"), to recognise it after its value changed.
local function key(t)
    t = tostring(t or "")
    t = t:gsub("%s*%b()%s*$", ""):gsub(":.*$", "")
    return (t:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.key = key

local function side(plugin)
    return (plugin and plugin.ui and plugin.ui.document) and "reader" or "fm"
end

local function parked()
    local Park = package.loaded["lib/bookshelf_reader_park"]
    return Park and Park.isParked and Park.isParked() or false
end

local function lastBook()
    local ok, hist = pcall(function() return require("readhistory").hist end)
    local lfs = require("libs/libkoreader-lfs")
    for _i, e in ipairs(ok and hist or {}) do
        if e.file and lfs.attributes(e.file, "mode") == "file" then return e.file end
    end
end

-- ---------------------------------------------------------------- going there

--- Open the Settings app of the UI now on screen at `sec_id`'s row `name`.
function M.openRow(sec_id, name)
    local Settings = require("bos_settings")
    local s = Settings.top()
    if not s then return false end
    s:showHome()
    if s.screen and s.screen.openRow then s.screen:openRow(sec_id, name) end
    return true
end

--- When the reader (or the file browser) is up and settled, open the app there.
local function whenUp(want, sec_id, name)
    local tries = 0
    local function look()
        tries = tries + 1
        local R = package.loaded["apps/reader/readerui"]
        local F = package.loaded["apps/filemanager/filemanager"]
        local up = (want == "reader" and R and R.instance and R.instance.document)
            or (want == "fm" and F and F.instance and not (R and R.instance))
        if up then
            UIManager:scheduleIn(0.3, function() M.openRow(sec_id, name) end)
        elseif tries < 60 then
            UIManager:scheduleIn(0.25, look)
        end
    end
    UIManager:scheduleIn(0.1, look)
end

local function closeApp()
    local Settings = require("bos_settings")
    local s = Settings.top()
    if s and s.closeHub then s:closeHub() end
end

--- A home row from the reader: finish the parked book (or go home first).
local function goHome(sec_id, name)
    closeApp()
    local Park = package.loaded["lib/bookshelf_reader_park"] or select(2, pcall(require, "lib/bookshelf_reader_park"))
    local function finish()
        if type(Park) == "table" and Park.isParked and Park.isParked() then
            UIManager:forceRePaint()
            Park.runInFileManager(function() end)
        end
        whenUp("fm", sec_id, name)
    end
    if parked() then
        UIManager:nextTick(finish)
    else
        local R = package.loaded["apps/reader/readerui"]
        local ui = R and R.instance
        if ui then pcall(function() require("bos_shelf").back(ui) end) end
        UIManager:scheduleIn(0.6, finish)
    end
end

--- A book row from home: open the last book there.
local function goReader(sec_id, name)
    local file = lastBook()
    if not file then return end
    closeApp()
    UIManager:nextTick(function()
        local ok, err = pcall(function() require("bos_shelf").open(file) end)
        if not ok then logger.warn("ShelfTechUI: settings, opening the last book:", err) return end
        whenUp("reader", sec_id, name)
    end)
end

-- ---------------------------------------------------------------- the merge

-- Rows that act on the book or folder in front of you rather than set
-- anything: not brought over (a table of contents at home means nothing).
local ACTIONS = {}
for _i, t in ipairs{
    -- a book's
    _("Table of contents"), _("Bookmarks"), _("Highlights"), _("Go to page"), _("Skim document"), _("Book map"),
    _("Page browser"), _("Go back to previous location"), _("Go forward to next location"), _("Book information"),
    _("Book status"), _("Open previous document"), _("Fulltext search"), _("Last fulltext search results"),
    _("Bookmark search"), _("Translate current page"),
    -- home's
    _("Open last document"), _("Close Bookshelf"), _("File search"), _("Last file search results"),
} do ACTIONS[t] = true end

local function snapshot(sections)
    local out = {}
    for _i, sec in ipairs(sections) do
        if type(sec.id) == "string" and sec.id:match("^stui_") then
            local rows = {}
            for _j, it in ipairs(sec.items or {}) do
                if type(it) == "table" and it.heading then
                    table.insert(rows, { h = tostring(it.heading) })
                else
                    local t = text(it)
                    if t then table.insert(rows, { t = t, d = type(it.description) == "string" and it.description or nil }) end
                end
            end
            out[sec.id] = { name = sec.name, icon = sec.icon, rows = rows }
        end
    end
    return out
end

local function same(a, b)
    local dump = require("dump")
    return dump(a or {}) == dump(b or {})
end

local function standIn(row, sec_id, other)
    local name = row.t
    if other == "fm" then
        return {
            text = name, stui_away = "fm",
            mandatory = _("home ›"),
            description = T(_("A home setting. %1"), parked()
                and _("Tap to go there: the book under home finishes closing first.")
                or _("Tap to go there: this closes the book (your place is kept).")),
            keep_menu_open = true,
            callback = function() goHome(sec_id, name) end,
        }
    end
    local file = lastBook()
    local title = file and (file:match("([^/]+)%.[^./]+$") or file:match("([^/]+)$"))
    return {
        text = name, stui_away = "reader",
        mandatory = _("in a book ›"),
        description = file and T(_("A setting for books. Tap to open your last book (%1) at this setting."), title)
            or _("A setting for books: open a book to change it."),
        enabled_func = function() return lastBook() ~= nil end,
        keep_menu_open = true,
        callback = function() goReader(sec_id, name) end,
    }
end

function M.merge(plugin, sections)
    local here, other = side(plugin), side(plugin) == "reader" and "fm" or "reader"
    -- note this side's rows (only when they changed: no writes on every open)
    local snap = snapshot(sections)
    local skey = "settings_rows_" .. here
    if not same(Store.get(skey), snap) then Store.set(skey, snap) end
    local theirs = Store.get("settings_rows_" .. other)
    if type(theirs) ~= "table" then return sections end
    -- every row name (stable part) shown here, in any section
    local shown = {}
    for _i, sec in ipairs(sections) do
        for _j, it in ipairs(sec.items or {}) do
            local t = text(it)
            if t then shown[key(t)] = true end
        end
    end
    local by_id = {}
    for _i, sec in ipairs(sections) do by_id[sec.id] = sec end
    local order = { "stui_home", "stui_reading", "stui_look", "stui_connect", "stui_device", "stui_tools", "stui_system" }
    for oi, id in ipairs(order) do
        local them = theirs[id]
        if them and type(them.rows) == "table" then
            local sec = by_id[id]
            local added = false
            if not sec then
                sec = { id = id, name = them.name, icon = them.icon, items = {} }
            end
            local items = sec.items
            -- the place: after the last row or heading both sides share
            local at = 0
            local function find(pred)
                for k, it in ipairs(items) do if pred(it) then return k end end
            end
            for _k, row in ipairs(them.rows) do
                if row.h then
                    local k = find(function(it) return type(it) == "table" and it.heading == row.h end)
                    if k then at = k
                    else
                        -- a heading only they have: theirs, if a row of it is missing here
                        row._pending = true
                        at = at -- (inserted with its first missing row)
                    end
                elseif row.t then
                    local k = find(function(it) local t = text(it) return t and key(t) == key(row.t) end)
                    if k then
                        at = k
                    elseif not shown[key(row.t)] and not ACTIONS[row.t] and not ACTIONS[key(row.t)] then
                        -- the heading above it, if it isn't here yet
                        local prev
                        for p = _k - 1, 1, -1 do if them.rows[p].h then prev = them.rows[p] break end end
                        if prev and prev._pending then
                            table.insert(items, at + 1, { heading = prev.h })
                            at = at + 1
                            prev._pending = nil
                        end
                        table.insert(items, at + 1, standIn(row, id, other))
                        at = at + 1
                        shown[key(row.t)] = true
                        added = true
                    end
                end
            end
            for _k, row in ipairs(them.rows) do row._pending = nil end
            if added and not by_id[id] then
                -- a section only the other side has: in its usual place
                local pos = #sections + 1
                for si, s2 in ipairs(sections) do
                    for oj = oi + 1, #order do
                        if s2.id == order[oj] and si < pos then pos = si end
                    end
                end
                table.insert(sections, pos, sec)
                by_id[id] = sec
            end
        end
    end
    return sections
end

return M
