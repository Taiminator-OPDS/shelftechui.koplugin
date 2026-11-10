--[[
Search within a book, in the retro Bookshelf look:

  the search box     a retro window: pinstriped "SEARCH THIS BOOK" title,
                     square heavy frame, hard shadow, square buttons
  the search bar     (after ◁ ▷) a small retro window titled with what you
                     searched for, square buttons with hard shadows
  All results        ShelfTechUI's own page (bos_nav, "results"): the query
                     and how many, NEW SEARCH, each result as a card (its
                     number, page and chapter, the passage with the word in
                     bold). Tap one to go there.
  the result bar     (after picking a result) the same small retro window

Off with Settings → ShelfTechUI → KOReader's screens → Search dialogs.
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local T = require("ffi/util").template
local _ = require("gettext")

local M = {}

local function on()
    local ok, v = pcall(function() return require("bos_settings_store").get("skin_search") end)
    return not ok or v ~= false
end

local function scoped(fn, ...)
    local Skin = package.loaded["bos_skin"]
    if Skin and Skin.scoped then return Skin.scoped("retro", { title_line = false }, fn, ...) end
    return fn(...)
end

--- Run fn; every ButtonDialog it makes becomes a retro window titled `caption`.
local function retroButtonDialogs(caption, fn, ...)
    local ButtonDialog = require("ui/widget/buttondialog")
    local Retro = require("bos_retro")
    local orig_new = ButtonDialog.new
    ButtonDialog.new = function(cls, o, ...)
        local d = orig_new(cls, o, ...)
        local ok, err = pcall(Retro.window, d, caption, function() d:onClose() end)
        if not ok then logger.warn("ShelfTechUI: retro search bar:", err) end
        return d
    end
    local res = table.pack(pcall(scoped, fn, ...))
    ButtonDialog.new = orig_new
    if not res[1] then error(res[2], 0) end
    return unpack(res, 2, res.n)
end

function M.install()
    local ok, RS = pcall(require, "apps/reader/modules/readersearch")
    if not ok or not RS or RS._bos_retro then return end
    RS._bos_retro = true
    local Retro = require("bos_retro")
    Retro.installRetroInput()
    local InputDialog = require("ui/widget/inputdialog")

    -- the search box
    local orig_input = RS.onShowFulltextSearchInput
    RS.onShowFulltextSearchInput = function(self, ...)
        if not on() then return orig_input(self, ...) end
        local orig_new = InputDialog.new
        InputDialog.new = function(cls, o, ...)
            if type(o) == "table" and not o._bos_retro_wanted then
                o._bos_retro_wanted = true
                o.description = o.description or o.title
                o.title = _("Search this book")
            end
            return orig_new(cls, o, ...)
        end
        local res = table.pack(pcall(scoped, orig_input, self, ...))
        InputDialog.new = orig_new
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, res.n)
    end

    -- the search bar (◁ ▷ after a search)
    local orig_bar = RS.onShowSearchDialog
    RS.onShowSearchDialog = function(self, text, ...)
        if not on() then return orig_bar(self, text, ...) end
        return retroButtonDialogs(T(_("Search: %1"), tostring(text or "")), orig_bar, self, text, ...)
    end

    -- the result bar (n / N after picking a result)
    local orig_goto = RS.gotoResultsItem
    RS.gotoResultsItem = function(self, index, ...)
        if not on() then return orig_goto(self, index, ...) end
        return retroButtonDialogs(T(_("Result: %1"), tostring(self.last_search_text or "")), orig_goto, self,
            index, ...)
    end

    -- All results: ShelfTechUI's page instead of KOReader's list
    local orig_all = RS.onShowFindAllResults
    RS.onShowFindAllResults = function(self, ...)
        if not on() then return orig_all(self, ...) end
        local orig_show = UIManager.show
        local shown
        UIManager.show = function(um, w, ...)
            if w ~= nil and w == self.result_menu then
                shown = true
                local Nav = require("bos_nav")
                local index = self.findall_results_item_index
                self.findall_results_item_index = nil
                Nav.showResults(self.ui, self, w.item_table, index)
                return
            end
            return orig_show(um, w, ...)
        end
        local res = table.pack(pcall(orig_all, self, ...))
        UIManager.show = orig_show
        if not res[1] then error(res[2], 0) end
        return unpack(res, 2, res.n)
    end
end

return M
