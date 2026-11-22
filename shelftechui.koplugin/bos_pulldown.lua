--[[
The pull-down, from any screen: a swipe down from the top edge of Settings,
Hardcover, the store, Bookdrop's screens and ShelfTechUI's other full-screen
pages opens what a swipe down on home opens (Settings → Home → Swipe down
on home: the reading summary, or Settings). Over a book (its Contents,
Notebook, Pages…) it's what a swipe down in a book opens (Quick Settings).

Only a swipe that starts in the top band of the screen, so a page's own
swipes (turning pages, a list's scrolling) keep working below it. Screens
that already have a pull-down (home, a book) and the pulled-down panels
themselves are left alone, as is Wrapped (a swipe down closes it).

Off: Settings → Home → Swipe down from any screen.

  M.install()   once, at start
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

local M = {}

function M.enabled() return require("bos_settings_store").get("pulldown_everywhere") ~= false end

-- what the pull-down never opens over (they have their own, or a swipe down
-- means something there)
local SKIP = {
    ReaderUI = true, filemanager = true, ScreenSaver = true, ScreenSaverLock = true,
    bookshelfos_summary = true, bookshelfos_quicksettings = true,
    stui_wrapped = true, stui_wrapped_note = true,
}

--- The band at the top where a swipe down starts the pull-down.
function M.band()
    local Screen = require("device").screen
    return math.max(Screen:scaleBySize(56), math.floor(Screen:getHeight() * 0.07))
end

--- Is `w` (the window on top) a screen the pull-down opens over?
function M.eligible(w)
    if type(w) ~= "table" or not w.covers_fullscreen then return false end
    if SKIP[w.name] then return false end
    if w._shelf_dims then return false end -- (home itself)
    return true
end

--- What it opens: in a book (a window over the reader), what a swipe down
--- in a book opens; otherwise home's. nil when it's KOReader's menu.
function M.action()
    local Store = require("bos_settings_store")
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local reading = ReaderUI and ReaderUI.instance and ReaderUI.instance.document
    local target = reading and Store.get("reader_swipe") or Store.get("home_swipe")
    if target == "summary" then return function() require("bos_summary").show() end end
    if target == "qs" then return function() require("bos_quicksettings").show() end end
    if target == "settings" then
        return function()
            local s = require("bos_settings").top()
            if s then s:showHome() end
        end
    end
    return nil
end

local function topWindow()
    local stack = UIManager._window_stack
    local e = stack and stack[#stack]
    return e and e.widget
end

function M.install()
    if M._installed then return end
    M._installed = true
    local orig = UIManager.sendEvent
    UIManager.sendEvent = function(um, event, ...)
        if M.enabled() and type(event) == "table" and event.handler == "onGesture" then
            local ges = event.args and event.args[1]
            if type(ges) == "table" and ges.ges == "swipe" and ges.direction == "south"
                    and ges.pos and ges.pos.y <= M.band() then
                local w = topWindow()
                if M.eligible(w) then
                    local action = M.action()
                    if action then
                        local ok, err = pcall(action)
                        if not ok then logger.warn("ShelfTechUI: pull-down:", err) end
                        return true
                    end
                end
            end
        end
        return orig(um, event, ...)
    end
end

return M
