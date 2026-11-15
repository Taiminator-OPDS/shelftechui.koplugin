--[[
Hardcover while you read (as a Kindle keeps Goodreads up to date):

  * opening a book puts it on your Reading shelf (once it's known which
    Hardcover book it is: found by title and author, and only kept when
    that's certain; otherwise you choose in the book's Hardcover tab);
  * closing it sends how far along you are;
  * finishing it moves it to Read and asks for your rating;
  * a highlighted passage can be shared as a quote ("Hardcover" in the
    highlight menu).

Nothing here turns Wi-Fi on: what can't be sent waits (bos_hardcover's
queue) and goes the next time the device is connected.

  M.opened(ui)    a book was opened
  M.closing(ui)   it's being closed
  M.online()      Wi-Fi came on
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = {}

local function HC() return require("bos_hardcover") end

local function notify(text)
    pcall(function() require("ui/widget/notification"):notify(text) end)
end

local function props(ui)
    local p = ui.doc_props or {}
    local title = p.display_title or p.title
    local author = p.authors
    if type(author) == "string" then author = author:match("^[^\n]+") end
    return title, author
end

local function percent(ui)
    local pct
    pcall(function()
        if ui.rolling or ui.paging then
            local page, total = ui:getCurrentPage(), ui.document:getPageCount()
            if page and total and total > 0 then pct = page / total end
        end
    end)
    if not pct then pcall(function() pct = ui.doc_settings:readSetting("percent_finished") end) end
    return pct
end

--- "Hardcover" in the highlight menu: the passage, as a quote.
local function highlightButton(ui)
    if not (ui.highlight and ui.highlight.addToHighlightDialog) then return end
    ui.highlight:addToHighlightDialog("13_stui_hardcover", function(this)
        return {
            text = _("Hardcover"),
            enabled = HC().signedIn(),
            callback = function()
                local text
                pcall(function() text = this.selected_text and this.selected_text.text end)
                pcall(function() this:onClose() end)
                if not text or not text:match("%S") then return end
                local file = ui.document.file
                local link = HC().linkFor(file)
                if not link then
                    notify(_("Link this book to Hardcover first: hold it on home, Hardcover tab."))
                    return
                end
                if not HC().connected() then notify(_("Not connected: turn on Wi-Fi to share a quote.")) return end
                notify(_("Sharing the quote…"))
                HC().quote(link.id, text, function(ok, why)
                    notify(ok and _("Quote shared on Hardcover") or (why or _("Hardcover didn't take the quote.")))
                end)
            end,
        }
    end)
end

function M.opened(ui)
    if not (ui and ui.document) then return end
    pcall(highlightButton, ui)
    local H = HC()
    if not H.signedIn() or not H.get("auto_status", true) then return end
    local file = ui.document.file
    local link = H.linkFor(file)
    local function reading()
        local l = H.linkFor(file)
        -- (a book already read isn't moved back: a re-read is said on purpose)
        if l and l.status ~= 2 and l.status ~= 3 then H.status(file, 2) end
    end
    if link then return reading() end
    if not H.connected() then return end
    local title, author = props(ui)
    if not title then return end
    H.match(title, author, function(b, sure)
        if not (b and sure) or H.linkFor(file) then return end
        H.setLink(file, { id = b.id, title = b.title, author = b.author, pages = b.pages })
        reading()
    end)
end

--- Your rating for a book just finished (asked once home is back).
local function askRating(file)
    local H = HC()
    local link = H.linkFor(file)
    if not (link and H.connected()) then return end
    require("bos_hardcover_ui").rateDialog(T(_("Finished: %1\nYour rating on Hardcover"), link.title or ""), nil, function(v)
        if not v or v <= 0 then return end
        local function rate(entry_id)
            H.rate(entry_id, v, link.id, function(entry, why)
                notify(entry and _("Hardcover: rating saved") or (why or _("Hardcover didn't take the rating.")))
            end)
        end
        local l = H.linkFor(file)
        if l and l.entry and l.status == 3 then return rate(l.entry) end
        H.setStatus(link.id, 3, function(entry, why)
            if not entry then notify(why or _("Hardcover didn't take that.")) return end
            local now = H.linkFor(file) or link
            now.entry, now.status = entry.id, entry.status
            H.setLink(file, now)
            rate(entry.id)
        end)
    end)
end

function M.closing(ui)
    if not (ui and ui.document) then return end
    local H = HC()
    if not H.signedIn() then return end
    local file = ui.document.file
    local link = H.linkFor(file)
    if not link then return end
    local done = false
    pcall(function()
        local summary = ui.doc_settings:readSetting("summary")
        done = type(summary) == "table" and summary.status == "complete"
    end)
    if done then
        if link.status ~= 3 and H.get("auto_status", true) then
            H.status(file, 3)
            if H.get("ask_rating", true) and H.connected() then
                UIManager:scheduleIn(2.5, function()
                    local ok, err = pcall(askRating, file)
                    if not ok then logger.warn("ShelfTechUI: Hardcover rating:", err) end
                end)
            end
        end
        return
    end
    if H.get("auto_progress", true) then
        local pct = percent(ui)
        if pct and pct > 0 then H.progress(file, pct) end
    end
end

function M.online()
    UIManager:scheduleIn(6, function() pcall(function() HC().flush() end) end)
end

return M
