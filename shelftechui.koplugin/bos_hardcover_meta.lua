--[[
A book's details from Hardcover, put on the file (hold a book → Edit →
Details from Hardcover): its title, authors, series and number, description
and genres, and if you like its cover. Kept as KOReader's own custom details
(custom_metadata.lua in the book's .sdr), so KOReader's Book information
shows them too and "Reset" there takes them off again.

The book is the one the file is linked to on Hardcover, else Hardcover's
closest match for its title and author (shown first, to say yes to).

  M.run(file, hint)   hint: { title, author } as home knows them
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function info(text, timeout)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text, timeout = timeout })
end

--- KOReader's properties of the file as they are now (title, authors…);
--- `open`: from the book itself when nothing has read them yet.
local function currentProps(file, open)
    local ok, props = pcall(function()
        -- (KOReader's book info of the UI that's up: it asks its UI)
        local ui = (package.loaded["apps/reader/readerui"] or {}).instance
            or (package.loaded["apps/filemanager/filemanager"] or {}).instance
        return ui.bookinfo:getDocProps(file, nil, not open)
    end)
    return ok and type(props) == "table" and props or {}
end

--- The details written as KOReader's custom metadata of `file`.
function M.write(file, d)
    local DocSettings = require("docsettings")
    local path = DocSettings:findCustomMetadataFile(file)
    local cds = DocSettings.openSettingsFile(path)
    if not path then
        -- (the first custom details: a copy of the file's own, as KOReader keeps)
        local orig = currentProps(file)
        orig.display_title = nil
        cds:saveSetting("doc_props", orig)
    end
    local props = cds:readSetting("custom_props", {})
    local title = d.title
    if title and d.subtitle and d.subtitle ~= "" then title = title .. ": " .. d.subtitle end
    if title and title ~= "" then props.title = title end
    if d.authors and #d.authors > 0 then props.authors = table.concat(d.authors, "\n") end
    if d.series and d.series ~= "" then
        props.series = d.series
        props.series_index = d.series_index
    end
    if d.description and d.description ~= "" then props.description = d.description end
    if d.genres and #d.genres > 0 then props.keywords = table.concat(d.genres, "\n") end
    cds:flushCustomMetadata(file)
    return true
end

--- Everything that shows the book reads it again: the same steps as Home's
--- own "Refresh metadata" (lib/bookshelf_widget.lua, refresh_btn). The
--- book's cached row (cover and details) is dropped, so it's read again
--- from the file and its custom details; the cover may be fetched again;
--- Home's caches of the book, its progress record and the top panel's
--- remembered book are dropped; then Home is built again, which queues the
--- book to be read. (Before, only the row was dropped: the top panel kept the
--- old details and, on the device, the book's cover didn't come back.)
local function changed(file)
    local Event = require("ui/event")
    pcall(function()
        local ok_bim, BIM = pcall(require, "bookinfomanager")
        if ok_bim and BIM and BIM.deleteBookInfo then BIM:deleteBookInfo(file) end
    end)
    local okR, Repo = pcall(require, "lib/bookshelf_book_repository")
    if okR then
        pcall(Repo.forgetBook, file)
        pcall(function() Repo.invalidateLightMeta() end)
        pcall(function() Repo.invalidateProgressCache(file) end)
        pcall(function() Repo.invalidateBookCache("hardcover-details") end)
    end
    pcall(function() require("lib/bookshelf_scaled_cover_cache"):drop(file) end)
    local bw
    pcall(function() bw = require("bos_shelf").shelfWidget() end)
    if bw then
        pcall(function() bw:_allowCoverFetch(file) end)
        if bw._hero_current_memo and bw._hero_current_memo.fp == file then bw._hero_current_memo = nil end
        -- Home notes the books it has checked as fully read ("cover-ok") and
        -- doesn't look at them again; the note is cleared through a hook tied
        -- to one Home widget, which may not be the one showing. Cleared here
        -- on the live one, or the book is never read again: no cover, and
        -- the old details (what the Kindle showed).
        local memo = bw._bim_check_memo
        if memo then
            local prefix = file .. "|"
            for k in pairs(memo) do
                if k:sub(1, #prefix) == prefix then memo[k] = nil end
            end
        end
    end
    UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
    UIManager:broadcastEvent(Event:new("BookMetadataChanged", { filepath = file }))
    if bw then
        pcall(function()
            bw:_rebuild()
            UIManager:setDirty(bw, "ui")
        end)
    end
end

--- The cover from Hardcover, as the book's custom cover; cb(ok).
local function setCover(file, d, cb)
    if not d.image then return cb(false) end
    local tmp = require("datastorage"):getDataDir() .. "/cache/stui_hc_cover_" .. d.id .. ".jpg"
    require("bos_store").Async.run(function()
        return require("lib/bookshelf_cover_fetch").download(d.image, tmp, nil, nil, { block_timeout = 10, total_timeout = 30 })
    end, function(ok, got)
        local done = false
        if ok and got then
            local DocSettings = require("docsettings")
            local old = DocSettings:findCustomCoverFile(file)
            if old then os.remove(old) end
            done = DocSettings:flushCustomCover(file, tmp) and true or false
            os.remove(tmp)
        end
        cb(done)
    end, 45)
end

local function summary(d)
    local lines = { d.title or "" }
    if d.authors and #d.authors > 0 then lines[#lines + 1] = T(_("by %1"), table.concat(d.authors, ", ")) end
    if d.series then
        lines[#lines + 1] = d.series_index and T(_("%1, book %2"), d.series, (tostring(d.series_index):gsub("%.0$", ""))) or d.series
    end
    if d.year then lines[#lines + 1] = tostring(d.year) end
    if d.genres and #d.genres > 0 then
        local g = {}
        for i = 1, math.min(4, #d.genres) do g[i] = d.genres[i] end
        lines[#lines + 1] = table.concat(g, " · ")
    end
    return table.concat(lines, "\n")
end

--- Ask, then write: the details, and the cover if wanted.
local function offer(file, d, sure)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function apply(with_cover)
        UIManager:close(dlg)
        local ok, err = pcall(M.write, file, d)
        if not ok then
            logger.warn("ShelfTechUI: Hardcover details:", err)
            return info(_("The details couldn't be written."), 4)
        end
        -- (a book that wasn't linked: it is now, it's been said to be this one)
        local HC = require("bos_hardcover")
        if not HC.linkFor(file) then
            HC.setLink(file, { id = d.id, title = d.title, author = d.authors and d.authors[1], pages = d.pages })
        end
        local function finish(cover_ok)
            changed(file)
            info(with_cover and not cover_ok and _("Details from Hardcover saved. The cover couldn't be downloaded.")
                or _("Details from Hardcover saved."), 3)
        end
        if with_cover then setCover(file, d, finish) else finish() end
    end
    local head = sure and _("Use Hardcover's details for this book?")
        or _("Hardcover's closest match. Use its details for this book?")
    local buttons = {
        { { text = _("Details"), callback = function() apply(false) end },
          { text = _("Details and cover"), enabled = d.image ~= nil, callback = function() apply(true) end } },
        { { text = _("Cancel"), callback = function() UIManager:close(dlg) end } },
    }
    dlg = ButtonDialog:new{ title = head .. "\n\n" .. summary(d), title_align = "left", buttons = buttons }
    UIManager:show(dlg)
end

--- Find the book on Hardcover and offer its details for `file`.
function M.run(file, hint)
    local HC = require("bos_hardcover")
    if not HC.signedIn() then
        return info(_("Sign in to Hardcover first (Settings → Connect → Hardcover)."), 4)
    end
    local msg = require("ui/widget/infomessage"):new{ text = _("Asking Hardcover…") }
    UIManager:show(msg)
    local function got(id, sure)
        HC.details(id, function(d, why)
            UIManager:close(msg)
            if not d then return info(why or _("Hardcover didn't answer."), 4) end
            offer(file, d, sure)
        end)
    end
    local link = HC.linkFor(file)
    if link and link.id then return got(link.id, true) end
    hint = hint or {}
    local props = currentProps(file)
    local stem = (file:match("([^/]+)$") or ""):gsub("%.[^.]+$", "")
    if not hint.title and (not props.title or props.title == stem) then props = currentProps(file, true) end
    local title = hint.title or props.title or props.display_title
    if not title or title == "" then
        title = (file:match("([^/]+)$") or ""):gsub("%.[^.]+$", "")
    end
    local author = tostring(hint.author or props.authors or ""):gsub("\n.*", "")
    -- ("Melville, Herman" → "Herman Melville")
    local last, first = author:match("^([^,]+),%s*(.+)$")
    if last then author = first .. " " .. last end
    HC.match(title, author, function(hb, sure)
        if not hb then
            UIManager:close(msg)
            return info(T(_("“%1” wasn't found on Hardcover."), title), 4)
        end
        got(hb.id, sure)
    end)
end

return M
