--[[--
ShelfTechUI: one retro-tech interface for KOReader, with Bookshelf inside.

  Home        Bookshelf's home screen (AndyHazz/bookshelf.koplugin, bundled,
              in the retro look: line shelves, square covers on hard
              shadows), with a status bar across the top.
  Reading     tap the page for the reading toolbar (book card, CONTENTS ·
              NOTEBOOK · PAGES, GLIMPSE PIN STATS with a figure each); swipe
              down from the top for Quick Settings.
  Text (Aa)   KOReader's bottom menu, redesigned as a sheet.
  Settings    one full-screen Settings app, with Themes (bos_theme: seven
              looks for everything ShelfTechUI draws).

Bookshelf is loaded from bookshelf_main.lua and registered as ui.bookshelf,
and Glimpse from glimpse/main.lua as ui.glimpse, exactly as their own plugins
would be, so all of both works as it does on its own.

@module koplugin.ShelfTechUI
--]]--

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local PLUGIN_DIR = (debug.getinfo(1, "S").source:gsub("^@(.*)/[^/]*$", "%1"))

-- ShelfTechUI replaces these: with them installed too there would be two
-- home screens and two copies of every module. Then ShelfTechUI only asks
-- for them to be removed, and stays out of the way.
local CONFLICTS = { "bookshelf.koplugin", "bookshelfos.koplugin" }
local found_conflicts = {}
do
    local lfs = require("libs/libkoreader-lfs")
    local parent = PLUGIN_DIR:match("^(.*)/[^/]+$") or "."
    for _i, d in ipairs(CONFLICTS) do
        if lfs.attributes(parent .. "/" .. d, "mode") == "directory" then table.insert(found_conflicts, d) end
    end
end
if #found_conflicts > 0 then
    local Stub = WidgetContainer:extend{ name = "shelftechui", is_doc_only = false }
    function Stub:init()
        if Stub._warned then return end
        Stub._warned = true
        UIManager:nextTick(function()
            UIManager:show(InfoMessage:new{
                text = _("ShelfTechUI includes Bookshelf and Bookshelf OS. Please delete these from koreader/plugins, then restart:") .. "\n\n"
                    .. table.concat(found_conflicts, "\n"),
            })
        end)
    end
    return Stub
end

-- Bookshelf, bundled: its plugin class (instantiated in init)
local Bookshelf
do
    local ok, res = pcall(dofile, PLUGIN_DIR .. "/bookshelf_main.lua")
    if ok and type(res) == "table" then Bookshelf = res
    else logger.warn("ShelfTechUI: Bookshelf did not load:", res) end
end

-- Glimpse, bundled (Erik Fanki's reference-image viewer, in the retro look):
-- its plugin class, from glimpse/ so it finds its own assets and translations
local Glimpse
do
    local ok, res = pcall(dofile, PLUGIN_DIR .. "/glimpse/main.lua")
    if ok and type(res) == "table" then Glimpse = res
    else logger.warn("ShelfTechUI: Glimpse did not load:", res) end
end

-- Bookdrop, bundled (the book store, with its manga reader): its plugin
-- class, from bookdrop/ (its modules are required by name from there)
local Bookdrop
do
    -- its modules are found in bookdrop/ for good (a searcher: KOReader puts
    -- package.path back after loading a plugin, and Bookdrop requires some
    -- of its modules only when they're first needed)
    if not package.loaded._stui_bookdrop_searcher then
        package.loaded._stui_bookdrop_searcher = true
        local dir = PLUGIN_DIR .. "/bookdrop/"
        table.insert(package.loaders, function(name)
            if type(name) ~= "string" or name:find("[/\\]") then return nil end
            local path = dir .. name:gsub("%.", "/") .. ".lua"
            local f = io.open(path, "r")
            if not f then return "\n\tno file '" .. path .. "'" end
            f:close()
            local chunk, err = loadfile(path)
            if not chunk then error(err, 0) end
            return chunk
        end)
    end
    local ok, res = pcall(dofile, PLUGIN_DIR .. "/bookdrop/main.lua")
    if ok and type(res) == "table" then Bookdrop = res
    else logger.warn("ShelfTechUI: Bookdrop did not load:", res) end
end

-- the retro look for Bookshelf (line shelves, hard shadows, mono chrome),
-- and the theme's faces for Bookshelf's text
do
    local ok, err = pcall(function()
        require("stui_retro").install()
        require("stui_retro").themeFonts()
    end)
    if not ok then logger.warn("ShelfTechUI: retro shelf not applied:", err) end
end





-- Bookshelf look for KOReader's own screens (lists, dictionary, skim bar,
-- search, toasts): class-level hooks, once
do
    local ok, err = pcall(function() require("bos_skin").install() end)
    if not ok then logger.warn("ShelfTechUI: KOReader screens keep their look:", err) end
end

-- Hooks on KOReader's reader modules (the skim bar opens PAGES, the pins
-- badge, highlight handles, the book search): installed with the first book,
-- not at start, so home comes up without loading the reader's modules.
-- Class methods are looked up when called, so hooking after the reader's
-- modules exist is enough.
local reader_hooks_done = false
local function installReaderHooks()
    if reader_hooks_done then return end
    reader_hooks_done = true
    for _i, step in ipairs{
        { "PAGES not hooked to the skim bar", function() require("bos_nav").installSkim() end },
        { "pins badge not installed", function() require("bos_pins").install() end },
        { "highlight handles not installed", function() require("bos_handles").install() end },
        { "retro book search not installed", function() require("bos_search").install() end },
    } do
        local ok, err = pcall(step[2])
        if not ok then logger.warn("ShelfTechUI: " .. step[1] .. ":", err) end
    end
end

local Settings = require("bos_settings")

local BookshelfOS = WidgetContainer:extend{
    name = "shelftechui",
    is_doc_only = false,
}

-- The plugins and patches ShelfTechUI replaces: running them alongside it
-- would put two toolbars and two settings systems on screen.
local REPLACED = { "shortcutstoolbar", "kobotoolbar", "settingshub", "aleph", "FilebrowserPlus" }

--- Bookshelf, as its own plugin would be: ui.bookshelf, getting the same events.
function BookshelfOS:startBookshelf()
    if not Bookshelf or self.ui.bookshelf then return end
    local ok, inst = pcall(Bookshelf.new, Bookshelf, { ui = self.ui, path = PLUGIN_DIR })
    if not ok or not inst then
        logger.warn("ShelfTechUI: Bookshelf did not start:", inst)
        return
    end
    self.ui:registerModule("bookshelf", inst)
    pcall(function() require("pluginloader").loaded_plugins.bookshelf = inst end)
    -- the menus are built after every plugin's init: Bookshelf's go in as its own would
    self.bookshelf = inst
end

--- Glimpse, as its own plugin would be: ui.glimpse. If the separate Glimpse
--- plugin is installed too, it got there first: it is left be, and named in
--- the "please delete" note.
function BookshelfOS:startGlimpse()
    if not Glimpse then return end
    if self.ui.glimpse then
        self.glimpse_standalone = true
        return
    end
    local ok, inst = pcall(Glimpse.new, Glimpse, { ui = self.ui, path = PLUGIN_DIR .. "/glimpse" })
    if not ok or not inst then
        logger.warn("ShelfTechUI: Glimpse did not start:", inst)
        return
    end
    self.ui:registerModule("glimpse", inst)
    pcall(function() require("pluginloader").loaded_plugins.glimpse = inst end)
end

--- Bookdrop, as its own plugin would be: ui.bookdrop (a separate Bookdrop
--- plugin, if installed, is left be and named in the "please delete" note).
function BookshelfOS:startBookdrop()
    if not Bookdrop then return end
    if self.ui.bookdrop then
        self.bookdrop_standalone = true
        return
    end
    local ok, inst = pcall(Bookdrop.new, Bookdrop, { ui = self.ui, path = PLUGIN_DIR .. "/bookdrop" })
    if not ok or not inst then
        logger.warn("ShelfTechUI: Bookdrop did not start:", inst)
        return
    end
    self.ui:registerModule("bookdrop", inst)
    pcall(function() require("pluginloader").loaded_plugins.bookdrop = inst end)
end

function BookshelfOS:init()
    -- the file browser's list under home is built when it's seen (bos_fmlazy)
    pcall(function() require("bos_fmlazy").install() end)
    -- 1.6.3 kept two big lists of Settings rows in KOReader's settings file
    -- (about 40 KB, written out each time a book closes): gone
    if not BookshelfOS._rows_cleared then
        BookshelfOS._rows_cleared = true
        pcall(function()
            local St = require("bos_settings_store")
            if St.raw().settings_rows_fm ~= nil or St.raw().settings_rows_reader ~= nil then
                St.set("settings_rows_fm", nil)
                St.set("settings_rows_reader", nil)
            end
        end)
    end
    self:startBookshelf()
    self:startGlimpse()
    self:startBookdrop()
    -- Transfer: a server left on keeps its timer; "on when KOReader starts"
    if not BookshelfOS._transfer_resumed then
        BookshelfOS._transfer_resumed = true
        pcall(function() require("bos_transfer").resume() end)
        -- once: a Transfer tile in Quick Settings
        pcall(function()
            local Store = require("bos_settings_store")
            if Store.get("transfer_tile_added") or not require("bos_transfer").available() then return end
            Store.set("transfer_tile_added", true)
            local Controls = require("bos_controls")
            local list = { unpack(Store.get("qs_controls") or Controls.DEFAULTS.qs) }
            for _i, id in ipairs(list) do if id == "transfer" then return end end
            -- a shortcut you made to FilebrowserPlus becomes Transfer, where it was
            local customs, swapped = Store.raw().custom_controls, {}
            if type(customs) == "table" then
                for i = #customs, 1, -1 do
                    if customs[i].kind == "plugin" and tostring(customs[i].plugin):lower() == "filebrowserplus" then
                        swapped[customs[i].id] = true
                        table.remove(customs, i)
                    end
                end
            end
            for _i, key in ipairs{ "home_controls", "qs_controls" } do
                local ids = Store.get(key)
                if type(ids) == "table" then
                    local out, has = {}, false
                    for _j, id in ipairs(ids) do
                        if swapped[id] then id = "transfer" end
                        if id ~= "transfer" or not has then table.insert(out, id) end
                        if id == "transfer" then has = true end
                    end
                    Store.set(key, out)
                end
            end
            list = { unpack(Store.get("qs_controls") or list) }
            for _i, id in ipairs(list) do if id == "transfer" then return end end
            table.insert(list, "transfer")
            Store.set("qs_controls", list)
        end)
    end
    self:onDispatcherRegisterActions()
    self.settings_app = Settings.attach(self.ui)
    pcall(function() require("bos_shelf").install(self.ui) end)
    pcall(function() require("bos_calendar").install() end)
    -- square corners for the Bookshelf classes loaded since (they load lazily)
    UIManager:nextTick(function() pcall(function() require("stui_retro").squareBookshelf() end) end)
    -- home edge swipes (brightness, warmth, refresh)
    pcall(function() require("bos_device").installHome() end)
    -- the Library in the start menu (once)
    UIManager:nextTick(function() pcall(function() require("bos_library").seedStartMenu()
        require("bos_library").seedLauncher() end) end)
    -- For you: recommendation shelves, the want-to-read shelf, the book page
    pcall(function()
        require("bos_recs").registerSource()
        require("bos_online").registerSource()
        require("bos_bookpage").install()
    end)
    UIManager:nextTick(function() pcall(function()
        require("bos_recs").seed()
        require("bos_online").syncShelves()
        require("bos_online").forYouOnlineOnly()
    end) end)
    -- the Settings app in Bookshelf's start menu (once; Settings → Home to change)
    UIManager:nextTick(function() pcall(function() require("bos_startmenu").seed() end) end)
    if self.ui.document then
        -- the text sheet patches KOReader's ConfigDialog class, once: only a
        -- book has one, so it loads with the first book, not at start
        installReaderHooks()
        local okT, errT = pcall(require, "bos_textsheet")
        if not okT then logger.warn("ShelfTechUI: text sheet not applied:", errT) end
        self.toolbar = require("bos_toolbar").new(self.ui)
    end
    -- Bookshelf home's status bar (Bookshelf's widget class, installed once)
    local okH, Home = pcall(require, "bos_home")
    if okH and Home.install() then
        UIManager:nextTick(function() Home.refresh() end)
    end
    -- updates from GitHub: once a day, on Wi-Fi (Settings → System → Updates)
    if not self.ui.document and not BookshelfOS._update_scheduled then
        BookshelfOS._update_scheduled = true
        UIManager:scheduleIn(20, function() pcall(function() require("bos_update").autoCheck() end) end)
    end
    -- Wrapped: from 1 December, a card on home (once), and in January once more
    if not self.ui.document then
        UIManager:scheduleIn(8, function() BookshelfOS.wrappedNote() end)
    end
    -- the store on home (1.7.1): its chip first on the home bar, once; it's
    -- yours to move or remove (Settings → Home → Status bar)
    pcall(function()
        local St = require("bos_settings_store")
        if St.get("store_chip_seeded") then return end
        St.set("store_chip_seeded", true)
        local Controls = require("bos_controls")
        if type(St.get("home_controls")) ~= "table" or Controls.isOn("home", "store") then return end
        local ids = { "store" }
        for _i, id in ipairs(Controls.ids("home")) do table.insert(ids, id) end
        Controls.setIds("home", ids)
    end)
    -- home layouts (Shelf, Read, Dash): after the edge swipes, so theirs pass through
    pcall(function() require("bos_layouts").install() end)
    -- 1.4.0 put the Layout chip on the home bar unasked; it's now yours to add
    -- (Settings → Home → Status bar), so take that one back off, once
    local LStore = require("bos_settings_store")
    if LStore.get("layout_chip_seeded") and not LStore.get("layout_chip_unseeded") then
        pcall(function()
            local Controls = require("bos_controls")
            local ids = {}
            for _i, id in ipairs(Controls.ids("home")) do if id ~= "layout" then table.insert(ids, id) end end
            Controls.setIds("home", ids)
        end)
        LStore.set("layout_chip_unseeded", true)
    end
    self:warnReplaced()
end

function BookshelfOS:warnReplaced()
    if BookshelfOS._warned then return end
    local found = {}
    for _i, name in ipairs(REPLACED) do
        if self.ui[name] then table.insert(found, name:lower() .. ".koplugin") end
    end
    if self.glimpse_standalone then table.insert(found, "glimpse.koplugin") end
    if self.bookdrop_standalone then table.insert(found, "bookdrop.koplugin") end
    if #found == 0 then return end
    BookshelfOS._warned = true
    UIManager:nextTick(function()
        UIManager:show(InfoMessage:new{
            text = _("ShelfTechUI replaces these plugins. Please delete them from koreader/plugins:") .. "\n\n"
                .. table.concat(found, "\n"),
        })
    end)
end

function BookshelfOS:onDispatcherRegisterActions()
    Dispatcher:registerAction("bookshelfos_quick_settings", {
        category = "none", event = "BookshelfOSQuickSettings", title = _("Quick Settings"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_settings", {
        category = "none", event = "BookshelfOSSettings", title = _("ShelfTechUI: Settings"), general = true,
    })
    Dispatcher:registerAction("stui_library", {
        category = "none", event = "StuiLibrary", title = _("ShelfTechUI: Library"), general = true,
    })
    Dispatcher:registerAction("stui_transfer", {
        category = "none", event = "StuiTransfer", title = _("ShelfTechUI: Transfer"), general = true,
    })
    Dispatcher:registerAction("stui_transfer_toggle", {
        category = "none", event = "StuiTransferToggle", title = _("ShelfTechUI: Transfer on / off"), general = true,
    })
    Dispatcher:registerAction("stui_home_layout", {
        category = "none", event = "StuiHomeLayout", title = _("ShelfTechUI: next home layout"), general = true,
    })
    Dispatcher:registerAction("stui_wrapped", {
        category = "none", event = "StuiWrapped", title = _("ShelfTechUI: Wrapped (your year in books)"), general = true,
    })
    Dispatcher:registerAction("stui_store", {
        category = "none", event = "StuiStore", title = _("ShelfTechUI: Store"), general = true,
    })
    Dispatcher:registerAction("stui_online_picks", {
        category = "none", event = "StuiOnlinePicks", title = _("ShelfTechUI: Online picks"), general = true,
    })
    Dispatcher:registerAction("bookshelfos_toolbar", {
        category = "none", event = "BookshelfOSToolbar", title = _("Reading toolbar"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_contents", {
        category = "none", event = "BookshelfOSContents", title = _("ShelfTechUI contents"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_bookmarks", {
        category = "none", event = "BookshelfOSBookmarks", title = _("ShelfTechUI notebook: bookmarks"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_notes", {
        category = "none", event = "BookshelfOSNotes", title = _("ShelfTechUI notebook"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_map", {
        category = "none", event = "BookshelfOSMap", title = _("ShelfTechUI pages: grid"), reader = true,
    })
    Dispatcher:registerAction("bookshelfos_scrubber", {
        category = "none", event = "BookshelfOSScrubber", title = _("ShelfTechUI pages"), reader = true,
    })
end

function BookshelfOS:onBookshelfOSContents()
    if self.ui.document then require("bos_nav").showContents(self.ui) end
    return true
end

function BookshelfOS:onBookshelfOSNotes()
    if self.ui.document then require("bos_nav").showNotebook(self.ui) end
    return true
end

function BookshelfOS:onBookshelfOSBookmarks()
    if self.ui.document then require("bos_nav").showBookmarks(self.ui) end
    return true
end

function BookshelfOS:onBookshelfOSMap()
    if self.ui.document then require("bos_nav").show(self.ui, "pages", { view = "grid" }) end
    return true
end

function BookshelfOS:onBookshelfOSScrubber()
    if self.ui.document then require("bos_nav").showScrubber(self.ui) end
    return true
end

function BookshelfOS:onStuiLibrary()
    require("bos_library").show()
    return true
end

function BookshelfOS:onStuiTransfer()
    require("bos_transfer").show()
    return true
end

function BookshelfOS:onStuiTransferToggle()
    require("bos_transfer").toggle()
    return true
end

function BookshelfOS:onNetworkConnected()
    UIManager:scheduleIn(10, function() pcall(function() require("bos_update").autoCheck() end) end)
end

--- Wrapped's card, only over home itself (not a book, not a dialog).
function BookshelfOS.wrappedNote()
    pcall(function()
        local W = require("bos_wrapped")
        local stack = UIManager._window_stack
        local top = stack and stack[#stack] and stack[#stack].widget
        local okS, Shelf = pcall(require, "bos_shelf")
        local home = okS and Shelf.shelfWidget and Shelf.shelfWidget()
        if home and top == home then W.maybeNotify() end
    end)
end

function BookshelfOS:onResume()
    if not self.ui.document then UIManager:scheduleIn(3, function() BookshelfOS.wrappedNote() end) end
end

function BookshelfOS:onStuiWrapped()
    require("bos_wrapped").open()
    return true
end

function BookshelfOS:onStuiHomeLayout()
    require("bos_layouts").cycle()
    return true
end

function BookshelfOS:onStuiStore()
    require("bos_store").open()
    return true
end

function BookshelfOS:onStuiOnlinePicks()
    require("bos_online").showPicks()
    return true
end

function BookshelfOS:onBookshelfOSQuickSettings()
    require("bos_quicksettings").show()
    return true
end

function BookshelfOS:onBookshelfOSSettings()
    self.settings_app:showHome()
    return true
end

function BookshelfOS:onBookshelfOSToolbar()
    if self.toolbar then self.toolbar:toggle() end
    return true
end

-- ---- reader events, for the reading toolbar --------------------------------

function BookshelfOS:onReaderReady()
    if not self.ui.document then return end
    pcall(function() require("bos_pins").attach(self.ui) end)
    pcall(function() require("bos_pins").installHighlightButton(self.ui) end)
end

function BookshelfOS:onPageUpdate()
    if self.toolbar then self.toolbar:onPageUpdate() end
end

function BookshelfOS:onCloseDocument()
    if self.toolbar then self.toolbar:onCloseDocument() end
    pcall(function() require("bos_pins").detach(self.ui) end)
end

function BookshelfOS:onSetDimensions()
    if self.toolbar then self.toolbar:onSetDimensions() end
    self.settings_app:onSetDimensions()
end

function BookshelfOS:onCloseWidget()
    if self.toolbar then self.toolbar:onCloseWidget() end
    self.settings_app:onCloseWidget()
end

return BookshelfOS
