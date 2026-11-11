--[[
The file browser's list, built when it's seen.

KOReader's file browser is rebuilt every time a book closes (opening a book
throws it away). Its list of the home folder is built at once: every file
looked at, sorted, checked against collections, sidecars and the cover
database. Under Bookshelf's home that list is never on screen, yet it was
most of the time it takes to close a book (about 60% with a five-book
library, more with a big one): the pause before the start menu or the
Settings app opens after coming home from a book.

So while the file browser's list is hidden (Bookshelf's home covers it), it
isn't built: it keeps its folder, and an empty list. The first time it's
painted (you open the file browser, or close Bookshelf), it's built then,
before it shows. Anything that asks for the list on purpose (a refresh while
it's visible, changing folder) builds it as before.

  M.install()   once, as early as possible
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

--- Is Bookshelf's home on the window stack (so the file browser is under it)?
local function covered()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i].widget
        if type(w) == "table" and type(w._launchReader) == "function" then return true end
    end
    -- during a book's close, the shelf is put back on top right after the
    -- file browser is made: Bookshelf's park says so
    local Park = package.loaded["lib/bookshelf_reader_park"]
    if type(Park) == "table" and Park.isParked and Park.isParked() then return true end
    return false
end
M.covered = covered

function M.install()
    local ok, FC = pcall(require, "ui/widget/filechooser")
    if not ok or type(FC) ~= "table" or FC._stui_lazy then return end
    FC._stui_lazy = true
    local orig_refresh = FC.refreshPath
    FC.refreshPath = function(self, ...)
        if self.name == "filemanager" and not self._stui_shown and covered() then
            -- an empty list for now; built on the first paint
            self._stui_deferred = true
            local okS, err = pcall(self.switchItemTable, self, nil, {}, nil, nil, nil)
            if okS then return end
            logger.warn("ShelfTechUI: file browser list, deferring:", err)
        end
        self._stui_deferred = nil
        return orig_refresh(self, ...)
    end
    local orig_paint = FC.paintTo
    FC.paintTo = function(self, bb, x, y, ...)
        if self._stui_deferred then
            self._stui_deferred = nil
            self._stui_shown = true
            local okR, err = pcall(orig_refresh, self)
            if not okR then logger.warn("ShelfTechUI: file browser list:", err) end
        end
        return orig_paint(self, bb, x, y, ...)
    end
end

return M
