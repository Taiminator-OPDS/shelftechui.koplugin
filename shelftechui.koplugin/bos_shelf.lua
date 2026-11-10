--[[
Going between a book and Bookshelf home, the instant way.

Bookshelf can "park" a book: its shelf is laid over the open reader, and
coming back to the book is instant. It only parks when its shelf is on the
window stack; otherwise (a book opened from somewhere else, or read in
another orientation) it closes the book properly, with a "Closing book…"
message in the middle of the screen.

  M.back(ui)       from a book to home: put the shelf on the stack first so
                   the book is parked, not closed; when it must close, it
                   closes without the message
  M.open(file)     open a book through Bookshelf when its shelf is up, so
                   going back parks it (and reopening the parked book is
                   instant)
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

--- Run fn with Bookshelf's "Closing book…" message off (its setting is read
--- through its store's nilOrTrue; nothing is written).
local function quietly(fn)
    local ok_s, Store = pcall(require, "lib/bookshelf_settings_store")
    local orig = ok_s and type(Store) == "table" and Store.nilOrTrue
    if orig then
        Store.nilOrTrue = function(key, ...)
            if key == "show_close_msg" then return false end
            return orig(key, ...)
        end
    end
    local ok, err = pcall(fn)
    if orig then Store.nilOrTrue = orig end
    if not ok then error(err, 0) end
end
M.quietly = quietly

--- The shelf widget on the window stack, if any.
function M.shelfWidget()
    for i = #(UIManager._window_stack or {}), 1, -1 do
        local w = UIManager._window_stack[i].widget
        if type(w) == "table" and type(w._launchReader) == "function" then return w end
    end
end

--- Every way out of a book that goes through Bookshelf (KOReader's menu,
--- gestures, the Home key, our toolbar) parks the book when it can, and
--- never shows "Closing book…".
function M.install(ui)
    local bs = ui and ui.bookshelf
    local cls = bs and getmetatable(bs)
    if type(cls) ~= "table" or cls._bos_quiet or type(cls._safeShow) ~= "function" then return end
    cls._bos_quiet = true
    local orig = cls._safeShow
    cls._safeShow = function(self, ...)
        local args = table.pack(...)
        local res
        quietly(function()
            if self.ui and self.ui.document and not M.shelfWidget() and self.show then
                -- lay the shelf under the book so it can be parked
                pcall(self.show, self)
            end
            res = table.pack(orig(self, unpack(args, 1, args.n)))
        end)
        return unpack(res, 1, res.n)
    end
    -- Bookshelf's start menu, opened while a book is kept open under the
    -- shelf: Bookshelf closes the book first (its shortcuts need the file
    -- browser), with the message; do it quietly, in the background
    local okW, BW = pcall(require, "lib/bookshelf_widget")
    if okW and type(BW) == "table" and type(BW._openStartMenu) == "function" and not BW._bos_quiet then
        BW._bos_quiet = true
        local orig_sm = BW._openStartMenu
        BW._openStartMenu = function(...)
            local a = table.pack(...)
            local r
            quietly(function() r = table.pack(orig_sm(unpack(a, 1, a.n))) end)
            return unpack(r, 1, r.n)
        end
    end
    local ok, Park = pcall(require, "lib/bookshelf_reader_park")
    if ok and type(Park) == "table" and not Park._bos_quiet then
        Park._bos_quiet = true
        for _i, name in ipairs{ "closeShelfToFileManager", "finishToMenu", "runInFileManager" } do
            local f = Park[name]
            if type(f) == "function" then
                Park[name] = function(...)
                    local a = table.pack(...)
                    local r
                    quietly(function() r = table.pack(f(unpack(a, 1, a.n))) end)
                    return unpack(r, 1, r.n)
                end
            end
        end
    end
end

function M.back(ui)
    local bs = ui and ui.bookshelf
    pcall(M.install, ui)
    if not (bs and bs.onToggleBookshelf) then
        ui:handleEvent(Event:new("Home"))
        return
    end
    -- No shelf under the book (opened from history, the file browser, a
    -- shortcut…): lay one down first, so Bookshelf parks the book instead
    -- of closing it.
    if not M.shelfWidget() and bs.show then
        local ok, err = pcall(bs.show, bs)
        if not ok then logger.warn("ShelfTechUI: couldn't lay the shelf under the book:", err) end
    end
    quietly(function() ui:handleEvent(Event:new("ToggleBookshelf")) end)
end

function M.open(file)
    local shelf = M.shelfWidget()
    if shelf then
        local ok = pcall(shelf._launchReader, shelf, file)
        if ok then return end
    end
    require("apps/reader/readerui"):showReader(file)
end

return M
